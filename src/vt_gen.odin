// Made by occtools vt from the headers of libghostty-vt at 0fa3d577a5614150ff8e2c152de5fb9d5c6d2dec: not to be edited. What it holds: tools/occtools/vt.odin.
package occ

when ODIN_OS == .Windows {
	foreign import ghostty_vt { "../build/vt/ghostty-vt-static.lib", "system:ntdll.lib" }
} else {
	foreign import ghostty_vt "../build/vt/libghostty-vt.a"
}

VT_OK :: 0
VT_MODE_BRACKETED_PASTE :: 2004
VT_MODE_FOCUS_EVENT :: 1004
VT_STYLE_BOLD :: 1
VT_STYLE_FAINT :: 4
VT_STYLE_INVERSE :: 16
VT_STYLE_INVISIBLE :: 32
VT_STYLE_STRIKETHROUGH :: 64
VT_STYLE_UNDERLINE :: 1792
VT_SCROLL_TOP :: 0
VT_SCROLL_BOTTOM :: 1
VT_SCROLL_DELTA :: 2
VT_SCROLL_ROW :: 3
VT_OPT_USERDATA :: 1
VT_OPT_WRITE_PTY :: 2
VT_OPT_TITLE_CHANGED :: 6
VT_OPT_COLOR_FOREGROUND :: 12
VT_OPT_COLOR_BACKGROUND :: 13
VT_OPT_SCROLLBACK_MAX_LINES :: 29
VT_DATA_SCROLLBAR :: 9
VT_DATA_MOUSE_TRACKING :: 11
VT_DATA_TITLE :: 12
VT_DATA_MODE :: 37
VT_STATE_ROW_ITERATOR :: 4
VT_STATE_CURSOR_STYLE :: 10
VT_STATE_CURSOR_VISIBLE :: 11
VT_STATE_CURSOR_IN_VIEW :: 14
VT_STATE_CURSOR_X :: 15
VT_STATE_CURSOR_Y :: 16
VT_STATE_COLORS :: 19
VT_CURSOR_BAR :: 0
VT_CURSOR_BLOCK :: 1
VT_CURSOR_UNDERLINE :: 2
VT_ROW_CELLS :: 3
VT_CELL_STYLE :: 2
VT_CELL_GRAPHEMES_BUF :: 4
VT_CELL_BG :: 5
VT_CELL_FG :: 6
VT_ACTION_PRESS :: 1
VT_ACTION_REPEAT :: 2
VT_MODS_SHIFT :: 1
VT_MODS_CTRL :: 2
VT_MODS_ALT :: 4
VT_MOUSE_PRESS :: 0
VT_MOUSE_RELEASE :: 1
VT_MOUSE_MOTION :: 2
VT_MOUSE_LEFT :: 1
VT_MOUSE_RIGHT :: 2
VT_MOUSE_MIDDLE :: 3
VT_MOUSE_FOUR :: 4
VT_MOUSE_FIVE :: 5
VT_MOUSE_OPT_SIZE :: 3
VT_MOUSE_OPT_ANY_PRESSED :: 4
VT_MOUSE_OPT_TRACK_LAST_CELL :: 5
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

@(default_calling_convention = "c")
foreign ghostty_vt {
	ghostty_terminal_new :: proc(allocator: rawptr, terminal: ^Vt_Terminal, cols: u16, rows: u16) -> i32 ---
	ghostty_terminal_free :: proc(terminal: Vt_Terminal) ---
	ghostty_terminal_vt_write :: proc(terminal: Vt_Terminal, data: [^]u8, len: uint) ---
	ghostty_terminal_resize :: proc(terminal: Vt_Terminal, cols: u16, rows: u16, cell_width_px: u32, cell_height_px: u32) -> i32 ---
	ghostty_terminal_set :: proc(terminal: Vt_Terminal, option: i32, value: rawptr) -> i32 ---
	ghostty_terminal_get :: proc(terminal: Vt_Terminal, data: i32, out: rawptr) -> i32 ---
	ghostty_terminal_scroll_viewport :: proc(terminal: Vt_Terminal, behavior: Vt_Scroll) -> i32 ---
	ghostty_render_state_new :: proc(allocator: rawptr, state: ^Vt_State) -> i32 ---
	ghostty_render_state_free :: proc(state: Vt_State) ---
	ghostty_render_state_update :: proc(state: Vt_State, terminal: Vt_Terminal) -> i32 ---
	ghostty_render_state_get :: proc(state: Vt_State, data: i32, out: rawptr) -> i32 ---
	ghostty_render_state_row_iterator_new :: proc(allocator: rawptr, out_iterator: ^Vt_Rows) -> i32 ---
	ghostty_render_state_row_iterator_free :: proc(iterator: Vt_Rows) ---
	ghostty_render_state_row_iterator_next :: proc(iterator: Vt_Rows) -> bool ---
	ghostty_render_state_row_get :: proc(iterator: Vt_Rows, data: i32, out: rawptr) -> i32 ---
	ghostty_render_state_row_cells_new :: proc(allocator: rawptr, out_cells: ^Vt_Cells) -> i32 ---
	ghostty_render_state_row_cells_free :: proc(cells: Vt_Cells) ---
	ghostty_render_state_row_cells_next :: proc(cells: Vt_Cells) -> bool ---
	ghostty_render_state_row_cells_get :: proc(cells: Vt_Cells, data: i32, out: rawptr) -> i32 ---
	ghostty_key_encoder_new :: proc(allocator: rawptr, encoder: ^Vt_Key_Encoder) -> i32 ---
	ghostty_key_encoder_free :: proc(encoder: Vt_Key_Encoder) ---
	ghostty_key_encoder_set_from_terminal :: proc(encoder: Vt_Key_Encoder, terminal: Vt_Terminal) -> i32 ---
	ghostty_key_encoder_encode :: proc(encoder: Vt_Key_Encoder, event: Vt_Key_Event, buf: [^]u8, buf_len: uint, out_written: ^uint) -> i32 ---
	ghostty_key_event_new :: proc(allocator: rawptr, event: ^Vt_Key_Event) -> i32 ---
	ghostty_key_event_free :: proc(event: Vt_Key_Event) ---
	ghostty_key_event_set_key :: proc(event: Vt_Key_Event, key: i32) -> i32 ---
	ghostty_key_event_set_action :: proc(event: Vt_Key_Event, action: i32) -> i32 ---
	ghostty_key_event_set_mods :: proc(event: Vt_Key_Event, mods: u16) -> i32 ---
	ghostty_key_event_set_consumed_mods :: proc(event: Vt_Key_Event, consumed_mods: u16) -> i32 ---
	ghostty_key_event_set_unshifted_codepoint :: proc(event: Vt_Key_Event, codepoint: u32) -> i32 ---
	ghostty_key_event_set_utf8 :: proc(event: Vt_Key_Event, utf8: Vt_String) -> i32 ---
	ghostty_mouse_encoder_new :: proc(allocator: rawptr, encoder: ^Vt_Mouse_Encoder) -> i32 ---
	ghostty_mouse_encoder_free :: proc(encoder: Vt_Mouse_Encoder) ---
	ghostty_mouse_encoder_set :: proc(encoder: Vt_Mouse_Encoder, option: i32, value: rawptr) -> i32 ---
	ghostty_mouse_encoder_set_from_terminal :: proc(encoder: Vt_Mouse_Encoder, terminal: Vt_Terminal) -> i32 ---
	ghostty_mouse_encoder_encode :: proc(encoder: Vt_Mouse_Encoder, event: Vt_Mouse_Event, buf: [^]u8, buf_len: uint, out_written: ^uint) -> i32 ---
	ghostty_mouse_event_new :: proc(allocator: rawptr, event: ^Vt_Mouse_Event) -> i32 ---
	ghostty_mouse_event_free :: proc(event: Vt_Mouse_Event) ---
	ghostty_mouse_event_set_action :: proc(event: Vt_Mouse_Event, action: i32) -> i32 ---
	ghostty_mouse_event_set_button :: proc(event: Vt_Mouse_Event, button: i32) -> i32 ---
	ghostty_mouse_event_clear_button :: proc(event: Vt_Mouse_Event) -> i32 ---
	ghostty_mouse_event_set_mods :: proc(event: Vt_Mouse_Event, mods: u16) -> i32 ---
	ghostty_mouse_event_set_position :: proc(event: Vt_Mouse_Event, position: Vt_Mouse_Position) -> i32 ---
}
