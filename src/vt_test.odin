package occ

// Through the real library, for what a wrong number or a wrong layout would not say by itself: the numbers of vt.odin are copied from
// its headers, and one that moved still links, and then reads the wrong thing or writes past a struct.

import "base:runtime"
import "core:strings"
import "core:testing"

@(test)
what_goes_by_value_has_the_size_of_its_c_struct :: proc(t: ^testing.T) {
	testing.expect_value(t, size_of(Vt_Style_Color), 4)
	testing.expect_value(t, size_of(Vt_Style), 16)
	testing.expect_value(t, size_of(Vt_Scroll), 24)
	testing.expect_value(t, size_of(Vt_String), 16)
	testing.expect_value(t, size_of(Vt_Codepoints), 24)
	testing.expect_value(t, size_of(Vt_Scrollbar), 24)
	testing.expect_value(t, size_of(Vt_Mouse_Size), 40)
}

@(private = "file")
Vt_Cell_Read :: struct { text: string, style: Vt_Style, has_bg: bool, fg, bg: Vt_Rgb }

// The cells of the first row, as term_draw reads them.
@(private = "file")
first_row :: proc(term: ^Term) -> []Vt_Cell_Read {
	out := make([dynamic]Vt_Cell_Read, context.temp_allocator)
	if ghostty_render_state_update(term.state, term.vt) != VT_OK { return nil }
	if ghostty_render_state_get(term.state, VT_STATE_ROW_ITERATOR, &term.rows_it) != VT_OK { return nil }
	if !ghostty_render_state_row_iterator_next(term.rows_it) { return nil }
	if ghostty_render_state_row_get(term.rows_it, VT_ROW_CELLS, &term.cells) != VT_OK { return nil }
	for ghostty_render_state_row_cells_next(term.cells) {
		c: Vt_Cell_Read
		glyphs: [8]u32
		read := Vt_Codepoints{ptr = &glyphs[0], cap = len(glyphs)}
		ghostty_render_state_row_cells_get(term.cells, VT_CELL_GRAPHEMES_BUF, &read)
		b := strings.builder_make(context.temp_allocator)
		for g in glyphs[:min(read.len, len(glyphs))] { strings.write_rune(&b, rune(g)) }
		c.text = strings.to_string(b)
		ghostty_render_state_row_cells_get(term.cells, VT_CELL_STYLE, &c.style)
		ghostty_render_state_row_cells_get(term.cells, VT_CELL_FG, &c.fg)
		c.has_bg = ghostty_render_state_row_cells_get(term.cells, VT_CELL_BG, &c.bg) == VT_OK
		append(&out, c)
	}
	return out[:]
}

@(test)
a_cell_says_its_text_and_its_look :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()   // (the title is set from a callback, on the default allocator)
	term := term_new("x", "t", "")
	defer term_free(term)
	term_feed(term, "\x1b[1;4;9;38;2;10;20;30;48;2;40;50;60ma\x1b[0m\x1b[2;7mb\x1b[0m\x1b[8mc\x1b[0mé")
	row := first_row(term)
	if !testing.expect(t, len(row) >= 4, "the row is read") { return }
	a := row[0]
	testing.expect_value(t, a.text, "a")
	testing.expect(t, a.style.flags & VT_STYLE_BOLD != 0, "bold")
	testing.expect(t, a.style.flags & VT_STYLE_UNDERLINE != 0, "underlined")
	testing.expect(t, a.style.flags & VT_STYLE_STRIKETHROUGH != 0, "struck through")
	testing.expect(t, a.style.flags & (VT_STYLE_FAINT | VT_STYLE_INVERSE | VT_STYLE_INVISIBLE) == 0, "and nothing else")
	testing.expect_value(t, a.fg, Vt_Rgb{10, 20, 30})
	testing.expect(t, a.has_bg, "its own background")
	testing.expect_value(t, a.bg, Vt_Rgb{40, 50, 60})
	testing.expect(t, row[1].style.flags & VT_STYLE_FAINT != 0, "faint")
	testing.expect(t, row[1].style.flags & VT_STYLE_INVERSE != 0, "inverse")
	testing.expect(t, row[1].style.flags & VT_STYLE_BOLD == 0, "not bold")
	testing.expect(t, row[2].style.flags & VT_STYLE_INVISIBLE != 0, "invisible")
	testing.expect_value(t, row[3].text, "é")
	testing.expect_value(t, row[3].style.flags, 0)
	testing.expect(t, !row[3].has_bg, "the terminal's background")
	testing.expect_value(t, row[4].text, "")   // (a cell with nothing in it)
}

@(test)
a_cell_of_many_codepoints_is_not_written_past :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()   // (the title is set from a callback, on the default allocator)
	term := term_new("x", "t", "")
	defer term_free(term)
	// (a base letter and combining marks: more than the buffer holds would be cut, and nothing written past it)
	term_feed(term, "e\u0301\u0302\u0303")
	row := first_row(term)
	if !testing.expect(t, len(row) > 0, "the row is read") { return }
	testing.expect_value(t, row[0].text, "e\u0301\u0302\u0303")
}

@(test)
the_colours_and_the_options_reach_the_terminal :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()   // (the title is set from a callback, on the default allocator)
	term := term_new("x", "t", "")
	defer term_free(term)
	if !testing.expect_value(t, ghostty_render_state_update(term.state, term.vt), VT_OK) { return }
	colors := Vt_Colors{size = size_of(Vt_Colors)}
	testing.expect_value(t, ghostty_render_state_get(term.state, VT_STATE_COLORS, &colors), VT_OK)
	// (set by term_new: a number off by one would have set something else, and the defaults would show)
	want_bg := Vt_Rgb{u8((HEX_TERM_BG >> 24) & 0xff), u8((HEX_TERM_BG >> 16) & 0xff), u8((HEX_TERM_BG >> 8) & 0xff)}
	want_fg := Vt_Rgb{u8((HEX_TEXT >> 24) & 0xff), u8((HEX_TEXT >> 16) & 0xff), u8((HEX_TEXT >> 8) & 0xff)}
	testing.expect_value(t, colors.background, want_bg)
	testing.expect_value(t, colors.foreground, want_fg)
}

@(test)
what_a_program_sets_is_read_back :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()   // (the title is set from a callback, on the default allocator)
	term := term_new("x", "t", "")
	defer term_free(term)
	term_feed(term, "\x1b]0;a title\x07")
	title: Vt_String
	testing.expect_value(t, ghostty_terminal_get(term.vt, VT_DATA_TITLE, &title), VT_OK)
	testing.expect_value(t, string(title.ptr[:title.len]), "a title")

	for _ in 0 ..< 40 { term_feed(term, "line\r\n") }
	bar: Vt_Scrollbar
	testing.expect_value(t, ghostty_terminal_get(term.vt, VT_DATA_SCROLLBAR, &bar), VT_OK)
	testing.expect(t, bar.total > bar.len, "history above the screen")
	at_end := bar.offset
	testing.expect_value(t, ghostty_terminal_scroll_viewport(term.vt, {tag = .Delta, value = -3}), VT_OK)
	testing.expect_value(t, ghostty_terminal_get(term.vt, VT_DATA_SCROLLBAR, &bar), VT_OK)
	testing.expect_value(t, bar.offset, at_end - 3)
}

@(test)
the_cursor_is_where_the_text_stopped :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()   // (the title is set from a callback, on the default allocator)
	term := term_new("x", "t", "")
	defer term_free(term)
	term_feed(term, "\x1b[3;5H")
	testing.expect_value(t, ghostty_render_state_update(term.state, term.vt), VT_OK)
	visible, in_view: bool
	x, y: u16
	look: i32 = -1
	testing.expect_value(t, ghostty_render_state_get(term.state, VT_STATE_CURSOR_VISIBLE, &visible), VT_OK)
	testing.expect_value(t, ghostty_render_state_get(term.state, VT_STATE_CURSOR_IN_VIEW, &in_view), VT_OK)
	testing.expect_value(t, ghostty_render_state_get(term.state, VT_STATE_CURSOR_X, &x), VT_OK)
	testing.expect_value(t, ghostty_render_state_get(term.state, VT_STATE_CURSOR_Y, &y), VT_OK)
	testing.expect_value(t, ghostty_render_state_get(term.state, VT_STATE_CURSOR_STYLE, &look), VT_OK)
	testing.expect(t, visible && in_view, "shown")
	testing.expect_value(t, x, 4)
	testing.expect_value(t, y, 2)
	term_feed(term, "\x1b[6 q")   // (a bar)
	testing.expect_value(t, ghostty_render_state_update(term.state, term.vt), VT_OK)
	testing.expect_value(t, ghostty_render_state_get(term.state, VT_STATE_CURSOR_STYLE, &look), VT_OK)
	testing.expect_value(t, look, VT_CURSOR_BAR)
	term_feed(term, "\x1b[4 q")   // (an underline)
	testing.expect_value(t, ghostty_render_state_update(term.state, term.vt), VT_OK)
	testing.expect_value(t, ghostty_render_state_get(term.state, VT_STATE_CURSOR_STYLE, &look), VT_OK)
	testing.expect_value(t, look, VT_CURSOR_UNDERLINE)
}
