package ocn

// What waits in the inbox, and the Statistics panel, on the bench of the answers (answers_test.odin): requests kept, answered by the test in
// the order it wants, events given by hand. The shapes are the server's (2.2.5): what the spec does not say was read in its code.

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:testing"
import tk_json "gt:json"
import "gt:ui"
import remote "gt:remote"

@(private = "file")
show :: proc(app: ^App, id: string) {
	open_chat(app, id)
	bench_clear(app)
}

// The session shown, a turn running.
@(private = "file")
running :: proc(app: ^App, id: string) {
	show(app, id)
	bench_event(app, fmt.tprintf(`{{"type":"session.execution.started","data":{{"sessionID":"%s"}}}}`, id))
}

@(private = "file")
enqueued :: proc(app: ^App, id, text, delivery: string, files := "") {
	bench_event(app, fmt.tprintf(`{{"type":"session.inbox.enqueued","created":5,"data":{{"sessionID":"s","inboxID":"%s","item":{{"type":"user","delivery":"%s","payload":{{"text":"%s"%s}}}}}}}}`, id, delivery, text, files))
}

@(private = "file")
delivered :: proc(app: ^App, id: string) {
	bench_event(app, fmt.tprintf(`{{"type":"session.inbox.delivered","created":9,"data":{{"sessionID":"s","inboxID":"%s"}}}}`, id))
}

@(private = "file")
item_json :: proc(id, text, delivery: string) -> string {
	return fmt.tprintf(`{{"id":"%s","sessionID":"s","type":"user","delivery":"%s","time":{{"created":1}},"payload":{{"text":"%s"}}}}`, id, delivery, text)
}

@(private = "file")
listed :: proc(items: ..string) -> string {
	return fmt.tprintf(`{{"data":[%s]}}`, strings.join(items, ",", context.temp_allocator))
}

@(private = "file")
IMAGE_FILE :: `,"files":[{"data":"AAAA","mime":"image/png","name":"a.png","source":{"type":"inline"}}]`

@(private = "file")
attach :: proc(app: ^App, name: string) {
	pane := main_pane(app)
	append(&pane.composer.attachments, Attachment{name = strings.clone(name), uri = strings.clone("data:image/png;base64,AAAA")})
}

////////////////////////////////
// How a prompt goes

@(test)
while_a_turn_runs_enter_steers_and_the_other_key_queues :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	for d in PREF_DEFS {
		if d.name == "conversation.while_running" { testing.expect_value(t, d.default.s, "steer") }   // (a new reader gets this)
	}
	app := bench_new()
	pane := main_pane(app)
	running(app, "s")
	pref_set(app, "conversation.while_running", "steer")
	ui.text_edit_set(&pane.composer.area, "now")
	submit_prompt(app, pane)
	testing.expect(t, strings.contains(bench_take(t, .Prompt).body, `"delivery":"steer"`))

	ui.text_edit_set(&pane.composer.area, "later")
	submit_prompt(app, pane, true)
	r := bench_take(t, .Prompt)
	testing.expect(t, strings.contains(r.body, `"delivery":"queue"`), r.body)
	bench_answer(app, r, 200, fmt.tprintf(`{{"data":%s}}`, item_json("i1", "later", "queue")))

	pref_set(app, "conversation.while_running", "queue")
	ui.text_edit_set(&pane.composer.area, "swapped")
	submit_prompt(app, pane)
	testing.expect(t, strings.contains(bench_take(t, .Prompt).body, `"delivery":"queue"`), "the preference swaps them")
	ui.text_edit_set(&pane.composer.area, "swapped too")
	submit_prompt(app, pane, true)
	testing.expect(t, strings.contains(bench_take(t, .Prompt).body, `"delivery":"steer"`))
}

@(test)
when_nothing_runs_a_prompt_goes_as_it_always_did :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	pane := main_pane(app)
	show(app, "s")
	ui.text_edit_set(&pane.composer.area, "hello")
	submit_prompt(app, pane, true)
	testing.expect(t, !strings.contains(bench_take(t, .Prompt).body, "delivery"), "no word of it")
	enqueued(app, "i", "hello", "steer")
	testing.expect_value(t, len(pane.chat.messages), 1)
	testing.expect_value(t, len(pane.queue.items), 0)
}

@(test)
a_slash_command_queues_too :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	pane := main_pane(app)
	slash_load(app, []Slash{{strings.clone("review"), strings.clone("")}})
	running(app, "s")
	ui.text_edit_set(&pane.composer.area, "/review all")
	submit_prompt(app, pane)
	testing.expect(t, strings.contains(bench_take(t, .Prompt).body, `"delivery":"queue"`))
}

@(test)
what_failed_to_queue_comes_back_whole :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	pane := main_pane(app)
	running(app, "s")
	ui.text_edit_set(&pane.composer.area, "later")
	attach(app, "a.png")
	submit_prompt(app, pane)
	testing.expect_value(t, ui.text_edit_string(&pane.composer.area), "")
	bench_lost(app, bench_take(t, .Prompt))
	testing.expect_value(t, ui.text_edit_string(&pane.composer.area), "later")
	testing.expect_value(t, len(pane.composer.attachments), 1)
}

////////////////////////////////
// Every message that waits is in the list, and nowhere else

// During a run, what was sent showed in the conversation as sent, or not at all, and an image changed that: the list is the one place.
@(test)
what_waits_is_in_the_list_with_an_image_or_without :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	pane := main_pane(app)
	running(app, "s")
	enqueued(app, "a", "text only", "steer")
	enqueued(app, "b", "with an image", "steer", IMAGE_FILE)
	enqueued(app, "c", "for the end", "queue")
	testing.expect_value(t, len(pane.chat.messages), 0)
	testing.expect_value(t, len(pane.queue.items), 3)
	testing.expect_value(t, pane.queue.items[1].files, 1)
	testing.expect_value(t, pane.queue.items[2].delivery, Delivery.Queue)
}

@(test)
a_message_delivered_shows_once_in_its_place :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	pane := main_pane(app)
	running(app, "s")
	bench_event(app, `{"type":"session.step.started","data":{"sessionID":"s","assistantMessageID":"m1","agent":"a","model":{"id":"x","providerID":"p"},"started":1}}`)
	enqueued(app, "i", "later", "queue", IMAGE_FILE)
	delivered(app, "i")
	delivered(app, "i")
	testing.expect_value(t, len(pane.queue.items), 0)
	testing.expect_value(t, len(pane.chat.messages), 2)
	m := pane.chat.messages[1]
	testing.expect_value(t, m.id, "i")
	testing.expect_value(t, m.kind, Msg_Kind.User)
	testing.expect_value(t, m.text, "later")
	testing.expect_value(t, len(m.images), 1)
	testing.expect_value(t, m.created, 9)
	bench_event(app, `{"type":"session.step.started","data":{"sessionID":"s","assistantMessageID":"m2","agent":"a","model":{"id":"x","providerID":"p"},"started":2}}`)
	testing.expect_value(t, pane.chat.messages[2].id, "m2")   // (what follows goes after it)
}

@(test)
a_page_that_holds_what_waits_does_not_send_it :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	pane := main_pane(app)
	running(app, "s")
	enqueued(app, "i", "later", "queue")
	load_messages(app, pane, "s")
	bench_answer(app, bench_take(t, .Messages), 200, `{"data":[{"id":"i","type":"user","text":"later","time":{"created":1}}],"cursor":{"next":""}}`)
	testing.expect_value(t, len(pane.chat.messages), 0)
	delivered(app, "i")
	load_messages(app, pane, "s")
	bench_answer(app, bench_take(t, .Messages), 200, `{"data":[{"id":"i","type":"user","text":"later","time":{"created":1}}],"cursor":{"next":""}}`)
	testing.expect_value(t, len(pane.chat.messages), 1)
}

// The prompt's answer says it too: with the stream late, or down, what was sent does not vanish.
@(test)
the_answer_to_a_prompt_lists_it_once :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	pane := main_pane(app)
	running(app, "s")
	ui.text_edit_set(&pane.composer.area, "later")
	submit_prompt(app, pane)
	bench_answer(app, bench_take(t, .Prompt), 200, fmt.tprintf(`{{"data":%s}}`, item_json("i", "later", "queue")))
	testing.expect_value(t, len(pane.queue.items), 1)
	enqueued(app, "i", "later", "queue")
	testing.expect_value(t, len(pane.queue.items), 1)
}

@(test)
what_was_delivered_before_the_prompts_answer_is_not_listed_again :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	pane := main_pane(app)
	running(app, "s")
	ui.text_edit_set(&pane.composer.area, "later")
	submit_prompt(app, pane)
	r := bench_take(t, .Prompt)
	enqueued(app, "i", "later", "queue")
	delivered(app, "i")
	bench_answer(app, r, 200, fmt.tprintf(`{{"data":%s}}`, item_json("i", "later", "queue")))
	testing.expect_value(t, len(pane.queue.items), 0)
	testing.expect_value(t, len(pane.chat.messages), 1)
}

////////////////////////////////
// The list is the server's

@(test)
the_list_is_read_on_opening_and_on_reconnecting :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	pane := main_pane(app)
	open_chat(app, "s")
	r := bench_take(t, .Queue_List)
	testing.expect(t, strings.contains(r.path, "/api/session/s/inbox"))
	bench_answer(app, r, 200, listed(item_json("a", "one", "queue"), item_json("b", "two", "steer")))
	testing.expect_value(t, len(pane.queue.items), 2)
	bench_clear(app)
	stream_down(app, 0)
	stream_up(app)
	bench_answer(app, bench_take(t, .Queue_List), 200, listed(item_json("b", "two", "queue")))
	testing.expect_value(t, len(pane.queue.items), 1)
	testing.expect_value(t, pane.queue.items[0].id, "b")
	testing.expect_value(t, pane.queue.items[0].delivery, Delivery.Queue)
}

@(test)
a_stale_list_does_not_undo_what_the_stream_said :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	pane := main_pane(app)
	show(app, "s")
	queue_read(app, pane)
	first := bench_take(t, .Queue_List)
	bench_answer(app, first, 200, listed(item_json("gone", "x", "queue"), item_json("moved", "y", "queue")))
	queue_read(app, pane)
	stale := bench_take(t, .Queue_List)
	bench_event(app, `{"type":"session.execution.started","data":{"sessionID":"s"}}`)
	delivered(app, "gone")
	bench_event(app, `{"type":"session.inbox.delivery.changed","data":{"sessionID":"s","inboxID":"moved","delivery":"steer"}}`)
	enqueued(app, "new", "z", "queue")
	bench_answer(app, stale, 200, listed(item_json("gone", "x", "queue"), item_json("moved", "y", "queue")))
	testing.expect_value(t, len(pane.queue.items), 2)
	testing.expect(t, queue_find(app, pane, "gone") == nil, "delivered stays delivered")
	testing.expect_value(t, queue_find(app, pane, "moved").delivery, Delivery.Steer)
	testing.expect(t, queue_find(app, pane, "new") != nil, "what came since stays")
}

@(test)
another_clients_changes_show :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	pane := main_pane(app)
	running(app, "s")
	enqueued(app, "i", "later", "queue")
	bench_event(app, `{"type":"session.inbox.cancelled","data":{"sessionID":"s","inboxID":"i"}}`)
	testing.expect_value(t, len(pane.queue.items), 0)
	testing.expect_value(t, len(pane.chat.messages), 0)
}

@(test)
a_failed_reading_can_be_tried_again_and_a_refusal_says_nothing :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	pane := main_pane(app)
	open_chat(app, "s")
	bench_lost(app, bench_take(t, .Queue_List))
	testing.expect_value(t, pane.queue.read.state, remote.State.Failed)
	queue_read(app, pane)
	bench_answer(app, bench_take(t, .Queue_List), 404, `{"message":"no"}`)
	testing.expect_value(t, pane.queue.read.state, remote.State.Refused)
}

@(test)
what_waits_for_a_session_stays_with_it :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	pane := main_pane(app)
	running(app, "s")
	enqueued(app, "i", "later", "queue")
	queue_read(app, pane)
	old := bench_take(t, .Queue_List)
	show(app, "other")
	testing.expect_value(t, len(pane.queue.items), 0)
	bench_answer(app, old, 200, listed(item_json("i", "later", "queue")))
	testing.expect_value(t, len(pane.queue.items), 0)   // (not this session's: its reading was given up)
	bench_event(app, `{"type":"session.inbox.enqueued","data":{"sessionID":"s","inboxID":"j","item":{"type":"user","delivery":"queue","payload":{"text":"x"}}}}`)
	testing.expect_value(t, len(pane.queue.items), 0)
	open_chat(app, "s")
	bench_answer(app, bench_take(t, .Queue_List), 200, listed(item_json("i", "later", "queue"), item_json("j", "x", "queue")))
	testing.expect_value(t, len(pane.queue.items), 2)
}

////////////////////////////////
// What can be done to an item

@(test)
one_action_at_a_time_on_an_item :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	pane := main_pane(app)
	running(app, "s")
	enqueued(app, "i", "later", "queue")
	queue_remove(app, pane, "i")
	queue_remove(app, pane, "i")
	queue_steer(app, pane, "i")
	queue_edit(app, pane, "i")
	testing.expect_value(t, bench_count(.Queue_Cancel), 1)
	testing.expect_value(t, bench_count(.Queue_Steer), 0)
	testing.expect(t, !queue_editing(app, pane))
	bench_answer(app, bench_take(t, .Queue_Cancel), 204, "")
	testing.expect_value(t, len(pane.queue.items), 0)
}

// The other way with nothing written, while a run works, steers the first queued prompt into it (opencode 2.3.0's
// Ctrl+Enter); one already steered is passed, one on its way is waited for; nothing runs: nothing goes.
@(test)
the_other_way_with_nothing_written_steers_the_first_queued :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	pane := main_pane(app)
	running(app, "s")
	enqueued(app, "s1", "now", "steer")
	enqueued(app, "q1", "first", "queue")
	enqueued(app, "q2", "second", "queue")
	submit_prompt(app, pane, false)
	testing.expect_value(t, bench_count(.Queue_Steer), 0)   // (Enter with nothing: nothing)
	submit_prompt(app, pane, true)
	r := bench_take(t, .Queue_Steer)
	testing.expectf(t, strings.contains(r.path, "/inbox/q1"), "the first queued: %s", r.path)
	testing.expect_value(t, bench_count(.Prompt), 0)
	submit_prompt(app, pane, true)
	testing.expect_value(t, bench_count(.Queue_Steer), 0)   // (q1 on its way: not q2 instead)
	bench_answer(app, r, 204, "")
	bench_event(app, `{"type":"session.execution.succeeded","data":{"sessionID":"s"}}`)
	submit_prompt(app, pane, true)
	testing.expect_value(t, bench_count(.Queue_Steer), 0)   // (nothing runs)
}

////////////////////////////////
// Queue first (Alt+Enter)

// The ids the list over the composer shows, in its order.
@(private = "file")
shown_ids :: proc(app: ^App) -> string {
	pane := main_pane(app)
	ids := make([dynamic]string, context.temp_allocator)
	for it in pane.queue.items { if !queue_hidden(app, pane, it.id) { append(&ids, it.id) } }
	return strings.join(ids[:], " ", context.temp_allocator)
}

@(private = "file")
admitted :: proc(id, text: string) -> string { return fmt.tprintf(`{{"data":%s}}`, item_json(id, text, "queue")) }

// The id a copy was minted with, as its body says it.
@(private = "file")
copy_id :: proc(t: ^testing.T, r: ^Request, loc := #caller_location) -> string {
	v, _ := json.parse_string(r.body, parse_integers = true, allocator = context.temp_allocator)
	id := strings.clone(tk_json.text(v, "id"), context.temp_allocator)
	testing.expectf(t, strings.has_prefix(id, "msg_") && len(id) == 30, "a minted id: %q", r.body, loc = loc)
	return id
}

@(test)
a_message_id_is_the_servers_ascending_format :: proc(t: ^testing.T) {
	MS :: i64(1_763_200_000_123)
	a := message_id_at(MS)
	b := message_id_at(MS)
	c := message_id_at(MS + 1)
	testing.expect_value(t, len(a), 4 + 12 + MESSAGE_ID_RANDOM)
	testing.expect_value(t, a[:16], fmt.tprintf("msg_%012x", (u64(MS) * 0x1000 + 1) & 0xffff_ffff_ffff))
	testing.expect_value(t, b[:16], fmt.tprintf("msg_%012x", (u64(MS) * 0x1000 + 2) & 0xffff_ffff_ffff))
	testing.expect_value(t, c[:16], fmt.tprintf("msg_%012x", (u64(MS + 1) * 0x1000 + 1) & 0xffff_ffff_ffff))   // (the counter restarts)
	testing.expect(t, a < b && b < c, "ascending, in one millisecond too")
	for r in a[16:] { testing.expect(t, strings.contains_rune(MESSAGE_ID_CHARS, r), a) }
	testing.expect(t, strings.has_prefix(message_id_new(), "msg_"))
}

// Two prompts queued, one steered; Alt+Enter: "n" goes queued, then q1 and q2 are admitted again behind it, then their
// originals cancelled. Each prompt shows once all along; the steered one stays where it is.
@(private = "file")
alt_enter_two_queued :: proc(t: ^testing.T, app: ^App) {
	pane := main_pane(app)
	running(app, "s")
	enqueued(app, "s1", "steered", "steer")
	enqueued(app, "q1", "one", "queue")
	enqueued(app, "q2", "two", "queue")
	ui.text_edit_set(&pane.composer.area, "urgent")
	submit_prompt(app, pane, first = true)
	p := bench_take(t, .Prompt)
	testing.expect(t, strings.contains(p.body, `"delivery":"queue"`), p.body)
	testing.expect_value(t, ui.text_edit_string(&pane.composer.area), "")
	testing.expect_value(t, bench_count(.Queue_First_Copy), 0)   // (its id first)
	bench_answer(app, p, 200, admitted("n", "urgent"))
}

@(test)
alt_enter_queues_the_prompt_first :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	pane := main_pane(app)
	alt_enter_two_queued(t, app)
	c1 := bench_take(t, .Queue_First_Copy)
	testing.expect_value(t, c1.path, "/api/session/s/prompt")
	testing.expect(t, strings.contains(c1.body, `"text":"one"`), c1.body)
	testing.expect(t, strings.contains(c1.body, `"delivery":"queue"`), c1.body)
	testing.expect(t, strings.contains(c1.body, `"resume":false`), c1.body)
	testing.expect_value(t, bench_count(.Queue_First_Copy), 0)   // (one at a time)
	testing.expect_value(t, queue_find(app, pane, "q1").act, Queue_Act.Moving)
	id1 := copy_id(t, c1)
	enqueued(app, id1, "one", "queue")   // (its event before its answer: known by its id already)
	testing.expect_value(t, shown_ids(app), "s1 q1 q2 n")
	bench_answer(app, c1, 200, admitted(id1, "one"))
	c2 := bench_take(t, .Queue_First_Copy)
	testing.expect(t, strings.contains(c2.body, `"text":"two"`), c2.body)
	id2 := copy_id(t, c2)
	testing.expect(t, id1 != id2)
	testing.expect_value(t, bench_count(.Queue_First_Cancel), 0)   // (every copy in before an original goes)
	bench_answer(app, c2, 200, admitted(id2, "two"))
	testing.expect_value(t, shown_ids(app), "s1 q1 q2 n")
	x1 := bench_take(t, .Queue_First_Cancel)
	testing.expect_value(t, x1.method, "DELETE")
	testing.expect_value(t, x1.path, "/api/session/s/inbox/q1")
	testing.expect_value(t, bench_count(.Queue_First_Cancel), 0)
	bench_answer(app, x1, 204, "")
	testing.expect_value(t, shown_ids(app), fmt.tprintf("s1 q2 n %s", id1))
	x2 := bench_take(t, .Queue_First_Cancel)
	testing.expect_value(t, x2.path, "/api/session/s/inbox/q2")
	bench_answer(app, x2, 204, "")
	testing.expect_value(t, shown_ids(app), fmt.tprintf("s1 n %s %s", id1, id2))
	testing.expect_value(t, len(pane.queue.items), 4)
	testing.expect_value(t, pane.queue.first.phase, Queue_First_Phase.Idle)
	for it in pane.queue.items { testing.expect_value(t, it.act, Queue_Act.None) }
	testing.expect_value(t, bench_count(.Queue_First_Withdraw), 0)
}

@(test)
a_reorder_whose_copy_fails_leaves_the_queue_as_it_was :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	pane := main_pane(app)
	alt_enter_two_queued(t, app)
	c1 := bench_take(t, .Queue_First_Copy)
	id1 := copy_id(t, c1)
	bench_answer(app, c1, 200, admitted(id1, "one"))
	bench_answer(app, bench_take(t, .Queue_First_Copy), 500, `{"message":"file gone"}`)   // (refused: not in the inbox)
	w := bench_take(t, .Queue_First_Withdraw)
	testing.expect_value(t, w.method, "DELETE")
	testing.expect_value(t, w.path, fmt.tprintf("/api/session/s/inbox/%s", id1))
	testing.expect_value(t, bench_count(.Queue_First_Withdraw), 0)
	testing.expect_value(t, shown_ids(app), "s1 q1 q2 n")   // (the copy hidden while it goes back)
	bench_answer(app, w, 204, "")
	testing.expect_value(t, shown_ids(app), "s1 q1 q2 n")
	testing.expect_value(t, len(pane.queue.items), 4)
	testing.expect_value(t, bench_count(.Queue_First_Cancel), 0)
	testing.expect_value(t, pane.queue.first.phase, Queue_First_Phase.Idle)
	for it in pane.queue.items { testing.expect_value(t, it.act, Queue_Act.None) }
}

// The run's end delivers q1 while q2's copy is on its way: the queue changed, the reorder stops, both copies go back.
@(test)
a_prompt_delivered_during_a_reorder_stops_it :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	pane := main_pane(app)
	alt_enter_two_queued(t, app)
	c1 := bench_take(t, .Queue_First_Copy)
	id1 := copy_id(t, c1)
	bench_answer(app, c1, 200, admitted(id1, "one"))
	c2 := bench_take(t, .Queue_First_Copy)
	id2 := copy_id(t, c2)
	delivered(app, "q1")
	w1 := bench_take(t, .Queue_First_Withdraw)
	testing.expect_value(t, w1.path, fmt.tprintf("/api/session/s/inbox/%s", id1))
	testing.expect_value(t, bench_count(.Queue_First_Withdraw), 0)   // (not the one on its way: its DELETE could pass its POST)
	bench_answer(app, c2, 200, admitted(id2, "two"))
	w2 := bench_take(t, .Queue_First_Withdraw)
	testing.expect_value(t, w2.path, fmt.tprintf("/api/session/s/inbox/%s", id2))
	testing.expect_value(t, shown_ids(app), "s1 q2 n")
	bench_answer(app, w1, 204, "")
	testing.expect_value(t, pane.queue.first.phase, Queue_First_Phase.Withdrawing)   // (c2's DELETE still on its way)
	bench_answer(app, w2, 204, "")
	testing.expect_value(t, shown_ids(app), "s1 q2 n")
	testing.expect_value(t, len(pane.queue.items), 3)
	testing.expect_value(t, bench_count(.Queue_First_Cancel), 0)
	testing.expect_value(t, bench_count(.Queue_First_Copy), 0)
	testing.expect_value(t, pane.queue.first.phase, Queue_First_Phase.Idle)
	testing.expect_value(t, queue_find(app, pane, "q2").act, Queue_Act.None)
}

// The server took q2's copy (its event says so, with the minted id), then the answer was lost: it is taken back by that id.
@(test)
a_copy_whose_answer_was_lost_is_withdrawn_by_its_id :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	pane := main_pane(app)
	alt_enter_two_queued(t, app)
	c1 := bench_take(t, .Queue_First_Copy)
	id1 := copy_id(t, c1)
	bench_answer(app, c1, 200, admitted(id1, "one"))
	c2 := bench_take(t, .Queue_First_Copy)
	id2 := copy_id(t, c2)
	enqueued(app, id2, "two", "queue")
	testing.expect_value(t, shown_ids(app), "s1 q1 q2 n")
	bench_lost(app, c2)
	paths := make(map[string]^Request, allocator = context.temp_allocator)
	for _ in 0 ..< 2 { w := bench_take(t, .Queue_First_Withdraw); paths[w.path] = w }
	testing.expect_value(t, bench_count(.Queue_First_Withdraw), 0)
	w1, ok1 := paths[fmt.tprintf("/api/session/s/inbox/%s", id1)]
	w2, ok2 := paths[fmt.tprintf("/api/session/s/inbox/%s", id2)]
	testing.expect(t, ok1 && ok2, "both copies go back")
	testing.expect_value(t, shown_ids(app), "s1 q1 q2 n")
	if ok1 && ok2 {
		bench_answer(app, w1, 204, "")
		bench_answer(app, w2, 204, "")
	}
	testing.expect_value(t, shown_ids(app), "s1 q1 q2 n")
	testing.expect_value(t, len(pane.queue.items), 4)
	testing.expect_value(t, bench_count(.Queue_First_Cancel), 0)
	testing.expect_value(t, pane.queue.first.phase, Queue_First_Phase.Idle)
	for it in pane.queue.items { testing.expect_value(t, it.act, Queue_Act.None) }
}

// The answer was lost and the server never took it: the DELETE by its id answers 404, which is done, not a failure.
@(test)
a_withdraw_of_a_copy_never_taken_is_done :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	pane := main_pane(app)
	alt_enter_two_queued(t, app)
	c1 := bench_take(t, .Queue_First_Copy)
	id1 := copy_id(t, c1)
	bench_lost(app, c1)
	w := bench_take(t, .Queue_First_Withdraw)
	testing.expect_value(t, w.path, fmt.tprintf("/api/session/s/inbox/%s", id1))
	bench_answer(app, w, 404, `{"message":"not found"}`)
	testing.expect_value(t, pane.queue.first.phase, Queue_First_Phase.Idle)
	testing.expect_value(t, shown_ids(app), "s1 q1 q2 n")
	testing.expect_value(t, bench_count(.Queue_First_Cancel), 0)
}

@(test)
when_nothing_runs_alt_enter_sends_as_enter :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	pane := main_pane(app)
	show(app, "s")
	ui.text_edit_set(&pane.composer.area, "hello")
	submit_prompt(app, pane, first = true)
	r := bench_take(t, .Prompt)
	testing.expect(t, !strings.contains(r.body, "delivery"), r.body)
	testing.expect_value(t, len(pane.queue.first.outs), 0)
	bench_answer(app, r, 200, admitted("n", "hello"))
	testing.expect_value(t, bench_count(.Queue_First_Copy), 0)
}

@(test)
steer_changes_the_delivery_and_leaves_it_until_it_is_delivered :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	pane := main_pane(app)
	running(app, "s")
	enqueued(app, "i", "later", "queue")
	queue_steer(app, pane, "i")
	r := bench_take(t, .Queue_Steer)
	testing.expect_value(t, r.method, "PATCH")
	testing.expect_value(t, r.body, `{"delivery":"steer"}`)
	bench_answer(app, r, 204, "")
	it := queue_find(app, pane, "i")
	testing.expect_value(t, it.delivery, Delivery.Steer)
	testing.expect_value(t, it.act, Queue_Act.None)
	testing.expect_value(t, len(pane.chat.messages), 0)
	queue_steer(app, pane, "i")
	testing.expect_value(t, bench_count(.Queue_Steer), 0)   // (only what is queued)
}

@(test)
steer_refused_reads_the_list_again :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	pane := main_pane(app)
	running(app, "s")
	enqueued(app, "i", "later", "queue")
	queue_steer(app, pane, "i")
	bench_answer(app, bench_take(t, .Queue_Steer), 409, `{"message":"Pending input cannot change to steer"}`)
	testing.expect_value(t, queue_find(app, pane, "i").act, Queue_Act.None)
	testing.expect_value(t, bench_count(.Queue_List), 1)
}

@(test)
editing_brings_the_message_back_and_cancel_changes_nothing :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	pane := main_pane(app)
	running(app, "s")
	enqueued(app, "i", "later", "queue", IMAGE_FILE)
	ui.text_edit_set(&pane.composer.area, "a draft")
	attach(app, "draft.png")
	queue_edit(app, pane, "i")
	testing.expect(t, queue_editing(app, pane))
	testing.expect_value(t, ui.text_edit_string(&pane.composer.area), "later")
	testing.expect_value(t, len(pane.composer.attachments), 1)
	testing.expect_value(t, pane.composer.attachments[0].name, "a.png")
	testing.expect(t, strings.has_prefix(pane.composer.attachments[0].uri, "data:image/png;base64,"), "what it was stored as is a uri again")
	queue_edit_end(app, pane, .Cancel)
	testing.expect(t, !queue_editing(app, pane))
	testing.expect_value(t, ui.text_edit_string(&pane.composer.area), "a draft")
	testing.expect_value(t, pane.composer.attachments[0].name, "draft.png")
	testing.expect_value(t, bench_count(.Queue_Replace), 0)
	testing.expect(t, queue_find(app, pane, "i") != nil)
}

// The DELETE went through, and the server has not stored that message: it really left the inbox.
@(private = "file")
replaced :: proc(t: ^testing.T, app: ^App) {
	bench_answer(app, bench_take(t, .Queue_Replace), 204, "")
	bench_answer(app, bench_take(t, .Queue_Check), 404, `{"_tag":"MessageNotFoundError"}`)
}

@(test)
enter_replaces_what_was_edited :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	pane := main_pane(app)
	running(app, "s")
	enqueued(app, "i", "later", "queue")
	ui.text_edit_set(&pane.composer.area, "a draft")
	queue_edit(app, pane, "i")
	ui.text_edit_set(&pane.composer.area, "later, better")
	submit_prompt(app, pane)
	testing.expect(t, !queue_editing(app, pane))
	testing.expect_value(t, ui.text_edit_string(&pane.composer.area), "a draft")
	testing.expect_value(t, queue_find(app, pane, "i").act, Queue_Act.Replacing)
	testing.expect_value(t, bench_count(.Prompt), 0)   // (out first: it cannot go twice)
	replaced(t, app)
	testing.expect(t, queue_find(app, pane, "i") == nil)
	r := bench_take(t, .Prompt)
	testing.expect(t, strings.contains(r.body, "later, better"))
	testing.expect(t, strings.contains(r.body, `"delivery":"queue"`))
	testing.expect(t, strings.contains(r.body, `"resume":false`), "it does not start a run of its own")
}

@(test)
a_steered_message_edited_stays_steered :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	pane := main_pane(app)
	running(app, "s")
	enqueued(app, "i", "soon", "steer")
	queue_edit(app, pane, "i")
	ui.text_edit_set(&pane.composer.area, "sooner")
	submit_prompt(app, pane)
	replaced(t, app)
	testing.expect(t, strings.contains(bench_take(t, .Prompt).body, `"delivery":"steer"`))
}

@(test)
an_edit_that_could_not_take_the_item_out_changes_nothing :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	pane := main_pane(app)
	running(app, "s")
	enqueued(app, "i", "later", "queue")
	queue_edit(app, pane, "i")
	ui.text_edit_set(&pane.composer.area, "better")
	attach(app, "a.png")
	submit_prompt(app, pane)
	bench_lost(app, bench_take(t, .Queue_Replace))
	testing.expect_value(t, ui.text_edit_string(&pane.composer.area), "better")
	testing.expect_value(t, len(pane.composer.attachments), 1)
	testing.expect_value(t, queue_find(app, pane, "i").act, Queue_Act.None)
	testing.expect_value(t, bench_count(.Prompt), 0)
}

@(test)
an_edit_whose_prompt_fails_comes_back :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	pane := main_pane(app)
	running(app, "s")
	enqueued(app, "i", "later", "queue")
	queue_edit(app, pane, "i")
	ui.text_edit_set(&pane.composer.area, "better")
	submit_prompt(app, pane)
	replaced(t, app)
	bench_lost(app, bench_take(t, .Prompt))
	testing.expect_value(t, ui.text_edit_string(&pane.composer.area), "better")
}

@(test)
what_is_delivered_during_an_edit_leaves_the_text_in_the_composer :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	pane := main_pane(app)
	running(app, "s")
	enqueued(app, "i", "later", "queue")
	queue_edit(app, pane, "i")
	ui.text_edit_set(&pane.composer.area, "better")
	delivered(app, "i")
	testing.expect(t, !queue_editing(app, pane))
	testing.expect_value(t, ui.text_edit_string(&pane.composer.area), "better")
	testing.expect_value(t, len(pane.chat.messages), 1)
}

// DELETE of what was delivered answers 204 all the same: it must not go a second time.
@(test)
what_is_delivered_as_it_is_replaced_does_not_go_twice :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	pane := main_pane(app)
	running(app, "s")
	enqueued(app, "i", "later", "queue")
	queue_edit(app, pane, "i")
	ui.text_edit_set(&pane.composer.area, "better")
	submit_prompt(app, pane)
	r := bench_take(t, .Queue_Replace)
	delivered(app, "i")
	bench_answer(app, r, 204, "")
	testing.expect_value(t, bench_count(.Prompt), 0)
	testing.expect_value(t, ui.text_edit_string(&pane.composer.area), "better")
}

// The two connections have no order between them: the 204 comes first, or the stream is down. The stored message says it.
@(test)
what_is_delivered_before_a_204_the_stream_is_late_for_does_not_go_twice :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	pane := main_pane(app)
	running(app, "s")
	enqueued(app, "i", "later", "queue")
	queue_edit(app, pane, "i")
	ui.text_edit_set(&pane.composer.area, "better")
	submit_prompt(app, pane)
	bench_answer(app, bench_take(t, .Queue_Replace), 204, "")
	testing.expect_value(t, bench_count(.Prompt), 0)
	r := bench_take(t, .Queue_Check)
	testing.expect(t, strings.has_suffix(strings.split(r.path, "?", context.temp_allocator)[0], "/api/session/s/message/i"))
	delivered(app, "i")
	bench_answer(app, r, 200, `{"data":{"id":"i","type":"user"}}`)
	testing.expect_value(t, bench_count(.Prompt), 0)
	testing.expect_value(t, ui.text_edit_string(&pane.composer.area), "better")
}

@(test)
a_session_left_before_the_204_does_not_send_what_was_delivered :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	pane := main_pane(app)
	running(app, "s")
	enqueued(app, "i", "later", "queue")
	queue_edit(app, pane, "i")
	ui.text_edit_set(&pane.composer.area, "better")
	submit_prompt(app, pane)
	r := bench_take(t, .Queue_Replace)
	delivered(app, "i")
	show(app, "other")   // (what the stream said of "s" goes with it)
	bench_answer(app, r, 204, "")
	bench_answer(app, bench_take(t, .Queue_Check), 200, `{"data":{"id":"i","type":"user"}}`)
	testing.expect_value(t, bench_count(.Prompt), 0)
}

@(test)
a_check_that_cannot_answer_brings_the_text_back :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	pane := main_pane(app)
	running(app, "s")
	enqueued(app, "i", "later", "queue")
	queue_edit(app, pane, "i")
	ui.text_edit_set(&pane.composer.area, "better")
	submit_prompt(app, pane)
	bench_answer(app, bench_take(t, .Queue_Replace), 204, "")
	bench_lost(app, bench_take(t, .Queue_Check))
	testing.expect_value(t, bench_count(.Prompt), 0)
	testing.expect_value(t, ui.text_edit_string(&pane.composer.area), "better")
}

@(test)
leaving_a_session_or_a_server_cancels_the_edit :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	pane := main_pane(app)
	running(app, "s")
	enqueued(app, "i", "later", "queue")
	ui.text_edit_set(&pane.composer.area, "a draft")
	queue_edit(app, pane, "i")
	show(app, "other")
	testing.expect(t, !queue_editing(app, pane))
	testing.expect_value(t, ui.text_edit_string(&pane.composer.area), "")   // (the draft is the session's: it waits there)
	show(app, "s")
	testing.expect_value(t, ui.text_edit_string(&pane.composer.area), "a draft")
	defer drafts_destroy(app)

	running(app, "s")
	enqueued(app, "i", "later", "queue")
	queue_edit(app, pane, "i")
	queue_forget(app)
	testing.expect(t, !queue_editing(app, pane))
	testing.expect_value(t, len(pane.queue.items), 0)
	testing.expect_value(t, pane.queue.read.state, remote.State.Idle)
}

////////////////////////////////
// A run interrupted

@(test)
what_is_queued_stays_parked_when_a_run_is_interrupted :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	pane := main_pane(app)
	running(app, "s")
	enqueued(app, "i", "later", "queue")
	bench_event(app, `{"type":"session.execution.interrupted","data":{"sessionID":"s"}}`)
	bench_answer(app, bench_take(t, .Inbox), 200, listed(item_json("i", "later", "queue")))
	testing.expect_value(t, bench_count(.Inbox_Take), 0)
	testing.expect_value(t, len(pane.queue.items), 1)
	queue_steer(app, pane, "i")
	testing.expect_value(t, bench_count(.Queue_Steer), 1)   // (one word and it goes)
}

// Stored, a file is its data: sent as it was stored, the server refused it.
@(test)
what_was_steered_goes_on_after_an_interruption_as_a_prompt_can :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	pane := main_pane(app)
	running(app, "s")
	enqueued(app, "i", "soon", "steer", IMAGE_FILE)
	bench_event(app, `{"type":"session.execution.interrupted","data":{"sessionID":"s"}}`)
	bench_answer(app, bench_take(t, .Inbox), 200, fmt.tprintf(`{{"data":[{{"id":"i","type":"user","delivery":"steer","time":{{"created":1}},"payload":{{"text":"soon"%s}}}}]}}`, IMAGE_FILE))
	r := bench_take(t, .Inbox_Take)
	testing.expect(t, strings.contains(r.body, `"uri":"data:image/png;base64,AAAA"`), r.body)
	testing.expect(t, !strings.contains(r.body, `"mime"`), r.body)
	bench_answer(app, r, 204, "")
	testing.expect(t, queue_find(app, pane, "i") == nil)
	testing.expect_value(t, bench_count(.Prompt), 1)
}

////////////////////////////////
// The Statistics panel

// The Statistics and the Preview open where the other is: one place at the conversation's right, a tab each.
@(test)
statistics_and_the_preview_share_their_place :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	vs := &app.program_views
	show(app, "s")
	stats_open(app)
	testing.expect(t, ui.view_is_open(vs, STATS_VIEW))
	testing.expect_value(t, ui.view_presentation(vs, STATS_VIEW), ui.View_Presentation.Panel)
	testing.expect(t, !ui.view_is_open(vs, PREVIEW_VIEW), "the Preview is not opened with them")
	app.preview.open = true
	ui.view_open(vs, PREVIEW_VIEW, app)
	preview_close(app)
	testing.expect(t, ui.view_is_open(vs, STATS_VIEW), "the Preview closed, they stay")
	testing.expect(t, !ui.view_is_open(vs, PREVIEW_VIEW))
}

@(test)
the_pill_toggles_and_brings_up :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	vs := &app.program_views
	show(app, "s")
	stats_toggle(app)
	testing.expect(t, app.stats.open && ui.view_is_open(vs, STATS_VIEW))
	// (a panel not built in the last frame is a tab under another: the pill brings it up, it does not close it)
	app.stats.built = false
	stats_toggle(app)
	testing.expect(t, app.stats.open && ui.view_is_open(vs, STATS_VIEW), "under the other tab, it comes up")
	app.stats.built = true
	stats_toggle(app)
	testing.expect(t, !app.stats.open)
	testing.expect(t, !ui.view_is_open(vs, STATS_VIEW))
}

@(test)
statistics_do_not_block_the_keys :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	show(app, "s")
	stats_open(app)
	testing.expect(t, !overlay_open(app))
	testing.expect(t, command_keyed(app, command_find("session.new")))
}

@(private = "file")
CONTEXT :: `{"data":[
	{"id":"m0","type":"model-switched","time":{"created":1}},
	{"id":"u","type":"user","text":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","time":{"created":1},"files":[{"data":"AAAA","mime":"image/png","name":"a.png","source":{"type":"inline"}}]},
	{"id":"m1","type":"assistant","agent":"build","model":{"id":"mod","providerID":"p"},"time":{"created":2},
	 "tokens":{"input":3000,"output":10,"reasoning":0,"cache":{"read":7000,"write":0}},
	 "content":[{"type":"reasoning","text":"bbbbbbbb"},{"type":"text","text":"cccc"},
	            {"type":"tool","id":"t","name":"read","time":{"created":2},"state":{"status":"completed","input":{"filePath":"a.txt"},"content":[{"type":"text","text":"dddd"}]}}]},
	{"id":"i","type":"idle","outcome":"succeeded","time":{"created":3}}
]}`

@(test)
the_context_says_what_fills_it :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	show(app, "s")
	stats_open(app)
	r := bench_take(t, .Context)
	testing.expect_value(t, r.path, "/api/session/s/context")
	bench_answer(app, r, 200, CONTEXT)
	x := &app.stats.session_context
	testing.expect_value(t, x.total, 10000)
	testing.expect_value(t, x.model, "mod")
	testing.expect(t, len(x.groups) >= 4)
	testing.expect_value(t, x.groups[0].name, "Attached files")   // (the largest first)
	sum := 0.0
	found := false
	for g in x.groups {
		sum += g.tokens
		if g.name == "Tool: read" {
			found = true
			testing.expect_value(t, g.items[0].name, "a.txt")
			testing.expect(t, strings.contains(g.items[0].text, "dddd"), "what it read can be read")
		}
	}
	testing.expect(t, found)
	testing.expect_value(t, sum + x.unlisted, 10000)
}

@(test)
estimates_never_add_up_to_more_than_the_step_sent :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	show(app, "s")
	stats_open(app)
	bench_answer(app, bench_take(t, .Context), 200, `{"data":[{"id":"m","type":"assistant","model":{"id":"x"},"tokens":{"input":2,"cache":{"read":0}},"content":[{"type":"text","text":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}]}]}`)
	x := &app.stats.session_context
	testing.expect_value(t, x.groups[0].tokens, 2)
	testing.expect_value(t, x.unlisted, 0)
}

@(test)
the_context_is_read_when_a_step_ends_and_only_with_the_panel_open :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	show(app, "s")
	STEP :: `{"type":"session.step.ended","data":{"sessionID":"s","assistantMessageID":"m","finish":"stop","tokens":{"input":1,"output":1,"reasoning":0,"cache":{"read":0}}}}`
	bench_event(app, STEP)
	testing.expect_value(t, ui.deferred_in_ms(&app.cx.due[.Context]), 0)
	stats_open(app)
	bench_clear(app)
	bench_event(app, STEP)
	testing.expect(t, ui.deferred_in_ms(&app.cx.due[.Context]) > 0, "a wake is due")
	testing.expect_value(t, bench_count(.Context), 0)   // (once, a little after)
	bench_clock += CONTEXT_DEBOUNCE_MS + 1
	deferred_tick(app)
	testing.expect_value(t, bench_count(.Context), 1)
	deferred_tick(app)
	testing.expect_value(t, bench_count(.Context), 1)   // (nothing at rest)
}

@(test)
the_panel_follows_the_session_shown :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	show(app, "a")
	stats_open(app)
	old := bench_take(t, .Context)
	show(app, "b")
	stats_follow(app)
	testing.expect(t, strings.contains(bench_take(t, .Context).path, "/session/b/"))
	bench_answer(app, old, 200, CONTEXT)
	testing.expect_value(t, len(app.stats.session_context.groups), 0)   // (an earlier session's says nothing here)
	stats_follow(app)
	testing.expect_value(t, bench_count(.Context), 0)
}

@(test)
leaving_a_server_closes_the_panel :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	show(app, "a")
	stats_open(app)
	bench_answer(app, bench_take(t, .Context), 200, CONTEXT)
	stats_forget(app)
	testing.expect(t, !app.stats.open)
	testing.expect(t, !ui.view_is_open(&app.program_views, STATS_VIEW))
	testing.expect_value(t, len(app.stats.session_context.groups), 0)
	testing.expect_value(t, app.stats.context_read.state, remote.State.Idle)
}

// A steered message stuck behind a long step: Send now interrupts the run, and what was steered goes as a prompt at once.
// Nothing running: it goes now.
@(test)
send_now_interrupts_the_step_a_steered_message_waits_behind :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	pane := main_pane(app)
	running(app, "s")
	enqueued(app, "q", "later", "queue")
	queue_send_now(app, pane, "q")
	testing.expect_value(t, bench_count(.Action), 0)   // (only what is steered)
	enqueued(app, "i", "now please", "steer")
	queue_send_now(app, pane, "i")
	queue_send_now(app, pane, "i")
	r := bench_take(t, .Action)
	testing.expect_value(t, r.path, "/api/session/s/interrupt")
	testing.expect_value(t, bench_count(.Action), 0)   // (once)
	testing.expect_value(t, queue_find(app, pane, "i").act, Queue_Act.Sending)
	bench_answer(app, r, 204, "")
	bench_event(app, `{"type":"session.execution.interrupted","data":{"sessionID":"s"}}`)
	bench_answer(app, bench_take(t, .Inbox), 200, listed(item_json("q", "later", "queue"), item_json("i", "now please", "steer")))
	take := bench_take(t, .Inbox_Take)
	testing.expect_value(t, take.path, "/api/session/s/inbox/i")
	bench_answer(app, take, 204, "")
	p := bench_take(t, .Prompt)
	testing.expect(t, strings.contains(p.body, `"text":"now please"`), p.body)
	testing.expect(t, queue_find(app, pane, "i") == nil, "out of the list")
	testing.expect(t, queue_find(app, pane, "q") != nil, "what was queued stays")

	// nothing runs any more (the run ended without taking it): it goes now, without an interruption
	bench_event(app, `{"type":"session.execution.started","data":{"sessionID":"s"}}`)
	enqueued(app, "j", "parked", "steer")
	pane.chat.busy = false
	queue_send_now(app, pane, "j")
	testing.expect_value(t, bench_count(.Action), 0)
	testing.expect_value(t, bench_count(.Inbox), 1)
}
