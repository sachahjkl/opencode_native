// The link to the opencode server: where it is (service.json), requests on worker threads, the event stream on a
// thread of its own. Every answer reaches the interface through ui.post: it runs on the interface's thread, in
// begin_build, and wakes the window.
package occ

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import "gt:ui"

Server_Config :: struct {
	host:     string,
	port:     u16,
	password: string,
	tls:      bool,     // https (a remote server, a tunnel)
}

DEFAULT_PORT :: 4096

// This computer's opencode server, unless --url= / --password= say otherwise. Where it really runs first: the state the
// background service writes while it runs (~/.local/state/opencode/service.json: its url and password, what
// `opencode service status` prints); else what its configuration asks for (~/.config/opencode/service.json: a port
// that may be stale or absent); else the default port.
discover_server :: proc() -> Server_Config {
	cfg := Server_Config{host = "127.0.0.1", port = DEFAULT_PORT}
	home := os.get_env("USERPROFILE", context.temp_allocator)
	if home == "" { home = os.get_env("HOME", context.temp_allocator) }
	xdg :: proc(name, home, fallback: string) -> string {
		when ODIN_OS != .Windows { if v := os.get_env(name, context.temp_allocator); v != "" { return v } }
		return fmt.tprintf("%s/%s", home, fallback)
	}
	found := false
	// the running service
	if data, err := os.read_entire_file(fmt.tprintf("%s/opencode/service.json", xdg("XDG_STATE_HOME", home, ".local/state")), context.temp_allocator); err == nil {
		if v, jerr := json.parse_string(string(data), parse_integers = true, allocator = context.temp_allocator); jerr == nil {
			if host, port, ok := split_url(jstr(v, "url")); ok {
				cfg.host, cfg.port, found = host, port, true
				cfg.tls = strings.has_prefix(jstr(v, "url"), "https://")
				cfg.password = jstr(v, "password")
			}
		}
	}
	// its configuration
	if data, err := os.read_entire_file(fmt.tprintf("%s/opencode/service.json", xdg("XDG_CONFIG_HOME", home, ".config")), context.temp_allocator); err == nil {
		if v, jerr := json.parse_string(string(data), parse_integers = true, allocator = context.temp_allocator); jerr == nil {
			if !found {
				if p := jnum(v, "port"); p > 0 { cfg.port = u16(p) }
				if h := jstr(v, "hostname"); h != "" { cfg.host = h }
			}
			if cfg.password == "" { cfg.password = jstr(v, "password") }
		}
	}
	// a server listening everywhere is reached here
	if cfg.host == "0.0.0.0" || cfg.host == "::" || cfg.host == "[::]" { cfg.host = "127.0.0.1" }
	for a in os.args[1:] {
		if strings.has_prefix(a, "--password=") { cfg.password = a[len("--password="):] }
		if strings.has_prefix(a, "--url=") {
			u := a[len("--url="):]
			cfg.tls = strings.has_prefix(u, "https://")
			u = strings.trim_prefix(strings.trim_prefix(u, "http://"), "https://")
			u = strings.trim_suffix(u, "/")
			if i := strings.last_index_byte(u, ':'); i >= 0 {
				if p, ok := strconv.parse_int(u[i + 1:]); ok { cfg.port = u16(p) }
				cfg.host = u[:i]
			} else {
				cfg.host = u
				cfg.port = 0   // the default port of the scheme
			}
		}
	}
	cfg.host = strings.clone(cfg.host)
	cfg.password = strings.clone(cfg.password)
	return cfg
}

////////////////////////////////
// JSON helpers (paths of object keys; a missing key gives the zero value)

jget :: proc(v: json.Value, keys: ..string) -> json.Value {
	cur := v
	for k in keys {
		obj, ok := cur.(json.Object)
		if !ok { return nil }
		cur = obj[k] or_else nil
	}
	return cur
}

jstr :: proc(v: json.Value, keys: ..string) -> string {
	#partial switch x in jget(v, ..keys) {
	case json.String: return string(x)
	}
	return ""
}

jnum :: proc(v: json.Value, keys: ..string) -> f64 {
	#partial switch x in jget(v, ..keys) {
	case json.Float:   return f64(x)
	case json.Integer: return f64(x)
	}
	return 0
}

jbool :: proc(v: json.Value, keys: ..string) -> bool {
	#partial switch x in jget(v, ..keys) {
	case json.Boolean: return bool(x)
	}
	return false
}

jarr :: proc(v: json.Value, keys: ..string) -> json.Array {
	#partial switch x in jget(v, ..keys) {
	case json.Array: return x
	}
	return nil
}

JQUOTE_SPARE_BYTES :: 8   // the quotes and a few escapes before the builder grows

// A JSON string literal (quotes included).
jquote :: proc(s: string, allocator := context.temp_allocator) -> string {
	b := strings.builder_make(0, len(s) + JQUOTE_SPARE_BYTES, allocator)
	strings.write_byte(&b, '"')
	for r in s {
		switch r {
		case '"':  strings.write_string(&b, `\"`)
		case '\\': strings.write_string(&b, `\\`)
		case '\n': strings.write_string(&b, `\n`)
		case '\r': strings.write_string(&b, `\r`)
		case '\t': strings.write_string(&b, `\t`)
		case:
			if r < 0x20 { fmt.sbprintf(&b, `\u%04x`, int(r)) } else { strings.write_rune(&b, r) }
		}
	}
	strings.write_byte(&b, '"')
	return strings.to_string(b)
}

// Indented JSON text of a value (tool inputs shown to the user).
jtext :: proc(v: json.Value, allocator := context.temp_allocator) -> string {
	data, err := json.marshal(v, {pretty = true, use_spaces = true, spaces = 2}, allocator)
	if err != nil { return "" }
	return string(data)
}

// A query string value.
url_escape :: proc(s: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	for c in transmute([]u8)s {
		switch c {
		case 'A' ..= 'Z', 'a' ..= 'z', '0' ..= '9', '-', '_', '.', '~': strings.write_byte(&b, c)
		case: fmt.sbprintf(&b, "%%%02X", c)
		}
	}
	return strings.to_string(b)
}

////////////////////////////////
// Requests

Req_Kind :: enum u8 {
	Sessions,       // GET /api/session
	Messages,       // GET /api/session/:id/message (newest page)
	Older,          // GET /api/session/:id/message?cursor= (an older page)
	Agents,
	Models,
	Info,
	Permissions,    // GET /api/session/:id/permission
	Active,         // GET /api/session/active: the sessions running now
	Self,           // GET /api/session/:id: the session shown
	Parent,         // GET /api/session/:parent: the title of the session shown's parent
	Children,       // GET /api/session?parentID=: the sub-agents of the session shown
	// the settings' pages (settings.odin server_facts_answer)
	Cfg, Shells, Mcp, Saved, Usage, Providers, Skills, Commands,
	Projects,       // GET /api/project: the projects and their logos
	Stats,          // GET /api/experimental/session/stats: the project's totals (stats.odin)
	Created,        // POST /api/session: the new session
	Action,         // a POST whose answer only matters when it fails
	Prompt,         // POST /api/session/:id/prompt: the same, and its text comes back to the composer
}

Request :: struct {
	kind:   Req_Kind,
	method: string,
	path:   string,
	body:   string,
	tag:    string,    // the session it is about
	gen:    u64,       // the chat generation it was made for (answers for a chat since left are dropped)
	conn:   ^Conn,     // the connection it goes by (answers from a server since left are dropped)
	facts_gen: u64,    // the reading of the settings' pages it belongs to (answers of an earlier one are dropped)
	// the answer
	status: int,
	resp:   string,
	ok:     bool,
}

request :: proc(app: ^App, kind: Req_Kind, method, path: string, body := "", tag := "") {
	r := new(Request)
	r^ = {kind = kind, method = strings.clone(method), path = strings.clone(path), body = strings.clone(body), tag = strings.clone(tag), gen = app.chat.gen, conn = app.conn, facts_gen = app.facts_gen}
	sync.atomic_add(&app.pending, 1)
	thread.create_and_start_with_poly_data(r, proc(r: ^Request) {
		app := the_app
		r.status, r.resp, r.ok = http_request(&r.conn.http, r.method, r.path, r.body)
		if !ui.post(&app.ui_state, on_answer, r) { request_free(r) }
	}, self_cleanup = true)
}

request_free :: proc(r: ^Request) {
	delete(r.method); delete(r.path); delete(r.body); delete(r.tag); delete(r.resp)
	free(r)
}

ERROR_EXCERPT_BYTES :: 80   // of an error's body, in its toast

// On the interface's thread.
on_answer :: proc(data: rawptr, word: u64) {
	app := the_app
	r := (^Request)(data)
	defer request_free(r)
	sync.atomic_sub(&app.pending, 1)
	if r.conn != app.conn { return }   // a server left
	if !r.ok {
		// (this request failed: whether the connection is down is for the event stream to say, stream_state)
		fmt.eprintfln("request failed: %s %s: %s", r.method, r.path, r.resp)
		request_failed(app, r)
		ui.toast(.Bad, "Server unreachable (%s)", r.path)
		return
	}
	if r.status == 401 { app.auth_failed = true; request_failed(app, r); ui.toast(.Bad, "Authentication refused by the server"); return }
	if r.status >= 400 {
		v, _ := json.parse_string(r.resp, parse_integers = true, allocator = context.temp_allocator)
		msg := jstr(v, "message")
		ui.toast(.Bad, "%s %s: %d %s", r.method, r.path, r.status, msg if msg != "" else r.resp[:min(len(r.resp), ERROR_EXCERPT_BYTES)])
		request_failed(app, r)
		return
	}
	v, err := json.parse_string(r.resp, parse_integers = true, allocator = context.temp_allocator)
	if err != nil && r.kind != .Action && r.kind != .Prompt {
		ui.toast(.Warn, "Unreadable answer (%s)", r.path)
		request_failed(app, r)
		return
	}
	switch r.kind {
	case .Sessions:    sessions_load(app, v)
	case .Messages:
		if r.gen == app.chat.gen && r.tag == app.chat.id {
			first := !app.chat.loaded
			chat_load(app, v, false)
			if first && app.stick_bottom { app.snap_bottom = true }   // (shown at its bottom in the very frame it arrives: frame)
		}
	case .Older:       if r.gen == app.chat.gen && r.tag == app.chat.id { chat_load(app, v, true) }
	case .Agents:      agents_load(app, v)
	case .Models:      models_load(app, v)
	case .Info:        delete(app.server_version); app.server_version = strings.clone(jstr(v, "version"))
	case .Permissions: if r.tag == app.chat.id { permissions_load(app, jarr(v, "data")) }
	case .Active:      active_load(app, v)
	case .Self:        if r.tag == app.chat.id && r.gen == app.chat.gen { self_load(app, v) }
	case .Parent:      if r.tag == app.chat.id && r.gen == app.chat.gen { parent_load(app, v) }
	case .Children:    if r.tag == app.chat.id && r.gen == app.chat.gen { children_load(app, v) }
	case .Cfg, .Shells, .Mcp, .Saved, .Usage, .Providers, .Skills, .Commands: if r.facts_gen == app.facts_gen { server_facts_answer(app, r.kind, v) }
	case .Projects:    projects_load(app, v)
	case .Stats:       stats_load(app, v)
	case .Created:
		id := jstr(v, "data", "id")
		if id != "" {
			refresh_sessions(app)
			open_chat(app, id)
			if app.pending_prompt != "" {
				send_prompt(app, id, app.pending_prompt)
				delete(app.pending_prompt)
				app.pending_prompt = ""
			}
		} else {
			request_failed(app, r)
		}
	case .Action, .Prompt:
	}
}

// What a request that failed leaves undone, whatever the way it failed.
request_failed :: proc(app: ^App, r: ^Request) {
	#partial switch r.kind {
	case .Messages:
		if r.gen == app.chat.gen { app.chat.loading = false }
	case .Older:
		older_failed(app, r)
	case .Created:
		if app.pending_prompt != "" {
			prompt_restore(app, app.pending_prompt)
			delete(app.pending_prompt)
			app.pending_prompt = ""
		}
	case .Prompt:
		if v, err := json.parse_string(r.body, allocator = context.temp_allocator); err == nil { prompt_restore(app, jstr(v, "text")) }
	}
}

// The page before the first message was not read: said where it would have been.
older_failed :: proc(app: ^App, r: ^Request) {
	if r.gen != app.chat.gen || r.tag != app.chat.id { return }
	app.chat.loading_older = false
	app.chat.older_failed = ui.now_ms()
}

SESSIONS_LIMIT :: "200"   // most sessions read at a time (text of the query)

refresh_sessions :: proc(app: ^App) {
	request(app, .Sessions, "GET", "/api/session?limit=" + SESSIONS_LIMIT + "&order=desc")
	request(app, .Active, "GET", "/api/session/active")
}

load_messages :: proc(app: ^App, id: string) {
	request(app, .Messages, "GET", fmt.tprintf("/api/session/%s/message?limit=%d&order=desc", id, app.prefs.page_size), tag = id)
}

// How near, in screens: the page is there before the reader, unless they scroll fast (then messages() shows it coming).
OLDER_MARGIN :: 1.5
OLDER_RETRY_MS :: 3000   // a page that could not be read is not asked for again before this

// The page before the first message, when the view comes near it: read in good time, the reader does not ask for it.
load_older :: proc(app: ^App, b: ^ui.Box) {
	c := &app.chat
	if c.older == "" || c.loading || c.loading_older || !c.loaded { return }
	if c.older_failed > 0 && ui.now_ms() - c.older_failed < OLDER_RETRY_MS { return }
	if min(b.view_off.y, b.view_target.y) > b.size.y * OLDER_MARGIN { return }
	c.loading_older = true
	c.older_failed = 0
	request(app, .Older, "GET", fmt.tprintf("/api/session/%s/message?limit=%d&cursor=%s", app.chat.id, app.prefs.page_size, url_escape(app.chat.older)), tag = app.chat.id)
}

send_prompt :: proc(app: ^App, id, text: string) {
	request(app, .Prompt, "POST", fmt.tprintf("/api/session/%s/prompt", id), fmt.tprintf(`{{"text":%s}}`, jquote(text)), id)
}

create_session :: proc(app: ^App, directory: string) {
	body := directory != "" ? fmt.tprintf(`{{"location":{{"directory":%s}}}}`, jquote(directory)) : "{}"
	request(app, .Created, "POST", "/api/session", body)
}

interrupt_session :: proc(app: ^App, id: string) {
	request(app, .Action, "POST", fmt.tprintf("/api/session/%s/interrupt", id), "", id)
}

reply_permission :: proc(app: ^App, session, id, decision: string) {
	request(app, .Action, "POST", fmt.tprintf("/api/session/%s/permission/%s/reply", session, id), fmt.tprintf(`{{"decision":%s}}`, jquote(decision)), session)
}

switch_model :: proc(app: ^App, session: string, m: Model_Info) {
	request(app, .Action, "POST", fmt.tprintf("/api/session/%s/model", session),
		fmt.tprintf(`{{"model":{{"id":%s,"providerID":%s}}}}`, jquote(m.id), jquote(m.provider)), session)
}

switch_agent :: proc(app: ^App, session, agent: string) {
	request(app, .Action, "POST", fmt.tprintf("/api/session/%s/agent", session), fmt.tprintf(`{{"agent":%s}}`, jquote(agent)), session)
}

rename_session :: proc(app: ^App, session, title: string) {
	request(app, .Action, "PATCH", fmt.tprintf("/api/session/%s", session), fmt.tprintf(`{{"title":%s}}`, jquote(title)), session)
}

delete_session :: proc(app: ^App, session: string) {
	request(app, .Action, "DELETE", fmt.tprintf("/api/session/%s", session), "", session)
}

////////////////////////////////
// The event stream

STREAM_RETRY_S :: 2   // between two connections of the event stream

events_thread :: proc(data: rawptr) {
	c := (^Conn)(data)
	app := the_app
	for !sync.atomic_load(&c.stop) {
		st := http_sse(&c.http, "/api/event", &c.stop, proc(data: string, user: rawptr) -> bool {
			c := (^Conn)(user)
			e := new(Event_Msg)
			e^ = {conn = c, text = strings.clone(data)}
			if !ui.post(&the_app.ui_state, on_event, e, EVENT_WORD) { delete(e.text); free(e); return false }
			return true
		}, c, proc(user: rawptr) {
			ui.post(&the_app.ui_state, proc(data: rawptr, word: u64) { if data == the_app.conn { stream_state(the_app, true) } }, user)
		})
		if sync.atomic_load(&c.stop) { break }
		ui.post(&app.ui_state, proc(data: rawptr, word: u64) { if data == the_app.conn { stream_state(the_app, false) } }, c, u64(st))
		time.sleep(STREAM_RETRY_S * time.Second)
	}
}

// An event's text and the connection it came by (dropped when that is no longer the one connected).
Event_Msg :: struct { conn: ^Conn, text: string }

EVENT_WORD :: u64(0x4556454e54)   // a post's word for an Event_Msg (on_drop frees it)

// The stream (re)connected or dropped: on a reconnection everything is read again (events were missed meanwhile).
stream_state :: proc(app: ^App, up: bool) {
	was := app.online
	app.online = up
	if up && !was {
		refresh_sessions(app)
		if app.chat.id != "" { load_messages(app, app.chat.id) }
		if !app.have_agents { request(app, .Agents, "GET", "/api/agent") }
		if !app.have_models { request(app, .Models, "GET", "/api/model") }
		request(app, .Info, "GET", "/api/info")
		request(app, .Projects, "GET", "/api/project")
	}
}

on_event :: proc(data: rawptr, word: u64) {
	app := the_app
	e := (^Event_Msg)(data)
	defer { delete(e.text); free(e) }
	if e.conn != app.conn { return }   // a server left
	v, err := json.parse_string(e.text, parse_integers = true, allocator = context.temp_allocator)
	if err != nil { return }
	apply_event(app, v)
}

on_drop :: proc(data: rawptr, word: u64) {
	// an event (a Request is never dropped: the queue closes after the workers; the stream's states carry their Conn)
	if word == EVENT_WORD { e := (^Event_Msg)(data); delete(e.text); free(e) }
}

// "http://host:port[/]" -> host, port (ok false: not that form).
split_url :: proc(u: string) -> (host: string, port: u16, ok: bool) {
	v := strings.trim_suffix(strings.trim_prefix(strings.trim_prefix(u, "http://"), "https://"), "/")
	i := strings.last_index_byte(v, ':')
	if i <= 0 { return }
	p, pok := strconv.parse_int(v[i + 1:])
	if !pok || p <= 0 || p > 65535 { return }
	return v[:i], u16(p), true
}
