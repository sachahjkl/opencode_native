package ocn

// The sidebar's modes, what is not seen, what holds the rows under the pointer, and where a fork stops.

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:testing"
import "gt:config"

// The session `id` asks for a permission.
@(private = "file")
asks :: proc(app: ^App, id: string) {
	v, _ := json.parse_string(fmt.tprintf(`{{"id":"p","sessionID":"%s"}}`, id), allocator = context.temp_allocator)
	permission_add(app, v)
}

@(private = "file")
show :: proc(app: ^App, id: string) {
	open_chat(app, id)
	bench_clear(app)
}

// Sessions as the server lists them, the first one most recent.
@(private = "file")
sessions :: proc(app: ^App, body: string) {
	v, err := json.parse_string(body, parse_integers = true, allocator = context.temp_allocator)
	assert(err == nil)
	sessions_load(app, v)
}

@(private = "file")
LIST :: `{"data":[
	{"id":"waits","title":"Waits","location":{"directory":"C:/code/alpha"},"time":{"created":1,"updated":60,"idle":5,"viewed":5}},
	{"id":"ended","title":"Ended","outcome":"failed","location":{"directory":"C:/code/beta"},"time":{"created":1,"updated":50,"idle":40,"viewed":5}},
	{"id":"never","title":"Never viewed","location":{"directory":"C:/code/beta"},"time":{"created":1,"updated":45,"idle":40}},
	{"id":"runs","title":"Runs","location":{"directory":"C:/code/alpha"},"time":{"created":1,"updated":40,"idle":30,"viewed":5}},
	{"id":"seen","title":"Seen","location":{"directory":"C:/code/alpha"},"time":{"created":1,"updated":30,"idle":20,"viewed":20}},
	{"id":"new","title":"Not run yet","location":{"directory":"C:/code/gamma"},"time":{"created":1,"updated":20}},
	{"id":"sub","title":"A sub-agent","parentID":"seen","location":{"directory":"C:/code/alpha"},"time":{"created":1,"updated":10,"idle":9}}
]}`

// The sections as text: "TITLE: id id | TITLE: id".
@(private = "file")
dealt :: proc(app: ^App, sections: []Side_Section) -> string {
	b := strings.builder_make(context.temp_allocator)
	for sec, k in sections {
		if k > 0 { strings.write_string(&b, " | ") }
		fmt.sbprintf(&b, "%s:", sec.title != "" ? sec.title : base_name(sec.dir))
		for i in sec.items { fmt.sbprintf(&b, " %s", app.sessions[i].id) }
	}
	return strings.to_string(b)
}

@(private = "file")
inbox_app :: proc() -> ^App {
	app := bench_new()
	sessions(app, LIST)
	asks(app, "waits")
	set_busy(app, "runs", true)
	return app
}

@(test)
the_inbox_puts_what_needs_the_person_first :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := inbox_app()
	testing.expect_value(t, dealt(app, sidebar_sections(app, sidebar_rows(app, ""), .Inbox)),
		"Waits for you: waits | Finished: ended never | Running: runs | Recent: seen new")
	testing.expect_value(t, dealt(app, sidebar_sections(app, sidebar_rows(app, ""), .Projects)), "alpha: waits runs seen | beta: ended never | gamma: new")
}

@(test)
sections_with_nothing_do_not_show_and_search_works_in_both_modes :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := inbox_app()
	testing.expect_value(t, dealt(app, sidebar_sections(app, sidebar_rows(app, "beta"), .Inbox)), "Finished: ended never")
	testing.expect_value(t, dealt(app, sidebar_sections(app, sidebar_rows(app, "beta"), .Projects)), "beta: ended never")
	testing.expect_value(t, len(sidebar_sections(app, sidebar_rows(app, "nothing like it"), .Inbox)), 0)
}

@(test)
a_wait_of_a_sub_agent_is_its_parents_and_a_sub_agent_is_never_unseen :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	sessions(app, LIST)
	asks(app, "sub")
	testing.expect(t, session_waits(app, "seen"))
	testing.expect(t, !session_unseen(app, find_session(app, "sub")), "nobody views them: it would stay for ever")
	app.prefs.subagents = "flat"
	testing.expect_value(t, dealt(app, sidebar_sections(app, sidebar_rows(app, ""), .Inbox)),
		"Waits for you: seen sub | Finished: ended never runs | Recent: waits new")
}

@(test)
the_modes_are_the_preferences_words :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	def := config.entry(&app.cfg_prefs, config.ref_of(&app.cfg_prefs, "sidebar.mode")).def
	testing.expect_value(t, len(def.choices), len(Sidebar_Mode))
	for m in Sidebar_Mode {
		testing.expect_value(t, def.choices[int(m)], SIDEBAR_MODES[m].word)
		testing.expect_value(t, sidebar_mode_of(SIDEBAR_MODES[m].word), m)
	}
	testing.expect_value(t, def.default.s, "inbox")
	testing.expect_value(t, sidebar_mode_of("what a newer version wrote"), Sidebar_Mode.Inbox)
}

@(test)
opening_one_says_it_was_seen_and_only_that_end_of_it :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	sessions(app, LIST)
	open_chat(app, "ended")
	r := bench_take(t, .Session_Viewed)
	testing.expect_value(t, r.path, "/api/session/ended/view")
	testing.expect_value(t, r.body, `{"idle":40}`)
	testing.expect(t, !session_unseen(app, find_session(app, "ended")))
	open_chat(app, "seen")
	testing.expect_value(t, bench_count(.Session_Viewed), 0)   // (nothing new in it)
	open_chat(app, "ended")
	testing.expect_value(t, bench_count(.Session_Viewed), 0)
}

@(test)
a_run_ended_elsewhere_is_not_seen_at_once_and_the_one_shown_is_seen :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	sessions(app, LIST)
	show(app, "seen")
	bench_event(app, `{"type":"session.execution.started","data":{"sessionID":"seen"}}`)
	bench_event(app, `{"type":"session.execution.started","data":{"sessionID":"new"}}`)
	testing.expect_value(t, dealt(app, sidebar_sections(app, sidebar_rows(app, "run yet"), .Inbox)), "Running: new")
	bench_event(app, `{"type":"session.execution.failed","data":{"sessionID":"new"}}`)
	bench_event(app, `{"type":"session.execution.succeeded","data":{"sessionID":"seen"}}`)
	s := find_session(app, "new")
	testing.expect(t, session_unseen(app, s), "without waiting for the list, nor going through Recent")
	testing.expect_value(t, s.outcome, "failed")
	testing.expect_value(t, find_session(app, "seen").idle, 20)
	testing.expect_value(t, bench_count(.Session_Viewed), 0)   // (the time of that end is the server's: the list brings it)
	sessions(app, `{"data":[{"id":"seen","title":"Seen","time":{"created":1,"updated":70,"idle":70,"viewed":20}}]}`)
	r := bench_take(t, .Session_Viewed)
	testing.expect_value(t, r.body, `{"idle":70}`)
}

@(test)
what_another_client_saw_is_seen_here :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	sessions(app, LIST)
	testing.expect(t, session_unseen(app, find_session(app, "ended")))
	bench_event(app, `{"type":"session.viewed","data":{"sessionID":"ended","idle":40}}`)
	testing.expect(t, !session_unseen(app, find_session(app, "ended")))
	testing.expect_value(t, bench_count(.Session_Viewed), 0)
}

@(test)
a_view_refused_says_nothing :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	sessions(app, LIST)
	open_chat(app, "ended")
	bench_answer(app, bench_take(t, .Session_Viewed), 404, `{"message":"no such session"}`)
	for toast in app.state.toasts { testing.expect(t, !toast.alive, "a toast at each session opened") }
}

@(test)
rows_do_not_move_under_the_pointer :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := inbox_app()
	first := strings.clone(dealt(app, sidebar_held(app, sidebar_rows(app, ""), true, 1)))
	bench_event(app, `{"type":"session.execution.failed","data":{"sessionID":"runs"}}`)
	permission_remove(app, "p")
	sessions(app, strings.concatenate({LIST[:len(LIST) - 3], `,{"id":"born","title":"Born meanwhile","time":{"created":1,"updated":99}}]}`}, context.temp_allocator))
	testing.expect_value(t, dealt(app, sidebar_held(app, sidebar_rows(app, ""), true, 1)), first)
	testing.expect(t, app.cx.side_hold.on)

	// (the pointer left, or rested)
	testing.expect_value(t, dealt(app, sidebar_held(app, sidebar_rows(app, ""), false, 1)),
		"Finished: ended never runs | Recent: born waits seen new")
	testing.expect(t, !app.cx.side_hold.on)
}

@(test)
what_the_reader_asks_for_is_not_held :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := inbox_app()
	_ = sidebar_held(app, sidebar_rows(app, ""), true, 1)
	testing.expect_value(t, dealt(app, sidebar_held(app, sidebar_rows(app, "beta"), true, 2)), "Finished: ended never")
	app.prefs.sidebar_mode = .Projects
	testing.expect_value(t, dealt(app, sidebar_held(app, sidebar_rows(app, "beta"), true, 3)), "beta: ended never")
}

@(test)
a_session_gone_leaves_a_held_list :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	sessions(app, LIST)
	_ = sidebar_held(app, sidebar_rows(app, "beta"), true, 1)
	sessions(app, `{"data":[{"id":"never","title":"Never viewed","location":{"directory":"C:/code/beta"},"time":{"created":1,"updated":45,"idle":40}}]}`)
	testing.expect_value(t, dealt(app, sidebar_held(app, sidebar_rows(app, "beta"), true, 1)), "Finished: never")
	server_forget(app)
	testing.expect(t, !app.cx.side_hold.on)
}

@(private = "file")
conversation :: proc(app: ^App) {
	c := &app.chat
	append(&c.messages, Message{id = "m1", kind = .User, text = "first"}, Message{id = "m2", kind = .Assistant}, Message{id = "m3", kind = .Assistant}, Message{id = "m4", kind = .Idle}, Message{id = "m5", kind = .User, text = "second"}, Message{id = "m6", kind = .Assistant, streaming = true})
}

@(test)
a_fork_from_an_answer_keeps_it_and_from_a_prompt_leaves_it_out :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	show(app, "s")
	conversation(app)
	c := &app.chat
	testing.expect_value(t, fork_before(c, &c.messages[0]), "m1")
	testing.expect_value(t, fork_before(c, &c.messages[1]), "m3")
	testing.expect_value(t, fork_before(c, &c.messages[2]), "m4")
	testing.expect_value(t, fork_before(c, &c.messages[4]), "m5")
	testing.expect_value(t, fork_before(c, &c.messages[5]), "m6")   // (being written: it stays out, not half of it)
	c.messages[5].streaming = false
	testing.expect_value(t, fork_before(c, &c.messages[5]), "")     // (the last one: all there is)
}

@(test)
the_prompt_a_fork_leaves_out_comes_back_in_the_composer :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	show(app, "s")
	fork_session(app, "s", "m1", "first")
	r := bench_take(t, .Forked)
	testing.expect_value(t, r.body, `{"before":"m1"}`)
	bench_answer(app, r, 200, `{"data":{"id":"forked"}}`)
	testing.expect_value(t, len(app.nav_steps), 1)
	testing.expect_value(t, app.nav_steps[0].id, "forked")
	testing.expect_value(t, string(app.composer.buf[:]), "first")

	// (a fork of all of it has no prompt to give back, whatever the last one left)
	fork_session(app, "s", "")
	r = bench_take(t, .Forked)
	testing.expect_value(t, r.body, "{}")
	bench_answer(app, r, 200, `{"data":{"id":"forked2"}}`)
	testing.expect_value(t, string(app.composer.buf[:]), "first")
}

@(test)
what_a_schedule_row_says :: proc(t: ^testing.T) {
	it := Schedule{when_text = "every 1 day", remaining = 3, runs = 2, outcome = "ok"}
	testing.expect_value(t, schedule_detail(&it), "every 1 day · 3 left · ran 2 (ok)")
	it = Schedule{when_text = "once, in 2 hours", runs = 1}
	testing.expect_value(t, schedule_detail(&it), "once, in 2 hours · ran 1")
}
