// The command palette (Ctrl+K): one field that reaches everything. What the program does (commands.odin), the sessions, the
// agents, the models, the server's own commands and the preferences that are switches. A first character narrows it:
// > commands, @ sessions, / the server's commands, # models, : switches. What was chosen before comes first (it fades with
// a half-life of two weeks, palette_usage.txt beside the preferences).
package occ

import "core:fmt"
import "core:math"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "gt:config"
import "gt:draw"
import "gt:ui"

Pal_Kind :: enum u8 { Command, Session, Agent, Model, Slash, Switch }

Pal_Item :: struct {
	kind:   Pal_Kind,
	id:     string,
	title:  string,
	detail: string,
	keys:   string,
	icon:   string,
	cmd:    ^Command,
	index:  int,      // in app.models
	on:     bool,     // a switch's state
	toggle: bool,     // it is a switch
}

@(private = "file")
Pal_Hit :: struct { item: int, score: f64, ranges: []ui.Fuzzy_Range }

Usage :: struct { weight: f64, last_ms: f64 }

Palette :: struct {
	open:    bool,
	fresh:   bool,
	field:   ui.Text_Field,
	sel:     int,
	reveal:  bool,
	mouse:   Vec2,
	usage:   map[string]Usage,   // by "kind:id" (keys owned)
	file:    string,
}

Slash :: struct { name, description: string }   // a command of the server (owned)

palette_init :: proc(app: ^App, file: string) {
	p := &app.palette
	p.file = strings.clone(file)
	if file == "" { return }
	data, err := os.read_entire_file(file, context.temp_allocator)
	if err != nil { return }
	rest := string(data)
	for line in strings.split_lines_iterator(&rest) {
		parts := strings.split(line, "\t", context.temp_allocator)
		if len(parts) != 3 { continue }
		w, w_ok := strconv.parse_f64(parts[1])
		t, t_ok := strconv.parse_f64(parts[2])
		if w_ok && t_ok { p.usage[strings.clone(parts[0])] = {w, t} }
	}
}

@(private = "file")
usage_save :: proc(p: ^Palette) {
	if p.file == "" { return }
	b := strings.builder_make(context.temp_allocator)
	for k, u in p.usage { fmt.sbprintf(&b, "%s\t%f\t%f\n", k, u.weight, u.last_ms) }
	_ = os.write_entire_file(p.file, transmute([]u8)strings.to_string(b))
}

// What choosing this before is worth now.
@(private = "file")
usage_now :: proc(u: Usage, now: f64) -> f64 { return u.weight * math.pow(0.5, (now - u.last_ms) / USAGE_HALF_LIFE_MS) }

@(private = "file")
usage_key :: proc(it: ^Pal_Item) -> string { return fmt.tprintf("%d:%s", int(it.kind), it.id) }

@(private = "file")
usage_note :: proc(p: ^Palette, it: ^Pal_Item) {
	k := usage_key(it)
	now := now_epoch_ms()
	u, known := p.usage[k]
	if !known { k = strings.clone(k) }
	p.usage[k] = {usage_now(u, now) + 1, now}
	usage_save(p)
}

palette_toggle :: proc(app: ^App) {
	p := &app.palette
	if p.open { p.open = false; return }
	p.open, p.fresh, p.sel = true, true, 0
	ui.field_set(&p.field, "")
	if !app.cx.have_slash { request(app, .Slash, "GET", "/api/command") }
}

slash_load :: proc(app: ^App, list: []Slash) {
	for s in app.cx.slash { delete(s.name); delete(s.description) }
	clear(&app.cx.slash)
	append(&app.cx.slash, ..list)
	app.cx.have_slash = true
}

@(private = "file")
palette_items :: proc(app: ^App, only: rune, searching: bool) -> []Pal_Item {
	items := make([dynamic]Pal_Item, context.temp_allocator)
	want :: proc(only, mark: rune) -> bool { return only == 0 || only == mark }
	if want(only, '>') {
		for &c in COMMANDS {
			if !command_enabled(app, &c) || c.id == "app.palette" { continue }
			it := Pal_Item{kind = .Command, id = c.id, title = c.title, detail = c.group, keys = c.keys, icon = c.icon, cmd = &c}
			if c.checked != nil { it.toggle, it.on = true, c.checked(app) }
			append(&items, it)
		}
	}
	if want(only, '@') {
		shown := 0
		for &s in app.sessions {
			if s.parent != "" { continue }
			if !searching && only == 0 && shown == PALETTE_SESSIONS { break }
			append(&items, Pal_Item{kind = .Session, id = s.id, title = s.title != "" ? s.title : "Untitled", detail = base_name(s.directory), icon = ICO_CHAT})
			shown += 1
		}
	}
	if searching || only != 0 {
		if want(only, '/') {
			for s in app.cx.slash { append(&items, Pal_Item{kind = .Slash, id = s.name, title = fmt.tprintf("/%s", s.name), detail = s.description, icon = ICO_TERMINAL}) }
		}
		if want(only, '@') {
			for a in app.agents {
				if a.mode == "subagent" { continue }
				append(&items, Pal_Item{kind = .Agent, id = a.id, title = fmt.tprintf("Agent: %s", a.name != "" ? a.name : a.id), detail = a.description, icon = ICO_ROBOT, toggle = true, on = a.id == app.chat.agent})
			}
		}
		if want(only, '#') {
			for m, i in app.models {
				append(&items, Pal_Item{kind = .Model, id = fmt.tprintf("%s/%s", m.provider, m.id), title = m.name != "" ? m.name : m.id, detail = m.provider, icon = ICO_CHIP, index = i, toggle = true, on = m.id == app.chat.model && m.provider == app.chat.provider})
			}
		}
		if want(only, ':') {
			for d in PREF_DEFS {
				if d.kind != .Bool { continue }
				append(&items, Pal_Item{kind = .Switch, id = d.name, title = d.name, detail = ellipsize(d.description, 60), icon = ICO_SLIDERS, toggle = true, on = config.bool_of(&app.cfg_prefs, d.name)})
			}
		}
	}
	return items[:]
}

// Done when it is chosen. (open_root and command_run wait for the end of the frame; the others only note a value.)
@(private = "file")
palette_choose :: proc(app: ^App, it: ^Pal_Item) {
	usage_note(&app.palette, it)
	app.palette.open = false
	switch it.kind {
	case .Command: command_run(app, it.cmd)
	case .Session: open_root(app, it.id)
	case .Agent:
		if app.chat.id != "" { switch_agent(app, app.chat.id, it.id) }
		app.chat.agent = strings.clone(it.id, app.chat.alloc)
	case .Model:
		m := app.models[it.index]
		if app.chat.id != "" { switch_model(app, app.chat.id, m) }
		app.chat.model = strings.clone(m.id, app.chat.alloc)
		app.chat.provider = strings.clone(m.provider, app.chat.alloc)
	case .Slash:
		ui.area_set(&app.composer, fmt.tprintf("/%s ", it.id))
		app.cx.focus_composer = true
	case .Switch:
		pref_set(app, it.id, it.on ? "false" : "true")
	}
}

@(private = "file")
Pal_Row_Draw :: struct { selected: bool }

palette_dialog :: proc(app: ^App, em: f32) {
	p := &app.palette
	if !p.open { return }
	text_in := ui.field_string(&p.field)
	only: rune
	needle := text_in
	if len(text_in) > 0 && strings.contains_rune(">@/#:", rune(text_in[0])) {
		only = rune(text_in[0])
		needle = text_in[1:]
	}
	items := palette_items(app, only, needle != "")
	now := now_epoch_ms()
	hits := make([dynamic]Pal_Hit, context.temp_allocator)
	for &it, i in items {
		score, ranges, ok := ui.fuzzy_score(needle, it.title)
		if !ok { continue }
		s := f64(score)
		if u, known := p.usage[usage_key(&it)]; known { s += usage_now(u, now) * USAGE_SCORE }
		append(&hits, Pal_Hit{i, s, ranges})
	}
	slice.stable_sort_by(hits[:], proc(a, b: Pal_Hit) -> bool { return a.score > b.score })
	n := min(len(hits), PALETTE_ROWS_MAX)
	if n > 0 {
		if ui.key_press(.Down) { p.sel = (p.sel + 1) % n; p.reveal = true }
		if ui.key_press(.Up) { p.sel = (p.sel + n - 1) % n; p.reveal = true }
		if ui.key_press(.Page_Down) { p.sel = min(p.sel + PALETTE_ROWS, n - 1); p.reveal = true }
		if ui.key_press(.Page_Up) { p.sel = max(p.sel - PALETTE_ROWS, 0); p.reveal = true }
	}
	p.sel = clamp(p.sel, 0, max(n - 1, 0))
	mouse := ui.mouse_pos()
	moved := abs(mouse.x - p.mouse.x) + abs(mouse.y - p.mouse.y) > 0.5
	p.mouse = mouse
	chosen := -1
	row_h := math.round(em * 2.1)
	if ui.modal("palette", math.round(em * PALETTE_W_EM), &p.open, PALETTE_TOP) {
		dialog_backdrop()
		ui.spacer(ui.px(em * 0.6))
		ui.next({width = ui.fill(), height = ui.children_sum(), axis = .X, cross = .Center})
		if ui.row(.Center, id = "###pal_top") {
			ui.spacer(ui.px(em * 0.6))
			ui.next({width = ui.fill(), height = ui.px(math.round(em * 2.4)), axis = .X, cross = .Center})
			if well("###pal_well", .X, radius = 8, focus = 1) {
				ui.spacer(ui.px(em * 0.6))
				glyph(ICO_SEARCH, hex(HEX_FAINT), math.round(em * ICON_REGULAR))
				if ui.tags("bare") {
					ui.next({width = ui.fill(), height = ui.pct(1), text_pad = em * 0.35, font_size = math.round(em * FS_BODY)})
					res := ui.line_edit("###pal_field", &p.field, "Search commands, sessions, agents, models…")
					if p.fresh { ui.set_focus(res.box.key) }
					if res.changed { p.sel = 0; p.reveal = true }
					if res.committed && n > 0 { chosen = hits[p.sel].item }
					if res.cancelled { p.open = false }
				}
				text("n", fmt.tprintf("%d", len(hits)), hex(HEX_FAINT), ui.Style_Mod{font = app.mono, font_size = math.round(em * FS_CAPTION)})
				ui.spacer(ui.px(em * 0.6))
			}
			ui.spacer(ui.px(em * 0.6))
		}
		ui.spacer(ui.px(em * 0.45))
		view_h := f32(clamp(n, 1, PALETTE_ROWS)) * row_h
		ui.next({width = ui.fill(), height = ui.px(view_h)})
		if ui.scroll_y("###pal_list") {
			lb := ui.parent_box()
			if p.reveal {
				top := f32(p.sel) * row_h
				if top < lb.view_target.y { lb.view_target.y = top }
				if top + row_h > lb.view_target.y + view_h { lb.view_target.y = top + row_h - view_h }
				p.reveal = false
			}
			if n == 0 {
				ui.next({width = ui.fill(), height = ui.px(row_h), text_align = .Center})
				if ui.tags("weak") { ui.label("Nothing matches###none") }
			}
			for k in 0 ..< n {
				h := hits[k]
				it := &items[h.item]
				ui.next({width = ui.fill(), height = ui.px(row_h), axis = .X, cross = .Center})
				rb := ui.build_box({.Clickable}, fmt.tprintf("###pal_%d_%s", int(it.kind), label_safe(it.id)))
				sel := k == p.sel
				rd := ui.frame_new(Pal_Row_Draw)
				rd.selected = sel
				rb.custom = proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
					s := ui.scale()
					r := draw.rect_pad(b.rect, -1 * s)
					r.min.x += 6 * s
					r.max.x -= 6 * s
					if (^Pal_Row_Draw)(user).selected {
						draw_well(dc, r, 6 * s, hex(HEX_PAL_SELECTED))
						draw.rect(dc, {{r.min.x + 2 * s, r.min.y + 6 * s}, {r.min.x + 4 * s, r.max.y - 6 * s}}, accent(), 1 * s)
					}
				}
				rb.custom_user = rd
				rs := ui.signal(rb)
				if rs.hovering && moved { p.sel = k }
				if rs.clicked { chosen = h.item }
				if ui.parent(rb) {
					ui.spacer(ui.px(em * 1))
					glyph(it.icon, sel ? accent() : hex(HEX_FAINT), math.round(em * ICON_REGULAR), em * 1.3)
					ui.spacer(ui.px(em * 0.45))
					lit_text(app, it.title, len(it.title), h.ranges, sel ? hex(HEX_BRIGHT) : hex(HEX_TEXT), em)
					ui.spacer(ui.px(em * 0.7))
					if it.detail != "" { text("d", it.detail, hex(HEX_FAINT), ui.Style_Mod{font_size = math.round(em * FS_SMALL)}, ui.fill()) } else { ui.spacer(ui.fill()) }
					ui.spacer(ui.px(em * 0.5))
					if it.toggle && it.on { glyph(ICO_CHECK, accent(), math.round(em * ICON_SMALL)); ui.spacer(ui.px(em * 0.4)) }
					if it.keys != "" {
						text("k", it.keys, hex(HEX_WEAK), ui.Style_Mod{font = app.mono, font_size = math.round(em * FS_CAPTION)})
					}
					ui.spacer(ui.px(em * 1))
				}
			}
		}
		ui.next({width = ui.fill(), height = ui.px(math.round(em * 1.9)), axis = .X, cross = .Center})
		if ui.row(.Center, id = "###pal_foot") {
			ui.spacer(ui.px(em * 1))
			text("h", "> commands    @ sessions    / server    # models    : switches", hex(HEX_FAINT), ui.Style_Mod{font = app.mono, font_size = math.round(em * FS_CAPTION)}, ui.fill())
			text("k", "Enter run", hex(HEX_FAINT), ui.Style_Mod{font = app.mono, font_size = math.round(em * FS_CAPTION)})
			ui.spacer(ui.px(em * 1))
		}
	}
	p.fresh = false
	if chosen >= 0 { palette_choose(app, &items[chosen]) }
}
