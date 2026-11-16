// The menus of a right click: on a message, a tool call, a link's message, the composer, a session. A right press is taken
// where each thing is built, by the toolkit's rule (ui.context_take: the innermost first, one a build); the menu is built
// once, at the end of the build, for what was noted.
package ocn

import tk_json "gt:json"
import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:strings"
import "gt:draw"
import "gt:ui"
import lucide "gt:lucide"
import i18n "gt:i18n"

Ctx_Kind :: enum u8 { None, Message, Tool, Composer, Image, Diagram, Folder }

Ctx_Target :: struct {
	kind:   Ctx_Kind,
	msg:    string,     // the message; a diagram's text; a folder's path (owned)
	part:   int,        // its tool call
	image:  Image_Ref,  // the image (owned: the message that holds it can be read again before the menu is used)
	pane:   int,        // the slot of the pane it was opened in: its message, its composer (ctx_pane)
}

// The menu of a right click: what it is about (which block took the press: ui.context_take).
Ctx_Menu :: struct {
	target: Ctx_Target,
	// the window it opened in: a menu is its window's State's, and is built only there (window_overlays). Compared, never read:
	// that window may have closed since.
	window: ^ui.State,
}

// The chip at the end of a selection (quote_chip).
Quote_Chip :: struct {
	open:         bool,
	at:           Rect,
	kept:         string,   // what it quotes (owned)
	serial, done: u64,      // which selection, and the last one quoted (of `window`'s: each window counts its own)
	pane:         int,      // the slot of the pane under the pointer when the selection was made: its composer quotes it
	// the window it shows in: the last one pressed in (nil: the main window). Compared, never read.
	window:       ^ui.State,
}

// What each window builds last, over all it holds: the menu of a right click and the quote chip. The main window's build ends
// with it, and so does the build of a pane's view in a window of its own (src/md/features/chat-panes.md): what is opened in a
// window is built in that window.
window_overlays :: proc(app: ^App, em: f32) {
	context_menu(app, em)
}

// A right press on `b` opens the menu of `kind`: on it with nothing drawn over it there (ui.pointer_on: the composer over the
// last message, which the conversation scrolls under it, has the press), and nothing in it took the press first (it is checked
// after what is in it: the innermost keeps it). `pane`: the one it is built in (nil: the main view).
ctx_check :: proc(app: ^App, b: ^ui.Box, kind: Ctx_Kind, msg := "", part := 0, image := Image_Ref{}, pane: ^Chat_Pane = nil) {
	if b == nil || overlay_open(app) || !ui.context_take(b) { return }
	ctx_open(app, kind, msg, part, image, pane)
}

// The menu of `kind`, where the pointer is (a dialog opens its own: ctx_check leaves what is under a dialog alone).
ctx_open :: proc(app: ^App, kind: Ctx_Kind, msg := "", part := 0, image := Image_Ref{}, pane: ^Chat_Pane = nil) {
	delete(app.ctx_menu.target.msg)
	image_ref_delete(&app.ctx_menu.target.image)
	app.ctx_menu.target = {kind = kind, msg = strings.clone(msg), part = part, image = image_ref_clone(image), pane = pane_index(app, pane != nil ? pane : main_pane(app))}
	app.ctx_menu.window = built_state(app)
	ui.menu_open(CTX_MENU_KEY, ui.mouse_pos())
}

// The pane the menu was opened in; the main view when that pane closed since.
@(private = "file")
ctx_pane :: proc(app: ^App) -> ^Chat_Pane {
	i := app.ctx_menu.target.pane
	return pane_is_shown(app, i) ? &app.panes[i] : main_pane(app)
}

// The window the menu was opened in (none noted: the main one).
@(private = "file")
ctx_window :: proc(app: ^App) -> ^ui.State {
	return app.ctx_menu.window != nil ? app.ctx_menu.window : &app.state
}

@(private = "file")
find_msg :: proc(pane: ^Chat_Pane, id: string) -> ^Message {
	for &m in pane.chat.messages { if m.id == id { return &m } }
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
	pane := main_pane(app)
	delete(pane.composer.fork_prompt)
	pane.composer.fork_prompt = strings.clone(prompt)
	body := before != "" ? fmt.tprintf(`{{"before":%s}}`, tk_json.quote(before)) : "{}"
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

// "Fork from here", on the session `pane` shows, a sub-agent's as any other: the server makes a session of its own of it, parent of
// nothing. (It opens in the main view, whichever pane it came from.)
@(private = "file")
fork_from :: proc(app: ^App, pane: ^Chat_Pane, m: ^Message) {
	fork_session(app, pane.chat.id, fork_before(&pane.chat, m), m.kind == .User ? m.text : "")
}

@(private = "file")
fork_item :: proc(app: ^App, pane: ^Chat_Pane, m: ^Message) {
	if ui.menu_item(m.streaming ? i18n.tr("Fork before this answer") : i18n.tr("Fork from here"), icon = lucide.COPY).clicked { fork_from(app, pane, m) }
}

@(private = "file")
copied :: proc(s: string, said: string) {
	clip_set(s)
	ui.announce(&the_app.announcer, .Good, said)   // (the whole sentence: a language agrees its words with the thing)
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
message_menu :: proc(app: ^App, pane: ^Chat_Pane, m: ^Message) {
	// (the selection of the window the menu is built in: each window has its own)
	if s := built_state(app); ui.has_selection(s) {
		sel := ui.selected_text(s, context.temp_allocator)
		if ui.menu_item(i18n.tr("Quote"), "", icon = lucide.QUOTE).clicked { quote_text(app, pane, sel, false) }
		if ui.menu_item(i18n.tr("Quote with a comment"), command_shortcut(app, "session.quote"), icon = lucide.MESSAGE_SQUARE_QUOTE).clicked { quote_text(app, pane, sel, true) }
		if ui.menu_item(i18n.tr("Copy the selection"), "Ctrl+C", icon = lucide.COPY).clicked { copied(sel, i18n.tr("Selection copied")) }
		ui.menu_separator()
	}
	switch m.kind {
	case .User:
		if ui.menu_item(i18n.tr("Copy"), "", icon = lucide.COPY).clicked { copied(m.text, i18n.tr("Prompt copied")) }
		if ui.menu_item(i18n.tr("Edit in the composer"), icon = lucide.PENCIL).clicked {
			ui.text_edit_set(&pane.composer.area, m.text)
			pane.composer.focus_next = true
		}
		ui.menu_separator()
		fork_item(app, pane, m)
		if ui.menu_item(i18n.tr("What this prompt changed"), icon = lucide.FILE).clicked { changes_open(app, pane.chat.id, m.id) }
		if ui.menu_item(i18n.tr("Go back to here…"), icon = lucide.UNDO_2, disabled = pane.chat.busy).clicked { revert_stage(app, pane.chat.id, m.id, m.text) }
	case .Assistant:
		t := answer_text(m)
		if ui.menu_item(i18n.tr("Copy the answer"), icon = lucide.COPY, disabled = t == "").clicked { copied(t, i18n.tr("Answer copied")) }
		if url := first_url(t); url != "" {
			if ui.menu_item(i18n.tr("Open the link"), icon = lucide.GLOBE).clicked { preview_open(app, url) }
		}
		ui.menu_separator()
		fork_item(app, pane, m)
	case .Synthetic, .Shell:
		// (reports of background jobs: what their cards show, not their markup)
		t := len(m.jobs) > 0 ? jobs_text(m.jobs) : m.text
		if ui.menu_item(i18n.tr("Copy"), icon = lucide.COPY, disabled = t == "").clicked { copied(t, i18n.tr("Text copied")) }
		if m.shell_id != "" { if ui.menu_item(i18n.tr("Inspect the output"), icon = lucide.SQUARE_TERMINAL).clicked { output_view_open_shell(app, m.shell_id, m.text, chat_dir(app)) } }
		ui.menu_separator()
		fork_item(app, pane, m)
	case .Compaction, .Idle, .Switch, .Other:
		if ui.menu_item(i18n.tr("Copy"), icon = lucide.COPY, disabled = m.text == "").clicked { copied(m.text, i18n.tr("Text copied")) }
	}
}

// (`m` holds the call: most of an answer at work is its tool calls, and a press on one comes here.)
@(private = "file")
tool_menu :: proc(app: ^App, pane: ^Chat_Pane, m: ^Message, p: ^Part) {
	if ui.menu_item(i18n.tr("Copy the output"), icon = lucide.COPY, disabled = p.output == "").clicked { copied(p.output, i18n.tr("Output copied")) }
	if p.patch != "" { if ui.menu_item(i18n.tr("Copy the diff"), icon = lucide.COPY).clicked { copied(p.patch, i18n.tr("Diff copied")) } }
	if c := p.command; c != "" {
		if ui.menu_item(i18n.tr("Copy the command"), icon = lucide.SQUARE_TERMINAL).clicked { copied(c, i18n.tr("Command copied")) }
	}
	if tool_kind(p.tool_name) == .Shell && output_view_can(p) {
		if ui.menu_item(i18n.tr("Inspect the output"), icon = lucide.SQUARE_TERMINAL).clicked { output_view_open_part(app, p) }
	}
	if path := p.file_path; path != "" {
		if ui.menu_item(i18n.tr("Copy the path"), icon = lucide.FILE).clicked { copied(path, i18n.tr("Path copied")) }
		if ui.menu_item(i18n.tr("Show in the folder"), icon = lucide.FOLDER).clicked { reveal_path(path) }
	}
	if ui.menu_item(i18n.tr("Copy the input"), icon = lucide.COPY, disabled = p.input == "").clicked { copied(p.input, i18n.tr("Input copied")) }
	if url := first_url(p.output); url != "" {
		ui.menu_separator()
		if ui.menu_item(i18n.tr("Open the link"), icon = lucide.GLOBE).clicked { preview_open(app, url) }
	}
	ui.menu_separator()
	fork_item(app, pane, m)
}

// At the end of a window's build (window_overlays), for what a right press noted in that window. (Another window's builds build
// nothing: the toolkit closes a menu its window stops building, which is what a press in another window means.)
@(private = "file")
context_menu :: proc(app: ^App, em: f32) {
	pane := ctx_pane(app)
	quote_chip(app, em)
	if built_state(app) != ctx_window(app) { return }
	key := CTX_MENU_KEY
	// (the composer's is a text field's: the toolkit's, on its area)
	if app.ctx_menu.target.kind == .Composer {
		ui.edit_menu(key, &pane.composer.area, pane.composer.edit_key, .Plain, COMPOSER_PASTE)
		return
	}
	if ui.menu(key) {
		switch app.ctx_menu.target.kind {
		case .None, .Composer:
		case .Message:
			if m := find_msg(pane, app.ctx_menu.target.msg); m != nil { message_menu(app, pane, m) }
		case .Tool:
			if m := find_msg(pane, app.ctx_menu.target.msg); m != nil && app.ctx_menu.target.part < len(m.parts) { tool_menu(app, pane, m, &m.parts[app.ctx_menu.target.part]) }
		case .Image:
			image := app.ctx_menu.target.image
			if ui.menu_item(i18n.tr("Copy image"), image_view_shown(app) ? "Ctrl+C" : "", icon = lucide.COPY).clicked { image_copy(app, image) }
			if !image_view_shown(app) {
				if ui.menu_item(i18n.tr("Open in the viewer"), icon = lucide.ZOOM_IN).clicked { image_view_open(app, image) }
			}
		case .Folder:
			if ui.menu_item(i18n.tr("Copy the path"), icon = lucide.COPY).clicked { clip_set(app.ctx_menu.target.msg); ui.announce(&app.announcer, .Good, i18n.tr("Copied")) }
		case .Diagram:
			code := app.ctx_menu.target.msg
			viewed := ui.view_is_open(&app.program_views, DIAGRAM_VIEW)
			if ui.menu_item(i18n.tr("Copy as PNG"), viewed ? "Ctrl+C" : "", icon = lucide.IMAGE).clicked { diagram_copy_png(app, code, viewed ? app.diagram_view.direction : .Text) }
			if ui.menu_item(i18n.tr("Copy the text"), icon = lucide.COPY).clicked { clip_set(code); ui.announce(&app.announcer, .Good, i18n.tr("Copied")) }
			if !viewed {
				if ui.menu_item(i18n.tr("Open in the viewer"), icon = lucide.ZOOM_IN).clicked { diagram_view_open(app, code) }
			}
		}
	}
}

////////////////////////////////
// Quoting what is selected

// `text` as a quote at the end of `pane`'s composer, a line left under it for what one has to say about it. `comment`: the
// keyboard goes there.
quote_text :: proc(app: ^App, pane: ^Chat_Pane, text: string, comment: bool) {
	t := strings.trim_space(text)
	if t == "" { return }
	b := strings.builder_make(context.temp_allocator)
	had := strings.trim_space(ui.text_edit_string(&pane.composer.area))
	if had != "" { fmt.sbprintf(&b, "%s\n\n", had) }
	rest := t
	for line in strings.split_lines_iterator(&rest) { fmt.sbprintf(&b, "> %s\n", strings.trim_right_space(line)) }
	strings.write_byte(&b, '\n')
	ui.text_edit_set(&pane.composer.area, strings.to_string(b))
	if comment { pane.composer.focus_next = true } else { ui.announce(&app.announcer, .Good, i18n.tr("Quoted in the composer")) }
}

// Ctrl+Q: to the composer of the pane the selection was made in (quote_chip noted it).
quote_selection :: proc(app: ^App) {
	quote_text(app, quote_pane(app), ui.selected_text(&app.state, context.temp_allocator), true)
}

// The pane under the pointer when the selection was made; the main view when it closed since.
@(private = "file")
quote_pane :: proc(app: ^App) -> ^Chat_Pane {
	i := app.quote.pane
	return pane_is_shown(app, i) ? &app.panes[i] : main_pane(app)
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
	s := built_state(app)
	q := &app.quote
	// (one chip, in the last window pressed in: a selection is made with a press, and each window keeps its own, so a chip that
	// went to whichever window has one would jump between two at each frame)
	if ui.mouse_pressed(.Left) && q.window != s && !(q.window == nil && s == &app.state) {
		q.window, q.open = s, false
		q.serial, q.done = max(u64), max(u64)   // (another window's numbers: none of them is this window's)
	}
	if s != (q.window != nil ? q.window : &app.state) { return }
	id := "###quote_chip"
	on_chip := false
	if r, ok := ui.popover_rect(id); ok && q.open { on_chip = draw.rect_contains(r, ui.mouse_pos()) }
	if !on_chip {
		if !ui.has_selection(s) || overlay_open(app) || ui.active_key() != 0 { q.open = false; return }
		serial := ui.selection_serial(s)
		if serial == q.done { return }
		if quote_place(q, serial, ui.mouse_pos()) {
			delete(q.kept)
			q.kept = ui.selected_text(s)
			q.pane = pane_index(app, pane_at(app, ui.mouse_pos()))
		}
	}
	if !q.open { return }
	if ui.popover(id, q.at, math.round(em * QUOTE_CHIP_W_EM), .Above, align_right = false) {
		ui.next({width = ui.fill(), height = ui.px(math.round(em * 2.3)), axis = .X, cross = .Center})
		if ui.row(.Center, id = "###qr") {
			ui.spacer(ui.px(em * 0.35))
			quoted := ui.button("q1", i18n.tr("Quote"), o = {face = .Ghost, width = ui.fill(), height = math.round(em * BUTTON_SMALL_H_EM)}).clicked
			commented := ui.button("q2", i18n.tr("Comment"), o = {face = .Ghost, width = ui.fill(), height = math.round(em * BUTTON_SMALL_H_EM)}).clicked
			ui.spacer(ui.px(em * 0.35))
			if quoted || commented {
				quote_text(app, quote_pane(app), q.kept, commented)
				q.done = q.serial
				q.open = false
			}
		}
	}
}

////////////////////////////////
// Rename

Rename :: struct {
	at:    Rename_At,   // in place, where the title is (a double click on it); .None: the prompt (RENAME_VIEW), or nothing
	fresh: bool,
	held:  bool,        // in place: the field had the keyboard (losing it commits, as a click elsewhere)
	shown: bool,        // in place: its field was built in this build (or it began in it)
	id:    string,      // (owned)
	field: ui.Line_Edit,
}

Rename_At :: enum u8 { None, Header, Side }

// The field holds session `id`'s title, selected.
@(private = "file")
rename_prepare :: proc(app: ^App, id: string) {
	pane := main_pane(app)
	r := &app.rename
	delete(r.id)
	r.id = strings.clone(id)
	r.fresh, r.at = true, .None
	s := find_session(app, id)
	if s == nil && pane.chat.have_self && pane.chat.self.id == id { s = &pane.chat.self }
	ui.line_edit_set(&r.field, s != nil ? s.title : "")
	ui.line_edit_select_all(&r.field)
}

// The title of session `id`, asked in a dialog (the toolkit's prompt: its field has the keyboard as it opens).
rename_open :: proc(app: ^App, id: string) {
	rename_prepare(app, id)
	app.rename.fresh = false
	ui.prompt_open(RENAME_VIEW, &app.rename.field, {title = i18n.tr("Rename the session"), placeholder = i18n.tr("Title"), act = i18n.tr("Rename"), width_em = 28})
}

// The title of session `id`, edited where it is shown (`at`): Enter or a click elsewhere keeps it, Escape leaves it as it was.
rename_inline :: proc(app: ^App, id: string, at: Rename_At) {
	ui.view_close(&app.program_views, RENAME_VIEW)
	rename_prepare(app, id)
	app.rename.at, app.rename.held, app.rename.shown = at, false, true
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
	pad := math.round(em * ui.SPACE_2)
	w := ui.fill()
	if fit { w = ui.px(math.round(ui.text_width(app.font, font_size, ui.line_edit_string(&r.field)) + 2 * pad + em * RENAME_ROOM_EM), 0) }
	ui.next({width = w, height = ui.px(height), cross = .Center, radius = 5 * ui.scale()})
	if ui.well("###ren_in", .X, flags = {.Focus_Within, .Draw_Focus_Ring}) {
		if ui.tags("bare") {
			ui.next({width = ui.fill(), height = ui.pct(1), font_size = font_size, text_pad = pad})
			res := ui.line_edit("###ren_f", &r.field, {placeholder = i18n.tr("Title")})
			if r.fresh { ui.set_focus(res.box.key); r.fresh = false } else if res.focused { r.held = true }
			switch {
			case res.cancelled:          r.at = .None
			case res.committed:          rename_commit(app)
			case r.held && !res.focused: rename_commit(app)   // (a click elsewhere, Tab: as Enter)
			}
		}
	}
}

// After the sidebar and the conversation are built: a title edited in place that neither built (another session shown, its
// row scrolled away) is left as it was.
rename_follow :: proc(app: ^App) {
	r := &app.rename
	if r.at != .None && !r.shown { r.at = .None }
	r.shown = false
}

// The prompt's answer, in a build of the main window.
rename_answer :: proc(app: ^App) {
	if ui.prompt_answer(RENAME_VIEW) == .Confirmed { rename_commit(app) }
}

@(private = "file")
rename_commit :: proc(app: ^App) {
	r := &app.rename
	t := strings.trim_space(ui.line_edit_string(&r.field))
	ui.view_close(&app.program_views, RENAME_VIEW)
	r.at = .None
	if t == "" { return }
	if s := find_session(app, r.id); s != nil && s.title == t { return }   // (nothing changed: nothing to ask)
	rename_session(app, r.id, t)
	refresh_soon(app)
}

////////////////////////////////
// What the answers to its requests do (net.odin REQ_FACTS)

forked_on_ok :: proc(app: ^App, r: ^Request, v: json.Value) {
	pane := req_pane(app, r)
	id := tk_json.text(v, "data", "id")
	if id == "" { return }
	refresh_sessions(app)
	if r.gen == pane.chat.gen {
		open_root(app, id)
		prompt_restore(app, pane, pane.composer.fork_prompt)
		if pane.composer.fork_prompt != "" { pane.composer.focus_next = true }
	}
	ui.announce(&app.announcer, .Good, i18n.tr("Forked"))
}
