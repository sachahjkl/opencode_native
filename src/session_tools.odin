// What can be done to a session as a whole: move it to another folder, keep it in a file and bring it back, see what it changed, and go
// back to a prompt, its changes undone.
//
// Going back is in two steps on the server, and the first is not a rehearsal: `revert/stage` writes the files back at once and says
// which, `revert/commit` then drops what came after the prompt, `DELETE revert` puts the files back as they were. So the dialog says the
// truth (they are restored already), every way of closing it that is not Go back cancels, and a stage found on opening a session (the
// program died in between, another client did it) brings the dialog back rather than leaving the files changed with nothing on screen.
//
// The dialog is one machine, Changes_State: closed; viewing a diff (the steps of Changes_View_Step); a stage on its way, closed or not;
// staged; then committing or cancelling until the server has answered. Each request has its ticket: a late answer of one state never
// reaches another. A stage nobody waits for any more is cancelled by the one who knows it: the state, or net.odin answer_left once the
// server was left.
package ocn

import "base:runtime"

import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:mem/virtual"
import "core:os"
import "core:strings"
import "gt:platform"
import "gt:ui"
import diff "gt:diff"
import lucide "gt:lucide"
import remote "gt:remote"
import i18n "gt:i18n"

// What a dialog of a session's (a folder, a file) answers to, and what a task writes or reads there (heap; freed by its end).
@(private = "file")
Session_File :: struct { app: ^App, id, body, path: string, ok: bool }

@(private = "file")
session_file_new :: proc(app: ^App, id := "", body := "") -> ^Session_File {
	a := runtime.heap_allocator()
	f := new(Session_File, a)
	f^ = {app = app, id = strings.clone(id, a), body = strings.clone(body, a)}
	return f
}

@(private = "file")
session_file_free :: proc(data: rawptr) {
	f := (^Session_File)(data)
	a := runtime.heap_allocator()
	delete(f.id, a); delete(f.body, a); delete(f.path, a)
	free(f, a)
}

session_move_pick :: proc(app: ^App, id: string) {
	ui.file_dialog(&app.state, .Folder, {owner = app.win, title = i18n.tr("Move the session to"), remember_id = "session_move"}, proc(r: platform.Dialog_Result, user: rawptr) {
		f := (^Session_File)(user)
		defer session_file_free(f)
		if r.status != .Chosen || len(r.paths) == 0 { return }
		request(f.app, .Session_Moved, "POST", fmt.tprintf("/api/session/%s/move", f.id), fmt.tprintf(`{{"directory":%s}}`, jquote(r.paths[0])), f.id)
	}, session_file_new(app, id))
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
	filters := []platform.File_Filter{{name = i18n.tr("Session"), patterns = {"*.json"}}}
	// (the dialog, then the file written: both on the chores)
	ui.file_dialog(&app.state, .Save, {owner = app.win, title = i18n.tr("Export the session"), filters = filters, suggested_name = fmt.tprintf("%s.json", file_safe(title)), default_ext = "json", remember_id = "session_export", overwrite_prompt = true}, proc(r: platform.Dialog_Result, user: rawptr) {
		f := (^Session_File)(user)
		if r.status != .Chosen || len(r.paths) == 0 { session_file_free(f); return }
		f.path = strings.clone(r.paths[0], runtime.heap_allocator())
		ui.task(&f.app.state, proc(data: rawptr) {
			f := (^Session_File)(data)
			f.ok = os.write_entire_file(f.path, transmute([]u8)f.body) == nil
		}, proc(data: rawptr, _: u64) {
			f := (^Session_File)(data)
			if f.ok { ui.announce(&f.app.announcer, .Good, i18n.tr("Session exported")) } else { ui.announce(&f.app.announcer, .Bad, i18n.tr("The file could not be written")) }
			session_file_free(f)
		}, f, session_file_free)
	}, session_file_new(app, id, body))
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
	filters := []platform.File_Filter{{name = i18n.tr("Session"), patterns = {"*.json"}}}
	ui.file_dialog(&app.state, .Open, {owner = app.win, title = i18n.tr("Import a session"), filters = filters, all_files = true, remember_id = "session_export"}, proc(r: platform.Dialog_Result, user: rawptr) {
		if r.status != .Chosen || len(r.paths) == 0 { return }
		session_import_file((^App)(user), r.paths[0])
	}, app)
}

// The file is read by a task; what it holds is sent at the next build.
session_import_file :: proc(app: ^App, path: string) {
	f := session_file_new(app)
	f.path = strings.clone(path, runtime.heap_allocator())
	ui.task(&app.state, proc(data: rawptr) {
		f := (^Session_File)(data)
		bytes, err := os.read_entire_file(f.path, runtime.heap_allocator())
		f.ok = err == nil
		if f.ok { f.body = string(bytes) }
	}, proc(data: rawptr, _: u64) {
		f := (^Session_File)(data)
		defer session_file_free(f)
		if !f.ok { ui.announce(&f.app.announcer, .Bad, i18n.tr("The file could not be read")); return }
		v, bad := json.parse(transmute([]u8)f.body, parse_integers = true, allocator = context.temp_allocator)
		id := jstr(v, "info", "id")
		if bad != nil || id == "" { ui.announce(&f.app.announcer, .Bad, i18n.tr("This file is not an exported session")); return }
		request(f.app, .Session_Import, "POST", "/api/experimental/session/import", f.body, id)
	}, f, session_file_free)
}

// The server refuses a session it has already: that one is opened.
session_import_conflict :: proc(app: ^App, id: string) {
	open_root(app, id)
	ui.announce(&app.announcer, .Warn, i18n.tr("This session is already here"))
}

////////////////////////////////
// What a session changed

File_Change :: struct {
	file, patch, status: string,
	diff:      diff.Parsed,   // the patch read once, as it came (changes_fill)
	additions, deletions: int,
	more, open: bool,
}

Changes_View_Step :: enum u8 {
	First,      // the session's first prompt is looked for
	Last,       // ... its last
	Diff,       // the files, from a prompt or between the two
	Last_Turn,  // the server refused the range: the files of the last turn
}

Changes_Closed :: struct {}

// Only looking.
Changes_Viewing :: struct {
	session, from: string,   // (owned) from: only what this prompt changed
	first:     string,       // the whole session: its first prompt (owned)
	step:      Changes_View_Step,
}

// `revert/stage` is on its way: from here on the files may be written back.
Changes_Staging :: struct {
	session, message, prompt: string,   // (owned) message: going back to it; prompt: what comes back to the composer then
	closed:    bool,                    // the dialog is closed: its answer is awaited, to cancel it
}

Changes_Staged :: struct {
	session, message, prompt: string,   // (owned)
	found:     bool,                    // staged by no one here: found on opening the session
	no_snapshot: bool,                  // the folder keeps none: the files do not go back
}

Changes_Committing :: struct { session, prompt: string }   // (owned)
Changes_Cancelling :: struct { session: string }           // (owned)

Changes_State :: union #no_nil { Changes_Closed, Changes_Viewing, Changes_Staging, Changes_Staged, Changes_Committing, Changes_Cancelling }

Changes :: struct {
	state:     Changes_State,
	read:      remote.Remote,          // what Viewing reads, a step at a time
	revert:    remote.Remote,          // the stage, the commit or the cancel on its way
	gone_seq:  Seq,             // the stream's clock when going back last ended for the session shown: a read asked before that is old
	files:     [dynamic]File_Change,
	arena:     virtual.Arena,
}

@(private = "file")
changes_files_clear :: proc(c: ^Changes) {
	virtual.arena_destroy(&c.arena)
	clear(&c.files)
}

// Back to Closed: what the state held goes, and so does whatever was on its way for it.
@(private = "file")
changes_reset :: proc(c: ^Changes) {
	switch s in c.state {
	case Changes_Closed:
	case Changes_Viewing:    delete(s.session); delete(s.from); delete(s.first)
	case Changes_Staging:    delete(s.session); delete(s.message); delete(s.prompt)
	case Changes_Staged:     delete(s.session); delete(s.message); delete(s.prompt)
	case Changes_Committing: delete(s.session); delete(s.prompt)
	case Changes_Cancelling: delete(s.session)
	}
	c.state = Changes_Closed{}
	changes_files_clear(c)
	remote.reset(&c.read)
	remote.reset(&c.revert)
}

// A stage or what follows it is on its way or on screen: nothing else takes its place, or the prompt it holds would go.
changes_held :: proc(c: ^Changes) -> bool {
	switch _ in c.state {
	case Changes_Closed, Changes_Viewing: return false
	case Changes_Staging, Changes_Staged, Changes_Committing, Changes_Cancelling: return true
	}
	return false
}

// (What was clicked does not happen: it says why.)
@(private = "file")
changes_wait :: proc(app: ^App) -> bool {
	if !changes_held(&app.cx.changes) { return false }
	ui.announce(&app.announcer, .Warn, i18n.tr("Going back to a prompt is under way: try again in a moment"))
	return true
}

// Whether the dialog is on screen.
changes_shown :: proc(c: ^Changes) -> bool {
	switch s in c.state {
	case Changes_Viewing, Changes_Staged: return true
	case Changes_Staging:                 return !s.closed
	case Changes_Closed, Changes_Committing, Changes_Cancelling: return false
	}
	return false
}

// What the session changed from its first prompt to its last: the diff alone says only the last turn, and wants prompts as its ends.
// (What was being looked at gives way: its answers no longer count.)
changes_open :: proc(app: ^App, id: string, from := "") {
	c := &app.cx.changes
	if changes_wait(app) { return }
	view := Changes_Viewing{session = strings.clone(id), from = strings.clone(from)}
	changes_reset(c)
	c.state = view
	changes_read(app)
}

// From the first step: when it opens, and on Try again.
@(private = "file")
changes_read :: proc(app: ^App) {
	c := &app.cx.changes
	v, viewing := &c.state.(Changes_Viewing)
	if !viewing { return }
	changes_files_clear(c)
	delete(v.first)
	v.first = ""
	remote.reset(&c.read)
	remote.begin(&c.read)
	if v.from != "" {
		v.step = .Diff
		request(app, .Changes, "GET", fmt.tprintf("/api/session/%s/diff?from=%s", v.session, v.from), reading = &c.read)
	} else {
		v.step = .First
		request(app, .Changes_Range, "GET", fmt.tprintf("/api/session/%s/message?type=user&limit=1&order=asc", v.session), reading = &c.read)
	}
}

// The server answers again, and what is on screen could not be read.
changes_reread :: proc(app: ^App) {
	c := &app.cx.changes
	if _, viewing := c.state.(Changes_Viewing); viewing && remote.failed(&c.read) { changes_read(app) }
}

changes_range :: proc(app: ^App, v: json.Value) {
	c := &app.cx.changes
	s, viewing := &c.state.(Changes_Viewing)
	if !viewing { return }
	list := jarr(v, "data")
	if len(list) == 0 { return }   // (no prompt yet)
	msg := jstr(list[0], "id")
	remote.begin(&c.read)
	if s.step == .First {
		s.first = strings.clone(msg)
		s.step = .Last
		request(app, .Changes_Range, "GET", fmt.tprintf("/api/session/%s/message?type=user&limit=1&order=desc", s.session), reading = &c.read)
		return
	}
	s.step = .Diff
	request(app, .Changes, "GET", fmt.tprintf("/api/session/%s/diff?from=%s&to=%s", s.session, s.first, msg), reading = &c.read)
}

// A range over a change of folder is refused: the last turn then, and the dialog says so.
changes_refused :: proc(app: ^App) {
	c := &app.cx.changes
	s, viewing := &c.state.(Changes_Viewing)
	if !viewing || s.step != .Diff || s.first == "" { return }
	s.step = .Last_Turn
	remote.begin(&c.read)
	request(app, .Changes, "GET", fmt.tprintf("/api/session/%s/diff", s.session), reading = &c.read)
}

// Back to the prompt `msg`: from this request on, the files are as they were then, until Go back or Cancel.
revert_stage :: proc(app: ^App, id, msg, prompt: string) {
	c := &app.cx.changes
	if changes_wait(app) { return }
	session, message, words := strings.clone(id), strings.clone(msg), strings.clone(prompt)
	changes_reset(c)
	c.state = Changes_Staging{session = session, message = message, prompt = words}
	remote.begin(&c.revert)
	request(app, .Revert_Staged, "POST", fmt.tprintf("/api/session/%s/revert/stage", session), fmt.tprintf(`{{"messageID":%s,"files":true}}`, jquote(message)), session, reading = &c.revert)
}

@(private = "file")
changes_fill :: proc(c: ^Changes, list: json.Array) {
	changes_files_clear(c)
	_ = virtual.arena_init_growing(&c.arena)
	a := virtual.arena_allocator(&c.arena)
	for it, i in list {
		more, _ := jget(it, "more").(json.Boolean)
		patch := strings.clone(jstr(it, "patch"), a)
		append(&c.files, File_Change{
			file = strings.clone(jstr(it, "file"), a), patch = patch, diff = diff.parse(patch, a), status = strings.clone(jstr(it, "status"), a),
			additions = int(jnum(it, "additions")), deletions = int(jnum(it, "deletions")), more = bool(more), open = i < CHANGES_OPEN_FILES,
		})
	}
}

// A diff is a list.
changes_load :: proc(app: ^App, v: json.Value) {
	c := &app.cx.changes
	if _, viewing := c.state.(Changes_Viewing); viewing { changes_fill(c, jarr(v, "data")) }
}

// A stage has its files under "files", beside the snapshot it went back to. Closed in the meantime: it is cancelled at once.
revert_staged :: proc(app: ^App, v: json.Value) {
	c := &app.cx.changes
	s, staging := c.state.(Changes_Staging)
	if !staging { return }
	c.state = Changes_Staged{session = s.session, message = s.message, prompt = s.prompt, no_snapshot = jstr(v, "data", "snapshot") == ""}
	if s.closed { revert_cancel(app); return }
	changes_fill(c, jarr(v, "data", "files"))
}

// `revert`, the session's staged going back, as its description has it: this session was left there. (`asked_at`: a description read
// before going back ended says what no longer is.)
revert_found :: proc(app: ^App, id: string, revert: json.Value, asked_at: Seq) {
	c := &app.cx.changes
	if _, closed := c.state.(Changes_Closed); !closed || newer(c.gone_seq, asked_at) { return }
	c.state = Changes_Staged{
		session = strings.clone(id), message = strings.clone(jstr(revert, "messageID")),
		found = true, no_snapshot = jstr(revert, "snapshot") == "",
	}
	changes_fill(c, jarr(revert, "files"))
}

// Escape, the cross, a click outside, Cancel. Nothing stays staged by being closed: the files go back.
changes_close :: proc(app: ^App) {
	c := &app.cx.changes
	#partial switch &s in c.state {
	case Changes_Viewing: changes_reset(c)
	case Changes_Staging: s.closed = true
	case Changes_Staged:  revert_cancel(app)
	}
}

// What the session's description says from here until the server has told is the past, unless this fails: revert_failed.
@(private = "file")
revert_leaving :: proc(app: ^App, id: string) {
	if id == app.chat.id { app.cx.changes.gone_seq = app.cx.stream_seq + 1 }
}

revert_commit :: proc(app: ^App) {
	c := &app.cx.changes
	s, staged := c.state.(Changes_Staged)
	if !staged { return }
	delete(s.message)
	c.state = Changes_Committing{session = s.session, prompt = s.prompt}
	changes_files_clear(c)
	revert_leaving(app, s.session)
	remote.begin(&c.revert)
	request(app, .Revert_Done, "POST", fmt.tprintf("/api/session/%s/revert/commit", s.session), "", s.session, reading = &c.revert)
}

@(private = "file")
revert_cancel :: proc(app: ^App) {
	c := &app.cx.changes
	s, staged := c.state.(Changes_Staged)
	if !staged { return }
	delete(s.message); delete(s.prompt)
	c.state = Changes_Cancelling{session = s.session}
	changes_files_clear(c)
	revert_leaving(app, s.session)
	remote.begin(&c.revert)
	request(app, .Revert_Cancelled, "DELETE", fmt.tprintf("/api/session/%s/revert", s.session), "", s.session, reading = &c.revert)
}

// The conversation without what came after; the prompt back in the composer, unless something is being written there.
revert_done :: proc(app: ^App) {
	c := &app.cx.changes
	s, committing := c.state.(Changes_Committing)
	if !committing { return }
	if s.session == app.chat.id {
		load_messages(app, s.session)
		if s.prompt != "" && strings.trim_space(ui.text_edit_string(&app.composer.area)) == "" {
			ui.text_edit_set(&app.composer.area, s.prompt)
			app.composer.focus_next = true
		}
	}
	changes_reset(c)
	refresh_soon(app)
	ui.announce(&app.announcer, .Good, i18n.tr("Back to this prompt"))
}

revert_cancelled :: proc(app: ^App) { changes_reset(&app.cx.changes) }

// A stage, a commit or a cancel failed: whether the server is staged is not known here, so its description is read, and if it is, the
// dialog comes back rather than leaving it unsaid. (Of a session not shown: opening it reads that.)
revert_failed :: proc(app: ^App, id: string) {
	c := &app.cx.changes
	changes_reset(c)
	c.gone_seq = 0
	if id == app.chat.id { request(app, .Self, "GET", strings.concatenate({"/api/session/", id}, context.temp_allocator), tag = id) }
}

// Elsewhere (another client, or this one's own, whose answer then ends the state).
revert_gone :: proc(app: ^App, id: string) {
	c := &app.cx.changes
	if id == app.chat.id { c.gone_seq = app.cx.stream_seq }
	if s, staged := c.state.(Changes_Staged); staged && s.session == id { changes_reset(c) }
}

// The server is left, and `app.conn` is still it (server_connect): a stage on screen is closed as any other way of closing it would. One
// on its way is answer_left's. Nothing stays that could reach the next server with this one's ids.
changes_forget :: proc(app: ^App) {
	c := &app.cx.changes
	revert_cancel(app)
	changes_reset(c)
	c.gone_seq = 0
}

// What the head of the dialog says, by what is shown.
changes_say :: proc(c: ^Changes) -> string {
	add, del := 0, 0
	for f in c.files { add += f.additions; del += f.deletions }
	count := fmt.tprintf(i18n.tr(len(c.files), "%d file  +%d  -%d", "%d files  +%d  -%d"), len(c.files), add, del)
	#partial switch s in c.state {
	case Changes_Staging: return i18n.tr("Reading…")
	case Changes_Staged:
		lead := s.found ? i18n.tr("This session was left going back. ") : ""
		if s.no_snapshot { return fmt.tprintf(i18n.tr("%sThis folder keeps no snapshots: the files stay as they are, only the conversation goes back."), lead) }
		if len(c.files) == 0 { return fmt.tprintf(i18n.tr("%sNo file to restore: only the conversation goes back."), lead) }
		return fmt.tprintf(i18n.tr("%s%s, written back on disk already. Go back keeps it so and drops what came after this prompt; Cancel puts the files back."), lead, count)
	case Changes_Viewing:
		if len(c.files) == 0 { return i18n.tr("No change recorded. Only a git folder keeps them.") }
		if s.step == .Last_Turn { return fmt.tprintf(i18n.tr("%s, in the last turn only: this session changed folder, it cannot be compared as a whole."), count) }
	}
	return count
}

changes_dialog :: proc(app: ^App, em: f32) {
	c := &app.cx.changes
	if !changes_shown(c) { return }
	open := true
	changes_modal(app, &open, em)
	if !open { changes_close(app) }
}

@(private = "file")
changes_modal :: proc(app: ^App, open: ^bool, em: f32) {
	c := &app.cx.changes
	v, viewing := c.state.(Changes_Viewing)
	_, staging := c.state.(Changes_Staging)
	if ui.modal("changes", open, dialog_options(app, .Changes)) {
		dialog_backdrop()
		if ui.dialog_header("ch_head", !viewing ? i18n.tr("Go back to this prompt") : v.from != "" ? i18n.tr("What this prompt changed") : i18n.tr("What this session changed"), {close = true}) {}
		// (under the header, as wide as the dialog: the corner is the close cross's only beside the header)
		ui.next({width = ui.fill(), height = ui.children_sum(), axis = .X})
		if ui.row(id = "###ch_sub") {
			ui.spacer(ui.px(em * DIALOG_MARGIN_EM))
			ui.next({width = ui.fill(), height = ui.children_sum(), axis = .Y})
			if ui.column() {
				if !viewing || read_shown(app, "###ch_read", &c.read, em, changes_read) { info_line(app, "###ch_say", changes_say(c), em) }
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
							glyph(f.open ? lucide.CHEVRON_DOWN : lucide.CHEVRON_RIGHT, hex(HEX_FAINT), math.round(em * ICON_SMALL))
							ui.spacer(ui.px(em * 0.3))
							text("n", f.file, hex(HEX_TEXT), ui.Style_Mod{font = app.mono, font_size = math.round(em * FS_SMALL)}, ui.fill())
							if f.status != "" && f.status != "modified" {
								text("s", f.status, hex(HEX_FAINT), ui.Style_Mod{font_size = math.round(em * FS_CAPTION)})
								ui.spacer(ui.px(em * 0.6))
							}
							if f.patch != "" {
								ui.next({width = ui.text_size(0), height = ui.px(em * 1.4), font_size = math.round(em * FS_CAPTION), fg = hex(HEX_FAINT), cursor = .Hand, text_pad = 0})
								full := ui.build_box({.Clickable, .Draw_Text}, fmt.tprintf("%s###ff", i18n.tr("Full view")))
								if ui.signal(full).clicked { diff_full_open(app, f.file, f.patch); f.open = !f.open }   // (the head's click is undone: this one was not for it)
								ui.spacer(ui.px(em * 0.8))
							}
							text("a", fmt.tprintf("+%d", f.additions), hex(HEX_GREEN), ui.Style_Mod{font = app.mono, font_size = math.round(em * FS_CAPTION)})
							ui.spacer(ui.px(em * 0.4))
							text("d", fmt.tprintf("-%d", f.deletions), hex(HEX_RED), ui.Style_Mod{font = app.mono, font_size = math.round(em * FS_CAPTION)})
						}
						if f.open {
							diff_view(app, "###fd", f.diff, f.patch, em, CHANGES_DIFF_LINES, f.file)
							if f.more { text("m", i18n.tr("The server gave only the beginning of this file."), hex(HEX_FAINT), ui.Style_Mod{font_size = math.round(em * FS_CAPTION), height = ui.px(em * 1.5)}, ui.fill()) }
						}
						ui.spacer(ui.px(em * 0.4))
					}
					ui.spacer(ui.px(em * DIALOG_MARGIN_EM))
				}
			}
		}
		if !viewing {
			ui.spacer(ui.px(em * 0.5))
			ui.next({width = ui.fill(), height = ui.children_sum(), axis = .X, cross = .Center})
			if ui.row(.Center, id = "###ch_foot") {
				ui.spacer(ui.fill())
				if ui.button("ch_cancel", i18n.tr("Cancel")).clicked { open^ = false }
				ui.spacer(ui.px(em * 0.5))
				if ui.button("ch_go", i18n.tr("Go back"), lucide.UNDO_2, {intent = .Danger, disabled = staging}).clicked { revert_commit(app) }
				ui.spacer(ui.px(em * DIALOG_MARGIN_EM))
			}
		}
		ui.spacer(ui.px(em * 0.8))
	}
}

////////////////////////////////
// What the answers to its requests do (net.odin REQ_FACTS)

session_moved_on_ok :: proc(app: ^App, r: ^Request, v: json.Value) {
	ui.announce(&app.announcer, .Good, i18n.tr("Session moved"))
	refresh_soon(app)
}

session_export_on_ok :: proc(app: ^App, r: ^Request, v: json.Value) { session_export_save(app, r.tag, r.resp) }

session_import_on_ok :: proc(app: ^App, r: ^Request, v: json.Value) {
	refresh_soon(app)
	// (the reader who went elsewhere meanwhile stays there: it is in the sidebar)
	if id := jstr(v, "data", "id"); id != "" && r.gen == app.chat.gen { open_root(app, id) }
	ui.announce(&app.announcer, .Good, i18n.tr("Session imported"))
}

session_import_on_fail :: proc(app: ^App, r: ^Request, f: Failure, message: string) -> (told: bool) {
	if r.status == 409 { session_import_conflict(app, r.tag); return true }
	return false
}

changes_range_on_ok :: proc(app: ^App, r: ^Request, v: json.Value) { changes_range(app, v) }

changes_on_ok :: proc(app: ^App, r: ^Request, v: json.Value) { changes_load(app, v) }

changes_on_fail :: proc(app: ^App, r: ^Request, f: Failure, message: string) -> (told: bool) {
	if r.status == 400 { changes_refused(app) }
	return true
}

revert_staged_on_ok :: proc(app: ^App, r: ^Request, v: json.Value) { revert_staged(app, v) }

// A stage has written the files back: nobody waits for it any more, so they are put back as they were, on the server it went to.
revert_staged_on_left :: proc(app: ^App, r: ^Request) {
	if !r.ok || r.status >= 400 { return }
	request(app, .Action, "DELETE", fmt.tprintf("/api/session/%s/revert", r.tag), tag = r.tag, conn = r.conn)
}

revert_done_on_ok :: proc(app: ^App, r: ^Request, v: json.Value) { revert_done(app) }

revert_cancelled_on_ok :: proc(app: ^App, r: ^Request, v: json.Value) { revert_cancelled(app) }

revert_on_fail :: proc(app: ^App, r: ^Request, f: Failure, message: string) -> (told: bool) {
	revert_failed(app, r.tag)
	return false
}
