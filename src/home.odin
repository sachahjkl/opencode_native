// The first page: what runs now, where one was, a folder to start in. The composer under it starts a session in the folder
// chosen; a click on a session opens it.
package occ

import "core:fmt"
import "core:math"
import "core:strings"
import "gt:draw"
import "gt:platform"
import "gt:ui"

@(private = "file")
home_row_draw :: proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
	if b.hot_t > FADE_VISIBLE { draw.rect(dc, b.rect, {1, 1, 1, 0.035 * b.hot_t}, 7 * ui.scale()) }
}

@(private = "file")
home_session :: proc(app: ^App, s: ^Session_Info, em, now: f64, busy: bool) {
	e := f32(em)
	ui.next({width = ui.fill(), height = ui.px(math.round(e * 2.1)), axis = .X, cross = .Center})
	ui.a11y({role = .Button, name = s.title})
	b := ui.build_box({.Clickable, .Focusable}, fmt.tprintf("###hs_%s", s.id))
	b.custom = home_row_draw
	sig := ui.signal(b)
	if sig.clicked { open_root(app, s.id) }
	if sig.right_clicked {
		ui.ctx_menu_open(ui.key_from_string(0, "session_menu"), b.rect.min + sig.mouse)
		delete(app.menu_session)
		app.menu_session = strings.clone(s.id)
	}
	if ui.parent(b) {
		ui.spacer(ui.px(e * 0.6))
		if busy {
			session_lamp("###l", LAMP_WORKING, e)
		} else if !logo_of(app, "###lg", project_logo(app, s.project), math.round(e * 1.25)) {
			glyph(ICO_CHAT, hex(HEX_FAINT), math.round(e * ICON_SMALL), e * 1.25)
		}
		ui.spacer(ui.px(e * 0.55))
		text("t", s.title != "" ? s.title : "Untitled", hex(HEX_TEXT_SOFT), ui.Style_Mod{font_size = math.round(e * FS_LABEL)}, ui.fill())
		ui.spacer(ui.px(e * 0.5))
		text("d", base_name(s.directory), hex(HEX_FAINT), ui.Style_Mod{font = app.mono, font_size = math.round(e * FS_CAPTION)})
		ui.spacer(ui.px(e * 0.8))
		text("a", rel_time(now, s.updated), hex(HEX_FAINT), ui.Style_Mod{font = app.mono, font_size = math.round(e * FS_CAPTION)})
		ui.spacer(ui.px(e * 0.6))
	}
}

// The folders of the latest sessions, the latest first.
@(private = "file")
home_folders :: proc(app: ^App) -> []string {
	seen := make(map[string]bool, allocator = context.temp_allocator)
	out := make([dynamic]string, context.temp_allocator)
	for &s in app.sessions {
		if s.directory == "" || s.directory in seen { continue }
		seen[s.directory] = true
		append(&out, s.directory)
		if len(out) == HOME_FOLDERS { break }
	}
	return out[:]
}

@(private = "file")
home_pick_folder :: proc(app: ^App) {
	r := platform.pick_folder_dialog({owner = app.win, title = "Start a session in", remember_id = "new_session"})
	defer platform.dialog_result_destroy(&r)
	if r.status == .Chosen && len(r.paths) > 0 { app.chat.new_dir = strings.clone(r.paths[0], app.chat.alloc) }
}

home :: proc(app: ^App, em: f32) {
	now := now_epoch_ms()
	ui.spacer(ui.px(em * HOME_TOP_EM))
	ui.next({width = ui.fill(), height = ui.px(em * 3.2), axis = .X, cross = .Center})
	if ui.row(.Center, id = "###h_logo") {
		big := ui.Style_Mod{font = app.mono_bold, font_size = math.round(em * FS_WORDMARK * 0.8)}
		text("l1", "open", hex(HEX_FAINT), big)
		text("l2", "code", hex(HEX_TEXT), big)
		ui.spacer(ui.px(em * 0.6))
		text("l3", "native", accent(), ui.Style_Mod{font = app.mono, font_size = math.round(em * FS_WORDMARK * 0.8)})
		ui.spacer(ui.fill())
		if !online(app) {
			refused := app.link == .Auth_Refused
			text("c", fmt.tprintf(refused ? "%s refused the password" : "Connecting to %s…", server_base(app)), refused ? hex(HEX_RED) : hex(HEX_YELLOW), ui.Style_Mod{font = app.mono, font_size = math.round(em * FS_SMALL)})
		}
	}
	info_line(app, "###h_not_theirs", APP_NOT_THEIRS, em, hex(HEX_FAINT))
	ui.spacer(ui.px(em * 0.8))

	// where a new session starts
	section_label("h_start", "START IN", em)
	folders := home_folders(app)
	if app.chat.new_dir == "" && len(folders) > 0 { app.chat.new_dir = strings.clone(folders[0], app.chat.alloc) }
	ui.next({width = ui.fill(), height = ui.children_sum(), gap = {em * 0.45, em * 0.45}})
	if ui.flow({em * 0.45, em * 0.45}, "###h_folders") {
		for d, i in folders {
			kind := Btn_Kind.Normal
			if d == app.chat.new_dir { kind = .Toggled }
			if bevel_button(fmt.tprintf("###hf%d", i), base_name(d), ICO_FOLDER, kind, height = math.round(em * BUTTON_COMPACT_H_EM)).clicked {
				app.chat.new_dir = strings.clone(d, app.chat.alloc)
				app.cx.focus_composer = true
			}
		}
		if bevel_button("###hf_other", "Other folder…", ICO_ADD, .Ghost, height = math.round(em * BUTTON_COMPACT_H_EM)).clicked { home_pick_folder(app) }
	}
	ui.spacer(ui.px(em * 1.1))

	// what runs now, whatever the session
	running := 0
	for &s in app.sessions { if s.parent == "" && (app.busy[s.id] or_else false) { running += 1 } }
	if running > 0 {
		section_label("h_run", fmt.tprintf("RUNNING NOW  %d", running), em)
		shown := 0
		for &s in app.sessions {
			if s.parent != "" || !(app.busy[s.id] or_else false) { continue }
			if shown == HOME_RUNNING { break }
			home_session(app, &s, f64(em), now, true)
			shown += 1
		}
		ui.spacer(ui.px(em * 1))
	}

	if app.sessions_loaded {
		section_label("h_rec", "RECENT", em)
		shown := 0
		for &s in app.sessions {
			if s.parent != "" || (app.busy[s.id] or_else false) { continue }
			if shown == HOME_RECENT { break }
			home_session(app, &s, f64(em), now, false)
			shown += 1
		}
		if shown == 0 {
			ui.next({width = ui.fill(), height = ui.px(em * 2), axis = .X, cross = .Center})
			if ui.row(.Center, id = "###h_none") { text("n", "No session yet: ask anything below.", hex(HEX_FAINT), ui.Style_Mod{font_size = math.round(em * FS_NOTE)}) }
		}
		ui.spacer(ui.px(em * 1.1))
	}

	// what is worth knowing first
	ui.next({width = ui.fill(), height = ui.px(em * 1.6), axis = .X, cross = .Center})
	if ui.row(.Center, id = "###h_keys") {
		if hint_action("###hk1", "Ctrl+K  everything", em, app.mono) { command_run(app, command_find("app.palette")) }
		ui.spacer(ui.px(em * 1.6))
		if hint_action("###hk2", "Ctrl+Shift+B  preview", em, app.mono) { command_run(app, command_find("view.preview")) }
		ui.spacer(ui.px(em * 1.6))
		if hint_action("###hk3", "F1  shortcuts", em, app.mono) { command_run(app, command_find("app.help")) }
	}
	ui.spacer(ui.px(em * 2))
}
