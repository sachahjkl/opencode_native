// A server's requests, its event stream and its sockets, over the toolkit's gt:http (WinHTTP, libcurl). Every call
// blocks: workers and the stream's and sockets' threads make them, never the interface's. src/md/infrastructure/transport.md
// says why the limits are these.
package ocn

import "core:encoding/base64"
import "core:fmt"
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

// What a request to the server takes: its headers (`json`: a JSON body goes with it), its limits.
http_request_of :: proc(h: ^Http, method, body: string) -> tk_http.Request {
	json := body != "" || method == "POST" || method == "PUT" || method == "PATCH"
	headers := json ? http_headers(h, {"Accept", "application/json"}, {"Content-Type", "application/json"}) : http_headers(h, {"Accept", "application/json"})
	return {max_bytes = REQUEST_MAX_BYTES, user_agent = USER_AGENT, timeout = REQUEST_TIMEOUT, headers = headers, body = body == "" ? nil : transmute([]u8)body}
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

// What the event stream takes: no limit of its own but its silence.
http_stream_of :: proc(h: ^Http) -> tk_http.Request {
	return {user_agent = USER_AGENT, timeout = STREAM_SILENCE, headers = http_headers(h)}
}

// Reads the event stream at `path` until it ends, `on_event` says .Stop or `stop` is asked. Returns the status of its
// response (0: the server was not reached).
http_events :: proc(h: ^Http, path: string, stop: ^tk_http.Stop, on_event: tk_http.Event_Proc, user: rawptr) -> (status: int) {
	st, _ := tk_http.events(strings.concatenate({h.base, path}, context.temp_allocator), http_stream_of(h), on_event, user, stop)
	return st
}

// A socket at `path` on the server (ws:// or wss://, as the server's scheme); nil: none.
http_ws_open :: proc(h: ^Http, path: string) -> ^tk_http.Socket {
	scheme, rest := "ws", h.base
	switch {
	case strings.has_prefix(rest, "https://"): scheme, rest = "wss", rest[len("https://"):]
	case strings.has_prefix(rest, "http://"):  rest = rest[len("http://"):]
	}
	url := fmt.tprintf("%s://%s%s", scheme, rest, path)
	s, err := tk_http.ws_connect(url, {user_agent = USER_AGENT, timeout = SOCKET_TIMEOUT, headers = http_headers(h)})
	return err == .None ? s : nil
}

// The address of a server ("http://127.0.0.1:4096").
server_url :: proc(cfg: Server_Config) -> string {
	scheme := cfg.tls ? "https" : "http"
	if cfg.port == 0 { return fmt.aprintf("%s://%s", scheme, cfg.host) }
	return fmt.aprintf("%s://%s:%d", scheme, cfg.host, cfg.port)
}
