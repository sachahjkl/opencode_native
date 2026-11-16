// The composer is each session's own: what is typed in one (its text, its attachments, the files and agents it names) waits
// there while another is shown, and comes back with it. The home page has its own, under the empty id. A prompt being edited
// from the inbox, or a step through the history, gives the composer back its own text first.
//
// The texts are kept on disk too (drafts.json, beside the preferences), a second after the typing stops (at most every
// DRAFTS_SAVE_MOST_MS while it goes on), and when the program closes: a crash loses that second at most. The file is read at
// the start and written by a worker (app.stores.drafts, stores.odin). Only the texts: an attachment is an image's data, and
// a mention's file is the server's; they live as long as the program.
package ocn

import tk_json "gt:json"
import "core:encoding/json"
import "core:fmt"
import "core:strings"
import store "gt:store"
import "gt:ui"

DRAFTS_SAVE_MS      :: 1000
DRAFTS_SAVE_MOST_MS :: 5000

// The composer changed: the texts go to disk in a moment.
drafts_save_soon :: proc(app: ^App) { ui.deferred_ask(&app.cx.due[.Drafts], DRAFTS_SAVE_MS, DRAFTS_SAVE_MOST_MS) }

// Each frame the composer is built: what it holds against what it held, so that whatever changed it (a key, a prompt sent and
// the composer emptied, a prompt that came back) reaches the disk. (A sent prompt left on disk came back at the next start.)
drafts_track :: proc(app: ^App, pane: ^Chat_Pane) {
	text := ui.text_edit_string(&pane.composer.area)
	if text == pane.composer.drafts_seen { return }
	delete(pane.composer.drafts_seen)
	pane.composer.drafts_seen = strings.clone(text)
	drafts_save_soon(app)
}

// Every session's text, those shown from their pane's composer, as JSON: {"<session id>": "<text>", ...} ("" is the home page).
drafts_json :: proc(app: ^App) -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_byte(&b, '{')
	n := 0
	put :: proc(b: ^strings.Builder, n: ^int, id, text: string) {
		if strings.trim_space(text) == "" { return }
		if n^ > 0 { strings.write_byte(b, ',') }
		fmt.sbprintf(b, "%s:%s", tk_json.quote(id), tk_json.quote(text))
		n^ += 1
	}
	for id, d in app.drafts { if !pane_shows_draft(app, id) { put(&b, &n, id, d.text) } }
	// (a session in two panes: a key is said once, with the texts of both joined, as they are when one pane leaves)
	for &pane, i in app.panes {
		if !pane_is_shown(app, i) { continue }
		first := true
		for &other, j in app.panes[:i] { if pane_is_shown(app, j) && other.chat.id == pane.chat.id { first = false } }
		if !first { continue }
		text := ui.text_edit_string(&pane.composer.area)
		for &other, j in app.panes[i + 1:] {
			if pane_is_shown(app, i + 1 + j) && other.chat.id == pane.chat.id { text = drafts_join(text, ui.text_edit_string(&other.composer.area), context.temp_allocator) }
		}
		put(&b, &n, pane.chat.id, text)
	}
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
		if id in app.drafts { continue }
		app.drafts[strings.clone(id)] = Draft{text = strings.clone(string(s))}
	}
	for &pane, i in app.panes { if pane_is_shown(app, i) { draft_enter(app, &pane) } }
}

// A pane shows that session, its draft in its composer ("" is the home page: a pane on it shows it too).
@(private = "file")
pane_shows_draft :: proc(app: ^App, id: string) -> bool {
	for &pane, i in app.panes { if pane_is_shown(app, i) && pane.chat.id == id { return true } }
	return false
}

Draft :: struct {
	text:        string,              // (owned)
	attachments: [dynamic]Attachment,
	mentions:    [dynamic]Mention,
}

// Before the session shown changes: what the composer holds goes to its session's draft, and the composer is empty. The draft of
// a session that another pane still shows is in that pane's composer (src/md/features/chat-panes.md, "One session in both panes"):
// the text goes there, after its own.
draft_leave :: proc(app: ^App, pane: ^Chat_Pane) {
	if queue_editing(app, pane) { queue_edit_end(app, pane, .Cancel) }   // (the inbox's prompt goes back: the composer gets its own text)
	history_leave(app, pane, true)
	c := &pane.composer
	text := ui.text_edit_string(&pane.composer.area)
	empty := strings.trim_space(text) == "" && len(c.attachments) == 0 && len(c.mentions.chosen) == 0
	if other := pane_also_showing(app, pane); other != nil {
		if !empty {
			oc := &other.composer
			composer_append(&oc.area, text)
			append(&oc.attachments, ..c.attachments[:])
			append(&oc.mentions.chosen, ..c.mentions.chosen[:])
			clear(&c.attachments)
			clear(&c.mentions.chosen)
			drafts_save_soon(app)
		}
		ui.text_edit_set(&pane.composer.area, "")
		return
	}
	if empty { draft_drop(app, pane.chat.id); return }
	d, known := &app.drafts[pane.chat.id]
	if !known {
		app.drafts[strings.clone(pane.chat.id)] = {}
		d = &app.drafts[pane.chat.id]
	}
	// (joined, not replaced: nothing that waits there is lost, whatever put it there)
	joined := drafts_join(d.text, text)
	delete(d.text)
	d.text = joined
	append(&d.attachments, ..c.attachments[:])
	clear(&c.attachments)
	append(&d.mentions, ..c.mentions.chosen[:])
	clear(&c.mentions.chosen)
	ui.text_edit_set(&pane.composer.area, "")
	drafts_save_soon(app)
}

// Another shown pane on the session `pane` shows, or nil.
@(private = "file")
pane_also_showing :: proc(app: ^App, pane: ^Chat_Pane, chat := "") -> ^Chat_Pane {
	id := chat != "" ? chat : pane.chat.id
	for &other, i in app.panes {
		if &other != pane && pane_is_shown(app, i) && other.chat.id == id { return &other }
	}
	return nil
}

// Two texts of one session as one: a blank line between them; one alone when the other is empty or the same.
drafts_join :: proc(a, b: string, allocator := context.allocator) -> string {
	ta, tb := strings.trim_space(a), strings.trim_space(b)
	switch {
	case tb == "" || ta == tb: return strings.clone(a, allocator)
	case ta == "":             return strings.clone(b, allocator)
	}
	return strings.concatenate({strings.trim_right_space(a), "\n\n", b}, allocator)
}

// `text` after what a composer holds, its caret and its selection where they were: the person may be typing in it. (Its undo
// starts over, as for a prompt that comes back: the steps before would take the text away again.)
@(private = "file")
composer_append :: proc(area: ^ui.Text_Edit, text: string) {
	had := ui.text_edit_string(area)
	if strings.trim_space(had) == "" { ui.text_edit_set(area, text); return }
	keep := len(strings.trim_right_space(had))
	cursor, mark := min(area.cursor, keep), min(area.mark, keep)
	ui.text_edit_set(area, drafts_join(had, text, context.temp_allocator))
	area.cursor, area.mark = cursor, mark
}

// After it changed: the session's draft, if it has one, is in the composer again.
draft_enter :: proc(app: ^App, pane: ^Chat_Pane) {
	c := &pane.composer
	d, known := &app.drafts[pane.chat.id]
	if !known { return }
	ui.text_edit_set(&pane.composer.area, d.text)
	append(&c.attachments, ..d.attachments[:])
	append(&c.mentions.chosen, ..d.mentions[:])
	clear(&d.attachments)
	clear(&d.mentions)
	draft_drop(app, pane.chat.id)
}

// What came for the composer of session `chat` in `pane` (an attachment read on its thread, a file's path for the text): in
// that composer while the pane still shows that session, else in another pane's that shows it (its draft is there), else in the
// session's draft, which a composer gets when it shows it again.
composer_take :: proc(app: ^App, pane: ^Chat_Pane, chat: string, a: Maybe(Attachment), text: string) {
	pane := pane
	if chat != pane.chat.id {
		if other := pane_also_showing(app, pane, chat); other != nil { pane = other }
	}
	c := &pane.composer
	if chat == pane.chat.id {
		if x, ok := a.?; ok { append(&c.attachments, x) }
		if text != "" { area_insert(&pane.composer.area, text) }
		return
	}
	d, known := &app.drafts[chat]
	if !known {
		app.drafts[strings.clone(chat)] = {}
		d = &app.drafts[chat]
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
	key, d, known := map_entry_of(&app.drafts, id)
	if !known { return }
	draft_free(d)
	delete(d.attachments)
	delete(d.mentions)
	delete_key(&app.drafts, id)
	delete(key)
}

@(private = "file")
map_entry_of :: proc(m: ^map[string]Draft, id: string) -> (key: string, d: ^Draft, ok: bool) {
	for k, &v in m { if k == id { return k, &v, true } }
	return
}

drafts_destroy :: proc(app: ^App) {
	for k, &d in app.drafts {
		draft_free(&d)
		delete(d.attachments)
		delete(d.mentions)
		delete(k)
	}
	delete(app.drafts)
	app.drafts = nil
	for &pane in app.panes {
		delete(pane.composer.drafts_seen)
		pane.composer.drafts_seen = ""
	}
}
