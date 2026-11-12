package ocn

// The dialogs and what the server offers beside the conversation, on the bench of the answers (answers_test.odin): requests kept,
// answered by the test in the order it wants. Each case is a defect that once happened or could: what it checks fails without its fix.

import "base:runtime"
import "core:strings"
import "core:testing"
import "gt:ui"
import remote "gt:remote"

@(private = "file")
show :: proc(app: ^App, id: string) {
	open_chat(app, id)
	bench_clear(app)
}

// The session shown says its folder and its project.
@(private = "file")
described :: proc(app: ^App, t: ^testing.T, id, dir, project: string) {
	request(app, .Self, "GET", "/s", tag = id)
	bench_answer(app, bench_take(t, .Self), 200, strings.concatenate({`{"data":{"id":"`, id, `","projectID":"`, project, `","location":{"directory":"`, dir, `"}}}`}, context.temp_allocator))
}

@(private = "file")
STAGED :: `{"data":{"messageID":"m","snapshot":"abc","files":[{"file":"a.txt","patch":"","additions":1,"deletions":2,"status":"modified","more":true}]}}`

@(private = "file")
staged_with :: proc(app: ^App, t: ^testing.T, session: string) {
	revert_stage(app, session, "m", "the prompt")
	bench_answer(app, bench_take(t, .Revert_Staged), 200, STAGED)
}

@(private = "file")
state_is :: proc(c: ^Changes, $T: typeid) -> bool {
	_, ok := c.state.(T)
	return ok
}

@(private = "file")
step_is :: proc(n: ^Integrations, $T: typeid) -> bool {
	_, ok := n.step.(T)
	return ok
}

////////////////////////////////
// What a dialog says of a reading

@(test)
a_reading_says_where_it_stands_the_same_everywhere :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	x: remote.Remote
	testing.expect(t, !remote.shows(&x), "nothing read")
	words, _, again := read_words(app, &x)
	testing.expect_value(t, words, "Reading…")
	testing.expect(t, !again)
	app.link = .Retrying
	words, _, _ = read_words(app, &x)
	testing.expect(t, strings.has_prefix(words, "Not connected"), "not a reading that nothing will end")
	app.link = .Online

	remote.begin(&x)
	request(app, .Stats, "GET", "/x", reading = &x)
	bench_answer(app, bench_take(t, .Stats), 403, `{"message":"set it in config"}`)
	words, _, again = read_words(app, &x)
	testing.expect_value(t, words, "set it in config")
	testing.expect(t, again, "it can be tried again")

	remote.begin(&x)
	request(app, .Stats, "GET", "/x", reading = &x)
	bench_lost(app, bench_take(t, .Stats))
	words, _, again = read_words(app, &x)
	testing.expect_value(t, words, "Server unreachable")
	testing.expect(t, again)
}

// Read again after an action: what is looked at does not go blank. Failed, it is not shown as if it were true.
@(test)
a_refresh_leaves_what_is_shown_until_it_ends :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	x: remote.Remote
	remote.begin(&x)
	testing.expect(t, !remote.shows(&x), "the first time there is nothing to show")
	request(app, .Stats, "GET", "/x", reading = &x)
	bench_answer(app, bench_take(t, .Stats), 200, `{"data":{}}`)
	testing.expect(t, remote.shows(&x))
	remote.begin(&x)
	testing.expect(t, remote.shows(&x), "it stays")
	request(app, .Stats, "GET", "/x", reading = &x)
	bench_lost(app, bench_take(t, .Stats))
	testing.expect(t, !remote.shows(&x), "it says so")
	remote.reset(&x)
	remote.begin(&x)
	testing.expect(t, !remote.shows(&x), "something else is being read")
}

////////////////////////////////
// Going back

// A stage writes the files back at once: closed while it is on its way, it is still known, and cancelled as soon as it is there.
@(test)
a_stage_closed_on_its_way_is_cancelled :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	c := &app.cx.changes
	show(app, "s")
	revert_stage(app, "s", "m", "the prompt")
	testing.expect(t, state_is(c, Changes_Staging) && changes_shown(c), "on its way")
	changes_close(app)
	testing.expect(t, !changes_shown(c), "closed")
	changes_open(app, "s")
	testing.expect(t, state_is(c, Changes_Staging), "nothing else takes its place meanwhile")
	bench_answer(app, bench_take(t, .Revert_Staged), 200, STAGED)
	testing.expect(t, state_is(c, Changes_Cancelling), "it is cancelled, not left written back")
	r := bench_take(t, .Revert_Cancelled)
	testing.expect_value(t, r.path, "/api/session/s/revert")
	testing.expect_value(t, r.method, "DELETE")
	bench_answer(app, r, 200, "")
	testing.expect(t, state_is(c, Changes_Closed))
}

@(test)
a_stage_says_what_is_done_and_each_way_out_ends_it :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	c := &app.cx.changes
	show(app, "s")
	staged_with(app, t, "s")
	testing.expect_value(t, len(c.files), 1)
	testing.expect(t, c.files[0].more, "the patch is cut")
	testing.expect(t, strings.contains(changes_say(c), "written back on disk already"), "it says what is done")

	// done elsewhere: nothing to cancel
	bench_event(app, `{"type":"session.revert.cleared","data":{"sessionID":"s"}}`)
	testing.expect(t, state_is(c, Changes_Closed))
	testing.expect_value(t, bench_count(.Revert_Cancelled), 0)

	// closed by Escape: the files go back
	staged_with(app, t, "s")
	changes_close(app)
	testing.expect(t, state_is(c, Changes_Cancelling))
	bench_answer(app, bench_take(t, .Revert_Cancelled), 200, "")
	testing.expect(t, state_is(c, Changes_Closed))
}

// A folder without snapshots: the files do not go back, and the dialog must not say they do.
@(test)
a_stage_without_snapshot_says_only_the_conversation_goes_back :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	revert_stage(app, "s", "m", "")
	bench_answer(app, bench_take(t, .Revert_Staged), 200, `{"data":{"messageID":"m","files":[]}}`)
	testing.expect(t, strings.contains(changes_say(&app.cx.changes), "keeps no snapshots"), "it says so")
}

@(test)
a_stage_found_on_opening_a_session_says_so :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	c := &app.cx.changes
	show(app, "s")
	request(app, .Self, "GET", "/s", tag = "s")
	bench_answer(app, bench_take(t, .Self), 200, `{"data":{"id":"s","revert":{"messageID":"m","snapshot":"abc","files":[{"file":"a.txt"}]}}}`)
	testing.expect(t, state_is(c, Changes_Staged) && changes_shown(c))
	testing.expect(t, strings.has_prefix(changes_say(c), "This session was left going back."), "it says so")
	revert_commit(app)
	testing.expect(t, state_is(c, Changes_Committing))
}

// What changed, Escape, Go back: the old diff is not the stage. It said the files stay as they are while they were written back.
@(test)
a_late_diff_is_not_taken_for_the_stage :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	c := &app.cx.changes
	show(app, "s")
	changes_open(app, "s", "first")
	old := bench_take(t, .Changes)
	changes_close(app)
	revert_stage(app, "s", "m", "the prompt")
	bench_answer(app, old, 200, `{"data":[{"file":"late.txt"}]}`)
	testing.expect(t, state_is(c, Changes_Staging), "still on its way")
	testing.expect_value(t, len(c.files), 0)
	bench_answer(app, bench_take(t, .Revert_Staged), 200, STAGED)
	s, _ := c.state.(Changes_Staged)
	testing.expect(t, !s.no_snapshot, "the real answer was not dropped")
	testing.expect_value(t, c.files[0].file, "a.txt")
}

@(test)
a_late_step_of_the_range_does_not_go_on_into_the_stage :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	show(app, "s")
	changes_open(app, "s")
	old := bench_take(t, .Changes_Range)
	changes_close(app)
	revert_stage(app, "s", "m", "the prompt")
	bench_answer(app, old, 200, `{"data":[{"id":"first"}]}`)
	testing.expect_value(t, bench_count(.Changes_Range), 0)
	testing.expect_value(t, bench_count(.Changes), 0)
}

// A's failure closed B's stage dialog, and no cancel went out: files reverted with nothing on screen.
@(test)
a_failure_of_another_reading_leaves_the_stage_alone :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	c := &app.cx.changes
	show(app, "b")
	changes_open(app, "a", "first")
	old := bench_take(t, .Changes)
	changes_close(app)
	staged_with(app, t, "b")
	bench_answer(app, old, 500, `{"message":"no"}`)
	testing.expect(t, state_is(c, Changes_Staged) && changes_shown(c))
}

@(test)
a_stage_on_its_way_across_a_server_switch_ends_on_that_server :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	c := &app.cx.changes
	show(app, "s")
	left := app.conn
	revert_stage(app, "s", "m", "the prompt")
	r := bench_take(t, .Revert_Staged)
	server_forget(app)
	app.conn = bench_conn(app)
	testing.expect(t, state_is(c, Changes_Closed), "not wedged for the process")
	bench_answer(app, r, 200, STAGED)
	testing.expect(t, state_is(c, Changes_Closed))
	undo := bench_take(t, .Action)
	testing.expect_value(t, undo.conn, left)
	testing.expect_value(t, undo.path, "/api/session/s/revert")
	testing.expect_value(t, undo.method, "DELETE")
	changes_open(app, "other", "first")
	testing.expect(t, state_is(c, Changes_Viewing))
}

@(test)
a_stage_on_screen_across_a_server_switch_is_cancelled_where_it_is :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	c := &app.cx.changes
	show(app, "s")
	left := app.conn
	staged_with(app, t, "s")
	server_forget(app)
	app.conn = bench_conn(app)
	testing.expect(t, state_is(c, Changes_Closed))
	testing.expect_value(t, bench_take(t, .Revert_Cancelled).conn, left)
	changes_close(app)
	revert_commit(app)
	testing.expect_value(t, bench_count(.Revert_Cancelled), 0)
	testing.expect_value(t, bench_count(.Revert_Done), 0)
}

@(test)
looking_while_it_goes_back_keeps_the_prompt_for_the_composer :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	c := &app.cx.changes
	show(app, "s")
	staged_with(app, t, "s")
	revert_commit(app)
	testing.expect(t, !changes_shown(c), "closed at once")
	changes_open(app, "s")
	bench_answer(app, bench_take(t, .Revert_Done), 200, "")
	testing.expect_value(t, ui.area_string(&app.composer), "the prompt")
	testing.expect(t, state_is(c, Changes_Closed))
}

@(test)
the_last_view_asked_for_is_the_one_shown :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	c := &app.cx.changes
	show(app, "s")
	changes_open(app, "s")
	whole := bench_take(t, .Changes_Range)
	changes_open(app, "s", "m")
	bench_answer(app, whole, 200, `{"data":[{"id":"first"}]}`)
	testing.expect_value(t, bench_count(.Changes_Range), 0)
	bench_answer(app, bench_take(t, .Changes), 200, `{"data":[{"file":"mine.txt"}]}`)
	testing.expect_value(t, len(c.files), 1)
	testing.expect_value(t, c.files[0].file, "mine.txt")
}

// (Suspected by the audit, and it does happen: the description was read before the cancel and comes after the stream said it ended.)
@(test)
an_old_description_does_not_bring_back_what_ended :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	c := &app.cx.changes
	show(app, "s")
	request(app, .Self, "GET", "/s", tag = "s")
	old := bench_take(t, .Self)
	staged_with(app, t, "s")
	changes_close(app)
	bench_answer(app, bench_take(t, .Revert_Cancelled), 200, "")
	bench_event(app, `{"type":"session.revert.cleared","data":{"sessionID":"s"}}`)
	bench_answer(app, old, 200, `{"data":{"id":"s","revert":{"messageID":"m","snapshot":"abc","files":[]}}}`)
	testing.expect(t, state_is(c, Changes_Closed), "it would ask about a stage that is gone")

	// one asked after that says what is
	request(app, .Self, "GET", "/s", tag = "s")
	bench_answer(app, bench_take(t, .Self), 200, `{"data":{"id":"s","revert":{"messageID":"m","snapshot":"abc","files":[]}}}`)
	testing.expect(t, state_is(c, Changes_Staged))
}

// ... and before the stream has said anything: the cancel itself is what makes it old.
@(test)
a_description_asked_before_a_cancel_is_old_as_soon_as_it_goes :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	c := &app.cx.changes
	show(app, "s")
	staged_with(app, t, "s")
	request(app, .Self, "GET", "/s", tag = "s")
	old := bench_take(t, .Self)
	changes_close(app)
	bench_answer(app, bench_take(t, .Revert_Cancelled), 200, "")
	bench_answer(app, old, 200, `{"data":{"id":"s","revert":{"messageID":"m","snapshot":"abc","files":[]}}}`)
	testing.expect(t, state_is(c, Changes_Closed))
}

// Still staged, the files written back: the dialog comes back rather than leaving it unsaid.
@(test)
a_cancel_that_failed_brings_the_stage_back :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	c := &app.cx.changes
	show(app, "s")
	staged_with(app, t, "s")
	changes_close(app)
	bench_lost(app, bench_take(t, .Revert_Cancelled))
	testing.expect(t, state_is(c, Changes_Closed))
	bench_answer(app, bench_take(t, .Self), 200, `{"data":{"id":"s","revert":{"messageID":"m","snapshot":"abc","files":[]}}}`)
	testing.expect(t, state_is(c, Changes_Staged))
}

@(test)
a_stage_whose_answer_was_lost_is_looked_for :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	c := &app.cx.changes
	show(app, "s")
	revert_stage(app, "s", "m", "the prompt")
	bench_lost(app, bench_take(t, .Revert_Staged))
	testing.expect(t, state_is(c, Changes_Closed))
	testing.expect_value(t, bench_count(.Self), 1)
}

@(test)
what_changed_says_why_it_could_not_be_read_and_tries_again :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	c := &app.cx.changes
	show(app, "s")
	changes_open(app, "s")
	bench_lost(app, bench_take(t, .Changes_Range))
	testing.expect(t, changes_shown(c), "the dialog stays, and says it")
	testing.expect_value(t, c.read.state, remote.State.Failed)
	stream_down(app, 0)
	stream_up(app)
	bench_answer(app, bench_take(t, .Changes_Range), 200, `{"data":[{"id":"first"}]}`)
	bench_answer(app, bench_take(t, .Changes_Range), 200, `{"data":[{"id":"last"}]}`)
	testing.expect(t, strings.contains(bench_sent_path(.Changes), "from=first&to=last"))
	// a range over a change of folder: the last turn then
	bench_answer(app, bench_take(t, .Changes), 400, `{"message":"no range"}`)
	testing.expect_value(t, c.read.state, remote.State.Loading)
	bench_answer(app, bench_take(t, .Changes), 200, `{"data":[{"file":"a.txt"}]}`)
	testing.expect(t, strings.contains(changes_say(c), "in the last turn only"))
}

@(private = "file")
bench_sent_path :: proc(kind: Req_Kind) -> string {
	for r in bench_sent { if r.kind == kind { return r.path } }
	return ""
}

////////////////////////////////
// Connections

@(private = "file")
INTEGRATIONS :: `{"data":[{"id":"b","name":"B","methods":[{"type":"oauth","id":"web","label":"Sign in","form":[{"key":"host","type":"string","required":true,"default":"a.example"}]},{"type":"key"},{"type":"command","id":"cli","command":["login"]}],"connections":[{"type":"credential","id":"c1","label":"work"}]}]}`

@(private = "file")
connections_read :: proc(app: ^App, t: ^testing.T) -> ^Integrations {
	n := &app.cx.integrations
	integrations_ask(app)
	bench_answer(app, bench_take(t, .Integrations), 200, INTEGRATIONS)
	bench_answer(app, bench_take(t, .Credentials), 200, `{"data":[{"id":"c1","active":true}]}`)
	delete(n.shown)
	n.shown = strings.clone("b")
	return n
}

@(private = "file")
login_sent :: proc(app: ^App, t: ^testing.T, n: ^Integrations, method := 0) -> ^Request {
	n.step = Connect_Fill{method}
	connect_send(app, &n.list[0], &n.list[0].methods[method], method)
	return bench_take(t, .Connect_Begin)
}

@(private = "file")
LOGIN_BEGUN :: `{"data":{"attemptID":"a1","url":"","instructions":"Enter the code ABCD","mode":"auto"}}`

// A's accounts showed under B, and what was done went to B.
@(test)
the_accounts_of_a_server_left_go_with_it :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	n := connections_read(app, t)
	testing.expect_value(t, n.read.state, remote.State.Ready)
	integrations_ask(app)
	late := bench_take(t, .Integrations)
	server_forget(app)
	app.conn = bench_conn(app)
	testing.expect_value(t, n.read.state, remote.State.Idle)
	testing.expect_value(t, len(n.list), 0)
	testing.expect_value(t, n.shown, "")
	bench_answer(app, late, 200, INTEGRATIONS)
	testing.expect_value(t, len(n.list), 0)
}

// It was a false empty for the rest of the process, not even tried again on reconnecting.
@(test)
a_list_that_failed_says_so_and_is_read_again_when_the_server_comes_back :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	n := &app.cx.integrations
	integrations_ask(app)
	bench_lost(app, bench_take(t, .Integrations))
	testing.expect_value(t, n.read.state, remote.State.Failed)
	testing.expect(t, !remote.shows(&n.read), "no empty list")
	stream_down(app, 0)
	stream_up(app)
	testing.expect_value(t, bench_count(.Integrations), 1)
	bench_answer(app, bench_take(t, .Integrations), 200, INTEGRATIONS)
	testing.expect(t, remote.shows(&n.read))
}

@(test)
a_list_not_read_is_not_asked_for_by_an_event :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	bench_event(app, `{"type":"integration.updated","data":{}}`)
	testing.expect_value(t, bench_count(.Integrations), 0)
	testing.expect_value(t, bench_count(.Plugins), 0)
}

// Each event read the models again: lot 1's models_load replaces them, whichever way it is asked.
@(test)
events_of_integrations_do_not_pile_the_models_up :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	for _ in 0 ..< 3 {
		bench_event(app, `{"type":"integration.updated","data":{}}`)
		bench_answer(app, bench_take(t, .Models), 200, `{"data":[{"id":"m1","providerID":"p1","name":"M1"}]}`)
	}
	testing.expect_value(t, len(app.models), 1)
}

// A login: its details are kept, and what ends it says why.
@(test)
a_login_is_followed_until_it_ends :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	n := connections_read(app, t)
	bench_answer(app, login_sent(app, t, n), 200, LOGIN_BEGUN)
	w, _ := n.step.(Connect_Waiting)
	testing.expect_value(t, w.instructions, "Enter the code ABCD")
	testing.expect(t, !w.by_code, "it ends by itself")
	poll := bench_take(t, .Connect_Status)
	testing.expect_value(t, poll.path, "/api/integration/b/connect/oauth/a1")
	bench_answer(app, poll, 200, `{"data":{"status":"pending"}}`)
	testing.expect(t, step_is(n, Connect_Waiting))
	bench_answer(app, bench_take(t, .Connect_Status), 200, `{"data":{"status":"failed","message":"refused"}}`)
	testing.expect(t, step_is(n, Connect_Choose))
	testing.expect_value(t, n.failed, "refused")

	bench_answer(app, login_sent(app, t, n), 200, `{"data":{"attemptID":"a2","url":"","instructions":"","mode":"auto"}}`)
	bench_answer(app, bench_take(t, .Connect_Status), 200, `{"data":{"status":"expired"}}`)
	testing.expect(t, strings.contains(n.failed, "expired"), "it says so")
	bench_answer(app, login_sent(app, t, n), 200, `{"data":{"attemptID":"a3","url":"","instructions":"","mode":"auto"}}`)
	bench_answer(app, bench_take(t, .Connect_Status), 200, `{"data":{"status":"failed"}}`)
	testing.expect(t, n.failed != "", "not a failure that says nothing")
	bench_answer(app, login_sent(app, t, n), 500, `{"message":"no such method"}`)
	testing.expect(t, step_is(n, Connect_Fill), "back to what was filled in")
	testing.expect_value(t, n.failed, "no such method")
}

// (The server may be running the command: nothing else would end it.)
@(test)
an_attempt_cancelled_on_its_way_is_ended_when_its_id_comes :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	n := connections_read(app, t)
	r := login_sent(app, t, n, 2)
	connect_cancel(app)
	testing.expect(t, step_is(n, Connect_Choose))
	testing.expect_value(t, bench_count(.Action), 0)
	bench_answer(app, r, 200, `{"data":{"attemptID":"run 1","url":"","mode":"auto"}}`)
	testing.expect(t, step_is(n, Connect_Choose), "it opens nothing")
	testing.expect_value(t, bench_count(.Connect_Status), 0)
	undo := bench_take(t, .Action)
	testing.expect_value(t, undo.method, "DELETE")
	testing.expect_value(t, undo.path, "/api/integration/b/connect/command/run%201")
}

@(test)
an_attempt_begun_on_a_server_left_is_ended_there :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	n := connections_read(app, t)
	left := app.conn
	r := login_sent(app, t, n)
	server_forget(app)
	app.conn = bench_conn(app)
	bench_answer(app, r, 200, LOGIN_BEGUN)
	testing.expect_value(t, bench_take(t, .Action).conn, left)
}

@(test)
a_login_waiting_on_a_server_left_is_ended_there :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	n := connections_read(app, t)
	left := app.conn
	bench_answer(app, login_sent(app, t, n), 200, LOGIN_BEGUN)
	server_forget(app)
	app.conn = bench_conn(app)
	testing.expect(t, step_is(n, Connect_Choose))
	undo := bench_take(t, .Action)
	testing.expect_value(t, undo.conn, left)
	testing.expect_value(t, undo.path, "/api/integration/b/connect/oauth/a1")
}

// Late answers of an attempt given up: the failure sent the next attempt back to Fill, the success said Connected after Cancel.
@(test)
what_is_late_for_an_attempt_says_nothing_of_the_next :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	n := connections_read(app, t)
	old := login_sent(app, t, n)
	connect_cancel(app)
	next := login_sent(app, t, n)
	bench_answer(app, old, 500, `{"message":"too late"}`)
	testing.expect(t, step_is(n, Connect_Sending), "the next one still waits")
	testing.expect_value(t, n.failed, "")
	bench_answer(app, next, 200, LOGIN_BEGUN)
	bench_clear(app)

	connect_cancel(app)
	n.step = Connect_Fill{1}
	ui.field_set(&n.key, "k")
	connect_send(app, &n.list[0], &n.list[0].methods[1], 1)
	key := bench_take(t, .Connected)
	connect_cancel(app)
	bench_answer(app, key, 200, "")
	testing.expect_value(t, bench_count(.Models), 0)   // (connect_done reads them)
	testing.expect(t, step_is(n, Connect_Choose))
}

// One failed reading ended the polling: WAITING for ever.
@(test)
a_login_whose_status_cannot_be_read_says_so_and_can_go_on :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	n := connections_read(app, t)
	bench_answer(app, login_sent(app, t, n), 200, LOGIN_BEGUN)
	for _ in 0 ..< CONNECT_POLL_MISSES - 1 {
		bench_lost(app, bench_take(t, .Connect_Status))
		testing.expect_value(t, n.poll.state, remote.State.Loading)
	}
	bench_answer(app, bench_take(t, .Connect_Status), 500, `{"message":"it broke"}`)
	testing.expect_value(t, bench_count(.Connect_Status), 0)
	testing.expect(t, remote.failed(&n.poll), "the readings stopped, and it shows")
	testing.expect(t, step_is(n, Connect_Waiting), "the login may still end")
	connect_poll_again(app)
	bench_answer(app, bench_take(t, .Connect_Status), 200, `{"data":{"status":"complete"}}`)
	testing.expect(t, step_is(n, Connect_Choose))
	testing.expect_value(t, bench_count(.Models), 1)
}

@(test)
a_good_reading_starts_the_count_of_misses_over :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	n := connections_read(app, t)
	bench_answer(app, login_sent(app, t, n), 200, LOGIN_BEGUN)
	for _ in 0 ..< 3 {
		for _ in 0 ..< CONNECT_POLL_MISSES - 1 { bench_lost(app, bench_take(t, .Connect_Status)) }
		bench_answer(app, bench_take(t, .Connect_Status), 200, `{"data":{"status":"pending"}}`)
	}
	testing.expect_value(t, bench_count(.Connect_Status), 1)
}

// Finish had no state: a second click sent the code twice, and a refusal left no trace.
@(test)
a_code_goes_once_and_a_refusal_gives_it_back :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	n := connections_read(app, t)
	bench_answer(app, login_sent(app, t, n), 200, `{"data":{"attemptID":"a1","url":"","instructions":"","mode":"code"}}`)
	testing.expect_value(t, bench_count(.Connect_Status), 0)
	connect_finish(app)
	testing.expect_value(t, n.failed, "The code is empty")
	ui.field_set(&n.code, "ABCD")
	connect_finish(app)
	connect_finish(app)
	testing.expect_value(t, bench_count(.Connected), 1)
	testing.expect(t, step_is(n, Connect_Finishing))
	r := bench_take(t, .Connected)
	testing.expect_value(t, r.path, "/api/integration/b/connect/oauth/a1/complete")
	bench_answer(app, r, 400, `{"message":"wrong code"}`)
	testing.expect(t, step_is(n, Connect_Waiting))
	testing.expect_value(t, n.failed, "wrong code")
	testing.expect_value(t, ui.field_string(&n.code), "ABCD")
	connect_finish(app)
	bench_answer(app, bench_take(t, .Connected), 200, "")
	testing.expect(t, step_is(n, Connect_Choose))
	testing.expect_value(t, ui.field_string(&n.code), "")
}

@(test)
what_a_way_of_connecting_asked_goes_with_the_attempt :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	n := connections_read(app, t)
	n.step = Connect_Fill{0}
	f := n.list[0].methods[0].form
	ui.field_set(&f.fields[0].text, "typed.example")
	connect_cancel(app)
	testing.expect_value(t, ui.field_string(&f.fields[0].text), "a.example")
}

// What is filled in stays in front of the reader: the list comes after.
@(test)
a_list_changed_while_filling_in_is_read_afterwards :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	n := connections_read(app, t)
	n.step = Connect_Fill{0}
	bench_event(app, `{"type":"integration.updated","data":{}}`)
	testing.expect_value(t, bench_count(.Integrations), 0)
	testing.expect(t, n.dirty)
	connect_cancel(app)
	testing.expect_value(t, bench_count(.Integrations), 1)
}

////////////////////////////////
// Plugins

@(private = "file")
PLUGINS :: `{"data":[{"id":"mine","source":{"type":"package","target":"mine@1"},"features":{},"state":{"status":"active"}}]}`

@(test)
plugins_that_could_not_be_read_are_not_an_empty_list :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	p := &app.cx.plugins
	plugins_ask(app)
	bench_answer(app, bench_take(t, .Plugins), 500, `{"message":"no plugins here"}`)
	testing.expect(t, !remote.shows(&p.read))
	testing.expect_value(t, p.read.message, "no plugins here")
	plugins_ask(app)
	bench_answer(app, bench_take(t, .Plugins), 200, PLUGINS)
	testing.expect(t, remote.shows(&p.read))
}

// One kind for both: any list that came said the check was over, and a check across a server switch stayed Checking.
@(test)
a_check_ends_by_its_own_answer :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	p := &app.cx.plugins
	plugins_ask(app)
	list := bench_take(t, .Plugins)
	remote.begin(&p.check)
	request(app, .Plugins_Check, "POST", "/api/plugin/check", "{}", reading = &p.check)
	bench_answer(app, list, 200, PLUGINS)
	testing.expect_value(t, p.check.state, remote.State.Loading)
	bench_lost(app, bench_take(t, .Plugins_Check))
	testing.expect_value(t, p.check.state, remote.State.Failed)

	remote.begin(&p.check)
	request(app, .Plugins_Check, "POST", "/api/plugin/check", "{}", reading = &p.check)
	r := bench_take(t, .Plugins_Check)
	server_forget(app)
	app.conn = bench_conn(app)
	testing.expect_value(t, p.check.state, remote.State.Idle)
	bench_answer(app, r, 200, PLUGINS)
	testing.expect_value(t, len(p.list), 0)
}

@(test)
a_check_answered_replaces_a_reading_asked_before_it :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	p := &app.cx.plugins
	plugins_ask(app)
	older := bench_take(t, .Plugins)
	remote.begin(&p.check)
	request(app, .Plugins_Check, "POST", "/api/plugin/check", "{}", reading = &p.check)
	bench_answer(app, bench_take(t, .Plugins_Check), 200, PLUGINS)
	bench_answer(app, older, 200, `{"data":[]}`)
	testing.expect_value(t, len(p.list), 1)
}

////////////////////////////////
// Schedules

@(private = "file")
SCHEDULES :: `{"data":[{"id":"x","name":"n","status":"active"},{"id":"y","status":"paused"},{"id":"z","status":"done"},{"id":"w","status":"sleeping"}]}`

@(test)
every_way_of_failing_ends_the_reading_of_the_schedules :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	s := &app.cx.schedules
	schedules_open(app, "a")
	bench_lost(app, bench_take(t, .Schedules))
	testing.expect_value(t, s.read.state, remote.State.Failed)
	schedules_open(app, "a")
	bench_answer(app, bench_take(t, .Schedules), 401, "")
	testing.expect_value(t, s.read.state, remote.State.Failed)
	schedules_open(app, "a")
	bench_answer(app, bench_take(t, .Schedules), 200, "<html>")
	testing.expect_value(t, s.read.state, remote.State.Failed)
	// (a refusal with no words was taken for a list)
	schedules_open(app, "a")
	bench_answer(app, bench_take(t, .Schedules), 404, "")
	testing.expect_value(t, s.read.state, remote.State.Refused)
	testing.expect(t, !remote.shows(&s.read))
	testing.expect_value(t, s.read.message, "status 404")
}

@(test)
the_rows_of_a_session_do_not_show_under_another :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	s := &app.cx.schedules
	schedules_open(app, "a")
	bench_answer(app, bench_take(t, .Schedules), 200, SCHEDULES)
	testing.expect_value(t, len(s.list), 4)
	schedules_open(app, "b")
	testing.expect_value(t, len(s.list), 0)
	testing.expect(t, !remote.shows(&s.read))
	schedules_open(app, "c")
	late := bench_take(t, .Schedules)
	schedules_open(app, "d")
	bench_answer(app, late, 200, SCHEDULES)
	testing.expect_value(t, len(s.list), 0)
}

@(test)
a_status_it_does_not_know_is_neither_paused_nor_resumed :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	s := &app.cx.schedules
	schedules_open(app, "a")
	bench_answer(app, bench_take(t, .Schedules), 200, SCHEDULES)
	testing.expect_value(t, s.list[0].status, Schedule_Status.Active)
	testing.expect_value(t, s.list[1].status, Schedule_Status.Paused)
	testing.expect_value(t, s.list[2].status, Schedule_Status.Done)
	testing.expect_value(t, s.list[3].status, Schedule_Status.Unknown)
}

@(private = "file")
schedule_typed :: proc(s: ^Schedules, prompt: string) {
	ui.field_set(&s.prompt, prompt)
	ui.field_set(&s.value, "2 hours")
}

@(test)
a_second_enter_plans_nothing_more :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	s := &app.cx.schedules
	schedules_open(app, "a")
	bench_answer(app, bench_take(t, .Schedules), 200, `{"data":[]}`)
	schedule_typed(s, "wake")
	schedule_submit(app)
	schedule_submit(app)
	testing.expect_value(t, bench_count(.Schedule_Made), 1)
	bench_answer(app, bench_take(t, .Schedule_Made), 200, `{"data":{}}`)
	testing.expect_value(t, ui.field_string(&s.prompt), "")
	testing.expect_value(t, bench_count(.Schedules), 1)

	// refused: what was typed stays, the words are the server's, and it can be sent again
	schedule_typed(s, "again")
	schedule_submit(app)
	bench_answer(app, bench_take(t, .Schedule_Made), 400, `{"message":"Invalid duration"}`)
	testing.expect_value(t, s.making.message, "Invalid duration")
	testing.expect_value(t, ui.field_string(&s.prompt), "again")
	schedule_submit(app)
	testing.expect_value(t, bench_count(.Schedule_Made), 1)
	bench_lost(app, bench_take(t, .Schedule_Made))
	testing.expect_value(t, s.making.state, remote.State.Failed)
	testing.expect_value(t, ui.field_string(&s.prompt), "again")
}

@(test)
what_a_session_answers_leaves_what_was_typed_for_another :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	s := &app.cx.schedules
	schedules_open(app, "a")
	schedule_typed(s, "for a")
	schedule_submit(app)
	made := bench_take(t, .Schedule_Made)
	schedules_open(app, "b")
	testing.expect_value(t, ui.field_string(&s.prompt), "")   // (it would go to b)
	schedule_typed(s, "for b")
	bench_answer(app, made, 200, `{"data":{}}`)
	testing.expect_value(t, ui.field_string(&s.prompt), "for b")
	schedule_submit(app)
	testing.expect(t, strings.contains(bench_take(t, .Schedule_Made).body, `"sessionID":"b"`))
}

@(test)
what_was_typed_stays_for_its_session :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	s := &app.cx.schedules
	schedules_open(app, "a")
	schedule_typed(s, "kept")
	app.cx.open[.Schedules] = false
	schedules_open(app, "a")
	testing.expect_value(t, ui.field_string(&s.prompt), "kept")
}

@(test)
what_the_last_server_offered_says_nothing_of_the_next :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	app.cx.no_schedules, app.cx.no_artifacts = true, true
	server_forget(app)
	testing.expect(t, !app.cx.no_schedules && !app.cx.no_artifacts)
}

////////////////////////////////
// Artifacts

@(private = "file")
ARTIFACTS :: `{"data":[{"id":"one","title":"One","entry":"index.html"},{"id":"two","title":"Two","entry":"index.html"}]}`

@(test)
an_older_folders_artifacts_do_not_land_in_the_new_dialog :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	a := &app.cx.artifacts
	artifacts_open(app)
	old := bench_take(t, .Artifacts)
	artifacts_open(app)
	bench_answer(app, old, 200, ARTIFACTS)
	testing.expect_value(t, len(a.list), 0)
	testing.expect_value(t, a.read.state, remote.State.Loading)
	bench_answer(app, bench_take(t, .Artifacts), 403, `{"message":"set experimental.artifacts"}`)
	testing.expect_value(t, a.read.state, remote.State.Refused)
	artifacts_open(app)
	bench_lost(app, bench_take(t, .Artifacts))
	testing.expect_value(t, a.read.state, remote.State.Failed)
}

@(private = "file")
ARTIFACT_ONE :: `{"data":{"info":{"entry":"index.html"},"files":{"index.html":"<p>one"}}}`

// The header said B over A's content, and Open in the browser wrote A's files in B's temporary folder.
@(test)
the_files_shown_are_those_of_the_artifact_named :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	a := &app.cx.artifacts
	artifacts_open(app)
	bench_answer(app, bench_take(t, .Artifacts), 200, ARTIFACTS)
	artifact_show(app, "one")
	bench_answer(app, bench_take(t, .Artifact_Read), 200, ARTIFACT_ONE)
	testing.expect(t, artifact_can_open(a, &a.list[0]))

	artifact_show(app, "two")
	testing.expect_value(t, len(a.files), 0)
	testing.expect(t, !artifact_can_open(a, &a.list[1]), "nothing of it is here yet")

	// a late answer of the first
	artifact_show(app, "one")
	late := bench_take(t, .Artifact_Read)
	bench_clear(app)
	artifact_show(app, "two")
	bench_answer(app, late, 200, ARTIFACT_ONE)
	testing.expect_value(t, len(a.files), 0)

	bench_lost(app, bench_take(t, .Artifact_Read))
	testing.expect_value(t, a.file_read.state, remote.State.Failed)
	testing.expect(t, !artifact_can_open(a, &a.list[1]))
}

////////////////////////////////
// Files

@(private = "file")
ROWS :: `{"data":[{"path":"src","type":"directory"},{"path":"a.txt","type":"file"}]}`

@(test)
the_rows_of_a_folder_are_of_that_folder :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	f := &app.cx.files
	files_open(app)
	bench_answer(app, bench_take(t, .Files_List), 200, ROWS)
	testing.expect_value(t, len(f.rows), 2)

	files_open(app)
	testing.expect_value(t, len(f.rows), 0)
	testing.expect(t, !remote.shows(&f.read), "not 'This folder is empty.' before any answer")
	bench_lost(app, bench_take(t, .Files_List))
	testing.expect_value(t, f.read.state, remote.State.Failed)
	files_list(app)
	bench_answer(app, bench_take(t, .Files_List), 200, `{"data":[]}`)
	testing.expect(t, remote.shows(&f.read), "now it is empty")
}

// The root of a folder had no tag: an old root listing matched the new one.
@(test)
an_old_root_listing_does_not_match_the_new_one :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	f := &app.cx.files
	show(app, "a")
	described(app, t, "a", "D:/a", "p")
	files_open(app)
	old := bench_take(t, .Files_List)
	show(app, "b")
	described(app, t, "b", "D:/b", "p")
	files_open(app)
	bench_answer(app, old, 200, ROWS)
	testing.expect_value(t, len(f.rows), 0)
	r := bench_take(t, .Files_List)
	testing.expect(t, strings.contains(r.path, "D%3A%2Fb"))
	bench_answer(app, r, 200, `{"data":[{"path":"b.txt","type":"file"}]}`)
	testing.expect_value(t, f.rows[0].path, "b.txt")
}

// A search and a folder: the last asked says what the rows are.
@(test)
a_search_given_up_does_not_answer_for_the_folder :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	f := &app.cx.files
	files_open(app)
	bench_answer(app, bench_take(t, .Files_List), 200, ROWS)
	ui.field_set(&f.field, "x")
	files_list(app)
	testing.expect(t, f.searching)
	testing.expect(t, remote.shows(&f.read), "what was there stays while one types")
	search := bench_take(t, .Files_List)
	ui.field_set(&f.field, "")
	files_list(app)
	bench_answer(app, search, 200, `{"data":[{"path":"found/x.txt","type":"file"}]}`)
	testing.expect_value(t, len(f.rows), 2)
}

// The version was the hash of the path and the length: a file edited to the same length kept the text of its last reading.
@(test)
a_file_read_again_is_shown_again :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	f := &app.cx.files
	files_open(app)
	bench_clear(app)
	file_show(app, "a.txt")
	bench_answer(app, bench_take(t, .File_Read), 200, "first")
	v := f.version
	file_show(app, "a.txt")
	bench_answer(app, bench_take(t, .File_Read), 200, "other")
	testing.expect_value(t, f.content, "other")
	testing.expect(t, f.version != v, "the cache of the text would keep the first")
}

// Only the path was checked: the same path in the folder before.
@(test)
a_file_of_the_folder_before_does_not_show_in_this_one :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	f := &app.cx.files
	show(app, "a")
	described(app, t, "a", "D:/a", "p")
	files_open(app)
	bench_clear(app)
	file_show(app, "same.txt")
	old := bench_take(t, .File_Read)
	show(app, "b")
	described(app, t, "b", "D:/b", "p")
	files_open(app)
	bench_clear(app)
	file_show(app, "same.txt")
	bench_answer(app, old, 200, "of a")
	testing.expect_value(t, f.content, "")
	bench_answer(app, bench_take(t, .File_Read), 404, `{"message":"no such file"}`)
	testing.expect_value(t, f.file_read.message, "no such file")
	testing.expect(t, !remote.shows(&f.file_read))
}

@(test)
a_binary_file_says_so :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	f := &app.cx.files
	files_open(app)
	bench_clear(app)
	file_show(app, "a.bin")
	bench_answer(app, bench_take(t, .File_Read), 200, "a\x00b")
	testing.expect(t, f.binary)
	testing.expect_value(t, f.size, 3)
}

////////////////////////////////
// Mentions

@(private = "file")
typed :: proc(app: ^App, text: string) {
	ui.area_set(&app.composer, text)
	app.composer.cursor, app.composer.mark = len(text), len(text)
	app.composer_focused = true
}

@(private = "file")
HITS :: `{"location":{"directory":"D:/a"},"data":[{"path":"a.txt","type":"file"}]}`

// The zero of `dismissed` was a place: an `@` at the very start stayed closed.
@(test)
an_at_at_the_start_opens_at_once :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	typed(app, "@")
	mention_track(app)
	testing.expect(t, app.cx.mentions.open)
	testing.expect_value(t, bench_count(.Mention_Files), 1)
}

@(test)
what_is_proposed_is_of_the_folder_shown :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	m := &app.cx.mentions
	show(app, "a")
	described(app, t, "a", "D:/a", "p")
	typed(app, "@a")
	mention_track(app)
	bench_answer(app, bench_take(t, .Mention_Files), 200, HITS)
	testing.expect(t, mention_shown(app))

	show(app, "b")
	defer drafts_destroy(app)
	described(app, t, "b", "D:/b", "p")
	testing.expect(t, !mention_shown(app), "nothing of the other folder can be chosen")
	typed(app, "@a")   // (the composer is the session's: the word is typed again here)
	mention_track(app)
	testing.expect_value(t, len(m.hits), 0)
	testing.expect_value(t, m.dir, "")
	r := bench_take(t, .Mention_Files)
	testing.expect(t, strings.contains(r.path, "D%3A%2Fb"), "the same word asks about this folder")
	bench_answer(app, r, 200, HITS)
	testing.expect(t, mention_shown(app))
}

@(test)
a_word_given_up_or_refused_proposes_nothing_old :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	m := &app.cx.mentions
	typed(app, "@a")
	mention_track(app)
	old := bench_take(t, .Mention_Files)
	typed(app, "@ab")
	mention_track(app)
	bench_answer(app, old, 200, HITS)
	testing.expect_value(t, len(m.hits), 0)
	bench_answer(app, bench_take(t, .Mention_Files), 200, HITS)
	testing.expect_value(t, len(m.hits), 1)
	typed(app, "@abc")
	mention_track(app)
	bench_answer(app, bench_take(t, .Mention_Files), 404, `{"message":"no such folder"}`)
	testing.expect_value(t, len(m.hits), 0)
}

////////////////////////////////
// Statistics

@(private = "file")
STATS :: `{"data":{"sessions":7}}`

@(test)
the_project_says_why_it_could_not_be_read :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	show(app, "a")
	described(app, t, "a", "D:/a", "p1")
	stats_open(app)
	bench_lost(app, bench_take(t, .Stats))
	testing.expect_value(t, app.cx.stats_read.state, remote.State.Failed)
	stats_ask(app)
	bench_answer(app, bench_take(t, .Stats), 200, STATS)
	testing.expect_value(t, app.proj_stats.sessions, 7)
	testing.expect(t, remote.shows(&app.cx.stats_read))
}

@(test)
an_earlier_projects_totals_do_not_fill_the_dialog :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	show(app, "a")
	described(app, t, "a", "D:/a", "p1")
	stats_open(app)
	old := bench_take(t, .Stats)
	app.stats_open = false
	show(app, "b")
	described(app, t, "b", "D:/b", "p2")
	stats_open(app)
	bench_answer(app, old, 200, STATS)
	testing.expect_value(t, app.proj_stats.sessions, 0)
	testing.expect_value(t, app.cx.stats_read.state, remote.State.Loading)
}

// The project was looked at once, on opening: not known yet, the section was hidden for good.
@(test)
the_dialog_follows_the_session_shown :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	show(app, "a")
	stats_open(app)
	testing.expect_value(t, bench_count(.Stats), 0)
	described(app, t, "a", "D:/a", "p1")
	stats_follow(app)
	r := bench_take(t, .Stats)
	testing.expect(t, strings.contains(r.path, "project=p1"))
	bench_answer(app, r, 200, STATS)
	stats_follow(app)
	testing.expect_value(t, bench_count(.Stats), 0)   // (nothing is asked at rest)

	show(app, "b")
	described(app, t, "b", "D:/b", "p2")
	stats_follow(app)
	testing.expect_value(t, app.proj_stats.project, "p2")
	testing.expect_value(t, app.proj_stats.sessions, 0)
	testing.expect(t, strings.contains(bench_take(t, .Stats).path, "project=p2"))
}

////////////////////////////////
// The settings' pages

@(private = "file")
FACT_KINDS :: []Req_Kind{.Cfg, .Shells, .Mcp, .Saved, .Usage, .Providers, .Skills, .Commands}

@(private = "file")
facts_answered :: proc(app: ^App, t: ^testing.T) {
	for k in FACT_KINDS {
		body := `{"data":[]}`
		if k == .Mcp { body = `{"data":[{"name":"x","status":{"status":"connected"}}]}` }
		if k == .Saved { body = `{"data":[{"id":"s1","action":"read","effect":"allow"}]}` }
		if k == .Cfg { body = `{"data":[{"path":"/c.json","info":{"shell":"/bin/old"}}]}` }
		if k == .Usage { body = `{"data":{"workspace":{"name":"w"}}}` }
		bench_answer(app, bench_take(t, k), 200, body)
	}
}

// They were false empties: 'No MCP server is configured', 'No saved permission'.
@(test)
a_page_that_failed_is_not_an_empty_page :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	f := &app.facts
	settings_open(app)
	bench_answer(app, bench_take(t, .Mcp), 500, `{"message":"mcp is down"}`)
	bench_lost(app, bench_take(t, .Saved))
	bench_answer(app, bench_take(t, .Usage), 200, "<html>")
	bench_answer(app, bench_take(t, .Skills), 200, `{"data":[{"name":"s"}]}`)
	testing.expect_value(t, f.reads[.Mcp].state, remote.State.Refused)
	testing.expect_value(t, f.reads[.Mcp].message, "mcp is down")
	testing.expect_value(t, f.reads[.Saved].state, remote.State.Failed)
	testing.expect_value(t, f.reads[.Usage].state, remote.State.Failed)
	testing.expect_value(t, f.reads[.Skills].state, remote.State.Ready)
	testing.expect_value(t, f.reads[.Shells].state, remote.State.Loading)
}

// 'Asking the server...' depended on everything in flight anywhere: a sleeping poll, an image being decoded.
@(test)
what_a_page_says_is_of_its_own_reading :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	f := &app.facts
	settings_open(app)
	facts_answered(app, t)
	app.pending = 5
	for k in Fact { testing.expect(t, remote.shows(&f.reads[k])) }
}

// The settings open across a change of server: nothing read them again.
@(test)
the_pages_are_read_again_for_the_next_server :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	f := &app.facts
	settings_open(app)
	late := bench_take(t, .Mcp)
	bench_clear(app)
	server_forget(app)
	app.conn = bench_conn(app)
	testing.expect_value(t, f.reads[.Mcp].state, remote.State.Idle)
	bench_answer(app, late, 200, `{"data":[{"name":"theirs"}]}`)
	testing.expect_value(t, len(f.mcp), 0)
	stream_up(app)
	for k in FACT_KINDS { testing.expect_value(t, bench_count(k), 1) }
}

@(test)
pages_closed_are_not_read_by_a_reconnection :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	stream_down(app, 0)
	stream_up(app)
	testing.expect_value(t, bench_count(.Mcp), 0)
	testing.expect_value(t, bench_count(.Integrations), 0)
}

@(test)
a_page_read_again_replaces_what_it_said :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	f := &app.facts
	settings_open(app)
	facts_answered(app, t)
	server_facts_load(app)
	testing.expect_value(t, len(f.mcp), 1)   // (it stays on screen meanwhile)
	testing.expect_value(t, f.mcp[0].status, Mcp_Status.Connected)
	facts_answered(app, t)
	testing.expect_value(t, len(f.mcp), 1)
	testing.expect_value(t, len(f.saved), 1)
	testing.expect_value(t, len(f.files), 1)
}

// The reading raced the POST: it came first, and nothing read what the POST changed.
@(test)
the_pages_are_read_after_the_server_has_done_it :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	app.cx.open[.Settings] = true
	mcp_switch(app, "x", true)
	bench_clock += FACTS_DEBOUNCE_MS * DEFERRED_MOST * 2
	deferred_tick(app)
	testing.expect_value(t, bench_count(.Mcp), 0)
	bench_answer(app, bench_take(t, .Mcp_Done), 200, "")
	bench_clock += FACTS_DEBOUNCE_MS + 1
	deferred_tick(app)
	testing.expect_value(t, bench_count(.Mcp), 1)
	bench_clear(app)

	request(app, .Saved_Done, "DELETE", "/api/permission/saved/s1")
	bench_lost(app, bench_take(t, .Saved_Done))
	bench_clock += FACTS_DEBOUNCE_MS + 1
	deferred_tick(app)
	testing.expect_value(t, bench_count(.Saved), 1)
}

// 'connecting...' was written in the status: any reading wiped it, and with 'disconnecting...' a Connect button showed.
@(test)
what_goes_on_with_an_mcp_server_outlives_a_reading :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	f := &app.facts
	mcp_switch(app, "x", false)
	mcp_switch(app, "x", true)
	testing.expect_value(t, bench_count(.Mcp_Done), 1)
	server_facts_load(app)
	bench_answer(app, bench_take(t, .Mcp), 200, `{"data":[{"name":"x","status":{"status":"connected"}}]}`)
	going := mcp_going(f, "x")
	testing.expect(t, going != nil && !going.connecting)
	bench_lost(app, bench_take(t, .Mcp_Done))
	testing.expect(t, mcp_going(f, "x") == nil, "a failure ends it too")
}

@(test)
a_shell_the_server_refused_is_not_shown_as_set :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	f := &app.facts
	app.cx.open[.Settings] = true
	server_facts_load(app)
	facts_answered(app, t)
	testing.expect_value(t, f.shell, "/bin/old")
	shell_set(app, Shell_Info{"new", "/bin/new", true})
	testing.expect_value(t, f.shell, "/bin/new")
	bench_answer(app, bench_take(t, .Shell_Set), 400, `{"message":"no"}`)
	testing.expect_value(t, f.shell, "/bin/old")
	testing.expect(t, ui.deferred_in_ms(&app.cx.due[.Facts]) > 0, "what it says is read")
	shell_set(app, Shell_Info{"new", "/bin/new", true})
	bench_answer(app, bench_take(t, .Shell_Set), 200, "")
	testing.expect_value(t, f.shell, "/bin/new")
}

////////////////////////////////
// The quote chip

@(test)
the_chip_comes_back_where_it_was :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	cx := &app.cx
	testing.expect(t, quote_place(cx, 5, {100, 200}), "a new selection")
	testing.expect_value(t, cx.quote_at.min.x, 100)
	cx.quote_open = false   // (a dialog opened over it)
	testing.expect(t, !quote_place(cx, 5, {7, 9}), "the same one")
	testing.expect(t, cx.quote_open)
	testing.expect_value(t, cx.quote_at.min.x, 100)
	testing.expect(t, quote_place(cx, 6, {7, 9}))
	testing.expect_value(t, cx.quote_at.min.x, 7)
}

////////////////////////////////
// server_forget

// Everything of these features filled in, then a change of server: nothing of the old one remains, nothing stays on its way.
@(test)
a_server_left_leaves_nothing_in_the_dialogs :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	cx := &app.cx
	show(app, "s")
	described(app, t, "s", "D:/w", "p1")

	n := connections_read(app, t)
	bench_answer(app, login_sent(app, t, n), 200, LOGIN_BEGUN)
	plugins_ask(app)
	bench_answer(app, bench_take(t, .Plugins), 200, PLUGINS)
	remote.begin(&cx.plugins.check)
	request(app, .Plugins_Check, "POST", "/c", "{}", reading = &cx.plugins.check)
	schedules_open(app, "s")
	bench_answer(app, bench_take(t, .Schedules), 200, SCHEDULES)
	schedule_typed(&cx.schedules, "typed")
	schedule_submit(app)
	artifacts_open(app)
	bench_answer(app, bench_take(t, .Artifacts), 200, ARTIFACTS)
	artifact_show(app, "one")
	bench_answer(app, bench_take(t, .Artifact_Read), 200, ARTIFACT_ONE)
	files_open(app)
	bench_answer(app, bench_take(t, .Files_List), 200, ROWS)
	file_show(app, "a.txt")
	bench_answer(app, bench_take(t, .File_Read), 200, "text")
	typed(app, "@a")
	mention_track(app)
	bench_answer(app, bench_take(t, .Mention_Files), 200, HITS)
	stats_open(app)
	bench_answer(app, bench_take(t, .Stats), 200, STATS)
	settings_open(app)
	facts_answered(app, t)
	mcp_switch(app, "x", true)
	staged_with(app, t, "s")
	cx.no_schedules, cx.no_artifacts = true, true
	bench_clear(app)

	server_forget(app)
	bench_clear(app)
	app.conn = bench_conn(app)

	c := &cx.changes
	testing.expect(t, state_is(c, Changes_Closed))
	testing.expect_value(t, len(c.files), 0)
	testing.expect_value(t, c.revert.state, remote.State.Idle)

	testing.expect_value(t, len(n.list), 0)
	testing.expect(t, step_is(n, Connect_Choose))
	testing.expect_value(t, n.shown, "")
	testing.expect_value(t, n.read.state, remote.State.Idle)
	testing.expect_value(t, n.active.state, remote.State.Idle)
	testing.expect_value(t, n.poll.state, remote.State.Idle)
	testing.expect_value(t, n.sending.state, remote.State.Idle)

	p := &cx.plugins
	testing.expect_value(t, len(p.list), 0)
	testing.expect_value(t, p.read.state, remote.State.Idle)
	testing.expect_value(t, p.check.state, remote.State.Idle)

	s := &cx.schedules
	testing.expect(t, !cx.open[.Schedules])
	testing.expect_value(t, s.session, "")
	testing.expect_value(t, len(s.list), 0)
	testing.expect_value(t, ui.field_string(&s.prompt), "")
	testing.expect_value(t, s.read.state, remote.State.Idle)
	testing.expect_value(t, s.making.state, remote.State.Idle)
	testing.expect(t, !cx.no_schedules && !cx.no_artifacts)

	a := &cx.artifacts
	testing.expect(t, !cx.open[.Artifacts])
	testing.expect_value(t, a.dir, "")
	testing.expect_value(t, a.shown, "")
	testing.expect_value(t, len(a.list), 0)
	testing.expect_value(t, len(a.files), 0)
	testing.expect_value(t, a.read.state, remote.State.Idle)
	testing.expect_value(t, a.file_read.state, remote.State.Idle)

	f := &cx.files
	testing.expect(t, !cx.open[.Files])
	testing.expect_value(t, f.dir, "")
	testing.expect_value(t, f.file, "")
	testing.expect_value(t, f.content, "")
	testing.expect_value(t, len(f.rows), 0)
	testing.expect_value(t, f.read.state, remote.State.Idle)
	testing.expect_value(t, f.file_read.state, remote.State.Idle)

	m := &cx.mentions
	testing.expect(t, !m.open)
	testing.expect_value(t, len(m.hits), 0)
	testing.expect_value(t, m.dir, "")
	testing.expect_value(t, m.folder, "")
	testing.expect_value(t, m.read.state, remote.State.Idle)

	testing.expect(t, !app.stats_open)
	testing.expect_value(t, app.proj_stats.project, "")
	testing.expect_value(t, app.proj_stats.sessions, 0)
	testing.expect_value(t, cx.stats_read.state, remote.State.Idle)

	facts := &app.facts
	for k in Fact { testing.expect_value(t, facts.reads[k].state, remote.State.Idle) }
	testing.expect_value(t, len(facts.mcp), 0)
	testing.expect_value(t, len(facts.saved), 0)
	testing.expect_value(t, len(facts.files), 0)
	testing.expect_value(t, len(facts.going), 0)
	testing.expect_value(t, facts.shell, "")
	testing.expect_value(t, facts.workspace, "")
}
