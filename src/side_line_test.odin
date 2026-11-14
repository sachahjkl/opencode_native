package ocn

import "base:runtime"
import "core:testing"
import "gt:ui"
import session "gt:testkit/session"
import "gt:testkit/unwatched"

// The line of the title bar and of the status bar goes on from the left dock zone's handle: on its pixel column while
// the handle is held and after it is let go, at every scale; with nothing docked at the left, the bars keep their own.
@(test)
the_bar_lines_follow_the_dock_splitter :: proc(t: ^testing.T) {
	unwatched.run(t, proc(t: ^testing.T) {
		context.allocator = runtime.heap_allocator()
		app, s := bench_app(t)
		vs := &app.program_views
		if !ui.view_is_open(vs, SIDEBAR_VIEW) { ui.view_open(vs, SIDEBAR_VIEW, app) }
		session.wait_idle(s)

		on_the_line :: proc(t: ^testing.T, s: ^session.Session, app: ^App, when_: string, scale: f32) {
			line, docked := ui.view_dock_line(&app.program_views, .Left)
			if !testing.expectf(t, docked, "%s at %v: the sidebar's handle", when_, scale) { return }
			for name in ([]string{"tg", "sg_status"}) {
				b := session.find(s, name)
				if !testing.expectf(t, b != nil, "%s at %v: the line %s", when_, scale, name) { continue }
				testing.expectf(t, abs(b.rect.min.x - line.min.x) < 0.01, "%s at %v: %s at x %v, the handle's rule at %v", when_, scale, name, b.rect.min.x, line.min.x)
			}
		}

		for scale in ([]f32{1, 1.25, 1.5, 2}) {
			session.set_dpi(s, scale)
			session.wait_idle(s)
			on_the_line(t, s, app, "at rest", scale)
			before, _ := ui.view_dock_line(vs, .Left)
			h := session.find(s, "view_handle_Left")
			if !testing.expectf(t, h != nil, "at %v: the handle", scale) { return }
			from := session.center(h)
			to := from + {7, 0}
			// (held: the layout settles while the button is down)
			session.press(s, from)
			session.move(s, from + {3, 0})
			session.move(s, to)
			session.wait_idle(s)
			on_the_line(t, s, app, "held", scale)
			session.release(s, to)
			session.wait_idle(s)
			on_the_line(t, s, app, "let go", scale)
			after, _ := ui.view_dock_line(vs, .Left)
			testing.expectf(t, after.min.x > before.min.x, "at %v: the handle moved (%v, was %v)", scale, after.min.x, before.min.x)
		}

		ui.view_close(vs, SIDEBAR_VIEW)
		session.wait_idle(s)
		_, docked := ui.view_dock_line(vs, .Left)
		testing.expect(t, !docked, "the sidebar hidden: no handle")
		testing.expect(t, session.find(s, "tg") != nil && session.find(s, "sg_status") != nil, "the bars keep their line")
	})
}
