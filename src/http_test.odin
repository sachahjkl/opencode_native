package ocn

import "base:runtime"
import "core:fmt"
import "core:net"
import "core:strings"
import "core:testing"
import "core:thread"
import "gt:flate"
import tk_http "gt:http"

// A server of one answer, on 127.0.0.1: it reads the request's head, sends `answer`, and closes.
@(private = "file")
One_Answer :: struct { socket: net.TCP_Socket, port: int, answer: string, head: string, thread: ^thread.Thread }

@(private = "file")
one_answer_start :: proc(t: ^testing.T, answer: string) -> ^One_Answer {
	s := new(One_Answer)
	s.answer = answer
	sock, err := net.listen_tcp({net.IP4_Loopback, 0})
	testing.expect(t, err == nil, "listen")
	s.socket = sock
	ep, _ := net.bound_endpoint(sock)
	s.port = ep.port
	s.thread = thread.create_and_start_with_poly_data(s, proc(s: ^One_Answer) {
		client, _, err := net.accept_tcp(s.socket)
		if err != nil { return }
		buf: [dynamic]u8
		chunk: [1024]u8
		for !strings.contains(string(buf[:]), "\r\n\r\n") {
			n, e := net.recv_tcp(client, chunk[:])
			if e != nil || n == 0 { break }
			append(&buf, ..chunk[:n])
		}
		s.head = string(buf[:])
		net.send_tcp(client, transmute([]u8)s.answer)
		net.close(client)
	})
	return s
}

@(private = "file")
one_answer_end :: proc(s: ^One_Answer) {
	// (shut down first: a client that never came leaves the thread in accept, which a close alone does not wake on Linux)
	net.shutdown(s.socket, .Both)
	net.close(s.socket)
	thread.join(s.thread)
	thread.destroy(s.thread)
	delete(s.head)
	free(s)
}

// Without this limit nothing ever comes to say a dead link is dead: a machine that slept leaves the socket open.
@(test)
the_event_stream_has_a_limit_on_silence :: proc(t: ^testing.T) {
	h := http_init("http://127.0.0.1:1/", "opencode", "secret")
	defer http_destroy(&h)
	r := http_stream_of(&h)
	testing.expect_value(t, r.timeout, STREAM_SILENCE)
	testing.expect_value(t, h.base, "http://127.0.0.1:1")
	testing.expect_value(t, len(r.headers), 1)
	testing.expect_value(t, r.headers[0].value, "Basic b3BlbmNvZGU6c2VjcmV0")   // (opencode:secret)
	free_all(context.temp_allocator)
}

@(test)
a_request_with_a_body_says_it_is_json :: proc(t: ^testing.T) {
	h := http_init("http://127.0.0.1:1", "opencode", "")
	defer http_destroy(&h)
	post := http_request_of(&h, "POST", "")
	get := http_request_of(&h, "GET", "")
	has_type :: proc(r: tk_http.Request) -> bool {
		for x in r.headers { if x.name == "Content-Type" { return x.value == "application/json" } }
		return false
	}
	testing.expect(t, has_type(post), "a POST, even empty")
	testing.expect(t, !has_type(get), "a GET has none")
	testing.expect_value(t, len(get.headers), 1)   // (Accept; no password, no Authorization)
	free_all(context.temp_allocator)
}

// A server's answers come compressed when it can, decoded for the views; the event stream is not compressed (an event
// must come when it happens). Each call gives up on a server that does not answer after CONNECT_TIMEOUT.
@(test)
the_answers_come_compressed :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	text := strings.repeat(`{"id":"ses_1","title":"a session"},`, 40, context.temp_allocator)
	zipped := flate.deflate(.Gzip, transmute([]u8)text, context.temp_allocator)
	s := one_answer_start(t, fmt.tprintf("HTTP/1.1 200 OK\r\nContent-Encoding: gzip\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s", len(zipped), string(zipped)))
	h := http_init(fmt.tprintf("http://127.0.0.1:%d", s.port), "opencode", "")
	status, body, ok := http_request(&h, "GET", "/session")
	testing.expect(t, ok)
	testing.expect_value(t, status, 200)
	testing.expect_value(t, body, text)
	head := strings.to_lower(s.head, context.temp_allocator)
	testing.expectf(t, strings.contains(head, "accept-encoding: gzip"), "asked for gzip: %q", s.head)
	delete(body)
	one_answer_end(s)
	stream, socket := http_stream_of(&h), http_socket_of(&h)
	testing.expect(t, !stream.compressed)
	for r in ([]tk_http.Request{http_request_of(&h, "GET", ""), stream, socket}) { testing.expect_value(t, r.connect_timeout, CONNECT_TIMEOUT) }
	http_destroy(&h)
	free_all(context.temp_allocator)
}

// The stream is up at its first event (the server opens each with server.connected), not before: a refusal says its status.
@(test)
the_stream_is_up_at_its_first_event :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	the_app = app
	defer the_app = nil
	c := app.conn

	refused := one_answer_start(t, "HTTP/1.1 401 Unauthorized\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
	c.http = http_init(fmt.tprintf("http://127.0.0.1:%d", refused.port), "opencode", "pw")
	app.link = .Retrying
	refused_status, _ := stream_run(c)
	testing.expect_value(t, refused_status, 401)
	bench_drain(app)
	testing.expect_value(t, app.link, Conn_State.Retrying)
	testing.expect(t, strings.contains(refused.head, "Authorization: Basic "), "the password goes with it")
	one_answer_end(refused)
	http_destroy(&c.http)

	up := one_answer_start(t, "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nConnection: close\r\n\r\n: hi\n\ndata: {\"type\":\"server.connected\",\"properties\":{}}\n\n")
	c.http = http_init(fmt.tprintf("http://127.0.0.1:%d", up.port), "opencode", "")
	up_status, _ := stream_run(c)
	testing.expect_value(t, up_status, 200)
	bench_drain(app)
	testing.expect_value(t, app.link, Conn_State.Online)
	one_answer_end(up)
	http_destroy(&c.http)
	free_all(context.temp_allocator)
}

// A stream that cannot start says why in the log once per reason: a link that never comes up (no libcurl, a refusal)
// left the log empty, since the requests wait for the stream.
@(test)
a_failing_stream_says_why_once :: proc(t: ^testing.T) {
	testing.expect(t, stream_reason_new(0, .No_Client, 0, .None), "the first failure")
	testing.expect(t, !stream_reason_new(0, .No_Client, 0, .No_Client), "the same again: nothing")
	testing.expect(t, stream_reason_new(401, .None, 0, .No_Client), "another reason")
	testing.expect(t, !stream_reason_new(200, .None, 0, .No_Client), "a stream that ended well")
}
