package ocn

// The builds go by the interface's clock, the one the host reads: a test's, the film's slowed one. A build that took its dt
// from the system's clock moved a test's animations by the time its frames took (a middle click's scroll went up 2 px in
// 40 frames of the bench, 1 to 3 ms each, where the test's clock said 667 ms); a film that gave the system's clock back when
// it stopped sent a test's clock back in time, and its glides never ended.

import "base:runtime"
import "core:testing"
import session "gt:testkit/session"
import "gt:testkit/unwatched"

@(test)
the_builds_go_by_the_interfaces_clock :: proc(t: ^testing.T) {
	unwatched.run(t, proc(t: ^testing.T) {
		context.allocator = runtime.heap_allocator()
		app, s := bench_app(t)
		session.frames(s, 3)
		testing.expectf(t, abs(app.state.dt - f32(session.FRAME_MS / 1000)) < 1e-6, "a build's dt, the test's frame: %v s", app.state.dt)
		// the film's slowed clock, then the test's again: where it was, not the system's
		clock := app.state.clock
		testing.expect(t, clock != nil, "the test's clock")
		film_slow_start(app, BENCH_SLOW_MOTION)
		session.frames(s, 1)
		testing.expectf(t, app.state.dt < f32(session.FRAME_MS / 1000), "slowed: a build's dt %v s", app.state.dt)
		film_slow_stop(app)
		testing.expect(t, app.state.clock == clock, "the film stopped: the test's clock again")
		session.frames(s, 2)   // (the first one's dt is from the film's last time, a little past the test's)
		testing.expectf(t, abs(app.state.dt - f32(session.FRAME_MS / 1000)) < 1e-6, "a build's dt after the film: %v s", app.state.dt)
	})
}
