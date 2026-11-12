// The composer is each session's own: what is typed in one (its text, its attachments, the files and agents it names) waits
// there while another is shown, and comes back with it. The home page has its own, under the empty id. A prompt being edited
// from the inbox, or a step through the history, gives the composer back its own text first.
//
// The texts are kept on disk too (drafts.json, beside the preferences), a second after the typing stops (at most every
// DRAFTS_SAVE_MOST_MS while it goes on), and when the program closes: a crash loses that second at most. The file is read at
// the start and written by a worker (app.stores.drafts, stores.odin). Only the texts: an attachment is an image's data, and
// a mention's file is the server's; they live as long as the program.
package ocn

import "core:encoding/json"
import "core:fmt"
import "core:strings"
import store "gt:store"
import "gt:ui"

DRAFTS_SAVE_MS      :: 1000
DRAFTS_SAVE_MOST_MS :: 5000

// The composer changed: the texts go to disk in a moment.
drafts_save_soon :: proc(app: ^App) { deferred_ask(&app.cx.due[.Drafts], DRAFTS_SAVE_MS, DRAFTS_SAVE_MOST_MS) }

// Each frame the composer is built: what it holds against what it held, so that whatever changed it (a key, a prompt sent and
// the composer emptied, a prompt that came back) reaches the disk. (A sent prompt left on disk came back at the next start.)
drafts_track :: proc(app: ^App) {
	text := ui.area_string(&app.composer.area)
	if text == app.composer.drafts_seen { return }
	delete(app.composer.drafts_seen)
	app.composer.drafts_seen = strings.clone(text)
	drafts_save_soon(app)
}

// Every session's text, the one shown from the composer, as JSON: {"<session id>": "<text>", ...} ("" is the home page).
drafts_json :: proc(app: ^App) -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_byte(&b, '{')
	n := 0
	put :: proc(b: ^strings.Builder, n: ^int, id, text: string) {
		if strings.trim_space(text) == "" { return }
		if n^ > 0 { strings.write_byte(b, ',') }
		fmt.sbprintf(b, "%s:%s", jquote(id), jquote(text))
		n^ += 1
	}
	for id, d in app.composer.drafts { if id != app.chat.id { put(&b, &n, id, d.text) } }
	put(&b, &n, app.chat.id, ui.area_string(&app.composer.area))
	strings.write_byte(&b, '}')
	return strings.to_string(b)
}

// To disk, by the drafts' worker: written beside, then put in place (a crash in the middle leaves the last whole one).
drafts_save :: proc(app: ^App) {
	if app.prefs_file == "" { return }   // (a test: nothing on disk)
	store.writer_put(&app.stores.drafts, transmute([]u8)drafts_json(app))
}

// At start: the texts of last time (read with the other stores, before the window), each in its session's draft; the home
// page's in the composer.
drafts_load :: proc(app: ^App) {
	text := app.stores.drafts_read
	app.stores.drafts_read = ""
	defer delete(text)
	if app.prefs_file == "" || text == "" { return }
	drafts_load_json(app, text)
}

drafts_load_json :: proc(app: ^App, text: string) {
	v, bad := json.parse_string(text, allocator = context.temp_allocator)
	obj, ok := v.(json.Object)
	if bad != nil || !ok { return }
	for id, t in obj {
		s, is_text := t.(json.String)
		if !is_text || strings.trim_space(string(s)) == "" { continue }
		if id in app.composer.drafts { continue }
		app.composer.drafts[strings.clone(id)] = Draft{text = strings.clone(string(s))}
	}
	draft_enter(app)
}

Draft :: struct {
	text:        string,              // (owned)
	attachments: [dynamic]Attachment,
	mentions:    [dynamic]Mention,
}

// Before the session shown changes: what the composer holds goes to its session's draft, and the composer is empty.
draft_leave :: proc(app: ^App) {
	if queue_editing(app) { queue_edit_end(app, .Cancel) }   // (the inbox's prompt goes back: the composer gets its own text)
	history_leave(app, true)
	c := &app.composer
	text := ui.area_string(&app.composer.area)
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
	ui.area_set(&app.composer.area, "")
	drafts_save_soon(app)
}

// After it changed: the session's draft, if it has one, is in the composer again.
draft_enter :: proc(app: ^App) {
	c := &app.composer
	d, known := &c.drafts[app.chat.id]
	if !known { return }
	ui.area_set(&app.composer.area, d.text)
	append(&c.attachments, ..d.attachments[:])
	append(&c.mentions.chosen, ..d.mentions[:])
	clear(&d.attachments)
	clear(&d.mentions)
	draft_drop(app, app.chat.id)
}

// What came for the composer of session `chat` (an attachment read on its thread, a file's path for the text): in the
// composer when that session is shown, else in its draft, which its composer gets when it is shown again.
composer_take :: proc(app: ^App, chat: string, a: Maybe(Attachment), text: string) {
	c := &app.composer
	if chat == app.chat.id {
		if x, ok := a.?; ok { append(&c.attachments, x) }
		if text != "" { area_insert(&app.composer.area, text) }
		return
	}
	d, known := &c.drafts[chat]
	if !known {
		c.drafts[strings.clone(chat)] = {}
		d = &c.drafts[chat]
	}
	if x, ok := a.?; ok { append(&d.attachments, x) }
	if text != "" {
		joined := strings.concatenate({d.text, text})
		delete(d.text)
		d.text = joined
	}
	drafts_save_soon(app)
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
	key, d, known := map_entry_of(&app.composer.drafts, id)
	if !known { return }
	draft_free(d)
	delete(d.attachments)
	delete(d.mentions)
	delete_key(&app.composer.drafts, id)
	delete(key)
}

@(private = "file")
map_entry_of :: proc(m: ^map[string]Draft, id: string) -> (key: string, d: ^Draft, ok: bool) {
	for k, &v in m { if k == id { return k, &v, true } }
	return
}

drafts_destroy :: proc(app: ^App) {
	for k, &d in app.composer.drafts {
		draft_free(&d)
		delete(d.attachments)
		delete(d.mentions)
		delete(k)
	}
	delete(app.composer.drafts)
	app.composer.drafts = nil
	delete(app.composer.drafts_seen)
	app.composer.drafts_seen = ""
}
