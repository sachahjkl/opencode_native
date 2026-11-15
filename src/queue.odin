// What waits in the session's inbox: messages written while a turn runs, the server's until they are delivered. "steer" goes in at
// the next step of the turn, "queue" when the turn ends, each in its turn. They have one place, the list over the composer: a
// message shows in the conversation only once delivered, with an image or without, so what waits never reads as sent. (A prompt
// sent while nothing runs goes at once: it does not wait, it shows in the conversation as it always did. model.odin apply_event.)
//
// The list is the server's: read when a session opens and when the stream comes back (chat_read), kept current by the events, so that it
// survives a restart and another client's changes. An answer replaces it, except what the stream said since it was asked for
// (Request.asked_at). Only the session shown is held here: the others keep theirs on the server, and show it when they open.
//
// The server can change an item's delivery, not its text: an item edited is taken out and queued again, and goes to the end. It
// stays in place until Enter, so that Cancel changes nothing. If it is delivered meanwhile, what was typed stays in the composer.
//
// Alt+Enter while a turn runs queues a prompt first: the others are admitted again behind it (queue_first_start).
//
// A run interrupted leaves what is queued parked: nothing here sends it. It stays in the list, which says so, with Steer.
// What is steered waits for the run's next step: Send now stops what the agent is doing and sends it at once (queue_send_now),
// as Escape then Enter would.
package ocn

import tk_json "gt:json"
import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:strconv"
import "core:strings"
import "gt:ui"
import lucide "gt:lucide"
import remote "gt:remote"
import i18n "gt:i18n"

Delivery :: enum u8 { Steer, Queue }

// What is on its way for an item: one thing at a time. (Moving: a reorder copies it, then cancels it: queue_first_start.)
Queue_Act :: enum u8 { None, Sending, Removing, Replacing, Moving }

Queue_Item :: struct {
	id, text: string,      // (owned)
	payload:  string,      // what the server holds, as JSON (owned)
	delivery: Delivery,
	files:    int,         // what goes with it
	skills:   bool,        // ... skills, which the composer cannot give back: it is not edited here
	act:      Queue_Act,
	born:     Seq,         // the stream's clock when it came (a list asked before that does not know it)
	changed:  Seq,         // ... when its delivery changed
}

// The item that the composer holds, and what the composer held before it (owned, id "": none).
Queue_Edit :: struct {
	id:       string,
	draft:    string,
	files:    [dynamic]Attachment,
	mentions: [dynamic]Mention,
}

Queue :: struct {
	session: string,   // whose it is (owned)
	items:   [dynamic]Queue_Item,
	gone:    Gone_List,   // what left it lately
	read:    remote.Remote,
	edit:    Queue_Edit,
	first:   Queue_First,
}

// Alt+Enter's reorder: one at a time (src/md/features/queue-first.md).
Queue_First_Phase :: enum u8 {
	Idle,
	Copying,       // the copy of moves[at] is on its way
	Cancelling,    // every copy is in: the cancel of moves[at]'s original is on its way
	Withdrawing,   // stopped or done: what is still on its way is awaited (pending, copying)
}

// A queued prompt that a reorder admits again, then cancels. (strings owned)
Queue_Move :: struct {
	original, copy: string,   // copy: the id minted for it before its POST (message_id_new); "": not sent yet
	payload:        string,   // the original's, as the reorder found it
	left:      bool,          // the original left by another way than its own cancel: its copy is a duplicate
	withdrawn: bool,          // the copy's DELETE is on its way, or answered
}

Queue_First :: struct {
	phase:   Queue_First_Phase,
	run:     u64,      // in the tags of its requests: an answer of another run is an orphan
	lead:    string,   // the prompt put first (owned)
	moves:   [dynamic]Queue_Move,
	at:      int,
	copying: bool,     // a copy's POST is on its way
	pending: int,      // the copies' DELETEs on their way
	outs:    [dynamic]u64,      // Alt+Enter's prompts on their way (Outgoing ids)
	waiting: [dynamic]string,   // ... admitted, waiting for the machine (owned)
}

// How the composer's prompt would go now. (Idle: nothing runs, it goes as it always did.)
Send_As :: enum u8 { Idle, Queue, Steer }

// `alt`: the other key (Ctrl+Enter). conversation.while_running says which one is Enter.
composer_send_as :: proc(app: ^App, pane: ^Chat_Pane, alt := false) -> Send_As {
	if pane.chat.id == "" || !pane.chat.busy { return .Idle }
	return app.prefs.steer_first != alt ? .Steer : .Queue
}

// The fields of a prompt that say so.
send_as_fields :: proc(as: Send_As) -> string {
	switch as {
	case .Idle:  return ""
	case .Queue: return `,"delivery":"queue"`
	case .Steer: return `,"delivery":"steer"`
	}
	return ""
}

delivery_of :: proc(s: string) -> Delivery { return s == "queue" ? .Queue : .Steer }

queue_find :: proc(app: ^App, pane: ^Chat_Pane, id: string) -> ^Queue_Item {
	for &it in pane.queue.items { if it.id == id { return &it } }
	return nil
}

// A message of the session shown that still waits: a page that has it does not say it was sent.
queue_holds :: proc(app: ^App, pane: ^Chat_Pane, id: string) -> bool {
	return pane.queue.session == pane.chat.id && queue_find(app, pane, id) != nil
}

queue_editing :: proc(app: ^App, pane: ^Chat_Pane) -> bool { return pane.queue.edit.id != "" }

// What changes here without an event still counts on the stream's clock: a list asked before it is older.
@(private = "file")
queue_tick :: proc(app: ^App) -> Seq {
	app.cx.stream_seq += 1
	return app.cx.stream_seq
}

@(private = "file")
item_free :: proc(it: Queue_Item) { delete(it.id); delete(it.text); delete(it.payload) }

// An item as the list, an event or a prompt's answer gives it: its type, its delivery, its payload.
@(private = "file")
item_of :: proc(id: string, v: json.Value, born: Seq) -> Queue_Item {
	payload := tk_json.get(v, "payload")
	data, _ := json.marshal(payload, allocator = context.temp_allocator)
	return {
		id = strings.clone(id), text = strings.clone(tk_json.text(payload, "text")), payload = strings.clone(string(data)),
		delivery = delivery_of(tk_json.text(v, "delivery")), files = len(tk_json.array(payload, "files")), skills = len(tk_json.array(payload, "skills")) > 0, born = born,
	}
}

// (once: an event and the answer to the prompt both say it)
queue_add :: proc(app: ^App, pane: ^Chat_Pane, id: string, v: json.Value, born: Seq) {
	q := &pane.queue
	if id == "" || q.session != pane.chat.id || queue_find(app, pane, id) != nil { return }
	if gone_find(&q.gone, id) != nil { return }
	append(&q.items, item_of(id, v, born))
}

// The answer to a prompt: the server has it. Should the stream be late or down, the list is right all the same.
queue_prompt_answered :: proc(app: ^App, pane: ^Chat_Pane, r: ^Request, v: json.Value) {
	session := r.tag
	item := tk_json.get(v, "data")
	defer queue_first_admitted(app, pane, r.out, tk_json.text(item, "id"))   // (whatever the list does with it: the reorder reads it again)
	if session != pane.chat.id || tk_json.text(item, "type") != "user" { return }
	if !pane.chat.busy && delivery_of(tk_json.text(item, "delivery")) == .Steer { return }   // (it goes at once)
	if queue_shown_as_sent(app, pane, tk_json.text(item, "id")) { return }
	queue_add(app, pane, tk_json.text(item, "id"), item, queue_tick(app))
}

// It left the list: delivered, cancelled, here or elsewhere.
queue_gone :: proc(app: ^App, pane: ^Chat_Pane, id: string, delivered: bool, at: Seq) {
	q := &pane.queue
	if id == "" { return }
	if q.edit.id == id {
		queue_edit_end(app, pane, .Lost)
		ui.announce(&app.announcer, .Warn, delivered ? i18n.tr("That message was delivered meanwhile: what you wrote stays in the composer") : i18n.tr("That message is no longer waiting: what you wrote stays in the composer"))
	}
	for it, i in q.items {
		if it.id == id { item_free(it); ordered_remove(&q.items, i); break }
	}
	gone_add(&q.gone, id, at, QUEUE_GONE_MAX, delivered)
	queue_first_gone(app, pane, id, delivered)
}

queue_delivery_changed :: proc(app: ^App, pane: ^Chat_Pane, id: string, to: Delivery, at: Seq) {
	it := queue_find(app, pane, id)
	if it == nil { return }
	it.delivery, it.changed = to, at
}

// Everything that waits for the session shown, as the server says it now. (On opening, on Try again, on a reconnection.)
queue_read :: proc(app: ^App, pane: ^Chat_Pane) {
	q := &pane.queue
	if q.session != pane.chat.id { queue_switch(app, pane) }
	if pane.chat.id == "" { return }
	remote.begin(&q.read)
	request(app, .Queue_List, "GET", fmt.tprintf("/api/session/%s/inbox", pane.chat.id), tag = pane.chat.id, reading = &q.read, pane = pane)
}

// The answer replaces the list. Not what the stream said since it was asked for: what came since stays, what went does not return.
queue_load :: proc(app: ^App, pane: ^Chat_Pane, session: string, v: json.Value, asked_at: Seq) {
	q := &pane.queue
	if session != q.session { return }
	next := make([dynamic]Queue_Item, 0, max(len(q.items), 4))
	for it in tk_json.array(v, "data") {
		id := tk_json.text(it, "id")
		if id == "" || tk_json.text(it, "type") != "user" { continue }
		if g := gone_find(&q.gone, id); g != nil && newer(g.at, asked_at) { continue }
		if old := queue_find(app, pane, id); old != nil {
			if !newer(old.changed, asked_at) { old.delivery = delivery_of(tk_json.text(it, "delivery")) }
			append(&next, old^)
			old.id = ""   // (it moved)
			continue
		}
		// (sent while nothing ran, on its way to the run that takes it: it shows already)
		if delivery_of(tk_json.text(it, "delivery")) == .Steer && queue_shown_as_sent(app, pane, id) { continue }
		append(&next, item_of(id, it, 0))
	}
	dropped := make([dynamic]string, context.temp_allocator)
	for &old in q.items {
		if old.id == "" { continue }
		if newer(old.born, asked_at) { append(&next, old); continue }
		if q.edit.id == old.id {
			queue_edit_end(app, pane, .Lost)
			ui.announce(&app.announcer, .Warn, i18n.tr("That message is no longer waiting: what you wrote stays in the composer"))
		}
		append(&dropped, strings.clone(old.id, context.temp_allocator))
		item_free(old)
	}
	delete(q.items)
	q.items = next
	// (how they left is not said: a reorder takes them as gone, as their events would have said)
	for id in dropped { queue_first_gone(app, pane, id, false) }
	gone_settled(&q.gone, asked_at)
	for it in q.items { chat_drop(&pane.chat, it.id) }   // (a page read before this list)
}

// Nothing of the session left stays: it is on the server, and the next session has its own. What was being edited did not change.
queue_switch :: proc(app: ^App, pane: ^Chat_Pane) {
	q := &pane.queue
	if queue_editing(app, pane) { queue_edit_end(app, pane, .Cancel) }
	queue_first_abort(app, pane)
	for it in q.items { item_free(it) }
	clear(&q.items)
	gone_clear(&q.gone)
	remote.reset(&q.read)
	delete(q.session)
	q.session = strings.clone(pane.chat.id)
}

queue_forget :: proc(app: ^App) { for &pane, i in app.panes { if pane_is_shown(app, i) { queue_switch(app, &pane) } } }

// The server's copy of a prompt is not what a prompt is sent as: stored, a file is its data, its type and where it came from; sent, a
// uri. A skill goes by its id. Out of the inbox it has to be said again.
prompt_of_payload :: proc(v: json.Value) -> string {
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, `{{"text":%s`, tk_json.quote(tk_json.text(v, "text")))
	marshalled :: proc(v: json.Value) -> string {
		data, _ := json.marshal(v, allocator = context.temp_allocator)
		return string(data)
	}
	if files := tk_json.array(v, "files"); len(files) > 0 {
		strings.write_string(&b, `,"files":[`)
		for f, i in files {
			if i > 0 { strings.write_byte(&b, ',') }
			fmt.sbprintf(&b, `{{"uri":%s`, tk_json.quote(payload_file_uri(f)))
			if name := tk_json.text(f, "name"); name != "" { fmt.sbprintf(&b, `,"name":%s`, tk_json.quote(name)) }
			if m := tk_json.get(f, "mention"); m != nil { fmt.sbprintf(&b, `,"mention":%s`, marshalled(m)) }
			strings.write_byte(&b, '}')
		}
		strings.write_byte(&b, ']')
	}
	if agents := tk_json.get(v, "agents"); len(tk_json.array(v, "agents")) > 0 { fmt.sbprintf(&b, `,"agents":%s`, marshalled(agents)) }
	if skills := tk_json.array(v, "skills"); len(skills) > 0 {
		strings.write_string(&b, `,"skills":[`)
		for s, i in skills {
			if i > 0 { strings.write_byte(&b, ',') }
			fmt.sbprintf(&b, `{{"id":%s`, tk_json.quote(tk_json.text(s, "id")))
			if m := tk_json.get(s, "mention"); m != nil { fmt.sbprintf(&b, `,"mention":%s`, marshalled(m)) }
			strings.write_byte(&b, '}')
		}
		strings.write_byte(&b, ']')
	}
	if meta := tk_json.get(v, "metadata"); meta != nil { fmt.sbprintf(&b, `,"metadata":%s`, marshalled(meta)) }
	strings.write_byte(&b, '}')
	return strings.to_string(b)
}

// Where a file of a payload can be read from again: what it came from, else its data.
@(private = "file")
payload_file_uri :: proc(f: json.Value) -> string {
	if u := tk_json.text(f, "uri"); u != "" { return u }
	if tk_json.text(f, "source", "type") == "uri" { if u := tk_json.text(f, "source", "uri"); u != "" { return u } }
	return fmt.tprintf("data:%s;base64,%s", tk_json.text(f, "mime"), tk_json.text(f, "data"))
}

////////////////////////////////
// What can be done to an item

queue_steer :: proc(app: ^App, pane: ^Chat_Pane, id: string) {
	it := queue_find(app, pane, id)
	if it == nil || it.act != .None || it.delivery != .Queue || !online(app) { return }
	it.act = .Sending
	request(app, .Queue_Steer, "PATCH", fmt.tprintf("/api/session/%s/inbox/%s", pane.queue.session, id), `{"delivery":"steer"}`, id, pane = pane)
}

// The first prompt that waits for the run's end, steered into the run (the composer's other way with nothing written).
queue_steer_first :: proc(app: ^App, pane: ^Chat_Pane) {
	q := &pane.queue
	if q.session != pane.chat.id { return }
	// (the first one only: one already on its way is not skipped for the next, as the desktop does)
	for &it in q.items {
		if it.delivery != .Queue { continue }
		if it.act == .None { queue_steer(app, pane, it.id) }
		return
	}
}

// A steered message waits for the next step of the run; a long step (a long thought, a command that takes its time) keeps it
// waiting. This stops the step: the run interrupted, what was steered goes as a prompt at once, in its order (inbox_resume, on
// session.execution.interrupted). What the step was doing is lost, which is what the reader chose. Nothing runs: it goes now.
queue_send_now :: proc(app: ^App, pane: ^Chat_Pane, id: string) {
	it := queue_find(app, pane, id)
	if it == nil || it.act != .None || it.delivery != .Steer || !online(app) { return }
	it.act = .Sending
	if pane.chat.busy && pane.chat.id == pane.queue.session { interrupt_session(app, pane.queue.session) } else { inbox_resume(app, pane.queue.session) }
}

queue_remove :: proc(app: ^App, pane: ^Chat_Pane, id: string) {
	it := queue_find(app, pane, id)
	if it == nil || it.act != .None || !online(app) { return }
	it.act = .Removing
	request(app, .Queue_Cancel, "DELETE", fmt.tprintf("/api/session/%s/inbox/%s", pane.queue.session, id), "", id, pane = pane)
}

// The server said yes: what it will also say on the stream is done now, a stream that is late or down changes nothing.
queue_answered :: proc(app: ^App, r: ^Request) {
	pane := req_pane(app, r)
	if r.kind == .Queue_Cancel { queue_gone(app, pane, r.tag, false, queue_tick(app)); return }
	if it := queue_find(app, pane, r.tag); it != nil { it.act = .None }
	queue_delivery_changed(app, pane, r.tag, .Steer, queue_tick(app))
}

// It did not change. (`told`: the server no longer has it to change, the list is read again and says so.)
queue_failed :: proc(app: ^App, r: ^Request) -> (told: bool) {
	pane := req_pane(app, r)
	if it := queue_find(app, pane, r.tag); it != nil { it.act = .None }
	if r.status == 409 { queue_read(app, pane); return true }
	return false
}

Edit_End :: enum u8 {
	Cancel,   // what was written goes, the composer is as it was
	Done,     // what was written left with a prompt
	Lost,     // the item left: what was written stays
}

// Its text and its files go to the composer. It stays in the list meanwhile, and what the composer held waits for the end.
queue_edit :: proc(app: ^App, pane: ^Chat_Pane, id: string) {
	q := &pane.queue
	it := queue_find(app, pane, id)
	if it == nil || it.act != .None || it.skills { return }
	if queue_editing(app, pane) { queue_edit_end(app, pane, .Cancel) }
	history_leave(app, pane, true)
	it = queue_find(app, pane, id)
	e := &q.edit
	e.id = strings.clone(id)
	e.draft = strings.clone(ui.text_edit_string(&pane.composer.area))
	append(&e.files, ..pane.composer.attachments[:])
	clear(&pane.composer.attachments)
	append(&e.mentions, ..pane.composer.mentions.chosen[:])
	clear(&pane.composer.mentions.chosen)
	v := json_of_own(app, "queued payload", it.payload)
	body := json_of_own(app, "queued prompt", prompt_of_payload(v))
	prompt_parts(body, &pane.composer.attachments, &pane.composer.mentions.chosen)
	ui.text_edit_set(&pane.composer.area, it.text)
	pane.composer.focus_next = true
	activity_close(app)
}

queue_edit_end :: proc(app: ^App, pane: ^Chat_Pane, how: Edit_End) {
	e := &pane.queue.edit
	if e.id == "" { return }
	if how == .Cancel {
		for a in pane.composer.attachments { delete(a.name); delete(a.uri) }
		clear(&pane.composer.attachments)
		mentions_clear(app, pane)
		ui.text_edit_set(&pane.composer.area, "")
	}
	prompt_restore(app, pane, e.draft)
	append(&pane.composer.attachments, ..e.files[:])
	clear(&e.files)
	append(&pane.composer.mentions.chosen, ..e.mentions[:])
	clear(&e.mentions)
	delete(e.id); delete(e.draft)
	e.id, e.draft = "", ""
}

// Enter: the item gives way to what the composer says. Out first, so that it cannot go twice; the prompt goes when it is out, with the
// same delivery. If it cannot be taken out it stays as it was, and the text comes back. (Queued while nothing runs, it does not start one.)
queue_edit_commit :: proc(app: ^App, pane: ^Chat_Pane, text: string) {
	e := &pane.queue.edit
	it := queue_find(app, pane, e.id)
	if it == nil { queue_edit_end(app, pane, .Lost); return }
	it.act = .Replacing
	outgoing_replace(app, pane, text, it.id, it.delivery == .Queue ? `,"delivery":"queue","resume":false` : `,"delivery":"steer"`)
	ui.text_edit_set(&pane.composer.area, "")
	queue_edit_end(app, pane, .Done)
}

// The item is out: unless it was delivered first, its replacement goes. (Whether it was is read back unless the stream said it: outgoing_check.)
queue_replaced :: proc(app: ^App, pane: ^Chat_Pane, r: ^Request) {
	q := &pane.queue
	g := gone_find(&q.gone, r.tag)
	delivered := g != nil && g.delivered
	queue_gone(app, pane, r.tag, false, queue_tick(app))
	if delivered { outgoing_replaced(app, r.out, false) } else { outgoing_check(app, r.out, r.tag) }
}

queue_replace_failed :: proc(app: ^App, r: ^Request) {
	pane := req_pane(app, r)
	if it := queue_find(app, pane, r.tag); it != nil { it.act = .None }
	outgoing_answered(app, r, false)
}

////////////////////////////////
// Queue first (Alt+Enter: src/md/features/queue-first.md)

// The server has no move: the other queued prompts are admitted again after the one put first, then their originals cancelled.
// Admitted before cancelled, so that a failure only has to take the copies back: nothing queued is ever lost.

// Alt+Enter's prompt left (outgoing_composer): its reorder starts when its answer gives its id.
queue_first_await :: proc(app: ^App, pane: ^Chat_Pane, out: u64) {
	if out != 0 { append(&pane.queue.first.outs, out) }
}

// A prompt's answer. (Not one of Alt+Enter's: nothing.)
queue_first_admitted :: proc(app: ^App, pane: ^Chat_Pane, out: u64, id: string) {
	f := &pane.queue.first
	for o, i in f.outs {
		if o != out { continue }
		unordered_remove(&f.outs, i)
		if id != "" { append(&f.waiting, strings.clone(id)) }
		queue_first_next(app, pane)
		return
	}
}

// It failed: it comes back to the composer (outgoing_answered), there is nothing to move.
queue_first_dropped :: proc(app: ^App, pane: ^Chat_Pane, out: u64) {
	f := &pane.queue.first
	for o, i in f.outs { if o == out { unordered_remove(&f.outs, i); return } }
}

// A second Alt+Enter while a reorder runs waits for it: its prompt went at once, its reorder starts on the list as it is
// then. The newest ends first, as the key says; queued at the end instead, it would do the opposite of what it says.
@(private = "file")
queue_first_next :: proc(app: ^App, pane: ^Chat_Pane) {
	f := &pane.queue.first
	for f.phase == .Idle && len(f.waiting) > 0 {
		id := f.waiting[0]
		ordered_remove(&f.waiting, 0)
		queue_first_start(app, pane, id)
		delete(id)
	}
}

// Every other queued prompt moves behind `id`, in its order: those before it and those after it (another client's), so that it
// is first of all. A busy one (being steered, removed, edited) leaves the queue as it is: the prompt stays where it went.
@(private = "file")
queue_first_start :: proc(app: ^App, pane: ^Chat_Pane, id: string) {
	q := &pane.queue
	f := &q.first
	it := queue_find(app, pane, id)
	if it == nil || it.delivery != .Queue || q.session != pane.chat.id || !online(app) { return }
	ahead := false
	for x in q.items {
		if x.delivery != .Queue { continue }
		ahead = x.id != id
		break
	}
	if !ahead { return }   // (first already)
	for x in q.items {
		if x.delivery == .Queue && x.id != id && (x.act != .None || q.edit.id == x.id) { return }
	}
	for &x in q.items {
		if x.delivery != .Queue || x.id == id { continue }
		x.act = .Moving
		append(&f.moves, Queue_Move{original = strings.clone(x.id), payload = strings.clone(x.payload)})
	}
	f.run += 1
	f.lead = strings.clone(id)
	f.phase, f.at = .Copying, 0
	first_copy(app, pane)
}

// "run:id": which reorder a request is of.
@(private = "file")
first_tag :: proc(run: u64, id: string) -> string { return fmt.tprintf("%d:%s", run, id) }

@(private = "file")
first_tag_read :: proc(tag: string) -> (run: u64, id: string) {
	i := strings.index_byte(tag, ':')
	if i < 0 { return }
	run, _ = strconv.parse_u64(tag[:i])
	return run, tag[i + 1:]
}

@(private = "file")
first_path :: proc(app: ^App, pane: ^Chat_Pane, id: string) -> string {
	return fmt.tprintf("/api/session/%s/inbox/%s", pane.queue.session, id)
}

// The copy of moves[at]: its payload said again as a prompt, queued, not starting a run of its own. Its id is minted here,
// before it goes, as the desktop does: the copy is known by it whatever comes first, its event or its answer, and one whose
// answer never came (the server may have taken it) can still be taken back.
@(private = "file")
first_copy :: proc(app: ^App, pane: ^Chat_Pane) {
	f := &pane.queue.first
	m := &f.moves[f.at]
	m.copy = message_id_new(context.allocator)
	body := prompt_of_payload(json_of_own(app, "queued payload", m.payload))
	body = fmt.tprintf(`{{"id":%s,%s,"delivery":"queue","resume":false}}`, tk_json.quote(m.copy), body[1:len(body) - 1])
	f.copying = true
	request(app, .Queue_First_Copy, "POST", fmt.tprintf("/api/session/%s/prompt", pane.queue.session), body, first_tag(f.run, m.copy), pane = pane)
}

// The original of moves[at] goes; one that left by itself is passed. None left: done.
@(private = "file")
first_cancel :: proc(app: ^App, pane: ^Chat_Pane) {
	f := &pane.queue.first
	for f.at < len(f.moves) && f.moves[f.at].left { f.at += 1 }
	if f.at == len(f.moves) {
		f.phase = .Withdrawing   // (the duplicates' DELETEs may still be on their way)
		first_settle(app, pane)
		return
	}
	m := &f.moves[f.at]
	request(app, .Queue_First_Cancel, "DELETE", first_path(app, pane, m.original), tag = first_tag(f.run, m.original), pane = pane)
}

@(private = "file")
first_withdraw :: proc(app: ^App, pane: ^Chat_Pane, m: ^Queue_Move) {
	f := &pane.queue.first
	m.withdrawn = true
	f.pending += 1
	request(app, .Queue_First_Withdraw, "DELETE", first_path(app, pane, m.copy), tag = first_tag(f.run, m.copy), pane = pane)
}

// The queue changed under the copies, or one failed: the copies admitted go back, the queue is as it was.
@(private = "file")
first_stop :: proc(app: ^App, pane: ^Chat_Pane) {
	f := &pane.queue.first
	f.phase = .Withdrawing
	// (not the copy at `at`, on its way: a DELETE could reach the server before its POST. Its answer withdraws it)
	for &m, k in f.moves {
		if k >= f.at { break }
		if m.copy != "" && !m.withdrawn { first_withdraw(app, pane, &m) }
	}
	first_settle(app, pane)
}

// Nothing more on its way: the machine is free for the next Alt+Enter.
@(private = "file")
first_settle :: proc(app: ^App, pane: ^Chat_Pane) {
	q := &pane.queue
	f := &q.first
	if f.phase != .Withdrawing || f.pending > 0 || f.copying { return }
	for m in f.moves {
		if it := queue_find(app, pane, m.original); it != nil && it.act == .Moving { it.act = .None }
	}
	first_clear(f)
	queue_first_next(app, pane)
}

@(private = "file")
first_clear :: proc(f: ^Queue_First) {
	for m in f.moves { delete(m.original); delete(m.copy); delete(m.payload) }
	clear(&f.moves)
	delete(f.lead)
	f.lead = ""
	f.phase, f.at, f.pending, f.copying = .Idle, 0, 0, false
}

// The copy shows once its original is gone: until then the original holds its place, and each prompt shows once.
queue_hidden :: proc(app: ^App, pane: ^Chat_Pane, id: string) -> bool {
	for m in pane.queue.first.moves {
		if m.copy == id { return m.withdrawn || queue_find(app, pane, m.original) != nil }
	}
	return false
}

// Something left the list during a reorder (queue_gone).
@(private = "file")
queue_first_gone :: proc(app: ^App, pane: ^Chat_Pane, id: string, delivered: bool) {
	f := &pane.queue.first
	switch f.phase {
	case .Idle, .Withdrawing:
	case .Copying:
		// (the desktop's "Queued prompts changed before reordering": the prompt put first stays where it is)
		if id == f.lead { first_stop(app, pane); return }
		for m in f.moves {
			if m.original == id || m.copy == id { first_stop(app, pane); return }
		}
	case .Cancelling:
		for &m, k in f.moves {
			if m.original != id { continue }
			// (its own cancel is the one at `at`, or one before: what else takes it out leaves its copy a duplicate.
			// A cancel answers 204 for what was delivered too: only the event says it was)
			if delivered || k > f.at {
				if k > f.at { m.left = true }
				if m.copy != "" && !m.withdrawn { first_withdraw(app, pane, &m) }
			}
			return
		}
	}
}

// The session or the server left. What is admitted is not left half done: copies go back, or, all being in, the originals go.
@(private = "file")
queue_first_abort :: proc(app: ^App, pane: ^Chat_Pane) {
	f := &pane.queue.first
	switch f.phase {
	case .Idle, .Withdrawing:
	case .Copying:
		// (the one on its way: an orphan, its answer withdraws it)
		for &m, k in f.moves { if k < f.at && !m.withdrawn { first_withdraw(app, pane, &m) } }
	case .Cancelling:
		for m, k in f.moves {
			if k > f.at && !m.left { request(app, .Queue_First_Cancel, "DELETE", first_path(app, pane, m.original), tag = first_tag(0, m.original), pane = pane) }
		}
	}
	first_clear(f)
	f.run += 1   // (what is still on its way is an orphan now)
	clear(&f.outs)
	for id in f.waiting { delete(id) }
	clear(&f.waiting)
}

// A copy that nobody expects (its reorder stopped or left): it goes back, on the server and the session it went to.
@(private = "file")
first_orphan :: proc(app: ^App, r: ^Request, id: string) {
	session := strings.trim_prefix(r.path, "/api/session/")
	if i := strings.index_byte(session, '/'); i >= 0 { session = session[:i] }
	request(app, .Queue_First_Withdraw, "DELETE", fmt.tprintf("/api/session/%s/inbox/%s", session, id), tag = first_tag(0, id), conn = r.conn, pane = req_pane(app, r))
}

// (the tag names the copy: its minted id, which is its id in the inbox)
queue_first_copy_on_ok :: proc(app: ^App, r: ^Request, v: json.Value) {
	pane := req_pane(app, r)
	f := &pane.queue.first
	run, id := first_tag_read(r.tag)
	if run != f.run || !f.copying { first_orphan(app, r, id); return }
	f.copying = false
	m := &f.moves[f.at]
	if f.phase == .Withdrawing {
		first_withdraw(app, pane, m)
		first_settle(app, pane)
		return
	}
	queue_add(app, pane, m.copy, tk_json.get(v, "data"), queue_tick(app))
	f.at += 1
	if f.at < len(f.moves) { first_copy(app, pane); return }
	f.phase, f.at = .Cancelling, 0
	first_cancel(app, pane)
}

// Refused, it is not in the inbox. Without an answer, or with one that cannot be read, the server may have it: it is
// withdrawn by its id (a 404 says it never got there). Either way the queue is as it was; the toast says what failed.
queue_first_copy_on_fail :: proc(app: ^App, r: ^Request, failure: Failure, message: string) -> (told: bool) {
	pane := req_pane(app, r)
	f := &pane.queue.first
	run, id := first_tag_read(r.tag)
	taken := failure != .Refused && failure != .Auth
	if run != f.run || !f.copying {
		if taken { first_orphan(app, r, id) }
		return false
	}
	f.copying = false
	if taken { first_withdraw(app, pane, &f.moves[f.at]) }
	if f.phase == .Copying { first_stop(app, pane) } else { first_settle(app, pane) }
	return false
}

// (the server left: unless it refused it, it is taken back there)
queue_first_copy_on_left :: proc(app: ^App, r: ^Request) {
	if r.ok && r.status >= 400 { return }
	_, id := first_tag_read(r.tag)
	first_orphan(app, r, id)
}

queue_first_cancel_on_ok :: proc(app: ^App, r: ^Request, v: json.Value) {
	pane := req_pane(app, r)
	f := &pane.queue.first
	run, id := first_tag_read(r.tag)
	if run != f.run || f.phase != .Cancelling || f.moves[f.at].original != id { return }
	queue_gone(app, pane, id, false, queue_tick(app))   // (said by the stream first, delivered: that stays, gone_add)
	f.at += 1
	first_cancel(app, pane)
}

// An original that cannot be cancelled stays, and so do those after it: their copies go back. The content is intact, the order
// partly moved.
queue_first_cancel_on_fail :: proc(app: ^App, r: ^Request, failure: Failure, message: string) -> (told: bool) {
	pane := req_pane(app, r)
	f := &pane.queue.first
	run, id := first_tag_read(r.tag)
	if run != f.run || f.phase != .Cancelling || f.moves[f.at].original != id { return false }
	for &m, k in f.moves {
		if k >= f.at && m.copy != "" && !m.withdrawn { first_withdraw(app, pane, &m) }
	}
	f.phase = .Withdrawing
	first_settle(app, pane)
	return false
}

queue_first_withdraw_on_ok :: proc(app: ^App, r: ^Request, v: json.Value) {
	pane := req_pane(app, r)
	f := &pane.queue.first
	run, id := first_tag_read(r.tag)
	if run == 0 || run != f.run { return }
	queue_gone(app, pane, id, false, queue_tick(app))
	f.pending -= 1
	first_settle(app, pane)
}

// The copy stays: a duplicate the reader sees (it is no longer hidden) and can remove. A 404 is no failure: the server never
// took that copy (its POST failed on the way), or it left already.
queue_first_withdraw_on_fail :: proc(app: ^App, r: ^Request, failure: Failure, message: string) -> (told: bool) {
	pane := req_pane(app, r)
	if r.status == 404 { queue_first_withdraw_on_ok(app, r, nil); return true }
	f := &pane.queue.first
	run, id := first_tag_read(r.tag)
	if run == 0 || run != f.run { return false }
	for &m in f.moves { if m.copy == id { m.withdrawn = false } }
	f.pending -= 1
	first_settle(app, pane)
	return false
}

////////////////////////////////
// The list over the composer

// `id` of its row, and the words or the glyph that say it, as the room allows.
@(private = "file")
queue_action :: proc(id, label, icon: string, wide: bool, em: f32, intent := ui.Intent.Neutral) -> bool {
	if wide {
		ui.spacer(ui.px(em * 0.7))
		return hint_action(id, label, em, the_app.mono, intent = intent)
	}
	ui.spacer(ui.px(em * 0.15))
	ui.a11y({role = .Button, name = label})
	ink := Color{}
	if intent != .Neutral { _, ink, _ = intent_colors(intent) }
	ui.next({width = ui.px(math.round(em * QUEUE_GLYPH_EM)), height = ui.px(math.round(em * QUEUE_GLYPH_EM)), fg = ink})
	return ui.button(id, icon = icon).clicked
}

@(private = "file")
queue_row :: proc(app: ^App, pane: ^Chat_Pane, it: ^Queue_Item, n: int, em: f32) {
	q := &pane.queue
	id := strings.clone(it.id, context.temp_allocator)   // (an action may free it)
	editing := q.edit.id == it.id
	busy := it.act != .None
	note := ui.Style_Mod{font = app.mono, font_size = math.round(em * FS_CAPTION)}
	ui.next({width = ui.fill(), height = ui.px(math.round(em * QUEUE_ROW_H_EM)), axis = .X, cross = .Center})
	ui.a11y({role = .Group, name = fmt.tprintf(i18n.tr("Pending message %d: %s"), n, ellipsize(it.text, QUEUE_NAME_CHARS))})
	if ui.row(.Center, id = fmt.tprintf("###q_%s", id)) {
		ui.spacer(ui.px(em * TRAY_PAD_EM))
		text("n", it.delivery == .Queue ? fmt.tprintf("%d", n) : "›", hex(HEX_FAINT), note, ui.px(em * QUEUE_MARK_W_EM))
		line := preview_text(it.text)
		if line == "" { line = i18n.tr("(no text)") }
		text("t", ellipsize(line, QUEUE_LINE_CHARS), busy ? hex(HEX_FAINT) : hex(HEX_TEXT_SOFT), ui.Style_Mod{font_size = math.round(em * FS_NOTE)}, ui.fill())
		if it.files > 0 {
			ui.spacer(ui.px(em * 0.5))
			text("f", fmt.tprintf(i18n.tr(it.files, "%d file", "%d files"), it.files), hex(HEX_FAINT), note)
		}
		wide := pane.conversation.column_w > em * QUEUE_WORDS_MIN_EM
		switch {
		case editing:
			ui.spacer(ui.px(em * 0.7))
			text("e", "editing", accent(), note)
		case busy:
			ui.spacer(ui.px(em * 0.7))
			text("b", it.act == .Sending ? i18n.tr("sending…") : it.act == .Removing ? i18n.tr("removing…") : i18n.tr("changing…"), hex(HEX_FAINT), note)
		case:
			if !it.skills && queue_action("###edit", i18n.tr("Edit"), lucide.PENCIL, wide, em) { queue_edit(app, pane, id) }
			if it.delivery == .Queue && queue_action("###steer", i18n.tr("Steer"), lucide.SHIP_WHEEL, wide, em) { queue_steer(app, pane, id) }
			if it.delivery == .Steer && queue_action("###now", i18n.tr("Send now"), lucide.SEND_HORIZONAL, wide, em) { queue_send_now(app, pane, id) }
			if queue_action("###rm", i18n.tr("Remove"), lucide.X, wide, em, .Danger) { queue_remove(app, pane, id) }
		}
		ui.spacer(ui.px(em * TRAY_PAD_EM))
	}
}

// Its height is bounded, and it scrolls: a long list does not push the composer away.
queue_list :: proc(app: ^App, pane: ^Chat_Pane, em: f32) {
	q := &pane.queue
	if q.session != pane.chat.id { return }
	n := 0
	for it in q.items { if !queue_hidden(app, pane, it.id) { n += 1 } }
	if n == 0 {
		if q.read.state == .Failed {   // (a server without an inbox refuses: that has nothing to say)
			ui.next({width = ui.fill(), height = ui.children_sum(), axis = .X, cross = .Center})
			if ui.row(.Center, id = "###q_failed") {
				ui.spacer(ui.px(em * 0.5))
				if hint_action("###q_again", i18n.tr("What waits for this session could not be read  ·  Try again"), em, app.mono) { queue_read(app, pane) }
			}
			ui.spacer(ui.px(em * 0.25))
		}
		return
	}
	head_h := math.round(em * QUEUE_HEAD_H_EM)
	row_h := math.round(em * QUEUE_ROW_H_EM)
	list_h := f32(min(n, QUEUE_ROWS_SHOWN)) * row_h
	ui.next({width = ui.fill(), height = ui.px(head_h + list_h + math.round(em * 0.3)), axis = .Y})
	ui.a11y({role = .Group, name = i18n.tr("Pending messages")})
	box := ui.build_box({}, "###q_well")
	box.custom = tray_draw
	if ui.parent(box) {
		ui.next({width = ui.fill(), height = ui.px(head_h), axis = .X, cross = .Center})
		if ui.row(.Center, id = "###q_head") {
			ui.spacer(ui.px(em * TRAY_PAD_EM))
			text("h", fmt.tprintf(i18n.tr("PENDING  %d"), n), hex(HEX_FAINT), ui.Style_Mod{font = app.mono_bold, font_size = math.round(em * FS_CAPTION)})
			ui.spacer(ui.px(em * 0.9))
			// (the row cuts what has no room: what matters comes first)
			text("w", pane.chat.busy ? i18n.tr("not sent yet  ·  queued ones go when the turn ends") : i18n.tr("not sent  ·  the run stopped, these wait"), hex(HEX_FAINT), ui.Style_Mod{font = app.mono, font_size = math.round(em * FS_CAPTION)}, ui.fill())
			ui.spacer(ui.px(em * TRAY_PAD_EM))
		}
		ui.next({width = ui.fill(), height = ui.px(list_h)})
		if ui.scroll_y("###q_scroll") {
			ui.next({width = ui.fill(), height = ui.children_sum(), axis = .Y})
			if ui.column(id = "###q_rows") {
				shown := 0
				// (an action may take its item out: the list is walked by id)
				ids := make([]string, len(q.items), context.temp_allocator)
				for it, i in q.items { ids[i] = strings.clone(it.id, context.temp_allocator) }
				for id in ids {
					it := queue_find(app, pane, id)
					if it == nil || queue_hidden(app, pane, id) { continue }
					if it.delivery == .Queue { shown += 1 }
					queue_row(app, pane, it, shown, em)
				}
			}
		}
	}
	ui.spacer(ui.px(em * 0.45))
}

// In the composer, over what is written: what Enter will do is not what it usually does.
queue_edit_banner :: proc(app: ^App, pane: ^Chat_Pane, em: f32) {
	if !queue_editing(app, pane) { return }
	q := &pane.queue
	note := ui.Style_Mod{font = app.mono, font_size = math.round(em * FS_CAPTION)}
	ui.next({width = ui.fill(), height = ui.px(math.round(em * QUEUE_ROW_H_EM)), axis = .X, cross = .Center})
	if ui.row(.Center, id = "###q_banner") {
		ui.spacer(ui.px(em * 0.85))
		glyph(lucide.PENCIL, accent(), math.round(em * ICON_SMALL), em * 1.1)
		ui.spacer(ui.px(em * 0.25))
		text("t", i18n.tr("Editing a pending message"), accent(), ui.Style_Mod{font_size = math.round(em * FS_NOTE)})
		if len(q.items) > 1 && q.items[len(q.items) - 1].id != q.edit.id && pane.conversation.column_w > em * QUEUE_WORDS_MIN_EM {
			ui.spacer(ui.px(em * 0.6))
			text("o", i18n.tr("it goes back last"), hex(HEX_FAINT), note)
		}
		ui.spacer(ui.fill())
		if hint_action("###q_cancel", i18n.tr("Esc  cancel"), em, app.mono) { queue_edit_end(app, pane, .Cancel) }
		ui.spacer(ui.px(em * 0.85))
	}
}

////////////////////////////////
// The inbox of a run interrupted

// A run that is interrupted leaves what was steered into it in the session's inbox, where only the next prompt would pick it up,
// glued to that prompt: it looks lost. The newest goes as a prompt now, which starts a run: the server puts what is left in the
// inbox before a prompt, so they keep their order. (It has no way to wake an inbox: out of it, then sent.) If the prompt fails its text comes back to the composer; if the
// taking fails it stays in the inbox. Nothing is lost. What was queued is left where it is: the reader stopped the run, and queued it
// for after that run, not for a new one started without a word. It stays parked in the list over the composer, Steer at hand.
inbox_resume :: proc(app: ^App, id: string) {
	request(app, .Inbox, "GET", fmt.tprintf("/api/session/%s/inbox", id), tag = id)
}

inbox_on_ok :: proc(app: ^App, r: ^Request, v: json.Value) {
	newest: json.Value
	last: f64
	for item in tk_json.array(v, "data") {
		if tk_json.text(item, "type") != "user" || delivery_of(tk_json.text(item, "delivery")) == .Queue { continue }
		if t := tk_json.number(item, "time", "created"); t >= last { last, newest = t, item }
	}
	if newest == nil { return }
	request(app, .Inbox_Take, "DELETE", fmt.tprintf("/api/session/%s/inbox/%s", r.tag, tk_json.text(newest, "id")), prompt_of_payload(tk_json.get(newest, "payload")), r.tag)
}

// (a server without one: nothing to say)
inbox_on_fail :: proc(app: ^App, r: ^Request, f: Failure, message: string) -> (told: bool) { return f == .Refused }

inbox_take_on_ok :: proc(app: ^App, r: ^Request, v: json.Value) {
	// (what shows of it goes, in each pane that shows its session: the prompt comes back under its own id. The prompt is the first
	// such pane's, else the main view's)
	taken := r.path[strings.last_index_byte(r.path, '/') + 1:]
	from: ^Chat_Pane
	for &pane, i in app.panes {
		if !pane_is_shown(app, i) || r.tag != pane.chat.id { continue }
		if queue_shown_as_sent(app, &pane, taken) { chat_drop(&pane.chat, taken) }
		queue_gone(app, &pane, taken, false, app.cx.stream_seq)
		if from == nil { from = &pane }
	}
	outgoing_inbox(app, from != nil ? from : main_pane(app), r.tag, r.body)
}

////////////////////////////////
// What the answers to the queue's requests do (net.odin REQ_FACTS)

queue_list_on_ok :: proc(app: ^App, r: ^Request, v: json.Value) { queue_load(app, req_pane(app, r), r.tag, v, r.asked_at) }

// A Steer or a Cancel.
queue_item_on_ok :: proc(app: ^App, r: ^Request, v: json.Value) { queue_answered(app, r) }

queue_item_on_fail :: proc(app: ^App, r: ^Request, f: Failure, message: string) -> (told: bool) { return queue_failed(app, r) }

queue_replace_on_ok :: proc(app: ^App, r: ^Request, v: json.Value) { queue_replaced(app, req_pane(app, r), r) }

queue_replace_on_fail :: proc(app: ^App, r: ^Request, f: Failure, message: string) -> (told: bool) {
	queue_replace_failed(app, r)
	return true   // (Outgoing says it)
}

// (taken out or not, that server is left: what was written comes back)
queue_replace_on_left :: proc(app: ^App, r: ^Request) { outgoing_answered(app, r, false) }
