package ocn

// The bench of the panels and of what is around them (answers_test.odin has the bench itself): shells as tabs of the dock, the page and its
// agents, the updater. What needs a window, a socket or a web view is not here: their logic is, in what those call.

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sync"
import "core:testing"
import "gt:platform"
import "gt:ui"

@(thread_local) bench_update_job: ^Update_Job

@(private = "file")
shells :: proc(ids: ..string) -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, `{"data":[`)
	for id, i in ids { fmt.sbprintf(&b, `%s{{"id":%s,"title":"C:\\sh\\pwsh.exe","status":"running"}}`, i > 0 ? "," : "", jquote(id)) }
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

// A shell as a build leaves it: shown, its grid in place.
@(private = "file")
built :: proc(app: ^App, s: ^Term, key: ui.Key, focused := true) {
	s.shown, s.box = true, key
	s.rect = {{0, 0}, {800, 400}}
	s.metrics.cell_w, s.metrics.cell_h = 8, 16
	if focused { ui.set_focus(key) }
	terminals_settle(app)
}

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
each_shell_is_a_tab_along_the_bottom :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	open_shells(t, app, "a", "b")
	d := &app.dock
	s := &app.cx.terms
	testing.expect_value(t, len(s.list), 2)
	testing.expect(t, ui.dock_has(d, s.list[0].panel) && ui.dock_has(d, s.list[1].panel), "each has its tab")
	testing.expect_value(t, ui.dock_leaf_of(d, s.list[0].panel), ui.dock_leaf_of(d, s.list[1].panel))
	testing.expect(t, ui.dock_leaf_of(d, s.list[0].panel) != ui.dock_leaf_of(d, u32(Panel.Conversation)), "beside the conversation")
	testing.expect(t, !ui.dock_has(d, u32(Panel.Terminal)), "no tab says Terminal over them")
	testing.expect_value(t, panel_title(app, s.list[0].panel), "pwsh")
	testing.expect(t, s.list[0].panel >= TERM_PANEL_BASE, "the panels of the enum stay apart")
}

@(test)
what_stands_for_the_shells_gives_them_its_place :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	pref_set(app, "layout.dock", "dock1 x0.700([*conversation] [*terminal])")   // (a layout of an earlier version)
	terminal_toggle(app)
	d := &app.dock
	place := ui.dock_leaf_of(d, u32(Panel.Terminal))
	testing.expect(t, place != ui.DOCK_NONE, "something says the list is being read")
	bench_answer(app, bench_take(t, .Pty_List), 200, shells("a"))
	s := app.cx.terms.list[0]
	testing.expect(t, !ui.dock_has(d, u32(Panel.Terminal)), "it goes")
	testing.expect(t, ui.dock_leaf_of(d, s.panel) != ui.dock_leaf_of(d, u32(Panel.Conversation)), "the shell stands where it stood")
}

@(test)
a_saved_layout_finds_its_shells_again_and_forgets_the_others :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	pref_set(app, "layout.dock", "dock1 x0.500([*conversation] y0.500([*shell-a] [*shell-gone]))")
	open_shells(t, app, "a")
	d := &app.dock
	s := app.cx.terms.list[0]
	testing.expect_value(t, len(ui.dock_leaves(d, d.main)), 2)   // (the stack of what is gone goes with it)
	testing.expect(t, ui.dock_has(d, s.panel), "the shell has its tab")
	testing.expect_value(t, d.nodes[d.main].axis, ui.Axis.X)   // (beside the conversation, as saved: not along the bottom)
	for leaf in ui.dock_leaves(d, d.main) { testing.expect(t, ui.dock_tab_count(d, leaf) > 0, "no empty stack") }
	testing.expect_value(t, panel_name(app, s.panel), "shell-a")
}

@(test)
a_layout_of_shells_gone_leaves_nothing_behind :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	pref_set(app, "layout.dock", "dock1 y0.700([*conversation] [*shell-x,shell-y])")
	dock_setup(app)
	d := &app.dock
	testing.expect_value(t, len(ui.dock_leaves(d, d.main)), 1)
	testing.expect(t, ui.dock_has(d, u32(Panel.Conversation)), "the conversation stays")
}

@(test)
hiding_keeps_the_shells_showing_brings_them_back :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	open_shells(t, app, "a", "b")
	s := &app.cx.terms
	panels := [2]u32{s.list[0].panel, s.list[1].panel}
	built(app, s.list[0], 11)
	terminal_toggle(app)
	testing.expect(t, !s.open, "hidden")
	testing.expect_value(t, len(s.list), 2)
	testing.expect_value(t, bench_count(.Action), 0)   // (no DELETE)
	testing.expect(t, !ui.dock_has(&app.dock, panels[0]) && !ui.dock_has(&app.dock, panels[1]), "no tab left")
	testing.expect(t, app.cx.focus_composer, "the keyboard goes back to the conversation")
	terminal_toggle(app)
	testing.expect(t, s.open, "shown")
	testing.expect(t, ui.dock_has(&app.dock, panels[0]) && ui.dock_has(&app.dock, panels[1]), "both are back")
	testing.expect_value(t, bench_count(.Pty_List) + bench_count(.Pty_Made), 0)   // (nothing to read, nothing to make)
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
		testing.expect_value(t, len(term_events(app, ev)), 0)
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
	testing.expect_value(t, len(term_events(app, ev)), 1)
	testing.expect_value(t, outbox(s), "")
}

@(test)
closing_a_tab_closes_its_shell_the_last_one_the_area :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	open_shells(t, app, "a", "b")
	s := &app.cx.terms
	panel_close(app, s.list[0].panel)
	r := bench_take(t, .Action)
	testing.expect_value(t, r.method, "DELETE")
	testing.expect(t, strings.has_prefix(r.path, "/api/pty/a"), "that shell")
	bench_answer(app, r, 200, "")
	testing.expect(t, s.open, "the other stays")
	panel_close(app, s.list[0].panel)
	bench_answer(app, bench_take(t, .Action), 200, "")
	testing.expect(t, !s.open, "nothing left: the area closes")
	testing.expect_value(t, len(s.list), 0)
	terminals_reap(app)
	dock_setup(app)
	testing.expect_value(t, len(ui.dock_leaves(&app.dock, app.dock.main)), 1)
}

// A shell closed in a frame was built in it: its box draws it once more.
@(test)
a_shell_closed_stays_until_the_frame_is_drawn :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	open_shells(t, app, "a")
	s := app.cx.terms.list[0]
	panel_close(app, s.panel)
	testing.expect_value(t, len(app.cx.terms.gone), 1)
	testing.expect_value(t, s.id, "a")
	terminals_reap(app)
	testing.expect_value(t, len(app.cx.terms.gone), 0)
	bench_clear(app)
}

@(test)
what_ended_shows_it_and_can_restart_in_its_tab :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	open_shells(t, app, "a", "b")
	s := app.cx.terms.list[0]
	panel := s.panel
	leaf := ui.dock_leaf_of(&app.dock, panel)
	term_link_set(app, s, .Closed)
	testing.expect(t, strings.contains(term_label(s), "(ended)"), "its tab says it")
	term_restart(app, s)
	term_restart(app, s)   // (a double click)
	r := bench_take(t, .Pty_Made)
	testing.expect_value(t, bench_count(.Pty_Made), 0)
	bench_answer(app, r, 200, BODY_ONE_SHELL)
	testing.expect_value(t, bench_count(.Action), 0)   // (nothing to close: it ended)
	testing.expect(t, !ui.dock_has(&app.dock, panel), "the old tab went")
	n := term_find(app, "new")
	testing.expect(t, n != nil, "the new shell is there")
	testing.expect_value(t, ui.dock_tabs(&app.dock, leaf)[0], n.panel)   // (in the same place of its strip)
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
	terminals_settle(app)
	testing.expect(t, app.cx.terms.focused == nil, "nobody has it")
	ev := []platform.Event{{kind = .Text, text = 'x'}, {kind = .Key_Press, key = .Return}}
	testing.expect_value(t, len(term_events(app, ev)), 2)
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
	terminals_settle(app)
	ev := []platform.Event{{kind = .Scroll, pos = {10, 10}, delta = {0, 1}}, {kind = .Mouse_Press, pos = {10, 10}, button = .Left}}
	testing.expect_value(t, len(term_events(app, ev)), 2)
	testing.expect(t, !s.selecting, "no selection begins on it")
	testing.expect_value(t, app.cx.terms.press, Term_Press.None)
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
	panel := s.list[0].panel
	conn := s.list[0].conn
	server_forget(app)
	testing.expect_value(t, len(s.list), 0)
	testing.expect(t, sync.atomic_load(&conn.stop), "its thread stops")
	testing.expect_value(t, bench_count(.Action), 0)   // (it runs on, there)
	testing.expect(t, !ui.dock_has(&app.dock, panel), "no tab left")
	testing.expect(t, !s.open, "and no shell is made on the next server for this")
	testing.expect_value(t, s.read.state, Load_State.Idle)
	terminals_reap(app)
}

@(test)
what_is_asked_of_a_shell_goes_to_its_server :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	open_shells(t, app, "a")
	s := app.cx.terms.list[0]
	home := app.conn
	app.conn = new(Conn)   // (however it came to be another)
	term_resize(app, s, 100, 30, 8, 16)
	testing.expect(t, bench_take(t, .Pty_Size).conn == home, "the size")
	panel_close(app, s.panel)
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
	testing.expect(t, remote_failed(&app.cx.terms.read), "said in the panel")
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
	app.conn = new(Conn)
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
	app.conn = new(Conn)
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
	term_resize(app, s, 100, 30, 8, 16)
	term_resize(app, s, 110, 30, 8, 16)
	term_resize(app, s, 120, 40, 8, 16)
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
	term_resize(app, s, 120, 40, 8, 16)
	testing.expect_value(t, bench_count(.Pty_Size), 0)
}

@(test)
a_size_refused_is_not_asked_again_at_each_frame :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	open_shells(t, app, "a")
	s := app.cx.terms.list[0]
	term_resize(app, s, 100, 30, 8, 16)
	bench_answer(app, bench_take(t, .Pty_Size), 500, `{"message":"no"}`)
	term_resize(app, s, 100, 30, 8, 16)
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
	term_resize(app, s, 100, 30, 8, 16)
	testing.expect_value(t, bench_count(.Pty_Size), 0)
}

////////////////////////////////
// Selection and the mouse

// A drag from `from` to `to`, cells of the view.
@(private = "file")
drag_cells :: proc(s: ^Term, from, to: [2]int) {
	term_select_begin(s, from)
	term_select_to(s, to)
	s.selecting = false
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
	testing.expect_value(t, term_selection_text(s), "bravo")
	for i in 0 ..< 3 * int(s.rows) { term_feed(s, fmt.tprintf("line %d\r\n", i)) }
	testing.expect(t, term_has_selection(s), "rows came: still selected")
	testing.expect_value(t, term_selection_text(s), "bravo")
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
	before := term_selection_text(s)
	testing.expect(t, strings.has_prefix(before, "line "), "a line selected")
	ev := []platform.Event{{kind = .Scroll, pos = {10, 10}, delta = {0, -1}}}
	testing.expect_value(t, len(term_events(app, ev)), 0)
	testing.expect_value(t, term_selection_text(s), before)
	term_resize(app, s, 100, 30, 8, 16)
	testing.expect_value(t, term_selection_text(s), before)
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
	testing.expect(t, !term_has_selection(s), "a click")
	term_select_all(s)
	all := term_selection_text(s)
	testing.expectf(t, strings.has_prefix(all, "line 0\n") && strings.contains(all, "line 59"), "all of it: %q", all)
	term_selection_drop(s)
	testing.expect(t, !term_has_selection(s), "dropped")
}

@(test)
a_drag_ends_when_a_menu_opens :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	open_shells(t, app, "a")
	s := app.cx.terms.list[0]
	built(app, s, 11)
	ev := []platform.Event{{kind = .Mouse_Press, pos = {10, 10}, button = .Left}}
	_ = term_events(app, ev)
	testing.expect(t, s.selecting, "it began")
	app.cx.help_open = true
	_ = term_events(app, nil)
	testing.expect(t, !s.selecting, "the release will not come here")
	testing.expect_value(t, app.cx.terms.press, Term_Press.None)
}

@(test)
a_drag_ends_when_what_is_held_is_another_box :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	open_shells(t, app, "a")
	s := app.cx.terms.list[0]
	built(app, s, 11)
	ev := []platform.Event{{kind = .Mouse_Press, pos = {10, 10}, button = .Left}}
	_ = term_events(app, ev)
	app.state.active_key[.Left] = 99
	terminals_settle(app)
	testing.expect(t, !s.selecting, "it stops")
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
	_ = term_events(app, press)
	testing.expect(t, outbox(s) != "", "the press")
	clear(&s.conn.out)
	release := []platform.Event{{kind = .Mouse_Release, pos = {5000, 10}, button = .Left}}
	_ = term_events(app, release)
	testing.expect(t, outbox(s) != "", "the release, wherever the pointer went")
	testing.expect_value(t, app.cx.terms.press, Term_Press.None)
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
	_ = term_events(app, press)
	clear(&s.conn.out)
	terminals_begin(app)
	terminals_settle(app)
	testing.expect(t, outbox(s) != "", "or it stays held for ever")
}

////////////////////////////////
// The panels

@(test)
closing_the_preview_leaves_no_tab :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	open_shells(t, app, "a")   // (the dock stays: the ghost would be seen)
	preview_show(app)
	testing.expect(t, ui.dock_has(&app.dock, u32(Panel.Preview)), "its tab")
	panel_close(app, u32(Panel.Preview))
	testing.expect(t, !app.preview.open, "closed")
	testing.expect(t, !ui.dock_has(&app.dock, u32(Panel.Preview)), "and its tab with it")
}

@(test)
what_an_agent_opens_leaves_the_keyboard_where_it_is :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	preview_show(app, .Agent)
	testing.expect(t, !preview_front(&app.preview).focus_address, "the address bar stays out of it")
	panel_close(app, u32(Panel.Preview))
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
	testing.expect(t, !ui.dock_has(&app.dock, u32(Panel.Preview)), "no tab")
	testing.expect_value(t, len(p.tabs), 0)
	testing.expect_value(t, len(app.cx.web_views), 0)
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
	dock_setup(app)
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
	browser_message(app, {l, socket}, fmt.tprintf(`{{"jsonrpc":"2.0","id":%d,"method":"tools/call","params":{{"name":%s,"arguments":{{"url":"http://x"}}}}}}`, id, jquote(name)))
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
// Updates

@(private = "file")
checked :: proc(app: ^App, found := "", err := "", nothing := false) {
	j := bench_update_job
	bench_update_job = nil
	if err != "" { j.err = strings.clone(err) }
	j.nothing_new = nothing
	if found != "" { j.found = {version = strings.clone(found)} }
	update_answered(app, j)
}

@(test)
check_now_works_with_an_update_on_offer :: proc(t: ^testing.T) {
	when ODIN_OS != .Windows { return }
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	update_channel_seen(app, "stable")
	update_check(app, false)
	checked(app, found = "9.0.0")
	testing.expect(t, update_is_ready(&app.updater), "on offer")
	testing.expect_value(t, app.updater.result, "Version 9.0.0 is available")
	update_check(app, true)
	_, checking := app.updater.state.(Update_Checking)
	testing.expect(t, checking, "it looks again")
	checked(app, found = "9.1.0")
	testing.expect_value(t, update_version(&app.updater), "9.1.0")
}

@(test)
a_check_that_fails_keeps_what_was_on_offer :: proc(t: ^testing.T) {
	when ODIN_OS != .Windows { return }
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	update_channel_seen(app, "stable")
	update_check(app, false)
	checked(app, found = "9.0.0")
	update_check(app, false)
	checked(app, err = "unreachable")
	testing.expect_value(t, update_version(&app.updater), "9.0.0")
}

@(test)
asking_during_a_check_is_answered_by_it :: proc(t: ^testing.T) {
	when ODIN_OS != .Windows { return }
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	update_channel_seen(app, "stable")
	update_check(app, false)
	update_check(app, true)
	checked(app, nothing = true)
	testing.expect_value(t, toasts(app), 1)
	testing.expect_value(t, app.updater.result, "Up to date")
}

@(test)
another_channel_drops_the_offer :: proc(t: ^testing.T) {
	when ODIN_OS != .Windows { return }
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	update_channel_seen(app, "stable")
	update_check(app, false)
	checked(app, found = "9.0.0")
	update_channel_seen(app, "beta")
	testing.expect(t, app.updater.state == nil, "what was found was the other channel's")
	testing.expect_value(t, app.updater.result, "")
	update_install(app)
	testing.expect(t, bench_update_job == nil, "nothing to install")
}

@(test)
a_check_of_another_channel_is_asked_again :: proc(t: ^testing.T) {
	when ODIN_OS != .Windows { return }
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	update_channel_seen(app, "stable")
	update_check(app, false)
	update_channel_seen(app, "beta")
	checked(app, found = "9.0.0")
	testing.expect(t, !update_is_ready(&app.updater), "not of this channel")
	testing.expect(t, bench_update_job != nil, "it goes again")
	testing.expect_value(t, bench_update_job.channel, "beta")
	testing.expect_value(t, bench_update_job.path, UPDATE_BETA_DIR)
}

@(test)
an_install_goes_to_the_folder_of_its_offer :: proc(t: ^testing.T) {
	when ODIN_OS != .Windows { return }
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	update_channel_seen(app, "stable")
	update_check(app, false)
	checked(app, found = "9.0.0")
	app.prefs.update_channel = "beta"   // (changed, and the frame that follows it not there yet)
	update_install(app)
	testing.expect_value(t, bench_update_job.path, UPDATE_STABLE_DIR)
	testing.expect(t, update_is_downloading(&app.updater), "under way")
	checked(app, err = "no room")
	testing.expect(t, update_is_ready(&app.updater), "back on offer")
	update_install(app)
	checked(app)
	testing.expect(t, update_is_installed(&app.updater), "in place")
	testing.expect_value(t, update_version(&app.updater), "9.0.0")
}

@(private = "file")
update_channel_seen :: proc(app: ^App, channel: string) {
	app.prefs.update_channel = channel
	update_channel_follow(app)
}

////////////////////////////////
// Diffs

@(private = "file")
signs :: proc(patch: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	for l in diff_parse(patch) { fmt.sbprintf(&b, "%c%s|", l.sign, l.text) }
	return strings.to_string(b)
}

@(test)
a_line_that_looks_like_a_header_is_a_line :: proc(t: ^testing.T) {
	testing.expect_value(t, signs("--- a/f\n+++ b/f\n@@ -1,2 +1,2 @@\n--- x\n+++ y\n z\n"), "--- x|+++ y| z|")
}

@(test)
what_a_call_counts_is_what_a_diff_shows :: proc(t: ^testing.T) {
	p: Part
	part_patch_set(&p, "--- a/f\n+++ b/f\n@@ -1,2 +1,2 @@\n--- x\n+++ y\n z\n")
	testing.expect_value(t, p.added, 1)
	testing.expect_value(t, p.removed, 1)
	part_patch_set(&p, "---x\n+++y\n")   // (made here: no headers, the lines "--x" and "++y")
	testing.expect_value(t, p.added, 1)
	testing.expect_value(t, p.removed, 1)
}

@(test)
what_diff_lines_writes_has_no_header_to_skip :: proc(t: ^testing.T) {
	testing.expect_value(t, signs(diff_lines("-- x\nsame", "++ y\nsame", context.temp_allocator)), "--- x|+++ y| same|")
}

@(test)
a_second_file_starts_with_its_headers :: proc(t: ^testing.T) {
	patch := "diff --git a/a b/a\nindex 1..2 100644\n--- a/a\n+++ b/a\n@@ -1 +1 @@\n-one\n+two\ndiff --git a/b b/b\nindex 3..4 100644\n--- a/b\n+++ b/b\n@@ -5 +5 @@\n-three\n+four\n"
	testing.expect_value(t, signs(patch), "-one|+two|@|-three|+four|")
}

@(test)
the_numbers_of_a_hunk_follow_its_lines :: proc(t: ^testing.T) {
	lines := diff_parse("@@ -3,2 +7,2 @@\n a\n--- b\n+c\n")
	testing.expect_value(t, len(lines), 3)
	testing.expect_value(t, lines[1].old_no, 4)
	testing.expect_value(t, lines[1].text, "-- b")
	testing.expect_value(t, lines[2].new_no, 8)
}

@(test)
a_hunk_with_no_count_is_one_line :: proc(t: ^testing.T) {
	testing.expect_value(t, signs("--- a/a\n+++ b/a\n@@ -1 +1 @@\n-a\n+b\n--- a/b\n+++ b/b\n@@ -2 +2 @@\n-c\n+d\n"), "-a|+b|@|-c|+d|")
}

// (no count in its header: one line each, and those lines are lines, whatever they look like)
@(test)
a_hunk_of_one_line_holds_it :: proc(t: ^testing.T) {
	testing.expect_value(t, signs("--- a/a\n+++ b/a\n@@ -1 +1 @@\n--- x\n+++ y\n"), "--- x|+++ y|")
}

@(test)
a_hunk_that_only_removes_ends_on_its_count :: proc(t: ^testing.T) {
	testing.expect_value(t, signs("--- a/a\n+++ b/a\n@@ -1,1 +0,0 @@\n-a\n--- a/b\n+++ b/b\n@@ -0,0 +1,1 @@\n+b\n"), "-a|@|+b|")
}

////////////////////////////////
// Passwords

@(test)
a_rename_with_the_keyring_locked_keeps_the_password :: proc(t: ^testing.T) {
	old := Server{name = "a", stored = "sealed"}
	stored, drop := server_password_moves(old, Server{name = "b"})
	testing.expect(t, !drop, "the only copy is not deleted")
	testing.expect(t, stored != "", "the field still leads to it")
}

@(test)
what_the_old_name_held_goes_when_the_new_one_has_it :: proc(t: ^testing.T) {
	old := Server{name = "a", password = "p"}
	stored, drop := server_password_moves(old, Server{name = "b", password = "p"})
	testing.expect_value(t, stored, "")
	testing.expect(t, drop, "after the save")
}

@(test)
a_password_removed_is_removed :: proc(t: ^testing.T) {
	_, drop := server_password_moves(Server{name = "a", password = "p"}, Server{name = "a"})
	testing.expect(t, drop, "nothing stays in the keyring")
}

@(test)
the_same_name_keeps_its_password :: proc(t: ^testing.T) {
	stored, drop := server_password_moves(Server{name = "a", stored = "sealed"}, Server{name = "a"})
	testing.expect_value(t, stored, "sealed")
	testing.expect(t, !drop, "left as it was")
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
	testing.expect_value(t, app.view_start.key, u64(0))
	testing.expect_value(t, toasts(app), 1)
}

// A thumbnail is decoded at its place's size, in a few classes; the viewer at the whole image (what a texture holds).
@(test)
an_image_is_decoded_at_the_size_it_is_shown :: proc(t: ^testing.T) {
	testing.expect_value(t, image_dim_class(20, 2048), u32(32))     // a logo
	testing.expect_value(t, image_dim_class(200, 2048), u32(256))
	testing.expect_value(t, image_dim_class(420, 2048), u32(512))   // a tool's capture at 1.75
	testing.expect_value(t, image_dim_class(430, 2048), u32(512))   // (a window a little wider: the same texture)
	testing.expect_value(t, image_dim_class(910, 2048), u32(1024))
	testing.expect_value(t, image_dim_class(3000, 2048), u32(2048))
	testing.expect_value(t, image_dim_class(0, 2048), u32(2048))     // the viewer
}

// What waits for a decoder and is no longer shown when its turn comes is let go, not decoded: a find or a fast scroll that built a
// thousand thumbnails on its way decoded them all at once (14 GB).
@(test)
an_image_no_longer_shown_is_not_decoded :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	app.frame_no = 100
	pending := app.pending
	for i in 0 ..< 5 {
		key := u64(i * 2 + 1)
		app.images[key] = {state = .Pending, used = 10}   // (shown long ago)
		job := new(Decode_Job)
		job^ = {app = app, key = key, data = strings.clone("x")}
		append(&app.cx.image_queue, job)
		sync.atomic_add(&app.pending, 1)
	}
	images_pump(app)
	testing.expect_value(t, len(app.cx.image_queue), 0)
	testing.expect_value(t, app.cx.image_decoding, 0)   // (none started)
	testing.expect_value(t, len(app.images), 0)          // (asked again if shown again)
	testing.expect_value(t, app.pending, pending)
}

// The textures kept hold no more than the budget, the ones shown longest ago going first; what was just shown stays.
@(test)
the_textures_kept_hold_a_budget :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	app.frame_no = 100
	side := 1024   // 4 MiB each
	n := IMAGE_BUDGET_BYTES / (side * side * 4) + 10
	for i in 0 ..< n { app.images[u64(i * 2 + 1)] = {state = .Ready, w = side, h = side, used = u64(i)} }   // (no texture: nothing to destroy)
	app.images[9999] = {state = .Ready, w = 4096, h = 4096, used = 100}   // shown now: stays, whatever it costs
	images_trim(app)
	held := 0
	for _, e in app.images { held += e.w * e.h * 4 }
	testing.expect(t, 9999 in app.images, "what is shown stays")
	testing.expect(t, !(u64(1) in app.images), "the oldest went")
	testing.expect(t, u64((n - 1) * 2 + 1) in app.images, "the newest stays")
	testing.expectf(t, held <= IMAGE_BUDGET_BYTES, "within the budget: %d MB", held >> 20)
	testing.expectf(t, held > IMAGE_BUDGET_BYTES - side * side * 4, "no more went than needed: %d MB", held >> 20)
}

@(test)
a_picture_that_failed_says_why :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	e: Image_Entry
	image_failed(&e, "unsupported format")
	testing.expect_value(t, e.state, Image_State.Failed)
	testing.expect(t, strings.contains(image_failed_words(&e), "unsupported format"), "read at last")
}

////////////////////////////////
// What lot 2 left

@(test)
what_was_chosen_does_not_cross_to_the_next_server :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	ui.area_set(&app.composer, "look at @a.txt")
	append(&app.cx.mentions.chosen, Mention{.File, strings.clone("@a.txt"), strings.clone("file:///old/a.txt"), strings.clone("a.txt")})
	server_forget(app)
	testing.expect_value(t, len(app.cx.mentions.chosen), 0)
	testing.expect_value(t, ui.area_string(&app.composer), "look at @a.txt")
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
	first, second := new(Conn), new(Conn)
	append(&app.cx.conns, first, second)
	l := bench_link(app)
	threads_stop(app)
	testing.expect(t, sync.atomic_load(&first.stop) && sync.atomic_load(&second.stop), "every connection")
	testing.expect(t, sync.atomic_load(&app.cx.terms.list[0].conn.stop), "the shells' threads")
	testing.expect(t, sync.atomic_load(&l.stop), "the browser's")
}

// A shell's zoom is its own (Ctrl+= on the one with the keyboard, Ctrl and the wheel over one), nothing goes to the shell,
// and it is kept by the shell's id: the program started again finds it on the same shell. Back to 1 or closed: forgotten.
@(test)
each_shell_has_its_own_zoom_kept_by_its_id :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	tmp, _ := os.temp_dir(context.temp_allocator)
	file, _ := filepath.join({tmp, fmt.tprintf("ocn_term_zoom_%d.txt", os.get_pid())}, context.temp_allocator)
	defer os.remove(file)
	app := bench_new()
	app.term_zooms.file = file
	open_shells(t, app, "a", "b")
	a, b := app.cx.terms.list[0], app.cx.terms.list[1]
	built(app, a, 11)
	ev := []platform.Event{{kind = .Key_Press, key = .Equal, mods = {.Ctrl}}}
	testing.expect_value(t, len(term_events(app, ev)), 0)
	testing.expect_value(t, outbox(a), "")
	testing.expect(t, a.zoom > 1.05 && b.zoom == 1, "the one with the keyboard only")
	b.shown, b.box, b.rect = true, 12, {{0, 500}, {800, 900}}
	wheel := []platform.Event{{kind = .Scroll, pos = {10, 600}, delta = {0, 1}, mods = {.Ctrl}}}
	testing.expect_value(t, len(term_events(app, wheel)), 0)
	testing.expect(t, b.zoom < 0.95, "the one under the wheel")
	// the program again: the same shells, their zooms
	app2 := bench_new()
	term_zooms_load(app2, file)
	open_shells(t, app2, "a", "b")
	testing.expect_value(t, app2.cx.terms.list[0].zoom, a.zoom)
	testing.expect_value(t, app2.cx.terms.list[1].zoom, b.zoom)
	// back to 1: forgotten; closed: forgotten
	term_zoom_set(app, a, 1)
	term_close(app, b)
	testing.expect_value(t, len(app.term_zooms.by_id), 0)
	data, _ := os.read_entire_file(file, context.temp_allocator)
	testing.expect_value(t, string(data), "")
}
