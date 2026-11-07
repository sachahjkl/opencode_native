package occ

import "core:time"
import "gt:ui"

// --slow-motion=<n>: the interface's time goes n times slower, what occtools film asks for. A frame of the window takes it
// longer to read than a frame lasts; slowed down, every movement is filmed whole, and the frames carry this clock's time, so
// a clip plays back at the true speed. Nothing else changes: the server's time goes on.

film_slow_start :: proc(app: ^App, n: f64) {
	if n <= 1 { return }
	app.cx.film_slow = n
	app.cx.film_clock = ui.now_ms()
	app.cx.film_clock_at = app.cx.film_clock
	app.cx.film_begun = time.tick_now()
	ui.set_clock(&app.state, &app.cx.film_clock)
}

film_slow_tick :: proc(app: ^App) {
	if app.cx.film_slow <= 1 { return }
	app.cx.film_clock = app.cx.film_clock_at + time.duration_milliseconds(time.tick_since(app.cx.film_begun)) / app.cx.film_slow
}

film_slow_dt :: proc(app: ^App, dt: f32) -> f32 { return app.cx.film_slow > 1 ? dt / f32(app.cx.film_slow) : dt }
