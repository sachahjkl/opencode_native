// A server's requests, its event stream and its sockets, over the toolkit's gt:http (WinHTTP, libcurl). Every call
// blocks: workers and the stream's and sockets' threads make them, never the interface's. src/md/infrastructure/transport.md
// says why the limits are these.
package ocn

import "core:encoding/base64"
import "core:fmt"
import "core:strconv"
import "core:strings"
import "core:time"
import tk_http "gt:http"

// A whole request, a large answer's body included (a session's export): past it, the server is taken for unreachable.
REQUEST_TIMEOUT :: 3 * time.Minute
// The largest answer read (a long session's messages).
REQUEST_MAX_BYTES :: 256 << 20
// An event stream silent this long is taken for dead: a machine that slept, a network that went away without a word leave
// the socket open, and only the server's heartbeats tell it from a quiet server. Several of them may be missed.
STREAM_SILENCE :: 95 * time.Second
// A socket's handshake.
SOCKET_TIMEOUT :: 30 * time.Second
// The name's lookup and the connection, of a request, the stream and a socket: a server that does not answer is said
// down after this, not after the whole REQUEST_TIMEOUT.
CONNECT_TIMEOUT :: 5 * time.Second

USER_AGENT :: "opencode-native/" + APP_VERSION

// A server: its address and its credentials. (Owned by the Conn; read by its threads, never changed.)
Http :: struct {
	base: string,   // "http://host:port", no slash at its end
	auth: string,   // "Basic ..." ("": no password)
}

http_init :: proc(base: string, user, password: string) -> Http {
	h := Http{base = strings.clone(strings.trim_right(base, "/"))}
	if password != "" {
		creds := fmt.tprintf("%s:%s", user, password)
		h.auth = fmt.aprintf("Basic %s", base64.encode(transmute([]u8)creds, allocator = context.temp_allocator))
	}
	return h
}

http_destroy :: proc(h: ^Http) {
	delete(h.base)
	delete(h.auth)
	h^ = {}
}

// The headers of every call to the server, and `extra`. (Allocated in the temp allocator.)
@(private = "file")
http_headers :: proc(h: ^Http, extra: ..tk_http.Header) -> []tk_http.Header {
	out := make([dynamic]tk_http.Header, 0, len(extra) + 1, context.temp_allocator)
	if h.auth != "" { append(&out, tk_http.Header{"Authorization", h.auth}) }
	append(&out, ..extra)
	return out[:]
}

// What a request to the server takes: its headers (`json`: a JSON body goes with it), its limits. Its answer comes
// compressed when the server can (a session's messages are JSON: a remote server's answers cost several times less).
http_request_of :: proc(h: ^Http, method, body: string) -> tk_http.Request {
	json := body != "" || method == "POST" || method == "PUT" || method == "PATCH"
	headers := json ? http_headers(h, {"Accept", "application/json"}, {"Content-Type", "application/json"}) : http_headers(h, {"Accept", "application/json"})
	return {max_bytes = REQUEST_MAX_BYTES, user_agent = USER_AGENT, timeout = REQUEST_TIMEOUT, connect_timeout = CONNECT_TIMEOUT, compressed = true, headers = headers, body = body == "" ? nil : transmute([]u8)body}
}

// A whole request: the response body is allocated with `allocator`. `ok` = false: the server was not reached (`resp`
// says why).
http_request :: proc(h: ^Http, method, path: string, body := "", allocator := context.allocator) -> (status: int, resp: string, ok: bool) {
	res, err := tk_http.request(method, strings.concatenate({h.base, path}, context.temp_allocator), http_request_of(h, method, body), allocator)
	if err != .None { return 0, strings.clone(tk_http.error_text(err), allocator), false }
	status, resp = res.status, string(res.body)
	res.body = nil
	tk_http.response_destroy(&res, allocator)
	return status, resp, true
}

// What a range of a file brings back (Transport.range). body and etag are in the allocator given.
Range_Answer :: struct {
	ok:     bool,     // the server was reached (false: `why` says how it was not)
	why:    string,   // (static)
	status: int,      // 206: the range; 200: the whole file; 416: no such range (an empty file says `bytes */0`)
	body:   []u8,
	total:  i64,      // the file's size, from Content-Range (or a 200's body); -1: not said
	etag:   string,   // "": none
}

range_answer_destroy :: proc(a: ^Range_Answer, allocator := context.allocator) {
	delete(a.body, allocator)
	delete(a.etag, allocator)
	a^ = {}
}

// The total of a Content-Range: "bytes 0-99/39674" and "bytes */0" say it, "bytes 0-99/*" does not (-1).
content_range_total :: proc(v: string) -> i64 {
	slash := strings.last_index_byte(v, '/')
	if slash < 0 { return -1 }
	n, ok := strconv.parse_i64(strings.trim_space(v[slash + 1:]))
	return ok && n >= 0 ? n : -1
}

// The bytes `from` to `to` (included) of what a GET of `path` gives (`if_range`: the ETag the first range came with: a
// file changed since answers 200 whole). Not compressed: a range of a compressed body is no range of the file, and
// gt:http drops the length of a body it decodes. A server that ignores Range answers 200 with the whole file, up to
// REQUEST_MAX_BYTES.
http_range :: proc(h: ^Http, path: string, from, to: i64, if_range: string, allocator := context.allocator) -> Range_Answer {
	asked := tk_http.Header{"Range", fmt.tprintf("bytes=%d-%d", from, to)}
	headers := if_range != "" ? http_headers(h, asked, {"If-Range", if_range}) : http_headers(h, asked)
	req := tk_http.Request{max_bytes = REQUEST_MAX_BYTES, user_agent = USER_AGENT, timeout = REQUEST_TIMEOUT, connect_timeout = CONNECT_TIMEOUT, headers = headers}
	res, err := tk_http.request("GET", strings.concatenate({h.base, path}, context.temp_allocator), req, allocator)
	if err != .None { return {why = tk_http.error_text(err)} }
	a := Range_Answer{ok = true, status = res.status, body = res.body, total = -1}
	if v, ok := tk_http.header_value(res.headers, "Content-Range"); ok {
		a.total = content_range_total(v)
	} else if res.status == 200 {
		a.total = i64(len(res.body))
	}
	if v, ok := tk_http.header_value(res.headers, "ETag"); ok { a.etag = strings.clone(v, allocator) }
	res.body = nil
	tk_http.response_destroy(&res, allocator)
	return a
}

// What the event stream takes: no limit of its own but its silence, and its connection's. Not compressed: a server's
// compressor may hold a small event until its buffer fills, and an event must come when it happens.
http_stream_of :: proc(h: ^Http) -> tk_http.Request {
	return {user_agent = USER_AGENT, timeout = STREAM_SILENCE, connect_timeout = CONNECT_TIMEOUT, headers = http_headers(h)}
}

// Reads the event stream at `path` until it ends, `on_event` says .Stop or `stop` is asked. Returns the status of its
// response (0: the server was not reached).
http_events :: proc(h: ^Http, path: string, stop: ^tk_http.Stop, on_event: tk_http.Event_Proc, user: rawptr) -> (status: int, err: tk_http.Error) {
	return tk_http.events(strings.concatenate({h.base, path}, context.temp_allocator), http_stream_of(h), on_event, user, stop)
}

// A socket at `path` on the server (ws:// or wss://, as the server's scheme); nil: none.
http_ws_open :: proc(h: ^Http, path: string) -> ^tk_http.Socket {
	scheme, rest := "ws", h.base
	switch {
	case strings.has_prefix(rest, "https://"): scheme, rest = "wss", rest[len("https://"):]
	case strings.has_prefix(rest, "http://"):  rest = rest[len("http://"):]
	}
	url := fmt.tprintf("%s://%s%s", scheme, rest, path)
	s, err := tk_http.ws_connect(url, http_socket_of(h))
	return err == .None ? s : nil
}

// What a socket's handshake takes.
http_socket_of :: proc(h: ^Http) -> tk_http.Request {
	return {user_agent = USER_AGENT, timeout = SOCKET_TIMEOUT, connect_timeout = CONNECT_TIMEOUT, headers = http_headers(h)}
}

// The address of a server ("http://127.0.0.1:4096").
server_url :: proc(cfg: Server_Config) -> string {
	scheme := cfg.tls ? "https" : "http"
	if cfg.port == 0 { return fmt.aprintf("%s://%s", scheme, cfg.host) }
	return fmt.aprintf("%s://%s:%d", scheme, cfg.host, cfg.port)
}
