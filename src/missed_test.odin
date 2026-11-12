package ocn

// What was missed (missed.odin) against what the program knows: the log is a projection of it, never a second truth. Each test
// fails without what it tests.

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:math/rand"
import "core:strings"
import "core:testing"
import "gt:platform"
import notices "gt:notices"

@(private = "file")
MISSED_LIST :: `{"data":[
	{"id":"waits","title":"Waits","location":{"directory":"C:/code/alpha"},"time":{"created":1,"updated":60,"idle":5,"viewed":5}},
	{"id":"ended","title":"Ended","outcome":"failed","location":{"directory":"C:/code/beta"},"time":{"created":1,"updated":50,"idle":40,"viewed":5}},
	{"id":"never","title":"Never viewed","location":{"directory":"C:/code/beta"},"time":{"created":1,"updated":45,"idle":40}},
	{"id":"seen","title":"Seen","location":{"directory":"C:/code/alpha"},"time":{"created":1,"updated":30,"idle":20,"viewed":20}},
	{"id":"sub","title":"A sub-agent","parentID":"seen","location":{"directory":"C:/code/alpha"},"time":{"created":1,"updated":10,"idle":9}}
]}`

@(private = "file")
listed :: proc(app: ^App, body: string) {
	v, err := json.parse_string(body, parse_integers = true, allocator = context.temp_allocator)
	assert(err == nil)
	sessions_load(app, v)
}

// The list again, as the server would give it now: what this client knows of each session, without `without` (deleted).
@(private = "file")
relisted :: proc(app: ^App, without := "") {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, `{"data":[`)
	n := 0
	for s in app.sessions {
		if s.id == without { continue }
		if n > 0 { strings.write_byte(&b, ',') }
		fmt.sbprintf(&b, `{{"id":"%s","title":"%s","parentID":"%s","outcome":"%s","time":{{"created":1,"updated":%.0f,"idle":%.0f,"viewed":%.0f}}}}`,
			s.id, s.title, s.parent, s.outcome, s.updated, s.idle, s.viewed)
		n += 1
	}
	strings.write_string(&b, "]}")
	listed(app, strings.to_string(b))   // (the text is made before the list's memory is renewed)
}

@(private = "file")
open_entry :: proc(app: ^App, kind: Missed_Kind, id: string, asker := "") -> ^notices.Entry {
	return missed_log(app).live[missed_key(app, kind, id, asker)]
}

// For every session, at every step of a random sequence of what happens: an end not acknowledged in the log is a run that
// ended and that nobody saw (session_unseen), and a wait not acknowledged is a session that waits (sessions_waiting). A
// session deleted has nothing left in the log. A second truth (an entry kept by the log on its own) breaks it at once.
@(test)
what_was_missed_is_what_the_program_knows :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	state := rand.create(u64(20261112))
	context.random_generator = rand.default_random_generator(&state)
	listed(app, `{"data":[
		{"id":"r0","title":"R0","time":{"created":1,"updated":90,"idle":10,"viewed":10}},
		{"id":"r1","title":"R1","time":{"created":1,"updated":80,"idle":10,"viewed":10}},
		{"id":"r2","title":"R2","time":{"created":1,"updated":70,"idle":10,"viewed":10}},
		{"id":"r3","title":"R3","time":{"created":1,"updated":60,"idle":10,"viewed":10}},
		{"id":"r4","title":"R4","time":{"created":1,"updated":50,"idle":10,"viewed":10}},
		{"id":"r5","title":"R5","time":{"created":1,"updated":40,"idle":10,"viewed":10}},
		{"id":"c0","title":"C0","parentID":"r0","time":{"created":1,"updated":30,"idle":10,"viewed":10}},
		{"id":"c1","title":"C1","parentID":"r2","time":{"created":1,"updated":20,"idle":10,"viewed":10}}
	]}`)
	perms := make([dynamic]string, context.temp_allocator)
	forms := make([dynamic]string, context.temp_allocator)
	pick :: proc(app: ^App, roots_only := false) -> string {
		ids := make([dynamic]string, context.temp_allocator)
		for s in app.sessions { if !roots_only || s.parent == "" { append(&ids, strings.clone(s.id, context.temp_allocator)) } }
		return ids[rand.int_max(len(ids))]
	}
	has_children :: proc(app: ^App, id: string) -> bool {
		for s in app.sessions { if s.parent == id { return true } }
		return false
	}
	ENDS := [3]string{"succeeded", "failed", "interrupted"}
	next := 0
	for step in 0 ..< 600 {
		op := rand.int_max(10)
		switch op {
		case 0, 1:   // a run ends (the same session again: a new run)
			id := pick(app)
			bench_event(app, fmt.tprintf(`{{"type":"session.execution.started","data":{{"sessionID":"%s"}}}}`, id))
			bench_event(app, fmt.tprintf(`{{"type":"session.execution.%s","data":{{"sessionID":"%s"}}}}`, ENDS[rand.int_max(3)], id))
		case 2:      // another client saw it
			id := pick(app, roots_only = true)
			bench_event(app, fmt.tprintf(`{{"type":"session.viewed","data":{{"sessionID":"%s","idle":%.0f}}}}`, id, find_session(app, id).idle))
		case 3:      // the list comes
			relisted(app)
		case 4:      // a session is deleted (the server cancels what it asked)
			if len(app.sessions) <= 3 { continue }
			id := pick(app)
			if has_children(app, id) { continue }
			for {
				gone := ""
				for p in app.permissions { if p.session == id { gone = strings.clone(p.id, context.temp_allocator); break } }
				if gone == "" { break }
				bench_event(app, fmt.tprintf(`{{"type":"permission.replied","data":{{"id":"%s"}}}}`, gone))
			}
			for {
				gone := ""
				for f in app.cx.forms { if f.session == id { gone = strings.clone(f.id, context.temp_allocator); break } }
				if gone == "" { break }
				bench_event(app, fmt.tprintf(`{{"type":"form.cancelled","data":{{"id":"%s"}}}}`, gone))
			}
			if id == app.chat.id { chat_home(app) }
			gid := strings.clone(id, context.temp_allocator)
			bench_event(app, fmt.tprintf(`{{"type":"session.deleted","data":{{"sessionID":"%s"}}}}`, gid))
			relisted(app, gid)
			missed_sync(app)
			for e in missed_log(app).entries {
				if e.group == missed_group(app, gid) || e.key == missed_key(app, .Sub, gid) {
					testing.expectf(t, false, "step %d: %s deleted, its entry %q stays", step, gid, e.key)
					return
				}
			}
		case 5:      // a permission is asked
			next += 1
			id := fmt.tprintf("p%d", next)
			append(&perms, id)
			bench_event(app, fmt.tprintf(`{{"type":"permission.asked","data":{{"request":{{"id":"%s","sessionID":"%s","action":"bash"}}}}}}`, id, pick(app)))
		case 6:      // ... and answered
			if len(perms) == 0 { continue }
			i := rand.int_max(len(perms))
			bench_event(app, fmt.tprintf(`{{"type":"permission.replied","data":{{"id":"%s"}}}}`, perms[i]))
			unordered_remove(&perms, i)
		case 7:      // a question is asked
			next += 1
			id := fmt.tprintf("f%d", next)
			append(&forms, id)
			bench_event(app, fmt.tprintf(`{{"type":"form.created","data":{{"form":{{"id":"%s","sessionID":"%s","title":"Which?","fields":[]}}}}}}`, id, pick(app)))
		case 8:      // ... and cancelled
			if len(forms) == 0 { continue }
			i := rand.int_max(len(forms))
			bench_event(app, fmt.tprintf(`{{"type":"form.cancelled","data":{{"id":"%s"}}}}`, forms[i]))
			unordered_remove(&forms, i)
		case 9:      // the person opens a session, or goes home
			if rand.int_max(3) == 0 { chat_home(app) } else { open_chat(app, pick(app, roots_only = true)) }
		}
		effects_clear(app)
		bench_clear(app)
		missed_sync(app)

		log := missed_log(app)
		asked := make(map[string]bool, allocator = context.temp_allocator)
		for e in log.entries {
			if e.state == .Acknowledged { continue }
			if Missed_Kind(e.kind) == .End {
				id, _, _ := missed_key_parts(app, e.key)
				if find_session(app, id) == nil { testing.expectf(t, false, "step %d (op %d): an end of %s, a session not listed", step, op, id); return }
			}
			if !missed_is_wait(e) { continue }
			_, asker, _ := missed_key_parts(app, e.key)
			asked[asker] = true
			if s := find_session(app, asker); s != nil && s.parent != "" { asked[s.parent] = true }
		}
		waiting := sessions_waiting(app)
		for &s in app.sessions {
			end_open := open_entry(app, .End, s.id) != nil
			if end_open != session_unseen(app, &s) {
				testing.expectf(t, false, "step %d (op %d): %s: an open end %v, unseen %v", step, op, s.id, end_open, session_unseen(app, &s))
				return
			}
			if (s.id in asked) != (s.id in waiting) {
				testing.expectf(t, false, "step %d (op %d): %s: an open wait %v, waits %v", step, op, s.id, s.id in asked, s.id in waiting)
				return
			}
		}
	}
}

// Opening a session acknowledges its end, and says so to the server (POST /view, the path that was already there); acknowledging
// an end in the view says it too. A wait is acknowledged by its answer alone.
@(test)
opening_a_session_acknowledges_its_end :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	listed(app, MISSED_LIST)
	bench_event(app, `{"type":"permission.asked","data":{"request":{"id":"p1","sessionID":"waits","action":"bash","resources":["git push"]}}}`)
	missed_sync(app)
	testing.expect(t, open_entry(app, .End, "ended") != nil, "an end nobody saw")
	testing.expect(t, open_entry(app, .End, "never") != nil)
	testing.expect(t, open_entry(app, .End, "seen") == nil, "seen")
	testing.expect(t, open_entry(app, .End, "sub") == nil, "a sub-agent's end is read through its parent")
	if e := open_entry(app, .Permission, "p1", "waits"); testing.expect(t, e != nil, "the wait") {
		testing.expect_value(t, e.text, "bash git push")
	}

	open_chat(app, "ended")
	r := bench_take(t, .Session_Viewed)
	testing.expect_value(t, r.path, "/api/session/ended/view")
	missed_sync(app)
	testing.expect(t, open_entry(app, .End, "ended") == nil, "opened: acknowledged")
	if e := notices.find(missed_log(app), missed_key(app, .End, "ended")); testing.expect(t, e != nil, "in the history") {
		testing.expect_value(t, e.state, notices.State.Acknowledged)
	}

	testing.expect(t, missed_acknowledge(app, missed_key(app, .End, "never")))
	r = bench_take(t, .Session_Viewed)
	testing.expect_value(t, r.path, "/api/session/never/view")
	missed_sync(app)
	testing.expect(t, open_entry(app, .End, "never") == nil)
	testing.expect(t, !session_unseen(app, find_session(app, "never")), "seen here too")

	testing.expect(t, !missed_acknowledge(app, missed_key(app, .Permission, "p1", "waits")), "a wait waits for its answer")
	testing.expect_value(t, missed_acknowledge_all(app), 0)
	testing.expect(t, open_entry(app, .Permission, "p1", "waits") != nil)
	bench_event(app, `{"type":"permission.replied","data":{"id":"p1"}}`)
	missed_sync(app)
	testing.expect(t, open_entry(app, .Permission, "p1", "waits") == nil, "answered")
}

// A new end of a session whose end is open counts on the same entry; the view's count of what is New goes to 0 when the view
// opens, and the entries stay.
@(test)
the_count_is_what_was_not_shown_yet :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	listed(app, MISSED_LIST)
	missed_sync(app)
	missed_rows_refresh(app)
	testing.expect_value(t, app.missed.new_here, 2)
	bench_event(app, `{"type":"session.execution.started","data":{"sessionID":"ended"}}`)
	bench_event(app, `{"type":"session.execution.succeeded","data":{"sessionID":"ended"}}`)
	missed_sync(app)
	if e := open_entry(app, .End, "ended"); testing.expect(t, e != nil) {
		testing.expect_value(t, e.count, 2)
		testing.expect_value(t, missed_words(e), "Done ×2")
	}
	missed_rows_refresh(app)
	testing.expect_value(t, app.missed.new_here, 2)
	missed_toggle(app)
	testing.expect(t, app.cx.open[.Notices])
	missed_rows_refresh(app)
	testing.expect_value(t, app.missed.new_here, 0)
	testing.expect(t, open_entry(app, .End, "ended") != nil && open_entry(app, .End, "never") != nil, "seen, not acknowledged")
	headers, entries := 0, 0
	for r in app.missed.rows { if r.entry == nil { headers += 1 } else { entries += 1 } }
	testing.expect_value(t, headers, 2)
	testing.expect_value(t, entries, 2)
}

// A command of the background that ends, a sub-agent that ends, a run a schedule started: each has its entry, under the session
// at the top. Opening that session acknowledges them.
@(test)
a_command_a_sub_agent_and_a_scheduled_run_that_end_are_missed :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	listed(app, MISSED_LIST)
	open_chat(app, "seen")
	bench_clear(app)
	// a command of the session, sent to the background, that ends
	running, _ := json.parse_string(`{"data":[{"id":"sh_1","command":"cargo build --release","status":"running","metadata":{"sessionID":"seen"}}]}`, allocator = context.temp_allocator)
	activity_shells_load(app, running, app.activity.dir)
	jobs, _ := json.parse_string(`{"data":[{"shellID":"sh_1"}]}`, allocator = context.temp_allocator)
	activity_jobs_load(app, jobs, "seen")
	none, _ := json.parse_string(`{"data":[]}`, allocator = context.temp_allocator)
	activity_shells_load(app, none, app.activity.dir)
	exited, _ := json.parse_string(`{"data":{"id":"sh_1","status":"exited","exit":2}}`, allocator = context.temp_allocator)
	activity_shell_load(app, exited, "sh_1")
	if e := open_entry(app, .Shell, "sh_1"); testing.expect(t, e != nil, "the command's end") {
		testing.expect_value(t, e.group, missed_group(app, "seen"))
		testing.expect_value(t, e.text, "cargo build --release")
		testing.expect_value(t, missed_words(e), "Command failed")
	}
	// a sub-agent
	bench_event(app, `{"type":"session.execution.started","data":{"sessionID":"sub"}}`)
	bench_event(app, `{"type":"session.execution.failed","data":{"sessionID":"sub"}}`)
	if e := open_entry(app, .Sub, "sub"); testing.expect(t, e != nil, "the sub-agent's end") {
		testing.expect_value(t, e.group, missed_group(app, "seen"))
		testing.expect_value(t, missed_words(e), "Sub-agent failed")
	}
	// a schedule's prompt, then the run it started
	bench_event(app, `{"type":"session.inbox.enqueued","data":{"sessionID":"waits","inboxID":"msg_sch_1_3","item":{"type":"user","delivery":"steer","payload":{"text":"Check the nightly build\nand say what broke"}}}}`)
	bench_event(app, `{"type":"session.execution.started","data":{"sessionID":"waits"}}`)
	bench_event(app, `{"type":"session.execution.succeeded","data":{"sessionID":"waits"}}`)
	if e := open_entry(app, .Scheduled, "msg_sch_1_3"); testing.expect(t, e != nil, "the scheduled run") {
		testing.expect_value(t, e.group, missed_group(app, "waits"))
		testing.expect_value(t, e.text, "Check the nightly build")
	}
	testing.expect(t, open_entry(app, .End, "waits") != nil, "and its end")
	// the visit
	chat_home(app)
	open_chat(app, "seen")
	testing.expect(t, open_entry(app, .Shell, "sh_1") == nil, "visited")
	testing.expect(t, open_entry(app, .Sub, "sub") == nil, "visited")
	testing.expect(t, open_entry(app, .Scheduled, "msg_sch_1_3") != nil, "another session's")
}

// An entry whose notification of the system is shown closes it when it is acknowledged, a wait when it is answered; a second
// notification of an open entry replaces the first; a closed one is no longer the entry's.
@(test)
acknowledging_closes_the_notification :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	listed(app, MISSED_LIST)
	missed_sync(app)
	closed := make([dynamic]platform.Notification_Id, context.temp_allocator)
	log := missed_log(app)
	log.close_user = &closed
	log.close_system = proc(user: rawptr, id: platform.Notification_Id) { append((^[dynamic]platform.Notification_Id)(user), id) }
	ended := missed_key(app, .End, "ended")
	missed_system_set(app, ended, 41)
	testing.expect_value(t, missed_system_of(app, ended), 41)
	missed_system_set(app, ended, 42)   // (a second one of the same entry: the first goes)
	testing.expect_value(t, len(closed), 1)
	missed_acknowledge(app, ended)
	testing.expect_value(t, len(closed), 2)
	if len(closed) == 2 { testing.expect_value(t, closed[1], 42) }

	bench_event(app, `{"type":"form.created","data":{"form":{"id":"f1","sessionID":"waits","title":"Which branch?","fields":[]}}}`)
	missed_sync(app)
	question := missed_key(app, .Question, "f1", "waits")
	missed_system_set(app, question, 43)
	bench_event(app, `{"type":"form.replied","data":{"id":"f1"}}`)
	missed_sync(app)
	testing.expect_value(t, len(closed), 3)
	if len(closed) == 3 { testing.expect_value(t, closed[2], 43) }

	never := missed_key(app, .End, "never")
	missed_system_set(app, never, 44)
	missed_notification_closed(app, 44)
	testing.expect_value(t, missed_system_of(app, never), 0)
	missed_acknowledge(app, never)
	testing.expect_value(t, len(closed), 3)   // (the system closed it already)
	missed_system_set(app, never, 45)          // (shown after its entry was acknowledged: it goes at once)
	testing.expect_value(t, len(closed), 4)
}

// Two servers never mix: the entries of one are not shown, counted or acknowledged under the other.
@(test)
what_was_missed_is_each_servers :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	append(&app.servers, Server{name = "Home"}, Server{name = "Work"})
	app.server = 0
	listed(app, MISSED_LIST)
	missed_sync(app)
	missed_rows_refresh(app)
	testing.expect_value(t, app.missed.new_here, 2)
	app.server = 1
	missed_rows_refresh(app)
	testing.expect_value(t, app.missed.new_here, 0)
	testing.expect_value(t, len(app.missed.rows), 0)
	testing.expect_value(t, missed_acknowledge_all(app), 0)
	app.server = 0
	testing.expect(t, open_entry(app, .End, "ended") != nil, "the other server's stays")
	delete(app.servers)
	app.servers = nil
}

@(test)
an_excerpt_is_one_line_of_whole_characters :: proc(t: ^testing.T) {
	testing.expect_value(t, missed_excerpt("  first line  \nsecond"), "first line")
	long := strings.repeat("é", 150, context.temp_allocator)   // (300 bytes)
	cut := missed_excerpt(long)
	testing.expect(t, len(cut) <= MISSED_EXCERPT && len(cut) == 200, "200 bytes: whole characters")
}
