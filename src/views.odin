// The window: an integrated title bar, the sessions on the left (grouped by project folder), the conversation and its
// composer on the right, a status bar along the bottom.
package ocn

import "core:fmt"
import "core:unicode"
import "core:unicode/utf8"
import "core:hash"
import "core:math"
import "core:mem"
import "core:slice"
import "core:strings"
import "gt:draw"
import "gt:markdown"
import "gt:ui"
import lucide "gt:lucide"


TOAST_TOP_EM          :: 5.5
SIDEBAR_W_DEFAULT     :: 290
SIDEBAR_W_MIN         :: 200
SIDEBAR_W_MAX         :: 520
CONVERSATION_MIN_PX   :: 420   // what the sidebar's splitter leaves it
TITLE_BAR_MIN_H_PX    :: 34
TITLE_BAR_TITLE_CHARS :: 70
CRUMB_PARENT_CHARS    :: 60

HEX_TITLE_BAR_TOP     :: 0x181818ff
HEX_TITLE_BAR_BOTTOM  :: 0x111111ff
HEX_HEADER_TOP        :: 0x131313ff
HEX_HEADER_BOTTOM     :: 0x0d0d0dff
HEX_STATUS_TOP        :: 0x141414ff
HEX_STATUS_BOTTOM     :: 0x0e0e0eff
HEX_SUB_OFF_TITLE     :: 0x7a7a7aff
HEX_USER_PLATE_TOP    :: 0x222222ff
HEX_USER_PLATE_BOTTOM :: 0x1a1a1aff
HEX_USER_TEXT         :: 0xf2f2f2ff
HEX_ANSWER_TEXT       :: 0xdcdcdcff
HEX_TOOL_DONE_PIP     :: 0x4f8a5eff
HEX_TOOL_OUTPUT       :: 0xbdbdbdff
HEX_REASONING_TEXT    :: 0x9a9a9aff
HEX_PERM_TOP          :: 0x2a2116ff
HEX_PERM_BOTTOM       :: 0x1d170fff
HEX_PERM_DETAIL       :: 0xd8c8b0ff
HEX_COMPOSER_WELL     :: 0x080808ff

build_ui :: proc(app: ^App) {
	em := ui.font_size()
	global_keys(app)
	ui.next({width = ui.fill(), height = ui.fill(), axis = .Y})
	if ui.column(id = "###root") {
		title_bar(app, em)
		ui.next({width = ui.fill(), height = ui.fill()})
		if ui.row(id = "###body") {
			if !app.cx.sidebar_hidden {
				sidebar(app, em)
				room := ui.parent_box().size.x / ui.scale()
				ui.next({height = ui.fill()})
				ui.a11y({name = "Sidebar width"})
				groove_y: f32
				if ui.parent(ui.prev_box("###sidebar")) { if g := ui.prev_box("###sg"); g != nil { groove_y = (g.rect.min.y + g.rect.max.y) * 0.5 } }
				split := ui.splitter("###side_split", .X, &app.sidebar_w, SIDEBAR_W_MIN, SIDEBAR_W_MAX, {default_size = SIDEBAR_W_DEFAULT, total = room, min_other = CONVERSATION_MIN_PX})
				side_handle(split, groove_y, app.state.focus_visible)
			}
			main_area(app, em)
		}
		status_bar(app, em)
	}
	delete_dialog(app, em)
	setup_dialog(app, em)
	server_dialog(app, em)
	settings_dialog(app, em)
	image_viewer(app, em)
	rename_dialog(app, em)
	help_dialog(app, em)
	pair_dialog(app, em)
	integrations_watch(app)
	schedules_dialog(app, em)
	artifacts_dialog(app, em)
	changes_dialog(app, em)
	diff_full_dialog(app, em)
	output_view_dialog(app, em)
	files_dialog(app, em)
	palette_dialog(app, em)
	context_menu(app, em)
	// (only this way: a dialog opened by what was built after it, a menu, is open and not built until the next build)
	when ODIN_DEBUG { assert(len(app.state.modals_built) == 0 || overlay_open(app), "a dialog built that is not in App_Context.open: the program's keys would act behind it") }
	// (over the top of the conversation, under its header: at the bottom they hid the send button, when one wants to try again)
	ui.set_toast_area({{0, em * TOAST_TOP_EM}, app.state.window_size})
	ui.toasts_build()
	// (last: what is open and a field that has it took Escape before it gets here)
	if app.chat.busy && !overlay_open(app) && !mention_takes_escape(app) && ui.key_press(.Escape) { interrupt_session(app, app.chat.id) }
}

app_menu :: proc(app: ^App, key: ui.Key, em: f32) {
	if ui.ctx_menu(key) {   // (as wide as its longest item)
		if ui.menu_item("Command palette…", "Ctrl+K", icon = lucide.COMMAND).clicked { palette_toggle(app) }
		ui.menu_separator()
		if ui.menu_item("Home", "Ctrl+H", icon = lucide.HOME).clicked { command_run(app, command_find("nav.home")) }
		if ui.menu_item("New session", "Ctrl+N", icon = lucide.PLUS).clicked { command_run(app, command_find("session.new")) }
		if ui.menu_item("Refresh", "F5", icon = lucide.REFRESH_CW).clicked {
			refresh_sessions(app)
			if app.chat.id != "" { load_messages(app, app.chat.id) }
		}
		if ui.menu_item("Settings…", "Ctrl+,", icon = lucide.SLIDERS_HORIZONTAL).clicked { settings_open(app) }
		if ui.menu_item("Add a server…", icon = lucide.PLUG).clicked { server_edit_open(app, -1) }
		if ui.menu_item("Statistics panel", "Ctrl+I", app.stats_open, icon = lucide.GAUGE, enabled = app.chat.id != "").clicked { stats_toggle(app) }
		if preview_available() {
			if ui.menu_item("Preview panel", "Ctrl+Shift+B", app.preview.open, icon = lucide.GLOBE).clicked { command_run(app, command_find("view.preview")) }
		}
		if ui.menu_item("Keyboard shortcuts", "F1", icon = lucide.KEYBOARD).clicked { app.cx.open[.Help] = true }
		if ui.menu_item("Sub-agent sessions in the list", "", app.prefs.subagents == "flat", icon = lucide.BOT).clicked { pref_set(app, "sidebar.subagents", app.prefs.subagents == "flat" ? "nested" : "flat") }
		ui.menu_separator()
		if ui.menu_item("Setup…", icon = lucide.WRENCH).clicked { setup_open(app) }
		if ui.menu_item("About opencode native", icon = lucide.INFO).clicked { setup_open(app) }
		ui.menu_separator()
		if ui.menu_item("Quit", "Alt+F4", icon = lucide.LOG_OUT).clicked { app.quit = true }
	}
}

global_keys :: proc(app: ^App) {
	find_keys(app)
	commands_keys(app)
}

new_session :: proc(app: ^App) {
	nav_visit(app, app.chat.id, "")
	for s in app.nav { delete(s) }   // (the way back up is the session's: none from here)
	clear(&app.nav)
	dir := ""
	if s := find_session(app, app.chat.id); s != nil { dir = s.directory } else if len(app.sessions) > 0 { dir = app.sessions[0].directory }
	chat_home(app)
	remote_reset(&app.cx.chat_read)
	chat_view_start(app, 0)   // (a way back under way ends: its place is in the conversation left)
	app.chat.new_dir = strings.clone(dir, app.chat.alloc)
	chat_shown_changed(app)
	app.cx.focus_composer = true
}

////////////////////////////////
// Title bar

@(private = "file")
Bar_Draw :: struct { top, bottom: Color, lit_top: bool }

@(private = "file")
bar_draw :: proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
	d := (^Bar_Draw)(user)
	r := b.rect
	if flat() { draw.rect(dc, r, draw.mix(d.top, d.bottom, 0.5)); return }
	draw.rect_corners(dc, r, {d.top, d.bottom, d.top, d.bottom}, {})
	// (only with nothing above it: under a carved line, whose lower half is lit, it would be a second line)
	if d.lit_top { draw.rect(dc, {r.min, {r.max.x, r.min.y + px1()}}, {1, 1, 1, 0.05}) }
}

// The title bar's face: the finish's (ui.caption_face), in its two colours.
@(private = "file")
caption_draw :: proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
	d := (^Bar_Draw)(user)
	ui.caption_face(dc, b.rect, d.top, d.bottom)
}

@(private = "file")
Side_Handle_Draw :: struct { hot: bool, groove_y: f32 }

// The sidebar's edge and the handle that resizes it are one thing: the handle goes on with the sidebar's surface, and the one
// line between the sidebar and the conversation is at its right. The sidebar's own groove comes all the way to that line.
@(private = "file")
side_handle :: proc(split: ui.Splitter_Result, groove_y: f32, focus_visible: bool) {
	d := ui.frame_new(Side_Handle_Draw)
	d^ = {split.hovering || split.dragging || split.focused && focus_visible, groove_y}   // (focused by the keys only: a drag leaves the focus on it, not the colour)
	split.box.custom_user = d
	split.box.custom = proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
		d := (^Side_Handle_Draw)(user)
		r := b.rect
		draw.rect(dc, r, hex(HEX_BG1))
		line := 2 * px1()
		if d.groove_y > 0 {
			y := math.round(d.groove_y) - px1()
			draw_groove(dc, {r.min.x, y}, {r.max.x - line, y})
		}
		if d.hot {
			draw.rect(dc, {{r.max.x - line, r.min.y}, r.max}, accent())
		} else {
			draw_groove(dc, {r.max.x - line, r.min.y}, {r.max.x - line, r.max.y}, true)
		}
	}
}

// The line between the sidebar and the conversation goes on through the title bar and the status bar: after what a bar puts
// over the sidebar (`last`, its last box), at least `gap` then the line; a bar with more than the sidebar's width pushes it on.
@(private = "file")
side_line :: proc(id: string, last: ^ui.Box, gap, sidebar_w: f32) {
	x := ui.parent_box().rect.min.x + math.round(sidebar_w * ui.scale()) + math.round(SPLITTER_W_PX * ui.scale()) - 2 * px1()
	ui.spacer(ui.px(max(gap, x - last.rect.max.x)))
	edge_line(id, vertical = true)
}

title_bar :: proc(app: ^App, em: f32) {
	h := max(math.round(em * 2.6), math.round(TITLE_BAR_MIN_H_PX * ui.scale()))
	ui.next({width = ui.fill(), height = ui.px(h)})
	if ui.title_bar("###titlebar") {
		b := ui.parent_box()
		d := ui.frame_new(Bar_Draw)
		d^ = {hex(HEX_TITLE_BAR_TOP), hex(HEX_TITLE_BAR_BOTTOM), true}
		b.custom = caption_draw   // (the finish's title bar: in the edged one the accent fading out, its words light: ui.caption_ink)
		b.custom_user = d
		ink := ui.caption_ink
		ui.spacer(ui.px(em * 0.4))
		msig := glyph_button("###appmenu", lucide.MENU, math.round(h * 0.78), ink(hex(HEX_WEAK)))
		menu_key := ui.key_from_string(0, "app_menu")
		if msig.clicked { ui.ctx_menu_open_rect(menu_key, msig.box.rect, msig.box.key) }
		app_menu(app, menu_key, em)
		nav_button :: proc(app: ^App, id, icon, tip: string, d: int, size: f32) {
			can := nav_can(app, d)
			ui.a11y({role = .Button, name = tip})
			sig := glyph_button(id, icon, size, ui.caption_ink(can ? hex(HEX_WEAK) : hex(HEX_FAINT)))
			if sig.clicked { nav_step(app, d) }
			if can && ui.hovered_for(sig, TOOLTIP_DELAY_S) { if ui.tooltip() { ui.tooltip_text(tip) } }
		}
		nav_button(app, "###nav_back", lucide.ARROW_LEFT, "Back  (Alt+Left)", -1, math.round(h * 0.78))
		nav_button(app, "###nav_fwd", lucide.ARROW_RIGHT, "Forward  (Alt+Right)", 1, math.round(h * 0.78))
		ui.spacer(ui.px(em * 0.4))
		// the logo and the wordmark ("open" dim, "code" bright, "native" in the accent, in the mono face) go home, as on any site
		ui.next({width = ui.children_sum(), height = ui.pct(1), axis = .X, cross = .Center, cursor = .Hand})
		ui.a11y({role = .Button, name = "Home"})
		home_link := ui.build_box({.Clickable}, "###home_link")
		hsig := ui.signal(home_link)
		if ui.parent(home_link) {
			logo_box(app, "###tlogo", math.round(h * 0.6))
			ui.spacer(ui.px(em * 0.5))
			mono := ui.Style_Mod{font = app.mono_bold, font_size = math.round(em * FS_HEADING)}
			text("w1", "open", ink(hsig.hovering ? hex(HEX_TEXT) : hex(HEX_WEAK)), mono)
			text("w2", "code", ink(hsig.hovering ? hex(HEX_BRIGHT) : hex(HEX_TEXT)), mono)
			ui.spacer(ui.px(em * 0.45))
			text("w3", "native", ink(accent()), ui.Style_Mod{font = app.mono, font_size = math.round(em * FS_HEADING)})
		}
		if hsig.clicked { command_run(app, command_find("nav.home")) }
		if ui.hovered_for(hsig, TOOLTIP_DELAY_S) { if ui.tooltip() { ui.tooltip_text("Home  (Ctrl+H)") } }
		side_line("###tg", b.last, em * 0.9, app.sidebar_w)
		ui.spacer(ui.px(em * 1.3))
		if !app.servers[app.server].local {   // another computer's server: its name first
			glyph(lucide.GLOBE, ink(hex(HEX_CYAN)), math.round(em * ICON_SMALL))
			ui.spacer(ui.px(em * 0.3))
			text("srv", server_name(app), ink(hex(HEX_CYAN)), ui.Style_Mod{font = app.mono_bold, font_size = math.round(em * FS_SMALL)})
			if app.chat.id != "" { text("srvsep", "  /  ", ink(hex(HEX_FAINT)), ui.Style_Mod{font_size = math.round(em * FS_LABEL)}) }
		}
		s := find_session(app, app.chat.id)
		if s == nil && app.chat.have_self { s = &app.chat.self }
		if s != nil {
			// the project's logo before its folder
			if logo_of(app, "###tproj", project_logo(app, s.project), math.round(h * 0.55)) { ui.spacer(ui.px(em * 0.45)) }
			text("dir", base_name(s.directory), ink(hex(HEX_WEAK)), ui.Style_Mod{font_size = math.round(em * FS_LABEL)})
			text("sep", "  /  ", ink(hex(HEX_FAINT)), ui.Style_Mod{font_size = math.round(em * FS_LABEL)})
			text("ttl", ellipsize(s.title, TITLE_BAR_TITLE_CHARS), ink(hex(HEX_TEXT)), ui.Style_Mod{font_size = math.round(em * FS_LABEL)}, ui.fill())
		} else {
			ui.spacer(ui.fill())
		}
		if app.chat.busy {
			ui.spacer(ui.px(em * 0.8))
			throbber(app, "###tscan", accent(), math.round(em * 3), math.round(em * 0.75), em)
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
	ui.next({width = ui.px(app.sidebar_w * ui.scale()), height = ui.fill(), axis = .Y, bg = hex(HEX_BG1), radius = 0})   // (square: its rounded corner notched the bar's edge)
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
					ui.line_edit("###search", &app.search, "Search sessions", clearable = true)
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
	sections := sidebar_view(app, ui.field_string(&app.search), sidebar_hold_wanted(app, ui.parent_box()))
	kids := app.cx.side.kids   // (the sub-agents of each session, listed under it unless the list is flat)
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
			folded := app.folded[sec.key] or_else sec.shut
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
	if hs.clicked { app.folded[gkey] = !folded }
	// a right click: its project's menu (its icon)
	if hs.right_clicked && len(gr.items) > 0 {
		delete(app.menu_project)
		app.menu_project = strings.clone(app.sessions[gr.items[0]].project)
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
			delete(app.menu_session)
			app.menu_session = strings.clone(s.id)
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
					if renaming_at(app, s.id, .Side) { rename_in_place(app, em, title_style.font_size.?, math.round(em * 1.3)) } else { text_found("t", title, ui.field_string(&app.search), tcol, title_style, ui.fill()) }
					where_ := s.directory != "" ? base_name(s.directory) : "(no folder)"
					if session_unseen(app, s) && s.outcome != "succeeded" && s.outcome != "" { where_ = fmt.tprintf("%s · %s", where_, s.outcome) }
					text("p", ellipsize(where_, SIDE_PROJECT_CHARS), quiet, ui.Style_Mod{font_size = math.round(em * FS_CAPTION), height = ui.px(math.round(em * 1.1))}, ui.fill())
					ui.spacer(ui.fill())
				}
			} else if renaming_at(app, s.id, .Side) {
				rename_in_place(app, em, title_style.font_size.?, math.round(em * 1.6))
			} else {
				text_found("t", title, ui.field_string(&app.search), tcol, title_style, ui.fill())
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
		if ui.menu_item("Open", icon = lucide.EXTERNAL_LINK).clicked { open_root(app, app.menu_session) }
		if ui.menu_item("Rename…", "F2", icon = lucide.PENCIL).clicked { rename_open(app, app.menu_session) }
		if ui.menu_item("Fork", icon = lucide.GIT_FORK).clicked { fork_session(app, app.menu_session, "") }
		if ui.menu_item("Move to a folder…", icon = lucide.FOLDER_INPUT).clicked { session_move_pick(app, app.menu_session) }
		if s := find_session(app, app.menu_session); s != nil { project_icon_items(app, s.project) }
		archived := session_is_archived(app, app.menu_session)
		if ui.menu_item(archived ? "Unarchive" : "Archive", icon = archived ? lucide.ARCHIVE_RESTORE : lucide.ARCHIVE).clicked { session_archive(app, app.menu_session, !archived) }
		if ui.menu_item("What it changed", icon = lucide.FILE_DIFF).clicked { changes_open(app, app.menu_session) }
		if !app.cx.no_schedules && ui.menu_item("Schedules", icon = lucide.CALENDAR_CLOCK).clicked { schedules_open(app, app.menu_session) }
		if ui.menu_item("Export…", icon = lucide.DOWNLOAD).clicked { session_export(app, app.menu_session) }
		if ui.menu_item("Export without the text…", icon = lucide.FILE_DOWN).clicked { session_export(app, app.menu_session, redacted = true) }
		ui.menu_separator()
		if ui.menu_item("Copy session ID", icon = lucide.HASH).clicked { clip_set(app.menu_session) }
		if s := find_session(app, app.menu_session); s != nil {
			if ui.menu_item("Copy folder path", icon = lucide.CLIPBOARD_COPY).clicked { clip_set(s.directory) }
			if ui.menu_item("Show the folder", icon = lucide.FOLDER_OPEN).clicked { reveal_path(s.directory) }
			if ui.menu_item("Open a terminal here", icon = lucide.TERMINAL).clicked { terminal_open(s.directory) }
		}
		ui.menu_separator()
		if ui.menu_item("Delete…", icon = lucide.TRASH_2).clicked {
			delete(app.delete_id)
			app.delete_id = strings.clone(app.menu_session)
			app.cx.open[.Delete] = true
		}
	}
}

// A project's menu (a right click on its header in the sidebar).
project_menu :: proc(app: ^App, em: f32) {
	if ui.ctx_menu(ui.key_from_string(0, "project_menu"), em * 17) { project_icon_items(app, app.menu_project) }
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
				if s := find_session(app, app.delete_id); s != nil { title = s.title }
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
						delete_session(app, app.delete_id)
						if app.delete_id == app.chat.id { new_session(app) }
						nav_forget(app, app.delete_id)
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

////////////////////////////////
// Conversation

SPLITTER_W_PX     :: 5
AVAIL_FALLBACK_PX :: 1000   // before the window has a width
COLUMN_MIN_W_PX   :: 240
BOTTOM_SLACK_PX   :: 4      // this near its end the conversation is at its bottom
AUTOSCROLL_SLACK_PX :: 0.01 // ... while the wheel's click scrolls it: its steps are smaller than the slack (each would be put back at the bottom)
OPENED_FOLLOW_MS  :: 2000   // a conversation just opened follows its bottom that long, whatever the preference
PAGE_SCROLL       :: 0.9    // of the view: the end of the last page stays in sight
LINE_SCROLL_EM    :: 3

conversation :: proc(app: ^App, em: f32) {
	ui.next({width = ui.fill(), height = ui.fill(), axis = .Y, bg = hex(HEX_BG0), radius = 0})
	if ui.column(flags = {.Draw_Background}, id = "###main") {
		sc := ui.scale()
		// this frame's width, from the window (the box's own size is the last frame's: a resize would lag a frame behind):
		// the window less the sidebar and the splitter
		avail := f32(app.win.size.x)
		if !app.cx.sidebar_hidden { avail -= app.sidebar_w * sc + math.round(SPLITTER_W_PX * sc) }
		if app.cx.docked_w > 0 { avail = app.cx.docked_w }   // (a panel of the dock: its room)
		if avail <= 0 { avail = AVAIL_FALLBACK_PX * sc }
		app.column_w = 0
		zoom := app.prefs.content_zoom
		cem := math.round(em * zoom)   // the conversation's own size: its zoom is not the interface's
		col := max(COLUMN_MIN_W_PX * sc, min(app.prefs.column_w * sc * zoom, avail - em * 3))
		side := max(em * 1.5, (avail - col) * 0.5)
		app.column_w = col
		if app.chat.id != "" {
			chat_header(app, em)
		}
		main := ui.parent_box()
		app.cx.main_rect = main.rect
		ui.next({width = ui.fill(), height = ui.fill()})
		sb := ui.prev_box("###chat")
		find_update(app, sb, em)
		chat_scroll_place(app, sb, em)
		if ui.scroll_y("###chat") {
			ui.next({width = ui.fill(), height = ui.children_sum(), axis = .X})
			if ui.row(id = "###lane") {
				ui.spacer(ui.px(side))
				ui.next({width = ui.px(col), height = ui.children_sum(), axis = .Y})
				if ui.column(id = "###col") {
					if ui.style({font_size = cem}) {
						if app.chat.id == "" { home(app, cem) } else { messages(app, cem) }
					}
				}
			}
		}
		app.chat_sb = ui.prev_box("###chat")
		chat_scroll_settle(app, sb)
		if sb != nil && app.chat.id != "" { column_handles(app, sb, main, side, col, avail, em) }
		dock(app, em, side, col)
		// the find bar over the conversation's top-right corner, under the header
		find_bar(app, em, avail - em * 1.4, sb != nil ? sb.rect.min.y - main.rect.min.y + em * 0.6 : em * 4)
		go_bottom_pill(app, sb, main, avail, em)
	}
}

// The conversation's width by hand: a handle each side of its column where there is room, both moving it the same (the column stays
// in the middle). What it is let go at is the widest wanted (conversation.width): a narrower window narrows it, a wider one gives it
// back. Each shows as two short strokes, faint until the pointer comes.
@(private = "file")
column_handles :: proc(app: ^App, sb, main: ^ui.Box, side, col, avail, em: f32) {
	hw := math.round(em * COLUMN_HANDLE_EM)
	unit := ui.scale() * app.prefs.content_zoom   // (the preference is in logical pixels of the conversation)
	// (no room beside it, or the window narrows it already: nothing to give it by hand)
	if side < hw * 1.5 || col < app.prefs.column_w * unit - 1 { return }
	top := sb.rect.min.y - main.rect.min.y
	h := sb.rect.max.y - sb.rect.min.y
	for right in ([]bool{false, true}) {
		x := right ? side + col : side - hw
		ui.next({fixed_x = math.round(x), fixed_y = math.round(top), width = ui.px(hw), height = ui.px(h), cursor = .Col_Resize})
		ui.a11y({role = .Slider, name = "Conversation width"})
		b := ui.build_box({.Clickable}, right ? "###col_r" : "###col_l")
		sig := ui.signal(b)
		if sig.pressed { app.cx.column_drag_from = col / unit }
		if sig.dragging {
			d := (right ? sig.drag_delta.x : -sig.drag_delta.x) * 2 / unit
			most := min(f32(COLUMN_W_MAX), (avail - em * 3) / unit)
			app.prefs.column_w = clamp(math.round(app.cx.column_drag_from + d), f32(COLUMN_W_MIN), max(f32(COLUMN_W_MIN), app.cx.column_drag_from, most))   // (never under where it began for want of room)
		}
		if sig.released { pref_set(app, "conversation.width", fmt.tprintf("%d", int(app.prefs.column_w))) }
		g := ui.frame_new(f32)
		g^ = sig.dragging ? 1 : b.hot_t
		b.custom_user = g
		b.custom = proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
			lit := (^f32)(user)^
			p := px1()
			s := ui.scale()
			c := draw.rect_center(b.rect)
			len_ := math.round(COLUMN_GRIP_PX * s)
			col := ui.srgb_step(hex(HEX_LINE), hex(HEX_WEAK), lit)
			for i in ([]f32{-1, 1}) {   // two short strokes, side by side
				x := math.round(c.x + i * 1.5 * p)
				draw.rect(dc, {{x - p * 0.5, c.y - len_ * 0.5}, {x + p * 0.5, c.y + len_ * 0.5}}, col, p * 0.5)
			}
		}
	}
}

// Far from the end of the conversation: the way back to it, over its bottom. It comes after a screen and a bit: a small scroll
// up to read something again needs no button.
go_bottom_pill :: proc(app: ^App, sb, main: ^ui.Box, avail, em: f32) {
	if sb == nil || app.chat.id == "" { return }
	far := ui.view_limit(sb) - sb.view_off.y > sb.size.y * GO_BOTTOM_SCREENS
	t := ui.anim(ui.key_from_string(0, "go_bottom"), far ? 1 : 0, GO_BOTTOM_RATE)
	if t < 0.02 { return }
	h := math.round(em * BUTTON_COMPACT_H_EM)
	w := math.round(em * GO_BOTTOM_W_EM)
	y := sb.rect.max.y - main.rect.min.y - h - em * (0.2 + 0.6 * t)
	ui.next({fixed_x = math.round((avail - w) * 0.5), fixed_y = math.round(y), width = ui.px(w), height = ui.px(h), axis = .X, cross = .Center, cursor = .Hand})
	ui.a11y({role = .Button, name = "Go to the latest message"})
	b := ui.build_box({.Clickable, .Focusable}, "###go_bottom")
	d := ui.frame_new(f32)
	d^ = t
	b.custom_user = d
	b.custom = proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
		a := (^f32)(user)^
		r := (b.rect.max.y - b.rect.min.y) * 0.5
		draw.box_shadow(dc, b.rect, radii4(r), 8 * ui.scale(), {0, 0, 0, 0.6 * a})
		draw.rect(dc, b.rect, with_alpha(hex(b.hot_t > FADE_VISIBLE ? HEX_BG4 : HEX_BG3), a), r)
		draw.rect(dc, b.rect, with_alpha(hex(HEX_FLOATING_BORDER), a), r, px1())
	}
	sig := ui.signal(b)
	if sig.clicked {
		chat_scroll_event(app, Scroll_Signal.Go_Bottom)
		sb.view_target.y = ui.view_limit(sb)
	}
	if ui.parent(b) {
		ui.spacer(ui.fill())
		glyph(lucide.CHEVRON_DOWN, with_alpha(hex(HEX_TEXT_SOFT), t), math.round(em * ICON_SMALL))
		ui.spacer(ui.px(em * 0.3))
		text("t", "Latest", with_alpha(hex(HEX_TEXT_SOFT), t), ui.Style_Mod{font_size = math.round(em * FS_SMALL)})
		ui.spacer(ui.fill())
	}
}

// The keyboard scrolls the conversation, before this build reads where it is. Page Up and Page Down whatever has the focus
// (the composer too: the conversation is what one reads while typing); the arrows, Home and End when they mean nothing else:
// not in a text field, not while the focus is moved with the keyboard (a click gives a button the focus, and no ring).
chat_keys :: proc(app: ^App, sb: ^ui.Box, em: f32) -> (moved: bool) {
	if overlay_open(app) { return }
	limit := ui.view_limit(sb)
	y := sb.view_target.y
	if ui.key_press(.Page_Up) { y -= sb.size.y * PAGE_SCROLL }
	if ui.key_press(.Page_Down) { y += sb.size.y * PAGE_SCROLL }
	f := ui.box_from_key(ui.focus_key())
	top := false
	if f == nil || (.Text_Input not_in f.flags && !app.state.focus_visible) {
		if ui.key_press(.Up) { y -= em * LINE_SCROLL_EM }
		if ui.key_press(.Down) { y += em * LINE_SCROLL_EM }
		if ui.key_press(.Home) { y, top = 0, true }
		if ui.key_press(.End) { y = limit }
	}
	y = clamp(y, 0, limit)
	moved = y != sb.view_target.y
	if moved { ui.scrollbar_reveal(sb) }
	sb.view_target.y = y
	// (Home: the start as such, the pages read before it on the way included. Page Up stopped at the top is a place like any
	// other: a page read then comes above it, and the view stays on what it shows)
	if top { ui.view_top(sb) }
	return
}

chat_header :: proc(app: ^App, em: f32) {
	h := math.round(em * (app.chat.have_self && app.chat.self.parent != "" ? 4.3 : 3.3))   // (a sub-agent: a breadcrumb line above its title)
	ui.next({width = ui.fill(), height = ui.px(h), axis = .X, cross = .Center})
	if ui.row(.Center, id = "###hdr") {
		b := ui.parent_box()
		d := ui.frame_new(Bar_Draw)
		d^ = {hex(HEX_HEADER_TOP), hex(HEX_HEADER_BOTTOM), false}
		b.custom = bar_draw
		b.custom_user = d
		ui.spacer(ui.px(em * 1.3))
		s := find_session(app, app.chat.id)
		if s == nil && app.chat.have_self { s = &app.chat.self }   // (a sub-agent, or an old session: not in the sidebar's list)
		if back := back_target(app); back != "" {
			// the way back up: to the session drilled down from, or the parent
			if bevel_button("###back", "", lucide.ARROW_LEFT, .Normal, ui.px(math.round(em * BUTTON_H_EM)), math.round(em * BUTTON_H_EM)).clicked { go_back(app) }
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
						if back_target(app) == app.chat.self.parent { go_back(app) } else { drill_down(app, app.chat.self.parent) }
					}
					if ui.parent(pb) {
						text("p", ellipsize(parent, CRUMB_PARENT_CHARS), ps.hovering ? accent() : hex(HEX_WEAK), ui.Style_Mod{font_size = math.round(em * FS_SMALL)})
					}
					text("s", "  ›  sub-agent", hex(HEX_FAINT), ui.Style_Mod{font_size = math.round(em * FS_SMALL)})
				}
			}
			title := s != nil ? s.title : "New session"
			if s != nil && renaming_at(app, s.id, .Header) {
				rename_in_place(app, em, math.round(em * FS_HEADING), em * 1.5, fit = true)
			} else {
				ui.next({width = ui.fill(), height = ui.px(em * 1.5), axis = .X, cross = .Center})
				tb := ui.build_box(s != nil ? {.Clickable} : {}, "###title_b")
				if s != nil && ui.signal(tb).double_clicked { rename_inline(app, s.id, .Header) }
				if ui.parent(tb) {
					text("title", title != "" ? title : "Untitled", hex(HEX_BRIGHT), ui.Style_Mod{font_size = math.round(em * FS_HEADING), height = ui.px(em * 1.5)}, ui.fill())
				}
			}
			dir := s != nil ? s.directory : app.chat.new_dir
			text("dir", dir != "" ? dir : "default folder", hex(HEX_FAINT), ui.Style_Mod{font = app.mono, font_size = math.round(em * FS_SMALL), height = ui.px(em * 1.2), flags = dir != "" ? {.Selectable} : {}}, ui.fill())
			ui.spacer(ui.fill())
		}
		c := &app.chat
		// (its title edited: the line is the title's, the figures and the sub-agents wait)
		editing := s != nil && renaming_at(app, s.id, .Header)
		if !editing && len(c.children) > 0 && !(app.cx.docked_w > 0 && app.cx.docked_w < em * HEADER_FIGURES_MIN_EM && len(active_children(app)) == 0) {
			subagents_button(app, em)
			ui.spacer(ui.px(em * 0.6))
		}
		// (narrow, as a panel of the dock: the title first, the figures are in the statistics)
		narrow := editing || app.cx.docked_w > 0 && app.cx.docked_w < em * HEADER_FIGURES_MIN_EM
		if !narrow && c.tokens_in + c.tokens_out > 0 {
			if pill_button("###tok", fmt.tprintf("%s in · %s out", kfmt(c.tokens_in + c.cache_read), kfmt(c.tokens_out)), {}, lucide.ZAP).clicked { stats_toggle(app) }
			ui.spacer(ui.px(em * 0.4))
		}
		if !narrow && c.cost > 0 {
			if pill_button("###cost", fmt.tprintf("$%.2f", c.cost), hex(HEX_GREEN)).clicked { stats_toggle(app) }
			ui.spacer(ui.px(em * 0.4))
		}
		if c.busy {
			ui.spacer(ui.px(em * 0.4))
			if bevel_button("###stop", "Stop", lucide.SQUARE, .Danger, height = math.round(em * BUTTON_COMPACT_H_EM)).clicked { interrupt_session(app, c.id) }
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

messages :: proc(app: ^App, em: f32) {
	app.chat.view_box = nil
	c := &app.chat
	ui.spacer(ui.px(em * 1.2))
	subagent_banner(app, em)
	// Scrolling up reads the pages before this one by itself (load_older): this row is what is seen when it gets here first.
	if c.older != "" {
		ui.next({width = ui.fill(), height = ui.px(math.round(em * 2.4)), axis = .X, cross = .Center})
		if ui.row(.Center, id = "###older") {
			ui.spacer(ui.fill())
			if c.loading_older {
				scanner("###older_bar", accent(), math.round(em * 5), math.round(em * 0.9))
				ui.spacer(ui.px(em * 0.7))
			}
			if ui.tags("weak") { text("older_t", c.older_failed > 0 ? "Earlier messages could not be read: scroll to try again" : "Loading earlier messages…", hex(HEX_FAINT), ui.Style_Mod{font_size = math.round(em * FS_NOTE)}) }
			ui.spacer(ui.fill())
		}
		ui.spacer(ui.px(em * 0.6))
	}
	view := chat_view(app)
	if view == .Loading && len(c.messages) == 0 {
		ui.next({width = ui.fill(), height = ui.px(em * 2), text_align = .Center})
		if ui.tags("weak") { ui.label("Loading the conversation…###loading") }
	}
	if view == .Failed { chat_failed(app, em) }
	// Only the messages near the view are built (the toolkit's lazy column): the others stand as a space of the height they
	// had when last built. A long conversation, Markdown and all, made every frame slow. A find reads them all once for a needle,
	// a slice at each frame (its sweep: the window never freezes on a long conversation); everything is built while the
	// conversation loads; the last message always (it grows while streaming).
	// (The item is the if's block, like a row's; the column ends with this block: the space of the last messages skipped
	// goes before what follows.)
	{
		lz := ui.lazy_begin(all = app.chat.loading, sweep = ui.find_sweep())
		// (a view going back to where it was: the column keeps it on its message, however the heights around it settle. A page read
		// above: the message the view holds is built whatever, frame moves the view by as much as the page pushed it down. Copied:
		// a click in this build changes the state that owns them)
		back, keep := "", ""
		back_dy: f32
		#partial switch s in app.chat_scroll {
		case Scroll_Restoring: back, back_dy = strings.clone(s.msg, context.temp_allocator), s.dy
		case Scroll_Anchored:  keep = strings.clone(s.keep, context.temp_allocator)
		}
		restore := back != "" && !c.loading
		if restore { ui.lazy_pin(lz, fmt.tprintf("###msg_%s", back), back_dy) }
		top_seen := false   // the first message under the top of the view, for Back and Forward (subagents.odin nav_mark)
		for &m, i in c.messages {
			// (by its id: a page read before it does not change what it is, its height is still known)
			if m.id != "" && m.lazy_id == "" { m.lazy_id = fmt.aprintf("###msg_%s", m.id, allocator = c.alloc) }   // (once: this is every message, at every build)
			id := m.id != "" ? m.lazy_id : fmt.tprintf("###msg_end%d", len(c.messages) - i)
			held := m.id != "" && (m.id == back || m.id == keep)
			if ui.lazy_item(lz, id, always = i == len(c.messages) - 1 || held) {
				item := ui.parent_box()
				if sb := lz.scroll; sb != nil {
					if !top_seen && m.id != "" && item.rect.max.y > sb.rect.min.y {
						top_seen = true
						app.chat.view_msg, app.chat.view_dy, app.chat.view_box = m.id, sb.rect.min.y - item.rect.min.y, item
					}
				}
				message(app, c, &m, i, em)
				ctx_check(app, ui.parent_box(), .Message, m.id)
				// (what was made while this message was the last: up to the next one; before the first message, at the first)
				from := i == 0 ? 0 : m.created
				to := i + 1 < len(c.messages) ? c.messages[i + 1].created : max(f64)
				for a in chat_artifacts_between(app, from, to) { artifact_card(app, a, em) }
			}
		}
		if restore {
			// (what the first layouts say of the heights around it is not what the next ones find: it stays a few builds)
			found, moved := ui.lazy_pinned(lz)
			chat_scroll_event(app, Scroll_Restore_Held{found, moved})
			app.settle = max(app.settle, FRAMES_AFTER_INPUT)
		}
	}
	// The line of a run stands in the room the end of the conversation keeps anyway: the height is the same with it and without it, so
	// the bottom does not move when a run starts or ends. (It came on top of that room, and took four lines for one word.)
	goal_reason_line(app, em)
	foot := math.round(em * CHAT_FOOT_EM)
	if c.busy {
		line := math.round(em * WORKING_LINE_EM)
		ui.next({width = ui.fill(), height = ui.px(line), axis = .X, cross = .Center})
		if ui.row(.Center, id = "###working") {
			ui.spacer(ui.px(em * 0.4))
			throbber(app, "###wl", accent(), math.round(em * 7), math.round(em * 0.9), em)
			ui.spacer(ui.fill())
			if hint_action("###stop_hint", "Esc to stop", em) { interrupt_session(app, c.id) }
		}
		foot -= line
	}
	ui.spacer(ui.px(foot))
}

// The first page was not read: why, and the way to try again.
@(private = "file")
chat_failed :: proc(app: ^App, em: f32) {
	r := &app.cx.chat_read
	ui.next({width = ui.fill(), flags = {.Text_Wrap}, text_align = .Center})
	if ui.tags("weak") { ui.paragraph(fmt.tprintf("The conversation could not be read: %s###read_failed", label_safe(r.message != "" ? r.message : "no answer"))) }
	ui.spacer(ui.px(em * 0.7))
	ui.next({width = ui.fill(), height = ui.children_sum(), axis = .X, cross = .Center})
	if ui.row(.Center, id = "###read_retry") {
		ui.spacer(ui.fill())
		if bevel_button("###retry", "Try again", lucide.REFRESH_CW, .Normal, disabled = !online(app)).clicked { chat_read(app) }
		ui.spacer(ui.fill())
	}
}

// One message of the conversation, in its lazy item.
message :: proc(app: ^App, c: ^Chat, m: ^Message, i: int, em: f32) {
	switch m.kind {
	case .User:        user_message(app, m, em)
	case .Assistant:
		prev := i > 0 ? &c.messages[i - 1] : nil
		next := i + 1 < len(c.messages) ? &c.messages[i + 1] : nil
		assistant_message(app, m, em, continues(prev, m), next != nil && continues(m, next) ? next : nil, prev)
	case .Synthetic:
		if m.sub_child != "" { subagent_result(app, m, em) } else { note_line(app, m, em, lucide.ZAP, m.text != "" ? first_line(m.text) : "synthetic message") }
	case .Shell:       note_line(app, m, em, lucide.SQUARE_TERMINAL, fmt.tprintf("$ %s", m.text))
	case .Compaction:  note_line(app, m, em, lucide.LIST, "Conversation compacted")
	case .Idle:        if i < len(c.messages) - 1 { turn_end(app, m, em) }
	case .Switch:      switch_line(app, m, em)
	case .Other:
	}
}

// The first line of Markdown that says something, as text: a preview shows no marks (headings, quotes, lists, emphasis).
preview_text :: proc(s: string) -> string {
	rest := s
	for line in strings.split_lines_iterator(&rest) {
		t := strings.trim_left(strings.trim_space(line), "#>-*+ \t")
		digits := 0
		for digits < len(t) && t[digits] >= '0' && t[digits] <= '9' { digits += 1 }
		if digits > 0 && digits + 1 < len(t) && (t[digits] == '.' || t[digits] == ')') && t[digits + 1] == ' ' { t = t[digits + 2:] }
		if t == "" || strings.trim(t, "-*_=~` ") == "" { continue }
		for mark in ([]string{"**", "__", "~~", "`"}) { t, _ = strings.remove_all(t, mark, context.temp_allocator) }
		return t
	}
	return ""
}

first_line :: proc(s: string) -> string {
	t := strings.trim_space(s)
	if i := strings.index_byte(t, '\n'); i >= 0 { return t[:i] }
	return t
}

note_line :: proc(app: ^App, m: ^Message, em: f32, icon: string, s: string) {
	ui.next({width = ui.fill(), height = ui.px(em * 1.9), axis = .X, cross = .Center})
	if ui.row(.Center, id = fmt.tprintf("###n_%s", m.id)) {
		glyph(icon, hex(HEX_FAINT), math.round(em * ICON_SMALL))
		ui.spacer(ui.px(em * 0.3))
		text("t", s, hex(HEX_FAINT), ui.Style_Mod{font_size = math.round(em * FS_NOTE)}, ui.fill())
	}
	ui.spacer(ui.px(em * 0.6))
}

// What the session changed (its model, its agent, its folder), across the conversation as the end of a turn is: what it was, what it is.
switch_line :: proc(app: ^App, m: ^Message, em: f32) {
	icon, word: string
	switch m.switched {
	case .Agent:    icon, word = lucide.BOT, "agent"
	case .Model:    icon, word = lucide.CPU, "model"
	case .Location: icon, word = lucide.FOLDER, "folder"
	}
	small := ui.Style_Mod{font = app.mono, font_size = math.round(em * FS_SMALL)}
	ui.next({width = ui.fill(), height = ui.px(em * 2), axis = .X, cross = .Center})
	if ui.row(.Center, id = fmt.tprintf("###sw_%s", m.id)) {
		groove(across = true)
		ui.spacer(ui.px(em * 0.6))
		glyph(icon, hex(HEX_FAINT), math.round(em * ICON_SMALL))
		ui.spacer(ui.px(em * 0.35))
		text("w", word, hex(HEX_FAINT), small)
		ui.spacer(ui.px(em * 0.5))
		if m.previous != "" && m.previous != m.text {
			text("p", m.previous, hex(HEX_FAINT), small)
			text("arrow", "  →  ", hex(HEX_FAINT), small)
		}
		text("n", m.text, hex(HEX_WEAK), small)
		ui.spacer(ui.px(em * 0.6))
		groove(across = true)
	}
	ui.spacer(ui.px(em * 0.8))
}

turn_end :: proc(app: ^App, m: ^Message, em: f32) {
	ui.next({width = ui.fill(), height = ui.px(em * 2), axis = .X, cross = .Center})
	if ui.row(.Center, id = fmt.tprintf("###e_%s", m.id)) {
		groove(across = true)
		if m.finish != "" && m.finish != "succeeded" {
			ui.spacer(ui.px(em * 0.5))
			col := m.finish == "interrupted" ? hex(HEX_YELLOW) : hex(HEX_RED)
			text("o", m.finish, col, ui.Style_Mod{font = app.mono, font_size = math.round(em * FS_SMALL)})
			ui.spacer(ui.px(em * 0.5))
			groove(across = true)
		}
	}
	ui.spacer(ui.px(em * 0.8))
}

USER_IMAGE_W_PX :: 320
USER_IMAGE_H_PX :: 220

user_message :: proc(app: ^App, m: ^Message, em: f32) {
	ui.spacer(ui.px(em * 0.4))
	ui.next({width = ui.fill(), height = ui.children_sum(), axis = .Y})
	if plate(fmt.tprintf("###u_%s", m.id), top = HEX_USER_PLATE_TOP, bottom = HEX_USER_PLATE_BOTTOM, radius = CARD_RADIUS, shadow = 8, rim = 0.09) {
		ui.spacer(ui.px(em * 0.75))
		ui.next({width = ui.fill(), height = ui.children_sum(), axis = .X})
		if ui.row(id = "###in") {
			ui.spacer(ui.px(em * 1.1))
			ui.next({width = ui.fill(), height = ui.children_sum(), axis = .Y})
			if ui.column() {
				ui.next({width = ui.fill(), height = ui.px(em * 1.4), axis = .X, cross = .Center})
				if ui.row(.Center, id = "###who") {
					glyph(lucide.USER, accent(), math.round(em * ICON_SMALL), em * 1.1)
					ui.spacer(ui.px(em * 0.2))
					text("you", "You", accent(), ui.Style_Mod{font = app.mono_bold, font_size = math.round(em * FS_SMALL)})
					ui.spacer(ui.fill())
					text("at", clock_text(m.created, app.prefs.clock24), hex(HEX_FAINT), ui.Style_Mod{font = app.mono, font_size = math.round(em * FS_CAPTION)})
				}
				ui.spacer(ui.px(em * 0.35))
				runs := link_runs(&m.text_runs, m.text, {color = hex(HEX_USER_TEXT)}, app.chat.alloc)
				ui.next({width = ui.fill(), flags = {.Selectable}})
				link_clicked(ui.rich_paragraph("###text", runs))
				if len(m.images) > 0 {
					ui.spacer(ui.px(em * 0.6))
					sc := ui.scale()
					image_strip(app, "###imgs", m.images[:], USER_IMAGE_W_PX * sc, USER_IMAGE_H_PX * sc)
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
Who_Draw :: struct { col: Color, live, glow: bool }   // (glow: the preference, read at the build)

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
			wd^ = {agent_color(m.agent), m.streaming, app.prefs.glow}
			rb.custom = proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
				d := (^Who_Draw)(user)
				s := ui.scale()
				c := draw.rect_center(b.rect)
				r := Rect{{c.x - 1.5 * s, b.rect.min.y}, {c.x + 1.5 * s, b.rect.max.y}}
				if d.live && d.glow {
					a := 0.15 + 0.15 * (0.5 + 0.5 * math.sin(f32(ui.now_ms()) * PULSE_RATE))
					draw.box_shadow(dc, r, radii4(1.5 * s), 4 * s, with_alpha(d.col, a))
				}
				draw.rect(dc, r, d.live ? d.col : with_alpha(d.col, 0.75), 1.5 * s)
			}
			rb.custom_user = wd
			if m.streaming { animate(app) }
			ui.spacer(ui.px(em * 0.4))
			name := m.agent != "" ? m.agent : "assistant"
			text("ag", strings.to_upper(name[:1], context.temp_allocator), agent_color(m.agent), ui.Style_Mod{font = app.mono_bold, font_size = math.round(em * FS_SMALL)})
			text("ag2", name[1:], agent_color(m.agent), ui.Style_Mod{font = app.mono_bold, font_size = math.round(em * FS_SMALL)})
			if m.model != "" {
				text("dot", "  ·  ", hex(HEX_FAINT), ui.Style_Mod{font_size = math.round(em * FS_SMALL)})
				text("md", m.model, hex(HEX_WEAK), ui.Style_Mod{font = app.mono, font_size = math.round(em * FS_SMALL)})
			}
			ui.spacer(ui.fill())
			text("at", clock_text(m.created, app.prefs.clock24), hex(HEX_FAINT), ui.Style_Mod{font = app.mono, font_size = math.round(em * FS_CAPTION)})
		}
		ui.spacer(ui.px(em * 0.4))
		}
		for &p, i in m.parts {
			pid := fmt.tprintf("%s_%d", m.id, i)
			switch p.kind {
			case .Text:
				if len(p.text) > 0 {
					markdown.view(md_doc(&app.chat, pid), pid, string(p.text[:]), md_config(app, hex(HEX_ANSWER_TEXT)))
					ui.spacer(ui.px(em * 0.6))
				}
			case .Reasoning: reasoning_part(app, &p, pid, em)
			case .Tool:
				if !plain_tool(&p) { subagent_card(app, &p, pid, em); break }
				// consecutive calls share the timeline's rail, across the steps that go on from each other
				above := i > 0 ? plain_tool(&m.parts[i - 1]) : cont && prev != nil && len(prev.parts) > 0 && plain_tool(&prev.parts[len(prev.parts) - 1])
				below := i + 1 < len(m.parts) ? plain_tool(&m.parts[i + 1]) : next != nil && len(next.parts) > 0 && plain_tool(&next.parts[0])
				tool_part(app, &p, pid, em, above, below)
				ctx_check(app, ui.prev_box(fmt.tprintf("###tp_%s", pid)), .Tool, m.id, i)
			}
		}
		if app.prefs.usage && !m.streaming && m.tokens_out > 0 && m.finish == "stop" {
			ui.next({width = ui.fill(), height = ui.px(em * 1.5), axis = .X, cross = .Center})
			if ui.row(.Center, id = "###foot") {
				text("tk", fmt.tprintf("%s in · %s out%s", kfmt(m.tokens_in + m.cache_read), kfmt(m.tokens_out), m.cost > 0 ? fmt.tprintf(" · $%.3f", m.cost) : ""), hex(HEX_FAINT), ui.Style_Mod{font = app.mono, font_size = math.round(em * FS_CAPTION)})
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
	chat_scroll_event(app, Scroll_Anchor{head, head.rect.min.y})
}

@(private = "file")
head_draw :: proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
	if b.hot_t > FADE_VISIBLE {
		r := b.rect
		draw.rect(dc, r, {1, 1, 1, 0.035 * b.hot_t}, 7 * ui.scale())
	}
}

tool_icon :: proc(name: string) -> string {
	switch {
	case strings.contains(name, "bash") || strings.contains(name, "shell") || strings.contains(name, "pty"): return lucide.SQUARE_TERMINAL
	case name == "read" || name == "view":                                                             return lucide.FILE
	case strings.contains(name, "edit") || name == "write" || strings.contains(name, "patch"):           return lucide.PENCIL
	case name == "glob" || name == "grep" || name == "list" || strings.contains(name, "search") || name == "find": return lucide.SEARCH
	case strings.contains(name, "web") || strings.contains(name, "fetch") || strings.contains(name, "browser"): return lucide.GLOBE
	case name == "task" || strings.contains(name, "agent"):                                              return lucide.BOT
	case strings.contains(name, "todo"):                                                                 return lucide.LIST
	}
	return lucide.WRENCH
}

status_color :: proc(s: Tool_Status) -> Color {
	switch s {
	case .Pending, .Unknown: return hex(HEX_FAINT)
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
		lit := PULSE_LIT_MIN + PULSE_LIT_SPAN * (0.5 + 0.5 * math.sin(f32(ui.now_ms()) * PULSE_RATE))
		draw_lamp(dc, {x, cy}, math.round(sz * 0.85), status_color(d.status), lit)
	case .Done:    draw_pip(dc, {x, cy}, sz, hex(HEX_TOOL_DONE_PIP))
	case .Error:   draw_pip(dc, {x, cy}, sz, hex(HEX_RED))
	case .Unknown: draw_pip(dc, {x, cy}, sz, status_color(d.status))
	}
}

TOOL_INPUT_LINES_MAX    :: 40
TOOL_ERROR_LINES_FOLDED :: 6
TOOL_IMAGE_OPEN_W_PX    :: 520
TOOL_IMAGE_OPEN_H_PX    :: 360
TOOL_IMAGE_W_PX         :: 240
TOOL_IMAGE_H_PX         :: 150

// A tool call on the timeline: a flat row (its header lights under the pointer), its input and output in wells when
// open. `above`, `below`: calls right before and after it, joined by the rail.
tool_part :: proc(app: ^App, p: ^Part, pid: string, em: f32, above := false, below := false) {
	open := part_open(app, p.tool_id != "" ? p.tool_id : pid, app.prefs.expand_tools)
	head_h := math.round(em * 2.0)
	running := p.status == .Running || p.status == .Pending
	if running { animate(app) }
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
		edits := tool_kind(p.tool_name) == .Edit
		if edits { _ = part_patch(p, app.chat.alloc) }
		if ui.parent(hb) {
			ui.spacer(ui.px(em * 0.5))
			failed := p.status == .Error
			glyph(tool_icon(p.tool_name), failed ? hex(HEX_RED) : hex(HEX_FAINT), math.round(em * ICON_REGULAR))
			ui.spacer(ui.px(em * 0.35))
			text("nm", p.tool_name != "" ? p.tool_name : "tool", failed ? hex(HEX_ERROR_TEXT) : running ? hex(HEX_TEXT) : hex(HEX_WEAK), ui.Style_Mod{font = app.mono_bold, font_size = math.round(em * FS_NOTE)})
			ui.spacer(ui.px(em * 0.6))
			text("sj", p.subject, hex(HEX_WEAK), ui.Style_Mod{font = app.mono, font_size = math.round(em * FS_SMALL)}, ui.fill())
			ui.spacer(ui.px(em * 0.4))
			if edits && p.added + p.removed > 0 {
				st := ui.Style_Mod{font = app.mono, font_size = math.round(em * FS_CAPTION)}
				if p.added > 0 { text("ad", fmt.tprintf("+%d", p.added), hex(HEX_GREEN), st); ui.spacer(ui.px(em * 0.3)) }
				if p.removed > 0 { text("rm", fmt.tprintf("−%d", p.removed), hex(HEX_RED), st); ui.spacer(ui.px(em * 0.3)) }
				ui.spacer(ui.px(em * 0.2))
			}
			// how long it took, or has taken so far (it counts while it runs: animate above)
			// (and when, under the pointer: its start and its end. A click on it is the header's)
			if took := tool_elapsed(p, running, now_epoch_ms()); took != "" {
				ui.next({width = ui.text_size(0), height = ui.pct(1), fg = running ? hex(HEX_TEXT_SOFT) : hex(HEX_FAINT), font = app.mono, font_size = math.round(em * FS_CAPTION), text_pad = 0})
				tk := ui.signal(ui.build_box({.Draw_Text, .Clickable}, fmt.tprintf("%s###tk", took)))
				if tk.clicked { part_toggle(app, p.tool_id != "" ? p.tool_id : pid, hb) }
				if ui.hovered_for(tk, TOOLTIP_DELAY_S) { if ui.tooltip() { ui.tooltip_text(tool_when(p, running, now_epoch_ms(), app.prefs.clock24)) } }
				ui.spacer(ui.px(em * 0.5))
			}
			glyph(open ? lucide.CHEVRON_DOWN : lucide.CHEVRON_RIGHT, hex(HEX_FAINT), math.round(em * ICON_TINY))
			ui.spacer(ui.px(em * 0.6))
		}
		// a shell call: it can go to the background while it holds the turn, and says so once it is there
		if bg, bg_running := part_background(app, p); bg || (running && tool_kind(p.tool_name) == .Shell) {
			ui.next({width = ui.fill(), height = ui.px(math.round(em * 1.5)), axis = .X, cross = .Center})
			if ui.row(.Center, id = "###bgrow") {
				ui.spacer(ui.px(em * 0.5))
				if bg {
					if bg_running { session_lamp("###bgl", LAMP_BACKGROUND, em); ui.spacer(ui.px(em * 0.35)) }
					text("bgt", bg_running ? "in background" : "finished in background", hex(bg_running ? HEX_TEXT_SOFT : HEX_FAINT), ui.Style_Mod{font = app.mono, font_size = math.round(em * FS_CAPTION)})
				} else if hint_action("###bgpush", "push to background", em, app.mono, lucide.SEND_TO_BACK) {
					background_session(app, app.chat.id)
				}
			}
		}
		show_error := p.status == .Error && p.output != ""
		// (what changed in a file shows even folded, as images do: a screenshot, a diff are what one looks for)
		show_diff := edits && !open && p.status != .Error && p.patch != ""
		if open || show_error || show_diff || len(p.images) > 0 {
			ui.next({width = ui.fill(), height = ui.children_sum(), axis = .X})
			if ui.row(id = "###bodyrow") {
				ui.spacer(ui.px(em * 0.6))
				ui.next({width = ui.fill(), height = ui.children_sum(), axis = .Y})
				if ui.column() {
					if open {
						tool_body(app, p, em)
					} else if show_diff {
						diff_view(app, "###diff", p.diff, p.patch, em, DIFF_FOLDED_LINES, tool_diff_title(p))
					} else if show_error {
						mono_well("###output", p.output, em, TOOL_ERROR_LINES_FOLDED, hex(HEX_ERROR_TEXT), &p.output_well, app.chat.alloc)
					}
					if len(p.images) > 0 {
						ui.spacer(ui.px(em * 0.5))
						sc := ui.scale()
						image_strip(app, "###imgs", p.images[:], (open ? TOOL_IMAGE_OPEN_W_PX : TOOL_IMAGE_W_PX) * sc, (open ? TOOL_IMAGE_OPEN_H_PX : TOOL_IMAGE_H_PX) * sc)
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
	if ui.row(.Center, id = fmt.tprintf("###sl_%s", id)) { caption_title("l", s, "", em) }
}

// A title in capitals over what follows, `note` after it. Faint, in the mono face; in the edged style (Kernel) a stripe and
// the title in the accent, as a console's sections (gui_toolkit's section_header).
caption_title :: proc(id, title, note: string, em: f32, color := Color{}) {
	if ui.edged() {
		if ui.style({font = the_app.mono, font_size = math.round(em * FS_CAPTION / 0.85)}) {   // (section_header draws its title at 0.85)
			ui.section_header(fmt.tprintf("###ct_%s", id), title, note, "", color.a > 0 ? color : accent(), inline = true)
		}
		return
	}
	words := note != "" ? fmt.tprintf("%s  %s", title, note) : title
	text(id, words, hex(HEX_FAINT), ui.Style_Mod{font = the_app.mono_bold, font_size = math.round(em * FS_CAPTION)})
}

MONO_WELL_MAX_BYTES :: 20000   // of a tool's text, whatever the lines allow

// What a view read of a text, kept with it: a build of a text that did not change reads none of it again. A text is known by its
// place and its length; one that changed is in another place, or longer in the same (a part's text only grows in its buffer:
// apply_event gives a text that changed otherwise a new one). Kept with what owns the text (a part, a message), in the same memory.

// Where a text is cut to `max_lines` (`way`: what counts as a line, and how the cut is made), and how many lines are left out.
Text_Cut :: struct {
	src:       rawptr,
	n:         int,
	max_lines: int,
	way:       Cut_Way,
	body:      int,   // bytes shown (a Lines cut: the text up to there)
	extra:     int,
}

Cut_Way :: enum u8 { None, Lines, Read, Search }

text_cut_known :: proc(k: ^Text_Cut, s: string, max_lines: int, way: Cut_Way) -> bool {
	return k != nil && k.way == way && k.src == raw_data(s) && k.n == len(s) && k.max_lines == max_lines
}

text_cut_keep :: proc(k: ^Text_Cut, s: string, max_lines: int, way: Cut_Way, body, extra: int) {
	if k != nil { k^ = {src = raw_data(s), n = len(s), max_lines = max_lines, way = way, body = body, extra = extra} }
}

// mono_cut, counted once for a text (`k` nil: each time).
mono_cut_kept :: proc(k: ^Text_Cut, s: string, max_lines: int) -> (body: string, extra: int) {
	if text_cut_known(k, s, max_lines, .Lines) { return s[:k.body], k.extra }
	body, extra = mono_cut(s, max_lines)
	text_cut_keep(k, s, max_lines, .Lines, len(body), extra)
	return
}

// A text as runs, its web addresses links (ui.rich_links), kept with the text and the style they were made with. A text that grew
// in its place is read again from its last line before the old end: an address never spans a line, what is before it stays.
Link_Runs :: struct {
	src:   rawptr,
	n:     int,
	style: ui.Rich_Style,
	runs:  [dynamic]ui.Rich_Run,   // (in the memory of the text's owner: cleared and filled again, it does not grow past the text)
}

link_runs :: proc(k: ^Link_Runs, s: string, style: ui.Rich_Style, a: mem.Allocator) -> []ui.Rich_Run {
	same := k.src == raw_data(s) && k.style == style
	if same && k.n == len(s) { return k.runs[:] }
	if k.runs.allocator.procedure == nil { k.runs.allocator = a }
	from := 0
	if same && k.n < len(s) {
		if nl := strings.last_index_byte(s[:k.n], '\n'); nl >= 0 { from = nl + 1 }
	}
	// the runs before `from` stay, the one across it is cut there (a link has no line break: it is text)
	// (from > 0: they are runs of this text, in this place)
	kept := 0
	for from > 0 && kept < len(k.runs) {
		r := &k.runs[kept]
		start := int(uintptr(raw_data(r.text)) - uintptr(raw_data(s)))
		if start >= from { break }
		if start + len(r.text) > from { r.text = r.text[:from - start] }
		kept += 1
	}
	resize(&k.runs, kept)
	ui.rich_links(s[from:], style, &k.runs)
	k.src, k.n, k.style = raw_data(s), len(s), style
	return k.runs[:]
}

// What a well made of its text: where it is cut, its runs.
Well_Kept :: struct {
	cut:  Text_Cut,
	runs: Link_Runs,
}

// Monospace text in a sunken well, at most `max_lines` lines (the rest is counted). `kept` (in `kept_in`, the memory of the text's
// owner): what the well made of the text, for the next build. Without it, a text of the frame: read at each build.
mono_well :: proc(id: string, s: string, em: f32, max_lines: int, color := Color{}, kept: ^Well_Kept = nil, kept_in := mem.Allocator{}) {
	body, extra := mono_cut_kept(kept != nil ? &kept.cut : nil, s, max_lines)
	ui.next({width = ui.fill(), height = ui.children_sum(), axis = .Y})
	if well(id, radius = 6, base = HEX_CODE_WELL) {
		ui.spacer(ui.px(em * 0.5))
		mono_text(body, extra, em, 0.75, color, kept = kept != nil ? &kept.runs : nil, kept_in = kept_in)
		ui.spacer(ui.px(em * 0.5))
	}
}

// What mono_well holds, for a well that holds more: `body` (already cut), the lines left out, `pad` em on each side (`flush`: the text's own,
// none). `kept`: its runs, kept with the text (in `kept_in`).
mono_text :: proc(body: string, extra: int, em, pad: f32, color := Color{}, flush := false, kept: ^Link_Runs = nil, kept_in := mem.Allocator{}) {
	ui.next({width = ui.fill(), height = ui.children_sum(), axis = .X})
	if ui.row(id = "###r") {
		ui.spacer(ui.px(em * pad))
		style := ui.Rich_Style{font = the_app.mono, color = color.a > 0 ? color : hex(HEX_TOOL_OUTPUT)}
		runs: []ui.Rich_Run
		if kept != nil {
			runs = link_runs(kept, body, style, kept_in)
		} else {
			list := make([dynamic]ui.Rich_Run, context.temp_allocator)
			ui.rich_links(body, style, &list)
			runs = list[:]
		}
		m := ui.Style_Mod{width = ui.fill(), font_size = math.round(em * FS_NOTE), flags = {.Selectable}}
		if flush { m.text_pad = 0 }   // (its text starts at the pad, as a key above it)
		ui.next(m)
		link_clicked(ui.rich_paragraph("###t", runs))
		ui.spacer(ui.px(em * pad))
	}
	if extra > 0 {
		ui.next({width = ui.fill(), height = ui.px(em * 1.5), axis = .X, cross = .Center})
		if ui.row(.Center, id = "###more") {
			ui.spacer(ui.px(em * pad))
			text("m", fmt.tprintf("… %d more lines", extra), hex(HEX_FAINT), ui.Style_Mod{font = the_app.mono, font_size = math.round(em * FS_SMALL)})
		}
	}
}

// `s` cut to `max_lines` lines and MONO_WELL_MAX_BYTES: what is shown, and how many lines are left out.
mono_cut :: proc(s: string, max_lines: int) -> (body: string, extra: int) {
	body = s
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
	if len(body) > MONO_WELL_MAX_BYTES { body = body[:MONO_WELL_MAX_BYTES] }
	return
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
		glyph(lucide.LIGHTBULB, hex(HEX_FAINT), math.round(em * ICON_REGULAR))
		ui.spacer(ui.px(em * 0.3))
		// (a run over says no more about this part: it thought)
		text("t", p.done || !app.chat.busy ? "Thought" : "Thinking…", hex(HEX_WEAK), ui.Style_Mod{font_size = math.round(em * FS_NOTE)})
		ui.spacer(ui.px(em * 0.5))
		if !open {
			text("pv", preview_text(string(p.text[:])), hex(HEX_FAINT), ui.Style_Mod{font_size = math.round(em * FS_NOTE)}, ui.fill())
		} else { ui.spacer(ui.fill()) }
		glyph(open ? lucide.CHEVRON_DOWN : lucide.CHEVRON_RIGHT, hex(HEX_FAINT), math.round(em * ICON_TINY))
		ui.spacer(ui.px(em * 0.4))
	}
	if open {
		ui.next({width = ui.fill(), height = ui.children_sum(), axis = .X})
		if rail_row(fmt.tprintf("###rb_%s", pid), with_alpha(hex(HEX_WEAK), 0.4)) {
			ui.spacer(ui.px(em * 0.9))
			runs := link_runs(&p.text_runs, string(p.text[:]), {italic = true, color = hex(HEX_REASONING_TEXT)}, app.chat.alloc)
			ui.next({width = ui.fill(), font_size = math.round(em * FS_LABEL), flags = {.Selectable}})
			link_clicked(ui.rich_paragraph("###t", runs))
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
			goal_strip(app, em)
			activity_strip(app, em)
			for &p in app.permissions {
				if p.session == app.chat.id { permission_card(app, &p, em) }
			}
			forms_dock(app, em)
			queue_list(app, em)
			composer(app, em)
			activity_tray(app, em)
			ui.spacer(ui.px(em * 1.1))
		}
	}
}

permission_card :: proc(app: ^App, p: ^Permission, em: f32) {
	ui.next({width = ui.fill(), height = ui.children_sum(), axis = .Y})
	if plate(fmt.tprintf("###perm_%s", p.id), top = HEX_PERM_TOP, bottom = HEX_PERM_BOTTOM, radius = CARD_RADIUS, shadow = 8, rim = 0.1, border = with_alpha(hex(HEX_YELLOW), 0.55)) {
		ui.spacer(ui.px(em * 0.7))
		ui.next({width = ui.fill(), height = ui.children_sum(), axis = .X, cross = .Center})
		if ui.row(.Center, id = "###r") {
			ui.spacer(ui.px(em))
			glyph(lucide.SHIELD, hex(HEX_YELLOW), math.round(em * ICON_LARGE), em * 1.6)
			ui.spacer(ui.px(em * 0.5))
			ui.next({width = ui.fill(), height = ui.children_sum(), axis = .Y})
			if ui.column() {
				text("a", fmt.tprintf("Permission requested: %s", p.action), hex(HEX_YELLOW), ui.Style_Mod{font = app.mono_bold, font_size = math.round(em * FS_LABEL), height = ui.px(em * 1.5)}, ui.fill())
				detail := p.message != "" ? p.message : strings.join(p.resources, ", ", context.temp_allocator)
				text("d", detail, hex(HEX_PERM_DETAIL), ui.Style_Mod{font = app.mono, font_size = math.round(em * FS_SMALL), height = ui.px(em * 1.4)}, ui.fill())
			}
			ui.spacer(ui.px(em * 0.5))
			if bevel_button("###once", "Allow once", lucide.CHECK, .Accent, disabled = p.replying).clicked { reply_permission(app, p, "once") }
			ui.spacer(ui.px(em * 0.4))
			if bevel_button("###always", "Always", "", .Normal, disabled = p.replying).clicked { reply_permission(app, p, "always") }
			ui.spacer(ui.px(em * 0.4))
			if bevel_button("###reject", "Reject", lucide.X, .Danger, disabled = p.replying).clicked { reply_permission(app, p, "reject") }
			ui.spacer(ui.px(em))
		}
		ui.spacer(ui.px(em * 0.7))
	}
	ui.spacer(ui.px(em * 0.7))
}

COMPOSER_MAX_LINES   :: 12
COMPOSER_HINT_MIN_EM :: 44
COMPOSER_BUTTON_W_EM :: 2.6

composer :: proc(app: ^App, em: f32) {
	// Enter sends, Shift+Enter breaks the line (the editor itself breaks on Enter and commits on Ctrl+Enter). While a turn runs
	// one way queues and the other sends now: Enter and Ctrl+Enter, or in Ctrl+Enter mode Ctrl+Enter and Ctrl+Shift+Enter.
	submit, other := false, false
	keys := app.composer_focused && !app.cx.open[.Picker]
	// (the tray's keys with the focus nowhere too: a click on one of its rows leaves it there)
	if app.activity.open && !app.cx.open[.Picker] && (app.composer_focused || ui.focus_key() == 0) { activity_keys(app) }
	if keys { mention_keys(app) }
	if keys { slash_keys(app) }
	if keys { history_track(app) }
	// (wherever the focus is: this Escape must not stop the run)
	if queue_editing(app) && !overlay_open(app) && !history_browsing(app) && !mention_takes_escape(app) && ui.key_press(.Escape) { queue_edit_end(app, .Cancel) }
	if app.composer_focused && !app.prefs.ctrl_enter {   // (Ctrl+Enter mode: Enter breaks the line, the editor commits on Ctrl+Enter)
		if ui.key_press(.Return) { submit = true }
		if ui.key_press(.Return, {.Shift}) { area_insert(&app.composer, "\n") }
	}
	if app.composer_focused && app.prefs.ctrl_enter && ui.key_press(.Return, {.Ctrl, .Shift}) { submit, other = true, true }
	ui.next({width = ui.fill(), height = ui.children_sum(), axis = .Y})
	if well("###composer_well", radius = 11, base = HEX_COMPOSER_WELL, focus = app.composer_focused ? 1 : 0) {
		ui.spacer(ui.px(em * 0.45))
		queue_edit_banner(app, em)
		mention_list(app, em)
		slash_list(app, em)
		attachments_row(app, em)
		ui.next({width = ui.fill(), height = ui.children_sum(), axis = .X})
		if ui.row(id = "###edrow") {
			ui.spacer(ui.px(em * 0.35))
			if ui.tags("bare") {
				// Up and Down go through the history where they have nothing to move (the caret on the first line; going
				// through it, always); Down on the last line opens the tray of what runs. (Down moves the caret to the end
				// of the last line first: what tells is that it did not move.)
				down := false
				caret0 := app.composer.cursor
				if keys && ui.key_pressed_peek(.V, {.Ctrl}) && attach_paste(app) { _ = ui.key_press(.V, {.Ctrl}) }
				if keys && !app.activity.open {
					browsing := history_browsing(app)
					if ui.key_pressed_peek(.Up) && (browsing || composer_on_first_line(app)) {
						_ = ui.key_press(.Up)
						history_step(app, 1)
					}
					if browsing {
						if ui.key_press(.Down) { history_step(app, -1) }
						if ui.key_press(.Escape) { history_leave(app, true) }
					} else {
						down = ui.key_pressed_peek(.Down)
					}
				}
				// Escape while a turn runs stops it, and the composer keeps the keyboard (one goes on writing what made one stop it);
				// the editor would have let go of it. With nothing running, Escape lets go of it, as everywhere.
				if app.composer_focused && app.chat.busy && !overlay_open(app) && !mention_takes_escape(app) && !history_browsing(app) && !queue_editing(app) && ui.key_press(.Escape) {
					interrupt_session(app, app.chat.id)
				}
				// typed with nothing focused (a click in the conversation took the keyboard away): the composer takes it. Not a
				// space (a focused button's), nor while a dialog is over the window or a box (the terminal) has the keyboard.
				if !overlay_open(app) && ui.focus_key() == 0 && typed_word(app) { ui.type_to_field(ui.key_from_string(ui.parent_box().key, "###composer")) }
				ui.next({width = ui.fill(), font_size = math.round(em * FS_BODY), text_pad = em * 0.5})
				res := ui.text_edit("###composer", &app.composer, "Ask anything…", wrap = true, auto_height = true, min_lines = 2, max_lines = COMPOSER_MAX_LINES)
				app.composer_focused = res.focused
				mention_track(app)
				slash_track(app)
				if app.cx.focus_composer { ui.set_focus(res.box.key); app.cx.focus_composer = false }
				ctx_check(app, res.box, .Composer)
				if res.committed { submit, other = true, !app.prefs.ctrl_enter }
				if down && app.composer.cursor == caret0 { activity_open(app) }
				if res.changed { activity_close(app) }   // (typing: what is written is what matters now)
				drafts_track(app)   // (kept on disk a moment after it changes, however: typed, sent, put back)
			}
			ui.spacer(ui.px(em * 0.35))
		}
		// toolbar
		fit := composer_fit(app, em)
		ui.next({width = ui.fill(), height = ui.px(math.round(em * 2.8)), axis = .X, cross = .Center})
		if ui.row(.Center, id = "###tools") {
			ui.spacer(ui.px(em * 0.6))
			// what goes with the prompt, then who answers it and with what
			ui.a11y({role = .Button, name = "Attach files"})
			att := bevel_button("###attach", "", lucide.PAPERCLIP, .Ghost, height = math.round(em * BUTTON_COMPACT_H_EM), quiet = true)
			if att.clicked { attach_pick(app) }
			if ui.hovered_for(att, TOOLTIP_DELAY_S) { if ui.tooltip() { ui.tooltip_text("Attach files: images, PDF, text  (or paste, or drop them here)") } }
			ui.spacer(ui.px(em * 0.1))
			agent := shown_agent(app)
			if agent == "" { agent = "build" }
			asig := bevel_button("###agent", agent, lucide.BOT, .Ghost, height = math.round(em * BUTTON_COMPACT_H_EM), quiet = true, lit = app.cx.open[.Picker] && app.picker.id == "agent")
			if asig.clicked { if app.cx.open[.Picker] && app.picker.id == "agent" { app.cx.open[.Picker] = false } else { picker_open(app, "agent", asig.box.rect) } }
			ui.spacer(ui.px(em * 0.4))
			model, _ := shown_model(app)
			if model == "" { model = "default model" }
			msig := bevel_button("###model", model, lucide.CPU, .Ghost, height = math.round(em * BUTTON_COMPACT_H_EM), quiet = true, lit = app.cx.open[.Picker] && app.picker.id == "model")
			if msig.clicked { if app.cx.open[.Picker] && app.picker.id == "model" { app.cx.open[.Picker] = false } else { picker_open(app, "model", msig.box.rect) } }
			variant_button(app, em)
			ui.spacer(ui.px(em * 0.4))
			if app.chat.id != "" { approval_button(app, em) }   // (a session's: a new one has none yet)
			ui.spacer(ui.fill())
			held := composer_held(app)
			if app.column_w > em * COMPOSER_HINT_MIN_EM && fit < 1 {   // (room for it beside the agent and model buttons)
				if held {
					text("hint", attaching(app) ? "reading the attachment…" : "starting the session…", hex(HEX_FAINT), ui.Style_Mod{font = app.mono, font_size = math.round(em * FS_CAPTION)})
				} else if history_browsing(app) {
					text("hint", fmt.tprintf("history %d/%d   ·   ", app.history.at, len(app.history.view)), hex(HEX_FAINT), ui.Style_Mod{font = app.mono, font_size = math.round(em * FS_CAPTION)})
					if hint_action("###hist_back", "Esc  back to your text", em, app.mono) { history_leave(app, true) }
				} else if queue_editing(app) {
					if hint_action("###h_save", app.prefs.ctrl_enter ? "Ctrl+Enter  save" : "Enter  save", em, app.mono) { submit = true }
				} else if as := composer_send_as(app); as != .Idle {
					// (each says what it does, and does it)
					first, second := as == .Queue ? "queue" : "steer", as == .Queue ? "steer" : "queue"
					if hint_action("###h_first", fmt.tprintf("%s  %s", app.prefs.ctrl_enter ? "Ctrl+Enter" : "Enter", first), em, app.mono) { submit = true }
					text("h_dot", "   ·   ", hex(HEX_FAINT), ui.Style_Mod{font = app.mono, font_size = math.round(em * FS_CAPTION)})
					if hint_action("###h_second", fmt.tprintf("%s  %s", app.prefs.ctrl_enter ? "Ctrl+Shift+Enter" : "Ctrl+Enter", second), em, app.mono) { submit, other = true, true }
				} else {
					text("hint", app.prefs.ctrl_enter ? "Ctrl+Enter  send   ·   Enter  new line" : "Enter  send   ·   Shift+Enter  new line", hex(HEX_FAINT), ui.Style_Mod{font = app.mono, font_size = math.round(em * FS_CAPTION)})
				}
			}
			ui.spacer(ui.px(em * 0.8))
			composer_panels(app, em)
			if app.chat.busy {
				if bevel_button("###stop2", "", lucide.SQUARE, .Danger, ui.px(math.round(em * COMPOSER_BUTTON_W_EM)), math.round(em * BUTTON_H_EM)).clicked { interrupt_session(app, app.chat.id) }
				ui.spacer(ui.px(em * 0.4))
			}
			empty := len(strings.trim_space(ui.area_string(&app.composer))) == 0 && len(app.cx.attachments) == 0
			// (what it does, while that is not what it usually does)
			send_label, send_icon := "", lucide.SEND_HORIZONTAL
			if queue_editing(app) {
				send_label, send_icon = "Save", lucide.CHECK
			} else {
				switch composer_send_as(app) {
				case .Idle:
				case .Queue: send_label, send_icon = "Queue", lucide.LIST
				case .Steer: send_label = "Steer"
				}
			}
			if app.column_w <= em * QUEUE_WORDS_MIN_EM || fit >= 2 { send_label = "" }   // (narrow, its glyph says it: the toolbar has no room)
			send_w: Maybe(ui.Size) = send_label == "" ? ui.px(math.round(em * COMPOSER_BUTTON_W_EM)) : nil
			if bevel_button("###send", send_label, send_icon, .Accent, send_w, math.round(em * BUTTON_H_EM), disabled = empty || !online(app) || held).clicked { submit = true }
			ui.spacer(ui.px(em * 0.55))

			composer_pickers(app, agent, em)
		}
	}
	if submit { submit_prompt(app, other) }
}

// What the composer's toolbar leaves out to stay within itself: 1, the keys' hint; 2, the send button's word too. A step is taken
// when what it held went past its end in the last layout (a long model's name, Stop beside "Steer"), and given back once the row
// is wider than where it went past (by a margin: what came back would not go past at once).
@(private = "file")
composer_fit :: proc(app: ^App, em: f32) -> int {
	f := &app.cx.composer_fit
	tools := ui.prev_box("###tools")
	if tools == nil { return f.level }
	w := tools.rect.max.x - tools.rect.min.x
	end: f32
	for c := tools.first; c != nil; c = c.next {
		if .Floating_X not_in c.flags { end = max(end, c.rect.max.x) }
	}
	if end > tools.rect.max.x + 0.5 && f.level < len(f.at) {
		f.at[f.level] = w
		f.level += 1
	}
	for f.level > 0 && w > f.at[f.level - 1] + em * COMPOSER_FIT_SLACK_EM { f.level -= 1 }
	return f.level
}

// The browser and the shells, lit while they are open.
@(private = "file")
composer_panels :: proc(app: ^App, em: f32) {
	size := math.round(em * BUTTON_H_EM)
	panel :: proc(app: ^App, id, icon, name, tip, command: string, lit: bool, size, em: f32) {
		ui.a11y({role = .Button, name = name})
		sig := glyph_button(id, icon, size, lit ? accent() : Color{})
		if sig.clicked { command_run(app, command_find(command)) }
		if ui.hovered_for(sig, TOOLTIP_DELAY_S) { if ui.tooltip() { ui.tooltip_text(tip) } }
		ui.spacer(ui.px(em * 0.4))
	}
	if preview_available() { panel(app, "###preview_btn", lucide.GLOBE, "Preview panel", "Preview panel  (Ctrl+Shift+B)", "view.preview", app.preview.open, size, em) }
	panel(app, "###terminal_btn", lucide.SQUARE_TERMINAL, "Terminal", "Terminal  (Ctrl+Shift+T)", "view.terminal", app.cx.terms.open, size, em)
}

composer_pickers :: proc(app: ^App, agent: string, em: f32) {
	// the agent and the model: pickers searched as one types
	agent_items := make([dynamic]Pick_Item, context.temp_allocator)
	agent_ids := make([dynamic]string, context.temp_allocator)
	for a in app.agents {
		if a.mode == "subagent" { continue }
		append(&agent_items, Pick_Item{label = a.name != "" ? a.name : a.id, detail = a.mode == "primary" ? "" : a.mode, current = a.id == agent, color = agent_color(a.id)})
		append(&agent_ids, a.id)
	}
	if k := picker(app, &app.picker, "agent", "agents", agent_items[:], em); k >= 0 { choose_agent(app, agent_ids[k]) }
	shown, shown_provider := shown_model(app)
	model_items := make([dynamic]Pick_Item, len(app.models), context.temp_allocator)
	for m, i in app.models {
		model_items[i] = Pick_Item{label = m.name != "" ? m.name : m.id, group = m.provider, detail = m.ctx_len > 0 ? kfmt(m.ctx_len) : "", model = &app.models[i], current = m.id == shown && m.provider == shown_provider}
	}
	if k := picker(app, &app.picker, "model", "models", model_items[:], em); k >= 0 { choose_model(app, app.models[k]) }
}

// The reader picks one, in the picker or the palette: the session shown takes it, and it stands until that session's end.
choose_agent :: proc(app: ^App, agent: string) {
	c := &app.chat
	if c.id != "" { switch_agent(app, c.id, agent) }
	c.chose_agent = strings.clone(agent, c.alloc)
	choice_remember(app)
}

// (the variant stays when the new model has it too: "high" on one model is "high" on the next)
choose_model :: proc(app: ^App, m: Model_Info) {
	c := &app.chat
	variant := shown_variant(app)
	if !slice.contains(model_variants(app, m.id, m.provider), variant) { variant = "" }
	variant = strings.clone(variant, c.alloc)
	if c.id != "" { switch_model(app, c.id, m.id, m.provider, variant) }
	c.chose_model, c.chose_provider, c.chose_variant = strings.clone(m.id, c.alloc), strings.clone(m.provider, c.alloc), variant
	choice_remember(app)
}

// How hard the model shown thinks, picked in the composer's menu ("": the model's default). It goes with the model.
choose_variant :: proc(app: ^App, variant: string) {
	c := &app.chat
	model, provider := shown_model(app)
	if model == "" { return }   // (the server's default model: its variants are not known)
	model, provider = strings.clone(model, c.alloc), strings.clone(provider, c.alloc)
	if c.id != "" { switch_model(app, c.id, model, provider, variant) }
	c.chose_model, c.chose_provider, c.chose_variant = model, provider, strings.clone(variant, c.alloc)
	choice_remember(app)
}

// The agent and the model chosen last: what a new session starts with, from one run of the program to the next.
@(private = "file")
choice_remember :: proc(app: ^App) {
	model, provider := shown_model(app)
	agent := strings.clone(shown_agent(app), context.temp_allocator)
	model, provider = strings.clone(model, context.temp_allocator), strings.clone(provider, context.temp_allocator)
	pref_set(app, "session.agent", agent)
	pref_set(app, "session.model", model)
	pref_set(app, "session.provider", provider)
	pref_set(app, "session.variant", strings.clone(shown_variant(app), context.temp_allocator))
}

// The caret is on the first line the composer shows, wrapped or not (as last drawn).
composer_on_first_line :: proc(app: ^App) -> bool {
	a := &app.composer
	if len(a.buf) == 0 { return true }
	caret, _, ok := ui.text_edit_caret_rect(a)
	b := ui.prev_box("###composer")
	if !ok || b == nil { return false }
	return a.scroll.y < 1 && caret.min.y - b.rect.min.y < b.text_pad + (caret.max.y - caret.min.y) * 0.75
}

area_insert :: proc(a: ^ui.Text_Area, s: string) {
	lo, hi := min(a.cursor, a.mark), max(a.cursor, a.mark)
	remove_range(&a.buf, lo, hi)
	inject_at(&a.buf, lo, ..transmute([]u8)s)
	a.cursor = lo + len(s)
	a.mark = a.cursor
}

// A prompt that did not reach the server comes back to the composer, ahead of what was typed since.
prompt_restore :: proc(app: ^App, text: string) {
	if text == "" { return }   // (an image alone)
	typed := ui.area_string(&app.composer)
	ui.area_set(&app.composer, strings.trim_space(typed) == "" ? text : fmt.tprintf("%s\n%s", text, typed))
}

// "/name what follows", when the server has a command of that name. The server's commands not read yet: it waits for them
// (outgoing_slash_wait), and goes as a prompt if the name is not one.
slash_send :: proc(app: ^App, t: string, fields := "") -> bool {
	name, rest, ok := slash_split(t)
	if !ok { return false }
	if !app.cx.have_slash { outgoing_slash_wait(app, t, fields); return true }
	if !slash_known(app, name) { return false }
	outgoing_command(app, t, name, rest, fields)
	return true
}

// "/name what follows" as its name and what follows; ok: it starts with "/".
slash_split :: proc(t: string) -> (name, rest: string, ok: bool) {
	if !strings.has_prefix(t, "/") { return }
	name = t[1:]
	if i := strings.index_any(name, " \n"); i >= 0 { name, rest = name[:i], strings.trim_space(name[i:]) }
	return name, rest, true
}

slash_known :: proc(app: ^App, name: string) -> bool {
	for s in app.cx.slash { if s.name == name { return true } }
	return false
}

// Enter, or Send. While the session it would go to is starting it stays in the composer: nothing is lost, the button says it. While a
// turn runs `other` is the way that is not Enter's (composer_send_as); what is being edited goes back where it was, whichever.
submit_prompt :: proc(app: ^App, other := false) {
	t := strings.clone(strings.trim_space(ui.area_string(&app.composer)), context.temp_allocator)
	if (t == "" && len(app.cx.attachments) == 0) || !online(app) || composer_held(app) { return }
	history_leave(app, false)
	if queue_editing(app) { queue_edit_commit(app, t); return }
	as := composer_send_as(app, other)
	fields := send_as_fields(as)
	if app.chat.id == "" || !slash_send(app, t, fields) { outgoing_composer(app, t, app.chat.new_dir, fields) }
	ui.area_set(&app.composer, "")
	if as == .Idle { chat_scroll_event(app, Scroll_Signal.Go_Bottom) }   // (what waits shows over the composer: the conversation stays where it is)
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
		d^ = {hex(HEX_STATUS_TOP), hex(HEX_STATUS_BOTTOM), false}
		b.custom = bar_draw
		b.custom_user = d
		small := ui.Style_Mod{font = app.mono, font_size = math.round(em * FS_SMALL)}
		ui.spacer(ui.px(em * 0.35))
		// the server: a button that opens the menu of the servers (switch, add, edit)
		up := online(app)
		col := up ? hex(HEX_GREEN) : app.link == .Auth_Refused ? hex(HEX_RED) : hex(HEX_YELLOW)
		ui.next({width = ui.children_sum(), height = ui.px(h - 4 * ui.scale()), axis = .X, cross = .Center})
		sb := ui.build_box({.Clickable, .Focusable}, "###server_btn")
		sb.custom = proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
			if b.hot_t > FADE_VISIBLE || b.active_t > FADE_VISIBLE { draw_bevel(dc, b.rect, 5 * ui.scale(), hex(HEX_BG3), b.hot_t, b.active_t * b.hot_t) }
		}
		ssig := ui.signal(sb)
		skey := ui.key_from_string(0, "server_menu")
		if ssig.clicked { ui.ctx_menu_open_rect(skey, sb.rect, sb.key) }
		if ui.parent(sb) {
			ui.spacer(ui.px(em * 0.45))
			state_mark("###online", col, !up, size = em * 0.8)   // (connected is the normal state: a pip)
			ui.spacer(ui.px(em * 0.4))
			if len(app.servers) > 1 || !app.servers[app.server].local {
				text("sn", server_name(app), up ? hex(HEX_TEXT) : col, ui.Style_Mod{font = app.mono_bold, font_size = math.round(em * FS_SMALL)})
				ui.spacer(ui.px(em * 0.5))
			}
			state: string
			switch app.link {
			case .Connecting:   state = "connecting"
			case .Online:       state = "connected"
			case .Retrying:     state = "reconnecting"
			case .Auth_Refused: state = "auth refused"
			}
			text("st", fmt.tprintf("%s  %s", state, server_base(app)), up ? hex(HEX_WEAK) : col, small)
			ui.spacer(ui.px(em * 0.35))
			glyph(lucide.CHEVRON_DOWN, hex(HEX_FAINT), math.round(em * ICON_TINY))
			ui.spacer(ui.px(em * 0.45))
		}
		server_menu(app, skey, em)
		if app.server_version != "" {
			side_line("###sg_status", sb, em * 0.8, app.sidebar_w)
			ui.spacer(ui.px(em * 1.3))
			text("v", fmt.tprintf("opencode %s", app.server_version), hex(HEX_FAINT), small)
		}
		ui.spacer(ui.fill())
		update_pill(app, em)
		pend := int(app.pending)
		if pend == 0 { app.cx.pending_since = 0 } else if app.cx.pending_since == 0 { app.cx.pending_since = ui.now_ms() }
		if pend > 0 && ui.now_ms() - app.cx.pending_since >= PENDING_SHOW_MS {
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
		if app.prefs.show_fps {
			fps := app.cx.frame_ms > 0 ? 1000 / app.cx.frame_ms : 0
			text("fps", fmt.tprintf("%3.0f fps  %.1f ms", fps, app.cx.work_ms), hex(HEX_FAINT), small)
			ui.spacer(ui.px(em * 0.8))
			if n := app.cx.unreadable.count; n > 0 {   // (unreadable.odin: the log says what they were)
				text("unr", fmt.tprintf("%d unreadable", n), hex(HEX_YELLOW), small)
				ui.spacer(ui.px(em * 0.8))
			}
		}
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

// How hard the model thinks: a button beside the model's that opens the menu of its variants. None when the model has none.
@(private = "file")
variant_button :: proc(app: ^App, em: f32) {
	model, provider := shown_model(app)
	variants := model_variants(app, model, provider)
	if len(variants) == 0 { return }
	current := shown_variant(app)
	ui.spacer(ui.px(em * 0.2))
	ui.a11y({role = .Button, name = "Thinking"})
	sig := bevel_button("###variant", current != "" ? current : "default", lucide.GAUGE, .Ghost, height = math.round(em * BUTTON_COMPACT_H_EM), quiet = true)
	key := ui.key_from_string(0, "variant_menu")
	if sig.clicked { ui.ctx_menu_open_rect(key, sig.box.rect, sig.box.key) }
	if ui.hovered_for(sig, TOOLTIP_DELAY_S) { if ui.tooltip() { ui.tooltip_text("How hard the model thinks") } }
	if ui.ctx_menu(key, em * 12) {
		if ui.menu_item("default###v_default", "", current == "").clicked { choose_variant(app, "") }
		for v, i in variants {
			if ui.menu_item(fmt.tprintf("%s###v%d", label_safe(v), i), "", v == current).clicked { choose_variant(app, v) }
		}
	}
}

// A character typed this build that is not a space.
@(private = "file")
typed_word :: proc(app: ^App) -> bool {
	for r in app.state.typed { if r > ' ' && r != 0x7f { return true } }
	return false
}
