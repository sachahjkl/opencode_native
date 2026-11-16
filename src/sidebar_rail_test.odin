package ocn

import "base:runtime"
import "core:fmt"
import "core:testing"
import "gt:ui"
import session "gt:testkit/session"
import "gt:testkit/unwatched"

// The marks of the rail built, top to bottom.
@(private = "file")
rail_marks_built :: proc(s: ^session.Session) -> [dynamic]^ui.Box {
	marks := make([dynamic]^ui.Box, context.temp_allocator)
	for i := 0; ; i += 1 {
		b := session.find(s, "rail_mark", i)
		if b == nil { break }
		append(&marks, b)
	}
	return marks
}

// The mark of a session, by its name (its title).
@(private = "file")
rail_mark_of :: proc(s: ^session.Session, title: string) -> ^ui.Box {
	for b in rail_marks_built(s) { if b.a11y != nil && b.a11y.name == title { return b } }
	return nil
}

@(private = "file")
bench_title :: proc(i: int) -> string { return fmt.tprintf("Session %d about the project's frame pacing", i) }

// The sidebar's zone minimised builds the sidebar as its rail (src/md/features/sidebar-rail.md): New session, Search, the
// server's mark, then a mark per session in the list's order (what waits first; no sub-agent, its parent's lamp says it
// runs), each lit as its row. A hover shows its card (title, project, folder, what waits), a click opens the session,
// Down moves the keyboard to the next mark and its card follows; Restore brings the list back. A window too narrow for
// the sidebar and the conversation folds it to the same rail.
@(test)
the_sidebar_minimised_is_a_rail_of_marks :: proc(t: ^testing.T) {
	unwatched.run(t, proc(t: ^testing.T) {
		context.allocator = runtime.heap_allocator()
		app, s := bench_app(t)
		vs := &app.program_views
		if !ui.view_is_open(vs, SIDEBAR_VIEW) { ui.view_open(vs, SIDEBAR_VIEW, app) }
		// one waits (a permission), one runs, one runs only through its sub-agent (ses_9's parent is ses_8)
		append(&app.permissions, Permission{id = "per_1", session = "ses_6", action = "edit", message = "Edit src/main.odin"})
		app.busy["ses_3"] = true
		app.busy["ses_9"] = true
		marks_changed(app)
		session.wait_idle(s)
		testing.expect(t, session.find(s, "sidebar") != nil && session.find(s, "sidebar_rail") == nil, "the list at first")

		zone := session.get(s, "view_zone_Left")
		session.move(s, {zone.rect.min.x + 30, zone.rect.min.y + 2})
		session.wait_box(s, "view_stack_min")
		session.click(s, "view_stack_min")
		session.wait_box(s, "sidebar_rail")
		session.wait_idle(s)   // (the lazy column learns the marks' heights)
		testing.expect(t, session.find(s, "sidebar") == nil, "minimised: no list")
		zone = session.get(s, "view_zone_Left")
		em := ui.font_size()
		testing.expectf(t, abs((zone.rect.max.x - zone.rect.min.x) - SIDEBAR_RAIL_EM * em) <= 1.5, "the rail's width: %v", zone.rect)
		testing.expect(t, session.find(s, "rail_new") != nil && session.find(s, "rail_search") != nil && session.find(s, "rail_server") != nil, "New session, Search, the server")
		testing.expect(t, session.find(s, "view_rail_restore") != nil, "the zone's Restore at its top")

		// the list's order, sub-agents left out
		want := make([dynamic]string, context.temp_allocator)
		for &sec in app.sidebar.kept.sections {
			if app.sidebar.folded[sec.key] or_else sec.shut { continue }
			for i in sec.items { if app.sessions[i].parent == "" { append(&want, app.sessions[i].title) } }
		}
		marks := rail_marks_built(s)
		testing.expectf(t, len(marks) > 5 && len(marks) < len(want), "the marks in view built, not all: %d of %d", len(marks), len(want))
		for b, i in marks {
			if i >= len(want) { break }
			testing.expectf(t, b.a11y != nil && b.a11y.name == want[i], "mark %d: %q, want %q", i, b.a11y != nil ? b.a11y.name : "", want[i])
		}
		testing.expect(t, len(marks) > 1 && marks[0].a11y.name == bench_title(6) && marks[1].a11y.name == bench_title(3), "what waits first, then what runs")
		testing.expect(t, rail_mark_of(s, bench_title(9)) == nil, "no mark for a sub-agent")
		lit :: proc(s: ^session.Session, title, lamp: string) -> bool {
			b := rail_mark_of(s, title)
			return b != nil && session.find(s, lamp, 0, b) != nil
		}
		testing.expect(t, lit(s, bench_title(6), "waits"), "the one that waits: its lamp")
		testing.expect(t, lit(s, bench_title(3), "busy"), "the one that runs: its lamp")
		testing.expect(t, lit(s, bench_title(8), "busy"), "the parent of a sub-agent that runs: lit")
		testing.expect(t, !lit(s, bench_title(1), "busy") && !lit(s, bench_title(1), "waits"), "one at rest: no lamp")
		session.save_png(s, "rail.png")

		// a hover: the card
		session.move(s, session.center(marks[0]))
		session.wait_text(s, bench_title(6))
		testing.expect(t, session.find_text(s, "project_6") != nil, "its project")
		testing.expect(t, session.find_text(s, "C:/code") != nil, "the folder that holds it")
		testing.expect(t, session.find_text(s, "Asks permission: Edit src/main.odin") != nil, "what waits")
		session.frames(s, 2)
		tip := session.find(s, "tooltip")
		testing.expectf(t, tip != nil && tip.rect.min.x >= zone.rect.max.x, "the card past the rail's edge: %v, the rail %v", tip.rect if tip != nil else ui.Rect{}, zone.rect)
		session.save_png(s, "rail-tooltip.png")

		// a click opens the session; Down moves the keyboard to the next mark, its card beside it
		other := rail_mark_of(s, bench_title(2))
		if !testing.expect(t, other != nil, "the mark of session 2") { return }
		session.click_at(s, session.center(other))
		session.frames(s, 2)
		testing.expect_value(t, main_pane(app).chat.id, "ses_2")
		session.move(s, {f32(BENCH_SIZE.x) * 0.6, f32(BENCH_SIZE.y) * 0.5})
		session.key(s, .Down)
		session.frames(s, 2)
		next := ""
		for b, i in rail_marks_built(s) { if b.a11y.name == bench_title(2) && i + 1 < len(want) { next = want[i + 1] } }
		testing.expectf(t, next != "" && session.find_text(s, next) != nil, "Down: the card of the next mark, %q", next)
		testing.expect_value(t, session.focused_name(s), "rail_mark")
		session.key(s, .Up)
		session.frames(s, 2)
		testing.expect(t, session.find_text(s, bench_title(2)) != nil, "Up: back, its card")

		// Restore: the list
		session.click(s, "view_rail_restore")
		session.wait_box(s, "sidebar")
		testing.expect(t, session.find(s, "sidebar_rail") == nil, "restored: no rail")

		// a window too narrow for the sidebar and the conversation folds it to the rail; wide again, the list
		session.resize(s, {int((SIDEBAR_EM + ui.DOCK_MIN_EM * 0.5) * em), BENCH_SIZE.y})
		session.wait_box(s, "sidebar_rail")
		testing.expect(t, rail_mark_of(s, bench_title(6)) != nil, "folded: the marks")
		session.resize(s, BENCH_SIZE)
		session.wait_box(s, "sidebar")
	})
}
