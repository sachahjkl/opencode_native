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
import "gt:ui"
import lucide "gt:lucide"

// What a request says of the folder: the session's, or the one about to get a session; "": the server's own.
@(private = "file")
files_dir :: proc(app: ^App) -> string {
	d := chat_dir(app)
	return d != "" ? d : app.chat.new_dir
}

// The server writes paths with the separators of its system; a prompt reads better with one kind.
@(private = "file")
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

// A path in the address of a request: each part escaped, the slashes kept.
@(private = "file")
path_escape :: proc(p: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	rest := p
	first := true
	for part in strings.split_iterator(&rest, "/") {
		if !first { strings.write_byte(&b, '/') }
		first = false
		strings.write_string(&b, url_escape(part))
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
	read:      Remote,   // what is proposed for `query`
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
	remote_begin(&m.read)
	if m.query == "" {
		request(app, .Mention_Files, "GET", fmt.tprintf("/api/fs/list?%s", q), remote = &m.read)   // (the search wants a word)
	} else {
		request(app, .Mention_Files, "GET", fmt.tprintf("/api/fs/find?%s%squery=%s&type=file&limit=%d", q, amp, url_escape(m.query), MENTION_ROWS), remote = &m.read)
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
	start, query, ok := mention_word(ui.area_string(a), a.cursor)
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
	remote_reset(&m.read)
}

////////////////////////////////
// The dialog

File_Row :: struct {
	path, name: string,
	directory:  bool,
}

Files :: struct {
	fresh:   bool,
	dir:     string,               // the session's folder (owned)
	at:      string,               // the folder shown, from it, "": itself (owned)
	field:   ui.Text_Field,
	searching: bool,               // what is read is a search
	sel:     int,                  // the row the keyboard is on
	read:    Remote,               // the rows
	rows:    [dynamic]File_Row,
	arena:   virtual.Arena,
	file:    string,               // the file shown (owned, "": none)
	file_read: Remote,             // it
	binary:  bool,                 // it is not text
	content: string,               // (owned)
	size:    int,
	version: u64,                  // one more at each reading: its text may have changed whatever its length
}

@(private = "file")
files_rows_clear :: proc(f: ^Files) {
	virtual.arena_destroy(&f.arena)
	clear(&f.rows)
	f.sel = 0
}

// The rows go with the folder they were of. (A search typed further keeps them, until what it finds.)
@(private = "file")
files_elsewhere :: proc(f: ^Files) {
	files_rows_clear(f)
	remote_reset(&f.read)
}

files_list :: proc(app: ^App) {
	f := &app.cx.files
	word := strings.trim_space(ui.field_string(&f.field))
	f.searching = word != ""
	q := location_query(f.dir)
	amp := q != "" ? "&" : ""
	remote_begin(&f.read)
	if f.searching {
		request(app, .Files_List, "GET", fmt.tprintf("/api/fs/find?%s%squery=%s&limit=%d", q, amp, url_escape(word), FILES_FOUND_MAX), remote = &f.read)
	} else {
		path := f.at != "" ? fmt.tprintf("%spath=%s", amp, url_escape(f.at)) : ""
		request(app, .Files_List, "GET", fmt.tprintf("/api/fs/list?%s%s", q, path), remote = &f.read)
	}
}

@(private = "file")
files_clear :: proc(f: ^Files) {
	delete(f.dir); delete(f.at); delete(f.file); delete(f.content)
	f.dir, f.at, f.file, f.content = "", "", "", ""
	f.binary, f.size = false, 0
	remote_reset(&f.file_read)
	files_elsewhere(f)
	ui.field_set(&f.field, "")
}

files_open :: proc(app: ^App) {
	f := &app.cx.files
	files_clear(f)
	f.dir = strings.clone(files_dir(app))
	app.cx.open[.Files], f.fresh = true, true
	files_list(app)
}

files_forget :: proc(app: ^App) {
	f := &app.cx.files
	app.cx.open[.Files] = false
	files_clear(f)
}

// Folders first, each kind by name; a search keeps the server's ranking.
files_load :: proc(app: ^App, v: json.Value) {
	f := &app.cx.files
	files_rows_clear(f)
	_ = virtual.arena_init_growing(&f.arena)
	a := virtual.arena_allocator(&f.arena)
	for pass in 0 ..< 2 {
		for it in jarr(v, "data") {
			directory := jstr(it, "type") == "directory"
			if directory != (pass == 0) { continue }
			p := path_clean(jstr(it, "path"))
			append(&f.rows, File_Row{strings.clone(p, a), strings.clone(f.searching ? p : filepath.base(p), a), directory})
		}
	}
}

file_show :: proc(app: ^App, path: string) {
	f := &app.cx.files
	name := strings.clone(path)
	delete(f.file)
	f.file = name
	file_read(app)
}

// (Also Try again.)
@(private = "file")
file_read :: proc(app: ^App) {
	f := &app.cx.files
	delete(f.content)
	f.content, f.binary, f.size = "", false, 0
	remote_reset(&f.file_read)
	remote_begin(&f.file_read)
	q := location_query(f.dir)
	request(app, .File_Read, "GET", fmt.tprintf("/api/fs/read/%s%s%s", path_escape(f.file), q != "" ? "?" : "", q), remote = &f.file_read)
}

// What is shown of `raw`: its beginning when it is long, nothing when it is no text.
file_text :: proc(raw: string) -> (shown: string, is_text: bool) {
	head := raw[:min(len(raw), FILE_SNIFF_BYTES)]
	if strings.index_byte(head, 0) >= 0 { return "", false }
	shown = raw[:min(len(raw), FILE_VIEW_MAX_BYTES)]
	for len(shown) > 0 && len(shown) < len(raw) && !utf8.rune_start(raw[len(shown)]) { shown = shown[:len(shown) - 1] }   // (not in the middle of a character)
	return shown, utf8.valid_string(shown)
}

file_loaded :: proc(app: ^App, raw: string) {
	f := &app.cx.files
	f.size = len(raw)
	shown, is_text := file_text(raw)
	f.binary = !is_text
	if !is_text { return }
	delete(f.content)
	f.content = strings.clone(shown)
	f.version += 1
}

@(private = "file")
files_up :: proc(app: ^App) {
	f := &app.cx.files
	i := strings.last_index_byte(f.at, '/')
	up := strings.clone(i >= 0 ? f.at[:i] : "")
	delete(f.at)
	f.at = up
	files_elsewhere(f)
	files_list(app)
}

files_dialog :: proc(app: ^App, em: f32) {
	f := &app.cx.files
	if !app.cx.open[.Files] { return }
	if ui.modal_sized("files", DIALOG_PREFERRED_EM[.Files] * em, &app.cx.dialogs[.Files], &app.cx.open[.Files], DIALOG_MIN_EM[.Files] * em) {
		dialog_backdrop()
		ui.spacer(ui.px(em * 0.9))
		ui.next({width = ui.fill(), height = ui.children_sum(), axis = .X, cross = .Center})
		if ui.row(.Center, id = "###fl_head") {
			ui.spacer(ui.px(em * DIALOG_MARGIN_EM))
			text("t", f.at != "" && !f.searching ? f.at : base_name(f.dir), hex(HEX_BRIGHT), ui.Style_Mod{font_size = math.round(em * FS_TITLE), height = ui.px(em * 2)}, ui.fill())
			ui.spacer(ui.px(em * 3))
		}
		ui.spacer(ui.px(em * 0.5))
		ui.next({width = ui.fill(), height = ui.fill(), axis = .X})
		if ui.row(id = "###fl_body") {
			ui.spacer(ui.px(em * DIALOG_MARGIN_EM))
			ui.next({width = ui.px(math.round(em * FILES_LIST_W_EM)), height = ui.fill(), axis = .Y})
			if ui.column(id = "###fl_left") { files_left(app, em) }
			ui.spacer(ui.px(em))
			ui.next({width = ui.fill(), height = ui.fill(), axis = .Y})
			if ui.column(id = "###fl_right") { files_right(app, em) }
			ui.spacer(ui.px(em * DIALOG_MARGIN_EM))
		}
		ui.spacer(ui.px(em * 0.9))
		dialog_close(&app.cx.open[.Files])
	}
	f.fresh = false
}

// A row chosen: a folder is entered, a file read. False when the rows are not the same any more.
@(private = "file")
file_pick :: proc(app: ^App, r: File_Row) -> bool {
	f := &app.cx.files
	if !r.directory { file_show(app, r.path); return true }
	path := strings.clone(r.path)   // (of the arena that goes)
	delete(f.at)
	f.at = path
	ui.field_set(&f.field, "")
	files_elsewhere(f)
	files_list(app)
	return false
}

@(private = "file")
files_left :: proc(app: ^App, em: f32) {
	f := &app.cx.files
	shows := remote_shows(&f.read)
	if n := len(f.rows); n > 0 && shows {
		if ui.key_press(.Down) { f.sel = (f.sel + 1) % n }
		if ui.key_press(.Up) { f.sel = (f.sel + n - 1) % n }
	}
	ui.next({width = ui.fill(), height = ui.px(math.round(em * 2.4)), axis = .X, cross = .Center})
	if well("###fl_well", .X, radius = 8, focus = 1) {
		ui.spacer(ui.px(em * 0.6))
		glyph(lucide.SEARCH, hex(HEX_FAINT), math.round(em * ICON_REGULAR))
		if ui.tags("bare") {
			ui.next({width = ui.fill(), height = ui.pct(1), text_pad = em * 0.35, font_size = math.round(em * FS_BODY)})
			res := ui.line_edit("###fl_find", &f.field, "Find a file")
			if f.fresh { ui.set_focus(res.box.key) }
			if res.changed { files_list(app) }
			if res.cancelled { app.cx.open[.Files] = false }
			if res.committed && shows && f.sel < len(f.rows) && !file_pick(app, f.rows[f.sel]) { return }
		}
	}
	ui.spacer(ui.px(em * 0.4))
	ui.next({width = ui.fill(), height = ui.fill()})
	if ui.scroll_y("###fl_rows") {
		if f.at != "" && !f.searching {
			if file_row(app, "###fl_up", "..", lucide.FOLDER, false, em) { files_up(app); return }
		}
		if !read_shown(app, "###fl_read", &f.read, em, files_list) { return }
		if len(f.rows) == 0 { info_line(app, "###fl_none", f.searching ? "Nothing matches." : "This folder is empty.", em) }
		for r, i in f.rows {
			if !file_row(app, fmt.tprintf("###flr%d", i), r.name, r.directory ? lucide.FOLDER : lucide.FILE, i == f.sel, em) { continue }
			f.sel = i
			if !file_pick(app, r) { return }
		}
	}
}

@(private = "file")
file_row :: proc(app: ^App, id, name, icon: string, selected: bool, em: f32) -> bool {
	ui.next({width = ui.fill(), height = ui.px(math.round(em * 1.8)), axis = .X, cross = .Center, cursor = .Hand})
	row := ui.build_box({.Clickable}, id)
	clicked := ui.signal(row).clicked
	if ui.parent(row) {
		ui.spacer(ui.px(em * 0.3))
		glyph(icon, hex(selected ? HEX_BRIGHT : HEX_FAINT), math.round(em * ICON_SMALL), em * 1.1)
		ui.spacer(ui.px(em * 0.3))
		text("n", name, hex(selected ? HEX_BRIGHT : HEX_TEXT), ui.Style_Mod{font = app.mono, font_size = math.round(em * FS_SMALL)}, ui.fill())
	}
	return clicked
}

@(private = "file")
files_right :: proc(app: ^App, em: f32) {
	f := &app.cx.files
	if f.file == "" {
		info_line(app, "###fl_hint", "Pick a file to read it.", em)
		return
	}
	ui.next({width = ui.fill(), height = ui.children_sum(), axis = .X, cross = .Center})
	if ui.row(.Center, id = "###fl_bar") {
		text("p", f.file, hex(HEX_TEXT), ui.Style_Mod{font = app.mono, font_size = math.round(em * FS_SMALL), height = ui.px(em * 1.6)}, ui.fill())
		ui.spacer(ui.px(em * 0.5))
		if bevel_button("###fl_copy", "Copy path", lucide.COPY, .Normal, height = math.round(em * BUTTON_COMPACT_H_EM)).clicked {
			clip_set(fmt.tprintf("%s/%s", strings.trim_right(f.dir, `\/`), f.file))
		}
		ui.spacer(ui.px(em * 0.4))
		if bevel_button("###fl_mention", "Mention in the prompt", lucide.PENCIL, .Accent, height = math.round(em * BUTTON_COMPACT_H_EM)).clicked {
			a := &app.composer.area
			a.mark = a.cursor
			mention_put(app, .File, f.file, file_uri(f.dir, f.file), filepath.base(f.file))
			app.cx.open[.Files] = false
		}
	}
	ui.spacer(ui.px(em * 0.5))
	if !read_shown(app, "###fl_file", &f.file_read, em, file_read) { return }
	if f.binary {
		info_line(app, "###fl_bin", fmt.tprintf("Not text: %d bytes. It can still go with a prompt.", f.size), em)
		return
	}
	if f.size > len(f.content) { info_line(app, "###fl_cut", fmt.tprintf("The first %d of %d bytes.", len(f.content), f.size), em) }
	ui.next({width = ui.fill(), height = ui.fill()})
	if ui.scroll_y("###fl_view") {
		code_block("###fl_code", strings.trim_prefix(filepath.ext(f.file), "."), f.content, app.mono, version = f.version)
	}
}

////////////////////////////////
// What the answers to its requests do (net.odin REQ_FACTS)

mention_files_on_ok :: proc(app: ^App, r: ^Request, v: json.Value) { mention_load(app, v) }

mention_files_on_fail :: proc(app: ^App, r: ^Request, f: Failure, message: string) -> (told: bool) {
	mention_failed(app)    // (what was proposed is not what is typed any more)
	return f == .Refused   // (a server without one, a folder gone: nothing to say)
}

files_list_on_ok :: proc(app: ^App, r: ^Request, v: json.Value) { files_load(app, v) }

file_read_on_ok :: proc(app: ^App, r: ^Request, v: json.Value) { file_loaded(app, r.resp) }
