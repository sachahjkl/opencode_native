// HTTP and the server's event stream, over the client's Rust library (native/occ_native: ureq, rustls with the
// system's trust store; tools\build_native.ps1 -> build\native\occ_native.lib). Blocking calls, made from worker
// threads; one client for the whole program, shared by every thread.
package occ

import "core:fmt"
import "core:strings"

when ODIN_OS == .Windows {
	foreign import occ_native {
		"../build/native/occ_native.lib",
		"system:ws2_32.lib",
		"system:advapi32.lib",
		"system:userenv.lib",
		"system:ntdll.lib",
		"system:kernel32.lib",
		"system:bcrypt.lib",
		"system:crypt32.lib",
		"system:secur32.lib",
		"system:ole32.lib",
		"system:oleaut32.lib",
		"system:ncrypt.lib",
	}
} else {
	foreign import occ_native { "../build/native/libocc_native.a", "system:dl", "system:pthread", "system:m" }
}

Occ_Buf :: struct {
	ptr: [^]u8,
	len: uint,
	cap: uint,
}

@(default_calling_convention = "c")
foreign occ_native {
	occ_client_new :: proc(base: [^]u8, base_len: uint, user: [^]u8, user_len: uint, pass: [^]u8, pass_len: uint) -> rawptr ---
	occ_buf_free :: proc(b: Occ_Buf) ---
	occ_request :: proc(c: rawptr, method: [^]u8, method_len: uint, path: [^]u8, path_len: uint, body: [^]u8, body_len: uint, out_status: ^i32, out_body: ^Occ_Buf) -> i32 ---
	occ_sse_open :: proc(c: rawptr, path: [^]u8, path_len: uint, out_status: ^i32) -> rawptr ---
	occ_sse_next :: proc(s: rawptr, out: ^Occ_Buf) -> i32 ---
	occ_sse_free :: proc(s: rawptr) ---
	occ_image_decode :: proc(data: [^]u8, len: uint, base64: i32, max_dim: u32, out_w, out_h: ^u32, out: ^Occ_Buf) -> i32 ---   // (images.odin)
}

Http :: struct {
	base:   string,    // "http://host:port"
	client: rawptr,
}

http_init :: proc(h: ^Http, base: string, user, password: string) -> bool {
	h.base = strings.clone(base)
	h.client = occ_client_new(raw_data(base), len(base), raw_data(user), len(user), raw_data(password), len(password))
	return h.client != nil
}

@(private = "file")
take :: proc(b: Occ_Buf, allocator := context.allocator) -> string {
	if b.ptr == nil { return "" }
	s := strings.clone(string(b.ptr[:b.len]), allocator)
	occ_buf_free(b)
	return s
}

// A whole request: the response body is allocated with `allocator`. `ok` = false: the server was not reached (`resp`
// says why).
http_request :: proc(h: ^Http, method, path: string, body := "", allocator := context.allocator) -> (status: int, resp: string, ok: bool) {
	st: i32
	out: Occ_Buf
	r := occ_request(h.client, raw_data(method), len(method), raw_data(path), len(path), raw_data(body), len(body), &st, &out)
	return int(st), take(out, allocator), r == 0
}

// Server-sent events: calls `on_data` with the text of every event's data lines, until the stream ends, `stop` turns
// true or `on_data` returns false. Returns the status of the stream's response (0: the server was not reached).
http_sse :: proc(h: ^Http, path: string, stop: ^bool, on_data: proc(data: string, user: rawptr) -> bool, user: rawptr, connected: proc(user: rawptr) = nil) -> (status: int) {
	st: i32
	s := occ_sse_open(h.client, raw_data(path), len(path), &st)
	if s == nil { return int(st) }
	defer occ_sse_free(s)
	if connected != nil { connected(user) }
	for !stop^ {
		out: Occ_Buf
		if occ_sse_next(s, &out) != 1 { break }
		data := string(out.ptr[:out.len])
		keep := on_data(data, user)
		occ_buf_free(out)
		if !keep { break }
	}
	return int(st)
}

// The address of a server ("http://127.0.0.1:4096").
server_url :: proc(cfg: Server_Config) -> string {
	scheme := cfg.tls ? "https" : "http"
	if cfg.port == 0 { return fmt.aprintf("%s://%s", scheme, cfg.host) }
	return fmt.aprintf("%s://%s:%d", scheme, cfg.host, cfg.port)
}
