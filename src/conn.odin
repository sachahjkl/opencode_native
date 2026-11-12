// A connection to a server: its HTTP client, its transport, its workers, its event thread. It is freed when nothing uses it any
// more: the App lets go of it when another server is chosen, and each request, each thread that reads it holds it until its end
// (Conn.holders). The last to let go hands it to the App's chores, which stop and join its workers and close its client: the
// interface never waits for that.
package ocn

import "core:mem"
import "core:sync"
import "gt:ui"

Conn :: struct {
	app:       ^App,      // (for its threads: the_app is the interface's)
	http:      Http,
	transport: Transport,
	pool:      Work_Pool,   // its requests' workers
	stop:      bool,      // (atomic) its threads stop: the event thread at its next event or retry, a shell's at its next read
	// What uses it, on the interface's thread only: the App while it is the one connected, each request until its answer ran, each
	// thread that reads it until its last post ran. A thread lets go by a post: what it posted before, with this pointer in it, has run
	// by then, and no newer Conn at the same address can be taken for it.
	holders:   int,
	browser:   ^Browser_Link,           // the agents' browser tools on this connection, while they are wanted (browser_mcp.odin)
	browsers_left: [dynamic]^Browser_Link,   // ... in the folders one left while an agent works there
}

// Requests are short reads, mostly: stream_up asks for about fifteen at once, which a server answers four at a time faster than a
// frame. Not more: each is a thread and a socket to the server. Not fewer: a slow one (a large file, an export) leaves three for the rest.
CONN_WORKERS :: 4

// How a connection's calls reach its server. The program's is HTTP (HTTP_TRANSPORT); a test's keeps the requests for the test to answer
// (answers_test.odin), with the same path around it.
Transport :: struct {
	// A request: its status, its body, whether the server was reached. `done` false: the transport keeps it and ends it later with
	// request_finish.
	call:    proc(c: ^Conn, r: ^Request) -> (done: bool),
	// A call that is no request (the schema, a shell's list): what came back.
	fetch:   proc(c: ^Conn, method, path, body: string, allocator: mem.Allocator) -> (status: int, resp: string, ok: bool),
	// A shell's socket (nil: this transport has none, no shell's thread starts).
	ws_open: proc "c" (client: rawptr, path: [^]u8, path_len: uint) -> rawptr,
	close:   proc(c: ^Conn),   // the connection is freed: what the transport holds goes
}

HTTP_TRANSPORT :: Transport{call = http_call, fetch = http_fetch, ws_open = ocn_ws_open, close = http_close}

@(private = "file")
http_call :: proc(c: ^Conn, r: ^Request) -> bool {
	r.status, r.resp, r.ok = http_request(&c.http, r.method, r.path, r.body)
	return true
}

@(private = "file")
http_fetch :: proc(c: ^Conn, method, path, body: string, allocator: mem.Allocator) -> (status: int, resp: string, ok: bool) {
	return http_request(&c.http, method, path, body, allocator)
}

@(private = "file")
http_close :: proc(c: ^Conn) {
	if c.http.client != nil { ocn_client_free(c.http.client) }
	delete(c.http.base)
}

// A connection held once, by whoever made it; its workers are started.
conn_make :: proc(app: ^App, http: Http, transport: Transport, workers: int, clock: ^i64 = nil) -> ^Conn {
	c := new(Conn)
	c^ = {app = app, http = http, transport = transport, holders = 1}
	pool_init(&c.pool, workers, clock)
	append(&app.cx.conns, c)
	return c
}

conn_hold :: proc(c: ^Conn) { c.holders += 1 }

// (On the interface's thread.)
conn_release :: proc(app: ^App, c: ^Conn) {
	if c == nil { return }
	c.holders -= 1
	if c.holders > 0 { return }
	for x, i in app.cx.conns { if x == c { unordered_remove(&app.cx.conns, i); break } }
	pool_add(&app.cx.chores, conn_free_work, c)
}

// From a thread that held it: its posts run first (Conn.holders). A post refused (the program ends) keeps it.
conn_release_post :: proc(c: ^Conn) {
	ui.post(&c.app.state, proc(data: rawptr, word: u64) {
		c := (^Conn)(data)
		conn_release(c.app, c)
	}, c)
}

// Its threads are told to stop: a server left, the window closed.
conn_stop :: proc(c: ^Conn) { sync.atomic_store(&c.stop, true) }

// On a chore: nothing holds it, its workers rest and are joined.
@(private = "file")
conn_free_work :: proc(data: rawptr) { conn_free((^Conn)(data)) }

conn_free :: proc(c: ^Conn) {
	pool_stop(&c.pool)
	c.transport.close(c)
	delete(c.browsers_left)
	free(c)
}

// The App's own chores: one thread, so that they keep their order (a list saved, then a password forgotten under its old name).
CHORES_WORKERS :: 1
