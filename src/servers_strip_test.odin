package ocn

import "base:runtime"
import "core:fmt"
import "core:testing"
import session "gt:testkit/session"
import "gt:ui"
import "gt:testkit/unwatched"

// More servers than the sidebar's width: their tabs are the toolkit's strip, an arrow on the side that hides tabs (no
// scroll bar); a click on it brings the next tabs into view, and the other arrow comes.
@(test)
the_server_tabs_scroll_with_arrows :: proc(t: ^testing.T) {
	unwatched.run(t, proc(t: ^testing.T) {
		context.allocator = runtime.heap_allocator()
		app, s := bench_app(t)
		for i in 0 ..< 14 {
			append(&app.servers, Server{name = fmt.aprintf("Server %d of the bench", i), url = fmt.aprintf("http://10.0.0.%d:4096", i)})
		}
		session.wait_until(s, proc(s: ^session.Session) -> bool {
			return session.find(s, "strip_right", within = session.find(s, "srv_tabs")) != nil
		}, "the strip's arrow at the end")
		tabs := session.find(s, "srv_tabs")
		testing.expect(t, session.find(s, "strip_left", within = tabs) == nil, "none at the start: nothing hidden there")
		right := session.find(s, "strip_right", within = tabs)
		if !testing.expect(t, right != nil, "the arrow") { return }
		session.click_at(s, session.center(right))
		session.wait_idle(s)
		tabs = session.find(s, "srv_tabs")
		view := session.find(s, "strip_view", within = tabs)
		if !testing.expect(t, view != nil, "the strip's view") { return }
		testing.expectf(t, view.view_off.x > 0, "scrolled toward the end: %v", view.view_off.x)
		session.save_png(s, "server_strip_scrolled.png")
		left := session.find(s, "strip_left", within = tabs)
		testing.expectf(t, left != nil, "the arrow at the start now (offset %v, limit %v, view %v)", view.view_off.x, ui.view_limit(view, .X), view.rect)
	})
}
