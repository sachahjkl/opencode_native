package ocn

// The program on its heavy cases, in the test's process: the App made as main makes it, on an offscreen window
// (testkit/session drives it: its input, its clock), with a long conversation and many sessions made up here, no server.
// The tests check what each case must do; with -define:OCN_BENCH=true they also run BENCH_FRAMES frames of each and print
// the medians of the frame's steps (docs/performance.md: how they are compared).
//
//   odin test src -collection:gt=ext/gui_toolkit/src -o:speed -define:OCN_BENCH=true -define:ODIN_TEST_THREADS=1

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:time"
import "gt:config"
import tasks "gt:tasks"
import "gt:draw"
import "gt:font"
import mermaid "gt:mermaid"
import paint "gt:paint"
import "gt:platform"
import "gt:png"
import "gt:render"
import "gt:term"
import "gt:ui"
import lucide "gt:lucide"
import notices "gt:notices"
import session "gt:testkit/session"
import "gt:testkit/unwatched"

OCN_BENCH :: #config(OCN_BENCH, false)

BENCH_SIZE        :: [2]int{1600, 1000}
BENCH_TURNS       :: #config(OCN_BENCH_TURNS, 150)     // a user's prompt and the agent's answer each (tool calls, reasoning, Markdown)
BENCH_SESSIONS    :: 400
BENCH_PROJECTS    :: 12
BENCH_TOOLS       :: 4       // tool calls per answer
BENCH_FRAMES      :: 300 when OCN_BENCH else 12   // frames per case
BENCH_WHEEL       :: 3       // notches per frame, up
BENCH_PARAGRAPH_DELTAS :: 8   // a paragraph's deltas: then the model starts another
BENCH_DELTA       :: "Each `delta` adds a few words to the answer, **as a model streams**. "
BENCH_TYPED       :: "the quick brown fox jumps over the lazy dog "
BENCH_FIND        :: "lazy column"
BENCH_SEARCH      :: "project"
BENCH_PALETTE_SLIPS :: "frmae pacnig"   // words typed with slips: few items have them, most go through the search for slips
BENCH_MODELS      :: 300
BENCH_CHAT_ID     :: "ses_bench"
LAST_SESSION      :: "ls_ses_395"      // the last session of the last group (project_11), not a sub-agent
SIDEBAR_WHEEL     :: 10
BENCH_EPOCH_MS    :: 1.7e12
BENCH_STEP_MS     :: 60000
BENCH_SLOW_MOTION :: 1000    // the interface's time slowed this many times, where a test reads a movement under way
OLDER_WHEEL_FROM_SCREENS :: 4   // where the wheel turned up past the top starts from, in screens under the top

// An answer as models write them: headings, paragraphs with inline marks, a list, code, a table.
BENCH_ANSWER :: `## What changed

The lazy column builds only the messages near the view: the others stand as a **space of the height they had**, and
` + "`ui.lazy_item`" + ` says which. A long conversation, *Markdown and all*, made every frame slow before it; see [the toolkit](https://example.com/gt).

- the sidebar groups sessions by project folder
- each group shows its logo and its count
  - nested items are indented
- the composer keeps its height between frames

1. read the page
2. measure the steps
3. keep what wins

` + "```odin" + `
frame :: proc(app: ^App) {
	events := platform.poll_events(app.win, false)
	build(app, size, events, dt)
	ui.draw_tree(&app.state, &app.dc)
	for m, i in app.chat.messages {
		if i % 2 == 0 { continue }
		fmt.println(m.id, len(m.parts))
	}
}
` + "```" + `

| Step | Before | After | What changed |
|:-----|-------:|:-----:|:-------------|
| build | 1.20 ms | 0.80 ms | the lazy column builds only what is seen, and the heights it learned keep the scrollbar where it was while the rest is measured |
| draw | 0.40 ms | 0.35 ms | fewer boxes |
| ` + "`render`" + ` | 0.90 ms | 0.90 ms | ` + "`render/surface.odin`" + ` unchanged |

> A quote, to close: what is measured is kept, the rest is written down.

That is all for this step; the next one follows.`

BENCH_OUTPUT :: "src/views.odin:1046: tool_part\nsrc/views.odin:1120: mono_well\nsrc/markdown.odin:191: markdown\n"

@(private = "file")
bench_page :: proc() -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, `{"data":[`)
	n := 0
	item :: proc(b: ^strings.Builder, n: ^int, s: string) {
		if n^ > 0 { strings.write_byte(b, ',') }
		strings.write_string(b, s)
		n^ += 1
	}
	// newest first, as the server answers
	for turn := BENCH_TURNS - 1; turn >= 0; turn -= 1 {
		t := BENCH_EPOCH_MS + f64(turn) * BENCH_STEP_MS
		item(&b, &n, fmt.tprintf(`{{"id":"msg_%d_i","type":"idle","outcome":"succeeded","time":{{"created":%f}}}}`, turn, t + 3))
		parts := strings.builder_make(context.temp_allocator)
		fmt.sbprintf(&parts, `{{"type":"reasoning","text":%s}}`, jquote(fmt.tprintf("Thinking about step %d: what the user asked, what the code does, what to measure first.", turn)))
		for k in 0 ..< BENCH_TOOLS {
			out := strings.repeat(BENCH_OUTPUT, 10, context.temp_allocator)
			fmt.sbprintf(&parts, `,{{"type":"tool","id":"call_%d_%d","name":"read","state":{{"status":"completed","input":{{"filePath":"src/file_%d.odin"}},"content":[{{"type":"text","text":%s}}]}},"time":{{"created":%f,"completed":%f}}}}`,
				turn, k, k, jquote(out), t + 1, t + 2)
		}
		fmt.sbprintf(&parts, `,{{"type":"text","text":%s}}`, jquote(BENCH_ANSWER))
		if turn == BENCH_TURNS - 1 {   // (a tool of no known kind, its input a long value and a short one)
			fmt.sbprintf(&parts, `,{{"type":"tool","id":"call_x","name":"execute","state":{{"status":"completed","input":{{"code":%s,"session":"main"}},"content":[{{"type":"text","text":"{{\"connected\":true}}"}}]}},"time":{{"created":%f,"completed":%f}}}}`, jquote("const s = await tools.browse.status();\nlet p; try { p = await tools.browse.files.read('x.json') }\ncatch (e) { p = 'ERR ' + String(e.message) }\nreturn { connected: s.status.connected, p };"), t + 1, t + 2)
		}
		item(&b, &n, fmt.tprintf(`{{"id":"msg_%d_a","type":"assistant","agent":"build","model":{{"id":"claude-model","providerID":"anthropic"}},"finish":"stop","cost":0.01,"tokens":{{"input":1200,"output":800,"reasoning":50,"cache":{{"read":9000}}}},"time":{{"created":%f,"completed":%f}},"content":[%s]}}`,
			turn, t + 1, t + 2, strings.to_string(parts)))
		item(&b, &n, fmt.tprintf(`{{"id":"msg_%d_u","type":"user","text":%s,"time":{{"created":%f}}}}`, turn, jquote(fmt.tprintf("Step %d: look at the lazy column and tell me what it costs.", turn)), t))
	}
	strings.write_string(&b, `],"cursor":{"next":""}}`)
	return strings.to_string(b)
}

@(private = "file")
bench_sessions :: proc() -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, `{"data":[`)
	for i in 0 ..< BENCH_SESSIONS {
		if i > 0 { strings.write_byte(&b, ',') }
		id := i == 0 ? BENCH_CHAT_ID : fmt.tprintf("ses_%d", i)
		parent := i % 5 == 4 ? fmt.tprintf("ses_%d", i - 1) : ""
		fmt.sbprintf(&b, `{{"id":"%s","title":"Session %d about the project's frame pacing","parentID":"%s","location":{{"directory":"C:/code/project_%d"}},"agent":"build","time":{{"created":%f,"updated":%f}}}}`,
			id, i, parent, i % BENCH_PROJECTS, BENCH_EPOCH_MS, BENCH_EPOCH_MS - f64(i) * BENCH_STEP_MS)
	}
	strings.write_string(&b, `]}`)
	return strings.to_string(b)
}

// The App of main, on an offscreen window, with the made-up sessions and conversation loaded. It allocates as the program
// does, on the heap (the test's allocator tracks each allocation: slower, and the App keeps what it made until it ends).
@(private = "file")
bench_app :: proc(t: ^testing.T) -> (app: ^App, s: ^session.Session) {
	context.allocator = runtime.heap_allocator()
	app = new(App)
	the_app = app
	append(&app.servers, Server{name = "This computer", local = true})
	app.sidebar.width = SIDEBAR_W_DEFAULT
	app.chat_scroll = Scroll_Following{}
	app.link = .Online
	chat_reset(&app.chat)
	app.win = platform.open_window_offscreen("opencode", BENCH_SIZE)
	testing.expect(t, app.win != nil)
	// (the bench on the GPU, as the program; the checks on WARP: no GPU needed)
	testing.expect(t, fonts_init(app))
	testing.expect(t, render.init_offscreen(&app.r, app.win.size, warp = !OCN_BENCH))
	app_init(app, "")
	main_window_adopt(app)
	app.last_tick = time.tick_now()
	app.opened_first = true
	app.chat.id = strings.clone(BENCH_CHAT_ID, app.chat.alloc)
	v, err := json.parse_string(bench_sessions(), allocator = context.temp_allocator)
	testing.expect(t, err == nil)
	sessions_load(app, v)
	v, err = json.parse_string(bench_page(), allocator = context.temp_allocator)
	testing.expect(t, err == nil)
	chat_load(app, v, false)
	chat_scroll_event(app, Scroll_Signal.Snap)
	testing.cleanup(t, bench_end, app)
	s = session.attach(t, {win = app.win, state = &app.state, renderer = &app.r, user = app, frame = proc(user: rawptr) { frame((^App)(user)) }, allocator = context.allocator})
	// (the lazy column learns the heights of what it builds: the bottom settles in a few frames)
	session.wait_until(s, proc(s: ^session.Session) -> bool { return session.find(s, fmt.tprintf("msg_msg_%d_a", BENCH_TURNS - 1)) != nil }, "the last answer built")
	return
}

// A command's output, in the real interface: its grid, its bar, Close when it ended as one watched, and Escape closes it. (In the session of
// the test that has one: the testkit drives one window at a time.)
@(private = "file")
output_view_built :: proc(t: ^testing.T, app: ^App, s: ^session.Session) {
	v := output_view_open_shell(app, "sh_1", "cargo build", "C:/code/project_0")
	output_view_feed(v, "\x1b[32mCompiling\x1b[0m ocn\n")
	v.over, v.seen_end, v.status, v.has_exit = true, true, .Exited, true
	session.frames(s, 3)
	testing.expect(t, session.find(s, "out_bar") != nil, "the bar")
	testing.expect(t, session.find(s, "out_close") != nil, "Close, ended as one watched")
	testing.expect(t, session.find(s, "term_box") != nil, "the grid")
	testing.expectf(t, strings.has_prefix(term_text(v.term), "$ cargo build"), "the command, at the head of the grid: %q", term_text(v.term))
	// a drag over the grid selects, and Ctrl+C copies it
	if g := session.find(s, "term_box"); g != nil {
		y := g.rect.min.y + v.term.view.metrics.cell_h * 1.5   // (its second row: the first is the command)
		from := [2]f32{g.rect.min.x + 12, y}
		to := [2]f32{g.rect.min.x + 160, y}
		session.move(s, from)
		session.event(s, {kind = .Mouse_Press, button = .Left, pos = from})
		session.frames(s, 1)
		session.event(s, {kind = .Mouse_Move, pos = to, buttons = {.Left}})
		session.frames(s, 1)
		session.event(s, {kind = .Mouse_Release, button = .Left, pos = to})
		session.frames(s, 2)
		testing.expectf(t, term.has_selection(&v.term.view), "a selection (press %v)", v.term.view.press)
		session.event(s, {kind = .Key_Press, key = .C, mods = {.Ctrl}})
		session.frames(s, 1)
		testing.expectf(t, strings.contains(session.clipboard(s), "Compiling"), "copied: %q", session.clipboard(s))
	}
	// a right click on the grid: its menu
	term.selection_drop(&v.term.view)
	session.click(s, "term_box", .Right)
	session.frames(s, 2)
	testing.expect(t, session.find_text(s, "Select all") != nil && session.find_text(s, "Copy all the output") != nil, "the grid's menu")
	session.click_text(s, "Select all")
	session.frames(s, 2)
	testing.expect(t, term.has_selection(&v.term.view), "Select all: the screen selected")
	session.click(s, "term_box", .Right)
	session.frames(s, 2)
	session.click_text(s, "Copy all the output")
	session.frames(s, 2)
	testing.expectf(t, strings.contains(session.clipboard(s), "Compiling") && !strings.contains(session.clipboard(s), "\x1b") && !strings.contains(session.clipboard(s), "cargo build"), "all the output, plain, without the command: %q", session.clipboard(s))
	// the wheel over the grid scrolls the grid, not the conversation behind the dialog
	if g := session.find(s, "term_box"); g != nil {
		for i in 0 ..< 200 { output_view_feed(v, fmt.tprintf("line %d\n", i)) }
		session.frames(s, 2)
		testing.expect(t, term.at_bottom(&v.term.view), "it follows its end")
		chat := session.get(s, "chat")
		behind := chat.view_target.y
		at := session.center(g)
		session.move(s, at)
		session.event(s, {kind = .Scroll, pos = at, delta = {0, -3}})
		session.frames(s, 2)
		testing.expect(t, !term.at_bottom(&v.term.view), "the grid scrolled up")
		testing.expect_value(t, session.get(s, "chat").view_target.y, behind)
	}
	session.event(s, {kind = .Key_Press, key = .Escape})
	session.frames(s, 3)
	testing.expect(t, session.find(s, "out_bar") == nil, "Escape closes it")
	testing.expect_value(t, len(app.cx.outputs.list), 0)
}

// What the system gives back (the window, the device, the fonts); the rest goes with the process.
@(private = "file")
bench_end :: proc(p: rawptr) {
	app := (^App)(p)
	context.allocator = runtime.heap_allocator()
	ui.destroy(&app.state)
	draw.destroy(&app.dc)
	render.destroy(&app.r)
	font.destroy(&app.fonts)
	platform.destroy_window(app.win)
	if the_app == app { the_app = nil }
}

@(private = "file")
Bench_Case :: struct { name: string, build, draw, render, total, gpu: [dynamic]f64, builds, boxes: int }

// One frame of a case, its steps' times kept.
@(private = "file")
bench_frame :: proc(s: ^session.Session, c: ^Bench_Case) {
	app := (^App)(s.user)
	start := time.tick_now()
	session.frame(s)
	total := time.duration_milliseconds(time.tick_since(start))
	append(&c.build, time.duration_milliseconds(app.frame_times.build))
	append(&c.draw, time.duration_milliseconds(app.frame_times.draw))
	append(&c.render, time.duration_milliseconds(app.frame_times.render))
	append(&c.total, total)
	append(&c.gpu, f64(render.gpu_ms(&app.r)))
	c.builds += app.frame_times.builds
	c.boxes = ui.boxes_built(&app.state)
}

// The `i`th character of `s` (ASCII), round again past its end.
@(private = "file")
char_at :: proc(s: string, i: int) -> rune { return rune(s[i % len(s)]) }

@(private = "file")
median :: proc(v: []f64) -> f64 {
	if len(v) == 0 { return 0 }
	s := slice.clone(v, context.temp_allocator)
	slice.sort(s)
	return s[len(s) / 2]
}

@(private = "file")
bench_report :: proc(c: ^Bench_Case) {
	when OCN_BENCH {
		fmt.printfln("bench %-10s frame %6.3f ms  build %6.3f  draw %6.3f  render %6.3f  gpu %6.3f  boxes %d  (builds/frame %.2f, %d frames)",
			c.name, median(c.total[:]), median(c.build[:]), median(c.draw[:]), median(c.render[:]), median(c.gpu[:]), c.boxes, f64(c.builds) / f64(len(c.total)), len(c.total))
		if p, ok := render.gpu_profile(&the_app.r); ok {
			for st, k in p.steps { if st.count > 0 { fmt.printfln("        gpu %-12v %6.3f ms  x%d  %.1f MB", k, st.ms, st.count, f64(st.bytes) / (1 << 20)) } }
		}
	}
	delete(c.build); delete(c.draw); delete(c.render); delete(c.total); delete(c.gpu)
}

// A conversation of BENCH_TURNS answers: the view at its bottom builds the few messages it shows, scrolled to its top it
// builds the first one, typing in the composer and an answer that streams in keep it so; find builds every message.
@(test)
a_long_conversation_builds_what_is_seen :: proc(t: ^testing.T) {
	unwatched.run(t, proc(t: ^testing.T) {
		context.allocator = runtime.heap_allocator()   // (what the App's procedures free here was made on the heap)
		app, s := bench_app(t)
		c := &app.chat
		testing.expect_value(t, len(c.messages), 3 * BENCH_TURNS)
		sb := session.get(s, "chat")
		limit := sb.view_bounds.y - sb.size.y
		testing.expect(t, limit > f32(BENCH_TURNS) * sb.size.y * 0.5, "the conversation is many pages long")
		testing.expect(t, sb.view_off.y >= limit - 1, "opened at its bottom")
		testing.expect(t, session.find(s, "msg_msg_0_a") == nil, "the first one is not")
		// a tool of no known kind, open: its input in one well, the long value under its key
		app.prefs.expand_tools = true
		session.frames(s, 6)
		testing.expect(t, session.find(s, "iv0") != nil && session.find(s, "kv1") != nil, "the input's long value and its short one")
		app.prefs.expand_tools = false
		chat_scroll_event(app, Scroll_Signal.Snap)
		session.frames(s, 6)
		// the composer's toolbar, a run going (Stop) and "Steer", as the column narrows: the send button stays within it
		{
			busy, steer, width := app.chat.busy, app.prefs.steer_first, app.prefs.column_w
			app.chat.busy, app.prefs.steer_first = true, true
			session.click(s, "composer")
			session.type_text(s, "go on")
			for w in ([]f32{900, 760, 640, 560, 500, 440}) {
				app.prefs.column_w = w
				session.frames(s, 4)
				tools, send := session.get(s, "tools"), session.get(s, "send")
				testing.expectf(t, send.rect.max.x <= tools.rect.max.x + 0.5, "at %v, the send button within the toolbar: %v past %v (%q)", w, send.rect.max.x, tools.rect.max.x, send.text)
			}
			app.chat.busy, app.prefs.steer_first, app.prefs.column_w = busy, steer, width
			ui.text_edit_set(&app.composer.area, "")
			session.frames(s, 4)
		}
		// a double click on the title edits it in place: Enter keeps it, Escape leaves it, a click elsewhere keeps it
		session.click(s, "title_b", count = 2)
		session.frames(s, 2)
		testing.expect(t, app.rename.at == .Header && session.find(s, "ren_f") != nil && !app.cx.open[.Rename], "the header's title, a field in place")
		session.key(s, .A, {.Ctrl})
		session.type_text(s, "Frame pacing")
		session.frames(s, 1)
		testing.expect_value(t, ui.line_edit_string(&app.rename.field), "Frame pacing")
		session.key(s, .Return)
		session.frames(s, 2)
		testing.expect(t, app.rename.at == .None && session.find(s, "ren_f") == nil, "Enter: the words back")
		if row := session.get(s, "r_" + BENCH_CHAT_ID); row.rect.min.y > 0 { session.click_at(s, session.center(row), count = 2) } else { testing.fail_now(t, "the open session's row, out of view") }
		session.frames(s, 2)
		testing.expect(t, app.rename.at == .Side && session.find(s, "ren_f") != nil, "a row of the sidebar, a field in place")
		session.key(s, .Escape)
		session.frames(s, 2)
		testing.expect(t, app.rename.at == .None && session.find(s, "ren_f") == nil, "Escape: as it was")
		session.click(s, "title_b", count = 2)
		session.frames(s, 2)
		session.click(s, "composer")
		session.frames(s, 2)
		testing.expect(t, app.rename.at == .None, "a click elsewhere: kept")
		bottom_boxes := ui.boxes_built(&app.state)

		when OCN_BENCH { render.set_gpu_profile(&app.r, true) }
		idle := Bench_Case{name = "idle"}
		profile_begin()
		for _ in 0 ..< BENCH_FRAMES { bench_frame(s, &idle) }
		profile_end("idle")
		bench_report(&idle)

		// streaming: the last answer grows by a delta a frame
		last := &c.messages[len(c.messages) - 2]
		testing.expect_value(t, last.kind, Msg_Kind.Assistant)
		text := &last.parts[len(last.parts) - 1].text
		grown := len(text)
		stream := Bench_Case{name = "stream"}
		profile_begin()
		for i in 0 ..< BENCH_FRAMES {
			if i % BENCH_PARAGRAPH_DELTAS == 0 { append(text, "\n\n") }
			append(text, BENCH_DELTA)
			bench_frame(s, &stream)
		}
		profile_end("stream")
		bench_report(&stream)
		testing.expect_value(t, len(text), grown + BENCH_FRAMES * len(BENCH_DELTA) + 2 * ((BENCH_FRAMES + BENCH_PARAGRAPH_DELTAS - 1) / BENCH_PARAGRAPH_DELTAS))

		// typing in the composer, a character a frame
		session.click(s, "composer")
		typing := Bench_Case{name = "type"}
		for i in 0 ..< BENCH_FRAMES {
			session.event(s, {kind = .Text, text = char_at(BENCH_TYPED, i)})
			bench_frame(s, &typing)
		}
		bench_report(&typing)
		testing.expect_value(t, len(ui.text_edit_string(&app.composer.area)), BENCH_FRAMES)

		// a click of the wheel at the bottom, the pointer then a little above it: the view goes up, slowly, and lets go of the bottom.
		// Its steps (a pixel a frame or less) were each put back at the bottom it was following, and the lazy column read the error
		// of its rounded rects as a move: it stayed there, or broke free in a jump.
		{
			testing.expect(t, chat_following(app), "at its bottom, following it")
			mid := session.center(session.get(s, "chat"))
			session.move(s, mid)
			session.click_at(s, mid, .Middle)
			testing.expect(t, ui.autoscroll_running(&app.state), "the wheel's click: scrolling by the pointer")
			session.move(s, mid - {0, ui.autoscroll_settings(&app.state).dead_zone + 6})   // (just past the dead zone: the slowest)
			// (how far from the bottom: the content's height moves a little while the column learns the heights of what it builds)
			up: [dynamic]f32
			defer delete(up)
			for _ in 0 ..< 40 {
				session.frames(s, 1)
				b := session.get(s, "chat")
				append(&up, ui.view_limit(b) - b.view_target.y)
			}
			testing.expectf(t, up[len(up) - 1] > 4, "gone up: %v from the bottom", up[len(up) - 1])
			testing.expect(t, !chat_following(app), "the bottom let go of")
			for i in 1 ..< len(up) {
				testing.expectf(t, up[i] >= up[i - 1] - 0.1, "never back down: %v then %v from the bottom (frame %d)", up[i - 1], up[i], i)
				testing.expectf(t, up[i] - up[i - 1] < 40, "no jump: %v then %v from the bottom (frame %d)", up[i - 1], up[i], i)
			}
			session.click_at(s, mid)   // (a click ends it)
			session.frames(s, 2)
			testing.expect(t, !ui.autoscroll_running(&app.state), "a click ends it")
		}

		// the wheel, up through the conversation (from its bottom as it is now: the heights it learned since have moved it)
		sb = session.get(s, "chat")
		limit = sb.view_bounds.y - sb.size.y
		mid := session.center(sb)
		session.move(s, mid)
		scroll := Bench_Case{name = "scroll"}
		profile_begin()
		for _ in 0 ..< BENCH_FRAMES {
			session.event(s, {kind = .Scroll, pos = mid, delta = {0, -BENCH_WHEEL}})
			bench_frame(s, &scroll)
		}
		profile_end("scroll")
		bench_report(&scroll)
		sb = session.get(s, "chat")
		testing.expectf(t, sb.view_target.y < limit - f32(BENCH_FRAMES * BENCH_WHEEL) * ui.WHEEL_LINE_PX, "scrolled up, a notch at least a line of the wheel: %v from %v", sb.view_target.y, limit)
		testing.expect(t, ui.boxes_built(&app.state) < 2 * bottom_boxes, "still only what is seen")

		// the palette, open, its list filtered by what is typed
		command_run(app, command_find("app.palette"))
		session.frames(s, 3)
		pal := Bench_Case{name = "palette"}
		profile_begin()
		for i in 0 ..< BENCH_FRAMES {
			session.event(s, {kind = .Text, text = char_at(BENCH_FIND, i % 3)})
			if i % 3 == 2 { ui.line_edit_set(&app.palette.field, "") }
			bench_frame(s, &pal)
		}
		profile_end("palette")
		bench_report(&pal)

		// the palette at rest, nothing typed nor changed: only the pointer moves a pixel. Its frames cost as much as typing
		// did: each one matched and ranked every item again (a query that finds few: most items went on to the slips' search),
		// and built every row it found, in view or not.
		for i in 0 ..< BENCH_MODELS {
			append(&app.models, Model_Info{id = fmt.aprintf("model-%d", i), provider = fmt.aprintf("provider-%d", i % 12), name = fmt.aprintf("Model %d of the bench", i)})
		}
		for query in ([]string{BENCH_PALETTE_SLIPS, "@"}) {
			ui.line_edit_set(&app.palette.field, query)
			session.frames(s, 3)
			rest := Bench_Case{name = query == "@" ? "pal_all" : "pal_slips"}
			profile_begin()
			for i in 0 ..< BENCH_FRAMES {
				session.move(s, {800 + f32(i % 2), 120})
				bench_frame(s, &rest)
			}
			profile_end(rest.name)
			bench_report(&rest)
		}
		app.cx.open[.Palette] = false
		session.frames(s, 2)

		// a command's output in its terminal grid, over the conversation: a line in colour comes at each frame, then it rests
		{
			v := output_view_open_shell(app, "sh_bench", "cargo build", "C:/code/project_0")
			session.frames(s, 3)
			for k in 0 ..< 2 {
				out := Bench_Case{name = k == 0 ? "term_out" : "term_rest"}
				profile_begin()
				for i in 0 ..< BENCH_FRAMES {
					if k == 0 { output_view_feed(v, fmt.tprintf("\x1b[32m   Compiling\x1b[0m crate_%d v0.%d.0 (\x1b[1m/code/project/crates/crate_%d\x1b[0m)\n", i, i % 10, i)) }
					bench_frame(s, &out)
				}
				profile_end(out.name)
				bench_report(&out)
			}
			testing.expect(t, session.find(s, "term_box") != nil, "the grid")
			output_view_close(app, v)
			session.frames(s, 3)
		}

		// the tray, opening and closing without end, over the conversation
		tray := Bench_Case{name = "tray"}
		profile_begin()
		for i in 0 ..< BENCH_FRAMES {
			if i % 24 == 0 { activity_toggle(app) }
			bench_frame(s, &tray)
		}
		profile_end("tray")
		bench_report(&tray)
		activity_close(app)
		session.frames(s, 30)

		// the pointer sweeping the rows of a menu
		key := "app_menu"
		ui.menu_open(key, ui.Vec2{40, 40})
		session.frames(s, 3)
		menu := Bench_Case{name = "menu"}
		profile_begin()
		for i in 0 ..< BENCH_FRAMES {
			session.move(s, {120, 60 + f32(i % 40) * 8})
			bench_frame(s, &menu)
		}
		profile_end("menu")
		bench_report(&menu)
		ui.menu_close()
		session.frames(s, 2)

		// find: every message built, the needle typed a character a frame
		find_open(app)
		session.frames(s, 2)
		finding := Bench_Case{name = "find"}
		for i in 0 ..< min(BENCH_FRAMES, len(BENCH_FIND)) {
			session.event(s, {kind = .Text, text = char_at(BENCH_FIND, i)})
			bench_frame(s, &finding)
		}
		for len(finding.total) < BENCH_FRAMES { bench_frame(s, &finding) }
		bench_report(&finding)
		when OCN_BENCH {
			sweep: f64   // (the one frame that builds everything)
			for v in finding.total { sweep = max(sweep, v) }
			fmt.printfln("find: its sweep %.1f ms", sweep)
		}
		testing.expect_value(t, ui.line_edit_string(&app.find.field), BENCH_FIND)
		session.wait_until(s, proc(s: ^session.Session) -> bool { return !ui.find_pending() }, "the needle swept")
		session.frames(s, 3)
		found := ui.find_count()
		testing.expect(t, found > 1, "the sweep read the whole conversation")
		// (searched from where the reader is, a few screens over the bottom, the wheel's: the first match under the view's top, in
		// view, not the conversation's first, a conversation away. Which one it is depends on where the wheel stopped, which the
		// lazy column's estimates of the messages above once moved under the reader)
		{
			chat := session.get(s, "chat")
			testing.expectf(t, app.find.index > found / 2, "a match near the view: %d of %d", app.find.index, found)
			shown := false
			for m in ui.find_matches() {
				if m.index == app.find.index { shown = m.rect.max.y > chat.rect.min.y && m.rect.min.y < chat.rect.max.y }   // (window coordinates)
			}
			testing.expectf(t, shown, "the current match %d in view", app.find.index)
		}
		testing.expect(t, session.find(s, "msg_msg_0_a") == nil, "after the sweep, only what is near the view is built")
		// the first match, far from anything built: the view goes there, and it is lit with its index of the sweep
		app.find.index = found - 1
		find_step(app, 1)
		testing.expect_value(t, app.find.index, 0)
		session.wait_until(s, proc(s: ^session.Session) -> bool {
			for m in ui.find_matches() { if m.index == 0 { return true } }
			return false
		}, "the first match built and lit")
		testing.expect_value(t, ui.find_count(), found)
		find_close(app)
		session.frames(s, 2)

		// the sidebar: the sessions it shows are built, the others when it scrolls to them
		testing.expect(t, session.find(s, "ls_ses_1") != nil)
		testing.expect(t, session.find(s, LAST_SESSION) == nil, "the sidebar builds the sessions it shows")
		side := session.center(session.get(s, "sessions"))
		session.move(s, side)
		session.wait_until(s, proc(s: ^session.Session) -> bool {
			session.event(s, {kind = .Scroll, pos = s.pointer, delta = {0, SIDEBAR_WHEEL}})
			return session.find(s, LAST_SESSION) != nil
		}, "the last session built")

		// the sidebar's search, typed a character a frame (every session matched against it)
		session.click(s, "search")
		search := Bench_Case{name = "search"}
		for i in 0 ..< BENCH_FRAMES {
			if i < len(BENCH_SEARCH) { session.event(s, {kind = .Text, text = char_at(BENCH_SEARCH, i)}) }
			bench_frame(s, &search)
		}
		bench_report(&search)
		testing.expect_value(t, ui.line_edit_string(&app.sidebar.search), BENCH_SEARCH)

		older_pages_keep_the_view(t, app, s)
		output_view_built(t, app, s)
	})
}

@(private = "file")
Posted_Answer :: struct { app: ^App, r: ^Request }

// As a worker thread gives it: run in begin_build.
@(private = "file")
post_answer :: proc(app: ^App, r: ^Request, body: string) {
	r.status, r.ok, r.resp = 200, true, strings.clone(body)
	p := new(Posted_Answer)
	p^ = {app, r}
	ui.post(&app.state, proc(data: rawptr, word: u64) {
		p := (^Posted_Answer)(data)
		answer(p.app, p.r)
		free(p)
	}, p)
}

@(private = "file")
older_page :: proc(first, n: int, next: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, `{"data":[`)
	for i in 0 ..< n {   // (newest first)
		if i > 0 { strings.write_byte(&b, ',') }
		fmt.sbprintf(&b, `{{"id":"old_%d","type":"user","text":"An older prompt about a zebra, with a line of words after it.","time":{{"created":%d}}}}`, first + n - i, first + n - i)
	}
	fmt.sbprintf(&b, `],"cursor":{{"next":"%s"}}}}`, next)
	return strings.to_string(b)
}

// The view at the very top: a page read before the first message goes above what is read, and the view stays on it. If it stayed at
// offset 0 instead it would be at the top of the new page: the next one is asked for at once, and so on to the start of the history.
@(private = "file")
older_pages_keep_the_view :: proc(t: ^testing.T, app: ^App, s: ^session.Session) {
	c := &app.chat
	app.conn = bench_conn(app)   // (requests are kept: answers_test.odin)
	clear(&bench_sent)
	c.older = strings.clone("cursor", c.alloc)
	app.chat_scroll = Scroll_Free{}
	sb := session.get(s, "chat")
	sb.view_off.y, sb.view_target.y = 0, 0
	sb.view_anim[1] = {}
	session.frames(s, 3)
	testing.expect_value(t, bench_count(.Older), 1)
	name := fmt.tprintf("msg_%s", c.messages[0].id)
	y := session.get(s, name).rect.min.y
	post_answer(app, bench_take(t, .Older), older_page(1000, 60, "more"))
	session.frames(s, 6)
	sb = session.get(s, "chat")
	testing.expect_value(t, len(c.messages), 3 * BENCH_TURNS + 60)
	testing.expect(t, abs(session.get(s, name).rect.min.y - y) <= 2, "what was read did not move")
	testing.expect(t, sb.view_off.y > sb.size.y * OLDER_MARGIN, "the view is under the new page")
	testing.expect_value(t, bench_count(.Older), 0)

	// a find open: the current match stays the same one when a page comes in front of it
	find_open(app)
	ui.line_edit_set(&app.find.field, "zebra")
	session.wait_until(s, proc(s: ^session.Session) -> bool { return !ui.find_pending() && ui.find_count() == 60 }, "the needle swept")
	session.frames(s, 2)
	app.find.index = 10
	request(app, .Older, "GET", "/older", tag = c.id)
	post_answer(app, bench_take(t, .Older), older_page(2000, 8, ""))
	session.wait_until(s, proc(s: ^session.Session) -> bool { return ui.find_count() == 68 }, "the page swept")
	session.frames(s, 2)
	testing.expect_value(t, app.find.index, 18)
	find_close(app)

	// a wheel turned up past the top while the page is read stops at the top; the page that comes carries that stop along. (It
	// glided over all of the page to its top: the view jumped, and the next page was asked for at once.)
	// (from a known place, at rest, well under the top: where the find left the view is the machine's, at the top or still
	// gliding to its match, and a wheel turned up at the top glides nowhere)
	sb = session.get(s, "chat")
	ui.view_jump(sb, sb.size.y * OLDER_WHEEL_FROM_SCREENS)
	session.wait_idle(s)
	c.older = strings.clone("more", c.alloc)
	session.frames(s, 2)
	sb = session.get(s, "chat")
	testing.expectf(t, sb.view_off.y > sb.size.y * OLDER_MARGIN && !sb.view_anim[1].active, "under the top, at rest: %v", sb.view_off.y)
	testing.expect_value(t, bench_count(.Older), 0)
	// (the interface's time slowed for the frames read: a slow machine's frames would end the glide in them)
	film_slow_start(app, BENCH_SLOW_MOTION)
	session.wheel(s, session.center(sb), {0, -200})
	session.frames(s, 1)
	sb = session.get(s, "chat")
	testing.expect(t, sb.view_target.y == 0 && sb.view_anim[1].active, "on its way to the top, stopped there")
	film_slow_stop(app)
	if testing.expect_value(t, bench_count(.Older), 1) {
		post_answer(app, bench_take(t, .Older), older_page(3000, 60, ""))
		session.wait_idle(s)
		sb = session.get(s, "chat")
		testing.expectf(t, sb.view_off.y > sb.size.y * OLDER_MARGIN, "the view stays under the new page: %v", sb.view_off.y)
	}
	app.conn = nil
}

// The menus' icons are Lucide's characters, drawn in its face: the app menu has one on each item.
@(test)
the_menus_have_their_icons :: proc(t: ^testing.T) {
	unwatched.run(t, proc(t: ^testing.T) {
		context.allocator = runtime.heap_allocator()
		app, s := bench_app(t)
		session.click(s, "appmenu")
		session.frames(s, 3)
		icons := 0
		for i := 0; ; i += 1 {
			b := session.find(s, "ico", i)
			if b == nil { break }
			testing.expectf(t, b.font == app.icons, "an icon in Lucide's face (%v, not %v)", b.font, app.icons)
			icons += 1
		}
		testing.expectf(t, icons >= 12, "an icon on each item: %d", icons)
		session.event(s, {kind = .Key_Press, key = .Escape})
		session.frames(s, 2)
	})
}

// An artifact the session made is a card after the message it was made in (the last one, here); a click shows it.
@(test)
an_artifact_of_the_session_is_a_card :: proc(t: ^testing.T) {
	unwatched.run(t, proc(t: ^testing.T) {
		context.allocator = runtime.heap_allocator()
		app, s := bench_app(t)
		last := app.chat.messages[len(app.chat.messages) - 1]
		page := fmt.tprintf(`{{"data":[{{"id":"art_1","sessionID":"%s","title":"Essai d'outils","entry":"index.html","url":"/api/x/art_1/view/","time":{{"created":%f}}}},{{"id":"art_other","sessionID":"ses_2","title":"Not this one","time":{{"created":%f}}}}]}}`, app.chat.id, last.created + 1, last.created + 1)
		v, err := json.parse_string(page, allocator = context.temp_allocator)
		testing.expect(t, err == nil)
		chat_artifacts_load(app, app.chat.id, v)
		chat_artifacts_load(app, "ses_2", v)   // (an answer for a session not shown: not its)
		chat_scroll_event(app, Scroll_Signal.Snap)
		session.wait_idle(s)
		card := session.find(s, "art_art_1")
		if !testing.expect(t, card != nil, "the card") { return }
		testing.expect(t, session.find(s, "art_art_other") == nil, "another session's is not shown")
		testing.expect(t, session.find_text(s, "Essai d'outils") != nil, "its title")
		item := session.find(s, last.lazy_id[3:])
		testing.expect(t, item != nil && card.rect.min.y >= item.rect.min.y && card.rect.max.y <= item.rect.max.y, "in the last message's item")
		session.save_png(s, "artifact_card.png")
		session.click(s, "art_art_1")
		session.frames(s, 2)
		testing.expect(t, app.cx.open[.Artifacts] && app.cx.artifacts.shown == "art_1", "a click shows it")
		app.cx.open[.Artifacts] = false
	})
}

// A right click on the sessions' search opens its menu: Paste puts a value in it (gui_toolkit's edit_menu).
@(test)
the_search_has_a_menu :: proc(t: ^testing.T) {
	unwatched.run(t, proc(t: ^testing.T) {
		context.allocator = runtime.heap_allocator()
		app, s := bench_app(t)
		session.set_clipboard(s, "ses_2")
		session.click(s, "search", .Right)
		session.frames(s, 2)
		testing.expect(t, ui.menu_any_open(), "its menu")
		session.save_png(s, "search_menu.png")
		session.click_text(s, "Paste")
		session.frames(s, 3)
		testing.expect_value(t, ui.line_edit_string(&app.sidebar.search), "ses_2")
		testing.expect(t, session.find(s, "ls_ses_2") != nil, "the search found it by its id")
		// its cross empties it
		session.click(s, "clear")
		session.frames(s, 3)
		testing.expect_value(t, ui.line_edit_string(&app.sidebar.search), "")
	})
}

// The todos show all, what remains or what is done: the header's choice says how many of each.
@(test)
the_todos_filter_by_state :: proc(t: ^testing.T) {
	unwatched.run(t, proc(t: ^testing.T) {
		context.allocator = runtime.heap_allocator()
		app, s := bench_app(t)
		a := &app.activity
		todos_clear(a)
		for it in ([4][2]string{{"read the code", "completed"}, {"write the fix", "in_progress"}, {"test it", "pending"}, {"old idea", "cancelled"}}) {
			append(&a.todos, Todo{strings.clone(it[0]), strings.clone(it[1])})
		}
		defer todos_clear(a)
		activity_open(app)
		session.wait_idle(s)
		rows :: proc(s: ^session.Session) -> (n: int) {
			for k in 0 ..< 4 { if session.find(s, fmt.tprintf("td%d", k)) != nil { n += 1 } }
			return
		}
		testing.expect_value(t, rows(s), 4)
		testing.expect(t, session.find_text(s, "Active 2") != nil && session.find_text(s, "Done 2") != nil, "how many of each")
		session.click(s, "seg1")
		session.wait_idle(s)   // (the tray glides to its new height: what is clicked next stands still)
		testing.expect_value(t, a.todo_filter, Todo_Filter.Active)
		testing.expect(t, rows(s) == 2 && session.find(s, "td1") != nil && session.find(s, "td2") != nil, "what remains")
		session.click(s, "seg2")
		session.wait_idle(s)   // (the tray glides to its new height: what is clicked next stands still)
		testing.expect(t, rows(s) == 2 && session.find(s, "td0") != nil && session.find(s, "td3") != nil, "what is over")
		session.click(s, "seg0")
		session.wait_idle(s)   // (the tray glides to its new height: what is clicked next stands still)
		testing.expect_value(t, rows(s), 4)
		session.save_png(s, "todos_filter.png")
		activity_close(app)
	})
}

// Kernel is made for the edged finish: chosen, it brings it (whatever appearance.style says), and its square corners; the
// statistics' sections are headed in their colours, the tokens' mix a bar.
@(test)
the_console_theme_is_edged :: proc(t: ^testing.T) {
	unwatched.run(t, proc(t: ^testing.T) {
		context.allocator = runtime.heap_allocator()
		app, s := bench_app(t)
		// (the dark version, whatever the system's: a light one is flat by design, and a CI machine may be light)
		pref_set(app, "appearance.mode", "dark")
		defer pref_set(app, "appearance.mode", "system")
		testing.expect_value(t, app.theme.finish, ui.Finish.Machined)
		pref_set(app, "appearance.theme", "Kernel")
		defer pref_set(app, "appearance.theme", "OpenCode")
		testing.expect_value(t, app.theme.finish, ui.Finish.Edged)
		testing.expect_value(t, corners(), 0)
		pref_set(app, "appearance.finish", "flat")   // (the theme's own finish wins over the style asked)
		testing.expect_value(t, app.theme.finish, ui.Finish.Edged)
		pref_set(app, "appearance.finish", "machined")
		stats_open(app)
		session.wait_idle(s)
		testing.expect(t, session.find(s, "st_Tokens") != nil, "the tokens' section")
		session.save_png(s, "console.png")
		panel_close(app, u32(Panel.Stats))
	})
}

// The screens for the eye (build/session/bench_app/console_*.png), as the program looks by default (its own theme, OpenCode):
// the settings, the palette, the activity with its todos, a shell. What each shows is checked elsewhere; here, that each opens.
@(test)
the_console_screens :: proc(t: ^testing.T) {
	unwatched.run(t, proc(t: ^testing.T) {
		context.allocator = runtime.heap_allocator()
		app, s := bench_app(t)
		settings_open(app)
		session.wait_idle(s)
		session.save_png(s, "console_settings.png")
		app.cx.open[.Settings] = false
		// the approvals' shield and its menu, in the composer's toolbar
		session.wait_idle(s)
		testing.expect(t, session.find(s, "approval") != nil, "the shield")
		session.click(s, "approval")
		session.wait_idle(s)
		session.save_png(s, "console_approvals.png")
		ui.menu_close()
		session.frames(s, 2)
		command_run(app, command_find("app.palette"))
		session.frames(s, 3)
		ui.line_edit_set(&app.palette.field, "the")
		session.wait_idle(s)
		session.save_png(s, "console_palette.png")
		app.cx.open[.Palette] = false
		a := &app.activity
		todos_clear(a)
		for it in ([4][2]string{{"read the code", "completed"}, {"write the fix", "in_progress"}, {"test it", "pending"}, {"ship it", "pending"}}) {
			append(&a.todos, Todo{strings.clone(it[0]), strings.clone(it[1])})
		}
		defer todos_clear(a)
		activity_open(app)
		session.wait_idle(s)
		session.save_png(s, "console_activity.png")
		activity_close(app)
		if app.conn == nil { app.conn = bench_conn(app) }   // (the bench has no server: its requests are kept for the test to answer)
		clear(&bench_sent)
		terminal_toggle(app)
		bench_answer(app, bench_take(t, .Pty_List), 200, `{"data":[{"id":"a","title":"bash","status":"running"}]}`)
		for sh in app.cx.terms.list { term_link_set(app, sh, .Attached) }
		bench_clear(app)
		term_feed(app.cx.terms.list[0], "\x1b[1;34m~/code/project\x1b[0m \x1b[32m$\x1b[0m ls\r\n\x1b[1;34msrc\x1b[0m  \x1b[1;34mdocs\x1b[0m  README.md  \x1b[32mbuild.sh\x1b[0m\r\n\x1b[1;34m~/code/project\x1b[0m \x1b[32m$\x1b[0m odin build src\r\n\x1b[33mwarning\x1b[0m: an unused import\r\n\x1b[1;34m~/code/project\x1b[0m \x1b[32m$\x1b[0m ")
		session.wait_idle(s)
		testing.expect(t, len(app.cx.terms.list) == 1, "a shell")
		session.save_png(s, "console_terminal.png")
	})
}

// The shells have a face of their own, Fira Mono (no ligatures), not the code's; a family of the system when one is asked.
@(test)
the_shells_have_their_own_face :: proc(t: ^testing.T) {
	unwatched.run(t, proc(t: ^testing.T) {
		context.allocator = runtime.heap_allocator()
		app, _ := bench_app(t)
		testing.expect(t, app.term_font == app.own.term[0] && app.term_font != app.mono, "Fira Mono, not DM Mono")
		testing.expect(t, app.term_font_bold == app.own.term[1] && app.term_font_bold != app.term_font, "its bold")
		testing.expect_value(t, app.term_face, "")
		pref_set(app, "appearance.text.terminal_font", "DejaVu Sans Mono")
		defer pref_set(app, "appearance.text.terminal_font", "")
		if app.term_face != "" {   // (where it is installed)
			testing.expect_value(t, app.term_face, "DejaVu Sans Mono")
			testing.expect(t, app.term_font != app.own.term[0], "the system's")
		}
		pref_set(app, "appearance.text.terminal_font", "")
		testing.expect(t, app.term_font == app.own.term[0], "back to its own")
	})
}

// A shell's letters stay on their columns whatever their colours: a line whose colour changes at every letter ends where
// the same line in one colour ends (drawn at the face's own advance, a run fell behind the grid and the next one, at its cell,
// left a gap).
@(test)
a_shell_keeps_its_columns_across_colours :: proc(t: ^testing.T) {
	unwatched.run(t, proc(t: ^testing.T) {
		context.allocator = runtime.heap_allocator()
		app, s := bench_app(t)
		if app.conn == nil { app.conn = bench_conn(app) }   // (the bench has no server: its requests are kept for the test to answer)
		clear(&bench_sent)
		terminal_toggle(app)
		bench_answer(app, bench_take(t, .Pty_List), 200, `{"data":[{"id":"a","title":"bash","status":"running"}]}`)
		for sh in app.cx.terms.list { term_link_set(app, sh, .Attached) }
		bench_clear(app)
		if !testing.expect(t, len(app.cx.terms.list) == 1, "a shell") { return }
		sh := app.cx.terms.list[0]
		// one line in one colour, the same with a change of colour at every letter (each letter its own run, at its cell)
		mixed := strings.builder_make(context.temp_allocator)
		for c, i in "abcdefghijklmnopqrst" { fmt.sbprintf(&mixed, "\x1b[%dm%c", i % 2 == 0 ? 33 : 0, c) }
		term_feed(sh, fmt.tprintf("abcdefghijklmnopqrst\r\n%s\x1b[0m\r\n", strings.to_string(mixed)))   // (the cursor on the next line)
		session.wait_idle(s)
		img := session.capture(s)
		// the right end of what is drawn on a row of cells
		end_of :: proc(img: session.Image, r: Rect, top, h: f32) -> int {
			bg := session.pixel(img, int(r.max.x) - 4, int(top + h * 0.5))
			last := -1
			for y in int(top) ..< int(top + h) {
				for x in int(r.min.x) ..< int(r.max.x) - 8 {
					if !session.near(session.pixel(img, x, y), bg, 40) { last = max(last, x) }
				}
			}
			return last
		}
		// (each row where it is drawn: the grid is centered in its box, term.grid_origin)
		plain := end_of(img, sh.view.rect, sh.view.origin.y, sh.view.metrics.cell_h)
		coloured := end_of(img, sh.view.rect, sh.view.origin.y + sh.view.metrics.cell_h, sh.view.metrics.cell_h)
		testing.expect(t, plain > int(sh.view.rect.min.x), "the first line is drawn")
		testing.expectf(t, abs(plain - coloured) <= 1, "both lines end at one column: %d and %d", plain, coloured)
	})
}

// The system's title bar, by choice: chosen, the window's title is the system's and its buttons are not drawn here; the
// program's again when it is turned off.
@(test)
the_system_title_bar_by_choice :: proc(t: ^testing.T) {
	unwatched.run(t, proc(t: ^testing.T) {
		context.allocator = runtime.heap_allocator()
		app, s := bench_app(t)
		testing.expect(t, platform.is_integrated_title(app.win), "the program's title bar at first")
		session.wait_idle(s)
		testing.expect(t, session.find(s, "wb_close") != nil, "its buttons")
		pref_set(app, "window.system_title", "true")
		defer pref_set(app, "window.system_title", "false")
		session.wait_idle(s)
		testing.expect(t, !platform.is_integrated_title(app.win), "the system's")
		testing.expect(t, session.find(s, "wb_close") == nil, "the system's buttons: none here")
		testing.expect(t, session.find(s, "appmenu") != nil, "the program's bar stays, its menu in it")
		pref_set(app, "window.system_title", "false")
		session.wait_idle(s)
		testing.expect(t, platform.is_integrated_title(app.win) && session.find(s, "wb_close") != nil, "the program's again")
	})
}

// The full diff's close cross: in the dialog's corner, the same margin from its top and its right edge, centered with the
// header's controls and clear of them (it once touched the "Stacked | Split" choice beside it).
@(test)
the_full_diff_s_close_cross_is_clear_of_its_header :: proc(t: ^testing.T) {
	unwatched.run(t, proc(t: ^testing.T) {
		context.allocator = runtime.heap_allocator()
		app, s := bench_app(t)
		diff_full_open(app, "a.txt", "--- a/a.txt\n+++ b/a.txt\n@@ -1 +1 @@\n-a\n+b\n")
		session.frames(s, 3)
		x, mode := session.find(s, "dialog_close"), session.find(s, "df_mode")
		if !testing.expect(t, x != nil && mode != nil, "the cross and the layout's choice") { return }
		panel := x.parent.rect
		top, right := x.rect.min.y - panel.min.y, panel.max.x - x.rect.max.x
		testing.expectf(t, top > 0 && top == right, "the same margin from the top (%v) and from the right (%v)", top, right)
		testing.expectf(t, mode.rect.max.x + right <= x.rect.min.x, "the choice ends at %v, the cross begins at %v", mode.rect.max.x, x.rect.min.x)
		testing.expectf(t, abs(session.center(mode).y - session.center(x).y) <= 1, "centered together: %v and %v", session.center(mode).y, session.center(x).y)
	})
}

// The viewer, in the real interface: exactly around its picture, a press beside the picture closes it, a press on it does not, its corner
// sets the size it keeps, and its menu copies the image.
@(test)
the_viewer_hugs_its_picture_and_keeps_its_size :: proc(t: ^testing.T) {
	unwatched.run(t, proc(t: ^testing.T) {
		context.allocator = runtime.heap_allocator()
		app, s := bench_app(t)
		W, H :: 400, 200
		pixels := make([]u8, W * H * 4, context.temp_allocator)
		for i in 0 ..< W * H { pixels[i * 4], pixels[i * 4 + 1], pixels[i * 4 + 2], pixels[i * 4 + 3] = u8(i % W), 120, u8(i / W), 255 }
		tex := render.create_texture_rgba(&app.r, W, H)
		render.update_texture_rgba(&app.r, tex, 0, 0, W, H, pixels)
		open :: proc(app: ^App, tex: render.Texture) {
			// (as image_view_open, its decode not asked: the picture is given)
			image_ref_delete(&app.viewer.ref)
			app.viewer.ref = image_ref_clone(image_ref("not decoded here", .Bytes, "image/png", "picture.png"))
			app.viewer.key = 0x5eed
			app.images[app.viewer.key] = {state = .Ready, tex = tex, w = W, h = H, used = app.frame_no}
			app.cx.open[.Viewer], app.viewer.grown, app.viewer.focus = true, false, true
			ui.preview_reset(&app.viewer.view)
		}
		open(app, tex)
		session.frames(s, 3)
		view, panel := session.find(s, "view"), session.find(s, "modal_image_view")
		testing.expect(t, view != nil && panel != nil, "the viewer")
		if view == nil || panel == nil { return }
		em := ui.font_size()
		pad, bar := math.round(em * VIEWER_PAD_EM), math.round(em * VIEWER_BAR_EM)
		vs := view.rect.max - view.rect.min
		ps := panel.rect.max - panel.rect.min
		testing.expect_value(t, vs, [2]f32{W, H} * ui.scale())   // (the window has room: its pixels)
		testing.expect_value(t, ps.y, vs.y + pad + bar)
		testing.expect_value(t, ps.x, max(vs.x + 2 * pad, math.round(em * VIEWER_MIN_W_EM)))
		// a press on the picture keeps it; zoomed out, a press beside the picture closes it
		session.click_at(s, view.rect.min + 5)
		testing.expect(t, app.cx.open[.Viewer], "a press on the picture")
		app.viewer.view.zoom = 0.5
		session.frames(s, 2)
		// (the other corner: a second press where the first was would be a double click, which zooms)
		session.click_at(s, view.rect.max - 5)
		testing.expect(t, !app.cx.open[.Viewer], "a press beside the picture closes it")
		// its corner, outward: the picture grows past its pixels, as far as the pointer goes, and the size is kept (a share of the room)
		open(app, tex)
		session.frames(s, 3)
		view, panel = session.find(s, "view"), session.find(s, "modal_image_view")
		before := view.rect.max - view.rect.min
		testing.expect_value(t, before, [2]f32{W, H} * ui.scale())
		corner := panel.rect.max - 3
		session.press(s, corner)
		session.move(s, corner + {25, 0})
		session.move(s, corner + {50, 0})
		session.release(s, corner + {50, 0})
		session.frames(s, 2)
		view = session.find(s, "view")
		after := view.rect.max - view.rect.min
		testing.expectf(t, abs(after.x - (before.x + 100)) < 2, "the corner moved 50 px: both sides 100 px, past its pixels: %v", after)
		testing.expectf(t, abs(after.x / after.y - 2) < 0.02, "its shape kept: %v", after)
		room := app.state.window_size - 2 * math.round(em * ui.MODAL_MARGIN_EM)
		full := viewer_frame({W, H}, room, {2 * pad, pad + bar}, ui.scale(), 1, math.round(em * VIEWER_MIN_W_EM)).full
		kept := config.float_of(&app.cfg_prefs, "conversation.image_viewer_size")
		testing.expectf(t, abs(kept - f64(after.x / full.x)) < 0.01, "kept as a share of the room: %v", kept)
		// opened again: a picture that fits opens at its pixels, whatever the share kept
		open(app, tex)
		session.frames(s, 3)
		view = session.find(s, "view")
		testing.expect_value(t, view.rect.max - view.rect.min, before)
		// a copy: the file's pixels, whole, on the clipboard
		small := []u8{255, 0, 0, 255, 0, 255, 0, 128, 0, 0, 255, 255, 9, 8, 7, 0, 1, 2, 3, 4, 200, 100, 50, 255}
		file := png.encode(small, 3, 2, .Fast, context.temp_allocator)
		image_copy(app, image_ref(string(file), .Bytes, "image/png", "small.png"))
		session.wait_until(s, proc(s: ^session.Session) -> bool {
			img, ok := platform.clipboard_get_image(s.win, context.temp_allocator)
			return ok && img.size == {3, 2}
		}, "the copied image")
		img, _ := platform.clipboard_get_image(app.win, context.temp_allocator)
		testing.expect(t, slice.equal(img.rgba, small), "its pixels, as they were (alpha too)")
		// its menu
		session.click_at(s, session.center(view), .Right)
		session.frames(s, 2)
		testing.expect(t, session.find_text(s, "Copy image") != nil, "Copy image")
		session.event(s, {kind = .Key_Press, key = .Escape})
		session.frames(s, 2)
		session.event(s, {kind = .Key_Press, key = .Escape})
		session.frames(s, 3)
		testing.expect(t, !app.cx.open[.Viewer], "Escape closes it")
	})
}

// A question's long options and the review's long answers stay in the card: they go on to the next lines (they ran past its edge).
@(test)
a_form_s_long_lines_stay_in_its_card :: proc(t: ^testing.T) {
	unwatched.run(t, proc(t: ^testing.T) {
		app, s := bench_app(t)
		LONG :: "Format d'unité, description des fonctions, convention d'appel, chargeur. C'est le trou de recherche déjà identifié, et il reste ouvert"
		v, err := json.parse_string(fmt.tprintf(`{{"id":"frm_w","sessionID":"%s","question":true,"fields":[
			{{"key":"a","type":"multiselect","title":"À creuser","options":[{{"value":"u","label":"Contrat entre unités","description":"%s"}},{{"value":"m","label":"Machines","description":"%s"}}]}},
			{{"key":"b","type":"string","title":"Review","description":"%s"}}
		]}}`, BENCH_CHAT_ID, LONG, LONG, LONG), allocator = context.temp_allocator)
		testing.expect_value(t, err, json.Error.None)
		form_add(app, v)
		session.frames(s, 3)
		card := session.find(s, "form_frm_w")
		if !testing.expect(t, card != nil, "the card") { return }
		inside :: proc(t: ^testing.T, card, b: ^ui.Box, what: string, loc := #caller_location) {
			if !testing.expectf(t, b != nil, "%s", what, loc = loc) { return }
			testing.expectf(t, b.rect.max.x <= card.rect.max.x + 0.5, "%s: in the card (%v past %v)", what, b.rect.max.x, card.rect.max.x, loc = loc)
			for c := b.first; c != nil; c = c.next {
				testing.expectf(t, c.rect.max.x <= card.rect.max.x + 0.5, "%s: its parts in the card (%v past %v)", what, c.rect.max.x, card.rect.max.x, loc = loc)
			}
		}
		inside(t, card, session.find(s, "form_o0"), "a long option")
		f := app.cx.forms[0]
		ui.line_edit_set(&f.fields[1].text, LONG)
		f.fields[0].picks[0] = true
		f.page = 2   // (the review)
		session.frames(s, 3)
		inside(t, card, session.find(s, "form_rv0"), "the first answer")
		inside(t, card, session.find(s, "form_rv1"), "a long answer")
		forms_clear(app)
	})
}

// Under the pointer, a table's copy button is over its rows (the last of the table's boxes: built before them, the rows hid it and took
// its clicks), and a click on it copies the table.
@(test)
a_table_s_copy_button_is_over_its_rows :: proc(t: ^testing.T) {
	unwatched.run(t, proc(t: ^testing.T) {
		app, s := bench_app(t)
		// up from the bottom until a table's rows are in sight (the conversation builds what is seen)
		table_in_sight :: proc(s: ^session.Session, app: ^App) -> ^ui.Box {
			for i := 0; ; i += 1 {
				b := session.find(s, "rows", i)
				if b == nil { return nil }
				// (a table's, in the conversation: the sidebar's list is "rows" too)
				if b.rect.min.x > app.sidebar.width && b.rect.min.y > 0 && b.rect.max.y < f32(BENCH_SIZE.y) && b.rect.max.x > b.rect.min.x { return b }
			}
		}
		rows := table_in_sight(s, app)
		mid := [2]f32{app.sidebar.width + (f32(BENCH_SIZE.x) - app.sidebar.width) * 0.5, f32(BENCH_SIZE.y) * 0.5}
		for k := 0; rows == nil && k < 60; k += 1 {
			session.event(s, {kind = .Scroll, pos = mid, delta = {0, 3}})
			session.wait_idle(s)   // (the scroll glides: where the table is, once it stands)
			rows = table_in_sight(s, app)
		}
		if !testing.expect(t, rows != nil, "a table in sight") { return }
		session.move(s, session.center(rows))
		session.wait_idle(s)
		copy := session.find(s, "tcorner")
		if !testing.expect(t, copy != nil, "its copy button, under the pointer") { return }
		testing.expect(t, copy.parent != nil && copy.parent.last == copy, "the last of the table's boxes: over its rows")
		session.click_at(s, session.center(copy))
		session.frames(s, 2)
		testing.expect(t, session.find_text(s, "Table copied") != nil, "a click on it copies the table")
	})
}

// A form's tabs: each as wide as its title, on a next line when they do not fit; none over another, every title in its tab (shared
// out equally, a long title ran over the next tab).
@(test)
a_form_s_tabs_do_not_overlap :: proc(t: ^testing.T) {
	unwatched.run(t, proc(t: ^testing.T) {
		app, s := bench_app(t)
		titles := []string{"WebGPU implementation", "Linker", "Debug info", "Contract details", "Kernel operation limit", "Next step",
			"A question whose title is much longer than any tab should ever be, to make the tabs go onto a second line"}
		b := strings.builder_make(context.temp_allocator)
		fmt.sbprintf(&b, `{{"id":"frm_t","sessionID":"%s","question":true,"fields":[`, BENCH_CHAT_ID)
		for title, i in titles {
			if i > 0 { strings.write_string(&b, ",") }
			fmt.sbprintf(&b, `{{"key":"k%d","type":"string","title":"%s","options":[{{"value":"a","label":"A"}}]}}`, i, title)
		}
		strings.write_string(&b, "]}")
		v, err := json.parse_string(strings.to_string(b), allocator = context.temp_allocator)
		testing.expect_value(t, err, json.Error.None)
		form_add(app, v)
		session.frames(s, 3)
		card := session.find(s, "form_frm_t")
		if !testing.expect(t, card != nil, "the card") { return }
		tabs := make([dynamic]^ui.Box, context.temp_allocator)
		for i in 0 ..< len(titles) { if tb := session.find(s, fmt.tprintf("form_tab%d", i)); tb != nil { append(&tabs, tb) } }
		if tb := session.find(s, "form_tab_review"); tb != nil { append(&tabs, tb) }
		testing.expect_value(t, len(tabs), len(titles) + 1)
		rows := map[f32]bool{}
		defer delete(rows)
		for a, i in tabs {
			rows[a.rect.min.y] = true
			testing.expectf(t, a.rect.max.x <= card.rect.max.x + 0.5, "tab %d in the card", i)
			for c := a.first; c != nil; c = c.next {
				testing.expectf(t, c.rect.max.x <= a.rect.max.x + 0.5, "tab %d: its title in it (%v past %v)", i, c.rect.max.x, a.rect.max.x)
			}
			for b2, j in tabs {
				if j <= i { continue }
				over := a.rect.min.x < b2.rect.max.x - 0.5 && b2.rect.min.x < a.rect.max.x - 0.5 && a.rect.min.y < b2.rect.max.y - 0.5 && b2.rect.min.y < a.rect.max.y - 0.5
				testing.expectf(t, !over, "tabs %d and %d do not overlap (%v, %v)", i, j, a.rect, b2.rect)
			}
		}
		testing.expect(t, len(rows) > 1, "too many for one line: a second one")
		forms_clear(app)
	})
}

// A long conversation part opened in the middle of the view: its header stays where it was on screen, and what it shows
// grows below it (the view does not jump to the top).
@(private = "file")
long_parts_page :: proc() -> string {
	lines := strings.builder_make(context.temp_allocator)
	for i in 0 ..< 400 { fmt.sbprintf(&lines, "line %d of a long output, long enough to wrap maybe once or twice in the column\n", i) }
	long := strings.to_string(lines)
	t := BENCH_EPOCH_MS
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, `{{"data":[`)
	fmt.sbprintf(&b, `{{"id":"lp_3_a","type":"assistant","agent":"build","model":{{"id":"m","providerID":"p"}},"finish":"stop","time":{{"created":%f,"completed":%f}},"content":[{{"type":"text","text":"Done."}}]}},`, t + 40, t + 41)
	fmt.sbprintf(&b, `{{"id":"lp_3_u","type":"user","text":"And then?","time":{{"created":%f}}}},`, t + 30)
	fmt.sbprintf(&b, `{{"id":"lp_2_a","type":"assistant","agent":"build","model":{{"id":"m","providerID":"p"}},"finish":"stop","time":{{"created":%f,"completed":%f}},"content":[{{"type":"reasoning","text":%s}},{{"type":"tool","id":"call_sh","name":"shell","state":{{"status":"completed","input":{{"command":"make all"}},"content":[{{"type":"text","text":%s}}]}},"time":{{"created":%f,"completed":%f}}}},{{"type":"text","text":"It built."}}]}},`,
		t + 20, t + 25, jquote(long), jquote(long), t + 21, t + 22)
	fmt.sbprintf(&b, `{{"id":"lp_2_u","type":"user","text":"Build it.","time":{{"created":%f}}}},`, t + 10)
	fmt.sbprintf(&b, `{{"id":"lp_1_a","type":"assistant","agent":"build","model":{{"id":"m","providerID":"p"}},"finish":"stop","time":{{"created":%f,"completed":%f}},"content":[{{"type":"text","text":%s}}]}},`, t + 5, t + 6, jquote(strings.repeat("A paragraph above, to have something to scroll back to. ", 80, context.temp_allocator)))
	fmt.sbprintf(&b, `{{"id":"lp_1_u","type":"user","text":"Hello.","time":{{"created":%f}}}}`, t)
	strings.write_string(&b, `],"cursor":{"next":""}}`)
	return strings.to_string(b)
}

@(test)
a_long_part_opens_below_its_header :: proc(t: ^testing.T) {
	unwatched.run(t, proc(t: ^testing.T) {
		context.allocator = runtime.heap_allocator()
		app, s := bench_app(t)
		v, err := json.parse_string(long_parts_page(), allocator = context.temp_allocator)
		testing.expect(t, err == nil)
		chat_load(app, v, false)
		chat_scroll_event(app, Scroll_Signal.Snap)
		session.wait_idle(s)
		for name in ([]string{"rh_lp_2_a_0", "head"}) {
			h := session.find(s, name)
			if !testing.expectf(t, h != nil, "%s shows", name) { return }
			y := h.rect.min.y
			session.click(s, name)
			session.wait_idle(s)
			h = session.find(s, name)
			if !testing.expectf(t, h != nil, "%s opened: still shown", name) { return }
			testing.expectf(t, abs(h.rect.min.y - y) <= 1, "%s opened: stays at %v (now %v)", name, y, h.rect.min.y)
			session.click(s, name)   // (closed again: the next one where it was)
			session.wait_idle(s)
			h = session.find(s, name)
			if !testing.expectf(t, h != nil, "%s closed: still shown", name) { return }
			testing.expectf(t, abs(h.rect.min.y - y) <= 1, "%s closed: stays at %v (now %v)", name, y, h.rect.min.y)
		}
	})
}

// Seven long thoughts in a row, between shells (a run that thinks at length).
@(private = "file")
seven_thoughts_page :: proc() -> string {
	para := strings.repeat("I'm working out the kernel design now, with a rough budget of lines, so I want it tight and every part to earn its place. ", 4, context.temp_allocator)
	long := strings.builder_make(context.temp_allocator)
	for _ in 0 ..< 14 { strings.write_string(&long, para); strings.write_string(&long, "\n\n") }
	t := BENCH_EPOCH_MS
	parts := strings.builder_make(context.temp_allocator)
	for k in 0 ..< 7 {
		if k > 0 { strings.write_byte(&parts, ',') }
		fmt.sbprintf(&parts, `{{"type":"reasoning","text":%s}},{{"type":"tool","id":"call_%d","name":"shell","state":{{"status":"completed","input":{{"command":"cat docs/%d.md"}},"content":[{{"type":"text","text":"ok"}}]}},"time":{{"created":%f,"completed":%f}}}}`,
			jquote(strings.to_string(long)), k, k, t + 21, t + 22)
	}
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, `{{"data":[`)
	fmt.sbprintf(&b, `{{"id":"sv_2_a","type":"assistant","agent":"build","model":{{"id":"m","providerID":"p"}},"time":{{"created":%f}},"content":[%s]}},`, t + 20, strings.to_string(parts))   // (not completed: the run goes on)
	fmt.sbprintf(&b, `{{"id":"sv_2_u","type":"user","text":"Design it.","time":{{"created":%f}}}}`, t + 10)
	strings.write_string(&b, `],"cursor":{"next":""}}`)
	return strings.to_string(b)
}

// A thought opened while the run goes on: the message still grows below (a thought streams in) and the header opened stays where it was.
@(test)
a_thought_opened_while_the_run_goes_on_stays :: proc(t: ^testing.T) {
	unwatched.run(t, proc(t: ^testing.T) {
		context.allocator = runtime.heap_allocator()
		app, s := bench_app(t)
		v, err := json.parse_string(seven_thoughts_page(), allocator = context.temp_allocator)
		testing.expect(t, err == nil)
		chat_load(app, v, false)
		app.chat.busy = true
		set_busy(app, app.chat.id, true)
		chat_scroll_event(app, Scroll_Signal.Snap)
		session.wait_idle(s)
		chat := session.find(s, "chat")
		if !testing.expect(t, chat != nil, "the conversation") { return }
		mid := [2]f32{(chat.rect.min.x + chat.rect.max.x) * 0.5, (chat.rect.min.y + chat.rect.max.y) * 0.5}
		name := "rh_sv_2_a_8"
		for _ in 0 ..< 200 {
			h := session.find(s, name)
			if h != nil && h.rect.min.y > chat.rect.min.y + 40 && h.rect.min.y < mid.y { break }
			session.wheel(s, mid, {0, -1})
			session.frames(s, 3)
		}
		h := session.find(s, name)
		if !testing.expect(t, h != nil, "the thought reached") { return }
		y := h.rect.min.y
		session.click(s, name)
		session.frames(s, 3)
		for i in 0 ..< 20 {
			bench_event(app, fmt.tprintf(`{{"type":"session.reasoning.delta","data":{{"sessionID":"%s","assistantMessageID":"sv_2_a","ordinal":14,"delta":"more of the thought, word after word, line %d.\n\n"}}}}`, app.chat.id, i))
			session.frames(s, 2)
			h = session.find(s, name)
			if !testing.expectf(t, h != nil, "delta %d: the thought opened still shown", i) { return }
			if !testing.expectf(t, abs(h.rect.min.y - y) <= 1, "delta %d: stays at %v (now %v)", i, y, h.rect.min.y) { return }
		}
	})
}

// The answer that streams in, a delta at a time.
@(private = "file")
stream_delta :: proc(app: ^App, i: int) {
	text := i % BENCH_PARAGRAPH_DELTAS == 0 ? fmt.tprintf("\n\n%s", BENCH_DELTA) : BENCH_DELTA
	bench_event(app, fmt.tprintf(`{{"type":"session.text.delta","data":{{"sessionID":"%s","assistantMessageID":"live_a","ordinal":0,"delta":%s}}}}`, app.chat.id, jquote(text)))
}

// What the reader reads, read up in the conversation: `name` exactly at `y` on the screen, and the view moved by no glide.
@(private = "file")
read_stays :: proc(t: ^testing.T, app: ^App, s: ^session.Session, name: string, y: f32, what: string, i: int) -> bool {
	sb := session.get(s, "chat")
	b := session.find(s, name)
	if !testing.expectf(t, b != nil, "%s %d: %s still shown", what, i, name) { return false }
	if !testing.expectf(t, b.rect.min.y == y, "%s %d: %s stays at %v (now %v)", what, i, name, y, b.rect.min.y) { return false }
	if !testing.expectf(t, !sb.view_anim[1].active && sb.view_off.y == sb.view_target.y, "%s %d: no glide (%v toward %v)", what, i, sb.view_off.y, sb.view_target.y) { return false }
	return testing.expectf(t, !chat_following(app), "%s %d: the bottom still let go of", what, i)
}

// The agent answers while the reader has gone up into the conversation: what they read does not move by a pixel, whatever grows
// below it (the answer that streams in, a tool's output, the composer) or changes above it (a message near it that grows, and the
// estimate of the messages never built, which each measure of the streaming answer moves). Following the bottom, the answer's end
// stays where it is on the screen at every frame.
@(test)
what_is_read_stays_while_the_answer_streams :: proc(t: ^testing.T) {
	unwatched.run(t, proc(t: ^testing.T) {
		context.allocator = runtime.heap_allocator()
		app, s := bench_app(t)
		c := &app.chat
		c.busy = true
		set_busy(app, c.id, true)
		started := BENCH_EPOCH_MS + f64(BENCH_TURNS) * BENCH_STEP_MS
		bench_event(app, fmt.tprintf(`{{"type":"session.step.started","data":{{"sessionID":"%s","assistantMessageID":"live_a","agent":"build","model":{{"id":"m","providerID":"p"}},"started":%f}}}}`, c.id, started))
		bench_event(app, fmt.tprintf(`{{"type":"session.text.started","data":{{"sessionID":"%s","assistantMessageID":"live_a","ordinal":0}}}}`, c.id))
		stream_delta(app, 0)
		chat_scroll_event(app, Scroll_Signal.Snap)
		session.frames(s, 4)

		// following: glued to the bottom
		live := session.find(s, "msg_live_a")
		if !testing.expect(t, live != nil, "the answer that streams in") { return }
		bottom := live.rect.max.y
		for i in 1 ..< 40 {
			stream_delta(app, i)
			session.frames(s, 1)
			sb := session.get(s, "chat")
			if !testing.expectf(t, chat_following(app) && sb.view_off.y >= ui.view_limit(sb) - 0.5, "following, delta %d: at the bottom (%v of %v)", i, sb.view_off.y, ui.view_limit(sb)) { return }
			live = session.find(s, "msg_live_a")
			if !testing.expectf(t, live != nil && live.rect.max.y == bottom, "following, delta %d: its end stays at %v (now %v)", i, bottom, live != nil ? live.rect.max.y : -1) { return }
		}

		// gone up, to the middle of the conversation
		sb := session.get(s, "chat")
		chat_scroll_event(app, Scroll_Signal.Moved_Up)
		ui.view_jump(sb, math.round(ui.view_limit(sb) * 0.5))
		session.frames(s, 6)
		sb = session.get(s, "chat")
		testing.expect(t, !chat_following(app), "up: the bottom let go of")
		// an answer that can grow (its last part a text), built: the view's top put just under its end, so that it is entirely above
		// the view and still built (the band built reaches a screen above the view)
		above := -1
		for m, i in c.messages {
			if m.kind != .Assistant || len(m.parts) == 0 || m.parts[len(m.parts) - 1].kind != .Text { continue }
			if b := session.find(s, fmt.tprintf("msg_%s", m.id)); b != nil && b.rect.max.y > sb.rect.min.y { above = i; break }
		}
		if !testing.expect(t, above >= 0, "an answer built in the view") { return }
		above_name := fmt.tprintf("msg_%s", c.messages[above].id)
		ab := session.get(s, above_name)
		ui.view_jump(sb, ab.rect.max.y - sb.rect.min.y + sb.view_off.y + 1)
		session.frames(s, 6)
		sb = session.get(s, "chat")
		ab = session.find(s, above_name)
		if !testing.expectf(t, ab != nil && ab.rect.max.y <= sb.rect.min.y, "the answer built above the view (%v, the view's top %v)", ab != nil ? ab.rect.max.y : -1, sb.rect.min.y) { return }
		// a message after it whose top is in the view
		at := -1
		for i in above + 1 ..< len(c.messages) {
			b := session.find(s, fmt.tprintf("msg_%s", c.messages[i].id))
			if b != nil && b.rect.min.y > sb.rect.min.y && b.rect.min.y < sb.rect.max.y - sb.size.y * 0.25 { at = i; break }
		}
		if !testing.expect(t, at > above, "a message in the view") { return }
		name := fmt.tprintf("msg_%s", c.messages[at].id)
		y := session.get(s, name).rect.min.y

		// the answer streams in below
		for i in 40 ..< 100 {
			stream_delta(app, i)
			session.frames(s, 1)
			if !read_stays(t, app, s, name, y, "delta", i) { return }
		}
		// a tool runs and its output comes in
		bench_event(app, fmt.tprintf(`{{"type":"session.tool.input.started","data":{{"sessionID":"%s","assistantMessageID":"live_a","id":"call_live","name":"read"}}}}`, c.id))
		session.frames(s, 1)
		if !read_stays(t, app, s, name, y, "tool started", 0) { return }
		bench_event(app, fmt.tprintf(`{{"type":"session.tool.called","data":{{"sessionID":"%s","assistantMessageID":"live_a","id":"call_live","input":{{"filePath":"src/live.odin"}}}}}}`, c.id))
		session.frames(s, 1)
		if !read_stays(t, app, s, name, y, "tool called", 0) { return }
		bench_event(app, fmt.tprintf(`{{"type":"session.tool.success","data":{{"sessionID":"%s","assistantMessageID":"live_a","id":"call_live","content":[{{"type":"text","text":%s}}]}}}}`, c.id, jquote(strings.repeat(BENCH_OUTPUT, 30, context.temp_allocator))))
		for i in 0 ..< 3 {
			session.frames(s, 1)
			if !read_stays(t, app, s, name, y, "tool done", i) { return }
		}
		// a message above the view grows (its height measured anew)
		text := &c.messages[above].parts[len(c.messages[above].parts) - 1].text
		for i in 0 ..< 4 {
			append(text, "\n\nA paragraph more, above what is read, long enough to take a line or two of the column and push what follows it down.")
			session.frames(s, 1)
			if !read_stays(t, app, s, name, y, "above", i) { return }
		}
		// the composer grows a few lines
		ui.text_edit_set(&app.composer.area, "one\ntwo\nthree\nfour\nfive")
		for i in 0 ..< 3 {
			session.frames(s, 1)
			if !read_stays(t, app, s, name, y, "composer", i) { return }
		}
		ui.text_edit_set(&app.composer.area, "")
		// and the answer goes on
		for i in 100 ..< 140 {
			stream_delta(app, i)
			session.frames(s, 1)
			if !read_stays(t, app, s, name, y, "delta", i) { return }
		}
	})
}

// A paused goal says why (the server's reason) at the end of the conversation, across it, all of it; the strip over the composer
// stays one line.
@(test)
a_paused_goal_says_why :: proc(t: ^testing.T) {
	unwatched.run(t, proc(t: ^testing.T) {
		context.allocator = runtime.heap_allocator()
		app, s := bench_app(t)
		reason := "The session failed: You've hit your 5-hour limit, which resets at 11:00. Upgrade your plan or wait for the limit to reset before you resume the goal, which keeps its rounds."
		v, err := json.parse_string(fmt.tprintf(`{{"objective":"Booted OS with a REPL","status":"paused","reason":%s,"rounds":3,"maxRounds":50}}`, jquote(reason)), allocator = context.temp_allocator)
		testing.expect(t, err == nil)
		goal_set(app, app.chat.id, v)
		chat_scroll_event(app, Scroll_Signal.Snap)
		session.wait_idle(s)
		strip, line, why := session.find(s, "goal_strip"), session.find(s, "goal_why"), session.find(s, "goal_reason")
		if !testing.expect(t, strip != nil && line != nil && why != nil, "the strip, the line and the reason") { return }
		em := ui.font_size()
		testing.expectf(t, strip.rect.max.y - strip.rect.min.y < em * 2.5, "the strip: one line (%v)", strip.rect)
		testing.expect(t, why.rect.min.y >= line.rect.max.y - 0.5 && why.rect.max.y <= strip.rect.min.y, "the reason under its line, over the strip")
		testing.expect(t, why.rect.max.y - why.rect.min.y > em * 1.5, "all of it, on more than one line")
		testing.expect(t, strings.contains(why.text, "keeps its rounds"), "to its end")
		active, _ := json.parse_string(fmt.tprintf(`{{"objective":"Booted OS with a REPL","status":"active","reason":%s}}`, jquote(reason)), allocator = context.temp_allocator)
		goal_set(app, app.chat.id, active)
		session.frames(s, 2)
		testing.expect(t, session.find(s, "goal_reason") == nil, "it goes when the goal goes on")
		goal_set(app, app.chat.id, nil)
	})
}

// What the session changed (its model, its agent, its folder) shows across the conversation, what it was and what it is; the
// composer says what it uses now.
@(test)
a_session_s_changes_show_across :: proc(t: ^testing.T) {
	unwatched.run(t, proc(t: ^testing.T) {
		context.allocator = runtime.heap_allocator()
		app, s := bench_app(t)
		ts := BENCH_EPOCH_MS + 1e9
		page := fmt.tprintf(`{{"data":[{{"id":"sw_l","type":"location-switched","location":{{"directory":"/home/sacha/Projects/kernel"}},"previous":{{"location":{{"directory":"/home/sacha/Projects/old"}}}},"time":{{"created":%f}}}},{{"id":"sw_a","type":"agent-switched","agent":"plan","previous":"build","time":{{"created":%f}}}},{{"id":"sw_m","type":"model-switched","model":{{"id":"claude-fable-5-2","providerID":"claude-agent","variant":"high"}},"previous":{{"id":"opus","providerID":"claude-agent","variant":"default"}},"time":{{"created":%f}}}}],"cursor":{{"next":""}}}}`, ts + 3, ts + 2, ts + 1)
		v, err := json.parse_string(page, allocator = context.temp_allocator)
		testing.expect(t, err == nil)
		chat_load(app, v, false)
		chat_scroll_event(app, Scroll_Signal.Snap)
		session.wait_idle(s)
		for id in ([]string{"sw_sw_m", "sw_sw_a", "sw_sw_l"}) { testing.expectf(t, session.find(s, id) != nil, "%s across the conversation", id) }
		testing.expect(t, session.find_text(s, "claude-fable-5-2 · high") != nil, "the model now, with its variant")
		testing.expect(t, session.find_text(s, "opus") != nil, "the model before")
		testing.expect(t, session.find_text(s, "/home/sacha/Projects/kernel") != nil, "the folder now")
		model, _ := shown_model(app)
		testing.expect_value(t, model, "claude-fable-5-2")
		testing.expect_value(t, shown_variant(app), "high")
		testing.expect_value(t, shown_agent(app), "plan")
	})
}

// Typed with nothing focused (a click in the conversation took the keyboard away): the composer takes it, the character too. Not a
// space alone, nor while the palette is over the window.
@(test)
typing_with_nothing_focused_goes_to_the_composer :: proc(t: ^testing.T) {
	unwatched.run(t, proc(t: ^testing.T) {
		context.allocator = runtime.heap_allocator()
		app, s := bench_app(t)
		ui.set_focus(0)
		session.frames(s, 2)
		session.type_text(s, " ")
		session.frames(s, 2)
		testing.expect_value(t, ui.text_edit_string(&app.composer.area), "")
		ui.set_focus(0)
		session.type_text(s, "hi")
		session.frames(s, 2)
		testing.expect_value(t, ui.text_edit_string(&app.composer.area), "hi")
		testing.expect(t, app.composer.focused, "it has the keyboard")
		ui.text_edit_set(&app.composer.area, "")
		ui.set_focus(0)
		palette_toggle(app)
		session.frames(s, 2)
		ui.set_focus(0)
		session.type_text(s, "x")
		session.frames(s, 2)
		testing.expect_value(t, ui.text_edit_string(&app.composer.area), "")
		palette_toggle(app)
	})
}

// A password's field has an eye: it shows the password and hides it again; the dialog opened again hides it.
@(test)
a_password_can_be_shown :: proc(t: ^testing.T) {
	unwatched.run(t, proc(t: ^testing.T) {
		context.allocator = runtime.heap_allocator()
		app, s := bench_app(t)
		server_edit_open(app, -1)
		session.frames(s, 3)
		ui.line_edit_set(&app.server_edit.password, "hunter2")
		session.wait_idle(s)   // (the dialog fades in: a click meanwhile goes through it)
		eye := session.find(s, "reveal")
		if !testing.expect(t, eye != nil, "the password's eye") { return }
		shown :: proc(s: ^session.Session) -> string {   // (what the field draws: the eye is its child)
			eye := session.find(s, "reveal")
			return eye != nil && eye.parent != nil ? (^ui.Line_Edit_Draw)(eye.parent.custom_user).text : ""
		}
		testing.expect_value(t, shown(s), "•••••••")
		session.click(s, "reveal")
		testing.expect(t, app.server_edit.password_shown, "shown")
		testing.expect_value(t, shown(s), "hunter2")
		app.cx.open[.Server] = false
		session.frames(s, 2)
		server_edit_open(app, -1)
		testing.expect(t, !app.server_edit.password_shown, "opened again: hidden")
		app.cx.open[.Server] = false
	})
}

// The chores' one thread, held until a test lets it go: what a click put there waits behind it, in order.
@(private = "file") chores_gate: sync.Sema
@(private = "file") chores_passed: bool

// The servers are tabs at the top of the sidebar: one each, the one connected marked. A click on another connects to it; on the one
// connected, or a right click, the menu of the servers; "+" opens the dialog that adds one. The status bar's bottom left says the link
// and the versions of OpenCode and of this program, and has no server button any more.
@(test)
the_servers_are_tabs_of_the_sidebar :: proc(t: ^testing.T) {
	unwatched.run(t, proc(t: ^testing.T) {
		context.allocator = runtime.heap_allocator()
		app, s := bench_app(t)
		append(&app.servers, Server{name = "Work", url = "http://work:4096"})
		app.server = 1
		app.server_version = strings.clone("1.4.2")
		session.frames(s, 3)
		here, work := session.find(s, "srv_tab0"), session.find(s, "srv_tab1")
		if !testing.expect(t, here != nil && work != nil, "a tab per server") { return }
		testing.expect(t, session.find(s, "srv_tab2") == nil, "no other")
		testing.expect(t, session.find_text(s, "This computer") != nil && session.find_text(s, "Work") != nil, "their names")
		testing.expect(t, here.a11y != nil && !(here.a11y.selected.? or_else true), "this computer's: not the one connected")
		testing.expect(t, work.a11y != nil && (work.a11y.selected.? or_else false), "Work's: the one connected")

		// the status bar: the link and the versions, no server button
		testing.expect(t, session.find(s, "server_btn") == nil, "no server button in the status bar")
		testing.expect(t, session.find_text(s, "OpenCode 1.4.2") != nil, "OpenCode's version")
		testing.expect(t, session.find_text(s, "opencode native " + APP_VERSION) != nil, "this program's version")
		testing.expect(t, session.find_text(s, "connected") != nil, "the link's state")

		// the one connected: its menu, and no connection again
		seq := app.connect_seq
		session.click(s, "srv_tab1")
		testing.expect(t, session.find_text(s, "Edit this server…") != nil, "a click on the one connected: the menu")
		testing.expect_value(t, app.connect_seq, seq)
		session.key(s, .Escape)
		session.wait_idle(s)   // (it fades out)
		testing.expect(t, session.find_text(s, "Edit this server…") == nil, "Escape closes it")
		session.click(s, "srv_tab0", .Right)
		testing.expect(t, session.find_text(s, "Edit this server…") != nil, "a right click on another: the menu")
		session.key(s, .Escape)
		session.wait_idle(s)
		testing.expect_value(t, app.connect_seq, seq)

		// another: connected to (this computer's is found on a chore first: held here, then dropped, so nothing is connected)
		tasks.add(&app.cx.chores, proc(_: rawptr) { sync.sema_wait(&chores_gate) }, nil)
		session.click(s, "srv_tab0")
		testing.expect_value(t, app.connect_seq, seq + 1)
		app.connect_seq += 1   // (what is read is then for an earlier choice: no connection in a test)
		tasks.add(&app.cx.chores, proc(_: rawptr) { sync.atomic_store(&chores_passed, true) }, nil)
		sync.sema_post(&chores_gate)
		session.wait_until(s, proc(s: ^session.Session) -> bool { return sync.atomic_load(&chores_passed) }, "the chores done")
		session.frames(s, 2)
		testing.expect_value(t, app.server, 1)

		// "+": the dialog that adds a server
		session.click(s, "srv_add")
		testing.expect(t, app.cx.open[.Server] && app.server_edit.index == -1, "the dialog that adds a server")
		app.cx.open[.Server] = false
		session.frames(s, 2)
	})
}

// A session archived leaves its section for the last one, Archived, folded until it is opened; brought back, it is where it was.
@(test)
an_archived_session_is_put_away :: proc(t: ^testing.T) {
	unwatched.run(t, proc(t: ^testing.T) {
		context.allocator = runtime.heap_allocator()
		app, s := bench_app(t)
		id := "ses_2"
		ui.line_edit_set(&app.sidebar.search, `"Session 2 about"`)   // (it alone: the end of a long list is not built)
		session.frames(s, 2)
		testing.expect(t, session.find(s, "ls_ses_2") != nil, "listed")
		testing.expect(t, session.find_text(s, "ARCHIVED") == nil, "no Archived section while nothing is")
		session_archive(app, id, true)
		session.frames(s, 3)
		testing.expect(t, session.find(s, "ls_ses_2") == nil, "out of its section; Archived is folded")
		header := session.find_text(s, "ARCHIVED")
		if !testing.expect(t, header != nil, "the Archived section") { return }
		secs := sidebar_sections(app, sidebar_rows(app, ""), app.prefs.sidebar_mode)
		last := secs[len(secs) - 1]
		testing.expect(t, last.title == ARCHIVED_TITLE && len(last.items) == 1 && app.sessions[last.items[0]].id == id, "the last section, with it alone")
		app.sidebar.folded[last.key] = false   // (opened, as its header's click does)
		session.frames(s, 3)
		testing.expect(t, session.find(s, "ls_ses_2") != nil, "opened: it shows")
		session_archive(app, id, false)
		session.frames(s, 3)
		testing.expect(t, session.find(s, "ls_ses_2") != nil, "back in its section")
		testing.expect(t, session.find_text(s, "ARCHIVED") == nil, "nothing archived: no section")
		ui.line_edit_set(&app.sidebar.search, "")
	})
}

// Archived from the list, the pointer still on it: the row leaves its section at once (the list held under the pointer is
// for what changes by itself, not for what the person just did).
@(test)
a_session_archived_under_the_pointer_leaves_at_once :: proc(t: ^testing.T) {
	unwatched.run(t, proc(t: ^testing.T) {
		context.allocator = runtime.heap_allocator()
		app, s := bench_app(t)
		ui.line_edit_set(&app.sidebar.search, `"Session 2 about"`)
		session.frames(s, 2)
		row := session.find(s, "ls_ses_2")
		if !testing.expect(t, row != nil, "listed") { return }
		at := session.center(row)
		session.move(s, at)
		session.move(s, at + {2, 0})
		session.frames(s, 2)
		testing.expect(t, app.sidebar.hold.on, "the list is held under the pointer")
		session_archive(app, "ses_2", true)
		session.move(s, at + {4, 0})   // (the pointer moves on over the list: the hold goes on)
		session.frames(s, 2)
		testing.expect(t, session.find(s, "ls_ses_2") == nil, "out of its section at once; Archived is folded")
		testing.expect(t, session.find_text(s, "ARCHIVED") != nil, "the Archived section")
		session_archive(app, "ses_2", false)
		session.move(s, at + {6, 0})
		session.frames(s, 2)
		testing.expect(t, session.find(s, "ls_ses_2") != nil, "brought back: at once too")
		ui.line_edit_set(&app.sidebar.search, "")
	})
}

// Past the time the limit resets, the goal is still paused (the server waits for a word): the line says the limit reset, and
// offers to resume it. Before, it says when, and offers nothing.
@(test)
a_goal_paused_past_its_reset_offers_to_resume :: proc(t: ^testing.T) {
	unwatched.run(t, proc(t: ^testing.T) {
		context.allocator = runtime.heap_allocator()
		app, s := bench_app(t)
		paused :: proc(app: ^App, at: string) {
			v, _ := json.parse_string(fmt.tprintf(`{{"objective":"Booted OS","status":"paused","reason":"The session failed: limit. Resets at %s.","rounds":0,"maxRounds":50}}`, at), allocator = context.temp_allocator)
			goal_set(app, app.chat.id, v)
		}
		paused(app, "2000-01-01T00:00:00.000Z")
		chat_scroll_event(app, Scroll_Signal.Snap)
		session.wait_idle(s)
		testing.expect(t, session.find(s, "gw_resume") != nil, "past: resume offered")
		when_ := session.find(s, "when")
		testing.expect(t, when_ != nil && strings.contains(when_.text, "limit reset at"), "the limit reset")
		paused(app, "2999-01-01T00:00:00.000Z")
		session.frames(s, 2)
		testing.expect(t, session.find(s, "gw_resume") == nil, "not yet: nothing offered")
		goal_set(app, app.chat.id, nil)
	})
}

// Escape in the composer while a turn runs stops it, and the composer keeps the keyboard; with nothing running, it lets go of it.
@(test)
escape_stops_the_run_and_the_composer_keeps_the_keyboard :: proc(t: ^testing.T) {
	unwatched.run(t, proc(t: ^testing.T) {
		context.allocator = runtime.heap_allocator()
		app, s := bench_app(t)
		set_busy(app, app.chat.id, true)
		session.click(s, "composer")
		session.type_text(s, "wait, ")
		testing.expect_value(t, session.focused_name(s), "composer")
		session.key(s, .Escape)
		session.frames(s, 2)
		testing.expect_value(t, session.focused_name(s), "composer")   // (still writing)
		session.type_text(s, "no")
		testing.expect_value(t, ui.text_edit_string(&app.composer.area), "wait, no")
		app.chat.busy = false
		delete_key(&app.busy, app.chat.id)
		session.key(s, .Escape)
		session.frames(s, 2)
		testing.expect(t, session.focused_name(s) != "composer", "nothing runs: it lets go")
		ui.text_edit_set(&app.composer.area, "")
	})
}

// Where the window is is kept when it changes, and the window opens there again: an update's restart, on two monitors, puts it
// back where it was.
@(test)
the_window_opens_where_it_was :: proc(t: ^testing.T) {
	unwatched.run(t, proc(t: ^testing.T) {
		context.allocator = runtime.heap_allocator()
		app, _ := bench_app(t)
		platform.set_placement(app.win, {{-1700, 120, 1400, 900}, false})   // (the monitor on the left)
		app.cx.placement_ms = -PLACEMENT_CHECK_MS   // (looked at long ago)
		placement_track(app)
		testing.expect_value(t, config.string_of(&app.cfg_prefs, "window.placement"), "-1700 120 1400 900")
		// another start: the window opens elsewhere, the placement kept puts it back
		platform.set_placement(app.win, {{0, 0, 800, 600}, false})
		placement_restore(app)
		testing.expect_value(t, platform.get_placement(app.win), platform.Placement{{-1700, 120, 1400, 900}, false})
		// maximized there (as by its title bar: set_placement on Windows keeps it for show_window)
		platform.toggle_maximize(app.win)
		app.cx.placement_ms = -PLACEMENT_CHECK_MS   // (looked at long ago)
		placement_track(app)
		testing.expect_value(t, config.string_of(&app.cfg_prefs, "window.placement"), "-1700 120 1400 900 maximized")
		// unchanged: nothing written again
		app.cx.placement_ms = -PLACEMENT_CHECK_MS   // (looked at long ago)
		before := app.cx.placement_seen
		placement_track(app)
		testing.expect(t, app.cx.placement_seen == before, "the same: kept as it was")
	})
}

// A ```mermaid block is drawn as its diagram, the header's button shows its text and back; one still being written shows its text,
// and a text that is no diagram says why.
@(private = "file")
mermaid_page :: proc() -> string {
	t := BENCH_EPOCH_MS
	answer :: proc(id, text: string, at: f64) -> string {
		return fmt.tprintf(`{{"id":"%s","type":"assistant","agent":"build","model":{{"id":"m","providerID":"p"}},"finish":"stop","time":{{"created":%f,"completed":%f}},"content":[{{"type":"text","text":%s}}]}}`, id, at, at + 1, jquote(text))
	}
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, `{{"data":[%s,%s,%s,`, answer("mm_3", "Still writing:\n\n```mermaid\nflowchart LR\n  X --> Y\n", t + 30), answer("mm_2", "Not one:\n\n```mermaid\nthis is no diagram\n```\n", t + 20), answer("mm_1", "Here:\n\n```mermaid\nflowchart LR\n  A[Open the session] --> B{Busy?}\n  B -->|yes| C[Steer]\n  B -->|no| D[Send]\n```\n", t + 10))
	fmt.sbprintf(&b, `{{"id":"mm_u","type":"user","text":"Draw it","time":{{"created":%f}}}}],"cursor":{{"next":""}}}}`, t)
	return strings.to_string(b)
}

@(test)
a_mermaid_block_is_a_diagram :: proc(t: ^testing.T) {
	unwatched.run(t, proc(t: ^testing.T) {
		context.allocator = runtime.heap_allocator()
		app, s := bench_app(t)
		v, err := json.parse_string(mermaid_page(), allocator = context.temp_allocator)
		testing.expect(t, err == nil)
		chat_load(app, v, false)
		chat_scroll_event(app, Scroll_Signal.Snap)
		session.wait_idle(s)
		diagrams := 0
		for i := 0; session.find(s, "diagram", i) != nil; i += 1 { diagrams += 1 }
		testing.expect_value(t, diagrams, 1)   // (the closed one that is a diagram)
		d := session.find(s, "diagram")
		if !testing.expect(t, d != nil, "drawn") { return }
		testing.expect(t, d.rect.max.x - d.rect.min.x > 200 && d.rect.max.y - d.rect.min.y > 40, "at a readable size")
		testing.expect(t, session.find_text(s, "not a diagram", 0) != nil || session.find(s, "why") != nil, "the one that is not says why")
		session.save_png(s, "mermaid.png")
		// its text, and back
		session.click(s, "as_text")
		session.wait_idle(s)
		testing.expect(t, session.find(s, "diagram") == nil, "its text instead")
		session.click(s, "as_text")
		session.wait_idle(s)
		testing.expect(t, session.find(s, "diagram") != nil, "the diagram again")
		diagrams_free(app)
	})
}

// A diagram opens in its viewer on a click, larger than in the conversation: Ctrl and the wheel zoom it where the pointer is,
// the wheel and a drag move it, 0 fits it again; laid out from top to bottom, it is taller than wide; its menu copies it as a
// picture, at twice its size in the conversation, on the colour of code.
@(test)
a_diagram_is_zoomed_moved_and_laid_out_in_the_viewer :: proc(t: ^testing.T) {
	unwatched.run(t, proc(t: ^testing.T) {
		context.allocator = runtime.heap_allocator()
		app, s := bench_app(t)
		defer diagrams_free(app)
		v, err := json.parse_string(mermaid_page(), allocator = context.temp_allocator)
		testing.expect(t, err == nil)
		chat_load(app, v, false)
		chat_scroll_event(app, Scroll_Signal.Snap)
		session.wait_idle(s)
		if !testing.expect(t, session.find(s, "diagram") != nil, "drawn") { return }
		small := session.find(s, "diagram").rect
		session.click(s, "diagram")
		session.wait_idle(s)
		dv := &app.diagram_view
		testing.expect(t, app.cx.open[.Diagram] && dv.code != "", "a click opens the viewer on it")
		testing.expect_value(t, dv.own, mermaid.Direction.Left_Right)
		view := session.find(s, "dv_view")
		if !testing.expect(t, view != nil, "the view") { return }
		testing.expect(t, app.state.focus_key == view.key, "the view has the keyboard")
		vs := view.rect.max - view.rect.min
		testing.expectf(t, vs.x > small.max.x - small.min.x, "larger than in the conversation: %v", vs)
		at := session.center(view) + {30, 10}
		session.move(s, at)
		session.wheel(s, at, {0, -3}, {.Ctrl})
		session.frames(s, 2)
		testing.expectf(t, dv.preview.zoom > 1.9, "Ctrl and the wheel zoom: %v", dv.preview.zoom)
		testing.expectf(t, dv.preview.pan.x < 0 || dv.preview.pan.y < 0, "toward the pointer: %v", dv.preview.pan)
		session.save_png(s, "diagram_viewer.png")
		from := dv.preview.pan
		session.wheel(s, at, {0, 1})
		session.frames(s, 2)
		testing.expect(t, dv.preview.pan != from, "the wheel moves it")
		from = dv.preview.pan
		c := session.center(view)
		session.press(s, c)
		session.move(s, c + {20, 10})
		session.move(s, c + {40, 20})
		session.release(s, c + {40, 20})
		session.frames(s, 2)
		testing.expectf(t, dv.preview.pan != from, "a drag moves it: %v from %v", dv.preview.pan, from)
		session.event(s, {kind = .Key_Press, key = .N0})
		session.frames(s, 2)
		testing.expect(t, dv.preview.zoom == 1 && dv.preview.pan == {}, "0: back to what fits")

		dv.direction = .Top_Down
		session.wait_until(s, proc(s: ^session.Session) -> bool {
			app := the_app
			return app.diagram_view.shown == diagram_key(app.diagram_view.code, !app.cx.theme.light, .Top_Down)
		}, "the layout from top to bottom")
		tall := diagram_laid_out(app, dv.code, !app.cx.theme.light, .Top_Down)
		if !testing.expect(t, tall != nil && tall.why == "", "laid out") { return }
		testing.expectf(t, tall.doc.view[3] > tall.doc.view[2], "from top to bottom, taller than wide: %v", tall.doc.view)
		session.save_png(s, "diagram_viewer_top_down.png")

		session.click_at(s, session.center(view), .Right)
		session.frames(s, 2)
		testing.expect(t, session.find_text(s, "Copy as PNG") != nil, "Copy as PNG")
		testing.expect(t, session.find_text(s, "Copy the text") != nil, "Copy the text")
		session.event(s, {kind = .Key_Press, key = .Escape})
		session.frames(s, 2)
		pic, ok := diagram_picture(app, dv.code, dv.direction)
		defer paint.canvas_destroy(&pic)
		if !testing.expect(t, ok, "its picture") { return }
		want := tall.doc.view[2] * DIAGRAM_COPY_SCALE * diagram_scale(ui.font_size())
		testing.expectf(t, abs(f32(pic.width) - math.ceil(want)) < 1, "the layout shown, twice its size: %d for %v", pic.width, want)
		well := themed(HEX_CODE_WELL)
		testing.expectf(t, abs(pic.pixels[0].r - f32(well >> 24) / 255) < 0.01, "on the colour of code: %v", pic.pixels[0])
		inked := 0
		for p in pic.pixels { if abs(p.r - pic.pixels[0].r) + abs(p.g - pic.pixels[0].g) > 0.1 { inked += 1 } }
		testing.expectf(t, inked > len(pic.pixels) / 50, "its boxes, lines and words: %d", inked)
		session.event(s, {kind = .Key_Press, key = .Escape})
		session.frames(s, 3)
		testing.expect(t, !app.cx.open[.Diagram], "Escape closes it")
	})
}

// A row is square: the ground of the session shown reaches the corners of its row (a rounded one left the sidebar's colour
// there).
@(test)
the_session_shown_is_a_square_row :: proc(t: ^testing.T) {
	unwatched.run(t, proc(t: ^testing.T) {
		context.allocator = runtime.heap_allocator()
		_, s := bench_app(t)
		session.wait_idle(s)
		row: ^ui.Box
		for i := 0; ; i += 1 {
			b := session.find(s, "item", i)
			if b == nil { break }
			if b.custom == item_draw && (^Item_Draw)(b.custom_user).selected { row = b; break }
		}
		if !testing.expect(t, row != nil, "the row of the session shown") { return }
		img := session.capture(s)
		corner := session.pixel(img, int(row.rect.min.x) + 1, int(row.rect.min.y) + 1)
		inside := session.pixel(img, int(row.rect.min.x) + 1, int((row.rect.min.y + row.rect.max.y) * 0.5))
		testing.expectf(t, session.near(corner, inside, 6), "its corner is its ground: %v, %v", corner, inside)
	})
}

// A search of the sessions lights what it found in their titles: "frame" in "...frame pacing"; a word found in another
// field (the folder) lights nothing there.
@(test)
the_sessions_search_lights_what_it_found :: proc(t: ^testing.T) {
	unwatched.run(t, proc(t: ^testing.T) {
		context.allocator = runtime.heap_allocator()
		app, s := bench_app(t)
		lit_titles :: proc(s: ^session.Session) -> (lit, all: int) {
			for i := 0; ; i += 1 {
				b := session.find(s, "t", i)
				if b == nil { break }
				if !strings.contains(ui.box_text(b), "frame pacing") { continue }
				all += 1
				if b.custom != nil { lit += 1 }
			}
			return
		}
		ui.line_edit_set(&app.sidebar.search, "FRAME project_3")
		session.frames(s, 3)
		lit, all := lit_titles(s)
		testing.expectf(t, all > 0 && lit == all, "the titles found are lit: %d of %d", lit, all)
		ui.line_edit_set(&app.sidebar.search, "")
		session.frames(s, 3)
		lit, all = lit_titles(s)
		testing.expectf(t, all > 0 && lit == 0, "no search, nothing lit: %d of %d", lit, all)
	})
}

// The wheel turned notch after notch keeps a shell's grid as it is (each new size would rewrap its whole scrollback); at rest,
// the grid takes the columns of its new cells.
@(test)
a_shells_zoom_rewraps_once_at_rest :: proc(t: ^testing.T) {
	unwatched.run(t, proc(t: ^testing.T) {
		context.allocator = runtime.heap_allocator()
		app, s := bench_app(t)
		if app.conn == nil { app.conn = bench_conn(app) }
		clear(&bench_sent)
		terminal_toggle(app)
		bench_answer(app, bench_take(t, .Pty_List), 200, `{"data":[{"id":"a","title":"bash","status":"running"}]}`)
		for sh in app.cx.terms.list { term_link_set(app, sh, .Attached) }
		bench_clear(app)
		if !testing.expect(t, len(app.cx.terms.list) == 1, "a shell") { return }
		sh := app.cx.terms.list[0]
		session.wait_idle(s)
		cols := sh.view.cols
		at := session.center(session.get(s, "term_box"))
		for _ in 0 ..< 3 {
			session.event(s, {kind = .Scroll, pos = at, delta = {0, -1}, mods = {.Ctrl}})
			session.frames(s, 1)
			session.advance(s, term.ZOOM_REST_MS * 0.5)
		}
		testing.expectf(t, sh.view.zoom > 1.3, "zoomed in: %v", sh.view.zoom)
		testing.expect_value(t, sh.view.cols, cols)
		session.advance(s, term.ZOOM_REST_MS * 2)
		session.wait_idle(s)
		testing.expectf(t, sh.view.cols < cols, "at rest, fewer columns of bigger cells: %d, then %d", cols, sh.view.cols)
	})
}

// The palette's keys at its foot are apart from the list, by a line as the field is: the field, its line, the list, a line,
// the keys.
@(test)
the_palettes_keys_are_apart_from_its_list :: proc(t: ^testing.T) {
	unwatched.run(t, proc(t: ^testing.T) {
		context.allocator = runtime.heap_allocator()
		app, s := bench_app(t)
		palette_toggle(app)
		session.frames(s, 3)
		list, rule, foot := session.find(s, "pal_list"), session.find(s, "pal_foot_rule"), session.find(s, "pal_foot")
		if testing.expect(t, list != nil && rule != nil && foot != nil, "the list, a line, the keys") {
			testing.expect(t, rule.rect.min.y >= list.rect.max.y - 0.5 && rule.rect.max.y <= foot.rect.min.y + 0.5, "the line between them")
		}
		palette_toggle(app)
	})
}

// A shell's scroll bar is the toolkit's: it is there once the scrollback is longer than the grid, and its thumb dragged up
// moves the grid's view up the scrollback (the press is the bar's, not the shell's selection).
@(test)
a_shells_scroll_bar_can_be_dragged :: proc(t: ^testing.T) {
	unwatched.run(t, proc(t: ^testing.T) {
		context.allocator = runtime.heap_allocator()
		app, s := bench_app(t)
		if app.conn == nil { app.conn = bench_conn(app) }
		clear(&bench_sent)
		terminal_toggle(app)
		bench_answer(app, bench_take(t, .Pty_List), 200, `{"data":[{"id":"a","title":"bash","status":"running"}]}`)
		for sh in app.cx.terms.list { term_link_set(app, sh, .Attached) }
		bench_clear(app)
		if !testing.expect(t, len(app.cx.terms.list) == 1, "a shell") { return }
		sh := app.cx.terms.list[0]
		b := strings.builder_make(context.temp_allocator)
		for i in 0 ..< 200 { fmt.sbprintf(&b, "line %d\r\n", i) }
		term_feed(sh, strings.to_string(b))
		session.wait_idle(s)
		box := session.get(s, "term_box")
		_, thumb, ok := ui.scrollbar_rects(box)
		if !testing.expect(t, ok, "a scroll bar") { return }
		bar: Vt_Scrollbar
		ghostty_terminal_get(sh.vt, VT_DATA_SCROLLBAR, &bar)
		at_bottom := bar.offset
		from := (thumb.min + thumb.max) * 0.5
		session.move(s, from)
		session.event(s, {kind = .Mouse_Press, button = .Left, pos = from})
		session.frames(s, 1)
		to := [2]f32{from.x, box.rect.min.y + 2}
		session.move(s, to)
		session.frames(s, 2)
		session.event(s, {kind = .Mouse_Release, button = .Left, pos = to})
		session.wait_idle(s)
		ghostty_terminal_get(sh.vt, VT_DATA_SCROLLBAR, &bar)
		testing.expectf(t, bar.offset < at_bottom / 2, "the view went up the scrollback: %d, then %d", at_bottom, bar.offset)
		testing.expect(t, !term.has_selection(&sh.view), "no selection made by that press")
	})
}

// A recent folder of the home page shows only its name: its whole path is in its tooltip, and its menu copies it.
@(test)
a_recent_folder_tells_and_copies_its_path :: proc(t: ^testing.T) {
	unwatched.run(t, proc(t: ^testing.T) {
		context.allocator = runtime.heap_allocator()
		app, s := bench_app(t)
		chat_home(app)
		session.wait_until(s, proc(s: ^session.Session) -> bool { return session.find(s, "hf0") != nil }, "the recent folders built")
		session.wait_idle(s)   // (the home page comes in where the chat was: the folder stands still before the pointer goes to it)
		path := strings.clone(home_folders(app)[0], context.temp_allocator)
		testing.expect(t, session.find_text(s, path) == nil, "the path is not shown at rest")
		session.hover(s, "hf0")
		session.advance(s, f64(ui.FEEL_DEFAULT.tooltip_delay_ms) + 100)
		session.save_png(s, "folder_tooltip.png")
		testing.expect(t, session.find_text(s, path) != nil, "the tooltip says the whole path")
		session.click(s, "hf0", .Right)
		session.frames(s, 2)
		testing.expect(t, ui.menu_any_open(), "its menu")
		session.click_text(s, "Copy the path")
		session.frames(s, 2)
		testing.expect_value(t, session.clipboard(s), path)
	})
}

// Other folder… of the home page, with a server elsewhere: the dialog of the server's folders. A folder clicked is entered, and
// Choose this folder makes it the new session's.
@(test)
other_folder_browses_the_servers_folders :: proc(t: ^testing.T) {
	unwatched.run(t, proc(t: ^testing.T) {
		context.allocator = runtime.heap_allocator()
		app, s := bench_app(t)
		app.conn = bench_conn(app)
		defer { bench_clear(app); app.conn = nil }
		chat_home(app)
		session.wait_until(s, proc(s: ^session.Session) -> bool { return session.find(s, "hf_other") != nil }, "the home page built")
		session.wait_idle(s)
		session.click(s, "hf_other")
		session.frames(s, 2)
		testing.expect(t, app.cx.open[.Folders], "the server's folders")
		r := bench_take(t, .Folders_List)
		testing.expect_value(t, r.path, "/api/fs/list?path=C%3A%2Fcode%2Fproject_0")
		bench_answer(app, r, 200, `{"data":[{"path":"assets","type":"directory"},{"path":"src","type":"directory"},{"path":"README.md","type":"file"}]}`)
		session.wait_idle(s)
		testing.expect(t, session.find_text(s, "README.md") == nil, "no file")
		session.save_png(s, "server_folders.png")
		session.click(s, "for1")
		session.frames(s, 2)
		testing.expect_value(t, app.cx.folders.at, "C:/code/project_0/src")
		bench_answer(app, bench_take(t, .Folders_List), 200, `{"data":[]}`)
		session.frames(s, 2)
		testing.expect(t, session.find(s, "fo_none") != nil, "an empty folder says so")
		session.click(s, "fo_choose")
		session.frames(s, 2)
		testing.expect(t, !app.cx.open[.Folders], "closed")
		testing.expect_value(t, app.chat.new_dir, "C:/code/project_0/src")
	})
}

// A long session opened shows its bottom in the first frame after its page came: it showed an empty view for a frame (the lazy
// column placed its messages from where the view was before it jumped), then a place above the bottom (what that build measured
// moved the bottom).
@(test)
a_session_opens_at_its_bottom_in_its_first_frame :: proc(t: ^testing.T) {
	unwatched.run(t, proc(t: ^testing.T) {
		context.allocator = runtime.heap_allocator()
		app, s := bench_app(t)
		if app.conn == nil { app.conn = bench_conn(app) }
		session.wait_idle(s)
		open_chat(app, "ses_3")
		session.frames(s, 2)
		bench_answer(app, bench_take(t, .Messages), 200, bench_page())
		session.frames(s, 1)
		testing.expect(t, session.find(s, fmt.tprintf("msg_msg_%d_a", BENCH_TURNS - 1)) != nil, "its last answer built")
		sb := session.get(s, "chat")
		testing.expectf(t, sb.view_off.y >= ui.view_limit(sb) - 1, "at its bottom: %v of %v", sb.view_off.y, ui.view_limit(sb))
		testing.expectf(t, ui.view_limit(sb) > f32(BENCH_TURNS) * sb.size.y * 0.5, "the bottom of its whole length: %v", ui.view_limit(sb))
	})
}

// The palette over hundreds of sessions builds the rows in view only, and at rest makes nothing again: it built two hundred
// rows and matched and ranked every item at each frame, the pointer moving over it enough. A session that comes makes the list again.
@(test)
the_palette_at_rest_builds_only_its_rows_in_view :: proc(t: ^testing.T) {
	unwatched.run(t, proc(t: ^testing.T) {
		context.allocator = runtime.heap_allocator()
		app, s := bench_app(t)
		command_run(app, command_find("app.palette"))
		session.frames(s, 3)
		ui.line_edit_set(&app.palette.field, "@")
		session.frames(s, 3)
		found := len(app.palette.hits)
		testing.expectf(t, found >= 300, "the sessions found: %d", found)
		rows := 0
		list := session.find(s, "pal_list")
		if testing.expect(t, list != nil, "the list") {
			for c := list.first; c != nil; c = c.next { if strings.has_prefix(c.name, "###lrow_") || strings.contains(c.name, "lrow_") { rows += 1 } }
		}
		testing.expectf(t, rows > 5 && rows < 60, "the rows in view and a margin: %d built", rows)
		stamp, kept := app.palette.stamp, raw_data(app.palette.hits)
		for i in 0 ..< 4 {
			session.move(s, {800 + f32(i % 2), 120})
			session.frames(s, 1)
		}
		testing.expect_value(t, app.palette.stamp, stamp)
		testing.expect(t, raw_data(app.palette.hits) == kept, "the same hits: not ranked again")
		append(&app.sessions, Session_Info{id = "ses_new", title = "A session that just came", directory = "C:/code/new"})
		sessions_changed(app)
		session.frames(s, 2)
		testing.expect_value(t, len(app.palette.hits), found + 1)
		app.cx.open[.Palette] = false
		session.frames(s, 2)
	})
}

// The palette's search is on a field's background, the very colour of a menu's search band: it was the dialog's own colour
// (the toolkit's strip took the box's background, which in a dialog is the dialog's), lighter than the menu's. (Dark, as the
// request was: the system's mode, which "system" follows, is the machine's.)
@(test)
the_palettes_search_is_a_menus_search_band :: proc(t: ^testing.T) {
	unwatched.run(t, proc(t: ^testing.T) {
		context.allocator = runtime.heap_allocator()
		app, s := bench_app(t)
		pref_set(app, "appearance.theme", "OpenCode")
		pref_set(app, "appearance.mode", "dark")
		defer pref_set(app, "appearance.mode", "system")
		command_run(app, command_find("app.palette"))
		session.frames(s, 3)
		// a menu over it, something typed in it: its search band shows
		ui.menu_open("app_menu", ui.Vec2{900, 300})
		session.frames(s, 3)
		session.event(s, {kind = .Text, text = 's'})
		session.frames(s, 3)
		top, band, list := session.find(s, "pal_top"), session.find(s, "menu_search"), session.find(s, "pal_list")
		if !testing.expect(t, top != nil && band != nil && list != nil, "the palette's strip, the menu's band, the list") { return }
		img := session.capture(s)
		at :: proc(img: session.Image, b: ^ui.Box) -> session.Color { return session.pixel(img, int(b.rect.min.x) + 6, int((b.rect.min.y + b.rect.max.y) * 0.5)) }
		strip, menu, dialog := at(img, top), at(img, band), at(img, list)
		testing.expectf(t, session.near(strip, menu, 2), "the strip %v, the menu's band %v", strip, menu)
		testing.expectf(t, !session.near(strip, dialog, 4), "the strip %v apart from the dialog %v", strip, dialog)
		ui.menu_close()
		app.cx.open[.Palette] = false
		session.frames(s, 2)
	})
}

// A button says what it does by its colour, the toolkit's soft pair of its intent's hue: the delete dialog's Delete is red
// (Danger), the rename dialog's Rename its Primary; their Cancel a plain face, untinted (only the act carries an intent). Flat, so the middle of a face is its
// fill; dark, as the request was (Windows' CI is light).
@(test)
a_buttons_colour_says_what_it_does :: proc(t: ^testing.T) {
	unwatched.run(t, proc(t: ^testing.T) {
		context.allocator = runtime.heap_allocator()
		app, s := bench_app(t)
		pref_set(app, "appearance.theme", "OpenCode")
		pref_set(app, "appearance.mode", "dark")
		defer pref_set(app, "appearance.mode", "system")
		pref_set(app, "appearance.finish", "flat")
		defer pref_set(app, "appearance.finish", "machined")
		face :: proc(t: ^testing.T, s: ^session.Session, name: string, intent: ui.Intent) {
			b := session.find(s, name)
			if !testing.expectf(t, b != nil, "the button %s", name) { return }
			if intent == .Neutral {
				// (no intent, no tint: a plain face, grey, as any button's)
				img := session.capture(s)
				got := session.pixel(img, int(b.rect.min.x) + 4, int((b.rect.min.y + b.rect.max.y) * 0.5))
				d := max(abs(int(got.r) - int(got.g)), abs(int(got.g) - int(got.b)), abs(int(got.r) - int(got.b)))
				testing.expectf(t, d <= 3, "%s (neutral): its face %v, not tinted", name, got)
				return
			}
			hue := ui.hue_color(ui.intent_hue(intent))
			hue.a = 1
			fill, _ := ui.soft_pair(hue)
			to8 :: proc(x: f32) -> u8 { return u8(clamp(render.linear_to_srgb(clamp(x, 0, 1)) * 255 + 0.5, 0, 255)) }
			want := session.Color{to8(fill.r), to8(fill.g), to8(fill.b), 255}
			img := session.capture(s)
			got := session.pixel(img, int(b.rect.min.x) + 4, int((b.rect.min.y + b.rect.max.y) * 0.5))
			testing.expectf(t, session.near(got, want, 3), "%s (%v): its face %v, the soft fill %v", name, intent, got, want)
		}
		session.leave(s)   // (a face under the pointer is lit: not its fill)
		app.cx.open[.Delete] = true
		session.wait_idle(s)
		face(t, s, "confirm_act", .Danger)
		face(t, s, "confirm_cancel", .Neutral)   // (a Cancel is neutral: only the act carries its intent)
		app.cx.open[.Delete] = false
		session.frames(s, 2)
		rename_open(app, "ses_colour")
		session.wait_idle(s)
		face(t, s, "prompt_ok", .Primary)
		face(t, s, "prompt_cancel", .Neutral)
		app.cx.open[.Rename] = false
		session.frames(s, 2)
	})
}

// The palette's arrows move its selection: they are read inside its dialog, which holds the keys while it is open.
@(test)
the_palette_arrows_move_the_selection :: proc(t: ^testing.T) {
	unwatched.run(t, proc(t: ^testing.T) {
		context.allocator = runtime.heap_allocator()
		app, s := bench_app(t)
		command_run(app, command_find("app.palette"))
		session.frames(s, 3)
		testing.expect_value(t, app.palette.vl.sel, 0)
		session.key(s, .Down)
		session.frames(s, 2)
		testing.expect_value(t, app.palette.vl.sel, 1)
		session.key(s, .Down)
		session.key(s, .Up)
		session.frames(s, 2)
		testing.expect_value(t, app.palette.vl.sel, 1)
		session.key(s, .Up)
		session.frames(s, 2)
		testing.expect_value(t, app.palette.vl.sel, 0)
		app.cx.open[.Palette] = false
		session.frames(s, 2)
	})
}

// A paste in the composer asks the clipboard and waits for nothing: text goes in at the caret (Ctrl+V, Shift+Insert), an image
// without text is attached, files are attached, each once its answers came at a later frame.
@(test)
a_paste_in_the_composer_waits_for_no_clipboard :: proc(t: ^testing.T) {
	unwatched.run(t, proc(t: ^testing.T) {
		context.allocator = runtime.heap_allocator()
		app, s := bench_app(t)
		session.click(s, "composer")
		ui.text_edit_set(&app.composer.area, "")
		session.set_clipboard(s, "pasted words")
		session.key(s, .Insert, {.Shift})
		session.wait_until(s, proc(s: ^session.Session) -> bool { return ui.text_edit_string(&(^App)(s.user).composer.area) != "" }, "the text came")
		testing.expect_value(t, ui.text_edit_string(&app.composer.area), "pasted words")
		// an image alone: attached, read and encoded on a thread
		px := []u8{255, 0, 0, 255, 0, 0, 255, 255}
		testing.expect(t, platform.clipboard_set_image(app.win, {rgba = px, size = {2, 1}}))
		session.key(s, .V, {.Ctrl})
		session.wait_until(s, proc(s: ^session.Session) -> bool { return len((^App)(s.user).composer.attachments) == 1 }, "the image attached")
		testing.expect(t, strings.has_prefix(app.composer.attachments[0].uri, "data:image/png;base64,"), "as a PNG")
		testing.expect_value(t, ui.text_edit_string(&app.composer.area), "pasted words")
	})
}

// The composer's menu (Undo, Cut, Copy, Paste, Select all) comes on all of the composer, its focus there or not: the last
// message, which the conversation scrolls under it, does not take the press.
@(test)
the_composer_has_its_menu_all_over_it :: proc(t: ^testing.T) {
	unwatched.run(t, proc(t: ^testing.T) {
		context.allocator = runtime.heap_allocator()
		app, s := bench_app(t)
		testing.expect(t, !app.composer.focused, "the focus elsewhere")
		well := session.get(s, "composer_well")
		for at in ([][2]f32{session.center(session.get(s, "composer")), {well.rect.max.x - 40, well.rect.max.y - 6}}) {
			session.press(s, at, .Right)
			session.release(s, at, .Right)
			session.frames(s, 3)
			testing.expectf(t, ui.menu_any_open() && app.ctx_menu.target.kind == .Composer, "the composer's menu at %v, not %v's", at, app.ctx_menu.target.kind)
			testing.expect(t, session.find_text(s, "Paste") != nil && session.find_text(s, "Select all") != nil, "its actions")
			session.key(s, .Escape)
			session.frames(s, 2)
		}
	})
}

// A command at work can be inspected from its row, as a background one can from the tray: its output, as it prints it.
@(test)
a_running_command_is_inspected_from_its_row :: proc(t: ^testing.T) {
	unwatched.run(t, proc(t: ^testing.T) {
		context.allocator = runtime.heap_allocator()
		app, s := bench_app(t)
		// (the last call of the conversation, a command at work)
		call: ^Part
		#reverse for &m in app.chat.messages {
			#reverse for &p in m.parts { if p.kind == .Tool { call = &p; break } }
			if call != nil { break }
		}
		if !testing.expect(t, call != nil, "a call") { return }
		call.tool_name = strings.clone("bash", app.chat.alloc)
		call.status = .Running
		call.shell_id = strings.clone("sh_7", app.chat.alloc)
		app.chat.seq += 1
		session.wait_until(s, proc(s: ^session.Session) -> bool { return session.find(s, "bginspect") != nil }, "its row says it can be inspected")
		testing.expect(t, session.find(s, "bgpush") != nil, "and pushed to the background")
		session.wait_idle(s)   // (the conversation follows its end, which the row made longer: what is clicked stands still)
		session.click(s, "bginspect")
		session.frames(s, 2)
		v := app.cx.outputs.shown
		testing.expect(t, v != nil && v.shell == "sh_7", "its output, in its view")
	})
}

// Two sub-agents that ended: one done, one failed, their calls folded.
@(private = "file")
ended_subagents_page :: proc() -> string {
	t := BENCH_EPOCH_MS
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, `{{"data":[`)
	fmt.sbprintf(&b, `{{"id":"sg_1_a","type":"assistant","agent":"build","model":{{"id":"m","providerID":"p"}},"finish":"stop","time":{{"created":%f,"completed":%f}},"content":[`, t + 10, t + 200_000)
	fmt.sbprintf(&b, `{{"type":"tool","id":"call_ok","name":"subagent","state":{{"status":"completed","input":{{"agent":"explore","description":"Find the loaders","prompt":"go"}},"content":[{{"type":"text","text":"Found three loaders.\nThe second one reads the formats."}}]}},"time":{{"created":%f,"completed":%f}}}},`, t + 11, t + 11 + 133_000)
	fmt.sbprintf(&b, `{{"type":"tool","id":"call_ko","name":"subagent","state":{{"status":"error","input":{{"agent":"general","description":"Read the formats","prompt":"go"}},"error":{{"message":"The model refused."}}}},"time":{{"created":%f,"completed":%f}}}}`, t + 12, t + 12 + 133_000)
	fmt.sbprintf(&b, `]}},{{"id":"sg_1_u","type":"user","text":"Look.","time":{{"created":%f}}}}`, t)
	strings.write_string(&b, `],"cursor":{"next":""}}`)
	return strings.to_string(b)
}

// The box named `name` in the tree of `b`, nil: none.
@(private = "file")
named_under :: proc(s: ^session.Session, b: ^ui.Box, name: string) -> ^ui.Box {
	if b == nil || !ui.box_current(s.state, b) { return nil }
	if b.name == name { return b }
	for c := b.first; c != nil; c = c.next { if r := named_under(s, c, name); r != nil { return r } }
	return nil
}

// A sub-agent that ended says so on its folded card: the sign of its state on its mark, the word of its state before its time,
// and the first line of what it handed back (a failure's, its error).
@(test)
a_finished_sub_agent_says_so_folded :: proc(t: ^testing.T) {
	unwatched.run(t, proc(t: ^testing.T) {
		context.allocator = runtime.heap_allocator()
		app, s := bench_app(t)
		v, err := json.parse_string(ended_subagents_page(), allocator = context.temp_allocator)
		testing.expect(t, err == nil)
		chat_load(app, v, false)
		chat_scroll_event(app, Scroll_Signal.Snap)
		session.wait_idle(s)
		Want :: struct { card, sign, word, line: string }
		for w in ([]Want{
			{"sa_sg_1_a_0", lucide.CHECK, "done · 2m 13s", "Found three loaders."},
			{"sa_sg_1_a_1", lucide.X, "failed · 2m 13s", "The model refused."},
		}) {
			card := session.find(s, w.card)
			if !testing.expectf(t, card != nil, "the card %s", w.card) { continue }
			testing.expectf(t, named_under(s, card, "body") == nil, "%s: folded", w.card)
			mark := named_under(s, card, "st")
			sign := named_under(s, mark, "sign")
			testing.expectf(t, sign != nil && ui.box_text(sign) == w.sign, "%s: its mark's sign %q", w.card, w.sign)
			if sign != nil { testing.expectf(t, sign.rect.max.x > sign.rect.min.x && sign.rect.max.y > sign.rect.min.y, "%s: its sign is shown", w.card) }
			word := named_under(s, card, "du")
			testing.expectf(t, word != nil && ui.box_text(word) == w.word, "%s: %q (got %q)", w.card, w.word, word != nil ? ui.box_text(word) : "")
			line := named_under(s, card, "rs")
			testing.expectf(t, line != nil && ui.box_text(line) == w.line, "%s: folded, its result's first line %q (got %q)", w.card, w.line, line != nil ? ui.box_text(line) : "")
		}
	})
}

// The bell counts what was missed and not shown yet. The view lists it by session; opening it brings the count to 0 and the
// entries stay. Enter opens the session of the row chosen, A acknowledges it, and the history shows what was acknowledged.
@(test)
the_bell_counts_what_was_missed_and_its_view_answers_the_keys :: proc(t: ^testing.T) {
	unwatched.run(t, proc(t: ^testing.T) {
		context.allocator = runtime.heap_allocator()
		app, s := bench_app(t)
		app.prefs.notices_badge = true
		pref_set(app, "notices.view", "list")
		for id in ([3]string{"ses_1", "ses_2", "ses_3"}) {
			if x := find_session(app, id); testing.expect(t, x != nil && x.parent == "", id) { x.idle, x.viewed = BENCH_EPOCH_MS, 0 }
		}
		marks_changed(app)
		session.frames(s, 3)
		if badge := session.find(s, "badge_count"); testing.expect(t, badge != nil, "a count on the bell") {
			testing.expect_value(t, ui.box_text(badge), "3")
		}
		session.key(s, .N, {.Ctrl, .Shift})
		session.frames(s, 3)
		testing.expect(t, app.cx.open[.Notices], "Ctrl+Shift+N opens the view")
		testing.expect(t, session.find(s, "badge_count") == nil, "shown: nothing New")
		key1, key2 := missed_key(app, .End, "ses_1"), missed_key(app, .End, "ses_2")
		log := missed_log(app)
		testing.expect(t, log.live[key1] != nil && log.live[key2] != nil, "seen, not acknowledged")
		testing.expect(t, session.find_text(s, "Done") != nil, "what happened")
		// Enter: the session of the first entry (the newest session first; the same time: by its id)
		session.key(s, .Return)
		session.frames(s, 3)
		testing.expect_value(t, app.chat.id, "ses_1")
		testing.expect(t, !app.cx.open[.Notices], "the view closes")
		testing.expect(t, log.live[key1] == nil, "opened: acknowledged")
		// A: the entry chosen
		session.key(s, .N, {.Ctrl, .Shift})
		session.frames(s, 3)
		testing.expect(t, app.cx.open[.Notices])
		chosen := app.missed.vl.sel
		if testing.expect(t, chosen >= 0 && chosen < len(app.missed.rows) && app.missed.rows[chosen].entry != nil, "an entry is chosen") {
			key := app.missed.rows[chosen].entry.key
			session.key(s, .A)
			session.frames(s, 2)
			testing.expect(t, log.live[key] == nil, "A acknowledges it")
		}
		// the history: what was acknowledged, shown with it
		acknowledged :: proc(app: ^App) -> (n: int) {
			for r in app.missed.rows { if r.entry != nil && r.entry.state == .Acknowledged { n += 1 } }
			return
		}
		testing.expect_value(t, acknowledged(app), 0)
		session.click(s, "mi_hist")
		session.frames(s, 3)
		testing.expect_value(t, acknowledged(app), 2)
		session.key(s, .Escape)
		session.frames(s, 2)
		testing.expect(t, !app.cx.open[.Notices], "Escape closes it")
	})
}

// Three hundred entries: the view builds the rows in view and a margin, and at rest makes its rows again at no frame.
@(test)
the_view_of_what_was_missed_builds_only_its_rows_in_view :: proc(t: ^testing.T) {
	unwatched.run(t, proc(t: ^testing.T) {
		context.allocator = runtime.heap_allocator()
		app, s := bench_app(t)
		pref_set(app, "notices.view", "list")
		log := missed_log(app)
		for i in 0 ..< 300 {
			notices.put(log, {key = missed_key(app, .Shell, fmt.tprintf("sh_%d", i)), group = missed_group(app, fmt.tprintf("ses_%d", 1 + i / 10)),
				title = "Command ended", text = "cargo build", kind = u16(Missed_Kind.Shell), outcome = u8(Sub_State.Done), at = i64(BENCH_EPOCH_MS) + i64(i)})
		}
		command_run(app, command_find("view.notices"))
		session.frames(s, 4)
		testing.expect_value(t, len(app.missed.rows), 330)
		rows := 0
		if list := session.find(s, "mi_list"); testing.expect(t, list != nil, "the list") {
			for c := list.first; c != nil; c = c.next { if strings.contains(c.name, "lrow_") { rows += 1 } }
		}
		testing.expectf(t, rows > 5 && rows < 80, "the rows in view and a margin: %d built", rows)
		stamp, made := app.missed.rows_stamp, log.groups_made
		session.frames(s, 4)
		testing.expect_value(t, app.missed.rows_stamp, stamp)
		testing.expect_value(t, log.groups_made, made)
	})
}

// The report of each of these sessions, as the server would give it: its prompt and its answer name the session.
@(private = "file")
missed_reports_given :: proc(app: ^App, ids: []string) {
	for id in ids {
		page := fmt.tprintf(`{{"data":[{{"id":"a","type":"assistant","content":[{{"type":"text","text":"The loader of %s is **fixed**."}},{{"type":"tool","id":"t","name":"edit","state":{{"input":{{"filePath":"src/%s.odin"}}}}}}]}},{{"id":"u","type":"user","text":"Fix the loader of %s"}}]}}`, id, id, id)
		v, err := json.parse_string(page, parse_integers = true, allocator = context.temp_allocator)
		assert(err == nil, page)
		missed_report_load(app, id, v)
	}
}

// Three ends nobody saw: three sessions whose runs ended.
@(private = "file")
missed_three_ends :: proc(app: ^App, t: ^testing.T) -> [3]string {
	ids := [3]string{"ses_1", "ses_2", "ses_3"}
	for id in ids {
		if x := find_session(app, id); testing.expect(t, x != nil && x.parent == "", id) { x.idle, x.viewed = BENCH_EPOCH_MS, 0 }
	}
	marks_changed(app)
	return ids
}

@(private = "file")
card_count :: proc(s: ^session.Session) -> string { return ui.box_text(session.find(s, "card_count")) }

// What was missed shows one card at a time by default, each with its session, its request and its report. Right goes to the
// next card, Left back; A acknowledges the card shown and the next takes its place; with the history shown, A goes on to
// the next card.
@(test)
what_was_missed_shows_one_card_at_a_time :: proc(t: ^testing.T) {
	unwatched.run(t, proc(t: ^testing.T) {
		context.allocator = runtime.heap_allocator()
		app, s := bench_app(t)
		ids := missed_three_ends(app, t)
		session.frames(s, 2)
		missed_reports_given(app, ids[:])
		session.key(s, .N, {.Ctrl, .Shift})
		session.frames(s, 4)
		testing.expect(t, app.prefs.notices_cards, "cards: the default")
		testing.expect(t, session.find(s, "mi_cards") != nil && session.find(s, "mi_list") == nil, "a card, no list")
		testing.expect_value(t, card_count(s), "1 / 3")
		testing.expect(t, session.find_text(s, "Session 1 about") != nil, "its session")
		testing.expect(t, session.find_text(s, "Request") != nil, "its request")
		testing.expect(t, session.find_text(s, "Fix the loader of ses_1") != nil, "the prompt")
		testing.expect(t, session.find_text(s, "The loader of ses_1 is fixed") != nil, "the answer, as Markdown")
		testing.expect(t, session.find_text(s, "src/ses_1.odin") != nil, "the file it wrote")
		session.key(s, .Right)
		session.frames(s, 2)
		testing.expect_value(t, card_count(s), "2 / 3")
		testing.expect(t, session.find_text(s, "Fix the loader of ses_2") != nil, "the next card")
		session.key(s, .Left)
		session.frames(s, 2)
		testing.expect_value(t, card_count(s), "1 / 3")
		// A: acknowledged, the next takes its place
		log := missed_log(app)
		first := missed_key(app, .End, "ses_1")
		session.key(s, .A)
		session.frames(s, 3)
		testing.expect(t, log.live[first] == nil, "A acknowledges the card shown")
		testing.expect_value(t, card_count(s), "1 / 2")
		testing.expect(t, session.find_text(s, "Fix the loader of ses_2") != nil, "the next in its place")
		// the history shown: what is acknowledged stays a card, A goes on to the next
		session.click(s, "mi_hist")
		session.frames(s, 3)
		testing.expect_value(t, len(app.missed.cards_rows), 3)
		second := missed_key(app, .End, "ses_2")
		at := -1
		for k, i in app.missed.cards_rows { if app.missed.rows[k].entry.key == second { at = i } }
		if !testing.expect(t, at >= 0 && at < 2, "the second end, not the last card") { return }
		app.missed.cards.at = at
		session.frames(s, 2)
		session.key(s, .A)
		session.frames(s, 3)
		testing.expect(t, log.live[second] == nil, "acknowledged")
		testing.expect_value(t, app.missed.cards.at, at + 1)
	})
}

// A wait's card says Answer, not Acknowledge: its act opens the session that waits, and the view closes.
@(test)
a_wait_is_answered_from_its_card :: proc(t: ^testing.T) {
	unwatched.run(t, proc(t: ^testing.T) {
		context.allocator = runtime.heap_allocator()
		app, s := bench_app(t)
		bench_event(app, `{"type":"permission.asked","data":{"request":{"id":"p1","sessionID":"ses_2","action":"bash","resources":["git push"]}}}`)
		session.frames(s, 2)
		command_run(app, command_find("view.notices"))
		session.frames(s, 4)
		testing.expect_value(t, card_count(s), "1 / 1")
		testing.expect(t, session.find_text(s, "bash git push") != nil, "what is asked")
		settle := session.find(s, "card_settle")
		if testing.expect(t, settle != nil, "the card's act") { testing.expect(t, session.find_text(s, "Answer") != nil, "Answer") }
		session.click(s, "card_settle")
		session.frames(s, 3)
		testing.expect_value(t, app.chat.id, "ses_2")
		testing.expect(t, !app.cx.open[.Notices], "the view closes")
		testing.expect(t, missed_log(app).live[missed_key(app, .Permission, "p1", "ses_2")] != nil, "a wait waits for its answer")
	})
}

// The toggle of the header shows the list instead, and the preference keeps it. A row of the list unfolds in place (Right,
// Space): what it was asked shows under it; Space folds it again.
@(test)
what_was_missed_is_a_list_whose_rows_unfold :: proc(t: ^testing.T) {
	unwatched.run(t, proc(t: ^testing.T) {
		context.allocator = runtime.heap_allocator()
		app, s := bench_app(t)
		ids := missed_three_ends(app, t)
		session.frames(s, 2)
		missed_reports_given(app, ids[:])
		command_run(app, command_find("view.notices"))
		session.frames(s, 4)
		list_seg := named_under(s, session.find(s, "mi_mode"), "seg1")
		if !testing.expect(t, list_seg != nil, "the toggle") { return }
		session.click_at(s, session.center(list_seg))
		session.frames(s, 3)
		testing.expect(t, !app.prefs.notices_cards, "the list")
		testing.expect_value(t, config.string_of(&app.cfg_prefs, "notices.view"), "list")
		testing.expect(t, session.find(s, "mi_list") != nil && session.find(s, "mi_cards") == nil, "a list, no card")
		sel := app.missed.vl.sel
		if !testing.expect(t, sel >= 0 && sel < len(app.missed.rows) && app.missed.rows[sel].entry != nil, "an entry is chosen") { return }
		testing.expect(t, session.find(s, "brief") == nil, "folded")
		session.key(s, .Right)
		session.frames(s, 3)
		testing.expect(t, app.missed.unfolded[app.missed.rows[sel].entry.id], "Right unfolds it")
		testing.expect(t, session.find(s, "brief") != nil, "unfolded in place")
		testing.expect(t, session.find_text(s, "Fix the loader of ses_1") != nil, "its request")
		testing.expect(t, session.find_text(s, "The loader of ses_1 is fixed") != nil, "its answer, as Markdown")
		testing.expect(t, session.find_text(s, "**fixed**") == nil, "no Markdown marks shown")
		session.key(s, .Space)
		session.frames(s, 3)
		testing.expect(t, session.find(s, "brief") == nil, "Space folds it")
	})
}

// The prompts' marks on the conversation's scroll bar: a mark for each prompt, in the conversation's order, on a long
// conversation opened at its bottom. A click on the mark of a prompt far above (never built) puts it at the top of the view in
// that frame, no glide; its plate has the keyboard, and the view stays on it while the heights around it settle. The setting
// takes the marks off the bar, which is a plain one again.
@(test)
the_prompt_rail_goes_to_a_prompt_at_once :: proc(t: ^testing.T) {
	unwatched.run(t, proc(t: ^testing.T) {
		context.allocator = runtime.heap_allocator()
		app, s := bench_app(t)
		rail := &app.conversation.prompt_rail.rail
		sb := session.get(s, "chat")
		testing.expect_value(t, len(ui.scroll_marks_shown(rail)), BENCH_TURNS)
		last: f32 = -1
		for i in 0 ..< BENCH_TURNS {
			at, ok := ui.scroll_marks_at(rail, sb, i)
			if !testing.expectf(t, ok, "prompt %d has a mark", i) { return }
			testing.expectf(t, at.y >= last, "prompt %d below the one before it", i)
			last = at.y
		}
		testing.expect_value(t, ui.scroll_marks_id(rail, 10), "msg_10_u")
		testing.expect(t, session.find(s, "u_msg_10_u") == nil, "not built, far above")
		at, _ := ui.scroll_marks_at(rail, sb, 10)
		session.click_at(s, at)
		sb = session.get(s, "chat")
		plate := session.find(s, "u_msg_10_u")
		if !testing.expect(t, plate != nil, "the prompt built") { return }
		margin := math.round(ui.font_size() * PROMPT_RAIL_MARGIN_EM)
		top := plate.rect.min.y - sb.rect.min.y
		testing.expectf(t, top >= 0 && top < margin + ui.font_size() * 2, "at the top of the view: %v", top)
		testing.expect(t, !sb.view_anim[1].active && sb.view_off.y == sb.view_target.y, "no glide")
		testing.expect_value(t, session.focused_name(s), "u_msg_10_u")
		session.frames(s, 20)
		plate = session.get(s, "u_msg_10_u")
		testing.expectf(t, abs(plate.rect.min.y - sb.rect.min.y - top) < 1, "still there: %v, was %v", plate.rect.min.y - sb.rect.min.y, top)
		// hidden: no marks, and the bar is a plain one (narrower, from the top of the view)
		session.move(s, session.center(session.get(s, "chat")))
		session.frames(s, 3)
		marked, _, _ := ui.scrollbar_rects(session.get(s, "chat"))
		command_run(app, command_find("view.prompt_rail"))
		session.frames(s, 3)
		testing.expect(t, session.find(s, "prompt_rail") == nil, "no marks' button")
		_, ok := ui.scroll_marks_at(rail, session.get(s, "chat"), 10)
		testing.expect(t, !ok, "no marks on the bar")
		plain, _, _ := ui.scrollbar_rects(session.get(s, "chat"))
		testing.expectf(t, plain.max.x - plain.min.x < marked.max.x - marked.min.x, "narrower: %v, was %v", plain, marked)
		testing.expectf(t, plain.min.y < marked.min.y, "from higher: %v, was %v", plain, marked)
	})
}
