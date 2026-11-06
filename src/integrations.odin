// The Connections page of the settings: what the server can sign in to, the accounts it holds, and the ways to add one (a key, a login in
// the browser, what is already on the machine, a command). An integration's method may ask questions: they are the fields of a form.
//
// A key goes from its field to the server and is forgotten. The list of credentials says theirs too: only the ids and which is active are
// read from it, nothing else is ever copied here.
package occ

import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:mem/virtual"
import "core:strings"
import "gt:platform"
import "gt:ui"

Method_Kind :: enum u8 { Key, Oauth, External, Command, Env }

Int_Method :: struct {
	kind:   Method_Kind,
	id, label: string,
	names:  []string,    // Env: the variables; Command: what runs
	form:   ^Form_Req,   // what it asks (nil: nothing)
}

Connection :: struct {
	credential: bool,            // else from the environment
	id, label, method: string,   // (for the environment, `label` is the variable)
	needs_auth: bool,
	message, url: string,
	active: bool,
}

Integration :: struct {
	id, name:    string,
	methods:     []Int_Method,
	connections: []Connection,
}

// Connecting, from the ways offered to what the server says. (`method`: the way, in the integration shown.)
Connect_Choose  :: struct {}
Connect_Fill    :: struct { method: int }
Connect_Sending :: struct { method: int, kind: string }   // Integrations.sending is on its way; kind: "oauth", "command", "": it ends there
// A login or a command under way on the server.
Connect_Waiting :: struct {
	attempt, url, instructions: string,   // (owned)
	kind:    string,                      // "oauth", "command"
	by_code: bool,                        // the login ends with a code to paste
	misses:  int,                         // readings of its status that failed in a row
}
Connect_Finishing :: struct { wait: Connect_Waiting }   // the code is on its way: back to `wait` if it is refused

Connect_Step :: union #no_nil { Connect_Choose, Connect_Fill, Connect_Sending, Connect_Waiting, Connect_Finishing }

Integrations :: struct {
	read:     Remote,            // the list
	active:   Remote,            // which account is in use
	list:     [dynamic]Integration,
	arena:    virtual.Arena,
	has_arena: bool,
	dirty:    bool,              // changed on the server while something was being filled in
	search:   ui.Text_Field,
	shown:    string,            // the integration open (owned, "": the list)
	step:     Connect_Step,
	sending:  Remote,            // what Sending and Finishing wait for: its ticket ties the answer to this attempt
	poll:     Remote,            // the status of a login under way
	key, label, code: ui.Text_Field,
	failed:   string,            // why it did not work (owned)
	renaming: string,            // the connection whose label is edited (owned)
	rename:   ui.Text_Field,
	removing: string,            // the connection asked about (owned)
}

integrations_ask :: proc(app: ^App) {
	n := &app.cx.integrations
	remote_begin(&n.read)
	request(app, .Integrations, "GET", "/api/integration", remote = &n.read)
}

@(private = "file")
connect_idle :: proc(n: ^Integrations) -> bool {
	_, idle := n.step.(Connect_Choose)
	return idle
}

@(private = "file")
integrations_free :: proc(n: ^Integrations) {
	for it in n.list { for m in it.methods { if m.form != nil { form_free(m.form) } } }
	clear(&n.list)
	if n.has_arena { virtual.arena_destroy(&n.arena) }
	n.has_arena = false
}

@(private = "file")
method_kind :: proc(s: string) -> (kind: Method_Kind, ok: bool) {
	switch s {
	case "key":      return .Key, true
	case "oauth":    return .Oauth, true
	case "external": return .External, true
	case "command":  return .Command, true
	case "env":      return .Env, true
	}
	return
}

// Those connected first, each kind by the server's order. (What is being filled in stays: the list comes again when it is over.)
integrations_load :: proc(app: ^App, v: json.Value) {
	n := &app.cx.integrations
	if !connect_idle(n) { n.dirty = true; return }
	integrations_free(n)
	_ = virtual.arena_init_growing(&n.arena)
	n.has_arena = true
	a := virtual.arena_allocator(&n.arena)
	list := jarr(v, "data")
	for pass in 0 ..< 2 {
		for it in list {
			if (len(jarr(it, "connections")) > 0) != (pass == 0) { continue }
			one := Integration{id = strings.clone(jstr(it, "id"), a), name = strings.clone(jstr(it, "name"), a)}
			methods := make([dynamic]Int_Method, a)
			for m in jarr(it, "methods") {
				kind, known := method_kind(jstr(m, "type"))
				if !known { continue }
				im := Int_Method{kind = kind, id = strings.clone(jstr(m, "id"), a), label = strings.clone(jstr(m, "label"), a)}
				words := jarr(m, kind == .Env ? "names" : "command")
				im.names = make([]string, len(words), a)
				for w, k in words { s, _ := w.(json.String); im.names[k] = strings.clone(string(s), a) }
				if fields := jarr(m, "form"); len(fields) > 0 { im.form = form_new("", "", "", false, fields) }
				append(&methods, im)
			}
			one.methods = methods[:]
			conns := jarr(it, "connections")
			one.connections = make([]Connection, len(conns), a)
			for c, k in conns {
				env := jstr(c, "type") == "env"
				one.connections[k] = {
					credential = !env, id = strings.clone(jstr(c, "id"), a), label = strings.clone(jstr(c, env ? "name" : "label"), a), method = strings.clone(jstr(c, "method"), a),
					needs_auth = jstr(c, "status", "status") == "needs_auth", message = strings.clone(jstr(c, "status", "message"), a), url = strings.clone(jstr(c, "status", "url"), a),
				}
			}
			append(&n.list, one)
		}
	}
	remote_begin(&n.active)
	request(app, .Credentials, "GET", "/api/credential", remote = &n.active)
}

// Which account of each integration is in use: the only thing read from this list.
credentials_load :: proc(app: ^App, v: json.Value) {
	n := &app.cx.integrations
	for c in jarr(v, "data") {
		active, _ := jget(c, "active").(json.Boolean)
		id := jstr(c, "id")
		for it in n.list { for &k in it.connections { if k.id == id { k.active = bool(active) } } }
	}
}

// Something changed on the server: a login, another client. The models come with what is connected.
integrations_changed :: proc(app: ^App) {
	request(app, .Models, "GET", "/api/model")
	integrations_reread(app)
}

// Read again if it was read at all, once nothing is being filled in: a list that could not be read would hide that.
integrations_reread :: proc(app: ^App) {
	n := &app.cx.integrations
	if n.read.state == .Idle { return }
	if !connect_idle(n) { n.dirty = true; return }
	integrations_ask(app)
}

// (`app.conn` is still the server left: a login under way there is told it is over.)
integrations_forget :: proc(app: ^App) {
	n := &app.cx.integrations
	n.dirty = false
	connect_cancel(app)
	integrations_free(n)
	set_text(&n.shown, ""); set_text(&n.failed, ""); set_text(&n.renaming, ""); set_text(&n.removing, "")
	ui.field_set(&n.search, "")
	ui.field_set(&n.rename, "")
	remote_reset(&n.read)
	remote_reset(&n.active)
}

@(private = "file")
integration_find :: proc(n: ^Integrations, id: string) -> ^Integration {
	for &it in n.list { if it.id == id { return &it } }
	return nil
}

@(private = "file")
set_text :: proc(s: ^string, value: string) {
	delete(s^)
	s^ = strings.clone(value)
}

@(private = "file")
waiting_free :: proc(w: Connect_Waiting) { delete(w.attempt); delete(w.url); delete(w.instructions) }

// Back to the ways of connecting; what was typed is gone, a key first of all, and what a way asks with it. An answer on its way no longer
// counts.
@(private = "file")
connect_reset :: proc(app: ^App) {
	n := &app.cx.integrations
	ui.field_set(&n.key, "")
	ui.field_set(&n.code, "")
	ui.field_set(&n.label, "")
	if it := integration_find(n, n.shown); it != nil {
		for m in it.methods { if m.form != nil { form_reset(m.form) } }
	}
	#partial switch s in n.step {
	case Connect_Waiting:   waiting_free(s)
	case Connect_Finishing: waiting_free(s.wait)
	}
	n.step = Connect_Choose{}
	remote_reset(&n.sending)
	remote_reset(&n.poll)
	if n.dirty { n.dirty = false; integrations_ask(app) }
}

@(private = "file")
method_title :: proc(m: ^Int_Method) -> string {
	if m.label != "" { return m.label }
	switch m.kind {
	case .Key:      return "API key"
	case .Oauth:    return "Sign in"
	case .External: return "Use what is on this machine"
	case .Command:  return "Run a command"
	case .Env:      return "From the environment"
	}
	return ""
}

// `"answer":{...}` and the label, for the end of a body; what is missing, if something is.
connect_extra :: proc(form: ^Form_Req, label: string) -> (extra, problem: string) {
	answer := `"answer":{}`
	if form != nil {
		body, missing, _ := form_answer(form)
		if missing != "" { return "", missing }
		answer = body[1:len(body) - 1]
	}
	trimmed := strings.trim_space(label)
	return trimmed != "" ? fmt.tprintf(`%s,"label":%s`, answer, jquote(trimmed)) : answer, ""
}

// (`method`: `m`'s place in the integration.)
connect_send :: proc(app: ^App, it: ^Integration, m: ^Int_Method, method: int) {
	n := &app.cx.integrations
	extra, problem := connect_extra(m.form, ui.field_string(&n.label))
	if problem != "" { set_text(&n.failed, problem); return }
	key := strings.trim_space(ui.field_string(&n.key))
	if m.kind == .Key && key == "" { set_text(&n.failed, "The key is empty"); return }
	set_text(&n.failed, "")
	base := fmt.tprintf("/api/integration/%s/connect", url_escape(it.id))
	kind := ""
	remote_begin(&n.sending)
	switch m.kind {
	case .Key:
		request(app, .Connected, "POST", fmt.tprintf("%s/key", base), fmt.tprintf(`{{"key":%s,%s}}`, jquote(key), extra), remote = &n.sending)
		ui.field_set(&n.key, "")
	case .External:
		request(app, .Connected, "POST", fmt.tprintf("%s/external", base), fmt.tprintf(`{{"methodID":%s,%s}}`, jquote(m.id), extra), remote = &n.sending)
	case .Oauth:
		kind = "oauth"
		request(app, .Connect_Begin, "POST", fmt.tprintf("%s/oauth", base), fmt.tprintf(`{{"methodID":%s,%s}}`, jquote(m.id), extra), remote = &n.sending)
	case .Command:
		kind = "command"
		trimmed := strings.trim_space(ui.field_string(&n.label))
		label := trimmed != "" ? fmt.tprintf(`,"label":%s`, jquote(trimmed)) : ""
		request(app, .Connect_Begin, "POST", fmt.tprintf("%s/command", base), fmt.tprintf(`{{"methodID":%s%s}}`, jquote(m.id), label), remote = &n.sending)
	case .Env:
		remote_reset(&n.sending)
		return
	}
	n.step = Connect_Sending{method = method, kind = kind}
}

@(private = "file")
attempt_path :: proc(n: ^Integrations, w: Connect_Waiting) -> string {
	return fmt.tprintf("/api/integration/%s/connect/%s/%s", url_escape(n.shown), w.kind, url_escape(w.attempt))
}

// Its status in a while, by a thread that sleeps: nothing is drawn meanwhile.
@(private = "file")
connect_poll :: proc(app: ^App) {
	n := &app.cx.integrations
	w, waiting := n.step.(Connect_Waiting)
	if !waiting { return }
	remote_begin(&n.poll)
	request_later(app, .Connect_Status, attempt_path(n, w), CONNECT_POLL_MS, "", remote = &n.poll)
}

// Try again, once the readings have stopped.
connect_poll_again :: proc(app: ^App) {
	if w, waiting := &app.cx.integrations.step.(Connect_Waiting); waiting { w.misses = 0 }
	connect_poll(app)
}

// A login or a command began: the browser opens on the click that asked for it. (A begin for an attempt given up does not come here:
// answer_left ends it on the server.)
connect_begun :: proc(app: ^App, v: json.Value) {
	n := &app.cx.integrations
	s, sending := n.step.(Connect_Sending)
	if !sending { return }
	attempt := jstr(v, "data", "attemptID")
	if attempt == "" { connect_failed(app, "The server did not say how to go on"); return }
	w := Connect_Waiting{attempt = strings.clone(attempt), url = strings.clone(jstr(v, "data", "url")), instructions = strings.clone(jstr(v, "data", "instructions")), kind = s.kind, by_code = jstr(v, "data", "mode") == "code"}
	n.step = w
	if w.url != "" { _ = platform.open_url(w.url) }
	if !w.by_code { connect_poll(app) }
}

connect_status :: proc(app: ^App, v: json.Value) {
	n := &app.cx.integrations
	w, waiting := &n.step.(Connect_Waiting)
	if !waiting { return }
	w.misses = 0
	switch jstr(v, "data", "status") {
	case "complete": connect_done(app)
	case "failed":
		msg := jstr(v, "data", "message")
		set_text(&n.failed, msg != "" ? msg : "It did not work")
		connect_reset(app)
	case "expired":
		set_text(&n.failed, "It took too long: the attempt expired")
		connect_reset(app)
	case:
		if msg := jstr(v, "data", "message"); msg != "" { set_text(&w.instructions, msg) }
		connect_poll(app)
	}
}

// A reading that did not come through says nothing of the login: asked again, a few times. After that the readings stop, and connect_wait
// says so, with Try again beside its Cancel.
connect_poll_failed :: proc(app: ^App) {
	w, waiting := &app.cx.integrations.step.(Connect_Waiting)
	if !waiting { return }
	w.misses += 1
	if w.misses < CONNECT_POLL_MISSES { connect_poll(app) }
}

connect_done :: proc(app: ^App) {
	n := &app.cx.integrations
	set_text(&n.failed, "")
	n.dirty = false
	connect_reset(app)
	ui.toast(.Good, "Connected")
	integrations_changed(app)
}

// What was sent came back with a refusal, or not at all: one step back, and why. (An answer for an attempt given up has no ticket here.)
connect_failed :: proc(app: ^App, message: string) {
	n := &app.cx.integrations
	set_text(&n.failed, message)
	#partial switch s in n.step {
	case Connect_Sending:   n.step = Connect_Fill{s.method}
	case Connect_Finishing: n.step = s.wait
	}
}

// Whatever it had got to. An attempt whose id is known is ended here, one on its way when its id comes: answer_left.
connect_cancel :: proc(app: ^App) {
	n := &app.cx.integrations
	#partial switch s in n.step {
	case Connect_Waiting:   request(app, .Action, "DELETE", attempt_path(n, s))
	case Connect_Finishing: request(app, .Action, "DELETE", attempt_path(n, s.wait))
	}
	connect_reset(app)
}

// The code of a login that ends with one.
connect_finish :: proc(app: ^App) {
	n := &app.cx.integrations
	w, waiting := n.step.(Connect_Waiting)
	if !waiting { return }
	code := strings.trim_space(ui.field_string(&n.code))
	if code == "" { set_text(&n.failed, "The code is empty"); return }
	set_text(&n.failed, "")
	n.step = Connect_Finishing{wait = w}
	remote_begin(&n.sending)
	request(app, .Connected, "POST", fmt.tprintf("%s/complete", attempt_path(n, w)), fmt.tprintf(`{{"code":%s}}`, jquote(code)), remote = &n.sending)
}

// A login left open when the settings close would wait for nothing.
integrations_watch :: proc(app: ^App) {
	n := &app.cx.integrations
	if !app.settings_open && !connect_idle(n) { connect_cancel(app) }
}

@(private = "file")
line :: proc(id: string, f: ^ui.Text_Field, hint: string, em: f32, secret := false) -> ui.Edit_Result {
	res: ui.Edit_Result
	ui.next({width = ui.fill(), height = ui.px(math.round(em * 2)), axis = .X, cross = .Center})
	if well(fmt.tprintf("%s_w", id), .X, radius = 6) {
		ui.spacer(ui.px(em * 0.5))
		if ui.tags("bare") {
			ui.next({width = ui.fill(), height = ui.pct(1), text_pad = em * 0.3})
			res = ui.line_edit(id, f, hint, secret = secret)
		}
		ui.spacer(ui.px(em * 0.5))
	}
	return res
}

page_connections :: proc(app: ^App, em: f32) {
	n := &app.cx.integrations
	if n.read.state == .Idle { integrations_ask(app) }
	// (what is being filled in stays whatever a reading does: the list is not what it needs)
	if connect_idle(n) && !read_shown(app, "###int_read", &n.read, em, integrations_ask) { return }
	if remote_failed(&n.active) {
		read_shown(app, "###int_active", &n.active, em, integrations_ask)   // (which is in use is not known: no row can say)
		ui.spacer(ui.px(em * 0.4))
	}
	if n.failed != "" {
		info_line(app, "###int_failed", n.failed, em, hex(HEX_RED))
		ui.spacer(ui.px(em * 0.4))
	}
	if it := integration_find(n, n.shown); it != nil {
		integration_page(app, it, em)
		return
	}
	info_line(app, "###int_say", "The accounts the server signs in with: what you connect here gives you its models.", em)
	ui.spacer(ui.px(em * 0.5))
	line("###int_find", &n.search, "Find an integration", em)
	ui.spacer(ui.px(em * 0.5))
	word := strings.trim_space(ui.field_string(&n.search))
	shown, hidden := 0, 0
	for &it in n.list {
		if word != "" {
			_, _, by_name := ui.fuzzy_score(word, it.name)
			if !by_name { continue }
		}
		if shown == INTEGRATIONS_ROWS { hidden += 1; continue }
		integration_row(app, &it, shown, em)
		shown += 1
	}
	if shown == 0 { info_line(app, "###int_none", "Nothing matches.", em) }
	if hidden > 0 { info_line(app, "###int_more", fmt.tprintf("%d more: search to find them.", hidden), em) }
}

@(private = "file")
integration_row :: proc(app: ^App, it: ^Integration, k: int, em: f32) {
	n := &app.cx.integrations
	ui.next({width = ui.fill(), height = ui.px(math.round(em * 2)), axis = .X, cross = .Center, cursor = .Hand})
	row := ui.build_box({.Clickable}, fmt.tprintf("###intr_%s", label_safe(it.id)))
	if ui.signal(row).clicked {
		set_text(&n.shown, it.id)
		set_text(&n.failed, "")
	}
	if ui.parent(row) {
		connected := len(it.connections) > 0
		glyph(connected ? ICO_CHECK : ICO_PLUG, hex(connected ? HEX_GREEN : HEX_FAINT), math.round(em * ICON_SMALL), em * 1.2)
		ui.spacer(ui.px(em * 0.3))
		text("n", it.name, hex(HEX_TEXT), ui.Style_Mod{font_size = math.round(em * FS_SMALL), height = ui.px(em * 1.6)}, ui.fill())
		if connected {
			text("c", fmt.tprintf("%d connected", len(it.connections)), hex(HEX_FAINT), ui.Style_Mod{font_size = math.round(em * FS_CAPTION), height = ui.px(em * 1.6)})
			ui.spacer(ui.px(em * 0.4))
		}
		glyph(ICO_RIGHT, hex(HEX_FAINT), math.round(em * ICON_SMALL), em)
	}
}

@(private = "file")
integration_page :: proc(app: ^App, it: ^Integration, em: f32) {
	n := &app.cx.integrations
	small := math.round(em * BUTTON_COMPACT_H_EM)
	if bevel_button("###int_back", "All connections", ICO_BACK, .Ghost, height = small).clicked {
		connect_cancel(app)
		set_text(&n.shown, "")
		set_text(&n.failed, "")
		return
	}
	section(strings.to_upper(it.name, context.temp_allocator), em)
	for &c, i in it.connections { connection_row(app, &c, i, em) }
	if len(it.connections) > 0 { ui.spacer(ui.px(em * 0.6)) }
	fill :: proc(app: ^App, it: ^Integration, method: int, em: f32) {
		if method < len(it.methods) { connect_fill(app, it, &it.methods[method], method, em) }
	}
	switch s in n.step {
	case Connect_Choose:
		for &m, i in it.methods {
			if m.kind == .Env {
				info_line(app, fmt.tprintf("###int_env%d", i), fmt.tprintf("Or set %s where the server runs.", strings.join(m.names, " or ", context.temp_allocator)), em)
				continue
			}
			if bevel_button(fmt.tprintf("###int_m%d", i), label_safe(method_title(&m)), ICO_ADD, .Normal, ui.fill(), math.round(em * BUTTON_H_EM), left = true).clicked {
				n.step = Connect_Fill{i}
				set_text(&n.failed, "")
			}
			ui.spacer(ui.px(em * 0.25))
		}
	case Connect_Fill:    fill(app, it, s.method, em)
	case Connect_Sending: fill(app, it, s.method, em)
	case Connect_Waiting, Connect_Finishing:
		connect_wait(app, em)
	}
}

@(private = "file")
connection_row :: proc(app: ^App, c: ^Connection, i: int, em: f32) {
	n := &app.cx.integrations
	small := math.round(em * BUTTON_SMALL_H_EM)
	ui.next({width = ui.fill(), height = ui.children_sum(), axis = .X, cross = .Center})
	if ui.row(.Center, id = fmt.tprintf("###intc%d", i)) {
		lamp: u32 = c.needs_auth ? HEX_YELLOW : c.active ? HEX_GREEN : HEX_FAINT
		glyph(c.needs_auth ? ICO_WARN : ICO_CHECK, hex(lamp), math.round(em * ICON_SMALL), em * 1.2)
		ui.spacer(ui.px(em * 0.3))
		if c.id == n.renaming && c.credential {
			res := line("###int_rename", &n.rename, "A name", em)
			ui.set_focus(res.box.key)
			if res.committed {
				request(app, .Credential_Done, "PATCH", fmt.tprintf("/api/credential/%s", url_escape(c.id)), fmt.tprintf(`{{"label":%s}}`, jquote(strings.trim_space(ui.field_string(&n.rename)))))
				set_text(&n.renaming, "")
			}
			if res.cancelled { set_text(&n.renaming, "") }
		} else {
			name := c.label != "" ? c.label : c.method
			text("n", c.credential ? name : fmt.tprintf("%s, in the environment", name), hex(HEX_TEXT), ui.Style_Mod{font_size = math.round(em * FS_SMALL), height = ui.px(em * 1.6)}, ui.fill())
		}
		if c.credential && c.id != n.renaming {
			if c.id == n.removing {
				text("q", "Remove it?", hex(HEX_FAINT), ui.Style_Mod{font_size = math.round(em * FS_SMALL), height = ui.px(em * 1.6)})
				ui.spacer(ui.px(em * 0.4))
				if bevel_button("###int_yes", "Remove", ICO_DELETE, .Danger, height = small).clicked {
					request(app, .Credential_Done, "DELETE", fmt.tprintf("/api/credential/%s", url_escape(c.id)))
					set_text(&n.removing, "")
				}
				ui.spacer(ui.px(em * 0.3))
				if bevel_button("###int_no", "Keep", "", .Normal, height = small).clicked { set_text(&n.removing, "") }
			} else {
				if !c.active && bevel_button("###int_use", "Use", "", .Normal, height = small).clicked {
					request(app, .Credential_Done, "POST", fmt.tprintf("/api/credential/%s/activate", url_escape(c.id)))
				}
				ui.spacer(ui.px(em * 0.3))
				if bevel_button("###int_ren", "Rename", ICO_EDIT, .Ghost, height = small).clicked {
					set_text(&n.renaming, c.id)
					ui.field_set(&n.rename, c.label)
				}
				ui.spacer(ui.px(em * 0.3))
				if bevel_button("###int_rem", "Remove", ICO_DELETE, .Ghost, height = small).clicked { set_text(&n.removing, c.id) }
			}
		}
	}
	if c.needs_auth {
		info_line(app, fmt.tprintf("###intm%d", i), c.message != "" ? c.message : "It must sign in again.", em, hex(HEX_YELLOW))
		if c.url != "" && bevel_button(fmt.tprintf("###into%d", i), "Open", ICO_GLOBE, .Normal, height = small).clicked { _ = platform.open_url(c.url) }
	}
	ui.spacer(ui.px(em * 0.25))
}

@(private = "file")
connect_fill :: proc(app: ^App, it: ^Integration, m: ^Int_Method, method: int, em: f32) {
	n := &app.cx.integrations
	go := false
	section(strings.to_upper(method_title(m), context.temp_allocator), em)
	if m.kind == .Command {
		info_line(app, "###int_cmd", fmt.tprintf("The server will run: %s", strings.join(m.names, " ", context.temp_allocator)), em)
		ui.spacer(ui.px(em * 0.4))
	}
	if m.form != nil {
		for &fd, i in m.form.fields {
			if !field_shown(m.form, &fd) { continue }
			ui.next({width = ui.fill(), height = ui.children_sum(), axis = .Y})
			if ui.column(id = fmt.tprintf("###intf%d", i)) {
				title := fd.title != "" ? fd.title : fd.key
				text("l", title, hex(HEX_TEXT), ui.Style_Mod{font_size = math.round(em * FS_SMALL), height = ui.px(em * 1.6)}, ui.fill())
				if fd.description != "" { info_line(app, "###d", fd.description, em) }
				done := false
				form_field(app, &fd, em, &done)
			}
			ui.spacer(ui.px(em * 0.4))
		}
	}
	if m.kind == .Key {
		if line("###int_key", &n.key, "The key", em, secret = true).committed { go = true }
		ui.spacer(ui.px(em * 0.4))
	}
	if line("###int_label", &n.label, "A name for it (optional)", em).committed { go = true }
	ui.spacer(ui.px(em * 0.5))
	ui.next({width = ui.fill(), height = ui.children_sum(), axis = .X, cross = .Center})
	if ui.row(.Center, id = "###int_foot") {
		ui.spacer(ui.fill())
		if bevel_button("###int_cancel", "Cancel", "", .Normal).clicked {
			set_text(&n.failed, "")
			connect_cancel(app)
			return
		}
		ui.spacer(ui.px(em * 0.4))
		_, sending := n.step.(Connect_Sending)
		if bevel_button("###int_go", sending ? "Connecting…" : m.kind == .Oauth ? "Continue in the browser" : "Connect", ICO_CHECK, .Accent, disabled = sending).clicked { go = true }
	}
	if _, filling := n.step.(Connect_Fill); go && filling { connect_send(app, it, m, method) }
}

@(private = "file")
connect_wait :: proc(app: ^App, em: f32) {
	n := &app.cx.integrations
	w: Connect_Waiting
	finishing := false
	#partial switch s in n.step {
	case Connect_Waiting:   w = s
	case Connect_Finishing: w, finishing = s.wait, true
	}
	section(w.by_code ? "PASTE THE CODE" : "WAITING", em)
	ui.next({width = ui.fill(), font_size = math.round(em * FS_SMALL), flags = {.Text_Wrap, .Selectable}, fg = hex(HEX_TEXT), text_pad = 0})
	ui.paragraph(fmt.tprintf("%s###int_say", label_safe(w.instructions != "" ? w.instructions : "It goes on in the browser.")))
	ui.spacer(ui.px(em * 0.5))
	if remote_failed(&n.poll) {
		info_line(app, "###int_lost", "The server no longer says how this goes. It may still end: try again, or cancel it.", em, hex(HEX_YELLOW))
		ui.spacer(ui.px(em * 0.3))
		read_shown(app, "###int_poll", &n.poll, em, connect_poll_again)
		ui.spacer(ui.px(em * 0.5))
	}
	finish := false
	if w.by_code {
		if line("###int_code", &n.code, "The code", em).committed { finish = true }
		ui.spacer(ui.px(em * 0.5))
	}
	ui.next({width = ui.fill(), height = ui.children_sum(), axis = .X, cross = .Center})
	if ui.row(.Center, id = "###int_wfoot") {
		if w.url != "" && bevel_button("###int_open", "Open again", ICO_GLOBE, .Normal).clicked { _ = platform.open_url(w.url) }
		if w.instructions != "" {
			ui.spacer(ui.px(em * 0.4))
			if bevel_button("###int_copy", "Copy", ICO_COPY, .Normal).clicked { clip_set(w.instructions) }
		}
		ui.spacer(ui.fill())
		if bevel_button("###int_stop", "Cancel", "", .Normal).clicked {
			set_text(&n.failed, "")
			connect_cancel(app)
			return
		}
		if w.by_code {
			ui.spacer(ui.px(em * 0.4))
			if bevel_button("###int_finish", finishing ? "Finishing…" : "Finish", ICO_CHECK, .Accent, disabled = finishing).clicked { finish = true }
		}
	}
	if finish { connect_finish(app) }
}
