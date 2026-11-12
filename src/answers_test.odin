package ocn

// The bench of the answers: requests are kept instead of sent (net.odin request), and each is answered by the test, with the status
// and the body it wants, in the order it wants, through what the program runs for a real one (answer). No thread, no server: each
// test has its App and its thread, nothing is shared. Each case here is a defect that once happened or could: what it checks
// fails without its fix.

import "base:runtime"
import "core:encoding/base64"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "gt:draw"
import "gt:config"
import fsx "gt:fsx"
import "gt:png"
import "gt:ui"

// The requests of this thread's test, oldest first.
@(thread_local) bench_sent: [dynamic]^Request

bench_sent_add :: proc(r: ^Request) { append(&bench_sent, r) }

// An App as far as the answers need it: no window, no fonts, the toolkit's state only for what it holds (toasts, find, its clock).
bench_new :: proc() -> ^App {
	context.allocator = runtime.heap_allocator()
	app := new(App)
	ui.use(&app.state)
	ui.set_clock(&app.state, &bench_clock)
	bench_clock = 1000
	clear(&bench_sent)
	app.conn = new(Conn)
	app.cx.web_host = bench_web_host()
	app.link = .Online
	app.stick_bottom = true
	app.prefs.page_size = 50
	app.prefs.notify = "off"
	app.cfg_prefs = config.prefs_make()
	config.register(&app.cfg_prefs, PREF_DEFS[:])
	app.fonts_wanted = "\n\n\n"   // (the faces stay as they are: pref_set does not load any)
	chat_home(app)
	return app
}

@(thread_local) bench_clock: f64

// The oldest request of this kind not answered yet: it leaves the list, for bench_answer.
bench_take :: proc(t: ^testing.T, kind: Req_Kind, loc := #caller_location) -> ^Request {
	for r, i in bench_sent {
		if r.kind == kind { ordered_remove(&bench_sent, i); return r }
	}
	testing.expectf(t, false, "no %v request", kind, loc = loc)
	r := new(Request)
	r.kind = kind
	return r
}

bench_count :: proc(kind: Req_Kind) -> int {
	n := 0
	for r in bench_sent { if r.kind == kind { n += 1 } }
	return n
}

// Everything left unanswered is forgotten.
bench_clear :: proc(app: ^App) {
	clear(&app.cx.flights)
	for r in bench_sent { request_free(r); app.pending -= 1 }
	clear(&bench_sent)
}

bench_answer :: proc(app: ^App, r: ^Request, status: int, body: string) {
	r.status, r.ok = status, true
	r.resp = strings.clone(body)
	answer(app, r)
}

// The server was not reached.
bench_lost :: proc(app: ^App, r: ^Request) {
	r.ok = false
	r.resp = strings.clone("connection refused")
	answer(app, r)
}

bench_event :: proc(app: ^App, text: string) {
	v, err := json.parse_string(text, parse_integers = true, allocator = context.temp_allocator)
	assert(err == nil, text)
	apply_event(app, v)
}

@(private = "file")
attach :: proc(app: ^App, name: string) {
	append(&app.cx.attachments, Attachment{name = strings.clone(name), uri = strings.clone("data:image/png;base64,AAAA")})
}

@(private = "file")
show :: proc(app: ^App, id: string) {
	open_chat(app, id)
	bench_clear(app)
}

@(private = "file")
page :: proc(items: ..string) -> string {
	return fmt.tprintf(`{{"data":[%s],"cursor":{{"next":""}}}}`, strings.join(items, ",", context.temp_allocator))
}

@(private = "file")
JSON_MODEL :: `{"id":"m1","providerID":"p1","name":"M1"}`

////////////////////////////////
// The bench itself

@(test)
a_reading_replaced_drops_its_answer :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	x: Remote
	remote_begin(&x)
	request(app, .Agents, "GET", "/a", remote = &x)
	first := bench_take(t, .Agents)
	remote_begin(&x)
	request(app, .Agents, "GET", "/a", remote = &x)
	second := bench_take(t, .Agents)

	bench_answer(app, first, 200, `{"data":[{"id":"old"}]}`)
	testing.expect_value(t, len(app.agents), 0)
	testing.expect_value(t, x.state, Load_State.Loading)
	bench_answer(app, second, 200, `{"data":[{"id":"new"}]}`)
	testing.expect_value(t, x.state, Load_State.Ready)
	testing.expect_value(t, app.agents[0].id, "new")
}

@(test)
every_way_of_failing_settles_a_reading :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	x: Remote
	ask :: proc(app: ^App, t: ^testing.T, x: ^Remote) -> ^Request {
		remote_begin(x)
		request(app, .Sessions, "GET", "/s", remote = x)
		return bench_take(t, .Sessions)
	}
	bench_lost(app, ask(app, t, &x))
	testing.expect_value(t, x.state, Load_State.Failed)
	testing.expect(t, x.message != "")
	bench_answer(app, ask(app, t, &x), 401, "")
	testing.expect_value(t, x.state, Load_State.Failed)
	bench_answer(app, ask(app, t, &x), 500, `{"message":"it broke"}`)
	testing.expect_value(t, x.state, Load_State.Refused)
	testing.expect_value(t, x.message, "it broke")
	bench_answer(app, ask(app, t, &x), 200, "not json")
	testing.expect_value(t, x.state, Load_State.Failed)
	bench_answer(app, ask(app, t, &x), 200, `{"data":[]}`)
	testing.expect_value(t, x.state, Load_State.Ready)
	testing.expect_value(t, x.message, "")
}

// One that a feature's forget did not reset does not stay Loading: nothing will ever answer it.
@(test)
a_reading_of_a_server_left_does_not_stay_loading :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	x: Remote
	remote_begin(&x)
	request(app, .Agents, "GET", "/a", remote = &x)
	r := bench_take(t, .Agents)
	app.conn = new(Conn)
	bench_answer(app, r, 200, `{"data":[{"id":"theirs"}]}`)
	testing.expect_value(t, x.state, Load_State.Idle)
	testing.expect_value(t, len(app.agents), 0)
}

@(test)
a_bad_answer_does_not_leave_the_list_of_commands_stuck :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	show(app, "s")
	app.chat.have_self = true
	app.chat.self.directory = "D:/w"
	activity_tick(app)
	testing.expect(t, flying(app, .Shell_List, "D:/w"), "asked")
	bench_answer(app, bench_take(t, .Shell_List), 200, "<html>")
	testing.expect(t, !flying(app, .Shell_List, "D:/w"), "a 200 that cannot be read ends it too")
}

////////////////////////////////
// server_forget

@(test)
a_server_left_leaves_nothing_behind :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	slash_load(app, []Slash{{strings.clone("old"), strings.clone("")}})
	show(app, "s")
	append(&app.activity.jobs, Shell_Job{id = strings.clone("j"), status = .Running})
	app.activity.open = true
	app.find.open = true
	app.find.index = 3
	bench_event(app, `{"type":"permission.asked","data":{"request":{"id":"p","sessionID":"s"}}}`)
	waits_gone(app, "gone")
	refresh_soon(app)
	server_forget(app)
	testing.expect_value(t, app.link, Conn_State.Connecting)
	testing.expect_value(t, len(app.cx.slash), 0)
	testing.expect(t, !app.cx.have_slash)
	testing.expect_value(t, len(app.activity.jobs), 0)
	testing.expect(t, !app.activity.open)
	testing.expect(t, !app.find.open)
	testing.expect_value(t, len(app.permissions), 0)
	testing.expect_value(t, len(app.cx.waits_gone.items), 0)
	testing.expect_value(t, app.cx.due[.Refresh].due_ms, 0)
	testing.expect_value(t, chat_view(app), Chat_View.Home)
}

////////////////////////////////
// Prompts

@(test)
a_second_enter_keeps_the_first_prompt_whole :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	ui.area_set(&app.composer, "first")
	attach(app, "one.png")
	submit_prompt(app)
	testing.expect_value(t, ui.area_string(&app.composer), "")
	testing.expect_value(t, len(app.cx.attachments), 0)
	testing.expect(t, composer_held(app), "a session is starting from this composer")

	// the second Enter, and what is typed then: nothing leaves, nothing is made
	ui.area_set(&app.composer, "second")
	attach(app, "two.png")
	submit_prompt(app)
	testing.expect_value(t, bench_count(.Created), 1)
	testing.expect_value(t, ui.area_string(&app.composer), "second")
	testing.expect_value(t, len(app.cx.attachments), 1)

	// the first goes, with its own image, to its session
	bench_answer(app, bench_take(t, .Created), 200, `{"data":{"id":"new"}}`)
	bench_clear_but(app, .Prompt)
	r := bench_take(t, .Prompt)
	testing.expect(t, strings.contains(r.path, "/api/session/new/prompt"))
	testing.expect(t, strings.contains(r.body, `"text":"first"`))
	testing.expect(t, strings.contains(r.body, "one.png"))
	testing.expect(t, !strings.contains(r.body, "two.png"), "the image of what was typed after it stays")
	bench_answer(app, r, 200, "")
	testing.expect_value(t, len(app.cx.outgoing), 0)
}

// The other requests of a step, read by nobody here.
bench_clear_but :: proc(app: ^App, kind: Req_Kind) {
	for i := len(bench_sent) - 1; i >= 0; i -= 1 {
		r := bench_sent[i]
		if r.kind == kind { continue }
		ordered_remove(&bench_sent, i)
		request_free(r)
		app.pending -= 1
	}
}

@(test)
the_steps_of_a_new_session_keep_their_order_and_the_composer_waits :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	config.set_from_string(&app.cfg_prefs, "session.agent", "plan", .User)
	config.set_from_string(&app.cfg_prefs, "session.model", "m1", .User)
	ui.area_set(&app.composer, "go")
	attach(app, "a.png")
	submit_prompt(app)
	bench_answer(app, bench_take(t, .Created), 200, `{"data":{"id":"new"}}`)
	testing.expect_value(t, app.chat.id, "new")
	testing.expect_value(t, shown_agent(app), "plan")
	testing.expect_value(t, bench_count(.Prompt), 0)

	// a prompt in the middle of the steps stays where it is: it would overtake the first and take its image
	ui.area_set(&app.composer, "overtaker")
	submit_prompt(app)
	testing.expect_value(t, ui.area_string(&app.composer), "overtaker")
	testing.expect_value(t, bench_count(.Prompt), 0)

	bench_answer(app, bench_take(t, .Session_Agent), 200, "")
	bench_answer(app, bench_take(t, .Session_Model), 500, `{"message":"no such model"}`)   // (it goes all the same)
	r := bench_take(t, .Prompt)
	testing.expect(t, strings.contains(r.body, "a.png"))
	testing.expect(t, !composer_held(app))
	bench_answer(app, r, 200, "")
}

@(test)
what_failed_comes_back_whole :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	show(app, "s")
	attach(app, "alone.png")
	append(&app.cx.mentions.chosen, Mention{.File, strings.clone("@f"), strings.clone("file:///f"), strings.clone("f")})
	submit_prompt(app)
	testing.expect_value(t, len(app.cx.attachments), 0)
	bench_lost(app, bench_take(t, .Prompt))
	testing.expect_value(t, len(app.cx.attachments), 1)
	testing.expect_value(t, app.cx.attachments[0].name, "alone.png")
	testing.expect_value(t, len(app.cx.mentions.chosen), 1)
	testing.expect_value(t, len(app.cx.outgoing), 0)
}

@(test)
what_failed_waits_for_its_session :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	show(app, "a")
	ui.area_set(&app.composer, "for a")
	attach(app, "a.png")
	submit_prompt(app)
	r := bench_take(t, .Prompt)
	show(app, "b")
	bench_answer(app, r, 500, `{"message":"no"}`)
	testing.expect_value(t, ui.area_string(&app.composer), "")
	testing.expect_value(t, len(app.cx.attachments), 0)
	show(app, "a")
	testing.expect_value(t, ui.area_string(&app.composer), "for a")
	testing.expect_value(t, len(app.cx.attachments), 1)
}

// What was taken out of the inbox goes as a prompt: it comes back as whole as one of the composer.
@(test)
a_prompt_out_of_the_inbox_comes_back_whole :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	show(app, "s")
	request(app, .Inbox_Take, "DELETE", "/api/session/s/inbox/i", `{"text":"","files":[{"uri":"data:image/png;base64,AAAA","name":"only.png"},{"uri":"file:///f","name":"f","mention":{"start":0,"end":2,"text":"@f"}}]}`, "s")
	bench_answer(app, bench_take(t, .Inbox_Take), 200, "")
	r := bench_take(t, .Prompt)
	testing.expect(t, strings.contains(r.body, "only.png"), "it goes as it was")
	bench_lost(app, r)
	testing.expect_value(t, len(app.cx.attachments), 1)
	testing.expect_value(t, app.cx.attachments[0].name, "only.png")
	testing.expect(t, app.cx.attachments[0].ref.key != 0, "its thumbnail too")
	testing.expect_value(t, len(app.cx.mentions.chosen), 1)
}

@(test)
a_command_that_failed_comes_back :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	slash_load(app, []Slash{{strings.clone("review"), strings.clone("")}})
	show(app, "s")
	ui.area_set(&app.composer, "/review the rest")
	attach(app, "stays.png")
	submit_prompt(app)
	testing.expect_value(t, ui.area_string(&app.composer), "")
	testing.expect_value(t, len(app.cx.attachments), 1)
	r := bench_take(t, .Prompt)
	testing.expect(t, strings.has_suffix(r.path, "/command"))
	bench_lost(app, r)
	testing.expect_value(t, ui.area_string(&app.composer), "/review the rest")
}

@(test)
a_server_switch_gives_back_what_had_not_gone :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	ui.area_set(&app.composer, "mine")
	attach(app, "mine.png")
	submit_prompt(app)
	r := bench_take(t, .Created)
	app.conn = new(Conn)
	server_forget(app)
	testing.expect_value(t, ui.area_string(&app.composer), "mine")
	testing.expect_value(t, len(app.cx.attachments), 1)
	bench_answer(app, r, 200, `{"data":{"id":"theirs"}}`)
	testing.expect_value(t, app.chat.id, "")
	testing.expect_value(t, len(app.cx.outgoing), 0)
}

@(test)
a_session_made_late_does_not_move_the_reader :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	ui.area_set(&app.composer, "start")
	submit_prompt(app)
	r := bench_take(t, .Created)
	show(app, "elsewhere")
	bench_answer(app, r, 200, `{"data":{"id":"new"}}`)
	testing.expect_value(t, app.chat.id, "elsewhere")
	p := bench_take(t, .Prompt)
	testing.expect(t, strings.contains(p.path, "/api/session/new/prompt"), "it goes on without them")
	testing.expect_value(t, app.chat.chose_agent, "")
}

@(test)
what_is_late_for_a_chat_left_is_dropped :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	show(app, "a")
	fork_session(app, "a", "")
	r := bench_take(t, .Forked)
	show(app, "b")
	bench_answer(app, r, 200, `{"data":{"id":"fork"}}`)
	testing.expect_value(t, len(app.nav_steps), 0)

	request(app, .Session_Import, "POST", "/i")
	r = bench_take(t, .Session_Import)
	show(app, "c")
	bench_answer(app, r, 200, `{"data":{"id":"imported"}}`)
	testing.expect_value(t, len(app.nav_steps), 0)

	append(&app.activity.jobs, Shell_Job{id = strings.clone("j"), status = .Running})
	request(app, .Shell_Output, "GET", "/o", tag = "j")
	old := bench_take(t, .Shell_Output)
	old.gen -= 1
	bench_answer(app, old, 200, `{"data":{"output":"late","cursor":9}}`)
	testing.expect_value(t, len(app.activity.jobs[0].tail), 0)
}

////////////////////////////////
// Waits

@(private = "file")
PERM_P :: `{"id":"p","sessionID":"s","action":"read"}`

@(test)
a_card_whose_event_was_missed_goes :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	show(app, "s")
	bench_event(app, `{"type":"permission.asked","data":{"request":` + PERM_P + `}}`)
	bench_event(app, `{"type":"form.created","data":{"form":{"id":"f","sessionID":"s","fields":[]}}}`)
	testing.expect(t, session_waits(app, "s"))
	session_waits_load(app, "s")
	bench_answer(app, bench_take(t, .Permissions), 200, `{"data":[]}`)
	bench_answer(app, bench_take(t, .Forms), 200, `{"data":[]}`)
	testing.expect(t, !session_waits(app, "s"), "they would pulse for ever")
}

@(test)
a_late_list_does_not_bring_back_what_was_answered_nor_hide_what_came :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	show(app, "s")
	session_waits_load(app, "s")   // (a list on its way, read before all that follows)
	perms, forms := bench_take(t, .Permissions), bench_take(t, .Forms)
	bench_event(app, `{"type":"permission.asked","data":{"request":{"id":"new","sessionID":"s"}}}`)
	bench_event(app, `{"type":"permission.asked","data":{"request":` + PERM_P + `}}`)
	bench_event(app, `{"type":"permission.replied","data":{"id":"p"}}`)
	bench_event(app, `{"type":"form.created","data":{"form":{"id":"f2","sessionID":"s","fields":[]}}}`)
	bench_answer(app, perms, 200, page(PERM_P))
	bench_answer(app, forms, 200, `{"data":[]}`)
	testing.expect_value(t, len(app.permissions), 1)
	testing.expect_value(t, app.permissions[0].id, "new")
	testing.expect(t, form_find(app, "f2") != nil, "it came after that list was asked for")
}

@(test)
one_click_one_answer_and_a_failure_gives_the_buttons_back :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	show(app, "s")
	bench_event(app, `{"type":"permission.asked","data":{"request":` + PERM_P + `}}`)
	reply_permission(app, &app.permissions[0], "once")
	reply_permission(app, &app.permissions[0], "once")
	testing.expect_value(t, bench_count(.Permission_Reply), 1)
	bench_lost(app, bench_take(t, .Permission_Reply))
	testing.expect(t, !app.permissions[0].replying)
	reply_permission(app, &app.permissions[0], "reject")
	bench_answer(app, bench_take(t, .Permission_Reply), 200, "")
	testing.expect_value(t, len(app.permissions), 0)
}

@(test)
dismiss_does_not_race_an_answer_and_stays_until_it_is_done :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	show(app, "s")
	bench_event(app, `{"type":"form.created","data":{"form":{"id":"f","sessionID":"s","fields":[]}}}`)
	f := form_find(app, "f")
	f.sending = true   // (its answer on its way)
	form_dismiss(app, f)
	testing.expect_value(t, bench_count(.Form_Dismiss), 0)
	f.sending = false
	form_dismiss(app, f)
	form_dismiss(app, f)
	testing.expect_value(t, bench_count(.Form_Dismiss), 1)
	testing.expect(t, form_find(app, "f") != nil, "until the server has it")
	bench_lost(app, bench_take(t, .Form_Dismiss))
	testing.expect(t, !form_find(app, "f").sending, "the run still waits for it: it can be answered")
	form_dismiss(app, form_find(app, "f"))
	bench_answer(app, bench_take(t, .Form_Dismiss), 200, "")
	testing.expect(t, form_find(app, "f") == nil)
}

@(test)
a_reconnection_reads_what_the_session_needs_once :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	show(app, "s")
	bench_event(app, `{"type":"permission.asked","data":{"request":{"id":"p","sessionID":"other"}}}`)
	stream_down(app, 200)
	testing.expect_value(t, app.link, Conn_State.Retrying)
	stream_up(app)
	for kind in ([]Req_Kind{.Messages, .Self, .Children, .Agents, .Models, .Slash}) { testing.expect_value(t, bench_count(kind), 1) }
	testing.expect_value(t, bench_count(.Permissions), 2)   // (the session shown, and the one with a card)
	testing.expect_value(t, bench_count(.Forms), 2)
	bench_clear(app)
	stream_up(app)
	testing.expect_value(t, len(bench_sent), 0)
}

////////////////////////////////
// The connection

@(test)
a_refused_stream_says_so_and_it_clears :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	app.link = .Connecting
	stream_down(app, 401)
	testing.expect_value(t, app.link, Conn_State.Auth_Refused)
	stream_down(app, 0)
	testing.expect_value(t, app.link, Conn_State.Retrying)
	stream_down(app, 401)
	stream_up(app)
	testing.expect_value(t, app.link, Conn_State.Online)
	bench_clear(app)
	// (a request's 401 while the stream is up does not say the link is down: nothing would clear it)
	request(app, .Info, "GET", "/i")
	bench_answer(app, bench_take(t, .Info), 401, "")
	testing.expect_value(t, app.link, Conn_State.Online)
}

@(test)
an_answer_replaces_agents_and_models :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	for _ in 0 ..< 2 {
		request(app, .Models, "GET", "/m")
		bench_answer(app, bench_take(t, .Models), 200, page(JSON_MODEL))
		request(app, .Agents, "GET", "/a")
		bench_answer(app, bench_take(t, .Agents), 200, `{"data":[{"id":"a"}]}`)
	}
	testing.expect_value(t, len(app.models), 1)
	testing.expect_value(t, len(app.agents), 1)
}

@(test)
a_moved_server_gives_the_place_back_when_it_has_the_session :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	app.cx.reopen = {id = strings.clone("s"), msg = strings.clone("m"), dy = 12}
	request(app, .Sessions, "GET", "/s")
	bench_answer(app, bench_take(t, .Sessions), 200, `{"data":[{"id":"t"}]}`)
	testing.expect_value(t, app.chat.id, "")
	testing.expect_value(t, app.cx.reopen.id, "")

	app.cx.reopen = {id = strings.clone("s"), msg = strings.clone("m"), dy = 12}
	request(app, .Sessions, "GET", "/s")
	bench_answer(app, bench_take(t, .Sessions), 200, `{"data":[{"id":"s"}]}`)
	testing.expect_value(t, app.chat.id, "s")
	testing.expect_value(t, app.cx.restore_msg, "m")
	testing.expect(t, !app.stick_bottom)
}

////////////////////////////////
// What is put off

@(test)
a_deferred_read_comes_after_the_last_asking_and_not_never :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	refresh_soon(app)
	testing.expect(t, deferred_in_ms(&app.cx.due[.Refresh]) > 0, "a wake is due")
	bench_clock += REFRESH_DEBOUNCE_MS - 1
	refresh_soon(app)   // (another event: it moves back)
	bench_clock += 2    // (past the first deadline: that one would race what the event followed)
	deferred_tick(app)
	testing.expect_value(t, bench_count(.Sessions), 0)
	bench_clock += REFRESH_DEBOUNCE_MS
	deferred_tick(app)
	testing.expect_value(t, bench_count(.Sessions), 1)
	testing.expect_value(t, deferred_in_ms(&app.cx.due[.Refresh]), 0)
	bench_clear(app)
	// events without end
	for _ in 0 ..< 100 {
		refresh_soon(app)
		bench_clock += REFRESH_DEBOUNCE_MS / 2
		deferred_tick(app)
	}
	testing.expect(t, bench_count(.Sessions) > 1, "it still reads")
}

@(test)
at_rest_nothing_wakes_the_window :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	append(&app.servers, Server{local = false})
	deferred_tick(app)
	testing.expect_value(t, app.state.wake_ms, 0)
	children_soon(app)
	deferred_tick(app)
	testing.expect(t, app.state.wake_ms > 0, "it does while something is due")
}

@(test)
what_runs_wakes_its_next_reading :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	show(app, "s")
	app.chat.have_self = true
	append(&app.activity.jobs, Shell_Job{id = strings.clone("j"), status = .Running})
	activity_tick(app)
	bench_clear(app)
	testing.expect(t, activity_in_ms(app) > 0)
	app.activity.jobs[0].status = .Exited
	testing.expect_value(t, activity_in_ms(app), 0)
}

////////////////////////////////
// The conversation

@(private = "file")
MSG_RUNNING :: `{"id":"a1","type":"assistant","time":{"created":1},"content":[{"type":"text","text":"Hello"}]}`

@(test)
a_page_does_not_undo_what_was_streamed_since_it_was_asked :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	show(app, "s")
	load_messages(app, "s")
	first := bench_take(t, .Messages)
	bench_answer(app, first, 200, page(MSG_RUNNING))

	load_messages(app, "s")
	r := bench_take(t, .Messages)
	bench_event(app, `{"type":"session.text.delta","data":{"sessionID":"s","assistantMessageID":"a1","ordinal":0,"delta":" world"}}`)
	bench_event(app, `{"type":"session.text.started","data":{"sessionID":"s","assistantMessageID":"a2","ordinal":0}}`)
	bench_answer(app, r, 200, page(MSG_RUNNING))
	testing.expect_value(t, len(app.chat.messages), 2)
	testing.expect_value(t, string(app.chat.messages[0].parts[0].text[:]), "Hello world")
	testing.expect_value(t, app.chat.messages[1].id, "a2")

	// a page asked after them says what it says
	load_messages(app, "s")
	bench_answer(app, bench_take(t, .Messages), 200, page(MSG_RUNNING))
	testing.expect_value(t, len(app.chat.messages), 1)
	testing.expect_value(t, string(app.chat.messages[0].parts[0].text[:]), "Hello")
}

@(test)
a_conversation_that_could_not_be_read_says_so_and_a_retry_reads_it :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	testing.expect_value(t, chat_view(app), Chat_View.Home)
	open_chat(app, "s")
	testing.expect_value(t, chat_view(app), Chat_View.Loading)
	bench_answer(app, bench_take(t, .Messages), 404, `{"message":"no such session"}`)
	testing.expect_value(t, chat_view(app), Chat_View.Failed)
	testing.expect_value(t, app.cx.chat_read.state, Load_State.Refused)
	testing.expect_value(t, app.cx.chat_read.message, "no such session")
	bench_clear(app)
	chat_read(app)
	testing.expect_value(t, chat_view(app), Chat_View.Loading)
	bench_answer(app, bench_take(t, .Messages), 200, page())
	testing.expect_value(t, chat_view(app), Chat_View.Shown)
}

@(test)
the_home_page_is_one_state :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	testing.expect(t, app.chat.loaded, "at start")
	show(app, "s")
	new_session(app)
	testing.expect(t, app.chat.loaded)
	show(app, "s")
	server_forget(app)
	testing.expect(t, app.chat.loaded, "after a server")
}

@(test)
what_the_reader_chose_stands_over_what_was_used :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	// the remembered one, at start
	config.set_from_string(&app.cfg_prefs, "session.agent", "plan", .User)
	config.set_from_string(&app.cfg_prefs, "session.model", "remembered", .User)
	testing.expect_value(t, shown_agent(app), "plan")
	model, _ := shown_model(app)
	testing.expect_value(t, model, "remembered")

	show(app, "s")
	choose_model(app, Model_Info{id = "m9", provider = "p9"})
	testing.expect_value(t, config.string_of(&app.cfg_prefs, "session.model"), "m9")
	used := `{"id":"a1","type":"assistant","agent":"build","model":{"id":"m1","providerID":"p1"},"time":{"created":1,"completed":2},"content":[]}`
	load_messages(app, "s")
	bench_answer(app, bench_take(t, .Messages), 200, page(used))
	model, _ = shown_model(app)
	testing.expect_value(t, model, "m9")
	testing.expect_value(t, app.chat.model, "m1")
	testing.expect_value(t, shown_agent(app), "build")

	// the session did not take it: what it uses is shown again
	bench_lost(app, bench_take(t, .Session_Choice))
	model, _ = shown_model(app)
	testing.expect_value(t, model, "m1")
}

@(test)
back_goes_nowhere_that_is_gone :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	show(app, "parent")
	append(&app.nav, strings.clone("parent"))
	append(&app.nav, strings.clone("deleted"))
	show(app, "child")
	nav_forget(app, "deleted")
	testing.expect_value(t, len(app.nav), 1)
	testing.expect_value(t, back_target(app), "parent")
	new_session(app)
	testing.expect_value(t, len(app.nav), 0)
	testing.expect_value(t, back_target(app), "")
}

@(test)
a_session_deleted_elsewhere_goes_and_what_was_for_it_comes_home :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	show(app, "s")
	ui.area_set(&app.composer, "for s")
	submit_prompt(app)
	r := bench_take(t, .Prompt)
	bench_event(app, `{"type":"session.deleted","data":{"sessionID":"s"}}`)
	bench_lost(app, r)
	testing.expect_value(t, ui.area_string(&app.composer), "")
	nav_apply(app)
	testing.expect_value(t, app.chat.id, "")
	testing.expect_value(t, ui.area_string(&app.composer), "for s")
}

@(test)
a_late_list_of_runs_does_not_undo_the_stream :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	show(app, "s")
	request(app, .Active, "GET", "/a")
	r := bench_take(t, .Active)
	bench_event(app, `{"type":"session.execution.started","data":{"sessionID":"s"}}`)
	bench_answer(app, r, 200, `{"data":{}}`)
	testing.expect(t, app.chat.busy, "it started after that list was asked for")

	request(app, .Active, "GET", "/a")
	r = bench_take(t, .Active)
	bench_event(app, `{"type":"session.idle","data":{"sessionID":"s"}}`)
	bench_answer(app, r, 200, `{"data":{"s":{}}}`)
	testing.expect(t, !app.chat.busy, "it ended after that list was asked for")

	request(app, .Active, "GET", "/a")
	bench_answer(app, bench_take(t, .Active), 200, `{"data":{"s":{}}}`)
	testing.expect(t, app.chat.busy, "a list asked after that is the newer one")
}

@(test)
parts_say_only_what_they_know :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	a := context.temp_allocator
	v, _ := json.parse_string(`{"id":"a","type":"assistant","time":{"created":1},"content":[
		{"type":"reasoning","text":"first"},{"type":"tool","id":"t","name":"x","state":{"status":"a word from the future"}},{"type":"reasoning","text":"second"}]}`, parse_integers = true, allocator = a)
	m := message_from_json(v, a)
	testing.expect(t, m.parts[0].done, "followed by something")
	testing.expect_value(t, m.parts[1].status, Tool_Status.Unknown)
	testing.expect(t, !m.parts[2].done, "the last one of a message that runs")
}

////////////////////////////////
// Activity

@(test)
the_first_reading_waits_for_the_folder :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	show(app, "s")
	activity_tick(app)
	testing.expect_value(t, bench_count(.Shell_List), 0)
	request(app, .Self, "GET", "/s", tag = "s")
	bench_answer(app, bench_take(t, .Self), 200, `{"data":{"id":"s","location":{"directory":"D:/w"}}}`)
	activity_tick(app)
	r := bench_take(t, .Shell_List)
	testing.expect_value(t, r.tag, "D:/w")
}

@(test)
a_job_ends_only_when_the_server_says_it_does_not_know_it :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	show(app, "s")
	append(&app.activity.jobs, Shell_Job{id = strings.clone("j"), status = .Running})
	request(app, .Shell_One, "GET", "/j", tag = "j")
	bench_lost(app, bench_take(t, .Shell_One))
	testing.expect_value(t, app.activity.jobs[0].status, Job_Status.Running)
	request(app, .Shell_One, "GET", "/j", tag = "j")
	bench_answer(app, bench_take(t, .Shell_One), 404, "")
	testing.expect_value(t, app.activity.jobs[0].status, Job_Status.Exited)
}

////////////////////////////////
// The view, the keys, find

@(test)
what_the_reader_asks_wins_over_a_view_going_back :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	show(app, "s")
	nav_restore_begin(app, "m", 0)
	app.stick_bottom = false
	ui.area_set(&app.composer, "go")
	submit_prompt(app)
	testing.expect_value(t, app.cx.restore_msg, "")
	testing.expect(t, app.stick_bottom)
}

@(test)
a_view_going_back_gives_up :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	show(app, "s")
	// the page it needs failed
	app.chat.loading_older = true
	nav_restore_begin(app, "m", 0)
	request(app, .Older, "GET", "/o", tag = "s")
	bench_lost(app, bench_take(t, .Older))
	testing.expect_value(t, app.cx.restore_msg, "")
	// the message is never built: the clock ends it
	nav_restore_begin(app, "m", 0)
	bench_clock += NAV_RESTORE_WAIT_MS + 1
	deferred_tick(app)
	testing.expect_value(t, app.cx.restore_msg, "")
	// a page that comes gives it a whole wait again: a long way up a history is not a view that gets nowhere
	nav_restore_begin(app, "m", 0)
	bench_clock += NAV_RESTORE_WAIT_MS - 1
	nav_restore_page(app)
	bench_clock += 2
	deferred_tick(app)
	testing.expect_value(t, app.cx.restore_msg, "m")
	bench_clock += NAV_RESTORE_WAIT_MS
	deferred_tick(app)
	testing.expect_value(t, app.cx.restore_msg, "")
}

@(test)
the_scroll_bar_held_is_the_reader_moving :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	sb := new(ui.Box)
	sb.key = 7
	bar := ui.Key(8)
	app.state.sb_owner[bar] = sb.key
	testing.expect(t, !scrollbar_held(app, sb))
	app.state.active_key[.Left] = bar
	testing.expect(t, scrollbar_held(app, sb))
}

@(test)
an_inbox_item_does_not_fetch_a_reader_who_went_up :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	show(app, "s")
	app.stick_bottom = false
	bench_event(app, `{"type":"session.inbox.enqueued","data":{"sessionID":"s","inboxID":"i","item":{"type":"user","payload":{"text":"later"}}}}`)
	testing.expect_value(t, len(app.chat.messages), 1)
	testing.expect(t, !app.stick_bottom)
}

@(test)
what_is_open_has_the_keys :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	new_one := command_find("session.new")
	palette := command_find("app.palette")
	help := command_find("app.help")
	testing.expect(t, command_keyed(app, new_one) && command_keyed(app, palette))
	app.settings_open = true
	testing.expect(t, !command_keyed(app, new_one), "a shortcut does not act behind a dialog")
	testing.expect(t, !command_keyed(app, palette))
	app.settings_open = false
	app.palette.open = true
	testing.expect(t, command_keyed(app, palette), "its key closes it")
	testing.expect(t, !command_keyed(app, help))
	app.palette.open = false
	app.cx.help_open = true
	testing.expect(t, command_keyed(app, help))
}

@(test)
commands_asked_together_all_run :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	command_run(app, command_find("view.sidebar"))
	command_run(app, command_find("app.help"))
	commands_apply(app)
	testing.expect(t, app.cx.sidebar_hidden && app.cx.help_open)
	testing.expect_value(t, len(app.cx.commands_due), 0)
}

@(test)
ctrl_p_is_the_files_alone :: proc(t: ^testing.T) {
	for &c in COMMANDS {
		if c.key == .P && c.mods == {.Ctrl} { testing.expect_value(t, c.id, "session.files") }
	}
}

@(test)
find_follows_the_conversation :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	show(app, "a")
	app.find.open = true
	app.find.index = 4
	app.find.reveal = true
	show(app, "b")
	testing.expect_value(t, app.find.index, -1)
	testing.expect(t, app.find.open && !app.find.reveal)
	new_session(app)
	testing.expect(t, !app.find.open, "the home page has no conversation to search")
}

// A link that died in silence: only the stream has a limit on it, so its return is what opens the shells' sockets again. Not a first
// connection, and not for a shell of another server.
@(test)
the_stream_coming_back_renews_the_shells_sockets :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()   // (the App keeps what it made, as the program does, till it ends)
	app := bench_new()
	here, there := new(Term_Conn), new(Term_Conn)
	other := new(Conn)
	append(&app.cx.terms.list, new_clone(Term{server = app.conn, conn = here}), new_clone(Term{server = other, conn = there}))
	app.link = .Connecting
	stream_up(app)
	testing.expect(t, !here.renew, "a first connection has nothing to renew")
	app.link = .Retrying
	stream_up(app)
	testing.expect(t, here.renew, "the socket of this server's shell")
	testing.expect(t, !there.renew, "not another server's")
	here.renew = false
	stream_up(app)
	testing.expect(t, !here.renew, "still up: nothing happened")
}

// A session opened: what was on the screen stays until its first page, for a moment; never for a window with nothing to keep.
@(test)
what_was_shown_stays_while_a_first_page_comes :: proc(t: ^testing.T) {
	app := bench_new()
	size := draw.Vec2{800, 600}
	app.chat.id, app.chat.loading, app.chat.loaded = "s", true, false
	app.opened_ms = ui.now_ms()
	testing.expect_value(t, frame_held_ms(app, size), 0)   // (nothing shown yet)
	app.shown = {int(size.x), int(size.y)}
	testing.expect(t, frame_held_ms(app, size) > 0, "held")
	testing.expect_value(t, frame_held_ms(app, {801, 600}), 0)   // (resized: the picture would not fit)
	app.opened_ms = ui.now_ms() - OPEN_HOLD_MS - 1
	testing.expect_value(t, frame_held_ms(app, size), 0)   // (a slow server: Loading says so)
	app.opened_ms = ui.now_ms()
	app.chat.loading, app.chat.loaded = false, true
	testing.expect_value(t, frame_held_ms(app, size), 0)   // (it came: shown at once)
}

// A session's rules read as a preset: none, or one of the presets' own rule; any other set of rules is Custom (left alone).
@(test)
a_sessions_rules_read_as_a_preset :: proc(t: ^testing.T) {
	of :: proc(text: string) -> Approval {
		v, err := json.parse_string(text, allocator = context.temp_allocator)
		assert(err == nil, text)
		return approval_of(v)
	}
	testing.expect_value(t, approval_of(nil), Approval.Configured)
	testing.expect_value(t, of(`[]`), Approval.Configured)
	for m in Approval {
		if m == .Configured || m == .Custom { continue }
		testing.expectf(t, of(APPROVAL_RULES[m]) == m, "%v reads as itself", m)
	}
	testing.expect_value(t, of(`[{"action":"shell","resource":"*","effect":"allow"}]`), Approval.Custom)
	testing.expect_value(t, of(`[{"action":"*","resource":"*","effect":"allow"},{"action":"shell","resource":"rm *","effect":"ask"}]`), Approval.Custom)
}

// The shield sets the session's rules on the server, and shows what the server says of them, from this client or another;
// a permission asked is never answered here in the server's place.
@(test)
the_approval_mode_is_the_servers :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	show(app, "s")
	// the session shown, as the server describes it (no rules of its own)
	self, _ := json.parse_string(`{"data":{"id":"s","title":"t"}}`, allocator = context.temp_allocator)
	self_load(app, self, 0)
	testing.expect_value(t, approval_shown(app), Approval.Configured)
	approval_set(app, "s", .Allow_All)
	r := bench_take(t, .Action)
	testing.expect_value(t, r.method, "PATCH")
	testing.expect_value(t, r.path, "/api/session/s")
	testing.expect_value(t, r.body, `{"permissions":[{"action":"*","resource":"*","effect":"allow"}]}`)
	testing.expect_value(t, approval_shown(app), Approval.Allow_All)
	approval_set(app, "s", .Configured)
	testing.expect_value(t, bench_take(t, .Action).body, `{"permissions":null}`)
	// another client's choice
	bench_event(app, `{"type":"session.permissions","data":{"sessionID":"s","permissions":[{"action":"edit","resource":"*","effect":"allow"}]}}`)
	testing.expect_value(t, approval_shown(app), Approval.Allow_Edits)
	bench_event(app, `{"type":"session.permissions","data":{"sessionID":"other","permissions":[]}}`)
	testing.expect_value(t, approval_shown(app), Approval.Allow_Edits)   // (another session's)
	// what the server asks waits for an answer from someone: none from here by itself
	bench_event(app, `{"type":"permission.asked","data":{"request":` + PERM_P + `}}`)
	testing.expect_value(t, bench_count(.Permission_Reply), 0)
}

// A session made here starts with the preset of permission.new_sessions: its rules go in the request that makes it.
@(test)
a_new_session_starts_with_the_default_approvals :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	testing.expect_value(t, new_session_body(app, ""), "{}")
	testing.expect_value(t, new_session_body(app, "/w"), `{"location":{"directory":"/w"}}`)
	pref_set(app, "permission.new_sessions", "allow_all")
	defer pref_set(app, "permission.new_sessions", "configured")
	testing.expect_value(t, new_session_body(app, "/w"), `{"location":{"directory":"/w"},"permissions":[{"action":"*","resource":"*","effect":"allow"}]}`)
	outgoing_composer(app, "hello", "/w")
	r := bench_take(t, .Created)
	testing.expect(t, strings.contains(r.body, `"permissions":[{"action":"*","resource":"*","effect":"allow"}]`), r.body)
}

// A project's icon of the user's own: an image goes to the server as the icon's override, made the icon's size (a PNG data URL);
// what is no image goes nowhere, a removal empties it; the projects read again say which have one.
@(test)
a_projects_icon_is_set_on_the_server :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	dir := fmt.tprintf("%s/ocn_project_icon", fsx.temp_dir(context.temp_allocator))
	fsx.make_dirs(dir)
	defer fsx.remove_tree(dir)
	// a real image, larger than the icon's side: what goes is a PNG of PROJECT_ICON_SIDE at most, its proportions kept
	big := make([]u8, 600 * 300 * 4, context.temp_allocator)
	for i in 0 ..< 600 * 300 { big[i * 4], big[i * 4 + 3] = 200, 255 }
	jpg_like := fmt.tprintf("%s/wide.png", dir)
	_ = os.write_entire_file(jpg_like, png.encode(big, 600, 300, allocator = context.temp_allocator))
	project_icon_set_file(app, "p1", jpg_like)
	r := bench_take(t, .Project_Icon)
	testing.expect_value(t, r.method, "PATCH")
	testing.expect_value(t, r.path, "/api/project/p1")
	prefix := `{"icon":{"override":"data:image/png;base64,`
	if testing.expect(t, strings.has_prefix(r.body, prefix), r.body[:min(len(r.body), 80)]) {
		b64 := r.body[len(prefix):len(r.body) - len(`"}}`)]
		sent, _ := base64.decode(b64, allocator = context.temp_allocator)
		w, h, ok := png_size(sent)
		testing.expect(t, ok && w == PROJECT_ICON_SIDE && h == PROJECT_ICON_SIDE / 2, "made the icon's size, its proportions kept")
	}
	txt := fmt.tprintf("%s/notes.txt", dir)
	_ = os.write_entire_file(txt, transmute([]u8)string("hello"))
	project_icon_set_file(app, "p1", txt)
	testing.expect_value(t, bench_count(.Project_Icon), 0)   // (no image: nothing sent)
	project_icon_remove(app, "p1")
	testing.expect_value(t, bench_take(t, .Project_Icon).body, `{"icon":{"override":""}}`)
	v, _ := json.parse_string(`[{"id":"p1","icon":{"url":"data:image/png;base64,AA","override":"data:image/png;base64,BB"}},{"id":"p2","icon":{"url":"data:image/png;base64,AA","override":""}}]`, allocator = context.temp_allocator)
	projects_load(app, v)
	testing.expect(t, project_icon_overridden(app, "p1"), "p1: the user's own")
	testing.expect(t, !project_icon_overridden(app, "p2"), "p2: the one found in the project")
}

// A PNG's width and height (its IHDR), for what a test sent.
@(private = "file")
png_size :: proc(data: []u8) -> (w, h: int, ok: bool) {
	if len(data) < 24 || string(data[12:16]) != "IHDR" { return }
	be :: proc(b: []u8) -> int { return int(b[0]) << 24 | int(b[1]) << 16 | int(b[2]) << 8 | int(b[3]) }
	return be(data[16:20]), be(data[20:24]), true
}

// The tray is the session's: a folder's commands of another session stay out; those it pushed back say so.
@(test)
the_tray_shows_the_sessions_commands_only :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	show(app, "s")
	app.activity.dir = strings.clone("/w")
	shells, _ := json.parse_string(`{"data":[
		{"id":"a","status":"running","command":"ours","cwd":"/w","metadata":{"sessionID":"s"},"time":{"started":1}},
		{"id":"b","status":"running","command":"theirs","cwd":"/w","metadata":{"sessionID":"other"},"time":{"started":1}},
		{"id":"c","status":"running","command":"nobody's","cwd":"/w","metadata":{},"time":{"started":1}}]}`, allocator = context.temp_allocator)
	activity_shells_load(app, shells, "/w")
	testing.expect_value(t, len(app.activity.jobs), 3)
	ours := map[string]bool{}
	defer delete(ours)
	for &j in app.activity.jobs { ours[j.id] = job_ours(app, &j) }
	testing.expect(t, ours["a"] && !ours["b"] && ours["c"], "the session's and the unclaimed")
	_, shells_counted := activity_counts(app)
	testing.expect_value(t, shells_counted, 2)   // (the line over the composer counts the same ones)
	jobs, _ := json.parse_string(`{"data":[{"kind":"shell","id":"a","sessionID":"s","status":"running","shellID":"a","command":"ours","time":{"started":1}}]}`, allocator = context.temp_allocator)
	activity_jobs_load(app, jobs, "s")
	for &j in app.activity.jobs { testing.expect_value(t, j.background, j.id == "a") }
}

// The composer is each session's: what is typed in one comes back with it, and another starts from its own.
@(test)
the_composer_is_each_sessions :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	defer drafts_destroy(app)
	show(app, "a")
	ui.area_set(&app.composer, "for a")
	show(app, "b")
	testing.expect_value(t, ui.area_string(&app.composer), "")
	ui.area_set(&app.composer, "for b")
	show(app, "a")
	testing.expect_value(t, ui.area_string(&app.composer), "for a")
	show(app, "b")
	testing.expect_value(t, ui.area_string(&app.composer), "for b")
	chat_home(app)
	testing.expect_value(t, ui.area_string(&app.composer), "")
	show(app, "a")
	testing.expect_value(t, ui.area_string(&app.composer), "for a")
	testing.expect_value(t, len(app.cx.drafts), 1)   // (b's; a's is in the composer, the home page's was empty)
}

// The session's goal: read when shown, followed by the stream, gone when cleared; another session's says nothing here.
@(test)
the_goal_shows_over_the_composer :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	defer drafts_destroy(app)
	open_chat(app, "s")
	r := bench_take(t, .Goal)
	testing.expect(t, strings.contains(r.body, `"sessionID":"s"`))
	bench_answer(app, r, 200, `{"output":{"id":"g","objective":"ship it","status":"active","rounds":2,"maxRounds":10,"boot":"b","updatedAt":1}}`)
	testing.expect(t, app.chat.has_goal)
	testing.expect_value(t, app.chat.goal.objective, "ship it")
	testing.expect_value(t, app.chat.goal.rounds, 2)
	bench_event(app, `{"type":"rpc.opencode.goal.changed","data":{"sessionID":"other","goal":null}}`)
	testing.expect(t, app.chat.has_goal, "another session's goal")
	bench_event(app, `{"type":"rpc.opencode.goal.changed","data":{"sessionID":"s","goal":{"id":"g","objective":"ship it","status":"paused","rounds":3,"maxRounds":10,"boot":"b","updatedAt":2}}}`)
	testing.expect_value(t, app.chat.goal.status, Goal_Status.Paused)
	bench_event(app, `{"type":"rpc.opencode.goal.changed","data":{"sessionID":"s","goal":null}}`)
	testing.expect(t, !app.chat.has_goal, "cleared")
}

// A session at rest whose commands still run in the background says so; a sub-agent's command lights its parent too.
@(test)
the_sessions_with_commands_in_the_background :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	append(&app.sessions, Session_Info{id = "root"}, Session_Info{id = "child", parent = "root"}, Session_Info{id = "other"})
	defer clear(&app.sessions)
	v, _ := json.parse_string(`{"data":[{"kind":"shell","id":"j","sessionID":"child","status":"running","shellID":"j","command":"sleep 9","time":{"started":1}}]}`, allocator = context.temp_allocator)
	background_load(app, v)
	testing.expect(t, session_in_background(app, "child"))
	testing.expect(t, session_in_background(app, "root"), "its parent")
	testing.expect(t, !session_in_background(app, "other"))
	none, _ := json.parse_string(`{"data":[]}`, allocator = context.temp_allocator)
	background_load(app, none)
	testing.expect(t, !session_in_background(app, "root"), "all ended")
	delete(app.cx.background)
	app.cx.background = nil
}

// A shell call of the conversation that went to the background says so, and whether its command still runs there.
@(test)
a_shell_call_in_the_background :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	fg := test_tool("shell", `{"command":"sleep 9"}`, status = .Running)
	bg, running := part_background(app, &fg)
	testing.expect(t, !bg && !running, "in the foreground")
	moved := test_tool("shell", `{"command":"sleep 9"}`, "Command moved to the background (shell ID: sh_42).\nOutput is streaming to: x")
	append(&app.activity.jobs, Shell_Job{id = strings.clone("sh_42"), status = .Running, background = true})
	bg, running = part_background(app, &moved)
	testing.expect(t, bg && running, "in the background, running")
	app.activity.jobs[0].status = .Exited
	bg, running = part_background(app, &moved)
	testing.expect(t, bg && !running, "in the background, finished")
	read := test_tool("read", "", "(shell ID: sh_42)")
	bg, _ = part_background(app, &read)
	testing.expect(t, !bg, "only a shell call")
	asked := test_tool("shell", `{"command":"sleep 9","background":true}`, status = .Running)
	bg, _ = part_background(app, &asked)
	testing.expect(t, bg, "asked for the background in its input")
}

// The composer's texts go to disk as JSON and come back from it, each in its session; empty ones are not kept.
@(test)
the_drafts_survive_a_restart :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	defer drafts_destroy(app)
	show(app, "a")
	ui.area_set(&app.composer, "for a")
	show(app, "b")
	ui.area_set(&app.composer, "   ")
	saved := strings.clone(drafts_json(app), context.temp_allocator)
	testing.expect(t, strings.contains(saved, `"a":"for a"`), saved)
	testing.expect(t, !strings.contains(saved, `"b"`), "an empty text is not kept")

	again := bench_new()
	defer drafts_destroy(again)
	drafts_load_json(again, saved)
	show(again, "a")
	testing.expect_value(t, ui.area_string(&again.composer), "for a")
}

// A prompt sent empties the composer without a key: the disk hears of it too, and the text does not come back at the next start.
@(test)
a_sent_prompt_leaves_no_draft :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	defer drafts_destroy(app)
	show(app, "a")
	ui.area_set(&app.composer, "hello")
	drafts_track(app)
	app.cx.due[.Drafts] = {}
	ui.area_set(&app.composer, "")   // (as submit_prompt does)
	drafts_track(app)
	testing.expect(t, app.cx.due[.Drafts].due_ms != 0, "a save is due")
	testing.expect(t, !strings.contains(drafts_json(app), "hello"), drafts_json(app))
}

// The tray of what runs is each session's: open in one, closed in another, as each was left.
@(test)
the_tray_is_each_sessions :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	defer drafts_destroy(app)
	show(app, "a")
	activity_open(app)
	show(app, "b")
	testing.expect(t, !app.activity.open, "closed in another session")
	show(app, "a")
	testing.expect(t, app.activity.open, "open again where it was left open")
	activity_close(app)
	show(app, "b")
	show(app, "a")
	testing.expect(t, !app.activity.open, "closed where it was closed")
	activity_forget(app)
	delete(app.activity.open_in)
	app.activity.open_in = nil
}

// How hard the model thinks (its variant): read from what the session used, picked in the composer, sent with the model, kept
// across a change of model that has it too, remembered for a new session.
@(test)
the_thinking_level_goes_with_the_model :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	append(&app.models, Model_Info{id = strings.clone("opus"), provider = strings.clone("p"), efforts = strings.clone("low, high")},
		Model_Info{id = strings.clone("m2"), provider = strings.clone("p"), efforts = strings.clone("high")})
	show(app, "s")
	load_messages(app, "s")
	bench_answer(app, bench_take(t, .Messages), 200, page(`{"id":"a1","type":"assistant","agent":"build","model":{"id":"opus","providerID":"p","variant":"high"},"time":{"created":1,"completed":2},"content":[]}`))
	testing.expect_value(t, shown_variant(app), "high")
	load_messages(app, "s")
	bench_answer(app, bench_take(t, .Messages), 200, page(`{"id":"a2","type":"assistant","agent":"build","model":{"id":"opus","providerID":"p","variant":"default"},"time":{"created":1,"completed":2},"content":[]}`))
	testing.expect_value(t, shown_variant(app), "")   // ("default": none)

	choose_variant(app, "low")
	r := bench_take(t, .Session_Choice)
	testing.expect_value(t, r.body, `{"model":{"id":"opus","providerID":"p","variant":"low"}}`)
	testing.expect_value(t, shown_variant(app), "low")
	testing.expect_value(t, config.string_of(&app.cfg_prefs, "session.variant"), "low")

	choose_model(app, app.models[1])   // (m2 has no "low": its default)
	testing.expect_value(t, bench_take(t, .Session_Choice).body, `{"model":{"id":"m2","providerID":"p"}}`)
	testing.expect_value(t, shown_variant(app), "")
	choose_variant(app, "high")
	_ = bench_take(t, .Session_Choice)
	choose_model(app, app.models[0])   // (opus has "high": it stays)
	testing.expect_value(t, bench_take(t, .Session_Choice).body, `{"model":{"id":"opus","providerID":"p","variant":"high"}}`)

	// a new session starts with it
	show(app, "")
	ui.area_set(&app.composer, "go")
	submit_prompt(app)
	bench_answer(app, bench_take(t, .Created), 200, `{"data":{"id":"new"}}`)
	if bench_count(.Session_Agent) > 0 { bench_answer(app, bench_take(t, .Session_Agent), 200, "") }
	testing.expect_value(t, bench_take(t, .Session_Model).body, `{"model":{"id":"opus","providerID":"p","variant":"high"}}`)
}

// "/goal ..." sent before the server's commands are read (none yet: the stream not back, a server just left) waits for them and
// goes as the command, not as a prompt. A name the server has not, or commands that could not be read: a prompt, as written.
@(test)
a_slash_command_waits_for_the_commands :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	show(app, "s")
	testing.expect(t, !app.cx.have_slash, "no commands read")
	COMMANDS :: `{"data":[{"name":"goal","description":"Work on an objective until it is met"}]}`

	ui.area_set(&app.composer, "/goal ship the kernel")
	attach(app, "a.png")
	submit_prompt(app)
	testing.expect_value(t, bench_count(.Prompt), 0)
	testing.expect_value(t, ui.area_string(&app.composer), "")
	bench_answer(app, bench_take(t, .Slash), 200, COMMANDS)
	r := bench_take(t, .Prompt)
	testing.expect_value(t, r.path, "/api/session/s/command")
	testing.expect_value(t, r.body, `{"name":"goal","text":"ship the kernel"}`)
	testing.expect_value(t, len(app.cx.attachments), 1)   // (a command does not take it: back in the composer)
	bench_answer(app, r, 200, "")

	// a name the server has not: a prompt
	slash_forget(app)
	ui.area_set(&app.composer, "/nothing here")
	submit_prompt(app)
	bench_answer(app, bench_take(t, .Slash), 200, COMMANDS)
	r = bench_take(t, .Prompt)
	testing.expect_value(t, r.path, "/api/session/s/prompt")
	testing.expect(t, strings.has_prefix(r.body, `{"text":"/nothing here"`), r.body)
	bench_answer(app, r, 200, "")

	// the commands could not be read: a prompt all the same, nothing lost
	slash_forget(app)
	ui.area_set(&app.composer, "/goal pause")
	submit_prompt(app)
	bench_lost(app, bench_take(t, .Slash))
	r = bench_take(t, .Prompt)
	testing.expect_value(t, r.path, "/api/session/s/prompt")
	testing.expect(t, strings.has_prefix(r.body, `{"text":"/goal pause"`), r.body)
	bench_answer(app, r, 200, "")

	// not read then: asked again, and once read the next one goes at once
	ui.area_set(&app.composer, "/goal resume")
	submit_prompt(app)
	bench_answer(app, bench_take(t, .Slash), 200, COMMANDS)
	bench_answer(app, bench_take(t, .Prompt), 200, "")
	ui.area_set(&app.composer, "/goal clear")
	submit_prompt(app)
	testing.expect_value(t, bench_count(.Slash), 0)
	testing.expect_value(t, bench_take(t, .Prompt).body, `{"name":"goal","text":"clear"}`)
}

// The model or the agent chosen, here or elsewhere (session.model.selected, session.agent.selected): the composer says it at
// once, and the page is read again for its line in the conversation. Another session's says nothing here.
@(test)
a_choice_made_elsewhere_shows_at_once :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	show(app, "s")
	app.cx.due[.Refresh] = {}
	bench_event(app, `{"type":"session.model.selected","data":{"sessionID":"other","model":{"id":"x","providerID":"p"}}}`)
	testing.expect_value(t, app.cx.due[.Refresh].due_ms, 0)
	bench_event(app, `{"type":"session.model.selected","data":{"sessionID":"s","model":{"id":"claude-fable-5-2","providerID":"claude-agent","variant":"high"}}}`)
	bench_event(app, `{"type":"session.agent.selected","data":{"sessionID":"s","agent":"plan"}}`)
	model, _ := shown_model(app)
	testing.expect_value(t, model, "claude-fable-5-2")
	testing.expect_value(t, shown_variant(app), "high")
	testing.expect_value(t, shown_agent(app), "plan")
	testing.expect(t, app.cx.due[.Refresh].due_ms > 0, "the page read again")
}

// The goal's reason as the server says it ends with a time in UTC, after the same time in words: that sentence goes, and the line
// over the reason says the time on the local clock, and what is left.
@(test)
a_goal_s_reset_time_is_said_for_a_person :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	app.prefs.clock24 = true
	the_app = app   // (clock_time reads the 24-hour preference there)
	defer the_app = nil
	reason := "The session failed: You've hit your 5-hour limit · resets 12:20pm (Europe/Paris) Resets at 2026-11-10T11:20:00.000Z."
	text, at := reason_and_reset(reason)
	testing.expect_value(t, text, "The session failed: You've hit your 5-hour limit · resets 12:20pm (Europe/Paris)")
	testing.expect_value(t, at, 1794309600000.0)   // (2026-11-10 11:20 UTC)
	testing.expect_value(t, reset_text(at, at - 42 * 60_000 - 5_000), fmt.tprintf("  ·  resets at %s  ·  in 43 min", clock_time(at)))
	testing.expect_value(t, reset_text(at, at - 65 * 60_000), fmt.tprintf("  ·  resets at %s  ·  in 1h 05", clock_time(at)))
	testing.expect_value(t, reset_text(at, at + 1), fmt.tprintf("  ·  limit reset at %s", clock_time(at)))
	// another day: its date, and the time left in days
	later := at + 3 * 86_400_000
	testing.expect(t, strings.has_prefix(reset_text(later, at), "  ·  resets on Nov 13 at ") || strings.has_prefix(reset_text(later, at), "  ·  resets on Nov 14 at "), reset_text(later, at))
	testing.expect(t, strings.has_suffix(reset_text(later, at), "  ·  in 3d 00h"), reset_text(later, at))
	// a time in the middle of a sentence: the local clock's, in its place
	text, at = reason_and_reset("Paused until 2026-11-10T11:20:00Z by the user.")
	testing.expect_value(t, text, fmt.tprintf("Paused until %s by the user.", clock_time(1794309600000)))
	testing.expect_value(t, at, 1794309600000.0)
	text, at = reason_and_reset("The session failed: no time here.")
	testing.expect_value(t, text, "The session failed: no time here.")
	testing.expect_value(t, at, 0)
}

// Archiving asks the server (PATCH archived), and the list shows it at once; bringing it back, the same.
@(test)
archiving_asks_the_server_and_shows_at_once :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	append(&app.sessions, Session_Info{id = "s1", title = "One"})
	session_archive(app, "s1", true)
	r := bench_take(t, .Action)
	testing.expect_value(t, r.method, "PATCH")
	testing.expect_value(t, r.path, "/api/session/s1")
	testing.expect_value(t, r.body, `{"archived":true}`)
	testing.expect(t, session_is_archived(app, "s1"), "at once")
	// the list says it as the server keeps it
	v, _ := json.parse_string(`{"data":[{"id":"s1","title":"One","time":{"created":1,"updated":2,"archived":3}}]}`, allocator = context.temp_allocator)
	sessions_load(app, v)
	testing.expect(t, session_is_archived(app, "s1"), "time.archived")
	session_archive(app, "s1", false)
	testing.expect_value(t, bench_take(t, .Action).body, `{"archived":false}`)
	testing.expect(t, !session_is_archived(app, "s1"))
}
