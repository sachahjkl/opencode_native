package occ

import "core:math"
import "core:slice"
import "gt:draw"
import "gt:platform"
import "gt:render"
import "gt:ui"

// A panel in a window of its own, for a large screen or a second one. The same program, the same renderer, the same connection:
// the window has a ui.State and a surface of its own, and is built after the main one, in its frame. The panel goes on as ever;
// closing the window gives it its tab back.
//
// Being resized it is as stable as the main window, by the same two means. Its surface is a composition swap chain whose buffers keep
// the monitor's size, shown 1:1 and clipped by the window: nothing is ever stretched. (Below its child windows: the page moved into it
// would be behind it.) And it draws from inside the system's loop, which
// holds the thread for as long as the border is held: without on_frame no frame comes until the release.

Detached :: struct {
	app:     ^App,
	panel:   u32,
	win:     ^platform.Window,
	closing: bool,   // its panel was closed: a Preview's window outlives a session with no browser, not this
	state:   ui.State,
	surface: render.Surface,
	shown:   [2]int,   // the size of the last frame
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
	m := &app.ui_state
	ui.set_zoom(s, m.zoom)
	ui.set_density(s, m.density)
	ui.set_rounding(s, m.rounding)
	ui.set_scrollbar_autohide(s, app.prefs.autohide_scrollbars)
	ui.set_toast_position(s, m.toast_pos)
	s.icon_font, s.mono_font = m.icon_font, m.mono_font
	for regular, set in m.rich_faces { ui.rich_set_faces(s, regular, set[1], set[2], set[3]) }
}

// What a window's build leaves to the program's loop, which only looks at the main state: input settles as it does there, and what the window
// waits for (a tooltip, a bar to hide, a caret) wakes it.
detached_asks :: proc(app: ^App, s: ^ui.State, had_input: bool) {
	if had_input { app.frames = max(app.frames, FRAMES_AFTER_INPUT) }
	if ui.needs_frame(s) { app.frames = max(app.frames, 1) }
	if wait := ui.wake_in_ms(s); wait > 0 { ui.wake_within(&app.ui_state, wait) }
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
	d.panel = panel
	d.app = app
	d.win = platform.open_window(panel_title(app, panel), {DETACHED_W, DETACHED_H}, transparent = true)
	if !render.surface_init(&app.r, &d.surface, platform.native_surface_handles(d.win), d.win.size, transparent = true, fixed_size = platform.monitor_size(d.win), under_children = panel == u32(Panel.Preview)) {
		platform.destroy_window(d.win)
		free(d)
		ui.toast(.Bad, "No window: the renderer refused it")
		return
	}
	ui.init(&d.state, &app.fonts, &app.theme)
	ui.set_autoscroll_enabled(&d.state, true)
	ui.use(&app.ui_state)
	if t := term_of_panel(app, panel); t != nil { t.detached = true }
	ui.dock_close(&app.dock, panel)
	append(&app.cx.detached, d)
	if panel == u32(Panel.Preview) { preview_move(app, d.win) }
	d.win.user = d
	d.win.on_frame = detached_paint
	platform.show_window(d.win)
	app.frames = max(app.frames, FRAMES_AFTER_INPUT)
}

@(private = "file")
detached_end :: proc(app: ^App, i: int) {
	d := app.cx.detached[i]
	ordered_remove(&app.cx.detached, i)
	if t := term_of_panel(app, d.panel); t != nil { t.detached = false }
	if d.panel == u32(Panel.Preview) { preview_move(app, app.win) }
	render.surface_destroy(&app.r, &d.surface)
	ui.destroy(&d.state)
	ui.use(&app.ui_state)
	platform.destroy_window(d.win)
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
	switch {
	case d.panel == u32(Panel.Stats):
		app.cx.stats_w = size.x
		stats_panel(app, em)
	case d.panel == u32(Panel.Preview):
		preview_panel(app, em)
	case:
		if t := term_of_panel(app, d.panel); t != nil {
			terminal_panel(app, em, t)
			ui.set_focus(t.box)
		}
	}
}

// A frame asked for from inside the system's loop. A step of a resize is this window's alone, and at once: waiting for the main window's
// frame, or drawing it first, is what shows a window late on its border. The loop's timer, when the border rests, makes the program's
// whole frame: the main window, what a server said, a shell's output, go on.
@(private = "file")
detached_paint :: proc(user: rawptr) {
	d := (^Detached)(user)
	if ui.building() { return }
	if d.win.size != d.shown {
		detached_frame(d.app, d)
		free_all(context.temp_allocator)
	} else {
		frame(d.app, inner = true)
	}
}

@(private = "file")
detached_frame :: proc(app: ^App, d: ^Detached) {
	// First of all: the system's loop may begin in this call, a border held, and its frames want the renderer and the interface as a frame
	// leaves them. It may also end this window.
	events := platform.poll_events(d.win, false)
	if !slice.contains(app.cx.detached[:], d) { return }
	had_input := len(events) > 0
	s := &app.cx.terms
	ui.use(&d.state)
	render.surface_use(&app.r, &d.surface)
	render.resize(&app.r, d.win.size)
	keyboard := s.focused
	if t := term_of_panel(app, d.panel); t != nil {
		s.only, s.focused = t, t   // (what comes to this window is for its shell)
		events = term_events(app, events)
	}
	size := draw.Vec2{f32(d.win.size.x), f32(d.win.size.y)}
	detached_style(app, &d.state)
	ui.begin_build(&d.state, build_params(app, d.win, size, events, DETACHED_DT_S))
	detached_body(app, d, size, math.round(ui.font_size()))
	ui.end_build()
	platform.set_cursor(d.win, ui.cursor(&d.state))
	platform.set_title(d.win, panel_title(app, d.panel))
	draw.begin_frame(&app.dc, size)
	render.frame_begin(&app.r, hex(HEX_BG0))
	ui.draw_tree(&d.state, &app.dc)
	draw.end_frame(&app.dc)
	render.frame_end(&app.r, false)
	d.shown = d.win.size
	if d.panel == u32(Panel.Preview) { preview_place(app, false) }
	detached_asks(app, &d.state, had_input)
	s.only, s.focused = nil, keyboard
	render.surface_use(&app.r, &d.surface)   // (the exchange undone: the main window's again)
	ui.use(&app.ui_state)
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
			app.frames = max(app.frames, FRAMES_AFTER_INPUT)
		} else {
			detached_frame(app, d)
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
