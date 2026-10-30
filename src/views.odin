// The window: an integrated title bar, the sessions on the left (grouped by project folder), the conversation and its
// composer on the right, a status bar along the bottom.
package occ

import "core:fmt"
import "core:hash"
import "core:math"
import "core:strings"
import "core:time"
import "gt:draw"
import "gt:ui"


build_ui :: proc(app: ^App) {
	em := ui.font_size()
	global_keys(app)
	ui.next({width = ui.fill(), height = ui.fill(), axis = .Y})
	if ui.column(id = "###root") {
		title_bar(app, em)
		ui.next({width = ui.fill(), height = ui.fill()})
		if ui.row(id = "###body") {
			sidebar(app, em)
			room := ui.parent_box().size.x / ui.scale()
			ui.next({height = ui.fill()})
			ui.splitter("###side_split", .X, &app.sidebar_w, 200, 520, {default_size = 290, total = room, min_other = 420})
			conversation(app, em)
		}
		status_bar(app, em)
	}
	delete_dialog(app, em)
	setup_dialog(app, em)
	server_dialog(app, em)
	settings_dialog(app, em)
	image_viewer(app, em)
	stats_dialog(app, em)
}

app_menu :: proc(app: ^App, key: ui.Key, em: f32) {
	if ui.ctx_menu(key, em * 16) {
		if ui.menu_item("New session", "Ctrl+N").clicked { new_session(app) }
		if ui.menu_item("Refresh", "F5").clicked {
			refresh_sessions(app)
			if app.chat.id != "" { load_messages(app, app.chat.id) }
		}
		if ui.menu_item("Settings…", "Ctrl+,").clicked { settings_open(app) }
		if ui.menu_item("Add a server…").clicked { server_edit_open(app, -1) }
		if ui.menu_item("Session statistics", "Ctrl+I", enabled = app.chat.id != "").clicked { stats_open(app) }
		if ui.menu_item("Sub-agent sessions in the list", "", app.prefs.subagents == "flat").clicked { pref_set(app, "sidebar.subagents", app.prefs.subagents == "flat" ? "nested" : "flat") }
		ui.menu_separator()
		if ui.menu_item("Setup…").clicked { setup_open(app) }
		if ui.menu_item("About opencode native").clicked { setup_open(app) }
		ui.menu_separator()
		if ui.menu_item("Quit", "Alt+F4").clicked { app.quit = true }
	}
}

global_keys :: proc(app: ^App) {
	if ui.key_press(.N, {.Ctrl}) { new_session(app) }
	find_keys(app)
	if ui.key_press(.Comma, {.Ctrl}) { settings_open(app) }
	if app.chat.id != "" && ui.key_press(.I, {.Ctrl}) { stats_open(app) }
	if ui.key_press(.F5) {
		refresh_sessions(app)
		if app.chat.id != "" { load_messages(app, app.chat.id) }
	}
	if app.chat.busy && ui.key_press(.Escape, {.Ctrl}) { interrupt_session(app, app.chat.id) }
	if back_target(app) != "" && ui.key_press(.Left, {.Alt}) { go_back(app) }
}

new_session :: proc(app: ^App) {
	dir := ""
	if s := find_session(app, app.chat.id); s != nil { dir = s.directory } else if len(app.sessions) > 0 { dir = app.sessions[0].directory }
	chat_reset(&app.chat)
	app.chat.loaded = true
	app.stick_bottom = true
	app.new_dir = strings.clone(dir, app.chat.alloc)
	permissions_clear(app)
}

////////////////////////////////
// Title bar

@(private = "file")
Bar_Draw :: struct { top, bottom: Color }

@(private = "file")
bar_draw :: proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
	d := (^Bar_Draw)(user)
	r := b.rect
	draw.rect_corners(dc, r, {d.top, d.bottom, d.top, d.bottom}, {})
	p := px1()
	draw.rect(dc, {r.min, {r.max.x, r.min.y + p}}, {1, 1, 1, 0.05})
}

title_bar :: proc(app: ^App, em: f32) {
	h := max(math.round(em * 2.6), math.round(34 * ui.scale()))
	ui.next({width = ui.fill(), height = ui.px(h)})
	if ui.title_bar("###titlebar") {
		b := ui.parent_box()
		d := ui.frame_new(Bar_Draw)
		d^ = {hex(0x181818ff), hex(0x111111ff)}
		b.custom = bar_draw
		b.custom_user = d
		ui.spacer(ui.px(em * 0.4))
		msig := glyph_button("###appmenu", ICO_MENU, math.round(h * 0.78))
		menu_key := ui.key_from_string(0, "app_menu")
		if msig.clicked { ui.ctx_menu_open_rect(menu_key, msig.box.rect, msig.box.key) }
		app_menu(app, menu_key, em)
		ui.spacer(ui.px(em * 0.4))
		logo_box(app, "###tlogo", math.round(h * 0.6))
		ui.spacer(ui.px(em * 0.5))
		// the wordmark: "open" dim, "code" bright, in the mono face
		mono := ui.Style_Mod{font = app.mono_bold, font_size = math.round(em * 1.1)}
		text("w1", "open", hex(HEX_WEAK), mono)
		text("w2", "code", hex(HEX_TEXT), mono)
		ui.spacer(ui.px(em * 0.9))
		ui.next({height = ui.px(h * 0.55)})
		groove("###tg")
		ui.spacer(ui.px(em * 0.7))
		if !app.servers[app.server].local {   // another computer's server: its name first
			glyph(ICO_GLOBE, hex(HEX_CYAN), math.round(em * 0.8))
			ui.spacer(ui.px(em * 0.3))
			text("srv", server_name(app), hex(HEX_CYAN), ui.Style_Mod{font = app.mono_bold, font_size = math.round(em * 0.8)})
			if app.chat.id != "" { text("srvsep", "  /  ", hex(HEX_FAINT), ui.Style_Mod{font_size = math.round(em * 0.92)}) }
		}
		s := find_session(app, app.chat.id)
		if s == nil && app.chat.have_self { s = &app.chat.self }
		if s != nil {
			// the project's logo before its folder
			if logo_of(app, "###tproj", project_logo(app, s.project), math.round(h * 0.55)) { ui.spacer(ui.px(em * 0.45)) }
			text("dir", base_name(s.directory), hex(HEX_WEAK), ui.Style_Mod{font_size = math.round(em * 0.92)})
			text("sep", "  /  ", hex(HEX_FAINT), ui.Style_Mod{font_size = math.round(em * 0.92)})
			text("ttl", ellipsize(s.title, 70), hex(HEX_TEXT), ui.Style_Mod{font_size = math.round(em * 0.92)})
		}
		ui.spacer(ui.fill())
		if app.chat.busy {
			text("busy", "working", accent(), ui.Style_Mod{font = app.mono, font_size = math.round(em * 0.8)})
			ui.spacer(ui.px(em * 0.5))
			scanner("###tscan", accent(), math.round(em * 3), math.round(em * 0.75))
			ui.spacer(ui.px(em))
		}
		_, _ = ui.window_buttons()
	}
	// the bar's lower edge: a carved line
	edge_line("###tbedge")
}

base_name :: proc(path: string) -> string {
	p := strings.trim_right(path, "\\/")
	if i := strings.last_index_any(p, "\\/"); i >= 0 { return p[i + 1:] }
	return p
}

////////////////////////////////
// Sidebar

@(private = "file")
Item_Draw :: struct { selected: bool }

@(private = "file")
item_draw :: proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
	d := (^Item_Draw)(user)
	s := ui.scale()
	r := b.rect
	rad := 6 * s
	if d.selected {
		draw_well(dc, r, rad, hex(0x0b0b0bff))
		// the peach rail, glowing
		rail := Rect{{r.min.x + 3 * s, r.min.y + 7 * s}, {r.min.x + 6 * s, r.max.y - 7 * s}}
		draw.box_shadow(dc, rail, radii4(1.5 * s), 3 * s, with_alpha(accent(), 0.3))
		draw.rect(dc, rail, accent(), 1.5 * s)
	} else if b.hot_t > 0.01 {
		draw_bevel(dc, r, rad, hex(0x1c1c1cff), 0, b.active_t)
	}
}

@(private = "file")
Group :: struct { dir: string, items: [dynamic]int }

sidebar :: proc(app: ^App, em: f32) {
	ui.next({width = ui.px(app.sidebar_w * ui.scale()), height = ui.fill(), axis = .Y, bg = hex(HEX_BG1), radius = 0})   // (square: its rounded corner notched the bar's edge)
	if ui.column(flags = {.Draw_Background}, id = "###sidebar") {
		ui.spacer(ui.px(em * 1.0))
		pad_row :: proc(em: f32) { ui.spacer(ui.px(em * 0.75)) }
		// new session + refresh
		ui.next({width = ui.fill(), height = ui.children_sum(), axis = .X, cross = .Center})
		if ui.row(.Center, id = "###side_top") {
			pad_row(em)
			if bevel_button("###new", "New session", ICO_ADD, .Accent, ui.fill()).clicked { new_session(app) }
			ui.spacer(ui.px(em * 0.45))
			if bevel_button("###refresh", "", ICO_REFRESH, .Normal).clicked { refresh_sessions(app) }
			pad_row(em)
		}
		ui.spacer(ui.px(em * 0.7))
		// search well
		ui.next({width = ui.fill(), height = ui.children_sum(), axis = .X})
		if ui.row(id = "###side_search") {
			pad_row(em)
			ui.next({width = ui.fill(), height = ui.px(math.round(em * 2.1)), axis = .X, cross = .Center})
			if well("###search_well", .X, radius = 7) {
				ui.spacer(ui.px(em * 0.5))
				glyph(ICO_SEARCH, hex(HEX_FAINT), math.round(em * 0.8))
				if ui.tags("bare") {
					ui.next({width = ui.fill(), height = ui.pct(1), text_pad = em * 0.3})
					ui.line_edit("###search", &app.search, "Search sessions")
				}
			}
			pad_row(em)
		}
		ui.spacer(ui.px(em * 0.5))
		ui.next({width = ui.fill(), height = ui.px(6)})
		groove("###sg")

		ui.next({width = ui.fill(), height = ui.fill()})
		if ui.scroll_y("###sessions") {
			sessions_list(app, em)
		}
	}
	// the sidebar's right edge: a carved line
	edge_line("###side_edge", vertical = true)
}

sessions_list :: proc(app: ^App, em: f32) {
	if !app.sessions_loaded {
		ui.spacer(ui.px(em))
		ui.next({width = ui.fill(), height = ui.px(em * 2), text_align = .Center})
		if ui.tags("weak") { ui.label(app.online ? "Loading…" : "Connecting…") }
		return
	}
	q := strings.to_lower(ui.field_string(&app.search), context.temp_allocator)
	groups := make([dynamic]Group, context.temp_allocator)
	index := make(map[string]int, allocator = context.temp_allocator)
	// the sub-agents of each session (among those loaded), listed under it unless the list is flat
	kids := make(map[string][dynamic]int, allocator = context.temp_allocator)
	for s, i in app.sessions {
		if s.parent == "" { continue }
		list := kids[s.parent] or_else make([dynamic]int, context.temp_allocator)
		append(&list, i)
		kids[s.parent] = list
	}
	for s, i in app.sessions {
		if s.parent != "" && app.prefs.subagents != "flat" { continue }
		if q != "" && !strings.contains(strings.to_lower(s.title, context.temp_allocator), q) && !strings.contains(strings.to_lower(s.directory, context.temp_allocator), q) { continue }
		gi, ok := index[s.directory]
		if !ok {
			gi = len(groups)
			index[s.directory] = gi
			append(&groups, Group{dir = s.directory, items = make([dynamic]int, context.temp_allocator)})
		}
		append(&groups[gi].items, i)
	}
	now := now_epoch_ms()
	ui.spacer(ui.px(em * 0.4))
	for &gr, gi in groups {
		gkey := hash.fnv64a(transmute([]u8)gr.dir)
		folded := app.folded[gkey] or_else false
		// group header: folder, name, count, "+"
		ui.next({width = ui.fill(), height = ui.px(math.round(em * 2)), axis = .X, cross = .Center})
		hdr := ui.build_box({.Clickable, .Hot_Within}, fmt.tprintf("###g%d", gkey))
		hs := ui.signal(hdr)
		if hs.clicked { app.folded[gkey] = !folded }
		if ui.parent(hdr) {
			ui.spacer(ui.px(em * 0.8))
			glyph(folded ? ICO_RIGHT : ICO_DOWN, hex(HEX_FAINT), math.round(em * 0.6), em * 0.9)
			// the project's logo, else a folder
			logo := len(gr.items) > 0 ? project_logo(app, app.sessions[gr.items[0]].project) : nil
			if !logo_of(app, "###glogo", logo, math.round(em * 1.25)) { glyph(ICO_FOLDER, accent(), math.round(em * 0.85)) }
			ui.spacer(ui.px(em * 0.35))
			name := gr.dir != "" ? base_name(gr.dir) : "(no folder)"
			text("n", strings.to_upper(name, context.temp_allocator), hs.hovering ? hex(HEX_TEXT) : hex(HEX_WEAK), ui.Style_Mod{font = app.mono_bold, font_size = math.round(em * 0.78)})
			ui.spacer(ui.px(em * 0.4))
			text("c", fmt.tprintf("%d", len(gr.items)), hex(HEX_FAINT), ui.Style_Mod{font = app.mono, font_size = math.round(em * 0.75)})
			ui.spacer(ui.fill())
			// "+": always there (built only while the header was hovered, it vanished as soon as the pointer moved onto
			// it: the header is no longer the box under the pointer), shown while the header is hot (Hot_Within keeps it
			// hot over its button)
			plus_col := hdr.hot_t > 0.01 ? hex(HEX_WEAK) : Color{0, 0, 0, 0.001}
			if glyph_button("###gadd", ICO_ADD, math.round(em * 1.5), plus_col).clicked {
				new_session(app)
				delete(app.new_dir, app.chat.alloc)
				app.new_dir = strings.clone(gr.dir, app.chat.alloc)
			}
			ui.spacer(ui.px(em * 0.5))
		}
		if folded { continue }
		for i in gr.items {
			s := &app.sessions[i]
			session_item(app, s, em, now, 0, app.prefs.subagents == "nested" ? children_of(app, s.id, kids) : nil)
		}
		if gi < len(groups) - 1 { ui.spacer(ui.px(em * 0.5)) }
	}
	ui.spacer(ui.px(em))
	ui.next({width = ui.fill(), height = ui.children_sum(), axis = .X})
	if ui.row(id = "###side_settings") {
		ui.spacer(ui.px(em * 0.6))
		if glyph_label_button(app, "###open_settings", "Settings", em).clicked { settings_open(app) }
	}
	ui.spacer(ui.px(em))
	session_menu(app, em)
}

// A session of the sidebar; `depth` 1: a sub-agent listed under its parent. `kids`: its sub-agents (indices into
// app.sessions), listed under it when its toggle is open.
session_item :: proc(app: ^App, s: ^Session_Info, em: f32, now: f64, depth := 0, kids: []int = nil) {
	selected := s.id == app.chat.id
	sub_list := false
	ui.next({width = ui.fill(), height = ui.px(math.round(em * (depth > 0 ? 2.0 : 2.3))), axis = .X, cross = .Center})
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
		if sig.right_clicked {
			ui.ctx_menu_open(ui.key_from_string(0, "session_menu"), b.rect.min + sig.mouse)
			delete(app.menu_session)
			app.menu_session = strings.clone(s.id)
		}
		if ui.parent(b) {
			ui.spacer(ui.px(em * (s.parent != "" && depth == 0 ? 1.6 : 0.95)))
			busy := app.busy[s.id] or_else false
			if depth > 0 {
				// a sub-agent: its state as a lamp, its agent in its colour
				st := Sub_State.Unknown
				switch s.outcome {
				case "succeeded":   st = .Done
				case "failed":      st = .Failed
				case "interrupted": st = .Cancelled
				}
				if busy { st = .Running; app.animating = true }
				state_mark("###st", sub_state_color(st), busy, size = em * 0.75)
				ui.spacer(ui.px(em * 0.3))
				text("ag", s.agent, agent_color(s.agent), ui.Style_Mod{font = app.mono_bold, font_size = math.round(em * 0.7)})
				ui.spacer(ui.px(em * 0.35))
			} else if busy {
				lamp("###busy", accent(), pulse = true, size = em * 0.85)
				app.animating = true
				ui.spacer(ui.px(em * 0.35))
			}
			title := s.title != "" ? s.title : "Untitled"
			// a sub-agent: lit while it runs, dimmed once it is done
			tcol := hex(0xc8c8c8ff)
			if depth > 0 { tcol = busy ? hex(0xf4ead8ff) : hex(0x7a7a7aff) }
			if selected { tcol = hex(0xffffffff) }
			text("t", title, tcol, ui.Style_Mod{font_size = math.round(em * (depth > 0 ? 0.86 : 0.95))}, ui.fill())
			ui.spacer(ui.px(em * 0.4))
			if len(kids) > 0 {
				running := 0
				for k in kids { if app.busy[app.sessions[k].id] or_else false { running += 1 } }
				sub_list = sub_toggle(app, s.id, len(kids), running, em)
				ui.spacer(ui.px(em * 0.35))
			}
			text("a", rel_time(now, s.updated), hex(HEX_FAINT), ui.Style_Mod{font = app.mono, font_size = math.round(em * 0.74)})
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
					text("m", fmt.tprintf("… %d more: open the session and use its sub-agents menu", len(kids) - LIMIT), hex(HEX_FAINT), ui.Style_Mod{font_size = math.round(em * 0.78)}, ui.fill())
				}
				break
			}
			session_item(app, &app.sessions[k], em, now, depth + 1)
		}
	}
}

session_menu :: proc(app: ^App, em: f32) {
	key := ui.key_from_string(0, "session_menu")
	if ui.ctx_menu(key, em * 14) {
		if ui.menu_item("Open").clicked { open_root(app, app.menu_session) }
		if ui.menu_item("Copy session ID").clicked { clip_set(app.menu_session) }
		if s := find_session(app, app.menu_session); s != nil {
			if ui.menu_item("Copy folder path").clicked { clip_set(s.directory) }
		}
		ui.menu_separator()
		if ui.menu_item("Delete…").clicked {
			delete(app.delete_id)
			app.delete_id = strings.clone(app.menu_session)
			app.delete_open = true
		}
	}
}

delete_dialog :: proc(app: ^App, em: f32) {
	if ui.modal("delete", em * 26, &app.delete_open) {
		dialog_backdrop()
		ui.spacer(ui.px(em))
		ui.next({width = ui.fill(), height = ui.children_sum(), axis = .X})
		if ui.row() {
			ui.spacer(ui.px(em * 1.2))
			ui.next({width = ui.fill(), height = ui.children_sum(), axis = .Y})
			if ui.column() {
				title := "this session"
				if s := find_session(app, app.delete_id); s != nil { title = s.title }
				ui.next({width = ui.fill(), height = ui.px(em * 2), font_size = math.round(em * 1.15)})
				ui.label("Delete the session?###dt")
				ui.next({width = ui.fill(), flags = {.Text_Wrap}})
				if ui.tags("weak") { ui.paragraph(fmt.tprintf("“%s” and its messages will be removed from the server.###dp", title)) }
				ui.spacer(ui.px(em * 1.2))
				ui.next({width = ui.fill(), height = ui.children_sum(), axis = .X})
				if ui.row() {
					ui.spacer(ui.fill())
					if bevel_button("###cancel", "Cancel", "", .Normal).clicked { app.delete_open = false }
					ui.spacer(ui.px(em * 0.6))
					if bevel_button("###confirm", "Delete", ICO_DELETE, .Danger).clicked {
						delete_session(app, app.delete_id)
						if app.delete_id == app.chat.id { new_session(app) }
						app.delete_open = false
						app.refresh_due = true
					}
				}
				ui.spacer(ui.px(em * 1.2))
			}
			ui.spacer(ui.px(em * 1.2))
		}
	}
}

now_epoch_ms :: proc() -> f64 { return f64(time.time_to_unix_nano(time.now())) / 1e6 }

rel_time :: proc(now, t: f64) -> string {
	if t <= 0 { return "" }
	d := (now - t) / 1000
	switch {
	case d < 60:        return "now"
	case d < 3600:      return fmt.tprintf("%dm", int(d / 60))
	case d < 86400:     return fmt.tprintf("%dh", int(d / 3600))
	case d < 86400 * 7: return fmt.tprintf("%dd", int(d / 86400))
	}
	return fmt.tprintf("%dw", int(d / (86400 * 7)))
}

clock_time :: proc(t: f64) -> string {
	if t <= 0 { return "" }
	tm := time.unix(0, i64(t * 1e6))
	h, m, _ := time.clock_from_time(tm)
	// (UTC + the machine's offset: Windows' local time)
	off := local_offset_minutes()
	total := (h * 60 + m + off + 24 * 60) % (24 * 60)
	if !the_app.prefs.clock24 {
		hh := (total / 60) % 12
		return fmt.tprintf("%d:%02d %s", hh == 0 ? 12 : hh, total % 60, total / 60 < 12 ? "am" : "pm")
	}
	return fmt.tprintf("%02d:%02d", total / 60, total % 60)
}

////////////////////////////////
// Conversation

conversation :: proc(app: ^App, em: f32) {
	ui.next({width = ui.fill(), height = ui.fill(), axis = .Y, bg = hex(HEX_BG0), radius = 0})
	if ui.column(flags = {.Draw_Background}, id = "###main") {
		sc := ui.scale()
		// this frame's width, from the window (the box's own size is the last frame's: a resize would lag a frame behind):
		// the window less the sidebar, its edge and the splitter
		avail := f32(app.win.size.x) - app.sidebar_w * sc - 2 - math.round(5 * sc)
		if avail <= 0 { avail = 1000 * sc }
		app.column_w = 0
		col := max(240 * sc, min(app.prefs.column_w * sc, avail - em * 3))
		side := max(em * 1.5, (avail - col) * 0.5)
		app.column_w = col
		if app.chat.id != "" || app.chat.loaded {
			chat_header(app, em)
		}
		main := ui.parent_box()
		ui.next({width = ui.fill(), height = ui.fill()})
		sb := ui.prev_box("###chat")
		find_update(app, sb, em)
		if sb != nil {
			limit := max(0, sb.view_bounds.y - sb.size.y)
			// the scrollbar's drag (and the keyboard) moved it before this build (begin_build): up means let go of the bottom,
			// or following it would put it back at once and the thumb would stay stuck there
			if app.stick_bottom && sb.view_target.y < app.chat_target - 1 && sb.view_target.y < limit - 4 * ui.scale() { app.stick_bottom = false }
			if app.stick_bottom {
				sb.view_target.y = limit
				if app.stick_jump { sb.view_off.y = limit }
			}
		}
		if ui.scroll_y("###chat") {
			ui.next({width = ui.fill(), height = ui.children_sum(), axis = .X})
			if ui.row(id = "###lane") {
				ui.spacer(ui.px(side))
				ui.next({width = ui.px(col), height = ui.children_sum(), axis = .Y})
				if ui.column(id = "###col") {
					if app.chat.id == "" && !app.chat.loaded { empty_state(app, em) } else { messages(app, em) }
				}
			}
		}
		app.chat_sb = ui.prev_box("###chat")
		if sb != nil {
			// follow the bottom while the reader is there; scrolling up lets go of it
			limit := max(0, sb.view_bounds.y - sb.size.y)
			at_bottom := sb.view_target.y >= limit - 4 * ui.scale()
			// (with following off, only the first moments of a conversation just opened follow its bottom)
			follow := app.prefs.follow || ui.now_ms() - app.opened_ms < 2000
			if app.anchor == nil { app.stick_bottom = at_bottom && follow }   // (a part just toggled: it let go of the bottom)
			app.chat_target = sb.view_target.y
		}
		dock(app, em, side, col)
		// the find bar over the conversation's top-right corner, under the header
		find_bar(app, em, avail - em * 1.4, sb != nil ? sb.rect.min.y - main.rect.min.y + em * 0.6 : em * 4)
	}
}

chat_header :: proc(app: ^App, em: f32) {
	h := math.round(em * (app.chat.have_self && app.chat.self.parent != "" ? 4.3 : 3.3))   // (a sub-agent: a breadcrumb line above its title)
	ui.next({width = ui.fill(), height = ui.px(h), axis = .X, cross = .Center})
	if ui.row(.Center, id = "###hdr") {
		b := ui.parent_box()
		d := ui.frame_new(Bar_Draw)
		d^ = {hex(0x131313ff), hex(0x0d0d0dff)}
		b.custom = bar_draw
		b.custom_user = d
		ui.spacer(ui.px(em * 1.3))
		s := find_session(app, app.chat.id)
		if s == nil && app.chat.have_self { s = &app.chat.self }   // (a sub-agent, or an old session: not in the sidebar's list)
		if back := back_target(app); back != "" {
			// the way back up: to the session drilled down from, or the parent
			if bevel_button("###back", "", ICO_BACK, .Normal, ui.px(math.round(em * 2.1)), math.round(em * 2.1)).clicked { go_back(app) }
			ui.spacer(ui.px(em * 0.7))
		}
		if logo_of(app, "###hlogo", project_logo(app, chat_project(app)), math.round(em * 2.3)) { ui.spacer(ui.px(em * 0.7)) }
		ui.next({width = ui.fill(), height = ui.pct(1), axis = .Y})
		if ui.column(id = "###titles") {
			ui.spacer(ui.fill())
			if app.chat.have_self && app.chat.self.parent != "" {
				// breadcrumb: the parent, then this sub-agent
				ui.next({width = ui.fill(), height = ui.px(em * 1.2), axis = .X, cross = .Center})
				if ui.row(.Center, id = "###crumb") {
					parent := app.chat.parent_title != "" ? app.chat.parent_title : "parent session"
					ui.next({width = ui.children_sum(), height = ui.pct(1), axis = .X, cross = .Center, cursor = .Hand})
					pb := ui.build_box({.Clickable}, "###crumb_parent")
					ps := ui.signal(pb)
					if ps.clicked {
						if back_target(app) == app.chat.self.parent { go_back(app) } else { drill_down(app, strings.clone(app.chat.self.parent, context.temp_allocator)) }
					}
					if ui.parent(pb) {
						text("p", ellipsize(parent, 60), ps.hovering ? accent() : hex(HEX_WEAK), ui.Style_Mod{font_size = math.round(em * 0.78)})
					}
					text("s", "  ›  sub-agent", hex(HEX_FAINT), ui.Style_Mod{font_size = math.round(em * 0.78)})
				}
			}
			title := s != nil ? s.title : "New session"
			text("title", title != "" ? title : "Untitled", hex(0xffffffff), ui.Style_Mod{font_size = math.round(em * 1.12), height = ui.px(em * 1.5)}, ui.fill())
			dir := s != nil ? s.directory : app.new_dir
			text("dir", dir != "" ? dir : "default folder", hex(HEX_FAINT), ui.Style_Mod{font = app.mono, font_size = math.round(em * 0.76), height = ui.px(em * 1.2)}, ui.fill())
			ui.spacer(ui.fill())
		}
		c := &app.chat
		if len(c.children) > 0 {
			subagents_button(app, em)
			ui.spacer(ui.px(em * 0.6))
		}
		if c.tokens_in + c.tokens_out > 0 {
			if pill_button("###tok", fmt.tprintf("%s in · %s out", kfmt(c.tokens_in + c.cache_read), kfmt(c.tokens_out)), {}, ICO_BOLT).clicked { stats_open(app) }
			ui.spacer(ui.px(em * 0.4))
		}
		if c.cost > 0 {
			if pill_button("###cost", fmt.tprintf("$%.2f", c.cost), hex(HEX_GREEN)).clicked { stats_open(app) }
			ui.spacer(ui.px(em * 0.4))
		}
		if c.busy {
			ui.spacer(ui.px(em * 0.4))
			if bevel_button("###stop", "Stop", ICO_STOP, .Danger, height = math.round(em * 1.9)).clicked { interrupt_session(app, c.id) }
		}
		ui.spacer(ui.px(em * 1.2))
	}
	edge_line("###hdredge")
}

kfmt :: proc(v: f64) -> string {
	switch {
	case v >= 1e6: return fmt.tprintf("%.1fM", v / 1e6)
	case v >= 1e3: return fmt.tprintf("%.1fk", v / 1e3)
	}
	return fmt.tprintf("%d", int(v))
}

empty_state :: proc(app: ^App, em: f32) {
	ui.spacer(ui.px(em * 10))
	ui.next({width = ui.fill(), height = ui.px(em * 4), axis = .X, cross = .Center})
	if ui.row(.Center, id = "###logo") {
		ui.spacer(ui.fill())
		big := ui.Style_Mod{font = app.mono_bold, font_size = math.round(em * 3)}
		text("l1", "open", hex(HEX_FAINT), big)
		text("l2", "code", hex(HEX_TEXT), big)
		ui.spacer(ui.fill())
	}
	ui.next({width = ui.fill(), height = ui.px(em * 2), text_align = .Center})
	if ui.tags("weak") { ui.label(app.online ? "Pick a session on the left, or start a new one.###hint" : fmt.tprintf("Connecting to %s…###hint", server_base(app))) }
}

messages :: proc(app: ^App, em: f32) {
	c := &app.chat
	ui.spacer(ui.px(em * 1.2))
	subagent_banner(app, em)
	if c.older != "" {
		ui.next({width = ui.fill(), height = ui.children_sum(), axis = .X})
		if ui.row(id = "###older") {
			ui.spacer(ui.fill())
			if bevel_button("###load_older", c.loading ? "Loading…" : "Load earlier messages", ICO_HISTORY, .Normal).clicked { load_older(app) }
			ui.spacer(ui.fill())
		}
		ui.spacer(ui.px(em * 1.2))
	}
	if c.loading && len(c.messages) == 0 {
		ui.next({width = ui.fill(), height = ui.px(em * 2), text_align = .Center})
		if ui.tags("weak") { ui.label("Loading the conversation…###loading") }
	}
	for &m, i in c.messages {
		switch m.kind {
		case .User:        user_message(app, &m, em)
		case .Assistant:
			prev := i > 0 ? &c.messages[i - 1] : nil
			next := i + 1 < len(c.messages) ? &c.messages[i + 1] : nil
			assistant_message(app, &m, em, continues(prev, &m), next != nil && continues(&m, next) ? next : nil, prev)
		case .Synthetic:
			if m.sub_child != "" { subagent_result(app, &m, em) } else { note_line(app, &m, em, ICO_BOLT, m.text != "" ? first_line(m.text) : "synthetic message") }
		case .Shell:       note_line(app, &m, em, ICO_TERMINAL, fmt.tprintf("$ %s", m.text))
		case .Compaction:  note_line(app, &m, em, ICO_LIST, "Conversation compacted")
		case .Idle:        if i < len(c.messages) - 1 { turn_end(app, &m, em) }
		case .Other:
		}
	}
	if c.busy {
		ui.spacer(ui.px(em * 0.6))
		ui.next({width = ui.fill(), height = ui.px(em * 2), axis = .X, cross = .Center})
		if ui.row(.Center, id = "###working") {
			ui.spacer(ui.px(em * 0.4))
			text("w", "Working", accent(), ui.Style_Mod{font = app.mono, font_size = math.round(em * 0.85)})
			ui.spacer(ui.px(em * 0.7))
			scanner("###wl", accent(), math.round(em * 7), math.round(em * 0.9))
			ui.spacer(ui.fill())
			if ui.tags("weak") { text("hint", "Ctrl+Esc to stop", hex(HEX_FAINT), ui.Style_Mod{font_size = math.round(em * 0.8)}) }
		}
	}
	ui.spacer(ui.px(em * 2))
}

first_line :: proc(s: string) -> string {
	t := strings.trim_space(s)
	if i := strings.index_byte(t, '\n'); i >= 0 { return t[:i] }
	return t
}

note_line :: proc(app: ^App, m: ^Message, em: f32, icon: string, s: string) {
	ui.next({width = ui.fill(), height = ui.px(em * 1.9), axis = .X, cross = .Center})
	if ui.row(.Center, id = fmt.tprintf("###n_%s", m.id)) {
		glyph(icon, hex(HEX_FAINT), math.round(em * 0.8))
		ui.spacer(ui.px(em * 0.3))
		text("t", s, hex(HEX_FAINT), ui.Style_Mod{font_size = math.round(em * 0.85)}, ui.fill())
	}
	ui.spacer(ui.px(em * 0.6))
}

turn_end :: proc(app: ^App, m: ^Message, em: f32) {
	ui.next({width = ui.fill(), height = ui.px(em * 2), axis = .X, cross = .Center})
	if ui.row(.Center, id = fmt.tprintf("###e_%s", m.id)) {
		groove(across = true)
		if m.finish != "" && m.finish != "succeeded" {
			ui.spacer(ui.px(em * 0.5))
			col := m.finish == "interrupted" ? hex(HEX_YELLOW) : hex(HEX_RED)
			text("o", m.finish, col, ui.Style_Mod{font = app.mono, font_size = math.round(em * 0.75)})
			ui.spacer(ui.px(em * 0.5))
			groove(across = true)
		}
	}
	ui.spacer(ui.px(em * 0.8))
}

user_message :: proc(app: ^App, m: ^Message, em: f32) {
	ui.spacer(ui.px(em * 0.4))
	ui.next({width = ui.fill(), height = ui.children_sum(), axis = .Y})
	if plate(fmt.tprintf("###u_%s", m.id), top = 0x222222ff, bottom = 0x1a1a1aff, radius = 9, shadow = 8, rim = 0.09) {
		ui.spacer(ui.px(em * 0.75))
		ui.next({width = ui.fill(), height = ui.children_sum(), axis = .X})
		if ui.row(id = "###in") {
			ui.spacer(ui.px(em * 1.1))
			ui.next({width = ui.fill(), height = ui.children_sum(), axis = .Y})
			if ui.column() {
				ui.next({width = ui.fill(), height = ui.px(em * 1.4), axis = .X, cross = .Center})
				if ui.row(.Center, id = "###who") {
					glyph(ICO_PERSON, accent(), math.round(em * 0.8), em * 1.1)
					ui.spacer(ui.px(em * 0.2))
					text("you", "You", accent(), ui.Style_Mod{font = app.mono_bold, font_size = math.round(em * 0.8)})
					ui.spacer(ui.fill())
					text("at", clock_time(m.created), hex(HEX_FAINT), ui.Style_Mod{font = app.mono, font_size = math.round(em * 0.74)})
				}
				ui.spacer(ui.px(em * 0.35))
				runs := [1]ui.Rich_Run{{text = m.text, style = {color = hex(0xf2f2f2ff)}}}
				ui.next({width = ui.fill(), flags = {.Selectable}})
				ui.rich_paragraph("###text", runs[:])
				if len(m.images) > 0 {
					ui.spacer(ui.px(em * 0.6))
					sc := ui.scale()
					image_strip(app, "###imgs", m.images[:], 320 * sc, 220 * sc)
				}
			}
			ui.spacer(ui.px(em * 1.1))
		}
		ui.spacer(ui.px(em * 0.85))
	}
	ui.spacer(ui.px(em * 1.1))
}

agent_color :: proc(agent: string) -> Color {
	switch agent {
	case "build":   return accent()
	case "plan":    return hex(HEX_BLUE)
	case "general": return hex(HEX_PURPLE)
	case "explore": return hex(HEX_CYAN)
	}
	return hex(HEX_GREEN)
}

// `m` goes on from `prev` (an assistant step of the same agent and model, right after it): no header of its own.
continues :: proc(prev, m: ^Message) -> bool {
	return prev != nil && prev.kind == .Assistant && m.kind == .Assistant && (len(prev.parts) > 0 || prev.streaming) &&
		prev.agent == m.agent && prev.model == m.model
}

// A tool call drawn on the timeline (a sub-agent has its own card).
plain_tool :: proc(p: ^Part) -> bool { return p.kind == .Tool && p.tool_name != "subagent" && p.sub_agent == "" }

@(private = "file")
Who_Draw :: struct { col: Color, live: bool }

// `cont`: it goes on from the step before (no header); `next`: the step after when it goes on from this one.
assistant_message :: proc(app: ^App, m: ^Message, em: f32, cont := false, next: ^Message = nil, prev: ^Message = nil) {
	if len(m.parts) == 0 && !m.streaming { return }
	ui.next({width = ui.fill(), height = ui.children_sum(), axis = .Y})
	if ui.column(id = fmt.tprintf("###a_%s", m.id)) {
		// the speaker, once per run of steps: a rail in the agent's colour, agent, model, time
		if !cont {
		ui.next({width = ui.fill(), height = ui.px(em * 1.6), axis = .X, cross = .Center})
		if ui.row(.Center, id = "###who") {
			ui.next({width = ui.px(math.round(em * 0.5)), height = ui.px(math.round(em * 1.0))})
			rb := ui.build_box({}, "###al")
			wd := ui.frame_new(Who_Draw)
			wd^ = {agent_color(m.agent), m.streaming}
			rb.custom = proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
				d := (^Who_Draw)(user)
				s := ui.scale()
				c := draw.rect_center(b.rect)
				r := Rect{{c.x - 1.5 * s, b.rect.min.y}, {c.x + 1.5 * s, b.rect.max.y}}
				if d.live && the_app.prefs.glow {
					a := 0.15 + 0.15 * (0.5 + 0.5 * math.sin(f32(ui.now_ms()) * 0.006))
					draw.box_shadow(dc, r, radii4(1.5 * s), 4 * s, with_alpha(d.col, a))
				}
				draw.rect(dc, r, d.live ? d.col : with_alpha(d.col, 0.75), 1.5 * s)
			}
			rb.custom_user = wd
			if m.streaming { app.animating = true }
			ui.spacer(ui.px(em * 0.4))
			name := m.agent != "" ? m.agent : "assistant"
			text("ag", strings.to_upper(name[:1], context.temp_allocator), agent_color(m.agent), ui.Style_Mod{font = app.mono_bold, font_size = math.round(em * 0.8)})
			text("ag2", name[1:], agent_color(m.agent), ui.Style_Mod{font = app.mono_bold, font_size = math.round(em * 0.8)})
			if m.model != "" {
				text("dot", "  ·  ", hex(HEX_FAINT), ui.Style_Mod{font_size = math.round(em * 0.8)})
				text("md", m.model, hex(HEX_WEAK), ui.Style_Mod{font = app.mono, font_size = math.round(em * 0.78)})
			}
			ui.spacer(ui.fill())
			text("at", clock_time(m.created), hex(HEX_FAINT), ui.Style_Mod{font = app.mono, font_size = math.round(em * 0.74)})
		}
		ui.spacer(ui.px(em * 0.4))
		}
		for &p, i in m.parts {
			pid := fmt.tprintf("%s_%d", m.id, i)
			switch p.kind {
			case .Text:
				if len(p.text) > 0 {
					markdown(pid, string(p.text[:]), hex(0xdcdcdcff))
					ui.spacer(ui.px(em * 0.6))
				}
			case .Reasoning: reasoning_part(app, &p, pid, em)
			case .Tool:
				if !plain_tool(&p) { subagent_card(app, &p, pid, em); break }
				// consecutive calls share the timeline's rail, across the steps that go on from each other
				above := i > 0 ? plain_tool(&m.parts[i - 1]) : cont && prev != nil && len(prev.parts) > 0 && plain_tool(&prev.parts[len(prev.parts) - 1])
				below := i + 1 < len(m.parts) ? plain_tool(&m.parts[i + 1]) : next != nil && len(next.parts) > 0 && plain_tool(&next.parts[0])
				tool_part(app, &p, pid, em, above, below)
			}
		}
		if app.prefs.usage && !m.streaming && m.tokens_out > 0 && m.finish == "stop" {
			ui.next({width = ui.fill(), height = ui.px(em * 1.5), axis = .X, cross = .Center})
			if ui.row(.Center, id = "###foot") {
				text("tk", fmt.tprintf("%s in · %s out%s", kfmt(m.tokens_in + m.cache_read), kfmt(m.tokens_out), m.cost > 0 ? fmt.tprintf(" · $%.3f", m.cost) : ""), hex(HEX_FAINT), ui.Style_Mod{font = app.mono, font_size = math.round(em * 0.72)})
			}
		}
	}
	// a step that goes on in the next one stays close to it (the rail runs on when both meet on a tool call)
	if next == nil { ui.spacer(ui.px(em * 0.9)) }
}

part_open :: proc(app: ^App, id: string, default := false) -> bool {
	return app.expanded[hash.fnv64a(transmute([]u8)id)] or_else default
}

// Opens or closes a part from its header `head`: the header is the anchor of the scroll (frame keeps it where it was on
// screen, under the pointer, whatever grows or shrinks around it), and the conversation stops following its bottom.
part_toggle :: proc(app: ^App, id: string, head: ^ui.Box, default := false) {
	k := hash.fnv64a(transmute([]u8)id)
	app.expanded[k] = !(app.expanded[k] or_else default)
	app.anchor = head
	app.anchor_y = head.rect.min.y
	app.stick_bottom = false
}

@(private = "file")
Head_Draw :: struct { status: Tool_Status, open: bool }

@(private = "file")
head_draw :: proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
	if b.hot_t > 0.01 {
		r := b.rect
		draw.rect(dc, r, {1, 1, 1, 0.035 * b.hot_t}, 7 * ui.scale())
	}
}

tool_icon :: proc(name: string) -> string {
	switch {
	case strings.contains(name, "bash") || strings.contains(name, "shell") || strings.contains(name, "pty"): return ICO_TERMINAL
	case name == "read" || name == "view":                                                             return ICO_DOC
	case strings.contains(name, "edit") || name == "write" || strings.contains(name, "patch"):           return ICO_EDIT
	case name == "glob" || name == "grep" || name == "list" || strings.contains(name, "search") || name == "find": return ICO_SEARCH
	case strings.contains(name, "web") || strings.contains(name, "fetch") || strings.contains(name, "browser"): return ICO_GLOBE
	case name == "task" || strings.contains(name, "agent"):                                              return ICO_ROBOT
	case strings.contains(name, "todo"):                                                                 return ICO_LIST
	}
	return ICO_TOOL
}

status_color :: proc(s: Tool_Status) -> Color {
	switch s {
	case .Pending: return hex(HEX_FAINT)
	case .Running: return hex(HEX_YELLOW)
	case .Done:    return hex(HEX_GREEN)
	case .Error:   return hex(HEX_RED)
	}
	return {}
}

@(private = "file")
Rail_Draw :: struct { status: Tool_Status, above, below: bool, head: f32 }

// The timeline's gutter: a carved rail through the calls of a run, and at the height of the header the call's mark:
// a lamp while it runs, a pip once it is done, a red pip when it failed.
@(private = "file")
rail_draw :: proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
	d := (^Rail_Draw)(user)
	r := b.rect
	if b.parent != nil { r.max.y = b.parent.rect.max.y }   // (the box is as tall as the header; the row may be taller)
	x := math.round((r.min.x + r.max.x) * 0.5)
	cy := math.round(r.min.y + d.head * 0.5)
	if d.above { draw_groove(dc, {x, r.min.y}, {x, cy}, true) }
	if d.below { draw_groove(dc, {x, cy}, {x, r.max.y}, true) }
	sz := math.round(d.head * 0.38)
	switch d.status {
	case .Running, .Pending:
		lit := 0.45 + 0.55 * (0.5 + 0.5 * math.sin(f32(ui.now_ms()) * 0.006))
		draw_lamp(dc, {x, cy}, math.round(sz * 0.85), status_color(d.status), lit)
	case .Done:  draw_pip(dc, {x, cy}, sz, hex(0x4f8a5eff))
	case .Error: draw_pip(dc, {x, cy}, sz, hex(HEX_RED))
	}
}

// A tool call on the timeline: a flat row (its header lights under the pointer), its input and output in wells when
// open. `above`, `below`: calls right before and after it, joined by the rail.
tool_part :: proc(app: ^App, p: ^Part, pid: string, em: f32, above := false, below := false) {
	open := part_open(app, p.tool_id != "" ? p.tool_id : pid, app.prefs.expand_tools)
	head_h := math.round(em * 2.0)
	running := p.status == .Running || p.status == .Pending
	if running { app.animating = true }
	ui.next({width = ui.fill(), height = ui.children_sum(), axis = .X})
	if ui.row(id = fmt.tprintf("###tp_%s", pid)) {
		ui.next({width = ui.px(math.round(em * 1.5)), height = ui.px(head_h)})   // (the rail draws down to the row's bottom: fill() in a row sized by its children resolves far above)
		gb := ui.build_box({}, "###rail")
		rd := ui.frame_new(Rail_Draw)
		rd^ = {p.status, above, below, head_h}
		gb.custom = rail_draw
		gb.custom_user = rd
		ui.next({width = ui.fill(), height = ui.children_sum(), axis = .Y})
		if ui.column(id = "###col") {
		// header (click to open)
		ui.next({width = ui.fill(), height = ui.px(head_h), axis = .X, cross = .Center})
		hb := ui.build_box({.Clickable, .Focusable}, "###head")
		hb.custom = head_draw
		hs := ui.signal(hb)
		if hs.clicked { part_toggle(app, p.tool_id != "" ? p.tool_id : pid, hb) }
		if ui.parent(hb) {
			ui.spacer(ui.px(em * 0.5))
			failed := p.status == .Error
			glyph(tool_icon(p.tool_name), failed ? hex(HEX_RED) : hex(HEX_FAINT), math.round(em * 0.85))
			ui.spacer(ui.px(em * 0.35))
			text("nm", p.tool_name != "" ? p.tool_name : "tool", failed ? hex(0xf0a0a6ff) : running ? hex(0xffffffff) : hex(HEX_TEXT), ui.Style_Mod{font = app.mono_bold, font_size = math.round(em * 0.85)})
			ui.spacer(ui.px(em * 0.6))
			text("sj", p.subject, hex(HEX_WEAK), ui.Style_Mod{font = app.mono, font_size = math.round(em * 0.8)}, ui.fill())
			ui.spacer(ui.px(em * 0.4))
			glyph(open ? ICO_DOWN : ICO_RIGHT, hex(HEX_FAINT), math.round(em * 0.6))
			ui.spacer(ui.px(em * 0.6))
		}
		show_error := p.status == .Error && p.output != ""
		if open || show_error || len(p.images) > 0 {   // (images show even folded: a screenshot is what one looks for)
			ui.next({width = ui.fill(), height = ui.children_sum(), axis = .X})
			if ui.row(id = "###bodyrow") {
				ui.spacer(ui.px(em * 0.6))
				ui.next({width = ui.fill(), height = ui.children_sum(), axis = .Y})
				if ui.column() {
					if open && p.input != "" {
						section_label("in", "INPUT", em)
						mono_well("###input", p.input, em, 40)
						ui.spacer(ui.px(em * 0.5))
					}
					if p.output != "" && (open || show_error) {
						if open { section_label("out", p.status == .Error ? "ERROR" : "OUTPUT", em) }
						mono_well("###output", p.output, em, open ? app.prefs.tool_lines : 6, p.status == .Error ? hex(0xf0a0a6ff) : hex(0xbdbdbdff))
					}
					if len(p.images) > 0 {
						ui.spacer(ui.px(em * 0.5))
						sc := ui.scale()
						image_strip(app, "###imgs", p.images[:], (open ? 520 : 240) * sc, (open ? 360 : 150) * sc)
					}
					ui.spacer(ui.px(em * 0.6))
				}
				ui.spacer(ui.px(em * 0.6))
			}
		}
		}
	}
	if !below { ui.spacer(ui.px(em * 0.5)) }
}

section_label :: proc(id, s: string, em: f32) {
	ui.next({width = ui.fill(), height = ui.px(em * 1.4), axis = .X, cross = .Center})
	if ui.row(.Center, id = fmt.tprintf("###sl_%s", id)) {
		text("l", s, hex(HEX_FAINT), ui.Style_Mod{font = the_app.mono_bold, font_size = math.round(em * 0.68)})
	}
}

// Monospace text in a sunken well, at most `max_lines` lines (the rest is counted).
mono_well :: proc(id: string, s: string, em: f32, max_lines: int, color := Color{}) {
	body := s
	extra := 0
	n, cut := 0, len(s)
	for i in 0 ..< len(s) {
		if s[i] == '\n' {
			n += 1
			if n == max_lines { cut = i }
		}
	}
	if n >= max_lines && cut < len(s) {
		extra = n - max_lines + 1
		body = s[:cut]
	}
	if len(body) > 20000 { body = body[:20000] }
	ui.next({width = ui.fill(), height = ui.children_sum(), axis = .Y})
	if well(id, radius = 6, base = 0x060606ff) {
		ui.spacer(ui.px(em * 0.5))
		ui.next({width = ui.fill(), height = ui.children_sum(), axis = .X})
		if ui.row(id = "###r") {
			ui.spacer(ui.px(em * 0.75))
			runs := [1]ui.Rich_Run{{text = body, style = {font = the_app.mono, color = color.a > 0 ? color : hex(0xbdbdbdff)}}}
			ui.next({width = ui.fill(), font_size = math.round(em * 0.82), flags = {.Selectable}})
			ui.rich_paragraph("###t", runs[:])
			ui.spacer(ui.px(em * 0.75))
		}
		if extra > 0 {
			ui.next({width = ui.fill(), height = ui.px(em * 1.5), axis = .X, cross = .Center})
			if ui.row(.Center, id = "###more") {
				ui.spacer(ui.px(em * 0.75))
				text("m", fmt.tprintf("… %d more lines", extra), hex(HEX_FAINT), ui.Style_Mod{font = the_app.mono, font_size = math.round(em * 0.75)})
			}
		}
		ui.spacer(ui.px(em * 0.5))
	}
}

reasoning_part :: proc(app: ^App, p: ^Part, pid: string, em: f32) {
	if app.prefs.reasoning == "hidden" { return }
	open := part_open(app, pid, app.prefs.reasoning == "expanded")
	ui.next({width = ui.fill(), height = ui.px(math.round(em * 1.9)), axis = .X, cross = .Center})
	hb := ui.build_box({.Clickable, .Focusable}, fmt.tprintf("###rh_%s", pid))
	hb.custom = head_draw
	hs := ui.signal(hb)
	if hs.clicked { part_toggle(app, pid, hb) }
	if ui.parent(hb) {
		ui.spacer(ui.px(em * 0.2))
		glyph(ICO_BULB, hex(HEX_PURPLE), math.round(em * 0.85))
		ui.spacer(ui.px(em * 0.3))
		text("t", p.done ? "Thought" : "Thinking…", hex(HEX_PURPLE), ui.Style_Mod{font_size = math.round(em * 0.88)})
		ui.spacer(ui.px(em * 0.5))
		if !open {
			text("pv", first_line(string(p.text[:])), hex(HEX_FAINT), ui.Style_Mod{font_size = math.round(em * 0.85)}, ui.fill())
		} else { ui.spacer(ui.fill()) }
		glyph(open ? ICO_DOWN : ICO_RIGHT, hex(HEX_FAINT), math.round(em * 0.6))
		ui.spacer(ui.px(em * 0.4))
	}
	if open {
		ui.next({width = ui.fill(), height = ui.children_sum(), axis = .X})
		if rail_row(fmt.tprintf("###rb_%s", pid), with_alpha(hex(HEX_PURPLE), 0.45)) {
			ui.spacer(ui.px(em * 0.9))
			runs := [1]ui.Rich_Run{{text = string(p.text[:]), style = {italic = true, color = hex(0x9a9a9aff)}}}
			ui.next({width = ui.fill(), font_size = math.round(em * 0.92), flags = {.Selectable}})
			ui.rich_paragraph("###t", runs[:])
		}
	}
	ui.spacer(ui.px(em * 0.5))
}

////////////////////////////////
// The dock: permission requests and the composer

dock :: proc(app: ^App, em: f32, side, col: f32) {
	ui.next({width = ui.fill(), height = ui.children_sum(), axis = .X})
	if ui.row(id = "###dock") {
		ui.spacer(ui.px(side))
		ui.next({width = ui.px(col), height = ui.children_sum(), axis = .Y})
		if ui.column(id = "###dockcol") {
			active_strip(app, em)
			for &p in app.permissions {
				if p.session == app.chat.id { permission_card(app, &p, em) }
			}
			composer(app, em)
			ui.spacer(ui.px(em * 1.1))
		}
	}
}

permission_card :: proc(app: ^App, p: ^Permission, em: f32) {
	ui.next({width = ui.fill(), height = ui.children_sum(), axis = .Y})
	if plate(fmt.tprintf("###perm_%s", p.id), top = 0x2a2116ff, bottom = 0x1d170fff, radius = 9, shadow = 8, rim = 0.1, border = with_alpha(hex(HEX_YELLOW), 0.55)) {
		ui.spacer(ui.px(em * 0.7))
		ui.next({width = ui.fill(), height = ui.children_sum(), axis = .X, cross = .Center})
		if ui.row(.Center, id = "###r") {
			ui.spacer(ui.px(em))
			glyph(ICO_SHIELD, hex(HEX_YELLOW), math.round(em * 1.1), em * 1.6)
			ui.spacer(ui.px(em * 0.5))
			ui.next({width = ui.fill(), height = ui.children_sum(), axis = .Y})
			if ui.column() {
				text("a", fmt.tprintf("Permission requested: %s", p.action), hex(HEX_YELLOW), ui.Style_Mod{font = app.mono_bold, font_size = math.round(em * 0.9), height = ui.px(em * 1.5)}, ui.fill())
				detail := p.message != "" ? p.message : strings.join(p.resources, ", ", context.temp_allocator)
				text("d", detail, hex(0xd8c8b0ff), ui.Style_Mod{font = app.mono, font_size = math.round(em * 0.8), height = ui.px(em * 1.4)}, ui.fill())
			}
			ui.spacer(ui.px(em * 0.5))
			if bevel_button("###once", "Allow once", ICO_CHECK, .Accent).clicked { reply_permission(app, p.session, p.id, "once") }
			ui.spacer(ui.px(em * 0.4))
			if bevel_button("###always", "Always", "", .Normal).clicked { reply_permission(app, p.session, p.id, "always") }
			ui.spacer(ui.px(em * 0.4))
			if bevel_button("###reject", "Reject", ICO_CANCEL, .Danger).clicked { reply_permission(app, p.session, p.id, "reject") }
			ui.spacer(ui.px(em))
		}
		ui.spacer(ui.px(em * 0.7))
	}
	ui.spacer(ui.px(em * 0.7))
}

composer :: proc(app: ^App, em: f32) {
	// Enter sends, Shift+Enter breaks the line (the editor itself breaks on Enter and commits on Ctrl+Enter)
	submit := false
	if app.composer_focused && !app.prefs.ctrl_enter {   // (Ctrl+Enter mode: Enter breaks the line, the editor commits on Ctrl+Enter)
		if ui.key_press(.Return) { submit = true }
		if ui.key_press(.Return, {.Shift}) { area_insert(&app.composer, "\n") }
	}
	ui.next({width = ui.fill(), height = ui.children_sum(), axis = .Y})
	if well("###composer_well", radius = 11, base = 0x080808ff, focus = app.composer_focused ? 1 : 0) {
		ui.spacer(ui.px(em * 0.45))
		ui.next({width = ui.fill(), height = ui.children_sum(), axis = .X})
		if ui.row(id = "###edrow") {
			ui.spacer(ui.px(em * 0.35))
			if ui.tags("bare") {
				ui.next({width = ui.fill(), font_size = math.round(em * 1.02), text_pad = em * 0.5})
				res := ui.text_edit("###composer", &app.composer, "Ask anything…", wrap = true, auto_height = true, min_lines = 2, max_lines = 12)
				app.composer_focused = res.focused
				if res.committed { submit = true }
			}
			ui.spacer(ui.px(em * 0.35))
		}
		// toolbar
		ui.next({width = ui.fill(), height = ui.px(math.round(em * 2.8)), axis = .X, cross = .Center})
		if ui.row(.Center, id = "###tools") {
			ui.spacer(ui.px(em * 0.6))
			agent := app.chat.agent != "" ? app.chat.agent : "build"
			asig := bevel_button("###agent", agent, ICO_ROBOT, .Normal, height = math.round(em * 1.9))
			if asig.clicked { if app.picker.open && app.picker.id == "agent" { app.picker.open = false } else { picker_open(&app.picker, "agent", asig.box.rect) } }
			ui.spacer(ui.px(em * 0.4))
			model := app.chat.model != "" ? app.chat.model : "default model"
			msig := bevel_button("###model", model, ICO_CHIP, .Normal, height = math.round(em * 1.9))
			if msig.clicked { if app.picker.open && app.picker.id == "model" { app.picker.open = false } else { picker_open(&app.picker, "model", msig.box.rect) } }
			ui.spacer(ui.fill())
			if app.column_w > em * 44 {   // (room for it beside the agent and model buttons)
				text("hint", app.prefs.ctrl_enter ? "Ctrl+Enter  send   ·   Enter  new line" : "Enter  send   ·   Shift+Enter  new line", hex(HEX_FAINT), ui.Style_Mod{font = app.mono, font_size = math.round(em * 0.72)})
			}
			ui.spacer(ui.px(em * 0.8))
			if app.chat.busy {
				if bevel_button("###stop2", "", ICO_STOP, .Danger, ui.px(math.round(em * 2.6)), math.round(em * 2.1)).clicked { interrupt_session(app, app.chat.id) }
				ui.spacer(ui.px(em * 0.4))
			}
			empty := len(strings.trim_space(ui.area_string(&app.composer))) == 0
			if bevel_button("###send", "", ICO_SEND, .Accent, ui.px(math.round(em * 2.6)), math.round(em * 2.1), disabled = empty || !app.online).clicked { submit = true }
			ui.spacer(ui.px(em * 0.55))

			// the agent and the model: pickers searched as one types
			agent_items := make([dynamic]Pick_Item, context.temp_allocator)
			agent_ids := make([dynamic]string, context.temp_allocator)
			for a in app.agents {
				if a.mode == "subagent" { continue }
				append(&agent_items, Pick_Item{label = a.name != "" ? a.name : a.id, detail = a.mode == "primary" ? "" : a.mode, current = a.id == agent, color = agent_color(a.id)})
				append(&agent_ids, a.id)
			}
			if k := picker(app, &app.picker, "agent", "agents", agent_items[:], em); k >= 0 {
				if app.chat.id != "" { switch_agent(app, app.chat.id, agent_ids[k]) }
				app.chat.agent = strings.clone(agent_ids[k], app.chat.alloc)
			}
			model_items := make([dynamic]Pick_Item, len(app.models), context.temp_allocator)
			for m, i in app.models {
				model_items[i] = Pick_Item{label = m.name != "" ? m.name : m.id, group = m.provider, detail = m.ctx_len > 0 ? kfmt(m.ctx_len) : "", current = m.id == app.chat.model && m.provider == app.chat.provider}
			}
			if k := picker(app, &app.picker, "model", "models", model_items[:], em); k >= 0 {
				m := app.models[k]
				if app.chat.id != "" { switch_model(app, app.chat.id, m) }
				app.chat.model = strings.clone(m.id, app.chat.alloc)
				app.chat.provider = strings.clone(m.provider, app.chat.alloc)
			}
		}
	}
	if submit { submit_prompt(app) }
}

area_insert :: proc(a: ^ui.Text_Area, s: string) {
	lo, hi := min(a.cursor, a.mark), max(a.cursor, a.mark)
	remove_range(&a.buf, lo, hi)
	inject_at(&a.buf, lo, ..transmute([]u8)s)
	a.cursor = lo + len(s)
	a.mark = a.cursor
}

submit_prompt :: proc(app: ^App) {
	t := strings.trim_space(ui.area_string(&app.composer))
	if t == "" || !app.online { return }
	if app.chat.id == "" {
		delete(app.pending_prompt)
		app.pending_prompt = strings.clone(t)
		create_session(app, app.new_dir)
	} else {
		send_prompt(app, app.chat.id, t)
	}
	ui.area_set(&app.composer, "")
	app.stick_bottom = true
}

////////////////////////////////
// Status bar

status_bar :: proc(app: ^App, em: f32) {
	edge_line("###sbedge")
	h := math.round(em * 1.9)
	ui.next({width = ui.fill(), height = ui.px(h), axis = .X, cross = .Center})
	if ui.row(.Center, id = "###status") {
		b := ui.parent_box()
		d := ui.frame_new(Bar_Draw)
		d^ = {hex(0x141414ff), hex(0x0e0e0eff)}
		b.custom = bar_draw
		b.custom_user = d
		small := ui.Style_Mod{font = app.mono, font_size = math.round(em * 0.75)}
		ui.spacer(ui.px(em * 0.35))
		// the server: a button that opens the menu of the servers (switch, add, edit)
		col := app.online ? hex(HEX_GREEN) : app.auth_failed ? hex(HEX_RED) : hex(HEX_YELLOW)
		ui.next({width = ui.children_sum(), height = ui.px(h - 4 * ui.scale()), axis = .X, cross = .Center})
		sb := ui.build_box({.Clickable, .Focusable}, "###server_btn")
		sb.custom = proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
			if b.hot_t > 0.01 || b.active_t > 0.01 { draw_bevel(dc, b.rect, 5 * ui.scale(), hex(0x1e1e1eff), b.hot_t, b.active_t * b.hot_t) }
		}
		ssig := ui.signal(sb)
		skey := ui.key_from_string(0, "server_menu")
		if ssig.clicked { ui.ctx_menu_open_rect(skey, sb.rect, sb.key) }
		if ui.parent(sb) {
			ui.spacer(ui.px(em * 0.45))
			state_mark("###online", col, !app.online, size = em * 0.8)   // (connected is the normal state: a pip)
			ui.spacer(ui.px(em * 0.4))
			if len(app.servers) > 1 || !app.servers[app.server].local {
				text("sn", server_name(app), app.online ? hex(HEX_TEXT) : col, ui.Style_Mod{font = app.mono_bold, font_size = math.round(em * 0.75)})
				ui.spacer(ui.px(em * 0.5))
			}
			state := app.online ? "connected" : app.auth_failed ? "auth refused" : "connecting"
			text("st", fmt.tprintf("%s  %s", state, server_base(app)), app.online ? hex(HEX_WEAK) : col, small)
			ui.spacer(ui.px(em * 0.35))
			glyph(ICO_DOWN, hex(HEX_FAINT), math.round(em * 0.55))
			ui.spacer(ui.px(em * 0.45))
		}
		server_menu(app, skey, em)
		if app.server_version != "" {
			ui.spacer(ui.px(em * 0.8))
			ui.next({height = ui.px(h * 0.6)})
			groove()
			ui.spacer(ui.px(em * 0.6))
			text("v", fmt.tprintf("opencode %s", app.server_version), hex(HEX_FAINT), small)
		}
		ui.spacer(ui.fill())
		pend := int(app.pending)
		if pend > 0 {
			text("p", fmt.tprintf("%d request%s", pend, pend > 1 ? "s" : ""), hex(HEX_FAINT), small)
			ui.spacer(ui.px(em * 0.8))
		}
		nbusy := len(app.busy)
		if nbusy > 0 {
			text("b", fmt.tprintf("%d running", nbusy), accent(), small)
			ui.spacer(ui.px(em * 0.8))
		}
		text("n", fmt.tprintf("%d sessions", len(app.sessions)), hex(HEX_FAINT), small)
		ui.spacer(ui.px(em * 0.8))
	}
}

// At most `n` characters (an ellipsis replaces the rest).
ellipsize :: proc(s: string, n: int) -> string {
	count := 0
	for _, i in s {
		if count == n { return fmt.tprintf("%s…", s[:i]) }
		count += 1
	}
	return s
}
