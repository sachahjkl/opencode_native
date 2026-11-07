// libghostty-vt, the terminal emulation of Ghostty: what the Terminal panel uses of its C API. Built by occtools build, pinned
// there; the numbers below are those of its headers at that commit (zig-out/include/ghostty/vt). They are copied by hand and nothing
// checks them at the build: a number off by one still links. vt_test.odin reads through each of them on the real library.
package occ

when ODIN_OS == .Windows {
	foreign import ghostty_vt { "../build/vt/ghostty-vt-static.lib", "system:ntdll.lib" }
} else {
	foreign import ghostty_vt "../build/vt/libghostty-vt.a"
}

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

VT_STYLE_BOLD          :: 1 << 0
VT_STYLE_FAINT         :: 1 << 2
VT_STYLE_INVERSE       :: 1 << 4
VT_STYLE_INVISIBLE     :: 1 << 5
VT_STYLE_STRIKETHROUGH :: 1 << 6
VT_STYLE_UNDERLINE     :: 0x7 << 8   // (a kind, not a flag: 0 is none)

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
// (passed by value: its size is the ABI: the union has room for two words)
Vt_Scroll :: struct { tag: Vt_Scroll_Tag, value: i64, _pad: u64 }

Vt_Mode :: struct { mode: u16, value: bool }

// (value & 0x7FFF) | ansi << 15: these are DEC private modes.
VT_MODE_BRACKETED_PASTE :: 2004
VT_MODE_FOCUS_EVENT     :: 1004

Vt_Mouse_Size :: struct {
	size: uint,
	screen_width, screen_height, cell_width, cell_height: u32,
	padding_top, padding_bottom, padding_right, padding_left: u32,
}
Vt_Mouse_Position :: struct { x, y: f32 }

VT_OK :: 0

// GhosttyTerminalOption
VT_OPT_USERDATA      :: 1
VT_OPT_WRITE_PTY     :: 2
VT_OPT_TITLE_CHANGED :: 6
VT_OPT_COLOR_FOREGROUND :: 12
VT_OPT_COLOR_BACKGROUND :: 13
VT_OPT_SCROLLBACK_MAX_LINES :: 29

// GhosttyTerminalData
VT_DATA_SCROLLBAR      :: 9
VT_DATA_MOUSE_TRACKING :: 11
VT_DATA_TITLE          :: 12
VT_DATA_MODE           :: 37

// GhosttyRenderStateData
VT_STATE_ROW_ITERATOR   :: 4
VT_STATE_CURSOR_STYLE   :: 10
VT_STATE_CURSOR_VISIBLE :: 11
VT_STATE_CURSOR_IN_VIEW :: 14
VT_STATE_CURSOR_X       :: 15
VT_STATE_CURSOR_Y       :: 16
VT_STATE_COLORS         :: 19

VT_CURSOR_BAR       :: 0
VT_CURSOR_BLOCK     :: 1
VT_CURSOR_UNDERLINE :: 2

VT_ROW_CELLS :: 3

// GhosttyRenderStateRowCellsData
VT_CELL_STYLE         :: 2
VT_CELL_GRAPHEMES_BUF :: 4
VT_CELL_BG            :: 5
VT_CELL_FG            :: 6

VT_ACTION_PRESS  :: 1
VT_ACTION_REPEAT :: 2

VT_MODS_SHIFT :: 1 << 0
VT_MODS_CTRL  :: 1 << 1
VT_MODS_ALT   :: 1 << 2

VT_MOUSE_PRESS   :: 0
VT_MOUSE_RELEASE :: 1
VT_MOUSE_MOTION  :: 2

VT_MOUSE_LEFT   :: 1
VT_MOUSE_RIGHT  :: 2
VT_MOUSE_MIDDLE :: 3
VT_MOUSE_FOUR   :: 4   // (the wheel, up)
VT_MOUSE_FIVE   :: 5   // (the wheel, down)

VT_MOUSE_OPT_SIZE            :: 3
VT_MOUSE_OPT_ANY_PRESSED     :: 4
VT_MOUSE_OPT_TRACK_LAST_CELL :: 5

// GhosttyKey: the W3C codes, as a C compiler reads them in the headers.
VT_KEY_COMMA :: 5
VT_KEY_DIGIT_0 :: 6
VT_KEY_EQUAL :: 16
VT_KEY_A :: 20
VT_KEY_MINUS :: 46
VT_KEY_PERIOD :: 47
VT_KEY_SLASH :: 50
VT_KEY_BACKSPACE :: 53
VT_KEY_CONTEXT_MENU :: 55
VT_KEY_ENTER :: 58
VT_KEY_SPACE :: 63
VT_KEY_TAB :: 64
VT_KEY_DELETE :: 68
VT_KEY_END :: 69
VT_KEY_HOME :: 71
VT_KEY_INSERT :: 72
VT_KEY_PAGE_DOWN :: 73
VT_KEY_PAGE_UP :: 74
VT_KEY_ARROW_DOWN :: 75
VT_KEY_ARROW_LEFT :: 76
VT_KEY_ARROW_RIGHT :: 77
VT_KEY_ARROW_UP :: 78
VT_KEY_NUMPAD_ADD :: 90
VT_KEY_NUMPAD_SUBTRACT :: 107
VT_KEY_ESCAPE :: 120
VT_KEY_F1 :: 121

Vt_Write_Pty     :: proc "c" (t: Vt_Terminal, user: rawptr, data: [^]u8, n: uint)
Vt_Title_Changed :: proc "c" (t: Vt_Terminal, user: rawptr)

@(default_calling_convention = "c")
foreign ghostty_vt {
	ghostty_terminal_new :: proc(alloc: rawptr, t: ^Vt_Terminal, cols, rows: u16) -> i32 ---
	ghostty_terminal_free :: proc(t: Vt_Terminal) ---
	ghostty_terminal_vt_write :: proc(t: Vt_Terminal, data: [^]u8, n: uint) ---
	ghostty_terminal_resize :: proc(t: Vt_Terminal, cols, rows: u16, cell_w, cell_h: u32) -> i32 ---
	ghostty_terminal_set :: proc(t: Vt_Terminal, option: i32, value: rawptr) -> i32 ---
	ghostty_terminal_get :: proc(t: Vt_Terminal, data: i32, out: rawptr) -> i32 ---
	ghostty_terminal_scroll_viewport :: proc(t: Vt_Terminal, behaviour: Vt_Scroll) -> i32 ---

	ghostty_render_state_new :: proc(alloc: rawptr, s: ^Vt_State) -> i32 ---
	ghostty_render_state_free :: proc(s: Vt_State) ---
	ghostty_render_state_update :: proc(s: Vt_State, t: Vt_Terminal) -> i32 ---
	ghostty_render_state_get :: proc(s: Vt_State, data: i32, out: rawptr) -> i32 ---
	ghostty_render_state_row_iterator_new :: proc(alloc: rawptr, it: ^Vt_Rows) -> i32 ---
	ghostty_render_state_row_iterator_free :: proc(it: Vt_Rows) ---
	ghostty_render_state_row_iterator_next :: proc(it: Vt_Rows) -> bool ---
	ghostty_render_state_row_get :: proc(it: Vt_Rows, data: i32, out: rawptr) -> i32 ---
	ghostty_render_state_row_cells_new :: proc(alloc: rawptr, c: ^Vt_Cells) -> i32 ---
	ghostty_render_state_row_cells_free :: proc(c: Vt_Cells) ---
	ghostty_render_state_row_cells_next :: proc(c: Vt_Cells) -> bool ---
	ghostty_render_state_row_cells_get :: proc(c: Vt_Cells, data: i32, out: rawptr) -> i32 ---

	ghostty_key_encoder_new :: proc(alloc: rawptr, e: ^Vt_Key_Encoder) -> i32 ---
	ghostty_key_encoder_free :: proc(e: Vt_Key_Encoder) ---
	ghostty_key_encoder_set_from_terminal :: proc(e: Vt_Key_Encoder, t: Vt_Terminal) -> i32 ---
	ghostty_key_encoder_encode :: proc(e: Vt_Key_Encoder, ev: Vt_Key_Event, out: [^]u8, size: uint, n: ^uint) -> i32 ---
	ghostty_key_event_new :: proc(alloc: rawptr, ev: ^Vt_Key_Event) -> i32 ---
	ghostty_key_event_free :: proc(ev: Vt_Key_Event) ---
	ghostty_key_event_set_key :: proc(ev: Vt_Key_Event, key: i32) -> i32 ---
	ghostty_key_event_set_action :: proc(ev: Vt_Key_Event, action: i32) -> i32 ---
	ghostty_key_event_set_mods :: proc(ev: Vt_Key_Event, mods: u16) -> i32 ---
	ghostty_key_event_set_consumed_mods :: proc(ev: Vt_Key_Event, mods: u16) -> i32 ---
	ghostty_key_event_set_unshifted_codepoint :: proc(ev: Vt_Key_Event, cp: u32) -> i32 ---
	ghostty_key_event_set_utf8 :: proc(ev: Vt_Key_Event, s: Vt_String) -> i32 ---

	ghostty_mouse_encoder_new :: proc(alloc: rawptr, e: ^Vt_Mouse_Encoder) -> i32 ---
	ghostty_mouse_encoder_free :: proc(e: Vt_Mouse_Encoder) ---
	ghostty_mouse_encoder_set :: proc(e: Vt_Mouse_Encoder, option: i32, value: rawptr) -> i32 ---
	ghostty_mouse_encoder_set_from_terminal :: proc(e: Vt_Mouse_Encoder, t: Vt_Terminal) -> i32 ---
	ghostty_mouse_encoder_encode :: proc(e: Vt_Mouse_Encoder, ev: Vt_Mouse_Event, out: [^]u8, size: uint, n: ^uint) -> i32 ---
	ghostty_mouse_event_new :: proc(alloc: rawptr, ev: ^Vt_Mouse_Event) -> i32 ---
	ghostty_mouse_event_free :: proc(ev: Vt_Mouse_Event) ---
	ghostty_mouse_event_set_action :: proc(ev: Vt_Mouse_Event, action: i32) -> i32 ---
	ghostty_mouse_event_set_button :: proc(ev: Vt_Mouse_Event, button: i32) -> i32 ---
	ghostty_mouse_event_clear_button :: proc(ev: Vt_Mouse_Event) -> i32 ---
	ghostty_mouse_event_set_mods :: proc(ev: Vt_Mouse_Event, mods: u16) -> i32 ---
	ghostty_mouse_event_set_position :: proc(ev: Vt_Mouse_Event, pos: Vt_Mouse_Position) -> i32 ---
}
