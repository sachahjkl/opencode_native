// The command palette (Ctrl+K): one field that reaches everything. What the program does (commands.odin), the sessions, the
// agents, the models, the server's own commands and the settings (a switch flips; the others open the settings on themselves).
// A first character narrows it: > commands, @ sessions, / the server's commands, # models, : settings. What was chosen before
// comes first (it fades with a half-life of two weeks, palette_usage.txt beside the preferences).
package ocn

import "core:fmt"
import "core:math"
import "core:strconv"
import "core:strings"
import "gt:config"
import "gt:draw"
import store "gt:store"
import "gt:ui"
import lucide "gt:lucide"

Pal_Kind :: enum u8 { Command, Session, Agent, Model, Slash, Switch, Setting }

Pal_Item :: struct {
	kind:   Pal_Kind,
	id:     string,
	title:  string,
	detail: string,
	keys:   string,
	icon:   string,
	tags:   []string, // other words it is found by (a command's, a setting's)
	cmd:    ^Command,
	index:  int,      // in app.models
	on:     bool,     // a switch's state
	toggle: bool,     // it is a switch
}

Usage :: struct { weight: f64, last_ms: f64 }

Palette :: struct {
	fresh:   bool,
	field:   ui.Text_Field,
	sel:     int,
	reveal:  bool,
	mouse:   Vec2,
	view_h:  f32,                // the list's height at the last frame: a page of Page Up / Down
	usage:   map[string]Usage,   // by "kind:id" (keys owned); palette_usage.txt keeps them (app.stores.palette)
	search:  ui.Fuzzy_Cache,     // the query and the items folded, from one frame to the next: the list is made again each frame
}

Slash :: struct { name, description: string }   // a command of the server (owned)

// What the palette ranks first, from palette_usage.txt as read at the start (stores.odin): kept here as numbers, since the
// list's order reads them at each search.
palette_init :: proc(app: ^App) {
	p := &app.palette
	for e in store.list(&app.stores.palette) {
		weight, _, last := strings.partition(e.value, "\t")
		w, w_ok := strconv.parse_f64(weight)
		t, t_ok := strconv.parse_f64(last)
		if w_ok && t_ok { p.usage[strings.clone(e.key)] = {w, t} }
	}
}

// What choosing this before is worth now.
@(private = "file")
usage_now :: proc(u: Usage, now: f64) -> f64 { return u.weight * math.pow(0.5, (now - u.last_ms) / USAGE_HALF_LIFE_MS) }

@(private = "file")
usage_key :: proc(it: ^Pal_Item) -> string { return fmt.tprintf("%d:%s", int(it.kind), it.id) }

@(private = "file")
usage_note :: proc(app: ^App, it: ^Pal_Item) {
	p := &app.palette
	k := usage_key(it)
	now := now_epoch_ms()
	u, known := p.usage[k]
	if !known { k = strings.clone(k) }
	p.usage[k] = {usage_now(u, now) + 1, now}
	store.set(&app.stores.palette, k, fmt.tprintf("%f\t%f", p.usage[k].weight, now))
}

palette_toggle :: proc(app: ^App) {
	p := &app.palette
	if app.cx.open[.Palette] { app.cx.open[.Palette] = false; return }
	app.cx.open[.Palette], p.fresh, p.sel = true, true, 0
	ui.field_set(&p.field, "")
	if !app.cx.have_slash { request(app, .Slash, "GET", "/api/command") }
}

slash_load :: proc(app: ^App, list: []Slash) {
	slash_forget(app)
	append(&app.cx.slash, ..list)
	app.cx.have_slash = true
}

// The server left: its commands are not the next one's (stream_up reads those).
slash_forget :: proc(app: ^App) {
	for s in app.cx.slash { delete(s.name); delete(s.description) }
	clear(&app.cx.slash)
	app.cx.have_slash = false
}

palette_items :: proc(app: ^App, only: rune, searching: bool) -> []Pal_Item {
	items := make([dynamic]Pal_Item, context.temp_allocator)
	want :: proc(only, mark: rune) -> bool { return only == 0 || only == mark }
	if want(only, '>') {
		// (what a session's command acts on: the session shown, named beside it; "Fork the session" said which one)
		shown := ""
		if s := find_session(app, app.chat.id); s != nil { shown = fmt.tprintf("Session · %s", ellipsize(s.title != "" ? s.title : "Untitled", PALETTE_SESSION_CHARS)) }
		for &c in COMMANDS {
			if !command_enabled(app, &c) || c.id == "app.palette" { continue }
			it := Pal_Item{kind = .Command, id = c.id, title = c.title, detail = c.group, keys = c.keys, icon = c.icon, cmd = &c, tags = strings.fields(c.tags, context.temp_allocator)}
			if c.group == "Session" && shown != "" { it.detail = shown }
			if c.checked != nil { it.toggle, it.on = true, c.checked(app) }
			append(&items, it)
		}
	}
	if want(only, '@') {
		shown := 0
		for &s in app.sessions {
			if s.parent != "" { continue }
			if !searching && only == 0 && shown == PALETTE_SESSIONS { break }
			append(&items, Pal_Item{kind = .Session, id = s.id, title = s.title != "" ? s.title : "Untitled", detail = base_name(s.directory), icon = lucide.MESSAGE_SQUARE})
			shown += 1
		}
	}
	if searching || only != 0 {
		if want(only, '/') {
			for s in app.cx.slash { append(&items, Pal_Item{kind = .Slash, id = s.name, title = fmt.tprintf("/%s", s.name), detail = s.description, icon = lucide.SQUARE_TERMINAL}) }
		}
		if want(only, '@') {
			for a in app.agents {
				if a.mode == "subagent" { continue }
				append(&items, Pal_Item{kind = .Agent, id = a.id, title = fmt.tprintf("Agent: %s", a.name != "" ? a.name : a.id), detail = a.description, icon = lucide.BOT, toggle = true, on = a.id == shown_agent(app)})
			}
		}
		if want(only, '#') {
			shown, shown_provider := shown_model(app)
			for m, i in app.models {
				append(&items, Pal_Item{kind = .Model, id = fmt.tprintf("%s/%s", m.provider, m.id), title = m.name != "" ? m.name : m.id, detail = m.provider, icon = lucide.CPU, index = i, toggle = true, on = m.id == shown && m.provider == shown_provider})
			}
		}
		if want(only, ':') {
			// every setting of the settings' pages: a switch flips here, the others open the settings on themselves
			for d in PREF_DEFS {
				if d.hidden { continue }
				if d.kind != .Bool {
					append(&items, Pal_Item{kind = .Setting, id = d.name, title = setting_title(d), detail = ellipsize(d.description, 60), icon = lucide.SLIDERS_HORIZONTAL, tags = d.tags})
					continue
				}
				append(&items, Pal_Item{kind = .Switch, id = d.name, title = setting_title(d), detail = ellipsize(d.description, 60), icon = lucide.SLIDERS_HORIZONTAL, toggle = true, on = config.bool_of(&app.cfg_prefs, d.name), tags = d.tags})
			}
		}
	}
	return items[:]
}

// Done when it is chosen. (open_root and command_run wait for the end of the frame; the others only note a value.)
@(private = "file")
palette_choose :: proc(app: ^App, it: ^Pal_Item) {
	usage_note(app, it)
	app.cx.open[.Palette] = false
	switch it.kind {
	case .Command: command_run(app, it.cmd)
	case .Session: open_root(app, it.id)
	case .Agent: choose_agent(app, it.id)
	case .Model: choose_model(app, app.models[it.index])
	case .Slash:
		ui.area_set(&app.composer.area, fmt.tprintf("/%s ", it.id))
		app.composer.focus_next = true
	case .Switch:
		pref_set(app, it.id, it.on ? "false" : "true")
	case .Setting:
		// the settings, searching for it: it shows alone, with its control
		settings_open(app)
		ui.field_set(&app.settings.query, setting_query(it.id))
	}
}

@(private = "file")
Pal_Row_Draw :: struct { selected: bool }

palette_dialog :: proc(app: ^App, em: f32) {
	p := &app.palette
	if !app.cx.open[.Palette] { return }
	text_in := ui.field_string(&p.field)
	only: rune
	needle := text_in
	if len(text_in) > 0 && strings.contains_rune(">@/#:", rune(text_in[0])) {
		only = rune(text_in[0])
		needle = text_in[1:]
	}
	items := palette_items(app, only, needle != "")
	hits := palette_hits(app, items, needle)
	n := min(len(hits), PALETTE_ROWS_MAX)
	mouse := ui.mouse_pos()
	moved := abs(mouse.x - p.mouse.x) + abs(mouse.y - p.mouse.y) > 0.5
	p.mouse = mouse
	chosen := -1
	row_h := math.round(em * 2.1)
	// (resizable, its size kept as the dialogs' are; its top held where a palette is)
	if ui.modal_sized("palette", DIALOG_PREFERRED_EM[.Palette] * em, &app.cx.dialogs[.Palette], &app.cx.open[.Palette], DIALOG_MIN_EM[.Palette] * em, top = PALETTE_TOP) {
		// (read inside the dialog: an open dialog holds the keys from the code built outside it)
		if n > 0 {
			if ui.key_press(.Down) { p.sel = (p.sel + 1) % n; p.reveal = true }
			if ui.key_press(.Up) { p.sel = (p.sel + n - 1) % n; p.reveal = true }
			// (a page: the rows the list showed at the last frame, as large as the person made the palette)
			page := max(int(p.view_h / math.round(em * 2.1)), 1)
			if ui.key_press(.Page_Down) { p.sel = min(p.sel + page, n - 1); p.reveal = true }
			if ui.key_press(.Page_Up) { p.sel = max(p.sel - page, 0); p.reveal = true }
		}
		p.sel = clamp(p.sel, 0, max(n - 1, 0))
		dialog_backdrop()
		// the search: flush with the palette's top and sides, no frame of its own; a line under it parts it from the list
		ui.next({width = ui.fill(), height = ui.px(math.round(em * 2.8)), axis = .X, cross = .Center})
		if ui.row(.Center, id = "###pal_top") {
			ui.spacer(ui.px(em * 0.9))
			glyph(lucide.SEARCH, hex(HEX_FAINT), math.round(em * ICON_REGULAR))
			if ui.tags("bare") {
				ui.next({width = ui.fill(), height = ui.pct(1), text_pad = em * 0.45, font_size = math.round(em * FS_BODY)})
				res := ui.line_edit("###pal_field", &p.field, "Search commands, sessions, agents, models…")
				if p.fresh { ui.set_focus(res.box.key) }
				if res.changed { p.sel = 0; p.reveal = true }
				if res.committed && n > 0 { chosen = hits[p.sel].index }
				if res.cancelled { app.cx.open[.Palette] = false }
			}
			text("n", fmt.tprintf("%d", len(hits)), hex(HEX_FAINT), ui.Style_Mod{font = app.mono, font_size = math.round(em * FS_CAPTION)})
			ui.spacer(ui.px(em * 0.9))
		}
		edge_line("###pal_rule")
		ui.spacer(ui.px(em * 0.45))
		ui.next({width = ui.fill(), height = ui.fill()})
		if ui.scroll_y("###pal_list") {
			lb := ui.parent_box()
			// (its height: the last frame's, as the dialog's size and the window make it)
			view_h := lb.rect.max.y - lb.rect.min.y
			if view_h < row_h { view_h = f32(PALETTE_ROWS) * row_h }
			p.view_h = view_h
			if p.reveal {
				top := f32(p.sel) * row_h
				lb.view_target.y = ui.view_reveal_offset(lb.view_target.y, top, top + row_h, view_h)
				p.reveal = false
			}
			if n == 0 {
				ui.next({width = ui.fill(), height = ui.px(row_h), text_align = .Center})
				if ui.tags("weak") { ui.label("Nothing matches###none") }
			}
			for k in 0 ..< n {
				h := hits[k]
				it := &items[h.index]
				ui.next({width = ui.fill(), height = ui.px(row_h), axis = .X, cross = .Center})
				rb := ui.build_box({.Clickable}, fmt.tprintf("###pal_%d_%s", int(it.kind), label_safe(it.id)))
				sel := k == p.sel
				rd := ui.frame_new(Pal_Row_Draw)
				rd.selected = sel
				rb.custom = proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
					s := ui.scale()
					r := b.rect   // (flush: a highlight runs from one edge of the list to the other)
					if (^Pal_Row_Draw)(user).selected {
						draw_well(dc, r, 0, hex(HEX_PAL_SELECTED))   // (square: a row)
						draw.rect(dc, {{r.min.x + 2 * s, r.min.y + 6 * s}, {r.min.x + 4 * s, r.max.y - 6 * s}}, accent(), 1 * s)
					}
				}
				rb.custom_user = rd
				rs := ui.signal(rb)
				if rs.hovering && moved { p.sel = k }
				if rs.clicked { chosen = h.index }
				if ui.parent(rb) {
					ui.spacer(ui.px(em * 1))
					glyph(it.icon, sel ? accent() : hex(HEX_FAINT), math.round(em * ICON_REGULAR), em * 1.3)
					ui.spacer(ui.px(em * 0.45))
					lit_text(app, it.title, len(it.title), h.ranges, sel ? hex(HEX_BRIGHT) : hex(HEX_TEXT), em)
					ui.spacer(ui.px(em * 0.7))
					if it.detail != "" { text("d", it.detail, hex(HEX_FAINT), ui.Style_Mod{font_size = math.round(em * FS_SMALL)}, ui.fill()) } else { ui.spacer(ui.fill()) }
					ui.spacer(ui.px(em * 0.5))
					if it.toggle && it.on { glyph(lucide.CHECK, accent(), math.round(em * ICON_SMALL)); ui.spacer(ui.px(em * 0.4)) }
					if it.keys != "" {
						text("k", it.keys, hex(HEX_WEAK), ui.Style_Mod{font = app.mono, font_size = math.round(em * FS_CAPTION)})
					}
					ui.spacer(ui.px(em * 1))
				}
			}
		}
		edge_line("###pal_foot_rule")   // (as the field's from the results: the keys apart from the list)
		ui.next({width = ui.fill(), height = ui.px(math.round(em * 1.9)), axis = .X, cross = .Center})
		if ui.row(.Center, id = "###pal_foot") {
			ui.spacer(ui.px(em * 1))
			text("h", "> commands    @ sessions    / server    # models    : settings", hex(HEX_FAINT), ui.Style_Mod{font = app.mono, font_size = math.round(em * FS_CAPTION)}, ui.fill())
			text("k", "Enter run", hex(HEX_FAINT), ui.Style_Mod{font = app.mono, font_size = math.round(em * FS_CAPTION)})
			ui.spacer(ui.px(em * 1))
		}
	}
	p.fresh = false
	if chosen >= 0 { palette_choose(app, &items[chosen]) }
}

// A setting's title as the settings say it ("Notify › Permission", temp memory); the name is still found by what is typed
// (palette_view).
setting_title :: proc(d: config.Def) -> string {
	group := d.category
	if group == "" { group = d.name[:max(strings.index_byte(d.name, '.'), 0)] }
	return fmt.tprintf("%s › %s", config.category_title(group), config.title_of(d))
}

// What the settings' search is given to show one setting: its title (the search reads the titles and the descriptions).
setting_query :: proc(name: string) -> string {
	for d in PREF_DEFS { if d.name == name { return config.title_of(d) } }
	return name
}

// What the usage bonus reads (palette_hits): the counts, and now.
@(private = "file")
Usage_Now :: struct { palette: ^Palette, now: f64 }

// What `needle` finds among the items, best first (temp memory), as the toolkit's palette ranks its commands (ui.palette_match):
// a title whole or at the starts of its words, then its tags, then with a slip or two in each word; what was chosen lately higher.
palette_hits :: proc(app: ^App, items: []Pal_Item, needle: string) -> []ui.Rank_Hit {
	at := Usage_Now{&app.palette, now_epoch_ms()}
	return ui.rank(needle, items, proc(it: ^Pal_Item, _: rawptr) -> ui.Rank_Entry {
		// a switch is found by its name too ("appearance.system_title"), its title then shown without marks
		return {label = it.title, tags = it.tags, last = it.kind == .Switch || it.kind == .Setting ? it.id : ""}
	}, &at, bonus = proc(it: ^Pal_Item, user: rawptr) -> f64 {
		at := (^Usage_Now)(user)
		u, known := at.palette.usage[usage_key(it)]
		return known ? usage_now(u, at.now) * USAGE_SCORE : 0
	}, cache = &app.palette.search)
}
