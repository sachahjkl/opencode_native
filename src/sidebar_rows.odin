// The sidebar's rows: its top (new session, search, modes), the sections and their sessions, the menus of a session and of a
// project, the dialog that deletes a session. What it lists, and in what order, is in sidebar.odin.
package ocn

import "core:fmt"
import "core:math"
import "core:strings"
import "core:unicode"
import "core:unicode/utf8"
import "gt:draw"
import "gt:ui"
import lucide "gt:lucide"
import i18n "gt:i18n"

////////////////////////////////
// Sidebar

Item_Draw :: struct { selected: bool }

// The ground of the session shown: the theme's own navigation fill when it gives one, else ocn's (chosen_ground).
session_ground :: proc() -> Color {
	if fill, ok := chosen_fill(.Nav); ok { return fill }
	return chosen_ground()
}

item_draw :: proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
	d := (^Item_Draw)(user)
	// the one shown: a ground of the accent, nothing more (its mark and its lamp say the rest); under the pointer, a lighter
	// one. Square: a row's ground runs from edge to edge, row under row.
	// (flush: across the whole row of the sidebar, its indent included, not from where the item begins)
	r := b.rect
	if b.parent != nil { r.min.x, r.max.x = b.parent.rect.min.x, b.parent.rect.max.x }
	if d.selected {
		draw.rect(dc, r, session_ground())
	} else if b.hot_t > FADE_VISIBLE {
		draw.rect(dc, r, ui.with_alpha(ui.theme_color("text"), ITEM_HOVER_TINT * b.hot_t))
	}
}

// The sidebar zone's fold button (the toolkit's Minimise or Restore, ui.view_fold_button), at the start of a row: its
// centre on the rail's centre, so that it is the same pixel in the list and in the rail and stays under the pointer
// that folds and unfolds. Its space before it is set from the button's own width once it is built (the toolkit's
// size, never a copy of it here). False: the sidebar is in no side zone, no button.
sidebar_fold :: proc(v: ^ui.View, em: f32) -> bool {
	ui.next({width = ui.px(0), height = ui.px(0)})
	lead := ui.build_box({}, "###fold_lead")
	sig := ui.view_fold_button(v)
	if sig.box == nil { return false }
	lead.pref[.X] = ui.px(math.round((math.round(SIDEBAR_RAIL_EM * em) - sig.box.pref[.X].value) * 0.5))
	return true
}

sidebar :: proc(app: ^App, v: ^ui.View, em: f32) {
	ui.next({width = ui.fill(), height = ui.fill(), axis = .Y, bg = ui.theme_color("bar background"), radius = 0})   // (square: its rounded corner notched the bar's edge; as wide as its view)
	if ui.column(flags = {.Draw_Background}, id = "###sidebar") {
		ui.space(ui.SPACE_2)
		server_tabs(app, v, em)
		ui.space(ui.SPACE_2)
		// new session + refresh
		ui.next({width = ui.fill(), height = ui.children_sum(), axis = .X, cross = .Center})
		if ui.row(.Center, id = "###side_top") {
			ui.space(ui.SPACE_3)
			// (each names the palette's command it does: Shift+Enter on it in the palette shows the button)
			nsig := ui.button("new", i18n.tr("New session"), lucide.PLUS, {intent = .Primary, width = ui.fill()})
			ui.act_name(nsig.box, "command:session.new")
			if nsig.clicked { new_session(app) }
			ui.space(ui.SPACE_2)
			rsig := ui.button("refresh", icon = lucide.REFRESH_CW, o = {face = .Raised})
			ui.act_name(rsig.box, "command:app.refresh")
			if rsig.clicked { refresh_sessions(app) }
			ui.space(ui.SPACE_3)
		}
		ui.space(ui.SPACE_3)
		// search well
		ui.next({width = ui.fill(), height = ui.children_sum(), axis = .X})
		if ui.row(id = "###side_search") {
			ui.space(ui.SPACE_3)
			ui.next({width = ui.fill(), height = ui.px(math.round(em * FIELD_H_EM)), axis = .X, cross = .Center})
			if ui.well("###search_well", .X) {
				ui.space(ui.SPACE_2)
				glyph(lucide.SEARCH, ui.theme_color("faint text"), math.round(em * ICON_SMALL))
				if ui.tags("bare") {
					ui.next({width = ui.fill(), height = ui.pct(1), text_pad = em * 0.3})
					ui.line_edit("###search", &app.sidebar.search, {placeholder = i18n.tr("Search sessions"), clearable = true})
				}
			}
			ui.space(ui.SPACE_3)
		}
		ui.space(ui.SPACE_2)
		ui.next({width = ui.fill(), height = ui.children_sum(), axis = .X})
		if ui.row(id = "###side_modes") {
			ui.space(ui.SPACE_3)
			sidebar_mode_switch(app, em)
			ui.space(ui.SPACE_3)
		}
		ui.space(ui.SPACE_2)
		ui.next({width = ui.fill(), height = ui.px(GROOVE_BOX_PX)})
		groove("###sg")

		ui.next({width = ui.fill(), height = ui.fill()})
		if ui.scroll_y("###sessions") {
			sessions_list(app, em)
		}
	}
	// the sidebar's right edge: a carved line
}

sessions_list :: proc(app: ^App, em: f32) {
	pane := main_pane(app)
	if !app.sessions_loaded {
		ui.space(ui.SPACE_4)
		ui.next({width = ui.fill(), height = ui.px(em * 2), text_align = .Center})
		if ui.tags("weak") { ui.label(online(app) ? i18n.tr("Loading…") : i18n.tr("Connecting…")) }
		return
	}
	sections := sidebar_view(app, ui.line_edit_string(&app.sidebar.search), sidebar_hold_wanted(app, ui.parent_box()))
	kids := app.sidebar.kept.kids   // (the sub-agents of each session, listed under it unless the list is flat)
	mode := app.prefs.sidebar_mode
	now := now_epoch_ms()
	ui.space(ui.SPACE_2)
	// Only the rows near the view are built (the toolkit's lazy column, as the conversation's): a header or a session
	// each, the others stand as their height. Hundreds of sessions were built and drawn at every frame.
	ui.next({width = ui.fill(), height = ui.children_sum(), axis = .Y})
	if ui.column(id = "###rows") {
		lz := ui.lazy_begin()
		gap := false   // (between a section's last session and the next section)
		for &sec in sections {
			folded := app.sidebar.folded[sec.key] or_else sec.shut
			if ui.lazy_item(lz, sec.lazy_id) {
				if gap { ui.space(ui.SPACE_2) }
				if sec.title != "" { inbox_header(app, &sec, folded, em) } else { group_header(app, &sec, folded, em) }
			}
			gap = !folded
			if folded { continue }
			for i in sec.items {
				s := &app.sessions[i]
				if ui.lazy_item(lz, s.lazy_id, always = s.id == pane.chat.id) {
					session_item(app, s, em, now, 0, app.prefs.subagents == "nested" ? children_of(app, s.id, kids) : nil, project = mode == .Inbox)
				}
			}
		}
	}
	ui.space(ui.SPACE_4)
	ui.next({width = ui.fill(), height = ui.children_sum(), axis = .X})
	if ui.row(id = "###side_settings") {
		ui.space(ui.SPACE_2)
		ssig := glyph_label_button(app, "###open_settings", i18n.tr("Settings"), em)
		ui.act_name(ssig.box, "command:app.settings")
		if ssig.clicked { settings_open(app) }
	}
	ui.space(ui.SPACE_4)
	session_menu(app, em)
	project_menu(app, em)
}

// A group's header: folder, name, count, "+".
@(private = "file")
group_header :: proc(app: ^App, gr: ^Side_Section, folded: bool, em: f32) {
	pane := main_pane(app)
	gkey := gr.key
	ui.next({width = ui.fill(), height = ui.px(math.round(em * 2)), axis = .X, cross = .Center})
	hdr := ui.build_box({.Clickable, .Hot_Within}, fmt.tprintf("###g%d", gkey))
	hs := ui.signal(hdr)
	if hs.clicked { app.sidebar.folded[gkey] = !folded }
	// a right click: its project's menu (its icon)
	if hs.right_clicked && len(gr.items) > 0 {
		delete(app.sidebar.menu_project)
		app.sidebar.menu_project = strings.clone(app.sessions[gr.items[0]].project)
		ui.menu_open("project_menu", ui.mouse_pos(), hdr.key)
	}
	if ui.parent(hdr) {
		ui.space(ui.SPACE_3)
		glyph(folded ? lucide.CHEVRON_RIGHT : lucide.CHEVRON_DOWN, ui.theme_color("faint text"), math.round(em * ICON_TINY), em * 0.9)
		// the project's logo, else a folder
		logo := len(gr.items) > 0 ? project_logo(app, app.sessions[gr.items[0]].project) : nil
		if !logo_of(app, "###glogo", logo, math.round(em * 1.25)) { glyph(lucide.FOLDER, ui.hue(.Accent), math.round(em * ICON_REGULAR)) }
		ui.space(ui.SPACE_1)
		name := gr.dir != "" ? base_name(gr.dir) : i18n.tr("(no folder)")
		text("n", strings.to_upper(name, context.temp_allocator), hs.hovering ? ui.theme_color("text") : ui.theme_color("weak text"), ui.Style_Mod{font = app.mono_bold, font_size = math.round(em * FS_SMALL)})
		ui.space(ui.SPACE_2)
		text("c", fmt.tprintf("%d", len(gr.items)), ui.theme_color("faint text"), ui.Style_Mod{font = app.mono, font_size = math.round(em * FS_SMALL)})
		ui.spacer(ui.fill())
		// "+": always there (built only while the header was hovered, it vanished as soon as the pointer moved onto
		// it: the header is no longer the box under the pointer), shown while the header is hot (Hot_Within keeps it
		// hot over its button)
		plus_col := hdr.hot_t > FADE_VISIBLE ? ui.theme_color("weak text") : Color{0, 0, 0, 0.001}
		ui.next({width = ui.px(math.round(em * 1.5)), height = ui.px(math.round(em * 1.5)), fg = plus_col})
		if ui.button("gadd", icon = lucide.PLUS).clicked {
			new_session(app)
			delete(pane.chat.new_dir, pane.chat.alloc)
			pane.chat.new_dir = strings.clone(gr.dir, pane.chat.alloc)
		}
		ui.space(ui.SPACE_2)
	}
}

// A session of the sidebar; `depth` 1: a sub-agent listed under its parent. `kids`: its sub-agents (indices into
// app.sessions), listed under it when its toggle is open. `project`: its folder under its title, when the list does not say it.
// A session's mark: its project's logo; else the first letter of its title on a colour of the palette its id picks (the same session, the same colour,
// whatever its title becomes), the colour faint behind, full on the letter.
session_badge :: proc(app: ^App, s: ^Session_Info, size, em: f32) {
	if logo_of(app, "###badge_logo", project_logo(app, s.project), size) { return }   // (its project's logo, when it has one)
	letter := "·"
	for r, i in s.title {
		if unicode.is_letter(r) || unicode.is_digit(r) { letter = strings.to_upper(s.title[i:i + utf8.rune_size(r)], context.temp_allocator); break }
	}
	c := ui.hue(ui.Hue(session_badge_index(s.id)))
	ui.next({width = ui.px(size), height = ui.px(size), bg = ui.with_alpha(c, SESSION_BADGE_ALPHA), fg = c, radius = math.round(size * 0.3 * corners()),
		text_align = .Center, font = ui.styled_face(app.font, true, false), font_size = math.round(size * 0.55), text_pad = 0})
	ui.build_box({.Draw_Background, .Draw_Text, .No_Text_Trunc}, fmt.tprintf("%s###badge", letter))
}

// Which hue of the theme a session's id picks (FNV-1a: the same id, the same colour, on every machine).
session_badge_index :: proc(id: string) -> int {
	h: u32 = 2166136261
	for i in 0 ..< len(id) { h = (h ~ u32(id[i])) * 16777619 }
	return int(h % u32(len(ui.Hue)))
}

// What a session's lamp says, in the order one wins over another: what waits for the person first. The row and the
// rail's mark light the same lamp from it, the rail's tooltip says it in words.
Session_Light :: enum u8 { Rest, Unseen, Background, Running, Waits }

session_light :: proc(app: ^App, s: ^Session_Info) -> Session_Light {
	switch {
	case session_waits(app, s.id):           return .Waits        // (a run that cannot go on without the person)
	case app.busy[s.id] or_else false:       return .Running
	case session_in_background(app, s.id):   return .Background   // (at rest, its commands still running: steady)
	case session_unseen(app, s):             return .Unseen       // (over and not seen)
	}
	return .Rest
}

// The lamp of a light; an unseen end is how it ended, the lamp without its light.
session_light_lamp :: proc(s: ^Session_Info, light: Session_Light, em: f32) {
	switch light {
	case .Waits:      session_lamp("###waits", LAMP_WAITS, em)
	case .Running:    session_lamp("###busy", LAMP_WORKING, em)
	case .Background: session_lamp("###bg", LAMP_BACKGROUND, em)
	case .Unseen:
		st, _ := state_of_word(s.outcome)
		session_lamp_off("###unseen", sub_state_color(st), em)
	case .Rest:
	}
}

session_item :: proc(app: ^App, s: ^Session_Info, em: f32, now: f64, depth := 0, kids: []int = nil, project := false) {
	pane := main_pane(app)
	selected := s.id == pane.chat.id
	sub_list := false
	ui.next({width = ui.fill(), height = ui.px(math.round(em * (project ? SIDE_INBOX_ROW_EM : depth > 0 ? 2.0 : 2.3))), axis = .X, cross = .Center})
	if ui.row(.Center, id = fmt.tprintf("###r_%s", s.id)) {
		ui.spacer(ui.px(em * (ui.SPACE_2 + 1.1 * f32(depth))))   // (1.1: a level of the tree, under its parent's badge)
		ui.next({width = ui.fill(), height = ui.pct(1), axis = .X, cross = .Center})
		b := chosen_box({.Clickable, .Focusable}, "###item", selected, .Nav)
		d := ui.frame_new(Item_Draw)
		d.selected = selected
		b.custom = item_draw
		b.custom_user = d
		sig := ui.signal(b)
		if sig.clicked {
			if depth > 0 && s.parent != "" {
				// a sub-agent: Back returns to its parent
				open_root(app, s.parent)
				drill_down(app, s.id)
			} else { open_root(app, s.id) }
		}
		if sig.double_clicked { rename_inline(app, s.id, .Side) }
		if sig.right_clicked {
			ui.menu_open("session_menu", b.rect.min + sig.mouse)
			delete(app.sidebar.menu_session)
			app.sidebar.menu_session = strings.clone(s.id)
		}
		if ui.parent(b) {
			ui.spacer(ui.px(em * (s.parent != "" && depth == 0 ? 1.6 : ui.SPACE_4)))   // (1.6: a sub-agent's row lines up under its parent's title)
			if depth == 0 {
				session_badge(app, s, math.round(em * (project ? SESSION_BADGE_INBOX_EM : SESSION_BADGE_EM)), em)
				ui.space(ui.ICON_GAP)
			}
			busy := app.busy[s.id] or_else false
			if depth > 0 {
				// a sub-agent: its state's mark (a lamp while it runs, a sign once it ended), its agent in its colour
				st, _ := state_of_word(s.outcome)
				if busy { st = .Running }
				state_mark("###st", st, size = em * 0.75)
				ui.space(ui.SPACE_1)
				text("ag", s.agent, inked(b, ui.theme_color("faint text")), ui.Style_Mod{font = app.mono_bold, font_size = math.round(em * FS_CAPTION)})
				ui.space(ui.SPACE_1)
			} else if light := session_light(app, s); light != .Rest {
				session_light_lamp(s, light, em)
				ui.space(ui.SPACE_1)
			}
			title := s.title != "" ? s.title : i18n.tr("Untitled")
			// a sub-agent: lit while it runs, dimmed once it is done
			tcol := ui.theme_color("soft text")
			if depth > 0 { tcol = busy ? ui.theme_color("text") : ui.theme_color("weak text") }
			ground := selected ? session_ground() : ui.theme_color("bar background")
			if selected { tcol = inked(b, ui.readable(ui.theme_color("bright text"), ground, READABLE_TEXT)) }
			quiet := selected ? inked(b, ui.readable(ui.theme_color("weak text"), ground, READABLE_QUIET)) : ui.theme_color("faint text")   // (the folder, the age)
			title_style := ui.Style_Mod{font_size = math.round(em * (depth > 0 ? FS_NOTE : FS_LABEL))}
			if project {
				ui.next({width = ui.fill(), height = ui.pct(1), axis = .Y})
				if ui.column(id = "###words") {
					ui.spacer(ui.fill())
					title_style.height = ui.px(math.round(em * 1.3))
					if renaming_at(app, s.id, .Side) { rename_in_place(app, em, title_style.font_size.?, math.round(em * 1.3)) } else { text_found("t", title, ui.line_edit_string(&app.sidebar.search), tcol, title_style, ui.fill()) }
					where_ := s.directory != "" ? base_name(s.directory) : i18n.tr("(no folder)")
					if session_unseen(app, s) && s.outcome != "succeeded" && s.outcome != "" { where_ = fmt.tprintf("%s · %s", where_, s.outcome) }
					text("p", ellipsize(where_, SIDE_PROJECT_CHARS), quiet, ui.Style_Mod{font_size = math.round(em * FS_CAPTION), height = ui.px(math.round(em * 1.1))}, ui.fill())
					ui.spacer(ui.fill())
				}
			} else if renaming_at(app, s.id, .Side) {
				rename_in_place(app, em, title_style.font_size.?, math.round(em * 1.6))
			} else {
				text_found("t", title, ui.line_edit_string(&app.sidebar.search), tcol, title_style, ui.fill())
			}
			ui.space(ui.SPACE_2)
			if len(kids) > 0 {
				running := 0
				for k in kids { if app.busy[app.sessions[k].id] or_else false { running += 1 } }
				sub_list = sub_toggle(app, s.id, len(kids), running, em)
				ui.space(ui.SPACE_1)
			}
			text("a", age_text(now, s.updated), quiet, ui.Style_Mod{font = app.mono, font_size = math.round(em * FS_CAPTION)})
			ui.space(ui.SPACE_3)
		}
		ui.space(ui.SPACE_2)
	}
	if sub_list {
		LIMIT :: 30
		// the running ones first, then the finished ones (newest first)
		order := make([dynamic]int, 0, len(kids), context.temp_allocator)
		for k in kids { if app.busy[app.sessions[k].id] or_else false { append(&order, k) } }
		for k in kids { if !(app.busy[app.sessions[k].id] or_else false) { append(&order, k) } }
		for k, i in order {
			if i == LIMIT {
				ui.next({width = ui.fill(), height = ui.px(em * 1.6), axis = .X, cross = .Center})
				if ui.row(.Center, id = fmt.tprintf("###more_%s", s.id)) {
					ui.spacer(ui.px(em * 2.6))
					text("m", fmt.tprintf(i18n.tr(len(kids) - LIMIT, "… %d more: open the session and use its sub-agents menu", "… %d more: open the session and use its sub-agents menu"), len(kids) - LIMIT), ui.theme_color("faint text"), ui.Style_Mod{font_size = math.round(em * FS_SMALL)}, ui.fill())
				}
				break
			}
			session_item(app, &app.sessions[k], em, now, depth + 1)
		}
	}
}

session_menu :: proc(app: ^App, em: f32) {
	key := "session_menu"
	if ui.menu(key, em * 17) {
		if ui.menu_item(i18n.tr("Open"), icon = lucide.EXTERNAL_LINK).clicked { open_root(app, app.sidebar.menu_session) }
		if ui.menu_item(i18n.tr("Rename…"), command_shortcut(app, "session.rename"), icon = lucide.PENCIL).clicked { rename_open(app, app.sidebar.menu_session) }
		if ui.menu_item(i18n.tr("Fork"), icon = lucide.GIT_FORK).clicked { fork_session(app, app.sidebar.menu_session, "") }
		if ui.menu_item(i18n.tr("Move to a folder…"), icon = lucide.FOLDER_INPUT).clicked { session_move_pick(app, app.sidebar.menu_session) }
		if s := find_session(app, app.sidebar.menu_session); s != nil { project_icon_items(app, s.project) }
		archived := session_is_archived(app, app.sidebar.menu_session)
		if ui.menu_item(archived ? i18n.tr("Unarchive") : i18n.tr("Archive"), icon = archived ? lucide.ARCHIVE_RESTORE : lucide.ARCHIVE).clicked { session_archive(app, app.sidebar.menu_session, !archived) }
		if ui.menu_item(i18n.tr("What it changed"), icon = lucide.FILE_DIFF).clicked { changes_open(app, app.sidebar.menu_session) }
		if !app.cx.no_schedules && ui.menu_item(i18n.tr("Schedules"), icon = lucide.CALENDAR_CLOCK).clicked { schedules_open(app, app.sidebar.menu_session) }
		if ui.menu_item(i18n.tr("Export…"), icon = lucide.DOWNLOAD).clicked { session_export(app, app.sidebar.menu_session) }
		if ui.menu_item(i18n.tr("Export without the text…"), icon = lucide.FILE_DOWN).clicked { session_export(app, app.sidebar.menu_session, redacted = true) }
		ui.menu_separator()
		if ui.menu_item(i18n.tr("Copy session ID"), icon = lucide.HASH).clicked { session_id_copy(app, app.sidebar.menu_session) }
		if s := find_session(app, app.sidebar.menu_session); s != nil {
			if ui.menu_item(i18n.tr("Copy folder path"), icon = lucide.CLIPBOARD_COPY).clicked { clip_set(s.directory) }
			if ui.menu_item(i18n.tr("Show the folder"), icon = lucide.FOLDER_OPEN).clicked { reveal_path(s.directory) }
			if ui.menu_item(i18n.tr("Open a terminal here"), icon = lucide.TERMINAL).clicked { terminal_open(s.directory) }
		}
		ui.menu_separator()
		if ui.menu_item(i18n.tr("Delete…"), icon = lucide.TRASH_2).clicked { delete_ask(app, app.sidebar.menu_session) }
	}
}

// The question before a session is deleted (the toolkit's confirmation; its options are cloned as it opens).
delete_ask :: proc(app: ^App, id: string) {
	delete(app.sidebar.delete_id)
	app.sidebar.delete_id = strings.clone(id)
	title := i18n.tr("this session")
	if s := find_session(app, id); s != nil { title = s.title }
	ui.confirm_open(DELETE_VIEW, {title = i18n.tr("Delete the session?"), note = fmt.tprintf(i18n.tr("“%s” and its messages will be removed from the server."), title), act = i18n.tr("Delete"), width_em = 26})
}

// Its answer, in a build of the main window.
delete_answer :: proc(app: ^App) {
	pane := main_pane(app)
	if ui.confirm_answer(DELETE_VIEW) != .Confirmed || app.sidebar.delete_id == "" { return }
	delete_session(app, app.sidebar.delete_id)
	if app.sidebar.delete_id == pane.chat.id { new_session(app) }
	nav_forget(app, app.sidebar.delete_id)
	refresh_soon(app)
}

// A project's menu (a right click on its header in the sidebar).
project_menu :: proc(app: ^App, em: f32) {
	if ui.menu("project_menu", em * 17) { project_icon_items(app, app.sidebar.menu_project) }
}

