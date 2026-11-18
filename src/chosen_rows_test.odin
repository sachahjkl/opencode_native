package ocn

import "base:runtime"
import "core:testing"
import "gt:draw"
import "gt:ui"
import session "gt:testkit/session"
import "gt:testkit/unwatched"

// The main window as it is drawn: a picture to compare across a toolkit's version (build/<out>/<test>/main.png).
@(test)
the_main_window_shot :: proc(t: ^testing.T) {
	unwatched.run(t, proc(t: ^testing.T) {
		context.allocator = runtime.heap_allocator()
		_, s := bench_app(t)
		session.wait_idle(s)
		session.save_png(s, "main.png")
	})
}

// The session shown in the sidebar is a selected row as the toolkit's are (.Chosen, under "nav selected"): a theme's
// selection reaches it. OpenCode gives none: no ink, ocn's own ground. Old Head gives white on navy: its ground is the navy,
// its title the white.
@(test)
the_session_shown_is_a_chosen_row :: proc(t: ^testing.T) {
	unwatched.run(t, proc(t: ^testing.T) {
		context.allocator = runtime.heap_allocator()
		app, s := bench_app(t)
		vs := &app.program_views
		if !ui.view_is_open(vs, SIDEBAR_VIEW) { ui.view_open(vs, SIDEBAR_VIEW, app) }
		session.wait_idle(s)
		item_of :: proc(s: ^session.Session, id: string) -> ^ui.Box { return session.get(s, "item", within = session.get(s, id)) }
		shown, other := item_of(s, "r_ses_bench"), item_of(s, "r_ses_1")
		testing.expect(t, .Chosen in shown.flags, "the session shown: .Chosen")
		testing.expect(t, .Chosen not_in other.flags, "another session: not .Chosen")
		testing.expectf(t, shown.ink.a == 0, "OpenCode gives no ink: %v", shown.ink)
		testing.expect(t, session_ground() == chosen_ground(), "OpenCode gives no fill: ocn's own ground")

		pref_set(app, "appearance.theme", "Old Head")
		defer pref_set(app, "appearance.theme", "OpenCode")
		session.wait_idle(s)
		shown = item_of(s, "r_ses_bench")
		white, navy := draw.hex(0xffffffff), draw.hex(0x000080ff)
		testing.expectf(t, shown.ink == white, "Old Head's ink on the session shown: %v", shown.ink)
		testing.expectf(t, session_ground() == navy, "Old Head's fill under it: %v", session_ground())
		title := session.get(s, "t", within = shown)
		testing.expectf(t, title.target_text == white, "its title in the ink: %v", title.target_text)
		testing.expectf(t, item_of(s, "r_ses_1").ink.a == 0, "another session: no ink")
		session.save_png(s, "old-head.png")
	})
}
