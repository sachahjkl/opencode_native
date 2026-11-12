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


SIDEBAR_W_DEFAULT     :: 290
SIDEBAR_W_MIN         :: 200
SIDEBAR_W_MAX         :: 520

HEX_SUB_OFF_TITLE     :: 0x7a7a7aff

////////////////////////////////
// Sidebar

Item_Draw :: struct { selected: bool }

item_draw :: proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
	d := (^Item_Draw)(user)
	// the one shown: a ground of the accent, nothing more (its mark and its lamp say the rest); under the pointer, a lighter
	// one. Square: a row's ground runs from edge to edge, row under row.
	// (flush: across the whole row of the sidebar, its indent included, not from where the item begins)
	r := b.rect
	if b.parent != nil { r.min.x, r.max.x = b.parent.rect.min.x, b.parent.rect.max.x }
	if d.selected {
		draw.rect(dc, r, chosen_ground())
	} else if b.hot_t > FADE_VISIBLE {
		draw.rect(dc, r, with_alpha(hex(HEX_TEXT), ITEM_HOVER_TINT * b.hot_t))
	}
}

sidebar :: proc(app: ^App, em: f32) {
	ui.next({width = ui.px(app.sidebar.width * ui.scale()), height = ui.fill(), axis = .Y, bg = hex(HEX_BG1), radius = 0})   // (square: its rounded corner notched the bar's edge)
	if ui.column(flags = {.Draw_Background}, id = "###sidebar") {
		ui.spacer(ui.px(em * 1.0))
		pad_row :: proc(em: f32) { ui.spacer(ui.px(em * 0.75)) }
		// new session + refresh
		ui.next({width = ui.fill(), height = ui.children_sum(), axis = .X, cross = .Center})
		if ui.row(.Center, id = "###side_top") {
			pad_row(em)
			if bevel_button("###new", "New session", lucide.PLUS, .Accent, ui.fill()).clicked { new_session(app) }
			ui.spacer(ui.px(em * 0.45))
			if bevel_button("###refresh", "", lucide.REFRESH_CW, .Normal).clicked { refresh_sessions(app) }
			pad_row(em)
		}
		ui.spacer(ui.px(em * 0.7))
		// search well
		ui.next({width = ui.fill(), height = ui.children_sum(), axis = .X})
		if ui.row(id = "###side_search") {
			pad_row(em)
			ui.next({width = ui.fill(), height = ui.px(math.round(em * FIELD_H_EM)), axis = .X, cross = .Center})
			if well("###search_well", .X, radius = 7) {
				ui.spacer(ui.px(em * 0.5))
				glyph(lucide.SEARCH, hex(HEX_FAINT), math.round(em * ICON_SMALL))
				if ui.tags("bare") {
					ui.next({width = ui.fill(), height = ui.pct(1), text_pad = em * 0.3})
					ui.line_edit("###search", &app.sidebar.search, "Search sessions", clearable = true)
				}
			}
			pad_row(em)
		}
		ui.spacer(ui.px(em * 0.45))
		ui.next({width = ui.fill(), height = ui.children_sum(), axis = .X})
		if ui.row(id = "###side_modes") {
			pad_row(em)
			sidebar_mode_switch(app, em)
			pad_row(em)
		}
		ui.spacer(ui.px(em * 0.5))
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
	if !app.sessions_loaded {
		ui.spacer(ui.px(em))
		ui.next({width = ui.fill(), height = ui.px(em * 2), text_align = .Center})
		if ui.tags("weak") { ui.label(online(app) ? "Loading…" : "Connecting…") }
		return
	}
	sections := sidebar_view(app, ui.field_string(&app.sidebar.search), sidebar_hold_wanted(app, ui.parent_box()))
	kids := app.sidebar.kept.kids   // (the sub-agents of each session, listed under it unless the list is flat)
	mode := app.prefs.sidebar_mode
	now := now_epoch_ms()
	ui.spacer(ui.px(em * 0.4))
	// Only the rows near the view are built (the toolkit's lazy column, as the conversation's): a header or a session
	// each, the others stand as their height. Hundreds of sessions were built and drawn at every frame.
	ui.next({width = ui.fill(), height = ui.children_sum(), axis = .Y})
	if ui.column(id = "###rows") {
		lz := ui.lazy_begin()
		gap := false   // (between a section's last session and the next section)
		for &sec in sections {
			folded := app.sidebar.folded[sec.key] or_else sec.shut
			if ui.lazy_item(lz, sec.lazy_id) {
				if gap { ui.spacer(ui.px(em * 0.5)) }
				if sec.title != "" { inbox_header(app, &sec, folded, em) } else { group_header(app, &sec, folded, em) }
			}
			gap = !folded
			if folded { continue }
			for i in sec.items {
				s := &app.sessions[i]
				if ui.lazy_item(lz, s.lazy_id, always = s.id == app.chat.id) {
					session_item(app, s, em, now, 0, app.prefs.subagents == "nested" ? children_of(app, s.id, kids) : nil, project = mode == .Inbox)
				}
			}
		}
	}
	ui.spacer(ui.px(em))
	ui.next({width = ui.fill(), height = ui.children_sum(), axis = .X})
	if ui.row(id = "###side_settings") {
		ui.spacer(ui.px(em * 0.6))
		if glyph_label_button(app, "###open_settings", "Settings", em).clicked { settings_open(app) }
	}
	ui.spacer(ui.px(em))
	session_menu(app, em)
	project_menu(app, em)
}

// A group's header: folder, name, count, "+".
@(private = "file")
group_header :: proc(app: ^App, gr: ^Side_Section, folded: bool, em: f32) {
	gkey := gr.key
	ui.next({width = ui.fill(), height = ui.px(math.round(em * 2)), axis = .X, cross = .Center})
	hdr := ui.build_box({.Clickable, .Hot_Within}, fmt.tprintf("###g%d", gkey))
	hs := ui.signal(hdr)
	if hs.clicked { app.sidebar.folded[gkey] = !folded }
	// a right click: its project's menu (its icon)
	if hs.right_clicked && len(gr.items) > 0 {
		delete(app.sidebar.menu_project)
		app.sidebar.menu_project = strings.clone(app.sessions[gr.items[0]].project)
		ui.ctx_menu_open(ui.key_from_string(0, "project_menu"), ui.mouse_pos(), hdr.key)
	}
	if ui.parent(hdr) {
		ui.spacer(ui.px(em * 0.8))
		glyph(folded ? lucide.CHEVRON_RIGHT : lucide.CHEVRON_DOWN, hex(HEX_FAINT), math.round(em * ICON_TINY), em * 0.9)
		// the project's logo, else a folder
		logo := len(gr.items) > 0 ? project_logo(app, app.sessions[gr.items[0]].project) : nil
		if !logo_of(app, "###glogo", logo, math.round(em * 1.25)) { glyph(lucide.FOLDER, accent(), math.round(em * ICON_REGULAR)) }
		ui.spacer(ui.px(em * 0.35))
		name := gr.dir != "" ? base_name(gr.dir) : "(no folder)"
		text("n", strings.to_upper(name, context.temp_allocator), hs.hovering ? hex(HEX_TEXT) : hex(HEX_WEAK), ui.Style_Mod{font = app.mono_bold, font_size = math.round(em * FS_SMALL)})
		ui.spacer(ui.px(em * 0.4))
		text("c", fmt.tprintf("%d", len(gr.items)), hex(HEX_FAINT), ui.Style_Mod{font = app.mono, font_size = math.round(em * FS_SMALL)})
		ui.spacer(ui.fill())
		// "+": always there (built only while the header was hovered, it vanished as soon as the pointer moved onto
		// it: the header is no longer the box under the pointer), shown while the header is hot (Hot_Within keeps it
		// hot over its button)
		plus_col := hdr.hot_t > FADE_VISIBLE ? hex(HEX_WEAK) : Color{0, 0, 0, 0.001}
		if glyph_button("###gadd", lucide.PLUS, math.round(em * 1.5), plus_col).clicked {
			new_session(app)
			delete(app.chat.new_dir, app.chat.alloc)
			app.chat.new_dir = strings.clone(gr.dir, app.chat.alloc)
		}
		ui.spacer(ui.px(em * 0.5))
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
	c := hex(SESSION_BADGE_HEX[session_badge_index(s.id)])
	ui.next({width = ui.px(size), height = ui.px(size), bg = with_alpha(c, SESSION_BADGE_ALPHA), fg = c, radius = math.round(size * 0.3 * corners()),
		text_align = .Center, font = ui.styled_face(app.font, true, false), font_size = math.round(size * 0.55), text_pad = 0})
	ui.build_box({.Draw_Background, .Draw_Text, .No_Text_Trunc}, fmt.tprintf("%s###badge", letter))
}

// Which colour of the palette a session's id picks (FNV-1a: the same id, the same colour, on every machine).
session_badge_index :: proc(id: string) -> int {
	h: u32 = 2166136261
	for i in 0 ..< len(id) { h = (h ~ u32(id[i])) * 16777619 }
	return int(h % u32(len(SESSION_BADGE_HEX)))
}

session_item :: proc(app: ^App, s: ^Session_Info, em: f32, now: f64, depth := 0, kids: []int = nil, project := false) {
	selected := s.id == app.chat.id
	sub_list := false
	ui.next({width = ui.fill(), height = ui.px(math.round(em * (project ? SIDE_INBOX_ROW_EM : depth > 0 ? 2.0 : 2.3))), axis = .X, cross = .Center})
	if ui.row(.Center, id = fmt.tprintf("###r_%s", s.id)) {
		ui.spacer(ui.px(em * (0.5 + 1.1 * f32(depth))))
		ui.next({width = ui.fill(), height = ui.pct(1), axis = .X, cross = .Center})
		b := ui.build_box({.Clickable, .Focusable}, "###item")
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
			ui.ctx_menu_open(ui.key_from_string(0, "session_menu"), b.rect.min + sig.mouse)
			delete(app.sidebar.menu_session)
			app.sidebar.menu_session = strings.clone(s.id)
		}
		if ui.parent(b) {
			ui.spacer(ui.px(em * (s.parent != "" && depth == 0 ? 1.6 : 0.95)))
			if depth == 0 {
				session_badge(app, s, math.round(em * (project ? SESSION_BADGE_INBOX_EM : SESSION_BADGE_EM)), em)
				ui.spacer(ui.px(em * 0.55))
			}
			busy := app.busy[s.id] or_else false
			if depth > 0 {
				// a sub-agent: its state as a lamp, its agent in its colour
				st, _ := state_of_word(s.outcome)
				if busy { st = .Running; animate(app) }
				state_mark("###st", sub_state_color(st), busy, size = em * 0.75)
				ui.spacer(ui.px(em * 0.3))
				text("ag", s.agent, hex(HEX_FAINT), ui.Style_Mod{font = app.mono_bold, font_size = math.round(em * FS_CAPTION)})
				ui.spacer(ui.px(em * 0.35))
			} else if session_waits(app, s.id) {   // (a run that cannot go on without the person)
				session_lamp("###waits", LAMP_WAITS, em)
				ui.spacer(ui.px(em * 0.35))
			} else if busy {
				session_lamp("###busy", LAMP_WORKING, em)
				ui.spacer(ui.px(em * 0.35))
			} else if session_in_background(app, s.id) {   // (at rest, its commands still running: steady)
				session_lamp("###bg", LAMP_BACKGROUND, em)
				ui.spacer(ui.px(em * 0.35))
			} else if session_unseen(app, s) {   // (over and not seen: how it ended, the lamp without its light)
				st, _ := state_of_word(s.outcome)
				session_lamp_off("###unseen", sub_state_color(st), em)
				ui.spacer(ui.px(em * 0.35))
			}
			title := s.title != "" ? s.title : "Untitled"
			// a sub-agent: lit while it runs, dimmed once it is done
			tcol := hex(HEX_TEXT_SOFT)
			if depth > 0 { tcol = busy ? hex(HEX_TEXT) : hex(HEX_SUB_OFF_TITLE) }
			ground := selected ? chosen_ground() : hex(HEX_BG1)
			if selected { tcol = ui.readable(hex(HEX_BRIGHT), ground, READABLE_TEXT) }
			quiet := selected ? ui.readable(hex(HEX_WEAK), ground, READABLE_QUIET) : hex(HEX_FAINT)   // (the folder, the age)
			title_style := ui.Style_Mod{font_size = math.round(em * (depth > 0 ? FS_NOTE : FS_LABEL))}
			if project {
				ui.next({width = ui.fill(), height = ui.pct(1), axis = .Y})
				if ui.column(id = "###words") {
					ui.spacer(ui.fill())
					title_style.height = ui.px(math.round(em * 1.3))
					if renaming_at(app, s.id, .Side) { rename_in_place(app, em, title_style.font_size.?, math.round(em * 1.3)) } else { text_found("t", title, ui.field_string(&app.sidebar.search), tcol, title_style, ui.fill()) }
					where_ := s.directory != "" ? base_name(s.directory) : "(no folder)"
					if session_unseen(app, s) && s.outcome != "succeeded" && s.outcome != "" { where_ = fmt.tprintf("%s · %s", where_, s.outcome) }
					text("p", ellipsize(where_, SIDE_PROJECT_CHARS), quiet, ui.Style_Mod{font_size = math.round(em * FS_CAPTION), height = ui.px(math.round(em * 1.1))}, ui.fill())
					ui.spacer(ui.fill())
				}
			} else if renaming_at(app, s.id, .Side) {
				rename_in_place(app, em, title_style.font_size.?, math.round(em * 1.6))
			} else {
				text_found("t", title, ui.field_string(&app.sidebar.search), tcol, title_style, ui.fill())
			}
			ui.spacer(ui.px(em * 0.4))
			if len(kids) > 0 {
				running := 0
				for k in kids { if app.busy[app.sessions[k].id] or_else false { running += 1 } }
				sub_list = sub_toggle(app, s.id, len(kids), running, em)
				ui.spacer(ui.px(em * 0.35))
			}
			text("a", age_text(now, s.updated), quiet, ui.Style_Mod{font = app.mono, font_size = math.round(em * FS_CAPTION)})
			ui.spacer(ui.px(em * 0.7))
		}
		ui.spacer(ui.px(em * 0.5))
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
					text("m", fmt.tprintf("… %d more: open the session and use its sub-agents menu", len(kids) - LIMIT), hex(HEX_FAINT), ui.Style_Mod{font_size = math.round(em * FS_SMALL)}, ui.fill())
				}
				break
			}
			session_item(app, &app.sessions[k], em, now, depth + 1)
		}
	}
}

session_menu :: proc(app: ^App, em: f32) {
	key := ui.key_from_string(0, "session_menu")
	if ui.ctx_menu(key, em * 17) {
		if ui.menu_item("Open", icon = lucide.EXTERNAL_LINK).clicked { open_root(app, app.sidebar.menu_session) }
		if ui.menu_item("Rename…", "F2", icon = lucide.PENCIL).clicked { rename_open(app, app.sidebar.menu_session) }
		if ui.menu_item("Fork", icon = lucide.GIT_FORK).clicked { fork_session(app, app.sidebar.menu_session, "") }
		if ui.menu_item("Move to a folder…", icon = lucide.FOLDER_INPUT).clicked { session_move_pick(app, app.sidebar.menu_session) }
		if s := find_session(app, app.sidebar.menu_session); s != nil { project_icon_items(app, s.project) }
		archived := session_is_archived(app, app.sidebar.menu_session)
		if ui.menu_item(archived ? "Unarchive" : "Archive", icon = archived ? lucide.ARCHIVE_RESTORE : lucide.ARCHIVE).clicked { session_archive(app, app.sidebar.menu_session, !archived) }
		if ui.menu_item("What it changed", icon = lucide.FILE_DIFF).clicked { changes_open(app, app.sidebar.menu_session) }
		if !app.cx.no_schedules && ui.menu_item("Schedules", icon = lucide.CALENDAR_CLOCK).clicked { schedules_open(app, app.sidebar.menu_session) }
		if ui.menu_item("Export…", icon = lucide.DOWNLOAD).clicked { session_export(app, app.sidebar.menu_session) }
		if ui.menu_item("Export without the text…", icon = lucide.FILE_DOWN).clicked { session_export(app, app.sidebar.menu_session, redacted = true) }
		ui.menu_separator()
		if ui.menu_item("Copy session ID", icon = lucide.HASH).clicked { clip_set(app.sidebar.menu_session) }
		if s := find_session(app, app.sidebar.menu_session); s != nil {
			if ui.menu_item("Copy folder path", icon = lucide.CLIPBOARD_COPY).clicked { clip_set(s.directory) }
			if ui.menu_item("Show the folder", icon = lucide.FOLDER_OPEN).clicked { reveal_path(s.directory) }
			if ui.menu_item("Open a terminal here", icon = lucide.TERMINAL).clicked { terminal_open(s.directory) }
		}
		ui.menu_separator()
		if ui.menu_item("Delete…", icon = lucide.TRASH_2).clicked {
			delete(app.sidebar.delete_id)
			app.sidebar.delete_id = strings.clone(app.sidebar.menu_session)
			app.cx.open[.Delete] = true
		}
	}
}

// A project's menu (a right click on its header in the sidebar).
project_menu :: proc(app: ^App, em: f32) {
	if ui.ctx_menu(ui.key_from_string(0, "project_menu"), em * 17) { project_icon_items(app, app.sidebar.menu_project) }
}

delete_dialog :: proc(app: ^App, em: f32) {
	if ui.modal("delete", em * 26, &app.cx.open[.Delete]) {
		dialog_backdrop()
		ui.spacer(ui.px(em))
		ui.next({width = ui.fill(), height = ui.children_sum(), axis = .X})
		if ui.row() {
			ui.spacer(ui.px(em * 1.2))
			ui.next({width = ui.fill(), height = ui.children_sum(), axis = .Y})
			if ui.column() {
				title := "this session"
				if s := find_session(app, app.sidebar.delete_id); s != nil { title = s.title }
				ui.next({width = ui.fill(), height = ui.px(em * 2), font_size = math.round(em * FS_HEADING)})
				ui.label("Delete the session?###dt")
				ui.next({width = ui.fill(), flags = {.Text_Wrap}})
				if ui.tags("weak") { ui.paragraph(fmt.tprintf("“%s” and its messages will be removed from the server.###dp", label_safe(title))) }
				ui.spacer(ui.px(em * 1.2))
				ui.next({width = ui.fill(), height = ui.children_sum(), axis = .X})
				if ui.row() {
					ui.spacer(ui.fill())
					if bevel_button("###cancel", "Cancel", "", .Normal).clicked { app.cx.open[.Delete] = false }
					ui.spacer(ui.px(em * 0.6))
					if bevel_button("###confirm", "Delete", lucide.TRASH_2, .Danger).clicked {
						delete_session(app, app.sidebar.delete_id)
						if app.sidebar.delete_id == app.chat.id { new_session(app) }
						nav_forget(app, app.sidebar.delete_id)
						app.cx.open[.Delete] = false
						refresh_soon(app)
					}
				}
				ui.spacer(ui.px(em * 1.2))
			}
			ui.spacer(ui.px(em * 1.2))
		}
	}
}
