package ocn

// Through the real library, for what a wrong number or a wrong layout would not say by itself: the numbers of vt.odin are copied from
// its headers, and one that moved still links, and then reads the wrong thing or writes past a struct. And the emulation as the grid's
// source (terminal.odin, term.Source): what the widget is given and what it asks, through libghostty-vt. (The widget itself, on a
// screen of its own, is tested in gui_toolkit's tests/term.)

import "base:runtime"
import "core:strings"
import "core:testing"
import "gt:platform"
import "gt:term"

@(test)
what_goes_by_value_has_the_size_of_its_c_struct :: proc(t: ^testing.T) {
	testing.expect_value(t, size_of(Vt_Style_Color), 4)
	testing.expect_value(t, size_of(Vt_Style), 16)
	testing.expect_value(t, size_of(Vt_Scroll), 24)
	testing.expect_value(t, size_of(Vt_String), 16)
	testing.expect_value(t, size_of(Vt_Codepoints), 24)
	testing.expect_value(t, size_of(Vt_Scrollbar), 24)
	testing.expect_value(t, size_of(Vt_Mouse_Size), 40)
	testing.expect_value(t, size_of(Vt_Point), 24)
	testing.expect_value(t, offset_of(Vt_Point, value), 8)
	testing.expect_value(t, size_of(Vt_Grid_Ref), 16)
	testing.expect_value(t, size_of(Vt_Selection), 40)   // (its header says so: its layout is frozen)
	testing.expect_value(t, size_of(Vt_Row_Selection), 16)
	testing.expect_value(t, size_of(Vt_Colors), 792)
	testing.expect_value(t, size_of(Vt_Mode), 4)
}

@(private = "file")
Vt_Cell_Read :: struct { text: string, style: Vt_Style, has_bg: bool, fg, bg: Vt_Rgb }

// The cells of the first row, as term_rows reads them.
@(private = "file")
first_row :: proc(sh: ^Term) -> []Vt_Cell_Read {
	out := make([dynamic]Vt_Cell_Read, context.temp_allocator)
	if ghostty_render_state_update(sh.state, sh.vt) != VT_OK { return nil }
	if ghostty_render_state_get(sh.state, VT_STATE_ROW_ITERATOR, &sh.rows_it) != VT_OK { return nil }
	if !ghostty_render_state_row_iterator_next(sh.rows_it) { return nil }
	if ghostty_render_state_row_get(sh.rows_it, VT_ROW_CELLS, &sh.cells) != VT_OK { return nil }
	for ghostty_render_state_row_cells_next(sh.cells) {
		c: Vt_Cell_Read
		glyphs: [8]u32
		read := Vt_Codepoints{ptr = &glyphs[0], cap = len(glyphs)}
		ghostty_render_state_row_cells_get(sh.cells, VT_CELL_GRAPHEMES_BUF, &read)
		b := strings.builder_make(context.temp_allocator)
		for g in glyphs[:min(read.len, len(glyphs))] { strings.write_rune(&b, rune(g)) }
		c.text = strings.to_string(b)
		ghostty_render_state_row_cells_get(sh.cells, VT_CELL_STYLE, &c.style)
		ghostty_render_state_row_cells_get(sh.cells, VT_CELL_FG, &c.fg)
		c.has_bg = ghostty_render_state_row_cells_get(sh.cells, VT_CELL_BG, &c.bg) == VT_OK
		append(&out, c)
	}
	return out[:]
}

@(test)
a_cell_says_its_text_and_its_look :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()   // (the title is set from a callback, on the default allocator)
	sh := term_new("x", "t", "")
	defer term_free(sh)
	term_feed(sh, "\x1b[1;4;9;38;2;10;20;30;48;2;40;50;60ma\x1b[0m\x1b[2;7mb\x1b[0m\x1b[8mc\x1b[0mé")
	row := first_row(sh)
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
	sh := term_new("x", "t", "")
	defer term_free(sh)
	// (a base letter and combining marks: more than the buffer holds would be cut, and nothing written past it)
	term_feed(sh, "é̂̃")
	row := first_row(sh)
	if !testing.expect(t, len(row) > 0, "the row is read") { return }
	testing.expect_value(t, row[0].text, "é̂̃")
}

@(test)
the_colours_and_the_options_reach_the_terminal :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()   // (the title is set from a callback, on the default allocator)
	sh := term_new("x", "t", "")
	defer term_free(sh)
	if !testing.expect_value(t, ghostty_render_state_update(sh.state, sh.vt), VT_OK) { return }
	colors := Vt_Colors{size = size_of(Vt_Colors)}
	testing.expect_value(t, ghostty_render_state_get(sh.state, VT_STATE_COLORS, &colors), VT_OK)
	// (set by term_new: a number off by one would have set something else, and the defaults would show)
	want_bg := Vt_Rgb{u8((HEX_TERM_BG >> 24) & 0xff), u8((HEX_TERM_BG >> 16) & 0xff), u8((HEX_TERM_BG >> 8) & 0xff)}
	want_fg := Vt_Rgb{u8((HEX_TEXT >> 24) & 0xff), u8((HEX_TEXT >> 16) & 0xff), u8((HEX_TEXT >> 8) & 0xff)}
	testing.expect_value(t, colors.background, want_bg)
	testing.expect_value(t, colors.foreground, want_fg)
}

@(test)
what_a_program_sets_is_read_back :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()   // (the title is set from a callback, on the default allocator)
	sh := term_new("x", "t", "")
	defer term_free(sh)
	term_feed(sh, "\x1b]0;a title\x07")
	title: Vt_String
	testing.expect_value(t, ghostty_terminal_get(sh.vt, VT_DATA_TITLE, &title), VT_OK)
	testing.expect_value(t, string(title.ptr[:title.len]), "a title")

	for _ in 0 ..< 40 { term_feed(sh, "line\r\n") }
	bar, ok := term.scrollbar(&sh.view)
	testing.expect(t, ok && bar.total > bar.len, "history above the screen")
	at_end := bar.offset
	term.scroll(&sh.view, -3)
	bar, _ = term.scrollbar(&sh.view)
	testing.expect_value(t, bar.offset, at_end - 3)
	testing.expect(t, !term.at_bottom(&sh.view), "scrolled up")
	term.scroll_bottom(&sh.view)
	testing.expect(t, term.at_bottom(&sh.view), "and back")
}

@(test)
the_cursor_is_where_the_text_stopped :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()   // (the title is set from a callback, on the default allocator)
	sh := term_new("x", "t", "")
	defer term_free(sh)
	term_feed(sh, "\x1b[3;5H")
	testing.expect(t, term.refresh(&sh.view), "a picture")
	c := sh.view.picture.cursor
	testing.expect(t, c.shown, "shown")
	testing.expect_value(t, c.x, 4)
	testing.expect_value(t, c.y, 2)
	term_feed(sh, "\x1b[6 q")   // (a bar)
	term.refresh(&sh.view)
	testing.expect_value(t, sh.view.picture.cursor.shape, term.Cursor_Shape.Bar)
	term_feed(sh, "\x1b[4 q")   // (an underline)
	term.refresh(&sh.view)
	testing.expect_value(t, sh.view.picture.cursor.shape, term.Cursor_Shape.Underline)
}

// A frame builds again only the rows libghostty-vt says changed: none when the shell wrote nothing (the draw then reads no cell).
@(test)
a_row_is_built_again_only_when_it_changed :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()   // (the title is set from a callback, on the default allocator)
	sh := term_new("x", "t", "")
	defer term_free(sh)
	// (what the draw does before it draws, out of a frame: the rows built by this refresh)
	build :: proc(sh: ^Term) -> int {
		before := sh.view.rows_built
		if !term.refresh(&sh.view) { return -1 }
		return sh.view.rows_built - before
	}
	rows := sh.view.rows
	term_feed(sh, "hello\r\nworld")
	testing.expect_value(t, build(sh), rows)
	if !testing.expect_value(t, len(sh.view.lines), rows) { return }
	testing.expect_value(t, term.row_text(&sh.view, 0), "hello")
	testing.expect_value(t, term.row_text(&sh.view, 1), "world")
	testing.expect_value(t, build(sh), 0)   // (nothing written: nothing read)
	term_feed(sh, "!")
	n := build(sh)
	testing.expect(t, n >= 1 && n < rows, "only the rows written are built again")
	testing.expect_value(t, term.row_text(&sh.view, 1), "world!")
	testing.expect_value(t, term.row_text(&sh.view, 0), "hello")
	term_recolour(sh)
	testing.expect_value(t, build(sh), rows)   // (the colours moved: every row)
}

// The look of a cell reaches the row as the widget draws it: its colour, a line under it, the selection.
@(test)
a_cell_is_drawn_with_its_look :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	sh := term_new("x", "t", "")
	defer term_free(sh)
	term_feed(sh, "\x1b[4;38;2;10;20;30mab\x1b[0m cd")
	term.refresh(&sh.view)
	r := sh.view.lines[0]
	if !testing.expect_value(t, len(r.runs), 2) { return }
	testing.expect_value(t, string(r.text[r.runs[0].from:r.runs[0].to]), "ab")
	testing.expect(t, r.runs[0].color != r.runs[1].color, "its own colour")
	testing.expect_value(t, len(r.marks), 1)
	term.select_begin(&sh.view, {3, 0})
	term.select_to(&sh.view, {4, 0})
	term.refresh(&sh.view)
	r = sh.view.lines[0]
	selected := false
	for f in r.fills { if f.selected && f.from == 3 && f.to == 5 { selected = true } }
	testing.expect(t, selected, "the selection's cells")
	testing.expect_value(t, term.selection_text(&sh.view), "cd")
}

// A program's colour by number is the theme's: red (31) is the theme's red, the cube after the 16 made between the
// background and the text (not Ghostty's console colours).
@(test)
a_shells_colours_are_the_themes :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	sh := term_new("x", "t", "")
	defer term_free(sh)
	bg, fg := rgb_of(HEX_TERM_BG), rgb_of(HEX_TEXT)
	p := term_palette(bg, fg)
	testing.expect_value(t, p[1], rgb_of(HEX_RED))
	testing.expect_value(t, p[4], rgb_of(HEX_BLUE))
	testing.expect(t, p[16] != {} || p[231] != {}, "the cube made")
	term_recolour(sh)
	term_feed(sh, "\x1b[31mr\x1b[0m")
	row := first_row(sh)
	if testing.expect(t, len(row) > 0, "a row") { testing.expect_value(t, row[0].fg, rgb_of(HEX_RED)) }
}

// What the shell gets, byte for byte, through Ghostty's encoder: a wrong number of a key sends something else without a word.
@(test)
a_key_says_what_a_terminal_says :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	sh := term_new("x", "t", "")
	defer term_free(sh)
	expect :: proc(t: ^testing.T, sh: ^Term, k: platform.Key, mods: platform.Modifiers, want: string) {
		testing.expect_value(t, term.encode_key(&sh.view, {k, mods, false}), want)
	}
	expect(t, sh, .Return, {}, "\r")
	expect(t, sh, .Backspace, {}, "\x7f")
	expect(t, sh, .Tab, {}, "\t")
	expect(t, sh, .Escape, {}, "\x1b")
	expect(t, sh, .Up, {}, "\x1b[A")
	expect(t, sh, .Left, {}, "\x1b[D")
	expect(t, sh, .Home, {}, "\x1b[H")
	expect(t, sh, .End, {}, "\x1b[F")
	expect(t, sh, .Delete, {}, "\x1b[3~")
	expect(t, sh, .Page_Up, {}, "\x1b[5~")
	expect(t, sh, .F1, {}, "\x1bOP")
	expect(t, sh, .F5, {}, "\x1b[15~")
	expect(t, sh, .C, {.Ctrl}, "\x03")
	expect(t, sh, .K, {.Ctrl}, "\x0b")
	expect(t, sh, .Z, {.Ctrl}, "\x1a")
	expect(t, sh, .B, {.Alt}, "\x1bb")
	expect(t, sh, .A, {}, "")                  // (its character comes by the Text event)
	expect(t, sh, .N2, {.Ctrl, .Alt}, "")      // (AltGr: a character too)
	term_feed(sh, "\x1b[?1h")                  // (application cursor keys)
	expect(t, sh, .Up, {}, "\x1bOA")
}

// The modes the widget reads are the shell's: brackets around a paste, the mouse for a program that asks.
@(test)
the_modes_are_the_shells :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	sh := term_new("x", "t", "")
	defer term_free(sh)
	testing.expect_value(t, term.paste_text(&sh.view, "a\nb"), "a\rb")
	testing.expect(t, !term.tracks_mouse(&sh.view), "the pointer selects")
	term_feed(sh, "\x1b[?2004h\x1b[?1000h")
	testing.expect_value(t, term.paste_text(&sh.view, "a\nb"), "\x1b[200~a\nb\x1b[201~")
	testing.expect(t, term.tracks_mouse(&sh.view), "the program has the mouse")
}
