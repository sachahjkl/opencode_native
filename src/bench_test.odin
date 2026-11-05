package occ

// The program on its heavy cases, in the test's process: the App made as main makes it, on an offscreen window
// (testkit/session drives it: its input, its clock), with a long conversation and many sessions made up here, no server.
// The tests check what each case must do; with -define:OCC_BENCH=true they also run BENCH_FRAMES frames of each and print
// the medians of the frame's steps (docs/performance.md: how they are compared).
//
//   odin test src -collection:gt=ext/gui_toolkit -o:speed -define:OCC_BENCH=true -define:ODIN_TEST_THREADS=1

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:slice"
import "core:strings"
import "core:testing"
import "core:time"
import "gt:draw"
import "gt:font"
import "gt:platform"
import "gt:render"
import "gt:ui"
import session "gt:testkit/session"

OCC_BENCH :: #config(OCC_BENCH, false)

BENCH_SIZE        :: [2]int{1600, 1000}
BENCH_TURNS       :: 150     // a user's prompt and the agent's answer each (tool calls, reasoning, Markdown)
BENCH_SESSIONS    :: 400
BENCH_PROJECTS    :: 12
BENCH_TOOLS       :: 4       // tool calls per answer
BENCH_FRAMES      :: 300 when OCC_BENCH else 12   // frames per case
BENCH_WHEEL       :: 3       // notches per frame, up
BENCH_PARAGRAPH_DELTAS :: 8   // a paragraph's deltas: then the model starts another
BENCH_DELTA       :: "Each `delta` adds a few words to the answer, **as a model streams**. "
BENCH_TYPED       :: "the quick brown fox jumps over the lazy dog "
BENCH_FIND        :: "lazy column"
BENCH_SEARCH      :: "project"
BENCH_CHAT_ID     :: "ses_bench"
LAST_ANSWER       :: "msg_msg_149_a"   // (BENCH_TURNS - 1)
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
	ui.draw_tree(&app.ui_state, &app.dc)
	for m, i in app.chat.messages {
		if i % 2 == 0 { continue }
		fmt.println(m.id, len(m.parts))
	}
}
` + "```" + `

| Step | Before | After |
|:-----|-------:|:-----:|
| build | 1.20 ms | 0.80 ms |
| draw | 0.40 ms | 0.35 ms |
| ` + "`render`" + ` | 0.90 ms | 0.90 ms |

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
	app.stick_bottom = true
	app.online = true
	chat_reset(&app.chat)
	app.win = platform.open_window_offscreen("opencode", BENCH_SIZE)
	testing.expect(t, app.win != nil)
	// (the bench on the GPU, as the program; the checks on WARP: no GPU needed)
	testing.expect(t, fonts_init(app))
	testing.expect(t, render.init_offscreen(&app.r, app.win.size, warp = !OCC_BENCH))
	app_init(app, "")
	app.last_tick = time.tick_now()
	app.opened_first = true
	app.chat.id = strings.clone(BENCH_CHAT_ID, app.chat.alloc)
	v, err := json.parse_string(bench_sessions(), allocator = context.temp_allocator)
	testing.expect(t, err == nil)
	sessions_load(app, v)
	v, err = json.parse_string(bench_page(), allocator = context.temp_allocator)
	testing.expect(t, err == nil)
	chat_load(app, v, false)
	app.snap_bottom = true
	testing.cleanup(t, bench_end, app)
	s = session.attach(t, {win = app.win, state = &app.ui_state, renderer = &app.r, user = app, frame = proc(user: rawptr) { frame((^App)(user)) }, allocator = context.allocator})
	// (the lazy column learns the heights of what it builds: the bottom settles in a few frames)
	session.wait_until(s, proc(s: ^session.Session) -> bool { return session.find(s, LAST_ANSWER) != nil }, "the last answer built")
	return
}

// What the system gives back (the window, the device, the fonts); the rest goes with the process.
@(private = "file")
bench_end :: proc(p: rawptr) {
	app := (^App)(p)
	context.allocator = runtime.heap_allocator()
	ui.destroy(&app.ui_state)
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
	append(&c.build, time.duration_milliseconds(app.times.build))
	append(&c.draw, time.duration_milliseconds(app.times.draw))
	append(&c.render, time.duration_milliseconds(app.times.render))
	append(&c.total, total)
	append(&c.gpu, f64(render.gpu_ms(&app.r)))
	c.builds += app.times.builds
	c.boxes = ui.boxes_built(&app.ui_state)
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
	when OCC_BENCH {
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
	context.allocator = runtime.heap_allocator()   // (what the App's procedures free here was made on the heap)
	app, s := bench_app(t)
	c := &app.chat
	testing.expect_value(t, len(c.messages), 3 * BENCH_TURNS)
	sb := session.get(s, "chat")
	limit := sb.view_bounds.y - sb.size.y
	testing.expect(t, limit > f32(BENCH_TURNS) * sb.size.y * 0.5, "the conversation is many pages long")
	testing.expect(t, sb.view_off.y >= limit - 1, "opened at its bottom")
	testing.expect(t, session.find(s, "msg_msg_0_a") == nil, "the first one is not")
	bottom_boxes := ui.boxes_built(&app.ui_state)

	when OCC_BENCH { render.set_gpu_profile(&app.r, true) }
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

	// the wheel, up through the conversation
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
	testing.expect(t, sb.view_target.y < limit, "scrolled up")
	testing.expect(t, ui.boxes_built(&app.ui_state) < 2 * bottom_boxes, "still only what is seen")

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
	app.palette.open = false
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
	testing.expect(t, session.find(s, "msg_msg_0_a") != nil, "find builds the first answer too")
	testing.expect_value(t, ui.field_string(&app.find.field), BENCH_FIND)
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
}
