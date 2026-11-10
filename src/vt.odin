// libghostty-vt, the terminal emulation of Ghostty: the types of its C API that the Terminal panel uses. Its numbers and its calls are in
// vt_gen.odin, made from its headers by ocntools vt. The layouts here are written by hand: vt_test.odin reads through them on the real library.
package ocn

Vt_Terminal :: distinct rawptr
Vt_State    :: distinct rawptr
Vt_Rows     :: distinct rawptr
Vt_Cells    :: distinct rawptr
Vt_Key_Encoder   :: distinct rawptr
Vt_Key_Event     :: distinct rawptr
Vt_Mouse_Encoder :: distinct rawptr
Vt_Mouse_Event   :: distinct rawptr
Vt_Tracked_Ref   :: distinct rawptr
Vt_Formatter     :: distinct rawptr

// A cell of the grid, in the coordinates its tag says (VT_POINT_VIEWPORT: the rows shown; VT_POINT_SCREEN: from the top of the
// scrollback). (Passed by value: the union has room for two words.)
Vt_Coord :: struct { x: u16, y: u32 }
Vt_Point :: struct { tag: i32, value: struct #raw_union { coord: Vt_Coord, _pad: [2]u64 } }
// A cell, valid until the terminal next changes (a tracked one follows it).
Vt_Grid_Ref :: struct { node: rawptr, x, y: u16 }
// Both ends are in it; `start` is where the drag began, before or after `end`.
Vt_Selection :: struct { start, end: Vt_Grid_Ref, rectangle: bool }
// What of a row is selected: its columns from `start_x` to `end_x`, both in.
Vt_Row_Selection :: struct { size: uint, start_x, end_x: u16 }

Vt_Rgb :: struct { r, g, b: u8 }
Vt_String :: struct { ptr: [^]u8, len: uint }

Vt_Style_Color :: struct { tag: u8, value: [3]u8 }   // (the union is a palette index or three bytes)

Vt_Style :: struct {
	fg, bg, underline_color: Vt_Style_Color,
	flags:                   u16,
	reserved:                u16,
}

// Where a cell's codepoints go. `len`: how many it has, even past `cap`.
Vt_Codepoints :: struct { ptr: [^]u32, cap, len: uint }

Vt_Colors :: struct {
	size: uint,
	background, foreground, cursor: Vt_Rgb,
	cursor_has_value: bool,
	palette: [256]Vt_Rgb,
}

Vt_Scrollbar :: struct { total, offset, len: u64 }

Vt_Scroll_Tag :: enum i32 { Top, Bottom, Delta, Row }
#assert(int(Vt_Scroll_Tag.Top) == VT_SCROLL_TOP && int(Vt_Scroll_Tag.Bottom) == VT_SCROLL_BOTTOM && int(Vt_Scroll_Tag.Delta) == VT_SCROLL_DELTA && int(Vt_Scroll_Tag.Row) == VT_SCROLL_ROW)
// (passed by value: its size is the ABI: the union has room for two words)
Vt_Scroll :: struct { tag: Vt_Scroll_Tag, value: i64, _pad: u64 }

Vt_Mode :: struct { mode: u16, value: bool }

Vt_Mouse_Size :: struct {
	size: uint,
	screen_width, screen_height, cell_width, cell_height: u32,
	padding_top, padding_bottom, padding_right, padding_left: u32,
}
Vt_Mouse_Position :: struct { x, y: f32 }

Vt_Write_Pty     :: proc "c" (t: Vt_Terminal, user: rawptr, data: [^]u8, n: uint)
Vt_Title_Changed :: proc "c" (t: Vt_Terminal, user: rawptr)
