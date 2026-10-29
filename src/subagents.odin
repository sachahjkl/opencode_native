// Sub-agents: a session launches others (tool "subagent"), each a session of its own whose parent is the first. Here:
// what is known of one (its call, its session, its result, what it does now), the card that shows it in the parent's
// conversation, the line of its result, drilling down into it and back, the banner of a sub-agent's own conversation,
// the menu of a session's sub-agents, and their tree in the sidebar.
package occ

import "core:fmt"
import "core:hash"
import "core:math"
import "core:strings"
import "gt:draw"
import "gt:ui"

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
	case .Cancelled:          return hex(0xb08a5aff)
	}
	return {}
}

@(private = "file")
state_of_word :: proc(w: string) -> (Sub_State, bool) {
	switch w {
	case "completed", "succeeded":            return .Done, true
	case "error", "failed":                   return .Failed, true
	case "cancelled", "interrupted":          return .Cancelled, true
	case "running":                           return .Running, true
	}
	return .Unknown, false
}

// The result message of a sub-agent in the session shown (nil: none yet).
sub_result :: proc(c: ^Chat, child: string) -> ^Message {
	if child == "" { return nil }
	#reverse for &m in c.messages { if m.kind == .Synthetic && m.sub_child == child { return &m } }
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
		case .Error:   v.state = .Failed; v.result = p.output
		case .Done:
			// a foreground call ends with the sub-agent: its output is the result; a background one only launched it
			if !p.sub_background { v.state = .Done; v.result = p.output; v.ended = p.ended_ms }
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

// "4m 12s", "1h 03m": the time from `a` to `b` (epoch ms).
duration :: proc(a, b: f64) -> string {
	if a <= 0 || b <= a { return "" }
	s := int((b - a) / 1000)
	switch {
	case s < 60:   return fmt.tprintf("%ds", s)
	case s < 3600: return fmt.tprintf("%dm %02ds", s / 60, s % 60)
	}
	if s < 48 * 3600 { return fmt.tprintf("%dh %02dm", s / 3600, (s / 60) % 60) }
	return fmt.tprintf("%dd %02dh", s / 86400, (s / 3600) % 24)
}

////////////////////////////////
// Navigation

// Opens a session from the sidebar: no way back but its parent.
open_root :: proc(app: ^App, id: string) {
	for s in app.nav { delete(s) }
	clear(&app.nav)
	open_chat(app, id)
}

// Opens the sub-agent `child` of the session shown; Back comes here again.
drill_down :: proc(app: ^App, child: string) {
	if child == "" || child == app.chat.id { return }
	if app.chat.id != "" { append(&app.nav, strings.clone(app.chat.id)) }
	open_chat(app, child)
}

// The session to go back to: the one drilled down from, else the parent.
back_target :: proc(app: ^App) -> string {
	if len(app.nav) > 0 { return app.nav[len(app.nav) - 1] }
	return app.chat.self.parent
}

go_back :: proc(app: ^App) {
	if len(app.nav) > 0 {
		id := pop(&app.nav)
		defer delete(id)
		open_chat(app, id)
	} else if p := app.chat.self.parent; p != "" {
		open_chat(app, strings.clone(p, context.temp_allocator))
	}
}

////////////////////////////////
// The card of a sub-agent call (in the parent's conversation)

@(private = "file")
Rail_Draw :: struct { color: Color, hot: bool }

@(private = "file")
rail_draw :: proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
	d := (^Rail_Draw)(user)
	s := ui.scale()
	r := b.rect
	// the agent's colour down the left edge, and a faint wash of it at the top
	draw.rect_corners(dc, {r.min, {r.max.x, r.min.y + 40 * s}}, {with_alpha(d.color, 0.07), {0, 0, 0, 0}, with_alpha(d.color, 0.07), {0, 0, 0, 0}}, {9 * s, 0, 9 * s, 0})
	draw.rect(dc, {{r.min.x + 1 * s, r.min.y + 8 * s}, {r.min.x + 4 * s, r.max.y - 8 * s}}, with_alpha(d.color, 0.85), 1.5 * s)
	if b.hot_t > 0.01 { draw.rect(dc, r, {1, 1, 1, 0.02 * b.hot_t}, 9 * s) }
}

subagent_card :: proc(app: ^App, p: ^Part, pid: string, em: f32) {
	v := sub_view(app, p.sub_session, p)
	open := part_open(app, p.tool_id != "" ? p.tool_id : pid)
	acol := agent_color(v.agent)
	now := now_epoch_ms()
	running := v.state == .Running || v.state == .Starting
	if running { app.animating = true }
	// a running sub-agent is lit (warm face, glowing edge, full contrast); a finished one is switched off: flat, dim,
	// one line until it is opened
	off := !running
	compact := off && !open
	if off { acol = with_alpha(acol, 0.55) }
	desc_col := off ? hex(0x8c8c8cff) : hex(0xf6f6f6ff)

	ui.next({width = ui.fill(), height = ui.children_sum(), axis = .Y})
	pt, pb: u32 = 0x221e17ff, 0x17140fff
	shadow, rim: f32 = 8, 0.11
	border, glow := with_alpha(hex(HEX_YELLOW), 0.6), with_alpha(hex(HEX_YELLOW), 0.22)
	if off { pt, pb, shadow, rim, border, glow = 0x111111ff, 0x0e0e0eff, 0, 0.03, {0, 0, 0, 0.7}, {} }
	if plate(fmt.tprintf("###sa_%s", pid), top = pt, bottom = pb, radius = 9, shadow = shadow, rim = rim, border = border, glow = glow) {
		ui.next({width = ui.fill(), height = ui.children_sum(), axis = .Y})
		head := ui.build_box({.Clickable, .Focusable, .Hot_Within}, "###head")
		rd := ui.frame_new(Rail_Draw)
		rd.color = acol
		head.custom = rail_draw
		head.custom_user = rd
		hs := ui.signal(head)
		if hs.clicked { part_toggle(app, p.tool_id != "" ? p.tool_id : pid, head) }
		if app.seek_subagent && app.anchor == nil && head.rect.max.y != head.rect.min.y && app.chat.loaded {
			// --seek-subagent (tests): bring the first card near the top, as an anchor does
			app.seek_subagent = false
			app.anchor = head
			app.anchor_y = math.round(em * 7)
			app.stick_bottom = false
		}
		if hs.double_clicked && v.id != "" { drill_down(app, v.id) }
		if ui.parent(head) {
			ui.spacer(ui.px(em * 0.55))
			// line 1: status lamp, robot, agent, description, duration, open
			ui.next({width = ui.fill(), height = ui.px(math.round(em * (compact ? 1.7 : 1.9))), axis = .X, cross = .Center})
			if ui.row(.Center, id = "###l1") {
				ui.spacer(ui.px(em * 0.95))
				if running { lamp("###st", sub_state_color(v.state), 1, pulse = true, size = em * 0.95) } else { pip("###st", off ? with_alpha(sub_state_color(v.state), 0.5) : sub_state_color(v.state), em * 0.8) }
				ui.spacer(ui.px(em * 0.45))
				glyph(ICO_ROBOT, acol, math.round(em * 0.95))
				ui.spacer(ui.px(em * 0.25))
				name := v.agent != "" ? v.agent : "sub-agent"
				text("ag", strings.to_upper(name, context.temp_allocator), acol, ui.Style_Mod{font = app.mono_bold, font_size = math.round(em * 0.78)})
				ui.spacer(ui.px(em * 0.6))
				text("ds", v.desc != "" ? v.desc : "(no description)", desc_col, ui.Style_Mod{font_size = math.round(em * (off ? 0.9 : 0.98))}, ui.fill())
				ui.spacer(ui.px(em * 0.5))
				if compact {
					// switched off: its state in words, dimmed
					text("sw", sub_state_label(v.state), with_alpha(sub_state_color(v.state), 0.75), ui.Style_Mod{font = app.mono, font_size = math.round(em * 0.72)})
					ui.spacer(ui.px(em * 0.6))
				}
				end := v.ended > 0 ? v.ended : (running ? now : 0)
				if d := duration(v.started, end); d != "" {
					glyph(ICO_HISTORY, hex(HEX_FAINT), math.round(em * 0.7), em * 1.1)
					text("du", d, off ? hex(HEX_FAINT) : hex(HEX_YELLOW), ui.Style_Mod{font = app.mono, font_size = math.round(em * 0.76)})
					ui.spacer(ui.px(em * 0.6))
				}
				if v.id != "" {
					if compact {
						if glyph_button("###open", ICO_RIGHT, math.round(em * 1.5)).clicked { drill_down(app, v.id) }
					} else if bevel_button("###open", "Open", ICO_RIGHT, running ? .Accent : .Normal, height = math.round(em * 1.6)).clicked {
						drill_down(app, v.id)
					}
					ui.spacer(ui.px(em * 0.4))
				}
				glyph(open ? ICO_DOWN : ICO_RIGHT, hex(HEX_FAINT), math.round(em * 0.6), em * 1.1)
				ui.spacer(ui.px(em * 0.5))
			}
			// line 2: state (and what it does now), model, tokens, cost, tool calls, background
			if !compact { card_line2(app, &v, running, em) }
			// collapsed while lit: the first line of the result
			if !open && !compact && v.result != "" {
				ui.next({width = ui.fill(), height = ui.px(math.round(em * 1.6)), axis = .X, cross = .Center})
				if ui.row(.Center, id = "###l3") {
					ui.spacer(ui.px(em * 2.45))
					glyph(ICO_CHAT, hex(HEX_FAINT), math.round(em * 0.75), em * 1.2)
					text("rs", first_line(strings.trim_left(v.result, "# ")), hex(0xa8a8a8ff), ui.Style_Mod{font_size = math.round(em * 0.86)}, ui.fill())
					ui.spacer(ui.px(em * 0.8))
				}
			}
			ui.spacer(ui.px(em * (compact ? 0.15 : 0.5)))
		}
		if open {
			ui.next({width = ui.fill(), height = ui.children_sum(), axis = .X})
			if ui.row(id = "###body") {
				ui.spacer(ui.px(em * 1.2))
				ui.next({width = ui.fill(), height = ui.children_sum(), axis = .Y})
				if ui.column() {
					if v.session != nil {
						sub_facts(app, &v, em)
						ui.spacer(ui.px(em * 0.5))
					}
					if v.prompt != "" {
						section_label("pr", "PROMPT", em)
						mono_well("###prompt", v.prompt, em, 18, hex(0xc8c8c8ff))
						ui.spacer(ui.px(em * 0.6))
					}
					if v.result != "" {
						section_label("re", v.state == .Failed ? "ERROR" : "RESULT", em)
						ui.next({width = ui.fill(), height = ui.children_sum(), axis = .Y})
						if well("###result", radius = 7, base = 0x0b0b0bff) {
							ui.spacer(ui.px(em * 0.7))
							ui.next({width = ui.fill(), height = ui.children_sum(), axis = .X})
							if ui.row() {
								ui.spacer(ui.px(em * 0.9))
								ui.next({width = ui.fill(), height = ui.children_sum(), axis = .Y})
								if ui.column() { markdown(fmt.tprintf("%s_res", pid), v.result, hex(0xd8d8d8ff), math.round(em * 0.95)) }
								ui.spacer(ui.px(em * 0.9))
							}
							ui.spacer(ui.px(em * 0.7))
						}
						ui.spacer(ui.px(em * 0.4))
					} else if running {
						ui.next({width = ui.fill(), height = ui.px(em * 1.6), axis = .X, cross = .Center})
						if ui.row(.Center) { text("w", "No result yet: it is still working.", hex(HEX_FAINT), ui.Style_Mod{font_size = math.round(em * 0.86)}, ui.fill()) }
					}
					ui.spacer(ui.px(em * 0.7))
				}
				ui.spacer(ui.px(em * 1.0))
			}
		}
	}
	ui.spacer(ui.px(em * 0.6))
}

// The second line of a card: its state (and what it does now while it runs), background, model, tool calls, tokens, cost.
card_line2 :: proc(app: ^App, v: ^Sub_View, running: bool, em: f32) {
	ui.next({width = ui.fill(), height = ui.px(math.round(em * 1.7)), axis = .X, cross = .Center})
	if ui.row(.Center, id = "###l2") {
		ui.spacer(ui.px(em * 2.45))
		small := ui.Style_Mod{font = app.mono, font_size = math.round(em * 0.74)}
		text("st", sub_state_label(v.state), sub_state_color(v.state), ui.Style_Mod{font = app.mono_bold, font_size = math.round(em * 0.74)})
		if running && v.has_live && v.live.activity != "" {
			text("sep", "  ·  ", hex(HEX_FAINT), small)
			text("act", v.live.activity, hex(0xf0d8a8ff), small, ui.fill())
		} else {
			ui.spacer(ui.fill())
		}
		ui.spacer(ui.px(em * 0.4))
		if v.background { pill("###bg", "background", {}, ICO_HISTORY); ui.spacer(ui.px(em * 0.3)) }
		if v.model != "" { pill("###md", short_model(v.model), {}, ICO_CHIP); ui.spacer(ui.px(em * 0.3)) }
		tin, tout, cost := sub_totals(v)
		if tools := v.live.tools; tools > 0 { pill("###tl", fmt.tprintf("%d tools", tools), {}, ICO_TOOL); ui.spacer(ui.px(em * 0.3)) }
		if tin + tout > 0 { pill("###tk", fmt.tprintf("%s · %s", kfmt(tin), kfmt(tout)), {}, ICO_BOLT); ui.spacer(ui.px(em * 0.3)) }
		if cost > 0 { pill("###co", fmt.tprintf("$%.2f", cost), hex(HEX_GREEN)); ui.spacer(ui.px(em * 0.3)) }
		ui.spacer(ui.px(em * 0.5))
	}
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
	if well("###facts", radius = 7, base = 0x0b0b0bff) {
		ui.spacer(ui.px(em * 0.45))
		row :: proc(id, k, val: string, em: f32, col := Color{}) {
			ui.next({width = ui.fill(), height = ui.px(em * 1.4), axis = .X, cross = .Center})
			if ui.row(.Center, id = id) {
				ui.spacer(ui.px(em * 0.8))
				text("k", k, hex(HEX_FAINT), ui.Style_Mod{font = the_app.mono, font_size = math.round(em * 0.74)}, ui.px(em * 7))
				text("v", val, col.a > 0 ? col : hex(0xc8c8c8ff), ui.Style_Mod{font = the_app.mono, font_size = math.round(em * 0.74)}, ui.fill())
			}
		}
		row("###f1", "session", s.id, em)
		row("###f2", "title", s.title, em)
		row("###f3", "started", fmt.tprintf("%s  (%s ago)", clock_time(s.created), duration(s.created, now_epoch_ms())), em)
		if s.idle > 0 { row("###f4", "finished", fmt.tprintf("%s  after %s", clock_time(s.idle), duration(s.created, s.idle)), em) }
		if s.outcome != "" {
			st, _ := state_of_word(s.outcome)
			row("###f5", "outcome", s.outcome, em, sub_state_color(st))
		}
		row("###f6", "tokens", fmt.tprintf("in %s · out %s · reasoning %s · cache read %s · cache write %s", kfmt(s.tokens_in), kfmt(s.tokens_out), kfmt(s.reasoning), kfmt(s.cache_read), kfmt(s.cache_write)), em)
		if s.cost > 0 { row("###f7", "cost", fmt.tprintf("$%.4f", s.cost), em, hex(HEX_GREEN)) }
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
	acol := agent_color(v.agent)
	ui.next({width = ui.fill(), height = ui.children_sum(), axis = .Y})
	if ui.column(id = fmt.tprintf("###sr_%s", m.id)) {
		ui.next({width = ui.fill(), height = ui.px(math.round(em * 2)), axis = .X, cross = .Center})
		hb := ui.build_box({.Clickable, .Focusable, .Hot_Within}, "###head")
		hd := ui.frame_new(Rail_Draw)
		hd.color = acol
		hb.custom = proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
			if b.hot_t > 0.01 { draw.rect(dc, b.rect, {1, 1, 1, 0.035 * b.hot_t}, 7 * ui.scale()) }
		}
		hs := ui.signal(hb)
		if hs.clicked { part_toggle(app, m.id, hb) }
		if ui.parent(hb) {
			ui.spacer(ui.px(em * 0.3))
			glyph(ICO_UNDO, acol, math.round(em * 0.85), em * 1.3)   // (Undo arrow: it came back)
			text("ag", v.agent != "" ? v.agent : "sub-agent", acol, ui.Style_Mod{font = app.mono_bold, font_size = math.round(em * 0.8)})
			text("w", fmt.tprintf("  %s  ", st == .Done ? "returned" : sub_state_label(st)), sub_state_color(st), ui.Style_Mod{font_size = math.round(em * 0.86)})
			desc := m.sub_desc != "" ? m.sub_desc : v.desc
			text("d", desc, hex(0xc8c8c8ff), ui.Style_Mod{font_size = math.round(em * 0.88)}, ui.fill())
			text("at", clock_time(m.created), hex(HEX_FAINT), ui.Style_Mod{font = app.mono, font_size = math.round(em * 0.72)})
			ui.spacer(ui.px(em * 0.4))
			if m.sub_child != "" {
				if glyph_button("###open", ICO_RIGHT, math.round(em * 1.5), hex(HEX_WEAK)).clicked { drill_down(app, m.sub_child) }
			}
			glyph(open ? ICO_DOWN : ICO_RIGHT, hex(HEX_FAINT), math.round(em * 0.6), em * 1.1)
		}
		if open && m.text != "" {
			ui.next({width = ui.fill(), height = ui.children_sum(), axis = .X})
			if rail_row(fmt.tprintf("###srb_%s", m.id), with_alpha(acol, 0.5)) {
				ui.spacer(ui.px(em * 1.0))
				ui.next({width = ui.fill(), height = ui.children_sum(), axis = .Y})
				if ui.column() {
					ui.spacer(ui.px(em * 0.3))
					markdown(fmt.tprintf("%s_sr", m.id), m.text, hex(0xcfcfcfff), math.round(em * 0.95))
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
	acol := agent_color(s.agent)
	st, known := state_of_word(s.outcome)
	if app.busy[s.id] or_else false { st, known = .Running, true }
	ui.spacer(ui.px(em * 0.4))
	ui.next({width = ui.fill(), height = ui.children_sum(), axis = .Y})
	if plate("###sub_banner", top = 0x1d1a16ff, bottom = 0x151310ff, radius = 9, shadow = 6, rim = 0.08, border = with_alpha(acol, 0.45)) {
		if bx := ui.parent_box(); app.seek_subagent && app.anchor == nil && bx.rect.max.y > 0 && c.loaded {
			app.seek_subagent = false   // --seek-subagent (tests): bring the banner into view
			app.anchor = bx
			app.anchor_y = math.round(em * 7)
			app.stick_bottom = false
		}
		ui.spacer(ui.px(em * 0.7))
		ui.next({width = ui.fill(), height = ui.children_sum(), axis = .X, cross = .Center})
		if ui.row(.Center, id = "###r1") {
			ui.spacer(ui.px(em))
			glyph(ICO_ROBOT, acol, math.round(em * 1.2), em * 1.8)
			ui.spacer(ui.px(em * 0.4))
			ui.next({width = ui.fill(), height = ui.children_sum(), axis = .Y})
			if ui.column() {
				ui.next({width = ui.fill(), height = ui.px(em * 1.5), axis = .X, cross = .Center})
				if ui.row(.Center) {
					text("k", "SUB-AGENT", hex(HEX_FAINT), ui.Style_Mod{font = app.mono_bold, font_size = math.round(em * 0.7)})
					ui.spacer(ui.px(em * 0.5))
					text("a", s.agent, acol, ui.Style_Mod{font = app.mono_bold, font_size = math.round(em * 0.8)})
					if known {
						ui.spacer(ui.px(em * 0.5))
						state_mark("###l", sub_state_color(st), st == .Running, size = em * 0.75)
						if st == .Running { app.animating = true }
						ui.spacer(ui.px(em * 0.25))
						text("s", sub_state_label(st), sub_state_color(st), ui.Style_Mod{font = app.mono, font_size = math.round(em * 0.76)})
					}
					ui.spacer(ui.fill())
				}
				parent := c.parent_title != "" ? c.parent_title : s.parent
				text("p", fmt.tprintf("launched by “%s”", parent), hex(0xc8bca8ff), ui.Style_Mod{font_size = math.round(em * 0.88), height = ui.px(em * 1.4)}, ui.fill())
				end := s.idle > 0 && st != .Running ? s.idle : now_epoch_ms()
				facts := fmt.tprintf("started %s · %s · %s in · %s out%s", clock_time(s.created), duration(s.created, end), kfmt(s.tokens_in + s.cache_read), kfmt(s.tokens_out), s.cost > 0 ? fmt.tprintf(" · $%.2f", s.cost) : "")
				text("f", facts, hex(HEX_FAINT), ui.Style_Mod{font = app.mono, font_size = math.round(em * 0.72), height = ui.px(em * 1.3)}, ui.fill())
			}
			ui.spacer(ui.px(em * 0.5))
			if bevel_button("###back", "Return to main session", ICO_BACK, .Accent).clicked { go_back(app) }
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
		app.animating = true
		lamp("###sub_lamp", hex(HEX_YELLOW), 1, pulse = true, size = em * 1.0)
		ui.spacer(ui.px(em * 0.3))
		sig = bevel_button("###subs", fmt.tprintf("%d active", len(active)), ICO_ROBOT, .Accent, height = math.round(em * 1.9))
		ui.spacer(ui.px(em * 0.3))
		text("of", fmt.tprintf("/ %d", len(c.children)), hex(HEX_FAINT), ui.Style_Mod{font = app.mono, font_size = math.round(em * 0.76)})
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
				if ui.menu_item(fmt.tprintf("▶  %s  —  %s", ellipsize(s.title, 40), ellipsize(what, 36)), duration(s.created, now_epoch_ms())).clicked { drill_down(app, s.id) }
			}
			ui.menu_separator()
		}
		ui.menu_heading(fmt.tprintf("Finished (%d)", len(c.children) - len(active)))
		shown := 0
		for &s in c.children {
			if app.busy[s.id] or_else false { continue }
			if shown == 40 { ui.menu_item(fmt.tprintf("… and %d more", len(c.children) - len(active) - shown), enabled = false); break }
			v := sub_view(app, s.id)
			mark := "·"
			#partial switch v.state {
			case .Done:      mark = "✓"
			case .Failed:    mark = "✕"
			case .Cancelled: mark = "■"
			}
			end := v.ended > 0 ? v.ended : s.updated
			if ui.menu_item(fmt.tprintf("%s  %s · %s", mark, ellipsize(s.title, 48), s.agent), duration(s.created, end)).clicked { drill_down(app, s.id) }
			shown += 1
		}
	}
}

// A quiet button: a dim glyph and text, a bevel only under the pointer.
glyph_label_button :: proc(app: ^App, id, label: string, em: f32) -> ui.Signal {
	ui.next({width = ui.children_sum(), height = ui.px(math.round(em * 1.9)), axis = .X, cross = .Center})
	b := ui.build_box({.Clickable, .Focusable}, id)
	b.custom = proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
		if b.hot_t > 0.01 { draw_bevel(dc, b.rect, 6 * ui.scale(), hex(0x222222ff), b.hot_t, b.active_t) }
	}
	sig := ui.signal(b)
	if ui.parent(b) {
		ui.spacer(ui.px(em * 0.5))
		glyph(ICO_ROBOT, hex(HEX_FAINT), math.round(em * 0.85))
		ui.spacer(ui.px(em * 0.2))
		text("t", label, sig.hovering ? hex(HEX_TEXT) : hex(HEX_WEAK), ui.Style_Mod{font_size = math.round(em * 0.86)})
		ui.spacer(ui.px(em * 0.6))
	}
	return sig
}

// Above the composer, while sub-agents of the session shown run: one lit chip each (what it does now, for how long);
// a click opens it.
active_strip :: proc(app: ^App, em: f32) {
	active := active_children(app)
	if len(active) == 0 { return }
	app.animating = true
	now := now_epoch_ms()
	ui.next({width = ui.fill(), height = ui.children_sum(), gap = {em * 0.5, em * 0.5}})
	if ui.flow({em * 0.5, em * 0.5}, "###active_strip") {
		for s in active {
			v := sub_view(app, s.id)
			acol := agent_color(s.agent)
			ui.next({width = ui.children_sum(), height = ui.px(math.round(em * 2.3)), axis = .X, cross = .Center})
			b := ui.build_box({.Clickable, .Focusable}, fmt.tprintf("###act_%s", s.id))
			b.custom = proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
				s := ui.scale()
				draw_bevel(dc, b.rect, 8 * s, hex(0x2a2416ff), b.hot_t, b.active_t, hex(HEX_YELLOW))
			}
			sig := ui.signal(b)
			if sig.clicked { drill_down(app, s.id) }
			if ui.parent(b) {
				ui.spacer(ui.px(em * 0.6))
				lamp("###l", hex(HEX_YELLOW), 1, pulse = true, size = em * 0.85)
				ui.spacer(ui.px(em * 0.35))
				text("a", s.agent, acol, ui.Style_Mod{font = app.mono_bold, font_size = math.round(em * 0.74)})
				ui.spacer(ui.px(em * 0.4))
				text("t", ellipsize(s.title, 34), hex(0xf4ead8ff), ui.Style_Mod{font_size = math.round(em * 0.88)})
				if v.has_live && v.live.activity != "" {
					text("s", "  ·  ", hex(0x8a7a5aff), ui.Style_Mod{font_size = math.round(em * 0.8)})
					text("w", ellipsize(v.live.activity, 30), hex(0xd8c09aff), ui.Style_Mod{font = app.mono, font_size = math.round(em * 0.72)})
				}
				ui.spacer(ui.px(em * 0.5))
				text("d", duration(s.created, now), hex(HEX_YELLOW), ui.Style_Mod{font = app.mono, font_size = math.round(em * 0.72)})
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
	open := app.sub_open[k] or_else false
	ui.next({width = ui.children_sum(), height = ui.px(math.round(em * 1.45)), axis = .X, cross = .Center})
	b := ui.build_box({.Clickable}, "###subt")
	b.custom = proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
		draw_well(dc, b.rect, 999, hex(b.hot_t > 0.01 ? 0x161616ff : 0x0d0d0dff))
	}
	sig := ui.signal(b)
	if sig.clicked { app.sub_open[k] = !open }
	if ui.parent(b) {
		ui.spacer(ui.px(em * 0.4))
		if running > 0 {
			// the running ones, loud: a pulsing lamp and their count; the total quietly after
			lamp("###l", hex(HEX_YELLOW), 1, pulse = true, size = em * 0.7)
			the_app.animating = true
			ui.spacer(ui.px(em * 0.2))
			text("r", fmt.tprintf("%d", running), hex(HEX_YELLOW), ui.Style_Mod{font = the_app.mono_bold, font_size = math.round(em * 0.74)})
			text("n", fmt.tprintf("/%d", n), hex(HEX_FAINT), ui.Style_Mod{font = the_app.mono, font_size = math.round(em * 0.68)})
		} else {
			glyph(ICO_ROBOT, hex(HEX_FAINT), math.round(em * 0.62), em * 0.9)
			text("n", fmt.tprintf("%d", n), hex(HEX_FAINT), ui.Style_Mod{font = the_app.mono, font_size = math.round(em * 0.7)})
		}
		glyph(open ? ICO_DOWN : ICO_RIGHT, hex(HEX_FAINT), math.round(em * 0.5), em * 0.9)
		ui.spacer(ui.px(em * 0.2))
	}
	return open
}
