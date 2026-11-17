// Find in the conversation (src/md/features/find.md): the toolkit's find over the conversation's view, the messages its rows.
package ocn

import "base:runtime"
import "core:fmt"
import "core:strings"
import "core:testing"
import "gt:ui"
import session "gt:testkit/session"
import "gt:testkit/unwatched"

// The current match is lit, and inside the conversation's view.
@(private)
find_current_in_view :: proc(s: ^session.Session) -> bool {
	chat := session.find(s, "chat")
	if chat == nil || ui.find_index() < 0 { return false }
	for m in ui.find_matches() {
		if m.index != ui.find_index() { continue }
		// (window coordinates)
		if m.rect.min.y >= chat.rect.min.y && m.rect.max.y <= chat.rect.max.y { return true }
	}
	return false
}

@(private = "file")
find_opened :: proc(s: ^session.Session) -> bool { return ui.find_is_open(session.get(s, "chat").key) }

@(private = "file")
find_counted :: proc(s: ^session.Session) -> bool { return !ui.find_pending() && ui.find_index() >= 0 }

// Ctrl+F finds a word in a folded tool call of a message far above the view, never built: it is counted from the message's
// text, and the find goes to it, builds the message, opens the call and lights the match in view.
@(test)
ctrl_f_finds_a_folded_output_far_away :: proc(t: ^testing.T) {
	unwatched.run(t, proc(t: ^testing.T) {
		context.allocator = runtime.heap_allocator()
		app, s := bench_app(t)
		c := &main_pane(app).chat
		m := find_message(c, "msg_5_a")
		if !testing.expect(t, m != nil && len(m.parts) > 1 && m.parts[1].kind == .Tool, "turn 5's first call") { return }
		p := &m.parts[1]
		testing.expect(t, !part_open(app, p.tool_id, app.prefs.expand_tools), "folded")
		p.output = strings.clone("src/far.odin: the quokka line\n", c.alloc)
		chat_changed(c)
		session.frames(s, 2)
		testing.expect(t, session.find(s, "msg_msg_5_a") == nil, "far above the view: not built")

		session.key(s, .F, {.Ctrl})
		session.wait_until(s, find_opened, "the find open")
		session.type_text(s, "quokka")
		session.wait_until(s, find_counted, "counted")
		testing.expect_value(t, ui.find_count(), 1)
		session.wait_until(s, find_current_in_view, "the match lit in view")
		testing.expect(t, session.find(s, "msg_msg_5_a") != nil, "its message built")
		testing.expect(t, part_open(app, p.tool_id), "its call opened")
		testing.expect(t, session.find_text(s, "1/1") != nil, "the count says where it is")
		// (one match: F3 stays on it)
		session.key(s, .F3)
		session.wait_until(s, find_current_in_view, "still lit in view")
		testing.expect_value(t, ui.find_index(), 0)
	})
}

// The scope "Prompts" searches the reader's prompts alone (it replaced Jump to message): the count is theirs, a step goes to
// a prompt, and a few words of the first prompt, far above the view, take the view there.
@(test)
the_prompts_scope_counts_only_prompts :: proc(t: ^testing.T) {
	unwatched.run(t, proc(t: ^testing.T) {
		context.allocator = runtime.heap_allocator()
		app, s := bench_app(t)
		session.key(s, .F, {.Ctrl})
		session.wait_until(s, find_opened, "the find open")
		session.type_text(s, BENCH_FIND)
		session.wait_until(s, find_counted, "counted")
		testing.expect_value(t, ui.find_count(), 3 * BENCH_TURNS)   // (a prompt, a paragraph, a table's cell a turn)
		bar := session.get(s, fmt.tprintf("find_bar_%x", u64(session.get(s, "chat").key)))
		session.click_at(s, session.center(session.get(s, "seg1", within = bar)))
		session.wait_until(s, proc(s: ^session.Session) -> bool { return find_counted(s) && ui.find_count() == BENCH_TURNS }, "the prompts counted")
		// (the current one is the last prompt, at the bottom: Shift+F3 goes to the one before)
		session.key(s, .F3, {.Shift})
		session.wait_until(s, find_current_in_view, "a prompt's match lit in view")
		testing.expect_value(t, ui.find_index(), BENCH_TURNS - 2)
		in_prompt := false
		for m in ui.find_matches() {
			if m.index != ui.find_index() { continue }
			for turn in 0 ..< BENCH_TURNS {
				if b := session.find(s, fmt.tprintf("u_msg_%d_u", turn)); b != nil && m.rect.min.y >= b.rect.min.y && m.rect.max.y <= b.rect.max.y { in_prompt = true }
			}
		}
		testing.expect(t, in_prompt, "in a prompt's plate")
		testing.expect(t, session.find(s, "msg_msg_0_u") == nil, "the first prompt is far above the view")
		// (Ctrl+F again: the keyboard back in the field, its text selected)
		session.key(s, .F, {.Ctrl})
		session.type_text(s, "Step 0: look")
		session.wait_until(s, proc(s: ^session.Session) -> bool { return find_counted(s) && ui.find_count() == 1 && find_current_in_view(s) }, "the first prompt lit in view")
		testing.expect(t, session.find(s, "u_msg_0_u") != nil, "the conversation at the first prompt")
		// the home page has no conversation to search: the find goes with it
		new_session(app)
		session.wait_until(s, proc(s: ^session.Session) -> bool { return !ui.find_is_open() }, "closed on the home page")
	})
}

// The magnifier above the prompts' marks opens the find over the conversation, a second press closes it; the bar stands
// alone in its corner (the marks had a filter field there, which could be open with it).
@(test)
the_magnifier_opens_the_find :: proc(t: ^testing.T) {
	unwatched.run(t, proc(t: ^testing.T) {
		context.allocator = runtime.heap_allocator()
		app, s := bench_app(t)
		session.click(s, "prompt_rail")
		session.wait_until(s, find_opened, "the find open")
		chat := session.get(s, "chat")
		bar := session.wait_box(s, fmt.tprintf("find_bar_%x", u64(chat.key)))
		testing.expect(t, bar.rect.max.x <= chat.rect.max.x && bar.rect.min.y >= chat.rect.min.y, "inside the conversation's view")
		// (every text field over the bar is its own)
		inside :: proc(b, top: ^ui.Box) -> bool {
			for p := b; p != nil; p = p.parent { if p == top { return true } }
			return false
		}
		over :: proc(b, bar: ^ui.Box, n: ^int) {
			r := b.rect
			if .Text_Input in b.flags && r.min.x < bar.rect.max.x && r.max.x > bar.rect.min.x && r.min.y < bar.rect.max.y && r.max.y > bar.rect.min.y && !inside(b, bar) { n^ += 1 }
			for c := b.first; c != nil; c = c.next { over(c, bar, n) }
		}
		others := 0
		over(app.state.root, bar, &others)
		testing.expect_value(t, others, 0)
		session.click(s, "prompt_rail")
		session.wait_until(s, proc(s: ^session.Session) -> bool { return !ui.find_is_open() }, "closed")
	})
}

// A long conversation is counted in slices: the first frame after a needle does not read all of it (the frame would stall
// on it), and the count comes a few frames later. (The times are the bench's, OCN_BENCH.)
@(test)
a_long_conversation_is_counted_in_slices :: proc(t: ^testing.T) {
	unwatched.run(t, proc(t: ^testing.T) {
		context.allocator = runtime.heap_allocator()
		app, s := bench_app(t)
		session.key(s, .F, {.Ctrl})
		session.wait_until(s, find_opened, "the find open")
		total := 0
		for i in 0 ..< len(main_pane(app).chat.messages) {
			if text, ok := message_text(main_pane(app), i, context.temp_allocator, true); ok { total += len(text) }
		}
		testing.expectf(t, total > 2 * ui.FIND_BYTES_PER_FRAME, "a conversation longer than a few slices: %d bytes", total)
		for r in BENCH_FIND { session.event(s, {kind = .Text, text = r}) }
		session.frame(s)
		testing.expect(t, ui.find_pending(), "not all read in one frame")
		frames := 1
		for ui.find_pending() && frames < 1000 {
			session.frame(s)
			frames += 1
		}
		testing.expect(t, !ui.find_pending(), "counted")
		testing.expectf(t, frames > 1, "in slices: %d frames", frames)
		testing.expect_value(t, ui.find_count(), 3 * BENCH_TURNS)
	})
}

// A message's whole text (the find's, message_text with whole) is the text its boxes give once every part is open: the
// copy of the built messages with the reasoning and the tool calls opened. (A match found there is found again in the boxes,
// and numbered.)
@(test)
the_whole_text_is_the_boxes_opened :: proc(t: ^testing.T) {
	unwatched.run(t, proc(t: ^testing.T) {
		context.allocator = runtime.heap_allocator()
		app, s := bench_app(t)
		pane := main_pane(app)
		c := &pane.chat
		testing.expect(t, app.prefs.reasoning == "collapsed" && !app.prefs.expand_tools, "folded")
		// (the last two turns: a prompt, an answer, a turn's end, a prompt, the last answer)
		lo := len(c.messages) - 6
		hi := len(c.messages) - 2
		whole := make([dynamic]string, context.temp_allocator)
		for i in lo ..= hi {
			if text, ok := message_text(pane, i, context.temp_allocator, true); ok { append(&whole, text) }
		}
		folded := make([dynamic]string, context.temp_allocator)
		for i in lo ..= hi {
			if text, ok := message_text(pane, i, context.temp_allocator, false); ok { append(&folded, text) }
		}
		testing.expect(t, strings.join(folded[:], "\n\n", context.temp_allocator) != strings.join(whole[:], "\n\n", context.temp_allocator), "the folded parts are in the whole text alone")

		// everything open and built: the boxes' text, from the first selectable box of the first message to the last one's end
		app.prefs.reasoning, app.prefs.expand_tools = "expanded", true
		c.loading = true
		session.frames(s, 3)
		first_sel :: proc(b: ^ui.Box) -> ^ui.Box {
			if .Selectable in b.flags { return b }
			for k := b.first; k != nil; k = k.next { if f := first_sel(k); f != nil { return f } }
			return nil
		}
		last_sel :: proc(b: ^ui.Box) -> ^ui.Box {
			found: ^ui.Box
			if .Selectable in b.flags { found = b }
			for k := b.first; k != nil; k = k.next { if l := last_sel(k); l != nil { found = l } }
			return found
		}
		from := session.find(s, fmt.tprintf("msg_%s", c.messages[lo].id))
		to := session.find(s, fmt.tprintf("msg_%s", c.messages[hi].id))
		if !testing.expect(t, from != nil && to != nil, "built") { return }
		a, b := first_sel(from), last_sel(to)
		if !testing.expect(t, a != nil && b != nil, "selectable text") { return }
		ui.select_box(&app.state, b.key)
		end := app.state.sel.focus
		ui.select_box(&app.state, a.key)
		app.state.sel.focus = end
		boxes := ui.selected_text(&app.state, context.temp_allocator)
		c.loading = false
		joined := strings.join(whole[:], "\n\n", context.temp_allocator)
		if boxes != joined {
			at := 0
			for at < min(len(boxes), len(joined)) && boxes[at] == joined[at] { at += 1 }
			testing.expectf(t, false, "the whole text (%d bytes) is not the boxes' (%d bytes): from byte %d,\nwhole: %q\nboxes: %q", len(joined), len(boxes), at,
				joined[max(at - 80, 0):min(at + 80, len(joined))], boxes[max(at - 80, 0):min(at + 80, len(boxes))])
		}
	})
}
