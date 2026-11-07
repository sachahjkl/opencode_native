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
// A run interrupted leaves what is queued parked: nothing here sends it. It stays in the list, which says so, with Send now.
package occ

import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:strings"
import "gt:ui"

Delivery :: enum u8 { Steer, Queue }

// What is on its way for an item: one thing at a time.
Queue_Act :: enum u8 { None, Sending, Removing, Replacing }

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
	read:    Remote,
	edit:    Queue_Edit,
}

// How the composer's prompt would go now. (Idle: nothing runs, it goes as it always did.)
Send_As :: enum u8 { Idle, Queue, Steer }

// `alt`: the other key (Ctrl+Enter). conversation.while_running says which one is Enter.
composer_send_as :: proc(app: ^App, alt := false) -> Send_As {
	if app.chat.id == "" || !app.chat.busy { return .Idle }
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

queue_find :: proc(app: ^App, id: string) -> ^Queue_Item {
	for &it in app.cx.queue.items { if it.id == id { return &it } }
	return nil
}

// A message of the session shown that still waits: a page that has it does not say it was sent.
queue_holds :: proc(app: ^App, id: string) -> bool {
	return app.cx.queue.session == app.chat.id && queue_find(app, id) != nil
}

queue_editing :: proc(app: ^App) -> bool { return app.cx.queue.edit.id != "" }

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
	payload := jget(v, "payload")
	data, _ := json.marshal(payload, allocator = context.temp_allocator)
	return {
		id = strings.clone(id), text = strings.clone(jstr(payload, "text")), payload = strings.clone(string(data)),
		delivery = delivery_of(jstr(v, "delivery")), files = len(jarr(payload, "files")), skills = len(jarr(payload, "skills")) > 0, born = born,
	}
}

// (once: an event and the answer to the prompt both say it)
queue_add :: proc(app: ^App, id: string, v: json.Value, born: Seq) {
	q := &app.cx.queue
	if id == "" || q.session != app.chat.id || queue_find(app, id) != nil { return }
	if gone_find(&q.gone, id) != nil { return }
	append(&q.items, item_of(id, v, born))
}

// The answer to a prompt: the server has it. Should the stream be late or down, the list is right all the same.
queue_prompt_answered :: proc(app: ^App, session: string, v: json.Value) {
	item := jget(v, "data")
	if session != app.chat.id || jstr(item, "type") != "user" { return }
	if !app.chat.busy && delivery_of(jstr(item, "delivery")) == .Steer { return }   // (it goes at once)
	if queue_shown_as_sent(app, jstr(item, "id")) { return }
	queue_add(app, jstr(item, "id"), item, queue_tick(app))
}

// It left the list: delivered, cancelled, here or elsewhere.
queue_gone :: proc(app: ^App, id: string, delivered: bool, at: Seq) {
	q := &app.cx.queue
	if id == "" { return }
	if q.edit.id == id {
		queue_edit_end(app, .Lost)
		ui.toast(.Warn, delivered ? "That message was delivered meanwhile: what you wrote stays in the composer" : "That message is no longer waiting: what you wrote stays in the composer")
	}
	for it, i in q.items {
		if it.id == id { item_free(it); ordered_remove(&q.items, i); break }
	}
	gone_add(&q.gone, id, at, QUEUE_GONE_MAX, delivered)
}

queue_delivery_changed :: proc(app: ^App, id: string, to: Delivery, at: Seq) {
	it := queue_find(app, id)
	if it == nil { return }
	it.delivery, it.changed = to, at
}

// Everything that waits for the session shown, as the server says it now. (On opening, on Try again, on a reconnection.)
queue_read :: proc(app: ^App) {
	q := &app.cx.queue
	if q.session != app.chat.id { queue_switch(app) }
	if app.chat.id == "" { return }
	remote_begin(&q.read)
	request(app, .Queue_List, "GET", fmt.tprintf("/api/session/%s/inbox", app.chat.id), tag = app.chat.id, remote = &q.read)
}

// The answer replaces the list. Not what the stream said since it was asked for: what came since stays, what went does not return.
queue_load :: proc(app: ^App, session: string, v: json.Value, asked_at: Seq) {
	q := &app.cx.queue
	if session != q.session { return }
	next := make([dynamic]Queue_Item, 0, max(len(q.items), 4))
	for it in jarr(v, "data") {
		id := jstr(it, "id")
		if id == "" || jstr(it, "type") != "user" { continue }
		if g := gone_find(&q.gone, id); g != nil && newer(g.at, asked_at) { continue }
		if old := queue_find(app, id); old != nil {
			if !newer(old.changed, asked_at) { old.delivery = delivery_of(jstr(it, "delivery")) }
			append(&next, old^)
			old.id = ""   // (it moved)
			continue
		}
		// (sent while nothing ran, on its way to the run that takes it: it shows already)
		if delivery_of(jstr(it, "delivery")) == .Steer && queue_shown_as_sent(app, id) { continue }
		append(&next, item_of(id, it, 0))
	}
	for &old in q.items {
		if old.id == "" { continue }
		if newer(old.born, asked_at) { append(&next, old); continue }
		if q.edit.id == old.id {
			queue_edit_end(app, .Lost)
			ui.toast(.Warn, "That message is no longer waiting: what you wrote stays in the composer")
		}
		item_free(old)
	}
	delete(q.items)
	q.items = next
	gone_settled(&q.gone, asked_at)
	for it in q.items { chat_drop(&app.chat, it.id) }   // (a page read before this list)
}

// Nothing of the session left stays: it is on the server, and the next session has its own. What was being edited did not change.
queue_switch :: proc(app: ^App) {
	q := &app.cx.queue
	if queue_editing(app) { queue_edit_end(app, .Cancel) }
	for it in q.items { item_free(it) }
	clear(&q.items)
	gone_clear(&q.gone)
	remote_reset(&q.read)
	delete(q.session)
	q.session = strings.clone(app.chat.id)
}

queue_forget :: proc(app: ^App) { queue_switch(app) }

// The server's copy of a prompt is not what a prompt is sent as: stored, a file is its data, its type and where it came from; sent, a
// uri. A skill goes by its id. Out of the inbox it has to be said again.
prompt_of_payload :: proc(v: json.Value) -> string {
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, `{{"text":%s`, jquote(jstr(v, "text")))
	marshalled :: proc(v: json.Value) -> string {
		data, _ := json.marshal(v, allocator = context.temp_allocator)
		return string(data)
	}
	if files := jarr(v, "files"); len(files) > 0 {
		strings.write_string(&b, `,"files":[`)
		for f, i in files {
			if i > 0 { strings.write_byte(&b, ',') }
			fmt.sbprintf(&b, `{{"uri":%s`, jquote(payload_file_uri(f)))
			if name := jstr(f, "name"); name != "" { fmt.sbprintf(&b, `,"name":%s`, jquote(name)) }
			if m := jget(f, "mention"); m != nil { fmt.sbprintf(&b, `,"mention":%s`, marshalled(m)) }
			strings.write_byte(&b, '}')
		}
		strings.write_byte(&b, ']')
	}
	if agents := jget(v, "agents"); len(jarr(v, "agents")) > 0 { fmt.sbprintf(&b, `,"agents":%s`, marshalled(agents)) }
	if skills := jarr(v, "skills"); len(skills) > 0 {
		strings.write_string(&b, `,"skills":[`)
		for s, i in skills {
			if i > 0 { strings.write_byte(&b, ',') }
			fmt.sbprintf(&b, `{{"id":%s`, jquote(jstr(s, "id")))
			if m := jget(s, "mention"); m != nil { fmt.sbprintf(&b, `,"mention":%s`, marshalled(m)) }
			strings.write_byte(&b, '}')
		}
		strings.write_byte(&b, ']')
	}
	if meta := jget(v, "metadata"); meta != nil { fmt.sbprintf(&b, `,"metadata":%s`, marshalled(meta)) }
	strings.write_byte(&b, '}')
	return strings.to_string(b)
}

// Where a file of a payload can be read from again: what it came from, else its data.
@(private = "file")
payload_file_uri :: proc(f: json.Value) -> string {
	if u := jstr(f, "uri"); u != "" { return u }
	if jstr(f, "source", "type") == "uri" { if u := jstr(f, "source", "uri"); u != "" { return u } }
	return fmt.tprintf("data:%s;base64,%s", jstr(f, "mime"), jstr(f, "data"))
}

////////////////////////////////
// What can be done to an item

queue_send_now :: proc(app: ^App, id: string) {
	it := queue_find(app, id)
	if it == nil || it.act != .None || it.delivery != .Queue || !online(app) { return }
	it.act = .Sending
	request(app, .Queue_Steer, "PATCH", fmt.tprintf("/api/session/%s/inbox/%s", app.cx.queue.session, id), `{"delivery":"steer"}`, id)
}

queue_remove :: proc(app: ^App, id: string) {
	it := queue_find(app, id)
	if it == nil || it.act != .None || !online(app) { return }
	it.act = .Removing
	request(app, .Queue_Cancel, "DELETE", fmt.tprintf("/api/session/%s/inbox/%s", app.cx.queue.session, id), "", id)
}

// The server said yes: what it will also say on the stream is done now, a stream that is late or down changes nothing.
queue_answered :: proc(app: ^App, r: ^Request) {
	if r.kind == .Queue_Cancel { queue_gone(app, r.tag, false, queue_tick(app)); return }
	if it := queue_find(app, r.tag); it != nil { it.act = .None }
	queue_delivery_changed(app, r.tag, .Steer, queue_tick(app))
}

// It did not change. (`told`: the server no longer has it to change, the list is read again and says so.)
queue_failed :: proc(app: ^App, r: ^Request) -> (told: bool) {
	if it := queue_find(app, r.tag); it != nil { it.act = .None }
	if r.status == 409 { queue_read(app); return true }
	return false
}

Edit_End :: enum u8 {
	Cancel,   // what was written goes, the composer is as it was
	Done,     // what was written left with a prompt
	Lost,     // the item left: what was written stays
}

// Its text and its files go to the composer. It stays in the list meanwhile, and what the composer held waits for the end.
queue_edit :: proc(app: ^App, id: string) {
	q := &app.cx.queue
	it := queue_find(app, id)
	if it == nil || it.act != .None || it.skills { return }
	if queue_editing(app) { queue_edit_end(app, .Cancel) }
	history_leave(app, true)
	it = queue_find(app, id)
	e := &q.edit
	e.id = strings.clone(id)
	e.draft = strings.clone(ui.area_string(&app.composer))
	append(&e.files, ..app.cx.attachments[:])
	clear(&app.cx.attachments)
	append(&e.mentions, ..app.cx.mentions.chosen[:])
	clear(&app.cx.mentions.chosen)
	v, _ := json.parse_string(it.payload, parse_integers = true, allocator = context.temp_allocator)
	body, _ := json.parse_string(prompt_of_payload(v), parse_integers = true, allocator = context.temp_allocator)
	prompt_parts(body, &app.cx.attachments, &app.cx.mentions.chosen)
	ui.area_set(&app.composer, it.text)
	app.cx.focus_composer = true
	activity_close(app)
}

queue_edit_end :: proc(app: ^App, how: Edit_End) {
	e := &app.cx.queue.edit
	if e.id == "" { return }
	if how == .Cancel {
		for a in app.cx.attachments { delete(a.name); delete(a.uri) }
		clear(&app.cx.attachments)
		mentions_clear(app)
		ui.area_set(&app.composer, "")
	}
	prompt_restore(app, e.draft)
	append(&app.cx.attachments, ..e.files[:])
	clear(&e.files)
	append(&app.cx.mentions.chosen, ..e.mentions[:])
	clear(&e.mentions)
	delete(e.id); delete(e.draft)
	e.id, e.draft = "", ""
}

// Enter: the item gives way to what the composer says. Out first, so that it cannot go twice; the prompt goes when it is out, with the
// same delivery. If it cannot be taken out it stays as it was, and the text comes back. (Queued while nothing runs, it does not start one.)
queue_edit_commit :: proc(app: ^App, text: string) {
	e := &app.cx.queue.edit
	it := queue_find(app, e.id)
	if it == nil { queue_edit_end(app, .Lost); return }
	it.act = .Replacing
	outgoing_replace(app, text, it.id, it.delivery == .Queue ? `,"delivery":"queue","resume":false` : `,"delivery":"steer"`)
	ui.area_set(&app.composer, "")
	queue_edit_end(app, .Done)
}

// The item is out: unless it was delivered first, its replacement goes. (Whether it was is read back unless the stream said it: outgoing_check.)
queue_replaced :: proc(app: ^App, r: ^Request) {
	q := &app.cx.queue
	g := gone_find(&q.gone, r.tag)
	delivered := g != nil && g.delivered
	queue_gone(app, r.tag, false, queue_tick(app))
	if delivered { outgoing_replaced(app, r.out, false) } else { outgoing_check(app, r.out, r.tag) }
}

queue_replace_failed :: proc(app: ^App, r: ^Request) {
	if it := queue_find(app, r.tag); it != nil { it.act = .None }
	outgoing_answered(app, r, false)
}

////////////////////////////////
// The list over the composer

// `id` of its row, and the words or the glyph that say it, as the room allows.
@(private = "file")
queue_action :: proc(id, label, icon: string, wide: bool, em: f32) -> bool {
	if wide {
		ui.spacer(ui.px(em * 0.7))
		return hint_action(id, label, em, the_app.mono)
	}
	ui.spacer(ui.px(em * 0.15))
	ui.a11y({role = .Button, name = label})
	return glyph_button(id, icon, math.round(em * QUEUE_GLYPH_EM)).clicked
}

@(private = "file")
queue_row :: proc(app: ^App, it: ^Queue_Item, n: int, em: f32) {
	q := &app.cx.queue
	id := strings.clone(it.id, context.temp_allocator)   // (an action may free it)
	editing := q.edit.id == it.id
	busy := it.act != .None
	note := ui.Style_Mod{font = app.mono, font_size = math.round(em * FS_CAPTION)}
	ui.next({width = ui.fill(), height = ui.px(math.round(em * QUEUE_ROW_H_EM)), axis = .X, cross = .Center})
	ui.a11y({role = .Group, name = fmt.tprintf("Pending message %d: %s", n, ellipsize(it.text, QUEUE_NAME_CHARS))})
	if ui.row(.Center, id = fmt.tprintf("###q_%s", id)) {
		ui.spacer(ui.px(em * TRAY_PAD_EM))
		text("n", it.delivery == .Queue ? fmt.tprintf("%d", n) : "›", hex(HEX_FAINT), note, ui.px(em * QUEUE_MARK_W_EM))
		line := preview_text(it.text)
		if line == "" { line = "(no text)" }
		text("t", ellipsize(line, QUEUE_LINE_CHARS), busy ? hex(HEX_FAINT) : hex(HEX_TEXT_SOFT), ui.Style_Mod{font_size = math.round(em * FS_NOTE)}, ui.fill())
		if it.files > 0 {
			ui.spacer(ui.px(em * 0.5))
			text("f", it.files == 1 ? "1 file" : fmt.tprintf("%d files", it.files), hex(HEX_FAINT), note)
		}
		wide := app.column_w > em * QUEUE_WORDS_MIN_EM
		switch {
		case editing:
			ui.spacer(ui.px(em * 0.7))
			text("e", "editing", accent(), note)
		case busy:
			ui.spacer(ui.px(em * 0.7))
			text("b", it.act == .Sending ? "sending…" : it.act == .Removing ? "removing…" : "changing…", hex(HEX_FAINT), note)
		case:
			if !it.skills && queue_action("###edit", "Edit", ICO_EDIT, wide, em) { queue_edit(app, id) }
			if it.delivery == .Queue && queue_action("###now", "Send now", ICO_SEND, wide, em) { queue_send_now(app, id) }
			if queue_action("###rm", "Remove", ICO_CANCEL, wide, em) { queue_remove(app, id) }
		}
		ui.spacer(ui.px(em * TRAY_PAD_EM))
	}
}

// Its height is bounded, and it scrolls: a long list does not push the composer away.
queue_list :: proc(app: ^App, em: f32) {
	q := &app.cx.queue
	if q.session != app.chat.id { return }
	n := len(q.items)
	if n == 0 {
		if q.read.state == .Failed {   // (a server without an inbox refuses: that has nothing to say)
			ui.next({width = ui.fill(), height = ui.children_sum(), axis = .X, cross = .Center})
			if ui.row(.Center, id = "###q_failed") {
				ui.spacer(ui.px(em * 0.5))
				if hint_action("###q_again", "What waits for this session could not be read  ·  Try again", em, app.mono) { queue_read(app) }
			}
			ui.spacer(ui.px(em * 0.25))
		}
		return
	}
	head_h := math.round(em * QUEUE_HEAD_H_EM)
	row_h := math.round(em * QUEUE_ROW_H_EM)
	list_h := f32(min(n, QUEUE_ROWS_SHOWN)) * row_h
	ui.next({width = ui.fill(), height = ui.px(head_h + list_h + math.round(em * 0.3)), axis = .Y})
	ui.a11y({role = .Group, name = "Pending messages"})
	box := ui.build_box({}, "###q_well")
	box.custom = tray_draw
	if ui.parent(box) {
		ui.next({width = ui.fill(), height = ui.px(head_h), axis = .X, cross = .Center})
		if ui.row(.Center, id = "###q_head") {
			ui.spacer(ui.px(em * TRAY_PAD_EM))
			text("h", fmt.tprintf("PENDING  %d", n), hex(HEX_FAINT), ui.Style_Mod{font = app.mono_bold, font_size = math.round(em * FS_CAPTION)})
			ui.spacer(ui.px(em * 0.9))
			// (the row cuts what has no room: what matters comes first)
			text("w", app.chat.busy ? "not sent yet  ·  queued ones go when the turn ends" : "not sent  ·  the run stopped, these wait", hex(HEX_FAINT), ui.Style_Mod{font = app.mono, font_size = math.round(em * FS_CAPTION)}, ui.fill())
			ui.spacer(ui.px(em * TRAY_PAD_EM))
		}
		ui.next({width = ui.fill(), height = ui.px(list_h)})
		if ui.scroll_y("###q_scroll") {
			ui.next({width = ui.fill(), height = ui.children_sum(), axis = .Y})
			if ui.column(id = "###q_rows") {
				shown := 0
				// (an action may take its item out: the list is walked by id)
				ids := make([]string, n, context.temp_allocator)
				for it, i in q.items { ids[i] = strings.clone(it.id, context.temp_allocator) }
				for id in ids {
					it := queue_find(app, id)
					if it == nil { continue }
					if it.delivery == .Queue { shown += 1 }
					queue_row(app, it, shown, em)
				}
			}
		}
	}
	ui.spacer(ui.px(em * 0.45))
}

// In the composer, over what is written: what Enter will do is not what it usually does.
queue_edit_banner :: proc(app: ^App, em: f32) {
	if !queue_editing(app) { return }
	q := &app.cx.queue
	note := ui.Style_Mod{font = app.mono, font_size = math.round(em * FS_CAPTION)}
	ui.next({width = ui.fill(), height = ui.px(math.round(em * QUEUE_ROW_H_EM)), axis = .X, cross = .Center})
	if ui.row(.Center, id = "###q_banner") {
		ui.spacer(ui.px(em * 0.85))
		glyph(ICO_EDIT, accent(), math.round(em * ICON_SMALL), em * 1.1)
		ui.spacer(ui.px(em * 0.25))
		text("t", "Editing a pending message", accent(), ui.Style_Mod{font_size = math.round(em * FS_NOTE)})
		if len(q.items) > 1 && q.items[len(q.items) - 1].id != q.edit.id && app.column_w > em * QUEUE_WORDS_MIN_EM {
			ui.spacer(ui.px(em * 0.6))
			text("o", "it goes back last", hex(HEX_FAINT), note)
		}
		ui.spacer(ui.fill())
		if hint_action("###q_cancel", "Esc  cancel", em, app.mono) { queue_edit_end(app, .Cancel) }
		ui.spacer(ui.px(em * 0.85))
	}
}
