// The menus of a right click: on a message, a tool call, a link's message, the composer, a session. A right press is looked
// at where each thing is built, the innermost first (the first to take it keeps it); the menu is built once, at the end of the
// build, for what was noted.
package occ

import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:strings"
import "gt:ui"

Ctx_Kind :: enum u8 { None, Message, Tool, Composer }

Ctx_Target :: struct {
	kind:   Ctx_Kind,
	msg:    string,     // the message (owned)
	part:   int,        // its tool call
}

// A right press in `b` opens the menu of `kind`, unless something over it or inside it took the press.
ctx_check :: proc(app: ^App, b: ^ui.Box, kind: Ctx_Kind, msg := "", part := 0) {
	if app.cx.ctx_taken || !ui.mouse_pressed(.Right) || b == nil || overlay_open(app) { return }
	if !rect_contains(b.rect, ui.mouse_pos()) { return }
	app.cx.ctx_taken = true
	delete(app.cx.ctx.msg)
	app.cx.ctx = {kind = kind, msg = strings.clone(msg), part = part}
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

fork_session :: proc(app: ^App, id, before: string) {
	body := before != "" ? fmt.tprintf(`{{"before":%s}}`, jquote(before)) : "{}"
	request(app, .Forked, "POST", fmt.tprintf("/api/session/%s/fork", id), body, id)
}

@(private = "file")
copied :: proc(s: string, what: string) {
	clip_set(s)
	ui.toast(.Good, "%s copied", what)
}

@(private = "file")
input_field :: proc(p: ^Part, key: string) -> string {
	v, err := json.parse_string(p.input, allocator = context.temp_allocator)
	return err == nil ? jstr(v, key) : ""
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
	a := &app.composer
	lo, hi := min(a.cursor, a.mark), max(a.cursor, a.mark)
	if ui.menu_item("Undo", "Ctrl+Z", enabled = len(a.undo) > 0).clicked { ui.area_undo(a) }
	if ui.menu_item("Redo", "Ctrl+Y", enabled = len(a.redo) > 0).clicked { ui.area_redo(a) }
	ui.menu_separator()
	if ui.menu_item("Cut", "Ctrl+X", enabled = hi > lo).clicked {
		clip_set(string(a.buf[lo:hi]))
		area_insert(a, "")
	}
	if ui.menu_item("Copy", "Ctrl+C", enabled = hi > lo).clicked { clip_set(string(a.buf[lo:hi])) }
	if ui.menu_item("Paste", "Ctrl+V").clicked {
		if !attach_paste(app) { area_insert(a, clip_get()) }
		app.cx.focus_composer = true
	}
	ui.menu_separator()
	if ui.menu_item("Select all", "Ctrl+A", enabled = len(a.buf) > 0).clicked {
		a.mark, a.cursor = 0, len(a.buf)
		app.cx.focus_composer = true
	}
}

@(private = "file")
message_menu :: proc(app: ^App, m: ^Message) {
	if ui.has_selection(&app.ui_state) {
		sel := ui.selected_text(&app.ui_state, context.temp_allocator)
		if ui.menu_item("Quote", "").clicked { quote_text(app, sel, false) }
		if ui.menu_item("Quote with a comment", "Ctrl+Q").clicked { quote_text(app, sel, true) }
		if ui.menu_item("Copy the selection", "Ctrl+C").clicked { copied(sel, "Selection") }
		ui.menu_separator()
	}
	switch m.kind {
	case .User:
		if ui.menu_item("Copy", "", icon = ICO_COPY).clicked { copied(m.text, "Prompt") }
		if ui.menu_item("Edit in the composer", icon = ICO_EDIT).clicked {
			ui.area_set(&app.composer, m.text)
			app.cx.focus_composer = true
		}
		ui.menu_separator()
		if ui.menu_item("Fork from here", icon = ICO_COPY).clicked { fork_session(app, app.chat.id, m.id) }
	case .Assistant:
		t := answer_text(m)
		if ui.menu_item("Copy the answer", icon = ICO_COPY, enabled = t != "").clicked { copied(t, "Answer") }
		if url := first_url(t); url != "" {
			if ui.menu_item("Open the link", icon = ICO_GLOBE).clicked { preview_open(app, url) }
		}
		ui.menu_separator()
		if ui.menu_item("Fork from here", icon = ICO_COPY).clicked { fork_session(app, app.chat.id, m.id) }
	case .Synthetic, .Shell, .Compaction, .Idle, .Other:
		if ui.menu_item("Copy", icon = ICO_COPY, enabled = m.text != "").clicked { copied(m.text, "Text") }
	}
}

@(private = "file")
tool_menu :: proc(app: ^App, p: ^Part) {
	if ui.menu_item("Copy the output", icon = ICO_COPY, enabled = p.output != "").clicked { copied(p.output, "Output") }
	if p.patch != "" { if ui.menu_item("Copy the diff", icon = ICO_COPY).clicked { copied(p.patch, "Diff") } }
	if c := input_field(p, "command"); c != "" {
		if ui.menu_item("Copy the command", icon = ICO_TERMINAL).clicked { copied(c, "Command") }
	}
	path := input_field(p, "filePath")
	if path == "" { path = input_field(p, "path") }
	if path != "" {
		if ui.menu_item("Copy the path", icon = ICO_DOC).clicked { copied(path, "Path") }
		if ui.menu_item("Show in the folder", icon = ICO_FOLDER).clicked { reveal_path(path) }
	}
	if ui.menu_item("Copy the input", enabled = p.input != "").clicked { copied(p.input, "Input") }
	if url := first_url(p.output); url != "" {
		ui.menu_separator()
		if ui.menu_item("Open the link", icon = ICO_GLOBE).clicked { preview_open(app, url) }
	}
}

// At the end of the build, for what a right press noted.
context_menu :: proc(app: ^App, em: f32) {
	app.cx.ctx_taken = false
	quote_chip(app, em)
	if ui.ctx_menu(ui.key_from_string(0, CTX_MENU_KEY)) {
		switch app.cx.ctx.kind {
		case .None:
		case .Composer: composer_menu(app)
		case .Message:
			if m := find_msg(app, app.cx.ctx.msg); m != nil { message_menu(app, m) }
		case .Tool:
			if m := find_msg(app, app.cx.ctx.msg); m != nil && app.cx.ctx.part < len(m.parts) { tool_menu(app, &m.parts[app.cx.ctx.part]) }
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
	had := strings.trim_space(ui.area_string(&app.composer))
	if had != "" { fmt.sbprintf(&b, "%s\n\n", had) }
	rest := t
	for line in strings.split_lines_iterator(&rest) { fmt.sbprintf(&b, "> %s\n", strings.trim_right_space(line)) }
	strings.write_byte(&b, '\n')
	ui.area_set(&app.composer, strings.to_string(b))
	if comment { app.cx.focus_composer = true } else { ui.toast(.Good, "Quoted in the composer") }
}

quote_selection :: proc(app: ^App) {
	quote_text(app, ui.selected_text(&app.ui_state, context.temp_allocator), true)
}

// Where a selection ends: what can be done with it, at hand. The press on it may take the selection away: the text was kept.
quote_chip :: proc(app: ^App, em: f32) {
	s := &app.ui_state
	cx := &app.cx
	id := "###quote_chip"
	on_chip := false
	if r, ok := ui.popover_rect(id); ok && cx.quote_open { on_chip = rect_contains(r, ui.mouse_pos()) }
	if !on_chip {
		if !ui.has_selection(s) || overlay_open(app) || ui.active_key() != 0 { cx.quote_open = false; return }
		serial := ui.selection_serial(s)
		if serial == cx.quote_done { return }
		if serial != cx.quote_serial || !cx.quote_open {
			cx.quote_serial = serial
			cx.quote_open = true
			delete(cx.quote_kept)
			cx.quote_kept = ui.selected_text(s)
			p := ui.mouse_pos()
			cx.quote_at = {p, p + 1}
		}
	}
	if !cx.quote_open { return }
	if ui.popover(id, cx.quote_at, math.round(em * QUOTE_CHIP_W_EM), .Above, align_right = false) {
		ui.next({width = ui.fill(), height = ui.px(math.round(em * 2.3)), axis = .X, cross = .Center})
		if ui.row(.Center, id = "###qr") {
			ui.spacer(ui.px(em * 0.35))
			quoted := bevel_button("###q1", "Quote", "", .Ghost, ui.fill(), math.round(em * BUTTON_SMALL_H_EM)).clicked
			commented := bevel_button("###q2", "Comment", "", .Ghost, ui.fill(), math.round(em * BUTTON_SMALL_H_EM)).clicked
			ui.spacer(ui.px(em * 0.35))
			if quoted || commented {
				quote_text(app, cx.quote_kept, commented)
				cx.quote_done = cx.quote_serial
				cx.quote_open = false
			}
		}
	}
}

////////////////////////////////
// Rename

Rename :: struct {
	open:  bool,
	fresh: bool,
	id:    string,   // (owned)
	field: ui.Text_Field,
}

rename_open :: proc(app: ^App, id: string) {
	r := &app.rename
	delete(r.id)
	r.id = strings.clone(id)
	r.open, r.fresh = true, true
	s := find_session(app, id)
	ui.field_set(&r.field, s != nil ? s.title : "")
	ui.field_select_all(&r.field)
}

rename_dialog :: proc(app: ^App, em: f32) {
	r := &app.rename
	if ui.modal("rename", em * 28, &r.open) {
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
						if res.cancelled { r.open = false }
					}
				}
				ui.spacer(ui.px(em * 0.9))
				ui.next({width = ui.fill(), height = ui.children_sum(), axis = .X, cross = .Center})
				if ui.row(.Center, id = "###ren_b") {
					ui.spacer(ui.fill())
					if bevel_button("###c", "Cancel", "", .Normal).clicked { r.open = false }
					ui.spacer(ui.px(em * 0.5))
					if bevel_button("###ok", "Rename", ICO_CHECK, .Accent).clicked { rename_commit(app) }
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
	r.open = false
	if t == "" { return }
	rename_session(app, r.id, t)
	app.refresh_due = true
}
