// The command palette (Ctrl+K): one field that reaches everything. What the program does (commands.odin), the sessions, the
// agents, the models, the server's own commands and the settings (a switch flips; the others open the settings on themselves).
// A first character narrows it: > commands, @ sessions, / the server's commands, # models, : settings. What was chosen before
// comes first (ui.Choice_Memory: it fades with a half-life of two weeks, palette_choices.txt beside the preferences).
package ocn

import "core:fmt"
import "core:hash"
import "core:math"
import "core:mem/virtual"
import "core:strings"
import prefs_page "gt:prefs_page"
import "gt:config"
import "gt:draw"
import "gt:ui"
import lucide "gt:lucide"
import i18n "gt:i18n"

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
	toggle: bool,     // it is a switch (its state: pal_item_on, read for the rows shown)
}

// The list is made when what it is made of changes (palette_stamp), not at each frame: a palette at rest, the pointer moving
// over it, cost as much as typing in it, every item matched and ranked again and every row found built.
Palette :: struct {
	fresh:   bool,
	field:   ui.Line_Edit,
	reveal:  bool,
	mouse:   Vec2,
	choices: ui.Choice_Memory,   // by "kind:id" (choice_key); palette_choices.txt keeps them (stores_open)
	search:  ui.Fuzzy_Cache,     // the query and the items folded, and the hits of the last stamp (ui.rank's version)
	stamp:   u64,                // what the items and the hits were made from (palette_stamp)
	items:   []Pal_Item,         // (in `arena`)
	hits:    []ui.Rank_Hit,      // (the search's)
	ids:     [dynamic]u64,       // each hit's identity, for its rows (the list measures them by it)
	arena:   virtual.Arena,
	vl:      ui.Virtual_List,    // only the rows in view are built; `vl.sel`: the row chosen
}

Slash :: struct { name, description: string }   // a command of the server (owned)

// What the palette ranks first, read on the chores and merged at a next build (the choices made meanwhile are kept).
palette_open :: proc(app: ^App) {
	ui.choice_memory_open(&app.palette.choices, &app.state, pjoin({config_dir(), "palette_choices.txt"}))
}

@(private = "file")
choice_key :: proc(it: ^Pal_Item) -> string { return fmt.tprintf("%d:%s", int(it.kind), it.id) }

palette_toggle :: proc(app: ^App) {
	p := &app.palette
	if app.cx.open[.Palette] { app.cx.open[.Palette] = false; return }
	app.cx.open[.Palette], p.fresh, p.vl.sel, p.stamp = true, true, 0, 0
	ui.line_edit_set(&p.field, "")
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
		if s := find_session(app, app.chat.id); s != nil { shown = fmt.tprintf(i18n.tr("Session · %s"), ellipsize(s.title != "" ? s.title : i18n.tr("Untitled"), PALETTE_SESSION_CHARS)) }
		for &c in COMMANDS {
			if !command_enabled(app, &c) || c.id == "app.palette" { continue }
			it := Pal_Item{kind = .Command, id = c.id, title = i18n.tr(c.title), detail = i18n.tr(c.group), keys = c.keys, icon = c.icon, cmd = &c, tags = strings.fields(c.tags, context.temp_allocator)}
			if c.group == "Session" && shown != "" { it.detail = shown }
			if c.checked != nil { it.toggle = true }
			append(&items, it)
		}
	}
	if want(only, '@') {
		shown := 0
		for &s in app.sessions {
			if s.parent != "" { continue }
			if !searching && only == 0 && shown == PALETTE_SESSIONS { break }
			append(&items, Pal_Item{kind = .Session, id = s.id, title = s.title != "" ? s.title : i18n.tr("Untitled"), detail = base_name(s.directory), icon = lucide.MESSAGE_SQUARE})
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
				append(&items, Pal_Item{kind = .Agent, id = a.id, title = fmt.tprintf(i18n.tr("Agent: %s"), a.name != "" ? a.name : a.id), detail = a.description, icon = lucide.BOT, toggle = true})
			}
		}
		if want(only, '#') {
			for m, i in app.models {
				append(&items, Pal_Item{kind = .Model, id = fmt.tprintf("%s/%s", m.provider, m.id), title = m.name != "" ? m.name : m.id, detail = m.provider, icon = lucide.CPU, index = i, toggle = true})
			}
		}
		if want(only, ':') {
			// every setting of the settings' pages: a switch flips here, the others open the settings on themselves
			for &e in the_app.cfg_prefs.entries {
				d := e.def
				if d.hidden { continue }
				if d.kind != .Bool {
					append(&items, Pal_Item{kind = .Setting, id = d.name, title = setting_title(&the_app.cfg_prefs, d), detail = ellipsize(i18n.tr(d.description), 60), icon = lucide.SLIDERS_HORIZONTAL, tags = d.tags})
					continue
				}
				append(&items, Pal_Item{kind = .Switch, id = d.name, title = setting_title(&the_app.cfg_prefs, d), detail = ellipsize(i18n.tr(d.description), 60), icon = lucide.SLIDERS_HORIZONTAL, toggle = true, tags = d.tags})
			}
		}
	}
	return items[:]
}

// A switch's state now: read for the rows shown only (a command's `checked` may walk the conversation).
pal_item_on :: proc(app: ^App, it: ^Pal_Item) -> bool {
	if !it.toggle { return false }
	switch it.kind {
	case .Command: return it.cmd != nil && it.cmd.checked != nil && it.cmd.checked(app)
	case .Agent: return it.id == shown_agent(app)
	case .Model:
		if it.index >= len(app.models) { return false }
		shown, provider := shown_model(app)
		m := app.models[it.index]
		return m.id == shown && m.provider == provider
	case .Switch: return config.bool_of(&app.cfg_prefs, it.id)
	case .Session, .Slash, .Setting: return false
	}
	return false
}

// What the list is made from: what is typed, and a count of each thing its items are read from. The same stamp, the same
// list: it is made again only when one of them moves (never 0: ui.rank keeps nothing for 0).
palette_stamp :: proc(app: ^App, text: string) -> u64 {
	h := hash.fnv64a(transmute([]u8)text)
	mix :: proc(h: ^u64, v: u64) { h^ = (h^ ~ v) * 0x100000001b3 }
	mix(&h, app.cx.events_run)
	mix(&h, app.cx.sessions_ver)
	mix(&h, app.cfg_prefs.version)
	mix(&h, u64(len(app.models)))
	mix(&h, u64(uintptr(raw_data(app.models))))
	mix(&h, u64(len(app.agents)))
	mix(&h, u64(uintptr(raw_data(app.agents))))
	mix(&h, u64(len(app.cx.slash)))
	mix(&h, hash.fnv64a(transmute([]u8)app.chat.id))
	mix(&h, app.palette.choices.version)   // (the file read after the start, a choice made: the order moves)
	// (which commands can act now: a command that cannot is not listed)
	for &c, i in COMMANDS { mix(&h, u64(i) << 1 | u64(command_enabled(app, &c))) }
	return h | 1
}

// The items and their hits for what is typed, made again when the stamp moved: the items copied into the palette's arena
// (they outlive the frame), ranked with the stamp as their version.
@(private = "file")
palette_refresh :: proc(app: ^App, text: string) {
	p := &app.palette
	stamp := palette_stamp(app, text)
	if stamp == p.stamp { return }
	p.stamp = stamp
	only: rune
	needle := text
	if len(text) > 0 && strings.contains_rune(">@/#:", rune(text[0])) {
		only = rune(text[0])
		needle = text[1:]
	}
	virtual.arena_free_all(&p.arena)
	a := virtual.arena_allocator(&p.arena)
	made := palette_items(app, only, needle != "")
	items := make([]Pal_Item, len(made), a)
	for it, i in made {
		items[i] = it
		items[i].id, items[i].title, items[i].detail = strings.clone(it.id, a), strings.clone(it.title, a), strings.clone(it.detail, a)
		items[i].keys, items[i].icon = strings.clone(it.keys, a), strings.clone(it.icon, a)
		tags := make([]string, len(it.tags), a)
		for t, k in it.tags { tags[k] = strings.clone(t, a) }
		items[i].tags = tags
	}
	p.items = items
	p.hits = palette_hits(app, items, needle, stamp)
	resize(&p.ids, len(p.hits))
	for h, i in p.hits {
		it := &items[h.index]
		p.ids[i] = hash.fnv64a(transmute([]u8)it.id, u64(it.kind) + 1)
	}
}

// Done when it is chosen. (open_root and command_run wait for the end of the frame; the others only note a value.)
@(private = "file")
palette_choose :: proc(app: ^App, it: ^Pal_Item) {
	ui.choice_note(&app.palette.choices, choice_key(it))
	app.cx.open[.Palette] = false
	switch it.kind {
	case .Command: command_run(app, it.cmd)
	case .Session: open_root(app, it.id)
	case .Agent: choose_agent(app, it.id)
	case .Model: choose_model(app, app.models[it.index])
	case .Slash:
		ui.text_edit_set(&app.composer.area, fmt.tprintf("/%s ", it.id))
		app.composer.focus_next = true
	case .Switch:
		pref_set(app, it.id, pal_item_on(app, it) ? "false" : "true")
	case .Setting:
		// the settings, searching for it: it shows alone, with its control
		settings_open(app)
		prefs_page.show(&app.settings.prefs, &app.cfg_prefs, settings_options(app), it.id)
	}
}

@(private = "file")
Pal_Row_Draw :: struct { selected: bool }

palette_dialog :: proc(app: ^App, em: f32) {
	p := &app.palette
	if !app.cx.open[.Palette] { return }
	palette_refresh(app, ui.line_edit_string(&p.field))
	items, hits := p.items, p.hits
	n := len(hits)
	mouse := ui.mouse_pos()
	moved := abs(mouse.x - p.mouse.x) + abs(mouse.y - p.mouse.y) > 0.5
	p.mouse = mouse
	chosen := -1
	row_h := math.round(em * 2.1)
	vl := &p.vl
	// (resizable, its size kept as the dialogs' are; its top held where a palette is)
	if ui.modal("palette", &app.cx.open[.Palette], dialog_options(app, .Palette, top = PALETTE_TOP)) {
		// (read inside the dialog: an open dialog holds the keys from the code built outside it. The field keeps the keyboard:
		// the list's keys are read here; a click on the list gives it the keys, and it reads them itself)
		if n > 0 {
			sel := vl.sel
			if ui.key_press(.Down) { sel = (sel + 1) % n; p.reveal = true }
			if ui.key_press(.Up) { sel = (sel + n - 1) % n; p.reveal = true }
			page := max(vl.page_rows, 1)   // (the rows the list showed at the last frame, as large as the person made the palette)
			if ui.key_press(.Page_Down) { sel = min(sel + page, n - 1); p.reveal = true }
			if ui.key_press(.Page_Up) { sel = max(sel - page, 0); p.reveal = true }
			vl.sel = sel
		}
		vl.sel = clamp(vl.sel, 0, max(n - 1, 0))
		dialog_backdrop()
		// the search: flush with the palette's top and sides, on a field's darker background, a line under it (the toolkit's
		// strip, as every palette and menu that searches has it: ui.dialog_top_draw), its top corners the dialog's
		ui.next({width = ui.fill(), height = ui.px(math.round(em * 2.8)), axis = .X, cross = .Center, radius = ui.parent_box().radius})
		if ui.row(.Center, id = "###pal_top") {
			ui.parent_box().custom = ui.dialog_top_draw
			ui.spacer(ui.px(em * 0.9))
			glyph(lucide.SEARCH, hex(HEX_FAINT), math.round(em * ICON_REGULAR))
			if ui.tags("bare") {
				ui.next({width = ui.fill(), height = ui.pct(1), text_pad = em * 0.45, font_size = math.round(em * FS_BODY)})
				res := ui.line_edit("###pal_field", &p.field, {placeholder = i18n.tr("Search commands, sessions, agents, models…")})
				if p.fresh { ui.set_focus(res.box.key) }
				if res.changed { vl.sel = 0; p.reveal = true }
				if res.committed && n > 0 { chosen = hits[vl.sel].index }
				if res.cancelled { app.cx.open[.Palette] = false }
			}
			text("n", fmt.tprintf("%d", n), hex(HEX_FAINT), ui.Style_Mod{font = app.mono, font_size = math.round(em * FS_CAPTION)})
			ui.spacer(ui.px(em * 0.9))
		}
		ui.spacer(ui.px(em * 0.45))
		if p.reveal && n > 0 { ui.list_select(&vl.list, vl.sel); p.reveal = false }
		vl.no_typeahead = true   // (letters are the field's)
		ui.next({width = ui.fill(), height = ui.fill()})
		if rows, ok := ui.vlist("###pal_list", vl, p.ids[:], ids_version = p.stamp); ok {
			if n == 0 {
				ui.next({width = ui.fill(), height = ui.px(row_h), text_align = .Center})
				if ui.tags("weak") { ui.label(fmt.tprintf("%s###none", i18n.tr("Nothing matches"))) }
			}
			if vl.activated && n > 0 { chosen = hits[vl.sel].index }
			if vl.cancelled { app.cx.open[.Palette] = false }
			for k in rows.first ..< rows.last {
				h := hits[k]
				it := &items[h.index]
				ui.next({width = ui.fill(), height = ui.px(row_h), axis = .X, cross = .Center})
				rb := ui.build_box({.Clickable}, ui.vlist_row_name(k))   // (its name: the list measures it)
				sel := k == vl.sel
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
				if rs.hovering && moved { vl.sel = k }
				if rs.clicked { chosen = h.index }
				if ui.parent(rb) {
					ui.spacer(ui.px(em * 1))
					glyph(it.icon, sel ? accent() : hex(HEX_FAINT), math.round(em * ICON_REGULAR), em * 1.3)
					ui.spacer(ui.px(em * 0.45))
					lit_text(app, it.title, len(it.title), h.ranges, sel ? hex(HEX_BRIGHT) : hex(HEX_TEXT), em)
					ui.spacer(ui.px(em * 0.7))
					if it.detail != "" { text("d", it.detail, hex(HEX_FAINT), ui.Style_Mod{font_size = math.round(em * FS_SMALL)}, ui.fill()) } else { ui.spacer(ui.fill()) }
					ui.spacer(ui.px(em * 0.5))
					if pal_item_on(app, it) { glyph(lucide.CHECK, accent(), math.round(em * ICON_SMALL)); ui.spacer(ui.px(em * 0.4)) }
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
			text("h", i18n.tr("> commands    @ sessions    / server    # models    : settings"), hex(HEX_FAINT), ui.Style_Mod{font = app.mono, font_size = math.round(em * FS_CAPTION)}, ui.fill())
			text("k", i18n.tr("Enter run"), hex(HEX_FAINT), ui.Style_Mod{font = app.mono, font_size = math.round(em * FS_CAPTION)})
			ui.spacer(ui.px(em * 1))
		}
	}
	p.fresh = false
	if chosen >= 0 { palette_choose(app, &items[chosen]) }
}

// A setting's title as the settings say it ("Notify › Permission", temp memory); the name is still found by what is typed
// (palette_view).
setting_title :: proc(p: ^config.Prefs, d: config.Def) -> string {
	group := d.name[:max(strings.index_byte(d.name, '.'), 0)]
	return fmt.tprintf("%s › %s", i18n.tr(config.group_title(p, group)), i18n.tr(config.title_of(d)))
}

// What the choices' bonus reads (palette_hits): the memory, and now.
@(private = "file")
Choices_Now :: struct { memory: ^ui.Choice_Memory, now_ms: i64 }

// What `needle` finds among the items, best first (temp memory; with a `version`, the search's: ui.rank), as the toolkit's palette
// ranks its commands (ui.palette_match):
// a title whole or at the starts of its words, then its tags, then with a slip or two in each word; what was chosen lately higher.
palette_hits :: proc(app: ^App, items: []Pal_Item, needle: string, version: u64 = 0) -> []ui.Rank_Hit {
	at := Choices_Now{&app.palette.choices, i64(now_epoch_ms())}
	return ui.rank(needle, items, proc(it: ^Pal_Item, _: rawptr) -> ui.Rank_Entry {
		// a switch is found by its name too ("window.system_title"), its title then shown without marks
		return {label = it.title, tags = it.tags, last = it.kind == .Switch || it.kind == .Setting ? it.id : ""}
	}, &at, bonus = proc(it: ^Pal_Item, user: rawptr) -> f64 {
		at := (^Choices_Now)(user)
		return ui.choice_weight(at.memory, choice_key(it), at.now_ms) * USAGE_SCORE
	}, cache = &app.palette.search, version = version)
}
