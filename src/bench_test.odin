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
import "core:testing"
import "core:time"
import "gt:config"
import "gt:draw"
import "gt:font"
import paint "gt:paint"
import "gt:platform"
import "gt:png"
import "gt:render"
import "gt:ui"
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
BENCH_CHAT_ID     :: "ses_bench"
LAST_SESSION      :: "ls_ses_395"      // the last session of the last group (project_11), not a sub-agent
SIDEBAR_WHEEL     :: 10
BENCH_EPOCH_MS    :: 1.7e12
BENCH_STEP_MS     :: 60000

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
	app.sidebar_w = SIDEBAR_W_DEFAULT
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
		y := g.rect.min.y + v.term.metrics.cell_h * 1.5   // (its second row: the first is the command)
		from := [2]f32{g.rect.min.x + 12, y}
		to := [2]f32{g.rect.min.x + 160, y}
		session.move(s, from)
		session.event(s, {kind = .Mouse_Press, button = .Left, pos = from})
		session.frames(s, 1)
		session.event(s, {kind = .Mouse_Move, pos = to, buttons = {.Left}})
		session.frames(s, 1)
		session.event(s, {kind = .Mouse_Release, button = .Left, pos = to})
		session.frames(s, 2)
		testing.expectf(t, term_has_selection(v.term), "a selection (selecting %v)", v.term.selecting)
		session.event(s, {kind = .Key_Press, key = .C, mods = {.Ctrl}})
		session.frames(s, 1)
		testing.expectf(t, strings.contains(session.clipboard(s), "Compiling"), "copied: %q", session.clipboard(s))
	}
	// a right click on the grid: its menu
	term_selection_drop(v.term)
	session.click(s, "term_box", .Right)
	session.frames(s, 2)
	testing.expect(t, session.find_text(s, "Select all") != nil && session.find_text(s, "Copy all the output") != nil, "the grid's menu")
	session.click_text(s, "Select all")
	session.frames(s, 2)
	testing.expect(t, term_has_selection(v.term), "Select all: the screen selected")
	session.click(s, "term_box", .Right)
	session.frames(s, 2)
	session.click_text(s, "Copy all the output")
	session.frames(s, 2)
	testing.expectf(t, strings.contains(session.clipboard(s), "Compiling") && !strings.contains(session.clipboard(s), "\x1b") && !strings.contains(session.clipboard(s), "cargo build"), "all the output, plain, without the command: %q", session.clipboard(s))
	// the wheel over the grid scrolls the grid, not the conversation behind the dialog
	if g := session.find(s, "term_box"); g != nil {
		for i in 0 ..< 200 { output_view_feed(v, fmt.tprintf("line %d\n", i)) }
		session.frames(s, 2)
		testing.expect(t, term_at_bottom(v.term), "it follows its end")
		chat := session.get(s, "chat")
		behind := chat.view_target.y
		at := session.center(g)
		session.move(s, at)
		session.event(s, {kind = .Scroll, pos = at, delta = {0, -3}})
		session.frames(s, 2)
		testing.expect(t, !term_at_bottom(v.term), "the grid scrolled up")
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
			ui.area_set(&app.composer, "")
			session.frames(s, 4)
		}
		// a double click on the title edits it in place: Enter keeps it, Escape leaves it, a click elsewhere keeps it
		session.click(s, "title_b", count = 2)
		session.frames(s, 2)
		testing.expect(t, app.rename.at == .Header && session.find(s, "ren_f") != nil && !app.cx.open[.Rename], "the header's title, a field in place")
		session.key(s, .A, {.Ctrl})
		session.type_text(s, "Frame pacing")
		session.frames(s, 1)
		testing.expect_value(t, ui.field_string(&app.rename.field), "Frame pacing")
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
		testing.expect_value(t, len(ui.area_string(&app.composer)), BENCH_FRAMES)

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
			if i % 3 == 2 { ui.field_set(&app.palette.field, "") }
			bench_frame(s, &pal)
		}
		profile_end("palette")
		bench_report(&pal)
		app.cx.open[.Palette] = false
		session.frames(s, 2)

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
		key := ui.key_from_string(0, "app_menu")
		ui.ctx_menu_open(key, {40, 40})
		session.frames(s, 3)
		menu := Bench_Case{name = "menu"}
		profile_begin()
		for i in 0 ..< BENCH_FRAMES {
			session.move(s, {120, 60 + f32(i % 40) * 8})
			bench_frame(s, &menu)
		}
		profile_end("menu")
		bench_report(&menu)
		ui.ctx_menu_close()
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
		testing.expect_value(t, ui.field_string(&app.find.field), BENCH_FIND)
		session.wait_until(s, proc(s: ^session.Session) -> bool { return !ui.find_pending() }, "the needle swept")
		session.frames(s, 3)
		found := ui.find_count()
		testing.expect(t, found > 1, "the sweep read the whole conversation")
		testing.expect_value(t, app.find.index, found - 1)   // (searched from the bottom, under its last match: that one, not the first, a conversation away)
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
		testing.expect_value(t, ui.field_string(&app.search), BENCH_SEARCH)

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
	app.conn = new(Conn)   // (requests are kept: answers_test.odin)
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
	ui.field_set(&app.find.field, "zebra")
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
	c.older = strings.clone("more", c.alloc)
	session.frames(s, 2)
	sb = session.get(s, "chat")
	session.wheel(s, session.center(sb), {0, -200})
	session.frames(s, 1)
	sb = session.get(s, "chat")
	testing.expect(t, sb.view_target.y == 0 && sb.view_anim[1].active, "on its way to the top, stopped there")
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

// A right click on the sessions' search opens its menu: Paste puts a value in it (gui_toolkit's field_menu).
@(test)
the_search_has_a_menu :: proc(t: ^testing.T) {
	unwatched.run(t, proc(t: ^testing.T) {
		context.allocator = runtime.heap_allocator()
		app, s := bench_app(t)
		session.set_clipboard(s, "ses_2")
		session.click(s, "search", .Right)
		session.frames(s, 2)
		testing.expect(t, ui.ctx_menu_any_open(), "its menu")
		session.save_png(s, "search_menu.png")
		session.click_text(s, "Paste")
		session.frames(s, 3)
		testing.expect_value(t, ui.field_string(&app.search), "ses_2")
		testing.expect(t, session.find(s, "ls_ses_2") != nil, "the search found it by its id")
		// its cross empties it
		session.click(s, "clear")
		session.frames(s, 3)
		testing.expect_value(t, ui.field_string(&app.search), "")
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
		pref_set(app, "appearance.style", "flat")   // (the theme's own finish wins over the style asked)
		testing.expect_value(t, app.theme.finish, ui.Finish.Edged)
		pref_set(app, "appearance.style", "machined")
		stats_open(app)
		session.wait_idle(s)
		testing.expect(t, session.find(s, "st_Tokens") != nil, "the tokens' section")
		session.save_png(s, "console.png")
		panel_close(app, u32(Panel.Stats))
	})
}

// The screens in Kernel, for the eye (build/session/bench_app/console_*.png): the settings, the palette, the activity with
// its todos, a shell. What each shows is checked elsewhere; here, that each opens in the theme.
@(test)
the_console_screens :: proc(t: ^testing.T) {
	unwatched.run(t, proc(t: ^testing.T) {
		context.allocator = runtime.heap_allocator()
		app, s := bench_app(t)
		pref_set(app, "appearance.theme", "Kernel")
		defer pref_set(app, "appearance.theme", "OpenCode")
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
		ui.ctx_menu_close()
		session.frames(s, 2)
		command_run(app, command_find("app.palette"))
		session.frames(s, 3)
		ui.field_set(&app.palette.field, "the")
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
		if app.conn == nil { app.conn = new(Conn) }   // (the bench has no server: its requests are kept for the test to answer)
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
		pref_set(app, "appearance.terminal_font", "DejaVu Sans Mono")
		defer pref_set(app, "appearance.terminal_font", "")
		if app.term_face != "" {   // (where it is installed)
			testing.expect_value(t, app.term_face, "DejaVu Sans Mono")
			testing.expect(t, app.term_font != app.own.term[0], "the system's")
		}
		pref_set(app, "appearance.terminal_font", "")
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
		if app.conn == nil { app.conn = new(Conn) }   // (the bench has no server: its requests are kept for the test to answer)
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
		plain := end_of(img, sh.rect, sh.rect.min.y, sh.metrics.cell_h)
		coloured := end_of(img, sh.rect, sh.rect.min.y + sh.metrics.cell_h, sh.metrics.cell_h)
		testing.expect(t, plain > int(sh.rect.min.x), "the first line is drawn")
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
		pref_set(app, "appearance.system_title", "true")
		defer pref_set(app, "appearance.system_title", "false")
		session.wait_idle(s)
		testing.expect(t, !platform.is_integrated_title(app.win), "the system's")
		testing.expect(t, session.find(s, "wb_close") == nil, "the system's buttons: none here")
		testing.expect(t, session.find(s, "appmenu") != nil, "the program's bar stays, its menu in it")
		pref_set(app, "appearance.system_title", "false")
		session.wait_idle(s)
		testing.expect(t, platform.is_integrated_title(app.win) && session.find(s, "wb_close") != nil, "the program's again")
	})
}

// A slider of the settings dragged and let go: the preference takes the value it was let go at, and keeps it.
@(test)
a_slider_keeps_the_value_it_is_let_go_at :: proc(t: ^testing.T) {
	unwatched.run(t, proc(t: ^testing.T) {
		context.allocator = runtime.heap_allocator()
		app, s := bench_app(t)
		settings_open(app)
		ui.field_set(&app.settings_query, "conversation width")
		session.frames(s, 3)
		sl := session.find(s, "sl")
		if !testing.expect(t, sl != nil, "the slider") { return }
		before := config.int_of(&app.cfg_prefs, "conversation.width")
		from := session.center(sl)
		to := from + {(sl.rect.max.x - sl.rect.min.x) * 0.3, 0}
		session.press(s, from)
		session.move(s, from + {10, 0})
		session.move(s, to)
		session.release(s, to)
		session.frames(s, 3)
		after := config.int_of(&app.cfg_prefs, "conversation.width")
		testing.expectf(t, after > before + 20, "dragged right: %v, from %v", after, before)
		session.frames(s, 3)
		testing.expect_value(t, config.int_of(&app.cfg_prefs, "conversation.width"), after)
		ui.field_set(&app.settings_query, "")
		app.cx.open[.Settings] = false
		pref_set(app, "conversation.width", fmt.tprintf("%v", before))
	})
}

// The settings' search: what matches in every client page, under its page's title, and nothing else of the pages.
@(test)
the_settings_search_shows_what_matches :: proc(t: ^testing.T) {
	unwatched.run(t, proc(t: ^testing.T) {
		context.allocator = runtime.heap_allocator()
		app, s := bench_app(t)
		settings_open(app)
		session.frames(s, 3)
		testing.expect(t, session.find(s, "set_appearance.glow") != nil, "a page shows its settings")
		testing.expect(t, session.find_text(s, fmt.tprintf("opencode native %s", APP_VERSION)) != nil, "the version, under the pages")
		ui.field_set(&app.settings_query, "permission")
		session.frames(s, 3)
		testing.expect(t, session.find(s, "set_notify.permission") != nil, "the match")
		testing.expect(t, session.find(s, "set_appearance.glow") == nil, "nothing else")
		testing.expect(t, session.find(s, "hint_setup") == nil, "nor what a page says besides its settings")
		ui.field_set(&app.settings_query, "no setting is called this")
		session.frames(s, 3)
		testing.expect(t, session.find_text(s, "No setting matches.") != nil, "nothing matches, and it says so")
		ui.field_set(&app.settings_query, "")
		session.frames(s, 3)
		testing.expect(t, session.find(s, "set_appearance.glow") != nil, "the page again")
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
			image_ref_delete(&app.view_ref)
			app.view_ref = image_ref_clone(image_ref("not decoded here", .Bytes, "image/png", "picture.png"))
			app.view_key = 0x5eed
			app.images[app.view_key] = {state = .Ready, tex = tex, w = W, h = H, used = app.frame_no}
			app.cx.open[.Viewer], app.view_zoom, app.view_pan, app.view_grown = true, 1, {}, false
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
		app.view_zoom = 0.5
		session.frames(s, 2)
		session.click_at(s, view.rect.min + 5)
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
		ui.field_set(&f.fields[1].text, LONG)
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
				if b.rect.min.x > app.sidebar_w && b.rect.min.y > 0 && b.rect.max.y < f32(BENCH_SIZE.y) && b.rect.max.x > b.rect.min.x { return b }
			}
		}
		rows := table_in_sight(s, app)
		mid := [2]f32{app.sidebar_w + (f32(BENCH_SIZE.x) - app.sidebar_w) * 0.5, f32(BENCH_SIZE.y) * 0.5}
		for k := 0; rows == nil && k < 60; k += 1 {
			session.event(s, {kind = .Scroll, pos = mid, delta = {0, 3}})
			session.wait_idle(s)   // (the scroll glides: where the table is, once it stands)
			rows = table_in_sight(s, app)
		}
		if !testing.expect(t, rows != nil, "a table in sight") { return }
		session.move(s, session.center(rows))
		session.wait_idle(s)
		copy := session.find(s, "tcopy")
		if !testing.expect(t, copy != nil, "its copy button, under the pointer") { return }
		testing.expect(t, copy.parent != nil && copy.parent.last == copy, "the last of the table's boxes: over its rows")
		session.click_at(s, session.center(copy))
		session.frames(s, 2)
		testing.expect(t, session.find_text(s, "Table copied") != nil, "a click on it copies the table")
	})
}

// Every setting the palette lists (not a hidden one) is on a settings page: the search the palette gives the settings shows it, with
// its control. A hidden one is on none.
@(test)
every_setting_of_the_palette_is_on_a_page :: proc(t: ^testing.T) {
	unwatched.run(t, proc(t: ^testing.T) {
		context.allocator = runtime.heap_allocator()
		app, s := bench_app(t)
		settings_open(app)
		for d in PREF_DEFS {
			ui.field_set(&app.settings_query, setting_query(d.name))
			session.frames(s, 2)
			found := session.find(s, fmt.tprintf("set_%s", d.name)) != nil
			if d.hidden {
				testing.expectf(t, !found, "%s is hidden: on no page", d.name)
			} else {
				testing.expectf(t, found, "%s: the settings show it when the palette opens them on it (%q)", d.name, setting_query(d.name))
			}
		}
		ui.field_set(&app.settings_query, "")
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
		testing.expect_value(t, ui.area_string(&app.composer), "")
		ui.set_focus(0)
		session.type_text(s, "hi")
		session.frames(s, 2)
		testing.expect_value(t, ui.area_string(&app.composer), "hi")
		testing.expect(t, app.composer_focused, "it has the keyboard")
		ui.area_set(&app.composer, "")
		ui.set_focus(0)
		palette_toggle(app)
		session.frames(s, 2)
		ui.set_focus(0)
		session.type_text(s, "x")
		session.frames(s, 2)
		testing.expect_value(t, ui.area_string(&app.composer), "")
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
		ui.field_set(&app.server_edit.password, "hunter2")
		session.frames(s, 2)
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

// A session archived leaves its section for the last one, Archived, folded until it is opened; brought back, it is where it was.
@(test)
an_archived_session_is_put_away :: proc(t: ^testing.T) {
	unwatched.run(t, proc(t: ^testing.T) {
		context.allocator = runtime.heap_allocator()
		app, s := bench_app(t)
		id := "ses_2"
		ui.field_set(&app.search, `"Session 2 about"`)   // (it alone: the end of a long list is not built)
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
		app.folded[last.key] = false   // (opened, as its header's click does)
		session.frames(s, 3)
		testing.expect(t, session.find(s, "ls_ses_2") != nil, "opened: it shows")
		session_archive(app, id, false)
		session.frames(s, 3)
		testing.expect(t, session.find(s, "ls_ses_2") != nil, "back in its section")
		testing.expect(t, session.find_text(s, "ARCHIVED") == nil, "nothing archived: no section")
		ui.field_set(&app.search, "")
	})
}

// Archived from the list, the pointer still on it: the row leaves its section at once (the list held under the pointer is
// for what changes by itself, not for what the person just did).
@(test)
a_session_archived_under_the_pointer_leaves_at_once :: proc(t: ^testing.T) {
	unwatched.run(t, proc(t: ^testing.T) {
		context.allocator = runtime.heap_allocator()
		app, s := bench_app(t)
		ui.field_set(&app.search, `"Session 2 about"`)
		session.frames(s, 2)
		row := session.find(s, "ls_ses_2")
		if !testing.expect(t, row != nil, "listed") { return }
		at := session.center(row)
		session.move(s, at)
		session.move(s, at + {2, 0})
		session.frames(s, 2)
		testing.expect(t, app.cx.side_hold.on, "the list is held under the pointer")
		session_archive(app, "ses_2", true)
		session.move(s, at + {4, 0})   // (the pointer moves on over the list: the hold goes on)
		session.frames(s, 2)
		testing.expect(t, session.find(s, "ls_ses_2") == nil, "out of its section at once; Archived is folded")
		testing.expect(t, session.find_text(s, "ARCHIVED") != nil, "the Archived section")
		session_archive(app, "ses_2", false)
		session.move(s, at + {6, 0})
		session.frames(s, 2)
		testing.expect(t, session.find(s, "ls_ses_2") != nil, "brought back: at once too")
		ui.field_set(&app.search, "")
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
		testing.expect_value(t, ui.area_string(&app.composer), "wait, no")
		app.chat.busy = false
		delete_key(&app.busy, app.chat.id)
		session.key(s, .Escape)
		session.frames(s, 2)
		testing.expect(t, session.focused_name(s) != "composer", "nothing runs: it lets go")
		ui.area_set(&app.composer, "")
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

// A diagram opens in the viewer on a click: the wheel zooms it where the pointer is, a drag moves it, + and 0; its menu copies it
// as a picture, at twice its size in the conversation, on the colour of code.
@(test)
a_diagram_is_zoomed_and_moved_in_the_viewer :: proc(t: ^testing.T) {
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
		session.click(s, "diagram")
		session.wait_idle(s)
		testing.expect(t, app.cx.open[.Viewer] && app.view_diagram != "", "a click opens the viewer on it")
		view := session.find(s, "view")
		if !testing.expect(t, view != nil, "the view") { return }
		em := ui.font_size()
		room := app.state.window_size - 2 * math.round(em * ui.MODAL_MARGIN_EM)
		vs := view.rect.max - view.rect.min
		testing.expectf(t, vs.x > room.x * app.prefs.viewer_scale - 2 * em || vs.y > room.y * app.prefs.viewer_scale - 4 * em, "larger than in the conversation: the share of the room (%v of %v)", vs, room)
		at := session.center(view) + {30, 10}
		session.move(s, at)
		session.wheel(s, at, {0, -3})
		session.frames(s, 2)
		testing.expectf(t, app.view_zoom > 1.9, "the wheel zooms: %v", app.view_zoom)
		testing.expectf(t, app.view_pan.x < 0 && app.view_pan.y < 0, "toward the pointer: %v", app.view_pan)
		session.save_png(s, "diagram_viewer.png")
		from := app.view_pan
		c := session.center(view)
		session.press(s, c)
		session.move(s, c + {20, 10})
		session.move(s, c + {40, 20})
		session.release(s, c + {40, 20})
		session.frames(s, 2)
		testing.expectf(t, abs(app.view_pan.x - from.x - 40) < 1 && abs(app.view_pan.y - from.y - 20) < 1, "a drag moves it: %v from %v", app.view_pan, from)
		session.event(s, {kind = .Key_Press, key = .N0})
		session.frames(s, 2)
		testing.expect(t, app.view_zoom == 1 && app.view_pan == {}, "0: back to what fits")
		session.click_at(s, session.center(view), .Right)
		session.frames(s, 2)
		testing.expect(t, session.find_text(s, "Copy as PNG") != nil, "Copy as PNG")
		testing.expect(t, session.find_text(s, "Copy the text") != nil, "Copy the text")
		session.event(s, {kind = .Key_Press, key = .Escape})
		session.frames(s, 2)
		pic, ok := diagram_picture(app, app.view_diagram)
		defer paint.canvas_destroy(&pic)
		if !testing.expect(t, ok, "its picture") { return }
		d := diagram_of(app, app.view_diagram, !app.cx.theme.light)
		want := d.doc.view[2] * DIAGRAM_COPY_SCALE * diagram_scale(ui.font_size())
		testing.expectf(t, abs(f32(pic.width) - math.ceil(want)) < 1, "twice its size: %d for %v", pic.width, want)
		well := themed(HEX_CODE_WELL)
		testing.expectf(t, abs(pic.pixels[0].r - f32(well >> 24) / 255) < 0.01, "on the colour of code: %v", pic.pixels[0])
		inked := 0
		for p in pic.pixels { if abs(p.r - pic.pixels[0].r) + abs(p.g - pic.pixels[0].g) > 0.1 { inked += 1 } }
		testing.expectf(t, inked > len(pic.pixels) / 50, "its boxes, lines and words: %d", inked)
		session.event(s, {kind = .Key_Press, key = .Escape})
		session.frames(s, 3)
		testing.expect(t, !app.cx.open[.Viewer], "Escape closes it")
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
		ui.field_set(&app.search, "FRAME project_3")
		session.frames(s, 3)
		lit, all := lit_titles(s)
		testing.expectf(t, all > 0 && lit == all, "the titles found are lit: %d of %d", lit, all)
		ui.field_set(&app.search, "")
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
		if app.conn == nil { app.conn = new(Conn) }
		clear(&bench_sent)
		terminal_toggle(app)
		bench_answer(app, bench_take(t, .Pty_List), 200, `{"data":[{"id":"a","title":"bash","status":"running"}]}`)
		for sh in app.cx.terms.list { term_link_set(app, sh, .Attached) }
		bench_clear(app)
		if !testing.expect(t, len(app.cx.terms.list) == 1, "a shell") { return }
		sh := app.cx.terms.list[0]
		session.wait_idle(s)
		cols := sh.cols
		at := session.center(session.get(s, "term_box"))
		for _ in 0 ..< 3 {
			session.event(s, {kind = .Scroll, pos = at, delta = {0, -1}, mods = {.Ctrl}})
			session.frames(s, 1)
			session.advance(s, TERM_ZOOM_REST_MS * 0.5)
		}
		testing.expectf(t, sh.zoom > 1.3, "zoomed in: %v", sh.zoom)
		testing.expect_value(t, sh.cols, cols)
		session.advance(s, TERM_ZOOM_REST_MS * 2)
		session.wait_idle(s)
		testing.expectf(t, sh.cols < cols, "at rest, fewer columns of bigger cells: %d, then %d", cols, sh.cols)
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
		if app.conn == nil { app.conn = new(Conn) }
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
		testing.expect(t, !term_has_selection(sh), "no selection made by that press")
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
		session.advance(s, 1000 * TOOLTIP_DELAY_S + 100)
		session.save_png(s, "folder_tooltip.png")
		testing.expect(t, session.find_text(s, path) != nil, "the tooltip says the whole path")
		session.click(s, "hf0", .Right)
		session.frames(s, 2)
		testing.expect(t, ui.ctx_menu_any_open(), "its menu")
		session.click_text(s, "Copy the path")
		session.frames(s, 2)
		testing.expect_value(t, session.clipboard(s), path)
	})
}
