// The statistics of the session shown (the header's token pill opens them): its totals, its context against the model's
// window, its pace, what the loaded messages did (tools, models), its sub-agents, and the project's totals from the
// server (GET /api/experimental/session/stats?project=..&tools=detail).
package occ

import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:mem/virtual"
import "core:slice"
import "core:strings"
import "gt:draw"
import "gt:ui"

Tool_Count :: struct { name: string, calls, failed: int, p50: f64 }
Model_Count :: struct { name: string, steps: int, tokens_in, tokens_out, cost: f64 }

Project_Stats :: struct {
	arena:      virtual.Arena,
	ready:      bool,
	project:    string,
	sessions, subagents, prompts, steps: int,
	tokens_in, tokens_out, reasoning, cache_read, cache_write, cost: f64,
	active_days, streak: int,
	calls, succeeded, failed: int,
	tools:      [dynamic]Tool_Count,
	models:     [dynamic]Model_Count,
	from, to:   f64,
}

stats_open :: proc(app: ^App) {
	app.stats_open = true
	p := chat_project(app)
	ps := &app.proj_stats
	virtual.arena_destroy(&ps.arena)
	ps^ = {}
	_ = virtual.arena_init_growing(&ps.arena)
	if p != "" {
		ps.project = strings.clone(p, virtual.arena_allocator(&ps.arena))
		request(app, .Stats, "GET", fmt.tprintf("/api/experimental/session/stats?project=%s&tools=detail", url_escape(p)))
	}
}

stats_load :: proc(app: ^App, v: json.Value) {
	ps := &app.proj_stats
	a := virtual.arena_allocator(&ps.arena)
	d := jget(v, "data")
	ps.ready = true
	ps.sessions, ps.subagents = int(jnum(d, "sessions")), int(jnum(d, "subagents"))
	ps.prompts, ps.steps = int(jnum(d, "prompts")), int(jnum(d, "steps"))
	ps.tokens_in, ps.tokens_out, ps.reasoning = jnum(d, "tokens", "input"), jnum(d, "tokens", "output"), jnum(d, "tokens", "reasoning")
	ps.cache_read, ps.cache_write, ps.cost = jnum(d, "tokens", "cache", "read"), jnum(d, "tokens", "cache", "write"), jnum(d, "cost")
	ps.active_days, ps.streak = int(jnum(d, "activeDays")), int(jnum(d, "streak"))
	ps.from, ps.to = jnum(d, "range", "from"), jnum(d, "range", "to")
	ps.calls = int(jnum(d, "tools", "totals", "calls"))
	ps.succeeded = int(jnum(d, "tools", "totals", "succeeded"))
	ps.failed = int(jnum(d, "tools", "totals", "failed"))
	ps.tools = make([dynamic]Tool_Count, a)
	for t in jarr(d, "tools", "usage") {
		append(&ps.tools, Tool_Count{strings.clone(jstr(t, "name"), a), int(jnum(t, "calls")), int(jnum(t, "failed")), jnum(t, "durationP50")})
	}
	ps.models = make([dynamic]Model_Count, a)
	for m in jarr(d, "models") {
		append(&ps.models, Model_Count{strings.clone(jstr(m, "model", "id"), a), int(jnum(m, "steps")), jnum(m, "tokens", "input") + jnum(m, "tokens", "cache", "read"), jnum(m, "tokens", "output"), jnum(m, "cost")})
	}
}

// What the loaded messages of the session did.
@(private = "file")
Local :: struct {
	prompts, steps, msgs: int,
	calls, failed:        int,
	tools:                [dynamic]Tool_Count,
	models:               [dynamic]Model_Count,
	active_ms:            f64,   // sum of the steps' durations
	out_tokens:           f64,
	last_context:         f64,   // the input of the last step (its prompt, cache included): the context it filled
	last_model:           string,
	first, last:          f64,
}

@(private = "file")
local_stats :: proc(app: ^App) -> (l: Local) {
	l.tools = make([dynamic]Tool_Count, context.temp_allocator)
	l.models = make([dynamic]Model_Count, context.temp_allocator)
	for &m in app.chat.messages {
		l.msgs += 1
		if m.created > 0 && (l.first == 0 || m.created < l.first) { l.first = m.created }
		if m.created > l.last { l.last = m.created }
		#partial switch m.kind {
		case .User: l.prompts += 1
		case .Assistant:
			l.steps += 1
			if m.completed > m.created && m.created > 0 { l.active_ms += m.completed - m.created }
			l.out_tokens += m.tokens_out
			if m.tokens_in + m.cache_read > 0 { l.last_context = m.tokens_in + m.cache_read; l.last_model = m.model }
			name := m.model != "" ? m.model : "?"
			found := false
			for &mc in l.models {
				if mc.name == name { mc.steps += 1; mc.tokens_in += m.tokens_in + m.cache_read; mc.tokens_out += m.tokens_out; mc.cost += m.cost; found = true; break }
			}
			if !found { append(&l.models, Model_Count{name, 1, m.tokens_in + m.cache_read, m.tokens_out, m.cost}) }
			for &p in m.parts {
				if p.kind != .Tool { continue }
				l.calls += 1
				if p.status == .Error { l.failed += 1 }
				tn := p.tool_name != "" ? p.tool_name : "?"
				tf := false
				for &tc in l.tools {
					if tc.name == tn { tc.calls += 1; if p.status == .Error { tc.failed += 1 }; tf = true; break }
				}
				if !tf { append(&l.tools, Tool_Count{tn, 1, p.status == .Error ? 1 : 0, 0}) }
			}
		}
	}
	slice.sort_by(l.tools[:], proc(a, b: Tool_Count) -> bool { return a.calls > b.calls })
	slice.sort_by(l.models[:], proc(a, b: Model_Count) -> bool { return a.steps > b.steps })
	return
}

////////////////////////////////
// The dialog

@(private = "file")
Bar :: struct { t: f32, color: Color }

@(private = "file")
bar_draw :: proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
	d := (^Bar)(user)
	s := ui.scale()
	r := b.rect
	h := r.max.y - r.min.y
	draw_well(dc, r, h * 0.5, hex(0x0a0a0aff))
	w := (r.max.x - r.min.x - 2 * s) * clamp(d.t, 0, 1)
	if w > 1 {
		fr := Rect{{r.min.x + s, r.min.y + s}, {r.min.x + s + max(w, h - 2 * s), r.max.y - s}}
		draw.rect_corners(dc, fr, {lighten(d.color, 0.2), darken(d.color, 0.15), lighten(d.color, 0.2), darken(d.color, 0.15)}, radii4((h - 2 * s) * 0.5))
	}
}

// A sunken bar filled to `t` (0..1).
meter :: proc(id: string, t: f32, color: Color, em: f32, width: Maybe(ui.Size) = nil) {
	ui.next({width = width.? or_else ui.fill(), height = ui.px(math.round(em * 0.75))})
	b := ui.build_box({}, id)
	d := ui.frame_new(Bar)
	d^ = {t, color}
	b.custom = bar_draw
	b.custom_user = d
}

// A big number with its caption under it, in a tile.
@(private = "file")
tile :: proc(id, value, caption: string, color: Color, em: f32) {
	ui.next({width = ui.px(em * 9.5), height = ui.children_sum(), axis = .Y})
	if plate(id, top = 0x1a1a1aff, bottom = 0x141414ff, radius = 8, shadow = 3) {
		ui.spacer(ui.px(em * 0.5))
		ui.next({width = ui.fill(), height = ui.px(em * 1.9), fg = color, font = the_app.mono_bold, font_size = math.round(em * 1.25), text_align = .Center})
		ui.build_box({.Draw_Text}, fmt.tprintf("%s###v", value))
		ui.next({width = ui.fill(), height = ui.px(em * 1.3), fg = hex(HEX_FAINT), font_size = math.round(em * 0.74), text_align = .Center})
		ui.build_box({.Draw_Text}, fmt.tprintf("%s###c", caption))
		ui.spacer(ui.px(em * 0.4))
	}
}

@(private = "file")
kv :: proc(id, k, v: string, em: f32, col := Color{}) {
	ui.next({width = ui.fill(), height = ui.px(em * 1.45), axis = .X, cross = .Center})
	if ui.row(.Center, id = id) {
		text("k", k, hex(HEX_FAINT), ui.Style_Mod{font = the_app.mono, font_size = math.round(em * 0.76)}, ui.px(em * 11))
		text("v", v, col.a > 0 ? col : hex(0xdadadaff), ui.Style_Mod{font = the_app.mono, font_size = math.round(em * 0.78)}, ui.fill())
	}
}

// A row of a ranking: name, a bar of its share, its count (and failures).
@(private = "file")
rank_row :: proc(id, name: string, n, max_n, failed: int, extra: string, em: f32, color: Color) {
	ui.next({width = ui.fill(), height = ui.px(em * 1.55), axis = .X, cross = .Center})
	if ui.row(.Center, id = id) {
		text("n", ellipsize(name, 28), hex(0xe2e2e2ff), ui.Style_Mod{font = the_app.mono, font_size = math.round(em * 0.78)}, ui.px(em * 11))
		meter("###m", max_n > 0 ? f32(n) / f32(max_n) : 0, color, em)
		ui.spacer(ui.px(em * 0.6))
		text("c", fmt.tprintf("%d", n), hex(0xdadadaff), ui.Style_Mod{font = the_app.mono_bold, font_size = math.round(em * 0.78)}, ui.px(em * 3))
		text("f", failed > 0 ? fmt.tprintf("%d failed", failed) : "", hex(HEX_RED), ui.Style_Mod{font = the_app.mono, font_size = math.round(em * 0.72)}, ui.px(em * 5))
		text("x", extra, hex(HEX_FAINT), ui.Style_Mod{font = the_app.mono, font_size = math.round(em * 0.72)}, ui.px(em * 6.5))
	}
}

@(private = "file")
heading :: proc(s: string, em: f32) {
	ui.spacer(ui.px(em * 0.9))
	section_label(fmt.tprintf("st_%s", s), s, em)
	ui.spacer(ui.px(em * 0.2))
}

stats_dialog :: proc(app: ^App, em: f32) {
	if !app.stats_open { return }
	c := &app.chat
	s := c.have_self ? &c.self : find_session(app, c.id)
	if ui.modal("stats", em * 46, &app.stats_open, 0.06) {
		dialog_backdrop()
		h := math.round(min(em * 38, app.ui_state.window_size.y * 0.84))
		ui.next({width = ui.fill(), height = ui.px(h)})
		if ui.scroll_y("###stats_scroll") {
			ui.next({width = ui.fill(), height = ui.children_sum(), axis = .X})
			if ui.row() {
				ui.spacer(ui.px(em * 1.4))
				ui.next({width = ui.fill(), height = ui.children_sum(), axis = .Y})
				if ui.column() {
					stats_body(app, s, em)
				}
				ui.spacer(ui.px(em * 1.4))
			}
		}
		dialog_close(&app.stats_open)
	}
}

@(private = "file")
stats_body :: proc(app: ^App, s: ^Session_Info, em: f32) {
	c := &app.chat
	l := local_stats(app)
	now := now_epoch_ms()
	ui.spacer(ui.px(em * 1.1))
	ui.next({width = ui.fill(), height = ui.px(em * 2.2), axis = .X, cross = .Center})
	if ui.row(.Center, id = "###title") {
		if logo_of(app, "###lg", project_logo(app, chat_project(app)), math.round(em * 1.8)) { ui.spacer(ui.px(em * 0.5)) }
		text("t", s != nil && s.title != "" ? s.title : "Session", hex(0xffffffff), ui.Style_Mod{font_size = math.round(em * 1.3)}, ui.fill())
		ui.spacer(ui.px(em * 1.6))   // (room for the dialog's close cross)
	}
	// totals: the session's (the server's), else the live ones
	tin, tout, reas, cread, cwrite, cost := c.tokens_in, c.tokens_out, 0.0, c.cache_read, 0.0, c.cost
	if s != nil {
		tin, tout, reas, cread, cwrite = max(tin, s.tokens_in), max(tout, s.tokens_out), s.reasoning, max(cread, s.cache_read), s.cache_write
		cost = max(cost, s.cost)
	}
	ui.spacer(ui.px(em * 0.7))
	ui.next({width = ui.fill(), height = ui.children_sum(), gap = {em * 0.6, em * 0.6}})
	if ui.flow({em * 0.6, em * 0.6}, "###tiles") {
		tile("###t1", kfmt(tin + cread), "tokens in", hex(HEX_BLUE), em)
		tile("###t2", kfmt(tout), "tokens out", accent(), em)
		tile("###t3", kfmt(reas), "reasoning", hex(HEX_PURPLE), em)
		tile("###t4", cost > 0 ? fmt.tprintf("$%.2f", cost) : "$0", "cost", hex(HEX_GREEN), em)
		hit := tin + cread > 0 ? cread / (tin + cread) : 0
		tile("###t5", fmt.tprintf("%.0f %%", hit * 100), "cache hits", hex(HEX_CYAN), em)
	}

	heading("CONTEXT", em)
	ctx := 0.0
	for m in app.models { if m.id == (l.last_model != "" ? l.last_model : c.model) { ctx = m.ctx_len; break } }
	if l.last_context > 0 && ctx > 0 {
		t := f32(l.last_context / ctx)
		col := t > 0.85 ? hex(HEX_RED) : t > 0.6 ? hex(HEX_YELLOW) : hex(HEX_GREEN)
		ui.next({width = ui.fill(), height = ui.px(em * 1.7), axis = .X, cross = .Center})
		if ui.row(.Center, id = "###ctx") {
			meter("###m", t, col, em)
			ui.spacer(ui.px(em * 0.7))
			text("p", fmt.tprintf("%.0f %%  ·  %s / %s", t * 100, kfmt(l.last_context), kfmt(ctx)), col, ui.Style_Mod{font = app.mono_bold, font_size = math.round(em * 0.8)})
		}
		info_line(app, "###ctxh", "What the last step sent the model (its prompt, cache included) against the model's context window. Near the top, opencode compacts the conversation.", em)
	} else {
		info_line(app, "###ctxn", "Not known yet (no step in the loaded messages, or the model's window is not listed).", em, hex(HEX_FAINT))
	}

	heading("TOKENS", em)
	kv("###k1", "input", fmt.tprintf("%s  (uncached)", kfmt(tin)), em)
	kv("###k2", "cache read", kfmt(cread), em)
	kv("###k3", "cache write", kfmt(cwrite), em)
	kv("###k4", "output", kfmt(tout), em)
	kv("###k5", "reasoning", kfmt(reas), em)
	kv("###k6", "cost", fmt.tprintf("$%.4f", cost), em, hex(HEX_GREEN))

	heading("TIME", em)
	if s != nil {
		kv("###d1", "created", fmt.tprintf("%s  (%s ago)", clock_time(s.created), duration(s.created, now)), em)
		if s.updated > 0 { kv("###d2", "last change", fmt.tprintf("%s  (%s ago)", clock_time(s.updated), duration(s.updated, now)), em) }
	}
	if l.active_ms > 0 {
		kv("###d3", "model at work", fmt.tprintf("%s over %d steps (%s a step)", duration(0.001, l.active_ms), l.steps, duration(0.001, l.active_ms / f64(max(l.steps, 1)))), em)
		if l.out_tokens > 0 { kv("###d4", "output pace", fmt.tprintf("%.0f tokens / s", l.out_tokens / (l.active_ms / 1000)), em) }
	}
	kv("###d5", "loaded", fmt.tprintf("%d messages · %d prompts · %d steps%s", l.msgs, l.prompts, l.steps, c.older != "" ? " (earlier ones not loaded)" : ""), em)

	heading(fmt.tprintf("TOOLS  (%d calls, %d failed)", l.calls, l.failed), em)
	max_t := len(l.tools) > 0 ? l.tools[0].calls : 0
	for t, i in l.tools {
		if i == 14 { info_line(app, "###tm", fmt.tprintf("… and %d more tools", len(l.tools) - 14), em, hex(HEX_FAINT)); break }
		rank_row(fmt.tprintf("###tl%d", i), t.name, t.calls, max_t, t.failed, "", em, accent())
	}
	if len(l.tools) == 0 { info_line(app, "###tn", "No tool call in the loaded messages.", em, hex(HEX_FAINT)) }

	if len(l.models) > 0 {
		heading("MODELS", em)
		max_m := l.models[0].steps
		for m, i in l.models {
			rank_row(fmt.tprintf("###ml%d", i), m.name, m.steps, max_m, 0, fmt.tprintf("%s out", kfmt(m.tokens_out)), em, hex(HEX_BLUE))
		}
	}

	if len(c.children) > 0 {
		heading("SUB-AGENTS", em)
		running, scost, sin, sout := 0, 0.0, 0.0, 0.0
		for k in c.children {
			if app.busy[k.id] or_else false { running += 1 }
			scost += k.cost; sin += k.tokens_in + k.cache_read; sout += k.tokens_out
		}
		kv("###s1", "launched", fmt.tprintf("%d  (%d running)", len(c.children), running), em, running > 0 ? hex(HEX_YELLOW) : {})
		kv("###s2", "their tokens", fmt.tprintf("%s in · %s out", kfmt(sin), kfmt(sout)), em)
		if scost > 0 { kv("###s3", "their cost", fmt.tprintf("$%.2f", scost), em, hex(HEX_GREEN)) }
	}

	ps := &app.proj_stats
	if ps.project != "" {
		heading("THE PROJECT", em)
		if !ps.ready {
			info_line(app, "###pl", "Asking the server…", em, hex(HEX_FAINT))
		} else {
			kv("###p1", "sessions", fmt.tprintf("%d  (+ %d sub-agents)", ps.sessions, ps.subagents), em)
			kv("###p2", "prompts · steps", fmt.tprintf("%d · %d", ps.prompts, ps.steps), em)
			kv("###p3", "tokens", fmt.tprintf("%s in · %s out · %s reasoning", kfmt(ps.tokens_in + ps.cache_read), kfmt(ps.tokens_out), kfmt(ps.reasoning)), em)
			if ps.cost > 0 { kv("###p4", "cost", fmt.tprintf("$%.2f", ps.cost), em, hex(HEX_GREEN)) }
			kv("###p5", "active days", fmt.tprintf("%d  (streak %d)", ps.active_days, ps.streak), em)
			if ps.from > 0 { kv("###p6", "since", fmt.tprintf("%s ago", duration(ps.from, now)), em) }
			kv("###p7", "tool calls", fmt.tprintf("%d  (%d failed)", ps.calls, ps.failed), em, ps.failed > 0 ? hex(0xe0a0a0ff) : {})
			if len(ps.tools) > 0 {
				ui.spacer(ui.px(em * 0.4))
				max_p := 0
				for t in ps.tools { max_p = max(max_p, t.calls) }
				for t, i in ps.tools {
					if i == 12 { break }
					rank_row(fmt.tprintf("###pt%d", i), t.name, t.calls, max_p, t.failed, t.p50 > 0 ? fmt.tprintf("p50 %s", ms_text(t.p50)) : "", em, hex(HEX_PURPLE))
				}
			}
			if len(ps.models) > 0 {
				ui.spacer(ui.px(em * 0.4))
				max_s := 0
				for m in ps.models { max_s = max(max_s, m.steps) }
				for m, i in ps.models {
					rank_row(fmt.tprintf("###pm%d", i), m.name, m.steps, max_s, 0, m.cost > 0 ? fmt.tprintf("$%.2f", m.cost) : fmt.tprintf("%s out", kfmt(m.tokens_out)), em, hex(HEX_BLUE))
				}
			}
		}
	}
	ui.spacer(ui.px(em * 1.3))
}

ms_text :: proc(ms: f64) -> string {
	if ms < 1000 { return fmt.tprintf("%.0f ms", ms) }
	return fmt.tprintf("%.1f s", ms / 1000)
}

// A pill of text that is a button (the header's token count): sunken, lit under the pointer.
pill_button :: proc(id: string, label: string, color := Color{}, icon := "") -> ui.Signal {
	em := ui.font_size()
	fs := math.round(em * 0.8)
	ui.next({width = ui.children_sum(), height = ui.px(math.round(em * 1.45)), axis = .X, cross = .Center, cursor = .Hand})
	b := ui.build_box({.Clickable, .Focusable}, id)
	b.custom = proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
		h := b.rect.max.y - b.rect.min.y
		draw_well(dc, b.rect, h * 0.5, hex(b.hot_t > 0.01 ? 0x1a1a1aff : 0x0d0d0dff), b.hot_t * 0.6, accent())
	}
	sig := ui.signal(b)
	if ui.parent(b) {
		ui.spacer(ui.px(em * 0.5))
		fg := color.a > 0 ? color : hex(HEX_WEAK)
		if sig.hovering { fg = lighten(fg, 0.4) }
		if icon != "" {
			ui.next({width = ui.px(em), height = ui.pct(1), font = the_app.icons, font_size = math.round(em * 0.7), fg = fg, text_pad = 0, text_align = .Center})
			ui.build_box({.Draw_Text, .No_Text_Trunc}, fmt.tprintf("%s###i", icon))
			ui.spacer(ui.px(em * 0.25))
		}
		ui.next({width = ui.text_size(0), height = ui.pct(1), font = the_app.mono, font_size = fs, fg = fg, text_pad = 0})
		ui.build_box({.Draw_Text}, fmt.tprintf("%s###t", label))
		ui.spacer(ui.px(em * 0.5))
	}
	return sig
}
