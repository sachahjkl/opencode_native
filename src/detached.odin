package ocn

import "core:math"
import "gt:draw"
import "gt:host"
import "gt:platform"
import "gt:ui"

// A panel in a window of its own, for a large screen or a second one. The same program, the same renderer, the same connection:
// the window has a ui.State and a surface of its own, and is built after the main one, in its frame. The panel goes on as ever;
// closing the window gives it its tab back.
//
// It is a host.Host, as the main window: its frame goes in the toolkit's order, this program's parts in its hooks. Being resized it is as
// stable as the main window, by the same means: a composition surface whose buffers keep the monitor's size, shown 1:1 and clipped by the
// window (below its child windows: the page moved into it would be behind it), and frames from inside the system's loop for as long as the
// border is held. A step of a resize is this window's alone, at once; when the border rests, the program's whole frame goes on.

Detached :: struct {
	using window: host.Host,   // win, state, surface, shown
	app:       ^App,
	panel:     u32,
	closing:   bool,   // its panel was closed: a Preview's window outlives a session with no browser, not this
	had_input: bool,   // in this frame
	built:     bool,   // ... and it was built
	keyboard:  ^Term,  // whose the keys were before this window's build took them
}

panel_detached :: proc(app: ^App, panel: u32) -> bool { return detached_window(app, panel) != nil }

// The panel's window, if it has one.
detached_window :: proc(app: ^App, panel: u32) -> ^platform.Window {
	for d in app.cx.detached {
		if d.panel == panel { return d.win }
	}
	return nil
}

// The state of the panel's window, if it has one.
detached_state :: proc(app: ^App, panel: u32) -> ^ui.State {
	for d in app.cx.detached {
		if d.panel == panel { return &d.state }
	}
	return nil
}

// A panel looks the same out of the main window: what its state was given, whenever a preference gave it, is read at each frame. (Plain
// values, and faces that only change the state when they differ.)
detached_style :: proc(app: ^App, s: ^ui.State) {
	m := &app.state
	ui.set_zoom(s, m.zoom)
	ui.set_density(s, m.density)
	ui.set_rounding(s, m.rounding)
	ui.set_scrollbar_autohide(s, app.prefs.autohide_scrollbars)
	ui.set_toast_position(s, m.toast_pos)
	s.icon_font, s.mono_font = m.icon_font, m.mono_font
	for regular, set in m.families { ui.set_family(s, regular, set[1], set[2], set[3]) }
}

// What a window's build leaves to the program's loop, which only looks at the main state: input settles as it does there, and what the window
// waits for (a tooltip, a bar to hide, a caret) wakes it.
detached_asks :: proc(app: ^App, s: ^ui.State, had_input: bool) {
	if had_input { app.settle = max(app.settle, FRAMES_AFTER_INPUT) }
	if ui.needs_frame(s) { app.settle = max(app.settle, 1) }
	if wait := ui.wake_in_ms(s); wait > 0 { ui.wake_within(&app.state, wait) }
}

// Nothing it shows can have changed: its last picture stays, and it costs nothing. (A pointer passing over the main window used to build and
// present every other window too.)
detached_still :: proc(app: ^App, d: ^Detached, had_input: bool) -> bool {
	return !had_input && !app.cx.shared_moved && d.win.size == d.shown && !ui.needs_frame(&d.state) && !ui.wake_due(&d.state)
}

// The panel was closed, by whatever way: its window goes at the next frame.
detached_closing :: proc(app: ^App, panel: u32) {
	for d in app.cx.detached {
		if d.panel == panel { d.closing = true }
	}
}

@(private = "file")
panel_can_detach :: proc(panel: u32) -> bool { return panel != u32(Panel.Conversation) && panel != u32(Panel.Terminal) }

panel_detach :: proc(app: ^App, panel: u32) {
	if !panel_can_detach(panel) || panel_detached(app, panel) { return }
	d := new(Detached)
	d.panel, d.app = panel, app
	if !host.host_open(&d.window, &app.gfx, {title = panel_title(app, panel), size = {DETACHED_W, DETACHED_H}, under_children = panel == u32(Panel.Preview)}, detached_build, d) {
		free(d)
		ui.toast(.Bad, "No window: the renderer refused it")
		return
	}
	platform.set_dark_title(d.win, !app.cx.theme.light)
	detached_hooks(d)
	ui.set_autoscroll_enabled(&d.state, true)
	if t := term_of_panel(app, panel); t != nil { t.detached = true }
	if panel < OUTPUT_PANEL_BASE { ui.dock_close(&app.dock, panel) }   // (a command's output never had a tab)
	append(&app.cx.detached, d)
	if panel == u32(Panel.Preview) { preview_move(app, d.win) }
	platform.show_window(d.win)
	app.settle = max(app.settle, FRAMES_AFTER_INPUT)
}

@(private = "file")
detached_end :: proc(app: ^App, i: int) {
	d := app.cx.detached[i]
	ordered_remove(&app.cx.detached, i)
	if d.panel < OUTPUT_PANEL_BASE { if t := term_of_panel(app, d.panel); t != nil { t.detached = false } }
	if d.panel == u32(Panel.Preview) { preview_move(app, app.win) }
	panel := d.panel
	host.host_close(&d.window)
	output_view_window_left(app, panel)
	free(d)
}

// A panel that is going: its window with it.
detached_forget :: proc(app: ^App, panel: u32) {
	for d, i in app.cx.detached {
		if d.panel == panel { detached_end(app, i); return }
	}
}

// The program closes.
detached_stop :: proc(app: ^App) {
	for len(app.cx.detached) > 0 { detached_end(app, len(app.cx.detached) - 1) }
}

@(private = "file")
detached_body :: proc(app: ^App, d: ^Detached, size: draw.Vec2, em: f32) {
	if v := output_view_of_panel(app, d.panel); v != nil {
		output_view_body(app, v, em, true)
		ui.set_focus(v.term.view.box)
		return
	}
	switch {
	case d.panel == u32(Panel.Stats):
		app.cx.stats_w = size.x
		stats_panel(app, em)
	case d.panel == u32(Panel.Preview):
		preview_panel(app, em)
	case:
		if t := term_of_panel(app, d.panel); t != nil {
			terminal_panel(app, em, t)
			ui.set_focus(t.view.box)
		}
	}
}

@(private = "file")
detached_build :: proc(h: ^host.Host, size: draw.Vec2) {
	d := (^Detached)(h.user)
	detached_body(d.app, d, size, math.round(ui.font_size()))
}

// Its parts of a frame. The shell of a window of its own has its keys: what comes to this window is for it.
@(private = "file")
detached_hooks :: proc(d: ^Detached) {
	h := &d.window
	h.background = hex(HEX_BG0)
	h.partial_redraw = true   // each frame repaints only what changed
	h.still = proc(h: ^host.Host, events: []platform.Event) -> bool {
		d := (^Detached)(h.user)
		d.had_input = len(events) > 0
		if !detached_still(d.app, d, d.had_input) { return false }
		detached_asks(d.app, &d.state, false)   // (what it waits for still wakes the program)
		return true
	}
	h.input = proc(h: ^host.Host, events: []platform.Event) -> []platform.Event {
		d := (^Detached)(h.user)
		app := d.app
		s := &app.cx.terms
		app.cx.built = &d.state
		d.built, d.keyboard = true, s.focused
		t := term_of_panel(app, d.panel)
		if t == nil { return events }
		s.only, s.focused = t, t
		return term_events(app, events)
	}
	h.params = proc(h: ^host.Host, p: ^ui.Build_Params) {
		d := (^Detached)(h.user)
		detached_style(d.app, &d.state)
		p^ = build_params(d.app, h.win, p.window_size, p.events, DETACHED_DT_S)
	}
	h.after_build = proc(h: ^host.Host) {
		d := (^Detached)(h.user)
		s := &d.app.cx.terms
		platform.set_title(h.win, panel_title(d.app, d.panel))
		s.only, s.focused = nil, d.keyboard
		d.app.cx.built = nil
	}
	h.after_frame = proc(h: ^host.Host) {
		d := (^Detached)(h.user)
		if !d.built { return }
		d.built = false
		if d.panel == u32(Panel.Preview) { preview_place(d.app, false) }
		detached_asks(d.app, &d.state, d.had_input)
	}
	h.rest_frame = proc(h: ^host.Host) { frame((^Detached)(h.user).app, inner = true) }
}

// After the main window's frame. A window closed gives its panel its tab back; a panel closed takes its window.
detached_frames :: proc(app: ^App) {
	for i := len(app.cx.detached) - 1; i >= 0; i -= 1 {
		if i >= len(app.cx.detached) { continue }   // (a frame of the system's loop, inside this one, closed one)
		d := app.cx.detached[i]
		gone := d.panel == u32(Panel.Stats) && !app.stats_open || d.closing
		if platform.is_closed(d.win) || gone {
			detached_end(app, i)
			dock_setup(app)
			app.settle = max(app.settle, FRAMES_AFTER_INPUT)
		} else {
			host.host_frame(&d.window)
		}
	}
}

// The panel in front of a stack, if it can have a window.
panel_in_front :: proc(app: ^App, leaf: i32) -> u32 {
	for p in ui.dock_tabs(&app.dock, leaf) {
		if panel_can_detach(p) && ui.dock_shown(&app.dock, p) { return p }
	}
	return 0
}

// The palette's: the panel with the keyboard, else the first that shows.
@(private = "file")
panel_for_window :: proc(app: ^App) -> u32 {
	s := &app.cx.terms
	if s.focused != nil && !s.focused.detached { return s.focused.panel }
	for t in s.list {
		if !t.detached && ui.dock_shown(&app.dock, t.panel) { return t.panel }
	}
	if app.preview.open && ui.dock_shown(&app.dock, u32(Panel.Preview)) { return u32(Panel.Preview) }
	if app.stats_open && ui.dock_shown(&app.dock, u32(Panel.Stats)) { return u32(Panel.Stats) }
	return 0
}

panel_window_can :: proc(app: ^App) -> bool { return panel_for_window(app) != 0 }

panel_window_open :: proc(app: ^App) {
	if p := panel_for_window(app); p != 0 { panel_detach(app, p) }
}
