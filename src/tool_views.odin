// What a tool call shows when it is open, by what the tool does: a diff for what edits a file (the server's own patch, else
// one made here with gt:diff from the call's input), the lines of a file with their numbers, matches under their file,
// a command and what it printed, a checklist. The rest shows its input as keys and values, never as raw JSON.
package ocn

import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:strconv"
import "core:strings"
import "gt:ui"
import diff "gt:diff"
import lucide "gt:lucide"
import syntax "gt:syntax"
import i18n "gt:i18n"

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

// The diff of a call: the server's, else made once from what it was asked (a call still running, an older server).
part_patch :: proc(p: ^Part, a := context.allocator) -> string {
	if p.patch != "" || p.patch_tried || p.input == "" { return p.patch }
	p.patch_tried = true
	if p.has_old {
		part_patch_set(p, diff.between(p.old_text, p.new_text, a), a)
	} else if p.has_content {
		part_patch_set(p, diff.between("", p.content, a), a)
	}
	return p.patch
}

// `patch` is the call's: read once, here (its lines, what it adds and removes), not at each build. (In `a`: the patch's.)
part_patch_set :: proc(p: ^Part, patch: string, a := context.allocator) {
	p.patch = patch
	p.diff = diff.parse(patch, a)
	p.added, p.removed = p.diff.added, p.diff.removed
}

////////////////////////////////
// A diff

// A line's text with its tabs opened and its length bounded (`s` is one line).
@(private = "file")
line_shown :: proc(s: string) -> string {
	t, _ := strings.replace_all(s, "\t", TOOL_TAB, context.temp_allocator)
	return ellipsize(t, TOOL_LINE_CHARS)
}

gutter :: proc(id: string, n: int, em: f32) {
	s := n > 0 ? fmt.tprintf("%d", n) : ""
	text(id, s, hex(HEX_DIFF_LINE_NO), ui.Style_Mod{font = the_app.mono, font_size = math.round(em * FS_CAPTION), text_align = .Right}, ui.px(em * GUTTER_EM))
}

// A diff's rows at our sizes, the code in its colours when `file` names a language.
diff_options :: proc(app: ^App, em: f32, file := "") -> diff.Options {
	o := diff.Options{
		font = app.mono, sign_font = app.mono_bold, number_font = app.mono,
		size = math.round(em * FS_SMALL), number_size = math.round(em * FS_CAPTION),
		row_height = math.round(em * 1.3), gap_height = math.round(em * 0.9),
		gutter_width = em * GUTTER_EM, sign_width = em, indent = em * 0.4, tab = TOOL_TAB,
	}
	if file != "" { if l, ok := syntax.language_of_file(file); ok { o.language = l } }
	return o
}

// The lines of a patch (`d`, read from `patch`) in a well, at most `max_lines` of them (the rest is counted, and the whole opens
// in its own window).
diff_view :: proc(app: ^App, id: string, d: diff.Parsed, patch: string, em: f32, max_lines: int, title := "Diff") {
	lines := d.lines
	if len(lines) == 0 { return }
	ui.next({width = ui.fill(), height = ui.children_sum(), axis = .Y})
	if ui.well(id) {
		ui.spacer(ui.px(em * 0.3))
		o := diff_options(app, em, title)
		o.max_bytes = TOOL_LINE_CHARS
		diff.lines_view("###lines", lines[:min(len(lines), max_lines)], d.numbered, o)
		if diff_more(len(lines) - min(len(lines), max_lines), em) { diff_full_open(app, title, patch) }
		ui.spacer(ui.px(em * 0.3))
	}
}

@(private = "file")
more_lines :: proc(n: int, em: f32) {
	if n <= 0 { return }
	ui.next({width = ui.fill(), height = ui.px(em * 1.5), axis = .X, cross = .Center})
	if ui.row(.Center, id = "###more") {
		ui.spacer(ui.px(em * 0.75))
		text("m", fmt.tprintf(i18n.tr(n, "… %d more lines", "… %d more lines"), n), hex(HEX_FAINT), ui.Style_Mod{font = the_app.mono, font_size = math.round(em * FS_SMALL)})
	}
}

// What is not shown, and the way to all of it: a text naming an action is a button.
@(private = "file")
diff_more :: proc(n: int, em: f32) -> (clicked: bool) {
	ui.next({width = ui.fill(), height = ui.px(em * 1.5), axis = .X, cross = .Center, cursor = .Hand})
	b := ui.build_box({.Clickable}, "###more")
	sig := ui.signal(b)
	if ui.parent(b) {
		ui.spacer(ui.px(em * 0.75))
		col := sig.hovering ? hex(HEX_TEXT) : hex(HEX_FAINT)
		fs := math.round(em * FS_SMALL)
		if n > 0 { text("m", fmt.tprintf(i18n.tr(n, "… %d more lines", "… %d more lines"), n), col, ui.Style_Mod{font = the_app.mono, font_size = fs}); ui.spacer(ui.px(em * 0.8)) }
		text("f", i18n.tr("Full view"), col, ui.Style_Mod{font_size = fs})
	}
	return sig.clicked
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

// A file as the read tool gives it: a line of what was read, then "number: text" lines. (`cut`: how many are left out, counted
// once for this output: a build reads no further than what it shows.)
read_view :: proc(app: ^App, id, output: string, em: f32, max_lines: int, cut: ^Text_Cut) {
	ui.next({width = ui.fill(), height = ui.children_sum(), axis = .Y})
	if ui.well(id) {
		ui.spacer(ui.px(em * 0.4))
		known := text_cut_known(cut, output, max_lines, .Read)
		rest := output
		k := 0
		left := 0
		for l in strings.split_lines_iterator(&rest) {
			no, t, ok := numbered_line(l)
			if !ok { continue }
			if k == max_lines {
				if known { break }
				left += 1
				continue
			}
			code_row(app, no, t, k, em)
			k += 1
		}
		if known { left = cut.extra } else { text_cut_keep(cut, output, max_lines, .Read, len(output), left) }
		more_lines(left, em)
		ui.spacer(ui.px(em * 0.4))
	}
}

// Whether `output` reads as lines of a file (a tool of another name may print anything).
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
search_view :: proc(app: ^App, id, output: string, em: f32, max_lines: int, cut: ^Text_Cut) {
	ui.next({width = ui.fill(), height = ui.children_sum(), axis = .Y})
	if ui.well(id) {
		ui.spacer(ui.px(em * 0.4))
		known := text_cut_known(cut, output, max_lines, .Search)
		rest := output
		k, left := 0, 0
		for l in strings.split_lines_iterator(&rest) {
			t := strings.trim_space(l)
			if t == "" { continue }
			if k == max_lines {
				if known { break }
				left += 1
				continue
			}
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
		if known { left = cut.extra } else { text_cut_keep(cut, output, max_lines, .Search, len(output), left) }
		more_lines(left, em)
		ui.spacer(ui.px(em * 0.4))
	}
}

////////////////////////////////
// The others

// A command, as one would have typed it.
@(private = "file")
command_view :: proc(app: ^App, id: string, p: ^Part, em: f32) {
	if p.command_line == "" { return }
	mono_well(id, p.command_line, em, TOOL_INPUT_LINES_MAX, hex(HEX_TEXT_SOFT), &p.command_well, app.chat.alloc)
	ui.spacer(ui.px(em * 0.35))
}

@(private = "file")
todo_view :: proc(app: ^App, p: ^Part, em: f32) -> bool {
	if !p.has_todos { return false }
	for t, k in p.todos { todo_row(app, t, k, em) }
	ui.spacer(ui.px(em * 0.3))
	return true
}

// A value of the input on one line, as it reads (temp memory).
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

// The input as keys and values, in one well: a long value under its key, at the place of the short ones' values' start. (No well in
// the well: one edge beside another reads as unfinished.)
input_view :: proc(app: ^App, p: ^Part, em: f32) {
	if !p.input_object { mono_well("###input", p.input, em, TOOL_INPUT_LINES_MAX); return }
	ui.next({width = ui.fill(), height = ui.children_sum(), axis = .Y})
	if ui.well("###input") {
		ui.spacer(ui.px(em * 0.4))
		for &f, i in p.fields {
			k, s := f.key, f.value
			if f.long {
				if i > 0 { ui.spacer(ui.px(em * 0.3)) }
				ui.next({width = ui.fill(), height = ui.px(em * 1.4), axis = .X, cross = .Center})
				if ui.row(.Center, id = fmt.tprintf("###ik%d", i)) {
					ui.spacer(ui.px(em * INPUT_PAD_EM))
					text("l", k, hex(HEX_FAINT), ui.Style_Mod{font = the_app.mono_bold, font_size = math.round(em * FS_CAPTION)})
				}
				ui.next({width = ui.fill(), height = ui.children_sum(), axis = .Y})
				if ui.column(id = fmt.tprintf("###iv%d", i)) {
					body, extra := mono_cut_kept(&f.well.cut, s, TOOL_INPUT_LINES_MAX)
					mono_text(body, extra, em, INPUT_PAD_EM, flush = true, kept = &f.well.runs, kept_in = app.chat.alloc)
				}
				if i + 1 < len(p.fields) { ui.spacer(ui.px(em * 0.3)) }
			} else {
				kv_row(fmt.tprintf("###kv%d", i), k, s, em, {h = 1.4, key_w = 7, key_fs = FS_CAPTION, val_fs = FS_SMALL, pad_l = INPUT_PAD_EM, val = HEX_TEXT_SOFT})
			}
		}
		ui.spacer(ui.px(em * 0.4))
	}
	ui.spacer(ui.px(em * 0.5))
}

// What a call that edits names: its file, as the arguments say.
tool_diff_title :: proc(p: ^Part) -> string {
	if p.subject != "" { return p.subject }
	return p.tool_name != "" ? p.tool_name : i18n.tr("Diff")
}

// The body of a call that is open, by what it does.
tool_body :: proc(app: ^App, p: ^Part, em: f32) {
	failed := p.status == .Error
	lines := app.prefs.tool_lines
	output :: proc(app: ^App, p: ^Part, em: f32, lines: int) {
		if p.output == "" { return }
		mono_well("###output", p.output, em, lines, p.status == .Error ? hex(HEX_ERROR_TEXT) : hex(HEX_TOOL_OUTPUT), &p.output_well, app.chat.alloc)
	}
	switch tool_kind(p.tool_name) {
	case .Edit:
		if patch := part_patch(p, app.chat.alloc); patch != "" {
			diff_view(app, "###diff", p.diff, patch, em, lines, tool_diff_title(p))
			if failed { ui.spacer(ui.px(em * 0.4)); output(app, p, em, lines) }
			return
		}
	case .Read:
		if !failed && p.output_numbered { read_view(app, "###read", p.output, em, lines, &p.output_well.cut); return }
	case .Search:
		if !failed && p.output != "" { search_view(app, "###search", p.output, em, lines, &p.output_well.cut); return }
	case .Shell:
		command_view(app, "###cmd", p, em)
		output(app, p, em, lines)
		if output_view_can(p) {
			ui.next({width = ui.fill(), height = ui.children_sum(), axis = .X, cross = .Center})
			if ui.row(.Center, id = "###cmd_more") {
				ui.spacer(ui.fill())
				if ui.button_icon("###inspect", lucide.SQUARE_TERMINAL, i18n.tr("Inspect the output"), height = math.round(em * BUTTON_SMALL_H_EM), quiet = true, face = .Ghost).clicked { output_view_open_part(app, p) }
			}
		}
		return
	case .Todo:
		if todo_view(app, p, em) { return }
	case .Other:
	}
	if p.input != "" { input_view(app, p, em) }
	output(app, p, em, lines)
}
