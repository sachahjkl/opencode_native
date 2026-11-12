package ocntools

// src/vt_gen.odin, from the headers of the libghostty-vt that is built: its numbers and its calls, as they are at that commit. A number
// copied by hand still links when it moves, and then sets another option; here a name that went stops the tool, and a type it does
// not know too. What is used is listed below: the headers hold a thousand names, the program forty calls.
//   ocntools vt [--check] [--headers folder]

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"

VT_HEADERS :: VT_SOURCE + "/include/ghostty/vt"
VT_GEN     :: "src/vt_gen.odin"
VT_ANSI_BIT :: 15   // ghostty_mode_new: what says a mode is an ANSI one

Vt_Number :: struct { odin, c: string }

VT_NUMBERS :: [?]Vt_Number{
	{"VT_OK", "GHOSTTY_SUCCESS"},
	{"VT_OUT_OF_SPACE", "GHOSTTY_OUT_OF_SPACE"},

	{"VT_MODE_BRACKETED_PASTE", "GHOSTTY_MODE_BRACKETED_PASTE"},
	{"VT_MODE_FOCUS_EVENT", "GHOSTTY_MODE_FOCUS_EVENT"},

	{"VT_STYLE_BOLD", "GHOSTTY_STYLE_FLAG_BOLD"},
	{"VT_STYLE_FAINT", "GHOSTTY_STYLE_FLAG_FAINT"},
	{"VT_STYLE_INVERSE", "GHOSTTY_STYLE_FLAG_INVERSE"},
	{"VT_STYLE_INVISIBLE", "GHOSTTY_STYLE_FLAG_INVISIBLE"},
	{"VT_STYLE_STRIKETHROUGH", "GHOSTTY_STYLE_FLAG_STRIKETHROUGH"},
	{"VT_STYLE_UNDERLINE", "GHOSTTY_STYLE_UNDERLINE_MASK"},

	{"VT_SCROLL_TOP", "GHOSTTY_TERMINAL_SCROLL_VIEWPORT_TOP"},
	{"VT_SCROLL_BOTTOM", "GHOSTTY_TERMINAL_SCROLL_VIEWPORT_BOTTOM"},
	{"VT_SCROLL_DELTA", "GHOSTTY_TERMINAL_SCROLL_VIEWPORT_DELTA"},
	{"VT_SCROLL_ROW", "GHOSTTY_TERMINAL_SCROLL_VIEWPORT_ROW"},

	{"VT_OPT_USERDATA", "GHOSTTY_TERMINAL_OPT_USERDATA"},
	{"VT_OPT_COLOR_PALETTE", "GHOSTTY_TERMINAL_OPT_COLOR_PALETTE"},
	{"VT_OPT_WRITE_PTY", "GHOSTTY_TERMINAL_OPT_WRITE_PTY"},
	{"VT_OPT_TITLE_CHANGED", "GHOSTTY_TERMINAL_OPT_TITLE_CHANGED"},
	{"VT_OPT_COLOR_FOREGROUND", "GHOSTTY_TERMINAL_OPT_COLOR_FOREGROUND"},
	{"VT_OPT_COLOR_BACKGROUND", "GHOSTTY_TERMINAL_OPT_COLOR_BACKGROUND"},
	{"VT_OPT_SCROLLBACK_MAX_LINES", "GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_LINES"},
	{"VT_OPT_SELECTION", "GHOSTTY_TERMINAL_OPT_SELECTION"},

	{"VT_DATA_SCROLLBAR", "GHOSTTY_TERMINAL_DATA_SCROLLBAR"},
	{"VT_DATA_MOUSE_TRACKING", "GHOSTTY_TERMINAL_DATA_MOUSE_TRACKING"},
	{"VT_DATA_TITLE", "GHOSTTY_TERMINAL_DATA_TITLE"},
	{"VT_DATA_MODE", "GHOSTTY_TERMINAL_DATA_MODE"},
	{"VT_DATA_SELECTION", "GHOSTTY_TERMINAL_DATA_SELECTION"},

	{"VT_POINT_VIEWPORT", "GHOSTTY_POINT_TAG_VIEWPORT"},
	{"VT_POINT_SCREEN", "GHOSTTY_POINT_TAG_SCREEN"},

	{"VT_FORMAT_UNWRAP", "GHOSTTY_FORMATTER_OPT_UNWRAP"},
	{"VT_FORMAT_SELECTION", "GHOSTTY_FORMATTER_OPT_SELECTION"},

	{"VT_STATE_ROW_ITERATOR", "GHOSTTY_RENDER_STATE_DATA_ROW_ITERATOR"},
	{"VT_STATE_CURSOR_STYLE", "GHOSTTY_RENDER_STATE_DATA_CURSOR_VISUAL_STYLE"},
	{"VT_STATE_CURSOR_VISIBLE", "GHOSTTY_RENDER_STATE_DATA_CURSOR_VISIBLE"},
	{"VT_STATE_CURSOR_IN_VIEW", "GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_HAS_VALUE"},
	{"VT_STATE_CURSOR_X", "GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_X"},
	{"VT_STATE_CURSOR_Y", "GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_Y"},
	{"VT_STATE_COLORS", "GHOSTTY_RENDER_STATE_DATA_COLORS"},
	{"VT_STATE_DIRTY", "GHOSTTY_RENDER_STATE_DATA_DIRTY"},

	{"VT_DIRTY_FALSE", "GHOSTTY_RENDER_STATE_DIRTY_FALSE"},
	{"VT_DIRTY_FULL", "GHOSTTY_RENDER_STATE_DIRTY_FULL"},

	{"VT_CURSOR_BAR", "GHOSTTY_CURSOR_STYLE_BAR"},
	{"VT_CURSOR_BLOCK", "GHOSTTY_CURSOR_STYLE_BLOCK"},
	{"VT_CURSOR_UNDERLINE", "GHOSTTY_CURSOR_STYLE_UNDERLINE"},

	{"VT_ROW_CELLS", "GHOSTTY_RENDER_STATE_ROW_DATA_CELLS"},
	{"VT_ROW_SELECTION", "GHOSTTY_RENDER_STATE_ROW_DATA_SELECTION"},
	{"VT_ROW_DIRTY", "GHOSTTY_RENDER_STATE_ROW_DATA_DIRTY"},

	{"VT_CELL_STYLE", "GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_STYLE"},
	{"VT_CELL_GRAPHEMES_BUF", "GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_BUF"},
	{"VT_CELL_BG", "GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_BG_COLOR"},
	{"VT_CELL_FG", "GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_FG_COLOR"},

	{"VT_ACTION_PRESS", "GHOSTTY_KEY_ACTION_PRESS"},
	{"VT_ACTION_REPEAT", "GHOSTTY_KEY_ACTION_REPEAT"},

	{"VT_MODS_SHIFT", "GHOSTTY_MODS_SHIFT"},
	{"VT_MODS_CTRL", "GHOSTTY_MODS_CTRL"},
	{"VT_MODS_ALT", "GHOSTTY_MODS_ALT"},

	{"VT_MOUSE_PRESS", "GHOSTTY_MOUSE_ACTION_PRESS"},
	{"VT_MOUSE_RELEASE", "GHOSTTY_MOUSE_ACTION_RELEASE"},
	{"VT_MOUSE_MOTION", "GHOSTTY_MOUSE_ACTION_MOTION"},

	{"VT_MOUSE_LEFT", "GHOSTTY_MOUSE_BUTTON_LEFT"},
	{"VT_MOUSE_RIGHT", "GHOSTTY_MOUSE_BUTTON_RIGHT"},
	{"VT_MOUSE_MIDDLE", "GHOSTTY_MOUSE_BUTTON_MIDDLE"},
	{"VT_MOUSE_FOUR", "GHOSTTY_MOUSE_BUTTON_FOUR"},
	{"VT_MOUSE_FIVE", "GHOSTTY_MOUSE_BUTTON_FIVE"},

	{"VT_MOUSE_OPT_SIZE", "GHOSTTY_MOUSE_ENCODER_OPT_SIZE"},
	{"VT_MOUSE_OPT_ANY_PRESSED", "GHOSTTY_MOUSE_ENCODER_OPT_ANY_BUTTON_PRESSED"},
	{"VT_MOUSE_OPT_TRACK_LAST_CELL", "GHOSTTY_MOUSE_ENCODER_OPT_TRACK_LAST_CELL"},

	{"VT_KEY_COMMA", "GHOSTTY_KEY_COMMA"},
	{"VT_KEY_DIGIT_0", "GHOSTTY_KEY_DIGIT_0"},
	{"VT_KEY_EQUAL", "GHOSTTY_KEY_EQUAL"},
	{"VT_KEY_A", "GHOSTTY_KEY_A"},
	{"VT_KEY_MINUS", "GHOSTTY_KEY_MINUS"},
	{"VT_KEY_PERIOD", "GHOSTTY_KEY_PERIOD"},
	{"VT_KEY_SLASH", "GHOSTTY_KEY_SLASH"},
	{"VT_KEY_BACKSPACE", "GHOSTTY_KEY_BACKSPACE"},
	{"VT_KEY_CONTEXT_MENU", "GHOSTTY_KEY_CONTEXT_MENU"},
	{"VT_KEY_ENTER", "GHOSTTY_KEY_ENTER"},
	{"VT_KEY_SPACE", "GHOSTTY_KEY_SPACE"},
	{"VT_KEY_TAB", "GHOSTTY_KEY_TAB"},
	{"VT_KEY_DELETE", "GHOSTTY_KEY_DELETE"},
	{"VT_KEY_END", "GHOSTTY_KEY_END"},
	{"VT_KEY_HOME", "GHOSTTY_KEY_HOME"},
	{"VT_KEY_INSERT", "GHOSTTY_KEY_INSERT"},
	{"VT_KEY_PAGE_DOWN", "GHOSTTY_KEY_PAGE_DOWN"},
	{"VT_KEY_PAGE_UP", "GHOSTTY_KEY_PAGE_UP"},
	{"VT_KEY_ARROW_DOWN", "GHOSTTY_KEY_ARROW_DOWN"},
	{"VT_KEY_ARROW_LEFT", "GHOSTTY_KEY_ARROW_LEFT"},
	{"VT_KEY_ARROW_RIGHT", "GHOSTTY_KEY_ARROW_RIGHT"},
	{"VT_KEY_ARROW_UP", "GHOSTTY_KEY_ARROW_UP"},
	{"VT_KEY_NUMPAD_ADD", "GHOSTTY_KEY_NUMPAD_ADD"},
	{"VT_KEY_NUMPAD_SUBTRACT", "GHOSTTY_KEY_NUMPAD_SUBTRACT"},
	{"VT_KEY_ESCAPE", "GHOSTTY_KEY_ESCAPE"},
	{"VT_KEY_F1", "GHOSTTY_KEY_F1"},
}

// The program counts from the first of these (term_key): they must follow each other.
Vt_Run :: struct { first, last: string, count: i64 }
VT_RUNS :: [?]Vt_Run{
	{"GHOSTTY_KEY_A", "GHOSTTY_KEY_Z", 26},
	{"GHOSTTY_KEY_DIGIT_0", "GHOSTTY_KEY_DIGIT_9", 10},
	{"GHOSTTY_KEY_F1", "GHOSTTY_KEY_F12", 12},
}

VT_CALLS :: [?]string{
	"ghostty_terminal_new", "ghostty_terminal_free", "ghostty_terminal_vt_write", "ghostty_terminal_resize", "ghostty_terminal_set",
	"ghostty_terminal_get", "ghostty_terminal_scroll_viewport",
	"ghostty_terminal_grid_ref", "ghostty_terminal_grid_ref_track", "ghostty_tracked_grid_ref_snapshot", "ghostty_tracked_grid_ref_free",
	"ghostty_formatter_terminal_new", "ghostty_formatter_set", "ghostty_formatter_format_buf", "ghostty_formatter_free",
	"ghostty_render_state_new", "ghostty_render_state_free", "ghostty_render_state_update", "ghostty_render_state_clean",
	"ghostty_render_state_get",
	"ghostty_render_state_row_iterator_new", "ghostty_render_state_row_iterator_free", "ghostty_render_state_row_iterator_next",
	"ghostty_render_state_row_get", "ghostty_render_state_row_cells_new", "ghostty_render_state_row_cells_free",
	"ghostty_render_state_row_cells_next", "ghostty_render_state_row_cells_get",
	"ghostty_key_encoder_new", "ghostty_key_encoder_free", "ghostty_key_encoder_set_from_terminal", "ghostty_key_encoder_encode",
	"ghostty_key_event_new", "ghostty_key_event_free", "ghostty_key_event_set_key", "ghostty_key_event_set_action",
	"ghostty_key_event_set_mods", "ghostty_key_event_set_consumed_mods", "ghostty_key_event_set_unshifted_codepoint",
	"ghostty_key_event_set_utf8",
	"ghostty_mouse_encoder_new", "ghostty_mouse_encoder_free", "ghostty_mouse_encoder_set", "ghostty_mouse_encoder_set_from_terminal",
	"ghostty_mouse_encoder_encode",
	"ghostty_mouse_event_new", "ghostty_mouse_event_free", "ghostty_mouse_event_set_action", "ghostty_mouse_event_set_button",
	"ghostty_mouse_event_clear_button", "ghostty_mouse_event_set_mods", "ghostty_mouse_event_set_position",
	"ghostty_color_palette_generate",
}

// What src/vt.odin declares for each of these: their layout is checked there, on the real library (vt_test.odin).
Vt_Type :: struct { c, odin: string }
VT_TYPES :: [?]Vt_Type{
	{"void", ""}, {"bool", "bool"}, {"size_t", "uint"}, {"uint8_t", "u8"}, {"uint16_t", "u16"}, {"uint32_t", "u32"}, {"uint64_t", "u64"},
	{"GhosttyResult", "i32"},
	{"GhosttyTerminal", "Vt_Terminal"}, {"GhosttyRenderState", "Vt_State"}, {"GhosttyRenderStateRowIterator", "Vt_Rows"},
	{"GhosttyRenderStateRowCells", "Vt_Cells"}, {"GhosttyKeyEncoder", "Vt_Key_Encoder"}, {"GhosttyKeyEvent", "Vt_Key_Event"},
	{"GhosttyMouseEncoder", "Vt_Mouse_Encoder"}, {"GhosttyMouseEvent", "Vt_Mouse_Event"},
	{"GhosttyString", "Vt_String"}, {"GhosttyTerminalScrollViewport", "Vt_Scroll"}, {"GhosttyMousePosition", "Vt_Mouse_Position"},
	{"GhosttyPoint", "Vt_Point"}, {"GhosttyGridRef", "Vt_Grid_Ref"}, {"GhosttyTrackedGridRef", "Vt_Tracked_Ref"},
	{"GhosttyFormatter", "Vt_Formatter"}, {"GhosttyColorRgb", "Vt_Rgb"}, {"GhosttyColorPaletteMask", "Vt_Palette_Mask"},
}

Vt_Headers :: struct {
	numbers: map[string]i64,      // the enumerators
	defines: map[string]string,
	enums:   map[string]bool,     // typedef enum: an int
	scalars: map[string]string,   // typedef uint16_t GhosttyMods
	calls:   map[string]string,   // what follows GHOSTTY_API, up to its ;
}

// (a string with // in it would be cut: the headers have none outside their comments)
vt_uncomment :: proc(text: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	for i := 0; i < len(text); {
		rest := text[i:]
		switch {
		case strings.has_prefix(rest, "/*"):
			end := strings.index(rest, "*/")
			if end < 0 { return strings.to_string(b) }
			i += end + 2
		case strings.has_prefix(rest, "//"):
			end := strings.index_byte(rest, '\n')
			if end < 0 { return strings.to_string(b) }
			i += end
		case:
			strings.write_byte(&b, text[i])
			i += 1
		}
	}
	return strings.to_string(b)
}

// A number as the headers write it: 5, -3, 0x7u, 1u << 0, (GhosttyStyleFlags)(1u << 3), SHIFTED << NAME, ghostty_mode_new(2004, false).
vt_eval :: proc(h: ^Vt_Headers, expr: string, depth := 0) -> (value: i64, ok: bool) {
	if depth > 8 { return }
	s := strings.trim_space(expr)
	if strings.has_prefix(s, "-") {   // (the results that are errors: GHOSTTY_OUT_OF_SPACE = -3)
		v := vt_eval(h, s[1:], depth + 1) or_return
		return -v, true
	}
	if at := strings.index(s, "ghostty_mode_new("); at >= 0 {
		args := strings.split(s[at + len("ghostty_mode_new("):], ",", context.temp_allocator)
		if len(args) != 2 { return }
		v := vt_eval(h, args[0], depth + 1) or_return
		ansi: i64 = strings.contains(args[1], "true") ? 1 : 0
		return v & 0x7FFF | ansi << VT_ANSI_BIT, true
	}
	for {   // (a cast)
		open := strings.index(s, "(Ghostty")
		if open < 0 { break }
		close := strings.index_byte(s[open:], ')')
		if close < 0 { return }
		s = strings.concatenate({s[:open], s[open + close + 1:]}, context.temp_allocator)
	}
	s, _ = strings.remove_all(s, "(", context.temp_allocator)
	s, _ = strings.remove_all(s, ")", context.temp_allocator)
	parts := strings.split(s, "<<", context.temp_allocator)
	if len(parts) > 2 { return }
	for p, i in parts {
		word := strings.trim_space(p)
		v: i64
		if word != "" && word[0] >= '0' && word[0] <= '9' {
			n, parsed := strconv.parse_i64(strings.trim_right(word, "uUlL"))
			if !parsed { return }
			v = n
		} else if known, has := h.numbers[word]; has {
			v = known
		} else if body, defined := h.defines[word]; defined {
			v = vt_eval(h, body, depth + 1) or_return
		} else {
			return
		}
		value = i == 0 ? v : value << uint(v)
	}
	return value, true
}

// One header's text, into what is known. An enumerator with no value of its own follows the last.
vt_read :: proc(h: ^Vt_Headers, source: string) {
	text, _ := strings.replace_all(vt_uncomment(source), "\r\n", "\n", context.temp_allocator)
	text, _ = strings.replace_all(text, "\\\n", " ", context.temp_allocator)
	for line in strings.split_lines(text, context.temp_allocator) {
		l := strings.trim_space(line)
		if strings.has_prefix(l, "#define ") {
			fields := strings.fields(l, context.temp_allocator)
			if len(fields) < 3 || strings.contains_rune(fields[1], '(') { continue }
			h.defines[fields[1]] = strings.join(fields[2:], " ", context.temp_allocator)
		}
		if strings.has_prefix(l, "typedef ") && strings.has_suffix(l, ";") {
			fields := strings.fields(l[:len(l) - 1], context.temp_allocator)
			if len(fields) == 3 && strings.has_suffix(fields[1], "_t") { h.scalars[fields[2]] = fields[1] }
		}
	}
	rest := text
	for {
		at := strings.index(rest, "typedef enum")
		if at < 0 { break }
		rest = rest[at:]
		open := strings.index_byte(rest, '{')
		close := strings.index_byte(rest, '}')
		if open < 0 || close < open { break }
		after := rest[close + 1:]
		end := strings.index_byte(after, ';')
		if end < 0 { break }
		h.enums[strings.trim_space(after[:end])] = true
		next: i64 = 0
		for item in strings.split(rest[open + 1:close], ",", context.temp_allocator) {
			word := strings.trim_space(item)
			if word == "" { continue }
			name := word
			if eq := strings.index_byte(word, '='); eq >= 0 {
				name = strings.trim_space(word[:eq])
				v, known := vt_eval(h, word[eq + 1:])
				if !known { continue }   // (the _MAX_VALUE that sizes an enum)
				next = v
			}
			h.numbers[name] = next
			next += 1
		}
		rest = after
	}
	rest = text
	for {
		at := strings.index(rest, "GHOSTTY_API")
		if at < 0 { break }
		rest = rest[at + len("GHOSTTY_API"):]
		end := strings.index_byte(rest, ';')
		if end < 0 { break }
		decl := strings.join(strings.fields(rest[:end], context.temp_allocator), " ", context.temp_allocator)
		if open := strings.index_byte(decl, '('); open > 0 {
			head := strings.trim_space(decl[:open])
			name := head[strings.last_index_any(head, " *") + 1:]
			h.calls[name] = decl
		}
		rest = rest[end:]
	}
}

// A C type as Odin says it. "": none (void).
vt_type :: proc(h: ^Vt_Headers, c: string) -> (odin: string, ok: bool) {
	stars := strings.count(c, "*")
	base, _ := strings.remove_all(c, "*", context.temp_allocator)
	base, _ = strings.remove_all(base, "const ", context.temp_allocator)
	base = strings.trim_space(base)
	if stars > 1 { return }
	if stars == 1 {
		switch base {
		case "void", "GhosttyAllocator": return "rawptr", true
		case "char", "uint8_t":          return "[^]u8", true
		}
	}
	types := VT_TYPES
	if scalar, is := h.scalars[base]; is { base = scalar }
	plain := ""
	found := false
	for t in types { if t.c == base { plain, found = t.odin, true } }
	if !found && base in h.enums { plain, found = "i32", true }
	if !found { return }
	return stars == 1 ? fmt.tprintf("^%s", plain) : plain, true
}

@(private = "file")
is_word :: proc(c: u8) -> bool { return c == '_' || c >= '0' && c <= '9' || c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' }

// The declaration of a call, in a foreign block.
vt_call :: proc(h: ^Vt_Headers, name, decl: string) -> (line: string, ok: bool) {
	open := strings.index_byte(decl, '(')
	close := strings.last_index_byte(decl, ')')
	if open < 0 || close < open { return }
	head := strings.trim_space(decl[:open])
	ret := vt_type(h, strings.trim_suffix(head, name)) or_return
	args := make([dynamic]string, context.temp_allocator)
	for a in strings.split(decl[open + 1:close], ",", context.temp_allocator) {
		arg := strings.trim_space(a)
		if arg == "" || arg == "void" { continue }
		at := len(arg)
		for at > 0 && is_word(arg[at - 1]) { at -= 1 }
		t := vt_type(h, arg[:at]) or_return
		word := arg[at:]
		switch word { case "context", "map", "proc", "in", "not_in", "do", "defer": word = strings.concatenate({word, "_"}, context.temp_allocator) }
		append(&args, fmt.tprintf("%s: %s", word, t))
	}
	arrow := ret != "" ? fmt.tprintf(" -> %s", ret) : ""
	return fmt.tprintf("\t%s :: proc(%s)%s ---", name, strings.join(args[:], ", ", context.temp_allocator), arrow), true
}

// The file, or every name that stops it.
vt_generate :: proc(h: ^Vt_Headers, commit: string) -> (text: string, problems: []string) {
	bad := make([dynamic]string, context.temp_allocator)
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, "// Made by ocntools vt from the headers of libghostty-vt at %s: not to be edited. What it holds: tools/ocntools/vt.odin.\n", commit)
	strings.write_string(&b, "package ocn\n\nwhen ODIN_OS == .Windows {\n\tforeign import ghostty_vt { \"../build/vt/ghostty-vt-static.lib\", \"system:ntdll.lib\" }\n} else {\n\tforeign import ghostty_vt \"../build/vt/libghostty-vt.a\"\n}\n\n")
	number :: proc(h: ^Vt_Headers, c: string) -> (i64, bool) {
		if v, known := h.numbers[c]; known { return v, true }
		if body, defined := h.defines[c]; defined { return vt_eval(h, body) }
		return 0, false
	}
	numbers := VT_NUMBERS
	for n in numbers {
		v, known := number(h, n.c)
		if !known { append(&bad, fmt.tprintf("no number %s", n.c)); continue }
		fmt.sbprintf(&b, "%s :: %d\n", n.odin, v)
	}
	runs := VT_RUNS
	for r in runs {
		first, has_first := number(h, r.first)
		last, has_last := number(h, r.last)
		if !has_first || !has_last || last - first + 1 != r.count { append(&bad, fmt.tprintf("%s to %s do not follow each other", r.first, r.last)) }
	}
	strings.write_string(&b, "\n@(default_calling_convention = \"c\")\nforeign ghostty_vt {\n")
	calls := VT_CALLS
	for name in calls {
		decl, declared := h.calls[name]
		if !declared { append(&bad, fmt.tprintf("no call %s", name)); continue }
		line, known := vt_call(h, name, decl)
		if !known { append(&bad, fmt.tprintf("a type of %s has no Odin name: %s", name, decl)); continue }
		strings.write_string(&b, line)
		strings.write_byte(&b, '\n')
	}
	strings.write_string(&b, "}\n")
	return strings.to_string(b), bad[:]
}

run_vt :: proc(args: []string) -> int {
	folder := VT_HEADERS
	check := false
	for i := 0; i < len(args); i += 1 {
		switch {
		case args[i] == "--check":
			check = true
		case args[i] == "--headers" && i + 1 < len(args):
			i += 1
			folder = args[i]
		case:
			fmt.eprintfln("vt: what is %s?", args[i])
			return EXIT_USAGE
		}
	}
	return vt_run(folder, check)
}

// (`check`: the file must be what these headers make)
vt_run :: proc(folder: string, check: bool) -> int {
	files := make([dynamic]string, context.temp_allocator)
	files_under(folder, &files)
	slice.sort(files[:])
	h: Vt_Headers
	h.numbers = make(map[string]i64, context.temp_allocator)
	h.defines = make(map[string]string, context.temp_allocator)
	h.enums = make(map[string]bool, context.temp_allocator)
	h.scalars = make(map[string]string, context.temp_allocator)
	h.calls = make(map[string]string, context.temp_allocator)
	// (first the defines and the types, whichever header they are in: an enumerator may name one of another)
	for f in files { if strings.has_suffix(f, ".h") { vt_read(&h, read_text(f)) } }
	if len(h.calls) == 0 { fmt.eprintfln("vt: no headers in %s: ocntools build first", folder); return 1 }
	text, problems := vt_generate(&h, GHOSTTY_COMMIT)
	if len(problems) > 0 {
		for p in problems { fmt.eprintfln("vt: %s", p) }
		return 1
	}
	if check {
		now, _ := strings.replace_all(read_text(VT_GEN), "\r\n", "\n", context.temp_allocator)
		if now != text { fmt.eprintfln("vt: %s is not what these headers make: ocntools vt", VT_GEN); return 1 }
		fmt.printfln("vt: %s is what the headers make", VT_GEN)
		return 0
	}
	if os.write_entire_file(VT_GEN, transmute([]byte)text) != nil { fmt.eprintfln("vt: cannot write %s", VT_GEN); return 1 }
	fmt.printfln("vt: %s written", VT_GEN)
	return 0
}
