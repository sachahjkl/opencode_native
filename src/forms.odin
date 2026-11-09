// What an agent asks the person: a form of the server (the `question` tool makes one, with metadata.kind = "question"; a plugin may
// too). A card over the composer, with what is asked and the ways to answer it, until it is answered or dismissed. The run waits for
// it, so it must not go unseen: a sub-agent's shows in the conversation of its parent, and the sidebar lights the session that waits.
package occ

import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:mem/virtual"
import "core:strconv"
import "core:strings"
import "gt:platform"
import "gt:ui"
import lucide "gt:lucide"

Form_Option :: struct { value, label, description: string }
Form_When   :: struct { key, op, value: string }

Form_Field :: struct {
	key, title, description, kind, placeholder, url: string,
	required, custom, hidden: bool,
	options:  []Form_Option,
	shown_if: []Form_When,
	min, max: Maybe(f64),
	// what the person says
	text:   ui.Text_Field,   // a line to fill, a number, the answer of one's own
	choice: int,             // the option chosen (-1: none)
	picks:  []bool,          // multiselect: the options ticked
	on:     bool,
	// what it starts with (form_reset)
	start_text:   string,
	start_choice: int,
	start_picks:  []bool,
	start_on:     bool,
}

Form_Req :: struct {
	id, session, title: string,
	question: bool,
	fields:   []Form_Field,
	arena:    virtual.Arena,
	sending:  bool,  // its answer or its dismissal is on its way: one at a time
	born:     Seq,   // the stream's clock when it came (a list asked before that does not know it: forms_replace)
	page:     int,   // several questions: the one shown, among those shown; past the last, the review
}

@(private = "file")
json_text :: proc(v: json.Value) -> string {
	#partial switch x in v {
	case json.String:  return string(x)
	case json.Integer: return fmt.tprintf("%d", x)
	case json.Float:   return fmt.tprintf("%v", x)
	case json.Boolean: return x ? "true" : "false"
	}
	return ""
}

@(private = "file")
json_number :: proc(v: json.Value, key: string) -> Maybe(f64) {
	#partial switch x in jget(v, key) {
	case json.Integer: return f64(x)
	case json.Float:   return f64(x)
	}
	return nil
}

form_add :: proc(app: ^App, v: json.Value) {
	id := jstr(v, "id")
	if id == "" || form_find(app, id) != nil || waits_were_answered(app, id) { return }
	f := form_new(id, jstr(v, "sessionID"), jstr(v, "title"), jstr(v, "metadata", "kind") == "question", jarr(v, "fields"))
	f.born = app.cx.stream_seq
	append(&app.cx.forms, f)
	app.settle = max(app.settle, FRAMES_AFTER_INPUT)
}

// What the server says a session asks: as permissions_replace. A form that stays keeps what the person has filled in.
forms_replace :: proc(app: ^App, session: string, list: json.Array, asked_at: Seq) {
	forms := &app.cx.forms
	for i := len(forms) - 1; i >= 0; i -= 1 {
		f := forms[i]
		if f.session != session || f.sending || newer(f.born, asked_at) { continue }
		listed := false
		for it in list { if jstr(it, "id") == f.id { listed = true; break } }
		if !listed { form_remove(app, f.id) }
	}
	for it in list { form_add(app, it) }
}

// Fields as the server describes them, a form's or what a way of connecting asks.
form_new :: proc(id, session, title: string, question: bool, list: json.Array) -> ^Form_Req {
	f := new(Form_Req)
	_ = virtual.arena_init_growing(&f.arena)
	a := virtual.arena_allocator(&f.arena)
	f.id, f.session, f.title, f.question = strings.clone(id, a), strings.clone(session, a), strings.clone(title, a), question
	f.fields = make([]Form_Field, len(list), a)
	for it, i in list {
		fd := &f.fields[i]
		fd.key, fd.title, fd.description = strings.clone(jstr(it, "key"), a), strings.clone(jstr(it, "title"), a), strings.clone(jstr(it, "description"), a)
		fd.kind, fd.placeholder, fd.url = strings.clone(jstr(it, "type"), a), strings.clone(jstr(it, "placeholder"), a), strings.clone(jstr(it, "url"), a)
		fd.required, fd.custom, fd.hidden = jbool(it, "required"), jbool(it, "custom"), jbool(it, "hidden")
		fd.min, fd.max = json_number(it, "minimum"), json_number(it, "maximum")
		fd.choice = -1
		opts := jarr(it, "options")
		fd.options = make([]Form_Option, len(opts), a)
		for o, k in opts { fd.options[k] = {strings.clone(jstr(o, "value"), a), strings.clone(jstr(o, "label"), a), strings.clone(jstr(o, "description"), a)} }
		fd.picks = make([]bool, len(opts), a)
		conds := jarr(it, "when")
		fd.shown_if = make([]Form_When, len(conds), a)
		for c, k in conds { fd.shown_if[k] = {strings.clone(jstr(c, "key"), a), strings.clone(jstr(c, "op"), a), strings.clone(json_text(jget(c, "value")), a)} }
		// what it starts with
		def := jget(it, "default")
		#partial switch x in def {
		case json.Boolean: fd.on = x
		case json.Array:
			for d in x { for o, k in fd.options { if o.value == json_text(d) { fd.picks[k] = true } } }
		case:
			s := json_text(def)
			if s == "" { break }
			known := false
			for o, k in fd.options { if o.value == s { fd.choice, known = k, true } }
			if !known { ui.field_set(&fd.text, s) }
		}
		fd.start_text, fd.start_choice, fd.start_on = strings.clone(ui.field_string(&fd.text), a), fd.choice, fd.on
		fd.start_picks = make([]bool, len(opts), a)
		copy(fd.start_picks, fd.picks)
	}
	return f
}

// As it came: what was answered goes. (What a way of connecting asks outlives one attempt.)
form_reset :: proc(f: ^Form_Req) {
	for &fd in f.fields {
		ui.field_set(&fd.text, fd.start_text)
		fd.choice, fd.on = fd.start_choice, fd.start_on
		copy(fd.picks, fd.start_picks)
	}
	f.page = 0
}

form_free :: proc(f: ^Form_Req) {
	for &fd in f.fields { ui.field_destroy(&fd.text) }
	virtual.arena_destroy(&f.arena)
	free(f)
}

form_find :: proc(app: ^App, id: string) -> ^Form_Req {
	for f in app.cx.forms { if f.id == id { return f } }
	return nil
}

form_remove :: proc(app: ^App, id: string) {
	for f, i in app.cx.forms {
		if f.id != id { continue }
		ordered_remove(&app.cx.forms, i)
		form_free(f)
		return
	}
}

forms_clear :: proc(app: ^App) {
	for len(app.cx.forms) > 0 { form_remove(app, app.cx.forms[0].id) }
}

// The sessions that ask something of the person and wait for it, themselves or through a sub-agent. (Once for a whole list: asked of each
// session it went through all the sessions for each thing that waits.)
sessions_waiting :: proc(app: ^App) -> map[string]bool {
	set := make(map[string]bool, allocator = context.temp_allocator)
	note :: proc(app: ^App, set: ^map[string]bool, sid: string) {
		set[sid] = true
		if s := find_session(app, sid); s != nil && s.parent != "" { set[s.parent] = true }
	}
	for f in app.cx.forms { note(app, &set, f.session) }
	for p in app.permissions { note(app, &set, p.session) }
	return set
}

session_waits :: proc(app: ^App, id: string) -> bool {
	return id in sessions_waiting(app)
}

// The forms and the permissions a session waits on (those asked before the stream connected: only a session at work can wait).
session_waits_load :: proc(app: ^App, id: string) {
	request(app, .Forms, "GET", fmt.tprintf("/api/session/%s/form", id), tag = id)
	request(app, .Permissions, "GET", fmt.tprintf("/api/session/%s/permission", id), tag = id)
}

@(private = "file")
field_value :: proc(fd: ^Form_Field) -> string {
	switch fd.kind {
	case "boolean": return fd.on ? "true" : "false"
	case "string":  if fd.choice >= 0 { return fd.options[fd.choice].value }
	}
	return strings.trim_space(ui.field_string(&fd.text))
}

// Whether the field is asked, given the answers so far.
field_shown :: proc(f: ^Form_Req, fd: ^Form_Field) -> bool {
	if fd.hidden { return false }
	for w in fd.shown_if {
		v := ""
		for &o in f.fields { if o.key == w.key { v = field_value(&o) } }
		if (v == w.value) != (w.op == "eq") { return false }
	}
	return true
}

// The answer as the server wants it; what is wrong and on which page when something is missing.
form_answer :: proc(f: ^Form_Req) -> (body, problem: string, at: int) {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, `{"answer":{`)
	first := true
	page := -1
	put :: proc(b: ^strings.Builder, first: ^bool, key, raw: string) {
		if !first^ { strings.write_byte(b, ',') }
		first^ = false
		fmt.sbprintf(b, "%s:%s", jquote(key), raw)
	}
	for &fd in f.fields {
		if !field_shown(f, &fd) { continue }
		page += 1
		if fd.kind == "external" { continue }
		name := fd.title != "" ? fd.title : fd.description != "" ? fd.description : fd.key
		must := fd.required || f.question
		switch fd.kind {
		case "boolean":
			put(&b, &first, fd.key, fd.on ? "true" : "false")
		case "number", "integer":
			s := field_value(&fd)
			if s == "" {
				if must { return "", fmt.tprintf("Answer: %s", name), page }
				continue
			}
			n, ok := strconv.parse_f64(s)
			if !ok || (fd.kind == "integer" && math.floor(n) != n) { return "", fmt.tprintf("%s: a %s is expected", name, fd.kind == "integer" ? "whole number" : "number"), page }
			if m, has := fd.min.?; has && n < m { return "", fmt.tprintf("%s: %v at least", name, m), page }
			if m, has := fd.max.?; has && n > m { return "", fmt.tprintf("%s: %v at most", name, m), page }
			put(&b, &first, fd.key, s)
		case "multiselect":
			l := strings.builder_make(context.temp_allocator)
			strings.write_byte(&l, '[')
			n := 0
			for o, k in fd.options {
				if !fd.picks[k] { continue }
				if n > 0 { strings.write_byte(&l, ',') }
				strings.write_string(&l, jquote(o.value))
				n += 1
			}
			if own := field_value(&fd); own != "" {
				if n > 0 { strings.write_byte(&l, ',') }
				strings.write_string(&l, jquote(own))
				n += 1
			}
			strings.write_byte(&l, ']')
			if n == 0 && must { return "", fmt.tprintf("Answer: %s", name), page }
			put(&b, &first, fd.key, strings.to_string(l))
		case:
			s := field_value(&fd)
			if s == "" {
				if must { return "", fmt.tprintf("Answer: %s", name), page }
				continue
			}
			put(&b, &first, fd.key, jquote(s))
		}
	}
	strings.write_string(&b, "}}")
	return strings.to_string(b), "", -1
}

@(private = "file")
form_send :: proc(app: ^App, f: ^Form_Req) {
	if f.sending { return }
	body, problem, at := form_answer(f)
	if problem != "" {
		ui.toast(.Warn, "%s", problem)
		f.page = at   // (what is missing, in front of the person)
		return
	}
	f.sending = true
	request(app, .Form_Reply, "POST", fmt.tprintf("/api/session/%s/form/%s/reply", f.session, f.id), body, f.id)
}

form_dismiss :: proc(app: ^App, f: ^Form_Req) {
	if f.sending { return }   // (an answer on its way: the server is told one thing)
	f.sending = true
	request(app, .Form_Dismiss, "DELETE", fmt.tprintf("/api/session/%s/form/%s", f.session, f.id), "", f.id)
}

// How tall a question would be, in em: too much of it and it scrolls, or what is around it would be crushed.
@(private = "file")
field_height :: proc(fd: ^Form_Field) -> f32 {
	h: f32 = FORM_FIELD_GAP_EM + (fd.title != "" ? FORM_LINE_EM : 0) + (fd.description != "" ? FORM_LINE_EM : 0)
	h += f32(len(fd.options)) * (BUTTON_H_EM + FORM_OPTION_GAP_EM)
	if len(fd.options) == 0 || fd.custom { h += FORM_LINE_EM }
	return h
}

// The forms of the conversation shown, one at a time: the oldest, what comes next counted. (Several at once would not fit, and a
// run goes on question by question.)
forms_dock :: proc(app: ^App, em: f32) {
	first: ^Form_Req
	n := 0
	for f in app.cx.forms {
		if f.session != app.chat.id && !is_child(&app.chat, f.session) { continue }
		if first == nil { first = f }
		n += 1
	}
	if first != nil { form_card(app, first, n, em) }
}

// One question at a time: several make tabs, then a review, and only that sends. (A single one sends itself once picked.) What is
// shown can change as it is answered: `when`, so the pages are counted again at each frame.
form_card :: proc(app: ^App, f: ^Form_Req, others: int, em: f32) {
	pages := make([dynamic]int, 0, len(f.fields), context.temp_allocator)   // the fields shown
	for &fd, i in f.fields { if field_shown(f, &fd) { append(&pages, i) } }
	wizard := len(pages) > 1
	f.page = clamp(f.page, 0, wizard ? len(pages) : max(len(pages) - 1, 0))
	reviewing := wizard && f.page == len(pages)
	sub := f.session != app.chat.id
	send, dismiss, next := false, false, false
	ui.next({width = ui.fill(), height = ui.children_sum(), axis = .Y})
	if plate(fmt.tprintf("###form_%s", f.id), top = HEX_PERM_TOP, bottom = HEX_PERM_BOTTOM, radius = CARD_RADIUS, shadow = 8, rim = 0.1, border = with_alpha(accent(), 0.55)) {
		ui.spacer(ui.px(em * 0.7))
		ui.next({width = ui.fill(), height = ui.children_sum(), axis = .X, cross = .Center})
		if ui.row(.Center, id = "###head") {
			ui.spacer(ui.px(em))
			glyph(lucide.LIGHTBULB, accent(), math.round(em * ICON_LARGE), em * 1.6)
			ui.spacer(ui.px(em * 0.5))
			title := f.question ? (sub ? "A sub-agent asks" : "The agent asks") : (f.title != "" ? f.title : "The agent asks")
			text("t", title, accent(), ui.Style_Mod{font = app.mono_bold, font_size = math.round(em * FS_LABEL), height = ui.px(em * 1.5)}, ui.fill())
			if others > 1 { text("n", fmt.tprintf("1 of %d", others), hex(HEX_FAINT), ui.Style_Mod{font = app.mono, font_size = math.round(em * FS_CAPTION)}) }
			ui.spacer(ui.px(em))
		}
		ui.spacer(ui.px(em * 0.3))
		if wizard {
			form_tabs(f, pages[:], em)
			reviewing = f.page == len(pages)   // (a tab just clicked: this frame shows it)
		}
		room := min(FORM_BODY_H_EM, app.state.window_size.y * FORM_BODY_WINDOW / em)
		want := f32(len(pages)) * FORM_LINE_EM
		if !reviewing && len(pages) > 0 { want = field_height(&f.fields[pages[f.page]]) }
		// (too much at once scrolls: the conversation stays in sight, and nothing is crushed)
		if want > room {
			ui.next({width = ui.fill(), height = ui.px(math.round(em * room))})
			if ui.scroll_y("###body") { form_page(app, f, pages[:], reviewing, wizard, em, &send, &next) }
		} else {
			form_page(app, f, pages[:], reviewing, wizard, em, &send, &next)
		}
		ui.spacer(ui.px(em * 0.4))
		ui.next({width = ui.fill(), height = ui.children_sum(), axis = .X, cross = .Center})
		if ui.row(.Center, id = "###foot") {
			ui.spacer(ui.px(em))
			if bevel_button("###form_dismiss", "Dismiss", "", .Ghost, disabled = f.sending).clicked { dismiss = true }
			ui.spacer(ui.fill())
			if wizard && f.page > 0 {
				if bevel_button("###form_prev", "Back", lucide.ARROW_LEFT, .Normal).clicked { f.page -= 1 }
				ui.spacer(ui.px(em * 0.4))
			}
			if wizard && !reviewing {
				if bevel_button("###form_next", f.page == len(pages) - 1 ? "Review" : "Next", lucide.ARROW_RIGHT, .Accent).clicked { next = true }
			} else {
				if bevel_button("###form_send", "Send", lucide.CHECK, .Accent, disabled = f.sending).clicked { send = true }
			}
			ui.spacer(ui.px(em))
		}
		ui.spacer(ui.px(em * 0.7))
	}
	ui.spacer(ui.px(em * 0.7))
	if next { f.page += 1 }
	if dismiss { form_dismiss(app, f) } else if send { form_send(app, f) }
}

// The questions and the review as tabs: any of them at any time, those answered ticked.
@(private = "file")
form_tabs :: proc(f: ^Form_Req, pages: []int, em: f32) {
	ui.next({width = ui.fill(), height = ui.children_sum(), axis = .X})
	if ui.row(id = "###tabs") {
		ui.spacer(ui.px(em))
		h := math.round(em * BUTTON_COMPACT_H_EM)
		// each tab as wide as its title, onto a next line when they do not fit (shared out equally, a long title ran over the
		// next tab)
		ui.next({width = ui.fill()})
		if ui.flow({em * 0.25, em * 0.25}, "###tabs_flow") {
			for p, k in pages {
				fd := &f.fields[p]
				name := fd.title != "" ? fd.title : fmt.tprintf("Question %d", k + 1)
				if bevel_button(fmt.tprintf("###form_tab%d", k), label_safe(name), field_answer(fd) != "" ? lucide.CHECK : "", f.page == k ? .Toggled : .Ghost, height = h).clicked { f.page = k }
			}
			if bevel_button("###form_tab_review", "Review", "", f.page == len(pages) ? .Toggled : .Ghost, height = h).clicked { f.page = len(pages) }
		}
		ui.spacer(ui.px(em))
	}
	ui.spacer(ui.px(em * 0.5))
}

// What the field says now, for a person to read ("": nothing yet).
@(private = "file")
field_answer :: proc(fd: ^Form_Field) -> string {
	switch fd.kind {
	case "boolean":  return fd.on ? "Yes" : "No"
	case "external": return ""
	case "multiselect":
		b := strings.builder_make(context.temp_allocator)
		for o, k in fd.options {
			if !fd.picks[k] { continue }
			if strings.builder_len(b) > 0 { strings.write_string(&b, ", ") }
			strings.write_string(&b, o.label)
		}
		if own := field_value(fd); own != "" {
			if strings.builder_len(b) > 0 { strings.write_string(&b, ", ") }
			strings.write_string(&b, own)
		}
		return strings.to_string(b)
	}
	if fd.choice >= 0 { return fd.options[fd.choice].label }
	return field_value(fd)
}

@(private = "file")
form_page :: proc(app: ^App, f: ^Form_Req, pages: []int, reviewing, wizard: bool, em: f32, send, next: ^bool) {
	if reviewing {
		// (a line per question: a click goes back to it)
		for p, k in pages {
			fd := &f.fields[p]
			ui.next({width = ui.fill(), height = ui.children_sum(), axis = .X, cross = .Center})
			if ui.row(.Center, id = fmt.tprintf("###rv%d", k)) {
				ui.spacer(ui.px(em))
				a := field_answer(fd)
				name := fd.title != "" ? fd.title : fd.description != "" ? fd.description : fmt.tprintf("Question %d", k + 1)
				if bevel_button(fmt.tprintf("###form_rv%d", k), label_safe(fmt.tprintf("%s:  %s", name, a != "" ? a : "no answer")), "", .Ghost, ui.fill(), math.round(em * BUTTON_H_EM), left = true, wrap = true).clicked { f.page = k }
				ui.spacer(ui.px(em))
			}
			ui.spacer(ui.px(em * 0.15))
		}
		return
	}
	if len(pages) == 0 { return }
	fd := &f.fields[pages[f.page]]
	ui.next({width = ui.fill(), height = ui.children_sum(), axis = .X})
	if ui.row(id = fmt.tprintf("###f%d", pages[f.page])) {
		ui.spacer(ui.px(em))
		ui.next({width = ui.fill(), height = ui.children_sum(), axis = .Y})
		if ui.column() {
			if fd.title != "" && fd.title != fd.description {
				text("t", fd.title, hex(HEX_BRIGHT), ui.Style_Mod{font_size = math.round(em * FS_LABEL), height = ui.px(em * 1.5)}, ui.fill())
			}
			if fd.description != "" { info_line(app, "###d", fd.description, em, hex(HEX_TEXT_SOFT)) }
			ui.spacer(ui.px(em * 0.35))
			// (picked, or Enter: on to what comes next, the end of the form if there is nothing else)
			done := false
			form_field(app, fd, em, &done)
			if done { if wizard { next^ = true } else { send^ = true } }
			ui.spacer(ui.px(em * 0.6))
		}
		ui.spacer(ui.px(em))
	}
}

@(private = "file")
option_label :: proc(o: Form_Option) -> string {
	return o.description != "" && o.description != o.label ? fmt.tprintf("%s  -  %s", o.label, o.description) : o.label
}

form_field :: proc(app: ^App, fd: ^Form_Field, em: f32, done: ^bool) {
	h := math.round(em * BUTTON_H_EM)
	switch fd.kind {
	case "boolean":
		ui.toggle("###on", "", &fd.on)
	case "external":
		if fd.url != "" && bevel_button("###open", "Open", lucide.GLOBE, .Normal).clicked { _ = platform.open_url(fd.url) }
	case "multiselect":
		for o, k in fd.options {
			ui.next({width = ui.fill()})
			ui.checkbox(fmt.tprintf("###form_o%d", k), label_safe(option_label(o)), &fd.picks[k], wrap = true)
			ui.spacer(ui.px(em * 0.15))
		}
		if fd.custom { form_line(fd, em, "Something else", done) }
	case:
		for o, k in fd.options {
			if bevel_button(fmt.tprintf("###form_o%d", k), label_safe(option_label(o)), "", fd.choice == k ? .Toggled : .Normal, ui.fill(), h, left = true, wrap = true).clicked {
				fd.choice = k
				ui.field_set(&fd.text, "")
				done^ = true
			}
			ui.spacer(ui.px(em * 0.25))
		}
		if len(fd.options) == 0 || fd.custom {
			form_line(fd, em, fd.placeholder != "" ? fd.placeholder : len(fd.options) > 0 ? "Something else" : "Your answer", done)
		}
	}
}

@(private = "file")
form_line :: proc(fd: ^Form_Field, em: f32, placeholder: string, done: ^bool) {
	ui.next({width = ui.fill(), height = ui.px(math.round(em * 2)), axis = .X, cross = .Center})
	if well("###lw", .X, radius = 6) {
		ui.spacer(ui.px(em * 0.5))
		if ui.tags("bare") {
			ui.next({width = ui.fill(), height = ui.pct(1), text_pad = em * 0.3})
			if ui.line_edit("###form_line", &fd.text, placeholder).committed { done^ = true }
		}
		ui.spacer(ui.px(em * 0.5))
	}
	if ui.field_string(&fd.text) != "" { fd.choice = -1 }   // (one's own words instead of an option)
}
