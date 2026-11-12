// Sub-agents: a session launches others (tool "subagent"), each a session of its own whose parent is the first. Here:
// what is known of one (its call, its session, its result, what it does now), the card that shows it in the parent's
// conversation, the line of its result, drilling down into it and back, the banner of a sub-agent's own conversation,
// the menu of a session's sub-agents, and their tree in the sidebar.
package ocn

import "core:fmt"
import "core:hash"
import "core:math"
import "core:strings"
import "gt:draw"
import "gt:markdown"
import "gt:ui"
import lucide "gt:lucide"

HEX_SUB_CANCELLED    :: 0xb08a5aff
HEX_CARD_OFF_TOP     :: 0x111111ff
HEX_CARD_OFF_BOTTOM  :: 0x0e0e0eff
HEX_CARD_RESULT_LINE :: 0xa8a8a8ff
HEX_CARD_RESULT      :: 0xd8d8d8ff
HEX_RETURNED_TEXT    :: 0xcfcfcfff
HEX_SUB_TOGGLE_HOT   :: 0x161616ff

// A card's first line, in font sizes: its padding, its mark, the gap after it; the lines under it start under the name.
CARD_PAD_EM      :: 0.8
CARD_MARK_EM     :: 0.9
CARD_MARK_GAP_EM :: 0.45
CARD_INDENT_EM   :: CARD_PAD_EM + CARD_MARK_EM + CARD_MARK_GAP_EM
SEEK_ANCHOR_EM     :: 7      // --seek-subagent: how far down the view it lands
PROMPT_LINES_MAX   :: 18
FINISHED_SHOWN     :: 40     // in the menu of the sub-agents

// What the menu and the chips keep of a title or an activity, in characters.
MENU_TITLE_CHARS    :: 40
MENU_ACTIVITY_CHARS :: 36
MENU_FINISHED_CHARS :: 48
CHIP_TITLE_CHARS    :: 34
CHIP_ACTIVITY_CHARS :: 30

Sub_State :: enum u8 { Starting, Running, Done, Failed, Cancelled, Unknown }

// Everything known of one sub-agent, gathered from its call, its session, its result message and the live stream.
Sub_View :: struct {
	id:         string,          // its session ("" until the server gave it)
	agent:      string,
	desc:       string,
	prompt:     string,
	model:      string,
	background: bool,
	state:      Sub_State,
	result:     string,          // what it handed back
	session:    ^Session_Info,   // its session, when known (children of the session shown)
	live:       Sub_Live,
	has_live:   bool,
	started, ended: f64,         // epoch ms (ended 0: still going)
}

sub_state_label :: proc(s: Sub_State) -> string {
	switch s {
	case .Starting:  return "starting"
	case .Running:   return "running"
	case .Done:      return "done"
	case .Failed:    return "failed"
	case .Cancelled: return "cancelled"
	case .Unknown:   return "launched"
	}
	return ""
}

sub_state_color :: proc(s: Sub_State) -> Color {
	switch s {
	case .Starting, .Unknown: return hex(HEX_FAINT)
	case .Running:            return hex(HEX_YELLOW)
	case .Done:               return hex(HEX_GREEN)
	case .Failed:             return hex(HEX_RED)
	case .Cancelled:          return hex(HEX_SUB_CANCELLED)
	}
	return {}
}

state_of_word :: proc(w: string) -> (Sub_State, bool) {
	switch w {
	case "completed", "succeeded":            return .Done, true
	case "error", "failed":                   return .Failed, true
	case "cancelled", "interrupted":          return .Cancelled, true
	case "running":                           return .Running, true
	}
	return .Unknown, false
}

// What the conversation says of its sub-agents, read again only when that changed (Chat.subs_seq: subs_changed): the message each one's
// result came back in, and the sessions a call names as its own. Each card, each row of the activity, each event of another session
// asked it of every message, at every build.
Sub_Index :: struct {
	made:     bool,
	at:       u64,                // Chat.subs_seq it was read at
	results:  map[string]int,     // a sub-agent's session → the last message its result came back in (an index into messages)
	claimed:  map[string]bool,    // the sessions a call of the conversation names
	computed: int,                // times it was read (tests)
}

sub_index :: proc(c: ^Chat) -> ^Sub_Index {
	x := &c.subs
	if x.made && x.at == c.subs_seq { return x }
	a := arena_renew(&c.subs_arena)
	x.results = make(map[string]int, allocator = a)
	x.claimed = make(map[string]bool, allocator = a)
	for &m, i in c.messages {
		if m.kind == .Synthetic && m.sub_child != "" { x.results[strings.clone(m.sub_child, a)] = i }   // (the last one wins)
		for &p in m.parts { if p.sub_session != "" { x.claimed[strings.clone(p.sub_session, a)] = true } }
	}
	x.made, x.at = true, c.subs_seq
	x.computed += 1
	return x
}

// The result message of a sub-agent in the session shown (nil: none yet).
sub_result :: proc(c: ^Chat, child: string) -> ^Message {
	if child == "" { return nil }
	if i, ok := sub_index(c).results[child]; ok { return &c.messages[i] }
	return nil
}

// What is known of the sub-agent `child` (a session id), from a call `p` when there is one.
sub_view :: proc(app: ^App, child: string, p: ^Part = nil) -> (v: Sub_View) {
	c := &app.chat
	v.id = child
	v.state = .Unknown
	if p != nil {
		v.agent, v.desc, v.prompt, v.model, v.background = p.sub_agent, p.sub_desc, p.sub_prompt, p.sub_model, p.sub_background
		v.started = p.started_ms
		switch p.status {
		case .Pending: v.state = .Starting
		case .Running: v.state = .Running
		case .Error:   v.state = .Failed; v.result = p.output; v.ended = p.ended_ms
		case .Done:
			// a foreground call ends with the sub-agent: its output is the result; a background one only launched it
			if !p.sub_background { v.state = .Done; v.result = p.output; v.ended = p.ended_ms }
		case .Unknown:
		}
	}
	if child == "" { return }
	if s := find_child(c, child); s != nil {
		v.session = s
		if v.desc == "" { v.desc = s.title }
		if v.agent == "" { v.agent = s.agent }
		if v.model == "" && s.model != "" { v.model = s.model }
		if v.started == 0 { v.started = s.created }
		if st, ok := state_of_word(s.outcome); ok && v.state != .Failed { v.state = st; if s.idle > 0 { v.ended = s.idle } }
	}
	if m := sub_result(c, child); m != nil {
		if st, ok := state_of_word(m.sub_state); ok { v.state = st }
		if m.text != "" { v.result = m.text }
		if v.desc == "" { v.desc = m.sub_desc }
		if v.agent == "" { v.agent = strings.to_lower(m.sub_agent, context.temp_allocator) }
		if v.ended == 0 { v.ended = m.created }
	}
	if l, ok := c.live[child]; ok { v.live, v.has_live = l, true }
	if app.busy[child] or_else false { v.state = .Running; v.ended = 0 }
	return
}

////////////////////////////////
// Navigation

// Navigation is asked for while the interface is built, by boxes that go on reading what they show, and opening a session
// drops the arena that holds it. So these only note it: nav_apply does it after the frame (frame).
Nav_Kind :: enum u8 { Root, Drill, Back, History, Gone }   // (Gone: the session shown was deleted elsewhere)
Nav_Step :: struct { kind: Nav_Kind, id: string }   // (id owned)

// Where one goes and has been: the way back up drilled sub-agents, the steps asked for in this frame, the history of places.
Nav :: struct {
	drilled: [dynamic]string,      // the sessions drilled down from, outermost first (owned): Back returns to the last
	steps:   [dynamic]Nav_Step,    // navigation asked for in this frame
	visited: [dynamic]Nav_Place,   // where one has been (nav_visit)
	at:      int,                  // where one is in it
	moving:  bool,                 // a step of the history: nothing to add to it
}

// Opens a session from the sidebar: no way back but its parent.
open_root :: proc(app: ^App, id: string) { append(&app.nav.steps, Nav_Step{.Root, strings.clone(id)}) }

// Opens the sub-agent `child` of the session shown; Back comes here again.
drill_down :: proc(app: ^App, child: string) {
	if child == "" { return }
	append(&app.nav.steps, Nav_Step{.Drill, strings.clone(child)})
}

go_back :: proc(app: ^App) { append(&app.nav.steps, Nav_Step{kind = .Back}) }

// What was asked for during the frame, in order.
nav_apply :: proc(app: ^App) {
	if len(app.nav.steps) == 0 { return }
	for st in app.nav.steps {
		switch st.kind {
		case .Root:
			for s in app.nav.drilled { delete(s) }
			clear(&app.nav.drilled)
			open_chat(app, st.id)
		case .Drill:
			if st.id != app.chat.id {
				if app.chat.id != "" { append(&app.nav.drilled, strings.clone(app.chat.id)) }
				open_chat(app, st.id)
			}
		case .Back:
			nav_back(app)
		case .History:
			// (a place already in the history: going there adds nothing to it. The way up a sub-agent's parents stays the parent)
			app.nav.moving = true
			for s in app.nav.drilled { delete(s) }
			clear(&app.nav.drilled)
			if st.id == "" { new_session(app) } else { open_chat(app, st.id) }
			app.nav.moving = false
			nav_restore(app, st.id)
		case .Gone:
			app.nav.moving = true   // (it left the history: nav_forget)
			new_session(app)
			app.nav.moving = false
		}
		delete(st.id)
	}
	clear(&app.nav.steps)
	app.settle = max(app.settle, FRAMES_AFTER_INPUT)
}

// A place of the history: a session ("": the home page), and where the reader was in it: the message at the top of the view and how
// far into it. A message, not an offset: what is not built has a height estimated, and a page read above moves everything.
Nav_Place :: struct {
	id, msg: string,   // (owned)
	dy:      f32,
	bottom:  bool,     // at the end, following it
}

@(private = "file")
nav_place_free :: proc(p: Nav_Place) { delete(p.id); delete(p.msg) }

// Where the reader is, kept in the place they leave.
@(private = "file")
nav_mark :: proc(app: ^App) {
	nav := &app.nav
	if nav.at >= len(nav.visited) { return }
	p := &nav.visited[nav.at]
	if p.id != app.chat.id || p.id == "" { return }
	delete(p.msg)
	p.msg, p.dy, p.bottom = strings.clone(app.chat.view_msg), app.chat.view_dy, chat_following(app)
}

// Where one has been, as in a browser: every session opened and the home page ("") go here, whichever way they were reached (the
// sidebar, the palette, a sub-agent's card); going somewhere from the middle of it forgets what was ahead. `from` is where the
// window is, for the first step.
nav_visit :: proc(app: ^App, from, id: string) {
	nav := &app.nav
	if nav.moving { return }
	nav_mark(app)
	if len(nav.visited) == 0 { append(&nav.visited, Nav_Place{id = strings.clone(from)}); nav.at = 0 }
	if nav.visited[nav.at].id == id { return }
	for len(nav.visited) > nav.at + 1 { nav_place_free(pop(&nav.visited)) }
	append(&nav.visited, Nav_Place{id = strings.clone(id)})
	nav.at += 1
	if len(nav.visited) > NAV_HISTORY_MAX {
		nav_place_free(nav.visited[0])
		ordered_remove(&nav.visited, 0)
		nav.at -= 1
	}
}

// Whether there is somewhere `d` steps from here (-1: back, 1: forward).
nav_can :: proc(app: ^App, d: int) -> bool {
	i := app.nav.at + d
	return i >= 0 && i < len(app.nav.visited)
}

nav_step :: proc(app: ^App, d: int) {
	if !nav_can(app, d) { return }
	nav_mark(app)
	app.nav.at += d
	append(&app.nav.steps, Nav_Step{.History, strings.clone(app.nav.visited[app.nav.at].id)})
}

// The view goes back to where it was in the place reached (messages does it, once the message is there and laid out). (The same
// session: open_chat did not start the view over, and a way back under way ends here.)
@(private = "file")
nav_restore :: proc(app: ^App, id: string) {
	nav := &app.nav
	if nav.at < len(nav.visited) {
		p := nav.visited[nav.at]
		if p.id == id && id != "" && !p.bottom && p.msg != "" {
			chat_scroll_event(app, Scroll_Restore{p.msg, p.dy})
			return
		}
	}
	chat_scroll_event(app, Scroll_Signal.Restore_End)
}

// The conversation's scroll bar is held.
scrollbar_held :: proc(app: ^App, sb: ^ui.Box) -> bool {
	owner, held := app.state.sb_owner[ui.active_key()]
	return held && owner == sb.key
}

// A session that is gone leaves the history, and what it separated does not stand twice in a row.
nav_forget :: proc(app: ^App, id: string) {
	nav := &app.nav
	drop :: proc(nav: ^Nav, i: int) {
		nav_place_free(nav.visited[i])
		ordered_remove(&nav.visited, i)
		if i <= nav.at && nav.at > 0 { nav.at -= 1 }
	}
	gone := strings.clone(id, context.temp_allocator)   // (it may be one of them)
	for i := len(nav.visited) - 1; i >= 0; i -= 1 { if nav.visited[i].id == gone { drop(nav, i) } }
	for i := len(nav.visited) - 1; i > 0; i -= 1 { if nav.visited[i].id == nav.visited[i - 1].id { drop(nav, i) } }
	for i := len(app.nav.drilled) - 1; i >= 0; i -= 1 {
		if app.nav.drilled[i] == gone { delete(app.nav.drilled[i]); ordered_remove(&app.nav.drilled, i) }
	}
}

nav_clear :: proc(app: ^App) {
	for p in app.nav.visited { nav_place_free(p) }
	clear(&app.nav.visited)
	app.nav.at = 0
	app.chat.view_msg = ""
	chat_scroll_event(app, Scroll_Signal.Restore_End)
}

// The session to go back to: the one drilled down from, else the parent.
back_target :: proc(app: ^App) -> string {
	if len(app.nav.drilled) > 0 { return app.nav.drilled[len(app.nav.drilled) - 1] }
	return app.chat.self.parent
}

@(private = "file")
nav_back :: proc(app: ^App) {
	if len(app.nav.drilled) > 0 {
		id := pop(&app.nav.drilled)
		defer delete(id)
		open_chat(app, id)
	} else if p := app.chat.self.parent; p != "" {
		open_chat(app, strings.clone(p, context.temp_allocator))
	}
}

////////////////////////////////
// The card of a sub-agent call (in the parent's conversation)

// A card's header, lit a little under the pointer.
@(private = "file")
card_head_draw :: proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
	if b.hot_t > FADE_VISIBLE { draw.rect(dc, b.rect, {1, 1, 1, 0.012 * b.hot_t}, CARD_RADIUS * ui.scale()) }
}

// A sub-agent's call: a calm plate of the neutral steps, the only colour its state's, on its mark. One that runs is raised
// and carries a pulsing lamp; one that is over is flat and dim, one line until it is opened.
subagent_card :: proc(app: ^App, p: ^Part, pid: string, em: f32) {
	v := sub_view(app, p.sub_session != "" ? p.sub_session : sub_session_guess(&app.chat, p), p)
	part_id := p.tool_id != "" ? p.tool_id : pid
	open := part_open(app, part_id)
	running := v.state == .Running || v.state == .Starting
	if running { animate(app) }
	ui.next({width = ui.fill(), height = ui.children_sum(), axis = .Y})
	pt, pb: u32 = HEX_PLATE_TOP, HEX_PLATE_BOTTOM
	shadow, rim: f32 = 3, 0.07
	border := Color{0, 0, 0, 0.85}
	if !running { pt, pb, shadow, rim, border = HEX_CARD_OFF_TOP, HEX_CARD_OFF_BOTTOM, 0, 0.03, {0, 0, 0, 0.7} }
	if plate(fmt.tprintf("###sa_%s", pid), top = pt, bottom = pb, radius = CARD_RADIUS, shadow = shadow, rim = rim, border = border) {
		card_head(app, &v, part_id, open, running, em)
		if open { card_body(app, &v, p, pid, running, em) }
	}
	ui.spacer(ui.px(em * 0.6))
}

// The session of a sub-agent call whose own the server has not said yet: it says it when the call ends, so a running card could not
// be opened. The child of the shown session with the call's description as its title (and its agent), not another call's, the
// first one made after the call started. "": none.
sub_session_guess :: proc(c: ^Chat, p: ^Part) -> string {
	if p.sub_desc == "" { return "" }
	best: ^Session_Info
	for &s in c.children {
		if s.title != p.sub_desc || (p.sub_agent != "" && s.agent != "" && s.agent != p.sub_agent) { continue }
		if p.started_ms > 0 && s.created + SUB_GUESS_SLACK_MS < p.started_ms { continue }   // (made before the call: another one's)
		if s.id in sub_index(c).claimed { continue }   // (a call of the conversation names it as its own already)
		if best == nil || s.created < best.created { best = &s }
	}
	return best != nil ? best.id : ""
}

SUB_GUESS_SLACK_MS :: 5000   // a child made this much before the call's start is still its (the two clocks are the server's, a step apart)

// The clickable header of a card: its first line and, unless it is folded and over, the quiet line and a preview.
@(private = "file")
card_head :: proc(app: ^App, v: ^Sub_View, part_id: string, open, running: bool, em: f32) {
	end := v.ended > 0 ? v.ended : (running ? now_epoch_ms() : 0)
	name := v.agent != "" ? v.agent : "sub-agent"
	desc := v.desc != "" ? v.desc : "(no description)"
	ui.next({width = ui.fill(), height = ui.children_sum(), axis = .Y})
	ui.a11y({role = .Button, name = fmt.tprintf("%s, %s: %s", sub_state_label(v.state), name, desc)})
	head := ui.build_box({.Clickable, .Focusable, .Hot_Within}, "###head")
	head.custom = card_head_draw
	hs := ui.signal(head)
	if hs.clicked { part_toggle(app, part_id, head) }
	if app.seek_subagent && !chat_anchored(app) && head.rect.max.y != head.rect.min.y && app.chat.loaded {
		// --seek-subagent (tests): bring the first card near the top, as an anchor does
		app.seek_subagent = false
		chat_scroll_event(app, Scroll_Anchor{head, math.round(em * SEEK_ANCHOR_EM)})
	}
	if hs.double_clicked && v.id != "" { drill_down(app, v.id) }
	if ui.parent(head) { card_lines(app, v, name, desc, open, running, end, em) }
}

// What a card's header shows.
@(private = "file")
card_lines :: proc(app: ^App, v: ^Sub_View, name, desc: string, open, running: bool, end: f64, em: f32) {
	compact := !running && !open
	// (one line unless a second has something to say: how long is on the first, whatever the state)
	meta := compact ? "" : card_meta(v, running)
	preview := !compact && !open && v.result != ""
	tight := meta == "" && !preview
	ui.spacer(ui.px(em * (tight ? 0.2 : 0.45)))
	ui.next({width = ui.fill(), height = ui.px(math.round(em * 1.9)), axis = .X, cross = .Center})
	if ui.row(.Center, id = "###l1") {
		ui.spacer(ui.px(em * CARD_PAD_EM))
		state_mark("###st", sub_state_color(v.state), running, size = em * CARD_MARK_EM)
		ui.spacer(ui.px(em * CARD_MARK_GAP_EM))
		text("ag", name, running ? hex(HEX_WEAK) : hex(HEX_FAINT), ui.Style_Mod{font = app.mono_bold, font_size = math.round(em * FS_SMALL)})
		ui.spacer(ui.px(em * 0.6))
		text("ds", desc, running ? hex(HEX_TEXT) : hex(HEX_WEAK), ui.Style_Mod{font_size = math.round(em * FS_LABEL)}, ui.fill())
		ui.spacer(ui.px(em * 0.5))
		if what := card_when(v, end); what != "" {
			text("du", what, hex(HEX_FAINT), ui.Style_Mod{font = app.mono, font_size = math.round(em * FS_CAPTION)})
			ui.spacer(ui.px(em * 0.5))
		}
		if v.id != "" {
			if bevel_button("###open", "Open", "", height = math.round(em * BUTTON_SMALL_H_EM), quiet = true, face = .Ghost).clicked { drill_down(app, v.id) }
			ui.spacer(ui.px(em * 0.2))
		}
		glyph(open ? lucide.CHEVRON_DOWN : lucide.CHEVRON_RIGHT, hex(HEX_FAINT), math.round(em * ICON_TINY), em * 1.1)
		ui.spacer(ui.px(em * 0.5))
	}
	if meta != "" {
		ui.next({width = ui.fill(), height = ui.px(math.round(em * 1.3)), axis = .X, cross = .Center})
		if ui.row(.Center, id = "###l2") {
			ui.spacer(ui.px(em * CARD_INDENT_EM))
			text("mt", meta, hex(HEX_FAINT), ui.Style_Mod{font = app.mono, font_size = math.round(em * FS_CAPTION)}, ui.fill())
			ui.spacer(ui.px(em * 0.8))
		}
	}
	// folded while it runs: what it has said so far
	if preview {
		ui.next({width = ui.fill(), height = ui.px(math.round(em * 1.5)), axis = .X, cross = .Center})
		if ui.row(.Center, id = "###l3") {
			ui.spacer(ui.px(em * CARD_INDENT_EM))
			text("rs", preview_text(v.result), hex(HEX_CARD_RESULT_LINE), ui.Style_Mod{font_size = math.round(em * FS_NOTE)}, ui.fill())
			ui.spacer(ui.px(em * 0.8))
		}
	}
	ui.spacer(ui.px(em * (tight ? 0.2 : 0.5)))
}

// What a card keeps on its first line, at its right: the state where it needs words (the mark says the others), how long.
card_when :: proc(v: ^Sub_View, end: f64) -> string {
	d := duration_text(v.started, end)
	if v.state != .Failed && v.state != .Cancelled { return d }
	return d != "" ? fmt.tprintf("%s · %s", sub_state_label(v.state), d) : sub_state_label(v.state)
}

// A card opened: what its session says, its prompt (`p`'s), its result.
card_body :: proc(app: ^App, v: ^Sub_View, p: ^Part, pid: string, running: bool, em: f32) {
	ui.next({width = ui.fill(), height = ui.children_sum(), axis = .X})
	if ui.row(id = "###body") {
		ui.spacer(ui.px(em * CARD_PAD_EM))
		ui.next({width = ui.fill(), height = ui.children_sum(), axis = .Y})
		if ui.column() {
			if v.session != nil {
				sub_facts(app, v, em)
				ui.spacer(ui.px(em * 0.5))
			}
			if v.prompt != "" {
				section_label("pr", "PROMPT", em)
				body, extra := mono_cut_kept(&p.prompt_well.cut, v.prompt, PROMPT_LINES_MAX)   // (the card is its frame: no box of its own inside it)
				mono_text(body, extra, em, 0, hex(HEX_TEXT_SOFT), flush = true, kept = &p.prompt_well.runs, kept_in = app.chat.alloc)
				ui.spacer(ui.px(em * 0.6))
			}
			if v.result != "" {
				section_label("re", v.state == .Failed ? "ERROR" : "RESULT", em)
				ui.next({width = ui.fill(), height = ui.children_sum(), axis = .Y})   // (as the prompt: in the card, no box of its own)
				if ui.column(id = "###result") {
					id := fmt.tprintf("%s_res", pid)
					markdown.view(md_doc(&app.chat, id), id, v.result, md_config(app, hex(HEX_CARD_RESULT)), math.round(em * FS_LABEL))
				}
				ui.spacer(ui.px(em * 0.4))
			} else if running {
				ui.next({width = ui.fill(), height = ui.px(em * 1.6), axis = .X, cross = .Center})
				if ui.row(.Center) { text("w", "No result yet: it is still working.", hex(HEX_FAINT), ui.Style_Mod{font_size = math.round(em * FS_NOTE)}, ui.fill()) }
			}
			ui.spacer(ui.px(em * 0.7))
		}
		ui.spacer(ui.px(em * CARD_PAD_EM))
	}
}

// The quiet line of a card, when it has something to say: what it does now, the model, tool calls, tokens, cost.
card_meta :: proc(v: ^Sub_View, running: bool) -> string {
	parts := make([dynamic]string, context.temp_allocator)
	if running && v.has_live && v.live.activity != "" { append(&parts, v.live.activity) }
	if v.background { append(&parts, "background") }
	if v.model != "" { append(&parts, short_model(v.model)) }
	if v.live.tools > 0 { append(&parts, fmt.tprintf("%d tools", v.live.tools)) }
	tin, tout, cost := sub_totals(v)
	if tin + tout > 0 { append(&parts, fmt.tprintf("%s in", kfmt(tin)), fmt.tprintf("%s out", kfmt(tout))) }
	if cost > 0 { append(&parts, fmt.tprintf("$%.2f", cost)) }
	return strings.join(parts[:], " · ", context.temp_allocator)
}

// "claude-sonnet-5-5" from "anthropic/claude-sonnet-5-5".
short_model :: proc(m: string) -> string {
	if i := strings.last_index_byte(m, '/'); i >= 0 { return m[i + 1:] }
	return m
}

// Its tokens in (cache reads included), out, and its cost: the live stream's while it runs, else its session's.
sub_totals :: proc(v: ^Sub_View) -> (tin, tout, cost: f64) {
	if v.session != nil {
		tin, tout, cost = v.session.tokens_in + v.session.cache_read, v.session.tokens_out, v.session.cost
	}
	if v.has_live && v.live.tokens_in + v.live.tokens_out > tin + tout {
		tin, tout = v.live.tokens_in, v.live.tokens_out
		cost = max(cost, v.live.cost)
	}
	return
}

// A table of what its session says: session id, started, idle, outcome, tokens in detail.
sub_facts :: proc(app: ^App, v: ^Sub_View, em: f32) {
	s := v.session
	section_label("fa", "SESSION", em)
	ui.next({width = ui.fill(), height = ui.children_sum(), axis = .Y})
	if well("###facts", radius = 7, base = HEX_FACTS_WELL) {
		ui.spacer(ui.px(em * 0.45))
		row :: proc(id, k, val: string, em: f32, col := Color{}) {
			kv_row(id, k, val, em, {h = 1.4, key_w = 7, key_fs = FS_CAPTION, val_fs = FS_CAPTION, pad_l = 0.8, val = HEX_TEXT_SOFT}, col)
		}
		row("###f1", "session", s.id, em)
		row("###f2", "title", s.title, em)
		row("###f3", "started", fmt.tprintf("%s  (%s ago)", clock_text(s.created, app.prefs.clock24), duration_text(s.created, now_epoch_ms())), em)
		if s.idle > 0 { row("###f4", "finished", fmt.tprintf("%s  after %s", clock_text(s.idle, app.prefs.clock24), duration_text(s.created, s.idle)), em) }
		if s.outcome != "" {
			row("###f5", "outcome", s.outcome, em)
		}
		row("###f6", "tokens", fmt.tprintf("in %s · out %s · reasoning %s · cache read %s · cache write %s", kfmt(s.tokens_in), kfmt(s.tokens_out), kfmt(s.reasoning), kfmt(s.cache_read), kfmt(s.cache_write)), em)
		if s.cost > 0 { row("###f7", "cost", fmt.tprintf("$%.4f", s.cost), em) }
		if v.has_live && v.live.steps + v.live.tools > 0 { row("###f8", "seen live", fmt.tprintf("%d steps · %d tool calls", v.live.steps, v.live.tools), em) }
		ui.spacer(ui.px(em * 0.45))
	}
}

////////////////////////////////
// The result of a sub-agent, where it came back in the parent's conversation

subagent_result :: proc(app: ^App, m: ^Message, em: f32) {
	v := sub_view(app, m.sub_child)
	st, _ := state_of_word(m.sub_state)
	open := part_open(app, m.id)
	ui.next({width = ui.fill(), height = ui.children_sum(), axis = .Y})
	if ui.column(id = fmt.tprintf("###sr_%s", m.id)) {
		ui.next({width = ui.fill(), height = ui.px(math.round(em * 2)), axis = .X, cross = .Center})
		hb := ui.build_box({.Clickable, .Focusable, .Hot_Within}, "###head")
		hb.custom = proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
			if b.hot_t > FADE_VISIBLE { draw.rect(dc, b.rect, {1, 1, 1, 0.035 * b.hot_t}) }   // (square: a row)
		}
		hs := ui.signal(hb)
		if hs.clicked { part_toggle(app, m.id, hb) }
		if ui.parent(hb) {
			ui.spacer(ui.px(em * CARD_PAD_EM))
			pip("###st", sub_state_color(st), em * CARD_MARK_EM)
			ui.spacer(ui.px(em * CARD_MARK_GAP_EM))
			word := st == .Done ? "returned" : sub_state_label(st)
			text("ag", fmt.tprintf("%s %s", v.agent != "" ? v.agent : "sub-agent", word), hex(HEX_FAINT), ui.Style_Mod{font = app.mono_bold, font_size = math.round(em * FS_SMALL)})
			ui.spacer(ui.px(em * 0.6))
			desc := m.sub_desc != "" ? m.sub_desc : v.desc
			text("d", desc, hex(HEX_WEAK), ui.Style_Mod{font_size = math.round(em * FS_LABEL)}, ui.fill())
			text("at", clock_text(m.created, app.prefs.clock24), hex(HEX_FAINT), ui.Style_Mod{font = app.mono, font_size = math.round(em * FS_CAPTION)})
			ui.spacer(ui.px(em * 0.5))
			if m.sub_child != "" {
				if bevel_button("###open", "Open", "", height = math.round(em * BUTTON_SMALL_H_EM), quiet = true, face = .Ghost).clicked { drill_down(app, m.sub_child) }
				ui.spacer(ui.px(em * 0.2))
			}
			glyph(open ? lucide.CHEVRON_DOWN : lucide.CHEVRON_RIGHT, hex(HEX_FAINT), math.round(em * ICON_TINY), em * 1.1)
			ui.spacer(ui.px(em * 0.5))
		}
		if open && m.text != "" {
			ui.next({width = ui.fill(), height = ui.children_sum(), axis = .X})
			if rail_row(fmt.tprintf("###srb_%s", m.id), with_alpha(hex(HEX_WEAK), 0.4)) {
				ui.spacer(ui.px(em * 1.0))
				ui.next({width = ui.fill(), height = ui.children_sum(), axis = .Y})
				if ui.column() {
					ui.spacer(ui.px(em * 0.3))
					id := fmt.tprintf("%s_sr", m.id)
					markdown.view(md_doc(&app.chat, id), id, m.text, md_config(app, hex(HEX_RETURNED_TEXT)), math.round(em * FS_LABEL))
					ui.spacer(ui.px(em * 0.3))
				}
			}
		}
	}
	ui.spacer(ui.px(em * 0.5))
}

////////////////////////////////
// A sub-agent's own conversation: where it comes from, and the way back

subagent_banner :: proc(app: ^App, em: f32) {
	c := &app.chat
	if !c.have_self || c.self.parent == "" { return }
	s := &c.self
	st, known := state_of_word(s.outcome)
	if app.busy[s.id] or_else false { st, known = .Running, true }
	ui.spacer(ui.px(em * 0.4))
	ui.next({width = ui.fill(), height = ui.children_sum(), axis = .Y})
	if plate("###sub_banner", radius = CARD_RADIUS, shadow = 3) {
		if bx := ui.parent_box(); app.seek_subagent && !chat_anchored(app) && bx.rect.max.y > 0 && c.loaded {
			app.seek_subagent = false   // --seek-subagent (tests): bring the banner into view
			chat_scroll_event(app, Scroll_Anchor{bx, math.round(em * SEEK_ANCHOR_EM)})
		}
		ui.spacer(ui.px(em * 0.7))
		ui.next({width = ui.fill(), height = ui.children_sum(), axis = .X, cross = .Center})
		if ui.row(.Center, id = "###r1") {
			ui.spacer(ui.px(em))
			glyph(lucide.BOT, hex(HEX_FAINT), math.round(em * ICON_LARGE), em * 1.8)
			ui.spacer(ui.px(em * 0.4))
			ui.next({width = ui.fill(), height = ui.children_sum(), axis = .Y})
			if ui.column() {
				ui.next({width = ui.fill(), height = ui.px(em * 1.5), axis = .X, cross = .Center})
				if ui.row(.Center) {
					text("k", "SUB-AGENT", hex(HEX_FAINT), ui.Style_Mod{font = app.mono_bold, font_size = math.round(em * FS_CAPTION)})
					ui.spacer(ui.px(em * 0.5))
					text("a", s.agent, hex(HEX_TEXT), ui.Style_Mod{font = app.mono_bold, font_size = math.round(em * FS_SMALL)})
					if known {
						ui.spacer(ui.px(em * 0.5))
						state_mark("###l", sub_state_color(st), st == .Running, size = em * 0.75)
						if st == .Running { animate(app) }
						ui.spacer(ui.px(em * 0.25))
						text("s", sub_state_label(st), hex(HEX_FAINT), ui.Style_Mod{font = app.mono, font_size = math.round(em * FS_SMALL)})
					}
					ui.spacer(ui.fill())
				}
				parent := c.parent_title != "" ? c.parent_title : s.parent
				text("p", fmt.tprintf("launched by “%s”", parent), hex(HEX_WEAK), ui.Style_Mod{font_size = math.round(em * FS_NOTE), height = ui.px(em * 1.4)}, ui.fill())
				end := s.idle > 0 && st != .Running ? s.idle : now_epoch_ms()
				facts := fmt.tprintf("started %s · %s · %s in · %s out%s", clock_text(s.created, app.prefs.clock24), duration_text(s.created, end), kfmt(s.tokens_in + s.cache_read), kfmt(s.tokens_out), s.cost > 0 ? fmt.tprintf(" · $%.2f", s.cost) : "")
				text("f", facts, hex(HEX_FAINT), ui.Style_Mod{font = app.mono, font_size = math.round(em * FS_CAPTION), height = ui.px(em * 1.3)}, ui.fill())
			}
			ui.spacer(ui.px(em * 0.5))
			if bevel_button("###back", "Return to main session", lucide.ARROW_LEFT).clicked { go_back(app) }
			ui.spacer(ui.px(em))
		}
		ui.spacer(ui.px(em * 0.7))
	}
	ui.spacer(ui.px(em * 1.0))
}

////////////////////////////////
// The sub-agents of the session shown, as a button of its header and its menu

// The sub-agents of the session shown that run now.
active_children :: proc(app: ^App) -> [dynamic]^Session_Info {
	list := make([dynamic]^Session_Info, context.temp_allocator)
	for &s in app.chat.children { if app.busy[s.id] or_else false { append(&list, &s) } }
	return list
}

// The header's button: the running ones first and loud (a lit button, a pulsing lamp, their count); when none runs, a
// quiet count of the past ones. Its menu lists the running ones, then the finished ones.
subagents_button :: proc(app: ^App, em: f32) {
	c := &app.chat
	if len(c.children) == 0 { return }
	active := active_children(app)
	key := ui.key_from_string(0, "subagents_menu")
	sig: ui.Signal
	if len(active) > 0 {
		animate(app)
		lamp("###sub_lamp", hex(HEX_YELLOW), 1, pulse = true, size = em * 1.0)
		ui.spacer(ui.px(em * 0.3))
		sig = bevel_button("###subs", fmt.tprintf("%d active", len(active)), lucide.BOT, height = math.round(em * BUTTON_COMPACT_H_EM))
		ui.spacer(ui.px(em * 0.3))
		text("of", fmt.tprintf("/ %d", len(c.children)), hex(HEX_FAINT), ui.Style_Mod{font = app.mono, font_size = math.round(em * FS_SMALL)})
	} else {
		sig = glyph_label_button(app, "###subs", fmt.tprintf("%d past sub-agents", len(c.children)), em)
	}
	if sig.clicked { ui.ctx_menu_open_rect(key, sig.box.rect, sig.box.key) }
	if ui.ctx_menu(key, em * 32) {
		if len(active) > 0 {
			ui.menu_heading(fmt.tprintf("Active now (%d)", len(active)))
			for s in active {
				v := sub_view(app, s.id)
				what := v.has_live && v.live.activity != "" ? v.live.activity : s.agent
				if ui.menu_item(fmt.tprintf("▶  %s  —  %s", label_safe(ellipsize(s.title, MENU_TITLE_CHARS)), label_safe(ellipsize(what, MENU_ACTIVITY_CHARS))), duration_text(s.created, now_epoch_ms())).clicked { drill_down(app, s.id) }
			}
			ui.menu_separator()
		}
		ui.menu_heading(fmt.tprintf("Finished (%d)", len(c.children) - len(active)))
		shown := 0
		for &s in c.children {
			if app.busy[s.id] or_else false { continue }
			if shown == FINISHED_SHOWN { ui.menu_item(fmt.tprintf("… and %d more", len(c.children) - len(active) - shown), enabled = false); break }
			v := sub_view(app, s.id)
			mark := "·"
			#partial switch v.state {
			case .Done:      mark = "✓"
			case .Failed:    mark = "✕"
			case .Cancelled: mark = "■"
			}
			end := v.ended > 0 ? v.ended : s.updated
			if ui.menu_item(fmt.tprintf("%s  %s · %s", mark, label_safe(ellipsize(s.title, MENU_FINISHED_CHARS)), label_safe(s.agent)), duration_text(s.created, end)).clicked { drill_down(app, s.id) }
			shown += 1
		}
	}
}

// A quiet button: a dim glyph and text, a bevel only under the pointer.
glyph_label_button :: proc(app: ^App, id, label: string, em: f32) -> ui.Signal {
	ui.next({width = ui.children_sum(), height = ui.px(math.round(em * BUTTON_COMPACT_H_EM)), axis = .X, cross = .Center})
	b := ui.build_box({.Clickable, .Focusable}, id)
	b.custom = proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
		if b.hot_t > FADE_VISIBLE { draw_bevel(dc, b.rect, BUTTON_RADIUS * ui.scale(), hex(HEX_BTN_GHOST), b.hot_t, b.active_t) }
	}
	sig := ui.signal(b)
	if ui.parent(b) {
		ui.spacer(ui.px(em * 0.5))
		glyph(lucide.BOT, hex(HEX_FAINT), math.round(em * ICON_REGULAR))
		ui.spacer(ui.px(em * 0.2))
		text("t", label, sig.hovering ? hex(HEX_TEXT) : hex(HEX_WEAK), ui.Style_Mod{font_size = math.round(em * FS_NOTE)})
		ui.spacer(ui.px(em * 0.6))
	}
	return sig
}

// Above the composer, while sub-agents of the session shown run: one chip each, in the language of their cards: a neutral
// plate, the lamp the only colour, what it does now and for how long quietly after its name. A click opens it.
active_strip :: proc(app: ^App, em: f32) {
	active := active_children(app)
	if len(active) == 0 { return }
	animate(app)
	now := now_epoch_ms()
	ui.next({width = ui.fill(), height = ui.children_sum(), gap = {em * 0.5, em * 0.5}})
	if ui.flow({em * 0.5, em * 0.5}, "###active_strip") {
		for s in active {
			v := sub_view(app, s.id)
			ui.next({width = ui.children_sum(), height = ui.px(math.round(em * BUTTON_COMPACT_H_EM)), axis = .X, cross = .Center})
			b := ui.build_box({.Clickable, .Focusable}, fmt.tprintf("###act_%s", s.id))
			b.custom = proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
				draw_bevel(dc, b.rect, BUTTON_RADIUS * ui.scale(), hex(HEX_BG3), b.hot_t, b.active_t)
			}
			sig := ui.signal(b)
			if sig.clicked { drill_down(app, s.id) }
			if ui.parent(b) {
				ui.spacer(ui.px(em * 0.55))
				lamp("###l", hex(HEX_YELLOW), 1, pulse = true, size = em * CARD_MARK_EM)
				ui.spacer(ui.px(em * 0.35))
				text("a", s.agent, hex(HEX_WEAK), ui.Style_Mod{font = app.mono_bold, font_size = math.round(em * FS_CAPTION)})
				ui.spacer(ui.px(em * 0.45))
				text("t", ellipsize(s.title, CHIP_TITLE_CHARS), hex(HEX_TEXT), ui.Style_Mod{font_size = math.round(em * FS_NOTE)})
				ui.spacer(ui.px(em * 0.5))
				what := duration_text(s.created, now)
				if v.has_live && v.live.activity != "" { what = fmt.tprintf("%s · %s", ellipsize(v.live.activity, CHIP_ACTIVITY_CHARS), what) }
				text("w", what, hex(HEX_FAINT), ui.Style_Mod{font = app.mono, font_size = math.round(em * FS_CAPTION)})
				ui.spacer(ui.px(em * 0.6))
			}
		}
	}
	ui.spacer(ui.px(em * 0.6))
}

////////////////////////////////
// The sidebar: a session's sub-agents under it

// The children of `id` among the loaded sessions (indices into app.sessions, newest first).
children_of :: proc(app: ^App, id: string, kids: map[string][dynamic]int) -> []int {
	if list, ok := kids[id]; ok { return list[:] }
	return nil
}

// A small disclosure + count beside a session that has sub-agents; returns whether its list is open.
sub_toggle :: proc(app: ^App, id: string, n: int, running: int, em: f32) -> bool {
	k := hash.fnv64a(transmute([]u8)id)
	open := app.sidebar.sub_open[k] or_else false
	ui.next({width = ui.children_sum(), height = ui.px(math.round(em * PILL_H_EM)), axis = .X, cross = .Center})
	b := ui.build_box({.Clickable}, "###subt")
	b.custom = proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
		draw_well(dc, b.rect, PILL_RADIUS, hex(b.hot_t > FADE_VISIBLE ? HEX_SUB_TOGGLE_HOT : HEX_PILL))
	}
	sig := ui.signal(b)
	if sig.clicked { app.sidebar.sub_open[k] = !open }
	if ui.parent(b) {
		ui.spacer(ui.px(em * 0.4))
		if running > 0 {
			// the running ones, loud: a pulsing lamp and their count; the total quietly after
			lamp("###l", hex(HEX_YELLOW), 1, pulse = true, size = em * 0.7)
			animate(the_app)
			ui.spacer(ui.px(em * 0.2))
			text("r", fmt.tprintf("%d", running), hex(HEX_YELLOW), ui.Style_Mod{font = the_app.mono_bold, font_size = math.round(em * FS_CAPTION)})
			text("n", fmt.tprintf("/%d", n), hex(HEX_FAINT), ui.Style_Mod{font = the_app.mono, font_size = math.round(em * FS_CAPTION)})
		} else {
			glyph(lucide.BOT, hex(HEX_FAINT), math.round(em * ICON_TINY), em * 0.9)
			text("n", fmt.tprintf("%d", n), hex(HEX_FAINT), ui.Style_Mod{font = the_app.mono, font_size = math.round(em * FS_CAPTION)})
		}
		glyph(open ? lucide.CHEVRON_DOWN : lucide.CHEVRON_RIGHT, hex(HEX_FAINT), math.round(em * ICON_TINY), em * 0.9)
		ui.spacer(ui.px(em * 0.2))
	}
	return open
}
