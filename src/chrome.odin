// The window's bars: the title bar, the conversation's header, the status bar.
package ocn

import "core:fmt"
import "core:math"
import "core:strings"
import "gt:draw"
import "gt:ui"
import lucide "gt:lucide"


TITLE_BAR_MIN_H_PX    :: 34
TITLE_BAR_TITLE_CHARS :: 70
CRUMB_PARENT_CHARS    :: 60

HEX_TITLE_BAR_TOP     :: 0x181818ff
HEX_TITLE_BAR_BOTTOM  :: 0x111111ff
HEX_HEADER_TOP        :: 0x131313ff
HEX_HEADER_BOTTOM     :: 0x0d0d0dff
HEX_STATUS_TOP        :: 0x141414ff
HEX_STATUS_BOTTOM     :: 0x0e0e0eff

// What the bars show that is measured between builds: how long requests have waited, the frame rate.
Chrome :: struct {
	pending_since: f64,   // when requests went from none to some (the status bar)
	frame_ms:      f32,   // what the status bar's rate says: between two frames, smoothed
	work_ms:       f32,   // ... what a frame costs (build, draw, render)
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
		side_line("###tg", b.last, em * 0.9, app.sidebar.width)
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
		if !editing && len(c.children) > 0 && !(app.conversation.docked_w > 0 && app.conversation.docked_w < em * HEADER_FIGURES_MIN_EM && len(active_children(app)) == 0) {
			subagents_button(app, em)
			ui.spacer(ui.px(em * 0.6))
		}
		// (narrow, as a panel of the dock: the title first, the figures are in the statistics)
		narrow := editing || app.conversation.docked_w > 0 && app.conversation.docked_w < em * HEADER_FIGURES_MIN_EM
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
			side_line("###sg_status", sb, em * 0.8, app.sidebar.width)
			ui.spacer(ui.px(em * 1.3))
			text("v", fmt.tprintf("opencode %s", app.server_version), hex(HEX_FAINT), small)
		}
		ui.spacer(ui.fill())
		update_pill(app, em)
		pend := int(app.pending)
		if pend == 0 { app.chrome.pending_since = 0 } else if app.chrome.pending_since == 0 { app.chrome.pending_since = ui.now_ms() }
		if pend > 0 && ui.now_ms() - app.chrome.pending_since >= PENDING_SHOW_MS {
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
			fps := app.chrome.frame_ms > 0 ? 1000 / app.chrome.frame_ms : 0
			text("fps", fmt.tprintf("%3.0f fps  %.1f ms", fps, app.chrome.work_ms), hex(HEX_FAINT), small)
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
