package occ

import "core:math"
import "gt:draw"
import "gt:platform"
import "gt:render"
import "gt:ui"

// A shell in a window of its own, for a large screen or a second one. The same program, the same renderer, the same connection:
// the window has a ui.State and a surface of its own, and is built after the main one, in its frame. The shell goes on as ever;
// closing the window gives it its tab back.

Detached :: struct {
	term:    ^Term,
	win:     ^platform.Window,
	state:   ui.State,
	surface: render.Surface,
}

terminal_detach :: proc(app: ^App, t: ^Term) {
	if t.detached { return }
	d := new(Detached)
	d.term = t
	d.win = platform.open_window(term_label(t), {DETACHED_W, DETACHED_H})
	surface, ok := render.surface_create(&app.r, platform.native_surface_handles(d.win), d.win.size)
	if !ok {
		platform.destroy_window(d.win)
		free(d)
		ui.toast(.Bad, "No window: the renderer refused it")
		return
	}
	d.surface = surface
	ui.init(&d.state, &app.fonts, &app.theme)
	ui.set_zoom(&d.state, app.prefs.zoom)
	ui.use(&app.ui_state)
	t.detached = true
	ui.dock_close(&app.dock, t.panel)
	append(&app.cx.detached, d)
	platform.show_window(d.win)
	app.frames = max(app.frames, FRAMES_AFTER_INPUT)
}

// The shell in front: the one with the keyboard, else the last that had it, else any with a tab.
@(private = "file")
term_in_front :: proc(app: ^App) -> ^Term {
	s := &app.cx.terms
	if s.focused != nil && !s.focused.detached { return s.focused }
	if t := term_of_panel(app, s.last_panel); t != nil && !t.detached { return t }
	for t in s.list {
		if !t.detached { return t }
	}
	return nil
}

terminal_can_detach :: proc(app: ^App) -> bool { return term_in_front(app) != nil }

terminal_detach_current :: proc(app: ^App) {
	if t := term_in_front(app); t != nil { terminal_detach(app, t) }
}

@(private = "file")
detached_end :: proc(app: ^App, i: int) {
	d := app.cx.detached[i]
	ordered_remove(&app.cx.detached, i)
	d.term.detached = false
	render.surface_destroy(&app.r, &d.surface)
	ui.destroy(&d.state)
	ui.use(&app.ui_state)
	platform.destroy_window(d.win)
	free(d)
}

// A shell that is going: its window with it.
detached_forget :: proc(app: ^App, t: ^Term) {
	for d, i in app.cx.detached {
		if d.term == t { detached_end(app, i); return }
	}
}

// The program closes.
detached_stop :: proc(app: ^App) {
	for len(app.cx.detached) > 0 { detached_end(app, len(app.cx.detached) - 1) }
}

@(private = "file")
detached_frame :: proc(app: ^App, d: ^Detached) {
	s := &app.cx.terms
	t := d.term
	ui.use(&d.state)
	render.surface_use(&app.r, &d.surface)
	render.resize(&app.r, d.win.size)
	keyboard := s.focused
	s.only, s.focused = t, t   // (what comes to this window is for its shell)
	events := term_events(app, platform.poll_events(d.win, false))
	size := draw.Vec2{f32(d.win.size.x), f32(d.win.size.y)}
	ui.begin_build(&d.state, {
		window_size = size, events = events, dt = DETACHED_DT_S, animations = animations_on(app),
		dpi_scale = app.scale > 0 ? app.scale : d.win.dpi_scale, window = d.win,
		base = ui.Style{pref = {.X = ui.text_size(), .Y = ui.px(30)}, font = app.font, font_size = app.prefs.font_size, text_pad = 6, cursor = .Arrow, radius = 6},
		clipboard_get = clip_get, clipboard_set = clip_set,
	})
	terminal_panel(app, math.round(ui.font_size()), t)
	ui.set_focus(t.box)
	ui.end_build()
	platform.set_cursor(d.win, ui.cursor(&d.state))
	draw.begin_frame(&app.dc, size)
	render.frame_begin(&app.r, hex(HEX_BG0))
	ui.draw_tree(&d.state, &app.dc)
	draw.end_frame(&app.dc)
	render.frame_end(&app.r, false)
	if ui.needs_frame(&d.state) { app.frames = max(app.frames, 1) }
	s.only, s.focused = nil, keyboard
	render.surface_use(&app.r, &d.surface)   // (the exchange undone: the main window's again)
	ui.use(&app.ui_state)
}

// After the main window's frame. A window closed gives its shell its tab back.
detached_frames :: proc(app: ^App) {
	for i := len(app.cx.detached) - 1; i >= 0; i -= 1 {
		d := app.cx.detached[i]
		if platform.is_closed(d.win) {
			detached_end(app, i)
			terminals_dock(app)
			app.frames = max(app.frames, FRAMES_AFTER_INPUT)
		} else {
			detached_frame(app, d)
		}
	}
}
