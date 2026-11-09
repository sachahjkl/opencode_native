package ocn

// A socket as a thread uses it. (A test gives its own.)
Ws_Ops :: struct {
	open:         proc "c" (c: rawptr, path: [^]u8, path_len: uint) -> rawptr,
	read:         proc "c" (w: rawptr, out: ^Ocn_Buf) -> i32,
	send:         proc "c" (w: rawptr, data: [^]u8, n: uint) -> i32,
	read_timeout: proc "c" (w: rawptr, ms: u32),
	free:         proc "c" (w: rawptr),
}

WS_OPS :: Ws_Ops{ocn_ws_open, ocn_ws_read, ocn_ws_send, ocn_ws_read_timeout, ocn_ws_free}

// What a socket's thread does while it is open: what waits goes out, between reads that wait a little; what comes is handed over. It returns when
// `going` says so, or when the socket goes. What follows, opening it again or not and why, is each one's own: a shell's server says whether it
// ended, a folder's tools just come back.
ws_pump :: proc(ops: Ws_Ops, ws: rawptr, job: ^$T, going: proc(job: ^T) -> bool, flush: proc(job: ^T, ws: rawptr), frame: proc(job: ^T, text: string)) {
	for going(job) {
		flush(job, ws)
		out: Ocn_Buf
		r := ops.read(ws, &out)
		if r < 0 { return }
		if r == 0 { continue }   // (the read waited, a little: this is what sends come between)
		frame(job, string(out.ptr[:out.len]))
		ocn_buf_free(out)
	}
}
