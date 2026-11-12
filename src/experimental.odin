// This client is experimental, and takes the server's experimental options as on: at each connection to a server of this computer, those
// its schema offers and its configuration does not mention go in its global file. The list is the server's, never ours: an option it no
// longer has is not added, and one left in the file is ignored by it (it says so by dropping the key). What the person set is left alone,
// a false too. The API writes no such option, so the file is what changes: comments stay, the file is read back before it replaces the old
// one, and the server sees it by itself. A server elsewhere: its file is not here, and the dialogs say what it answers.
package ocn

import "core:encoding/json"
import "core:os"
import "core:strings"
import "gt:ui"

// The options the server's schema offers that are plain switches, and whether a feature of ours is among them.
experimental_keys :: proc(spec: json.Value, allocator := context.temp_allocator) -> []string {
	keys := make([dynamic]string, allocator)
	props, _ := jget(spec, "components", "schemas", "Config.InfoEncoded", "properties", "experimental", "properties").(json.Object)
	for k, v in props {
		if jstr(v, "type") == "boolean" { append(&keys, strings.clone(k, allocator)) }
	}
	return keys[:]
}

@(private = "file")
Jsonc_Scan :: struct { text: string, at: int }

// Past a string, whose opening quote is at `at`.
@(private = "file")
skip_string :: proc(s: ^Jsonc_Scan) {
	s.at += 1
	for s.at < len(s.text) {
		switch s.text[s.at] {
		case '\\': s.at += 2; continue
		case '"':  s.at += 1; return
		}
		s.at += 1
	}
}

// Past what is no value: blanks and comments.
@(private = "file")
skip_blank :: proc(s: ^Jsonc_Scan) {
	for s.at < len(s.text) {
		c := s.text[s.at]
		switch {
		case c == ' ' || c == '\n' || c == '\r' || c == '\t': s.at += 1
		case strings.has_prefix(s.text[s.at:], "//"):
			end := strings.index_byte(s.text[s.at:], '\n')
			s.at = end < 0 ? len(s.text) : s.at + end
		case strings.has_prefix(s.text[s.at:], "/*"):
			end := strings.index(s.text[s.at:], "*/")
			s.at = end < 0 ? len(s.text) : s.at + end + 2
		case: return
		}
	}
}

// Where the top-level object's key `key` has its value (-1: no such key; -2: not an object at the top).
@(private = "file")
jsonc_value_of :: proc(text, key: string) -> int {
	s := Jsonc_Scan{text, 0}
	skip_blank(&s)
	if s.at >= len(text) || text[s.at] != '{' { return -2 }
	s.at += 1
	depth := 1
	for s.at < len(text) && depth > 0 {
		skip_blank(&s)
		if s.at >= len(text) { break }
		switch text[s.at] {
		case '{', '[': depth += 1; s.at += 1
		case '}', ']': depth -= 1; s.at += 1
		case '"':
			start := s.at
			skip_string(&s)
			if depth != 1 || text[start + 1:s.at - 1] != key { continue }
			skip_blank(&s)
			if s.at < len(text) && text[s.at] == ':' {
				s.at += 1
				skip_blank(&s)
				return s.at
			}
		case: s.at += 1
		}
	}
	return -1
}

// `text` with `keys` on in its "experimental" object, what it already says of them left as it is; "" when nothing is to change or it
// is not a file this can read.
config_with_experimental :: proc(text: string, keys: []string, allocator := context.temp_allocator) -> string {
	at := jsonc_value_of(text, "experimental")
	if at == -2 { return "" }
	b := strings.builder_make(allocator)
	if at < 0 {
		// no such object: first in the file
		s := Jsonc_Scan{text, 0}
		skip_blank(&s)
		open := s.at + 1
		s.at = open
		skip_blank(&s)
		empty := s.at < len(text) && text[s.at] == '}'
		strings.write_string(&b, text[:open])
		strings.write_string(&b, "\n  \"experimental\": {")
		for k, i in keys {
			if i > 0 { strings.write_byte(&b, ',') }
			strings.write_string(&b, "\n    ")
			strings.write_string(&b, jquote(k))
			strings.write_string(&b, ": true")
		}
		strings.write_string(&b, "\n  }")
		if !empty { strings.write_byte(&b, ',') }
		strings.write_string(&b, text[open:])
		return len(keys) > 0 ? strings.to_string(b) : ""
	}
	if at >= len(text) || text[at] != '{' { return "" }
	object := text[at:]
	// what the object says already: its keys are those at its own level
	missing := make([dynamic]string, context.temp_allocator)
	inner := object_text(object)
	for k in keys {
		if jsonc_value_of(inner, k) < 0 { append(&missing, k) }
	}
	if len(missing) == 0 { return "" }
	s := Jsonc_Scan{text, at + 1}
	skip_blank(&s)
	empty := s.at < len(text) && text[s.at] == '}'
	strings.write_string(&b, text[:at + 1])
	for k, i in missing {
		strings.write_string(&b, "\n    ")
		strings.write_string(&b, jquote(k))
		strings.write_string(&b, ": true")
		if !empty || i < len(missing) - 1 { strings.write_byte(&b, ',') }
	}
	if empty { strings.write_string(&b, "\n  ") }
	strings.write_string(&b, text[at + 1:])
	return strings.to_string(b)
}

// The object that starts `s`, up to its closing brace.
@(private = "file")
object_text :: proc(s: string) -> string {
	c := Jsonc_Scan{s, 0}
	depth := 0
	for c.at < len(s) {
		skip_blank(&c)
		if c.at >= len(s) { break }
		switch s[c.at] {
		case '{', '[': depth += 1; c.at += 1
		case '}', ']':
			depth -= 1
			c.at += 1
			if depth == 0 { return s[:c.at] }
		case '"': skip_string(&c)
		case: c.at += 1
		}
	}
	return s
}

@(private = "file")
Experimental_Job :: struct { app: ^App, conn: ^Conn, write: bool }

@(private = "file")
Experimental_Answer :: struct { app: ^App, conn: ^Conn, known: bool, schedules, artifacts, changed: bool }

// On a worker of the connection, which it holds until its answer ran: the schema is large, and nothing here is for the interface to wait for.
experimental_check :: proc(app: ^App) {
	job := new(Experimental_Job)
	job^ = {app, app.conn, app.prefs.experimental && url_is_here(app.conn.http.base)}
	conn_hold(app.conn)
	pool_add(&app.conn.pool, proc(data: rawptr) {
		job := (^Experimental_Job)(data)
		defer free(job)
		a := context.temp_allocator
		answer := new(Experimental_Answer)
		answer.app, answer.conn = job.app, job.conn
		status, spec_text, ok := job.conn.transport.fetch(job.conn, "GET", "/openapi.json", "", a)
		if ok && status < 300 {
			spec, err := json.parse_string(spec_text, allocator = a)
			keys := experimental_keys(spec, a)
			if err == nil && len(keys) > 0 {
				answer.known = true
				for k in keys {
					if k == "schedules" { answer.schedules = true }
					if k == "artifacts" { answer.artifacts = true }
				}
				if job.write { answer.changed = experimental_write(job.conn, keys) }
			}
		}
		if !ui.post(&job.app.state, experimental_answer, answer) { free(answer) }
	}, job)
}

// The global file the server reads last.
@(private = "file")
experimental_write :: proc(conn: ^Conn, keys: []string) -> bool {
	a := context.temp_allocator
	status, body, ok := conn.transport.fetch(conn, "GET", "/api/config", "", a)
	if !ok || status >= 300 { return false }
	v, err := json.parse_string(body, allocator = a)
	if err != nil { return false }
	docs, _ := v.(json.Array)
	path := ""
	for d in docs {
		if jstr(d, "type") == "document" && jstr(d, "path") != "" { path = jstr(d, "path") }
	}
	if path == "" { return false }
	data, read_err := os.read_entire_file(path, a)
	if read_err != nil { return false }
	next := config_with_experimental(string(data), keys, a)
	if next == "" { return false }
	if _, bad := json.parse_string(next, .JSON5, allocator = a); bad != nil { return false }   // (never a file it could not read)
	tmp := strings.concatenate({path, ".tmp"}, a)
	if os.write_entire_file(tmp, transmute([]u8)next) != nil { return false }
	return os.rename(tmp, path) == nil
}

@(private = "file")
experimental_answer :: proc(data: rawptr, word: u64) {
	r := (^Experimental_Answer)(data)
	app := r.app
	defer { conn_release(app, r.conn); free(r) }
	if r.conn != app.conn { return }
	if r.known { app.cx.no_schedules, app.cx.no_artifacts = !r.schedules, !r.artifacts }
	if r.changed { ui.toast(.Good, "The server's experimental options are on") }
}
