// The first page: what runs now, where one was, a folder to start in. The composer under it starts a session in the folder
// chosen; a click on a session opens it.
package ocn

import "core:fmt"
import "core:math"
import "core:strings"
import "gt:draw"
import "gt:platform"
import "gt:ui"
import lucide "gt:lucide"
import i18n "gt:i18n"

@(private = "file")
home_row_draw :: proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
	if b.hot_t > FADE_VISIBLE { draw.rect(dc, b.rect, {1, 1, 1, 0.035 * b.hot_t}) }   // (square: a row)
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
		ui.menu_open("session_menu", b.rect.min + sig.mouse)
		delete(app.sidebar.menu_session)
		app.sidebar.menu_session = strings.clone(s.id)
	}
	if ui.parent(b) {
		ui.spacer(ui.px(e * 0.6))
		if busy {
			session_lamp("###l", LAMP_WORKING, e)
		} else if !logo_of(app, "###lg", project_logo(app, s.project), math.round(e * 1.25)) {
			glyph(lucide.MESSAGE_SQUARE, hex(HEX_FAINT), math.round(e * ICON_SMALL), e * 1.25)
		}
		ui.spacer(ui.px(e * 0.55))
		text("t", s.title != "" ? s.title : i18n.tr("Untitled"), hex(HEX_TEXT_SOFT), ui.Style_Mod{font_size = math.round(e * FS_LABEL)}, ui.fill())
		ui.spacer(ui.px(e * 0.5))
		text("d", base_name(s.directory), hex(HEX_FAINT), ui.Style_Mod{font = app.mono, font_size = math.round(e * FS_CAPTION)})
		ui.spacer(ui.px(e * 0.8))
		text("a", age_text(now, s.updated), hex(HEX_FAINT), ui.Style_Mod{font = app.mono, font_size = math.round(e * FS_CAPTION)})
		ui.spacer(ui.px(e * 0.6))
	}
}

// What the home page lists of the sessions: made again when the sessions or what runs change (sessions_ver, marks_ver), not
// at each frame. The indices are in app.sessions and the folders its strings: both good until sessions_ver moves.
Home_Lists :: struct {
	sessions_ver, marks_ver: u64,
	made:    bool,
	folders: [dynamic]string,   // the folders of the latest sessions, the latest first
	running: [dynamic]int,      // the top sessions that run, at most HOME_RUNNING
	running_count: int,         // all of them
	recent:  [dynamic]int,      // the latest top sessions that neither run nor are archived, at most HOME_RECENT
}

@(private = "file")
home_lists :: proc(app: ^App) -> ^Home_Lists {
	h := &app.cx.home_lists
	if h.made && h.sessions_ver == app.cx.sessions_ver && h.marks_ver == app.cx.marks_ver { return h }
	h.made, h.sessions_ver, h.marks_ver = true, app.cx.sessions_ver, app.cx.marks_ver
	clear(&h.folders); clear(&h.running); clear(&h.recent)
	h.running_count = 0
	seen := make(map[string]bool, allocator = context.temp_allocator)
	for &s, i in app.sessions {
		if s.directory != "" && s.directory not_in seen && len(h.folders) < HOME_FOLDERS {
			seen[s.directory] = true
			append(&h.folders, s.directory)
		}
		if s.parent != "" { continue }
		if app.busy[s.id] or_else false {
			h.running_count += 1
			if len(h.running) < HOME_RUNNING { append(&h.running, i) }
		} else if s.archived == 0 && len(h.recent) < HOME_RECENT {   // (archived: put away)
			append(&h.recent, i)
		}
	}
	return h
}

// The folders of the latest sessions, the latest first.
home_folders :: proc(app: ^App) -> []string { return home_lists(app).folders[:] }

@(private = "file")
home_pick_folder :: proc(app: ^App) {
	ui.file_dialog(&app.state, .Folder, {owner = app.win, title = i18n.tr("Start a session in"), remember_id = "new_session"}, proc(r: platform.Dialog_Result, user: rawptr) {
		app := (^App)(user)
		if r.status == .Chosen && len(r.paths) > 0 { app.chat.new_dir = strings.clone(r.paths[0], app.chat.alloc) }
	}, app)
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
			text("c", fmt.tprintf(refused ? i18n.tr("%s refused the password") : i18n.tr("Connecting to %s…"), server_base(app)), refused ? hex(HEX_RED) : hex(HEX_YELLOW), ui.Style_Mod{font = app.mono, font_size = math.round(em * FS_SMALL)})
		}
	}
	info_line(app, "###h_not_theirs", i18n.tr(APP_NOT_THEIRS), em, hex(HEX_FAINT))
	ui.spacer(ui.px(em * 0.8))

	// where a new session starts
	section_label("h_start", i18n.tr("START IN"), em)
	folders := home_folders(app)
	if app.chat.new_dir == "" && len(folders) > 0 { app.chat.new_dir = strings.clone(folders[0], app.chat.alloc) }
	ui.next({width = ui.fill(), height = ui.children_sum(), gap = {em * 0.45, em * 0.45}})
	if ui.flow({em * 0.45, em * 0.45}, "###h_folders") {
		for d, i in folders {
			sig := ui.button(fmt.tprintf("hf%d", i), ui.text_shown(base_name(d)), lucide.FOLDER, {face = d == app.chat.new_dir ? .Toggled : .Raised, height = math.round(em * BUTTON_COMPACT_H_EM)})
			if sig.clicked {
				app.chat.new_dir = strings.clone(d, app.chat.alloc)
				app.composer.focus_next = true
			}
			// (the button shows the folder's name alone: two folders of one name differ only by their paths)
			if ui.hovered_for(sig) { if ui.tooltip() { ui.tooltip_text(d) } }
			if sig.right_clicked { ctx_open(app, .Folder, msg = d) }
		}
		if ui.button("hf_other", i18n.tr("Other folder…"), lucide.PLUS, {face = .Ghost, height = math.round(em * BUTTON_COMPACT_H_EM)}).clicked { home_pick_folder(app) }
	}
	ui.spacer(ui.px(em * 1.1))

	// what runs now, whatever the session
	lists := home_lists(app)
	if lists.running_count > 0 {
		section_label("h_run", fmt.tprintf(i18n.tr("RUNNING NOW  %d"), lists.running_count), em)
		for i in lists.running { home_session(app, &app.sessions[i], f64(em), now, true) }
		ui.spacer(ui.px(em * 1))
	}

	if app.sessions_loaded {
		section_label("h_rec", i18n.tr("RECENT"), em)
		for i in lists.recent { home_session(app, &app.sessions[i], f64(em), now, false) }
		if len(lists.recent) == 0 {
			ui.next({width = ui.fill(), height = ui.px(em * 2), axis = .X, cross = .Center})
			if ui.row(.Center, id = "###h_none") { text("n", i18n.tr("No session yet: ask anything below."), hex(HEX_FAINT), ui.Style_Mod{font_size = math.round(em * FS_NOTE)}) }
		}
		ui.spacer(ui.px(em * 1.1))
	}

	// what is worth knowing first
	ui.next({width = ui.fill(), height = ui.px(em * 1.6), axis = .X, cross = .Center})
	if ui.row(.Center, id = "###h_keys") {
		if hint_action("###hk1", i18n.tr("Ctrl+K  everything"), em, app.mono) { command_run(app, command_find("app.palette")) }
		ui.spacer(ui.px(em * 1.6))
		if hint_action("###hk2", i18n.tr("Ctrl+Shift+B  preview"), em, app.mono) { command_run(app, command_find("view.preview")) }
		ui.spacer(ui.px(em * 1.6))
		if hint_action("###hk3", i18n.tr("F1  shortcuts"), em, app.mono) { command_run(app, command_find("app.help")) }
	}
	ui.spacer(ui.px(em * 2))
}
