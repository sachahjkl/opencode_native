// The Preview panel: a web page beside the conversation, a view (PREVIEW_VIEW: docked at its right, floating, in a window of its
// own, wherever the user puts it). What an agent builds shows here, and the agents can drive it (browser_mcp.odin). The Statistics
// panel (stats.odin) shares its place at first: one stack, a tab each. The page is a child window of the system's, over everything
// the toolkit draws in its place: it steps aside while a dialog or a menu is open over it, and follows the view to another window
// (preview_moved). Each session has its own browser, of one tab or several, inside this one panel (preview_views.odin): what is
// here is the session shown's, and what it does to the page it does to its front tab, unless it is given another.
package ocn

import "core:fmt"
import "core:math"
import "core:strings"
import desktop "gt:desktop"
import "gt:draw"
import "gt:platform"
import "gt:ui"
import lucide "gt:lucide"
import i18n "gt:i18n"

// Who wants a panel: what an agent opens does not move the keyboard.
Asked_By :: enum u8 { User, Agent }

// Where the web view stands. (nil: none, not asked for or closed.) Its failure says why, and it can be tried again.
Web_Creating :: struct {}
Web_Ready    :: struct {}
Web_Failed   :: struct { why: string }   // (owned)
Web_State    :: union { Web_Creating, Web_Ready, Web_Failed }

// What the web view says, as it says it: on the window's message loop, which also turns inside a modal dialog of the system, in the
// middle of a build. Nothing is done there; a frame takes the list at a point of its own (web_events_drain).
Web_Event_Kind :: enum i32 {
	Ready = 1,
	Failed,      // (data: why)
	Source,      // the address changed (data: it)
	Title,       // (data: it)
	Loaded,      // a navigation ended (id: which; data: one byte, not 0 when it succeeded)
	Script,      // a script's result, JSON (id: the caller's)
	Capture,     // a picture, PNG (id: the caller's)
	Key,         // a key the page had (id: virtual key)
	Nav_Start,   // a navigation began (id: which; a redirection has the same one)
}

Web_Event :: struct { kind: Web_Event_Kind, id: u64, data: []u8, ctrl: bool }   // (data owned)

VK_F1 :: 0x70

// A page of a session's browser.
Preview_Tab :: struct {
	id:       string,             // what the agents call it: the same for its whole life (owned)
	field:    ui.Line_Edit,      // the address
	url:      string,             // what the page shows (owned)
	title:    string,             // (owned)
	navs:     [dynamic]u64,       // the navigations under way: one can begin before the last ends
	web:      Web_State,
	view:     ^Web_View,          // its web view (nil: none, not asked for, or the limit took it: preview_trim)
	asked:    bool,               // it was given an address, which may not have come yet
	focus_page: bool,             // the page takes the keyboard when its view comes
	used:     u64,                // when it was last shown or driven (Previews.clock)
	focus_address: bool,          // the address takes the focus at its next build
	placed:   [4]int,             // x, y, width, height last given to the view
	placed_shown: bool,
	placed_ms: f64,
}

// A session's browser.
Preview :: struct {
	open:     bool,               // its panel is: the session shown's, for what lights a button or a menu
	tabs:     [dynamic]^Preview_Tab,
	front:    int,                // the one that shows
	key:      string,             // the session it is the browser of ("": the home page) (owned)
	gone:     bool,               // its session was deleted: it is not parked
	body:     Rect,               // where the page goes, at the last layout (frame pixels of the window it is built in)
	shown:    bool,               // the panel's body was built in this frame (preview_after_frames reads it, then lets go of it)
	occluded: bool,               // ... and a view floats over it, or a dialog is over it (it steps aside)
	addr_key: ui.Key,             // the address field: what the page says does not overwrite what one types
	due_new:  bool,               // what the panel's boxes asked for, done where nothing is built (preview_dues)
	due_front, due_close: ^Preview_Tab,
}

// The look of a session's browser tabs: a flat bar, and on it words. No tab has a surface or an edge of its own: the one shown
// is lit, with a line as wide as it lying on the bar's lower edge. What a tab is shows by what it says, not by a box around it.
@(private = "file")
tab_look_draw :: proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
	if user == nil { return }   // (not the one shown)
	r := b.rect
	h := 2 * px1()
	inset := TAB_LINE_INSET_EM * ui.font_size()
	draw.rect(dc, {{r.min.x + inset, r.max.y - h}, {r.max.x - inset, r.max.y}}, accent())
}

// The strip's bar under those tabs.
@(private = "file")
strip_look :: proc() {
	b := ui.parent_box()
	b.custom = proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
		if ui.edged() { ui.caption_face(dc, b.rect, hex(HEX_BG1), hex(HEX_BG1), false); return }
		draw.rect(dc, b.rect, hex(HEX_BG1))
		draw.rect(dc, {{b.rect.min.x, b.rect.max.y - px1()}, b.rect.max}, hex(HEX_LINE))
	}
}

// The Preview's title: its front page's.
preview_title :: proc(app: ^App) -> string {
	t := preview_front(&app.preview)
	return t != nil && t.title != "" ? ellipsize(t.title, 28) : i18n.tr("Preview")
}

// Closed, whichever way: its view, the session's browser (its tabs stay, for when it opens again).
preview_close :: proc(app: ^App) {
	app.preview.open = false
	preview_home(app)
	ui.view_close(&app.program_views, PREVIEW_VIEW)
	app.settle = max(app.settle, FRAMES_AFTER_INPUT)
}

// (read once: this is asked at every frame, and it is a look in the registry)
preview_available :: proc() -> bool {
	@(static) known, available: bool
	if !known { known, available = true, web_available() }
	return available
}

// The Preview panel needs a web view the window can hold: WebView2 on Windows. Linux has none that a Wayland window can
// hold, so agents there use the user's own browser through OpenCode Browse: the toast opens its page.
BROWSE_URL :: "https://opencode.ai/extensions/browse"

preview_missing :: proc() {
	when ODIN_OS == .Linux {
		ui.announce(&the_app.announcer, .Info, i18n.tr("No Preview panel on Linux: let agents use your own browser with OpenCode Browse. Click to see it"), action = proc(_: rawptr) { ui.open(BROWSE_URL, .Url) }, user = nil)
	} else {
		ui.announce(&the_app.announcer, .Warn, i18n.tr("The Preview panel needs the WebView2 runtime"))
	}
}

preview_toggle :: proc(app: ^App) {
	if !preview_available() { preview_missing(); return }
	if app.preview.open { preview_close(app) } else { preview_show(app) }
}

preview_show :: proc(app: ^App, by := Asked_By.User) {
	p := &app.preview
	p.open = true
	t := preview_front_made(app, p)
	preview_revive(app, t)
	ui.view_open(&app.program_views, PREVIEW_VIEW, app, owner = &app.state)   // (one open comes forward: its tab in front)
	t.focus_address = by == .User && t.url == ""   // (nothing to show yet: what comes next is an address)
	app.settle = max(app.settle, FRAMES_AFTER_INPUT)
}

// As preview_show, for any session's: a parked one opens where it is, out of sight, and shows when its session does.
preview_show_in :: proc(app: ^App, p: ^Preview, by: Asked_By) {
	if p == &app.preview { preview_show(app, by); return }
	p.open = true
	preview_revive(app, preview_front_made(app, p))
}

// A link: in the panel where there is one, else in the system's browser.
preview_open :: proc(app: ^App, url: string, by := Asked_By.User) {
	if !preview_available() { ui.open(url, .Url); return }
	p := &app.preview
	if !p.open { preview_show(app, by) }
	preview_go(app, preview_front_made(app, p), url)
}

// (What is not on the screen stays where it is: an agent's page does not take the panel from what the user reads.)
preview_go :: proc(app: ^App, t: ^Preview_Tab, url: string) {
	if preview_tab_shown(app, t) && app.preview.open { ui.view_open(&app.program_views, PREVIEW_VIEW, app, owner = &app.state) }
	web_navigate(app, t, url)
	ui.line_edit_set(&t.field, url)
}

preview_loading :: proc(t: ^Preview_Tab) -> bool { return len(t.navs) > 0 }

web_state_set :: proc(t: ^Preview_Tab, state: Web_State) {
	if f, failed := t.web.(Web_Failed); failed { delete(f.why) }
	t.web = state
}

// The pages went with a server left: what they show was that server's work, and what an agent of the next one would read there is not its
// own. Every session's goes, and the next ones start clean.
preview_forget :: proc(app: ^App) {
	p := &app.preview
	if p.open { preview_close(app) }
	preview_tabs_clear(app, p)
	for _, e in app.previews.by_session {
		preview_free(app, e)
		free(e)
	}
	clear(&app.previews.by_session)
}

////////////////////////////////
// What the web view says

// (On the window's message loop, maybe in a build: it only keeps it. `ctrl`: read now, the key is down now.)
web_event_add :: proc(v: ^Web_View, kind: Web_Event_Kind, id: u64, data: []u8, ctrl := false) {
	if v.gone { return }
	own := make([]u8, len(data))
	copy(own, data)
	append(&v.events, Web_Event{kind, id, own, ctrl})
	v.app.settle = max(v.app.settle, FRAMES_AFTER_INPUT)
}

web_events_drop :: proc(v: ^Web_View) {
	for e in v.events { delete(e.data) }
	clear(&v.events)
}

// The frame's point for it: no build runs, and what an event does may say more (a script refused answers at once): that waits for the next.
web_events_drain :: proc(app: ^App) {
	for v in app.previews.views {
		if len(v.events) == 0 { continue }
		batch := v.events
		v.events = {}
		app.cx.shared_moved = true
		for e in batch {
			if !v.gone { web_event_apply(app, v, e) }
			delete(e.data)
		}
		delete(batch)
	}
}

// (Each to the tab of the view that said it, shown or not.)
@(private = "file")
web_event_apply :: proc(app: ^App, v: ^Web_View, e: Web_Event) {
	t := v.tab
	s := string(e.data)
	switch e.kind {
	case .Ready:
		web_state_set(t, Web_Ready{})
		// (it was on its way while the panel changed windows, or it stopped being the page on the screen)
		if w := preview_window(app, t); v.parent != w {
			web_parent(t, w)
			t.placed = {}
		}
	case .Failed:
		web_state_set(t, Web_Failed{strings.clone(s)})
		clear(&t.navs)
		browser_calls_fail(app, v, s)
	case .Source:    preview_set_url(app, t, s)
	case .Title:     preview_set_title(t, s)
	case .Nav_Start: preview_nav_started(app, t, e.id)
	case .Loaded:    preview_nav_ended(app, t, e.id, len(e.data) > 0 && e.data[0] != 0)
	case .Script:    browser_script_done(app, v, e.id, s)
	case .Capture:   browser_capture_done(app, v, e.id, e.data)
	case .Key:
		// (the page has the keyboard: what the program answers to must still reach it)
		if e.ctrl && e.id == u64('K') { if palette_shown(app) { palette_hide(app) } else { palette_show(app) } }
		if e.ctrl && e.id == u64('T') { app.preview.due_new = true }
		if e.ctrl && e.id == u64('W') { app.preview.due_close = t }
		if e.id == VK_F1 { command_run(app, command_find("app.help")) }
	}
}

// (A redirection is the same navigation, started again.)
@(private = "file")
preview_nav_started :: proc(app: ^App, t: ^Preview_Tab, nav: u64) {
	for n in t.navs { if n == nav { return } }
	append(&t.navs, nav)
	browser_nav_started(app, t.view, nav)
}

@(private = "file")
preview_nav_ended :: proc(app: ^App, t: ^Preview_Tab, nav: u64, ok: bool) {
	for n, i in t.navs { if n == nav { ordered_remove(&t.navs, i); break } }
	preview_page_focus(app, t)
	browser_page_loaded(app, t, nav, ok)
}

reveal_path :: proc(path: string) { ui.open(path, .Reveal) }

// The system's terminal, in a session's folder (desktop.open_terminal: $TERMINAL or a common one; Windows Terminal).
terminal_open :: proc(dir: string) {
	if dir == "" || !desktop.open_terminal(dir) { ui.announce(&the_app.announcer, .Warn, i18n.tr("No terminal could be started in that folder")) }
}

// What the address bar was given: an address, a host, or a file.
preview_address :: proc(s: string) -> string {
	t := strings.trim_space(s)
	switch {
	case t == "": return ""
	case strings.contains(t, "://"), strings.has_prefix(t, "about:"), strings.has_prefix(t, "data:"): return t
	case len(t) > 2 && t[1] == ':': return fmt.tprintf("file:///%s", t)
	case strings.has_prefix(t, "localhost"), strings.has_prefix(t, "127.0.0.1"): return fmt.tprintf("http://%s", t)
	}
	return fmt.tprintf("https://%s", t)
}

// The state of the window the panel is in: its focus is there.
preview_state :: proc(app: ^App) -> ^ui.State { return view_state(app, PREVIEW_VIEW) }

// The web view's news (on the interface's thread, between two frames).
preview_set_url :: proc(app: ^App, t: ^Preview_Tab, url: string) {
	delete(t.url)
	t.url = strings.clone(url)
	if !preview_tab_shown(app, t) || ui.focus_key_of(preview_state(app)) != app.preview.addr_key { ui.line_edit_set(&t.field, url) }
}

preview_set_title :: proc(t: ^Preview_Tab, title: string) {
	delete(t.title)
	t.title = strings.clone(title)
}

// The tabs of a session that has several, above its address: the look of the dock's, inside its panel.
@(private = "file")
preview_strip :: proc(app: ^App, p: ^Preview, em: f32) {
	if len(p.tabs) < 2 { return }
	ui.next({width = ui.fill(), height = ui.px(math.round(em * PREVIEW_TAB_H_EM)), axis = .X, cross = .Center})
	if ui.row(.Center, id = "###pv_tabs") {
		strip_look()
		for t, i in p.tabs {
			in_front := i == p.front
			title := t.title != "" ? t.title : t.url != "" ? t.url : i18n.tr("New tab")
			ui.a11y({role = .Button, name = fmt.tprintf(i18n.tr("Browser tab: %s"), title)})
			ui.next({width = ui.fill(), height = ui.pct(1), axis = .X, cross = .Center})
			b := ui.build_box({.Clickable, .Middle_Click, .Hot_Within, .Clip}, fmt.tprintf("###pv_tab_%s", t.id))
			b.custom, b.custom_user = tab_look_draw, in_front ? rawptr(app) : nil
			sig := ui.signal(b)
			if sig.clicked { p.due_front = t }
			if sig.middle_clicked { p.due_close = t }
			if ui.parent(b) {
				col := in_front ? hex(HEX_BRIGHT) : sig.hovering ? hex(HEX_TEXT_SOFT) : hex(HEX_WEAK)
				ui.spacer(ui.px(em * 0.6))
				text("t", ellipsize(title, PREVIEW_TAB_TITLE_MOST), col, ui.Style_Mod{font_size = math.round(em * FS_NOTE)}, ui.fill())
				ui.a11y({role = .Button, name = i18n.tr("Close this tab")})
				ui.next({width = ui.px(math.round(em * GLYPH_BUTTON_EM * 0.75)), height = ui.px(math.round(em * GLYPH_BUTTON_EM * 0.75))})
				if ui.button("pv_tab_x", icon = lucide.X).clicked { p.due_close = t }
				ui.spacer(ui.px(em * 0.25))
			}
		}
	}
}

// What the address bar was given: the page goes there, and has the keyboard, now or when its view comes.
preview_commit :: proc(app: ^App, t: ^Preview_Tab, typed: string) {
	if u := preview_address(typed); u != "" {
		app.preview.open = true   // (the panel's own window shows a session that had no browser yet: now it has)
		web_navigate(app, t, u)
	}
	t.focus_page = true
	preview_page_focus(app, t)
}

// A view takes the keyboard only once it shows and has a page: asked before, it does nothing and says nothing. (A view just made comes here
// when its first page has loaded, and a page loading in one that is there waits as well.)
preview_page_focus :: proc(app: ^App, t: ^Preview_Tab) {
	_, ready := t.web.(Web_Ready)
	if !t.focus_page || !ready || !t.placed_shown || len(t.navs) > 0 || !preview_tab_shown(app, t) { return }
	t.focus_page = false
	web_act(t, .Focus)
}

// A row of the panel's strip.
@(private = "file")
preview_bar :: proc(app: ^App, t: ^Preview_Tab, em: f32) {
	p := &app.preview
	// (The panel has the keyboard: elsewhere these are not this panel's to take. In the page they come by web_event_apply.)
	if p.addr_key != 0 && ui.focus_key() == p.addr_key {
		if ui.key_press(.T, {.Ctrl}) { p.due_new = true }
		if ui.key_press(.W, {.Ctrl}) { p.due_close = t }
	}
	h := math.round(em * 2.4)
	ui.next({width = ui.fill(), height = ui.px(h), axis = .X, cross = .Center})
	if ui.row(.Center, id = "###pv_bar") {
		ui.spacer(ui.px(em * 0.4))
		size := math.round(em * GLYPH_BUTTON_EM)
		ui.next({width = ui.px(size), height = ui.px(size)})
		if ui.button("pv_back", icon = lucide.ARROW_LEFT).clicked { web_act(t, .Back) }
		ui.next({width = ui.px(size), height = ui.px(size)})
		if ui.button("pv_fwd", icon = lucide.CHEVRON_RIGHT).clicked { web_act(t, .Forward) }
		ui.next({width = ui.px(size), height = ui.px(size)})
		if ui.button("pv_reload", icon = preview_loading(t) ? lucide.X : lucide.REFRESH_CW).clicked { web_act(t, preview_loading(t) ? .Stop : .Reload) }
		ui.spacer(ui.px(em * 0.35))
		ui.next({width = ui.fill(), height = ui.px(math.round(em * 1.8)), axis = .X, cross = .Center})
		if ui.well("###pv_addr", .X) {
			ui.spacer(ui.px(em * 0.4))
			if ui.tags("bare") {
				ui.next({width = ui.fill(), height = ui.pct(1), text_pad = em * 0.3, font = app.mono, font_size = math.round(em * FS_SMALL)})
				res := ui.line_edit("###pv_url", &t.field, {placeholder = i18n.tr("localhost:3000 or an address")})
				p.addr_key = res.box.key
				if t.focus_address { ui.set_focus(res.box.key); t.focus_address = false }
				if res.committed { preview_commit(app, t, ui.line_edit_string(&t.field)) }
			}
		}
		ui.spacer(ui.px(em * 0.35))
		ui.a11y({role = .Button, name = i18n.tr("New browser tab")})
		ui.next({width = ui.px(size), height = ui.px(size)})
		if ui.button("pv_new", icon = lucide.PLUS).clicked { p.due_new = true }
		ui.next({width = ui.px(size), height = ui.px(size)})
		if ui.button("pv_out", icon = lucide.GLOBE).clicked && t.url != "" { ui.open(t.url, .Url) }
		ui.spacer(ui.px(em * 0.4))
	}
	edge_line("###pv_edge")
}

// The panel's view: wherever it is, its page goes where its body is laid out (preview_after_frames).
preview_view :: proc(v: ^ui.View, app: ^App) {
	em := ui.font_size()
	p := &app.preview
	ui.view_title(v, preview_title(app))
	// (unseen, it is measured: its page waits for where it shows)
	if v.shown { p.shown = true }
	t := preview_front_made(app, p)
	ui.next({width = ui.fill(), height = ui.fill(), axis = .Y, bg = hex(HEX_PREVIEW_BG), radius = 0})
	if ui.column(flags = {.Draw_Background}, id = "###pv") {
		preview_strip(app, p, em)
		preview_bar(app, t, em)
		ui.next({width = ui.fill(), height = ui.fill(), axis = .X, cross = .Center})
		b := ui.build_box({}, "###pv_page")
		if v.shown {
			p.body = b.rect
			// (a floating view over the page: it steps aside, or it would hide it)
			p.occluded = false
			for r in ui.view_occluders(v) {
				if r.min.x < b.rect.max.x && b.rect.min.x < r.max.x && r.min.y < b.rect.max.y && b.rect.min.y < r.max.y { p.occluded = true }
			}
		}
		if ui.parent(b) {
			msg := ""
			failed := false
			switch w in t.web {
			case Web_Failed:
				msg, failed = fmt.tprintf(i18n.tr("The page could not start: %s"), w.why), true
			case Web_Creating:
				msg = i18n.tr("Starting the web view…")
			case Web_Ready:
				if preview_covered(app) { msg = t.title } else if t.url == "" { msg = i18n.tr(PREVIEW_NOTHING) }
			case nil:
				msg = t.asked ? i18n.tr("Starting the web view…") : i18n.tr(PREVIEW_NOTHING)
			}
			if msg != "" {
				ui.spacer(ui.fill())
				text("m", msg, hex(HEX_FAINT), ui.Style_Mod{font_size = math.round(em * FS_NOTE)})
				if failed {
					ui.spacer(ui.px(em * 0.5))
					if ui.button("pv_again", i18n.tr("Try again"), lucide.REFRESH_CW, {height = math.round(em * BUTTON_COMPACT_H_EM)}).clicked { web_start(app, t) }
				}
				ui.spacer(ui.fill())
			}
		}
	}
}

// Something of the toolkit's is over the page in the window it is in: a view that floats or a dialog over it (its last
// build: ui.view_occluders), a menu, the file browser. (The page is a child window of the system's: it would hide them.)
preview_covered :: proc(app: ^App) -> bool {
	st := preview_state(app)
	// (a dialog anywhere: its scrim dims the whole window, the page with it; the page in a dialog: those over it, occluded)
	dialog := len(st.modals_open) > 0 && ui.view_presentation(&app.program_views, PREVIEW_VIEW) != .Dialog
	return app.preview.occluded || dialog || len(st.menus) > 0 || ui.file_dialog_shown(st)
}

// The page follows its view to another window of the system (View_Options.moved), at once: the window it leaves may close
// before the frame ends. (The web view is told its parent; what it says comes back on its own queue: web_events_drain.)
preview_moved :: proc(data: rawptr, win: ^platform.Window) {
	app := (^App)(data)
	app.previews.win = win == app.win ? nil : win
	preview_move(app, win)
}

// The panel closes: its page goes back to the main window first, as a window of its own closes with what is in it.
preview_home :: proc(app: ^App) {
	if app.previews.win != nil { preview_moved(app, app.win) }
}

// After the frames of every window (the main one, then the views'): the page where its panel was laid out, or out of the
// way of what the toolkit shows over it.
preview_after_frames :: proc(app: ^App) {
	preview_place(app, preview_covered(app))
	app.preview.shown = false
}

// The window the panel is in (the main one until it moved).
preview_panel_window :: proc(app: ^App) -> ^platform.Window {
	return app.previews.win != nil ? app.previews.win : app.win
}

// The page where the panel's body was laid out (`over`: something of the toolkit's is over it: out of the way).
preview_place :: proc(app: ^App, over: bool) {
	p := &app.preview
	t := preview_front(p)
	if t == nil { return }
	show := p.open && p.shown && !over
	r := p.body
	x, y := int(math.round(r.min.x)), int(math.round(r.min.y))
	w, h := int(math.round(r.max.x - r.min.x)), int(math.round(r.max.y - r.min.y))
	// A page laid out again is the browser's work, not this frame's: while the window or a splitter moves it follows at its
	// own pace, so that the interface keeps its own; it lands exactly when the move ends. Nothing changed: nothing is asked.
	same := t.placed == [4]int{x, y, w, h} && t.placed_shown == show
	if same { return }
	now := ui.now_ms()
	if show == t.placed_shown && now - t.placed_ms < PREVIEW_PLACE_MS {
		app.settle = max(app.settle, 1)   // (the last step is not lost)
		return
	}
	t.placed, t.placed_shown, t.placed_ms = {x, y, w, h}, show, now
	web_place(t, x, y, w, h, show)
	preview_page_focus(app, t)
}


