// Find in a conversation (src/md/features/find.md): the toolkit's find (gt:ui find_bar), one per view, over the
// conversation's scroll box. ocn gives it the messages as rows: each one's whole text (message_text, every fold open), a
// stamp that moves when that text does, the way to open what holds a match (message_reveal), and the scopes All and Prompts.
package ocn

import "core:hash"
import "core:strings"
import "gt:ui"
import i18n "gt:i18n"

// The bar over the conversation's scroll box `sb` (the last build's), built while the find is open over it. `scrolled`: the
// find moved the view since the last build (a move of the reader's: chat_scroll_place).
conversation_find :: proc(app: ^App, pane: ^Chat_Pane, sb: ^ui.Box) -> (scrolled: bool) {
	c := &pane.conversation
	c.find_over = false
	if sb == nil { return }
	st := ui.current_state()
	// (the home page has no conversation to search)
	if pane.chat.id == "" {
		if ui.find_is_open(sb.key) { ui.find_close(st) }
		return
	}
	if c.find_waits != "" {
		ui.find_open(st, sb.key, c.find_waits)
		find_unwait(pane)
	}
	c.find_over = ui.find_is_open(sb.key)
	scopes := make([]ui.Find_Scope, 2, context.temp_allocator)
	scopes[0] = {name = i18n.tr("All")}
	scopes[1] = {name = i18n.tr("Prompts"), keep = message_is_prompt}
	return ui.find_bar(sb, {placeholder = i18n.tr("Find in the conversation"), scopes = scopes}).scrolled
}

// Ctrl+F on pane `pane`, or --find's `text`: the find opens over its conversation, in the pane's window, at once. A pane that
// shows no conversation yet (a start, before the sessions are read; the home page) has no view to open it over: --find's text
// waits for its first conversation (the home page would close it).
find_show :: proc(app: ^App, pane: ^Chat_Pane, text := "") {
	c := &pane.conversation
	if pane.chat.id != "" && c.scroll_key != 0 {
		ui.find_open(pane_window(app, pane), c.scroll_key, text)
		return
	}
	if text == "" { return }
	delete(c.find_waits)
	c.find_waits = strings.clone(text)
}

// The pane goes: the find over its view closes, in its window. (Its last build says whether it is over it: the toolkit
// answers that only for the window being built.)
find_pane_closed :: proc(app: ^App, pane: ^Chat_Pane) {
	find_unwait(pane)
	c := &pane.conversation
	if c.find_over { ui.find_close(pane_window(app, pane)) }
	c.find_over = false
}

// The server left: --find's text is not opened over the next one's conversation. (One open goes with the home page each
// pane goes to: conversation_find.)
find_forget :: proc(app: ^App) { for &pane in app.panes { find_unwait(&pane) } }

@(private = "file")
find_unwait :: proc(pane: ^Chat_Pane) {
	c := &pane.conversation
	delete(c.find_waits)
	c.find_waits = ""
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
