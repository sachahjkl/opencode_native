// What can be done to a session as a whole: move it to another folder, keep it in a file and bring it back, see what it changed, and go
// back to a prompt, its changes undone.
//
// Going back is in two steps on the server, and the first is not a rehearsal: `revert/stage` writes the files back at once and says
// which, `revert/commit` then drops what came after the prompt, `DELETE revert` puts the files back as they were. So the dialog says the
// truth (they are restored already), every way of closing it that is not Go back cancels, and a stage found on opening a session (the
// program died in between, another client did it) brings the dialog back rather than leaving the files changed with nothing on screen.
package occ

import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:mem/virtual"
import "core:os"
import "core:strings"
import "gt:platform"
import "gt:ui"

session_move_pick :: proc(app: ^App, id: string) {
	r := platform.pick_folder_dialog({owner = app.win, title = "Move the session to", remember_id = "session_move"})
	defer platform.dialog_result_destroy(&r)
	if r.status != .Chosen || len(r.paths) == 0 { return }
	request(app, .Session_Moved, "POST", fmt.tprintf("/api/session/%s/move", id), fmt.tprintf(`{{"directory":%s}}`, jquote(r.paths[0])), id)
}

// (`redacted`: the server replaces every text by a mark: a file that shows the shape of a session, to share.)
session_export :: proc(app: ^App, id: string, redacted := false) {
	request(app, .Session_Export, "GET", fmt.tprintf("/api/experimental/session/%s/export%s", id, redacted ? "?sanitize=true" : ""), tag = id)
}

// (`raw`: the server's answer: what goes in the file is what is under its "data", as the import takes it.)
session_export_save :: proc(app: ^App, id, raw: string) {
	body := export_body(raw)
	title := id
	if s := find_session(app, id); s != nil && s.title != "" { title = s.title }
	filters := []platform.File_Filter{{name = "Session", patterns = {"*.json"}}}
	r := platform.save_file_dialog({owner = app.win, title = "Export the session", filters = filters, suggested_name = fmt.tprintf("%s.json", file_safe(title)), default_ext = "json", remember_id = "session_export", overwrite_prompt = true})
	defer platform.dialog_result_destroy(&r)
	if r.status != .Chosen || len(r.paths) == 0 { return }
	if os.write_entire_file(r.paths[0], transmute([]u8)body) != nil { ui.toast(.Bad, "The file could not be written"); return }
	ui.toast(.Good, "Session exported")
}

export_body :: proc(raw: string) -> string {
	body := strings.trim_space(raw)
	if strings.has_prefix(body, `{"data":`) && strings.has_suffix(body, "}") { body = body[len(`{"data":`):len(body) - 1] }
	return body
}

// A title as a file name, in the temporary allocator.
file_safe :: proc(s: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	for r in s { strings.write_rune(&b, strings.contains_rune(`\/:*?"<>|`, r) || r < ' ' ? '-' : r) }
	return strings.to_string(b)
}

session_import_pick :: proc(app: ^App) {
	filters := []platform.File_Filter{{name = "Session", patterns = {"*.json"}}}
	r := platform.open_file_dialog({owner = app.win, title = "Import a session", filters = filters, all_files = true, remember_id = "session_export"})
	defer platform.dialog_result_destroy(&r)
	if r.status != .Chosen || len(r.paths) == 0 { return }
	session_import_file(app, r.paths[0])
}

session_import_file :: proc(app: ^App, path: string) {
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil { ui.toast(.Bad, "The file could not be read"); return }
	v, bad := json.parse(data, parse_integers = true, allocator = context.temp_allocator)
	id := jstr(v, "info", "id")
	if bad != nil || id == "" { ui.toast(.Bad, "This file is not an exported session"); return }
	request(app, .Session_Import, "POST", "/api/experimental/session/import", string(data), id)
}

// The server refuses a session it has already: that one is opened.
session_import_conflict :: proc(app: ^App, id: string) {
	open_root(app, id)
	ui.toast(.Warn, "This session is already here")
}

////////////////////////////////
// What a session changed

File_Change :: struct {
	file, patch, status: string,
	additions, deletions: int,
	more, open: bool,
}

Changes :: struct {
	open, loading: bool,
	session:   string,              // (owned)
	from:      string,              // only what this prompt changed (owned)
	first:     string,              // the whole session: its first prompt, the last one being looked for (owned)
	whole:     bool,                // asked from the first prompt to the last
	last_turn: bool,                // the server refused that: only the last turn is shown
	revert:    string,              // going back to this message (owned, "": only looking)
	prompt:    string,              // what comes back to the composer then (owned)
	staged:    bool,                // the server has it staged: the files are written back
	found:     bool,                // staged by no one here: found on opening the session
	no_snapshot: bool,              // the folder keeps none: the files do not go back
	files:     [dynamic]File_Change,
	arena:     virtual.Arena,
	has_arena: bool,
}

@(private = "file")
changes_reset :: proc(c: ^Changes) {
	if c.has_arena { virtual.arena_destroy(&c.arena) }
	delete(c.session); delete(c.from); delete(c.first); delete(c.revert); delete(c.prompt)
	delete(c.files)
	c^ = {}
}

// (A stage on its way, its dialog closed by then: its answer is awaited, to cancel it.)
@(private = "file")
changes_held :: proc(c: ^Changes) -> bool { return c.staged || (c.loading && c.revert != "") }

// What the session changed from its first prompt to its last: the diff alone says only the last turn, and wants prompts as its ends.
changes_open :: proc(app: ^App, id: string, from := "") {
	c := &app.cx.changes
	if changes_held(c) { return }
	changes_reset(c)
	c.open, c.loading, c.session, c.from = true, true, strings.clone(id), strings.clone(from)
	if from != "" {
		request(app, .Changes, "GET", fmt.tprintf("/api/session/%s/diff?from=%s", id, from), tag = id)
	} else {
		request(app, .Changes_Range, "GET", fmt.tprintf("/api/session/%s/message?type=user&limit=1&order=asc", id), tag = id)
	}
}

changes_range :: proc(app: ^App, id: string, v: json.Value) {
	c := &app.cx.changes
	if !c.open || c.session != id { return }
	list := jarr(v, "data")
	if len(list) == 0 { c.loading = false; return }   // (no prompt yet)
	msg := jstr(list[0], "id")
	if c.first == "" {
		c.first = strings.clone(msg)
		request(app, .Changes_Range, "GET", fmt.tprintf("/api/session/%s/message?type=user&limit=1&order=desc", id), tag = id)
		return
	}
	c.whole = true
	request(app, .Changes, "GET", fmt.tprintf("/api/session/%s/diff?from=%s&to=%s", id, c.first, msg), tag = id)
}

// A range over a change of folder is refused: the last turn then, and the dialog says so.
changes_refused :: proc(app: ^App, id: string) -> bool {
	c := &app.cx.changes
	if !c.open || !c.whole || c.session != id { return false }
	c.whole, c.last_turn = false, true
	request(app, .Changes, "GET", fmt.tprintf("/api/session/%s/diff", id), tag = id)
	return true
}

// Back to the prompt `msg`: from this request on, the files are as they were then, until Go back or Cancel.
revert_stage :: proc(app: ^App, id, msg, prompt: string) {
	c := &app.cx.changes
	if changes_held(c) { return }
	changes_reset(c)
	c.open, c.loading, c.session, c.revert, c.prompt = true, true, strings.clone(id), strings.clone(msg), strings.clone(prompt)
	request(app, .Changes, "POST", fmt.tprintf("/api/session/%s/revert/stage", id), fmt.tprintf(`{{"messageID":%s,"files":true}}`, jquote(msg)), id)
}

@(private = "file")
changes_fill :: proc(c: ^Changes, list: json.Array) {
	if !c.has_arena { _ = virtual.arena_init_growing(&c.arena); c.has_arena = true }
	a := virtual.arena_allocator(&c.arena)
	for it, i in list {
		more, _ := jget(it, "more").(json.Boolean)
		append(&c.files, File_Change{
			file = strings.clone(jstr(it, "file"), a), patch = strings.clone(jstr(it, "patch"), a), status = strings.clone(jstr(it, "status"), a),
			additions = int(jnum(it, "additions")), deletions = int(jnum(it, "deletions")), more = bool(more), open = i < CHANGES_OPEN_FILES,
		})
	}
}

// The answer of either: a diff is a list, a stage has it under "files" beside the snapshot it went back to.
changes_load :: proc(app: ^App, id: string, v: json.Value) {
	c := &app.cx.changes
	if c.session != id || !c.loading { return }
	c.loading = false
	if c.revert != "" {
		c.staged = true   // (closed in the meantime: changes_dialog cancels it)
		c.no_snapshot = jstr(v, "data", "snapshot") == ""
		if c.open { changes_fill(c, jarr(v, "data", "files")) }
	} else if c.open {
		changes_fill(c, jarr(v, "data"))
	}
}

// `revert`, the session's staged going back, as its description has it: this session was left there.
revert_found :: proc(app: ^App, id: string, revert: json.Value) {
	c := &app.cx.changes
	if c.open || changes_held(c) { return }
	changes_reset(c)
	c.open, c.staged, c.found = true, true, true
	c.session, c.revert = strings.clone(id), strings.clone(jstr(revert, "messageID"))
	c.no_snapshot = jstr(revert, "snapshot") == ""
	changes_fill(c, jarr(revert, "files"))
}

changes_failed :: proc(app: ^App) {
	c := &app.cx.changes
	c.open, c.loading, c.staged = false, false, false
}

@(private = "file")
revert_commit :: proc(app: ^App) {
	c := &app.cx.changes
	request(app, .Revert_Done, "POST", fmt.tprintf("/api/session/%s/revert/commit", c.session), "", c.session)
	c.staged, c.open = false, false
}

@(private = "file")
revert_cancel :: proc(app: ^App) {
	c := &app.cx.changes
	request(app, .Revert_Cancelled, "DELETE", fmt.tprintf("/api/session/%s/revert", c.session), "", c.session)
	c.staged = false
}

// The conversation without what came after; the prompt back in the composer, unless something is being written there.
revert_done :: proc(app: ^App, id: string) {
	c := &app.cx.changes
	if id == app.chat.id {
		load_messages(app, id)
		if c.session == id && c.prompt != "" && strings.trim_space(ui.area_string(&app.composer)) == "" {
			ui.area_set(&app.composer, c.prompt)
			app.cx.focus_composer = true
		}
	}
	app.refresh_due = true
	ui.toast(.Good, "Back to this prompt")
}

// Elsewhere (another client, or this one's own, then nothing is open any more).
revert_gone :: proc(app: ^App, id: string) {
	c := &app.cx.changes
	if c.session == id && c.staged { c.staged, c.open = false, false }
}

// What the head of the dialog says, by what is shown.
changes_say :: proc(c: ^Changes) -> string {
	if c.loading { return "Reading…" }
	add, del := 0, 0
	for f in c.files { add += f.additions; del += f.deletions }
	count := fmt.tprintf("%d %s  +%d  -%d", len(c.files), len(c.files) == 1 ? "file" : "files", add, del)
	if c.revert != "" {
		lead := c.found ? "This session was left going back. " : ""
		if c.no_snapshot { return fmt.tprintf("%sThis folder keeps no snapshots: the files stay as they are, only the conversation goes back.", lead) }
		if len(c.files) == 0 { return fmt.tprintf("%sNo file to restore: only the conversation goes back.", lead) }
		return fmt.tprintf("%s%s, written back on disk already. Go back keeps it so and drops what came after this prompt; Cancel puts the files back.", lead, count)
	}
	if len(c.files) == 0 { return "No change recorded. Only a git folder keeps them." }
	if c.last_turn { return fmt.tprintf("%s, in the last turn only: this session changed folder, it cannot be compared as a whole.", count) }
	return count
}

changes_dialog :: proc(app: ^App, em: f32) {
	c := &app.cx.changes
	if !c.open {
		if c.staged { revert_cancel(app) }   // (closed by Escape or a click outside: the files go back)
		return
	}
	if ui.modal_sized("changes", DIALOG_PREFERRED_EM[.Changes] * em, &app.cx.dialogs[.Changes], &c.open, DIALOG_MIN_EM[.Changes] * em) {
		dialog_backdrop()
		ui.spacer(ui.px(em * 0.9))
		ui.next({width = ui.fill(), height = ui.children_sum(), axis = .X})
		if ui.row(id = "###ch_head") {
			ui.spacer(ui.px(em * DIALOG_MARGIN_EM))
			ui.next({width = ui.fill(), height = ui.children_sum(), axis = .Y})
			if ui.column() {
				title := c.revert != "" ? "Go back to this prompt" : c.from != "" ? "What this prompt changed" : "What this session changed"
				text("t", title, hex(HEX_BRIGHT), ui.Style_Mod{font_size = math.round(em * FS_TITLE), height = ui.px(em * 2)}, ui.fill())
				info_line(app, "###ch_say", changes_say(c), em)
			}
			ui.spacer(ui.px(em * DIALOG_MARGIN_EM))
		}
		ui.spacer(ui.px(em * 0.5))
		ui.next({width = ui.fill(), height = ui.fill()})
		if ui.scroll_y("###ch_list") {
			for &f, i in c.files {
				ui.next({width = ui.fill(), height = ui.children_sum(), axis = .X})
				if ui.row(id = fmt.tprintf("###chf%d", i)) {
					ui.spacer(ui.px(em * DIALOG_MARGIN_EM))
					ui.next({width = ui.fill(), height = ui.children_sum(), axis = .Y})
					if ui.column() {
						ui.next({width = ui.fill(), height = ui.px(math.round(em * 1.9)), axis = .X, cross = .Center, cursor = .Hand})
						head := ui.build_box({.Clickable}, "###fh")
						if ui.signal(head).clicked { f.open = !f.open }
						if ui.parent(head) {
							glyph(f.open ? ICO_DOWN : ICO_RIGHT, hex(HEX_FAINT), math.round(em * ICON_SMALL))
							ui.spacer(ui.px(em * 0.3))
							text("n", f.file, hex(HEX_TEXT), ui.Style_Mod{font = app.mono, font_size = math.round(em * FS_SMALL)}, ui.fill())
							if f.status != "" && f.status != "modified" {
								text("s", f.status, hex(HEX_FAINT), ui.Style_Mod{font_size = math.round(em * FS_CAPTION)})
								ui.spacer(ui.px(em * 0.6))
							}
							text("a", fmt.tprintf("+%d", f.additions), hex(HEX_GREEN), ui.Style_Mod{font = app.mono, font_size = math.round(em * FS_CAPTION)})
							ui.spacer(ui.px(em * 0.4))
							text("d", fmt.tprintf("-%d", f.deletions), hex(HEX_RED), ui.Style_Mod{font = app.mono, font_size = math.round(em * FS_CAPTION)})
						}
						if f.open {
							diff_view(app, "###fd", f.patch, em, CHANGES_DIFF_LINES)
							if f.more { text("m", "The server gave only the beginning of this file.", hex(HEX_FAINT), ui.Style_Mod{font_size = math.round(em * FS_CAPTION), height = ui.px(em * 1.5)}, ui.fill()) }
						}
						ui.spacer(ui.px(em * 0.4))
					}
					ui.spacer(ui.px(em * DIALOG_MARGIN_EM))
				}
			}
		}
		if c.revert != "" {
			ui.spacer(ui.px(em * 0.5))
			ui.next({width = ui.fill(), height = ui.children_sum(), axis = .X, cross = .Center})
			if ui.row(.Center, id = "###ch_foot") {
				ui.spacer(ui.fill())
				if bevel_button("###ch_cancel", "Cancel", "", .Normal).clicked { c.open = false }
				ui.spacer(ui.px(em * 0.5))
				if bevel_button("###ch_go", "Go back", ICO_UNDO, .Danger, disabled = c.loading).clicked { revert_commit(app) }
				ui.spacer(ui.px(em * DIALOG_MARGIN_EM))
			}
		}
		ui.spacer(ui.px(em * 0.8))
		dialog_close(&c.open)
	}
}
