// The window's bars: the title bar, the conversation's header, the status bar.
package ocn

import "core:fmt"
import "core:math"
import "core:strings"
import "gt:draw"
import "gt:ui"
import lucide "gt:lucide"
import i18n "gt:i18n"


TITLE_BAR_MIN_H_PX    :: 34
TITLE_BAR_TITLE_CHARS :: 70
CRUMB_PARENT_CHARS    :: 60


// What the bars show that is measured between builds: how long requests have waited, the frame rate.
Chrome :: struct {
	pending_since: f64,   // when requests went from none to some (the status bar)
	frame_ms:      f32,   // what the status bar's rate says: between two frames, smoothed
	work_ms:       f32,   // ... what a frame costs (build, draw, render)
	said:          Status_Said,
}

// What the status bar says of the server, held (status_said_follow): a server switch forgets everything of the old
// one before the new one answers, and the bar showed "0 sessions", no version, a width that jumped. Each value changes
// only when the new server has said its own; until then the old one's stays, and the change morphs (ui.morph_label).
Status_Said :: struct {
	version:  string,   // (owned) "": none said yet, ever
	sessions: int,
	running:  int,
	counted:  bool,     // `sessions` and `running` are a server's (its list was read once)
}

// The held values follow what the server says, once it has said it.
status_said_follow :: proc(app: ^App) {
	s := &app.chrome.said
	if app.server_version != "" && app.server_version != s.version {
		delete(s.version)
		s.version = strings.clone(app.server_version)
	}
	// (the list read: its count and what runs are the server's; before it, the old server's stay)
	if app.sessions_loaded { s.sessions, s.running, s.counted = len(app.sessions), len(app.busy), true }
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

// The rule of the left dock zone's handle (the sidebar's edge, where it is docked) goes on through the title bar and the
// status bar: after what a bar puts over the zone (`last`, its last box), at least `gap` then the line; a bar with more
// than the zone's width pushes it on. Its place is the handle's own (ui.view_dock_line), never a width of ocn's: the
// spacer reads the last layout, the drawing this frame's, so the two are on one pixel column during a drag too.
// No handle (nothing docked at the left, the zone minimised or maximised): the bar's own groove after the gap.
@(private = "file")
side_line :: proc(app: ^App, id: string, last: ^ui.Box, gap: f32) {
	vs := &app.program_views
	line, docked := ui.view_dock_line(vs, .Left)
	if !docked {
		ui.spacer(ui.px(gap))
		edge_line(id, vertical = true)
		return
	}
	ui.spacer(ui.px(max(gap, line.min.x - last.rect.max.x)))
	ui.next({width = ui.px(line.max.x - line.min.x), height = ui.fill()})
	b := ui.build_box({}, id)
	d := ui.frame_new(Side_Line_Draw)
	d^ = {vs, ui.color("border")}   // (the handle's colour at rest)
	b.custom, b.custom_user = side_line_draw, d
}

@(private = "file")
Side_Line_Draw :: struct { views: ^ui.Views, color: Color }

@(private = "file")
side_line_draw :: proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
	d := (^Side_Line_Draw)(user)
	line, docked := ui.view_dock_line(d.views, .Left)
	if !docked { line = b.rect }
	// (a bar wider than the zone pushed its line on: it stays after the bar's words)
	x := max(line.min.x, b.rect.min.x)
	draw.rect(dc, {{x, b.rect.min.y}, {x + (line.max.x - line.min.x), b.rect.max.y}}, d.color)
}

title_bar :: proc(app: ^App, em: f32) {
	pane := main_pane(app)
	h := max(math.round(em * 2.6), math.round(TITLE_BAR_MIN_H_PX * ui.scale()))
	ui.next({width = ui.fill(), height = ui.px(h)})
	if ui.title_bar("###titlebar") {
		b := ui.parent_box()
		d := ui.frame_new(Bar_Draw)
		d^ = {ui.theme_color("card background"), ui.theme_color("bar background"), true}
		b.custom = caption_draw   // (the finish's title bar: in the edged one the accent fading out, its words light: ui.caption_ink)
		b.custom_user = d
		ink := ui.caption_ink
		ui.spacer(ui.px(em * 0.4))
		ui.next({width = ui.px(math.round(h * 0.78)), height = ui.px(math.round(h * 0.78)), fg = ink(ui.theme_color("weak text"))})
		msig := ui.button("appmenu", icon = lucide.MENU)
		menu_key := "app_menu"
		if msig.clicked { ui.menu_open(menu_key, msig.box.rect, msig.box.key) }
		app_menu(app, menu_key, em)
		nav_button :: proc(app: ^App, id, icon, tip: string, d: int, size: f32) {
			can := nav_can(app, d)
			ui.a11y({role = .Button, name = tip})
			ui.next({width = ui.px(size), height = ui.px(size), fg = ui.caption_ink(can ? ui.theme_color("weak text") : ui.theme_color("faint text"))})
			sig := ui.button(id, icon = icon)
			if sig.clicked { nav_step(app, d) }
			if can && ui.hovered_for(sig) { if ui.tooltip() { ui.tooltip_text(tip) } }
		}
		nav_button(app, "nav_back", lucide.ARROW_LEFT, i18n.tr("Back  (Alt+Left)"), -1, math.round(h * 0.78))
		nav_button(app, "nav_fwd", lucide.ARROW_RIGHT, i18n.tr("Forward  (Alt+Right)"), 1, math.round(h * 0.78))
		ui.spacer(ui.px(em * 0.4))
		// the logo and the wordmark ("open" dim, "code" bright, "native" in the accent, in the mono face) go home, as on any site
		ui.next({width = ui.children_sum(), height = ui.pct(1), axis = .X, cross = .Center, cursor = .Hand})
		ui.a11y({role = .Button, name = i18n.tr("Home")})
		home_link := ui.build_box({.Clickable}, "###home_link")
		hsig := ui.signal(home_link)
		if ui.parent(home_link) {
			logo_box(app, "###tlogo", math.round(h * 0.6))
			ui.spacer(ui.px(em * 0.5))
			mono := ui.Style_Mod{font = app.mono_bold, font_size = math.round(em * FS_HEADING)}
			text("w1", "open", ink(hsig.hovering ? ui.theme_color("text") : ui.theme_color("weak text")), mono)
			text("w2", "code", ink(hsig.hovering ? ui.theme_color("bright text") : ui.theme_color("text")), mono)
			ui.spacer(ui.px(em * 0.45))
			text("w3", "native", ink(ui.hue(.Accent)), ui.Style_Mod{font = app.mono, font_size = math.round(em * FS_HEADING)})
		}
		if hsig.clicked { command_run(app, command_find("nav.home")) }
		if ui.hovered_for(hsig) { if ui.tooltip() { ui.tooltip_text(i18n.tr("Home  (Ctrl+H)")) } }
		side_line(app, "###tg", b.last, em * 0.9)
		ui.spacer(ui.px(em * 1.3))
		if !app.servers[app.server].local {   // another computer's server: its name first
			glyph(lucide.GLOBE, ink(ui.hue(.Cyan)), math.round(em * ICON_SMALL))
			ui.spacer(ui.px(em * 0.3))
			text("srv", i18n.tr(server_name(app)), ink(ui.hue(.Cyan)), ui.Style_Mod{font = app.mono_bold, font_size = math.round(em * FS_SMALL)})
			if pane.chat.id != "" { text("srvsep", "  /  ", ink(ui.theme_color("faint text")), ui.Style_Mod{font_size = math.round(em * FS_LABEL)}) }
		}
		s := find_session(app, pane.chat.id)
		if s == nil && pane.chat.have_self { s = &pane.chat.self }
		if s != nil {
			// the project's logo before its folder
			if logo_of(app, "###tproj", project_logo(app, s.project), math.round(h * 0.55)) { ui.spacer(ui.px(em * 0.45)) }
			text("dir", base_name(s.directory), ink(ui.theme_color("weak text")), ui.Style_Mod{font_size = math.round(em * FS_LABEL)})
			text("sep", "  /  ", ink(ui.theme_color("faint text")), ui.Style_Mod{font_size = math.round(em * FS_LABEL)})
			text("ttl", ellipsize(s.title, TITLE_BAR_TITLE_CHARS), ink(ui.theme_color("text")), ui.Style_Mod{font_size = math.round(em * FS_LABEL)}, ui.fill())
		} else {
			ui.spacer(ui.fill())
		}
		if pane.chat.busy {
			ui.spacer(ui.px(em * 0.8))
			throbber(app, pane, "###tscan", ui.hue(.Accent), math.round(em * 3), math.round(em * 0.75), em)
			ui.spacer(ui.px(em))
		}
		missed_bell(app, math.round(h * 0.78), em)
		ui.spacer(ui.px(em * 0.4))
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

// The session's id beside its title, muted, while the pointer is on the header: a click copies it.
@(private = "file")
session_id_copy_hint :: proc(app: ^App, id: string, em: f32) -> bool {
	// (muted: found when looked for, never read in passing; brighter under the pointer, which says it is a target)
	ui.next({width = ui.children_sum(), height = ui.pct(1), axis = .X, cross = .Center, cursor = .Hand})
	b := ui.build_box({.Clickable}, "###session_id")
	sig := ui.signal(b)
	if ui.parent(b) {
		text("t", id, sig.hovering ? ui.theme_color("weak text") : ui.theme_color("faint text"), ui.Style_Mod{font = app.mono, font_size = math.round(em * FS_CAPTION)})
	}
	ui.a11y_default(b, {role = .Button, name = i18n.tr("Copy the session ID")})
	if ui.hovered_for(sig) { if ui.tooltip() { ui.tooltip_text(i18n.tr("Copy the session ID")) } }
	return sig.clicked
}

// The session's id to the clipboard, and said.
session_id_copy :: proc(app: ^App, id: string) {
	clip_set(id)
	ui.announce(&app.announcer, .Good, i18n.tr("Session ID copied"))
}

chat_header :: proc(app: ^App, em: f32) {
	pane := main_pane(app)
	h := math.round(em * (pane.chat.have_self && pane.chat.self.parent != "" ? 4.3 : 3.3))   // (a sub-agent: a breadcrumb line above its title)
	ui.next({width = ui.fill(), height = ui.px(h), axis = .X, cross = .Center})
	if ui.row(.Center, id = "###hdr") {
		b := ui.parent_box()
		d := ui.frame_new(Bar_Draw)
		d^ = {between("bar background", "card background", 0.5), between("background", "bar background", 0.5), false}
		b.custom = bar_draw
		b.custom_user = d
		ui.spacer(ui.px(em * 1.3))
		s := find_session(app, pane.chat.id)
		if s == nil && pane.chat.have_self { s = &pane.chat.self }   // (a sub-agent, or an old session: not in the sidebar's list)
		if back := back_target(app); back != "" {
			// the way back up: to the session drilled down from, or the parent
			if ui.button("back", icon = lucide.ARROW_LEFT, o = {face = .Raised, width = ui.px(math.round(em * BUTTON_H_EM)), height = math.round(em * BUTTON_H_EM)}).clicked { go_back(app) }
			ui.spacer(ui.px(em * 0.7))
		}
		if logo_of(app, "###hlogo", project_logo(app, chat_project(app)), math.round(em * 2.3)) { ui.spacer(ui.px(em * 0.7)) }
		ui.next({width = ui.fill(), height = ui.pct(1), axis = .Y})
		if ui.column(id = "###titles") {
			ui.spacer(ui.fill())
			if pane.chat.have_self && pane.chat.self.parent != "" {
				// breadcrumb: the parent, then this sub-agent
				ui.next({width = ui.fill(), height = ui.px(em * 1.2), axis = .X, cross = .Center})
				if ui.row(.Center, id = "###crumb") {
					parent := pane.chat.parent_title != "" ? pane.chat.parent_title : i18n.tr("parent session")
					ui.next({width = ui.children_sum(), height = ui.pct(1), axis = .X, cross = .Center, cursor = .Hand})
					pb := ui.build_box({.Clickable}, "###crumb_parent")
					ps := ui.signal(pb)
					if ps.clicked {
						if back_target(app) == pane.chat.self.parent { go_back(app) } else { drill_down(app, pane.chat.self.parent) }
					}
					if ui.parent(pb) {
						text("p", ellipsize(parent, CRUMB_PARENT_CHARS), ps.hovering ? ui.hue(.Accent) : ui.theme_color("weak text"), ui.Style_Mod{font_size = math.round(em * FS_SMALL)})
					}
					text("s", i18n.tr("  ›  sub-agent"), ui.theme_color("faint text"), ui.Style_Mod{font_size = math.round(em * FS_SMALL)})
				}
			}
			title := s != nil ? s.title : i18n.tr("New session")
			if s != nil && renaming_at(app, s.id, .Header) {
				rename_in_place(app, em, math.round(em * FS_HEADING), em * 1.5, fit = true)
			} else {
				ui.next({width = ui.fill(), height = ui.px(em * 1.5), axis = .X, cross = .Center})
				tb := ui.build_box(s != nil ? {.Clickable} : {}, "###title_b")
				if s != nil && ui.signal(tb).double_clicked { rename_inline(app, s.id, .Header) }
				if ui.parent(tb) {
					// (as wide as its words, shrinking first: the id goes right after it)
					text("title", title != "" ? title : i18n.tr("Untitled"), ui.theme_color("bright text"), ui.Style_Mod{font_size = math.round(em * FS_HEADING), height = ui.px(em * 1.5)}, ui.text_size(0, 0))
					// (the session's id, as opencode 2.3.0 lets it be found: muted beside the title, while the pointer is on the
					// header; a click copies it. Never there otherwise: it is not something one reads)
					if s != nil && ui.pointer_on(b) {
						ui.spacer(ui.px(em * 0.6))
						if session_id_copy_hint(app, s.id, em) { session_id_copy(app, s.id) }
					}
				}
			}
			dir := s != nil ? s.directory : pane.chat.new_dir
			text("dir", dir != "" ? dir : i18n.tr("default folder"), ui.theme_color("faint text"), ui.Style_Mod{font = app.mono, font_size = math.round(em * FS_SMALL), height = ui.px(em * 1.2), flags = dir != "" ? {.Selectable} : {}}, ui.fill())
			ui.spacer(ui.fill())
		}
		c := &pane.chat
		// (its title edited: the line is the title's, the figures and the sub-agents wait)
		editing := s != nil && renaming_at(app, s.id, .Header)
		thin := pane.conversation.width > 0 && pane.conversation.width < em * HEADER_FIGURES_MIN_EM
		if !editing && len(c.children) > 0 && !(thin && len(active_children(app, pane)) == 0) {
			subagents_button(app, pane, em)
			ui.spacer(ui.px(em * 0.6))
		}
		// (narrow, between panels: the title first, the figures are in the statistics)
		narrow := editing || thin
		if !narrow && c.tokens_in + c.tokens_out > 0 {
			if pill_button("###tok", fmt.tprintf(i18n.tr("%s in · %s out"), kfmt(c.tokens_in + c.cache_read), kfmt(c.tokens_out)), {}, lucide.ZAP).clicked { stats_toggle(app) }
			ui.spacer(ui.px(em * 0.4))
		}
		if !narrow && c.cost > 0 {
			if pill_button("###cost", dollars(c.cost), ui.hue(.Green)).clicked { stats_toggle(app) }
			ui.spacer(ui.px(em * 0.4))
		}
		if c.busy {
			ui.spacer(ui.px(em * 0.4))
			if ui.button("stop", i18n.tr("Stop"), lucide.SQUARE, {intent = .Danger, height = math.round(em * BUTTON_COMPACT_H_EM)}).clicked { interrupt_session(app, c.id) }
		}
		ui.spacer(ui.px(em * 1.2))
	}
	edge_line("###hdredge")
}

// (every number a person reads with the language's decimal mark: "1,5k" in French; i18n.decimal, i18n.percent)
kfmt :: proc(v: f64) -> string {
	switch {
	case v >= 1e6: return fmt.tprintf("%sM", i18n.decimal(v / 1e6, 1))
	case v >= 1e3: return fmt.tprintf("%sk", i18n.decimal(v / 1e3, 1))
	}
	return fmt.tprintf("%d", int(v))
}

// A cost in dollars, as the servers count it, written as the language writes an amount: "$0.42", "0,42 $" in French.
dollars :: proc(v: f64, decimals := 2) -> string { return fmt.tprintf(i18n.tr("$%s"), i18n.decimal(v, decimals)) }

////////////////////////////////
// Status bar

status_bar :: proc(app: ^App, em: f32) {
	edge_line("###sbedge")
	h := math.round(em * 1.9)
	ui.next({width = ui.fill(), height = ui.px(h), axis = .X, cross = .Center})
	if ui.row(.Center, id = "###status") {
		b := ui.parent_box()
		d := ui.frame_new(Bar_Draw)
		d^ = {between("bar background", "card background", 0.67), between("background", "bar background", 0.67), false}
		b.custom = bar_draw
		b.custom_user = d
		small := ui.Style_Mod{font = app.mono, font_size = math.round(em * FS_SMALL)}
		ui.spacer(ui.px(em * 0.8))
		// the link to the server: its state and its address (the server is chosen in the sidebar's tabs: server_tabs)
		ui.next({width = ui.children_sum(), height = ui.pct(1), axis = .X, cross = .Center})
		if ui.row(.Center, id = "###link") {
			link_lamp(app, "###online", em * 0.8)
			ui.spacer(ui.px(em * 0.4))
			// (a server switch: the words that change morph in place, ui.morph_label)
			morph_text("st", link_word(app), online(app) ? ui.theme_color("weak text") : link_color(app), small)
			if base := server_base(app); base != "" {
				ui.spacer(ui.px(em * 0.6))
				morph_text("base", base, ui.theme_color("faint text"), small)
			}
		}
		side_line(app, "###sg_status", b.last, em * 0.8)
		// the versions: the server's, and this program's (names of products: not translated)
		ui.spacer(ui.px(em * 1.3))
		status_said_follow(app)
		said := &app.chrome.said
		if said.version != "" {
			morph_text("v", fmt.tprintf("OpenCode %s", said.version), ui.theme_color("faint text"), small)
			ui.spacer(ui.px(em * 0.8))
		}
		text("ocn_v", APP_TITLE + " " + APP_VERSION, ui.theme_color("faint text"), small)
		ui.spacer(ui.fill())
		update_pill(app, em)
		pend := int(app.pending)
		if pend == 0 { app.chrome.pending_since = 0 } else if app.chrome.pending_since == 0 { app.chrome.pending_since = ui.now_ms() }
		if pend > 0 && ui.now_ms() - app.chrome.pending_since >= PENDING_SHOW_MS {
			text("p", fmt.tprintf(i18n.tr(pend, "%d request", "%d requests"), pend), ui.theme_color("faint text"), small)
			ui.spacer(ui.px(em * 0.8))
		}
		if said.running > 0 {
			morph_text("b", fmt.tprintf(i18n.tr("%d running"), said.running), ui.hue(.Accent), small)
			ui.spacer(ui.px(em * 0.8))
		}
		// (no count before a server's first list: never a "0 sessions" that is no server's)
		if said.counted {
			morph_text("n", fmt.tprintf(i18n.tr(said.sessions, "%d sessions", "%d sessions"), said.sessions), ui.theme_color("faint text"), small)
			ui.spacer(ui.px(em * 0.8))
		}
		if app.prefs.show_fps {
			fps := app.chrome.frame_ms > 0 ? 1000 / app.chrome.frame_ms : 0
			text("fps", i18n.decimal_marks(fmt.tprintf(i18n.tr("%3.0f fps  %.1f ms"), fps, app.chrome.work_ms)), ui.theme_color("faint text"), small)
			ui.spacer(ui.px(em * 0.8))
			if n := app.cx.unreadable.count; n > 0 {   // (unreadable.odin: the log says what they were)
				text("unr", fmt.tprintf(i18n.tr(n, "%d unreadable", "%d unreadable"), n), ui.hue(.Yellow), small)
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
