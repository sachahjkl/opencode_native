package occ

// What waits in the inbox, and the Statistics panel, on the bench of the answers (answers_test.odin): requests kept, answered by the test in
// the order it wants, events given by hand. The shapes are the server's (2.2.5): what the spec does not say was read in its code.

import "base:runtime"
import "core:fmt"
import "core:strings"
import "core:testing"
import "gt:config"
import "gt:ui"

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
	append(&app.cx.attachments, Attachment{name = strings.clone(name), uri = strings.clone("data:image/png;base64,AAAA")})
}

////////////////////////////////
// How a prompt goes

@(test)
while_a_turn_runs_enter_sends_now_and_the_other_key_queues :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	for d in PREF_DEFS {
		if d.name == "conversation.while_running" { testing.expect_value(t, d.default.s, "steer") }   // (a new reader gets this)
	}
	app := bench_new()
	running(app, "s")
	pref_set(app, "conversation.while_running", "steer")
	ui.area_set(&app.composer, "now")
	submit_prompt(app)
	testing.expect(t, strings.contains(bench_take(t, .Prompt).body, `"delivery":"steer"`))

	ui.area_set(&app.composer, "later")
	submit_prompt(app, true)
	r := bench_take(t, .Prompt)
	testing.expect(t, strings.contains(r.body, `"delivery":"queue"`), r.body)
	bench_answer(app, r, 200, fmt.tprintf(`{{"data":%s}}`, item_json("i1", "later", "queue")))

	pref_set(app, "conversation.while_running", "queue")
	ui.area_set(&app.composer, "swapped")
	submit_prompt(app)
	testing.expect(t, strings.contains(bench_take(t, .Prompt).body, `"delivery":"queue"`), "the preference swaps them")
	ui.area_set(&app.composer, "swapped too")
	submit_prompt(app, true)
	testing.expect(t, strings.contains(bench_take(t, .Prompt).body, `"delivery":"steer"`))
}

@(test)
when_nothing_runs_a_prompt_goes_as_it_always_did :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	show(app, "s")
	ui.area_set(&app.composer, "hello")
	submit_prompt(app, true)
	testing.expect(t, !strings.contains(bench_take(t, .Prompt).body, "delivery"), "no word of it")
	enqueued(app, "i", "hello", "steer")
	testing.expect_value(t, len(app.chat.messages), 1)
	testing.expect_value(t, len(app.cx.queue.items), 0)
}

@(test)
a_slash_command_queues_too :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	slash_load(app, []Slash{{strings.clone("review"), strings.clone("")}})
	running(app, "s")
	ui.area_set(&app.composer, "/review all")
	submit_prompt(app)
	testing.expect(t, strings.contains(bench_take(t, .Prompt).body, `"delivery":"queue"`))
}

@(test)
what_failed_to_queue_comes_back_whole :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	running(app, "s")
	ui.area_set(&app.composer, "later")
	attach(app, "a.png")
	submit_prompt(app)
	testing.expect_value(t, ui.area_string(&app.composer), "")
	bench_lost(app, bench_take(t, .Prompt))
	testing.expect_value(t, ui.area_string(&app.composer), "later")
	testing.expect_value(t, len(app.cx.attachments), 1)
}

////////////////////////////////
// Every message that waits is in the list, and nowhere else

// During a run, what was sent showed in the conversation as sent, or not at all, and an image changed that: the list is the one place.
@(test)
what_waits_is_in_the_list_with_an_image_or_without :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	running(app, "s")
	enqueued(app, "a", "text only", "steer")
	enqueued(app, "b", "with an image", "steer", IMAGE_FILE)
	enqueued(app, "c", "for the end", "queue")
	testing.expect_value(t, len(app.chat.messages), 0)
	testing.expect_value(t, len(app.cx.queue.items), 3)
	testing.expect_value(t, app.cx.queue.items[1].files, 1)
	testing.expect_value(t, app.cx.queue.items[2].delivery, Delivery.Queue)
}

@(test)
a_message_delivered_shows_once_in_its_place :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	running(app, "s")
	bench_event(app, `{"type":"session.step.started","data":{"sessionID":"s","assistantMessageID":"m1","agent":"a","model":{"id":"x","providerID":"p"},"started":1}}`)
	enqueued(app, "i", "later", "queue", IMAGE_FILE)
	delivered(app, "i")
	delivered(app, "i")
	testing.expect_value(t, len(app.cx.queue.items), 0)
	testing.expect_value(t, len(app.chat.messages), 2)
	m := app.chat.messages[1]
	testing.expect_value(t, m.id, "i")
	testing.expect_value(t, m.kind, Msg_Kind.User)
	testing.expect_value(t, m.text, "later")
	testing.expect_value(t, len(m.images), 1)
	testing.expect_value(t, m.created, 9)
	bench_event(app, `{"type":"session.step.started","data":{"sessionID":"s","assistantMessageID":"m2","agent":"a","model":{"id":"x","providerID":"p"},"started":2}}`)
	testing.expect_value(t, app.chat.messages[2].id, "m2")   // (what follows goes after it)
}

@(test)
a_page_that_holds_what_waits_does_not_send_it :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	running(app, "s")
	enqueued(app, "i", "later", "queue")
	load_messages(app, "s")
	bench_answer(app, bench_take(t, .Messages), 200, `{"data":[{"id":"i","type":"user","text":"later","time":{"created":1}}],"cursor":{"next":""}}`)
	testing.expect_value(t, len(app.chat.messages), 0)
	delivered(app, "i")
	load_messages(app, "s")
	bench_answer(app, bench_take(t, .Messages), 200, `{"data":[{"id":"i","type":"user","text":"later","time":{"created":1}}],"cursor":{"next":""}}`)
	testing.expect_value(t, len(app.chat.messages), 1)
}

// The prompt's answer says it too: with the stream late, or down, what was sent does not vanish.
@(test)
the_answer_to_a_prompt_lists_it_once :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	running(app, "s")
	ui.area_set(&app.composer, "later")
	submit_prompt(app)
	bench_answer(app, bench_take(t, .Prompt), 200, fmt.tprintf(`{{"data":%s}}`, item_json("i", "later", "queue")))
	testing.expect_value(t, len(app.cx.queue.items), 1)
	enqueued(app, "i", "later", "queue")
	testing.expect_value(t, len(app.cx.queue.items), 1)
}

@(test)
what_was_delivered_before_the_prompts_answer_is_not_listed_again :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	running(app, "s")
	ui.area_set(&app.composer, "later")
	submit_prompt(app)
	r := bench_take(t, .Prompt)
	enqueued(app, "i", "later", "queue")
	delivered(app, "i")
	bench_answer(app, r, 200, fmt.tprintf(`{{"data":%s}}`, item_json("i", "later", "queue")))
	testing.expect_value(t, len(app.cx.queue.items), 0)
	testing.expect_value(t, len(app.chat.messages), 1)
}

////////////////////////////////
// The list is the server's

@(test)
the_list_is_read_on_opening_and_on_reconnecting :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	open_chat(app, "s")
	r := bench_take(t, .Queue_List)
	testing.expect(t, strings.contains(r.path, "/api/session/s/inbox"))
	bench_answer(app, r, 200, listed(item_json("a", "one", "queue"), item_json("b", "two", "steer")))
	testing.expect_value(t, len(app.cx.queue.items), 2)
	bench_clear(app)
	stream_down(app, 0)
	stream_up(app)
	bench_answer(app, bench_take(t, .Queue_List), 200, listed(item_json("b", "two", "queue")))
	testing.expect_value(t, len(app.cx.queue.items), 1)
	testing.expect_value(t, app.cx.queue.items[0].id, "b")
	testing.expect_value(t, app.cx.queue.items[0].delivery, Delivery.Queue)
}

@(test)
a_stale_list_does_not_undo_what_the_stream_said :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	show(app, "s")
	queue_read(app)
	first := bench_take(t, .Queue_List)
	bench_answer(app, first, 200, listed(item_json("gone", "x", "queue"), item_json("moved", "y", "queue")))
	queue_read(app)
	stale := bench_take(t, .Queue_List)
	bench_event(app, `{"type":"session.execution.started","data":{"sessionID":"s"}}`)
	delivered(app, "gone")
	bench_event(app, `{"type":"session.inbox.delivery.changed","data":{"sessionID":"s","inboxID":"moved","delivery":"steer"}}`)
	enqueued(app, "new", "z", "queue")
	bench_answer(app, stale, 200, listed(item_json("gone", "x", "queue"), item_json("moved", "y", "queue")))
	testing.expect_value(t, len(app.cx.queue.items), 2)
	testing.expect(t, queue_find(app, "gone") == nil, "delivered stays delivered")
	testing.expect_value(t, queue_find(app, "moved").delivery, Delivery.Steer)
	testing.expect(t, queue_find(app, "new") != nil, "what came since stays")
}

@(test)
another_clients_changes_show :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	running(app, "s")
	enqueued(app, "i", "later", "queue")
	bench_event(app, `{"type":"session.inbox.cancelled","data":{"sessionID":"s","inboxID":"i"}}`)
	testing.expect_value(t, len(app.cx.queue.items), 0)
	testing.expect_value(t, len(app.chat.messages), 0)
}

@(test)
a_failed_reading_can_be_tried_again_and_a_refusal_says_nothing :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	open_chat(app, "s")
	bench_lost(app, bench_take(t, .Queue_List))
	testing.expect_value(t, app.cx.queue.read.state, Load_State.Failed)
	queue_read(app)
	bench_answer(app, bench_take(t, .Queue_List), 404, `{"message":"no"}`)
	testing.expect_value(t, app.cx.queue.read.state, Load_State.Refused)
}

@(test)
what_waits_for_a_session_stays_with_it :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	running(app, "s")
	enqueued(app, "i", "later", "queue")
	queue_read(app)
	old := bench_take(t, .Queue_List)
	show(app, "other")
	testing.expect_value(t, len(app.cx.queue.items), 0)
	bench_answer(app, old, 200, listed(item_json("i", "later", "queue")))
	testing.expect_value(t, len(app.cx.queue.items), 0)   // (not this session's: its reading was given up)
	bench_event(app, `{"type":"session.inbox.enqueued","data":{"sessionID":"s","inboxID":"j","item":{"type":"user","delivery":"queue","payload":{"text":"x"}}}}`)
	testing.expect_value(t, len(app.cx.queue.items), 0)
	open_chat(app, "s")
	bench_answer(app, bench_take(t, .Queue_List), 200, listed(item_json("i", "later", "queue"), item_json("j", "x", "queue")))
	testing.expect_value(t, len(app.cx.queue.items), 2)
}

////////////////////////////////
// What can be done to an item

@(test)
one_action_at_a_time_on_an_item :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	running(app, "s")
	enqueued(app, "i", "later", "queue")
	queue_remove(app, "i")
	queue_remove(app, "i")
	queue_send_now(app, "i")
	queue_edit(app, "i")
	testing.expect_value(t, bench_count(.Queue_Cancel), 1)
	testing.expect_value(t, bench_count(.Queue_Steer), 0)
	testing.expect(t, !queue_editing(app))
	bench_answer(app, bench_take(t, .Queue_Cancel), 204, "")
	testing.expect_value(t, len(app.cx.queue.items), 0)
}

@(test)
send_now_changes_the_delivery_and_leaves_it_until_it_is_delivered :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	running(app, "s")
	enqueued(app, "i", "later", "queue")
	queue_send_now(app, "i")
	r := bench_take(t, .Queue_Steer)
	testing.expect_value(t, r.method, "PATCH")
	testing.expect_value(t, r.body, `{"delivery":"steer"}`)
	bench_answer(app, r, 204, "")
	it := queue_find(app, "i")
	testing.expect_value(t, it.delivery, Delivery.Steer)
	testing.expect_value(t, it.act, Queue_Act.None)
	testing.expect_value(t, len(app.chat.messages), 0)
	queue_send_now(app, "i")
	testing.expect_value(t, bench_count(.Queue_Steer), 0)   // (only what is queued)
}

@(test)
send_now_refused_reads_the_list_again :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	running(app, "s")
	enqueued(app, "i", "later", "queue")
	queue_send_now(app, "i")
	bench_answer(app, bench_take(t, .Queue_Steer), 409, `{"message":"Pending input cannot change to steer"}`)
	testing.expect_value(t, queue_find(app, "i").act, Queue_Act.None)
	testing.expect_value(t, bench_count(.Queue_List), 1)
}

@(test)
editing_brings_the_message_back_and_cancel_changes_nothing :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	running(app, "s")
	enqueued(app, "i", "later", "queue", IMAGE_FILE)
	ui.area_set(&app.composer, "a draft")
	attach(app, "draft.png")
	queue_edit(app, "i")
	testing.expect(t, queue_editing(app))
	testing.expect_value(t, ui.area_string(&app.composer), "later")
	testing.expect_value(t, len(app.cx.attachments), 1)
	testing.expect_value(t, app.cx.attachments[0].name, "a.png")
	testing.expect(t, strings.has_prefix(app.cx.attachments[0].uri, "data:image/png;base64,"), "what it was stored as is a uri again")
	queue_edit_end(app, .Cancel)
	testing.expect(t, !queue_editing(app))
	testing.expect_value(t, ui.area_string(&app.composer), "a draft")
	testing.expect_value(t, app.cx.attachments[0].name, "draft.png")
	testing.expect_value(t, bench_count(.Queue_Replace), 0)
	testing.expect(t, queue_find(app, "i") != nil)
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
	running(app, "s")
	enqueued(app, "i", "later", "queue")
	ui.area_set(&app.composer, "a draft")
	queue_edit(app, "i")
	ui.area_set(&app.composer, "later, better")
	submit_prompt(app)
	testing.expect(t, !queue_editing(app))
	testing.expect_value(t, ui.area_string(&app.composer), "a draft")
	testing.expect_value(t, queue_find(app, "i").act, Queue_Act.Replacing)
	testing.expect_value(t, bench_count(.Prompt), 0)   // (out first: it cannot go twice)
	replaced(t, app)
	testing.expect(t, queue_find(app, "i") == nil)
	r := bench_take(t, .Prompt)
	testing.expect(t, strings.contains(r.body, "later, better"))
	testing.expect(t, strings.contains(r.body, `"delivery":"queue"`))
	testing.expect(t, strings.contains(r.body, `"resume":false`), "it does not start a run of its own")
}

@(test)
a_steered_message_edited_stays_steered :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	running(app, "s")
	enqueued(app, "i", "soon", "steer")
	queue_edit(app, "i")
	ui.area_set(&app.composer, "sooner")
	submit_prompt(app)
	replaced(t, app)
	testing.expect(t, strings.contains(bench_take(t, .Prompt).body, `"delivery":"steer"`))
}

@(test)
an_edit_that_could_not_take_the_item_out_changes_nothing :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	running(app, "s")
	enqueued(app, "i", "later", "queue")
	queue_edit(app, "i")
	ui.area_set(&app.composer, "better")
	attach(app, "a.png")
	submit_prompt(app)
	bench_lost(app, bench_take(t, .Queue_Replace))
	testing.expect_value(t, ui.area_string(&app.composer), "better")
	testing.expect_value(t, len(app.cx.attachments), 1)
	testing.expect_value(t, queue_find(app, "i").act, Queue_Act.None)
	testing.expect_value(t, bench_count(.Prompt), 0)
}

@(test)
an_edit_whose_prompt_fails_comes_back :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	running(app, "s")
	enqueued(app, "i", "later", "queue")
	queue_edit(app, "i")
	ui.area_set(&app.composer, "better")
	submit_prompt(app)
	replaced(t, app)
	bench_lost(app, bench_take(t, .Prompt))
	testing.expect_value(t, ui.area_string(&app.composer), "better")
}

@(test)
what_is_delivered_during_an_edit_leaves_the_text_in_the_composer :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	running(app, "s")
	enqueued(app, "i", "later", "queue")
	queue_edit(app, "i")
	ui.area_set(&app.composer, "better")
	delivered(app, "i")
	testing.expect(t, !queue_editing(app))
	testing.expect_value(t, ui.area_string(&app.composer), "better")
	testing.expect_value(t, len(app.chat.messages), 1)
}

// DELETE of what was delivered answers 204 all the same: it must not go a second time.
@(test)
what_is_delivered_as_it_is_replaced_does_not_go_twice :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	running(app, "s")
	enqueued(app, "i", "later", "queue")
	queue_edit(app, "i")
	ui.area_set(&app.composer, "better")
	submit_prompt(app)
	r := bench_take(t, .Queue_Replace)
	delivered(app, "i")
	bench_answer(app, r, 204, "")
	testing.expect_value(t, bench_count(.Prompt), 0)
	testing.expect_value(t, ui.area_string(&app.composer), "better")
}

// The two connections have no order between them: the 204 comes first, or the stream is down. The stored message says it.
@(test)
what_is_delivered_before_a_204_the_stream_is_late_for_does_not_go_twice :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	running(app, "s")
	enqueued(app, "i", "later", "queue")
	queue_edit(app, "i")
	ui.area_set(&app.composer, "better")
	submit_prompt(app)
	bench_answer(app, bench_take(t, .Queue_Replace), 204, "")
	testing.expect_value(t, bench_count(.Prompt), 0)
	r := bench_take(t, .Queue_Check)
	testing.expect(t, strings.has_suffix(strings.split(r.path, "?", context.temp_allocator)[0], "/api/session/s/message/i"))
	delivered(app, "i")
	bench_answer(app, r, 200, `{"data":{"id":"i","type":"user"}}`)
	testing.expect_value(t, bench_count(.Prompt), 0)
	testing.expect_value(t, ui.area_string(&app.composer), "better")
}

@(test)
a_session_left_before_the_204_does_not_send_what_was_delivered :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	running(app, "s")
	enqueued(app, "i", "later", "queue")
	queue_edit(app, "i")
	ui.area_set(&app.composer, "better")
	submit_prompt(app)
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
	running(app, "s")
	enqueued(app, "i", "later", "queue")
	queue_edit(app, "i")
	ui.area_set(&app.composer, "better")
	submit_prompt(app)
	bench_answer(app, bench_take(t, .Queue_Replace), 204, "")
	bench_lost(app, bench_take(t, .Queue_Check))
	testing.expect_value(t, bench_count(.Prompt), 0)
	testing.expect_value(t, ui.area_string(&app.composer), "better")
}

@(test)
leaving_a_session_or_a_server_cancels_the_edit :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	running(app, "s")
	enqueued(app, "i", "later", "queue")
	ui.area_set(&app.composer, "a draft")
	queue_edit(app, "i")
	show(app, "other")
	testing.expect(t, !queue_editing(app))
	testing.expect_value(t, ui.area_string(&app.composer), "")   // (the draft is the session's: it waits there)
	show(app, "s")
	testing.expect_value(t, ui.area_string(&app.composer), "a draft")
	defer drafts_destroy(app)

	running(app, "s")
	enqueued(app, "i", "later", "queue")
	queue_edit(app, "i")
	queue_forget(app)
	testing.expect(t, !queue_editing(app))
	testing.expect_value(t, len(app.cx.queue.items), 0)
	testing.expect_value(t, app.cx.queue.read.state, Load_State.Idle)
}

////////////////////////////////
// A run interrupted

@(test)
what_is_queued_stays_parked_when_a_run_is_interrupted :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	running(app, "s")
	enqueued(app, "i", "later", "queue")
	bench_event(app, `{"type":"session.execution.interrupted","data":{"sessionID":"s"}}`)
	bench_answer(app, bench_take(t, .Inbox), 200, listed(item_json("i", "later", "queue")))
	testing.expect_value(t, bench_count(.Inbox_Take), 0)
	testing.expect_value(t, len(app.cx.queue.items), 1)
	queue_send_now(app, "i")
	testing.expect_value(t, bench_count(.Queue_Steer), 1)   // (one word and it goes)
}

// Stored, a file is its data: sent as it was stored, the server refused it.
@(test)
what_was_steered_goes_on_after_an_interruption_as_a_prompt_can :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	running(app, "s")
	enqueued(app, "i", "soon", "steer", IMAGE_FILE)
	bench_event(app, `{"type":"session.execution.interrupted","data":{"sessionID":"s"}}`)
	bench_answer(app, bench_take(t, .Inbox), 200, fmt.tprintf(`{{"data":[{{"id":"i","type":"user","delivery":"steer","time":{{"created":1}},"payload":{{"text":"soon"%s}}}}]}}`, IMAGE_FILE))
	r := bench_take(t, .Inbox_Take)
	testing.expect(t, strings.contains(r.body, `"uri":"data:image/png;base64,AAAA"`), r.body)
	testing.expect(t, !strings.contains(r.body, `"mime"`), r.body)
	bench_answer(app, r, 204, "")
	testing.expect(t, queue_find(app, "i") == nil)
	testing.expect_value(t, bench_count(.Prompt), 1)
}

////////////////////////////////
// The Statistics panel

@(private = "file")
same_stack :: proc(app: ^App) -> bool {
	a, b := ui.dock_leaf_of(&app.dock, u32(Panel.Stats)), ui.dock_leaf_of(&app.dock, u32(Panel.Preview))
	return a >= 0 && a == b
}

@(test)
statistics_join_the_preview_and_the_preview_joins_them :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	show(app, "s")
	app.preview.open = true
	dock_setup(app)
	stats_open(app)
	testing.expect(t, same_stack(app), "a tab of the Preview's stack")
	testing.expect(t, ui.dock_shown(&app.dock, u32(Panel.Stats)))
	panel_close(app, u32(Panel.Preview))
	testing.expect(t, ui.dock_has(&app.dock, u32(Panel.Stats)))
	app.preview.open = true
	dock_setup(app)
	testing.expect(t, same_stack(app), "the Preview comes back beside them")
	testing.expect(t, ui.dock_leaf_of(&app.dock, u32(Panel.Conversation)) != ui.dock_leaf_of(&app.dock, u32(Panel.Stats)))
}

@(test)
alone_they_open_where_the_preview_opens :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	show(app, "s")
	stats_open(app)
	got := ui.dock_format(&app.dock, panel_name, app)
	testing.expect(t, strings.contains(got, "x0.560"), got)   // (the default layout's width, not a new panel's)
	testing.expect(t, !strings.contains(got, "preview"), got)
}

@(test)
a_saved_layout_holds_them_and_does_not_open_them :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	pref_set(app, "layout.dock", "dock1 x0.500([*conversation] [*statistics preview])")
	dock_setup(app)
	testing.expect(t, !ui.dock_has(&app.dock, u32(Panel.Stats)), "closed: no tab")
	app.preview.open = true
	stats_open(app)
	testing.expect(t, same_stack(app))
}

@(test)
the_pill_toggles_and_brings_up :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	show(app, "s")
	app.preview.open = true
	dock_setup(app)
	stats_toggle(app)
	testing.expect(t, app.stats_open)
	ui.dock_activate(&app.dock, u32(Panel.Preview))
	stats_toggle(app)
	testing.expect(t, app.stats_open && ui.dock_shown(&app.dock, u32(Panel.Stats)), "under the other tab, it comes up")
	stats_toggle(app)
	testing.expect(t, !app.stats_open)
	testing.expect(t, !ui.dock_has(&app.dock, u32(Panel.Stats)))
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
	x := &app.cx.stats_context
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
	x := &app.cx.stats_context
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
	testing.expect_value(t, deferred_in_ms(&app.cx.due[.Context]), 0)
	stats_open(app)
	bench_clear(app)
	bench_event(app, STEP)
	testing.expect(t, deferred_in_ms(&app.cx.due[.Context]) > 0, "a wake is due")
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
	testing.expect_value(t, len(app.cx.stats_context.groups), 0)   // (an earlier session's says nothing here)
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
	testing.expect(t, !app.stats_open)
	testing.expect(t, !ui.dock_has(&app.dock, u32(Panel.Stats)))
	testing.expect_value(t, len(app.cx.stats_context.groups), 0)
	testing.expect_value(t, app.cx.context_read.state, Load_State.Idle)
}

// Sizes are saved by position: Statistics was the second dialog.
@(test)
a_saved_size_stays_with_its_dialog :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	pref_set(app, "layout.dialogs", "100x1 200x2 300x3 400x4 500x5 600x6 700x7")
	dialogs_track(app)
	testing.expect_value(t, app.cx.dialogs[.Settings].x, 100)
	testing.expect_value(t, app.cx.dialogs[.Help].x, 300)
	testing.expect_value(t, app.cx.dialogs[.Artifacts].x, 700)
	testing.expect_value(t, config.string_of(&app.cfg_prefs, "layout.dialogs"), "100x1 200x2 300x3 400x4 500x5 600x6 700x7")   // (nothing changed: nothing written)
}
