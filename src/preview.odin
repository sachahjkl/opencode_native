// The Preview panel: a web page beside the conversation, in a dock (the panels can be moved, stacked, floated and folded by
// their tabs; their layout is a preference). What an agent builds shows here, and the agents can drive it (browser_mcp.odin).
// The Statistics panel (stats.odin) shares its place: one stack, a tab each, never a second panel at the side.
// While the panel is closed there is no dock at all: a lone tab strip would only take room. The page is a child window of
// the system's, over everything the toolkit draws in its place: it steps aside while a dialog or a menu is open.
package occ

import "core:fmt"
import "core:math"
import "core:strings"
import "gt:config"
import "gt:draw"
import "gt:platform"
import "gt:ui"

// (Panel.Terminal: while there is no shell. The shells are panels too, from TERM_PANEL_BASE.)
Panel :: enum u32 { Conversation = 1, Preview, Terminal, Stats }

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

Preview :: struct {
	open:     bool,
	field:    ui.Text_Field,      // the address
	url:      string,             // what the page shows (owned)
	title:    string,             // (owned)
	navs:     [dynamic]u64,       // the navigations under way: one can begin before the last ends
	web:      Web_State,
	events:   [dynamic]Web_Event, // said since the last drain
	body:     Rect,               // where the page goes, at the last layout (frame pixels)
	shown:    bool,               // the panel's body was built in this frame
	addr_key: ui.Key,             // the address field: what the page says does not overwrite what one types
	focus_address: bool,          // it takes the focus at its next build
	placed:   [4]int,             // x, y, width, height last given to the view
	placed_shown: bool,
	placed_ms: f64,
}

// The dock's look: a flat bar, and on it words. No tab has a surface or an edge of its own: the one shown is lit, with a line
// as wide as it lying on the bar's lower edge. What a tab is shows by what it says, not by a box around it.
@(private = "file")
tab_look_draw :: proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
	if user == nil { return }   // (not the one shown)
	r := b.rect
	h := 2 * px1()
	inset := TAB_LINE_INSET_EM * ui.font_size()
	draw.rect(dc, {{r.min.x + inset, r.max.y - h}, {r.max.x - inset, r.max.y}}, accent())
}

@(private = "file")
panel_tab :: proc(user: rawptr, t: ui.Dock_Tab) {
	app := (^App)(user)
	em := ui.font_size()
	t.box.flags -= {.Draw_Hot_Effects}   // (the theme's box under the pointer)
	t.box.custom, t.box.custom_user = tab_look_draw, t.active ? rawptr(app) : nil
	if t.panel >= TERM_PANEL_BASE && ui.signal(t.box).clicked { term_focus_ask(app, t.panel) }   // (a shell's tab: to type in it)
	col := t.active ? hex(HEX_BRIGHT) : t.hot ? hex(HEX_TEXT_SOFT) : hex(HEX_WEAK)
	ui.spacer(ui.px(em * TAB_PAD_EM))
	text("t", panel_title(app, t.panel), col, ui.Style_Mod{font_size = math.round(em * FS_NOTE)})
	ui.spacer(ui.px(em * TAB_PAD_EM))
}

@(private = "file")
strip_look :: proc(user: rawptr, d: ^ui.Dock, leaf: i32) {
	b := ui.parent_box()
	b.custom = proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
		draw.rect(dc, b.rect, hex(HEX_BG1))
		draw.rect(dc, {{b.rect.min.x, b.rect.max.y - px1()}, b.rect.max}, hex(HEX_LINE))
	}
}

@(private = "file")
strip_end :: proc(user: rawptr, d: ^ui.Dock, leaf: i32) { terminal_strip_end((^App)(user), d, leaf, ui.font_size()) }

panel_title :: proc(user: rawptr, panel: u32) -> string {
	app := (^App)(user)
	if t := term_of_panel(app, panel); t != nil { return term_label(t) }
	switch Panel(panel) {
	case .Conversation: return "Conversation"
	case .Preview:      return app.preview.title != "" ? ellipsize(app.preview.title, 28) : "Preview"
	case .Terminal:     return "Terminal"
	case .Stats:        return "Statistics"
	}
	return ""
}

@(private = "file")
panel_closable :: proc(user: rawptr, panel: u32) -> bool { return Panel(panel) != .Conversation }

// In the saved layout a shell goes by the server's id: another run gives it another panel. A shell gone, a shell of another server: no
// panel answers to its name, and the layout drops it, with the stack it leaves empty.
PANEL_SHELL_PREFIX :: "shell-"

panel_name :: proc(user: rawptr, id: u32) -> string {
	if t := term_of_panel((^App)(user), id); t != nil { return fmt.tprintf("%s%s", PANEL_SHELL_PREFIX, t.id) }
	switch Panel(id) {
	case .Conversation: return "conversation"
	case .Preview:      return "preview"
	case .Terminal:     return "terminal"
	case .Stats:        return "statistics"
	}
	return ""
}

panel_of :: proc(user: rawptr, name: string) -> (u32, bool) {
	if strings.has_prefix(name, PANEL_SHELL_PREFIX) {
		t := term_find((^App)(user), name[len(PANEL_SHELL_PREFIX):])
		return t != nil ? t.panel : 0, t != nil
	}
	switch name {
	case "conversation": return u32(Panel.Conversation), true
	case "preview":      return u32(Panel.Preview), true
	case "terminal":     return u32(Panel.Terminal), true
	case "statistics":   return u32(Panel.Stats), true
	}
	return 0, false
}

@(private = "file")
dock_save :: proc(user: rawptr, d: ^ui.Dock) {
	pref_set((^App)(user), "layout.dock", ui.dock_format(d, panel_name, user))
}

// The layout of the preferences, every panel in it.
dock_setup :: proc(app: ^App) {
	d := &app.dock
	ui.dock_init(d)
	if !ui.dock_parse(d, config.string_of(&app.cfg_prefs, "layout.dock"), panel_of, app) { ui.dock_parse(d, DOCK_DEFAULT, panel_of, app) }
	if !ui.dock_has(d, u32(Panel.Conversation)) { ui.dock_parse(d, DOCK_DEFAULT, panel_of, app) }
	// The Preview and the Statistics share a stack: each goes where the other stands, or stood in the layout (it is closed after),
	// and takes its width; else beside the conversation.
	beside :: proc(d: ^ui.Dock, other: Panel) -> ui.Dock_Target {
		return ui.dock_has(d, u32(other)) ? ui.dock_with(d, u32(other)) : ui.dock_beside(d, u32(Panel.Conversation), .Right)
	}
	if app.preview.open && !ui.dock_has(d, u32(Panel.Preview)) { ui.dock_add(d, u32(Panel.Preview), beside(d, .Stats)) }
	if app.stats_open && !ui.dock_has(d, u32(Panel.Stats)) { ui.dock_add(d, u32(Panel.Stats), beside(d, .Preview)) }
	// (only what is open has a tab)
	if !app.preview.open { ui.dock_close(d, u32(Panel.Preview)) }
	if !app.stats_open { ui.dock_close(d, u32(Panel.Stats)) }
	terminals_dock(app)
}

// One way out of the dock for every panel, whichever way it is closed: its tab, its key, its menu, the program itself. Nothing keeps a tab
// whose panel is gone, nor a panel without its tab.
panel_close :: proc(app: ^App, panel: u32) {
	switch {
	case panel == u32(Panel.Preview):
		app.preview.open = false
		ui.dock_close(&app.dock, panel)
	case panel == u32(Panel.Stats):
		app.stats_open = false
		ui.dock_close(&app.dock, panel)
	case panel == u32(Panel.Terminal):
		terminals_hide(app)
	case:
		if t := term_of_panel(app, panel); t != nil { term_close(app, t) }
	}
	app.frames = max(app.frames, FRAMES_AFTER_INPUT)
}

// (read once: this is asked at every frame, and it is a look in the registry)
preview_available :: proc() -> bool {
	@(static) known, available: bool
	if !known { known, available = true, web_available() }
	return available
}

preview_toggle :: proc(app: ^App) {
	if !preview_available() { ui.toast(.Warn, "The Preview panel needs the WebView2 runtime"); return }
	if app.preview.open { panel_close(app, u32(Panel.Preview)) } else { preview_show(app) }
}

preview_show :: proc(app: ^App, by := Asked_By.User) {
	p := &app.preview
	p.open = true
	dock_setup(app)
	web_start(app)
	ui.dock_activate(&app.dock, u32(Panel.Preview))
	p.focus_address = by == .User && p.url == ""   // (nothing to show yet: what comes next is an address)
	app.frames = max(app.frames, FRAMES_AFTER_INPUT)
}

// A link: in the panel where there is one, else in the system's browser.
preview_open :: proc(app: ^App, url: string, by := Asked_By.User) {
	if !preview_available() { _ = platform.open_url(url); return }
	preview_go(app, url, by)
}

preview_go :: proc(app: ^App, url: string, by: Asked_By) {
	p := &app.preview
	if !p.open { preview_show(app, by) }
	ui.dock_activate(&app.dock, u32(Panel.Preview))
	web_navigate(app, url)
	ui.field_set(&p.field, url)
}

preview_loading :: proc(p: ^Preview) -> bool { return len(p.navs) > 0 }

web_state_set :: proc(p: ^Preview, state: Web_State) {
	if f, failed := p.web.(Web_Failed); failed { delete(f.why) }
	p.web = state
}

// The page went with a server left: what it shows was that server's work, and what an agent of the next one would read there is not its own.
// The view goes too, and the next one starts clean.
preview_forget :: proc(app: ^App) {
	p := &app.preview
	if p.open { panel_close(app, u32(Panel.Preview)) }
	web_close(app)
	web_events_drop(p)
	web_state_set(p, nil)
	clear(&p.navs)
	delete(p.url); delete(p.title)
	p.url, p.title = "", ""
	ui.field_set(&p.field, "")
	p.focus_address = false
	p.placed, p.placed_shown, p.placed_ms = {}, false, 0
}

////////////////////////////////
// What the web view says

// (On the window's message loop, maybe in a build: it only keeps it. `ctrl`: read now, the key is down now.)
web_event_add :: proc(app: ^App, kind: Web_Event_Kind, id: u64, data: []u8, ctrl := false) {
	own := make([]u8, len(data))
	copy(own, data)
	append(&app.preview.events, Web_Event{kind, id, own, ctrl})
	app.frames = max(app.frames, FRAMES_AFTER_INPUT)
}

web_events_drop :: proc(p: ^Preview) {
	for e in p.events { delete(e.data) }
	clear(&p.events)
}

// The frame's point for it: no build runs, and what an event does may say more (a script refused answers at once): that waits for the next.
web_events_drain :: proc(app: ^App) {
	p := &app.preview
	if len(p.events) == 0 { return }
	batch := p.events
	p.events = {}
	defer delete(batch)
	for e in batch {
		web_event_apply(app, e)
		delete(e.data)
	}
}

@(private = "file")
web_event_apply :: proc(app: ^App, e: Web_Event) {
	p := &app.preview
	s := string(e.data)
	switch e.kind {
	case .Ready:
		web_state_set(p, Web_Ready{})
	case .Failed:
		web_state_set(p, Web_Failed{strings.clone(s)})
		clear(&p.navs)
		browser_calls_fail(app, s)
	case .Source:    preview_set_url(app, s)
	case .Title:     preview_set_title(app, s)
	case .Nav_Start: preview_nav_started(app, e.id)
	case .Loaded:    preview_nav_ended(app, e.id, len(e.data) > 0 && e.data[0] != 0)
	case .Script:    browser_script_done(app, e.id, s)
	case .Capture:   browser_capture_done(app, e.id, e.data)
	case .Key:
		// (the page has the keyboard: what the program answers to must still reach it)
		if e.ctrl && e.id == u64('K') { command_run(app, command_find("app.palette")) }
		if e.id == VK_F1 { command_run(app, command_find("app.help")) }
	}
}

// (A redirection is the same navigation, started again.)
@(private = "file")
preview_nav_started :: proc(app: ^App, nav: u64) {
	p := &app.preview
	for n in p.navs { if n == nav { return } }
	append(&p.navs, nav)
	browser_nav_started(app, nav)
}

@(private = "file")
preview_nav_ended :: proc(app: ^App, nav: u64, ok: bool) {
	p := &app.preview
	for n, i in p.navs { if n == nav { ordered_remove(&p.navs, i); break } }
	browser_page_loaded(app, nav, ok)
}

reveal_path :: proc(path: string) { _ = platform.reveal_in_folder(path) }

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

// The web view's news (on the interface's thread, between two frames).
preview_set_url :: proc(app: ^App, url: string) {
	p := &app.preview
	delete(p.url)
	p.url = strings.clone(url)
	if ui.focus_key() != p.addr_key { ui.field_set(&p.field, url) }
}

preview_set_title :: proc(app: ^App, title: string) {
	delete(app.preview.title)
	app.preview.title = strings.clone(title)
}

// A row of the panel's strip.
@(private = "file")
preview_bar :: proc(app: ^App, em: f32) {
	p := &app.preview
	h := math.round(em * 2.4)
	ui.next({width = ui.fill(), height = ui.px(h), axis = .X, cross = .Center})
	if ui.row(.Center, id = "###pv_bar") {
		ui.spacer(ui.px(em * 0.4))
		size := math.round(em * GLYPH_BUTTON_EM)
		if glyph_button("###pv_back", ICO_BACK, size).clicked { web_act(app, .Back) }
		if glyph_button("###pv_fwd", ICO_RIGHT, size).clicked { web_act(app, .Forward) }
		if glyph_button("###pv_reload", preview_loading(p) ? ICO_CANCEL : ICO_REFRESH, size).clicked { web_act(app, preview_loading(p) ? .Stop : .Reload) }
		ui.spacer(ui.px(em * 0.35))
		ui.next({width = ui.fill(), height = ui.px(math.round(em * 1.8)), axis = .X, cross = .Center})
		if well("###pv_addr", .X, radius = 6) {
			ui.spacer(ui.px(em * 0.4))
			if ui.tags("bare") {
				ui.next({width = ui.fill(), height = ui.pct(1), text_pad = em * 0.3, font = app.mono, font_size = math.round(em * FS_SMALL)})
				res := ui.line_edit("###pv_url", &p.field, "localhost:3000 or an address")
				p.addr_key = res.box.key
				if p.focus_address { ui.set_focus(res.box.key); p.focus_address = false }
				if res.committed {
					if u := preview_address(ui.field_string(&p.field)); u != "" { web_navigate(app, u) }
					web_act(app, .Focus)
				}
			}
		}
		ui.spacer(ui.px(em * 0.35))
		if glyph_button("###pv_out", ICO_GLOBE, size).clicked && p.url != "" { _ = platform.open_url(p.url) }
		ui.spacer(ui.px(em * 0.4))
	}
	edge_line("###pv_edge")
}

@(private = "file")
preview_panel :: proc(app: ^App, em: f32) {
	p := &app.preview
	p.shown = true
	ui.next({width = ui.fill(), height = ui.fill(), axis = .Y, bg = hex(HEX_PREVIEW_BG), radius = 0})
	if ui.column(flags = {.Draw_Background}, id = "###pv") {
		preview_bar(app, em)
		ui.next({width = ui.fill(), height = ui.fill(), axis = .X, cross = .Center})
		b := ui.build_box({}, "###pv_page")
		p.body = b.rect
		if ui.parent(b) {
			msg := ""
			failed := false
			switch w in p.web {
			case Web_Failed:
				msg, failed = fmt.tprintf("The page could not start: %s", w.why), true
			case Web_Creating:
				msg = "Starting the web view…"
			case Web_Ready:
				if overlay_open(app) { msg = p.title } else if p.url == "" { msg = "Nothing to show yet. Type an address above, or let an agent open one." }
			case nil:
				msg = "Starting the web view…"
			}
			if msg != "" {
				ui.spacer(ui.fill())
				text("m", msg, hex(HEX_FAINT), ui.Style_Mod{font_size = math.round(em * FS_NOTE)})
				if failed {
					ui.spacer(ui.px(em * 0.5))
					if bevel_button("###pv_again", "Try again", ICO_REFRESH, .Normal, height = math.round(em * BUTTON_COMPACT_H_EM)).clicked { web_start(app) }
				}
				ui.spacer(ui.fill())
			}
		}
	}
}

// Where the conversation goes: alone, or as a panel of the dock.
main_area :: proc(app: ^App, em: f32) {
	p := &app.preview
	s := &app.cx.terms
	p.shown = false
	terminals_begin(app)
	defer terminals_settle(app)
	app.cx.docked_w = 0
	// (in the dock or out of it the conversation is other boxes, and their scroll starts at the top: whatever opened or closed a panel)
	docked := p.open || s.open || app.stats_open
	if docked != app.cx.was_docked {
		app.cx.was_docked = docked
		nav_hold_view(app)
	}
	if !docked { conversation(app, em); return }
	d := &app.dock
	ui.next({width = ui.fill(), height = ui.fill()})
	ui.dock_begin(d, "###dock", {title = panel_title, tab = panel_tab, strip_begin = strip_look, strip_end = strip_end, closable = panel_closable, on_save = dock_save, user = app, close_buttons = true, tab_height = math.round(em * DOCK_TAB_H_EM)})
	if ui.dock_panel(d, u32(Panel.Conversation)) {
		app.cx.docked_w = ui.dock_panel_size(d, u32(Panel.Conversation)).x
		conversation(app, em)
	}
	if p.open {
		if ui.dock_panel(d, u32(Panel.Preview)) { preview_panel(app, em) }
	}
	if app.stats_open {
		if ui.dock_panel(d, u32(Panel.Stats)) {
			app.cx.stats_w = ui.dock_panel_size(d, u32(Panel.Stats)).x
			stats_panel(app, em)
		}
	}
	if s.open {
		for t in s.list {
			if t.detached { continue }
			if ui.dock_panel(d, t.panel) { terminal_panel(app, em, t) }
		}
		if ui.dock_panel(d, u32(Panel.Terminal)) { terminal_waiting(app, em) }
	}
	res := ui.dock_end(d)
	if res.closed != ui.DOCK_NO_PANEL { panel_close(app, res.closed) }
	if s.close_due != 0 {
		panel_close(app, s.close_due)
		s.close_due = 0
	}
}

// After the frame: the page where its panel was laid out, or out of the way of what the toolkit shows over it.
preview_place :: proc(app: ^App) {
	p := &app.preview
	over := overlay_open(app) || ui.active_key() != 0 && app.dock.held
	show := p.open && p.shown && !over
	r := p.body
	x, y := int(math.round(r.min.x)), int(math.round(r.min.y))
	w, h := int(math.round(r.max.x - r.min.x)), int(math.round(r.max.y - r.min.y))
	// A page laid out again is the browser's work, not this frame's: while the window or a splitter moves it follows at its
	// own pace, so that the interface keeps its own; it lands exactly when the move ends. Nothing changed: nothing is asked.
	same := p.placed == [4]int{x, y, w, h} && p.placed_shown == show
	if same { return }
	now := ui.now_ms()
	if show == p.placed_shown && now - p.placed_ms < PREVIEW_PLACE_MS {
		app.frames = max(app.frames, 1)   // (the last step is not lost)
		return
	}
	p.placed, p.placed_shown, p.placed_ms = {x, y, w, h}, show, now
	web_place(app, x, y, w, h, show)
}


