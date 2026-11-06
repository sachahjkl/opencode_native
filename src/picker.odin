// A picker: a list in a popover over the button that opened it, filtered as one types (subsequence matching, the matched
// characters lit), driven by the keyboard (Up / Down / Page Up / Page Down / Enter / Escape) or the pointer. The model
// and the agent of the composer use it. Items of groups (a model's provider) are under a header that folds while nothing is
// typed, to look through them by hand (Left and Right fold and unfold); typing goes through them all, by how well they match.
package occ

import "core:fmt"
import "core:math"
import "core:slice"
import "core:strings"
import "gt:draw"
import "gt:ui"

Pick_Item :: struct {
	label:   string,   // what is matched and shown
	group:   string,   // matched too, shown faint after it (a model's provider)
	detail:  string,   // shown at the right, not matched (a context size)
	current: bool,
	color:   Color,    // a rail in that colour before the label (none: zero)
}

Picker :: struct {
	open:   bool,
	id:     string,
	anchor: Rect,
	field:  ui.Text_Field,
	sel:    int,       // in the rows shown
	unfolded: map[string]bool,   // the groups open (keys owned); the current item's opens with the picker
	reveal: bool,      // bring the selected row into view (the keyboard moved it, it was opened, the search changed)
	fresh:  bool,      // opened in this frame: focus the field, select the current item
	mouse:  Vec2,
}

PICK_ROWS :: 10

HEX_PICK_SELECTED :: 0x0c0c0cff

picker_open :: proc(p: ^Picker, id: string, anchor: Rect) {
	p.open, p.id, p.anchor, p.fresh = true, id, anchor, true
	p.sel = 0
	ui.field_set(&p.field, "")
}

Hit :: struct { index, score: int, ranges: []ui.Fuzzy_Range }

// A row of the list: an item (`hit` in the hits), or the header of `group` (`hit` -1).
Pick_Row :: struct {
	hit:   int,
	group: string,
	count: int,   // a header: its items
}

picker_unfolded :: proc(p: ^Picker, group: string) -> bool { return group in p.unfolded }

picker_fold :: proc(p: ^Picker, group: string, open: bool) {
	if open == picker_unfolded(p, group) { return }
	if open {
		p.unfolded[strings.clone(group)] = true
	} else {
		key, _ := delete_key(&p.unfolded, group)
		delete(key)
	}
}

// What the list shows. With nothing typed, the items of groups go under their header, in the order they come (a group's items are
// together); else, or with no groups, the hits as they are.
picker_rows :: proc(p: ^Picker, items: []Pick_Item, hits: []Hit, typed: bool) -> []Pick_Row {
	rows := make([dynamic]Pick_Row, 0, len(hits), context.temp_allocator)
	grouped := false
	if !typed { for h in hits { if items[h.index].group != "" { grouped = true; break } } }
	if !grouped {
		for _, k in hits { append(&rows, Pick_Row{hit = k}) }
		return rows[:]
	}
	header := -1
	for h, k in hits {
		g := items[h.index].group
		if header < 0 || rows[header].group != g {
			append(&rows, Pick_Row{hit = -1, group = g})
			header = len(rows) - 1
		}
		rows[header].count += 1
		if picker_unfolded(p, g) { append(&rows, Pick_Row{hit = k, group = g}) }
	}
	return rows[:]
}

// Builds the picker `id` while it is open; returns the index in `items` of the one chosen in this frame (-1: none).
picker :: proc(app: ^App, p: ^Picker, id: string, title: string, items: []Pick_Item, em: f32, align_right := false) -> (chosen: int) {
	chosen = -1
	if !p.open || p.id != id { return }
	needle := ui.field_string(&p.field)
	hits := make([dynamic]Hit, context.temp_allocator)
	for it, i in items {
		hay := it.group != "" ? fmt.tprintf("%s  %s", it.label, it.group) : it.label
		score, ranges, ok := ui.fuzzy_score(needle, hay)
		if ok { append(&hits, Hit{i, score, ranges}) }
	}
	if needle != "" { slice.stable_sort_by(hits[:], proc(a, b: Hit) -> bool { return a.score > b.score }) }
	if p.fresh { for h in hits { if it := items[h.index]; it.current && it.group != "" { picker_fold(p, it.group, true) } } }
	typed := needle != ""
	rows := picker_rows(p, items, hits[:], typed)
	n := len(rows)
	if p.fresh {
		for r, k in rows { if r.hit >= 0 && items[hits[r.hit].index].current { p.sel = k } }
		p.reveal = true
	}
	// the keyboard
	if n > 0 {
		if !typed {   // (nothing typed: these keys have no text to move in)
			at := rows[clamp(p.sel, 0, n - 1)]
			if at.group != "" && ui.key_press(.Right) && !picker_unfolded(p, at.group) {
				picker_fold(p, at.group, true)
				rows = picker_rows(p, items, hits[:], typed)
				n = len(rows)
			}
			if at.group != "" && ui.key_press(.Left) && picker_unfolded(p, at.group) {
				picker_fold(p, at.group, false)
				rows = picker_rows(p, items, hits[:], typed)
				n = len(rows)
				for r, k in rows { if r.hit < 0 && r.group == at.group { p.sel = k } }
				p.reveal = true
			}
		}
		if ui.key_press(.Down) { p.sel = (p.sel + 1) % n; p.reveal = true }
		if ui.key_press(.Up) { p.sel = (p.sel + n - 1) % n; p.reveal = true }
		if ui.key_press(.Page_Down) { p.sel = min(p.sel + PICK_ROWS, n - 1); p.reveal = true }
		if ui.key_press(.Page_Up) { p.sel = max(p.sel - PICK_ROWS, 0); p.reveal = true }
	}
	p.sel = clamp(p.sel, 0, max(n - 1, 0))
	mouse := ui.mouse_pos()
	moved := abs(mouse.x - p.mouse.x) + abs(mouse.y - p.mouse.y) > 0.5
	p.mouse = mouse

	width := math.round(em * 26)
	row_h := math.round(em * 2.0)
	if ui.popover(fmt.tprintf("###pick_%s", id), p.anchor, width, .Above, align_right = align_right) {
		ui.spacer(ui.px(em * 0.5))
		// the search
		ui.next({width = ui.fill(), height = ui.children_sum(), axis = .X, cross = .Center})
		if ui.row(.Center, id = "###ps") {
			ui.spacer(ui.px(em * 0.5))
			ui.next({width = ui.fill(), height = ui.px(math.round(em * FIELD_H_EM)), axis = .X, cross = .Center})
			if well("###psw", .X, radius = 7, focus = 1) {
				ui.spacer(ui.px(em * 0.5))
				glyph(ICO_SEARCH, hex(HEX_FAINT), math.round(em * ICON_SMALL))
				if ui.tags("bare") {
					ui.next({width = ui.fill(), height = ui.pct(1), text_pad = em * 0.3})
					res := ui.line_edit("###pf", &p.field, fmt.tprintf("Search %s", title))
					if p.fresh { ui.set_focus(res.box.key) }
					if res.changed { p.sel = 0; p.reveal = true }
					if res.committed && n > 0 { chosen = picker_take(p, items, hits[:], rows, p.sel) }
					if res.cancelled { p.open = false }
				}
				text("pn", fmt.tprintf("%d", len(hits)), hex(HEX_FAINT), ui.Style_Mod{font = app.mono, font_size = math.round(em * FS_CAPTION)})
				ui.spacer(ui.px(em * 0.6))
			}
			ui.spacer(ui.px(em * 0.5))
		}
		ui.spacer(ui.px(em * 0.4))
		// the rows: a scroll box (smooth wheel scrolling), the selected row kept in view
		view_h := f32(clamp(n, 1, PICK_ROWS)) * row_h
		ui.next({width = ui.fill(), height = ui.px(view_h)})
		if ui.scroll_y("###pl") {
			lb := ui.parent_box()
			if p.reveal {
				top := f32(p.sel) * row_h
				if top < lb.view_target.y { lb.view_target.y = top }
				if top + row_h > lb.view_target.y + view_h { lb.view_target.y = top + row_h - view_h }
				if p.fresh { lb.view_off.y = lb.view_target.y }   // (opened: at once)
				p.reveal = false
			}
			if n == 0 {
				ui.next({width = ui.fill(), height = ui.px(row_h), text_align = .Center})
				if ui.tags("weak") { ui.label("Nothing matches###none") }
			}
			for k in 0 ..< n {
				row := rows[k]
				ui.next({width = ui.fill(), height = ui.px(row_h), axis = .X, cross = .Center})
				rb := ui.build_box({.Clickable}, row.hit < 0 ? fmt.tprintf("###pg_%s", row.group) : fmt.tprintf("###pr%d", hits[row.hit].index))
				sel := k == p.sel
				rd := ui.frame_new(bool)
				rd^ = sel
				rb.custom = proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
					s := ui.scale()
					r := draw.rect_pad(b.rect, -2 * s)
					r.min.x += 4 * s
					r.max.x -= 4 * s
					if (^bool)(user)^ { draw_well(dc, r, 6 * s, hex(HEX_PICK_SELECTED)) } else if b.hot_t > FADE_VISIBLE { draw.rect(dc, r, {1, 1, 1, 0.04 * b.hot_t}, 6 * s) }
				}
				rb.custom_user = rd
				rs := ui.signal(rb)
				if rs.hovering && moved { p.sel = k }
				if rs.clicked { chosen = picker_take(p, items, hits[:], rows, k) }
				if row.hit < 0 {
					if ui.parent(rb) {
						ui.spacer(ui.px(em * 0.6))
						glyph(picker_unfolded(p, row.group) ? ICO_DOWN : ICO_RIGHT, hex(HEX_FAINT), math.round(em * ICON_SMALL))
						ui.spacer(ui.px(em * 0.35))
						text("g", row.group, sel ? hex(HEX_BRIGHT) : hex(HEX_TEXT), ui.Style_Mod{font_size = math.round(em * FS_LABEL)})
						ui.spacer(ui.fill())
						text("n", fmt.tprintf("%d", row.count), hex(HEX_FAINT), ui.Style_Mod{font = app.mono, font_size = math.round(em * FS_CAPTION)})
						ui.spacer(ui.px(em * 0.75))
					}
					continue
				}
				h := hits[row.hit]
				it := items[h.index]
				if ui.parent(rb) {
					ui.spacer(ui.px(em * (row.group != "" ? 1.9 : 0.75)))
					if it.color.a > 0 {
						ui.next({width = ui.px(math.round(em * 0.5)), height = ui.px(math.round(em * 0.9))})
						cb := ui.build_box({}, "###c")
						cd := ui.frame_new(Color)
						cd^ = it.color
						cb.custom = proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
							s := ui.scale()
							c := draw.rect_center(b.rect)
							draw.rect(dc, {{c.x - 1.5 * s, b.rect.min.y}, {c.x + 1.5 * s, b.rect.max.y}}, (^Color)(user)^, 1.5 * s)
						}
						cb.custom_user = cd
						ui.spacer(ui.px(em * 0.3))
					}
					// (under its header the group is said already)
					hay := it.group != "" && row.group == "" ? fmt.tprintf("%s  %s", it.label, it.group) : it.label
					lit_text(app, hay, len(it.label), h.ranges, sel || it.current ? hex(HEX_BRIGHT) : hex(HEX_TEXT), em)
					ui.spacer(ui.fill())
					if it.detail != "" {
						text("d", it.detail, hex(HEX_FAINT), ui.Style_Mod{font = app.mono, font_size = math.round(em * FS_CAPTION)})
						ui.spacer(ui.px(em * 0.5))
					}
					if it.current { glyph(ICO_CHECK, accent(), math.round(em * ICON_SMALL)) } else { ui.spacer(ui.px(math.round(em * 0.75))) }
					ui.spacer(ui.px(em * 0.75))
				}
			}
		}
		ui.spacer(ui.px(em * 0.4))
	}
	if n > 0 && p.open && !p.fresh && ui.key_press(.Return) && chosen < 0 { chosen = picker_take(p, items, hits[:], rows, p.sel) }
	// a press outside closes it (the button that opened it toggles it: its own click closes it)
	if !p.fresh && ui.mouse_pressed(.Left) {
		if r, ok := ui.popover_rect(fmt.tprintf("###pick_%s", id)); ok && !rect_has(r, mouse) && !rect_has(p.anchor, mouse) { p.open = false }
	}
	if ui.key_press(.Escape) { p.open = false }
	if chosen >= 0 { p.open = false }
	p.fresh = false
	return
}

// Row `k` taken: an item is chosen; a header folds or unfolds, and nothing is.
picker_take :: proc(p: ^Picker, items: []Pick_Item, hits: []Hit, rows: []Pick_Row, k: int) -> int {
	if k < 0 || k >= len(rows) { return -1 }
	r := rows[k]
	if r.hit >= 0 { return hits[r.hit].index }
	picker_fold(p, r.group, !picker_unfolded(p, r.group))
	return -1
}

@(private = "file")
rect_has :: proc(r: Rect, p: Vec2) -> bool { return p.x >= r.min.x && p.x < r.max.x && p.y >= r.min.y && p.y < r.max.y }

// `s` in runs: the matched ones lit in the accent on a tint, the rest plain; from byte `split` on (a group), faint.
lit_text :: proc(app: ^App, s: string, split: int, ranges: []ui.Fuzzy_Range, col: Color, em: f32) {
	fs := math.round(em * FS_LABEL)
	at := 0
	k := 0
	seg :: proc(app: ^App, k: ^int, s: string, lit, faint: bool, col: Color, fs: f32) {
		if s == "" { return }
		c := faint ? hex(HEX_FAINT) : col
		m := ui.Style_Mod{font_size = faint ? math.round(fs * FS_NOTE) : fs}
		if lit {
			c = accent()
			m.bg = with_alpha(accent(), 0.16)
			m.radius = 3 * ui.scale()
			m.width = ui.text_size(0)
			m.height = ui.px(math.round(fs * LINE_HEIGHT_RATIO))
			m.fg = c
			m.text_pad = 0
			ui.next(m)
			ui.build_box({.Draw_Text, .Draw_Background}, fmt.tprintf("%s###s%d", label_safe(s), k^))
		} else {
			text(fmt.tprintf("s%d", k^), s, c, m)
		}
		k^ += 1
	}
	emit :: proc(app: ^App, k: ^int, s: string, from, to, split: int, lit: bool, col: Color, fs: f32) {
		// (a run may cross into the group)
		if from < split && to > split {
			seg(app, k, s[from:split], lit, false, col, fs)
			seg(app, k, s[split:to], lit, true, col, fs)
		} else {
			seg(app, k, s[from:to], lit, from >= split, col, fs)
		}
	}
	for r in ranges {
		if r[0] > at { emit(app, &k, s, at, r[0], split, false, col, fs) }
		emit(app, &k, s, r[0], r[1], split, true, col, fs)
		at = r[1]
	}
	if at < len(s) { emit(app, &k, s, at, len(s), split, false, col, fs) }
}
