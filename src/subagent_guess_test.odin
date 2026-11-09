package occ

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
