package occtools

// A client of the toolkit's devtools (Chrome DevTools Protocol, the toolkit's devtools package): one connection for a whole run.
// What ext/gui_toolkit/tools/cdp_client.mjs does, without a process per gesture.

import "core:encoding/base64"
import "core:encoding/json"
import "core:fmt"
import "core:net"
import "core:os"
import "core:strings"
import "core:time"

DT_READ_LIMIT :: 75 * time.Second   // (above what any wait asks of the window: it answers at its own timeout)
DT_CHUNK      :: 64 * 1024
DT_ACK_ID     :: -1   // (no call waits for it)
WS_TEXT       :: 1
WS_CLOSE      :: 8
WS_PING       :: 9
WS_PONG       :: 10

Dt :: struct {
	sock:    net.TCP_Socket,
	next_id: int,
	buf:     [dynamic]byte,
	// (a film: where the frames go, and what came)
	cast_dir:   string,
	cast_names: [dynamic]string,
	cast_times: [dynamic]f64,
}

Box :: struct {
	name, text: string,
	x, y, w, h: f64,
}

// One frame of what a client sends: masked, as the protocol wants it.
ws_encode :: proc(opcode: u8, payload: []byte, mask: [4]byte, allocator := context.allocator) -> []byte {
	out := make([dynamic]byte, 0, len(payload) + 14, allocator)
	append(&out, 0x80 | opcode)
	n := len(payload)
	switch {
	case n < 126:
		append(&out, 0x80 | u8(n))
	case n < 65536:
		append(&out, 0x80 | 126, u8(n >> 8), u8(n))
	case:
		append(&out, 0x80 | 127)
		for shift := 56; shift >= 0; shift -= 8 { append(&out, u8(u64(n) >> uint(shift))) }
	}
	append(&out, mask[0], mask[1], mask[2], mask[3])
	for b, i in payload { append(&out, b ~ mask[i % 4]) }
	return out[:]
}

// The first frame of `buf`, a server's (not masked). !complete: more bytes are needed.
ws_decode :: proc(buf: []byte) -> (opcode: u8, fin: bool, payload: []byte, used: int, complete: bool) {
	if len(buf) < 2 { return }
	opcode, fin = buf[0] & 0x0f, buf[0] & 0x80 != 0
	n := int(buf[1] & 0x7f)
	at := 2
	switch n {
	case 126:
		if len(buf) < 4 { return }
		n = int(buf[2]) << 8 | int(buf[3])
		at = 4
	case 127:
		if len(buf) < 10 { return }
		n = 0
		for i in 2 ..< 10 { n = n << 8 | int(buf[i]) }
		at = 10
	}
	if len(buf) < at + n { return }
	return opcode, fin, buf[at:at + n], at + n, true
}

json_text :: proc(s: string) -> string {
	data, err := json.marshal(s, allocator = context.temp_allocator)
	return err == nil ? string(data) : `""`
}

// An answer to the call `id`? Its result, or its error's message.
dt_answer :: proc(text: string, id: int) -> (result: json.Value, failure: string, mine: bool) {
	v, err := json.parse(transmute([]byte)text)
	if err != nil { return nil, "", false }
	o, is_object := v.(json.Object)
	if !is_object { return nil, "", false }
	n, has_id := json_int(o["id"])
	if !has_id || n != id { return nil, "", false }
	if e, failed := o["error"].(json.Object); failed {
		message, _ := e["message"].(json.String)
		return nil, message != "" ? message : "an error", true
	}
	return o["result"], "", true
}

json_int :: proc(v: json.Value) -> (int, bool) {
	#partial switch n in v {
	case json.Integer: return int(n), true
	case json.Float:   return int(n), true
	}
	return 0, false
}

json_num :: proc(v: json.Value) -> f64 {
	#partial switch n in v {
	case json.Integer: return f64(n)
	case json.Float:   return f64(n)
	}
	return 0
}

dt_connect :: proc(port: int) -> (d: Dt, ok: bool) {
	here := net.Endpoint{address = net.IP4_Loopback, port = port}
	status, body, got := http_at(here, "GET", "/json/list", "")
	if !got || status != 200 { return }
	Target :: struct {
		webSocketDebuggerUrl: string,
	}
	targets: []Target
	if json.unmarshal(transmute([]byte)body, &targets) != nil || len(targets) == 0 { return }
	url := targets[0].webSocketDebuggerUrl
	slash := strings.index(url[min(len("ws://"), len(url)):], "/")
	if slash < 0 { return }
	path := url[len("ws://") + slash:]

	sock, err := net.dial_tcp_from_endpoint(here)
	if err != nil { return }
	_ = net.set_option(sock, .Receive_Timeout, DT_READ_LIMIT)
	d.sock = sock
	head := fmt.tprintf("GET %s HTTP/1.1\r\nHost: 127.0.0.1:%d\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: b2NjdG9vbHMgb2NjdG9vbHM=\r\nSec-WebSocket-Version: 13\r\n\r\n", path, port)
	if _, e := net.send_tcp(sock, transmute([]byte)head); e != nil { net.close(sock); return }
	for {
		end := strings.index(string(d.buf[:]), "\r\n\r\n")
		if end >= 0 {
			if !strings.contains(string(d.buf[:end]), " 101 ") { net.close(sock); return }
			remove_range(&d.buf, 0, end + 4)
			return d, true
		}
		if !dt_read(&d) { net.close(sock); return }
	}
}

@(private = "file")
dt_read :: proc(d: ^Dt) -> bool {
	chunk: [DT_CHUNK]byte
	n, err := net.recv_tcp(d.sock, chunk[:])
	if err != nil || n == 0 { return false }
	append(&d.buf, ..chunk[:n])
	return true
}

@(private = "file")
dt_write :: proc(d: ^Dt, opcode: u8, payload: []byte) -> bool {
	_, err := net.send_tcp(d.sock, ws_encode(opcode, payload, {0x6f, 0x63, 0x63, 0x74}, context.temp_allocator))
	return err == nil
}

// The next whole message.
@(private = "file")
dt_message :: proc(d: ^Dt) -> (text: string, ok: bool) {
	whole := make([dynamic]byte)
	for {
		opcode, fin, payload, used, complete := ws_decode(d.buf[:])
		if !complete {
			if !dt_read(d) { delete(whole); return "", false }
			continue
		}
		switch opcode {
		case WS_CLOSE:
			delete(whole)
			return "", false
		case WS_PING:
			dt_write(d, WS_PONG, payload)
		case WS_PONG:
		case:
			append(&whole, ..payload)
		}
		remove_range(&d.buf, 0, used)
		if fin && opcode != WS_PING && opcode != WS_PONG { return string(whole[:]), true }
	}
}

// `params`: a JSON object. What the window answers; a failure is said here, once.
dt_call :: proc(d: ^Dt, method: string, params := "{}") -> (result: json.Value, ok: bool) {
	d.next_id += 1
	message := fmt.tprintf(`{{"id":%d,"method":%s,"params":%s}}`, d.next_id, json_text(method), params)
	if !dt_write(d, WS_TEXT, transmute([]byte)message) { fmt.eprintfln("%s: the window is gone", method); return nil, false }
	for {
		text, got := dt_message(d)
		if !got { fmt.eprintfln("%s: the connection ended", method); return nil, false }
		r, failure, mine := dt_answer(text, d.next_id)
		if !mine { dt_event(d, text) }
		delete(text)
		if !mine { continue }
		if failure != "" { fmt.eprintfln("%s: %s", method, failure); return nil, false }
		return r, true
	}
}

// A frame of a film: kept, and acknowledged, or none follows.
@(private = "file")
dt_event :: proc(d: ^Dt, text: string) {
	if d.cast_dir == "" || !strings.contains(text[:min(len(text), 64)], "Page.screencastFrame") { return }
	v, err := json.parse(transmute([]byte)text)
	if err != nil { return }
	defer json.destroy_value(v)
	o, _ := v.(json.Object)
	p, _ := o["params"].(json.Object)
	m, _ := p["metadata"].(json.Object)
	data, _ := p["data"].(json.String)
	id, _ := json_int(p["sessionId"])
	png, decode_err := base64.decode(data)
	if decode_err != nil { return }
	defer delete(png)
	name := fmt.aprintf("frame-%06d.png", len(d.cast_names))
	if os.write_entire_file(fmt.tprintf("%s/%s", d.cast_dir, name), png) != nil { return }
	append(&d.cast_names, name)
	append(&d.cast_times, json_num(m["timestamp"]))
	dt_write(d, WS_TEXT, transmute([]byte)fmt.tprintf(`{{"id":%d,"method":"Page.screencastFrameAck","params":{{"sessionId":%d}}}}`, DT_ACK_ID, id))
}

dt_close :: proc(d: ^Dt) { net.close(d.sock) }

dt_find :: proc(d: ^Dt, text: string) -> []Box {
	r, ok := dt_call(d, "Toolkit.find", fmt.tprintf(`{{"text":%s}}`, json_text(text)))
	if !ok { return nil }
	o, _ := r.(json.Object)
	nodes, _ := o["nodes"].(json.Array)
	out := make([]Box, len(nodes), context.temp_allocator)
	for n, i in nodes {
		b, _ := n.(json.Object)
		name, _ := b["name"].(json.String)
		value, _ := b["text"].(json.String)
		out[i] = {name, value, json_num(b["x"]), json_num(b["y"]), json_num(b["w"]), json_num(b["h"])}
	}
	return out
}

dt_has :: proc(d: ^Dt, text: string) -> bool { return len(dt_find(d, text)) > 0 }

// Until the text is there (or gone): the window waits, nothing here sleeps.
dt_wait_for :: proc(d: ^Dt, text: string, limit: time.Duration, gone := false) -> bool {
	_, ok := dt_call(d, "Toolkit.waitFor", fmt.tprintf(`{{"text":%s,"gone":%v,"timeout":%d}}`, json_text(text), gone, int(time.duration_milliseconds(limit))))
	return ok
}

dt_wait_name :: proc(d: ^Dt, name: string, limit: time.Duration) -> bool {
	_, ok := dt_call(d, "Toolkit.waitFor", fmt.tprintf(`{{"name":%s,"timeout":%d}}`, json_text(name), int(time.duration_milliseconds(limit))))
	return ok
}

dt_click_name :: proc(d: ^Dt, name: string) -> bool {
	_, ok := dt_call(d, "Toolkit.click", fmt.tprintf(`{{"name":%s,"index":0,"count":1,"button":"left"}}`, json_text(name)))
	return ok
}

dt_type :: proc(d: ^Dt, text: string) -> bool {
	_, ok := dt_call(d, "Input.insertText", fmt.tprintf(`{{"text":%s}}`, json_text(text)))
	return ok
}

KEY_ALT   :: 1
KEY_CTRL  :: 2
KEY_META  :: 4
KEY_SHIFT :: 8

// "ctrl+shift+t": the key, its modifiers, the text it types.
key_parts :: proc(name: string) -> (key: string, mods: int, text: string) {
	parts := strings.split(name, "+", context.temp_allocator)
	for p in parts[:len(parts) - 1] {
		switch strings.to_lower(p, context.temp_allocator) {
		case "alt":             mods |= KEY_ALT
		case "ctrl", "control": mods |= KEY_CTRL
		case "meta":            mods |= KEY_META
		case "shift":           mods |= KEY_SHIFT
		}
	}
	key = parts[len(parts) - 1]
	switch strings.to_lower(key, context.temp_allocator) {
	case "enter":  key = "Enter"
	case "tab":    key = "Tab"
	case "escape": key = "Escape"
	case "space":  key = " "
	}
	if len(key) == 1 && mods & KEY_CTRL == 0 { text = key }
	return
}

dt_key :: proc(d: ^Dt, name: string) -> bool {
	key, mods, text := key_parts(name)
	_, down := dt_call(d, "Input.dispatchKeyEvent", fmt.tprintf(`{{"type":"keyDown","key":%s,"text":%s,"modifiers":%d}}`, json_text(key), json_text(text), mods))
	_, up := dt_call(d, "Input.dispatchKeyEvent", fmt.tprintf(`{{"type":"keyUp","key":%s,"modifiers":%d}}`, json_text(key), mods))
	return down && up
}

// The window's pixels in a PNG.
dt_shot :: proc(d: ^Dt, path: string) -> bool {
	r, ok := dt_call(d, "Page.captureScreenshot", `{"format":"png"}`)
	if !ok { return false }
	o, _ := r.(json.Object)
	data, _ := o["data"].(json.String)
	png, err := base64.decode(data, allocator = context.temp_allocator)
	if err != nil { return false }
	return os.write_entire_file(path, png) == nil
}
