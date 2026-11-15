package ocn

// The bench of the panels and of what is around them (answers_test.odin has the bench itself): shells as tabs of the dock, the page and its
// agents. What needs a window, a socket or a web view is not here: their logic is, in what those call. (The updates are the
// toolkit's Updater, tested there: gt:update's updater_test, its channels too.)

import tk_json "gt:json"
import "base:runtime"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sync"
import "core:testing"
import "gt:platform"
import "gt:term"
import store "gt:store"
import "gt:ui"
import remote "gt:remote"

@(private = "file")
shells :: proc(ids: ..string) -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, `{"data":[`)
	for id, i in ids { fmt.sbprintf(&b, `%s{{"id":%s,"title":"C:\\sh\\pwsh.exe","status":"running"}}`, i > 0 ? "," : "", tk_json.quote(id)) }
	strings.write_string(&b, `]}`)
	return strings.to_string(b)
}

// The panel opened on a server that has these shells.
@(private = "file")
open_shells :: proc(t: ^testing.T, app: ^App, ids: ..string, loc := #caller_location) {
	terminal_toggle(app)
	bench_answer(app, bench_take(t, .Pty_List, loc), 200, shells(..ids))
	for s in app.cx.terms.list { term_link_set(app, s, .Attached) }
	bench_clear(app)
}

// A shell as a build of the main window leaves it: shown, its grid in place, the keyboard on it.
@(private = "file")
built :: proc(app: ^App, s: ^Term, key: ui.Key, focused := true) {
	s.shown, s.view.box, s.built_in = true, key, &app.state
	s.view.rect = {{0, 0}, {800, 400}}
	s.view.metrics.cell_w, s.view.metrics.cell_h = 8, 16
	if focused {
		ui.set_focus(key)
		app.cx.terms.focused, app.cx.terms.last = s, s
	}
}

// Whether a shell's view is open ("": what stands there while there is none).
@(private = "file")
term_view_open :: proc(app: ^App, id: string) -> bool { return ui.view_is_open(&app.program_views, TERMINAL_VIEW, id) }

@(private = "file")
outbox :: proc(s: ^Term) -> string { return string(s.conn.out[:]) }

@(private = "file")
toasts :: proc(app: ^App) -> (n: int) {
	for &x in app.state.toasts { if x.alive { n += 1 } }
	return
}

@(private = "file")
BODY_ONE_SHELL :: `{"data":{"id":"new","title":"Terminal 1","status":"running"}}`

////////////////////////////////
// Shells are tabs

@(test)
each_shell_is_a_view_along_the_bottom :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	open_shells(t, app, "a", "b")
	s := &app.cx.terms
	testing.expect_value(t, len(s.list), 2)
	testing.expect(t, term_view_open(app, "a") && term_view_open(app, "b"), "each has its view")
	testing.expect_value(t, ui.view_presentation(&app.program_views, TERMINAL_VIEW, "a"), ui.View_Presentation.Panel)
	testing.expect(t, !term_view_open(app, ""), "nothing says Terminal over them")
	testing.expect_value(t, term_label(s.list[0]), "pwsh")
}

@(test)
what_stands_for_the_shells_gives_them_its_place :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	terminal_toggle(app)
	testing.expect(t, term_view_open(app, ""), "something says the list is being read")
	bench_answer(app, bench_take(t, .Pty_List), 200, shells("a"))
	testing.expect(t, !term_view_open(app, ""), "it goes")
	testing.expect(t, term_view_open(app, "a"), "the shell has its view")
}

@(test)
hiding_keeps_the_shells_showing_brings_them_back :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	pane := main_pane(app)
	open_shells(t, app, "a", "b")
	s := &app.cx.terms
	built(app, s.list[0], 11)
	terminal_toggle(app)
	testing.expect(t, !s.open, "hidden")
	testing.expect_value(t, len(s.list), 2)
	testing.expect_value(t, bench_count(.Action), 0)   // (no DELETE)
	testing.expect(t, !term_view_open(app, "a") && !term_view_open(app, "b"), "no view left")
	testing.expect(t, pane.composer.focus_next, "the keyboard goes back to the conversation")
	terminal_toggle(app)
	testing.expect(t, s.open, "shown")
	testing.expect(t, term_view_open(app, "a") && term_view_open(app, "b"), "both are back")
	testing.expect_value(t, bench_count(.Pty_List) + bench_count(.Pty_Made), 0)   // (nothing to read, nothing to make)
}

// The user's close of a shell's view closes the shell, as its tab's did.
@(test)
the_close_of_a_shells_view_closes_the_shell :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	open_shells(t, app, "a", "b")
	ui.views_command_run(&app.program_views, {id = TERMINAL_VIEW, instance = "a", act = .Close})
	views_answers(app)
	r := bench_take(t, .Action)
	testing.expect_value(t, r.method, "DELETE")
	testing.expect(t, strings.has_prefix(r.path, "/api/pty/a"), "that shell")
	bench_answer(app, r, 200, "")
	testing.expect(t, term_find(app, "a") == nil && term_find(app, "b") != nil)
	terminals_reap(app)
}

// Shift+Insert is the terminals' other paste, Ctrl+Insert their other copy: the program's, not keys sent to the shell (Insert
// would reach it as "\x1b[2~").
@(test)
shift_insert_pastes_ctrl_insert_copies :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	open_shells(t, app, "a")
	s := app.cx.terms.list[0]
	built(app, s, 11)
	for mods in ([2]platform.Modifiers{{.Shift}, {.Ctrl}}) {
		ev := []platform.Event{{kind = .Key_Press, key = .Insert, mods = mods}}
		testing.expect_value(t, len(term_events(app, &app.state, ev)), 0)
	}
	testing.expect(t, !strings.contains(outbox(s), "[2~"), "no Insert key sent to the shell")
}

@(test)
the_toggle_key_reaches_the_program_from_inside_a_shell :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	open_shells(t, app, "a")
	s := app.cx.terms.list[0]
	built(app, s, 11)
	ev := []platform.Event{{kind = .Key_Press, key = .T, mods = {.Ctrl, .Shift}}}
	testing.expect_value(t, len(term_events(app, &app.state, ev)), 1)
	testing.expect_value(t, outbox(s), "")
}

@(test)
closing_a_tab_closes_its_shell_the_last_one_the_area :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	open_shells(t, app, "a", "b")
	s := &app.cx.terms
	term_close(app, s.list[0])
	r := bench_take(t, .Action)
	testing.expect_value(t, r.method, "DELETE")
	testing.expect(t, strings.has_prefix(r.path, "/api/pty/a"), "that shell")
	bench_answer(app, r, 200, "")
	testing.expect(t, s.open, "the other stays")
	term_close(app, s.list[0])
	bench_answer(app, bench_take(t, .Action), 200, "")
	testing.expect(t, !s.open, "nothing left: the area closes")
	testing.expect_value(t, len(s.list), 0)
	testing.expect(t, !term_view_open(app, "a") && !term_view_open(app, "b") && !term_view_open(app, ""), "no view left")
	terminals_reap(app)
}

// A shell closed in a frame was built in it: its box draws it once more.
@(test)
a_shell_closed_stays_until_the_frame_is_drawn :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	open_shells(t, app, "a")
	s := app.cx.terms.list[0]
	term_close(app, s)
	testing.expect_value(t, len(app.cx.terms.gone), 1)
	testing.expect_value(t, s.id, "a")
	terminals_reap(app)
	testing.expect_value(t, len(app.cx.terms.gone), 0)
	bench_clear(app)
}

@(test)
what_ended_shows_it_and_can_restart :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	open_shells(t, app, "a", "b")
	s := app.cx.terms.list[0]
	term_link_set(app, s, .Closed)
	testing.expect(t, strings.contains(term_label(s), "(ended)"), "its tab says it")
	term_restart(app, s)
	term_restart(app, s)   // (a double click)
	r := bench_take(t, .Pty_Made)
	testing.expect_value(t, bench_count(.Pty_Made), 0)
	bench_answer(app, r, 200, BODY_ONE_SHELL)
	testing.expect_value(t, bench_count(.Action), 0)   // (nothing to close: it ended)
	testing.expect(t, !term_view_open(app, "a"), "the old view went")
	n := term_find(app, "new")
	testing.expect(t, n != nil, "the new shell is there")
	testing.expect(t, term_view_open(app, "new"), "with its view")
}

////////////////////////////////
// Focus and visibility

@(test)
a_hidden_shell_takes_no_key :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	open_shells(t, app, "a")
	s := app.cx.terms.list[0]
	built(app, s, 11)
	testing.expect(t, app.cx.terms.focused == s, "it has the keyboard")
	// (under another tab: the next build does not build it)
	terminals_begin(app)
	terminals_end(app)
	testing.expect(t, app.cx.terms.focused == nil, "nobody has it")
	ev := []platform.Event{{kind = .Text, text = 'x'}, {kind = .Key_Press, key = .Return}}
	testing.expect_value(t, len(term_events(app, &app.state, ev)), 2)
	testing.expect_value(t, outbox(s), "")
}

@(test)
a_hidden_shell_takes_no_wheel_nor_press :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	open_shells(t, app, "a")
	s := app.cx.terms.list[0]
	built(app, s, 11)
	terminals_begin(app)
	terminals_end(app)
	ev := []platform.Event{{kind = .Scroll, pos = {10, 10}, delta = {0, 1}}, {kind = .Mouse_Press, pos = {10, 10}, button = .Left}}
	testing.expect_value(t, len(term_events(app, &app.state, ev)), 2)
	testing.expect(t, s.view.press != .Select, "no selection begins on it")
	testing.expect(t, app.cx.terms.pressed == nil, "nothing held")
}

@(test)
an_answer_does_not_take_the_keyboard :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	ui.set_focus(5)
	terminal_toggle(app)
	bench_answer(app, bench_take(t, .Pty_List), 200, shells())
	ui.set_focus(7)   // (the composer, while the shell was being made)
	bench_answer(app, bench_take(t, .Pty_Made), 200, BODY_ONE_SHELL)
	s := term_find(app, "new")
	testing.expect(t, !term_takes_focus(&app.cx.terms, s, ui.focus_key()), "the reader went elsewhere")
	testing.expect(t, !app.cx.terms.ask.on, "and it is not asked for again")
}

@(test)
what_the_user_asked_for_takes_the_keyboard :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	ui.set_focus(5)
	terminal_toggle(app)
	bench_answer(app, bench_take(t, .Pty_List), 200, shells())
	bench_answer(app, bench_take(t, .Pty_Made), 200, BODY_ONE_SHELL)
	testing.expect(t, term_takes_focus(&app.cx.terms, term_find(app, "new"), ui.focus_key()), "the shell asked for")
}

// (seen in the window: the shell on screen took the request, and the new one came without the keyboard)
@(test)
a_new_shell_gets_the_keyboard_the_one_shown_does_not :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	open_shells(t, app, "a")
	s := &app.cx.terms
	old := s.list[0]
	ui.set_focus(5)
	s.ask = {}
	term_create(app)
	testing.expect(t, !term_takes_focus(s, old, ui.focus_key()), "the next build of the one shown asks first")
	bench_answer(app, bench_take(t, .Pty_Made), 200, BODY_ONE_SHELL)
	testing.expect(t, term_takes_focus(s, term_find(app, "new"), ui.focus_key()), "the new one has it")
}

@(test)
what_is_found_is_what_was_asked_for :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	ui.set_focus(5)
	terminal_toggle(app)
	bench_answer(app, bench_take(t, .Pty_List), 200, shells("a", "b"))
	testing.expect(t, term_takes_focus(&app.cx.terms, term_find(app, "b"), ui.focus_key()), "the last one, shown")
}

////////////////////////////////
// Servers

@(test)
leaving_a_server_lets_go_of_its_shells :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	open_shells(t, app, "a")
	s := &app.cx.terms
	conn := s.list[0].conn
	server_forget(app)
	testing.expect_value(t, len(s.list), 0)
	testing.expect(t, sync.atomic_load(&conn.stop), "its thread stops")
	testing.expect_value(t, bench_count(.Action), 0)   // (it runs on, there)
	testing.expect(t, !term_view_open(app, "a"), "no view left")
	testing.expect(t, !s.open, "and no shell is made on the next server for this")
	testing.expect_value(t, s.read.state, remote.State.Idle)
	terminals_reap(app)
}

@(test)
what_is_asked_of_a_shell_goes_to_its_server :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	open_shells(t, app, "a")
	s := app.cx.terms.list[0]
	home := app.conn
	app.conn = bench_conn(app)   // (however it came to be another)
	term.size_set(&s.view, 100, 30, {8, 16})
	testing.expect(t, bench_take(t, .Pty_Size).conn == home, "the size")
	term_close(app, s)
	testing.expect(t, bench_take(t, .Action).conn == home, "the DELETE")
	app.conn = home
	bench_sent_clear_pending(app, 2)
	terminals_reap(app)
}

// (for what bench_take took and the test does not answer)
@(private = "file")
bench_sent_clear_pending :: proc(app: ^App, n: i32) { app.pending -= n }

@(test)
a_list_that_failed_is_read_again_when_the_server_answers :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	terminal_toggle(app)
	bench_lost(app, bench_take(t, .Pty_List))
	testing.expect(t, remote.failed(&app.cx.terms.read), "said in the panel")
	testing.expect_value(t, toasts(app), 0)
	app.link = .Retrying
	stream_up(app)
	testing.expect_value(t, bench_count(.Pty_List), 1)
	bench_clear(app)
}

@(test)
a_list_from_a_server_left_makes_nothing :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	terminal_toggle(app)
	r := bench_take(t, .Pty_List)
	server_forget(app)
	app.conn = bench_conn(app)
	bench_answer(app, r, 200, shells("a"))
	testing.expect_value(t, len(app.cx.terms.list), 0)
	testing.expect_value(t, bench_count(.Pty_Made), 0)
}

@(test)
a_shell_made_on_a_server_left_does_not_stay_there :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	terminal_toggle(app)
	bench_answer(app, bench_take(t, .Pty_List), 200, shells())
	r := bench_take(t, .Pty_Made)
	left := app.conn
	server_forget(app)
	app.conn = bench_conn(app)
	bench_answer(app, r, 200, BODY_ONE_SHELL)
	testing.expect_value(t, len(app.cx.terms.list), 0)
	d := bench_take(t, .Action)
	testing.expect_value(t, d.method, "DELETE")
	testing.expect(t, d.conn == left, "asked of that server")
	testing.expect(t, strings.has_prefix(d.path, "/api/pty/new"), "that shell")
	app.pending -= 1
}

@(test)
new_while_the_list_is_read_makes_one_shell :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	terminal_toggle(app)
	term_create(app)   // (the + of the panel, the list on its way)
	testing.expect_value(t, bench_count(.Pty_Made), 0)
	bench_answer(app, bench_take(t, .Pty_List), 200, shells())
	testing.expect_value(t, bench_count(.Pty_Made), 1)
	r := bench_take(t, .Pty_Made)
	term_create(app)   // (and again, that one on its way)
	testing.expect_value(t, bench_count(.Pty_Made), 0)
	bench_answer(app, r, 200, BODY_ONE_SHELL)
	testing.expect_value(t, len(app.cx.terms.list), 1)
}

////////////////////////////////
// A shell's link

@(test)
what_is_typed_with_no_socket_goes_nowhere :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	open_shells(t, app, "a")
	s := app.cx.terms.list[0]
	term_send(s, "ls")
	term_link_set(app, s, .Lost)
	testing.expect_value(t, outbox(s), "")   // (what waited will not run later, unseen)
	term_send(s, "rm -rf x\r")
	testing.expect_value(t, outbox(s), "")
	term_link_set(app, s, .Closed)
	term_send(s, "x")
	testing.expect_value(t, outbox(s), "")
}

@(test)
what_waits_for_a_first_socket_is_bounded :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	terminal_toggle(app)
	bench_answer(app, bench_take(t, .Pty_List), 200, shells("a"))
	s := app.cx.terms.list[0]
	testing.expect_value(t, s.link, Term_Link.Connecting)
	big := strings.repeat("x", TERM_OUT_MAX / 2 + 1, context.temp_allocator)
	term_send(s, big)
	term_send(s, big)
	testing.expect_value(t, len(s.conn.out), len(big))
}

@(test)
the_cursor_counts_as_the_server_does :: proc(t: ^testing.T) {
	c: Term_Conn
	testing.expect(t, !term_frame(&c, "\x00{\"cursor\":120}"), "where the server is: no output")
	testing.expect_value(t, c.cursor, i64(120))
	testing.expect(t, term_frame(&c, "abc"), "output")
	testing.expect_value(t, c.cursor, i64(123))
	_ = term_frame(&c, "é")           // (one unit, two bytes)
	testing.expect_value(t, c.cursor, i64(124))
	_ = term_frame(&c, "\U0001F600")  // (two units, four bytes)
	testing.expect_value(t, c.cursor, i64(126))
}

@(test)
the_list_says_whether_a_shell_is_over :: proc(t: ^testing.T) {
	body := `{"data":[{"id":"a","status":"running"},{"id":"b","status":"exited"}]}`
	testing.expect(t, term_listed(body, "a"), "running")
	testing.expect(t, !term_listed(body, "b"), "exited")
	testing.expect(t, !term_listed(body, "c"), "gone")
	testing.expect(t, term_listed("not json", "a"), "nothing can be said: tried again")
}

@(test)
the_waits_grow_and_stop_growing :: proc(t: ^testing.T) {
	testing.expect_value(t, term_backoff_ms(1), TERM_RETRY_MS)
	testing.expect_value(t, term_backoff_ms(2), TERM_RETRY_MS * 2)
	testing.expect_value(t, term_backoff_ms(TERM_RETRIES), TERM_RETRY_MOST_MS)
	testing.expect_value(t, term_backoff_ms(100), TERM_RETRY_MOST_MS)
}

@(test)
a_socket_given_up_on_comes_back_with_the_server :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	open_shells(t, app, "a")
	s := app.cx.terms.list[0]
	term_link_set(app, s, .Lost, given_up = true)
	testing.expect(t, strings.contains(term_label(s), "(lost)"), "its tab says it")
	app.link = .Retrying
	stream_up(app)
	testing.expect_value(t, s.link, Term_Link.Connecting)
	testing.expect(t, !s.given_up, "a thread is on it")
	bench_clear(app)
}

@(test)
a_size_goes_once_the_grid_has_rested :: proc(t: ^testing.T) {
	testing.expect(t, term_size_rested(1000, 1000, false), "the first at once")
	testing.expect(t, !term_size_rested(1000 + TERM_SIZE_QUIET_MS - 1, 1000, true), "not while it moves")
	testing.expect(t, term_size_rested(1000 + TERM_SIZE_QUIET_MS, 1000, true), "then it goes")
}

@(test)
the_picture_waits_for_what_a_shell_paints :: proc(t: ^testing.T) {
	testing.expect(t, !term_painting(5000, 0, 0, 0), "nothing awaited")
	testing.expect(t, term_painting(5000, 0, 0, 4990), "its size is on its way")
	testing.expect(t, !term_painting(5000 + TERM_PAINT_MOST_MS, 0, 0, 5000), "an answer that never comes holds nothing for good")
	testing.expect(t, term_painting(5010, 5000, 0, 0), "told, it paints")
	testing.expect(t, term_painting(5100, 5000, 5090, 0), "it goes on writing")
	testing.expect(t, !term_painting(5000 + TERM_PAINT_QUIET_MS, 5000, 0, 0), "a shell with nothing to paint")
	testing.expect(t, !term_painting(5000 + TERM_PAINT_MOST_MS, 5000, 5000 + TERM_PAINT_MOST_MS - 1, 0), "one that never stops writing holds nothing for good")
}

@(test)
only_the_last_size_goes_one_at_a_time :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	open_shells(t, app, "a")
	s := app.cx.terms.list[0]
	term.size_set(&s.view, 100, 30, {8, 16})
	term.size_set(&s.view, 110, 30, {8, 16})
	term.size_set(&s.view, 120, 40, {8, 16})
	testing.expect_value(t, bench_count(.Pty_Size), 1)
	first := bench_take(t, .Pty_Size)
	testing.expect(t, strings.contains(first.body, `"cols":100`), "the first")
	bench_answer(app, first, 200, "")
	testing.expect_value(t, bench_count(.Pty_Size), 0)   // (the grid has only just moved: the shell would paint for nothing)
	s.grid_ms = 0   // (it has rested)
	term_size_send(app, s)
	last := bench_take(t, .Pty_Size)
	testing.expect(t, strings.contains(last.body, `"cols":120`) && strings.contains(last.body, `"rows":40`), "then the last, none between")
	bench_answer(app, last, 200, "")
	testing.expect_value(t, bench_count(.Pty_Size), 0)
	term.size_set(&s.view, 120, 40, {8, 16})
	testing.expect_value(t, bench_count(.Pty_Size), 0)
}

@(test)
a_size_refused_is_not_asked_again_at_each_frame :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	open_shells(t, app, "a")
	s := app.cx.terms.list[0]
	term.size_set(&s.view, 100, 30, {8, 16})
	bench_answer(app, bench_take(t, .Pty_Size), 500, `{"message":"no"}`)
	term.size_set(&s.view, 100, 30, {8, 16})
	testing.expect_value(t, bench_count(.Pty_Size), 0)
	testing.expect_value(t, toasts(app), 0)
}

@(test)
a_shell_that_ended_has_no_size :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	open_shells(t, app, "a")
	s := app.cx.terms.list[0]
	term_link_set(app, s, .Closed)
	term.size_set(&s.view, 100, 30, {8, 16})
	testing.expect_value(t, bench_count(.Pty_Size), 0)
}

////////////////////////////////
// Selection and the mouse

// A drag from `from` to `to`, cells of the view.
@(private = "file")
drag_cells :: proc(s: ^Term, from, to: [2]int) {
	term.select_begin(&s.view, from)
	term.select_to(&s.view, to)
}

// The rows that come move the selected text up and out of the view: the selection stays on it, and a copy is that text.
@(test)
output_keeps_a_selection_on_its_text :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	open_shells(t, app, "a")
	s := app.cx.terms.list[0]
	term_feed(s, "alpha\r\nbravo charlie\r\n")
	drag_cells(s, {0, 1}, {4, 1})
	testing.expect_value(t, term.selection_text(&s.view), "bravo")
	for i in 0 ..< 3 * s.view.rows { term_feed(s, fmt.tprintf("line %d\r\n", i)) }
	testing.expect(t, term.has_selection(&s.view), "rows came: still selected")
	testing.expect_value(t, term.selection_text(&s.view), "bravo")
}

// The view moved by the wheel, the grid wrapped again: the selection is on the same text.
@(test)
the_wheel_and_a_new_size_keep_a_selection :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	open_shells(t, app, "a")
	s := app.cx.terms.list[0]
	for i in 0 ..< 60 { term_feed(s, fmt.tprintf("line %d\r\n", i)) }
	built(app, s, 11)
	drag_cells(s, {0, 2}, {6, 2})
	before := term.selection_text(&s.view)
	testing.expect(t, strings.has_prefix(before, "line "), "a line selected")
	ev := []platform.Event{{kind = .Scroll, pos = {10, 10}, delta = {0, -1}}}
	testing.expect_value(t, len(term_events(app, &app.state, ev)), 0)
	testing.expect_value(t, term.selection_text(&s.view), before)
	term.size_set(&s.view, 100, 30, {8, 16})
	testing.expect_value(t, term.selection_text(&s.view), before)
	bench_clear(app)
}

// A press let go on the cell it began on selects nothing; Select all takes the scrollback too.
@(test)
a_click_selects_nothing_and_select_all_takes_the_scrollback :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	open_shells(t, app, "a")
	s := app.cx.terms.list[0]
	for i in 0 ..< 60 { term_feed(s, fmt.tprintf("line %d\r\n", i)) }
	drag_cells(s, {3, 3}, {3, 3})
	testing.expect(t, !term.has_selection(&s.view), "a click")
	term.select_all(&s.view)
	all := term.selection_text(&s.view)
	testing.expectf(t, strings.has_prefix(all, "line 0\n") && strings.contains(all, "line 59"), "all of it: %q", all)
	term.selection_drop(&s.view)
	testing.expect(t, !term.has_selection(&s.view), "dropped")
}

@(test)
a_drag_ends_when_a_menu_opens :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	open_shells(t, app, "a")
	s := app.cx.terms.list[0]
	built(app, s, 11)
	ev := []platform.Event{{kind = .Mouse_Press, pos = {10, 10}, button = .Left}}
	_ = term_events(app, &app.state, ev)
	testing.expect(t, s.view.press == .Select, "it began")
	help_open(app)
	_ = term_events(app, &app.state, nil)
	testing.expect(t, s.view.press != .Select, "the release will not come here")
	testing.expect(t, app.cx.terms.pressed == nil, "nothing held")
}

@(test)
a_drag_ends_when_what_is_held_is_another_box :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	open_shells(t, app, "a")
	s := app.cx.terms.list[0]
	built(app, s, 11)
	ev := []platform.Event{{kind = .Mouse_Press, pos = {10, 10}, button = .Left}}
	_ = term_events(app, &app.state, ev)
	app.state.active_key[.Left] = 99
	terminals_end(app)
	testing.expect(t, s.view.press != .Select, "it stops")
}

@(test)
a_program_hears_the_release_outside_the_grid :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	open_shells(t, app, "a")
	s := app.cx.terms.list[0]
	built(app, s, 11)
	term_feed(s, "\x1b[?1000h")
	press := []platform.Event{{kind = .Mouse_Press, pos = {10, 10}, button = .Left}}
	_ = term_events(app, &app.state, press)
	testing.expect(t, outbox(s) != "", "the press")
	clear(&s.conn.out)
	release := []platform.Event{{kind = .Mouse_Release, pos = {5000, 10}, button = .Left}}
	_ = term_events(app, &app.state, release)
	testing.expect(t, outbox(s) != "", "the release, wherever the pointer went")
	testing.expect(t, app.cx.terms.pressed == nil, "nothing held")
}

@(test)
a_program_hears_the_release_when_the_shell_goes :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	open_shells(t, app, "a")
	s := app.cx.terms.list[0]
	built(app, s, 11)
	term_feed(s, "\x1b[?1000h")
	press := []platform.Event{{kind = .Mouse_Press, pos = {10, 10}, button = .Left}}
	_ = term_events(app, &app.state, press)
	clear(&s.conn.out)
	terminals_begin(app)
	terminals_end(app)
	testing.expect(t, outbox(s) != "", "or it stays held for ever")
}

////////////////////////////////
// The panels

@(test)
closing_the_preview_leaves_no_view :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	open_shells(t, app, "a")
	preview_show(app)
	testing.expect(t, ui.view_is_open(&app.program_views, PREVIEW_VIEW), "its view")
	preview_close(app)
	testing.expect(t, !app.preview.open, "closed")
	testing.expect(t, !ui.view_is_open(&app.program_views, PREVIEW_VIEW), "and its view with it")
	testing.expect(t, term_view_open(app, "a"), "the shells stay")
}

// The user's close of the Preview's view (its cross, its menu, the palette) is the program's close.
@(test)
the_close_of_the_previews_view_closes_the_preview :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	preview_show(app)
	ui.views_command_run(&app.program_views, {id = PREVIEW_VIEW, act = .Close})
	views_answers(app)
	testing.expect(t, !app.preview.open)
	testing.expect_value(t, len(app.preview.tabs), 1)   // (closed is not forgotten: Ctrl+Shift+B brings it)
}

@(test)
what_an_agent_opens_leaves_the_keyboard_where_it_is :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	preview_show(app, .Agent)
	testing.expect(t, !preview_front(&app.preview).focus_address, "the address bar stays out of it")
	preview_close(app)
	preview_show(app)
	testing.expect(t, preview_front(&app.preview).focus_address, "what the user opens takes it")
}

////////////////////////////////
// What the web view says

@(test)
what_the_view_says_waits_for_its_point_of_the_frame :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	// (in the middle of a build: what was made in the frame's memory stays, and nothing moves)
	kept := fmt.tprintf("frame %d", 12)
	web_said(app, .Title, 0, transmute([]u8)string("A title"))
	web_said(app, .Ready, 0, nil)
	testing.expect_value(t, kept, "frame 12")
	tab := preview_front(&app.preview)
	testing.expect_value(t, tab.title, "")
	_, early := tab.web.(Web_Ready)
	testing.expect(t, !early, "not yet")
	web_events_drain(app)
	testing.expect_value(t, tab.title, "A title")
	_, ready := tab.web.(Web_Ready)
	testing.expect(t, ready, "now")
	testing.expect_value(t, len(tab.view.events), 0)
}

@(test)
what_the_view_says_owns_its_words :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	b := [4]u8{'a', 'b', 'c', 'd'}
	web_said(app, .Title, 0, b[:])
	b[0] = 'z'
	web_events_drain(app)
	testing.expect_value(t, preview_front(&app.preview).title, "abcd")
}

@(test)
overlapping_navigations_each_count :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	web_said(app, .Nav_Start, 1, nil)
	p := preview_front(&app.preview)
	web_said(app, .Nav_Start, 2, nil)
	web_said(app, .Nav_Start, 2, nil)   // (redirected)
	web_events_drain(app)
	done := [1]u8{0}
	web_said(app, .Loaded, 1, done[:])
	web_events_drain(app)
	testing.expect(t, preview_loading(p), "the second still loads")
	done[0] = 1
	web_said(app, .Loaded, 2, done[:])
	web_events_drain(app)
	testing.expect(t, !preview_loading(p), "over")
}

@(test)
a_failed_view_says_why_and_can_start_again :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	web_said(app, .Failed, 0, transmute([]u8)string("no runtime"))
	web_events_drain(app)
	tab := preview_front(&app.preview)
	f, failed := tab.web.(Web_Failed)
	testing.expect(t, failed, "failed")
	testing.expect_value(t, f.why, "no runtime")
	web_start(app, tab)
	_, still := tab.web.(Web_Failed)
	testing.expect(t, !still, "a failure holds for that attempt")
}

@(test)
a_server_left_takes_the_page_with_it :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	preview_show(app)
	tab := preview_front(&app.preview)
	tab.web = Web_Ready{}
	preview_set_url(app, tab, "http://a.local/secret")
	preview_set_title(tab, "Of server A")
	web_said(app, .Title, 0, transmute([]u8)string("late"))
	append(&tab.navs, 3)
	server_forget(app)
	p := &app.preview
	testing.expect(t, !p.open, "closed")
	testing.expect(t, !ui.view_is_open(&app.program_views, PREVIEW_VIEW), "no view")
	testing.expect_value(t, len(p.tabs), 0)
	testing.expect_value(t, len(app.previews.views), 0)
	web_events_drain(app)
	testing.expect_value(t, len(p.tabs), 0)
}

////////////////////////////////
// The agents' browser

@(private = "file")
bench_link :: proc(app: ^App) -> ^Browser_Link {
	l := new(Browser_Link)
	l.conn = app.conn
	l.socket, l.serial = 1, 1
	app.conn.browser = l
	app.preview.open = true
	tab := preview_front_made(app, &app.preview)
	web_start(app, tab)
	web_state_set(tab, Web_Ready{})
	return l
}

@(private = "file")
sent :: proc(l: ^Browser_Link) -> string {
	b := strings.builder_make(context.temp_allocator)
	for o in l.outbox {
		strings.write_string(&b, o.text)
		delete(o.text)
	}
	clear(&l.outbox)
	return strings.to_string(b)
}

@(private = "file")
call :: proc(app: ^App, l: ^Browser_Link, id: int, name: string, socket: u64 = 1) {
	browser_message(app, {l, socket}, fmt.tprintf(`{{"jsonrpc":"2.0","id":%d,"method":"tools/call","params":{{"name":%s,"arguments":{{"url":"http://x"}}}}}}`, id, tk_json.quote(name)))
}

@(test)
a_load_answers_only_for_its_navigation :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	l := bench_link(app)
	web_said(app, .Nav_Start, 5, nil)   // (what the page was doing on its own)
	web_events_drain(app)
	call(app, l, 1, "navigate")
	web_said(app, .Nav_Start, 6, nil)   // (the call's)
	web_events_drain(app)
	done := [1]u8{0}
	web_said(app, .Loaded, 5, done[:])
	web_events_drain(app)
	testing.expect_value(t, sent(l), "")
	testing.expect_value(t, len(app.browser.calls), 1)
	done[0] = 1
	web_said(app, .Loaded, 6, done[:])
	web_events_drain(app)
	testing.expect(t, strings.contains(sent(l), `"id":1`), "its own one")
	testing.expect_value(t, len(app.browser.calls), 0)
}

@(test)
two_loads_have_a_navigation_each :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	l := bench_link(app)
	call(app, l, 1, "navigate")
	call(app, l, 2, "reload")
	web_said(app, .Nav_Start, 7, nil)
	web_said(app, .Nav_Start, 8, nil)
	web_events_drain(app)
	done := [1]u8{1}
	web_said(app, .Loaded, 8, done[:])
	web_events_drain(app)
	answer := sent(l)
	testing.expect(t, strings.contains(answer, `"id":2`) && !strings.contains(answer, `"id":1`), "the second, alone")
}

@(test)
no_history_is_said_at_once :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	l := bench_link(app)
	call(app, l, 1, "back")
	testing.expect(t, strings.contains(sent(l), "no page to go back to"), "not after 30 s")
	testing.expect_value(t, len(app.browser.calls), 0)
}

@(test)
the_tab_says_its_real_history :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	l := bench_link(app)
	call(app, l, 1, "tabs_list")
	answer := sent(l)
	testing.expect(t, strings.contains(answer, `canGoBack\":false`), answer)
}

@(test)
an_answer_goes_on_the_socket_of_its_call :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	l := bench_link(app)
	call(app, l, 1, "evaluate")
	testing.expect_value(t, len(app.browser.calls), 1)
	c := app.browser.calls[0]
	testing.expect_value(t, c.to.socket, u64(1))
	w := c.wait.(Wait_Script)
	sync.atomic_store(&l.socket, 2)   // (the folder moved: another socket)
	browser_script_done(app, c.view, w.id, `"result"`)
	testing.expect_value(t, sent(l), "")   // (the agent of that one did not ask)
}

@(test)
the_calls_of_a_socket_gone_go_with_it :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	l := bench_link(app)
	call(app, l, 1, "evaluate")
	browser_calls_drop(app, {l, 1})
	testing.expect_value(t, len(app.browser.calls), 0)
}

@(test)
a_message_of_another_socket_is_not_served :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	l := bench_link(app)
	call(app, l, 1, "tabs_list", socket = 9)
	testing.expect_value(t, sent(l), "")
	other := new(Browser_Link)
	other.socket = 1
	call(app, other, 1, "tabs_list")
	testing.expect_value(t, len(other.outbox), 0)
}

@(test)
a_server_left_forgets_its_calls :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	l := bench_link(app)
	call(app, l, 1, "evaluate")
	server_forget(app)
	testing.expect_value(t, len(app.browser.calls), 0)
}

@(test)
each_connection_has_its_folder :: proc(t: ^testing.T) {
	a, b: Browser_Link
	defer delete(a.dir)
	browser_link_follow(&a, "C:/a")
	path, _ := browser_link_target(&b)
	testing.expect(t, !strings.contains(path, "C%3A"), "the next server is not offered the last one's")
	delete(path)
}

// A move between the reading of the folder and the socket's opening is seen by that socket.
@(test)
a_move_after_the_target_is_a_move :: proc(t: ^testing.T) {
	l: Browser_Link
	defer delete(l.dir)
	browser_link_follow(&l, "C:/a")
	path, moved := browser_link_target(&l)
	delete(path)
	testing.expect(t, !browser_link_moved(&l, moved), "nothing yet")
	browser_link_follow(&l, "C:/a")
	testing.expect(t, !browser_link_moved(&l, moved), "the same folder is no move")
	browser_link_follow(&l, "C:/b")
	testing.expect(t, browser_link_moved(&l, moved), "that one is")
}

@(test)
the_preference_holds_at_once :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	l := bench_link(app)
	app.prefs.browser_tools = false
	call(app, l, 1, "evaluate")
	browser_tick(app)
	testing.expect(t, app.conn.browser == nil, "turned off")
	testing.expect(t, sync.atomic_load(&l.stop), "its thread stops")
	testing.expect_value(t, len(app.browser.calls), 0)
}

@(test)
a_call_runs_out_with_the_window_at_rest :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	l := bench_link(app)
	app.prefs.browser_tools = true
	testing.expect_value(t, browser_in_ms(app), 0)   // (nothing pending: no wake)
	call(app, l, 1, "evaluate")
	testing.expect_value(t, browser_in_ms(app), BROWSER_CALL_S * 1000 + 1)
	bench_clock += BROWSER_CALL_S * 1000
	browser_tick(app)
	testing.expect(t, strings.contains(sent(l), "did not answer in time"), "said")
	testing.expect_value(t, browser_in_ms(app), 0)
}

@(test)
a_view_that_fails_answers_what_waits_and_says_why :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	l := bench_link(app)
	call(app, l, 1, "navigate")
	web_said(app, .Failed, 0, transmute([]u8)string("no runtime"))
	web_events_drain(app)
	testing.expect(t, strings.contains(sent(l), "no runtime"), "the call that waited")
	testing.expect_value(t, len(app.browser.calls), 0)
	call(app, l, 2, "snapshot")
	answer := sent(l)
	testing.expect(t, strings.contains(answer, "no runtime") && !strings.contains(answer, "try again in a moment"), "not told to retry for ever")
}

////////////////////////////////
// Diffs
// (reading a patch is gt:diff's, tested there: tests/diff)

@(test)
what_a_call_counts_is_what_a_diff_shows :: proc(t: ^testing.T) {
	p: Part
	part_patch_set(&p, "--- a/f\n+++ b/f\n@@ -1,2 +1,2 @@\n--- x\n+++ y\n z\n", context.temp_allocator)
	testing.expect_value(t, p.added, 1)
	testing.expect_value(t, p.removed, 1)
	part_patch_set(&p, "---x\n+++y\n", context.temp_allocator)   // (made here: no headers, the lines "--x" and "++y")
	testing.expect_value(t, p.added, 1)
	testing.expect_value(t, p.removed, 1)
}

////////////////////////////////
// Passwords

@(test)
a_rename_with_the_keyring_locked_keeps_the_password :: proc(t: ^testing.T) {
	old := Server{name = "a", field = "sealed"}
	field, forget := server_password_moves(old, Server{name = "b"})
	testing.expect_value(t, forget, "")   // the only copy is not deleted
	testing.expect_value(t, field, "sealed")   // the field still leads to it
}

@(test)
what_the_old_name_held_goes_when_the_new_one_has_it :: proc(t: ^testing.T) {
	old := Server{name = "a", password = "p", field = "secret-service:v1:a"}
	field, forget := server_password_moves(old, Server{name = "b", password = "p"})
	testing.expect_value(t, field, "")
	testing.expect_value(t, forget, "secret-service:v1:a")   // after the save
}

// A server renamed while its keyring was locked keeps the item of its old name; renamed again once it opens, the item its field names
// goes, not the one its name names.
@(test)
a_rename_forgets_the_item_of_the_field :: proc(t: ^testing.T) {
	old := Server{name = "b", password = "p", field = "secret-service:v1:a"}
	_, forget := server_password_moves(old, Server{name = "c", password = "p"})
	testing.expect_value(t, forget, "secret-service:v1:a")
}

@(test)
a_password_removed_is_removed :: proc(t: ^testing.T) {
	_, forget := server_password_moves(Server{name = "a", password = "p", field = "secret-service:v1:a"}, Server{name = "a"})
	testing.expect_value(t, forget, "secret-service:v1:a")   // nothing stays in the keyring
}

@(test)
the_same_name_keeps_its_password :: proc(t: ^testing.T) {
	field, forget := server_password_moves(Server{name = "a", field = "sealed"}, Server{name = "a"})
	testing.expect_value(t, field, "sealed")
	testing.expect_value(t, forget, "")   // left as it was
}

// The same name sealed again gives the same field (Linux: the item the seal just replaced): forgetting it would lose the new password.
@(test)
a_save_keeps_the_item_it_just_wrote :: proc(t: ^testing.T) {
	written := []Server{{name = "a", field = "secret-service:v1:a"}}
	testing.expect(t, !server_forget_after("secret-service:v1:a", written))
	testing.expect(t, server_forget_after("secret-service:v1:b", written))
	testing.expect(t, !server_forget_after("", written))
}

////////////////////////////////
// Images

@(test)
an_empty_file_ends_the_wait :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	path := filepath.join({os.get_env("TEMP", context.temp_allocator), "ocn_empty_image_test.png"}, context.temp_allocator) or_else ""
	testing.expect(t, os.write_entire_file(path, []u8{}) == nil, "the file")
	defer os.remove(path)
	image_view_start(app, path)
	image_view_wait(app)
	testing.expect_value(t, ui.wake_in_ms(&app.state), 0)   // (no frame after frame)
	testing.expect_value(t, app.viewer.start.key, u64(0))
	testing.expect_value(t, toasts(app), 1)
}

////////////////////////////////
// What lot 2 left

@(test)
what_was_chosen_does_not_cross_to_the_next_server :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	pane := main_pane(app)
	ui.text_edit_set(&pane.composer.area, "look at @a.txt")
	append(&pane.composer.mentions.chosen, Mention{.File, strings.clone("@a.txt"), strings.clone("file:///old/a.txt"), strings.clone("a.txt")})
	server_forget(app)
	testing.expect_value(t, len(pane.composer.mentions.chosen), 0)
	testing.expect_value(t, ui.text_edit_string(&pane.composer.area), "look at @a.txt")
}

@(test)
a_double_click_revokes_once :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	saved_revoke(app, "s1")
	saved_revoke(app, "s1")
	testing.expect_value(t, bench_count(.Saved_Done), 1)
	bench_lost(app, bench_take(t, .Saved_Done))
	testing.expect(t, !saved_revoking(&app.facts, "s1"), "it can be tried again")
	saved_revoke(app, "s1")
	testing.expect_value(t, bench_count(.Saved_Done), 1)
	bench_answer(app, bench_take(t, .Saved_Done), 200, "")
	testing.expect(t, !saved_revoking(&app.facts, "s1"), "over")
}

////////////////////////////////
// Shutdown

@(test)
closing_stops_every_connection_and_shell :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	open_shells(t, app, "a")
	first, second := bench_conn(app), bench_conn(app)
	l := bench_link(app)
	threads_stop(app)
	testing.expect(t, conn_stopped(first) && conn_stopped(second), "every connection")
	testing.expect(t, sync.atomic_load(&app.cx.terms.list[0].conn.stop), "the shells' threads")
	testing.expect(t, sync.atomic_load(&l.stop), "the browser's")
}

// A shell's zoom is its grid's zone (the interface routes the zoom keys and Ctrl+wheel to it): nothing goes to the shell,
// and it is kept by the shell's id: the program started again finds it on the same shell. Reset or closed: forgotten.
@(test)
each_shell_has_its_own_zoom_kept_by_its_id :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	tmp, _ := os.temp_dir(context.temp_allocator)
	file, _ := filepath.join({tmp, fmt.tprintf("ocn_term_zoom_%d.txt", os.get_pid())}, context.temp_allocator)
	os.remove(file)
	defer os.remove(file)
	app := bench_new()
	store.open(&app.stores.zooms, file, wait_ms = 0, most_ms = 0)
	open_shells(t, app, "a", "b")
	a, b := app.cx.terms.list[0], app.cx.terms.list[1]
	built(app, a, 11)
	ev := []platform.Event{{kind = .Key_Press, key = .Equal, mods = {.Ctrl}}}
	testing.expect_value(t, len(term_events(app, &app.state, ev)), 1)   // (left to the interface, which zooms the zone of the focus)
	testing.expect_value(t, outbox(a), "")
	// (each build marks a grid's zone with its shell's id: a bench builds nothing)
	ui.zoom_zone(&a.view.zone, a.id)
	ui.zoom_zone(&b.view.zone, b.id)
	ui.zoom_zone_by(&a.view.zone, 1.25)
	ui.zoom_zone_by(&b.view.zone, 0.8)
	testing.expect(t, ui.zoom_zone_value(&a.view.zone) > 1.05 && ui.zoom_zone_value(&b.view.zone) < 0.95, "each its own")
	// the program again: the same shells, their zooms
	store.flush(&app.stores.zooms)
	app2 := bench_new()
	store.open(&app2.stores.zooms, file)
	zooms_load(app2)
	store.close(&app2.stores.zooms)
	open_shells(t, app2, "a", "b")
	a2, b2 := app2.cx.terms.list[0], app2.cx.terms.list[1]
	testing.expect_value(t, ui.zoom_zone(&a2.view.zone, a2.id), ui.zoom_zone_value(&a.view.zone))
	testing.expect_value(t, ui.zoom_zone(&b2.view.zone, b2.id), ui.zoom_zone_value(&b.view.zone))
	// reset: forgotten; closed: forgotten
	ui.zoom_zone_reset(&a.view.zone)
	term_close(app, b)
	testing.expect_value(t, len(app.term_zooms.kept.values), 0)
	store.close(&app.stores.zooms)   // (what was set last, on the disk)
	data, _ := os.read_entire_file(file, context.temp_allocator)
	testing.expect_value(t, string(data), "")
}

// The start reads nothing on the interface's thread: where this computer's server runs (its files) and a saved server's password (the
// keyring) are read on a chore when a connection needs them (server_connect); until then the field waits as it is in the file.
@(test)
the_servers_start_with_nothing_read :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	defer store.close(&app.stores.servers)
	testing.expect(t, store.set(&app.stores.servers, "Work", "http://work:4096\tsecret-service:v1:Work"))
	servers_init(app)
	if !testing.expect_value(t, len(app.servers), 2) { return }
	here, work := app.servers[0], app.servers[1]
	testing.expect(t, here.local && here.url == "" && here.password == "", "this computer's address is not read yet")
	testing.expect_value(t, work.url, "http://work:4096")
	testing.expect_value(t, work.password, "")
	testing.expect_value(t, work.field, "secret-service:v1:Work")
	testing.expect(t, !app.servers_in_clear)
}
