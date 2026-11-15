// The server's commands, proposed as one types: `/` at the start of the composer opens a list of those whose name matches
// what follows it (subsequence matching, the best first). Up and Down choose, Tab or Enter puts `/name ` in the composer,
// Escape closes it for this word. Enter on a name typed in full sends it, as before (slash_send).
package ocn

import tk_json "gt:json"
import "core:encoding/json"
import "core:strings"
import "gt:ui"
import lucide "gt:lucide"
import i18n "gt:i18n"

Slash :: struct { name, description: string }   // a command of the server (owned), or of this program (CLIENT_COMMANDS)

// The commands this program runs itself, listed before the server's and run before a server's of the same name is looked up
// (client_command_run). Their descriptions are English, translated where they are shown.
CLIENT_COMMANDS := [?]Slash{
	{"btw", i18n.later("Ask something aside: a fork of this session, in a panel")},
}

// The client's commands, then the server's: what `/` and the palette's `>` list (temp memory, the descriptions translated).
slash_entries :: proc(app: ^App) -> []Slash {
	out := make([]Slash, len(CLIENT_COMMANDS) + len(app.cx.slash), context.temp_allocator)
	for c, i in CLIENT_COMMANDS { out[i] = {c.name, i18n.tr(c.description)} }
	copy(out[len(CLIENT_COMMANDS):], app.cx.slash[:])
	return out
}

// `t` is a command of this program: it ran (true), or it stays in the composer, with nothing to act on (no text, no session).
client_command_run :: proc(app: ^App, pane: ^Chat_Pane, t: string) -> bool {
	name, rest, ok := slash_split(t)
	if !ok || name != "btw" { return false }
	if rest == "" || pane.chat.id == "" { return true }
	btw_start(app, pane, rest)
	ui.text_edit_set(&pane.composer.area, "")
	return true
}

// The server's commands read (stream_up): the composer's `/` list and the palette's (its version moves).
slash_load :: proc(app: ^App, list: []Slash) {
	slash_forget(app)
	append(&app.cx.slash, ..list)
	app.cx.have_slash = true
}

// The server left: its commands are not the next one's (stream_up reads those).
slash_forget :: proc(app: ^App) {
	for s in app.cx.slash { delete(s.name); delete(s.description) }
	clear(&app.cx.slash)
	app.cx.have_slash = false
	app.palette.server.version += 1
}

Slash_Pick :: struct {
	open:      bool,
	dismissed: bool,      // Escape: closed until the word changes
	query:     string,    // what follows the `/` (owned)
	sel:       int,
	list:      ui.Key,    // its box
	search:    ui.Fuzzy_Cache,   // the query and the names folded: the list is ranked several times a frame
}

// The command being typed: the composer starts with `/` and the caret is in its first word.
slash_word :: proc(text: string, cursor: int) -> (query: string, ok: bool) {
	if !strings.has_prefix(text, "/") || cursor < 1 || cursor > len(text) { return }
	q := text[1:cursor]
	if strings.contains_any(q, " \n\t") { return }
	return q, true
}

// The commands that match `query`, best first (indices into slash_entries), at most MENTION_ROWS.
slash_matches :: proc(app: ^App, pane: ^Chat_Pane, query: string) -> []int {
	hits := ui.rank(query, slash_entries(app), proc(s: ^Slash, _: rawptr) -> ui.Rank_Entry { return {label = s.name} }, match = ui.rank_fuzzy, cache = &pane.composer.slash_pick.search)
	out := make([dynamic]int, context.temp_allocator)
	for h in hits {
		if len(out) == MENTION_ROWS { break }
		append(&out, h.index)
	}
	return out[:]
}

// After the editor: what the caret stands on now.
slash_track :: proc(app: ^App, pane: ^Chat_Pane) {
	p := &pane.composer.slash_pick
	a := &pane.composer.area
	query, ok := slash_word(ui.text_edit_string(a), a.cursor)
	if !ok || a.cursor != a.mark || pane.chat.id == "" {   // (a new session's first prompt is no command: slash_send)
		p.open, p.dismissed = false, false
		return
	}
	if !pane.composer.focused {
		if !ui.hot_within(p.list) { p.open = false }   // (a press on a row leaves the editor: it is the click that chooses)
		return
	}
	if query != p.query {
		delete(p.query)
		p.query = strings.clone(query)
		p.sel, p.dismissed = 0, false
	}
	if p.dismissed { return }
	// (read again at each opening, whatever was read before: a server that has just started lists its commands before its
	// plugins add theirs, and a list read once would stay that one for the program's life; the one read shows meanwhile)
	if !p.open && !flying(app, .Slash, "") { request(app, .Slash, "GET", "/api/command") }
	p.open = true
}

slash_shown :: proc(app: ^App, pane: ^Chat_Pane) -> bool {
	p := &pane.composer.slash_pick
	return p.open && len(slash_matches(app, pane, p.query)) > 0
}

@(private = "file")
slash_choose :: proc(app: ^App, pane: ^Chat_Pane, at: int) {
	a := &pane.composer.area
	a.mark = 0   // (what was typed goes: `/` and the word)
	area_insert(a, strings.concatenate({"/", slash_entries(app)[at].name, " "}, context.temp_allocator))
	pane.composer.slash_pick.open = false
	pane.composer.focus_next = true
}

// Before the editor and before Enter sends: the list has the keys it needs.
slash_keys :: proc(app: ^App, pane: ^Chat_Pane) {
	p := &pane.composer.slash_pick
	if !slash_shown(app, pane) { return }
	hits := slash_matches(app, pane, p.query)
	n := len(hits)
	p.sel = clamp(p.sel, 0, n - 1)
	if ui.key_press(.Down) { p.sel = (p.sel + 1) % n }
	if ui.key_press(.Up) { p.sel = (p.sel + n - 1) % n }
	if ui.key_press(.Escape) { p.open, p.dismissed = false, true; return }
	if ui.key_press(.Tab) { slash_choose(app, pane, hits[p.sel]); return }
	// (Enter on a command typed in full sends it)
	if slash_entries(app)[hits[p.sel]].name == p.query { return }
	if ui.key_press(.Return) { slash_choose(app, pane, hits[p.sel]) }
}

// Over the text of the composer, in its well.
slash_list :: proc(app: ^App, pane: ^Chat_Pane, em: f32) {
	p := &pane.composer.slash_pick
	if !slash_shown(app, pane) { return }
	hits := slash_matches(app, pane, p.query)
	rows := make([]Completion_Row, len(hits), context.temp_allocator)
	all := slash_entries(app)
	for at, k in hits { rows[k] = {lucide.SQUARE_TERMINAL, strings.concatenate({"/", all[at].name}, context.temp_allocator), all[at].description} }
	clicked: int
	clicked, p.list = completion_list(app, "###slash_list", rows, p.sel, em)
	if clicked >= 0 { slash_choose(app, pane, hits[clicked]) }
}

////////////////////////////////
// What the answers to its requests do (net.odin REQ_FACTS)

slash_on_ok :: proc(app: ^App, r: ^Request, v: json.Value) {
	list := make([dynamic]Slash, context.temp_allocator)
	for it in tk_json.array(v, "data") { append(&list, Slash{strings.clone(tk_json.text(it, "name")), strings.clone(tk_json.text(it, "description"))}) }
	slash_load(app, list[:])
	outgoing_catalog(app)
}

slash_on_fail :: proc(app: ^App, r: ^Request, f: Failure, message: string) -> (told: bool) {
	outgoing_catalog(app)   // (what waited for the commands goes as a prompt: nothing is lost)
	return false
}

// "/name what follows", when the server has a command of that name. The server's commands not read yet: it waits for them
// (outgoing_slash_wait), and goes as a prompt if the name is not one.
slash_send :: proc(app: ^App, pane: ^Chat_Pane, t: string, fields := "") -> bool {
	name, rest, ok := slash_split(t)
	if !ok { return false }
	if !app.cx.have_slash { outgoing_slash_wait(app, pane, t, fields); return true }
	if !slash_known(app, name) { return false }
	outgoing_command(app, pane, t, name, rest, fields)
	return true
}

// "/name what follows" as its name and what follows; ok: it starts with "/".
slash_split :: proc(t: string) -> (name, rest: string, ok: bool) {
	if !strings.has_prefix(t, "/") { return }
	name = t[1:]
	if i := strings.index_any(name, " \n"); i >= 0 { name, rest = name[:i], strings.trim_space(name[i:]) }
	return name, rest, true
}

slash_known :: proc(app: ^App, name: string) -> bool {
	for s in app.cx.slash { if s.name == name { return true } }
	return false
}
