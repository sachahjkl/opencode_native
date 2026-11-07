package occ

// What a review set out to break, and did: each case as it was shown, so that it stays mended. (The file of what is reviewed: a test that
// belongs to a feature lives with it.)

import "base:runtime"
import "core:fmt"
import "core:strings"
import "core:testing"
import "gt:platform"
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
	term_resize(app, s, 100, 30, 8, 16)
	bench_answer(app, bench_take(t, .Pty_Size), 200, "")
	bench_clock += 2000
	due_tick(app, .Term_Size)
	app.settle = 0

	cols := u16(100)
	for ms := 0; ms <= stop; ms += 10 {
		cols += 1
		term_resize(app, s, cols, 30, 8, 16)
		if ms < stop { bench_clock += 10 }
	}
	app.settle = FRAMES_AFTER_INPUT
	next_frame := bench_clock + 17
	for _ in 0 ..< 3000 {
		bench_clock += 1
		if deferred_in_ms(&app.cx.due[.Term_Size]) > 0 && bench_clock >= app.cx.due[.Term_Size].due_ms { due_tick(app, .Term_Size) }
		if app.settle > 0 && bench_clock >= next_frame {
			term_resize(app, s, cols, 30, 8, 16)   // (terminal_panel's term_fit, at each build)
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

@(test)
a_shell_in_its_window_still_hears_with_the_tabs_hidden :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	shells_open(t, app, "a", "b")
	s := &app.cx.terms
	b := s.list[1]
	d := new(Detached)
	d.panel = b.panel
	d.win = new(platform.Window)
	append(&app.cx.detached, d)
	b.detached = true
	ui.dock_close(&app.dock, b.panel)
	ui.dock_activate(&app.dock, s.list[0].panel)

	terminal_toggle(app)
	testing.expect(t, !s.open)
	testing.expect(t, panel_detached(app, b.panel))

	s.only, s.focused = b, b   // (what detached_frame does)
	ev := []platform.Event{{kind = .Text, text = 'x'}}
	_ = term_events(app, ev)
	s.only, s.focused = nil, nil
	testing.expect_value(t, string(b.conn.out[:]), "x")
}

// The banner's Close does not depend on a dock that is built: with the tabs hidden nothing is.
@(test)
the_close_of_a_shell_in_its_window_needs_no_dock :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	shells_open(t, app, "a")
	s := &app.cx.terms
	s.close_due = s.list[0].panel
	terms_close_due(app)
	testing.expect_value(t, s.close_due, u32(0))
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

// The address being typed in the panel's own window: its focus is in that window's state.
@(test)
what_is_typed_in_the_panels_window_stays_through_a_redirect :: proc(t: ^testing.T) {
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
	d := new(Detached)
	d.panel = u32(Panel.Preview)
	d.win = new(platform.Window)
	append(&app.cx.detached, d)
	app.preview.addr_key = 42
	d.state.focus_key = 42
	ui.field_set(&tab.field, "http://typing")
	web_event_add(tab.view, .Source, 0, transmute([]u8)string("http://redirected.local/"))
	web_events_drain(app)
	testing.expect_value(t, ui.field_string(&tab.field), "http://typing")
	clear(&app.cx.detached)
}

// Only a 404 says that a channel has nothing; a check that learned nothing leaves the offer.
@(test)
a_failed_check_is_no_news_of_the_update :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	testing.expect(t, update_says_missing(404, true))
	testing.expect(t, !update_says_missing(0, false), "no network")
	testing.expect(t, !update_says_missing(503, true))
	app := bench_new()
	app.prefs.update_channel = "stable"
	offer := new(Update_Offer)
	offer.manifest.version = strings.clone("9.9.9")
	offer.path, offer.channel = strings.clone("/x/"), strings.clone("stable")
	app.updater.state = Update_Ready{offer}
	when ODIN_OS == .Windows {
		update_check(app, true)
		j := bench_update_job
		bench_update_job = nil
		j.err = strings.clone("the server could not be read")
		update_answered(app, j)
		testing.expect(t, update_is_ready(&app.updater), "what is on offer stays")
		testing.expect(t, app.updater.result != "Up to date")
	}
}

// What a dialog holds came from the server left.
@(test)
leaving_a_server_closes_what_acts_on_its_sessions :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	app.delete_open, app.rename.open = true, true
	server_forget(app)
	testing.expect(t, !app.delete_open && !app.rename.open)
}

// A window's own needs reach the loop, which looks at the main state alone.
@(test)
what_a_window_waits_for_wakes_the_program :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	app.settle = 0
	s: ui.State
	ui.set_clock(&s, &bench_clock)
	s.wake_ms = 400
	detached_asks(app, &s, false)
	testing.expect_value(t, app.settle, 0)
	testing.expect(t, ui.wake_in_ms(&app.state) > 0, "the delay is the loop's too")
	detached_asks(app, &s, true)
	testing.expect_value(t, app.settle, FRAMES_AFTER_INPUT)
}

@(test)
a_panels_window_looks_as_the_main_one :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	m := &app.state
	ui.set_density(m, 1.2)
	ui.set_rounding(m, 0.5)
	m.mono_font = 7
	m.icon_font = 9
	app.prefs.autohide_scrollbars = true
	s: ui.State
	detached_style(app, &s)
	testing.expect_value(t, s.density, m.density)
	testing.expect_value(t, s.rounding, m.rounding)
	testing.expect_value(t, s.mono_font, m.mono_font)
	testing.expect_value(t, s.icon_font, m.icon_font)
	testing.expect(t, s.scrollbar_autohide)
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
	read = proc "c" (w: rawptr, out: ^Occ_Buf) -> i32 {
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

// A pointer passing over the main window builds nothing in the others; what they show changing, or their own input, does.
@(test)
a_window_of_its_own_rests_while_nothing_it_shows_changes :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	d := new(Detached)
	d.win = new(platform.Window)
	d.win.size, d.shown = {800, 600}, {800, 600}
	ui.set_clock(&d.state, &bench_clock)
	testing.expect(t, detached_still(app, d, false))
	testing.expect(t, !detached_still(app, d, true), "its own input")
	app.cx.shared_moved = true
	testing.expect(t, !detached_still(app, d, false), "what every window shows")
	app.cx.shared_moved = false
	d.win.size = {900, 600}
	testing.expect(t, !detached_still(app, d, false), "its size")
}
