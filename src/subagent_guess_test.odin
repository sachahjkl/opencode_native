package ocn

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:testing"
import tk_json "gt:json"
import "gt:timefmt"

// A running sub-agent's card finds its session before the server names it (it does when the call ends): the child with the call's
// description as its title, made after the call started, that no other call names.
@(test)
a_running_card_finds_its_session :: proc(t: ^testing.T) {
	c: Chat
	chat_reset(&c)
	append(&c.children,
		Session_Info{id = "ses_old", title = "Research formats and loaders", agent = "general", created = 1_000},
		Session_Info{id = "ses_b", title = "Research interface type systems", agent = "general", created = 100_200},
		Session_Info{id = "ses_a", title = "Research formats and loaders", agent = "general", created = 100_100},
		Session_Info{id = "ses_a2", title = "Research formats and loaders", agent = "general", created = 200_000})
	a := Part{kind = .Tool, tool_name = "subagent", sub_agent = "general", sub_desc = "Research formats and loaders", started_ms = 100_000}
	b := Part{kind = .Tool, tool_name = "subagent", sub_agent = "general", sub_desc = "Research interface type systems", started_ms = 100_050}
	testing.expect_value(t, sub_session_guess(&c, &a), "ses_a")   // (not the one made long before, nor the later one)
	testing.expect_value(t, sub_session_guess(&c, &b), "ses_b")
	// another call names ses_a already: this one is the next made after it started
	parts := make([dynamic]Part, context.temp_allocator)
	append(&parts, Part{kind = .Tool, tool_name = "subagent", sub_session = "ses_a"})
	append(&c.messages, Message{id = "m1", kind = .Assistant, parts = parts})
	subs_changed(&c)   // (as a page read does)
	testing.expect_value(t, sub_session_guess(&c, &a), "ses_a2")
	other := Part{kind = .Tool, tool_name = "subagent", sub_agent = "build", sub_desc = "Research interface type systems", started_ms = 100_050}
	testing.expect_value(t, sub_session_guess(&c, &other), "")   // (another agent's)
	testing.expect_value(t, sub_session_guess(&c, &Part{kind = .Tool, tool_name = "subagent"}), "")
	delete(c.children)
	delete(c.messages)
}

// What the conversation says of its sub-agents and its figures are read once per change of it: a call that ends names its session and
// hands back its result at once, a page brings the result message; a build that changes nothing reads nothing again.
@(test)
a_sub_agents_end_shows_and_nothing_is_read_again_meanwhile :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	pane := main_pane(app)
	open_chat(app, "s")
	bench_clear(app)
	c := &pane.chat
	bench_event(app, `{"type":"session.tool.called","data":{"sessionID":"s","assistantMessageID":"a1","id":"t1","input":{"agent":"general","description":"Look","prompt":"go"}}}`)
	testing.expect(t, !is_child(c, "child1"))
	p := &c.messages[0].parts[0]
	testing.expect_value(t, sub_view(app, pane, "", p).state, Sub_State.Running)
	read := c.subs.computed
	stats := local_stats(app)
	testing.expect_value(t, stats.calls, 1)
	figured := app.stats.local.computed
	for _ in 0 ..< 3 {
		testing.expect(t, sub_result(c, "child1") == nil && !is_child(c, "child1"))
		_ = local_stats(app)
	}
	testing.expect_value(t, c.subs.computed, read)
	testing.expect_value(t, app.stats.local.computed, figured)

	bench_event(app, `{"type":"session.tool.success","data":{"sessionID":"s","assistantMessageID":"a1","id":"t1","content":[{"type":"text","text":"found it"}],"metadata":{"sessionID":"child1"}}}`)
	testing.expect(t, is_child(c, "child1"), "the call names it now")
	p = &c.messages[0].parts[0]
	v := sub_view(app, pane, p.sub_session, p)
	testing.expect_value(t, v.state, Sub_State.Done)
	testing.expect_value(t, v.result, "found it")
	bench_event(app, `{"type":"session.step.ended","data":{"sessionID":"s","assistantMessageID":"a1","finish":"stop","tokens":{"output":7}}}`)
	testing.expect_value(t, local_stats(app).out_tokens, 7)

	page := `{"data":[{"id":"m2","type":"synthetic","text":"<subagent sessionID=\"child1\">all done</subagent>","description":"Look","metadata":{"source":"subagent","childID":"child1","state":"failed","agent":"general"},"time":{"created":5}}]}`
	v2, _ := json.parse_string(page, parse_integers = true, allocator = context.temp_allocator)
	chat_load(app, pane, v2, false)
	m := sub_result(c, "child1")
	testing.expect(t, m != nil && m.text == "all done", "the result message of the page")
	testing.expect_value(t, sub_view(app, pane, "child1").state, Sub_State.Failed)
	testing.expect_value(t, local_stats(app).msgs, len(c.messages))
	read, figured = c.subs.computed, app.stats.local.computed
	_ = sub_result(c, "child1")
	_ = local_stats(app)
	testing.expect_value(t, c.subs.computed, read)
	testing.expect_value(t, app.stats.local.computed, figured)
}

// A tool call's time: tenths while short, minutes later; while it runs, up to now; nothing when its times are not known.
@(test)
a_tool_calls_time :: proc(t: ^testing.T) {
	p := Part{started_ms = 1_000, ended_ms = 1_420}
	testing.expect_value(t, tool_elapsed(&p, false, 99_000), "0.4s")
	p.ended_ms = 1_000 + 252_000
	testing.expect_value(t, tool_elapsed(&p, false, 99_000), "4m 12s")
	running := Part{started_ms = 1_000}
	testing.expect_value(t, tool_elapsed(&running, true, 13_000), "12s")
	testing.expect_value(t, tool_elapsed(&running, true, 900), "<0.1s")   // (the server's clock ahead)
	unknown := Part{}
	testing.expect_value(t, tool_elapsed(&unknown, true, 13_000), "")
}

// When a tool call ran, to the second; another day with its date.
@(test)
a_tool_call_says_when :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	day := f64(MS_PER_S * SECS_PER_DAY)
	start := day * 20_000 + 3_600_000 + 61_000 - f64(timefmt.local_offset_minutes()) * 60 * MS_PER_S   // (01:01:01, local)
	p := Part{started_ms = start, ended_ms = start + 12_000}
	testing.expect_value(t, tool_when(&p, false, start + 60_000, true), "Started today 01:01:01, ended today 01:01:13")
	testing.expect_value(t, tool_when(&p, true, start + 1_000, true), "Started today 01:01:01, running")
	when_ := tool_when(&p, false, start + 2 * day, true)
	testing.expectf(t, strings.contains(when_, ", 01:01:01") && !strings.contains(when_, "today"), "another day, its date: %s", when_)
}

// One place says how a sub-agent stands: a foreground call (an older session's) that returned while its session is still busy
// is finishing (not running again); a launch that returned runs, whether its session is busy yet or not.
@(test)
a_returned_call_whose_session_is_busy_is_finishing :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	pane := main_pane(app)
	open_chat(app, "s")
	bench_clear(app)
	p := Part{kind = .Tool, tool_name = "subagent", status = .Done, sub_session = "child1", sub_agent = "general", started_ms = 1_000, ended_ms = 9_000}
	testing.expect_value(t, sub_view(app, pane, "child1", &p).state, Sub_State.Done)
	app.busy["child1"] = true
	v := sub_view(app, pane, "child1", &p)
	testing.expect_value(t, v.state, Sub_State.Finishing)
	testing.expect(t, sub_live(v.state) && v.ended == 0, "finishing goes on: a lamp, its time still counted")
	testing.expect_value(t, sub_state_label(v.state), "finishing")
	bg := Part{kind = .Tool, tool_name = "subagent", status = .Done, sub_session = "child2", sub_launched = true, output = "The subagent is working in the background"}
	v2 := sub_view(app, pane, "child2", &bg)
	testing.expect_value(t, v2.state, Sub_State.Running)
	testing.expect_value(t, v2.result, "")   // (the server's word to the model is no result)
	app.busy["child2"] = true
	testing.expect_value(t, sub_view(app, pane, "child2", &bg).state, Sub_State.Running)
	delete_key(&app.busy, "child1")
	delete_key(&app.busy, "child2")
}

// Events of a sub-agent launched in the background (opencode 2.3.0): its call, which returns at once, and its session. `child`
// names its session, `call` its call, `msg` the parent's message the call is in.
@(private = "file")
bg_launch :: proc(app: ^App, msg, call, child, desc: string, follow_up := false) {
	resume := follow_up ? fmt.tprintf(`,"sessionID":"%s"`, child) : ""
	bench_event(app, fmt.tprintf(`{{"type":"session.tool.called","created":10,"data":{{"sessionID":"s","assistantMessageID":"%s","id":"%s","input":{{"agent":"general","description":"%s","prompt":"go"%s}}}}}}`, msg, call, desc, resume))
	bench_event(app, fmt.tprintf(`{{"type":"session.tool.progress","data":{{"sessionID":"s","assistantMessageID":"%s","id":"%s","metadata":{{"sessionID":"%s","status":"running"}}}}}}`, msg, call, child))
	bench_event(app, fmt.tprintf(`{{"type":"session.tool.success","created":11,"data":{{"sessionID":"s","assistantMessageID":"%s","id":"%s","content":[{{"type":"text","text":"The subagent is working in the background (sessionID: %s)."}}],"metadata":{{"sessionID":"%s","status":"running"}}}}}}`, msg, call, child, child))
}

// A child's report, as the server admits it into the parent's inbox (SubagentCompletion.deliver): `state` is the tag's, the
// metadata keeps the period's status.
@(private = "file")
bg_report :: proc(app: ^App, id, child, state, body: string) {
	text := fmt.tprintf("<subagent sessionID=\"%s\" state=\"%s\" description=\"Look\">\n%s\n</subagent>", child, state, body)
	bench_event(app, fmt.tprintf(`{{"type":"session.inbox.enqueued","created":20,"data":{{"sessionID":"s","inboxID":"%s","item":{{"type":"synthetic","delivery":"steer","payload":{{"text":%s,"description":"Look","metadata":{{"source":"subagent","childID":"%s","agent":"general","state":"completed"}}}}}}}}}}`, id, tk_json.quote(text), child))
}

@(private = "file")
bg_card :: proc(app: ^App, call: string) -> ^Part {
	pane := main_pane(app)
	for &m in pane.chat.messages { for &p in m.parts { if p.tool_id == call { return &p } } }
	return nil
}

// A call that returns at once does not end its child: the card and the tray's count say it runs, before its session is
// busy, while it is, and after it went idle until its report came. Before, the call's end read as the child's: "done", with
// the server's word to the model as its result.
@(test)
a_launch_that_returns_at_once_keeps_its_child_running :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	pane := main_pane(app)
	open_chat(app, "s")
	bench_clear(app)
	bg_launch(app, "a1", "t1", "child1", "Look")
	p := bg_card(app, "t1")
	if !testing.expect(t, p != nil && p.status == .Done && p.sub_launched, "the call returned, a launch") { return }
	v := sub_view(app, pane, p.sub_session, p)
	testing.expect_value(t, v.state, Sub_State.Running)
	testing.expect_value(t, v.result, "")
	agents, _ := activity_counts(app)
	testing.expect_value(t, agents, 1)
	bench_event(app, `{"type":"session.execution.started","data":{"sessionID":"child1"}}`)
	testing.expect_value(t, sub_view(app, pane, "child1", bg_card(app, "t1")).state, Sub_State.Running)
	agents, _ = activity_counts(app)
	testing.expect_value(t, agents, 1)
	// idle, its report not come yet: it is not over
	bench_event(app, `{"type":"session.execution.succeeded","data":{"sessionID":"child1"}}`)
	testing.expect_value(t, sub_view(app, pane, "child1", bg_card(app, "t1")).state, Sub_State.Running)
	agents, _ = activity_counts(app)
	testing.expect_value(t, agents, 1)
	// what runs is kept: asked again with nothing changed, it is not made again
	made := pane.chat.running.computed
	for _ in 0 ..< 3 { _, _ = activity_counts(app); _ = active_children(app, pane) }
	testing.expect_value(t, pane.chat.running.computed, made)
}

// The child's report comes into the conversation as it is admitted, and it is the child's end: its card shows what it said and
// is done, the tray counts it no more. Its delivery adds nothing again.
@(test)
a_childs_report_shows_and_ends_it :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	pane := main_pane(app)
	open_chat(app, "s")
	bench_clear(app)
	c := &pane.chat
	bg_launch(app, "a1", "t1", "child1", "Look")
	bg_report(app, "msg_r1", "child1", "completed", "Found three loaders.")
	m := sub_result(c, "child1")
	if !testing.expect(t, m != nil, "the report is in the conversation") { return }
	testing.expect_value(t, m.text, "Found three loaders.")
	testing.expect(t, !m.sub_running)
	v := sub_view(app, pane, "child1", bg_card(app, "t1"))
	testing.expect_value(t, v.state, Sub_State.Done)
	testing.expect_value(t, v.result, "Found three loaders.")
	agents, _ := activity_counts(app)
	testing.expect_value(t, agents, 0)
	n := len(c.messages)
	bench_event(app, `{"type":"session.inbox.delivered","created":21,"data":{"sessionID":"s","inboxID":"msg_r1"}}`)
	testing.expect_value(t, len(c.messages), n)
}

// A report that says the child's own work still runs keeps it running; the final report ends it. A row of that first report
// has no lamp: it is a past event.
@(test)
a_report_whose_work_still_runs_keeps_its_child_running :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	pane := main_pane(app)
	open_chat(app, "s")
	bench_clear(app)
	c := &pane.chat
	bg_launch(app, "a1", "t1", "child1", "Look")
	bg_report(app, "msg_r1", "child1", "running", "Half of it.\n\nBackground work still running:\n- shell (sh_1): make test")
	m := sub_result(c, "child1")
	if !testing.expect(t, m != nil && m.sub_running, "a report that says its work runs on") { return }
	testing.expect_value(t, m.sub_state, "completed")   // (the metadata keeps the period's status: only the tag says it runs)
	v := sub_view(app, pane, "child1", bg_card(app, "t1"))
	testing.expect_value(t, v.state, Sub_State.Running)
	testing.expect(t, v.work_runs && v.ended == 0)
	testing.expect(t, strings.has_prefix(v.result, "Half of it."), "what it said so far is shown")
	agents, _ := activity_counts(app)
	testing.expect_value(t, agents, 1)
	bg_report(app, "msg_r2", "child1", "completed", "All of it.")
	v = sub_view(app, pane, "child1", bg_card(app, "t1"))
	testing.expect_value(t, v.state, Sub_State.Done)
	testing.expect(t, !v.work_runs)
	testing.expect_value(t, v.result, "All of it.")
	agents, _ = activity_counts(app)
	testing.expect_value(t, agents, 0)
	reports := 0
	for &x in c.messages { if x.kind == .Synthetic && x.sub_child == "child1" { reports += 1 } }
	testing.expect_value(t, reports, 2)   // (each report is its own row)
}

// Two children at once, each followed on its own: one's report ends that one only. A follow-up call sets a child to work again
// after its report: it runs until the next one.
@(test)
two_children_are_followed_each_on_its_own :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	pane := main_pane(app)
	open_chat(app, "s")
	bench_clear(app)
	bg_launch(app, "a1", "t1", "child1", "Look")
	bg_launch(app, "a1", "t2", "child2", "Read")
	bench_event(app, `{"type":"session.execution.started","data":{"sessionID":"child1"}}`)
	bench_event(app, `{"type":"session.execution.started","data":{"sessionID":"child2"}}`)
	agents, _ := activity_counts(app)
	testing.expect_value(t, agents, 2)
	bench_event(app, `{"type":"session.execution.succeeded","data":{"sessionID":"child2"}}`)
	bg_report(app, "msg_r2", "child2", "completed", "Read it.")
	testing.expect_value(t, sub_view(app, pane, "child1", bg_card(app, "t1")).state, Sub_State.Running)
	testing.expect_value(t, sub_view(app, pane, "child2", bg_card(app, "t2")).state, Sub_State.Done)
	agents, _ = activity_counts(app)
	testing.expect_value(t, agents, 1)
	bench_event(app, `{"type":"session.execution.succeeded","data":{"sessionID":"child1"}}`)
	bg_report(app, "msg_r1", "child1", "completed", "Looked.")
	testing.expect_value(t, sub_view(app, pane, "child1", bg_card(app, "t1")).state, Sub_State.Done)
	agents, _ = activity_counts(app)
	testing.expect_value(t, agents, 0)
	// a follow-up to child2, in a later step
	bg_launch(app, "a2", "t3", "child2", "Read", follow_up = true)
	testing.expect_value(t, sub_view(app, pane, "child2", bg_card(app, "t3")).state, Sub_State.Running)
	testing.expect_value(t, sub_view(app, pane, "child1", bg_card(app, "t1")).state, Sub_State.Done)
	agents, _ = activity_counts(app)
	testing.expect_value(t, agents, 1)
	bg_report(app, "msg_r3", "child2", "completed", "Read it again.")
	v := sub_view(app, pane, "child2", bg_card(app, "t3"))
	testing.expect_value(t, v.state, Sub_State.Done)
	testing.expect_value(t, v.result, "Read it again.")
}
