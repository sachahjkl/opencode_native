// Find in a conversation (src/md/features/find.md): the toolkit's find (gt:ui find_bar), one per view, over the
// conversation's scroll box. ocn gives it the messages as rows: each one's whole text (message_text, every fold open), a
// stamp that moves when that text does, the way to open what holds a match (message_reveal), and the scopes All and Prompts.
package ocn

import "core:hash"
import "core:strings"
import "gt:ui"
import i18n "gt:i18n"

// The bar over the conversation's scroll box `sb` (this build's or the last one's), built while the find is open over it.
// Ctrl+F and --find are asked outside the build of the pane's window (a command runs after the frame): they open it here.
conversation_find :: proc(app: ^App, pane: ^Chat_Pane, sb: ^ui.Box) {
	if sb == nil { return }
	c := &pane.conversation
	// (the home page has no conversation to search; --find given at a start waits for the session it opens)
	if pane.chat.id == "" {
		if ui.find_is_open(sb.key) { ui.find_close() }
		return
	}
	if c.find_due {
		ui.find_open(sb.key, c.find_text)
		find_unask(pane)
	}
	scopes := make([]ui.Find_Scope, 2, context.temp_allocator)
	scopes[0] = {name = i18n.tr("All")}
	scopes[1] = {name = i18n.tr("Prompts"), keep = message_is_prompt}
	ui.find_bar(sb, {placeholder = i18n.tr("Find in the conversation"), scopes = scopes})
}

// Ctrl+F on pane `pane`, or --find's `text`: the find opens over its conversation at its next build.
find_ask :: proc(app: ^App, pane: ^Chat_Pane, text := "") {
	c := &pane.conversation
	c.find_due = true
	delete(c.find_text)
	c.find_text = strings.clone(text)
}

// The pane goes: the find over its view closes when it is open in the window being built (a pane in a window of its own goes
// with that window's State).
find_pane_closed :: proc(app: ^App, pane: ^Chat_Pane) {
	find_unask(pane)
	c := &pane.conversation
	if ui.current_state() != nil && c.scroll_key != 0 && ui.find_is_open(c.scroll_key) { ui.find_close() }
}

// The server left: a find asked for is not opened over the next one's conversation. (One open goes with the home page each
// pane goes to: conversation_find.)
find_forget :: proc(app: ^App) { for &pane in app.panes { find_unask(&pane) } }

@(private = "file")
find_unask :: proc(pane: ^Chat_Pane) {
	c := &pane.conversation
	c.find_due = false
	delete(c.find_text)
	c.find_text = ""
}

// The scope "Prompts": the reader's own messages (it replaced Jump to message).
message_is_prompt :: proc(user: rawptr, i: int) -> bool {
	c := &(^Chat_Pane)(user).chat
	return i >= 0 && i < len(c.messages) && c.messages[i].kind == .User
}

// Message `i`'s stamp (ui.Text_Rows.stamp): it moves whenever its whole text can have changed. A sum of what its text is made
// of (lengths, states, the stream's clock), cheap enough to be asked of thousands of messages a frame; what a sub-agent's card
// reads lives elsewhere in the conversation (its session, its result), so a message with one also takes the conversation's count
// of changes. The preferences that shape the text (the reasoning hidden, the lines of a tool) go into every stamp.
message_stamp :: proc(user: rawptr, i: int) -> u64 {
	pane := (^Chat_Pane)(user)
	c := &pane.chat
	if i < 0 || i >= len(c.messages) { return 0 }
	app := the_app
	m := &c.messages[i]
	h := u64(m.touched) * HASH_MIX_B
	mix :: proc(h: ^u64, v: int) { h^ = (h^ ~ u64(v)) * 0x100000001b3 }
	mix(&h, int(m.kind))
	mix(&h, len(m.text))
	mix(&h, len(m.parts))
	mix(&h, len(m.jobs))
	mix(&h, len(m.mcp_data))
	mix(&h, app.prefs.tool_lines)
	mix(&h, app.prefs.reasoning == "hidden" ? 1 : 0)
	elsewhere := m.sub_child != ""
	for &p in m.parts {
		mix(&h, len(p.text))
		mix(&h, len(p.output))
		mix(&h, len(p.input))
		mix(&h, len(p.patch))
		mix(&h, len(p.stream.text))
		mix(&h, int(p.status))
		if p.kind == .Tool && !plain_tool(&p) { elsewhere = true }
	}
	if elsewhere {
		mix(&h, int(c.changes))
		mix(&h, int(c.children_ver))
	}
	return h
}

// The rows' version (ui.Text_Rows.version): another conversation, messages come or go, or any of them changed. A change makes
// the find go over the rows' stamps again (a few thousand a frame), reading only the texts whose stamp moved.
messages_version :: proc(c: ^Chat) -> u64 {
	return c.gen * HASH_MIX_B ~ u64(len(c.messages)) << 40 ~ c.changes
}

// The find's current match is at byte `offset` of message `i`'s whole text, in a part that is folded (ui.Text_Rows.reveal): the
// parts that hold it open, as a click on their headers would open them (a Mermaid diagram shows its text).
message_reveal :: proc(user: rawptr, i: int, offset: int) {
	pane := (^Chat_Pane)(user)
	if i < 0 || i >= len(pane.chat.messages) { return }
	t := Copy_Text{b = strings.builder_make(context.temp_allocator), whole = true, reveal = offset}
	message_write(&t, pane, i)
	app := the_app
	for key in t.opens { app.expanded[hash.fnv64a(transmute([]u8)key)] = true }
}
