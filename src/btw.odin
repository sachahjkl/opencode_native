// /btw: an aside without leaving the conversation (src/md/features/chat-panes.md). The session shown is forked, the fork titled
// and sent a preamble then the person's text, and shown in a pane of its own, presented as a panel at the right of the
// conversation (BTW_VIEW). The pane is a conversation like the main one: the same build, the same composer.
package ocn

import tk_json "gt:json"
import "core:fmt"
import "core:math"
import "core:strings"
import "gt:ui"
import lucide "gt:lucide"
import i18n "gt:i18n"

BTW_VIEW :: "btw"

// The metadata.source of the preamble's synthetic message: what the display hides (model.odin synthetic_set).
BTW_SOURCE :: "ocn.btw"

// What the fork reads before the person's text. English: the model's language, not the interface's.
BTW_PREAMBLE :: "This conversation is a short aside of the conversation it was forked from. Answer the next message briefly. Change no file unless asked."

// The fork's title: "btw: " and the first words of the text, at most this many, at most this long.
BTW_TITLE_WORDS :: 6
BTW_TITLE_CHARS :: 48

// The pane the panel shows, nil: none.
btw_pane :: proc(app: ^App) -> ^Chat_Pane {
	if app.btw == 0 || !app.panes[app.btw].shown { return nil }
	return &app.panes[app.btw]
}

// `/btw <text>` from `pane`: its session forked at its last message; while a run streams, before the answer that streams (what
// it said so far has no end to keep).
btw_start :: proc(app: ^App, pane: ^Chat_Pane, text: string) {
	c := &pane.chat
	before := ""
	if c.busy {
		#reverse for &m in c.messages {
			if m.kind == .Assistant && m.streaming { before = fork_before(c, &m); break }
		}
	}
	outgoing_aside(app, pane, before, text)
}

// The panel shows session `id`, in its pane (made when none is shown), and opens. The keyboard stays where it is.
btw_open :: proc(app: ^App, id: string) -> ^Chat_Pane {
	pane := btw_pane(app)
	if pane == nil { pane = pane_free(app) }
	assert(pane != nil, "a pane for the panel")   // (PANES_MAX leaves room: only the panel takes one)
	app.btw = pane_index(app, pane)
	pane_show(app, pane, id)
	ui.view_open(&app.program_views, BTW_VIEW, app)
	return pane
}

// The panel closes, and its pane with it; its session stays in the sidebar.
btw_close :: proc(app: ^App) {
	if pane := btw_pane(app); pane != nil { pane_close(app, pane) }
	app.btw = 0
	ui.view_close(&app.program_views, BTW_VIEW)
}

// The panel's session goes to the main view; the panel closes. (Closed first: its composer's text waits in the session's draft,
// and the main view's composer takes it.)
btw_to_main :: proc(app: ^App) {
	pane := btw_pane(app)
	if pane == nil { return }
	id := strings.clone(pane.chat.id, context.temp_allocator)
	btw_close(app)
	open_root(app, id)
}

// "btw: " and the first words of `text`, on one line.
btw_title :: proc(text: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "btw:")
	rest := text
	n := 0
	for word in strings.fields_iterator(&rest) {
		if n == BTW_TITLE_WORDS || strings.builder_len(b) + 1 + len(word) > BTW_TITLE_CHARS {
			strings.write_string(&b, "…")
			break
		}
		strings.write_byte(&b, ' ')
		strings.write_string(&b, word)
		n += 1
	}
	return strings.to_string(b)
}

// The body of the preamble: a synthetic message that does not start a run (the prompt that follows does), marked for the display.
btw_preamble_body :: proc() -> string {
	return fmt.tprintf(`{{"text":%s,"description":"btw","metadata":{{"source":%s}},"resume":false}}`, tk_json.quote(BTW_PREAMBLE), tk_json.quote(BTW_SOURCE))
}

// The panel: the fork's conversation and its composer. Its tab says the title (the strip shows with the panel alone:
// tabs_always), the strip carries the way to the main view; the body has no header of its own, which would say the title twice.
btw_view :: proc(v: ^ui.View, app: ^App) {
	pane := btw_pane(app)
	if pane == nil { ui.view_end(v, 0); return }
	em := ui.font_size()
	// (in a window of its own the panel is that window's whole build: what the main window's build opens and builds over its
	// panes, at its top and at its end, this one does for its pane. Docked or floating, it is part of the main window's build,
	// which does it once.)
	own_window := built_state(app) != &app.state
	if own_window { chooser_build(app) }
	defer if own_window { window_overlays(app, em) }
	title := i18n.tr("Aside")
	if s := find_session(app, pane.chat.id); s != nil && s.title != "" { title = s.title } else if pane.chat.have_self && pane.chat.self.title != "" { title = pane.chat.self.title }
	ui.view_title(v, title)
	if ui.view_header_tools(v) {
		size := math.round(em * BUTTON_COMPACT_H_EM)
		ui.a11y({role = .Button, name = i18n.tr("Open in the main view")})
		ui.next({width = ui.px(size), height = ui.px(size)})
		sig := ui.button("btw_main", icon = lucide.MAXIMIZE_2, o = {face = .Ghost})
		if ui.hovered_for(sig) { if ui.tooltip() { ui.tooltip_text(i18n.tr("Open in the main view")) } }
		if sig.clicked { btw_to_main(app); return }
	}
	conversation(app, pane, em, ui.view_room(v).x)
}
