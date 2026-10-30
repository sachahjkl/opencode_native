// Markdown of the replies, the subset models write: headings, paragraphs, lists, quotes, rules, tables, fenced code,
// and inline **bold**, *italic*, `code`, ~~strike~~, [links](url). Each block is a rich_paragraph (selectable).
package occ

import "core:fmt"
import "core:math"
import "core:strings"
import "gt:platform"
import "gt:ui"

// A name for a piece of the source (where its bytes lie, how far, at which size): the rich layout cache finds the block by
// it instead of hashing its text at every frame. A message's text only grows: a block keeps its bytes until they move,
// and then it is a new name (the toolkit mixes in the paragraph's box, so two messages never share one).
src_version :: proc(first, last: string, size: f32) -> u64 {
	if len(first) == 0 && len(last) == 0 { return 0 }
	a := u64(uintptr(raw_data(first)))
	b := u64(uintptr(raw_data(last))) + u64(len(last))
	return ((a * 0x9e3779b97f4a7c15) ~ (b * 0xc2b2ae3d27d4eb4f) ~ u64(transmute(u32)size)) | 1
}

// Inline Markdown of one block into runs (temp memory).
inline_runs :: proc(text: string, base: ui.Rich_Style, out: ^[dynamic]ui.Rich_Run) {
	st := base
	i, start := 0, 0
	flush :: proc(out: ^[dynamic]ui.Rich_Run, s: string, st: ui.Rich_Style) { if s != "" { append(out, ui.Rich_Run{text = s, style = st}) } }
	for i < len(text) {
		c := text[i]
		switch {
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
			cs.color = hex(0xe5c07bff)
			flush(out, text[i + 1:i + 1 + e], cs)
			i += e + 2; start = i
		case c == '[':
			close_b := strings.index(text[i:], "](")
			close_p := close_b >= 0 ? strings.index_byte(text[i + close_b:], ')') : -1
			if close_b < 0 || close_p < 0 { i += 1; continue }
			flush(out, text[start:i], st)
			l := st
			l.link = text[i + close_b + 2:i + close_b + close_p]
			l.underline = true
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
			if lvl <= 6 && lvl < len(t) && t[lvl] == ' ' {
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
			k := [7]f32{1, 1.45, 1.25, 1.1, 1, 1, 1}
			inline_runs(bl.lines[0], {bold = true, color = bl.level <= 2 ? hex(0xffffffff) : color}, &runs)
			if bl.level >= 2 { ui.spacer(ui.px(em * 0.3)) }
			ui.next({width = ui.fill(), font_size = math.round(fs * k[bl.level]), flags = {.Selectable}})
			res := ui.rich_paragraph(bid, runs[:], version = src_version(bl.lines[0], bl.lines[0], fs))
			link_clicked(res)
		case .Para, .Quote:
			runs := make([dynamic]ui.Rich_Run, context.temp_allocator)
			inline_runs(joined(bl.lines[:]), {color = bl.kind == .Quote ? hex(HEX_WEAK) : color}, &runs)
			if bl.kind == .Quote {
				ui.next({width = ui.fill(), height = ui.children_sum(), axis = .X})
				if rail_row(fmt.tprintf("%s_q", bid), with_alpha(accent(), 0.6)) {
					ui.spacer(ui.px(em * 0.9))
					ui.next({width = ui.fill(), font_size = fs, flags = {.Selectable}})
					link_clicked(ui.rich_paragraph(bid, runs[:], version = src_version(bl.lines[0], bl.lines[len(bl.lines) - 1], fs)))
				}
			} else {
				ui.next({width = ui.fill(), font_size = fs, flags = {.Selectable}})
				link_clicked(ui.rich_paragraph(bid, runs[:], version = src_version(bl.lines[0], bl.lines[len(bl.lines) - 1], fs)))
			}
		case .Bullet, .Number:
			ui.next({width = ui.fill(), height = ui.children_sum(), axis = .X})
			if ui.row(id = fmt.tprintf("%s_li", bid)) {
				ui.spacer(ui.px(em * (0.3 + 1.2 * f32(bl.level))))
				mk := bl.marker
				if bl.kind == .Bullet { mk = bl.level == 0 ? "•" : "◦" }
				ui.next({width = ui.px(em * 1.3), height = ui.px(math.round(fs * 1.35)), fg = accent(), font_size = fs, text_pad = 0})
				ui.build_box({.Draw_Text}, fmt.tprintf("%s###mk", mk))
				runs := make([dynamic]ui.Rich_Run, context.temp_allocator)
				inline_runs(joined(bl.lines[:]), {color = color}, &runs)
				ui.next({width = ui.fill(), font_size = fs, flags = {.Selectable}})
				link_clicked(ui.rich_paragraph(bid, runs[:], version = src_version(bl.lines[0], bl.lines[len(bl.lines) - 1], fs)))
			}
		}
	}
}

@(private = "file")
link_clicked :: proc(res: ui.Rich_Result) {
	if res.link_clicked >= 0 { platform.open_url(res.link) }
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

// A Markdown table as a grid: the header row bold, columns as wide as their widest cell (shrunk to the room when the
// table is wider), each column aligned as its separator says (":--", ":-:", "--:"), alternate rows shaded.
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
	// widths: the widest cell of each column (inline Markdown markers stripped for the measure)
	pad := math.round(em * 0.7)
	widths := make([]f32, ncol, context.temp_allocator)
	cell_size := math.round(fs * 0.92)
	for r, ri in rows {
		for c, ci in r {
			plain, _ := strings.remove_all(c, "**", context.temp_allocator)
			plain, _ = strings.remove_all(plain, "`", context.temp_allocator)
			w := ui.text_width(ri == 0 ? the_app.mono_bold : the_app.font, cell_size, plain) + 2 * pad
			widths[ci] = max(widths[ci], w)
		}
	}
	ui.next({width = ui.fill(), height = ui.children_sum(), axis = .Y})
	if well(id, radius = 6, base = 0x090909ff) {
		ui.spacer(ui.px(em * 0.3))
		for r, ri in rows {
			ui.next({width = ui.fill(), height = ui.children_sum(), axis = .X, bg = ri == 0 ? with_alpha(accent(), 0.10) : ri % 2 == 0 ? Color{1, 1, 1, 0.01} : {}})
			if ui.row(flags = {.Draw_Background}, id = fmt.tprintf("###tr%d", ri)) {
				for ci in 0 ..< ncol {
					c := ci < len(r) ? r[ci] : ""
					runs := make([dynamic]ui.Rich_Run, context.temp_allocator)
					inline_runs(c, {bold = ri == 0, color = ri == 0 ? hex(0xffffffff) : color}, &runs)
					al := ci < len(aligns) ? aligns[ci] : ui.Text_Align.Left
					ui.next({width = ui.px(widths[ci], 0.4), height = ui.children_sum(), axis = .X})
					if ui.row(id = fmt.tprintf("###tc%d", ci)) {
						ui.spacer(ui.px(pad))
						ui.next({width = ui.fill(), font_size = cell_size, flags = {.Selectable}, text_align = al})
						ui.rich_paragraph("###p", runs[:], version = src_version(c, c, cell_size))
						ui.spacer(ui.px(pad))
					}
				}
			}
			if ri == 0 { ui.next({width = ui.fill(), height = ui.px(2), bg = with_alpha(accent(), 0.35)}); ui.build_box({.Draw_Background}, "###hl") }
		}
		ui.spacer(ui.px(em * 0.3))
	}
}

// Code in a sunken well, under a header with its language and a copy button.
code_block :: proc(id: string, lang: string, code: string, table := false, version: u64 = 0) {
	em := ui.font_size()
	ui.next({width = ui.fill(), height = ui.children_sum()})
	if well(id, radius = 6, base = 0x060606ff) {
		if !table {
			ui.next({width = ui.fill(), height = ui.px(math.round(em * 1.9)), axis = .X, cross = .Center})
			if ui.row(.Center, id = "###hdr") {
				ui.spacer(ui.px(em * 0.7))
				glyph(ICO_CODE, hex(HEX_FAINT), math.round(em * 0.75), em)
				ui.spacer(ui.px(em * 0.3))
				text("lang", lang != "" ? lang : "text", hex(HEX_FAINT), ui.Style_Mod{font = the_app.mono, font_size = math.round(em * 0.78)})
				ui.spacer(ui.fill())
				if glyph_button("###copy", ICO_COPY, math.round(em * 1.6)).clicked {
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
			runs := [1]ui.Rich_Run{{text = code, style = {font = the_app.mono, color = hex(table ? HEX_TEXT : 0xd4d4d4ff)}}}
			ui.next({width = ui.fill(), font_size = math.round(em * 0.86), flags = {.Selectable}})
			ui.rich_paragraph("###code", runs[:], version = version)
			ui.spacer(ui.px(em * 0.9))
		}
		ui.spacer(ui.px(em * 0.7))
	}
}
