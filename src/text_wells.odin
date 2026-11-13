// Text in wells (a tool's input and output, cut to a number of lines, its addresses links), and the captions over them.
package ocn

import "core:fmt"
import "core:math"
import "core:mem"
import "core:strings"
import "gt:ui"
import i18n "gt:i18n"


HEX_TOOL_OUTPUT       :: 0xbdbdbdff

section_label :: proc(id, s: string, em: f32) {
	ui.next({width = ui.fill(), height = ui.px(em * 1.4), axis = .X, cross = .Center})
	if ui.row(.Center, id = fmt.tprintf("###sl_%s", id)) { caption_title("l", s, "", em) }
}

// A title in capitals over what follows, `note` after it. Faint, in the mono face; in the edged style (Kernel) a stripe and
// the title in the accent, as a console's sections (gui_toolkit's section_header).
caption_title :: proc(id, title, note: string, em: f32, color := Color{}) {
	if ui.edged() {
		if ui.style({font = the_app.mono, font_size = math.round(em * FS_CAPTION / 0.85)}) {   // (section_header draws its title at 0.85)
			ui.section_header(fmt.tprintf("###ct_%s", id), title, note, "", color.a > 0 ? color : accent(), inline = true)
		}
		return
	}
	words := note != "" ? fmt.tprintf("%s  %s", title, note) : title
	text(id, words, hex(HEX_FAINT), ui.Style_Mod{font = the_app.mono_bold, font_size = math.round(em * FS_CAPTION)})
}

MONO_WELL_MAX_BYTES :: 20000   // of a tool's text, whatever the lines allow

// What a view read of a text, kept with it: a build of a text that did not change reads none of it again. A text is known by its
// place and its length; one that changed is in another place, or longer in the same (a part's text only grows in its buffer:
// apply_event gives a text that changed otherwise a new one). Kept with what owns the text (a part, a message), in the same memory.

// Where a text is cut to `max_lines` (`way`: what counts as a line, and how the cut is made), and how many lines are left out.
Text_Cut :: struct {
	src:       rawptr,
	n:         int,
	max_lines: int,
	way:       Cut_Way,
	body:      int,   // bytes shown (a Lines cut: the text up to there)
	extra:     int,
}

Cut_Way :: enum u8 { None, Lines, Read, Search }

text_cut_known :: proc(k: ^Text_Cut, s: string, max_lines: int, way: Cut_Way) -> bool {
	return k != nil && k.way == way && k.src == raw_data(s) && k.n == len(s) && k.max_lines == max_lines
}

text_cut_keep :: proc(k: ^Text_Cut, s: string, max_lines: int, way: Cut_Way, body, extra: int) {
	if k != nil { k^ = {src = raw_data(s), n = len(s), max_lines = max_lines, way = way, body = body, extra = extra} }
}

// mono_cut, counted once for a text (`k` nil: each time).
mono_cut_kept :: proc(k: ^Text_Cut, s: string, max_lines: int) -> (body: string, extra: int) {
	if text_cut_known(k, s, max_lines, .Lines) { return s[:k.body], k.extra }
	body, extra = mono_cut(s, max_lines)
	text_cut_keep(k, s, max_lines, .Lines, len(body), extra)
	return
}

// A text as runs, its web addresses links (ui.rich_links), kept with the text and the style they were made with. A text that grew
// in its place is read again from its last line before the old end: an address never spans a line, what is before it stays.
Link_Runs :: struct {
	src:   rawptr,
	n:     int,
	style: ui.Rich_Style,
	runs:  [dynamic]ui.Rich_Run,   // (in the memory of the text's owner: cleared and filled again, it does not grow past the text)
}

link_runs :: proc(k: ^Link_Runs, s: string, style: ui.Rich_Style, a: mem.Allocator) -> []ui.Rich_Run {
	same := k.src == raw_data(s) && k.style == style
	if same && k.n == len(s) { return k.runs[:] }
	if k.runs.allocator.procedure == nil { k.runs.allocator = a }
	from := 0
	if same && k.n < len(s) {
		if nl := strings.last_index_byte(s[:k.n], '\n'); nl >= 0 { from = nl + 1 }
	}
	// the runs before `from` stay, the one across it is cut there (a link has no line break: it is text)
	// (from > 0: they are runs of this text, in this place)
	kept := 0
	for from > 0 && kept < len(k.runs) {
		r := &k.runs[kept]
		start := int(uintptr(raw_data(r.text)) - uintptr(raw_data(s)))
		if start >= from { break }
		if start + len(r.text) > from { r.text = r.text[:from - start] }
		kept += 1
	}
	resize(&k.runs, kept)
	ui.rich_links(s[from:], style, &k.runs)
	k.src, k.n, k.style = raw_data(s), len(s), style
	return k.runs[:]
}

// What a well made of its text: where it is cut, its runs.
Well_Kept :: struct {
	cut:  Text_Cut,
	runs: Link_Runs,
}

// Monospace text in a sunken well, at most `max_lines` lines (the rest is counted). `kept` (in `kept_in`, the memory of the text's
// owner): what the well made of the text, for the next build. Without it, a text of the frame: read at each build.
mono_well :: proc(id: string, s: string, em: f32, max_lines: int, color := Color{}, kept: ^Well_Kept = nil, kept_in := mem.Allocator{}) {
	body, extra := mono_cut_kept(kept != nil ? &kept.cut : nil, s, max_lines)
	ui.next({width = ui.fill(), height = ui.children_sum(), axis = .Y})
	if ui.well(id) {
		ui.spacer(ui.px(em * 0.5))
		mono_text(body, extra, em, 0.75, color, kept = kept != nil ? &kept.runs : nil, kept_in = kept_in)
		ui.spacer(ui.px(em * 0.5))
	}
}

// What mono_well holds, for a well that holds more: `body` (already cut), the lines left out, `pad` em on each side (`flush`: the text's own,
// none). `kept`: its runs, kept with the text (in `kept_in`).
mono_text :: proc(body: string, extra: int, em, pad: f32, color := Color{}, flush := false, kept: ^Link_Runs = nil, kept_in := mem.Allocator{}) {
	ui.next({width = ui.fill(), height = ui.children_sum(), axis = .X})
	if ui.row(id = "###r") {
		ui.spacer(ui.px(em * pad))
		style := ui.Rich_Style{font = the_app.mono, color = color.a > 0 ? color : hex(HEX_TOOL_OUTPUT)}
		runs: []ui.Rich_Run
		if kept != nil {
			runs = link_runs(kept, body, style, kept_in)
		} else {
			list := make([dynamic]ui.Rich_Run, context.temp_allocator)
			ui.rich_links(body, style, &list)
			runs = list[:]
		}
		m := ui.Style_Mod{width = ui.fill(), font_size = math.round(em * FS_NOTE), flags = {.Selectable}}
		if flush { m.text_pad = 0 }   // (its text starts at the pad, as a key above it)
		ui.next(m)
		link_clicked(ui.rich_paragraph("###t", runs))
		ui.spacer(ui.px(em * pad))
	}
	if extra > 0 {
		ui.next({width = ui.fill(), height = ui.px(em * 1.5), axis = .X, cross = .Center})
		if ui.row(.Center, id = "###more") {
			ui.spacer(ui.px(em * pad))
			text("m", fmt.tprintf(i18n.tr(extra, "… %d more lines", "… %d more lines"), extra), hex(HEX_FAINT), ui.Style_Mod{font = the_app.mono, font_size = math.round(em * FS_SMALL)})
		}
	}
}

// `s` cut to `max_lines` lines and MONO_WELL_MAX_BYTES: what is shown, and how many lines are left out.
mono_cut :: proc(s: string, max_lines: int) -> (body: string, extra: int) {
	body = s
	n, cut := 0, len(s)
	for i in 0 ..< len(s) {
		if s[i] == '\n' {
			n += 1
			if n == max_lines { cut = i }
		}
	}
	if n >= max_lines && cut < len(s) {
		extra = n - max_lines + 1
		body = s[:cut]
	}
	if len(body) > MONO_WELL_MAX_BYTES { body = body[:MONO_WELL_MAX_BYTES] }
	return
}
