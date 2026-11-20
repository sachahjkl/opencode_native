// The thumbnails of the server's pictures, for the file browser's cards: the file's bytes by the download's transport on
// workers of their own, decoded and reduced there, answered on the interface's thread. src/md/features/server-thumbnails.md
// says why it is made this way.
package ocn

import "base:runtime"
import "core:strings"
import "core:sync"
import "core:time"
import tk_http "gt:http"
import img "gt:image"
import tasks "gt:tasks"
import "gt:ui"

// Pictures that come at once: a third waits in the pool's queue.
SERVER_THUMB_WORKERS :: 2
// A larger picture gets no thumbnail: its bytes are kept in memory until the decode.
SERVER_THUMB_MAX_BYTES :: 20 << 20
// How long the program's end waits for the thumbnails' workers to see their stop.
SERVER_THUMB_STOP_BOUND :: 3 * time.Second

Server_Thumbs :: struct {
	pool:    tasks.Pool,
	started: bool,
	jobs:    [dynamic]^Server_Thumb,   // asked and not answered (the interface's)
}

// One ask, from the interface to a worker and back.
Server_Thumb :: struct {
	app:     ^App,
	conn:    ^Conn,           // held until its answer
	reply:   ui.File_Reply,
	read:    string,          // the GET's path and query (heap)
	side:    int,
	stop:    tk_http.Stop,    // asked by a server switch, or the program's end
	// written by its worker before it posts its answer
	bytes:   [dynamic]u8,     // (heap) what came, until the decode
	too_big: bool,
	rgba:    []u8,            // (heap) nil: answered failed
	width:   int,
	height:  int,
}

// Where a worker is: a test sees each step on the thread that makes it, never the interface's. nil: none.
Server_Thumb_Step :: enum u8 { Fetch, Decode }
server_thumb_hook: proc(step: Server_Thumb_Step)

// A test reads the answers here instead of the toolkit's cache (on the interface's thread). nil: the toolkit's.
@(thread_local) server_thumb_answer_hook: proc(reply: ui.File_Reply, rgba: []u8, width, height: int)

// File_Source.thumbnail of the server's files: a picture gt:image decodes, in the session's folder, is fetched; any
// other file is answered at once (its card keeps its kind's icon).
server_thumbnail :: proc(src: ^ui.File_Source, path: string, px: int, reply: ui.File_Reply) {
	app := (^App)(src.user)
	f := &app.server_files
	rel, inside := server_files_within(f, path)
	c := app.conn
	if !inside || rel == "" || !ui.file_thumbnail_decodes(path) || c == nil || c.transport.receive == nil {
		server_thumb_answer(reply, nil, 0, 0)
		return
	}
	ts := &f.thumbs
	if !ts.started {
		tasks.start(&ts.pool, {threads = SERVER_THUMB_WORKERS, newest_first = true})
		ts.started = true
	}
	h := runtime.heap_allocator()
	j := new(Server_Thumb, h)
	j^ = {app = app, conn = c, reply = reply, read = strings.clone(download_read_path(f.location, rel), h), side = max(px, 1)}
	conn_hold(c)
	append(&ts.jobs, j)
	if !tasks.add(&ts.pool, server_thumb_work, j) { server_thumb_done(j, 0) }
}

// The jobs of the server left end at their next chunk; each is still answered, by its post.
server_thumbs_forget :: proc(app: ^App) {
	for j in app.server_files.thumbs.jobs { tk_http.stop_ask(&j.stop) }
}

// The program's end: every job stops, the workers are waited for within `bound`.
server_thumbs_stop :: proc(app: ^App, bound := SERVER_THUMB_STOP_BOUND) {
	ts := &app.server_files.thumbs
	if !ts.started { return }
	server_thumbs_forget(app)
	_ = tasks.stop(&ts.pool, bound = bound)
	ts.started = false
}

////////////////////////////////
// On its worker

@(private = "file")
server_thumb_work :: proc(data: rawptr) {
	j := (^Server_Thumb)(data)
	// (the pool's context is the one it started in, a test's tracker maybe: what this thread allocates is the heap's)
	context.allocator = runtime.heap_allocator()
	if server_thumb_hook != nil { server_thumb_hook(.Fetch) }
	a := j.conn.transport.receive(j.conn, j.read, server_thumb_part, j, &j.stop)
	whole := a.err == .None && a.status >= 200 && a.status <= 299 && !j.too_big && !sync.atomic_load(&j.stop.asked)
	if whole && len(j.bytes) > 0 {
		if server_thumb_hook != nil { server_thumb_hook(.Decode) }
		j.rgba, j.width, j.height = server_thumb_make(j.bytes[:], j.side)
	}
	delete(j.bytes)
	j.bytes = nil
	_ = ui.post(&j.app.state, server_thumb_done, j)
}

// One chunk kept; a body over the bound stops the request (its announced length at the first chunk).
@(private = "file")
server_thumb_part :: proc(user: rawptr, part: tk_http.Body_Part) -> tk_http.Keep_Going {
	j := (^Server_Thumb)(user)
	if sync.atomic_load(&j.stop.asked) { return .Stop }
	if part.length > SERVER_THUMB_MAX_BYTES || part.received > SERVER_THUMB_MAX_BYTES {
		j.too_big = true
		return .Stop
	}
	if j.bytes == nil && part.length > 0 { reserve(&j.bytes, int(part.length)) }
	append(&j.bytes, ..part.bytes)
	return .Continue
}

// The picture of `bytes`, its longer side at most `side`, its ratio kept, in the heap; nil when gt:image cannot read it.
server_thumb_make :: proc(bytes: []u8, side: int) -> (rgba: []u8, width, height: int) {
	h := runtime.heap_allocator()
	pic, _, ok := img.decode(bytes, h)
	if !ok { return }
	w, ht := pic.width, pic.height
	if max(w, ht) <= side { return pic.pixels, w, ht }
	defer delete(pic.pixels, h)
	k := f32(side) / f32(max(w, ht))
	w, ht = max(1, int(f32(w) * k + 0.5)), max(1, int(f32(ht) * k + 0.5))
	// (a box filter, as the local source's: the fastest reduction, and good enough at a card's size)
	small := img.resize(pic, w, ht, .Box, h)
	return small.pixels, small.width, small.height
}

////////////////////////////////
// Back on the interface's thread

// Its one answer: the pixels, or a failure.
@(private = "file")
server_thumb_done :: proc(data: rawptr, _: u64) {
	j := (^Server_Thumb)(data)
	app := j.app
	ts := &app.server_files.thumbs
	for x, i in ts.jobs { if x == j { unordered_remove(&ts.jobs, i); break } }
	server_thumb_answer(j.reply, j.rgba, j.width, j.height)
	conn_release(app, j.conn)
	h := runtime.heap_allocator()
	delete(j.read, h)
	delete(j.rgba, h)
	free(j, h)
}

@(private = "file")
server_thumb_answer :: proc(reply: ui.File_Reply, rgba: []u8, width, height: int) {
	if server_thumb_answer_hook != nil {
		server_thumb_answer_hook(reply, rgba, width, height)
	} else if rgba != nil {
		ui.file_reply_thumbnail(reply, rgba, width, height)
	} else {
		ui.file_reply_failed(reply, "")
	}
}
