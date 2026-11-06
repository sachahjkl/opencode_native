// What a tool call shows when it is open, by what the tool does: a diff for what edits a file (the server's own patch, else
// one made here with core:diff from the call's input), the lines of a file with their numbers, matches under their file,
// a command and what it printed, a checklist. The rest shows its input as keys and values, never as raw JSON.
package occ

import "core:diff"
import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:slice"
import "core:strconv"
import "core:strings"
import "gt:ui"

Tool_Kind :: enum u8 { Other, Edit, Read, Search, Shell, Todo }

tool_kind :: proc(name: string) -> Tool_Kind {
	switch {
	case name == "edit" || name == "write" || name == "multiedit" || strings.contains(name, "patch"): return .Edit
	case name == "read" || name == "view":                                                             return .Read
	case name == "grep" || name == "glob" || name == "list":                                           return .Search
	case strings.contains(name, "shell") || strings.contains(name, "bash"):                            return .Shell
	case strings.contains(name, "todo"):                                                               return .Todo
	}
	return .Other
}

////////////////////////////////
// The patch of a call

@(private = "file")
bit_set_at :: proc(bits: []u64, i: int) -> bool { return bits[i / 64] & (u64(1) << uint(i % 64)) != 0 }

// `old` to `new` as the lines of a unified diff, without its headers (a whole snippet: no numbers to give, no hunks).
diff_lines :: proc(old, new: string, allocator := context.allocator) -> string {
	a := strings.split_lines(old, context.temp_allocator)
	b := strings.split_lines(new, context.temp_allocator)
	c, err := diff.diff(a, b, context.temp_allocator, context.temp_allocator)
	if err != nil { return "" }
	out := strings.builder_make(allocator)
	line :: proc(out: ^strings.Builder, sign: byte, s: string) {
		strings.write_byte(out, sign)
		strings.write_string(out, s)
		strings.write_byte(out, '\n')
	}
	b_bits := c.bits[(c.n + 63) / 64:]
	i, j := 0, 0
	for i < c.n || j < c.m {
		if i < c.n && bit_set_at(c.bits, i) { line(&out, '-', a[i]); i += 1; continue }
		if j < c.m && bit_set_at(b_bits, j) { line(&out, '+', b[j]); j += 1; continue }
		if i < c.n { line(&out, ' ', a[i]) }
		i += 1
		j += 1
	}
	return strings.to_string(out)
}

// The first of `keys` the call's input has.
@(private = "file")
input_str :: proc(v: json.Value, keys: ..string) -> (s: string, ok: bool) {
	for k in keys {
		if t, is := jget(v, k).(json.String); is { return string(t), true }
	}
	return
}

// The diff of a call: the server's, else made once from what it was asked (a call still running, an older server).
part_patch :: proc(p: ^Part, a := context.allocator) -> string {
	if p.patch != "" || p.patch_tried || p.input == "" { return p.patch }
	p.patch_tried = true
	v, err := json.parse_string(p.input, allocator = context.temp_allocator)
	if err != nil { return "" }
	if old, has := input_str(v, "oldString", "old_string"); has {
		new, _ := input_str(v, "newString", "new_string")
		part_patch_set(p, diff_lines(old, new, a))
	} else if content, is := input_str(v, "content"); is {
		part_patch_set(p, diff_lines("", content, a))
	}
	return p.patch
}

// `patch` is the call's: what it adds and removes counted once.
part_patch_set :: proc(p: ^Part, patch: string) {
	p.patch = patch
	p.added, p.removed = 0, 0
	for l in diff_parse(patch) {
		if l.sign == '+' { p.added += 1 } else if l.sign == '-' { p.removed += 1 }
	}
}

////////////////////////////////
// A diff

@(private = "file")
Diff_Line :: struct {
	sign:   byte,       // ' ', '+', '-', '@' (a hunk begins)
	text:   string,
	old_no, new_no: int,
	lo, hi: int,        // what changed in it, in bytes of `text` (lo == hi: nothing to mark)
}

// The number after `mark` in a hunk's header, "@@ -12,3 +14,4 @@".
@(private = "file")
hunk_start :: proc(h: string, mark: byte) -> int {
	i := strings.index_byte(h, mark)
	if i < 0 { return 0 }
	end := i + 1
	for end < len(h) && h[end] >= '0' && h[end] <= '9' { end += 1 }
	n, _ := strconv.parse_int(h[i + 1:end])
	return n
}

// The count after `mark`'s number in a hunk's header: "-12,3". (None said: one line.)
@(private = "file")
hunk_count :: proc(h: string, mark: byte) -> int {
	i := strings.index_byte(h, mark)
	if i < 0 { return 0 }
	end := i + 1
	for end < len(h) && h[end] >= '0' && h[end] <= '9' { end += 1 }
	if end >= len(h) || h[end] != ',' { return 1 }
	stop := end + 1
	for stop < len(h) && h[stop] >= '0' && h[stop] <= '9' { stop += 1 }
	n, _ := strconv.parse_int(h[end + 1:stop])
	return n
}

// What comes before a file's first hunk. (The line "Binary files … differ" says something, and stays.)
@(private = "file")
file_header :: proc(l: string) -> bool {
	for p in ([]string{"diff --git ", "index ", "new file mode ", "deleted file mode ", "old mode ", "new mode ", "similarity index ", "rename from ", "rename to ", "Index: ", "====="}) {
		if strings.has_prefix(l, p) { return true }
	}
	return false
}

// A line of a hunk begins with a sign, and only the counts of its header say where it ends: "--- x" there is the line "-- x" removed. Out
// of a hunk, "--- x" is a file's header. What diff_lines writes has neither headers nor hunks: it is all lines, whatever they look like.
Diff_Mode :: enum u8 { Header, Hunk }

diff_parse :: proc(patch: string) -> []Diff_Line {
	out := make([dynamic]Diff_Line, context.temp_allocator)
	old_no, new_no := 0, 0
	old_left, new_left := 0, 0
	mode := Diff_Mode.Header
	// (a line of diff_lines always has its sign first: a header or a hunk's start can only be the real thing)
	headers := false
	scan := patch
	for l in strings.split_lines_iterator(&scan) {
		if strings.has_prefix(l, "@@") || file_header(l) { headers = true; break }
	}
	line :: proc(out: ^[dynamic]Diff_Line, l: string, old_no, new_no: ^int) {
		switch {
		case strings.has_prefix(l, "+"):
			append(out, Diff_Line{sign = '+', text = l[1:], new_no = new_no^})
			if new_no^ > 0 { new_no^ += 1 }
		case strings.has_prefix(l, "-"):
			append(out, Diff_Line{sign = '-', text = l[1:], old_no = old_no^})
			if old_no^ > 0 { old_no^ += 1 }
		case:
			append(out, Diff_Line{sign = ' ', text = strings.trim_prefix(l, " "), old_no = old_no^, new_no = new_no^})
			if old_no^ > 0 { old_no^ += 1 }
			if new_no^ > 0 { new_no^ += 1 }
		}
	}
	rest := patch
	for l in strings.split_lines_iterator(&rest) {
		if strings.has_prefix(l, "\\ ") { continue }
		switch mode {
		case .Hunk:
			line(&out, l, &old_no, &new_no)
			if !strings.has_prefix(l, "+") { old_left -= 1 }
			if !strings.has_prefix(l, "-") { new_left -= 1 }
			if old_left <= 0 && new_left <= 0 { mode = .Header }
		case .Header:
			switch {
			case strings.has_prefix(l, "@@"):
				old_no, new_no = hunk_start(l, '-'), hunk_start(l, '+')
				old_left, new_left = hunk_count(l, '-'), hunk_count(l, '+')
				if len(out) > 0 { append(&out, Diff_Line{sign = '@'}) }
				if old_left > 0 || new_left > 0 { mode = .Hunk }
			case !headers:
				line(&out, l, &old_no, &new_no)
			case file_header(l), strings.has_prefix(l, "--- "), strings.has_prefix(l, "+++ "):
			case:
				line(&out, l, &old_no, &new_no)
			}
		}
	}
	return out[:]
}

// In a block of lines removed then added, the k-th of each are the same line changed: what they share at each end is
// left plain, what is between is what the eye looks for.
@(private = "file")
diff_mark :: proc(lines: []Diff_Line) {
	i := 0
	for i < len(lines) {
		if lines[i].sign != '-' { i += 1; continue }
		d0 := i
		for i < len(lines) && lines[i].sign == '-' { i += 1 }
		a0 := i
		for i < len(lines) && lines[i].sign == '+' { i += 1 }
		for k in 0 ..< min(a0 - d0, i - a0) {
			x, y := &lines[d0 + k], &lines[a0 + k]
			p := 0
			for p < len(x.text) && p < len(y.text) && x.text[p] == y.text[p] { p += 1 }
			for p > 0 && p < len(x.text) && x.text[p] & 0xC0 == 0x80 { p -= 1 }   // (not inside a character)
			s := 0
			for s < len(x.text) - p && s < len(y.text) - p && x.text[len(x.text) - 1 - s] == y.text[len(y.text) - 1 - s] { s += 1 }
			for s > 0 && x.text[len(x.text) - s] & 0xC0 == 0x80 { s -= 1 }
			if p == 0 && s == 0 { continue }   // (nothing shared: the whole line is the change)
			x.lo, x.hi = p, len(x.text) - s
			y.lo, y.hi = p, len(y.text) - s
		}
	}
}

// A line's text with its tabs opened and its length bounded (`s` is one line).
@(private = "file")
line_shown :: proc(s: string) -> string {
	t, _ := strings.replace_all(s, "\t", TOOL_TAB, context.temp_allocator)
	return ellipsize(t, TOOL_LINE_CHARS)
}

@(private = "file")
gutter :: proc(id: string, n: int, em: f32) {
	s := n > 0 ? fmt.tprintf("%d", n) : ""
	text(id, s, hex(HEX_DIFF_LINE_NO), ui.Style_Mod{font = the_app.mono, font_size = math.round(em * FS_CAPTION), text_align = .Right}, ui.px(em * GUTTER_EM))
}

@(private = "file")
diff_row :: proc(app: ^App, l: Diff_Line, k: int, numbered: bool, em: f32) {
	h := math.round(em * 1.3)
	fs := math.round(em * FS_SMALL)
	if l.sign == '@' {
		ui.next({width = ui.fill(), height = ui.px(math.round(em * 0.9)), axis = .X, cross = .Center})
		if ui.row(.Center, id = fmt.tprintf("###dh%d", k)) {
			ui.spacer(ui.px(em * 0.6))
			text("h", "⋯", hex(HEX_FAINT), ui.Style_Mod{font = app.mono, font_size = fs})
		}
		return
	}
	bg := CLEAR
	col := hex(HEX_TOOL_OUTPUT)
	mark := CLEAR
	if l.sign == '+' { bg, col, mark = hex(HEX_DIFF_ADD_BG), hex(HEX_DIFF_ADD_TEXT), hex(HEX_DIFF_ADD_MARK) }
	if l.sign == '-' { bg, col, mark = hex(HEX_DIFF_DEL_BG), hex(HEX_DIFF_DEL_TEXT), hex(HEX_DIFF_DEL_MARK) }
	ui.next({width = ui.fill(), height = ui.px(h), axis = .X, cross = .Center, bg = bg, radius = 0})
	b := ui.build_box({.Draw_Background, .Clip}, fmt.tprintf("###dl%d", k))
	if ui.parent(b) {
		if numbered {
			gutter("o", l.old_no, em)
			gutter("n", l.new_no, em)
			ui.spacer(ui.px(em * 0.4))
		} else {
			ui.spacer(ui.px(em * 0.5))
		}
		sign := l.sign == ' ' ? " " : l.sign == '+' ? "+" : "−"
		text("s", sign, l.sign == '+' ? hex(HEX_GREEN) : l.sign == '-' ? hex(HEX_RED) : hex(HEX_FAINT), ui.Style_Mod{font = app.mono_bold, font_size = fs}, ui.px(em * 1))
		st := ui.Style_Mod{font = app.mono, font_size = fs}
		if l.hi > l.lo {
			if l.lo > 0 { text("a", line_shown(l.text[:l.lo]), col, st) }
			ui.next({width = ui.text_size(0), height = ui.px(h), font = app.mono, font_size = fs, bg = mark, fg = hex(HEX_BRIGHT), radius = 2 * ui.scale(), text_pad = 0})
			ui.build_box({.Draw_Text, .Draw_Background}, fmt.tprintf("%s###b", label_safe(line_shown(l.text[l.lo:l.hi]))))
			text("c", line_shown(l.text[l.hi:]), col, st, ui.fill())
		} else {
			text("t", line_shown(l.text), col, st, ui.fill())
		}
	}
}

// The lines of a patch in a well, at most `max_lines` of them (the rest is counted).
diff_view :: proc(app: ^App, id, patch: string, em: f32, max_lines: int) {
	lines := diff_parse(patch)
	if len(lines) == 0 { return }
	diff_mark(lines)
	numbered := false
	for l in lines { if l.old_no > 0 || l.new_no > 0 { numbered = true; break } }
	ui.next({width = ui.fill(), height = ui.children_sum(), axis = .Y})
	if well(id, radius = 6, base = HEX_CODE_WELL) {
		ui.spacer(ui.px(em * 0.3))
		shown := min(len(lines), max_lines)
		for l, k in lines[:shown] { diff_row(app, l, k, numbered, em) }
		more_lines(len(lines) - shown, em)
		ui.spacer(ui.px(em * 0.3))
	}
}

@(private = "file")
more_lines :: proc(n: int, em: f32) {
	if n <= 0 { return }
	ui.next({width = ui.fill(), height = ui.px(em * 1.5), axis = .X, cross = .Center})
	if ui.row(.Center, id = "###more") {
		ui.spacer(ui.px(em * 0.75))
		text("m", fmt.tprintf("… %d more lines", n), hex(HEX_FAINT), ui.Style_Mod{font = the_app.mono, font_size = math.round(em * FS_SMALL)})
	}
}

////////////////////////////////
// Lines of a file, matches

@(private = "file")
code_row :: proc(app: ^App, no: int, s: string, k: int, em: f32) {
	ui.next({width = ui.fill(), height = ui.px(math.round(em * 1.3)), axis = .X, cross = .Center})
	if ui.row(.Center, id = fmt.tprintf("###cl%d", k)) {
		gutter("n", no, em)
		ui.spacer(ui.px(em * 0.7))
		text("t", line_shown(s), hex(HEX_TOOL_OUTPUT), ui.Style_Mod{font = app.mono, font_size = math.round(em * FS_SMALL)}, ui.fill())
	}
}

// "12: text": the number and the rest.
@(private = "file")
numbered_line :: proc(l: string) -> (no: int, rest: string, ok: bool) {
	i := strings.index_byte(l, ':')
	if i <= 0 { return }
	n, is := strconv.parse_int(l[:i], 10)
	if !is { return }
	rest = l[i + 1:]
	return n, strings.trim_prefix(rest, " "), true
}

// A file as the read tool gives it: a line of what was read, then "number: text" lines.
read_view :: proc(app: ^App, id, output: string, em: f32, max_lines: int) {
	ui.next({width = ui.fill(), height = ui.children_sum(), axis = .Y})
	if well(id, radius = 6, base = HEX_CODE_WELL) {
		ui.spacer(ui.px(em * 0.4))
		rest := output
		k := 0
		left := 0
		for l in strings.split_lines_iterator(&rest) {
			no, t, ok := numbered_line(l)
			if !ok { continue }
			if k == max_lines { left += 1; continue }
			code_row(app, no, t, k, em)
			k += 1
		}
		more_lines(left, em)
		ui.spacer(ui.px(em * 0.4))
	}
}

// Whether `output` reads as lines of a file (a tool of another name may print anything).
@(private = "file")
read_lines_in :: proc(output: string) -> bool {
	rest := output
	n := 0
	for l in strings.split_lines_iterator(&rest) {
		if _, _, ok := numbered_line(l); ok { n += 1 }
		if n >= 1 { return true }
	}
	return false
}

// Matches under their file ("path:" then "  Line 12: text"), paths one a line.
search_view :: proc(app: ^App, id, output: string, em: f32, max_lines: int) {
	ui.next({width = ui.fill(), height = ui.children_sum(), axis = .Y})
	if well(id, radius = 6, base = HEX_CODE_WELL) {
		ui.spacer(ui.px(em * 0.4))
		rest := output
		k, left := 0, 0
		for l in strings.split_lines_iterator(&rest) {
			t := strings.trim_space(l)
			if t == "" { continue }
			if k == max_lines { left += 1; continue }
			if strings.has_prefix(t, "Line ") {
				no, s, ok := numbered_line(t[len("Line "):])
				if ok { code_row(app, no, strings.trim_space(s), k, em); k += 1; continue }
			}
			ui.next({width = ui.fill(), height = ui.px(math.round(em * 1.4)), axis = .X, cross = .Center})
			if ui.row(.Center, id = fmt.tprintf("###sf%d", k)) {
				ui.spacer(ui.px(em * 0.75))
				is_file := strings.has_suffix(t, ":") || strings.contains_any(t, "\\/")
				text("f", strings.trim_suffix(t, ":"), is_file ? hex(HEX_TEXT_SOFT) : hex(HEX_FAINT), ui.Style_Mod{font = is_file ? app.mono_bold : app.mono, font_size = math.round(em * FS_SMALL)}, ui.fill())
			}
			k += 1
		}
		more_lines(left, em)
		ui.spacer(ui.px(em * 0.4))
	}
}

////////////////////////////////
// The others

// A command, as one would have typed it.
@(private = "file")
command_view :: proc(app: ^App, id, input: string, em: f32) {
	v, err := json.parse_string(input, allocator = context.temp_allocator)
	if err != nil { return }
	cmd := jstr(v, "command")
	if cmd == "" { return }
	mono_well(id, fmt.tprintf("$ %s", cmd), em, TOOL_INPUT_LINES_MAX, hex(HEX_TEXT_SOFT))
	ui.spacer(ui.px(em * 0.35))
}

@(private = "file")
todo_view :: proc(app: ^App, input: string, em: f32) -> bool {
	v, err := json.parse_string(input, allocator = context.temp_allocator)
	if err != nil { return false }
	list := jarr(v, "todos")
	if list == nil { return false }
	for t, k in list { todo_row(app, Todo{jstr(t, "content"), jstr(t, "status")}, k, em) }
	ui.spacer(ui.px(em * 0.3))
	return true
}

// A value of the input on one line, as it reads.
@(private = "file")
value_text :: proc(v: json.Value) -> string {
	#partial switch x in v {
	case json.String:  return string(x)
	case json.Integer: return fmt.tprintf("%d", x)
	case json.Float:   return fmt.tprintf("%v", x)
	case json.Boolean: return x ? "yes" : "no"
	case json.Null:    return "—"
	}
	return jtext(v)
}

// The input as keys and values; a long value in a well of its own.
input_view :: proc(app: ^App, input: string, em: f32) {
	v, err := json.parse_string(input, allocator = context.temp_allocator)
	obj, is := v.(json.Object)
	if err != nil || !is { mono_well("###input", input, em, TOOL_INPUT_LINES_MAX); return }
	keys := make([dynamic]string, context.temp_allocator)
	for k in obj { append(&keys, k) }
	slice.sort(keys[:])
	ui.next({width = ui.fill(), height = ui.children_sum(), axis = .Y})
	if well("###input", radius = 6, base = HEX_CODE_WELL) {
		ui.spacer(ui.px(em * 0.4))
		for k, i in keys {
			s := value_text(obj[k])
			if strings.index_byte(s, '\n') >= 0 || len(s) > TOOL_LINE_CHARS {
				section_label(fmt.tprintf("ik%d", i), k, em)
				mono_well(fmt.tprintf("###iv%d", i), s, em, TOOL_INPUT_LINES_MAX)
			} else {
				kv_row(fmt.tprintf("###kv%d", i), k, s, em, {h = 1.4, key_w = 7, key_fs = FS_CAPTION, val_fs = FS_SMALL, pad_l = 0.8, val = HEX_TEXT_SOFT})
			}
		}
		ui.spacer(ui.px(em * 0.4))
	}
	ui.spacer(ui.px(em * 0.5))
}

// The body of a call that is open, by what it does.
tool_body :: proc(app: ^App, p: ^Part, em: f32) {
	failed := p.status == .Error
	lines := app.prefs.tool_lines
	output :: proc(app: ^App, p: ^Part, em: f32, lines: int) {
		if p.output == "" { return }
		mono_well("###output", p.output, em, lines, p.status == .Error ? hex(HEX_ERROR_TEXT) : hex(HEX_TOOL_OUTPUT))
	}
	switch tool_kind(p.tool_name) {
	case .Edit:
		if patch := part_patch(p, app.chat.alloc); patch != "" {
			diff_view(app, "###diff", patch, em, lines)
			if failed { ui.spacer(ui.px(em * 0.4)); output(app, p, em, lines) }
			return
		}
	case .Read:
		if !failed && read_lines_in(p.output) { read_view(app, "###read", p.output, em, lines); return }
	case .Search:
		if !failed && p.output != "" { search_view(app, "###search", p.output, em, lines); return }
	case .Shell:
		command_view(app, "###cmd", p.input, em)
		output(app, p, em, lines)
		return
	case .Todo:
		if todo_view(app, p.input, em) { return }
	case .Other:
	}
	if p.input != "" { input_view(app, p.input, em) }
	output(app, p, em, lines)
}
