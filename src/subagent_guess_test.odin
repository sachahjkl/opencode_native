package ocn

import "base:runtime"
import "core:encoding/json"
import "core:strings"
import "core:testing"

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
	open_chat(app, "s")
	bench_clear(app)
	c := &app.chat
	bench_event(app, `{"type":"session.tool.called","data":{"sessionID":"s","assistantMessageID":"a1","id":"t1","input":{"agent":"general","description":"Look","prompt":"go"}}}`)
	testing.expect(t, !is_child(c, "child1"))
	p := &c.messages[0].parts[0]
	testing.expect_value(t, sub_view(app, "", p).state, Sub_State.Running)
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
	v := sub_view(app, p.sub_session, p)
	testing.expect_value(t, v.state, Sub_State.Done)
	testing.expect_value(t, v.result, "found it")
	bench_event(app, `{"type":"session.step.ended","data":{"sessionID":"s","assistantMessageID":"a1","finish":"stop","tokens":{"output":7}}}`)
	testing.expect_value(t, local_stats(app).out_tokens, 7)

	page := `{"data":[{"id":"m2","type":"synthetic","text":"<subagent sessionID=\"child1\">all done</subagent>","description":"Look","metadata":{"source":"subagent","childID":"child1","state":"failed","agent":"general"},"time":{"created":5}}]}`
	v2, _ := json.parse_string(page, parse_integers = true, allocator = context.temp_allocator)
	chat_load(app, v2, false)
	m := sub_result(c, "child1")
	testing.expect(t, m != nil && m.text == "all done", "the result message of the page")
	testing.expect_value(t, sub_view(app, "child1").state, Sub_State.Failed)
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
	start := day * 20_000 + 3_600_000 + 61_000 - f64(local_offset_minutes()) * 60 * MS_PER_S   // (01:01:01, local)
	p := Part{started_ms = start, ended_ms = start + 12_000}
	testing.expect_value(t, tool_when(&p, false, start + 60_000, true), "Started 01:01:01, ended 01:01:13")
	testing.expect_value(t, tool_when(&p, true, start + 1_000, true), "Started 01:01:01, running")
	when_ := tool_when(&p, false, start + 2 * day, true)
	testing.expectf(t, strings.contains(when_, ", 01:01:01") && when_ != "Started 01:01:01, ended 01:01:13", "another day, its date: %s", when_)
}

// One place says how a sub-agent stands: a call that returned while its session is still busy is finishing (not running
// again); a background call that returned, nothing known yet of its end, is in background (not "launched").
@(test)
a_returned_call_whose_session_is_busy_is_finishing :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	open_chat(app, "s")
	bench_clear(app)
	p := Part{kind = .Tool, tool_name = "subagent", status = .Done, sub_session = "child1", sub_agent = "general", started_ms = 1_000, ended_ms = 9_000}
	testing.expect_value(t, sub_view(app, "child1", &p).state, Sub_State.Done)
	app.busy["child1"] = true
	v := sub_view(app, "child1", &p)
	testing.expect_value(t, v.state, Sub_State.Finishing)
	testing.expect(t, sub_live(v.state) && v.ended == 0, "finishing goes on: a lamp, its time still counted")
	testing.expect_value(t, sub_state_label(v.state), "finishing")
	bg := Part{kind = .Tool, tool_name = "subagent", status = .Done, sub_session = "child2", sub_background = true}
	testing.expect_value(t, sub_view(app, "child2", &bg).state, Sub_State.Background)
	testing.expect_value(t, sub_state_label(.Background), "in background")
	app.busy["child2"] = true
	testing.expect_value(t, sub_view(app, "child2", &bg).state, Sub_State.Running)   // (a background one at work runs: it did not return)
	delete_key(&app.busy, "child1")
	delete_key(&app.busy, "child2")
}
