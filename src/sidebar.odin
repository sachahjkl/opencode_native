// What the sidebar lists, and in what order. A mode is a way of dealing the sessions into sections: an entry of Sidebar_Mode, its
// word and label below, a case of sidebar_sections. Everything else (the search, the rows, the headers, folding, what holds the order
// under the pointer) is the same for all of them. The rows themselves are in sidebar_rows.odin.
package ocn

import "core:fmt"
import "core:hash"
import "core:math"
import "core:mem"
import "core:mem/virtual"
import "core:strings"
import "gt:draw"
import "gt:config"
import "gt:ui"
import lucide "gt:lucide"
import i18n "gt:i18n"

Sidebar_Mode :: enum u8 { Inbox, Projects }

// (`word`: the value of sidebar.mode, PREF_DEFS lists the same ones.)
SIDEBAR_MODES := [Sidebar_Mode]struct { word, label: string }{
	.Inbox    = {"inbox", i18n.later("Inbox")},
	.Projects = {"projects", i18n.later("Projects")},
}

sidebar_mode_of :: proc(word: string) -> Sidebar_Mode {
	for m in Sidebar_Mode { if SIDEBAR_MODES[m].word == word { return m } }
	return {}
}

sidebar_mode_set :: proc(app: ^App, m: Sidebar_Mode) { pref_set(app, "sidebar.mode", SIDEBAR_MODES[m].word) }

// The palette's switch: the next one, however many there are.
sidebar_mode_next :: proc(app: ^App) {
	sidebar_mode_set(app, Sidebar_Mode((int(app.prefs.sidebar_mode) + 1) % len(Sidebar_Mode)))
}

// What needs the person first. A session is in the first of these that it can be: one that runs again is no longer finished.
Inbox_Class :: enum u8 { Waiting, Finished, Running, Rest }

INBOX_TITLES := [Inbox_Class]string{.Waiting = i18n.later("Waits for you"), .Finished = i18n.later("Finished"), .Running = i18n.later("Running"), .Rest = i18n.later("Recent")}

// A section of the list. `items`: indices into app.sessions, in order.
Side_Section :: struct {
	key:     u64,      // what folds it
	lazy_id: string,   // its header's id in the lazy column
	dir:     string,   // a project's folder
	title:   string,   // "": it is a project, named after its folder
	unseen:  bool,     // what it holds can be marked as seen, all at once
	shut:    bool,     // folded until it is opened (Archived)
	items:   [dynamic]int,
}

ARCHIVED_TITLE := i18n.later("Archived")   // (a section's title: translated where it is shown)

// The server knows what was seen, for every client of it and across restarts: a run ended (time.idle) after the last end someone looked
// at (time.viewed), POST /view says one was. Its own rule, on the sessions one opens: sub-agents are read through their parent, and
// nobody ever views them. The one shown is seen; one at work has not finished.
session_unseen :: proc(app: ^App, s: ^Session_Info) -> bool {
	return session_end_unseen(app, s) && !(app.busy[s.id] or_else false)
}

// Says that the end of its last run was seen, once it is known: `idle` must be the server's. (A failure says nothing: the next list
// shows it as it stands.)
session_seen :: proc(app: ^App, s: ^Session_Info) {
	if s.idle <= s.viewed { return }
	request(app, .Session_Viewed, "POST", fmt.tprintf("/api/session/%s/view", s.id), fmt.tprintf(`{{"idle":%.0f}}`, s.idle), s.id)
	s.viewed = s.idle
	marks_changed(app)
}

// A run ended: until the list says when, the row must not go through Recent to get to Finished. (No clock here: only that it is later
// than what was seen.)
session_ended :: proc(app: ^App, id, outcome: string) {
	s := find_session(app, id)
	if s == nil || id == app.chat.id { return }
	s.idle = max(s.idle, s.viewed + 1)
	s.outcome = outcome   // (a literal, or the word of the next list)
	marks_changed(app)
}

// Someone looked at it, here or elsewhere.
session_viewed :: proc(app: ^App, id: string, idle: f64) {
	if s := find_session(app, id); s != nil { s.viewed = max(s.viewed, idle); marks_changed(app) }
}

// The list says what ended: the one shown was in front of the person.
sessions_seen_shown :: proc(app: ^App) {
	if app.busy[app.chat.id] or_else false { return }
	if s := find_session(app, app.chat.id); s != nil { session_seen(app, s) }
}

// The rows of the list before they are dealt, in the mode's order: sub-agents as the preference says, what the search leaves.
// A search keeps a session when each of its words is in one of its fields (session_matches). A sub-agent found while its parent
// is not has a row of its own: nested under a parent that is not shown, it would not be seen.
sidebar_rows :: proc(app: ^App, query: string, allocator := context.temp_allocator) -> []int {
	rows := make([dynamic]int, 0, len(app.sessions), allocator)
	nested := app.prefs.subagents != "flat"
	searching := strings.trim_space(query) != ""
	shown := make(map[string]bool, allocator = context.temp_allocator)
	for s, i in app.sessions {
		if s.parent != "" && nested { continue }
		if searching && !session_matches(s, query) { continue }
		append(&rows, i)
		shown[s.id] = true
	}
	if !searching || !nested { return rows[:] }
	for s, i in app.sessions {
		if s.parent == "" || shown[s.parent] || !session_matches(s, query) { continue }
		append(&rows, i)
	}
	return rows[:]
}

// What a search of the sessions looks in: each word of `query` in one of these, in any case.
session_matches :: proc(s: Session_Info, query: string) -> bool {
	return config.words_match(query, s.title, s.id, s.directory, s.agent, s.model, s.provider, s.parent)
}

// The one place that knows the modes. What was archived is in none of their sections: it is in the last one, Archived, folded
// until it is opened, whatever the mode.
sidebar_sections :: proc(app: ^App, rows: []int, mode: Sidebar_Mode, allocator := context.temp_allocator) -> []Side_Section {
	live := make([dynamic]int, 0, len(rows), context.temp_allocator)
	archived := make([dynamic]int, allocator)
	for i in rows { append(app.sessions[i].archived > 0 ? &archived : &live, i) }
	sections: [dynamic]Side_Section
	switch mode {
	case .Inbox:    sections = inbox_sections(app, live[:], allocator)
	case .Projects: sections = project_sections(app, live[:], allocator)
	}
	if len(archived) > 0 {
		append(&sections, Side_Section{key = hash.fnv64a(transmute([]u8)string("archived")), title = ARCHIVED_TITLE, shut = true, items = archived})
	}
	for &sec in sections { sec.lazy_id = side_section_lazy_id(sec.key, allocator) }
	return sections[:]
}

@(private = "file")
side_section_lazy_id :: proc(key: u64, a: mem.Allocator) -> string { return fmt.aprintf("###lg%d", key, allocator = a) }

// Archives a session, or brings it back: at once here, the server's list then says it as it stands.
session_archive :: proc(app: ^App, id: string, archive: bool) {
	if s := find_session(app, id); s != nil { s.archived = archive ? max(now_epoch_ms(), 1) : 0; marks_changed(app) }
	// (the list held under the pointer is for what changes by itself: what the person just did shows at once, the hold
	// taken again from the sections as they are now)
	sidebar_hold_end(app)
	request(app, .Action, "PATCH", fmt.tprintf("/api/session/%s", id), archive ? `{"archived":true}` : `{"archived":false}`, id)
	refresh_sessions(app)
}

session_is_archived :: proc(app: ^App, id: string) -> bool {
	s := find_session(app, id)
	return s != nil && s.archived > 0
}

// The present grouping: a section per folder, the one last active first.
@(private = "file")
project_sections :: proc(app: ^App, rows: []int, a: mem.Allocator) -> [dynamic]Side_Section {
	sections := make([dynamic]Side_Section, a)
	index := make(map[string]int, allocator = context.temp_allocator)
	for i in rows {
		dir := app.sessions[i].directory
		at, ok := index[dir]
		if !ok {
			at = len(sections)
			index[dir] = at
			append(&sections, Side_Section{key = hash.fnv64a(transmute([]u8)dir), dir = dir, items = make([dynamic]int, a)})
		}
		append(&sections[at].items, i)
	}
	return sections
}

// What needs attention first, across projects; those with nothing do not show. What lights a row decides its section: session_waits,
// app.busy, session_unseen. (app.sessions is by recency: so is each section.)
@(private = "file")
inbox_sections :: proc(app: ^App, rows: []int, a: mem.Allocator) -> [dynamic]Side_Section {
	waiting := sessions_waiting(app)
	dealt: [Inbox_Class][dynamic]int
	for c in Inbox_Class { dealt[c] = make([dynamic]int, a) }
	for i in rows {
		s := &app.sessions[i]
		class := Inbox_Class.Rest
		switch {
		case s.id in waiting:                class = .Waiting
		case app.busy[s.id] or_else false:   class = .Running
		case session_unseen(app, s):         class = .Finished
		}
		append(&dealt[class], i)
	}
	sections := make([dynamic]Side_Section, a)
	for c in Inbox_Class {
		if len(dealt[c]) == 0 { continue }
		key := fmt.tprintf("inbox:%v", c)
		append(&sections, Side_Section{key = hash.fnv64a(transmute([]u8)key), title = INBOX_TITLES[c], unseen = c == .Finished, items = dealt[c]})
	}
	return sections
}

// Rows do not move under a pointer about to click one. While it moves over the list, sections and order stay what they were when it came
// (the sessions in them stay live: a lamp changes at once, a title too); a run that ends meanwhile moves its row when the pointer has
// left the list, or has stayed still for SIDEBAR_HOLD_MS. New sessions wait as well: a row added above would push the others down.
Side_Held :: struct { key: u64, dir, title: string, unseen, shut: bool, ids: [dynamic]string }   // (owned)

Side_Hold :: struct {
	on:       bool,
	sections: [dynamic]Side_Held,
	over:     u64,        // what the list is of: another search, mode or preference is another list
	ver:      u64,        // moves when a hold starts or ends (Side_Kept)
}

// What the list shows, kept until what it is made from changes. Its rows: the list of sessions (sessions_ver), the search, the mode and
// the sub-agents preference. Its sections: the rows, what deals a session or lights it (marks_ver), the session shown (it is never
// unseen) and the hold. Made at every build, they went through every session, with a map, a string and a hash each.
Side_Kept :: struct {
	rows_arena:     virtual.Arena,
	rows_made:      bool,
	rows_sessions:  u64,             // sessions_ver they were made at
	query:          string,          // the search as typed (rows_arena)
	mode:           Sidebar_Mode,
	subagents:      string,          // the preference (rows_arena)
	rows:           []int,
	kids:           map[string][dynamic]int,   // each session's sub-agents among the loaded ones, newest first (indices into app.sessions)
	of:             u64,             // what the list is of (Side_Hold.over)
	rows_ver:       u64,             // counts the rows made: what the sections were made from

	sections_arena: virtual.Arena,
	sections_made:  bool,
	sections_rows, sections_marks, sections_hold: u64,   // rows_ver, marks_ver and Side_Hold.ver they were made at
	shown:          string,          // app.chat.id they were made with (sections_arena)
	sections:       []Side_Section,

	rows_computed, sections_computed: int,   // times each was made (tests)
}

// The sidebar: its width, its search, what is folded or open in it, what it keeps of the list, what its menus are about.
Sidebar :: struct {
	width:        f32,
	hidden:       bool,
	search:       ui.Text_Field,
	folded:       map[u64]bool,   // groups folded (hash of the directory)
	sub_open:     map[u64]bool,   // sessions whose sub-agents are listed under them
	hold:         Side_Hold,      // the order, under the pointer
	kept:         Side_Kept,      // the rows and sections
	menu_session: string,         // the session the context menu is about (owned)
	menu_project: string,         // the project the project menu is about (owned)
	delete_id:    string,         // the session the dialog that deletes it is about
}

// The sections the list shows, made again only when what they come from changed. `wanted`: the pointer is over the list.
sidebar_view :: proc(app: ^App, query: string, wanted: bool) -> []Side_Section {
	k := &app.sidebar.kept
	h := &app.sidebar.hold
	side_rows_refresh(app, query)
	if h.on && (!wanted || h.over != k.of) { sidebar_hold_end(app) }
	side_sections_refresh(app)
	if !h.on && wanted {
		h.on, h.over = true, k.of
		for &sec in k.sections {
			held := Side_Held{key = sec.key, dir = strings.clone(sec.dir), title = strings.clone(sec.title), unseen = sec.unseen, shut = sec.shut}
			for i in sec.items { append(&held.ids, strings.clone(app.sessions[i].id)) }
			append(&h.sections, held)
		}
		h.ver += 1
		k.sections_hold = h.ver   // (what is held is what shows: nothing to make again)
	}
	return k.sections
}

@(private = "file")
side_rows_refresh :: proc(app: ^App, query: string) {
	k := &app.sidebar.kept
	mode := app.prefs.sidebar_mode
	if k.rows_made && k.rows_sessions == app.cx.sessions_ver && k.mode == mode && k.query == query && k.subagents == app.prefs.subagents { return }
	a := arena_renew(&k.rows_arena)
	k.rows_made, k.rows_sessions, k.mode = true, app.cx.sessions_ver, mode
	k.query, k.subagents = strings.clone(query, a), strings.clone(app.prefs.subagents, a)
	lower := strings.to_lower(query, context.temp_allocator)
	k.rows = sidebar_rows(app, lower, a)
	k.kids = make(map[string][dynamic]int, allocator = a)
	for s, i in app.sessions {
		if s.parent == "" { continue }
		list := k.kids[s.parent] or_else make([dynamic]int, a)
		append(&list, i)
		k.kids[s.parent] = list
	}
	k.of = hash.fnv64a(transmute([]u8)fmt.tprintf("%v %s %s", mode, app.prefs.subagents, lower))
	k.rows_ver += 1
	k.rows_computed += 1
}

@(private = "file")
side_sections_refresh :: proc(app: ^App) {
	k := &app.sidebar.kept
	h := &app.sidebar.hold
	if k.sections_made && k.sections_rows == k.rows_ver && k.sections_marks == app.cx.marks_ver && k.sections_hold == h.ver && k.shown == app.chat.id { return }
	a := arena_renew(&k.sections_arena)
	k.sections = h.on ? held_sections(app, k.rows, a) : sidebar_sections(app, k.rows, k.mode, a)
	k.sections_made, k.sections_rows, k.sections_marks, k.sections_hold = true, k.rows_ver, app.cx.marks_ver, h.ver
	k.shown = strings.clone(app.chat.id, a)
	k.sections_computed += 1
}

// The sections held, with the sessions in them now. By id: a new list changes the indices.
@(private = "file")
held_sections :: proc(app: ^App, rows: []int, a: mem.Allocator) -> []Side_Section {
	h := &app.sidebar.hold
	listed := make([]bool, len(app.sessions), context.temp_allocator)
	for i in rows { listed[i] = true }
	sections := make([dynamic]Side_Section, 0, len(h.sections), a)
	for &held in h.sections {
		sec := Side_Section{key = held.key, dir = strings.clone(held.dir, a), title = strings.clone(held.title, a), unseen = held.unseen, shut = held.shut, items = make([dynamic]int, 0, len(held.ids), a)}
		for id in held.ids { if i, there := app.session_at[id]; there && listed[i] { append(&sec.items, i) } }
		if len(sec.items) == 0 { continue }
		sec.lazy_id = side_section_lazy_id(sec.key, a)
		append(&sections, sec)
	}
	return sections[:]
}

sidebar_hold_end :: proc(app: ^App) {
	h := &app.sidebar.hold
	for &sec in h.sections {
		for id in sec.ids { delete(id) }
		delete(sec.ids)
		delete(sec.dir); delete(sec.title)
	}
	clear(&h.sections)
	h.on = false
	h.ver += 1
	app.cx.due[.Side_Wake] = {}   // (the frame that lets go, when nothing else would come)
}

// What the pointer asks of the list, from the box that scrolls it.
sidebar_hold_wanted :: proc(app: ^App, list: ^ui.Box) -> bool {
	since := ui.now_ms() - app.cx.pointer_ms
	if !draw.rect_contains(list.rect, ui.mouse_pos()) || since >= SIDEBAR_HOLD_MS { return false }
	// (at rest nothing draws: this is what ends the hold if the pointer stays where it is)
	app.cx.due[.Side_Wake] = {}
	ui.deferred_ask(&app.cx.due[.Side_Wake], SIDEBAR_HOLD_MS - since + 1)
	return true
}

// Marks all that the section shows as seen.
@(private = "file")
section_seen :: proc(app: ^App, sec: ^Side_Section) {
	for i in sec.items { session_seen(app, &app.sessions[i]) }
}

// The modes, under the search.
sidebar_mode_switch :: proc(app: ^App, em: f32) {
	labels: [len(Sidebar_Mode)]string
	for m in Sidebar_Mode { labels[m] = i18n.tr(SIDEBAR_MODES[m].label) }
	sel := int(app.prefs.sidebar_mode)
	if ui.style({font_size = math.round(em * FS_SMALL)}) {
		ui.next({width = ui.fill(), height = ui.px(math.round(em * SIDE_MODES_H_EM))})
		ui.a11y({name = i18n.tr("What the sidebar shows")})
		if choice("###side_mode", labels[:], &sel) { sidebar_mode_set(app, Sidebar_Mode(sel)) }
	}
}

// A section of the inbox: its name, how many, and for what is finished the way to say all of it was seen.
inbox_header :: proc(app: ^App, sec: ^Side_Section, folded: bool, em: f32) {
	ui.next({width = ui.fill(), height = ui.px(math.round(em * 1.9)), axis = .X, cross = .Center})
	hdr := ui.build_box({.Clickable, .Hot_Within}, fmt.tprintf("###g%d", sec.key))
	hs := ui.signal(hdr)
	if hs.clicked { app.sidebar.folded[sec.key] = !folded }
	if ui.parent(hdr) {
		ui.spacer(ui.px(em * 0.8))
		glyph(folded ? lucide.CHEVRON_RIGHT : lucide.CHEVRON_DOWN, hex(HEX_FAINT), math.round(em * ICON_TINY), em * 0.9)
		ui.spacer(ui.px(em * 0.2))
		text("n", strings.to_upper(i18n.tr(sec.title), context.temp_allocator), hs.hovering ? hex(HEX_TEXT) : hex(HEX_WEAK), ui.Style_Mod{font = app.mono_bold, font_size = math.round(em * FS_SMALL)})
		ui.spacer(ui.px(em * 0.4))
		text("c", fmt.tprintf("%d", len(sec.items)), hex(HEX_FAINT), ui.Style_Mod{font = app.mono, font_size = math.round(em * FS_SMALL)})
		ui.spacer(ui.fill())
		if sec.unseen {
			if hint_action("###seen_all", i18n.tr("Mark as seen"), em) { section_seen(app, sec) }
			ui.spacer(ui.px(em * 0.9))
		}
	}
}
