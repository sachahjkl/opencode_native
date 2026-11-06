package occ

import "core:fmt"
import "core:math"
import "core:slice"
import "core:strings"
import "gt:ui"

// A diff in a window of its own, whole: stacked, or old and new side by side. The rows are read once, when it opens; only
// those in view are built.

Diff_Layout :: enum u8 { Stacked, Split }

DIFF_LAYOUT_NAMES := [Diff_Layout]string{.Stacked = "stacked", .Split = "split"}
DIFF_LAYOUT_LABELS := [Diff_Layout]string{.Stacked = "Stacked", .Split = "Split"}

// The two sides of a line, by index in the lines; -1: nothing on that side. A line that is the same, or the mark between two
// hunks, is on both.
Split_Row :: struct { left, right: int }

Diff_Full :: struct {
	open:           bool,
	title, patch:   string,
	lines:          []Diff_Line,
	rows:           []Split_Row,
	added, removed: int,
}

diff_layout_of :: proc(s: string) -> Diff_Layout { return s == DIFF_LAYOUT_NAMES[.Split] ? .Split : .Stacked }

// In a block of lines removed then added, the k-th of each are the same line changed, as diff_mark has them: side by side.
diff_split_rows :: proc(lines: []Diff_Line, allocator := context.allocator) -> []Split_Row {
	out := make([dynamic]Split_Row, 0, len(lines), allocator)
	i := 0
	for i < len(lines) {
		if lines[i].sign != '-' && lines[i].sign != '+' {
			append(&out, Split_Row{i, i})
			i += 1
			continue
		}
		d0 := i
		for i < len(lines) && lines[i].sign == '-' { i += 1 }
		a0 := i
		for i < len(lines) && lines[i].sign == '+' { i += 1 }
		removed, added := a0 - d0, i - a0
		for k in 0 ..< max(removed, added) {
			append(&out, Split_Row{k < removed ? d0 + k : -1, k < added ? a0 + k : -1})
		}
	}
	return out[:]
}

diff_full_open :: proc(app: ^App, title, patch: string) {
	d := &app.cx.diff_full
	diff_full_close(d)
	d.title, d.patch = strings.clone(title), strings.clone(patch)
	lines := diff_parse(d.patch)   // (their texts are in d.patch)
	diff_mark(lines)
	d.lines = slice.clone(lines)
	d.rows = diff_split_rows(d.lines)
	for l in d.lines {
		if l.sign == '+' { d.added += 1 }
		if l.sign == '-' { d.removed += 1 }
	}
	d.open = true
}

diff_full_close :: proc(d: ^Diff_Full) {
	delete(d.title)
	delete(d.patch)
	delete(d.lines)
	delete(d.rows)
	d^ = {}
}

// Which of a line's numbers its row shows.
Diff_Numbers :: enum u8 { Both, Old, New }

// A line on one row, its text selectable. (Long ones go past the edge: a row is one line, or the two sides would not face.)
@(private = "file")
diff_cell :: proc(app: ^App, id: string, line: Maybe(Diff_Line), numbers: Diff_Numbers, em: f32) {
	h := math.round(em * 1.3)
	l, there := line.?
	bg := CLEAR
	col := hex(HEX_TOOL_OUTPUT)
	mark := CLEAR
	if l.sign == '+' { bg, col, mark = hex(HEX_DIFF_ADD_BG), hex(HEX_DIFF_ADD_TEXT), hex(HEX_DIFF_ADD_MARK) }
	if l.sign == '-' { bg, col, mark = hex(HEX_DIFF_DEL_BG), hex(HEX_DIFF_DEL_TEXT), hex(HEX_DIFF_DEL_MARK) }
	ui.next({width = ui.fill(), height = ui.px(h), axis = .X, cross = .Center, bg = bg, radius = 0})
	b := ui.build_box({.Draw_Background, .Clip}, id)
	if ui.parent(b) {
		if there { diff_cell_line(app, l, numbers, col, mark, h, em) }
	}
}

@(private = "file")
diff_cell_line :: proc(app: ^App, l: Diff_Line, numbers: Diff_Numbers, col, mark: Color, h, em: f32) {
	fs := math.round(em * FS_SMALL)
	switch numbers {
	case .Both:
		gutter("o", l.old_no, em)
		gutter("n", l.new_no, em)
	case .Old: gutter("o", l.old_no, em)
	case .New: gutter("n", l.new_no, em)
	}
	ui.spacer(ui.px(em * 0.4))
	sign := l.sign == ' ' ? " " : l.sign == '+' ? "+" : "−"
	text("s", sign, l.sign == '+' ? hex(HEX_GREEN) : l.sign == '-' ? hex(HEX_RED) : hex(HEX_FAINT), ui.Style_Mod{font = app.mono_bold, font_size = fs}, ui.px(em * 1))
	open :: proc(s: string) -> string {
		out, _ := strings.replace_all(s, "\t", TOOL_TAB, context.temp_allocator)
		return out
	}
	st := ui.Style_Mod{font = app.mono, font_size = fs, flags = {.Selectable}}
	if l.hi > l.lo {
		if l.lo > 0 { text("a", open(l.text[:l.lo]), col, st) }
		ui.next({width = ui.text_size(0), height = ui.px(h), font = app.mono, font_size = fs, bg = mark, fg = hex(HEX_BRIGHT), radius = 2 * ui.scale(), text_pad = 0, flags = {.Selectable}})
		ui.build_box({.Draw_Text, .Draw_Background}, fmt.tprintf("%s###b", label_safe(open(l.text[l.lo:l.hi]))))
		text("c", open(l.text[l.hi:]), col, st, ui.fill())
	} else {
		text("t", open(l.text), col, st, ui.fill())
	}
}

@(private = "file")
diff_gap :: proc(id: string, em: f32) {
	ui.next({width = ui.fill(), height = ui.px(math.round(em * 1.1)), axis = .X, cross = .Center})
	if ui.row(.Center, id = id) {
		ui.spacer(ui.px(em * 0.6))
		text("h", "⋯", hex(HEX_FAINT), ui.Style_Mod{font = the_app.mono, font_size = math.round(em * FS_SMALL)})
	}
}

@(private = "file")
diff_split_row :: proc(app: ^App, d: ^Diff_Full, r: Split_Row, em: f32) {
	ui.next({width = ui.fill(), height = ui.px(math.round(em * 1.3)), axis = .X})
	if ui.row(id = "###r") {
		diff_cell(app, "###a", r.left >= 0 ? d.lines[r.left] : nil, .Old, em)
		ui.next({width = ui.px(max(1, ui.scale())), height = ui.px(math.round(em * 1.3)), bg = hex(HEX_FAINT)})
		ui.build_box({.Draw_Background}, "###bar")
		diff_cell(app, "###b", r.right >= 0 ? d.lines[r.right] : nil, .New, em)
	}
}

@(private = "file")
diff_full_rows :: proc(app: ^App, d: ^Diff_Full, layout: Diff_Layout, em: f32) {
	lz := ui.lazy_begin()
	switch layout {
	case .Stacked:
		for l, i in d.lines {
			if ui.lazy_item(lz, fmt.tprintf("###dk%d", i)) {
				if l.sign == '@' { diff_gap("###g", em) } else { diff_cell(app, "###c", l, .Both, em) }
			}
		}
	case .Split:
		for r, i in d.rows {
			if ui.lazy_item(lz, fmt.tprintf("###dp%d", i)) {
				if r.left >= 0 && d.lines[r.left].sign == '@' {
					diff_gap("###g", em)
				} else {
					diff_split_row(app, d, r, em)
				}
			}
		}
	}
}

diff_full_dialog :: proc(app: ^App, em: f32) {
	d := &app.cx.diff_full
	if !d.open { return }
	open := true
	if ui.modal_sized("diff_full", DIALOG_PREFERRED_EM[.Diff] * em, &app.cx.dialogs[.Diff], &open, DIALOG_MIN_EM[.Diff] * em) {
		dialog_backdrop()
		ui.spacer(ui.px(em * 0.9))
		ui.next({width = ui.fill(), height = ui.children_sum(), axis = .X, cross = .Center})
		if ui.row(.Center, id = "###df_head") {
			ui.spacer(ui.px(em * DIALOG_MARGIN_EM))
			text("t", d.title, hex(HEX_BRIGHT), ui.Style_Mod{font_size = math.round(em * FS_TITLE), height = ui.px(em * 2)}, ui.fill())
			text("a", fmt.tprintf("+%d", d.added), hex(HEX_GREEN), ui.Style_Mod{font = app.mono, font_size = math.round(em * FS_SMALL), height = ui.px(em * 2)})
			ui.spacer(ui.px(em * 0.5))
			text("d", fmt.tprintf("-%d", d.removed), hex(HEX_RED), ui.Style_Mod{font = app.mono, font_size = math.round(em * FS_SMALL), height = ui.px(em * 2)})
			ui.spacer(ui.px(em))
			sel := int(app.prefs.diff_layout)
			labels := []string{DIFF_LAYOUT_LABELS[.Stacked], DIFF_LAYOUT_LABELS[.Split]}
			ui.next({width = ui.px(em * 12), height = ui.px(em * 2)})
			if ui.segmented("###df_mode", labels, &sel) { pref_set(app, "conversation.diff_layout", DIFF_LAYOUT_NAMES[Diff_Layout(sel)]) }
			ui.spacer(ui.px(em * 3.2))   // (the dialog's close button is there)
		}
		ui.spacer(ui.px(em * 0.6))
		ui.next({width = ui.fill(), height = ui.fill()})
		if ui.scroll_y("###df_list") {
			ui.next({width = ui.fill(), height = ui.children_sum(), axis = .Y})
			if ui.column(id = "###df_rows") { diff_full_rows(app, d, app.prefs.diff_layout, em) }
		}
		ui.spacer(ui.px(em * 0.6))
		dialog_close(&open)
	}
	if !open { diff_full_close(d) }
}
