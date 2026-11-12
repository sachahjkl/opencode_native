// The menus of a right click: on a message, a tool call, a link's message, the composer, a session. A right press is looked
// at where each thing is built, the innermost first (the first to take it keeps it); the menu is built once, at the end of the
// build, for what was noted.
package ocn

import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:strings"
import "gt:ui"
import lucide "gt:lucide"

Ctx_Kind :: enum u8 { None, Message, Tool, Composer, Image, Diagram, Folder }

Ctx_Target :: struct {
	kind:   Ctx_Kind,
	msg:    string,     // the message; a diagram's text; a folder's path (owned)
	part:   int,        // its tool call
	image:  Image_Ref,  // the image (owned: the message that holds it can be read again before the menu is used)
}

// The menu of a right click: what it is about, and whether this build's right press found it.
Ctx_Menu :: struct {
	target: Ctx_Target,
	taken:  bool,   // a right press of this build found its target
}

// The chip at the end of a selection (quote_chip).
Quote_Chip :: struct {
	open:         bool,
	at:           Rect,
	kept:         string,   // what it quotes (owned)
	serial, done: u64,      // which selection, and the last one quoted
}

// A right press on `b` opens the menu of `kind`: on it with nothing drawn over it there (ui.pointer_on: the composer over the
// last message, which the conversation scrolls under it, has the press), and nothing in it took the press first (it is checked
// after what is in it: the innermost keeps it).
ctx_check :: proc(app: ^App, b: ^ui.Box, kind: Ctx_Kind, msg := "", part := 0, image := Image_Ref{}) {
	if app.ctx_menu.taken || !ui.mouse_pressed(.Right) || b == nil || overlay_open(app) { return }
	if !ui.pointer_on(b) { return }
	ctx_open(app, kind, msg, part, image)
}

// The menu of `kind`, where the pointer is (a dialog opens its own: ctx_check leaves what is under a dialog alone).
ctx_open :: proc(app: ^App, kind: Ctx_Kind, msg := "", part := 0, image := Image_Ref{}) {
	app.ctx_menu.taken = true
	delete(app.ctx_menu.target.msg)
	image_ref_delete(&app.ctx_menu.target.image)
	app.ctx_menu.target = {kind = kind, msg = strings.clone(msg), part = part, image = image_ref_clone(image)}
	ui.ctx_menu_open(ui.key_from_string(0, CTX_MENU_KEY), ui.mouse_pos())
}

@(private = "file")
find_msg :: proc(app: ^App, id: string) -> ^Message {
	for &m in app.chat.messages { if m.id == id { return &m } }
	return nil
}

// All that an answer says, without its tools.
@(private = "file")
answer_text :: proc(m: ^Message) -> string {
	b := strings.builder_make(context.temp_allocator)
	for &p in m.parts {
		if p.kind != .Text || len(p.text) == 0 { continue }
		if strings.builder_len(b) > 0 { strings.write_string(&b, "\n\n") }
		strings.write_string(&b, string(p.text[:]))
	}
	return strings.to_string(b)
}

// A new session with the history of `id` before the message `before` ("": all of it). `prompt`: what the composer takes back in it.
fork_session :: proc(app: ^App, id, before: string, prompt := "") {
	delete(app.composer.fork_prompt)
	app.composer.fork_prompt = strings.clone(prompt)
	body := before != "" ? fmt.tprintf(`{{"before":%s}}`, jquote(before)) : "{}"
	request(app, .Forked, "POST", fmt.tprintf("/api/session/%s/fork", id), body, id)
}

// The message a fork from `m` stops before, "" for all there is: the server copies what comes before a message, `m` not included. A
// message read stays, so what stops it is the next one. An answer still being written has no end to keep: it stays out, with what it
// said so far. A prompt stays out too: going on from it means sending it again, or something else (fork_from).
fork_before :: proc(c: ^Chat, m: ^Message) -> string {
	if m.kind == .User || m.streaming { return m.id }
	past := false
	for &x in c.messages {
		if past && x.id != "" { return x.id }
		if x.id == m.id { past = true }
	}
	return ""
}

// "Fork from here", on the session shown, a sub-agent's as any other: the server makes a session of its own of it, parent of nothing.
@(private = "file")
fork_from :: proc(app: ^App, m: ^Message) {
	fork_session(app, app.chat.id, fork_before(&app.chat, m), m.kind == .User ? m.text : "")
}

@(private = "file")
fork_item :: proc(app: ^App, m: ^Message) {
	if ui.menu_item(m.streaming ? "Fork before this answer" : "Fork from here", icon = lucide.COPY).clicked { fork_from(app, m) }
}

@(private = "file")
copied :: proc(s: string, what: string) {
	clip_set(s)
	ui.toast(.Good, "%s copied", what)
}

// The first address a text holds, http or https.
first_url :: proc(s: string) -> string {
	i := strings.index(s, "http://")
	if j := strings.index(s, "https://"); j >= 0 && (i < 0 || j < i) { i = j }
	if i < 0 { return "" }
	end := i
	for end < len(s) && !strings.contains_rune(" \t\r\n\"'<>)]}`", rune(s[end])) { end += 1 }
	return s[i:end]
}

@(private = "file")
composer_menu :: proc(app: ^App) {
	a := &app.composer.area
	lo, hi := min(a.cursor, a.mark), max(a.cursor, a.mark)
	if ui.menu_item("Undo", "Ctrl+Z", icon = lucide.UNDO_2, enabled = len(a.undo) > 0).clicked { ui.area_undo(a) }
	if ui.menu_item("Redo", "Ctrl+Y", icon = lucide.REDO_2, enabled = len(a.redo) > 0).clicked { ui.area_redo(a) }
	ui.menu_separator()
	if ui.menu_item("Cut", "Ctrl+X", icon = lucide.SCISSORS, enabled = hi > lo).clicked {
		clip_set(string(a.buf[lo:hi]))
		area_insert(a, "")
	}
	if ui.menu_item("Copy", "Ctrl+C", icon = lucide.COPY, enabled = hi > lo).clicked { clip_set(string(a.buf[lo:hi])) }
	if ui.menu_item("Paste", "Ctrl+V", icon = lucide.CLIPBOARD_PASTE).clicked {
		composer_paste(app)
		app.composer.focus_next = true
	}
	ui.menu_separator()
	if ui.menu_item("Select all", "Ctrl+A", icon = lucide.TEXT_CURSOR_INPUT, enabled = len(a.buf) > 0).clicked {
		a.mark, a.cursor = 0, len(a.buf)
		app.composer.focus_next = true
	}
}

@(private = "file")
message_menu :: proc(app: ^App, m: ^Message) {
	if ui.has_selection(&app.state) {
		sel := ui.selected_text(&app.state, context.temp_allocator)
		if ui.menu_item("Quote", "", icon = lucide.QUOTE).clicked { quote_text(app, sel, false) }
		if ui.menu_item("Quote with a comment", "Ctrl+Q", icon = lucide.MESSAGE_SQUARE_QUOTE).clicked { quote_text(app, sel, true) }
		if ui.menu_item("Copy the selection", "Ctrl+C", icon = lucide.COPY).clicked { copied(sel, "Selection") }
		ui.menu_separator()
	}
	switch m.kind {
	case .User:
		if ui.menu_item("Copy", "", icon = lucide.COPY).clicked { copied(m.text, "Prompt") }
		if ui.menu_item("Edit in the composer", icon = lucide.PENCIL).clicked {
			ui.area_set(&app.composer.area, m.text)
			app.composer.focus_next = true
		}
		ui.menu_separator()
		fork_item(app, m)
		if ui.menu_item("What this prompt changed", icon = lucide.FILE).clicked { changes_open(app, app.chat.id, m.id) }
		if ui.menu_item("Go back to here…", icon = lucide.UNDO_2, enabled = !app.chat.busy).clicked { revert_stage(app, app.chat.id, m.id, m.text) }
	case .Assistant:
		t := answer_text(m)
		if ui.menu_item("Copy the answer", icon = lucide.COPY, enabled = t != "").clicked { copied(t, "Answer") }
		if url := first_url(t); url != "" {
			if ui.menu_item("Open the link", icon = lucide.GLOBE).clicked { preview_open(app, url) }
		}
		ui.menu_separator()
		fork_item(app, m)
	case .Synthetic, .Shell:
		if ui.menu_item("Copy", icon = lucide.COPY, enabled = m.text != "").clicked { copied(m.text, "Text") }
		if m.shell_id != "" { if ui.menu_item("Inspect the output", icon = lucide.SQUARE_TERMINAL).clicked { output_view_open_shell(app, m.shell_id, m.text, chat_dir(app)) } }
		ui.menu_separator()
		fork_item(app, m)
	case .Compaction, .Idle, .Switch, .Other:
		if ui.menu_item("Copy", icon = lucide.COPY, enabled = m.text != "").clicked { copied(m.text, "Text") }
	}
}

// (`m` holds the call: most of an answer at work is its tool calls, and a press on one comes here.)
@(private = "file")
tool_menu :: proc(app: ^App, m: ^Message, p: ^Part) {
	if ui.menu_item("Copy the output", icon = lucide.COPY, enabled = p.output != "").clicked { copied(p.output, "Output") }
	if p.patch != "" { if ui.menu_item("Copy the diff", icon = lucide.COPY).clicked { copied(p.patch, "Diff") } }
	if c := p.command; c != "" {
		if ui.menu_item("Copy the command", icon = lucide.SQUARE_TERMINAL).clicked { copied(c, "Command") }
	}
	if tool_kind(p.tool_name) == .Shell && output_view_can(p) {
		if ui.menu_item("Inspect the output", icon = lucide.SQUARE_TERMINAL).clicked { output_view_open_part(app, p) }
	}
	if path := p.file_path; path != "" {
		if ui.menu_item("Copy the path", icon = lucide.FILE).clicked { copied(path, "Path") }
		if ui.menu_item("Show in the folder", icon = lucide.FOLDER).clicked { reveal_path(path) }
	}
	if ui.menu_item("Copy the input", icon = lucide.COPY, enabled = p.input != "").clicked { copied(p.input, "Input") }
	if url := first_url(p.output); url != "" {
		ui.menu_separator()
		if ui.menu_item("Open the link", icon = lucide.GLOBE).clicked { preview_open(app, url) }
	}
	ui.menu_separator()
	fork_item(app, m)
}

// At the end of the build, for what a right press noted.
context_menu :: proc(app: ^App, em: f32) {
	app.ctx_menu.taken = false
	quote_chip(app, em)
	if ui.ctx_menu(ui.key_from_string(0, CTX_MENU_KEY)) {
		switch app.ctx_menu.target.kind {
		case .None:
		case .Composer: composer_menu(app)
		case .Message:
			if m := find_msg(app, app.ctx_menu.target.msg); m != nil { message_menu(app, m) }
		case .Tool:
			if m := find_msg(app, app.ctx_menu.target.msg); m != nil && app.ctx_menu.target.part < len(m.parts) { tool_menu(app, m, &m.parts[app.ctx_menu.target.part]) }
		case .Image:
			image := app.ctx_menu.target.image
			if ui.menu_item("Copy image", app.cx.open[.Viewer] ? "Ctrl+C" : "", icon = lucide.COPY).clicked { image_copy(app, image) }
			if !app.cx.open[.Viewer] {
				if ui.menu_item("Open in the viewer", icon = lucide.ZOOM_IN).clicked { image_view_open(app, image) }
			}
		case .Folder:
			if ui.menu_item("Copy the path", icon = lucide.COPY).clicked { clip_set(app.ctx_menu.target.msg); ui.toast(.Good, "Copied") }
		case .Diagram:
			code := app.ctx_menu.target.msg
			if ui.menu_item("Copy as PNG", app.cx.open[.Viewer] ? "Ctrl+C" : "", icon = lucide.IMAGE).clicked { diagram_copy_png(app, code) }
			if ui.menu_item("Copy the text", icon = lucide.COPY).clicked { clip_set(code); ui.toast(.Good, "Copied") }
			if !app.cx.open[.Viewer] {
				if ui.menu_item("Open in the viewer", icon = lucide.ZOOM_IN).clicked { diagram_view_open(app, code) }
			}
		}
	}
}

////////////////////////////////
// Quoting what is selected

// `text` as a quote at the end of the composer, a line left under it for what one has to say about it. `comment`: the
// keyboard goes there.
quote_text :: proc(app: ^App, text: string, comment: bool) {
	t := strings.trim_space(text)
	if t == "" { return }
	b := strings.builder_make(context.temp_allocator)
	had := strings.trim_space(ui.area_string(&app.composer.area))
	if had != "" { fmt.sbprintf(&b, "%s\n\n", had) }
	rest := t
	for line in strings.split_lines_iterator(&rest) { fmt.sbprintf(&b, "> %s\n", strings.trim_right_space(line)) }
	strings.write_byte(&b, '\n')
	ui.area_set(&app.composer.area, strings.to_string(b))
	if comment { app.composer.focus_next = true } else { ui.toast(.Good, "Quoted in the composer") }
}

quote_selection :: proc(app: ^App) {
	quote_text(app, ui.selected_text(&app.state, context.temp_allocator), true)
}

// The chip of selection `serial`: a new one goes where the pointer ended it (true). One that comes back, a dialog that hid it closed,
// stays where it was: the pointer is wherever that dialog left it.
quote_place :: proc(q: ^Quote_Chip, serial: u64, pointer: Vec2) -> (new_selection: bool) {
	q.open = true
	if serial == q.serial { return false }
	q.serial = serial
	q.at = {pointer, pointer + 1}
	return true
}

// Where a selection ends: what can be done with it, at hand. The press on it may take the selection away: the text was kept.
quote_chip :: proc(app: ^App, em: f32) {
	s := &app.state
	q := &app.quote
	id := "###quote_chip"
	on_chip := false
	if r, ok := ui.popover_rect(id); ok && q.open { on_chip = rect_contains(r, ui.mouse_pos()) }
	if !on_chip {
		if !ui.has_selection(s) || overlay_open(app) || ui.active_key() != 0 { q.open = false; return }
		serial := ui.selection_serial(s)
		if serial == q.done { return }
		if quote_place(q, serial, ui.mouse_pos()) {
			delete(q.kept)
			q.kept = ui.selected_text(s)
		}
	}
	if !q.open { return }
	if ui.popover(id, q.at, math.round(em * QUOTE_CHIP_W_EM), .Above, align_right = false) {
		ui.next({width = ui.fill(), height = ui.px(math.round(em * 2.3)), axis = .X, cross = .Center})
		if ui.row(.Center, id = "###qr") {
			ui.spacer(ui.px(em * 0.35))
			quoted := bevel_button("###q1", "Quote", "", .Ghost, ui.fill(), math.round(em * BUTTON_SMALL_H_EM)).clicked
			commented := bevel_button("###q2", "Comment", "", .Ghost, ui.fill(), math.round(em * BUTTON_SMALL_H_EM)).clicked
			ui.spacer(ui.px(em * 0.35))
			if quoted || commented {
				quote_text(app, q.kept, commented)
				q.done = q.serial
				q.open = false
			}
		}
	}
}

////////////////////////////////
// Rename

Rename :: struct {
	at:    Rename_At,   // in place, where the title is (a double click on it); or the dialog (Dialog.Rename)
	fresh: bool,
	held:  bool,        // in place: the field had the keyboard (losing it commits, as a click elsewhere)
	shown: bool,        // in place: its field was built in this build (or it began in it)
	id:    string,      // (owned)
	field: ui.Text_Field,
}

Rename_At :: enum u8 { None, Header, Side }

rename_open :: proc(app: ^App, id: string) {
	r := &app.rename
	delete(r.id)
	r.id = strings.clone(id)
	app.cx.open[.Rename], r.fresh, r.at = true, true, .None
	s := find_session(app, id)
	if s == nil && app.chat.have_self && app.chat.self.id == id { s = &app.chat.self }
	ui.field_set(&r.field, s != nil ? s.title : "")
	ui.field_select_all(&r.field)
}

// The title of session `id`, edited where it is shown (`at`): Enter or a click elsewhere keeps it, Escape leaves it as it was.
rename_inline :: proc(app: ^App, id: string, at: Rename_At) {
	rename_open(app, id)
	app.cx.open[.Rename], app.rename.at, app.rename.held, app.rename.shown = false, at, false, true
}

// Whether session `id`'s title is being edited at `at`: then rename_in_place stands where its words would.
renaming_at :: proc(app: ^App, id: string, at: Rename_At) -> bool {
	return app.rename.at == at && app.rename.id == id
}

// The title's field, in place of its words: as tall, in their size, in a well that says it is a field. `fit`: as wide as its words
// and room to type (where the words had no more than theirs: beside others that take their own), else the whole place.
rename_in_place :: proc(app: ^App, em, font_size, height: f32, fit := false) {
	r := &app.rename
	r.shown = true
	pad := math.round(em * RENAME_PAD_EM)
	w := ui.fill()
	if fit { w = ui.px(math.round(ui.text_width(app.font, font_size, ui.field_string(&r.field)) + 2 * pad + em * RENAME_ROOM_EM), 0) }
	ui.next({width = w, height = ui.px(height), axis = .X, cross = .Center})
	if well("###ren_in", .X, radius = 5, focus = 1) {
		if ui.tags("bare") {
			ui.next({width = ui.fill(), height = ui.pct(1), font_size = font_size, text_pad = pad})
			res := ui.line_edit("###ren_f", &r.field, "Title")
			if r.fresh { ui.set_focus(res.box.key); r.fresh = false } else if res.focused { r.held = true }
			switch {
			case res.cancelled:          r.at = .None
			case res.committed:          rename_commit(app)
			case r.held && !res.focused: rename_commit(app)   // (a click elsewhere, Tab: as Enter)
			}
		}
	}
}

rename_dialog :: proc(app: ^App, em: f32) {
	r := &app.rename
	// (built after the sidebar and the conversation: a title edited in place that neither built - another session shown, its row
	// scrolled away - is left as it was)
	if r.at != .None && !r.shown { r.at = .None }
	r.shown = false
	if ui.modal("rename", em * 28, &app.cx.open[.Rename]) {
		dialog_backdrop()
		ui.spacer(ui.px(em))
		ui.next({width = ui.fill(), height = ui.children_sum(), axis = .X})
		if ui.row(id = "###ren") {
			ui.spacer(ui.px(em * 1.2))
			ui.next({width = ui.fill(), height = ui.children_sum(), axis = .Y})
			if ui.column() {
				text("t", "Rename the session", hex(HEX_BRIGHT), ui.Style_Mod{font_size = math.round(em * FS_TITLE), height = ui.px(em * 2)}, ui.fill())
				ui.spacer(ui.px(em * 0.4))
				ui.next({width = ui.fill(), height = ui.px(math.round(em * FIELD_H_EM)), axis = .X, cross = .Center})
				if well("###ren_w", .X, radius = 7, focus = 1) {
					if ui.tags("bare") {
						ui.next({width = ui.fill(), height = ui.pct(1), text_pad = em * 0.5})
						res := ui.line_edit("###ren_f", &r.field, "Title")
						if r.fresh { ui.set_focus(res.box.key); r.fresh = false }
						if res.committed { rename_commit(app) }
						if res.cancelled { app.cx.open[.Rename] = false }
					}
				}
				ui.spacer(ui.px(em * 0.9))
				ui.next({width = ui.fill(), height = ui.children_sum(), axis = .X, cross = .Center})
				if ui.row(.Center, id = "###ren_b") {
					ui.spacer(ui.fill())
					if bevel_button("###c", "Cancel", "", .Normal).clicked { app.cx.open[.Rename] = false }
					ui.spacer(ui.px(em * 0.5))
					if bevel_button("###ok", "Rename", lucide.CHECK, .Accent).clicked { rename_commit(app) }
				}
				ui.spacer(ui.px(em))
			}
			ui.spacer(ui.px(em * 1.2))
		}
	}
}

@(private = "file")
rename_commit :: proc(app: ^App) {
	r := &app.rename
	t := strings.trim_space(ui.field_string(&r.field))
	app.cx.open[.Rename], r.at = false, .None
	if t == "" { return }
	if s := find_session(app, r.id); s != nil && s.title == t { return }   // (nothing changed: nothing to ask)
	rename_session(app, r.id, t)
	refresh_soon(app)
}

////////////////////////////////
// What the answers to its requests do (net.odin REQ_FACTS)

forked_on_ok :: proc(app: ^App, r: ^Request, v: json.Value) {
	id := jstr(v, "data", "id")
	if id == "" { return }
	refresh_sessions(app)
	if r.gen == app.chat.gen {
		open_root(app, id)
		prompt_restore(app, app.composer.fork_prompt)
		if app.composer.fork_prompt != "" { app.composer.focus_next = true }
	}
	ui.toast(.Good, "Forked")
}
