package occtools

import "core:net"
import "core:testing"

@(test)
a_frame_comes_back_as_it_left :: proc(t: ^testing.T) {
	for size in ([]int{0, 5, 125, 126, 65535, 65536}) {
		payload := make([]byte, size, context.temp_allocator)
		for i in 0 ..< size { payload[i] = byte(i) }
		sent := ws_encode(WS_TEXT, payload, {1, 2, 3, 4}, context.temp_allocator)
		// (a server's frame is this one without the mask: strip it, and undo it)
		at := size < 126 ? 2 : (size < 65536 ? 4 : 10)
		plain := make([dynamic]byte, context.temp_allocator)
		append(&plain, sent[0], sent[1] & 0x7f)
		append(&plain, ..sent[2:at])
		mask := [4]byte{1, 2, 3, 4}
		for b, i in sent[at + 4:] { append(&plain, b ~ mask[i % 4]) }
		opcode, fin, got, used, complete := ws_decode(plain[:])
		testing.expect(t, complete && fin)
		testing.expect_value(t, opcode, u8(WS_TEXT))
		testing.expect_value(t, used, len(plain))
		testing.expect_value(t, string(got), string(payload))
	}
}

@(test)
half_a_frame_waits_for_the_rest :: proc(t: ^testing.T) {
	_, _, _, _, complete := ws_decode({0x81, 5, 'h', 'e'})
	testing.expect(t, !complete)
	_, _, _, _, complete = ws_decode({0x81})
	testing.expect(t, !complete)
}

@(test)
an_answer_is_the_one_of_its_call :: proc(t: ^testing.T) {
	_, _, mine := dt_answer(`{"method":"Page.frame","params":{}}`, 3)
	testing.expect(t, !mine, "an event")
	_, _, mine = dt_answer(`{"id":2,"result":{}}`, 3)
	testing.expect(t, !mine, "another call")
	_, failure, mine2 := dt_answer(`{"id":3,"error":{"code":1,"message":"no such box"}}`, 3)
	testing.expect(t, mine2)
	testing.expect_value(t, failure, "no such box")
}

@(test)
a_key_by_its_name :: proc(t: ^testing.T) {
	key, mods, text := key_parts("ctrl+shift+t")
	testing.expect_value(t, key, "t")
	testing.expect_value(t, mods, KEY_CTRL | KEY_SHIFT)
	testing.expect_value(t, text, "")
	key, mods, text = key_parts("Enter")
	testing.expect_value(t, key, "Enter")
	testing.expect_value(t, mods, 0)
	key, _, text = key_parts("a")
	testing.expect_value(t, text, "a")
}

@(test)
a_response_with_chunks_or_without :: proc(t: ^testing.T) {
	status, body, ok := http_parse("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nhi")
	testing.expect(t, ok)
	testing.expect_value(t, status, 200)
	testing.expect_value(t, body, "hi")
	status, body, ok = http_parse("HTTP/1.1 204 No Content\r\n\r\n")
	testing.expect(t, ok)
	testing.expect_value(t, status, 204)
	status, body, ok = http_parse("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n3\r\nabc\r\n2\r\nde\r\n0\r\n\r\n")
	testing.expect(t, ok)
	testing.expect_value(t, body, "abcde")
	_, _, ok = http_parse("nonsense")
	testing.expect(t, !ok)
}

// What clean removes is decided here: what was there before stays, whatever it is.
@(test)
only_what_is_new_is_taken_for_ours :: proc(t: ^testing.T) {
	fresh := new_ids({"a", "b"}, {"a", "b", "c"})
	testing.expect_value(t, len(fresh), 1)
	testing.expect_value(t, fresh[0], "c")
	testing.expect_value(t, len(new_ids({"a", "b"}, {"a"})), 0)
	testing.expect_value(t, len(new_ids({"a"}, nil)), 0)
}

@(test)
a_snapshot_reads_as_it_was_written :: proc(t: ^testing.T) {
	ptys, sessions := snapshot_read(snapshot_text({"p1", "p2"}, {"s1"}))
	testing.expect_value(t, len(ptys), 2)
	testing.expect_value(t, ptys[1], "p2")
	testing.expect_value(t, len(sessions), 1)
	testing.expect_value(t, sessions[0], "s1")
}

@(test)
the_middle_of_some_runs :: proc(t: ^testing.T) {
	testing.expect_value(t, median({3, 1, 2}), 2.0)
	testing.expect_value(t, median({4, 1, 2, 3}), 2.5)
	testing.expect_value(t, median({}), 0.0)
}

@(test)
a_frame_is_held_until_the_next_one :: proc(t: ^testing.T) {
	list := concat_list({"a.png", "b.png"}, {10, 10.25})
	testing.expect_value(t, list, "ffconcat version 1.0\nfile a.png\nduration 0.2500\nfile b.png\nduration 1.0000\nfile b.png\n")
}

@(test)
the_server_lists_in_two_shapes :: proc(t: ^testing.T) {
	testing.expect_value(t, len(ids_of(`{"data":[{"id":"a"},{"id":"b"}]}`)), 2)
	testing.expect_value(t, len(ids_of(`[{"id":"a"}]`)), 1)
	testing.expect_value(t, len(ids_of("not json")), 0)
}

// The proxy on real sockets, nothing to wait for: a connection goes through, and drop ends it at once.
@(test)
the_proxy_passes_and_cuts :: proc(t: ^testing.T) {
	listener, err := net.listen_tcp({address = net.IP4_Loopback, port = 0})
	testing.expect(t, err == nil)
	defer net.close(listener)
	target, _ := net.bound_endpoint(listener)
	p, ok := proxy_start(target)
	testing.expect(t, ok)
	client, dial_err := net.dial_tcp_from_endpoint(net.Endpoint{address = net.IP4_Loopback, port = p.port})
	testing.expect(t, dial_err == nil)
	defer net.close(client)
	server, _, accept_err := net.accept_tcp(listener)
	testing.expect(t, accept_err == nil)
	defer net.close(server)

	_, _ = net.send_tcp(client, transmute([]byte)string("ping"))
	buf: [8]byte
	n, _ := net.recv_tcp(server, buf[:])
	testing.expect_value(t, string(buf[:n]), "ping")
	testing.expect_value(t, proxy_opened(p), 1)

	proxy_drop(p)
	n, _ = net.recv_tcp(client, buf[:])
	testing.expect_value(t, n, 0)
}
