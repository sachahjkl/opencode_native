// The Preview panel: a web page beside the conversation, in a dock (the panels can be moved, stacked, floated and folded by
// their tabs; their layout is a preference). What an agent builds shows here, and the agents can drive it (browser_mcp.odin).
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

Panel :: enum u32 { Conversation = 1, Preview, Terminal }

Preview :: struct {
	open:     bool,
	field:    ui.Text_Field,      // the address
	url:      string,             // what the page shows (owned)
	title:    string,             // (owned)
	loading:  bool,
	ready:    bool,               // the view exists
	failed:   string,             // why it could not be made (owned)
	body:     Rect,               // where the page goes, at the last layout (frame pixels)
	shown:    bool,               // the panel's body was built in this frame
	asked:    string,             // an address to open once the view exists (owned)
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
panel_title :: proc(user: rawptr, panel: u32) -> string {
	app := (^App)(user)
	switch Panel(panel) {
	case .Conversation: return "Conversation"
	case .Preview:      return app.preview.title != "" ? ellipsize(app.preview.title, 28) : "Preview"
	case .Terminal:     return "Terminal"
	}
	return ""
}

@(private = "file")
panel_closable :: proc(user: rawptr, panel: u32) -> bool { return Panel(panel) != .Conversation }

@(private = "file")
panel_name :: proc(user: rawptr, id: u32) -> string { return Panel(id) == .Preview ? "preview" : Panel(id) == .Terminal ? "terminal" : "conversation" }

@(private = "file")
panel_of :: proc(user: rawptr, name: string) -> (u32, bool) {
	switch name {
	case "conversation": return u32(Panel.Conversation), true
	case "preview":      return u32(Panel.Preview), true
	case "terminal":     return u32(Panel.Terminal), true
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
	// (only what is open has a tab)
	if app.preview.open {
		if !ui.dock_has(d, u32(Panel.Preview)) { ui.dock_add(d, u32(Panel.Preview), ui.dock_beside(d, u32(Panel.Conversation), .Right)) }
	} else {
		ui.dock_close(d, u32(Panel.Preview))
	}
	if app.cx.terms.open {
		if !ui.dock_has(d, u32(Panel.Terminal)) { ui.dock_add(d, u32(Panel.Terminal), ui.Dock_Target{place = .Edge_Bottom}) }
	} else {
		ui.dock_close(d, u32(Panel.Terminal))
	}
}

// (read once: this is asked at every frame, and it is a look in the registry)
preview_available :: proc() -> bool {
	@(static) known, available: bool
	if !known { known, available = true, web_available() }
	return available
}

preview_toggle :: proc(app: ^App) {
	p := &app.preview
	if !preview_available() { ui.toast(.Warn, "The Preview panel needs the WebView2 runtime"); return }
	p.open = !p.open
	if p.open {
		dock_setup(app)
		web_start(app)
		ui.dock_activate(&app.dock, u32(Panel.Preview))
		p.focus_address = p.url == ""   // (nothing to show yet: what comes next is an address)
	}
	app.frames = max(app.frames, FRAMES_AFTER_INPUT)
}

// A link: in the panel where there is one, else in the system's browser.
preview_open :: proc(app: ^App, url: string) {
	if !preview_available() { _ = platform.open_url(url); return }
	p := &app.preview
	if !p.open { preview_toggle(app) }
	ui.dock_activate(&app.dock, u32(Panel.Preview))
	web_navigate(app, url)
	ui.field_set(&p.field, url)
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
		if glyph_button("###pv_reload", p.loading ? ICO_CANCEL : ICO_REFRESH, size).clicked { web_act(app, p.loading ? .Stop : .Reload) }
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
			switch {
			case p.failed != "":     msg = fmt.tprintf("The page could not start: %s", p.failed)
			case !p.ready:           msg = "Starting the web view…"
			case overlay_open(app):  msg = p.title
			case p.url == "":        msg = "Nothing to show yet. Type an address above, or let an agent open one."
			}
			if msg != "" {
				ui.spacer(ui.fill())
				text("m", msg, hex(HEX_FAINT), ui.Style_Mod{font_size = math.round(em * FS_NOTE)})
				ui.spacer(ui.fill())
			}
		}
	}
}

// Where the conversation goes: alone, or as a panel of the dock.
main_area :: proc(app: ^App, em: f32) {
	p := &app.preview
	p.shown = false
	app.cx.docked_w = 0
	// (in the dock or out of it the conversation is other boxes, and their scroll starts at the top: whatever opened or closed a panel)
	docked := p.open || app.cx.terms.open
	if docked != app.cx.was_docked {
		app.cx.was_docked = docked
		nav_hold_view(app)
	}
	if !docked { conversation(app, em); return }
	d := &app.dock
	ui.next({width = ui.fill(), height = ui.fill()})
	ui.dock_begin(d, "###dock", {title = panel_title, tab = panel_tab, strip_begin = strip_look, closable = panel_closable, on_save = dock_save, user = app, close_buttons = true, tab_height = math.round(em * DOCK_TAB_H_EM)})
	if ui.dock_panel(d, u32(Panel.Conversation)) {
		app.cx.docked_w = ui.dock_panel_size(d, u32(Panel.Conversation)).x
		conversation(app, em)
	}
	if p.open {
		if ui.dock_panel(d, u32(Panel.Preview)) { preview_panel(app, em) }
	}
	if app.cx.terms.open {
		if ui.dock_panel(d, u32(Panel.Terminal)) { terminal_panel(app, em) }
	}
	res := ui.dock_end(d)
	if res.closed == u32(Panel.Preview) { p.open = false }
	if res.closed == u32(Panel.Terminal) {
		app.cx.terms.open = false
		app.cx.terms.focused = false
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


