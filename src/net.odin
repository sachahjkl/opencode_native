// The link to the opencode server: where it is (service.json), requests on worker threads, the event stream on a
// thread of its own. Every answer reaches the interface through ui.post: it runs on the interface's thread, in
// begin_build, and wakes the window.
package ocn

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:mem/virtual"
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
	local := cfg
	url_given, password_given := false, false
	for a in os.args[1:] {
		if strings.has_prefix(a, "--password=") { cfg.password = a[len("--password="):]; password_given = true }
		if strings.has_prefix(a, "--url=") {
			u := a[len("--url="):]
			url_given = true
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
	// the password of this computer's server goes to that server only
	if url_given && !password_given && !same_server(local.host, local.port, cfg.host, cfg.port) { cfg.password = "" }
	cfg.host = strings.clone(cfg.host)
	cfg.password = strings.clone(cfg.password)
	return cfg
}

// Two addresses of one server: the same port and the same host, the names of this computer being one.
same_server :: proc(host_a: string, port_a: u16, host_b: string, port_b: u16) -> bool {
	if port_a != port_b { return false }
	return host_a == host_b || (host_is_here(host_a) && host_is_here(host_b))
}

host_is_here :: proc(h: string) -> bool { return h == "localhost" || h == "::1" || h == "[::1]" || strings.has_prefix(h, "127.") }

// Whether a server's files are this computer's: "http://127.0.0.1:4096", "https://[::1]:4096".
url_is_here :: proc(url: string) -> bool {
	_, _, rest := strings.partition(url, "://")
	if strings.has_prefix(rest, "[") {
		end := strings.index_byte(rest, ']')
		return end > 0 && host_is_here(rest[:end + 1])
	}
	cut := strings.index_any(rest, ":/")
	return host_is_here(cut < 0 ? rest : rest[:cut])
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
	Todo_Scan,      // GET /api/session/:id/message?cursor= (an older page, read for its last todo list alone: activity.odin)
	Agents,
	Models,
	Info,
	Permissions,    // GET /api/session/:id/permission
	Permission_Reply, // POST /api/session/:id/permission/:id/reply (the tag: the permission)
	Active,         // GET /api/session/active: the sessions running now
	Self,           // GET /api/session/:id: the session shown
	Parent,         // GET /api/session/:parent: the title of the session shown's parent
	Children,       // GET /api/session?parentID=: the sub-agents of the session shown
	// the settings' pages (settings.odin server_facts_answer)
	Cfg, Shells, Mcp, Saved, Usage, Providers, Skills, Commands,
	Shell_Set,      // PATCH /api/experimental/config (the tag: the shell it replaces)
	Mcp_Done,       // POST /api/experimental/mcp/:name/connect, /disconnect (the tag: its name)
	Saved_Done,     // DELETE /api/permission/saved/:id
	Projects,       // GET /api/project: the projects and their logos
	Stats,          // GET /api/experimental/session/stats: the project's totals (stats.odin)
	Created,        // POST /api/session: the new session
	Action,         // a POST whose answer only matters when it fails
	Prompt,         // POST /api/session/:id/prompt, /command: an Outgoing (outgoing.odin), what failed comes back to the composer
	// what runs behind the conversation (activity.odin); a server without them says nothing about it
	Shell_List,     // GET /api/shell: the commands running in a folder
	Shell_One,      // GET /api/shell/:id: how one ended
	Job_List,       // GET /api/experimental/job: which of the session's commands run in the background
	Background,     // GET /api/experimental/job: every session's commands running in the background (the sidebar's lamps)
	Shell_Output,   // GET /api/shell/:id/output: what it printed since
	Peek,           // GET /api/session/:child/message: the end of a sub-agent's work
	Goal,           // POST /api/rpc/opencode.goal/get: the session's goal (goal.odin)
	Pair,           // POST /api/pair: a code that pairs a device (pair.odin)
	Slash,          // GET /api/command: the server's commands (the palette, "/name" in the composer)
	Forked,         // POST /api/session/:id/fork: the new session
	Session_Agent,  // a new session takes the agent chosen last (outgoing.odin outgoing_setup)
	Session_Model,  // ... and the model
	Session_Choice, // POST /api/session/:id/agent, /model: what the reader picked
	Session_Moved,  // POST /api/session/:id/move
	Session_Export, // GET /api/experimental/session/:id/export (session_tools.odin)
	Session_Import, // POST /api/experimental/session/import
	Pty_List,       // GET /api/pty (terminal.odin)
	Pty_Made,       // POST /api/pty
	Pty_Size,       // PUT /api/pty/:id, one at a time (the tag: the shell)
	Schedules,      // GET /api/experimental/schedule (schedules.odin)
	Schedule_Made,  // POST
	Schedule_Done,  // DELETE, POST .../pause, /resume
	Artifacts,      // GET /api/experimental/artifacts
	Artifact_Read,  // GET .../:id
	Chat_Artifacts, // GET /api/experimental/artifacts: those of the session shown (tag: its id)
	Artifact_Done,  // DELETE
	Plugins,        // GET /api/plugin
	Plugins_Check,  // POST /api/plugin/check: the same list, looked up again
	Plugin_Update,  // POST /api/plugin/update
	Integrations,   // GET /api/integration (integrations.odin)
	Credentials,    // GET /api/credential: only which are active is read
	Credential_Done, // PATCH, DELETE /api/credential/:id, POST .../activate
	Connected,      // POST .../connect/key, /external, /oauth/:id/complete
	Connect_Begin,  // POST .../connect/oauth, /command
	Connect_Status, // GET .../connect/oauth/:id, /command/:id
	Mention_Files,  // GET /api/fs/list, /api/fs/find: what @ proposes (files.odin)
	Files_List,     // the same for the dialog
	File_Read,      // GET /api/fs/read/*
	Changes_Range,  // GET /api/session/:id/message?type=user: the first prompt, then the last
	Changes,        // GET /api/session/:id/diff: the files
	Revert_Staged,  // POST /api/session/:id/revert/stage: the files, written back by then
	Revert_Done,    // POST /api/session/:id/revert/commit
	Revert_Cancelled, // DELETE /api/session/:id/revert
	Forms,          // GET /api/session/:id/form: what it asks and waits for (forms.odin)
	Form_Reply,     // POST /api/session/:id/form/:form/reply (the tag: the form)
	Form_Dismiss,   // DELETE /api/session/:id/form/:form (the tag: the form)
	Inbox,          // GET /api/session/:id/inbox: what was sent during a run that was interrupted
	Inbox_Take,     // DELETE /api/session/:id/inbox/:message: out of it, to go as a prompt (the body: that prompt)
	Queue_List,     // GET /api/session/:id/inbox: what waits, for the list over the composer (queue.odin)
	Queue_Steer,    // PATCH .../inbox/:message: a queued one goes now (the tag: the item)
	Queue_Cancel,   // DELETE .../inbox/:message: it does not go (the tag: the item)
	Queue_Replace,  // DELETE .../inbox/:message: it gives way to its edited text, an Outgoing (the tag: the item)
	Queue_Check,    // GET .../message/:message: it answers 204 for what was delivered too; only a stored message says so
	Output_Read,    // GET /api/shell/:id/output: for a view of a command (output_view.odin; the tag: the command)
	Output_State,   // GET /api/shell/:id: ... how it stands
	Context,        // GET /api/session/:id/context: what the model has in front of it (stats.odin)
	Session_Viewed, // POST /api/session/:id/view: the end of its last run was seen (sidebar.odin)
}

Request :: struct {
	kind:   Req_Kind,
	method: string,
	path:   string,
	body:   string,
	tag:    string,    // what it is about: a session, or what Req_Kind says
	gen:    u64,       // the chat generation it was made for (answers for a chat since left are dropped)
	conn:   ^Conn,     // the connection it goes by (answers from a server since left are dropped)
	app:    ^App,      // (for its thread: the_app is the interface's)
	remote: ^Remote,   // the reading it is (nil: none), and which one: answer settles it
	ticket: u64,
	out:    u64,       // the prompt on its way it carries (outgoing.odin, 0: none)
	asked_at: Seq,     // App_Context.stream_seq when it left: what the stream said after that is newer than its answer
	// the answer
	status: int,
	resp:   string,
	ok:     bool,
	delay:  int,      // ms to sleep first, in its thread
	// ... read on its thread: nothing here waits for it on the interface's (nil: read there, by answer)
	read_in:    ^virtual.Arena,
	value:      json.Value,
	unreadable: bool,
}

// (`conn`: a server left, for what must be undone there: answer_left.)
// A request on its way. Its answer ends it, whatever that answer is and whoever reads it: no flag to lower on each way out.
Flight :: struct { kind: Req_Kind, tag: string, conn: ^Conn }   // (tag owned)

// Whether that is on its way to the server of now.
flying :: proc(app: ^App, kind: Req_Kind, tag: string) -> bool {
	for f in app.cx.flights { if f.kind == kind && f.conn == app.conn && f.tag == tag { return true } }
	return false
}

@(private = "file")
flight_ends :: proc(app: ^App, r: ^Request) {
	for f, i in app.cx.flights {
		if f.kind == r.kind && f.conn == r.conn && f.tag == r.tag {
			delete(f.tag)
			ordered_remove(&app.cx.flights, i)
			return
		}
	}
}

request :: proc(app: ^App, kind: Req_Kind, method, path: string, body := "", tag := "", delay := 0, remote: ^Remote = nil, out: u64 = 0, conn: ^Conn = nil) {
	to := conn != nil ? conn : app.conn
	if to == nil {   // (no server yet: nothing to ask)
		if remote != nil { remote_settle(remote, .Failed, "Not connected") }
		return
	}
	r := new(Request)
	r^ = {kind = kind, method = strings.clone(method), path = strings.clone(path), body = strings.clone(body), tag = strings.clone(tag), gen = app.chat.gen, conn = to, app = app, delay = delay, remote = remote, out = out, asked_at = app.cx.stream_seq}
	if remote != nil { r.ticket = remote.ticket }
	sync.atomic_add(&app.pending, 1)
	append(&app.cx.flights, Flight{kind, strings.clone(tag), to})
	when ODIN_TEST {   // (answers_test.odin: kept for the test to answer, in the order it wants)
		bench_sent_add(r)
		return
	}
	thread.create_and_start_with_poly_data(r, proc(r: ^Request) {
		if r.delay > 0 { time.sleep(time.Duration(r.delay) * time.Millisecond) }
		r.status, r.resp, r.ok = http_request(&r.conn.http, r.method, r.path, r.body)
		req_read(r)
		if !ui.post(&r.app.state, on_answer, r) { request_free(r) }
	}, self_cleanup = true)
}

// A GET in a while: what is being waited for costs a sleeping thread, no frame.
request_later :: proc(app: ^App, kind: Req_Kind, path: string, ms: int, tag: string, remote: ^Remote = nil) {
	request(app, kind, "GET", path, tag = tag, delay = ms, remote = remote)
}

// Whether what it says is read at all. (A prompt's answer says more when it can: queue_prompt_answered.)
@(private = "file")
req_is_read :: proc(r: ^Request) -> bool { return REQ_FACTS[r.kind].json || r.kind == .Prompt }

// On the request's thread: the answer does not stand before a click in the interface's. What it holds lives as what a handler reads from the
// frame's allocator does: answers_spent_free.
@(private = "file")
req_read :: proc(r: ^Request) {
	if !r.ok || r.status >= 400 || !req_is_read(r) { return }
	r.read_in = new(virtual.Arena)
	_ = virtual.arena_init_growing(r.read_in)
	v, err := json.parse_string(r.resp, parse_integers = true, allocator = virtual.arena_allocator(r.read_in))
	r.value, r.unreadable = v, err != nil
}

// After a frame: what the answers of that frame held.
answers_spent_free :: proc(app: ^App) {
	for a in app.cx.answers_spent {
		virtual.arena_destroy(a)
		free(a)
	}
	clear(&app.cx.answers_spent)
}

request_free :: proc(r: ^Request) {
	if r.read_in != nil {
		virtual.arena_destroy(r.read_in)
		free(r.read_in)
	}
	delete(r.method); delete(r.path); delete(r.body); delete(r.tag); delete(r.resp)
	free(r)
}

ERROR_EXCERPT_BYTES :: 80   // of an error's body, in its toast

// On the interface's thread.
on_answer :: proc(data: rawptr, word: u64) { answer(the_app, (^Request)(data)) }

// How long a request's answer means anything, past the server it went to (Request.conn).
Req_Life :: enum u8 {
	Server,     // whatever is shown: what acts on what comes
	Chat,       // the conversation and the session it was asked for
	Chat_Gen,   // the conversation it was asked in (its tag is a folder or a command)
}

// What is known of a kind of request, in one place. `json`: an answer that cannot be read is a failure; of the others, only that they went
// through matters, or the answer is not JSON at all. (Every kind is here: a new one does not compile until it says.)
Req_Facts :: struct { json: bool, life: Req_Life }

@(rodata) REQ_FACTS := [Req_Kind]Req_Facts{
	.Sessions         = {json = true},
	.Messages         = {json = true, life = .Chat},
	.Older            = {json = true, life = .Chat},
	.Todo_Scan        = {json = true, life = .Chat},
	.Agents           = {json = true},
	.Models           = {json = true},
	.Info             = {json = true},
	.Permissions      = {json = true},
	.Permission_Reply = {},
	.Active           = {json = true},
	.Self             = {json = true, life = .Chat},
	.Parent           = {json = true, life = .Chat},
	.Children         = {json = true, life = .Chat},
	.Cfg              = {json = true},
	.Shells           = {json = true},
	.Mcp              = {json = true},
	.Saved            = {json = true},
	.Usage            = {json = true},
	.Providers        = {json = true},
	.Skills           = {json = true},
	.Commands         = {json = true},
	.Shell_Set        = {},
	.Mcp_Done         = {},
	.Saved_Done       = {},
	.Projects         = {json = true},
	.Stats            = {json = true},
	.Created          = {json = true},
	.Action           = {},
	.Prompt           = {},
	.Shell_List       = {json = true, life = .Chat_Gen},
	.Job_List         = {json = true, life = .Chat_Gen},
	.Background       = {json = true},
	.Shell_One        = {json = true, life = .Chat_Gen},
	.Shell_Output     = {json = true, life = .Chat_Gen},
	.Peek             = {json = true, life = .Chat_Gen},
	.Slash            = {json = true},
	.Goal             = {json = true, life = .Chat_Gen},
	.Pair             = {json = true},   // (the server's, whatever is shown)
	.Forked           = {json = true},
	.Session_Agent    = {},
	.Session_Model    = {},
	.Session_Choice   = {},
	.Session_Moved    = {},
	.Session_Export   = {json = true},
	.Session_Import   = {json = true},
	.Pty_List         = {json = true},
	.Pty_Made         = {json = true},
	.Pty_Size         = {},
	.Schedules        = {json = true},
	.Schedule_Made    = {json = true},
	.Schedule_Done    = {},
	.Artifacts        = {json = true},
	.Artifact_Read    = {json = true},
	.Chat_Artifacts   = {json = true},
	.Artifact_Done    = {},
	.Plugins          = {json = true},
	.Plugins_Check    = {json = true},
	.Plugin_Update    = {},
	.Integrations     = {json = true},
	.Credentials      = {json = true},
	.Credential_Done  = {},
	.Connected        = {},
	.Connect_Begin    = {json = true},
	.Connect_Status   = {json = true},
	.Mention_Files    = {json = true},
	.Files_List       = {json = true},
	.File_Read        = {},
	.Changes_Range    = {json = true},
	.Changes          = {json = true},
	.Revert_Staged    = {json = true},
	.Revert_Done      = {},
	.Revert_Cancelled = {},
	.Forms            = {json = true},
	.Form_Reply       = {},
	.Form_Dismiss     = {},
	.Inbox            = {json = true},
	.Inbox_Take       = {},
	.Queue_List       = {json = true},
	.Queue_Steer      = {},
	.Queue_Cancel     = {},
	.Queue_Replace    = {},
	.Queue_Check      = {},
	.Output_Read      = {json = true},
	.Output_State     = {json = true},
	.Context          = {json = true, life = .Chat},
	.Session_Viewed   = {},
}

// The conversation it was asked for is gone: what it says is about nothing shown, success or failure.
@(private = "file")
req_outlived :: proc(app: ^App, r: ^Request) -> bool {
	switch REQ_FACTS[r.kind].life {
	case .Server:   return false
	case .Chat:     return r.gen != app.chat.gen || r.tag != app.chat.id
	case .Chat_Gen: return r.gen != app.chat.gen
	}
	return false
}

// What the server said when it refused (its `message`, else the start of the body).
@(private = "file")
refusal_text :: proc(r: ^Request) -> string {
	v, _ := json.parse_string(r.resp, parse_integers = true, allocator = context.temp_allocator)
	if msg := jstr(v, "message"); msg != "" { return msg }
	if r.resp != "" { return r.resp[:min(len(r.resp), ERROR_EXCERPT_BYTES)] }
	return fmt.tprintf("status %d", r.status)
}

// What was begun on a server and nobody waits for any more: nothing here will end it, so it is undone there, on the server it went
// to. (A stage has written the files back; a login or a command goes on running.)
@(private = "file")
answer_left :: proc(app: ^App, r: ^Request) {
	if !r.ok || r.status >= 400 { return }
	#partial switch r.kind {
	case .Revert_Staged:
		request(app, .Action, "DELETE", fmt.tprintf("/api/session/%s/revert", r.tag), tag = r.tag, conn = r.conn)
	case .Connect_Begin:
		v, _ := json.parse_string(r.resp, parse_integers = true, allocator = context.temp_allocator)
		if id := jstr(v, "data", "attemptID"); id != "" { request(app, .Action, "DELETE", fmt.tprintf("%s/%s", r.path, url_escape(id)), conn = r.conn) }
	case .Pty_Made:
		v, _ := json.parse_string(r.resp, parse_integers = true, allocator = context.temp_allocator)
		term_made_left(app, r, v)
	}
}

// Everything an answer can be, in one place. A Remote is settled here, before any handler.
answer :: proc(app: ^App, r: ^Request) {
	defer {
		if r.read_in != nil { append(&app.cx.answers_spent, r.read_in) }
		r.read_in = nil
		request_free(r)
	}
	sync.atomic_sub(&app.pending, 1)
	flight_ends(app, r)
	if r.conn != app.conn {
		// a server left: server_forget cleaned up what depends on it. A reading it forgot does not stay Loading, and a
		// prompt on its way still has to say whether it got there.
		if x := r.remote; x != nil && x.ticket == r.ticket { remote_reset(x) }
		if r.kind == .Prompt { outgoing_answered(app, r, r.ok && r.status < 400) }
		if r.kind == .Queue_Replace || r.kind == .Queue_Check { outgoing_answered(app, r, false) }   // (taken out or not, that server is left: what was written comes back)
		answer_left(app, r)
		return
	}
	if (r.remote != nil && r.remote.ticket != r.ticket) || req_outlived(app, r) {   // a reading given up, a conversation left
		answer_left(app, r)
		return
	}
	if !r.ok {
		// (this request failed: whether the connection is down is for the event stream to say, stream_up)
		fmt.eprintfln("request failed: %s %s: %s", r.method, r.path, r.resp)
		answer_failed(app, r, .Transport, "Server unreachable")
		return
	}
	if r.status == 401 { answer_failed(app, r, .Auth, "Authentication refused by the server"); return }
	if r.status >= 400 { answer_failed(app, r, .Refused, refusal_text(r)); return }
	v := r.value
	unreadable := r.unreadable
	if r.read_in == nil && req_is_read(r) {   // (a test's answer: no thread read it)
		err: json.Error
		v, err = json.parse_string(r.resp, parse_integers = true, allocator = context.temp_allocator)
		unreadable = err != nil
	}
	if unreadable && REQ_FACTS[r.kind].json { answer_failed(app, r, .Unreadable, "Unreadable answer"); return }
	if r.remote != nil { remote_settle(r.remote, .Ready, "") }
	switch r.kind {
	case .Sessions:    sessions_load(app, v)
	case .Messages:
		first := !app.chat.loaded
		chat_load(app, v, false, r.asked_at)
		if first && app.stick_bottom { app.snap_bottom = true }   // (shown at its bottom in the very frame it arrives: frame)
		nav_restore_check(app)
	case .Todo_Scan:
		todos_scan_load(app, r, v)
	case .Older:
		chat_load(app, v, true)
		nav_restore_page(app)
		nav_restore_check(app)
	case .Agents:      agents_load(app, v)
	case .Models:      models_load(app, v)
	case .Info:
		delete(app.server_version); app.server_version = strings.clone(jstr(v, "version"))
		server_urls_clear(app)
		for u in jarr(v, "urls") { if s, ok := u.(json.String); ok && s != "" { append(&app.server_urls, strings.clone(string(s))) } }
	case .Pair:        pair_load(app, jstr(v, "code"), jnum(v, "expires_in"))
	case .Permissions: permissions_replace(app, r.tag, jarr(v, "data"), r.asked_at)
	case .Permission_Reply:
		waits_gone(app, r.tag)
		permission_remove(app, r.tag)
	case .Active:      active_load(app, v, r.asked_at)
	case .Self:        self_load(app, v, r.asked_at)
	case .Parent:      parent_load(app, v)
	case .Children:    children_load(app, v)
	case .Cfg, .Shells, .Mcp, .Saved, .Usage, .Providers, .Skills, .Commands: server_facts_answer(app, r.kind, v)
	case .Shell_Set:
		ui.toast(.Good, "Shell set")
		facts_soon(app)   // (a reading that crossed it said the one before)
	case .Mcp_Done:    mcp_done(app, r.tag)
	case .Saved_Done:  saved_revoke_done(app, r.tag)
	case .Projects:    projects_load(app, v)
	case .Stats:       stats_load(app, v)
	case .Created:
		if id := jstr(v, "data", "id"); id != "" {
			outgoing_created(app, r, id)
		} else {
			answer_failed(app, r, .Unreadable, "Unreadable answer")
		}
	case .Action:
	case .Prompt:
		// (the stream may say a prompt without its files: what was attached shows as soon as it is stored)
		if strings.contains(r.body, `"files":`) && r.gen == app.chat.gen && r.tag == app.chat.id { load_messages(app, r.tag) }
		queue_prompt_answered(app, r.tag, v)
		outgoing_answered(app, r, true)
	case .Session_Agent: outgoing_setup(app, r.out, .Model)
	case .Session_Model: outgoing_setup(app, r.out, .Sending)
	case .Session_Choice:
	case .Session_Moved: ui.toast(.Good, "Session moved"); refresh_soon(app)
	case .Session_Export: session_export_save(app, r.tag, r.resp)
	case .Session_Import:
		refresh_soon(app)
		// (the reader who went elsewhere meanwhile stays there: it is in the sidebar)
		if id := jstr(v, "data", "id"); id != "" && r.gen == app.chat.gen { open_root(app, id) }
		ui.toast(.Good, "Session imported")
	case .Pty_List:      terminals_load(app, r.tag, v)
	case .Pty_Made:      term_made(app, r.tag, v)
	case .Pty_Size:      term_size_answered(app, r.tag)
	case .Schedules:     schedules_load(app, v)
	case .Schedule_Made: schedule_made(app)
	case .Schedule_Done: schedule_changed(app)
	case .Artifacts:     artifacts_load(app, v)
	case .Chat_Artifacts: chat_artifacts_load(app, r.tag, v)
	case .Artifact_Read: artifact_loaded(app, v)
	case .Artifact_Done: artifacts_changed(app)
	case .Plugins:       plugins_load(app, v)
	case .Plugins_Check: plugins_checked(app, v)
	case .Plugin_Update: plugins_changed(app)
	case .Integrations:  integrations_load(app, v)
	case .Credentials:   credentials_load(app, v)
	case .Credential_Done: integrations_changed(app)
	case .Connected:     connect_done(app)
	case .Connect_Begin: connect_begun(app, v)
	case .Connect_Status: connect_status(app, v)
	case .Mention_Files: mention_load(app, v)
	case .Files_List:    files_load(app, v)
	case .File_Read:     file_loaded(app, r.resp)
	case .Changes_Range: changes_range(app, v)
	case .Changes:       changes_load(app, v)
	case .Revert_Staged: revert_staged(app, v)
	case .Revert_Done:   revert_done(app)
	case .Revert_Cancelled: revert_cancelled(app)
	case .Forms:         forms_replace(app, r.tag, jarr(v, "data"), r.asked_at)
	case .Form_Reply, .Form_Dismiss:
		waits_gone(app, r.tag)
		form_remove(app, r.tag)
	case .Inbox:         inbox_take(app, r.tag, v)
	case .Inbox_Take:    inbox_send(app, r)
	case .Queue_List:    queue_load(app, r.tag, v, r.asked_at)
	case .Queue_Steer, .Queue_Cancel: queue_answered(app, r)
	case .Queue_Replace: queue_replaced(app, r)
	case .Queue_Check:   outgoing_replaced(app, r.out, false)   // (stored: it was delivered)
	case .Output_Read:   output_view_output_load(app, v, r.tag)
	case .Output_State:  output_view_state_load(app, v, r.tag)
	case .Context:       context_load(app, r.tag, v)
	case .Shell_List:   activity_shells_load(app, v, r.tag)
	case .Job_List:     activity_jobs_load(app, v, r.tag)
	case .Background:   background_load(app, v)
	case .Shell_One:    activity_shell_load(app, v, r.tag)
	case .Shell_Output: activity_output_load(app, v, r.tag)
	case .Peek:         activity_peek_load(app, v, r.tag)
	case .Goal:         goal_set(app, r.tag, jget(v, "output"))
	case .Slash:
		list := make([dynamic]Slash, context.temp_allocator)
		for it in jarr(v, "data") { append(&list, Slash{strings.clone(jstr(it, "name")), strings.clone(jstr(it, "description"))}) }
		slash_load(app, list[:])
		outgoing_catalog(app)
	case .Session_Viewed:   // (session.viewed says it, to every client)
	case .Forked:
		if id := jstr(v, "data", "id"); id != "" {
			refresh_sessions(app)
			if r.gen == app.chat.gen {
				open_root(app, id)
				prompt_restore(app, app.cx.fork_prompt)
				if app.cx.fork_prompt != "" { app.cx.focus_composer = true }
			}
			ui.toast(.Good, "Forked")
		}
	}
}

// How a request failed.
Failure :: enum u8 {
	Transport,    // the server was not reached
	Auth,         // 401
	Refused,      // another status from 400 on: `message` is the server's
	Unreadable,   // a success that says nothing that can be read
}

// Every failure comes here: its Remote, what it leaves undone, what the reader is told.
answer_failed :: proc(app: ^App, r: ^Request, f: Failure, message: string) {
	if r.remote != nil { remote_settle(r.remote, f == .Refused ? .Refused : .Failed, message) }
	if f == .Auth { conn_auth_refused(app) }
	if request_failed(app, r, f, message) { return }
	switch f {
	case .Transport:  ui.toast(.Bad, "Server unreachable (%s)", r.path)
	case .Auth:       ui.toast(.Bad, "Authentication refused by the server")
	case .Refused:    ui.toast(.Bad, "%s %s: %d %s", r.method, r.path, r.status, message)
	case .Unreadable: ui.toast(.Warn, "Unreadable answer (%s)", r.path)
	}
}

// What a request that failed leaves undone, whatever the way it failed. Every kind is here: a new one does not compile until it
// says. `told`: the failure is shown where it belongs, or is not one (a server without that page): no toast.
@(private = "file")
request_failed :: proc(app: ^App, r: ^Request, f: Failure, message: string) -> (told: bool) {
	refused := f == .Refused
	switch r.kind {
	case .Session_Agent: outgoing_setup(app, r.out, .Model)     // (the prompt goes all the same, with what the session has)
	case .Session_Model: outgoing_setup(app, r.out, .Sending)
	case .Session_Choice:
		// (the session did not take it: what is shown goes back to what it uses)
		if r.gen == app.chat.gen && r.tag == app.chat.id {
			if strings.has_suffix(r.path, "/agent") { app.chat.chose_agent = "" } else { app.chat.chose_model, app.chat.chose_provider, app.chat.chose_variant = "", "", "" }
		}
	case .Created, .Prompt:
		outgoing_answered(app, r, false)
	case .Messages:
		app.chat.loading = false
		nav_restore_clear(app)   // (what it would go back to will not come)
	case .Older:
		older_failed(app, r)
	case .Todo_Scan:
		if r.tag == app.activity.scan.session {
			app.activity.scan.busy, app.activity.scan.over = false, true   // (not again: the list stays as the pages read say)
			app.activity.todos_sig = 0
		}
	case .Form_Reply, .Form_Dismiss:
		if fr := form_find(app, r.tag); fr != nil { fr.sending = false }
	case .Permission_Reply:
		for &p in app.permissions { if p.id == r.tag { p.replying = false } }
	case .Plugin_Update:
		plugins_changed(app)
	case .Connected, .Connect_Begin:
		connect_failed(app, message)
		return true
	case .Connect_Status:
		connect_poll_failed(app)
		return true
	case .Changes:
		if r.status == 400 { changes_refused(app) }
		return true
	case .Revert_Staged, .Revert_Done, .Revert_Cancelled:
		revert_failed(app, r.tag)
	case .Shell_Set:
		shell_failed(app, r.tag)
	case .Mcp_Done:
		mcp_done(app, r.tag)
	case .Saved_Done:
		saved_revoke_done(app, r.tag)
	case .Pty_List:
		return app.cx.terms.open   // (the panel says it, with its Try again)
	case .Pty_Made:
		return term_made_failed(app)
	case .Pty_Size:
		term_size_answered(app, r.tag)   // (the grid has its size; a server that refuses it says nothing worth a toast at each step of a drag)
		return true
	case .Pair:
		pair_failed(app, message)
		return true   // (the dialog says it, with its Try again)
	case .Goal, .Background:
		return true   // (a server without the goal plugin: no line over the composer, nothing to say)
	case .Shell_List, .Shell_One, .Shell_Output, .Peek, .Job_List:
		// (what runs behind the conversation: a server without it says nothing about it)
		activity_request_failed(app, r)
		return true
	case .Inbox:
		return refused   // (a server without one: nothing to say)
	case .Queue_List:
		return true      // (the list says it, with its Try again; a server without one says nothing)
	case .Queue_Steer, .Queue_Cancel:
		return queue_failed(app, r)
	case .Queue_Replace:
		queue_replace_failed(app, r)
		return true      // (Outgoing says it)
	case .Output_Read, .Output_State:
		output_view_failed(app, r)
		return true      // (the view says it)
	case .Queue_Check:
		// (404: not stored, so it really left the inbox. Anything else says nothing: what was written comes back rather than go twice.)
		if r.status == 404 { outgoing_replaced(app, r.out, true) } else { outgoing_answered(app, r, false) }
		return true
	case .Mention_Files:
		mention_failed(app)   // (what was proposed is not what is typed any more)
		return refused        // (a server without one, a folder gone: nothing to say)
	// (a dialog's reading: read_shown says it where it would have been, in the server's words: "set experimental.schedules in config")
	case .Chat_Artifacts:
		return true   // (no cards: a server without artifacts says nothing worth a toast)
	case .Schedules, .Artifacts, .Artifact_Read, .Plugins, .Integrations, .Credentials, .Files_List, .File_Read, .Stats, .Context, .Changes_Range,
	     .Cfg, .Shells, .Mcp, .Saved, .Usage, .Providers, .Skills, .Commands:
		return true
	case .Slash:
		outgoing_catalog(app)   // (what waited for the commands goes as a prompt: nothing is lost)
		return false
	case .Schedule_Made:
		return app.cx.schedules.open   // ("Invalid duration": under the form, with what was typed)
	case .Session_Viewed:
		return true   // (nothing to say: the next list shows it as it stands)
	case .Session_Import:
		if r.status == 409 { session_import_conflict(app, r.tag); return true }
	// nothing waits on them here: the toast says it, what they would have changed stays
	case .Sessions, .Agents, .Models, .Info, .Permissions, .Active, .Self, .Parent, .Children, .Projects,
	     .Action, .Forked, .Session_Moved, .Session_Export,
	     .Schedule_Done, .Artifact_Done, .Credential_Done, .Plugins_Check, .Forms, .Inbox_Take:
	}
	return false
}

// The page before the first message was not read: said where it would have been.
older_failed :: proc(app: ^App, r: ^Request) {
	if r.gen != app.chat.gen || r.tag != app.chat.id { return }
	app.chat.loading_older = false
	app.chat.older_failed = ui.now_ms()
	nav_restore_clear(app)   // (the place it would go back to is on that page: the view is the reader's again)
}

SESSIONS_LIMIT :: "200"   // most sessions read at a time (text of the query)

refresh_sessions :: proc(app: ^App) {
	request(app, .Sessions, "GET", "/api/session?limit=" + SESSIONS_LIMIT + "&order=desc")
	request(app, .Active, "GET", "/api/session/active")
	background_read(app)
}

// A new reading replaces the one on its way: what it brings is the newer one.
load_messages :: proc(app: ^App, id: string) {
	if !app.chat.loaded { app.chat.loading = true }
	remote_begin(&app.cx.chat_read)
	request(app, .Messages, "GET", fmt.tprintf("/api/session/%s/message?limit=%d&order=desc", id, app.prefs.page_size), tag = id, remote = &app.cx.chat_read)
}

// Everything the session shown needs from the server: when it opens, on Try again, when the stream comes back.
chat_read :: proc(app: ^App) {
	c := &app.chat
	if c.id == "" { return }
	id := strings.clone(c.id, context.temp_allocator)
	load_messages(app, id)
	if !c.have_self { request(app, .Self, "GET", strings.concatenate({"/api/session/", id}, context.temp_allocator), tag = id) }
	load_children(app)
	session_waits_load(app, id)
	queue_read(app)
	chat_artifacts_ask(app)
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


// A run that is interrupted leaves what was steered into it in the session's inbox, where only the next prompt would pick it up,
// glued to that prompt: it looks lost. The newest goes as a prompt now, which starts a run: the server puts what is left in the
// inbox before a prompt, so they keep their order. (It has no way to wake an inbox: out of it, then sent.) If the prompt fails its text comes back to the composer; if the
// taking fails it stays in the inbox. Nothing is lost. What was queued is left where it is: the reader stopped the run, and queued it
// for after that run, not for a new one started without a word. It stays parked in the list (queue.odin), Steer at hand.
inbox_resume :: proc(app: ^App, id: string) {
	request(app, .Inbox, "GET", fmt.tprintf("/api/session/%s/inbox", id), tag = id)
}

@(private = "file")
inbox_take :: proc(app: ^App, id: string, v: json.Value) {
	newest: json.Value
	last: f64
	for item in jarr(v, "data") {
		if jstr(item, "type") != "user" || delivery_of(jstr(item, "delivery")) == .Queue { continue }
		if t := jnum(item, "time", "created"); t >= last { last, newest = t, item }
	}
	if newest == nil { return }
	request(app, .Inbox_Take, "DELETE", fmt.tprintf("/api/session/%s/inbox/%s", id, jstr(newest, "id")), prompt_of_payload(jget(newest, "payload")), id)
}

@(private = "file")
inbox_send :: proc(app: ^App, r: ^Request) {
	// (what shows of it goes: the prompt comes back under its own id)
	if r.tag == app.chat.id {
		taken := r.path[strings.last_index_byte(r.path, '/') + 1:]
		if queue_shown_as_sent(app, taken) { chat_drop(&app.chat, taken) }
		queue_gone(app, taken, false, app.cx.stream_seq)
	}
	outgoing_inbox(app, r.tag, r.body)
}

interrupt_session :: proc(app: ^App, id: string) {
	request(app, .Action, "POST", fmt.tprintf("/api/session/%s/interrupt", id), "", id)
}

// One answer to it: the second click of a double click finds it on its way.
reply_permission :: proc(app: ^App, p: ^Permission, decision: string) {
	if p.replying { return }
	p.replying = true
	request(app, .Permission_Reply, "POST", fmt.tprintf("/api/session/%s/permission/%s/reply", p.session, p.id), fmt.tprintf(`{{"decision":%s}}`, jquote(decision)), p.id)
}

// permission.allow_all: every permission waiting is allowed once (each is answered once: one on its way is left).
permissions_allow_pending :: proc(app: ^App) {
	for &p in app.permissions { if !p.replying { reply_permission(app, &p, "once") } }
}

switch_model :: proc(app: ^App, session, model, provider, variant: string) {
	request(app, .Session_Choice, "POST", fmt.tprintf("/api/session/%s/model", session), model_body(model, provider, variant), session)
}

switch_agent :: proc(app: ^App, session, agent: string) {
	request(app, .Session_Choice, "POST", fmt.tprintf("/api/session/%s/agent", session), fmt.tprintf(`{{"agent":%s}}`, jquote(agent)), session)
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
	for !sync.atomic_load(&c.stop) {
		st := http_sse(&c.http, "/api/event", &c.stop, proc(data: string, user: rawptr) -> bool {
			c := (^Conn)(user)
			e := new(Event_Msg)
			e^ = {conn = c, text = strings.clone(data)}
			if !ui.post(&c.app.state, on_event, e, EVENT_WORD) { delete(e.text); free(e); return false }
			return true
		}, c, proc(user: rawptr) {
			ui.post(&(^Conn)(user).app.state, proc(data: rawptr, word: u64) { if data == the_app.conn { stream_up(the_app) } }, user)
		})
		if sync.atomic_load(&c.stop) { break }
		ui.post(&c.app.state, proc(data: rawptr, word: u64) { if data == the_app.conn { stream_down(the_app, int(word)) } }, c, u64(st))
		time.sleep(STREAM_RETRY_S * time.Second)
	}
}

// An event's text and the connection it came by (dropped when that is no longer the one connected).
Event_Msg :: struct { conn: ^Conn, text: string }

EVENT_WORD :: u64(0x4556454e54)   // a post's word for an Event_Msg (on_drop frees it)

// Where the link to the server stands, as the event stream says it: stream_up and stream_down write it, server_forget starts it
// again.
Conn_State :: enum u8 {
	Connecting,     // a server just chosen: no word from its stream yet
	Online,
	Retrying,       // it dropped, or does not answer: tried again every STREAM_RETRY_S
	Auth_Refused,   // it says 401: tried again too, a password corrected elsewhere clears it
}

online :: proc(app: ^App) -> bool { return app.link == .Online }

// The stream connected: on a reconnection everything is read again (events were missed meanwhile), by answers that replace.
stream_up :: proc(app: ^App) {
	was := app.link
	app.link = .Online
	if was == .Online { return }
	app.cx.waits_unread = true
	if was == .Retrying {
		terminals_renew(app)
		browser_renew(app)
	}
	refresh_sessions(app)
	chat_read(app)
	for id in waits_sessions(app) { if id != app.chat.id { session_waits_load(app, id) } }
	request(app, .Agents, "GET", "/api/agent")
	request(app, .Models, "GET", "/api/model")
	request(app, .Slash, "GET", "/api/command")
	request(app, .Info, "GET", "/api/info")
	request(app, .Projects, "GET", "/api/project")
	dialogs_reread(app)
	when !ODIN_TEST {   // (threads and files of their own: not what the answers' bench looks at)
		experimental_check(app)
	}
}

// The server answers again, or for the first time: what a dialog has on screen and could not read is tried again, and the pages of the
// settings, whose events were missed, are read again. Nothing that was not open is asked for.
@(private = "file")
dialogs_reread :: proc(app: ^App) {
	cx := &app.cx
	if app.settings_open { server_facts_load(app) }
	integrations_reread(app)
	plugins_changed(app)
	if cx.schedules.open && remote_failed(&cx.schedules.read) { schedules_ask(app) }
	if cx.artifacts.open && remote_failed(&cx.artifacts.read) { artifacts_ask(app) }
	if cx.files.open && remote_failed(&cx.files.read) { files_list(app) }
	if app.stats_open {
		if remote_failed(&cx.stats_read) { stats_ask(app) }
		context_ask(app)   // (what a step added was missed)
	}
	changes_reread(app)
	terminals_reread(app)
}

// The stream ended, or could not start: `status` is what its response said (0: no response; 200: it was up, and it dropped or
// stayed silent past the limit of native/ocn_native).
stream_down :: proc(app: ^App, status: int) {
	app.link = status == 401 ? .Auth_Refused : .Retrying
}

// A request says 401. While the stream is up that is this request's business: only a link that is not up is refused.
conn_auth_refused :: proc(app: ^App) {
	if app.link != .Online { app.link = .Auth_Refused }
}

// A session changed: the list is read again once things are quiet.
refresh_soon :: proc(app: ^App) { deferred_ask(&app.cx.due[.Refresh], REFRESH_DEBOUNCE_MS, REFRESH_DEBOUNCE_MS * DEFERRED_MOST) }

children_soon :: proc(app: ^App) { deferred_ask(&app.cx.due[.Children], CHILDREN_DEBOUNCE_MS, CHILDREN_DEBOUNCE_MS * DEFERRED_MOST) }

facts_soon :: proc(app: ^App) { deferred_ask(&app.cx.due[.Facts], FACTS_DEBOUNCE_MS, FACTS_DEBOUNCE_MS * DEFERRED_MOST) }

on_event :: proc(data: rawptr, word: u64) {
	app := the_app
	e := (^Event_Msg)(data)
	defer { delete(e.text); free(e) }
	if e.conn != app.conn { return }   // a server left
	v, err := json.parse_string(e.text, parse_integers = true, allocator = context.temp_allocator)
	if err != nil { return }
	apply_event(app, v)
}

// What the queue will never run. It blocks when full and is closed only at the end, with no worker joined and no ui.destroy: a Request or a
// shell's output left there then goes with the process, and a post refused after the close is freed by whoever posted it. An event is the
// one message this has to know, for a queue that does get destroyed (a test's).
on_drop :: proc(data: rawptr, word: u64) {
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
