// A browser per session, of one tab or several. A tab is the live thing: a page, its web view, its address, its history. A session's
// Preview is its list of tabs and the one in front; `app.preview` is the Preview of the session shown, and the others wait in
// `cx.previews`, parked, by session. Only the front tab of the session shown is visible; every other page is alive and hidden. A web view is
// made when a tab first needs one, so a session that never opens the browser costs nothing. Whatever a view says reaches its own tab: a
// parked page goes on loading, and an agent can go on driving it.
package occ

import "core:fmt"
import "core:strings"
import "gt:platform"
import "gt:ui"

Web_Act :: enum i32 { Back, Forward, Reload, Stop, Focus }

// What the panel asks of a real web view, and all it asks: the program's is the system's (webview_windows.odin), the tests' counts
// (preview_test.odin). Empty while there is no window to put a view in, and on a system with no web view.
Web_Host :: struct {
	open:     proc(app: ^App, v: ^Web_View, parent: ^platform.Window) -> rawptr,   // (nil: it did not start)
	close:    proc(native: rawptr),
	parent:   proc(native: rawptr, w: ^platform.Window),
	navigate: proc(native: rawptr, url: string),
	act:      proc(native: rawptr, what: Web_Act),
	can:      proc(native: rawptr, what: Web_Act) -> bool,
	script:   proc(native: rawptr, code: string, id: u64),
	capture:  proc(native: rawptr, id: u64),
	place:    proc(native: rawptr, x, y, w, h: int, visible: bool),
}

// What a view's callback is given: it knows its tab, whichever is shown when it comes. (Never freed: a script's answer may still come after
// the view is closed, and it is small. `gone` says nobody listens, and `tab` is not to be followed then.)
Web_View :: struct {
	app:    ^App,
	tab:    ^Preview_Tab,
	native: rawptr,
	parent: ^platform.Window,     // the window it is in (compared, never followed: that window may be gone)
	events: [dynamic]Web_Event,   // said since the last drain
	gone:   bool,
}

// The view exists, or is on its way. One that failed is made anew: a failure holds for this attempt, not for ever.
web_start :: proc(app: ^App, t: ^Preview_Tab) {
	switch _ in t.web {
	case Web_Creating, Web_Ready: return
	case Web_Failed:              web_close(app, t)
	case nil:
	}
	host := app.cx.web_host
	if host.open == nil { return }   // (no window: nothing to put it in)
	v := new(Web_View)
	v.app, v.tab = app, t
	v.parent = preview_window(app, t)
	v.native = host.open(app, v, v.parent)
	if v.native == nil {
		free(v)
		web_state_set(t, Web_Failed{strings.clone("the WebView2 runtime did not start")})
		return
	}
	t.view = v
	append(&app.cx.web_views, v)
	web_state_set(t, Web_Creating{})
	preview_touch(app, t)
	if preview_tab_shown(app, t) {
		t.placed, t.placed_shown, t.placed_ms = {}, false, 0   // (a tab that was laid out with no view: this one has been told nothing)
	} else {
		web_hide(t)
	}
	preview_trim(app, t)
}

// The view is destroyed, and what it would still say is dropped with it. (A view on its way closes itself when it comes: native.)
web_close :: proc(app: ^App, t: ^Preview_Tab) {
	if v := t.view; v != nil {
		browser_calls_end(app, v, "The page was closed before it answered.")
		app.cx.web_host.close(v.native)
		v.gone = true
		web_events_drop(v)
		delete(v.events)
		for w, i in app.cx.web_views { if w == v { ordered_remove(&app.cx.web_views, i); break } }
		t.view = nil
	}
	web_state_set(t, nil)
}

// The page goes into this window. A view on its way has no window to leave yet: its Ready brings it here (web_event_apply).
web_parent :: proc(t: ^Preview_Tab, w: ^platform.Window) {
	v := t.view
	if v == nil || v.parent == w { return }
	if _, coming := t.web.(Web_Creating); coming { return }
	v.app.cx.web_host.parent(v.native, w)
	v.parent = w
}

web_navigate :: proc(app: ^App, t: ^Preview_Tab, url: string) {
	t.asked = true
	if t.view == nil { web_start(app, t) }
	if v := t.view; v != nil { app.cx.web_host.navigate(v.native, url) }
}

web_act :: proc(t: ^Preview_Tab, what: Web_Act) {
	if v := t.view; v != nil { v.app.cx.web_host.act(v.native, what) }
}

// Whether the page has a place to go Back or Forward to.
web_can :: proc(t: ^Preview_Tab, what: Web_Act) -> bool {
	v := t.view
	return v != nil && v.app.cx.web_host.can(v.native, what)
}

web_script :: proc(t: ^Preview_Tab, code: string, id: u64) {
	if v := t.view; v != nil { v.app.cx.web_host.script(v.native, code, id) }
}

web_capture :: proc(t: ^Preview_Tab, id: u64) {
	if v := t.view; v != nil { v.app.cx.web_host.capture(v.native, id) }
}

web_place :: proc(t: ^Preview_Tab, x, y, w, h: int, visible: bool) {
	if v := t.view; v != nil { v.app.cx.web_host.place(v.native, x, y, w, h, visible) }
}

// Out of sight, at a size a page can be read at: what is laid out at nothing has no element an agent could see.
@(private = "file")
web_hide :: proc(t: ^Preview_Tab) {
	v := t.view
	if v == nil { return }
	r := t.placed
	if r[2] == 0 || r[3] == 0 {
		r = {0, 0, PREVIEW_PARKED_W, PREVIEW_PARKED_H}
		if f := preview_front(&v.app.preview); f != nil && f.placed[2] > 0 && f.placed[3] > 0 { r = f.placed }
	}
	t.placed, t.placed_shown = r, false
	web_place(t, r[0], r[1], r[2], r[3], false)
}

////////////////////////////////
// The tabs of a session

// The tab in front. (nil: the session has none yet.)
preview_front :: proc(p: ^Preview) -> ^Preview_Tab {
	return p.front < len(p.tabs) ? p.tabs[p.front] : nil
}

// (The ids go on from session to session: one given to an agent never comes to mean another page.)
@(private = "file")
preview_tab_make :: proc(app: ^App) -> ^Preview_Tab {
	app.cx.preview_tabs_made += 1
	t := new(Preview_Tab)
	t.id = fmt.aprintf("tab_00000000-0000-4000-8000-%012x", app.cx.preview_tabs_made)
	return t
}

// The tab in front, one made if the session has none: an address bar has to have something to write in. It costs no view.
preview_front_made :: proc(app: ^App, p: ^Preview) -> ^Preview_Tab {
	if len(p.tabs) == 0 {
		append(&p.tabs, preview_tab_make(app))
		p.front = 0
	}
	return preview_front(p)
}

preview_tab_of :: proc(p: ^Preview, id: string) -> ^Preview_Tab {
	for t in p.tabs { if t.id == id { return t } }
	return nil
}

// Whether this is the page on the screen: the front tab of the session shown.
preview_tab_shown :: proc(app: ^App, t: ^Preview_Tab) -> bool { return preview_front(&app.preview) == t }

// A new tab, with nothing in it and so no view until it is given an address.
preview_tab_add :: proc(app: ^App, p: ^Preview, front := true) -> ^Preview_Tab {
	t := preview_tab_make(app)
	append(&p.tabs, t)
	if front { preview_tab_front(app, p, t) }
	return t
}

// Whether nothing was ever asked of it: what opens next may as well go here.
preview_tab_blank :: proc(t: ^Preview_Tab) -> bool { return t.url == "" && !t.asked && len(t.navs) == 0 }

@(private = "file")
tab_leave :: proc(app: ^App, t: ^Preview_Tab) {
	preview_touch(app, t)
	web_hide(t)
	web_parent(t, app.win)
}

// (Its place is asked for at the next frame, at once: it is not a move to follow at a pace.)
@(private = "file")
tab_bring :: proc(app: ^App, t: ^Preview_Tab) {
	t.placed, t.placed_shown, t.placed_ms = {}, false, 0
	web_parent(t, preview_window(app, t))
	if t.view == nil && t.url != "" { preview_revive(app, t) }
	preview_trim(app, t)
}

// This tab comes in front. In a session not shown nothing moves on the screen: it is what shows when the session does.
preview_tab_front :: proc(app: ^App, p: ^Preview, t: ^Preview_Tab) {
	old := preview_front(p)
	if old == t { return }
	shown := p == &app.preview
	if shown && old != nil { tab_leave(app, old) }
	for it, i in p.tabs { if it == t { p.front = i } }
	if shown { tab_bring(app, t) }
	app.frames = max(app.frames, FRAMES_AFTER_INPUT)
}

@(private = "file")
tab_free :: proc(app: ^App, t: ^Preview_Tab) {
	web_close(app, t)
	delete(t.navs)
	delete(t.url); delete(t.title); delete(t.id)
	ui.field_destroy(&t.field)
	free(t)
}

// Its neighbour takes its place, the next one or else the one before; the last of a session closes the panel, for that session.
preview_tab_close :: proc(app: ^App, p: ^Preview, t: ^Preview_Tab) {
	at := -1
	for it, i in p.tabs { if it == t { at = i } }
	if at < 0 { return }
	in_front := at == p.front
	tab_free(app, t)
	ordered_remove(&p.tabs, at)
	if len(p.tabs) == 0 {
		p.front = 0
		if p == &app.preview { panel_close(app, u32(Panel.Preview)) } else { p.open = false }
		return
	}
	if at < p.front { p.front -= 1 }
	if in_front {
		p.front = min(at, len(p.tabs) - 1)
		if p == &app.preview { tab_bring(app, preview_front(p)) }
	}
	app.frames = max(app.frames, FRAMES_AFTER_INPUT)
}

// The palette's and the keys'. (The panel closed: opening it is what was asked, with a tab of its own if it had others.)
preview_tab_new :: proc(app: ^App) {
	if !preview_available() { ui.toast(.Warn, "The Preview panel needs the WebView2 runtime"); return }
	p := &app.preview
	had := len(p.tabs) > 0
	if !p.open { preview_show(app) }
	if had { preview_tab_add(app, p) }
	if t := preview_front(p); t != nil { t.focus_address = true }
}

preview_tab_can_close :: proc(app: ^App) -> bool { return app.preview.open && len(app.preview.tabs) > 0 }

preview_tab_close_front :: proc(app: ^App) {
	if t := preview_front(&app.preview); t != nil && app.preview.open { preview_tab_close(app, &app.preview, t) }
}

// What a build asked for: the tabs it was going through stay as they are until it ends, and the page takes the keyboard of who chose it.
@(private = "file")
preview_dues :: proc(app: ^App) {
	p := &app.preview
	if p.due_new {
		p.due_new = false
		preview_tab_new(app)
	}
	if t := p.due_front; t != nil {
		p.due_front = nil
		preview_tab_front(app, p, t)
		t.focus_page = true
		preview_page_focus(app, t)
	}
	if t := p.due_close; t != nil {
		p.due_close = nil
		preview_tab_close(app, p, t)
		if f := preview_front(p); f != nil && p.open {
			f.focus_page = true
			preview_page_focus(app, f)
		}
	}
}

////////////////////////////////
// Whose browser

// The parent of a session, as far as the client knows it. (`known` false: it has not heard of this one yet.)
@(private = "file")
session_parent :: proc(app: ^App, id: string) -> (parent: string, known: bool) {
	c := &app.chat
	if id == c.id && c.have_self { return c.self.parent, true }
	if s := find_session(app, id); s != nil { return s.parent, true }
	if s := find_child(c, id); s != nil { return s.parent, true }
	return "", false
}

// A sub-agent works on what its session asked for: it uses that session's browser. `known` false: nothing is known of `id` yet.
preview_root :: proc(app: ^App, id: string) -> (root: string, known: bool) {
	root = id
	for _ in 0 ..< PREVIEW_PARENTS_MOST {
		parent, found := session_parent(app, root)
		if !found { return root, root != id }   // (a parent named, not read: the furthest one can say)
		if parent == "" { return root, true }
		root = parent
	}
	return root, true
}

// The browser of what is shown. (A sub-agent opened by its address is not known at once: until it is, the browser stays.)
@(private = "file")
preview_key :: proc(app: ^App) -> (key: string, known: bool) {
	if app.chat.id == "" { return "", true }
	return preview_root(app, len(app.nav) > 0 ? app.nav[0] : app.chat.id)
}

// The Preview of `key`, shown or parked, made if it has none.
preview_entry :: proc(app: ^App, key: string) -> ^Preview {
	if key == app.preview.key { return &app.preview }
	if e, parked := app.cx.previews[key]; parked { return e }
	e := new(Preview)
	e.key = strings.clone(key)
	app.cx.previews[e.key] = e
	return e
}

// The window a tab's page belongs in: what is not on the screen waits in the main one, whatever becomes of the panel's.
preview_window :: proc(app: ^App, t: ^Preview_Tab) -> ^platform.Window {
	if preview_tab_shown(app, t) { if w := detached_window(app, u32(Panel.Preview)); w != nil { return w } }
	return app.win
}

// The panel changes windows, and the page on the screen with it.
preview_move :: proc(app: ^App, w: ^platform.Window) {
	if t := preview_front(&app.preview); t != nil {
		web_parent(t, w)
		t.placed = {}   // (its place was in the other window)
	}
}

preview_touch :: proc(app: ^App, t: ^Preview_Tab) {
	app.cx.preview_clock += 1
	t.used = app.cx.preview_clock
}

////////////////////////////////
// Following the session shown

// Once a frame, where nothing is being built.
preview_follow :: proc(app: ^App) {
	preview_dues(app)
	key, known := preview_key(app)
	if known && key != app.preview.key { preview_switch(app, key) }
}

// Hidden and parked, the next one brought: its pages as they were left, never loaded again unless the limit took their view.
@(private = "file")
preview_switch :: proc(app: ^App, key: string) {
	d := &app.dock
	old := &app.preview
	window := detached_window(app, u32(Panel.Preview))
	was_open, was_front := old.open, ui.dock_shown(d, u32(Panel.Preview))
	if t := preview_front(old); t != nil { tab_leave(app, t) }
	preview_park(app)

	if e, parked := app.cx.previews[key]; parked {
		delete_key(&app.cx.previews, key)
		app.preview = e^
		free(e)
	} else {
		app.preview = {key = strings.clone(key)}
	}
	p := &app.preview
	p.shown = false
	if t := preview_front(p); t != nil {
		t.focus_address = false
		tab_bring(app, t)
	}

	// (A panel in a window of its own has no tab: the window just shows the next page, or an empty panel.)
	if window == nil {
		if !p.open {
			ui.dock_close(d, u32(Panel.Preview))
		} else {
			if !ui.dock_has(d, u32(Panel.Preview)) { dock_setup(app) }
			if !was_open || was_front { ui.dock_activate(d, u32(Panel.Preview)) }
		}
		d.saved = d.serial   // (another session shown is no change of the layout: the panel keeps its place in what is saved)
	}
	app.frames = max(app.frames, FRAMES_AFTER_INPUT)
}

// What holds nothing is not kept: going through a hundred sessions leaves nothing behind.
@(private = "file")
preview_park :: proc(app: ^App) {
	old := &app.preview
	holds := old.open
	for t in old.tabs { holds ||= t.view != nil || t.url != "" }
	if old.gone || !holds {
		preview_free(app, old)
		return
	}
	old.due_new, old.due_front, old.due_close = false, nil, nil
	e := new(Preview)
	e^ = old^
	app.cx.previews[e.key] = e
}

// A tab with a view, its page loaded again from its address if the limit took the last one.
preview_revive :: proc(app: ^App, t: ^Preview_Tab) {
	lost := t.view == nil && t.url != ""
	web_start(app, t)
	if lost { web_navigate(app, t, t.url) }
}

@(private = "file")
oldest_of :: proc(app: ^App, p: ^Preview, keep, oldest: ^Preview_Tab) -> ^Preview_Tab {
	oldest := oldest
	for t in p.tabs {
		if t == keep || t.view == nil || preview_tab_shown(app, t) || browser_calls_on(app, t.view) { continue }
		if oldest == nil || t.used < oldest.used { oldest = t }
	}
	return oldest
}

// This is a program that must stay light, and each page is a browser's renderer in memory: past PREVIEW_VIEWS_MOST, across every session and
// tab, the view shown longest ago goes. The page on the screen never does, nor a view an agent's call waits on: its answer must come from
// it. The tab stays with its address and its id: showing it loads the page again; what is lost is the page's own state and its history.
@(private = "file")
preview_trim :: proc(app: ^App, keep: ^Preview_Tab) {
	for len(app.cx.web_views) > PREVIEW_VIEWS_MOST {
		oldest := oldest_of(app, &app.preview, keep, nil)
		for _, e in app.cx.previews { oldest = oldest_of(app, e, keep, oldest) }
		if oldest == nil { return }
		web_close(app, oldest)
		clear(&oldest.navs)
	}
}

// As if it had never been opened.
preview_tabs_clear :: proc(app: ^App, p: ^Preview) {
	for t in p.tabs { tab_free(app, t) }
	clear(&p.tabs)
	p.front = 0
	p.due_new, p.due_front, p.due_close = false, nil, nil
}

preview_free :: proc(app: ^App, p: ^Preview) {
	preview_tabs_clear(app, p)
	delete(p.tabs)
	delete(p.key)
}

// The session went: its browser with it. (The one shown goes when it stops being shown, which comes next: nav_apply.)
preview_session_gone :: proc(app: ^App, id: string) {
	if id == app.preview.key {
		app.preview.gone = true
		return
	}
	e, parked := app.cx.previews[id]
	if !parked { return }
	delete_key(&app.cx.previews, id)
	preview_free(app, e)
	free(e)
}

// The home page's prompt made this session: what was open beside it was opened for it, and stays with it.
preview_adopt :: proc(app: ^App, id: string) {
	p := &app.preview
	if p.key != "" || id in app.cx.previews { return }
	p.key = strings.clone(id)
}
