// The link to the opencode server: where it is (service.json), requests on worker threads, the event stream on a
// thread of its own. Every answer reaches the interface through ui.post: it runs on the interface's thread, in
// begin_build, and wakes the window.
package ocn

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:mem"
import "core:mem/virtual"
import "core:sync"
import "core:time"
import "core:unicode/utf8"
import "gt:ascii"
import "gt:ui"
import remote "gt:remote"

Server_Config :: struct {
	host:     string,
	port:     u16,
	password: string,
	tls:      bool,     // https (a remote server, a tunnel)
}

DEFAULT_PORT :: 4096

// This computer's opencode server, unless `url` / `password` (--url=, --password=; "": not given) say otherwise. Where it
// really runs first: the state the
// background service writes while it runs (~/.local/state/opencode/service.json: its url and password, what
// `opencode service status` prints); else what its configuration asks for (~/.config/opencode/service.json: a port
// that may be stale or absent); else the default port.
discover_server :: proc(url := "", password := "") -> Server_Config {
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
	if password != "" { cfg.password = password }
	if url != "" {
		cfg.tls = strings.has_prefix(url, "https://")
		u := strings.trim_prefix(strings.trim_prefix(url, "http://"), "https://")
		u = strings.trim_suffix(u, "/")
		if i := strings.last_index_byte(u, ':'); i >= 0 {
			if p, ok := strconv.parse_int(u[i + 1:]); ok { cfg.port = u16(p) }
			cfg.host = u[:i]
		} else {
			cfg.host = u
			cfg.port = 0   // the default port of the scheme
		}
	}
	// the password of this computer's server goes to that server only
	if url != "" && password == "" && !same_server(local.host, local.port, cfg.host, cfg.port) { cfg.password = "" }
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
	jquote_into(&b, s)
	return strings.to_string(b)
}

// jquote, written to `b`. What needs nothing is copied a run at a time (an attached file's data URL is megabytes of it): the
// next byte to escape, or past ASCII, is found 16 bytes at a time (ascii.index_any_byte). A byte that is no UTF-8 goes as
// U+FFFD, as it always went.
jquote_into :: proc(b: ^strings.Builder, s: string) {
	strings.write_byte(b, '"')
	rest := s
	for len(rest) > 0 {
		k := ascii.index_any_byte(rest, "\"\\", below = 0x20, non_ascii = true)
		if k < 0 { strings.write_string(b, rest); break }
		strings.write_string(b, rest[:k])
		rest = rest[k:]
		if rest[0] >= 0x80 {
			// (runes past ASCII: the run copied whole, but for a byte that is no UTF-8)
			run := 0
			for run < len(rest) && rest[run] >= 0x80 {
				r, w := utf8.decode_rune_in_string(rest[run:])
				if r == utf8.RUNE_ERROR && w == 1 {
					strings.write_string(b, rest[:run])
					strings.write_string(b, "\uFFFD")
					rest, run = rest[run + 1:], 0
					continue
				}
				run += w
			}
			strings.write_string(b, rest[:run])
			rest = rest[run:]
			continue
		}
		switch c := rest[0]; c {
		case '"':  strings.write_string(b, `\"`)
		case '\\': strings.write_string(b, `\\`)
		case '\n': strings.write_string(b, `\n`)
		case '\r': strings.write_string(b, `\r`)
		case '\t': strings.write_string(b, `\t`)
		case:       fmt.sbprintf(b, `\u%04x`, int(c))
		}
		rest = rest[1:]
	}
	strings.write_byte(b, '"')
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
	Project_Icon,   // PATCH /api/project/:id {icon.override} (project_icon.odin; the tag: the project)
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
	reading: ^remote.Remote,   // the reading it is (nil: none), and which one: answer settles it
	ticket: u64,
	out:    u64,       // the prompt on its way it carries (outgoing.odin, 0: none)
	prompt: Maybe(Prompt_Parts),   // what its body is made of, built on its thread (outgoing_send: megabytes to quote; nil: `body`)
	asked_at: Seq,     // App_Context.stream_seq when it left: what the stream said after that is newer than its answer
	life:   Req_Life,  // (REQ_FACTS: read here, for its worker)
	chat_mark: u64,    // App.chat_mark when it left: its worker sees that the conversation changed since
	// the answer
	status: int,
	resp:   string,
	ok:     bool,
	dropped: bool,     // its worker found it no longer wanted: not sent, or its answer not read (req_unwanted)
	delay:  int,       // ms it waited in its connection's timed queue before it went
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

// A request goes to its connection's workers (`delay` ms from now: it waits in their timed queue, no thread sleeps for it). It holds the
// connection until its answer ran. The workers give no order: what must follow another is asked when the other's answer comes
// (outgoing.odin, a shell's size).
request :: proc(app: ^App, kind: Req_Kind, method, path: string, body := "", tag := "", delay := 0, reading: ^remote.Remote = nil, out: u64 = 0, conn: ^Conn = nil, prompt: Maybe(Prompt_Parts) = nil) {
	to := conn != nil ? conn : app.conn
	if to == nil {   // (no server yet: nothing to ask)
		if reading != nil { remote.settle(reading, .Failed, "Not connected") }
		return
	}
	r := new(Request)
	r^ = {kind = kind, method = strings.clone(method), path = strings.clone(path), body = strings.clone(body), tag = strings.clone(tag), gen = app.chat.gen, conn = to, app = app, delay = delay, reading = reading, out = out, asked_at = app.cx.stream_seq, prompt = prompt}
	r.life, r.chat_mark = REQ_FACTS[kind].life, sync.atomic_load(&app.chat_mark)
	if reading != nil { r.ticket = reading.ticket }
	sync.atomic_add(&app.pending, 1)
	append(&app.cx.flights, Flight{kind, strings.clone(tag), to})
	conn_hold(to)
	pool_add(&to.pool, request_run, r, delay)
}

// On a worker: what is no longer wanted is not sent; the rest goes by the connection's transport.
@(private = "file")
request_run :: proc(data: rawptr) {
	r := (^Request)(data)
	if req_unwanted(r) {
		r.dropped = true
		if !ui.post(&r.app.state, on_answer, r) { request_free(r) }
		return
	}
	request_body(r)
	if r.conn.transport.call(r.conn, r) { request_finish(r) }
}

// Its answer came (on a worker, or where the transport ended it): read unless no longer wanted, then handed to the interface.
request_finish :: proc(r: ^Request) {
	if req_unwanted(r) { r.dropped = true } else { req_read(r) }
	if !ui.post(&r.app.state, on_answer, r) { request_free(r) }
}

// Seen from a worker: the conversation it was asked for was left (what req_outlived says on the interface, from what a worker can read:
// the chat changed since, by App.chat_mark).
req_unwanted :: proc(r: ^Request) -> bool {
	return r.life != .Server && sync.atomic_load(&r.app.chat_mark) != r.chat_mark
}

// A prompt's body, on the request's worker. Its parts are no longer read after it: the answer may free them.
@(private = "file")
request_body :: proc(r: ^Request) {
	p, ok := r.prompt.?
	if !ok { return }
	delete(r.body)
	r.body = prompt_body(p)
	r.prompt = nil
}

// A GET in a while: what is being waited for costs neither a frame nor a sleeping thread.
request_later :: proc(app: ^App, kind: Req_Kind, path: string, ms: int, tag: string, reading: ^remote.Remote = nil) {
	request(app, kind, "GET", path, tag = tag, delay = ms, reading = reading)
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
	// (on an error the parser frees what it made with context.allocator, not with `allocator`: the arena's must be both)
	context.allocator = virtual.arena_allocator(r.read_in)
	v, err := json.parse_string(r.resp, parse_integers = true, allocator = context.allocator)
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
on_answer :: proc(data: rawptr, word: u64) {
	r := (^Request)(data)
	answer(r.app, r)
}

// How long a request's answer means anything, past the server it went to (Request.conn).
Req_Life :: enum u8 {
	Server,     // whatever is shown: what acts on what comes
	Chat,       // the conversation and the session it was asked for
	Chat_Gen,   // the conversation it was asked in (its tag is a folder or a command)
}

// What is known of a kind of request, in one place. `json`: an answer that cannot be read is a failure; of the others, only that they went
// through matters, or the answer is not JSON at all. What its answer does lives with the feature that asked for it (the procedure named
// in its entry): this table only says who. (Every kind is here: a new one does not compile until it says.)
// - on_ok: what a good answer does (nil: nothing, only that it went through mattered).
// - on_fail: what a failure leaves undone, whatever the way it failed. `told`: the failure is shown where it belongs, or is not one
//   (a server without that page): no toast. (nil: nothing undone, the toast says it.)
// - on_left: what was begun on a server and nobody waits for any more, a server left or a conversation left (answer_left).
Req_On_Ok   :: #type proc(app: ^App, r: ^Request, v: json.Value)
Req_On_Fail :: #type proc(app: ^App, r: ^Request, f: Failure, message: string) -> (told: bool)
Req_On_Left :: #type proc(app: ^App, r: ^Request)

Req_Facts :: struct {
	json:    bool,
	life:    Req_Life,
	on_ok:   Req_On_Ok,
	on_fail: Req_On_Fail,
	on_left: Req_On_Left,
}

// A failure that is shown where it belongs, or is none (a server without that page): no toast, nothing undone.
quiet_on_fail :: proc(app: ^App, r: ^Request, f: Failure, message: string) -> (told: bool) { return true }

@(rodata) REQ_FACTS := [Req_Kind]Req_Facts{
	.Sessions         = {json = true, on_ok = sessions_on_ok},
	.Messages         = {json = true, life = .Chat, on_ok = messages_on_ok, on_fail = messages_on_fail},
	.Older            = {json = true, life = .Chat, on_ok = older_on_ok, on_fail = older_on_fail},
	.Todo_Scan        = {json = true, life = .Chat, on_ok = todos_scan_load, on_fail = todo_scan_on_fail},
	.Agents           = {json = true, on_ok = agents_on_ok},
	.Models           = {json = true, on_ok = models_on_ok},
	.Info             = {json = true, on_ok = info_on_ok},
	.Permissions      = {json = true, on_ok = permissions_on_ok},
	.Permission_Reply = {on_ok = permission_reply_on_ok, on_fail = permission_reply_on_fail},
	.Active           = {json = true, on_ok = active_on_ok},
	.Self             = {json = true, life = .Chat, on_ok = self_on_ok},
	.Parent           = {json = true, life = .Chat, on_ok = parent_on_ok},
	.Children         = {json = true, life = .Chat, on_ok = children_on_ok},
	.Cfg              = {json = true, on_ok = server_facts_on_ok, on_fail = quiet_on_fail},
	.Shells           = {json = true, on_ok = server_facts_on_ok, on_fail = quiet_on_fail},
	.Mcp              = {json = true, on_ok = server_facts_on_ok, on_fail = quiet_on_fail},
	.Saved            = {json = true, on_ok = server_facts_on_ok, on_fail = quiet_on_fail},
	.Usage            = {json = true, on_ok = server_facts_on_ok, on_fail = quiet_on_fail},
	.Providers        = {json = true, on_ok = server_facts_on_ok, on_fail = quiet_on_fail},
	.Skills           = {json = true, on_ok = server_facts_on_ok, on_fail = quiet_on_fail},
	.Commands         = {json = true, on_ok = server_facts_on_ok, on_fail = quiet_on_fail},
	.Shell_Set        = {on_ok = shell_set_on_ok, on_fail = shell_set_on_fail},
	.Mcp_Done         = {on_ok = mcp_done_on_ok, on_fail = mcp_done_on_fail},
	.Saved_Done       = {on_ok = saved_done_on_ok, on_fail = saved_done_on_fail},
	.Projects         = {json = true, on_ok = projects_on_ok},
	.Project_Icon     = {on_ok = project_icon_on_ok},   // (failed: the toast says it, the icon is as it was)
	.Stats            = {json = true, on_ok = stats_on_ok, on_fail = quiet_on_fail},
	.Created          = {json = true, on_ok = created_on_ok, on_fail = created_on_fail},
	.Action           = {},
	.Prompt           = {on_ok = prompt_on_ok, on_fail = prompt_on_fail, on_left = prompt_on_left},
	.Shell_List       = {json = true, life = .Chat_Gen, on_ok = shell_list_on_ok, on_fail = activity_on_fail},
	.Job_List         = {json = true, life = .Chat_Gen, on_ok = job_list_on_ok, on_fail = activity_on_fail},
	.Background       = {json = true, on_ok = background_on_ok, on_fail = quiet_on_fail},
	.Shell_One        = {json = true, life = .Chat_Gen, on_ok = shell_one_on_ok, on_fail = activity_on_fail},
	.Shell_Output     = {json = true, life = .Chat_Gen, on_ok = shell_output_on_ok, on_fail = activity_on_fail},
	.Peek             = {json = true, life = .Chat_Gen, on_ok = peek_on_ok, on_fail = activity_on_fail},
	.Slash            = {json = true, on_ok = slash_on_ok, on_fail = slash_on_fail},
	.Goal             = {json = true, life = .Chat_Gen, on_ok = goal_on_ok, on_fail = quiet_on_fail},   // (a server without the goal plugin: nothing to say)
	.Pair             = {json = true, on_ok = pair_on_ok, on_fail = pair_on_fail},   // (the server's, whatever is shown)
	.Forked           = {json = true, on_ok = forked_on_ok},
	.Session_Agent    = {on_ok = session_agent_on_ok, on_fail = session_agent_on_fail},
	.Session_Model    = {on_ok = session_model_on_ok, on_fail = session_model_on_fail},
	.Session_Choice   = {on_fail = session_choice_on_fail},
	.Session_Moved    = {on_ok = session_moved_on_ok},
	.Session_Export   = {json = true, on_ok = session_export_on_ok},
	.Session_Import   = {json = true, on_ok = session_import_on_ok, on_fail = session_import_on_fail},
	.Pty_List         = {json = true, on_ok = pty_list_on_ok, on_fail = pty_list_on_fail},
	.Pty_Made         = {json = true, on_ok = pty_made_on_ok, on_fail = pty_made_on_fail, on_left = pty_made_on_left},
	.Pty_Size         = {on_ok = pty_size_on_ok, on_fail = pty_size_on_fail},
	.Schedules        = {json = true, on_ok = schedules_on_ok, on_fail = quiet_on_fail},
	.Schedule_Made    = {json = true, on_ok = schedule_made_on_ok, on_fail = schedule_made_on_fail},
	.Schedule_Done    = {on_ok = schedule_done_on_ok},
	.Artifacts        = {json = true, on_ok = artifacts_on_ok, on_fail = quiet_on_fail},
	.Artifact_Read    = {json = true, on_ok = artifact_read_on_ok, on_fail = quiet_on_fail},
	.Chat_Artifacts   = {json = true, on_ok = chat_artifacts_on_ok, on_fail = quiet_on_fail},   // (no cards: nothing worth a toast)
	.Artifact_Done    = {on_ok = artifact_done_on_ok},
	.Plugins          = {json = true, on_ok = plugins_on_ok, on_fail = quiet_on_fail},
	.Plugins_Check    = {json = true, on_ok = plugins_check_on_ok},
	.Plugin_Update    = {on_ok = plugin_update_on_ok, on_fail = plugin_update_on_fail},
	.Integrations     = {json = true, on_ok = integrations_on_ok, on_fail = quiet_on_fail},
	.Credentials      = {json = true, on_ok = credentials_on_ok, on_fail = quiet_on_fail},
	.Credential_Done  = {on_ok = credential_done_on_ok},
	.Connected        = {on_ok = connected_on_ok, on_fail = connect_on_fail},
	.Connect_Begin    = {json = true, on_ok = connect_begin_on_ok, on_fail = connect_on_fail, on_left = connect_begin_on_left},
	.Connect_Status   = {json = true, on_ok = connect_status_on_ok, on_fail = connect_status_on_fail},
	.Mention_Files    = {json = true, on_ok = mention_files_on_ok, on_fail = mention_files_on_fail},
	.Files_List       = {json = true, on_ok = files_list_on_ok, on_fail = quiet_on_fail},
	.File_Read        = {on_ok = file_read_on_ok, on_fail = quiet_on_fail},
	.Changes_Range    = {json = true, on_ok = changes_range_on_ok, on_fail = quiet_on_fail},
	.Changes          = {json = true, on_ok = changes_on_ok, on_fail = changes_on_fail},
	.Revert_Staged    = {json = true, on_ok = revert_staged_on_ok, on_fail = revert_on_fail, on_left = revert_staged_on_left},
	.Revert_Done      = {on_ok = revert_done_on_ok, on_fail = revert_on_fail},
	.Revert_Cancelled = {on_ok = revert_cancelled_on_ok, on_fail = revert_on_fail},
	.Forms            = {json = true, on_ok = forms_on_ok},
	.Form_Reply       = {on_ok = form_answer_on_ok, on_fail = form_answer_on_fail},
	.Form_Dismiss     = {on_ok = form_answer_on_ok, on_fail = form_answer_on_fail},
	.Inbox            = {json = true, on_ok = inbox_on_ok, on_fail = inbox_on_fail},
	.Inbox_Take       = {on_ok = inbox_take_on_ok},
	.Queue_List       = {json = true, on_ok = queue_list_on_ok, on_fail = quiet_on_fail},   // (the list says it, with its Try again)
	.Queue_Steer      = {on_ok = queue_item_on_ok, on_fail = queue_item_on_fail},
	.Queue_Cancel     = {on_ok = queue_item_on_ok, on_fail = queue_item_on_fail},
	.Queue_Replace    = {on_ok = queue_replace_on_ok, on_fail = queue_replace_on_fail, on_left = queue_replace_on_left},
	.Queue_Check      = {on_ok = queue_check_on_ok, on_fail = queue_check_on_fail, on_left = queue_check_on_left},
	.Output_Read      = {json = true, on_ok = output_read_on_ok, on_fail = output_view_on_fail},
	.Output_State     = {json = true, on_ok = output_state_on_ok, on_fail = output_view_on_fail},
	.Context          = {json = true, life = .Chat, on_ok = context_on_ok, on_fail = quiet_on_fail},
	.Session_Viewed   = {on_fail = quiet_on_fail},   // (session.viewed says it, to every client; the next list shows it as it stands)
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
// to (the kind's on_left). (A stage has written the files back; a login or a command goes on running; a prompt on its way still has
// to say whether it got there.)
@(private = "file")
answer_left :: proc(app: ^App, r: ^Request) {
	if left := REQ_FACTS[r.kind].on_left; left != nil { left(app, r) }
}

// Everything an answer can be, in one place. A Remote is settled here, before the kind's procedure.
answer :: proc(app: ^App, r: ^Request) {
	defer {
		if r.read_in != nil { append(&app.cx.answers_spent, r.read_in) }
		r.read_in = nil
		c := r.conn
		request_free(r)
		conn_release(app, c)
	}
	sync.atomic_sub(&app.pending, 1)
	flight_ends(app, r)
	if r.conn != app.conn {
		// a server left: server_forget cleaned up what depends on it. A reading it forgot does not stay Loading.
		if x := r.reading; x != nil && remote.current(x, r.ticket) { remote.reset(x) }
		answer_left(app, r)
		return
	}
	if (r.reading != nil && !remote.current(r.reading, r.ticket)) || r.dropped || req_outlived(app, r) {   // a reading given up, a conversation left
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
	if r.reading != nil { remote.settle(r.reading, .Ready, "") }
	if ok := REQ_FACTS[r.kind].on_ok; ok != nil { ok(app, r, v) }
}

// How a request failed.
Failure :: enum u8 {
	Transport,    // the server was not reached
	Auth,         // 401
	Refused,      // another status from 400 on: `message` is the server's
	Unreadable,   // a success that says nothing that can be read
}

// Every failure comes here: its Remote, what it leaves undone (the kind's on_fail), what the reader is told.
answer_failed :: proc(app: ^App, r: ^Request, f: Failure, message: string) {
	if r.reading != nil { remote.settle(r.reading, f == .Refused ? .Refused : .Failed, message) }
	if f == .Auth { conn_auth_refused(app) }
	if f == .Unreadable { unreadable_note(app, fmt.tprintf("answer %v", r.kind), r.resp) }   // (counted before on_fail: it may tell no one)
	if fail := REQ_FACTS[r.kind].on_fail; fail != nil && fail(app, r, f, message) { return }
	switch f {
	case .Transport:  ui.toast(.Bad, "Server unreachable (%s)", r.path)
	case .Auth:       ui.toast(.Bad, "Authentication refused by the server")
	case .Refused:    ui.toast(.Bad, "%s %s: %d %s", r.method, r.path, r.status, message)
	case .Unreadable: ui.toast(.Warn, "Unreadable answer (%s)", r.path)
	}
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
	remote.begin(&app.cx.chat_read)
	request(app, .Messages, "GET", fmt.tprintf("/api/session/%s/message?limit=%d&order=desc", id, app.prefs.page_size), tag = id, reading = &app.cx.chat_read)
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

interrupt_session :: proc(app: ^App, id: string) {
	request(app, .Action, "POST", fmt.tprintf("/api/session/%s/interrupt", id), "", id)
}

// One answer to it: the second click of a double click finds it on its way.
reply_permission :: proc(app: ^App, p: ^Permission, decision: string) {
	if p.replying { return }
	p.replying = true
	request(app, .Permission_Reply, "POST", fmt.tprintf("/api/session/%s/permission/%s/reply", p.session, p.id), fmt.tprintf(`{{"decision":%s}}`, jquote(decision)), p.id)
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
			e := event_read(c, data)
			if !ui.post(&c.app.state, on_event, e, EVENT_WORD) { event_free(e); return false }
			return true
		}, c, proc(user: rawptr) {
			ui.post(&(^Conn)(user).app.state, proc(data: rawptr, word: u64) { if data == the_app.conn { stream_up(the_app) } }, user)
		})
		if sync.atomic_load(&c.stop) { break }
		ui.post(&c.app.state, proc(data: rawptr, word: u64) { if data == the_app.conn { stream_down(the_app, int(word)) } }, c, u64(st))
		time.sleep(STREAM_RETRY_S * time.Second)
	}
	conn_release_post(c)
}

// An event read on the stream's thread, and the connection it came by (dropped when that is no longer the one connected). Read there,
// not in the interface's thread: a burst of deltas costs that thread only what applying them costs. What it holds lives in its own arena,
// gone once applied (event_take).
Event_Msg :: struct {
	conn:       ^Conn,
	value:      json.Value,
	unreadable: bool,
	excerpt:    string,            // an unreadable one's first bytes, for the log
	arena:      mem.Dynamic_Arena,
}

EVENT_WORD :: u64(0x4556454e54)   // a post's word for an Event_Msg (on_drop frees it)

// Small blocks: most events are a delta of a few hundred bytes, and a large text (a tool's output) goes in a block of its own.
EVENT_BLOCK_BYTES    :: 8 * 1024
EVENT_OUT_BAND_BYTES :: 2 * 1024

// `allocator`: where the arena takes its blocks (a test's, to see them all given back).
event_read :: proc(c: ^Conn, text: string, allocator := context.allocator) -> ^Event_Msg {
	e := new(Event_Msg, allocator)
	e.conn = c
	mem.dynamic_arena_init(&e.arena, allocator, allocator, EVENT_BLOCK_BYTES, EVENT_OUT_BAND_BYTES)
	a := mem.dynamic_arena_allocator(&e.arena)
	// (on an error the parser frees what it made with context.allocator, not with `allocator`: the arena's own, which frees nothing)
	context.allocator = a
	v, err := json.parse_string(text, parse_integers = true, allocator = a)
	if err != nil {
		e.unreadable = true
		e.excerpt = strings.clone(text[:min(len(text), UNREADABLE_EXCERPT_BYTES)], a)
	} else {
		e.value = v
	}
	return e
}

event_free :: proc(e: ^Event_Msg) {
	allocator := e.arena.block_allocator
	mem.dynamic_arena_destroy(&e.arena)
	free(e, allocator)
}

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
	experimental_check(app)
}

// The server answers again, or for the first time: what a dialog has on screen and could not read is tried again, and the pages of the
// settings, whose events were missed, are read again. Nothing that was not open is asked for.
@(private = "file")
dialogs_reread :: proc(app: ^App) {
	cx := &app.cx
	if app.cx.open[.Settings] { server_facts_load(app) }
	integrations_reread(app)
	plugins_changed(app)
	if cx.open[.Schedules] && remote.failed(&cx.schedules.read) { schedules_ask(app) }
	if cx.open[.Artifacts] && remote.failed(&cx.artifacts.read) { artifacts_ask(app) }
	if cx.open[.Files] && remote.failed(&cx.files.read) { files_list(app) }
	if app.stats_open {
		if remote.failed(&cx.stats_read) { stats_ask(app) }
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
refresh_soon :: proc(app: ^App) { ui.deferred_ask(&app.cx.due[.Refresh], REFRESH_DEBOUNCE_MS, REFRESH_DEBOUNCE_MS * DEFERRED_MOST) }

children_soon :: proc(app: ^App) { ui.deferred_ask(&app.cx.due[.Children], CHILDREN_DEBOUNCE_MS, CHILDREN_DEBOUNCE_MS * DEFERRED_MOST) }

facts_soon :: proc(app: ^App) { ui.deferred_ask(&app.cx.due[.Facts], FACTS_DEBOUNCE_MS, FACTS_DEBOUNCE_MS * DEFERRED_MOST) }

on_event :: proc(data: rawptr, word: u64) { event_take(the_app, (^Event_Msg)(data)) }

// An event read on the stream's thread, applied, then freed. Only what changed what a window shows moves the windows of their own
// (shared_moved): a delta of a session nobody looks at leaves them at rest. (main.odin posts_moved counts the other posts.)
event_take :: proc(app: ^App, e: ^Event_Msg) {
	defer event_free(e)
	app.cx.events_run += 1
	if e.conn != app.conn { return }   // a server left
	if e.unreadable {
		unreadable_note(app, "event", e.excerpt)
		return
	}
	if apply_event(app, e.value) { app.cx.shared_moved = true }
}

// What the queue will never run. It blocks when full and is closed only at the end, with no worker joined and no ui.destroy: a Request or a
// shell's output left there then goes with the process, and a post refused after the close is freed by whoever posted it. An event is the
// one message this has to know, for a queue that does get destroyed (a test's).
on_drop :: proc(data: rawptr, word: u64) {
	if word == EVENT_WORD { event_free((^Event_Msg)(data)) }
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
