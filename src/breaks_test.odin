package ocn

// What a review set out to break, and did: each case as it was shown, so that it stays mended. (The file of what is reviewed: a test that
// belongs to a feature lives with it.)

import "base:runtime"
import "core:fmt"
import "core:strings"
import "core:testing"
import "gt:platform"
import "gt:term"
import "gt:ui"

@(private = "file")
shells_json :: proc(ids: ..string) -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, `{"data":[`)
	for id, i in ids { fmt.sbprintf(&b, `%s{{"id":%s,"title":"sh","status":"running"}}`, i > 0 ? "," : "", jquote(id)) }
	strings.write_string(&b, `]}`)
	return strings.to_string(b)
}

@(private = "file")
shells_open :: proc(t: ^testing.T, app: ^App, ids: ..string) {
	terminal_toggle(app)
	bench_answer(app, bench_take(t, .Pty_List), 200, shells_json(..ids))
	for s in app.cx.terms.list { term_link_set(app, s, .Attached) }
	bench_clear(app)
}

// A drag that stops `stop` ms after its first step: frames for a moment, and then the window wakes only for what is due.
@(private = "file")
told_after_drag :: proc(t: ^testing.T, stop: int) -> bool {
	app := bench_new()
	shells_open(t, app, "a")
	s := app.cx.terms.list[0]
	term.size_set(&s.view, 100, 30, {8, 16})
	bench_answer(app, bench_take(t, .Pty_Size), 200, "")
	bench_clock += 2000
	due_tick(app, .Term_Size)
	app.settle = 0

	cols := u16(100)
	for ms := 0; ms <= stop; ms += 10 {
		cols += 1
		term.size_set(&s.view, int(cols), 30, {8, 16})
		if ms < stop { bench_clock += 10 }
	}
	app.settle = FRAMES_AFTER_INPUT
	next_frame := bench_clock + 17
	for _ in 0 ..< 3000 {
		bench_clock += 1
		if ui.deferred_in_ms(&app.cx.due[.Term_Size]) > 0 && bench_clock >= app.cx.due[.Term_Size].due_ms { due_tick(app, .Term_Size) }
		if app.settle > 0 && bench_clock >= next_frame {
			term.size_set(&s.view, int(cols), 30, {8, 16})   // (the grid's fit in term.build, at each build)
			app.settle -= 1
			next_frame = bench_clock + 17
		}
	}
	told := bench_count(.Pty_Size) == 1
	bench_clear(app)
	return told
}

@(test)
a_drag_ends_with_the_shell_told_its_size_whenever_it_stops :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	for stop := 0; stop < 150; stop += 10 {
		testing.expectf(t, told_after_drag(t, stop), "the last step %d ms after the first", stop)
	}
}

// A window's input goes to a grid built in it: a shell in a view's window hears that window (its input hook is the main
// window's), and the main window types nothing into it.
@(test)
a_window_types_only_into_its_own_grids :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	shells_open(t, app, "a", "b")
	s := &app.cx.terms
	b := s.list[1]
	other: ui.State
	s.focused, b.built_in = b, &other
	ev := []platform.Event{{kind = .Text, text = 'x'}}
	left := term_events(app, &app.state, ev)
	testing.expect_value(t, len(left), 1)
	testing.expect_value(t, len(b.conn.out), 0)
	ev = []platform.Event{{kind = .Text, text = 'x'}}
	left = term_events(app, &other, ev)
	testing.expect_value(t, len(left), 0)
	testing.expect_value(t, string(b.conn.out[:]), "x")
	s.focused = nil
}

// The banner's Close does not depend on where its view is: closed, a shell's view is built nowhere.
@(test)
the_close_of_a_shell_needs_no_build :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	shells_open(t, app, "a")
	s := &app.cx.terms
	id := strings.clone(s.list[0].id, context.temp_allocator)
	s.close_due = s.list[0]
	terms_close_due(app)
	testing.expect(t, s.close_due == nil)
	testing.expect_value(t, len(s.list), 0)
	testing.expect(t, !ui.view_is_open(&app.program_views, TERMINAL_VIEW, id), "its view went with it")
}

@(test)
output_that_starts_with_a_zero_is_output :: proc(t: ^testing.T) {
	c: Term_Conn
	testing.expect(t, term_frame(&c, "\x00hello"))
	testing.expect_value(t, c.cursor, i64(6))
	testing.expect(t, !term_frame(&c, "\x00{\"cursor\":42}"), "where it stands is not output")
	testing.expect_value(t, c.cursor, i64(42))
	free_all(context.temp_allocator)
}

@(private = "file")
go_to_session :: proc(app: ^App, id: string) {
	chat_reset(&app.chat)
	app.chat.id = strings.clone(id, app.chat.alloc)
	app.chat.have_self = true
	app.chat.self.parent = strings.clone("", app.chat.alloc)
	preview_follow(app)
}

@(test)
a_tab_the_limit_took_before_its_address_loads_what_was_asked :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	app.win = new(platform.Window)
	go_to_session(app, "a")
	preview_show(app)
	tab := preview_front(&app.preview)
	preview_commit(app, tab, "http://slow.local/")
	for i in 0 ..< PREVIEW_VIEWS_MOST {
		go_to_session(app, fmt.tprintf("x%d", i))
		preview_show(app)
		other := preview_front(&app.preview)
		preview_go(app, other, "http://x.local/")
		web_event_add(other.view, .Ready, 0, nil)
		web_event_add(other.view, .Source, 0, transmute([]u8)string("http://x.local/"))
		web_events_drain(app)
	}
	go_to_session(app, "a")
	front := preview_front(&app.preview)
	testing.expect(t, front == tab)
	testing.expect(t, front.view != nil, "a view comes back for what was asked")
	testing.expect_value(t, front.url, "http://slow.local/")
}

// The address being typed in the panel: its focus is in the state of the window the panel is in.
@(test)
what_is_typed_in_the_panel_stays_through_a_redirect :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	app.win = new(platform.Window)
	app.chat.id = "a"
	preview_follow(app)
	preview_show(app)
	tab := preview_front(&app.preview)
	preview_go(app, tab, "http://a.local/")
	web_event_add(tab.view, .Ready, 0, nil)
	web_events_drain(app)
	app.preview.addr_key = 42
	app.state.focus_key = 42
	ui.line_edit_set(&tab.field, "http://typing")
	web_event_add(tab.view, .Source, 0, transmute([]u8)string("http://redirected.local/"))
	web_events_drain(app)
	testing.expect_value(t, ui.line_edit_string(&tab.field), "http://typing")
}

// What a dialog holds came from the server left.
@(test)
leaving_a_server_closes_what_acts_on_its_sessions :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	delete_ask(app, "s")
	rename_open(app, "s")
	vs := &app.program_views
	testing.expect(t, ui.view_is_open(vs, DELETE_VIEW) && ui.view_is_open(vs, RENAME_VIEW))
	server_forget(app)
	testing.expect(t, !ui.view_is_open(vs, DELETE_VIEW) && !ui.view_is_open(vs, RENAME_VIEW))
}

////////////////////////////////
// The browser's last answer before a change of folder: the link's thread, on a socket of the test's

@(private = "file")
Fake_Socket :: struct { app: ^App, l: ^Browser_Link, move: bool, reads, opens: int, sent: [dynamic]string, ctx: runtime.Context }

@(thread_local, private = "file") fake: Fake_Socket

@(private = "file")
FAKE_SOCKET :: Ws_Ops{
	open = proc "c" (c: rawptr, path: [^]u8, n: uint) -> rawptr {
		fake.opens += 1
		if fake.opens > 1 { fake.l.stop = true; return nil }
		return rawptr(uintptr(1))
	},
	read_timeout = proc "c" (w: rawptr, ms: u32) {},
	free = proc "c" (w: rawptr) {},
	send = proc "c" (w: rawptr, data: [^]u8, n: uint) -> i32 {
		context = fake.ctx
		append(&fake.sent, strings.clone(string(data[:n])))
		return 0
	},
	// All that happens on the interface's thread during one read.
	read = proc "c" (w: rawptr, out: ^Ocn_Buf) -> i32 {
		context = fake.ctx
		app, l := fake.app, fake.l
		fake.reads += 1
		switch fake.reads {
		case 1:
			tool_call(app, {l, l.socket}, "7", "evaluate", nil, "")
			if fake.move { app.chat.self.directory = strings.clone("B", app.chat.alloc) }
			browser_follow(app)
		case 2:
			v := preview_front(&app.preview).view
			web_event_add(v, .Script, app.browser.next_id, transmute([]u8)string(`"42"`))
			web_events_drain(app)
			browser_tick(app)
		case:
			l.stop = true
		}
		return 0
	},
}

@(private = "file")
answers_sent :: proc(move: bool) -> int {
	app := bench_new()
	app.win = new(platform.Window)
	app.prefs.browser_tools = true
	app.chat.id = strings.clone("a", app.chat.alloc)
	app.chat.have_self = true
	app.chat.self.directory = strings.clone("A", app.chat.alloc)
	preview_follow(app)
	preview_show(app)
	tab := preview_front(&app.preview)
	preview_go(app, tab, "http://a.local/")
	web_event_add(tab.view, .Ready, 0, nil)
	web_events_drain(app)
	l := new(Browser_Link)
	l.app, l.ws, l.conn = app, FAKE_SOCKET, app.conn
	l.dir = strings.clone("A")
	app.conn.browser = l
	fake = {app = app, l = l, move = move, ctx = context}
	conn_hold(app.conn)   // (as browser_start does: the thread lets go at its end)
	browser_thread(l)
	n := 0
	for s in fake.sent { if strings.contains(s, "42") { n += 1 } }
	return n
}

@(test)
the_answer_goes_out_on_the_socket_it_came_for :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	testing.expect_value(t, answers_sent(false), 1)
}

@(test)
the_answer_a_change_of_folder_waited_for_is_not_lost :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	testing.expect_value(t, answers_sent(true), 1)
}

