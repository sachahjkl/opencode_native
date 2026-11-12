// The Statistics panel: a tab of the stack the Preview is in (preview.odin dock_setup), opened by the header's token pill. It follows the
// session shown, live, on what the stream says, and never takes the keyboard. Its figures; what fills its context against the
// model's window (GET /api/session/:id/context, read again when a step ends: the server gives the messages, not their sizes, so sizes are
// estimated from their text and scaled to what the last step really sent); its pace; what the loaded messages did (tools, models); its
// sub-agents; and the project's totals from the server (GET /api/experimental/session/stats?project=..&tools=detail).
package ocn

import "core:encoding/json"
import "core:fmt"
import "core:hash"
import "core:math"
import "core:mem"
import "core:mem/virtual"
import "core:slice"
import "core:strings"
import "gt:draw"
import "gt:ui"
import lucide "gt:lucide"
import remote "gt:remote"

Tool_Count :: struct { name: string, calls, failed: int, p50: f64 }
Model_Count :: struct { name: string, steps: int, tokens_in, tokens_out, cost: f64 }

Project_Stats :: struct {
	arena:      virtual.Arena,
	project:    string,   // what they are of ("": not known yet, or none); App_Context.stats_read says how far that is
	sessions, subagents, prompts, steps: int,
	tokens_in, tokens_out, reasoning, cache_read, cache_write, cost: f64,
	active_days, streak: int,
	calls, succeeded, failed: int,
	tools:      [dynamic]Tool_Count,
	models:     [dynamic]Model_Count,
	from, to:   f64,
}

// A part of the context: the tool calls of one tool, the answers, the prompts. Everything in it lives in Stats_Context's arena.
Ctx_Item :: struct {
	key, name: string,
	text:      string,   // what can be read of it ("": nothing, an image)
	tokens:    f64,
}

Ctx_Group :: struct {
	name:   string,
	tokens: f64,
	items:  [dynamic]Ctx_Item,   // the largest first
}

Stats_Context :: struct {
	arena:    virtual.Arena,
	session:  string,   // whose it is (owned)
	groups:   [dynamic]Ctx_Group,   // the largest first
	total:    f64,      // what the last step sent the model (0: no step yet)
	unlisted: f64,      // ... of which no message says: the instructions, the tools' descriptions
	model:    string,   // what that step ran on
}

stats_open :: proc(app: ^App) {
	app.stats_open = true
	dock_setup(app)
	ui.dock_activate(&app.dock, u32(Panel.Stats))
	stats_ask(app)
	context_ask(app)
	app.settle = max(app.settle, FRAMES_AFTER_INPUT)
}

// Shown, hidden. (Open, but under the Preview's tab: it comes up. What the pill is for is to see it.)
stats_toggle :: proc(app: ^App) {
	switch {
	case !app.stats_open:                         stats_open(app)
	case !ui.dock_shown(&app.dock, u32(Panel.Stats)):
		ui.dock_activate(&app.dock, u32(Panel.Stats))
		app.settle = max(app.settle, FRAMES_AFTER_INPUT)
	case:                                         panel_close(app, u32(Panel.Stats))
	}
}

// The totals of the project of the session shown, nothing of the one before. (Also Try again.)
stats_ask :: proc(app: ^App) {
	p := strings.clone(chat_project(app), context.temp_allocator)   // (it may live in the arena that goes)
	ps := &app.proj_stats
	virtual.arena_destroy(&ps.arena)
	ps^ = {}
	_ = virtual.arena_init_growing(&ps.arena)
	remote.reset(&app.cx.stats_read)
	if p == "" { return }
	ps.project = strings.clone(p, virtual.arena_allocator(&ps.arena))
	remote.begin(&app.cx.stats_read)
	request(app, .Stats, "GET", fmt.tprintf("/api/experimental/session/stats?project=%s&tools=detail", url_escape(p)), reading = &app.cx.stats_read)
}

// The panel stays on the session shown: its project comes after it opened (.Self), or the conversation changed under it.
stats_follow :: proc(app: ^App) {
	if chat_project(app) != app.proj_stats.project { stats_ask(app) }
	if app.cx.stats_context.session != app.chat.id { context_ask(app) }
}

stats_forget :: proc(app: ^App) {
	if app.stats_open { panel_close(app, u32(Panel.Stats)) }
	ps := &app.proj_stats
	virtual.arena_destroy(&ps.arena)
	ps^ = {}
	remote.reset(&app.cx.stats_read)
	context_clear(app)
	remote.reset(&app.cx.context_read)
}

@(private = "file")
context_clear :: proc(app: ^App) {
	x := &app.cx.stats_context
	virtual.arena_destroy(&x.arena)
	delete(x.session)
	x^ = {}
}

// What the model has in front of it. (A step ended, the stream came back, Try again.) What is shown stays until the answer, unless it
// is of another session.
context_ask :: proc(app: ^App) {
	x := &app.cx.stats_context
	id := app.chat.id
	if x.session != id {
		context_clear(app)
		x.session = strings.clone(id)
		remote.reset(&app.cx.context_read)
	}
	if id == "" { return }
	remote.begin(&app.cx.context_read)
	request(app, .Context, "GET", fmt.tprintf("/api/session/%s/context", id), tag = id, reading = &app.cx.context_read)
}

// The stream has no event for it: a step that ended is when the context changed. Nothing is read while the panel is closed.
stats_context_soon :: proc(app: ^App) {
	if app.stats_open { ui.deferred_ask(&app.cx.due[.Context], CONTEXT_DEBOUNCE_MS, CONTEXT_DEBOUNCE_MS * DEFERRED_MOST) }
}

@(private = "file")
context_add :: proc(x: ^Stats_Context, group, name, text, key: string, tokens: f64) {
	a := virtual.arena_allocator(&x.arena)
	g: ^Ctx_Group
	for &o in x.groups { if o.name == group { g = &o; break } }
	if g == nil {
		append(&x.groups, Ctx_Group{name = strings.clone(group, a), items = make([dynamic]Ctx_Item, a)})
		g = &x.groups[len(x.groups) - 1]
	}
	g.tokens += tokens
	append(&g.items, Ctx_Item{strings.clone(key, a), strings.clone(ellipsize(name, CTX_ITEM_CHARS), a), strings.clone(text, a), tokens})
}

// A text's size, estimated.
@(private = "file")
tokens_of :: proc(s: string) -> f64 { return f64(len(s)) / CTX_BYTES_PER_TOKEN }

@(private = "file")
context_message :: proc(x: ^Stats_Context, m: json.Value) {
	id := jstr(m, "id")
	text_part :: proc(x: ^Stats_Context, group, t, key: string) {
		if t != "" { context_add(x, group, preview_text(t), t, key, tokens_of(t)) }
	}
	switch jstr(m, "type") {
	case "user":
		text_part(x, "Your prompts", jstr(m, "text"), id)
		for f, i in jarr(m, "files") {
			key := fmt.tprintf("%s_f%d", id, i)
			name := jstr(f, "name") != "" ? jstr(f, "name") : "attachment"
			image := strings.has_prefix(jstr(f, "mime"), "image/")
			context_add(x, "Attached files", name, "", key, image ? CTX_IMAGE_TOKENS : f64(len(jstr(f, "data"))) * 0.75 / CTX_BYTES_PER_TOKEN)
		}
	case "synthetic", "system":
		text_part(x, "Notes to the model", jstr(m, "text"), id)
	case "skill":
		context_add(x, "Skills", jstr(m, "name"), jstr(m, "text"), id, tokens_of(jstr(m, "text")))
	case "shell":
		t := fmt.tprintf("$ %s\n%s", jstr(m, "command"), jstr(m, "output", "output"))
		context_add(x, "Shell commands", jstr(m, "command"), t, id, tokens_of(t))
	case "compaction":
		text_part(x, "Summary of what came before", jstr(m, "summary"), id)
	case "assistant":
		for p, i in jarr(m, "content") {
			key := fmt.tprintf("%s_%d", id, i)
			switch jstr(p, "type") {
			case "text":      text_part(x, "Answers", jstr(p, "text"), key)
			case "reasoning": text_part(x, "Reasoning", jstr(p, "text"), key)
			case "tool":
				st := jget(p, "state")
				name := jstr(p, "name")
				call: Part
				call.tool_name = name
				tool_set_input(&call, jget(st, "input"), context.temp_allocator)
				out := jstr(st, "status") == "error" ? error_text(jget(st, "error")) : content_text(jarr(st, "content"))
				t := fmt.tprintf("%s\n\n%s", call.input, out)
				context_add(x, fmt.tprintf("Tool: %s", name), call.subject != "" ? call.subject : name, t, key, tokens_of(t))
			}
		}
		used := jnum(m, "tokens", "input") + jnum(m, "tokens", "cache", "read")
		if used > 0 {
			x.total = used
			x.model = strings.clone(jstr(m, "model", "id"), virtual.arena_allocator(&x.arena))
		}
	}
}

// The answer replaces what was read. Sizes are in proportion to the text, and together never more than what the step really sent.
context_load :: proc(app: ^App, session: string, v: json.Value) {
	x := &app.cx.stats_context
	virtual.arena_destroy(&x.arena)
	delete(x.session)
	x^ = {session = strings.clone(session)}
	_ = virtual.arena_init_growing(&x.arena)
	x.groups = make([dynamic]Ctx_Group, virtual.arena_allocator(&x.arena))
	for m in jarr(v, "data") { context_message(x, m) }
	sum := 0.0
	for g in x.groups { sum += g.tokens }
	if x.total > 0 && sum > x.total {
		k := x.total / sum
		for &g in x.groups {
			g.tokens *= k
			for &it in g.items { it.tokens *= k }
		}
		sum = x.total
	}
	x.unlisted = max(x.total - sum, 0)
	for &g in x.groups { slice.sort_by(g.items[:], proc(a, b: Ctx_Item) -> bool { return a.tokens > b.tokens }) }
	slice.sort_by(x.groups[:], proc(a, b: Ctx_Group) -> bool { return a.tokens > b.tokens })
}

stats_load :: proc(app: ^App, v: json.Value) {
	ps := &app.proj_stats
	a := virtual.arena_allocator(&ps.arena)
	d := jget(v, "data")
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
Local_Stats :: struct {
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

// The figures of the loaded messages, kept until they change (Chat.changes) or another conversation opens (Chat.gen): the panel went
// through every message and part at every build while it was open.
Local_Kept :: struct {
	arena:    virtual.Arena,   // its lists
	made:     bool,
	gen:      u64,             // Chat.gen and Chat.changes it was made at
	changes:  u64,
	stats:    Local_Stats,     // (its names are the conversation's: read only while gen is the chat's)
	computed: int,             // times it was made (tests)
}

local_stats :: proc(app: ^App) -> ^Local_Stats {
	k := &app.cx.local_stats
	c := &app.chat
	if k.made && k.gen == c.gen && k.changes == c.changes { return &k.stats }
	k.stats = local_stats_of(c, arena_renew(&k.arena))
	k.made, k.gen, k.changes = true, c.gen, c.changes
	k.computed += 1
	return &k.stats
}

@(private = "file")
local_stats_of :: proc(c: ^Chat, a: mem.Allocator) -> (l: Local_Stats) {
	l.tools = make([dynamic]Tool_Count, a)
	l.models = make([dynamic]Model_Count, a)
	for &m in c.messages {
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
// The panel

CONTEXT_FULL_SHARE  :: 0.85    // of the model's window
CONTEXT_WARN_SHARE  :: 0.6
TOOLS_SHOWN         :: 14
PROJECT_TOOLS_SHOWN :: 12
RANK_NAME_CHARS     :: 28
DURATION_ORIGIN_MS  :: 0.001   // duration_text() takes a start of 0 as unknown; a sum of steps starts there

HEX_METER_WELL  :: 0x0a0a0aff
HEX_STAT_VALUE  :: 0xdadadaff
HEX_RANK_NAME   :: 0xe2e2e2ff
HEX_STAT_FAILED :: 0xe0a0a0ff
HEX_PILL_HOT    :: 0x1a1a1aff

@(private = "file")
Bar :: struct { t: f32, color: Color }

@(private = "file")
bar_draw :: proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
	d := (^Bar)(user)
	s := ui.scale()
	r := b.rect
	h := r.max.y - r.min.y
	draw_well(dc, r, h * 0.5, hex(HEX_METER_WELL))
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

// A figure and what it is: plain type, nothing around it. The columns line up when they wrap; a figure is never cut.
@(private = "file")
figure :: proc(id, value, caption: string, color: Color, em: f32) {
	size := math.round(em * FS_FIGURE)
	ui.next({width = ui.px(max(em * FIGURE_W_EM, ui.text_width(the_app.font, size, value) + em)), height = ui.children_sum(), axis = .Y})
	if ui.column(id = id) {
		ui.next({width = ui.fill(), height = ui.px(math.round(em * FIGURE_H_EM)), fg = color, font = the_app.font, font_size = size, text_pad = 0})
		ui.build_box({.Draw_Text, .No_Text_Trunc}, fmt.tprintf("%s###v", value))
		ui.next({width = ui.fill(), height = ui.px(math.round(em * FIGURE_CAPTION_EM)), fg = hex(HEX_FAINT), font = the_app.font, font_size = math.round(em * FS_CAPTION), text_pad = 0})
		ui.build_box({.Draw_Text}, fmt.tprintf("%s###c", caption))
	}
}

// A value that wraps: nothing of it is cut, however narrow the panel.
@(private = "file")
wrapped :: proc(id, v: string, color: Color, em: f32) {
	ui.next({width = ui.fill(), font = the_app.mono, font_size = math.round(em * FS_SMALL), flags = {.Text_Wrap}, fg = color, text_pad = 0})
	ui.paragraph(fmt.tprintf("%s%s", label_safe(v), id))
}

// A key and its value, which wraps; very narrow, it goes under its key.
@(private = "file")
kv :: proc(id, k, v: string, em: f32, col := Color{}) {
	w := the_app.cx.stats_w
	color := col.a > 0 ? col : hex(HEX_STAT_VALUE)
	key := ui.Style_Mod{font = the_app.mono, font_size = math.round(em * FS_SMALL), height = ui.px(math.round(em * 1.45))}
	stacked := w <= em * STATS_STACK_EM
	ui.next({width = ui.fill(), height = ui.children_sum(), axis = stacked ? .Y : .X})
	b := ui.build_box({}, id)
	if ui.parent(b) {
		text("k", k, hex(HEX_FAINT), key, stacked ? ui.fill() : ui.px(min(em * STATS_KEY_W_EM, w * STATS_KEY_SHARE)))
		ui.next({width = ui.fill(), height = ui.children_sum(), axis = .Y})
		if ui.column(id = "###c") {
			if !stacked { ui.spacer(ui.px(math.round(em * 0.2))) }
			wrapped("###v", v, color, em)
			ui.spacer(ui.px(math.round(em * 0.2)))
		}
	}
}

// A row of a ranking: name, a bar of its share, its count (and failures). Narrow, the numbers keep what they need and the name gives way.
@(private = "file")
rank_row :: proc(id, name: string, n, max_n, failed: int, extra: string, em: f32, color: Color) {
	mono := ui.Style_Mod{font = the_app.mono, font_size = math.round(em * FS_SMALL)}
	note := ui.Style_Mod{font = the_app.mono, font_size = math.round(em * FS_CAPTION)}
	bold := ui.Style_Mod{font = the_app.mono_bold, font_size = math.round(em * FS_SMALL)}
	failures := failed > 0 ? fmt.tprintf("%d failed", failed) : ""
	ui.next({width = ui.fill(), height = ui.px(em * 1.55), axis = .X, cross = .Center})
	if ui.row(.Center, id = id) {
		if the_app.cx.stats_w > em * STATS_WIDE_EM {
			text("n", ellipsize(name, RANK_NAME_CHARS), hex(HEX_RANK_NAME), mono, ui.px(em * 11))
			meter("###m", max_n > 0 ? f32(n) / f32(max_n) : 0, color, em)
			ui.spacer(ui.px(em * 0.6))
			text("c", fmt.tprintf("%d", n), hex(HEX_STAT_VALUE), bold, ui.px(em * 3))
			text("f", failures, hex(HEX_RED), note, ui.px(em * 5))
			text("x", extra, hex(HEX_FAINT), note, ui.px(em * 6.5))
			return
		}
		text("n", ellipsize(name, RANK_NAME_CHARS), hex(HEX_RANK_NAME), mono, ui.fill())
		ui.spacer(ui.px(em * 0.5))
		if the_app.cx.stats_w > em * STATS_METER_EM {
			meter("###m", max_n > 0 ? f32(n) / f32(max_n) : 0, color, em, ui.px(em * STATS_METER_W_EM))
			ui.spacer(ui.px(em * 0.5))
		}
		if failures != "" {
			text("f", failures, hex(HEX_RED), note)
			ui.spacer(ui.px(em * 0.5))
		}
		if extra != "" {
			text("x", extra, hex(HEX_FAINT), note)
			ui.spacer(ui.px(em * 0.5))
		}
		text("c", fmt.tprintf("%d", n), hex(HEX_STAT_VALUE), bold)
	}
}

@(private = "file")
// A section of the panel: a stripe and its title in its colour (one of opencode's, as the theme shown has it), a weak note.
heading :: proc(s: string, em: f32, color: u32 = HEX_BLUE, note := "") {
	ui.spacer(ui.px(em * 0.9))
	if ui.style({font = the_app.mono, font_size = em}) {
		ui.section_header(fmt.tprintf("###st_%s", s), s, note, "", hex(color))
	}
	ui.spacer(ui.px(em * 0.35))
}

// Its place in the dock. Nothing here is focusable: it does not take the keyboard from the composer.
stats_panel :: proc(app: ^App, em: f32) {
	stats_follow(app)
	c := &app.chat
	s := c.have_self ? &c.self : find_session(app, c.id)
	ui.next({width = ui.fill(), height = ui.fill(), axis = .Y, bg = hex(HEX_BG0), radius = 0})
	if ui.column(flags = {.Draw_Background}, id = "###st") {
		ui.next({width = ui.fill(), height = ui.fill()})
		if ui.scroll_y("###stats_scroll") {
			pad := em * (app.cx.stats_w > em * STATS_STACK_EM ? DIALOG_MARGIN_EM : STATS_NARROW_PAD_EM)
			ui.next({width = ui.fill(), height = ui.children_sum(), axis = .X})
			if ui.row() {
				ui.spacer(ui.px(pad))
				ui.next({width = ui.fill(), height = ui.children_sum(), axis = .Y})
				if ui.column() {
					if c.id != "" {
						stats_body(app, s, em)
					} else {
						ui.spacer(ui.px(em * 1.2))
						info_line(app, "###st_none", "Open a session: its statistics show here.", em, hex(HEX_FAINT))
					}
				}
				ui.spacer(ui.px(pad))
			}
		}
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
		text("t", s != nil && s.title != "" ? s.title : "Session", hex(HEX_BRIGHT), ui.Style_Mod{font_size = math.round(em * FS_TITLE)}, ui.fill())
	}
	totals := stats_totals(c, s)
	used, window := context_used(app, c, l)
	stats_figures(totals, used, window, em)
	stats_context(app, used, window, em)
	stats_tokens(totals, em)
	stats_time(c, s, l, now, app.prefs.clock24, em)
	stats_rankings(app, l, em)
	stats_children(app, c, em)
	stats_project(app, now, em)
	ui.spacer(ui.px(em * 1.3))
}

// The session's totals: the server's, else the live ones.
@(private = "file")
Totals :: struct { tin, tout, reas, cread, cwrite, cost: f64 }

@(private = "file")
stats_totals :: proc(c: ^Chat, s: ^Session_Info) -> (t: Totals) {
	t = {c.tokens_in, c.tokens_out, 0, c.cache_read, 0, c.cost}
	if s != nil {
		t = {max(t.tin, s.tokens_in), max(t.tout, s.tokens_out), s.reasoning, max(t.cread, s.cache_read), s.cache_write, max(t.cost, s.cost)}
	}
	return
}

// The context filled, and the model's window (0: not known). The server's word for it first, what the loaded messages say else.
@(private = "file")
context_used :: proc(app: ^App, c: ^Chat, l: ^Local_Stats) -> (used, window: f64) {
	x := &app.cx.stats_context
	used = x.total > 0 ? x.total : l.last_context
	model := x.model != "" ? x.model : l.last_model != "" ? l.last_model : c.model
	for m in app.models { if m.id == model { window = m.ctx_len; break } }
	return
}

// Near full is the one thing here that a colour has to say.
@(private = "file")
context_color :: proc(t: f32) -> Color {
	return t > CONTEXT_FULL_SHARE ? hex(HEX_RED) : t > CONTEXT_WARN_SHARE ? hex(HEX_YELLOW) : hex(HEX_TEXT)
}

@(private = "file")
stats_figures :: proc(t: Totals, used, window: f64, em: f32) {
	tin, tout, reas, cread, cost := t.tin, t.tout, t.reas, t.cread, t.cost
	plain := hex(HEX_TEXT)
	ui.spacer(ui.px(em * 0.8))
	ui.next({width = ui.fill(), height = ui.children_sum(), gap = {em * 0.5, em * 0.7}})
	if ui.flow({em * 0.5, em * 0.7}, "###figures") {
		if used > 0 && window > 0 {
			share := f32(used / window)
			figure("###f0", fmt.tprintf("%.0f %%", share * 100), "context", context_color(share), em)
		}
		figure("###f1", kfmt(tin + cread), "tokens in", plain, em)
		figure("###f2", kfmt(tout), "tokens out", plain, em)
		figure("###f3", kfmt(reas), "reasoning", plain, em)
		figure("###f4", cost > 0 ? fmt.tprintf("$%.2f", cost) : "$0", "cost", plain, em)
		hit := tin + cread > 0 ? cread / (tin + cread) : 0
		figure("###f5", fmt.tprintf("%.0f %%", hit * 100), "cache hits", plain, em)
	}
}

// One colour, fainter from the largest part to the smallest: the bar says how much, the list says what.
@(private = "file")
context_shade :: proc(i: int) -> Color {
	return with_alpha(accent(), max(CTX_SHADE_FIRST - f32(i) * CTX_SHADE_STEP, CTX_SHADE_LAST))
}

@(private = "file")
Bar_Part :: struct { share: f32, color: Color }

@(private = "file")
Stacked_Bar :: struct { parts: []Bar_Part }

@(private = "file")
stacked_draw :: proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
	d := (^Stacked_Bar)(user)
	s := ui.scale()
	r := b.rect
	h := r.max.y - r.min.y
	draw_well(dc, r, h * 0.5, hex(HEX_METER_WELL))
	room := r.max.x - r.min.x - 2 * s
	x := r.min.x + s
	for p in d.parts {
		w := room * clamp(p.share, 0, 1)
		if w < 1 { continue }
		draw.rect(dc, {{x, r.min.y + s}, {min(x + w - s, r.max.x - s), r.max.y - s}}, p.color, s)
		x += w
	}
}

// What fills the context as parts of a bar as long as the model's window.
@(private = "file")
context_bar :: proc(app: ^App, used, window: f64, em: f32) {
	x := &app.cx.stats_context
	whole := window > 0 ? window : used
	parts := make([dynamic]Bar_Part, context.temp_allocator)
	rest := 0.0
	for g, i in x.groups {
		if i < CTX_BAR_PARTS { append(&parts, Bar_Part{f32(g.tokens / whole), context_shade(i)}) } else { rest += g.tokens }
	}
	if rest > 0 { append(&parts, Bar_Part{f32(rest / whole), context_shade(CTX_BAR_PARTS)}) }
	if x.unlisted > 0 { append(&parts, Bar_Part{f32(x.unlisted / whole), hex(HEX_FAINT)}) }
	if len(x.groups) == 0 && x.unlisted == 0 { append(&parts, Bar_Part{f32(used / whole), hex(HEX_WEAK)}) }   // (only its total is known)
	ui.next({width = ui.fill(), height = ui.px(math.round(em * 0.75))})
	b := ui.build_box({}, "###ctx_bar")
	d := ui.frame_new(Stacked_Bar)
	d.parts = parts[:]
	b.custom = stacked_draw
	b.custom_user = d
}

// A square of a part's colour.
@(private = "file")
swatch :: proc(color: Color, em: f32) {
	side := math.round(em * 0.6)
	ui.next({width = ui.px(side), height = ui.px(side)})
	b := ui.build_box({}, "###sw")
	d := ui.frame_new(Color)
	d^ = color
	b.custom = proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) { draw.rect(dc, b.rect, (^Color)(user)^, 2 * ui.scale()) }
	b.custom_user = d
}

// A line of the list. `key` "": nothing opens. True when clicked.
@(private = "file")
context_line :: proc(app: ^App, id, name, size, key: string, indent: f32, shade: Maybe(Color), em: f32) -> bool {
	opens := key != ""
	ui.next({width = ui.fill(), height = ui.px(em * 1.55), axis = .X, cross = .Center, cursor = opens ? .Hand : .Arrow})
	b := ui.build_box(opens ? {.Clickable} : {}, id)
	b.custom = proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
		if b.hot_t > FADE_VISIBLE { draw.rect(dc, b.rect, {1, 1, 1, 0.035 * b.hot_t}) }   // (square: a row)
	}
	sig := ui.signal(b)
	if ui.parent(b) {
		ui.spacer(ui.px(em * (0.2 + indent)))
		if opens {
			glyph(context_open(app, key) ? lucide.CHEVRON_DOWN : lucide.CHEVRON_RIGHT, hex(HEX_FAINT), math.round(em * ICON_TINY), em)
		} else {
			ui.spacer(ui.px(em))
		}
		if c, has := shade.?; has {
			swatch(c, em)
			ui.spacer(ui.px(em * 0.45))
		}
		text("n", name, hex(HEX_RANK_NAME), ui.Style_Mod{font = app.mono, font_size = math.round(em * FS_SMALL)}, ui.fill())
		ui.spacer(ui.px(em * 0.5))
		text("s", size, hex(HEX_STAT_VALUE), ui.Style_Mod{font = app.mono, font_size = math.round(em * FS_SMALL)})
		ui.spacer(ui.px(em * 0.2))
	}
	return sig.clicked
}

@(private = "file")
context_open :: proc(app: ^App, key: string) -> bool { return app.expanded[hash.fnv64a(transmute([]u8)key)] or_else false }

@(private = "file")
context_flip :: proc(app: ^App, key: string) {
	k := hash.fnv64a(transmute([]u8)key)
	app.expanded[k] = !(app.expanded[k] or_else false)
}

// The parts, the largest first, each opened in place on what it holds, each of those on its text.
@(private = "file")
context_list :: proc(app: ^App, used: f64, em: f32) {
	x := &app.cx.stats_context
	whole := max(used, 1)
	size_of :: proc(tokens, whole: f64) -> string {
		if the_app.cx.stats_w <= ui.font_size() * STATS_STACK_EM { return fmt.tprintf("~%s", kfmt(tokens)) }   // (the name needs the room)
		return fmt.tprintf("~%s  %.0f %%", kfmt(tokens), tokens / whole * 100)
	}
	for &g, i in x.groups {
		key := fmt.tprintf("ctxg_%s", g.name)
		name := len(g.items) > 1 ? fmt.tprintf("%s  (%d)", g.name, len(g.items)) : g.name
		if context_line(app, fmt.tprintf("###cg%d", i), name, size_of(g.tokens, whole), key, 0, context_shade(min(i, CTX_BAR_PARTS)), em) { context_flip(app, key) }
		if !context_open(app, key) { continue }
		for &it, k in g.items {
			if k == CTX_ITEMS_SHOWN {
				info_line(app, fmt.tprintf("###cm%d", i), fmt.tprintf("… and %d more", len(g.items) - CTX_ITEMS_SHOWN), em, hex(HEX_FAINT))
				break
			}
			item_key := it.text != "" ? fmt.tprintf("ctxi_%s", it.key) : ""
			if context_line(app, fmt.tprintf("###ci%d_%d", i, k), it.name, fmt.tprintf("~%s", kfmt(it.tokens)), item_key, 1, nil, em) { context_flip(app, item_key) }
			if item_key != "" && context_open(app, item_key) {
				mono_well(fmt.tprintf("###cw%d_%d", i, k), it.text, em, CTX_OPEN_LINES)
				ui.spacer(ui.px(em * 0.3))
			}
		}
	}
	if x.unlisted > 0 {
		context_line(app, "###cu", "Instructions and tool definitions", size_of(x.unlisted, whole), "", 0, hex(HEX_FAINT), em)
	}
}

// The context the last step filled, against the model's window, and what fills it.
@(private = "file")
stats_context :: proc(app: ^App, used, window: f64, em: f32) {
	heading("Context", em, HEX_CYAN)
	if used > 0 {
		t := f32(window > 0 ? used / window : 0)
		wrapped("###ctx", window > 0 ? fmt.tprintf("%.0f %%  ·  %s / %s", t * 100, kfmt(used), kfmt(window)) : fmt.tprintf("%s  (the model's window is not listed)", kfmt(used)), context_color(t), em)
		ui.spacer(ui.px(em * 0.35))
		context_bar(app, used, window, em)
		ui.spacer(ui.px(em * 0.5))
	} else {
		info_line(app, "###ctxn", "Not known yet (no step in the loaded messages, or the model's window is not listed).", em, hex(HEX_FAINT))
	}
	if read_shown(app, "###ctxl", &app.cx.context_read, em, context_ask) {
		context_list(app, used, em)
		ui.spacer(ui.px(em * 0.3))
		info_line(app, "###ctxh", "The last step's total is the server's. It gives the messages, not their sizes: the parts are estimated from their text, the rest is what no message says. Near the top, opencode compacts the conversation.", em)
	}
}

@(private = "file")
stats_tokens :: proc(t: Totals, em: f32) {
	tin, tout, reas, cread, cwrite, cost := t.tin, t.tout, t.reas, t.cread, t.cwrite, t.cost
	heading("Tokens", em, HEX_YELLOW)
	// their mix at a glance: what went in (cached or not), what came out
	if total := tin + cread + cwrite + tout + reas; total > 0 {
		ui.next({width = ui.fill(), height = ui.px(math.round(em * 1.5))})
		ui.stacked_bar("###kbar", {
			{f32(tin), hex(HEX_BLUE), kfmt(tin)}, {f32(cread), hex(HEX_CYAN), kfmt(cread)}, {f32(cwrite), hex(HEX_PURPLE), kfmt(cwrite)},
			{f32(tout), hex(HEX_GREEN), kfmt(tout)}, {f32(reas), hex(HEX_YELLOW), kfmt(reas)},
		})
		ui.spacer(ui.px(em * 0.4))
	}
	kv("###k1", "input", fmt.tprintf("%s  (uncached)", kfmt(tin)), em, hex(HEX_BLUE))   // (the colour of its part of the bar)
	kv("###k2", "cache read", kfmt(cread), em, hex(HEX_CYAN))
	kv("###k3", "cache write", kfmt(cwrite), em, hex(HEX_PURPLE))
	kv("###k4", "output", kfmt(tout), em, hex(HEX_GREEN))
	kv("###k5", "reasoning", kfmt(reas), em, hex(HEX_YELLOW))
	kv("###k6", "cost", fmt.tprintf("$%.4f", cost), em)
}

@(private = "file")
stats_time :: proc(c: ^Chat, s: ^Session_Info, l: ^Local_Stats, now: f64, clock24: bool, em: f32) {
	heading("Time", em, HEX_PURPLE)
	if s != nil {
		kv("###d1", "created", fmt.tprintf("%s  (%s ago)", clock_text(s.created, clock24), duration_text(s.created, now)), em)
		if s.updated > 0 { kv("###d2", "last change", fmt.tprintf("%s  (%s ago)", clock_text(s.updated, clock24), duration_text(s.updated, now)), em) }
	}
	if l.active_ms > 0 {
		kv("###d3", "model at work", fmt.tprintf("%s over %d steps (%s a step)", duration_text(DURATION_ORIGIN_MS, l.active_ms), l.steps, duration_text(DURATION_ORIGIN_MS, l.active_ms / f64(max(l.steps, 1)))), em)
		if l.out_tokens > 0 { kv("###d4", "output pace", fmt.tprintf("%.0f tokens / s", l.out_tokens / (l.active_ms / MS_PER_S)), em) }
	}
	kv("###d5", "loaded", fmt.tprintf("%d messages · %d prompts · %d steps%s", l.msgs, l.prompts, l.steps, c.older != "" ? " (earlier ones not loaded)" : ""), em)
}

// What the loaded messages called, and which models answered.
@(private = "file")
stats_rankings :: proc(app: ^App, l: ^Local_Stats, em: f32) {
	heading("Tools", em, HEX_GREEN, fmt.tprintf("%d calls, %d failed", l.calls, l.failed))
	max_t := len(l.tools) > 0 ? l.tools[0].calls : 0
	for t, i in l.tools {
		if i == TOOLS_SHOWN { info_line(app, "###tm", fmt.tprintf("… and %d more tools", len(l.tools) - TOOLS_SHOWN), em, hex(HEX_FAINT)); break }
		rank_row(fmt.tprintf("###tl%d", i), t.name, t.calls, max_t, t.failed, "", em, accent())
	}
	if len(l.tools) == 0 { info_line(app, "###tn", "No tool call in the loaded messages.", em, hex(HEX_FAINT)) }

	if len(l.models) > 0 {
		heading("Models", em, HEX_PEACH)
		max_m := l.models[0].steps
		for m, i in l.models {
			rank_row(fmt.tprintf("###ml%d", i), m.name, m.steps, max_m, 0, fmt.tprintf("%s out", kfmt(m.tokens_out)), em, hex(HEX_WEAK))
		}
	}
}

@(private = "file")
stats_children :: proc(app: ^App, c: ^Chat, em: f32) {
	if len(c.children) > 0 {
		heading("Sub-agents", em, HEX_ROSE)
		running, scost, sin, sout := 0, 0.0, 0.0, 0.0
		for k in c.children {
			if app.busy[k.id] or_else false { running += 1 }
			scost += k.cost; sin += k.tokens_in + k.cache_read; sout += k.tokens_out
		}
		kv("###s1", "launched", fmt.tprintf("%d  (%d running)", len(c.children), running), em, running > 0 ? hex(HEX_YELLOW) : {})
		kv("###s2", "their tokens", fmt.tprintf("%s in · %s out", kfmt(sin), kfmt(sout)), em)
		if scost > 0 { kv("###s3", "their cost", fmt.tprintf("$%.2f", scost), em) }
	}
}

// The project's totals, from the server.
@(private = "file")
stats_project :: proc(app: ^App, now: f64, em: f32) {
	ps := &app.proj_stats
	if ps.project != "" {
		heading("The project", em, HEX_BLUE)
		if read_shown(app, "###pl", &app.cx.stats_read, em, stats_ask) {
			kv("###p1", "sessions", fmt.tprintf("%d  (+ %d sub-agents)", ps.sessions, ps.subagents), em)
			kv("###p2", "prompts · steps", fmt.tprintf("%d · %d", ps.prompts, ps.steps), em)
			kv("###p3", "tokens", fmt.tprintf("%s in · %s out · %s reasoning", kfmt(ps.tokens_in + ps.cache_read), kfmt(ps.tokens_out), kfmt(ps.reasoning)), em)
			if ps.cost > 0 { kv("###p4", "cost", fmt.tprintf("$%.2f", ps.cost), em) }
			kv("###p5", "active days", fmt.tprintf("%d  (streak %d)", ps.active_days, ps.streak), em)
			if ps.from > 0 { kv("###p6", "since", fmt.tprintf("%s ago", duration_text(ps.from, now)), em) }
			kv("###p7", "tool calls", fmt.tprintf("%d  (%d failed)", ps.calls, ps.failed), em, ps.failed > 0 ? hex(HEX_STAT_FAILED) : {})
			if len(ps.tools) > 0 {
				ui.spacer(ui.px(em * 0.4))
				max_p := 0
				for t in ps.tools { max_p = max(max_p, t.calls) }
				for t, i in ps.tools {
					if i == PROJECT_TOOLS_SHOWN { break }
					rank_row(fmt.tprintf("###pt%d", i), t.name, t.calls, max_p, t.failed, t.p50 > 0 ? fmt.tprintf("p50 %s", ms_text(t.p50)) : "", em, accent())
				}
			}
			if len(ps.models) > 0 {
				ui.spacer(ui.px(em * 0.4))
				max_s := 0
				for m in ps.models { max_s = max(max_s, m.steps) }
				for m, i in ps.models {
					rank_row(fmt.tprintf("###pm%d", i), m.name, m.steps, max_s, 0, m.cost > 0 ? fmt.tprintf("$%.2f", m.cost) : fmt.tprintf("%s out", kfmt(m.tokens_out)), em, hex(HEX_WEAK))
				}
			}
		}
	}
}

// A pill of text that is a button (the header's token count): sunken, lit under the pointer.
pill_button :: proc(id: string, label: string, color := Color{}, icon := "") -> ui.Signal {
	em := ui.font_size()
	fs := math.round(em * FS_SMALL)
	ui.next({width = ui.children_sum(), height = ui.px(math.round(em * PILL_H_EM)), axis = .X, cross = .Center, cursor = .Hand})
	b := ui.build_box({.Clickable, .Focusable}, id)
	b.custom = proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
		h := b.rect.max.y - b.rect.min.y
		draw_well(dc, b.rect, h * 0.5, hex(b.hot_t > FADE_VISIBLE ? HEX_PILL_HOT : HEX_PILL), b.hot_t * 0.6, accent())
	}
	sig := ui.signal(b)
	if ui.parent(b) {
		ui.spacer(ui.px(em * 0.5))
		fg := color.a > 0 ? color : hex(HEX_WEAK)
		if sig.hovering { fg = lighten(fg, 0.4) }
		if icon != "" {
			ui.next({width = ui.px(em), height = ui.pct(1), font = the_app.icons, font_size = math.round(em * ICON_SMALL), fg = fg, text_pad = 0, text_align = .Center})
			ui.build_box({.Draw_Text, .No_Text_Trunc}, fmt.tprintf("%s###i", icon))
			ui.spacer(ui.px(em * 0.25))
		}
		ui.next({width = ui.text_size(0), height = ui.pct(1), font = the_app.mono, font_size = fs, fg = fg, text_pad = 0})
		ui.build_box({.Draw_Text}, fmt.tprintf("%s###t", label))
		ui.spacer(ui.px(em * 0.5))
	}
	return sig
}

////////////////////////////////
// What the answers to its requests do (net.odin REQ_FACTS)

stats_on_ok :: proc(app: ^App, r: ^Request, v: json.Value) { stats_load(app, v) }

context_on_ok :: proc(app: ^App, r: ^Request, v: json.Value) { context_load(app, r.tag, v) }
