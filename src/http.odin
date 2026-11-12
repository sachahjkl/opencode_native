// HTTP and the server's event stream, over the client's Rust library (native/ocn_native: ureq, rustls with the
// system's trust store; ocntools build -> build\native\ocn_native.lib). Blocking calls, made from worker
// threads; one client for the whole program, shared by every thread.
package ocn

import "core:fmt"
import "core:strings"

when ODIN_OS == .Windows {
	foreign import ocn_native {
		"../build/native/ocn_native.lib",
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
	foreign import ocn_native { "../build/native/libocn_native.a", "system:dl", "system:pthread", "system:m" }
}

Ocn_Buf :: struct {
	ptr: [^]u8,
	len: uint,
	cap: uint,
}

@(default_calling_convention = "c")
foreign ocn_native {
	ocn_client_new :: proc(base: [^]u8, base_len: uint, user: [^]u8, user_len: uint, pass: [^]u8, pass_len: uint) -> rawptr ---
	ocn_client_free :: proc(c: rawptr) ---
	ocn_buf_free :: proc(b: Ocn_Buf) ---
	ocn_request :: proc(c: rawptr, method: [^]u8, method_len: uint, path: [^]u8, path_len: uint, body: [^]u8, body_len: uint, out_status: ^i32, out_body: ^Ocn_Buf) -> i32 ---
	ocn_sse_open :: proc(c: rawptr, path: [^]u8, path_len: uint, out_status: ^i32) -> rawptr ---
	ocn_sse_next :: proc(s: rawptr, out: ^Ocn_Buf) -> i32 ---
	ocn_sse_free :: proc(s: rawptr) ---
	ocn_image_decode :: proc(data: [^]u8, len: uint, base64: i32, max_dim: u32, out_w, out_h: ^u32, out: ^Ocn_Buf) -> i32 ---   // (images.odin)
	ocn_ws_open :: proc(c: rawptr, path: [^]u8, path_len: uint) -> rawptr ---   // (browser_mcp.odin)
	ocn_ws_read :: proc(w: rawptr, out: ^Ocn_Buf) -> i32 ---
	ocn_ws_send :: proc(w: rawptr, data: [^]u8, n: uint) -> i32 ---
	ocn_ws_read_timeout :: proc(w: rawptr, ms: u32) ---   // (terminal.odin)
	ocn_ws_free :: proc(w: rawptr) ---
}

when ODIN_OS == .Windows {
	Web_Callback :: proc "c" (user: rawptr, kind: i32, id: u64, data: [^]u8, n: uint)

	@(default_calling_convention = "c")
	foreign ocn_native {   // (webview_windows.odin)
		ocn_webview_new :: proc(parent: int, data: [^]u8, data_len: uint, cb: Web_Callback, user: rawptr) -> rawptr ---
		ocn_webview_parent :: proc(w: rawptr, hwnd: int) ---
	ocn_webview_place :: proc(w: rawptr, x, y, width, height, visible: i32) ---
		ocn_webview_navigate :: proc(w: rawptr, url: [^]u8, n: uint) ---
		ocn_webview_act :: proc(w: rawptr, what: i32) ---
		ocn_webview_script :: proc(w: rawptr, code: [^]u8, n: uint, id: u64) ---
		ocn_webview_capture :: proc(w: rawptr, id: u64) ---
		ocn_webview_can :: proc(w: rawptr, what: i32) -> i32 ---
		ocn_webview_free :: proc(w: rawptr) ---
	}
}

Http :: struct {
	base:   string,    // "http://host:port"
	client: rawptr,
}

http_init :: proc(h: ^Http, base: string, user, password: string) -> bool {
	h.base = strings.clone(base)
	h.client = ocn_client_new(raw_data(base), len(base), raw_data(user), len(user), raw_data(password), len(password))
	return h.client != nil
}

@(private = "file")
take :: proc(b: Ocn_Buf, allocator := context.allocator) -> string {
	if b.ptr == nil { return "" }
	s := strings.clone(string(b.ptr[:b.len]), allocator)
	ocn_buf_free(b)
	return s
}

// A whole request: the response body is allocated with `allocator`. `ok` = false: the server was not reached (`resp`
// says why).
http_request :: proc(h: ^Http, method, path: string, body := "", allocator := context.allocator) -> (status: int, resp: string, ok: bool) {
	st: i32
	out: Ocn_Buf
	r := ocn_request(h.client, raw_data(method), len(method), raw_data(path), len(path), raw_data(body), len(body), &st, &out)
	return int(st), take(out, allocator), r == 0
}

// Server-sent events: calls `on_data` with the text of every event's data lines, until the stream ends, `stop` turns
// true or `on_data` returns false. Returns the status of the stream's response (0: the server was not reached).
http_sse :: proc(h: ^Http, path: string, stop: ^bool, on_data: proc(data: string, user: rawptr) -> bool, user: rawptr, connected: proc(user: rawptr) = nil) -> (status: int) {
	st: i32
	s := ocn_sse_open(h.client, raw_data(path), len(path), &st)
	if s == nil { return int(st) }
	defer ocn_sse_free(s)
	if connected != nil { connected(user) }
	for !stop^ {
		out: Ocn_Buf
		if ocn_sse_next(s, &out) != 1 { break }
		data := string(out.ptr[:out.len])
		keep := on_data(data, user)
		ocn_buf_free(out)
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
