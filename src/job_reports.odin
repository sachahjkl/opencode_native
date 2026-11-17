// The harness's reports of a background job that ended, which come into the conversation as a synthetic message whose text
// is markup: `<shell id=".." state=".." command="..">output</shell>`, `<subagent sessionID=".." state=".." description="..">
// report</subagent>`, one or several in a row. Read once when the message is read (chat_load), shown as one folded card each.
// A text that is not only such tags is no report: the message keeps its plain line.
package ocn

import "core:fmt"
import "core:math"
import "core:mem"
import "core:strconv"
import "core:strings"
import "gt:draw"
import "gt:markdown"
import "gt:ui"
import lucide "gt:lucide"
import i18n "gt:i18n"

Job_Kind :: enum u8 { Shell, Subagent }

JOB_TAGS :: [Job_Kind]string{ .Shell = "shell", .Subagent = "subagent" }

// The lines of a command's output an open card shows (the rest is counted).
JOB_OUTPUT_LINES :: 200
// The runes of a sub-agent's reason for stopping in its card's title.
JOB_REASON_RUNES :: 60

Job_Report :: struct {
	kind:        Job_Kind,
	id:          string,      // the shell's id, the sub-agent's session
	state:       Sub_State,
	state_word:  string,      // as the tag says it
	command:     string,      // a shell's
	description: string,      // a sub-agent's
	reason:      string,      // why it stopped, when the tag says it
	exit_code:   string,
	body:        string,      // a command's output, a sub-agent's report (Markdown)
	command_well, body_well: Well_Kept,   // what the open card made of its texts, for the next build
}

// The reports a synthetic message's text holds, in `a`; ok false (nothing kept) when the text is not only reports.
// A tag without its closing tag holds the rest of the text.
jobs_parse :: proc(s: string, a: mem.Allocator) -> (jobs: []Job_Report, ok: bool) {
	read := make([dynamic]Job_Report, context.temp_allocator)
	rest := strings.trim_space(s)
	if rest == "" { return nil, false }
	for rest != "" {
		r, after, one := job_parse(rest)
		if !one { return nil, false }
		append(&read, r)
		rest = strings.trim_left_space(after)
	}
	jobs = make([]Job_Report, len(read), a)
	for r, k in read {
		jobs[k] = {
			kind = r.kind, state = r.state,
			id = strings.clone(r.id, a), state_word = strings.clone(r.state_word, a),
			command = strings.clone(r.command, a), description = strings.clone(r.description, a),
			reason = strings.clone(r.reason, a), exit_code = strings.clone(r.exit_code, a),
			body = strings.clone(r.body, a),
		}
	}
	return jobs, true
}

// The report at the start of `s` (its texts in `s` or in the frame's memory), and what follows it.
@(private = "file")
job_parse :: proc(s: string) -> (r: Job_Report, rest: string, ok: bool) {
	if len(s) < 2 || s[0] != '<' { return }
	name := ""
	tags := JOB_TAGS
	for tag, k in tags {
		n := 1 + len(tag)
		if len(s) > n && s[1:n] == tag && (s[n] == '>' || s[n] == '/' || job_space(s[n])) {
			r.kind, name = k, tag
			break
		}
	}
	if name == "" { return }
	i := 1 + len(name)
	attrs: for {
		for i < len(s) && job_space(s[i]) { i += 1 }
		if i >= len(s) { return }   // (the opening tag has no end)
		switch s[i] {
		case '>':
			i += 1
			break attrs
		case '/':
			if i + 1 < len(s) && s[i + 1] == '>' {
				job_settle(&r)
				return r, s[i + 2:], true
			}
			return
		}
		start := i
		for i < len(s) && job_name_byte(s[i]) { i += 1 }
		if i == start { return }
		key := s[start:i]
		for i < len(s) && job_space(s[i]) { i += 1 }
		value := ""
		if i < len(s) && s[i] == '=' {
			i += 1
			for i < len(s) && job_space(s[i]) { i += 1 }
			if i >= len(s) { return }
			if q := s[i]; q == '"' || q == '\'' {
				end := job_value_end(s, i + 1, q)
				if end < 0 { return }
				value = s[i + 1:end]
				i = end + 1
			} else {
				from := i
				for i < len(s) && !job_space(s[i]) && s[i] != '>' { i += 1 }
				value = s[from:i]
			}
		}
		job_attribute(&r, key, entities_decoded(value))
	}
	body := s[i:]
	closing := fmt.tprintf("</%s>", name)
	if e := strings.index(body, closing); e >= 0 {
		rest = body[e + len(closing):]
		body = body[:e]
	}
	// (the lines around it are the markup's; the output's own indentation stays)
	r.body = strings.trim_right_space(strings.trim_left(body, "\r\n"))
	job_settle(&r)
	return r, rest, true
}

@(private = "file")
job_attribute :: proc(r: ^Job_Report, key, value: string) {
	switch key {
	case "id", "shellID", "sessionID":         r.id = value
	case "state", "status":                    r.state_word = value
	case "command":                            r.command = value
	case "description":                        r.description = value
	case "error", "reason":                    r.reason = value
	case "exit", "exitCode", "exit_code", "code": r.exit_code = value
	}
}

// Its state from its words: a command that exited with another code than 0 failed, whatever its state says.
@(private = "file")
job_settle :: proc(r: ^Job_Report) {
	st, known := state_of_word(r.state_word)
	if !known {
		switch r.state_word {
		case "exited", "done", "finished": st = .Done
		case "killed", "stopped":          st = .Cancelled
		case "timeout", "timed_out":       st = .Failed
		}
	}
	if r.exit_code != "" && r.exit_code != "0" && st != .Cancelled { st = .Failed }
	r.state = st
}

// Where a quoted value that starts at `from` ends: its quote `q`, the one followed by another attribute (`name="`) or by
// the tag's end and its line's; -1: none. The harness does not escape a command's own quotes (`command="grep "a" x"`):
// the first quote is not always the last. A tag whose body follows on its line ends at the first `q>` of that line.
@(private = "file")
job_value_end :: proc(s: string, from: int, q: u8) -> int {
	tag_end := -1
	for k := from; k < len(s); k += 1 {
		if s[k] == '\n' && tag_end >= 0 { break }
		if s[k] != q { continue }
		j := k + 1
		for j < len(s) && (s[j] == ' ' || s[j] == '\t') { j += 1 }
		if j >= len(s) { return k }
		// another attribute: a name, then = and a quote
		n := j
		for n < len(s) && job_name_byte(s[n]) { n += 1 }
		if n > j && j > k + 1 && n + 1 < len(s) && s[n] == '=' && (s[n + 1] == '"' || s[n + 1] == '\'') { return k }
		// the tag's end: at once when its line ends there, else the first one, if no later quote ends its line
		e := -1
		if s[j] == '>' { e = j + 1 } else if s[j] == '/' && j + 1 < len(s) && s[j + 1] == '>' { e = j + 2 }
		if e < 0 { continue }
		if e >= len(s) || s[e] == '\n' || s[e] == '\r' { return k }
		if tag_end < 0 { tag_end = k }
	}
	return tag_end
}

@(private = "file")
job_space :: proc(c: u8) -> bool { return c == ' ' || c == '\t' || c == '\n' || c == '\r' }

@(private = "file")
job_name_byte :: proc(c: u8) -> bool {
	return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_' || c == '-' || c == ':' || c == '.'
}

// An attribute's value with its character references read (`&quot;`, `&amp;`, `&#39;`, `&#x27;`...); an unknown one stays as written.
entities_decoded :: proc(s: string) -> string {
	if strings.index_byte(s, '&') < 0 { return s }
	b := strings.builder_make(context.temp_allocator)
	for i := 0; i < len(s); {
		if s[i] == '&' {
			if semi := strings.index_byte(s[i:], ';'); semi > 1 && semi <= 10 {
				if r, ok := entity_rune(s[i + 1:i + semi]); ok {
					strings.write_rune(&b, r)
					i += semi + 1
					continue
				}
			}
		}
		strings.write_byte(&b, s[i])
		i += 1
	}
	return strings.to_string(b)
}

@(private = "file")
entity_rune :: proc(name: string) -> (rune, bool) {
	switch name {
	case "quot": return '"', true
	case "amp":  return '&', true
	case "lt":   return '<', true
	case "gt":   return '>', true
	case "apos": return '\'', true
	}
	if len(name) < 2 || name[0] != '#' { return 0, false }
	digits, base := name[1:], 10
	if digits[0] == 'x' || digits[0] == 'X' { digits, base = digits[1:], 16 }
	if digits == "" { return 0, false }
	v, ok := strconv.parse_u64_of_base(digits, base)
	if !ok || v == 0 || v > 0x10FFFF || (v >= 0xD800 && v <= 0xDFFF) { return 0, false }
	return rune(v), true
}

////////////////////////////////
// The cards

// What the cards show, as the message's Copy gives it (temp memory): a command, `$ ` before it, then its output; a
// sub-agent's report, its Markdown as written. Two reports apart by an empty line. Never the markup they came in.
jobs_text :: proc(jobs: []Job_Report) -> string {
	b := strings.builder_make(context.temp_allocator)
	for r, k in jobs {
		if k > 0 { strings.write_string(&b, "\n\n") }
		switch r.kind {
		case .Shell:
			if r.command != "" {
				fmt.sbprintf(&b, "$ %s", r.command)
				if r.body != "" { strings.write_byte(&b, '\n') }
			}
			strings.write_string(&b, r.body)
		case .Subagent:
			strings.write_string(&b, r.body)
		}
	}
	return strings.to_string(b)
}

// The reports of message `m`, one card each: one line while folded, so that several in a row stay compact.
job_reports :: proc(app: ^App, pane: ^Chat_Pane, m: ^Message, em: f32) {
	for &r, k in m.jobs {
		job_card(app, pane, m, &r, k, em)
		ui.space(ui.SPACE_1)
	}
	ui.space(ui.SPACE_1)
}

// job_reports' selectable boxes as a copy reads them (message_text): each card open (or the text whole), its command and its
// output, or the sub-agent's report.
job_reports_text :: proc(t: ^Copy_Text, app: ^App, m: ^Message) {
	for &r, k in m.jobs {
		key := fmt.tprintf("%s_job%d", m.id, k)
		open := part_open(app, key)
		if !copy_fold(t, key, open) { continue }
		defer copy_unfold(t, open)
		switch r.kind {
		case .Shell:
			if r.command != "" { mono_well_text(t, fmt.tprintf("$ %s", r.command), JOB_OUTPUT_LINES) }
			mono_well_text(t, r.body != "" ? r.body : i18n.tr("(no output)"), JOB_OUTPUT_LINES)
		case .Subagent:
			if r.body != "" { md_text(t, app, key, r.body) }
		}
	}
}

// What a card's header says first: what ended, and how.
job_title :: proc(r: ^Job_Report) -> string {
	switch r.kind {
	case .Shell:
		#partial switch r.state {
		case .Done:      return i18n.tr("Command finished")
		case .Failed:    return r.exit_code != "" && r.exit_code != "0" ? fmt.tprintf(i18n.tr("Command failed (exit %s)"), r.exit_code) : i18n.tr("Command failed")
		case .Cancelled: return i18n.tr("Command stopped")
		case .Running:   return i18n.tr("Command running")
		}
		return r.state_word != "" ? fmt.tprintf(i18n.tr("Command ended (%s)"), r.state_word) : i18n.tr("Command finished")
	case .Subagent:
		#partial switch r.state {
		case .Done:      return i18n.tr("Sub-agent finished")
		case .Failed:
			reason := r.reason != "" ? r.reason : first_line(r.body)
			return reason != "" ? fmt.tprintf(i18n.tr("Sub-agent stopped: %s"), ellipsize(reason, JOB_REASON_RUNES)) : i18n.tr("Sub-agent stopped")
		case .Cancelled: return i18n.tr("Sub-agent stopped")
		case .Running:   return i18n.tr("Sub-agent running")
		}
		return r.state_word != "" ? fmt.tprintf(i18n.tr("Sub-agent ended (%s)"), r.state_word) : i18n.tr("Sub-agent finished")
	}
	return ""
}

@(private = "file")
job_head_draw :: proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
	if b.hot_t > FADE_VISIBLE { draw.rect(dc, b.rect, {1, 1, 1, 0.035 * b.hot_t}) }   // (square: a row)
}

// One report: a header that opens it (its state, what ended, the command's start or the sub-agent's task), then, open, the
// command and its output in the code font or the sub-agent's report as Markdown, all selectable.
@(private = "file")
job_card :: proc(app: ^App, pane: ^Chat_Pane, m: ^Message, r: ^Job_Report, k: int, em: f32) {
	key := fmt.tprintf("%s_job%d", m.id, k)
	open := part_open(app, key)
	ui.next({width = ui.fill(), height = ui.children_sum(), axis = .Y})
	if ui.column(id = fmt.tprintf("###job_%s_%d", m.id, k)) {
		ui.next({width = ui.fill(), height = ui.px(math.round(em * 1.9)), axis = .X, cross = .Center})
		hb := ui.build_box({.Clickable, .Focusable, .Hot_Within}, "###head")
		hb.custom = job_head_draw
		hs := ui.signal(hb)
		if hs.clicked { part_toggle(app, pane, key, hb) }
		// (the header shows the command's start: its whole on hover)
		if r.kind == .Shell && r.command != "" && ui.hovered_for(hs) { if ui.tooltip() { ui.tooltip_text(r.command) } }
		if ui.parent(hb) {
			ui.space(ui.CARD_PAD)
			state_mark("###st", r.state, size = em * CARD_MARK_EM)
			ui.space(ui.ICON_GAP)
			text("w", job_title(r), sub_state_ink(r.state), ui.Style_Mod{font = app.mono_bold, font_size = math.round(em * FS_SMALL)})
			ui.space(ui.SPACE_2)
			switch r.kind {
			case .Shell:
				line := first_line(r.command)
				if line != strings.trim_space(r.command) { line = fmt.tprintf("%s …", line) }
				text("c", line, ui.theme_color("weak text"), ui.Style_Mod{font = app.mono, font_size = math.round(em * FS_SMALL)}, ui.fill())
			case .Subagent:
				text("d", r.description, ui.theme_color("weak text"), ui.Style_Mod{font_size = math.round(em * FS_LABEL)}, ui.fill())
			}
			text("at", clock_text(m.created, app.prefs.clock24), ui.theme_color("faint text"), ui.Style_Mod{font = app.mono, font_size = math.round(em * FS_CAPTION)})
			ui.space(ui.SPACE_2)
			glyph(open ? lucide.CHEVRON_DOWN : lucide.CHEVRON_RIGHT, ui.theme_color("faint text"), math.round(em * ICON_TINY), em * 1.1)
			ui.space(ui.ICON_GAP)
		}
		if open {
			ui.next({width = ui.fill(), height = ui.children_sum(), axis = .X})
			if rail_row(fmt.tprintf("###jobb_%s_%d", m.id, k), ui.with_alpha(ui.theme_color("weak text"), 0.4)) {
				ui.space(ui.SPACE_4)
				ui.next({width = ui.fill(), height = ui.children_sum(), axis = .Y})
				if ui.column() {
					ui.space(ui.SPACE_1)
					switch r.kind {
					case .Shell:
						if r.command != "" {
							mono_well("###command", fmt.tprintf("$ %s", r.command), em, JOB_OUTPUT_LINES, ui.theme_color("soft text"), &r.command_well, pane.chat.alloc)
							ui.space(ui.SPACE_1)
						}
						out := r.body != "" ? r.body : i18n.tr("(no output)")
						mono_well("###output", out, em, JOB_OUTPUT_LINES, ui.theme_color("soft text"), &r.body_well, pane.chat.alloc)
					case .Subagent:
						if r.body == "" {
							text("none", i18n.tr("(no report)"), ui.theme_color("faint text"), ui.Style_Mod{font_size = math.round(em * FS_NOTE), height = ui.px(em * 1.5)})
						} else {
							id := fmt.tprintf("%s_job%d", m.id, k)
							markdown.view(md_doc(&pane.chat, id), id, r.body, md_config(app, ui.theme_color("soft text"), pane), math.round(em * FS_LABEL))
						}
					}
					ui.space(ui.SPACE_1)
				}
			}
		}
	}
}
