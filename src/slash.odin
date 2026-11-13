// The server's commands, proposed as one types: `/` at the start of the composer opens a list of those whose name matches
// what follows it (subsequence matching, the best first). Up and Down choose, Tab or Enter puts `/name ` in the composer,
// Escape closes it for this word. Enter on a name typed in full sends it, as before (slash_send).
package ocn

import "core:encoding/json"
import "core:strings"
import "gt:ui"
import lucide "gt:lucide"

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

// The commands that match `query`, best first (indices into app.cx.slash), at most MENTION_ROWS.
slash_matches :: proc(app: ^App, query: string) -> []int {
	hits := ui.rank(query, app.cx.slash[:], proc(s: ^Slash, _: rawptr) -> ui.Rank_Entry { return {label = s.name} }, match = ui.rank_fuzzy, cache = &app.composer.slash_pick.search)
	out := make([dynamic]int, context.temp_allocator)
	for h in hits {
		if len(out) == MENTION_ROWS { break }
		append(&out, h.index)
	}
	return out[:]
}

// After the editor: what the caret stands on now.
slash_track :: proc(app: ^App) {
	p := &app.composer.slash_pick
	a := &app.composer.area
	query, ok := slash_word(ui.text_edit_string(a), a.cursor)
	if !ok || a.cursor != a.mark || app.chat.id == "" {   // (a new session's first prompt is no command: slash_send)
		p.open, p.dismissed = false, false
		return
	}
	if !app.composer.focused {
		if !ui.hot_within(p.list) { p.open = false }   // (a press on a row leaves the editor: it is the click that chooses)
		return
	}
	if query != p.query {
		delete(p.query)
		p.query = strings.clone(query)
		p.sel, p.dismissed = 0, false
	}
	if p.dismissed { return }
	p.open = true
	if !app.cx.have_slash && !flying(app, .Slash, "") { request(app, .Slash, "GET", "/api/command") }
}

slash_shown :: proc(app: ^App) -> bool {
	p := &app.composer.slash_pick
	return p.open && len(slash_matches(app, p.query)) > 0
}

@(private = "file")
slash_choose :: proc(app: ^App, at: int) {
	a := &app.composer.area
	a.mark = 0   // (what was typed goes: `/` and the word)
	area_insert(a, strings.concatenate({"/", app.cx.slash[at].name, " "}, context.temp_allocator))
	app.composer.slash_pick.open = false
	app.composer.focus_next = true
}

// Before the editor and before Enter sends: the list has the keys it needs.
slash_keys :: proc(app: ^App) {
	p := &app.composer.slash_pick
	if !slash_shown(app) { return }
	hits := slash_matches(app, p.query)
	n := len(hits)
	p.sel = clamp(p.sel, 0, n - 1)
	if ui.key_press(.Down) { p.sel = (p.sel + 1) % n }
	if ui.key_press(.Up) { p.sel = (p.sel + n - 1) % n }
	if ui.key_press(.Escape) { p.open, p.dismissed = false, true; return }
	if ui.key_press(.Tab) { slash_choose(app, hits[p.sel]); return }
	// (Enter on a command typed in full sends it)
	if app.cx.slash[hits[p.sel]].name == p.query { return }
	if ui.key_press(.Return) { slash_choose(app, hits[p.sel]) }
}

// Over the text of the composer, in its well.
slash_list :: proc(app: ^App, em: f32) {
	p := &app.composer.slash_pick
	if !slash_shown(app) { return }
	hits := slash_matches(app, p.query)
	rows := make([]Completion_Row, len(hits), context.temp_allocator)
	for at, k in hits { rows[k] = {lucide.SQUARE_TERMINAL, strings.concatenate({"/", app.cx.slash[at].name}, context.temp_allocator), app.cx.slash[at].description} }
	clicked: int
	clicked, p.list = completion_list(app, "###slash_list", rows, p.sel, em)
	if clicked >= 0 { slash_choose(app, hits[clicked]) }
}

////////////////////////////////
// What the answers to its requests do (net.odin REQ_FACTS)

slash_on_ok :: proc(app: ^App, r: ^Request, v: json.Value) {
	list := make([dynamic]Slash, context.temp_allocator)
	for it in jarr(v, "data") { append(&list, Slash{strings.clone(jstr(it, "name")), strings.clone(jstr(it, "description"))}) }
	slash_load(app, list[:])
	outgoing_catalog(app)
}

slash_on_fail :: proc(app: ^App, r: ^Request, f: Failure, message: string) -> (told: bool) {
	outgoing_catalog(app)   // (what waited for the commands goes as a prompt: nothing is lost)
	return false
}

// "/name what follows", when the server has a command of that name. The server's commands not read yet: it waits for them
// (outgoing_slash_wait), and goes as a prompt if the name is not one.
slash_send :: proc(app: ^App, t: string, fields := "") -> bool {
	name, rest, ok := slash_split(t)
	if !ok { return false }
	if !app.cx.have_slash { outgoing_slash_wait(app, t, fields); return true }
	if !slash_known(app, name) { return false }
	outgoing_command(app, t, name, rest, fields)
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
