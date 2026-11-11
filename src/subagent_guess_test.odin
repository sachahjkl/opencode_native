package ocn

import "base:runtime"
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
	testing.expect_value(t, sub_session_guess(&c, &a), "ses_a2")
	other := Part{kind = .Tool, tool_name = "subagent", sub_agent = "build", sub_desc = "Research interface type systems", started_ms = 100_050}
	testing.expect_value(t, sub_session_guess(&c, &other), "")   // (another agent's)
	testing.expect_value(t, sub_session_guess(&c, &Part{kind = .Tool, tool_name = "subagent"}), "")
	delete(c.children)
	delete(c.messages)
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
	app := new(App)
	defer free(app)
	the_app = app
	app.prefs.clock24 = true
	day := f64(MS_PER_S * SECS_PER_DAY)
	start := day * 20_000 + 3_600_000 + 61_000 - f64(local_offset_minutes()) * 60 * MS_PER_S   // (01:01:01, local)
	p := Part{started_ms = start, ended_ms = start + 12_000}
	testing.expect_value(t, tool_when(&p, false, start + 60_000), "Started 01:01:01, ended 01:01:13")
	testing.expect_value(t, tool_when(&p, true, start + 1_000), "Started 01:01:01, running")
	when_ := tool_when(&p, false, start + 2 * day)
	testing.expectf(t, strings.contains(when_, ", 01:01:01") && when_ != "Started 01:01:01, ended 01:01:13", "another day, its date: %s", when_)
}
