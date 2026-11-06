// What the sidebar lists, and in what order. A mode is a way of dealing the sessions into sections: an entry of Sidebar_Mode, its
// word and label below, a case of sidebar_sections. Everything else (the search, the rows, the headers, folding, what holds the order
// under the pointer) is the same for all of them. The rows themselves are in views.odin.
package occ

import "core:fmt"
import "core:hash"
import "core:math"
import "core:strings"
import "gt:ui"

Sidebar_Mode :: enum u8 { Inbox, Projects }

// (`word`: the value of sidebar.mode, PREF_DEFS lists the same ones.)
SIDEBAR_MODES := [Sidebar_Mode]struct { word, label: string }{
	.Inbox    = {"inbox", "Inbox"},
	.Projects = {"projects", "Projects"},
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

INBOX_TITLES := [Inbox_Class]string{.Waiting = "Waits for you", .Finished = "Finished", .Running = "Running", .Rest = "Recent"}

// A section of the list. `items`: indices into app.sessions, in order.
Side_Section :: struct {
	key:     u64,      // what folds it
	dir:     string,   // a project's folder
	title:   string,   // "": it is a project, named after its folder
	unseen:  bool,     // what it holds can be marked as seen, all at once
	items:   [dynamic]int,
}

// The server knows what was seen, for every client of it and across restarts: a run ended (time.idle) after the last end someone looked
// at (time.viewed), POST /view says one was. Its own rule, on the sessions one opens: sub-agents are read through their parent, and
// nobody ever views them. The one shown is seen; one at work has not finished.
session_unseen :: proc(app: ^App, s: ^Session_Info) -> bool {
	return s.parent == "" && s.idle > s.viewed && s.id != app.chat.id && !(app.busy[s.id] or_else false)
}

// Says that the end of its last run was seen, once it is known: `idle` must be the server's. (A failure says nothing: the next list
// shows it as it stands.)
session_seen :: proc(app: ^App, s: ^Session_Info) {
	if s.idle <= s.viewed { return }
	request(app, .Session_Viewed, "POST", fmt.tprintf("/api/session/%s/view", s.id), fmt.tprintf(`{{"idle":%.0f}}`, s.idle), s.id)
	s.viewed = s.idle
}

// A run ended: until the list says when, the row must not go through Recent to get to Finished. (No clock here: only that it is later
// than what was seen.)
session_ended :: proc(app: ^App, id, outcome: string) {
	s := find_session(app, id)
	if s == nil || id == app.chat.id { return }
	s.idle = max(s.idle, s.viewed + 1)
	s.outcome = outcome   // (a literal, or the word of the next list)
}

// Someone looked at it, here or elsewhere.
session_viewed :: proc(app: ^App, id: string, idle: f64) {
	if s := find_session(app, id); s != nil { s.viewed = max(s.viewed, idle) }
}

// The list says what ended: the one shown was in front of the person.
sessions_seen_shown :: proc(app: ^App) {
	if app.busy[app.chat.id] or_else false { return }
	if s := find_session(app, app.chat.id); s != nil { session_seen(app, s) }
}

// The rows of the list before they are dealt, in the mode's order: sub-agents as the preference says, what the search leaves.
sidebar_rows :: proc(app: ^App, needle: string) -> []int {
	rows := make([dynamic]int, 0, len(app.sessions), context.temp_allocator)
	for s, i in app.sessions {
		if s.parent != "" && app.prefs.subagents != "flat" { continue }
		if needle != "" && !strings.contains(strings.to_lower(s.title, context.temp_allocator), needle) && !strings.contains(strings.to_lower(s.directory, context.temp_allocator), needle) { continue }
		append(&rows, i)
	}
	return rows[:]
}

// The one place that knows the modes.
sidebar_sections :: proc(app: ^App, rows: []int, mode: Sidebar_Mode) -> []Side_Section {
	switch mode {
	case .Inbox:    return inbox_sections(app, rows)
	case .Projects: return project_sections(app, rows)
	}
	return nil
}

// The present grouping: a section per folder, the one last active first.
@(private = "file")
project_sections :: proc(app: ^App, rows: []int) -> []Side_Section {
	sections := make([dynamic]Side_Section, context.temp_allocator)
	index := make(map[string]int, allocator = context.temp_allocator)
	for i in rows {
		dir := app.sessions[i].directory
		at, ok := index[dir]
		if !ok {
			at = len(sections)
			index[dir] = at
			append(&sections, Side_Section{key = hash.fnv64a(transmute([]u8)dir), dir = dir, items = make([dynamic]int, context.temp_allocator)})
		}
		append(&sections[at].items, i)
	}
	return sections[:]
}

// What needs attention first, across projects; those with nothing do not show. What lights a row decides its section: session_waits,
// app.busy, session_unseen. (app.sessions is by recency: so is each section.)
@(private = "file")
inbox_sections :: proc(app: ^App, rows: []int) -> []Side_Section {
	waiting := sessions_waiting(app)
	dealt: [Inbox_Class][dynamic]int
	for c in Inbox_Class { dealt[c] = make([dynamic]int, context.temp_allocator) }
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
	sections := make([dynamic]Side_Section, context.temp_allocator)
	for c in Inbox_Class {
		if len(dealt[c]) == 0 { continue }
		key := fmt.tprintf("inbox:%v", c)
		append(&sections, Side_Section{key = hash.fnv64a(transmute([]u8)key), title = INBOX_TITLES[c], unseen = c == .Finished, items = dealt[c]})
	}
	return sections[:]
}

// Rows do not move under a pointer about to click one. While it moves over the list, sections and order stay what they were when it came
// (the sessions in them stay live: a lamp changes at once, a title too); a run that ends meanwhile moves its row when the pointer has
// left the list, or has stayed still for SIDEBAR_HOLD_MS. New sessions wait as well: a row added above would push the others down.
Side_Held :: struct { key: u64, dir, title: string, unseen: bool, ids: [dynamic]string }   // (owned)

Side_Hold :: struct {
	on:       bool,
	sections: [dynamic]Side_Held,
	over:     u64,        // what the list is of: another search, mode or preference is another list
	wake:     Deferred,   // the frame that lets go, when nothing else would come
}

// `wanted`: the pointer is there. `of`: what this list is of.
sidebar_held :: proc(app: ^App, rows: []int, wanted: bool, of: u64) -> []Side_Section {
	h := &app.cx.side_hold
	if h.on && (!wanted || h.over != of) { sidebar_hold_end(app) }
	if !h.on {
		live := sidebar_sections(app, rows, app.prefs.sidebar_mode)
		if wanted {
			h.on, h.over = true, of
			for &sec in live {
				held := Side_Held{key = sec.key, dir = strings.clone(sec.dir), title = strings.clone(sec.title), unseen = sec.unseen}
				for i in sec.items { append(&held.ids, strings.clone(app.sessions[i].id)) }
				append(&h.sections, held)
			}
		}
		return live
	}
	// (by id: a new list changes the indices)
	at := make(map[string]int, len(rows), context.temp_allocator)
	for i in rows { at[app.sessions[i].id] = i }
	sections := make([dynamic]Side_Section, 0, len(h.sections), context.temp_allocator)
	for &held in h.sections {
		sec := Side_Section{key = held.key, dir = held.dir, title = held.title, unseen = held.unseen, items = make([dynamic]int, 0, len(held.ids), context.temp_allocator)}
		for id in held.ids { if i, there := at[id]; there { append(&sec.items, i) } }
		if len(sec.items) > 0 { append(&sections, sec) }
	}
	return sections[:]
}

sidebar_hold_end :: proc(app: ^App) {
	h := &app.cx.side_hold
	for &sec in h.sections {
		for id in sec.ids { delete(id) }
		delete(sec.ids)
		delete(sec.dir); delete(sec.title)
	}
	clear(&h.sections)
	h.on = false
	h.wake = {}
}

// What the pointer asks of the list, from the box that scrolls it.
sidebar_hold_wanted :: proc(app: ^App, list: ^ui.Box) -> bool {
	since := ui.now_ms() - app.cx.pointer_ms
	if !rect_contains(list.rect, ui.mouse_pos()) || since >= SIDEBAR_HOLD_MS { return false }
	// (at rest nothing draws: this is what ends the hold if the pointer stays where it is)
	app.cx.side_hold.wake = {}
	deferred_ask(&app.cx.side_hold.wake, SIDEBAR_HOLD_MS - since + 1)
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
	for m in Sidebar_Mode { labels[m] = SIDEBAR_MODES[m].label }
	sel := int(app.prefs.sidebar_mode)
	if ui.style({font_size = math.round(em * FS_SMALL)}) {
		ui.next({width = ui.fill(), height = ui.px(math.round(em * SIDE_MODES_H_EM))})
		ui.a11y({name = "What the sidebar shows"})
		if ui.segmented("###side_mode", labels[:], &sel) { sidebar_mode_set(app, Sidebar_Mode(sel)) }
	}
}

// A section of the inbox: its name, how many, and for what is finished the way to say all of it was seen.
inbox_header :: proc(app: ^App, sec: ^Side_Section, folded: bool, em: f32) {
	ui.next({width = ui.fill(), height = ui.px(math.round(em * 1.9)), axis = .X, cross = .Center})
	hdr := ui.build_box({.Clickable, .Hot_Within}, fmt.tprintf("###g%d", sec.key))
	hs := ui.signal(hdr)
	if hs.clicked { app.folded[sec.key] = !folded }
	if ui.parent(hdr) {
		ui.spacer(ui.px(em * 0.8))
		glyph(folded ? ICO_RIGHT : ICO_DOWN, hex(HEX_FAINT), math.round(em * ICON_TINY), em * 0.9)
		ui.spacer(ui.px(em * 0.2))
		text("n", strings.to_upper(sec.title, context.temp_allocator), hs.hovering ? hex(HEX_TEXT) : hex(HEX_WEAK), ui.Style_Mod{font = app.mono_bold, font_size = math.round(em * FS_SMALL)})
		ui.spacer(ui.px(em * 0.4))
		text("c", fmt.tprintf("%d", len(sec.items)), hex(HEX_FAINT), ui.Style_Mod{font = app.mono, font_size = math.round(em * FS_SMALL)})
		ui.spacer(ui.fill())
		if sec.unseen {
			if hint_action("###seen_all", "Mark as seen", em) { section_seen(app, sec) }
			ui.spacer(ui.px(em * 0.9))
		}
	}
}
