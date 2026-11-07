// libghostty-vt, the terminal emulation of Ghostty: the types of its C API that the Terminal panel uses. Its numbers and its calls are in
// vt_gen.odin, made from its headers by occtools vt. The layouts here are written by hand: vt_test.odin reads through them on the real library.
package occ

Vt_Terminal :: distinct rawptr
Vt_State    :: distinct rawptr
Vt_Rows     :: distinct rawptr
Vt_Cells    :: distinct rawptr
Vt_Key_Encoder   :: distinct rawptr
Vt_Key_Event     :: distinct rawptr
Vt_Mouse_Encoder :: distinct rawptr
Vt_Mouse_Event   :: distinct rawptr

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
