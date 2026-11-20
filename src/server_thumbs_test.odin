package ocn

// The thumbnails of the server's pictures (server_thumbs.odin): a connection whose transport streams a file in chunks
// as gt:http.receive gives them (a refusal gives none), the thumbnails' real workers, and hooks that see each answer
// and each worker's step on the thread that makes it.

import "base:runtime"
import "core:fmt"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"
import tk_http "gt:http"
import "gt:png"
import "gt:ui"
import session "gt:testkit/session"
import "gt:testkit/unwatched"

@(private = "file") THUMB_CHUNK :: 4096
@(private = "file") THUMB_BOUND :: 5 * time.Second

// What a fake server holds: a file's bytes by its GET's path, or a status, or a length it announces.
@(private = "file")
Thumb_Server :: struct {
	lock:      sync.Mutex,
	files:     map[string][]u8,   // by the GET's path and query
	status:    int,               // not 0: every answer is this status, without a chunk
	announce:  i64,               // not 0: the length the first chunk announces (a file too large)
	held:      bool,              // each fetch waits for `gate` before its first chunk
	gate:      sync.Sema,
	fetches:   int,               // (under lock) the GETs made
	running:   int,               // (under lock) at once now
	most:      int,               // (under lock) at once at most
}

@(private = "file") thumb_servers_lock: sync.Mutex
@(private = "file") thumb_servers: map[^Conn]^Thumb_Server

@(private = "file")
thumb_receive :: proc(c: ^Conn, path: string, on_part: tk_http.Part_Proc, user: rawptr, stop: ^tk_http.Stop) -> Receive_Answer {
	sync.lock(&thumb_servers_lock)
	f := thumb_servers[c]
	sync.unlock(&thumb_servers_lock)
	sync.lock(&f.lock)
	f.fetches += 1
	f.running += 1
	f.most = max(f.most, f.running)
	bytes, known := f.files[path]
	sync.unlock(&f.lock)
	defer {
		sync.lock(&f.lock)
		f.running -= 1
		sync.unlock(&f.lock)
	}
	if f.held { sync.sema_wait(&f.gate) }
	if sync.atomic_load(&stop.asked) { return {err = .Stopped, status = 200} }
	if f.status != 0 { return {status = f.status} }
	if !known { return {status = 404} }
	length := f.announce != 0 ? f.announce : i64(len(bytes))
	for at := 0; at < len(bytes); at += THUMB_CHUNK {
		if sync.atomic_load(&stop.asked) { return {err = .Stopped, status = 200} }
		hi := min(at + THUMB_CHUNK, len(bytes))
		if on_part(user, {bytes = bytes[at:hi], status = 200, received = i64(hi), length = length}) == .Stop { return {status = 200} }
	}
	return {status = 200}
}

// The interface's threads of the tests that run, and the workers' steps made on one of them.
@(private = "file") step_lock: sync.Mutex
@(private = "file") step_ui_threads: [dynamic]int
@(private = "file") steps_on_ui: int
@(private = "file") steps_made: [Server_Thumb_Step]int
@(private = "file") step_once: sync.Once

@(private = "file")
step_hook :: proc(step: Server_Thumb_Step) {
	sync.lock(&step_lock)
	defer sync.unlock(&step_lock)
	me := sync.current_thread_id()
	for x in step_ui_threads { if x == me { steps_on_ui += 1 } }
	steps_made[step] += 1
}

@(private = "file")
steps :: proc() -> (on_ui: int, made: [Server_Thumb_Step]int) {
	sync.lock(&step_lock)
	defer sync.unlock(&step_lock)
	return steps_on_ui, steps_made
}

// One answer the source gave, by its ticket.
@(private = "file")
Thumb_Answer :: struct {
	ticket:        u64,
	ok:            bool,
	width, height: int,
	bytes:         int,
}

@(private = "file") @(thread_local) answers: [dynamic]Thumb_Answer

@(private = "file")
answer_hook :: proc(reply: ui.File_Reply, rgba: []u8, width, height: int) {
	append(&answers, Thumb_Answer{reply.ticket, rgba != nil, width, height, len(rgba)})
}

// A bench App connected to a fake server, its source on the session's folder "/srv/p".
@(private = "file")
thumb_bench :: proc() -> (app: ^App, src: ^ui.File_Source, f: ^Thumb_Server) {
	sync.once_do(&step_once, proc() { server_thumb_hook = step_hook })
	sync.lock(&step_lock)
	append(&step_ui_threads, sync.current_thread_id())
	sync.unlock(&step_lock)
	server_thumb_answer_hook = answer_hook
	clear(&answers)
	app = bench_new()
	c := conn_make(app, {}, Transport{call = bench_call, fetch = bench_fetch, close = bench_close, receive = thumb_receive}, 0, &bench_pool_ms)
	app.conn = c
	f = new(Thumb_Server)
	f.files = make(map[string][]u8)
	sync.lock(&thumb_servers_lock)
	thumb_servers[c] = f
	sync.unlock(&thumb_servers_lock)
	src = server_files(app, "/srv/p")
	return
}

// The workers stopped; the answers go to the toolkit again (the hook is the thread's: the next test on it is another).
@(private = "file")
thumb_bench_end :: proc(app: ^App) {
	server_files_end(app)
	server_thumb_answer_hook = nil
}

// A PNG of `w` by `h`: `tint` across, white down, a ring in its middle (the ratio shows in a thumbnail).
@(private = "file")
thumb_png :: proc(w, h: int, tint: [3]u8 = {0x30, 0x80, 0xd0}) -> []u8 {
	rgba := make([]u8, w * h * 4, context.temp_allocator)
	for y in 0 ..< h {
		for x in 0 ..< w {
			i := (y * w + x) * 4
			across := f32(x) / f32(max(w - 1, 1))
			down := f32(y) / f32(max(h - 1, 1))
			dx, dy := f32(x - w / 2), f32(y - h / 2)
			r := f32(min(w, h)) * 0.3
			d := dx * dx + dy * dy
			ring := d < r * r && d > r * r * 0.5
			for k in 0 ..< 3 {
				c := f32(tint[k]) * (0.55 + 0.45 * across) + 255 * 0.35 * down
				rgba[i + k] = ring ? 0xf5 : u8(min(c, 255))
			}
			rgba[i + 3] = 0xff
		}
	}
	return png.encode(rgba, w, h)
}

// The posts run until `want` answers came, within THUMB_BOUND.
@(private = "file")
answered :: proc(app: ^App, want: int) -> bool {
	start := time.tick_now()
	for len(answers) < want {
		if time.tick_since(start) > THUMB_BOUND { return false }
		ui.drain_posts(&app.state, max(int))
		thread.yield()
	}
	return true
}

@(private = "file")
thumb_ask :: proc(src: ^ui.File_Source, path: string, px: int, ticket: u64) {
	src.thumbnail(src, path, px, {kind = .Thumbnail, ticket = ticket})
}

// A PNG of the folder: one GET of its bytes from the session's folder, decoded and reduced to the size asked, its ratio
// kept; a smaller one comes as it is. Neither the fetch nor the decode is on the interface's thread.
@(test)
a_servers_picture_gets_a_thumbnail_of_the_size_asked :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app, src, f := thumb_bench()
	defer thumb_bench_end(app)
	testing.expect(t, src.thumbnail != nil, "a location: thumbnails")
	f.files["/api/fs/read/img/wide.png?location[directory]=%2Fsrv%2Fp"] = thumb_png(600, 300)
	f.files["/api/fs/read/small.png?location[directory]=%2Fsrv%2Fp"] = thumb_png(40, 20)
	thumb_ask(src, "/srv/p/img/wide.png", 128, 1)
	thumb_ask(src, "/srv/p/small.png", 128, 2)
	testing.expect(t, answered(app, 2), "both answered")
	testing.expect_value(t, len(answers), 2)
	for a in answers {
		testing.expect(t, a.ok, "a thumbnail")
		switch a.ticket {
		case 1:
			testing.expect_value(t, [2]int{a.width, a.height}, [2]int{128, 64})
		case 2:
			testing.expect_value(t, [2]int{a.width, a.height}, [2]int{40, 20})
		}
		testing.expect_value(t, a.bytes, a.width * a.height * 4)
	}
	on_ui, made := steps()
	testing.expect_value(t, on_ui, 0)
	testing.expect(t, made[.Fetch] >= 2 && made[.Decode] >= 2, "fetched and decoded on the workers")
	testing.expect_value(t, len(app.server_files.thumbs.jobs), 0)
}

// What gets no thumbnail is answered failed, once: a file that is no picture and one outside the session's folder at
// once, with no request; a picture larger than the bound, and one the server does not have, by their requests.
@(test)
a_file_with_no_thumbnail_is_answered_failed :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app, src, f := thumb_bench()
	defer thumb_bench_end(app)
	thumb_ask(src, "/srv/p/notes.txt", 128, 1)
	thumb_ask(src, "/srv/elsewhere/a.png", 128, 2)
	testing.expect_value(t, len(answers), 2)
	testing.expect_value(t, f.fetches, 0)
	f.files["/api/fs/read/huge.png?location[directory]=%2Fsrv%2Fp"] = thumb_png(8, 8)
	f.announce = SERVER_THUMB_MAX_BYTES + 1
	thumb_ask(src, "/srv/p/huge.png", 128, 3)
	testing.expect(t, answered(app, 3), "the large one answered")
	f.announce = 0
	thumb_ask(src, "/srv/p/gone.png", 128, 4)
	testing.expect(t, answered(app, 4), "the missing one answered")
	f.status = 500
	f.files["/api/fs/read/b.png?location[directory]=%2Fsrv%2Fp"] = thumb_png(8, 8)
	thumb_ask(src, "/srv/p/b.png", 128, 5)
	testing.expect(t, answered(app, 5), "the refused one answered")
	seen: [6]int
	for a in answers {
		testing.expectf(t, !a.ok, "ticket %d: failed", a.ticket)
		seen[a.ticket] += 1
	}
	for k in 1 ..= 5 { testing.expectf(t, seen[k] == 1, "ticket %d answered once, not %d times", k, seen[k]) }
	testing.expect_value(t, f.fetches, 3)
}

// Many asked at once: two fetches run at a time, the others wait; each is answered once.
@(test)
at_most_two_pictures_come_at_once :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app, src, f := thumb_bench()
	defer thumb_bench_end(app)
	f.held = true
	N :: 6
	for k in 1 ..= N {
		f.files[fmt.aprintf("/api/fs/read/p%d.png?location[directory]=%%2Fsrv%%2Fp", k)] = thumb_png(16, 16)
		thumb_ask(src, fmt.tprintf("/srv/p/p%d.png", k), 64, u64(k))
	}
	start := time.tick_now()
	for {
		sync.lock(&f.lock)
		running := f.running
		sync.unlock(&f.lock)
		if running == SERVER_THUMB_WORKERS { break }
		testing.expect(t, time.tick_since(start) < THUMB_BOUND, "the workers took their fetches")
		if time.tick_since(start) >= THUMB_BOUND { break }
		thread.yield()
	}
	for _ in 0 ..< N { sync.sema_post(&f.gate) }
	testing.expect(t, answered(app, N), "every one answered")
	testing.expect_value(t, f.most, SERVER_THUMB_WORKERS)
	seen: [N + 1]int
	for a in answers { seen[a.ticket] += 1; testing.expect(t, a.ok, "a thumbnail") }
	for k in 1 ..= N { testing.expect_value(t, seen[k], 1) }
	on_ui, _ := steps()
	testing.expect_value(t, on_ui, 0)
}

// The server left while a picture comes: its fetch stops, and the ask is still answered, once, failed.
@(test)
a_server_switch_stops_a_thumbnail_and_answers_it :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app, src, f := thumb_bench()
	defer thumb_bench_end(app)
	f.held = true
	f.files["/api/fs/read/a.png?location[directory]=%2Fsrv%2Fp"] = thumb_png(16, 16)
	thumb_ask(src, "/srv/p/a.png", 64, 1)
	server_forget(app)
	sync.sema_post(&f.gate)
	testing.expect(t, answered(app, 1), "answered")
	testing.expect(t, len(answers) == 1 && !answers[0].ok, "once, failed")
	testing.expect_value(t, len(app.server_files.thumbs.jobs), 0)
}

// The toolkit keys its thumbnails by the source's `user`: one per server address, the same when a server comes back.
@(test)
each_server_has_its_own_thumbnails :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	defer thumb_bench_end(app)
	a := conn_make(app, {base = "http://a:4096"}, BENCH_TRANSPORT, 0, &bench_pool_ms)
	b := conn_make(app, {base = "http://b:4096"}, BENCH_TRANSPORT, 0, &bench_pool_ms)
	app.conn = a
	of_a := server_files(app, "/p").user
	app.conn = b
	of_b := server_files(app, "/p").user
	app.conn = a
	again := server_files(app, "/p").user
	testing.expect(t, of_a != of_b, "two servers, two keys")
	testing.expect(t, of_a == again, "a server come back finds its own")
	testing.expect(t, server_files_app(server_files(app)) == app, "the source's calls find the App")
	app.conn = nil
}

// The file browser on the session's folder of a server elsewhere, in its cards: the pictures' thumbnails come, the
// other files keep their icon. The cards of the next dialog on the same folder show them again without a request.
@(test)
the_cards_show_the_servers_pictures :: proc(t: ^testing.T) {
	unwatched.run(t, proc(t: ^testing.T) {
		context.allocator = runtime.heap_allocator()
		app, s := bench_app(t)
		pane := main_pane(app)
		server_thumb_answer_hook = nil   // (the toolkit's cache: the cards show what it holds)
		sync.once_do(&step_once, proc() { server_thumb_hook = step_hook })
		sync.lock(&step_lock)
		append(&step_ui_threads, sync.current_thread_id())
		sync.unlock(&step_lock)
		c := conn_make(app, {}, Transport{call = bench_call, fetch = bench_fetch, close = bench_close, receive = thumb_receive}, 0, &bench_pool_ms)
		append(&bench_conns, c)
		app.conn = c
		f := new(Thumb_Server)
		f.files = make(map[string][]u8)
		sync.lock(&thumb_servers_lock)
		thumb_servers[c] = f
		sync.unlock(&thumb_servers_lock)
		defer { server_thumbs_stop(app); bench_clear(app); app.conn = nil }
		Q :: "?location[directory]=C%3A%2Fcode%2Fproject_0"
		f.files["/api/fs/read/sunset.png" + Q] = thumb_png(640, 360, {0xf0, 0x70, 0x30})
		f.files["/api/fs/read/logo.png" + Q] = thumb_png(256, 256, {0x20, 0xa0, 0x60})
		f.files["/api/fs/read/chart.png" + Q] = thumb_png(300, 480, {0x80, 0x40, 0xc0})
		f.files["/api/fs/read/banner.png" + Q] = thumb_png(900, 200, {0x10, 0x50, 0xe0})
		LIST :: `{"data":[{"path":"assets/","type":"directory"},{"path":"banner.png","type":"file"},{"path":"chart.png","type":"file"},{"path":"logo.png","type":"file"},{"path":"README.md","type":"file"},{"path":"sunset.png","type":"file"}]}`
		files_open(app, pane)
		session.frames(s, 3)
		bench_answer(app, bench_take(t, .Server_Files_List), 200, LIST)
		session.wait_idle(s)
		session.click(s, "fb_view")
		session.click(s, fmt.tprintf("mi_%d_fb_view_%d", ui.TABLE_ZOOM_CARDS, ui.TABLE_ZOOM_CARDS))
		session.wait_until(s, proc(s: ^session.Session) -> bool { return ui.file_browser_counts(s.state).thumbs_ready == 4 }, "the four pictures' thumbnails")
		session.wait_idle(s)
		session.save_png(s, "server_thumbnails.png")
		testing.expect_value(t, f.fetches, 4)   // (README.md: no request)
		on_ui, _ := steps()
		testing.expect_value(t, on_ui, 0)
		session.key(s, .Escape)
		session.wait_until(s, proc(s: ^session.Session) -> bool { return !ui.file_dialog_shown(&(^App)(s.user).state) }, "closed")
		files_open(app, pane)
		session.frames(s, 3)
		bench_answer(app, bench_take(t, .Server_Files_List), 200, LIST)
		session.wait_idle(s)
		testing.expect_value(t, ui.file_browser_counts(&app.state).zoom, ui.TABLE_ZOOM_CARDS)
		testing.expect_value(t, ui.file_browser_counts(&app.state).thumbs_ready, 4)
		testing.expect_value(t, f.fetches, 4)
	})
}
