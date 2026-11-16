package ocn

import "core:time"
import "gt:ui"

// --slow-motion=<n>: the interface's time goes n times slower, what ocntools film asks for. A frame of the window takes it
// longer to read than a frame lasts; slowed down, every movement is filmed whole, and the frames carry this clock's time, so
// a clip plays back at the true speed. Nothing else changes: the server's time goes on.

// The slowed clock of --slow-motion.
Film :: struct {
	slow:     f64,         // how many times slower (film.odin): 0, the interface's time is the system's
	clock:    f64,         // what ui.now_ms says then
	clock_at: f64,
	begun:    time.Tick,
	before:   ^f64,        // the clock it took the place of, given back when it stops (a test's: nil, the system's)
}

film_slow_start :: proc(app: ^App, n: f64) {
	if n <= 1 { return }
	app.film.slow = n
	app.film.clock = ui.now_ms()
	app.film.clock_at = app.film.clock
	app.film.begun = time.tick_now()
	app.film.before = app.state.clock
	ui.set_clock(&app.state, &app.film.clock)
}

// The interface's time is what it was before: the system's, or a test's clock, which goes on from where it was.
film_slow_stop :: proc(app: ^App) {
	if app.film.slow <= 1 { return }
	app.film.slow = 0
	ui.set_clock(&app.state, app.film.before)
	app.film.before = nil
}

film_slow_tick :: proc(app: ^App) {
	if app.film.slow <= 1 { return }
	app.film.clock = app.film.clock_at + time.duration_milliseconds(time.tick_since(app.film.begun)) / app.film.slow
}
