package ocn

import "core:time"
import tk_http "gt:http"

// A socket as a thread uses it. (A test gives its own.)
Ws_Ops :: struct {
	open:  proc(h: ^Http, path: string) -> ^tk_http.Socket,
	recv:  proc(s: ^tk_http.Socket, wait: time.Duration) -> (tk_http.Message, tk_http.Error),
	send:  proc(s: ^tk_http.Socket, data: []u8) -> tk_http.Error,
	close: proc(s: ^tk_http.Socket),
}

WS_OPS :: Ws_Ops{
	open  = http_ws_open,
	recv  = proc(s: ^tk_http.Socket, wait: time.Duration) -> (tk_http.Message, tk_http.Error) { return tk_http.ws_recv(s, wait) },
	send  = proc(s: ^tk_http.Socket, data: []u8) -> tk_http.Error { return tk_http.ws_send(s, data) },
	close = tk_http.ws_close,
}

// What a socket's thread does while it is open: what waits goes out, between reads that wait at most `wait`; what comes is handed over. It
// returns when `going` says so, or when the socket goes. What follows, opening it again or not and why, is each one's own: a shell's server
// says whether it ended, a folder's tools just come back.
ws_pump :: proc(ops: Ws_Ops, ws: ^tk_http.Socket, wait: time.Duration, job: ^$T, going: proc(job: ^T) -> bool, flush: proc(job: ^T, ws: ^tk_http.Socket), frame: proc(job: ^T, text: string)) {
	for going(job) {
		flush(job, ws)
		m, err := ops.recv(ws, wait)
		if err == .Timed_Out { continue }   // (the read waited, a little: this is what sends come between)
		if err != .None || m.kind == .Close { return }
		frame(job, string(m.data))
	}
}
