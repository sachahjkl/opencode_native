// Markdown of the replies, the subset models write: headings, paragraphs, lists, quotes, rules, tables, fenced code,
// and inline **bold**, *italic*, `code`, ~~strike~~, [links](url). Each block is a rich_paragraph (selectable).
package occ

import "core:fmt"
import "core:math"
import "core:strings"
import "gt:draw"
import "gt:platform"
import "gt:ui"
import lucide "gt:lucide"

// Odd 64-bit constants that spread the bits of what they multiply.
HASH_MIX_A :: 0x9e3779b97f4a7c15
HASH_MIX_B :: 0xc2b2ae3d27d4eb4f

HEADING_LEVEL_MAX    :: 6
TABLE_COL_MAX_EM     :: 28    // a table's column is no wider (its words wrap past it); a table wider than its place scrolls sideways
TABLE_FADE_EM        :: 2     // the fade at a side of a table that scrolls, where it hides more
TABLE_BAR_PX         :: 4     // the bar under a table that scrolls sideways, at a scale of 1
HEX_INLINE_CODE      :: 0xe5c07bff
HEX_CODE_TEXT        :: 0xd4d4d4ff
HEX_TABLE_WELL       :: 0x090909ff
TABLE_STRIPE_ALPHA   :: 0.045   // every other row: the theme's text, this faint

// A name for a piece of the source (where its bytes lie, how far, at which size): the rich layout cache finds the block by
// it instead of hashing its text at every frame. A message's text only grows: a block keeps its bytes until they move,
// and then it is a new name (the toolkit mixes in the paragraph's box, so two messages never share one).
src_version :: proc(first, last: string, size: f32) -> u64 {
	if len(first) == 0 && len(last) == 0 { return 0 }
	a := u64(uintptr(raw_data(first)))
	b := u64(uintptr(raw_data(last))) + u64(len(last))
	return ((a * HASH_MIX_A) ~ (b * HASH_MIX_B) ~ u64(transmute(u32)size)) | 1
}

// Inline Markdown of one block into runs (temp memory).
// `code_size` (not 0): inline code at that size, when the text around it is at another.
inline_runs :: proc(text: string, base: ui.Rich_Style, out: ^[dynamic]ui.Rich_Run, code_size: f32 = 0) {
	st := base
	i, start := 0, 0
	flush :: proc(out: ^[dynamic]ui.Rich_Run, s: string, st: ui.Rich_Style) { if s != "" { append(out, ui.Rich_Run{text = s, style = st}) } }
	for i < len(text) {
		c := text[i]
		switch {
		case ui.web_address_len(text, i) > 0:   // a bare web address: a link (before the emphasis marks: "_" is common in them)
			n := ui.web_address_len(text, i)
			flush(out, text[start:i], st)
			l := st
			l.link, l.underline, l.color = text[i:i + n], true, {}
			flush(out, text[i:i + n], l)
			i += n; start = i
		case strings.has_prefix(text[i:], "**") || strings.has_prefix(text[i:], "__"):
			flush(out, text[start:i], st); st.bold = !st.bold; i += 2; start = i
		case strings.has_prefix(text[i:], "~~"):
			flush(out, text[start:i], st); st.strike = !st.strike; i += 2; start = i
		case c == '*' || (c == '_' && (i == 0 || !is_word(text[i - 1]) || st.italic) && (st.italic || (i + 1 < len(text) && text[i + 1] != ' '))):
			// (a lone '*' between spaces is a multiplication, not emphasis)
			if c == '*' && i + 1 < len(text) && text[i + 1] == ' ' && !st.italic { i += 1; continue }
			flush(out, text[start:i], st); st.italic = !st.italic; i += 1; start = i
		case c == '`':
			e := strings.index_byte(text[i + 1:], '`')
			if e < 0 { i += 1; continue }
			flush(out, text[start:i], st)
			cs := st
			cs.code = true
			if code_size > 0 { cs.size = code_size }
			cs.color = hex(HEX_INLINE_CODE)
			if inner := text[i + 1:i + 1 + e]; ui.web_address_len(inner, 0) == len(inner) {   // `https://...`: a link still
				cs.link, cs.underline, cs.color = inner, true, {}
			}
			flush(out, text[i + 1:i + 1 + e], cs)
			i += e + 2; start = i
		case c == '[':
			close_b := strings.index(text[i:], "](")
			close_p := close_b >= 0 ? strings.index_byte(text[i + close_b:], ')') : -1
			if close_b < 0 || close_p < 0 { i += 1; continue }
			flush(out, text[start:i], st)
			l := st
			l.link = text[i + close_b + 2:i + close_b + close_p]
			l.underline, l.color = true, {}   // (the theme's link colour)
			flush(out, text[i + 1:i + close_b], l)
			i += close_b + close_p + 1; start = i
		case:
			i += 1
		}
	}
	flush(out, text[start:], st)
}

@(private = "file")
is_word :: proc(c: u8) -> bool { return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') }

@(private = "file")
Block_Kind :: enum u8 { Para, Heading, Bullet, Number, Quote, Rule, Code, Table }

@(private = "file")
Block :: struct {
	kind:   Block_Kind,
	level:  int,      // heading level, list indent
	marker: string,   // "3." of a numbered item
	lang:   string,
	lines:  [dynamic]string,
}

@(private = "file")
list_item :: proc(l: string) -> (indent: int, marker: string, rest: string, ok: bool) {
	t := strings.trim_left(l, " \t")
	indent = (len(l) - len(t)) / 2
	if len(t) >= 2 && (t[0] == '-' || t[0] == '*' || t[0] == '+') && t[1] == ' ' { return indent, "•", t[2:], true }
	j := 0
	for j < len(t) && t[j] >= '0' && t[j] <= '9' { j += 1 }
	if j > 0 && j + 1 < len(t) && (t[j] == '.' || t[j] == ')') && t[j + 1] == ' ' { return indent, t[:j + 1], t[j + 2:], true }
	return
}

@(private = "file")
parse_blocks :: proc(src: string) -> [dynamic]Block {
	blocks := make([dynamic]Block, context.temp_allocator)
	cur: ^Block
	text := src
	in_code := false
	fence := ""
	for raw in strings.split_lines_iterator(&text) {
		line := strings.trim_right(raw, "\r")
		t := strings.trim_space(line)
		if in_code {
			if strings.has_prefix(t, fence) && strings.trim_left(t, "`~") == "" { in_code = false; cur = nil; continue }
			append(&cur.lines, line)
			continue
		}
		if strings.has_prefix(t, "```") || strings.has_prefix(t, "~~~") {
			n := 0
			for n < len(t) && t[n] == t[0] { n += 1 }
			fence = t[:n]
			append(&blocks, Block{kind = .Code, lang = strings.trim_space(t[n:]), lines = make([dynamic]string, context.temp_allocator)})
			cur = &blocks[len(blocks) - 1]
			in_code = true
			continue
		}
		if t == "" { cur = nil; continue }
		if t == "---" || t == "***" || t == "___" {
			append(&blocks, Block{kind = .Rule})
			cur = nil
			continue
		}
		if t[0] == '#' {
			lvl := 0
			for lvl < len(t) && t[lvl] == '#' { lvl += 1 }
			if lvl <= HEADING_LEVEL_MAX && lvl < len(t) && t[lvl] == ' ' {
				append(&blocks, Block{kind = .Heading, level = lvl, lines = make([dynamic]string, context.temp_allocator)})
				append(&blocks[len(blocks) - 1].lines, strings.trim_space(t[lvl:]))
				cur = nil
				continue
			}
		}
		if t[0] == '|' {
			if cur == nil || cur.kind != .Table {
				append(&blocks, Block{kind = .Table, lines = make([dynamic]string, context.temp_allocator)})
				cur = &blocks[len(blocks) - 1]
			}
			append(&cur.lines, t)
			continue
		}
		if t[0] == '>' {
			q := strings.trim_left(t[1:], " ")
			if cur == nil || cur.kind != .Quote {
				append(&blocks, Block{kind = .Quote, lines = make([dynamic]string, context.temp_allocator)})
				cur = &blocks[len(blocks) - 1]
			}
			append(&cur.lines, q)
			continue
		}
		if indent, marker, rest, ok := list_item(line); ok {
			append(&blocks, Block{kind = marker == "•" ? .Bullet : .Number, level = indent, marker = marker, lines = make([dynamic]string, context.temp_allocator)})
			cur = &blocks[len(blocks) - 1]
			append(&cur.lines, rest)
			continue
		}
		// continuation of a paragraph or a list item, or a new paragraph
		if cur != nil && (cur.kind == .Para || cur.kind == .Bullet || cur.kind == .Number || cur.kind == .Quote) {
			append(&cur.lines, t)
			continue
		}
		append(&blocks, Block{kind = .Para, lines = make([dynamic]string, context.temp_allocator)})
		cur = &blocks[len(blocks) - 1]
		append(&cur.lines, t)
	}
	return blocks
}

// The lines of a block joined as one paragraph (a line break where the source ends a line with two spaces or "\").
@(private = "file")
joined :: proc(lines: []string) -> string {
	b := strings.builder_make(context.temp_allocator)
	for l, i in lines {
		if i > 0 {
			prev := lines[i - 1]
			if strings.has_suffix(prev, "  ") || strings.has_suffix(prev, "\\") { strings.write_byte(&b, '\n') } else { strings.write_byte(&b, ' ') }
		}
		strings.write_string(&b, strings.trim_right(strings.trim_suffix(l, "\\"), " "))
	}
	return strings.to_string(b)
}

// Shows `src` as Markdown in the current column (full width). `id` keys its blocks.
markdown :: proc(id: string, src: string, color: Color, size: f32 = 0) {
	em := ui.font_size()
	fs := size > 0 ? size : em
	// the answers' own face and size; every line the same height, inline code or not; tables stay in the interface's face
	prose_fs := math.round(fs * the_app.prose_scale)
	line_h := math.round(prose_fs * PROSE_LINE_RATIO)
	blocks := parse_blocks(src)
	for &bl, n in blocks {
		bid := fmt.tprintf("###%s_b%d", id, n)
		if n > 0 { ui.spacer(ui.px(math.round(em * (bl.kind == .Bullet || bl.kind == .Number ? 0.25 : 0.6)))) }
		switch bl.kind {
		case .Rule:
			groove(bid)
		case .Code:
			code_block(bid, bl.lang, strings.join(bl.lines[:], "\n", context.temp_allocator), version = len(bl.lines) > 0 ? src_version(bl.lines[0], bl.lines[len(bl.lines) - 1], em) : 0)
		case .Table:
			table_block(bid, bl.lines[:], color, fs)
		case .Heading:
			runs := make([dynamic]ui.Rich_Run, context.temp_allocator)
			k := [HEADING_LEVEL_MAX + 1]f32{1, 1.45, 1.25, 1.1, 1, 1, 1}
			inline_runs(bl.lines[0], {bold = true, color = bl.level <= 2 ? hex(HEX_BRIGHT) : color}, &runs)
			if bl.level >= 2 { ui.spacer(ui.px(em * 0.3)) }
			ui.next({width = ui.fill(), font = the_app.prose, font_size = math.round(prose_fs * k[bl.level]), flags = {.Selectable}})
			res := ui.rich_paragraph(bid, runs[:], version = src_version(bl.lines[0], bl.lines[0], fs))
			link_clicked(res)
		case .Para, .Quote:
			runs := make([dynamic]ui.Rich_Run, context.temp_allocator)
			inline_runs(joined(bl.lines[:]), {color = bl.kind == .Quote ? hex(HEX_WEAK) : color}, &runs, code_size = fs)
			if bl.kind == .Quote {
				ui.next({width = ui.fill(), height = ui.children_sum(), axis = .X})
				if rail_row(fmt.tprintf("%s_q", bid), with_alpha(accent(), 0.6)) {
					ui.spacer(ui.px(em * 0.9))
					ui.next({width = ui.fill(), font = the_app.prose, font_size = prose_fs, flags = {.Selectable}})
					link_clicked(ui.rich_paragraph(bid, runs[:], version = src_version(bl.lines[0], bl.lines[len(bl.lines) - 1], fs), line_height = line_h))
				}
			} else {
				ui.next({width = ui.fill(), font = the_app.prose, font_size = prose_fs, flags = {.Selectable}})
				link_clicked(ui.rich_paragraph(bid, runs[:], version = src_version(bl.lines[0], bl.lines[len(bl.lines) - 1], fs), line_height = line_h))
			}
		case .Bullet, .Number:
			ui.next({width = ui.fill(), height = ui.children_sum(), axis = .X})
			if ui.row(id = fmt.tprintf("%s_li", bid)) {
				ui.spacer(ui.px(em * (0.3 + 1.2 * f32(bl.level))))
				mk := bl.marker
				if bl.kind == .Bullet { mk = bl.level == 0 ? "•" : "◦" }
				ui.next({width = ui.px(em * 1.3), height = ui.px(line_h), fg = accent(), font_size = fs, text_pad = 0})
				ui.build_box({.Draw_Text}, fmt.tprintf("%s###mk", mk))
				runs := make([dynamic]ui.Rich_Run, context.temp_allocator)
				inline_runs(joined(bl.lines[:]), {color = color}, &runs, code_size = fs)
				ui.next({width = ui.fill(), font = the_app.prose, font_size = prose_fs, flags = {.Selectable}})
				link_clicked(ui.rich_paragraph(bid, runs[:], version = src_version(bl.lines[0], bl.lines[len(bl.lines) - 1], fs), line_height = line_h))
			}
		}
	}
}

link_clicked :: proc(res: ui.Rich_Result) {
	if res.link_clicked >= 0 { link_open(res.link) }
}

// Links come from the model or the server, and the system runs what it is handed (a program, a batch file, a share): only
// what a browser or a mail client is for.
link_allowed :: proc(url: string) -> bool {
	u := strings.to_lower(url, context.temp_allocator)
	return strings.has_prefix(u, "http://") || strings.has_prefix(u, "https://") || strings.has_prefix(u, "mailto:")
}

link_open :: proc(url: string) {
	if link_allowed(url) {
		// (what an agent serves here is what the panel is for)
		if strings.contains(url, "://localhost") || strings.contains(url, "://127.0.0.1") { preview_open(the_app, url) } else { platform.open_url(url) }
	} else { ui.toast(.Warn, "Link not opened: %s", ellipsize(url, TOAST_TITLE_CHARS)) }
}

// The cells of a table row: `| a | b |` -> {"a", "b"}.
@(private = "file")
table_cells :: proc(line: string) -> []string {
	t := strings.trim_space(line)
	t = strings.trim_prefix(t, "|")
	t = strings.trim_suffix(t, "|")
	cells := strings.split(t, "|", context.temp_allocator)
	for &c in cells { c = strings.trim_space(c) }
	return cells
}

// A Markdown table as a grid: the header row bold, each column aligned as its separator says (":--", ":-:", "--:"), alternate
// rows shaded. Its columns: each as wide as its widest cell on one line when the table fits; else each keeps at least its longest
// word, the columns that lack the least are given all they lack first (a short one stays on one line), and the long ones share
// the rest as they lack it: they are the ones that wrap.
table_block :: proc(id: string, lines: []string, color: Color, fs: f32) {
	em := ui.font_size()
	rows := make([dynamic][]string, context.temp_allocator)
	aligns: []ui.Text_Align
	for l in lines {
		cells := table_cells(l)
		sep := len(cells) > 0
		for c in cells { if strings.trim(c, ":- ") != "" || c == "" { sep = false } }
		if sep && len(rows) == 1 {
			aligns = make([]ui.Text_Align, len(cells), context.temp_allocator)
			for c, i in cells {
				switch {
				case strings.has_prefix(c, ":") && strings.has_suffix(c, ":"): aligns[i] = .Center
				case strings.has_suffix(c, ":"):                               aligns[i] = .Right
				}
			}
			continue
		}
		append(&rows, cells)
	}
	if len(rows) == 0 { return }
	ncol := 0
	for r in rows { ncol = max(ncol, len(r)) }
	// each column's widest cell on one line, and its longest word: as its runs are laid out (bold, code and all)
	pad := math.round(em * 0.7)
	widths := make([]f32, ncol, context.temp_allocator)
	least := make([]f32, ncol, context.temp_allocator)
	cell_size := math.round(fs * FS_LABEL)
	cells := make([][][dynamic]ui.Rich_Run, len(rows), context.temp_allocator)
	st := &the_app.state
	rc := ui.Rich_Context{fonts = st.fonts, base_font = the_app.font, base_size = cell_size, mono = st.mono_font, faces = &st.rich_faces}
	for r, ri in rows {
		cells[ri] = make([][dynamic]ui.Rich_Run, ncol, context.temp_allocator)
		for ci in 0 ..< ncol {
			c := ci < len(r) ? r[ci] : ""
			cells[ri][ci] = make([dynamic]ui.Rich_Run, context.temp_allocator)
			inline_runs(c, {bold = ri == 0, color = ri == 0 ? hex(HEX_BRIGHT) : color}, &cells[ri][ci])
			l := ui.rich_layout(rc, cells[ri][ci][:], TABLE_MEASURE_W, allocator = context.temp_allocator)
			widths[ci] = max(widths[ci], math.ceil(l.size.x) + 2 * pad)
			for run in cells[ri][ci] {
				face, size := ui.rich_face(rc, run.style)
				for word in strings.split(run.text, " ", context.temp_allocator) {
					least[ci] = max(least[ci], math.ceil(ui.text_width(face, size, word) + (run.style.code ? em * TABLE_CODE_SLACK_EM : 0)) + 2 * pad)
				}
			}
		}
	}
	// each column as wide as its widest cell on one line, no wider than TABLE_COL_MAX_EM (past that its words wrap in it); never
	// squeezed under that: a table wider than its place scrolls sideways in its frame
	col_max := math.round(em * TABLE_COL_MAX_EM)
	total: f32
	for ci in 0 ..< ncol {
		widths[ci] = min(widths[ci], max(col_max, least[ci] < col_max ? least[ci] : col_max))
		total += widths[ci]
	}
	room := ui.parent_box().rect.max.x - ui.parent_box().rect.min.x   // (the place it had in the last layout: none yet, it fits)
	ui.next({width = ui.fill(), height = ui.children_sum(), axis = .Y})
	// (every other row tinted with the theme's text, faintly: light on a dark theme, dark on a light one; the header is told by
	// its words and its rule. The rows stand off the well's edge, rounded a little: their tint does not cover its rim.)
	stripe := with_alpha(hex(HEX_TEXT), TABLE_STRIPE_ALPHA)
	edge := 2 * px1()
	overflow := room > 0 && total > room - 2 * edge
	hs: ^ui.Box
	if well(id, radius = 6, base = HEX_TABLE_WELL) {
		// under the pointer, a copy button in its corner: the table as HTML (a plain grid, any program's own style) and as its
		// Markdown text
		table_box := ui.parent_box()
		over := draw.rect_contains(table_box.rect, ui.mouse_pos())   // (its cells are no buttons: the pointer anywhere on it)
		if tw := table_box.rect.max.x - table_box.rect.min.x; tw > 1 && over {
			sz := math.round(em * 1.6)
			m := math.round(em * 0.25)
			ui.next({fixed_x = tw - sz - m, fixed_y = m, width = ui.px(sz), height = ui.px(sz), axis = .X})
			if ui.row(id = "###tcopy") {
				ui.a11y({role = .Button, name = "Copy the table"})
				sig := glyph_button("###copy", lucide.COPY, sz)
				if sig.clicked {
					html := table_html(cells, aligns)
					_ = platform.clipboard_set(the_app.win, {text = strings.join(lines, "\n", context.temp_allocator), html = html})
					ui.toast(.Good, "Table copied")
				}
				if ui.hovered_for(sig, TOOLTIP_DELAY_S) { if ui.tooltip() { ui.tooltip_text("Copy the table (pastes as a table)") } }
			}
		}
		ui.spacer(ui.px(em * 0.3))
		ui.next({width = ui.fill(), height = ui.children_sum(), axis = .X})
		if ui.row(id = "###in") {
		ui.spacer(ui.px(edge))
		// (sideways: the rows in a box that scrolls; a fade on the side that hides more, and a bar under them, say so)
		hs = table_scroller(id, overflow, total, em)
		ui.next({width = overflow ? ui.px(total, 1) : ui.fill(), height = ui.children_sum(), axis = .Y})
		if ui.column(id = "###rows") {
		for r, ri in rows {
			ui.next({width = ui.fill(), height = ui.children_sum(), axis = .X, bg = ri > 0 && ri % 2 == 0 ? stripe : {}, radius = math.round(em * 0.25)})
			if ui.row(flags = {.Draw_Background}, id = fmt.tprintf("###tr%d", ri)) {
				for ci in 0 ..< ncol {
					c := ci < len(r) ? r[ci] : ""
					runs := cells[ri][ci]
					al := ci < len(aligns) ? aligns[ci] : ui.Text_Align.Left
					ui.next({width = ui.px(widths[ci], 1), height = ui.children_sum(), axis = .X})
					if ui.row(id = fmt.tprintf("###tc%d", ci)) {
						ui.spacer(ui.px(pad))
						ui.next({width = ui.fill(), height = ui.children_sum(), axis = .Y})
						if ui.column(id = "###v") {   // (the room around the words is the spacers': measured so)
							ui.spacer(ui.px(math.round(em * TABLE_CELL_PAD_Y_EM)))
							ui.next({width = ui.fill(), font = the_app.font, font_size = cell_size, flags = {.Selectable}, text_align = al, text_pad = 0})
							link_clicked(ui.rich_paragraph("###p", runs[:], version = src_version(c, c, cell_size)))
							ui.spacer(ui.px(math.round(em * TABLE_CELL_PAD_Y_EM)))
						}
						ui.spacer(ui.px(pad))
					}
				}
			}
			if ri == 0 { ui.next({width = ui.fill(), height = ui.px(2), bg = with_alpha(accent(), 0.35)}); ui.build_box({.Draw_Background}, "###hl") }
		}
		}
		ui.pop_parent()   // (table_scroller's box)
		ui.spacer(ui.px(edge))
		}
		if overflow { table_scroll_bar(hs, total, em) }
		ui.spacer(ui.px(em * 0.3))
	}
}

// The box a table's rows scroll sideways in (its parent until the caller pops it): the width it has, its content `total` wide
// when `overflow`. Its edge fades where it hides columns (by the last frame's offset).
@(private = "file")
table_scroller :: proc(id: string, overflow: bool, total, em: f32) -> ^ui.Box {
	ui.next({width = ui.fill(), height = ui.children_sum(), axis = .X})
	hs := ui.build_box(overflow ? {.View_Scroll_X, .Clip} : {}, "###hs")
	if overflow {
		w := hs.rect.max.x - hs.rect.min.x
		limit := max(total - w, 0)
		fade := math.round(em * TABLE_FADE_EM)
		hs.edge_fade = {hs.view_off.x > 0.5 ? fade : 0, 0, hs.view_off.x < limit - 0.5 ? fade : 0, 0}
		_ = ui.signal(hs)   // (the wheel sideways, or Shift+wheel, scrolls it in its signal)
	} else {
		hs.view_off, hs.view_target = {}, {}
	}
	ui.push_parent(hs)
	return hs
}

// Under a table that scrolls sideways: a thin track and where the view is on it. A press or a drag on it takes the view there.
@(private = "file")
table_scroll_bar :: proc(hs: ^ui.Box, total, em: f32) {
	h := math.round(TABLE_BAR_PX * ui.scale())
	ui.next({width = ui.fill(), height = ui.px(h + math.round(em * 0.5)), cursor = .Hand})
	bar := ui.build_box({.Clickable}, "###hbar")
	sig := ui.signal(bar)
	w := hs.rect.max.x - hs.rect.min.x
	if w <= 0 || total <= w { return }
	limit := total - w
	track := Rect{{bar.rect.min.x + em * 0.6, bar.rect.min.y + em * 0.15}, {bar.rect.max.x - em * 0.6, bar.rect.min.y + em * 0.15 + h}}
	tw := track.max.x - track.min.x
	thumb := max(tw * w / total, em * 2)
	if (sig.pressed || sig.dragging) && tw > thumb {
		t := clamp((ui.mouse_pos().x - track.min.x - thumb * 0.5) / (tw - thumb), 0, 1)
		hs.view_target.x = t * limit
	}
	d := ui.frame_new(Table_Bar_Draw)
	d^ = {track = track, at = track.min.x + (tw - thumb) * clamp(hs.view_off.x / limit, 0, 1), thumb = thumb, hot = sig.hovering || sig.dragging}
	bar.custom = proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
		d := (^Table_Bar_Draw)(user)
		r := (d.track.max.y - d.track.min.y) * 0.5
		draw.rect(dc, d.track, with_alpha(hex(HEX_TEXT), 0.08), r)
		draw.rect(dc, {{d.at, d.track.min.y}, {d.at + d.thumb, d.track.max.y}}, with_alpha(hex(HEX_TEXT), d.hot ? 0.45 : 0.28), r)
	}
	bar.custom_user = d
}

@(private = "file")
Table_Bar_Draw :: struct { track: Rect, at, thumb: f32, hot: bool }

// A table as HTML for the clipboard: a plain grid that takes the style of the program it is pasted in (its fonts, its colours),
// with a thin grey rule around each cell, a little room in them, the header row bold, each column aligned as written; what is
// bold, italic or code in a cell stays so. The first row is the header. Pure.
table_html :: proc(cells: [][][dynamic]ui.Rich_Run, aligns: []ui.Text_Align) -> string {
	esc :: proc(b: ^strings.Builder, s: string) {
		for r in s {
			switch r {
			case '&': strings.write_string(b, "&amp;")
			case '<': strings.write_string(b, "&lt;")
			case '>': strings.write_string(b, "&gt;")
			case '"': strings.write_string(b, "&quot;")
			case:     strings.write_rune(b, r)
			}
		}
	}
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, `<table style="border-collapse:collapse">`)
	for row, ri in cells {
		if ri == 0 { strings.write_string(&b, "<thead>") }
		if ri == 1 { strings.write_string(&b, "<tbody>") }
		strings.write_string(&b, "<tr>")
		tag := ri == 0 ? "th" : "td"
		for runs, ci in row {
			al := ci < len(aligns) ? aligns[ci] : ui.Text_Align.Left
			side := al == .Center ? "center" : al == .Right ? "right" : "left"
			fmt.sbprintf(&b, `<%s style="border:1px solid #bbb;padding:4px 8px;text-align:%s">`, tag, side)
			for run in runs {
				if run.style.code { strings.write_string(&b, "<code>") }
				if run.style.bold && ri > 0 { strings.write_string(&b, "<b>") }
				if run.style.italic { strings.write_string(&b, "<i>") }
				esc(&b, run.text)
				if run.style.italic { strings.write_string(&b, "</i>") }
				if run.style.bold && ri > 0 { strings.write_string(&b, "</b>") }
				if run.style.code { strings.write_string(&b, "</code>") }
			}
			fmt.sbprintf(&b, "</%s>", tag)
		}
		strings.write_string(&b, "</tr>")
		if ri == 0 { strings.write_string(&b, "</thead>") }
	}
	if len(cells) > 1 { strings.write_string(&b, "</tbody>") }
	strings.write_string(&b, "</table>")
	return strings.to_string(b)
}

// Code in a sunken well, under a header with its language and a copy button.
code_block :: proc(id: string, lang: string, code: string, table := false, version: u64 = 0) {
	em := ui.font_size()
	ui.next({width = ui.fill(), height = ui.children_sum()})
	if well(id, radius = 6, base = HEX_CODE_WELL) {
		if !table {
			ui.next({width = ui.fill(), height = ui.px(math.round(em * 1.9)), axis = .X, cross = .Center})
			if ui.row(.Center, id = "###hdr") {
				ui.spacer(ui.px(em * 0.7))
				glyph(lucide.CODE, hex(HEX_FAINT), math.round(em * ICON_SMALL), em)
				ui.spacer(ui.px(em * 0.3))
				text("lang", lang != "" ? lang : "text", hex(HEX_FAINT), ui.Style_Mod{font = the_app.mono, font_size = math.round(em * FS_SMALL)})
				ui.spacer(ui.fill())
				if glyph_button("###copy", lucide.COPY, math.round(em * 1.6)).clicked {
					platform.set_clipboard(the_app.win, code)
					ui.toast(.Good, "Copied")
				}
				ui.spacer(ui.px(em * 0.3))
			}
			ui.next({width = ui.fill(), height = ui.px(2)})
			ui.build_box({}, "")
		}
		ui.next({width = ui.fill(), height = ui.children_sum(), axis = .X})
		if ui.row(id = "###body") {
			ui.spacer(ui.px(em * 0.9))
			runs := [1]ui.Rich_Run{{text = code, style = {font = the_app.mono, color = hex(table ? HEX_TEXT : HEX_CODE_TEXT)}}}
			ui.next({width = ui.fill(), font_size = math.round(em * FS_NOTE), flags = {.Selectable}})
			ui.rich_paragraph("###code", runs[:], version = version)
			ui.spacer(ui.px(em * 0.9))
		}
		ui.spacer(ui.px(em * 0.7))
	}
}
