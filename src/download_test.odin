package ocn

// The downloads of the server's files (download.odin): a connection whose transport serves a file in ranges as opencode
// does (206, Content-Range, 416 `bytes */0` for an empty file), the downloads' real workers, and the hook that sees each
// file operation on the thread that makes it.

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"
import fsx "gt:fsx"
import "gt:ui"
import i18n "gt:i18n"
import session "gt:testkit/session"
import "gt:testkit/unwatched"

// What a fake server holds for one connection.
@(private = "file")
Fake_File :: struct {
	bytes:      []u8,
	status:     int,      // not 0: every answer is this status, with `refusal`
	refusal:    string,
	hold_after: int,      // the ranges served before one waits for `gate` (-1: none waits)
	changed_at: int,      // the range from which the file answers 200 whole, as a file changed since (-1: never)
	gate:       sync.Sema,
	served:     int,      // (atomic)
	lock:       sync.Mutex,
	paths:      [dynamic]string,   // what was asked (under lock)
	if_ranges:  [dynamic]string,
}

@(private = "file") fakes_lock: sync.Mutex
@(private = "file") fakes: map[^Conn]^Fake_File

@(private = "file")
fake_range :: proc(c: ^Conn, path: string, from, to: i64, if_range: string, allocator: runtime.Allocator) -> Range_Answer {
	sync.lock(&fakes_lock)
	f := fakes[c]
	sync.unlock(&fakes_lock)
	sync.lock(&f.lock)
	append(&f.paths, strings.clone(path, runtime.heap_allocator()))
	append(&f.if_ranges, strings.clone(if_range, runtime.heap_allocator()))
	sync.unlock(&f.lock)
	n := sync.atomic_add(&f.served, 1)
	if f.hold_after >= 0 && n >= f.hold_after { sync.sema_wait(&f.gate) }
	if f.status != 0 { return {ok = true, status = f.status, body = transmute([]u8)strings.clone(f.refusal, allocator), total = -1} }
	size := i64(len(f.bytes))
	if f.changed_at >= 0 && n >= f.changed_at {
		return {ok = true, status = 200, body = transmute([]u8)strings.clone(string(f.bytes), allocator), total = size}
	}
	if size == 0 || from >= size { return {ok = true, status = 416, total = size} }
	hi := min(to, size - 1)
	return {ok = true, status = 206, body = transmute([]u8)strings.clone(string(f.bytes[from:hi + 1]), allocator), total = size, etag = strings.clone(`W/"5-x"`, allocator)}
}

@(private = "file")
fake_close :: proc(c: ^Conn) {}

// The interface's threads of the tests that run, and what the hook saw.
@(private = "file") io_lock: sync.Mutex
@(private = "file") io_ui_threads: [dynamic]int
@(private = "file") io_on_ui: int   // (under io_lock) file operations made on an interface's thread
@(private = "file") io_seen: map[string]int   // (under io_lock) each path's operations
@(private = "file") io_once: sync.Once

@(private = "file")
io_hook :: proc(path: string) {
	sync.lock(&io_lock)
	defer sync.unlock(&io_lock)
	me := sync.current_thread_id()
	for x in io_ui_threads { if x == me { io_on_ui += 1 } }
	io_seen[strings.clone(path, runtime.heap_allocator())] += 1
}

@(private = "file")
io_count :: proc(path: string) -> int {
	sync.lock(&io_lock)
	defer sync.unlock(&io_lock)
	return io_seen[path]
}

@(private = "file")
io_on_ui_count :: proc() -> int {
	sync.lock(&io_lock)
	defer sync.unlock(&io_lock)
	return io_on_ui
}

// A bench App with a connection to the fake server holding `bytes`, chunks of 4 bytes, and a folder of its own for the
// files it downloads.
@(private = "file")
dl_bench :: proc(t: ^testing.T, bytes: string, name: string) -> (app: ^App, c: ^Conn, f: ^Fake_File, dir: string) {
	sync.once_do(&io_once, proc() {
		context.allocator = runtime.heap_allocator()
		io_seen = make(map[string]int)
		download_io_hook = io_hook
	})
	sync.lock(&io_lock)
	append(&io_ui_threads, sync.current_thread_id())
	sync.unlock(&io_lock)
	app = bench_new()
	app.downloads.chunk = 4
	c = conn_make(app, {}, Transport{call = bench_call, fetch = bench_fetch, close = fake_close, range = fake_range}, 0, &bench_pool_ms)
	app.conn = c
	f = new(Fake_File)
	f^ = {bytes = transmute([]u8)strings.clone(bytes), hold_after = -1, changed_at = -1}
	sync.lock(&fakes_lock)
	fakes[c] = f
	sync.unlock(&fakes_lock)
	dir = fmt.aprintf("%s/ocn_download_%s_%d", fsx.temp_dir(context.temp_allocator), name, sync.current_thread_id())
	_ = fsx.remove_tree(dir)
	testing.expect(t, fsx.make_dirs(dir), dir)
	return
}

@(private = "file") DL_BOUND :: 5 * time.Second

// The posts run until `done` says so, within DL_BOUND.
@(private = "file")
dl_until :: proc(app: ^App, done: proc(app: ^App, user: rawptr) -> bool, user: rawptr) -> bool {
	start := time.tick_now()
	for !done(app, user) {
		if time.tick_since(start) > DL_BOUND { return false }
		ui.drain_posts(&app.state, max(int))
		thread.yield()
	}
	return true
}

@(private = "file")
dl_got :: proc(app: ^App, user: rawptr) -> bool {
	d := (^Download)(user)
	return sync.atomic_load(&d.got) >= 4 && d.state == .Running
}

@(private = "file")
dl_ended :: proc(app: ^App, user: rawptr) -> bool {
	d := (^Download)(user)
	return d.state == .Done || d.state == .Failed
}

@(private = "file")
dl_none :: proc(app: ^App, user: rawptr) -> bool { return len(app.downloads.list) == 0 }

@(private = "file")
dl_exists :: proc(path: string) -> bool { return os.exists(path) }

// The toasts alive whose words hold `s`.
@(private = "file")
toasts_saying :: proc(app: ^App, s: string) -> int {
	n := 0
	for &x in app.state.toasts {
		if x.alive && (strings.contains(string(x.text[:x.len]), s) || strings.contains(string(x.title[:x.title_len]), s)) { n += 1 }
	}
	return n
}

// The file comes whole, a NUL and a 0xFF in it, in ranges, through a temp beside the target that holds what came so far,
// renamed at the end; each range after the first carries the first's ETag; the progress says the bytes and the total;
// the interface's thread makes no file operation.
@(test)
a_download_writes_its_bytes_through_a_temp :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	CONTENT :: "a\x00b\xffcdefg\xff"
	app, c, f, dir := dl_bench(t, CONTENT, "bytes")
	defer downloads_stop(app)
	f.hold_after = 1
	target := fmt.tprintf("%s/f.bin", dir)
	read := download_read_path("/srv/p", "/srv/p/data/f.bin")
	d := download_start(app, c, read, "f.bin", target)
	testing.expect(t, dl_until(app, dl_got, d), "the first range came")
	temp := d.temp
	testing.expect(t, strings.has_prefix(temp, target) && temp != target, "the temp is beside the target")
	testing.expect(t, dl_exists(temp), "what came so far is in the temp")
	testing.expect(t, !dl_exists(target), "the target is not written before the end")
	testing.expect_value(t, sync.atomic_load(&d.total), i64(10))
	testing.expect_value(t, download_progress_words(d), fmt.tprintf("%s (4 B of 10 B)", i18n.percent(0.4)))
	share, running := downloads_share(app)
	testing.expect_value(t, running, 1)
	testing.expect(t, share > 0.39 && share < 0.41, "the pill's share")
	for _ in 0 ..< 8 { sync.sema_post(&f.gate) }
	testing.expect(t, dl_until(app, dl_ended, d), "it ended")
	testing.expect_value(t, d.state, Download_State.Done)
	data, err := os.read_entire_file(target, context.temp_allocator)
	testing.expect(t, err == nil, "the target is there")
	testing.expect_value(t, string(data), CONTENT)
	testing.expect(t, !dl_exists(temp), "the temp was renamed")
	testing.expect(t, io_count(temp) >= 3, "the temp was written range by range")
	testing.expect_value(t, io_on_ui_count(), 0)
	sync.lock(&f.lock)
	testing.expect_value(t, len(f.paths), 3)
	for p in f.paths { testing.expect_value(t, p, "/api/fs/read/data/f.bin?location[directory]=%2Fsrv%2Fp") }
	testing.expect_value(t, f.if_ranges[0], "")
	testing.expect_value(t, f.if_ranges[2], `W/"5-x"`)
	sync.unlock(&f.lock)
	testing.expect_value(t, toasts_saying(app, "f.bin"), 1)
}

// Cancel: the temp goes, no file is made, nothing is said, and it leaves the list.
@(test)
a_cancelled_download_removes_its_temp :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app, c, f, dir := dl_bench(t, "0123456789", "cancel")
	defer downloads_stop(app)
	f.hold_after = 1
	target := fmt.tprintf("%s/c.bin", dir)
	d := download_start(app, c, download_read_path("/srv", "/srv/c.bin"), "c.bin", target)
	testing.expect(t, dl_until(app, dl_got, d), "the first range came")
	temp := strings.clone(d.temp, context.temp_allocator)
	testing.expect(t, dl_exists(temp), "the temp holds the first range")
	download_cancel(d)
	sync.sema_post(&f.gate)
	testing.expect(t, dl_until(app, dl_none, nil), "it left the list")
	testing.expect(t, !dl_exists(temp), "the temp is gone")
	testing.expect(t, !dl_exists(target), "no file")
	testing.expect_value(t, toasts_saying(app, "c.bin"), 0)
	testing.expect_value(t, io_on_ui_count(), 0)
}

// A 404: the server's reason, said once; no file, no temp.
@(test)
a_missing_file_says_why_and_writes_nothing :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app, c, f, dir := dl_bench(t, "", "missing")
	defer downloads_stop(app)
	f.status, f.refusal = 404, `{"_tag":"FileNotFoundError","message":"File not found: gone.txt"}`
	target := fmt.tprintf("%s/gone.txt", dir)
	d := download_start(app, c, download_read_path("/srv", "/srv/gone.txt"), "gone.txt", target)
	testing.expect(t, dl_until(app, dl_ended, d), "it ended")
	testing.expect_value(t, d.state, Download_State.Failed)
	testing.expect(t, strings.contains(d.why, "File not found: gone.txt"), d.why)
	testing.expect(t, !dl_exists(target) && !dl_exists(d.temp), "nothing written")
	testing.expect_value(t, io_count(d.temp), 0)
	testing.expect_value(t, toasts_saying(app, "File not found: gone.txt"), 1)
}

// An empty file has no first byte: the server's 416 `bytes */0` makes an empty file, not a failure.
@(test)
an_empty_file_downloads_empty :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app, c, _, dir := dl_bench(t, "", "empty")
	defer downloads_stop(app)
	target := fmt.tprintf("%s/e.txt", dir)
	d := download_start(app, c, download_read_path("/srv", "/srv/e.txt"), "e.txt", target)
	testing.expect(t, dl_until(app, dl_ended, d), "it ended")
	testing.expect_value(t, d.state, Download_State.Done)
	size, _, ok := fsx.stat(target)
	testing.expect(t, ok && size == 0, "an empty file")
}

// A file changed during the download answers its If-Range whole: the download fails, not a file of two versions.
@(test)
a_file_changed_during_the_download_fails :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app, c, f, dir := dl_bench(t, "0123456789", "changed")
	defer downloads_stop(app)
	f.changed_at = 1
	target := fmt.tprintf("%s/x.bin", dir)
	d := download_start(app, c, download_read_path("/srv", "/srv/x.bin"), "x.bin", target)
	testing.expect(t, dl_until(app, dl_ended, d), "it ended")
	testing.expect_value(t, d.state, Download_State.Failed)
	testing.expect(t, !dl_exists(target) && !dl_exists(d.temp), "nothing left")
}

// The program's end stops the downloads; a temp whose worker is still in a request is removed all the same.
@(test)
the_end_removes_the_temps :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app, c, f, dir := dl_bench(t, "0123456789", "end")
	f.hold_after = 1
	target := fmt.tprintf("%s/z.bin", dir)
	d := download_start(app, c, download_read_path("/srv", "/srv/z.bin"), "z.bin", target)
	testing.expect(t, dl_until(app, dl_got, d), "the first range came")
	temp := strings.clone(d.temp, context.temp_allocator)
	testing.expect(t, dl_exists(temp))
	downloads_stop(app, 50 * time.Millisecond)   // (its worker waits on the gate: past the bound)
	testing.expect(t, !dl_exists(temp), "the temp is gone")
	testing.expect(t, !dl_exists(target), "no file")
	sync.sema_post(&f.gate)   // (the worker sees its stop and ends)
}

// The GET of a file: from the session's folder when it is in it, else from its own folder; any system's separators.
@(test)
a_download_reads_from_the_right_folder :: proc(t: ^testing.T) {
	testing.expect_value(t, download_read_path("/home/u/p", "/home/u/p/src/a b.go"), "/api/fs/read/src/a%20b.go?location[directory]=%2Fhome%2Fu%2Fp")
	testing.expect_value(t, download_read_path("/home/u/p", "/etc/x.conf"), "/api/fs/read/x.conf?location[directory]=%2Fetc")
	testing.expect_value(t, download_read_path("/home/u/p", "src/a.go"), "/api/fs/read/src/a.go?location[directory]=%2Fhome%2Fu%2Fp")
	testing.expect_value(t, download_read_path(`C:\code\p`, `C:\code\p\a.txt`), "/api/fs/read/a.txt?location[directory]=C%3A%2Fcode%2Fp")
	testing.expect_value(t, download_read_path(`C:\code\p`, `D:\b.txt`), "/api/fs/read/b.txt?location[directory]=D%3A%2F")
	testing.expect_value(t, download_read_path("", "/x"), "/api/fs/read/x?location[directory]=%2F")
	testing.expect_value(t, download_name(`C:\code\p\a.txt`), "a.txt")
	_, ok := download_path_of("hello world")
	testing.expect(t, !ok, "words are no path")
	p, ok2 := download_path_of(" `src/main.odin` ")
	testing.expect(t, ok2 && p == "src/main.odin", p)
	testing.expect_value(t, content_range_total("bytes 0-99/39674"), i64(39674))
	testing.expect_value(t, content_range_total("bytes */0"), i64(0))
	testing.expect_value(t, content_range_total("bytes 0-99/*"), i64(-1))
}

// A read, edit or write call's menu offers to download its file.
@(test)
a_tool_call_s_file_can_be_downloaded :: proc(t: ^testing.T) {
	unwatched.run(t, proc(t: ^testing.T) {
		context.allocator = runtime.heap_allocator()
		app, s := bench_app(t)
		// (the last answer's first read call: its parts are a reasoning, then the tools)
		ctx_open(app, .Tool, fmt.tprintf("msg_%d_a", BENCH_TURNS - 1), 1)
		session.frames(s, 3)
		testing.expect(t, session.find_text(s, "Download…") != nil, "Download… in the tool call's menu")
		session.event(s, {kind = .Key_Press, key = .Escape})
		session.frames(s, 2)
	})
}
