// The composer is each session's own: what is typed in one (its text, its attachments, the files and agents it names) waits
// there while another is shown, and comes back with it. The home page has its own, under the empty id. A prompt being edited
// from the inbox, or a step through the history, gives the composer back its own text first.
package occ

import "core:strings"
import "gt:ui"

Draft :: struct {
	text:        string,              // (owned)
	attachments: [dynamic]Attachment,
	mentions:    [dynamic]Mention,
}

// Before the session shown changes: what the composer holds goes to its session's draft, and the composer is empty.
draft_leave :: proc(app: ^App) {
	if queue_editing(app) { queue_edit_end(app, .Cancel) }   // (the inbox's prompt goes back: the composer gets its own text)
	history_leave(app, true)
	c := &app.cx
	text := ui.area_string(&app.composer)
	if strings.trim_space(text) == "" && len(c.attachments) == 0 && len(c.mentions.chosen) == 0 { draft_drop(app, app.chat.id); return }
	d, known := &c.drafts[app.chat.id]
	if !known {
		c.drafts[strings.clone(app.chat.id)] = {}
		d = &c.drafts[app.chat.id]
	}
	draft_free(d)
	d.text = strings.clone(text)
	append(&d.attachments, ..c.attachments[:])
	clear(&c.attachments)
	append(&d.mentions, ..c.mentions.chosen[:])
	clear(&c.mentions.chosen)
	ui.area_set(&app.composer, "")
}

// After it changed: the session's draft, if it has one, is in the composer again.
draft_enter :: proc(app: ^App) {
	c := &app.cx
	d, known := &c.drafts[app.chat.id]
	if !known { return }
	ui.area_set(&app.composer, d.text)
	append(&c.attachments, ..d.attachments[:])
	append(&c.mentions.chosen, ..d.mentions[:])
	clear(&d.attachments)
	clear(&d.mentions)
	draft_drop(app, app.chat.id)
}

@(private = "file")
draft_free :: proc(d: ^Draft) {
	delete(d.text)
	d.text = ""
	for a in d.attachments { delete(a.name); delete(a.uri) }
	for m in d.mentions { delete(m.text); delete(m.target); delete(m.name) }
	clear(&d.attachments)
	clear(&d.mentions)
}

@(private = "file")
draft_drop :: proc(app: ^App, id: string) {
	key, d, known := map_entry_of(&app.cx.drafts, id)
	if !known { return }
	draft_free(d)
	delete(d.attachments)
	delete(d.mentions)
	delete_key(&app.cx.drafts, id)
	delete(key)
}

@(private = "file")
map_entry_of :: proc(m: ^map[string]Draft, id: string) -> (key: string, d: ^Draft, ok: bool) {
	for k, &v in m { if k == id { return k, &v, true } }
	return
}

drafts_destroy :: proc(app: ^App) {
	for k, &d in app.cx.drafts {
		draft_free(&d)
		delete(d.attachments)
		delete(d.mentions)
		delete(k)
	}
	delete(app.cx.drafts)
	app.cx.drafts = nil
}
