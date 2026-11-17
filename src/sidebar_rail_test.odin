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
// runs), each lit as its row. A hover shows its card at once (title, project · folder, state, what waits) and the next
// mark's as the pointer goes down, a click opens the session,
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

		// the list's Minimise is the first box of the servers' row, before the server's tab, at rest (no hover); no row
		// of its own above it: the sidebar starts at its zone's top
		em := ui.font_size()
		tabs := session.get(s, "srv_tabs")
		fold := session.find(s, "view_fold", within = tabs)
		if !testing.expect(t, fold != nil, "the fold button in the servers' row") { return }
		first: ^ui.Box
		for c := tabs.first; c != nil; c = c.next { if c.name != "fold_lead" && c.name != "" { first = c; break } }
		testing.expectf(t, first == fold, "the fold button first in the servers' row: %q", first != nil ? first.name : "")
		testing.expectf(t, fold.rect.max.x <= session.get(s, "srv_tab0").rect.min.x, "left of the server's tab: %v", fold.rect)
		zone := session.get(s, "view_zone_Left")
		side := session.get(s, "sidebar")
		testing.expectf(t, abs(side.rect.min.y - zone.rect.min.y) <= 0.5, "no row above the sidebar: %v in %v", side.rect, zone.rect)
		testing.expect(t, session.find(s, "view_rail_min") == nil, "no toolkit head row")
		if line, docked := ui.view_dock_line(vs, .Left); testing.expect(t, docked, "the sidebar's edge line") {
			tg := session.get(s, "tg").rect
			testing.expectf(t, abs(tg.min.x - line.min.x) <= 0.5, "the title bar's line on the sidebar's: %v, %v", tg, line)
		}
		minimise := fold.rect
		session.save_png(s, "fold-B-expanded.png")
		session.click(s, "view_fold")
		session.wait_box(s, "sidebar_rail")
		session.wait_idle(s)   // (the lazy column learns the marks' heights)
		testing.expect(t, session.find(s, "sidebar") == nil, "minimised: no list")
		zone = session.get(s, "view_zone_Left")
		// the rail's Restore is the same button at the same pixel: it stays under the pointer
		restore := session.get(s, "view_fold", within = session.get(s, "sidebar_rail")).rect
		testing.expectf(t, abs(restore.min.x - minimise.min.x) <= 1 && abs(restore.min.y - minimise.min.y) <= 1 &&
			abs(restore.max.x - minimise.max.x) <= 1 && abs(restore.max.y - minimise.max.y) <= 1, "Restore where Minimise was: %v, %v", restore, minimise)
		mid := (zone.rect.min.x + zone.rect.max.x) * 0.5
		testing.expectf(t, abs((restore.min.x + restore.max.x) * 0.5 - mid) <= 1, "Restore on the rail's centre: %v, the rail %v", restore, zone.rect)
		testing.expectf(t, abs((zone.rect.max.x - zone.rect.min.x) - SIDEBAR_RAIL_EM * em) <= 1.5, "the rail's width: %v", zone.rect)
		testing.expect(t, session.find(s, "rail_new") != nil && session.find(s, "rail_search") != nil && session.find(s, "rail_server") != nil, "New session, Search, the server")
		testing.expect(t, session.find(s, "view_rail_restore") == nil, "no Restore of the toolkit's: the view's own")
		session.save_png(s, "fold-B-rail.png")

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

		// a hover: the card at once, not after Feel.tooltip_delay_ms (a move is INPUT_FRAMES frames: 33 ms of the clock)
		in_card :: proc(s: ^session.Session, text: string) -> bool {
			tip := session.find(s, "tooltip")
			return tip != nil && tip.transparency < 1 && ui.box_find(s.state, "", text, 0, tip) != nil
		}
		session.move(s, session.center(marks[0]))
		testing.expect(t, in_card(s, bench_title(6)), "the card at once: its title")
		testing.expect(t, in_card(s, "project_6 · C:/code"), "its project and the folder that holds it, on one line")
		testing.expect(t, in_card(s, "Waits for you · "), "its state in words, then its last activity")
		testing.expect(t, in_card(s, "Edit src/main.odin"), "what waits")
		testing.expect(t, !in_card(s, "Last active"), "the time says itself: no label")
		tip := session.find(s, "tooltip")
		testing.expectf(t, tip != nil && tip.rect.min.x >= zone.rect.max.x, "the card past the rail's edge: %v, the rail %v", tip.rect if tip != nil else ui.Rect{}, zone.rect)
		testing.expectf(t, tip != nil && tip.rect.max.x - tip.rect.min.x <= RAIL_CARD_EM * em + 1, "the card at most RAIL_CARD_EM wide: %v", tip.rect if tip != nil else ui.Rect{})
		session.save_png(s, "rail-card.png")
		// the pointer down the rail: the next mark's card at once
		session.move(s, session.center(marks[1]))
		testing.expect(t, in_card(s, bench_title(3)) && !in_card(s, bench_title(6)), "the next mark: its card at once")
		testing.expect(t, in_card(s, "Running · "), "it runs")
		session.save_png(s, "rail-card-running.png")

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
		session.click(s, "view_fold")
		session.wait_box(s, "sidebar")
		testing.expect(t, session.find(s, "sidebar_rail") == nil, "restored: no rail")

		// the rail's edge pulled outward: the list, at the pointer; the title bar's line on the rail's edge line
		session.click(s, "view_fold")
		session.wait_box(s, "sidebar_rail")
		line, docked := ui.view_dock_line(vs, .Left)
		handle := session.get(s, "view_handle_Left")
		rail_zone := session.get(s, "view_zone_Left").rect
		testing.expectf(t, docked && line.min.x >= handle.rect.min.x && line.max.x <= handle.rect.max.x && abs(handle.rect.min.x - rail_zone.max.x) <= 1,
			"the rail's edge line, its handle against the rail: %v, %v, %v", line, handle.rect, rail_zone)
		// (the title bar's words wider than the rail push its line on, never before the rail's)
		title_line := session.get(s, "tg").rect
		testing.expectf(t, title_line.min.x >= line.min.x - 0.5, "the title bar's line not before the rail's: %v, %v", title_line, line)
		to := session.center(handle) + {SIDEBAR_EM * em * 0.8, 0}
		session.drag(s, session.center(handle), to)
		session.wait_box(s, "sidebar")
		testing.expect(t, session.find(s, "sidebar_rail") == nil, "pulled: the list")
		line, docked = ui.view_dock_line(vs, .Left)
		testing.expectf(t, docked && abs((line.min.x + line.max.x) * 0.5 - to.x) <= 2, "the list's edge at the pointer: %v, %v", line, to)
		session.save_png(s, "fold-B-pulled.png")

		// a window too narrow for the sidebar and the conversation folds it to the rail; wide again, the list
		session.resize(s, {int((SIDEBAR_EM + ui.DOCK_MIN_EM * 0.5) * em), BENCH_SIZE.y})
		session.wait_box(s, "sidebar_rail")
		testing.expect(t, rail_mark_of(s, bench_title(6)) != nil, "folded: the marks")
		session.resize(s, BENCH_SIZE)
		session.wait_box(s, "sidebar")
	})
}
