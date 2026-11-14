// The files of a session's folder, read from the server, which may be on another machine: `@` in the composer names one (or a sub-agent)
// for the prompt, the dialog browses them and shows one. A file named goes with the prompt as a file:// uri, which the server reads and
// inlines; the text keeps its `@path`, and the server is told where it stands in it.
package ocn

import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:mem/virtual"
import "core:path/filepath"
import "core:strings"
import "core:unicode/utf8"
import "gt:draw"
import "gt:platform"
import "gt:ui"
import lucide "gt:lucide"
import remote "gt:remote"
import i18n "gt:i18n"

// What a request says of the folder: the session's, or the one about to get a session; "": the server's own.
@(private = "file")
files_dir :: proc(app: ^App) -> string {
	d := chat_dir(app)
	return d != "" ? d : app.chat.new_dir
}

// The server writes paths with the separators of its system; a prompt reads better with one kind.
path_clean :: proc(p: string) -> string {
	s, _ := strings.replace_all(strings.trim_right(p, `\/`), `\`, "/", context.temp_allocator)
	return s
}

// A file of `dir` as the server takes it: absolute, with what a uri cannot hold escaped.
file_uri :: proc(dir, rel: string) -> string {
	joined, _ := strings.replace_all(fmt.tprintf("%s/%s", strings.trim_right(dir, `\/`), rel), `\`, "/", context.temp_allocator)
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, strings.has_prefix(joined, "/") ? "file://" : "file:///")
	for c in transmute([]u8)joined {
		switch c {
		case 'A' ..= 'Z', 'a' ..= 'z', '0' ..= '9', '-', '_', '.', '~', '/', ':': strings.write_byte(&b, c)
		case: fmt.sbprintf(&b, "%%%02X", c)
		}
	}
	return strings.to_string(b)
}

////////////////////////////////
// @ in the composer

Mention_Kind :: enum u8 { File, Agent }

Mention_Hit :: struct {
	kind:   Mention_Kind,
	label:  string,   // the path, or the agent's name
	detail: string,
}

// A name chosen, kept until the prompt goes.
Mention :: struct {
	kind:   Mention_Kind,
	text:   string,   // as it stands in the prompt, `@` included (owned)
	target: string,   // the file's uri, or the agent's name (owned)
	name:   string,   // the file's name (owned)
}

Mentions :: struct {
	open:      bool,
	start:     int,      // the `@`, in bytes of the composer
	dismissed: Maybe(int),   // Escape at this `@`: it stays closed there
	query:     string,   // what comes after it (owned)
	sel:       int,
	list:      ui.Key,   // its box
	read:      remote.Remote,   // what is proposed for `query`
	folder:    string,   // the folder that was asked about: what is proposed is of no other (owned)
	dir:       string,   // the folder the server answered for (owned)
	hits:      [dynamic]Mention_Hit,
	arena:     virtual.Arena,
	chosen:    [dynamic]Mention,
}

// The `@word` the caret is at the end of. A mail address is not one: the `@` starts a word.
mention_word :: proc(text: string, cursor: int) -> (start: int, query: string, ok: bool) {
	if cursor > len(text) { return }
	i := cursor
	for i > 0 {
		c := text[i - 1]
		if c == ' ' || c == '\n' || c == '\t' { return }
		i -= 1
		if c == '@' {
			if i > 0 && !strings.contains_rune(" \n\t", rune(text[i - 1])) { return }
			return i, text[i + 1:cursor], true
		}
	}
	return
}

@(private = "file")
mention_ask :: proc(app: ^App) {
	m := &app.composer.mentions
	folder := files_dir(app)
	if folder != m.folder {
		mention_hits_clear(m)
		delete(m.folder)
		m.folder = strings.clone(folder)
	}
	q := location_query(folder)
	amp := q != "" ? "&" : ""
	remote.begin(&m.read)
	if m.query == "" {
		request(app, .Mention_Files, "GET", fmt.tprintf("/api/fs/list?%s", q), reading = &m.read)   // (the search wants a word)
	} else {
		request(app, .Mention_Files, "GET", fmt.tprintf("/api/fs/find?%s%squery=%s&type=file&limit=%d", q, amp, url_escape(m.query), MENTION_ROWS), reading = &m.read)
	}
}

@(private = "file")
mention_hits_clear :: proc(m: ^Mentions) {
	virtual.arena_destroy(&m.arena)
	clear(&m.hits)
	delete(m.dir)
	m.dir = ""
	m.sel = 0
}

// What was asked was not answered: what was proposed for the word before is not for this one.
mention_failed :: proc(app: ^App) { mention_hits_clear(&app.composer.mentions) }

// After the editor: what the caret stands on now.
mention_track :: proc(app: ^App) {
	m := &app.composer.mentions
	a := &app.composer.area
	start, query, ok := mention_word(ui.text_edit_string(a), a.cursor)
	if !ok || a.cursor != a.mark {
		m.open, m.dismissed = false, nil
		return
	}
	if !app.composer.focused {
		if !ui.hot_within(m.list) { m.open = false }   // (a press on a row of the list leaves the editor: it is the click that chooses)
		return
	}
	if at, dismissed := m.dismissed.?; dismissed && at == start { return }
	// (the session changed under it: the same word asks about another folder)
	if m.open && m.start == start && m.query == query && m.folder == files_dir(app) { return }
	m.open, m.start = true, start
	delete(m.query)
	m.query = strings.clone(query)
	m.sel = 0
	mention_ask(app)
}

// The answer of the list or the search, if it is still what is looked for; sub-agents that match come first, the best first.
mention_load :: proc(app: ^App, v: json.Value) {
	m := &app.composer.mentions
	if !m.open { return }
	sel := m.sel
	mention_hits_clear(m)
	m.sel = sel
	_ = virtual.arena_init_growing(&m.arena)
	a := virtual.arena_allocator(&m.arena)
	m.dir = strings.clone(jstr(v, "location", "directory"))
	for h in ui.rank(m.query, app.agents[:], proc(ag: ^Agent_Info, _: rawptr) -> ui.Rank_Entry { return {label = ag.id, skip = ag.mode != "subagent"} }, match = ui.rank_fuzzy) {
		ag := &app.agents[h.index]
		append(&m.hits, Mention_Hit{.Agent, strings.clone(ag.id, a), strings.clone(ag.description, a)})
	}
	for it in jarr(v, "data") {
		if len(m.hits) == MENTION_ROWS { break }
		if jstr(it, "type") != "file" { continue }
		p := path_clean(jstr(it, "path"))
		append(&m.hits, Mention_Hit{.File, strings.clone(p, a), ""})
	}
	m.sel = clamp(m.sel, 0, max(len(m.hits) - 1, 0))
}

// (Of another folder than the one the session shown is in, nothing can be chosen, whatever the next frame finds.)
mention_shown :: proc(app: ^App) -> bool {
	m := &app.composer.mentions
	return m.open && len(m.hits) > 0 && m.folder == files_dir(app)
}

// In place of what was typed, or at the caret: `@name `, remembered for the prompt.
@(private = "file")
mention_put :: proc(app: ^App, kind: Mention_Kind, label, target, name: string) {
	m := &app.composer.mentions
	t := fmt.tprintf("@%s", label)
	area_insert(&app.composer.area, fmt.tprintf("%s ", t))
	append(&m.chosen, Mention{kind, strings.clone(t), strings.clone(target), strings.clone(name)})
	m.open = false
	app.composer.focus_next = true
}

@(private = "file")
mention_choose :: proc(app: ^App, k: int) {
	m := &app.composer.mentions
	h := m.hits[k]
	a := &app.composer.area
	a.mark, a.cursor = m.start, a.cursor   // (what was typed goes)
	if h.kind == .File {
		mention_put(app, .File, h.label, file_uri(m.dir, h.label), filepath.base(h.label))
	} else {
		mention_put(app, .Agent, h.label, h.label, "")
	}
}

// Before the editor and before Enter sends: the list has the keys it needs.
mention_keys :: proc(app: ^App) {
	m := &app.composer.mentions
	if !mention_shown(app) { return }
	n := len(m.hits)
	if ui.key_press(.Down) { m.sel = (m.sel + 1) % n }
	if ui.key_press(.Up) { m.sel = (m.sel + n - 1) % n }
	if ui.key_press(.Escape) { m.open, m.dismissed = false, m.start; return }
	if ui.key_press(.Tab) || ui.key_press(.Return) { mention_choose(app, m.sel) }
}

// Escape belongs to a list over the composer (the `@` mentions, the `/` commands) while it is there, not to the run.
mention_takes_escape :: proc(app: ^App) -> bool { return (mention_shown(app) || slash_shown(app)) && app.composer.focused }

// A row of a list over the composer (the `@` mentions, the `/` commands).
Completion_Row :: struct { icon, label, detail: string }

@(private = "file")
Completion_Row_Draw :: struct { selected: bool }

// The rows over the text of the composer, in its well, `sel` lit. The row clicked (-1: none), and the list's box.
completion_list :: proc(app: ^App, id: string, rows: []Completion_Row, sel: int, em: f32) -> (clicked: int, list: ui.Key) {
	clicked = -1
	ui.next({width = ui.fill(), height = ui.children_sum(), axis = .Y})
	if ui.column(id = id) {
		list = ui.parent_box().key
		for &r, k in rows {
			ui.next({width = ui.fill(), height = ui.px(math.round(em * 1.9)), axis = .X, cross = .Center, cursor = .Hand})
			row := ui.build_box({.Clickable}, fmt.tprintf("###row_%d", k))
			d := ui.frame_new(Completion_Row_Draw)
			d.selected = k == sel
			row.custom = proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
				if (^Completion_Row_Draw)(user).selected {
					r := b.rect   // (flush: a highlight runs from one edge of the list to the other)
					draw_well(dc, r, 0, hex(HEX_PAL_SELECTED))   // (square: a row)
				}
			}
			row.custom_user = d
			if ui.signal(row).clicked { clicked = k }
			if ui.parent(row) {
				ui.spacer(ui.px(em * 0.9))
				glyph(r.icon, hex(HEX_FAINT), math.round(em * ICON_SMALL), em * 1.1)
				ui.spacer(ui.px(em * 0.3))
				text("n", r.label, hex(HEX_TEXT), ui.Style_Mod{font = app.mono, font_size = math.round(em * FS_SMALL)})
				if r.detail != "" {
					ui.spacer(ui.px(em * 0.8))
					text("d", ellipsize(r.detail, MENTION_DETAIL_CHARS), hex(HEX_FAINT), ui.Style_Mod{font_size = math.round(em * FS_CAPTION)})
				}
			}
		}
	}
	return
}

// Over the text of the composer, in its well.
mention_list :: proc(app: ^App, em: f32) {
	m := &app.composer.mentions
	if !mention_shown(app) { return }
	rows := make([]Completion_Row, len(m.hits), context.temp_allocator)
	for h, k in m.hits { rows[k] = {h.kind == .File ? lucide.FILE : lucide.BOT, h.label, h.detail} }
	clicked: int
	clicked, m.list = completion_list(app, "###mention_list", rows, m.sel, em)
	if clicked >= 0 { mention_choose(app, clicked) }
}

// Where a mention stands, as the server counts: in UTF-16 units, as JavaScript does.
utf16_len :: proc(s: string) -> int {
	n := 0
	for r in s { n += r > 0xFFFF ? 2 : 1 }
	return n
}

// The mentions still in `text`, as the JSON of a prompt says them.
mention_json :: proc(m: ^Mention, text: string) -> (mention: string, ok: bool) {
	at := strings.index(text, m.text)
	if at < 0 { return }
	start := utf16_len(text[:at])
	return fmt.tprintf(`{{"start":%d,"end":%d,"text":%s}}`, start, start + utf16_len(m.text), jquote(m.text)), true
}

mentions_clear :: proc(app: ^App) {
	m := &app.composer.mentions
	for c in m.chosen { delete(c.text); delete(c.target); delete(c.name) }
	clear(&m.chosen)
}

mentions_destroy :: proc(app: ^App) {
	m := &app.composer.mentions
	mentions_clear(app)
	delete(m.chosen); delete(m.hits); delete(m.query); delete(m.dir); delete(m.folder); delete(m.read.message)
	virtual.arena_destroy(&m.arena)
	m^ = {}
	delete(app.composer.slash_pick.query)   // (the other list over the composer: slash.odin)
	ui.fuzzy_cache_destroy(&app.composer.slash_pick.search)
	app.composer.slash_pick = {}
}

// What the server proposed, and what was chosen of it: a file's uri on the server left says nothing on the next one, and must not go with a
// prompt there. The words stay in the composer, which is the reader's and goes through server_forget whole: they go as plain text.
mentions_forget :: proc(app: ^App) {
	m := &app.composer.mentions
	mentions_clear(app)
	mention_hits_clear(m)
	m.open, m.dismissed = false, nil
	delete(m.folder); delete(m.query)
	m.folder, m.query = "", ""
	remote.reset(&m.read)
}

////////////////////////////////
// The dialog

// The toolkit's file browser on the session's folder, its subfolders searched as one types: the files chosen are mentioned in
// the prompt. The folder is the server's: this computer's files when the server is here, else its own (folders.odin).
@(private = "file")
Files_Job :: struct {
	app: ^App,
	dir: string,   // the session's folder (owned)
}

files_open :: proc(app: ^App) {
	dir := files_dir(app)
	j := new(Files_Job)
	j^ = {app, strings.clone(dir)}
	places: []platform.File_Place
	if dir != "" { places = {{name = base_name(dir), path = dir}} }
	ui.file_dialog(&app.state, .Open, {owner = app.win, title = i18n.tr("Files of the session"), start_dir = dir, places = places, multiple = true, all_files = true, find_deep = true, act = i18n.tr("Mention"), remember_id = "session_files"}, proc(r: platform.Dialog_Result, user: rawptr) {
		j := (^Files_Job)(user)
		defer { delete(j.dir); free(j) }
		if r.status != .Chosen { return }
		a := &j.app.composer.area
		a.mark = a.cursor
		for p in r.paths { file_mention(j.app, j.dir, p) }
	}, j, source = folders_are_here(app) ? nil : server_files(app, dir))
}

// `path` (absolute, the server's) mentioned in the prompt: by its path from the session's folder when it is in it, else whole.
@(private = "file")
file_mention :: proc(app: ^App, dir, path: string) {
	p := path_clean(path)
	d := path_clean(dir)
	if d != "" && strings.has_prefix(p, d) && len(p) > len(d) && p[len(d)] == '/' {
		rel := p[len(d) + 1:]
		mention_put(app, .File, rel, file_uri(dir, rel), filepath.base(rel))
		return
	}
	mention_put(app, .File, p, file_uri(filepath.dir(p), filepath.base(p)), filepath.base(p))
}

// What is shown of `raw`: its beginning when it is long, nothing when it is no text.
file_text :: proc(raw: string) -> (shown: string, is_text: bool) {
	head := raw[:min(len(raw), FILE_SNIFF_BYTES)]
	if strings.index_byte(head, 0) >= 0 { return "", false }
	shown = raw[:min(len(raw), FILE_VIEW_MAX_BYTES)]
	for len(shown) > 0 && len(shown) < len(raw) && !utf8.rune_start(raw[len(shown)]) { shown = shown[:len(shown) - 1] }   // (not in the middle of a character)
	return shown, utf8.valid_string(shown)
}

////////////////////////////////
// What the answers to its requests do (net.odin REQ_FACTS)

mention_files_on_ok :: proc(app: ^App, r: ^Request, v: json.Value) { mention_load(app, v) }

mention_files_on_fail :: proc(app: ^App, r: ^Request, f: Failure, message: string) -> (told: bool) {
	mention_failed(app)    // (what was proposed is not what is typed any more)
	return f == .Refused   // (a server without one, a folder gone: nothing to say)
}

