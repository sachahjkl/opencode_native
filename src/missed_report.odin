// What a notification of "What you missed" says happened: the request that started the run (the person's prompt, or a
// command), the agent's last answer, the files its tools wrote and its last todo list. The conversation shown is another
// session's most of the time, so each report is read from the server for its own session (the root for an end, the child
// for a sub-agent, the session of a scheduled run) and kept in app.missed.reports while an entry of the log refers to it.
//
// A report is read when its entry is put (a new end: read again), when the view opens (the open entries that lack one), and
// when the card shown or a row unfolded lacks one. One request at a time per session (flying); a report being read, read or
// failed is not asked again by the view: Try again asks a failed one.
package ocn

import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:unicode/utf8"
import "gt:markdown"
import notices "gt:notices"

MISSED_REPORT_MESSAGES :: 50    // newest messages read for a report: the run's prompt is among them, most of the time
MISSED_REPORT_ASK_MAX  :: 6     // reports asked at once when the view opens
MISSED_REPORT_FLYING_MAX :: 8   // reports on their way, past which a new entry does not ask for its own (the view will)
MISSED_HEAD_LINES      :: 4     // lines of the request and of the answer in a row unfolded
MISSED_CARD_LINES      :: 12    // lines of the request in a card
MISSED_HEAD_BYTES      :: 600   // bytes of those lines, at most

Missed_Report_State :: enum u8 {
	Unread,    // to read (none was read, or its server was left)
	Reading,
	Read,
	Failed,
}

Missed_Report :: struct {
	state:        Missed_Report_State,
	again:        bool,               // a new end came while it was read: read again once the answer comes
	request:      string,             // the prompt that started the run, or "$ command" (owned)
	answer:       string,             // the last text of the agent, whole (owned)
	files:        [dynamic]string,    // what the run's tools wrote, each path once, in the order of the calls (owned)
	todos:        [dynamic]Todo,      // its last todo list (owned)
	tools:        int,                // tool calls of the run
	// cut once, when it is read (slices of the texts above)
	request_head: string,             // MISSED_HEAD_LINES of the request
	request_card: string,             // MISSED_CARD_LINES of it
	answer_head:  string,             // MISSED_HEAD_LINES of the answer
	doc:          ^markdown.Doc,      // the answer as Markdown, parsed once (made at its first view)
	head_doc:     ^markdown.Doc,      // ... its head, for a row unfolded in the list (Markdown too: no "**" shown)
}

// The session whose report an entry shows ("": none, a wait or a command).
missed_report_session :: proc(app: ^App, e: ^notices.Entry) -> string {
	#partial switch Missed_Kind(e.kind) {
	case .End, .Sub:
		if id, _, ok := missed_key_parts(app, e.key); ok { return id }
	case .Scheduled:
		if root, ok := missed_unscoped(app, e.group); ok { return root }
	}
	return ""
}

// The report of a session (nil: none asked).
missed_report_find :: proc(app: ^App, sid: string) -> ^Missed_Report {
	if sid == "" { return nil }
	if r, ok := &app.missed.reports[sid]; ok { return r }
	return nil
}

// Its report is read from the server (an entry was put: a new end of the session). A report on its way is read again
// when its answer comes.
missed_report_ask :: proc(app: ^App, sid: string) {
	if sid == "" || app.conn == nil { return }   // (no server: nothing to ask, nothing marked as asked)
	m := &app.missed
	r := missed_report_find(app, sid)
	if r == nil {
		m.reports[strings.clone(sid)] = {}
		r = &m.reports[sid]
	}
	if flying(app, .Missed_Report, sid) { r.again = true; return }
	r.state, r.again = .Reading, false
	request(app, .Missed_Report, "GET", fmt.tprintf("/api/session/%s/message?limit=%d&order=desc", sid, MISSED_REPORT_MESSAGES), tag = sid)
}

// An entry of `sid` was put: its report, if there is one, is out of date. A session with none waits for the view when many
// are on their way already (the first list of a server can put an end for each session nobody saw).
missed_report_put :: proc(app: ^App, sid: string) {
	if sid == "" { return }
	if missed_report_find(app, sid) == nil {
		n := 0
		for f in app.cx.flights { if f.kind == .Missed_Report { n += 1 } }
		if n >= MISSED_REPORT_FLYING_MAX { return }
	}
	missed_report_ask(app, sid)
}

// The view needs the report of `sid`: asked when it has none to show and none is on its way. True: asked.
missed_report_want :: proc(app: ^App, sid: string) -> bool {
	if sid == "" { return false }
	if r := missed_report_find(app, sid); r != nil && r.state != .Unread { return false }
	missed_report_ask(app, sid)
	return app.conn != nil
}

// The open entries of the view that lack a report, the newest first, MISSED_REPORT_ASK_MAX at most (the rows are made).
missed_reports_want_open :: proc(app: ^App) {
	asked := 0
	for r in app.missed.rows {
		if asked >= MISSED_REPORT_ASK_MAX { return }
		if r.entry == nil || r.entry.state == .Acknowledged { continue }
		if missed_report_want(app, missed_report_session(app, r.entry)) { asked += 1 }
	}
}

missed_report_on_ok :: proc(app: ^App, req: ^Request, v: json.Value) {
	missed_report_load(app, req.tag, v)
	if r := missed_report_find(app, req.tag); r != nil && r.again { missed_report_ask(app, req.tag) }
}

missed_report_on_fail :: proc(app: ^App, req: ^Request, f: Failure, message: string) -> (told: bool) {
	if r := missed_report_find(app, req.tag); r != nil {
		r.state = .Failed
		if r.again { missed_report_ask(app, req.tag) }
	}
	return true   // (the card says it, with its Try again)
}

// Its server was left: what it would have said is to be read again.
missed_report_on_left :: proc(app: ^App, req: ^Request) {
	if r := missed_report_find(app, req.tag); r != nil && r.state == .Reading { r.state = .Unread }
}

// A page of the session's messages, the newest first, read into its report (made if there is none: a test, an answer).
missed_report_load :: proc(app: ^App, sid: string, v: json.Value) {
	m := &app.missed
	r := missed_report_find(app, sid)
	if r == nil {
		m.reports[strings.clone(sid)] = {}
		r = &m.reports[sid]
	}
	missed_report_read(r, v)
	r.state = .Read
}

// What the run did, from a page of its session's messages, the newest first: the run is what follows the newest prompt.
missed_report_read :: proc(r: ^Missed_Report, v: json.Value) {
	missed_report_empty(r)
	items := jarr(v, "data")
	start := len(items)   // the newest prompt (none in the page: all of it is the run)
	for it, i in items {
		switch jstr(it, "type") {
		case "user":  r.request = strings.clone(jstr(it, "text"))
		case "shell": r.request = strings.concatenate({"$ ", jstr(it, "command")})
		case:         continue
		}
		start = i
		break
	}
	// the answer: the newest message of the agent that says something
	answer: for it in items[:start] {
		if jstr(it, "type") != "assistant" { continue }
		b := strings.builder_make(context.temp_allocator)
		for c in jarr(it, "content") {
			if jstr(c, "type") != "text" { continue }
			t := strings.trim_space(jstr(c, "text"))
			if t == "" { continue }
			if strings.builder_len(b) > 0 { strings.write_string(&b, "\n\n") }
			strings.write_string(&b, t)
		}
		if strings.builder_len(b) > 0 {
			r.answer = strings.clone(strings.to_string(b))
			break answer
		}
	}
	// the tools, in the order they ran: the files they wrote, the last todo list
	#reverse for it in items[:start] {
		if jstr(it, "type") != "assistant" { continue }
		for c in jarr(it, "content") {
			if jstr(c, "type") != "tool" { continue }
			r.tools += 1
			p := Part{tool_name = jstr(c, "name")}
			tool_set_input(&p, jget(c, "state", "input"), context.temp_allocator)
			if p.has_todos {
				for t in r.todos { delete(t.content); delete(t.status) }
				clear(&r.todos)
				for t in p.todos { append(&r.todos, Todo{strings.clone(t.content), strings.clone(t.status)}) }
			}
			if tool_kind(p.tool_name) != .Edit { continue }
			if p.file_path != "" { missed_report_file(r, p.file_path); continue }
			// (a patch names its files in what the server says of it)
			for f in jarr(c, "state", "metadata", "files") {
				path := jstr(f, "filePath")
				if path == "" { path = jstr(f, "relativePath") }
				if path == "" { path = jstr(f, "path") }
				if path != "" { missed_report_file(r, path) }
			}
		}
	}
	r.request_head = text_head(r.request, MISSED_HEAD_LINES)
	r.request_card = text_head(r.request, MISSED_CARD_LINES)
	r.answer_head = text_head(r.answer, MISSED_HEAD_LINES)
}

@(private = "file")
missed_report_file :: proc(r: ^Missed_Report, path: string) {
	for f in r.files { if f == path { return } }
	append(&r.files, strings.clone(path))
}

// What it read goes (its doc too: a new answer may be where the old one was, of the same length).
@(private = "file")
missed_report_empty :: proc(r: ^Missed_Report) {
	delete(r.request); delete(r.answer)
	for f in r.files { delete(f) }
	clear(&r.files)
	for t in r.todos { delete(t.content); delete(t.status) }
	clear(&r.todos)
	if r.doc != nil { markdown.doc_destroy(r.doc) }
	if r.head_doc != nil { markdown.doc_destroy(r.head_doc) }
	r.request, r.answer, r.request_head, r.request_card, r.answer_head, r.tools = "", "", "", "", "", 0
}

missed_report_free :: proc(r: ^Missed_Report) {
	missed_report_empty(r)
	delete(r.files)
	delete(r.todos)
	free(r.doc)
	free(r.head_doc)
	r^ = {}
}

// The answer's doc, made at its first view: parsed once, read again only when the answer is another.
missed_report_doc :: proc(r: ^Missed_Report) -> ^markdown.Doc {
	if r.doc == nil { r.doc = new(markdown.Doc) }
	return r.doc
}

// The doc of the answer's head, as missed_report_doc.
missed_report_head_doc :: proc(r: ^Missed_Report) -> ^markdown.Doc {
	if r.head_doc == nil { r.head_doc = new(markdown.Doc) }
	return r.head_doc
}

// The reports no entry of the log refers to any more go (when the rows are made again: the log or the server changed).
missed_reports_sweep :: proc(app: ^App) {
	m := &app.missed
	if len(m.reports) == 0 { return }
	used := make(map[string]bool, len(m.log.entries), context.temp_allocator)
	for e in m.log.entries {
		if sid := missed_report_session(app, e); sid != "" { used[sid] = true }
	}
	gone := make([dynamic]string, context.temp_allocator)
	for k in m.reports { if k not_in used { append(&gone, k) } }
	for k in gone {
		key, r := delete_key(&m.reports, k)
		missed_report_free(&r)
		delete(key)
	}
}

missed_reports_free :: proc(app: ^App) {
	m := &app.missed
	for k, &r in m.reports {
		missed_report_free(&r)
		delete(k)
	}
	delete(m.reports)
	m.reports = nil
}

// The first `n` lines of `s`, MISSED_HEAD_BYTES at most and whole characters (a slice of `s`).
text_head :: proc(s: string, n: int) -> string {
	end, lines := 0, 0
	for end < len(s) && lines < n {
		i := strings.index_byte(s[end:], '\n')
		if i < 0 { end = len(s); break }
		end += i + 1
		lines += 1
	}
	head := strings.trim_right_space(s[:end])
	if len(head) <= MISSED_HEAD_BYTES { return head }
	cut := MISSED_HEAD_BYTES
	for cut > 0 && !utf8.rune_start(head[cut]) { cut -= 1 }
	return head[:cut]
}
