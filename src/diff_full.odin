package ocn

import "core:fmt"
import "core:math"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "gt:ui"

// A diff in a window of its own, whole: stacked, or old and new side by side. The rows are read once, when it opens; only
// those in view are built.

Diff_Layout :: enum u8 { Stacked, Split }

diff_layout_name :: proc(l: Diff_Layout) -> string { return l == .Split ? "split" : "stacked" }

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

diff_layout_of :: proc(s: string) -> Diff_Layout { return s == diff_layout_name(.Split) ? .Split : .Stacked }

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
	d.lines = diff_read(d.patch).lines   // (their texts are in d.patch)
	d.rows = diff_split_rows(d.lines)
	for l in d.lines {
		if l.sign == '+' { d.added += 1 }
		if l.sign == '-' { d.removed += 1 }
	}
	d.open = true
}

diff_full_open_file :: proc(app: ^App, path: string) {
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil { ui.toast(.Bad, "Cannot read %s", path); return }
	diff_full_open(app, filepath.base(path), string(data))
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
	base := ui.Rich_Style{font = app.mono, color = col}
	runs := make([dynamic]ui.Rich_Run, context.temp_allocator)
	if l.hi > l.lo {
		if l.lo > 0 { append(&runs, ui.Rich_Run{text = open(l.text[:l.lo]), style = base}) }
		strong := base
		strong.color, strong.background = hex(HEX_BRIGHT), mark
		append(&runs, ui.Rich_Run{text = open(l.text[l.lo:l.hi]), style = strong})
		if l.hi < len(l.text) { append(&runs, ui.Rich_Run{text = open(l.text[l.hi:]), style = base}) }
	} else {
		append(&runs, ui.Rich_Run{text = l.text != "" ? open(l.text) : " ", style = base})
	}
	// One line: the two sides face; a copy has the whole of it.
	ui.next({width = ui.fill(), font_size = fs, flags = {.Selectable}})
	ui.rich_paragraph("###t", runs[:], 1)
}

@(private = "file")
diff_gap :: proc(id: string, em: f32) {
	ui.next({width = ui.fill(), height = ui.px(math.round(em * 1.3)), axis = .X, cross = .Center})   // (the height of every row: diff_window)
	if ui.row(.Center, id = id) {
		ui.spacer(ui.px(em * 0.6))
		text("h", "⋯", hex(HEX_FAINT), ui.Style_Mod{font = the_app.mono, font_size = math.round(em * FS_SMALL)})
	}
}

@(private = "file")
diff_split_row :: proc(app: ^App, d: ^Diff_Full, r: Split_Row, i: int, em: f32) {
	ui.next({width = ui.fill(), height = ui.px(math.round(em * 1.3)), axis = .X})
	if ui.row(id = fmt.tprintf("###r%d", i)) {
		diff_cell(app, "###a", r.left >= 0 ? d.lines[r.left] : nil, .Old, em)
		ui.next({width = ui.px(max(1, ui.scale())), height = ui.px(math.round(em * 1.3)), bg = hex(HEX_FAINT)})
		ui.build_box({.Draw_Background}, "###bar")
		diff_cell(app, "###b", r.right >= 0 ? d.lines[r.right] : nil, .New, em)
	}
}

// The rows to build for a view: every row has one height, so what shows is a sum, whatever the length of the diff. Both where
// the view is and where it goes, and a margin beyond.
diff_window :: proc(offset, target, view_h, row_h: f32, count: int) -> (first, last: int) {
	if row_h <= 0 { return 0, 0 }
	top := min(offset, target)
	bottom := max(offset, target) + view_h
	first = clamp(int(top / row_h) - DIFF_ROWS_MARGIN, 0, count)
	last = clamp(int(bottom / row_h) + 1 + DIFF_ROWS_MARGIN, first, count)
	return
}

@(private = "file")
diff_full_rows :: proc(app: ^App, d: ^Diff_Full, layout: Diff_Layout, view: ^ui.Box, em: f32) {
	h := math.round(em * 1.3)
	count := layout == .Stacked ? len(d.lines) : len(d.rows)
	first, last := diff_window(view.view_off.y, view.view_target.y, view.size.y, h, count)
	ui.spacer(ui.px(f32(first) * h))
	for i in first ..< last {
		switch layout {
		case .Stacked:
			l := d.lines[i]
			if l.sign == '@' { diff_gap(fmt.tprintf("###g%d", i), em) } else { diff_cell(app, fmt.tprintf("###c%d", i), l, .Both, em) }
		case .Split:
			r := d.rows[i]
			if r.left >= 0 && d.lines[r.left].sign == '@' { diff_gap(fmt.tprintf("###g%d", i), em) } else { diff_split_row(app, d, r, i, em) }
		}
	}
	ui.spacer(ui.px(f32(count - last) * h))
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
			text("t", d.title, hex(HEX_BRIGHT), ui.Style_Mod{font_size = math.round(em * FS_TITLE), height = ui.px(em * 2), flags = {.Selectable}}, ui.fill())   // (a path: to copy, to go to)
			text("a", fmt.tprintf("+%d", d.added), hex(HEX_GREEN), ui.Style_Mod{font = app.mono, font_size = math.round(em * FS_SMALL), height = ui.px(em * 2)})
			ui.spacer(ui.px(em * 0.5))
			text("d", fmt.tprintf("-%d", d.removed), hex(HEX_RED), ui.Style_Mod{font = app.mono, font_size = math.round(em * FS_SMALL), height = ui.px(em * 2)})
			ui.spacer(ui.px(em))
			if bevel_button("###df_copy", "Copy", "", .Normal).clicked {
				clip_set(d.patch)
				ui.toast(.Good, "Diff copied")
			}
			ui.spacer(ui.px(em * 0.6))
			sel := int(app.prefs.diff_layout)
			labels := []string{"Stacked", "Split"}
			ui.next({width = ui.px(em * 12), height = ui.px(em * 2)})
			if choice("###df_mode", labels, &sel) { pref_set(app, "conversation.diff_layout", diff_layout_name(Diff_Layout(sel))) }
			ui.spacer(ui.px(em * 3.2))   // (the dialog's close button is there)
		}
		ui.spacer(ui.px(em * 0.6))
		ui.next({width = ui.fill(), height = ui.fill(), axis = .Y})
		view := ui.build_box({.Clip, .View_Scroll_Y, .View_Clamp_Y, .Allow_Overflow_Y}, "###df_list")
		_ = ui.signal(view)
		if ui.parent(view) { diff_full_rows(app, d, app.prefs.diff_layout, view, em) }
		ui.spacer(ui.px(em * 0.6))
		dialog_close(&open)
	}
	if !open { diff_full_close(d) }
}
