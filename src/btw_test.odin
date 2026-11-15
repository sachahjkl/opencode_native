package ocn

// /btw and its panel (src/md/features/chat-panes.md, Layers 2 and 3): a second pane beside the main view, its requests, its
// events, its composer and its keys; the command that forks the session into it.

import "base:runtime"
import "core:fmt"
import "core:strings"
import "core:testing"
import "gt:ui"
import session "gt:testkit/session"
import "gt:testkit/unwatched"

@(private = "file")
btw_page :: proc(sid, text: string) -> string {
	return fmt.tprintf(`{{"data":[{{"id":"%s_u","type":"user","text":%q,"time":{{"created":1}}}}],"cursor":{{"next":""}}}}`, sid, text)
}

@(private = "file")
delta :: proc(app: ^App, sid, text: string) {
	bench_event(app, fmt.tprintf(`{{"type":"session.text.delta","data":{{"sessionID":"%s","assistantMessageID":"%s_a","ordinal":0,"delta":%q}}}}`, sid, sid, text))
}

// The text the pane's last answer streamed ("": none).
@(private = "file")
streamed :: proc(pane: ^Chat_Pane) -> string {
	#reverse for &m in pane.chat.messages {
		if m.kind == .Assistant && len(m.parts) > 0 { return string(m.parts[0].text[:]) }
	}
	return ""
}

// /btw forks the session shown, titles the fork, sends it the preamble then the text in that order, and opens the panel on it;
// the main view and its composer stay as they were, the text gone from it. Nothing typed after it: nothing happens, the text stays.
@(test)
btw_forks_titles_sends_and_opens_the_panel :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	main := main_pane(app)
	open_chat(app, "a")
	bench_clear(app)

	ui.text_edit_set(&main.composer.area, "/btw")
	submit_prompt(app, main)
	testing.expect_value(t, bench_count(.Btw_Fork), 0)
	testing.expect_value(t, ui.text_edit_string(&main.composer.area), "/btw")

	ui.text_edit_set(&main.composer.area, "/btw why is the build slow here today, really")
	submit_prompt(app, main)
	testing.expect_value(t, ui.text_edit_string(&main.composer.area), "")
	testing.expect_value(t, bench_count(.Prompt), 0)
	fork := bench_take(t, .Btw_Fork)
	testing.expect_value(t, fork.path, "/api/session/a/fork")
	testing.expect_value(t, fork.body, "{}")
	bench_answer(app, fork, 200, `{"data":{"id":"f"}}`)

	pane := btw_pane(app)
	if !testing.expect(t, pane != nil && pane != main, "the panel's pane") { return }
	testing.expect_value(t, pane.chat.id, "f")
	testing.expect(t, ui.view_is_open(&app.program_views, BTW_VIEW), "the panel open")
	testing.expect_value(t, main.chat.id, "a")
	title := bench_take(t, .Action)
	testing.expect_value(t, title.method, "PATCH")
	testing.expect_value(t, title.path, "/api/session/f")
	testing.expect_value(t, title.body, `{"title":"btw: why is the build slow here…"}`)
	read := bench_take(t, .Messages)
	testing.expect_value(t, read.pane, app.btw)
	testing.expect_value(t, read.tag, "f")

	aside := bench_take(t, .Btw_Aside)
	testing.expect_value(t, aside.path, "/api/session/f/synthetic")
	testing.expect(t, strings.contains(aside.body, `"resume":false`) && strings.contains(aside.body, BTW_SOURCE), aside.body)
	testing.expect_value(t, bench_count(.Prompt), 0)   // (after the preamble: no order between two on their way)
	bench_answer(app, aside, 200, `{"data":{}}`)
	prompt := bench_take(t, .Prompt)
	testing.expect_value(t, prompt.path, "/api/session/f/prompt")
	testing.expect_value(t, prompt.pane, app.btw)
	testing.expect(t, strings.has_prefix(prompt.body, `{"text":"why is the build slow here today, really"`), prompt.body)
	bench_answer(app, prompt, 200, `{"data":{}}`)
	testing.expect_value(t, len(app.cx.outgoing), 0)

	// the preamble, as the stream and the page give it: in the fork for the model, not shown
	bench_event(app, `{"type":"session.inbox.enqueued","data":{"sessionID":"f","inboxID":"syn","item":{"type":"synthetic","delivery":"queue","payload":{"text":"aside","metadata":{"source":"ocn.btw"}}}}}`)
	m := find_message(&pane.chat, "syn")
	testing.expect(t, m != nil && m.kind == .Other, "the preamble hidden")
	testing.expect_value(t, len(main.chat.messages), 0)
}

// While a run streams, the fork stops before the answer being written; a fork refused gives /btw back to the composer it came from.
@(test)
btw_forks_before_the_answer_that_streams :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	main := main_pane(app)
	open_chat(app, "a")
	bench_clear(app)
	set_busy(app, "a", true)
	load_messages(app, main, "a")
	bench_answer(app, bench_take(t, .Messages), 200,
		`{"data":[{"id":"a2","type":"assistant","time":{"created":2},"content":[{"type":"text","text":"half"}]},{"id":"a1","type":"user","text":"go","time":{"created":1}}],"cursor":{"next":""}}`)
	bench_clear(app)
	ui.text_edit_set(&main.composer.area, "/btw and then?")
	submit_prompt(app, main)
	fork := bench_take(t, .Btw_Fork)
	testing.expect_value(t, fork.body, `{"before":"a2"}`)
	bench_answer(app, fork, 500, `{"message":"no"}`)
	testing.expect_value(t, ui.text_edit_string(&main.composer.area), "/btw and then?")
	testing.expect(t, btw_pane(app) == nil, "no panel")
}

// The design's day-one test: while the panel's page is on its way, the main view goes to another session. The page lands in the
// panel; the main view shows none of it; a delta of the fork lands in the panel alone.
@(test)
the_panels_page_lands_in_the_panel_while_the_main_view_moves :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	main := main_pane(app)
	open_chat(app, "a")
	bench_clear(app)
	pane := btw_open(app, "f")
	page := bench_take(t, .Messages)
	bench_clear(app)
	open_chat(app, "b")
	bench_answer(app, page, 200, btw_page("f", "the aside"))
	testing.expect_value(t, len(pane.chat.messages), 1)
	testing.expect(t, pane.chat.loaded, "the panel's conversation read")
	testing.expect_value(t, main.chat.id, "b")
	testing.expect_value(t, len(main.chat.messages), 0)
	testing.expect(t, main.chat.loading, "the main view still waits for its own page")
	delta(app, "f", "aside answer")
	testing.expect_value(t, streamed(pane), "aside answer")
	testing.expect_value(t, len(main.chat.messages), 0)
	delta(app, "b", "main answer")
	testing.expect_value(t, streamed(main), "main answer")
	testing.expect_value(t, streamed(pane), "aside answer")
}

// Closed, the panel's pane is free again and what was asked for it is dropped; the session stays (nothing deleted), its
// composer's text in its draft. Its session deleted elsewhere closes it.
@(test)
closing_the_panel_frees_its_pane :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	open_chat(app, "a")
	bench_clear(app)
	pane := btw_open(app, "f")
	slot := app.btw
	page := bench_take(t, .Messages)
	ui.text_edit_set(&pane.composer.area, "half written")
	btw_close(app)
	testing.expect(t, !pane.shown && app.btw == 0, "the slot free")
	testing.expect(t, !ui.view_is_open(&app.program_views, BTW_VIEW), "the view closed")
	testing.expect(t, pane_free(app) == &app.panes[slot], "free for the next")
	testing.expect_value(t, app.drafts["f"].text, "half written")
	for r in bench_sent { testing.expect(t, r.method != "DELETE", "the session stays") }
	bench_answer(app, page, 200, btw_page("f", "late"))
	testing.expect_value(t, len(pane.chat.messages), 0)

	pane = btw_open(app, "g")
	bench_clear(app)
	bench_event(app, `{"type":"session.deleted","data":{"sessionID":"g"}}`)
	testing.expect(t, btw_pane(app) == nil, "its session deleted: the panel closed")
	testing.expect_value(t, main_pane(app).chat.id, "a")
}

// The same session in both panes: each follows its events, one zoom for both.
@(test)
one_session_in_two_panes :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	main := main_pane(app)
	open_chat(app, "a")
	pane := btw_open(app, "a")
	for bench_count(.Messages) > 0 { bench_answer(app, bench_take(t, .Messages), 200, btw_page("a", "hello")) }
	bench_clear(app)
	testing.expect_value(t, len(main.chat.messages), 1)
	testing.expect_value(t, len(pane.chat.messages), 1)
	delta(app, "a", "both")
	testing.expect_value(t, streamed(main), "both")
	testing.expect_value(t, streamed(pane), "both")
	_ = ui.zoom_zone(&main.zone, "a")
	_ = ui.zoom_zone(&pane.zone, "a")
	ui.zoom_zone_by(&main.zone, 1.25)
	testing.expect_value(t, ui.zoom_zone_value(&pane.zone), ui.zoom_zone_value(&main.zone))
	testing.expect(t, ui.zoom_zone_value(&pane.zone) > 1, "zoomed")
}

// The panel in the window: /btw from the main composer leaves the keyboard there; the panel's composer sends to the fork; Escape
// twice in the panel stops the fork's run, not the main one's.
@(test)
the_panels_composer_acts_on_the_fork :: proc(t: ^testing.T) {
	unwatched.run(t, proc(t: ^testing.T) {
		context.allocator = runtime.heap_allocator()
		app, s := bench_app(t)
		main := main_pane(app)
		app.conn = bench_conn(app)
		defer { bench_clear(app); app.conn = nil; set_busy(app, BENCH_CHAT_ID, false); set_busy(app, "ses_3", false) }
		main.composer.focus_next = true
		session.wait_until(s, proc(s: ^session.Session) -> bool { return main_pane((^App)(s.user)).composer.focused }, "the main composer focused")
		session.type_text(s, "/btw what now")
		session.key(s, .Return)
		bench_answer(app, bench_take(t, .Btw_Fork), 200, `{"data":{"id":"ses_3"}}`)
		session.frames(s, 3)
		pane := btw_pane(app)
		if !testing.expect(t, pane != nil, "the panel") { return }
		if bench_count(.Messages) > 0 { bench_answer(app, bench_take(t, .Messages), 200, btw_page("ses_3", "what now")) }
		session.frames(s, 3)
		testing.expect(t, main.composer.focused, "the main composer keeps the keyboard")
		root := app.state.boxes[pane.conversation.root] or_else nil
		testing.expect(t, root != nil && session.find(s, "composer", within = root) != nil, "the panel's composer")
		bench_clear(app)

		pane.composer.focus_next = true
		session.wait_until(s, proc(s: ^session.Session) -> bool { return btw_pane((^App)(s.user)).composer.focused }, "the panel's composer focused")
		testing.expect(t, keys_pane(app) == pane, "the keyboard's pane")
		session.type_text(s, "and then")
		session.key(s, .Return)
		sent := bench_take(t, .Prompt)
		testing.expect_value(t, sent.path, "/api/session/ses_3/prompt")
		testing.expect_value(t, sent.pane, app.btw)
		bench_answer(app, sent, 200, `{"data":{}}`)

		set_busy(app, BENCH_CHAT_ID, true)
		set_busy(app, "ses_3", true)
		session.frames(s, 2)
		bench_clear(app)
		session.key(s, .Escape)
		session.frames(s, 2)
		testing.expect_value(t, bench_count(.Action), 0)
		testing.expect(t, session.find(s, "stop_armed", within = root) != nil, "the panel says a second one stops")
		session.key(s, .Escape)
		session.frames(s, 2)
		stop := bench_take(t, .Action)
		testing.expect_value(t, stop.path, "/api/session/ses_3/interrupt")
		testing.expect_value(t, bench_count(.Action), 0)
		testing.expect(t, pane.composer.focused, "the panel's composer keeps the keyboard")
		btw_close(app)
		session.frames(s, 2)
	})
}
