// What the client knows: the sessions, the open conversation (its messages and their parts), agents, models and the
// pending permission requests. Loaded from the API, then kept current by the event stream.
package occ

import "core:encoding/json"
import "core:mem"
import "core:mem/virtual"
import "core:slice"
import "core:strings"
import "gt:ui"

Session_Info :: struct {
	id, title, parent, directory, agent, model, provider, outcome, project: string,
	created, updated, idle: f64,
	cost:            f64,
	tokens_in, tokens_out, reasoning, cache_read, cache_write: f64,
}

// What a sub-agent does while it runs, from the event stream (its session is not the one shown).
Sub_Live :: struct {
	activity:  string,    // its last tool call ("shell: cargo build"), or what it is doing
	tools:     int,       // tool calls seen
	steps:     int,       // model steps seen
	cost:      f64,
	tokens_in, tokens_out: f64,
	last_ms:   f64,       // when it last did something (epoch ms)
}

Tool_Status :: enum u8 { Pending, Running, Done, Error }
Part_Kind :: enum u8 { Text, Reasoning, Tool }

Part :: struct {
	kind:      Part_Kind,
	ordinal:   int,
	text:      [dynamic]u8,   // text and reasoning
	tool_id:   string,
	tool_name: string,
	status:    Tool_Status,
	input:     string,        // JSON text
	subject:   string,        // what the tool works on (a path, a command, a pattern), for its header
	output:    string,
	done:      bool,
	// a sub-agent launched by this call (tool "subagent")
	sub_session, sub_agent, sub_desc, sub_prompt, sub_model: string,
	sub_background: bool,
	started_ms, ended_ms: f64,
	images:    [dynamic]Image_Ref,   // what a tool handed back as images (screenshots, images read)
}

Msg_Kind :: enum u8 { User, Assistant, Synthetic, Shell, Compaction, Idle, Other }

Message :: struct {
	id:        string,
	kind:      Msg_Kind,
	created:   f64,
	completed: f64,
	agent, model, provider, finish: string,
	text:      string,        // user, synthetic, shell
	parts:     [dynamic]Part,
	tokens_in, tokens_out, reasoning, cache_read: f64,
	cost:      f64,
	streaming: bool,
	// a sub-agent's result handed back to this session (a synthetic message whose metadata.source is "subagent")
	sub_child, sub_state, sub_agent, sub_desc: string,
	images:    [dynamic]Image_Ref,   // attached to a user's prompt
}

// The open conversation. Everything in it lives in its arena, dropped when another conversation opens or the page is
// read again.
Chat :: struct {
	id:        string,
	gen:       u64,
	arena:     virtual.Arena,
	alloc:     mem.Allocator,
	messages:  [dynamic]Message,   // oldest first
	older:     string,             // cursor of the page before the first message ("": none)
	loading:   bool,
	loading_older: bool,           // that page is on its way
	older_failed:  f64,            // when it could not be read (ui.now_ms): tried again a little later, on the next scroll
	keep_id:   string,             // the message built whatever while the page before it comes in (the view stays on it)
	loaded:    bool,
	busy:      bool,
	cost:      f64,
	tokens_in, tokens_out, cache_read: f64,
	model, provider, agent: string,
	// the session itself (GET /api/session/:id), its parent, its sub-agents
	self:         Session_Info,
	have_self:    bool,
	parent_title: string,
	children:     [dynamic]Session_Info,   // sessions whose parent is this one (newest first)
	live:         map[string]Sub_Live,     // keyed by child session id (keys and strings in the arena)
}

Agent_Info :: struct { id, name, description, mode: string }
Model_Info :: struct { id, provider, name, family: string, ctx_len: f64 }
Permission :: struct { id, session, action, message: string, resources: []string }

chat_reset :: proc(c: ^Chat) {
	if c.alloc.procedure != nil { virtual.arena_destroy(&c.arena) }
	gen := c.gen
	c^ = {}
	c.gen = gen + 1
	_ = virtual.arena_init_growing(&c.arena)
	c.alloc = virtual.arena_allocator(&c.arena)
}

open_chat :: proc(app: ^App, session_id: string) {
	if session_id == app.chat.id { return }
	id := strings.clone(session_id, context.temp_allocator)   // (it may live in the arena chat_reset drops: a sub-agent's id from a card)
	chat_reset(&app.chat)
	app.new_dir = ""
	app.chat.id = strings.clone(id, app.chat.alloc)
	app.chat.loading = true
	app.opened_ms = ui.now_ms()
	app.chat_target = 0
	app.first_msg = nil
	app.stick_bottom = true
	if s := find_session(app, id); s != nil {
		app.chat.model = strings.clone(s.model, app.chat.alloc)
		app.chat.provider = strings.clone(s.provider, app.chat.alloc)
		app.chat.agent = strings.clone(s.agent, app.chat.alloc)
		app.chat.cost = s.cost
		app.chat.tokens_in, app.chat.tokens_out, app.chat.cache_read = s.tokens_in, s.tokens_out, s.cache_read
	}
	app.chat.busy = app.busy[id] or_else false
	app.chat.live = make(map[string]Sub_Live, allocator = app.chat.alloc)
	permissions_clear(app)
	load_messages(app, id)
	request(app, .Self, "GET", strings.concatenate({"/api/session/", id}, context.temp_allocator), tag = id)
	load_children(app)
	request(app, .Permissions, "GET", strings.concatenate({"/api/session/", id, "/permission"}, context.temp_allocator), tag = id)
}

find_session :: proc(app: ^App, id: string) -> ^Session_Info {
	for &s in app.sessions { if s.id == id { return &s } }
	return nil
}

////////////////////////////////
// Loading

session_from_json :: proc(it: json.Value, a: mem.Allocator) -> Session_Info {
	return {
		id = strings.clone(jstr(it, "id"), a), title = strings.clone(jstr(it, "title"), a),
		parent = strings.clone(jstr(it, "parentID"), a), directory = strings.clone(jstr(it, "location", "directory"), a),
		agent = strings.clone(jstr(it, "agent"), a), model = strings.clone(jstr(it, "model", "id"), a),
		provider = strings.clone(jstr(it, "model", "providerID"), a), outcome = strings.clone(jstr(it, "outcome"), a),
		project = strings.clone(jstr(it, "projectID"), a),
		created = jnum(it, "time", "created"), updated = jnum(it, "time", "updated"), idle = jnum(it, "time", "idle"),
		cost = jnum(it, "cost"), tokens_in = jnum(it, "tokens", "input"), tokens_out = jnum(it, "tokens", "output"),
		reasoning = jnum(it, "tokens", "reasoning"), cache_read = jnum(it, "tokens", "cache", "read"), cache_write = jnum(it, "tokens", "cache", "write"),
	}
}

// A project's logo (Project.icon: an image as a data URL, the user's override first) and its colour.
Project_Logo :: struct { ref: Image_Ref, has_ref: bool, color: string, worktree: string }

projects_load :: proc(app: ^App, v: json.Value) {
	virtual.arena_destroy(&app.proj_arena)
	_ = virtual.arena_init_growing(&app.proj_arena)
	a := virtual.arena_allocator(&app.proj_arena)
	app.projects = make(map[string]Project_Logo, allocator = a)
	list, _ := v.(json.Array)
	if list == nil { list = jarr(v, "data") }
	for it in list {
		icon := jget(it, "icon")
		url := jstr(icon, "override")
		if !strings.has_prefix(url, "data:") { url = jstr(icon, "url") }
		p := Project_Logo{color = strings.clone(jstr(icon, "color"), a), worktree = strings.clone(jstr(it, "worktree"), a)}
		if strings.has_prefix(url, "data:image/") {
			p.ref = image_ref(strings.clone(url, a), .Data_Url, "image", strings.clone(base_name(p.worktree), a))
			p.has_ref = true
		}
		app.projects[strings.clone(jstr(it, "id"), a)] = p
	}
}

// The logo of a project (nil: none).
project_logo :: proc(app: ^App, project: string) -> ^Image_Ref {
	if project == "" { return nil }
	if p, ok := &app.projects[project]; ok && p.has_ref { return &p.ref }
	return nil
}

// The project of the session shown.
chat_project :: proc(app: ^App) -> string {
	if app.chat.have_self { return app.chat.self.project }
	if s := find_session(app, app.chat.id); s != nil { return s.project }
	return ""
}

// The session shown, as the server describes it (its parent, its outcome, its totals).
self_load :: proc(app: ^App, v: json.Value) {
	c := &app.chat
	c.self = session_from_json(jget(v, "data"), c.alloc)
	c.have_self = true
	if c.self.parent != "" {
		if p := find_session(app, c.self.parent); p != nil {
			c.parent_title = strings.clone(p.title, c.alloc)
		} else {
			request(app, .Parent, "GET", strings.concatenate({"/api/session/", c.self.parent}, context.temp_allocator), tag = c.id)
		}
	}
}

parent_load :: proc(app: ^App, v: json.Value) {
	app.chat.parent_title = strings.clone(jstr(v, "data", "title"), app.chat.alloc)
}

// The sub-agents of the session shown (its children), newest first.
children_load :: proc(app: ^App, v: json.Value) {
	c := &app.chat
	c.children = make([dynamic]Session_Info, c.alloc)
	for it in jarr(v, "data") { append(&c.children, session_from_json(it, c.alloc)) }
}

find_child :: proc(c: ^Chat, id: string) -> ^Session_Info {
	for &s in c.children { if s.id == id { return &s } }
	return nil
}

load_children :: proc(app: ^App) {
	if app.chat.id == "" { return }
	request(app, .Children, "GET", strings.concatenate({"/api/session?limit=200&parentID=", app.chat.id}, context.temp_allocator), tag = app.chat.id)
}

sessions_load :: proc(app: ^App, v: json.Value) {
	virtual.arena_destroy(&app.sess_arena)
	_ = virtual.arena_init_growing(&app.sess_arena)
	a := virtual.arena_allocator(&app.sess_arena)
	app.sessions = make([dynamic]Session_Info, a)
	for it in jarr(v, "data") { append(&app.sessions, session_from_json(it, a)) }
	slice.sort_by(app.sessions[:], proc(x, y: Session_Info) -> bool { return x.updated > y.updated })
	app.sessions_loaded = true
	if app.chat.id == "" && len(app.sessions) > 0 && !app.opened_first {
		app.opened_first = true
		if app.start_session != "" {   // --session=<id>
			open_root(app, app.start_session)
		} else {
			for s in app.sessions { if s.parent == "" { open_chat(app, s.id); break } }
		}
	}
}

agents_load :: proc(app: ^App, v: json.Value) {
	app.have_agents = true
	for it in jarr(v, "data") {
		if jbool(it, "hidden") { continue }
		append(&app.agents, Agent_Info{
			id = strings.clone(jstr(it, "id")), name = strings.clone(jstr(it, "name")),
			description = strings.clone(jstr(it, "description")), mode = strings.clone(jstr(it, "mode")),
		})
	}
}

models_load :: proc(app: ^App, v: json.Value) {
	app.have_models = true
	for it in jarr(v, "data") {
		if jstr(it, "type") != "" && jstr(it, "type") != "chat" { continue }
		if _, has := jget(it, "enabled").(json.Boolean); has && !jbool(it, "enabled") { continue }
		append(&app.models, Model_Info{
			id = strings.clone(jstr(it, "id")), provider = strings.clone(jstr(it, "providerID")),
			name = strings.clone(jstr(it, "name")), family = strings.clone(jstr(it, "family")), ctx_len = jnum(it, "limit", "context"),
		})
	}
	slice.sort_by(app.models[:], proc(x, y: Model_Info) -> bool {
		if x.provider != y.provider { return x.provider < y.provider }
		return x.name < y.name
	})
}

// The sessions running now (the stream only tells about runs that start after it connected).
active_load :: proc(app: ^App, v: json.Value) {
	for k in app.busy { delete(k) }
	clear(&app.busy)
	app.chat.busy = false
	if obj, ok := jget(v, "data").(json.Object); ok {
		for id in obj { set_busy(app, id, true) }
	}
}

permissions_clear :: proc(app: ^App) {
	for p in app.permissions { permission_free(p) }
	clear(&app.permissions)
}

permission_free :: proc(p: Permission) {
	delete(p.id); delete(p.session); delete(p.action); delete(p.message)
	for r in p.resources { delete(r) }
	delete(p.resources)
}

permission_add :: proc(app: ^App, v: json.Value) {
	id := jstr(v, "id")
	if id == "" { return }
	for p in app.permissions { if p.id == id { return } }
	res := jarr(v, "resources")
	list := make([]string, len(res))
	for r, i in res { if s, ok := r.(json.String); ok { list[i] = strings.clone(string(s)) } }
	append(&app.permissions, Permission{
		id = strings.clone(id), session = strings.clone(jstr(v, "sessionID")), action = strings.clone(jstr(v, "action")),
		message = strings.clone(jstr(v, "message")), resources = list,
	})
}

permissions_load :: proc(app: ^App, list: json.Array) {
	for it in list { permission_add(app, it) }
}

permission_remove :: proc(app: ^App, id: string) {
	for p, i in app.permissions {
		if p.id == id { permission_free(p); ordered_remove(&app.permissions, i); return }
	}
}

// A page of messages (newest first in the answer). `older`: it goes before the ones already shown; without it, it replaces
// the newest ones (and what the stream had added to them), and the pages read before them stay.
chat_load :: proc(app: ^App, v: json.Value, older: bool) {
	c := &app.chat
	a := c.alloc
	c.loading = false
	c.loaded = true
	page := make([dynamic]Message, a)
	items := jarr(v, "data")
	#reverse for it in items {
		m := message_from_json(it, a)
		if m.kind == .Idle && len(page) > 0 && page[len(page) - 1].kind == .Idle { continue }
		if older && m.id != "" && find_message(c, m.id) != nil { continue }
		append(&page, m)
	}
	cursor := strings.clone(jstr(v, "cursor", "next"), a)
	if older {
		c.loading_older = false
		c.older = cursor
		// the view stays on what it shows: at the very top the lazy column does not move it (frame does)
		if b := app.first_msg; b != nil && !app.stick_bottom && len(c.messages) > 0 {
			c.keep_id = c.messages[0].id
			app.anchor = b
			app.anchor_y = b.rect.min.y
		}
		inject_at(&page, len(page), ..c.messages[:])
		c.messages = page
	} else {
		kept := -1
		if len(page) > 0 { for m, i in c.messages { if m.id == page[0].id { kept = i; break } } }
		if kept > 0 { inject_at(&page, 0, ..c.messages[:kept]) } else { c.older = cursor }
		c.messages = page
	}
	for m in c.messages {
		if m.kind == .Assistant && m.model != "" {
			c.model, c.provider, c.agent = m.model, m.provider, m.agent
		}
	}
}

message_from_json :: proc(it: json.Value, a: mem.Allocator) -> Message {
	m: Message
	m.id = strings.clone(jstr(it, "id"), a)
	m.created = jnum(it, "time", "created")
	m.completed = jnum(it, "time", "completed")
	m.parts = make([dynamic]Part, a)
	switch jstr(it, "type") {
	case "user":
		m.kind = .User
		m.text = strings.clone(jstr(it, "text"), a)
		for f in jarr(it, "files") {
			mime := jstr(f, "mime")
			if !strings.has_prefix(mime, "image/") { continue }
			if m.images == nil { m.images = make([dynamic]Image_Ref, a) }
			if src := jstr(f, "source", "uri"); jstr(f, "data") == "" && strings.has_prefix(src, "data:") {
				append(&m.images, image_ref(strings.clone(src, a), .Data_Url, strings.clone(mime, a), strings.clone(jstr(f, "name"), a)))
			} else {
				append(&m.images, image_ref(strings.clone(jstr(f, "data"), a), .Base64, strings.clone(mime, a), strings.clone(jstr(f, "name"), a)))
			}
		}
	case "assistant":
		m.kind = .Assistant
		m.agent = strings.clone(jstr(it, "agent"), a)
		m.model = strings.clone(jstr(it, "model", "id"), a)
		m.provider = strings.clone(jstr(it, "model", "providerID"), a)
		m.finish = strings.clone(jstr(it, "finish"), a)
		m.cost = jnum(it, "cost")
		m.tokens_in = jnum(it, "tokens", "input")
		m.tokens_out = jnum(it, "tokens", "output")
		m.reasoning = jnum(it, "tokens", "reasoning")
		m.cache_read = jnum(it, "tokens", "cache", "read")
		m.streaming = m.completed == 0
		ord := [Part_Kind]int{}
		for p in jarr(it, "content") {
			part: Part
			switch jstr(p, "type") {
			case "text":      part.kind = .Text
			case "reasoning": part.kind = .Reasoning
			case "tool":      part.kind = .Tool
			case: continue
			}
			part.ordinal = ord[part.kind]
			ord[part.kind] += 1
			part.done = true
			if part.kind == .Tool {
				part.tool_id = strings.clone(jstr(p, "id"), a)
				part.tool_name = strings.clone(jstr(p, "name"), a)
				st := jget(p, "state")
				switch jstr(st, "status") {
				case "streaming": part.status = .Pending
				case "running":   part.status = .Running
				case "completed": part.status = .Done
				case "error":     part.status = .Error
				}
				tool_set_input(&part, jget(st, "input"), a)
				tool_set_meta(&part, jget(st, "metadata"), a)
				part.started_ms = jnum(p, "time", "created")
				part.ended_ms = jnum(p, "time", "completed")
				if part.status == .Error {
					part.output = strings.clone(error_text(jget(st, "error")), a)
				} else {
					part.output = strings.clone(content_text(jarr(st, "content")), a)
					content_images(&part, jarr(st, "content"), a)
				}
			} else {
				part.text = make([dynamic]u8, a)
				append(&part.text, jstr(p, "text"))
				if part.kind == .Reasoning && len(part.text) == 0 { continue }   // (signed, empty: the provider hides it)
			}
			append(&m.parts, part)
		}
	case "synthetic":
		m.kind = .Synthetic
		m.text = strings.clone(jstr(it, "text"), a)
		if jstr(it, "metadata", "source") == "subagent" {
			m.sub_child = strings.clone(jstr(it, "metadata", "childID"), a)
			m.sub_state = strings.clone(jstr(it, "metadata", "state"), a)
			m.sub_agent = strings.clone(jstr(it, "metadata", "agent"), a)
			m.sub_desc = strings.clone(jstr(it, "description"), a)
			m.text = strings.clone(subagent_body(jstr(it, "text")), a)
		}
	case "shell":
		m.kind = .Shell
		m.text = strings.clone(jstr(it, "command"), a)
	case "compaction":
		m.kind = .Compaction
	case "idle":
		m.kind = .Idle
		m.finish = strings.clone(jstr(it, "outcome"), a)
	case:
		m.kind = .Other
		m.text = strings.clone(jstr(it, "type"), a)
	}
	return m
}

error_text :: proc(v: json.Value) -> string {
	#partial switch x in v {
	case json.String: return string(x)
	case json.Object: return jstr(v, "message")
	}
	return ""
}

// The images among a tool's content (`{type: "file", uri: "data:image/...;base64,...", mime, name}`).
content_images :: proc(p: ^Part, list: json.Array, a: mem.Allocator) {
	for c in list {
		if jstr(c, "type") != "file" { continue }
		mime, uri := jstr(c, "mime"), jstr(c, "uri")
		if !strings.has_prefix(mime, "image/") && !strings.has_prefix(uri, "data:image/") { continue }
		if p.images == nil { p.images = make([dynamic]Image_Ref, a) }
		if strings.has_prefix(uri, "data:") {
			append(&p.images, image_ref(strings.clone(uri, a), .Data_Url, strings.clone(mime, a), strings.clone(jstr(c, "name"), a)))
		} else if d := jstr(c, "data"); d != "" {
			append(&p.images, image_ref(strings.clone(d, a), .Base64, strings.clone(mime, a), strings.clone(jstr(c, "name"), a)))
		}
	}
}

content_text :: proc(list: json.Array) -> string {
	b := strings.builder_make(context.temp_allocator)
	for c in list {
		if t := jstr(c, "text"); t != "" {
			if strings.builder_len(b) > 0 { strings.write_byte(&b, '\n') }
			strings.write_string(&b, t)
		}
	}
	return strings.to_string(b)
}

// The text of a sub-agent's result without its envelope: `<subagent sessionID=".." state=".." description="..">text</subagent>`.
subagent_body :: proc(s: string) -> string {
	t := strings.trim_space(s)
	if strings.has_prefix(t, "<subagent") {
		if i := strings.index_byte(t, '>'); i >= 0 { t = t[i + 1:] }
	}
	t = strings.trim_suffix(strings.trim_space(t), "</subagent>")
	return strings.trim_space(t)
}

// What the server says of a tool call as it runs (a sub-agent's session).
tool_set_meta :: proc(p: ^Part, meta: json.Value, a: mem.Allocator) {
	if sid := jstr(meta, "sessionID"); sid != "" && p.sub_session == "" { p.sub_session = strings.clone(sid, a) }
}

// The input of a tool and the one thing it is about (shown in its header).
tool_set_input :: proc(p: ^Part, input: json.Value, a: mem.Allocator) {
	if input == nil { return }
	p.input = strings.clone(jtext(input), a)
	if p.tool_name == "subagent" || (jstr(input, "agent") != "" && jstr(input, "prompt") != "") {
		p.sub_agent = strings.clone(jstr(input, "agent"), a)
		p.sub_desc = strings.clone(jstr(input, "description"), a)
		p.sub_prompt = strings.clone(jstr(input, "prompt"), a)
		p.sub_model = strings.clone(jstr(input, "model"), a)
		p.sub_background = jbool(input, "background")
		if sid := jstr(input, "sessionID"); sid != "" { p.sub_session = strings.clone(sid, a) }   // (a sub-agent resumed)
	}
	for k in ([]string{"description", "command", "filePath", "path", "pattern", "query", "url", "prompt", "name"}) {
		if s := jstr(input, k); s != "" {
			s := s
			if i := strings.index_byte(s, '\n'); i >= 0 { s = s[:i] }
			p.subject = strings.clone(s, a)
			return
		}
	}
}

////////////////////////////////
// The event stream

@(private = "file")
find_message :: proc(c: ^Chat, id: string) -> ^Message {
	#reverse for &m in c.messages { if m.id == id { return &m } }
	return nil
}

@(private = "file")
assistant :: proc(c: ^Chat, id: string) -> ^Message {
	if m := find_message(c, id); m != nil { return m }
	append(&c.messages, Message{id = strings.clone(id, c.alloc), kind = .Assistant, streaming = true, parts = make([dynamic]Part, c.alloc)})
	return &c.messages[len(c.messages) - 1]
}

@(private = "file")
text_part :: proc(c: ^Chat, m: ^Message, kind: Part_Kind, ordinal: int) -> ^Part {
	for &p in m.parts { if p.kind == kind && p.ordinal == ordinal { return &p } }
	append(&m.parts, Part{kind = kind, ordinal = ordinal, text = make([dynamic]u8, c.alloc)})
	return &m.parts[len(m.parts) - 1]
}

@(private = "file")
tool_part :: proc(c: ^Chat, m: ^Message, id: string) -> ^Part {
	for &p in m.parts { if p.kind == .Tool && p.tool_id == id { return &p } }
	n := 0
	for p in m.parts { if p.kind == .Tool { n += 1 } }
	append(&m.parts, Part{kind = .Tool, ordinal = n, tool_id = strings.clone(id, c.alloc)})
	return &m.parts[len(m.parts) - 1]
}

apply_event :: proc(app: ^App, ev: json.Value) {
	kind := jstr(ev, "type")
	d := jget(ev, "data")
	sid := jstr(d, "sessionID")
	c := &app.chat
	mine := sid != "" && sid == c.id
	a := c.alloc

	switch kind {
	case "session.execution.started":
		set_busy(app, sid, true)
	case "session.execution.succeeded", "session.execution.failed", "session.execution.interrupted", "session.idle":
		if app.busy[sid] or_else false {
			notify_finished(app, sid, strings.trim_prefix(kind, "session.execution."))
		}
		set_busy(app, sid, false)
		if mine {
			load_messages(app, sid)   // the stored page: the stream only gave the pieces
			if kind == "session.execution.failed" { ui.toast(.Bad, "The run failed") }
		}
		app.refresh_due = true
	case "project.updated", "project.created":
		request(app, .Projects, "GET", "/api/project")   // (a new logo)
	case "session.created", "session.renamed", "session.deleted", "session.updated", "session.archived", "session.moved", "session.metadata.updated":
		app.refresh_due = true
		app.children_due = true
	case "permission.asked":
		req := jget(d, "request")
		if req == nil { req = d }
		permission_add(app, req)
		if jstr(req, "sessionID") != c.id { ui.toast(.Warn, "A session is waiting for a permission") }
		if app.prefs.notify_perm && !window_in_front(app) { flash_taskbar(app) }
	case "permission.replied":
		id := jstr(d, "id")
		if id == "" { id = jstr(d, "requestID") }
		permission_remove(app, id)
	}
	if sid != "" && !mine && is_child(c, sid) {
		child_event(app, kind, sid, d, ev)
		return
	}
	if !mine { return }

	mid := jstr(d, "assistantMessageID")
	switch kind {
	case "session.inbox.enqueued":
		item := jget(d, "item")
		if jstr(item, "type") == "user" && find_message(c, jstr(d, "inboxID")) == nil {
			append(&c.messages, Message{id = strings.clone(jstr(d, "inboxID"), a), kind = .User, text = strings.clone(jstr(item, "payload", "text"), a), created = jnum(ev, "created"), parts = make([dynamic]Part, a)})
			app.stick_bottom = true
		}
	case "session.step.started":
		m := assistant(c, mid)
		m.agent = strings.clone(jstr(d, "agent"), a)
		m.model = strings.clone(jstr(d, "model", "id"), a)
		m.provider = strings.clone(jstr(d, "model", "providerID"), a)
		m.created = jnum(d, "started")
		m.streaming = true
		c.model, c.provider, c.agent = m.model, m.provider, m.agent
	case "session.text.started", "session.reasoning.started":
		_ = text_part(c, assistant(c, mid), kind == "session.text.started" ? .Text : .Reasoning, int(jnum(d, "ordinal")))
	case "session.text.delta", "session.reasoning.delta":
		p := text_part(c, assistant(c, mid), kind == "session.text.delta" ? .Text : .Reasoning, int(jnum(d, "ordinal")))
		append(&p.text, jstr(d, "delta"))
	case "session.text.ended", "session.reasoning.ended":
		m := assistant(c, mid)
		k := kind == "session.text.ended" ? Part_Kind.Text : .Reasoning
		t := jstr(d, "text")
		if k == .Reasoning && t == "" {
			// nothing to show (a hidden chain of thought): drop the empty part
			for p, i in m.parts { if p.kind == k && p.ordinal == int(jnum(d, "ordinal")) && len(p.text) == 0 { ordered_remove(&m.parts, i); break } }
			return
		}
		p := text_part(c, m, k, int(jnum(d, "ordinal")))
		clear(&p.text)
		append(&p.text, t)
		p.done = true
	case "session.tool.input.started":
		p := tool_part(c, assistant(c, mid), jstr(d, "id"))
		p.tool_name = strings.clone(jstr(d, "name"), a)
		p.status = .Pending
	case "session.tool.called":
		p := tool_part(c, assistant(c, mid), jstr(d, "id"))
		tool_set_input(p, jget(d, "input"), a)
		p.status = .Running
		p.started_ms = jnum(ev, "created")
	case "session.tool.progress":
		p := tool_part(c, assistant(c, mid), jstr(d, "id"))
		tool_set_meta(p, jget(d, "metadata"), a)
		if p.sub_session != "" { app.children_due = true }
	case "session.tool.success":
		p := tool_part(c, assistant(c, mid), jstr(d, "id"))
		p.status = .Done
		p.done = true
		p.output = strings.clone(content_text(jarr(d, "content")), a)
		content_images(p, jarr(d, "content"), a)
		p.ended_ms = jnum(ev, "created")
		tool_set_meta(p, jget(d, "metadata"), a)
		if p.sub_session != "" { app.children_due = true }
	case "session.tool.failed":
		p := tool_part(c, assistant(c, mid), jstr(d, "id"))
		p.status = .Error
		p.done = true
		p.output = strings.clone(error_text(jget(d, "error")), a)
	case "session.step.ended":
		m := assistant(c, mid)
		m.streaming = false
		m.finish = strings.clone(jstr(d, "finish"), a)
		m.cost = jnum(d, "cost")
		m.tokens_in = jnum(d, "tokens", "input")
		m.tokens_out = jnum(d, "tokens", "output")
		m.reasoning = jnum(d, "tokens", "reasoning")
		m.cache_read = jnum(d, "tokens", "cache", "read")
	case "session.usage.updated":
		c.cost = jnum(d, "cost")
		c.tokens_in = jnum(d, "tokens", "input")
		c.tokens_out = jnum(d, "tokens", "output")
		c.cache_read = jnum(d, "tokens", "cache", "read")
	}
}

// A session the shown one launched: one of its children, or the session of one of its sub-agent calls.
is_child :: proc(c: ^Chat, sid: string) -> bool {
	if find_child(c, sid) != nil { return true }
	for &m in c.messages {
		for &p in m.parts { if p.sub_session == sid { return true } }
	}
	return false
}

// An event of a sub-agent of the session shown: what it is doing now, what it has cost.
child_event :: proc(app: ^App, kind, sid: string, d, ev: json.Value) {
	c := &app.chat
	a := c.alloc
	key := sid
	live, has := c.live[sid]
	if !has { key = strings.clone(sid, a) }
	now := jnum(ev, "created")
	if now == 0 { now = now_epoch_ms() }
	switch kind {
	case "session.step.started":
		live.steps += 1
		live.activity = "thinking"
	case "session.reasoning.started":
		live.activity = "thinking"
	case "session.text.started", "session.text.delta":
		live.activity = "writing"
	case "session.tool.input.started":
		live.activity = strings.clone(jstr(d, "name"), a)
	case "session.tool.called":
		live.tools += 1
		tmp: Part
		tmp.tool_name = live.activity
		tool_set_input(&tmp, jget(d, "input"), context.temp_allocator)
		live.activity = tmp.subject != "" ? strings.clone(strings.concatenate({live.activity, ": ", tmp.subject}, context.temp_allocator), a) : live.activity
	case "session.usage.updated":
		live.cost = jnum(d, "cost")
		live.tokens_in = jnum(d, "tokens", "input") + jnum(d, "tokens", "cache", "read")
		live.tokens_out = jnum(d, "tokens", "output")
	case "session.execution.succeeded", "session.execution.failed", "session.execution.interrupted", "session.idle":
		live.activity = ""
		app.children_due = true
	case:
		return
	}
	live.last_ms = now
	c.live[key] = live
}

set_busy :: proc(app: ^App, id: string, busy: bool) {
	if id == "" { return }
	if busy {
		if id not_in app.busy { app.busy[strings.clone(id)] = true }
	} else if id in app.busy {
		key, _ := delete_key(&app.busy, id)
		delete(key)
	}
	if id == app.chat.id { app.chat.busy = busy }
}
