package ocn

// The downloads of the server's files (download.odin): a connection whose transport streams a file in chunks as
// gt:http.receive gives them (a refusal gives no chunk), the downloads' real workers, and the hook that sees each file
// operation on the thread that makes it.

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"
import fsx "gt:fsx"
import tk_http "gt:http"
import "gt:host"
import "gt:platform"
import "gt:ui"
import i18n "gt:i18n"
import session "gt:testkit/session"
import "gt:testkit/unwatched"

// The bytes of one chunk the fake server gives.
@(private = "file") FAKE_CHUNK :: 4

// What a fake server holds for one connection.
@(private = "file")
Fake_File :: struct {
	bytes:      []u8,
	status:     int,   // not 0: the answer is this status, without a chunk (receive gives none of a refusal)
	short:      int,   // the body ends this many bytes before the length it announced (a file cut while it is read)
	hold_after: int,   // the chunks given before one waits for `gate` (-1: none waits)
	gate:       sync.Sema,
	given:      int,   // (atomic)
	lock:       sync.Mutex,
	paths:      [dynamic]string,   // what was asked (under lock)
}

@(private = "file") fakes_lock: sync.Mutex
@(private = "file") fakes: map[^Conn]^Fake_File

@(private = "file")
fake_receive :: proc(c: ^Conn, path: string, on_part: tk_http.Part_Proc, user: rawptr, stop: ^tk_http.Stop) -> Receive_Answer {
	sync.lock(&fakes_lock)
	f := fakes[c]
	sync.unlock(&fakes_lock)
	sync.lock(&f.lock)
	append(&f.paths, strings.clone(path, runtime.heap_allocator()))
	sync.unlock(&f.lock)
	if f.status != 0 { return {status = f.status} }
	size := len(f.bytes)
	sent := size - f.short
	// (the chunk's bytes copied: valid during the call only, as the clients' reused buffers)
	buf: [FAKE_CHUNK]u8
	for at := 0; at < sent; at += FAKE_CHUNK {
		n := sync.atomic_add(&f.given, 1)
		if f.hold_after >= 0 && n >= f.hold_after { sync.sema_wait(&f.gate) }
		if sync.atomic_load(&stop.asked) { return {err = .Stopped, status = 200} }
		hi := min(at + FAKE_CHUNK, sent)
		copy(buf[:], f.bytes[at:hi])
		if on_part(user, {bytes = buf[:hi - at], status = 200, received = i64(hi), length = i64(size)}) == .Stop { return {status = 200} }
	}
	return {status = 200}
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

// A bench App with a connection to the fake server holding `bytes`, and a folder of its own for the files it downloads.
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
	c, f = dl_fake_conn(app, bytes)
	dir = dl_dir(t, name)
	return
}

// A connection of `app` to a fake server that holds `bytes`.
@(private = "file")
dl_fake_conn :: proc(app: ^App, bytes: string) -> (c: ^Conn, f: ^Fake_File) {
	c = conn_make(app, {}, Transport{call = bench_call, fetch = bench_fetch, close = fake_close, receive = fake_receive}, 0, &bench_pool_ms)
	app.conn = c
	f = new(Fake_File)
	f^ = {bytes = transmute([]u8)strings.clone(bytes), hold_after = -1}
	sync.lock(&fakes_lock)
	fakes[c] = f
	sync.unlock(&fakes_lock)
	return
}

// An empty folder of the test's own.
@(private = "file")
dl_dir :: proc(t: ^testing.T, name: string) -> string {
	dir := fmt.aprintf("%s/ocn_download_%s_%d", fsx.temp_dir(context.temp_allocator), name, sync.current_thread_id())
	_ = fsx.remove_tree(dir)
	testing.expect(t, fsx.make_dirs(dir), dir)
	return dir
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
	return sync.atomic_load(&d.got) >= FAKE_CHUNK && d.state == .Running
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

// The names in `dir`: what a download left there, its temps included.
@(private = "file")
dl_files :: proc(dir: string) -> int {
	entries, err := os.read_directory_by_path(dir, -1, context.temp_allocator)
	return err == nil ? len(entries) : -1
}

// The toasts alive whose words hold `s`.
@(private = "file")
toasts_saying :: proc(app: ^App, s: string) -> int {
	n := 0
	for &x in app.state.toasts {
		if x.alive && (strings.contains(string(x.text[:x.len]), s) || strings.contains(string(x.title[:x.title_len]), s)) { n += 1 }
	}
	return n
}

// The file comes whole, a NUL and a 0xFF in it, in one request, through a temp beside the target that holds what came
// so far, renamed at the end; the progress says the bytes and the total, in the pill and in the notification with its
// Cancel; the interface's thread makes no file operation.
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
	testing.expect(t, dl_until(app, dl_got, d), "the first chunk came")
	temp := strings.clone(d.temp, context.temp_allocator)
	testing.expect(t, strings.has_prefix(temp, target) && temp != target, "the temp is beside the target")
	testing.expect(t, dl_exists(temp), "what came so far is in the temp")
	testing.expect(t, !dl_exists(target), "the target is not written before the end")
	testing.expect_value(t, sync.atomic_load(&d.total), i64(10))
	words := fmt.tprintf("%s (4 B of 10 B)", i18n.percent(0.4))
	testing.expect_value(t, download_progress_words(d), words)
	share, running := downloads_share(app)
	testing.expect_value(t, running, 1)
	testing.expect(t, share > 0.39 && share < 0.41, "the pill's share")
	n := download_notification(d)
	testing.expect(t, n.progress.shown && n.progress.value > 0.39 && n.progress.value < 0.41, "the notification's bar")
	testing.expect_value(t, n.progress.status, words)
	testing.expect(t, len(n.actions) == 1 && n.actions[0].id == DOWNLOAD_ACT_CANCEL, "its Cancel")
	testing.expect(t, n.silent, "an update makes no sound")
	for _ in 0 ..< 8 { sync.sema_post(&f.gate) }
	testing.expect(t, dl_until(app, dl_ended, d), "it ended")
	testing.expect_value(t, d.state, Download_State.Done)
	data, err := os.read_entire_file(target, context.temp_allocator)
	testing.expect(t, err == nil, "the target is there")
	testing.expect_value(t, string(data), CONTENT)
	testing.expect(t, !dl_exists(temp), "the temp was renamed")
	testing.expect_value(t, dl_files(dir), 1)
	testing.expect(t, io_count(temp) >= 3, "the temp was written chunk by chunk")
	testing.expect_value(t, io_on_ui_count(), 0)
	sync.lock(&f.lock)
	testing.expect_value(t, len(f.paths), 1)
	for p in f.paths { testing.expect_value(t, p, "/api/fs/read/data/f.bin?location[directory]=%2Fsrv%2Fp") }
	sync.unlock(&f.lock)
	testing.expect_value(t, toasts_saying(app, "f.bin"), 1)
	end := download_notification(d)
	testing.expect(t, !end.progress.shown && end.body == target, "the end: its target, no bar")
	testing.expect(t, len(end.actions) == 2 && end.actions[0].id == DOWNLOAD_ACT_OPEN && end.actions[1].id == DOWNLOAD_ACT_SHOW, "Open and Show in folder")
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
	testing.expect(t, dl_until(app, dl_got, d), "the first chunk came")
	temp := strings.clone(d.temp, context.temp_allocator)
	testing.expect(t, dl_exists(temp), "the temp holds the first chunk")
	download_cancel(d)
	sync.sema_post(&f.gate)
	testing.expect(t, dl_until(app, dl_none, nil), "it left the list")
	testing.expect(t, !dl_exists(temp), "the temp is gone")
	testing.expect(t, !dl_exists(target), "no file")
	testing.expect_value(t, dl_files(dir), 0)
	testing.expect_value(t, toasts_saying(app, "c.bin"), 0)
	testing.expect_value(t, io_on_ui_count(), 0)
}

// A 404: why, said once; no file, no temp, not even opened.
@(test)
a_missing_file_says_why_and_writes_nothing :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app, c, f, dir := dl_bench(t, "", "missing")
	defer downloads_stop(app)
	f.status = 404
	target := fmt.tprintf("%s/gone.txt", dir)
	d := download_start(app, c, download_read_path("/srv", "/srv/gone.txt"), "gone.txt", target)
	testing.expect(t, dl_until(app, dl_ended, d), "it ended")
	testing.expect_value(t, d.state, Download_State.Failed)
	testing.expect(t, strings.contains(d.why, "not on the server"), d.why)
	testing.expect(t, !dl_exists(target), "nothing written")
	testing.expect_value(t, dl_files(dir), 0)
	testing.expect_value(t, io_count(target), 0)
	testing.expect_value(t, toasts_saying(app, "not on the server"), 1)
}

// An empty file is a whole body without a chunk: an empty file, not a failure.
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
	testing.expect_value(t, dl_files(dir), 1)
}

// A file cut while it is read ends before the length the server announced: the download fails, not a file of two
// versions, and nothing is left.
@(test)
a_file_changed_during_the_download_fails :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app, c, f, dir := dl_bench(t, "0123456789", "changed")
	defer downloads_stop(app)
	f.short = 4
	target := fmt.tprintf("%s/x.bin", dir)
	d := download_start(app, c, download_read_path("/srv", "/srv/x.bin"), "x.bin", target)
	testing.expect(t, dl_until(app, dl_ended, d), "it ended")
	testing.expect_value(t, d.state, Download_State.Failed)
	testing.expect(t, strings.contains(d.why, "changed"), d.why)
	testing.expect(t, !dl_exists(target), "no file")
	testing.expect_value(t, dl_files(dir), 0)
}

// The program's end stops the downloads; a temp whose worker is still in a request is removed all the same.
@(test)
the_end_removes_the_temps :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app, c, f, dir := dl_bench(t, "0123456789", "end")
	f.hold_after = 1
	target := fmt.tprintf("%s/z.bin", dir)
	d := download_start(app, c, download_read_path("/srv", "/srv/z.bin"), "z.bin", target)
	testing.expect(t, dl_until(app, dl_got, d), "the first chunk came")
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

// How long the loop at rest waits for a post's wake before it looks at its bound again (real time).
@(private = "file") DL_REST_WAIT_MS :: 20

// The program's loop at rest (main.odin): a frame only when one is due (input, a change that settles, an animation), when
// a post woke the window, or at the timed wake the last build asked for, the test's clock moved there at once. Never a
// frame of the test's own: what the window shows moves only by what the program asked for. Until `done`, within DL_BOUND.
@(private = "file")
dl_rest_until :: proc(s: ^session.Session, done: proc(app: ^App, words: string) -> bool, words: string) -> bool {
	app := (^App)(s.user)
	hosts := [1]^host.Host{&app.window}
	start := time.tick_now()
	for !done(app, words) {
		if time.tick_since(start) > DL_BOUND { return false }
		due, wake := host.hosts_due(hosts[:])
		if !due && !ui.posts_pending(&app.state) {
			if wake == 0 {
				platform.wait_event(app.win, DL_REST_WAIT_MS)
				continue
			}
			s.clock += f64(wake)
		}
		session.frame(s)
	}
	return true
}

// The loop would sleep now: no frame due, no post waiting.
@(private = "file")
dl_at_rest :: proc(app: ^App, _: string) -> bool {
	hosts := [1]^host.Host{&app.window}
	due, _ := host.hosts_due(hosts[:])
	return !due && !ui.posts_pending(&app.state)
}

// The loop would sleep until input: at rest, and no timed wake asked.
@(private = "file")
dl_asleep :: proc(app: ^App, _: string) -> bool {
	hosts := [1]^host.Host{&app.window}
	due, wake := host.hosts_due(hosts[:])
	return !due && wake == 0 && !ui.posts_pending(&app.state)
}

// The status bar's pill says `words`.
@(private = "file")
pill_says :: proc(app: ^App, words: string) -> bool {
	pill := ui.box_find(&app.state, "downloads")
	return pill != nil && ui.box_find(&app.state, "", words, within = pill) != nil
}

// The pill follows the bytes while the window rests: two chunks come within one step, then the server is silent; the
// second shows all the same, and so does the end, with no input and no frame of the test's own.
@(test)
the_pill_follows_the_bytes_at_rest :: proc(t: ^testing.T) {
	unwatched.run(t, proc(t: ^testing.T) {
		context.allocator = runtime.heap_allocator()
		app, s := bench_app(t)
		app.announcer.mode = .Window   // (the pill: no notification on this desktop)
		c, f := dl_fake_conn(app, "0123456789")
		defer { downloads_stop(app); app.conn = nil }
		f.hold_after = 0
		target := fmt.tprintf("%s/r.bin", dl_dir(t, "rest"))
		session.activate(s, false)   // (no caret that blinks: nothing wakes the window but the download)
		session.wait_idle(s)
		d := download_start(app, c, download_read_path("/srv", "/srv/r.bin"), "r.bin", target)
		testing.expect(t, dl_rest_until(s, pill_says, "1"), "the pill: one download, no size yet")
		sync.sema_post(&f.gate)
		testing.expect(t, dl_rest_until(s, pill_says, i18n.percent(0.4)), "the first chunk")
		testing.expect(t, dl_rest_until(s, dl_at_rest, ""), "the window rests")
		// (the second chunk within the step of the first, then the server is silent)
		sync.sema_post(&f.gate)
		testing.expect(t, dl_rest_until(s, pill_says, i18n.percent(0.8)), "the second chunk shows while the server is silent")
		testing.expect(t, dl_rest_until(s, dl_asleep, ""), "then the window sleeps until the next chunk: no wake while nothing comes")
		sync.sema_post(&f.gate)
		done :: proc(app: ^App, words: string) -> bool { return app.downloads.list[0].state == .Done && pill_says(app, words) }
		testing.expect(t, dl_rest_until(s, done, "1"), "its end")
		testing.expect_value(t, d.state, Download_State.Done)
	})
}

// A running download shows in the pill even when its notification shows: a toast the system muted cannot be told from one
// it shows, and the window is the one place sure to be seen.
@(test)
a_running_download_shows_in_the_pill_beside_its_notification :: proc(t: ^testing.T) {
	unwatched.run(t, proc(t: ^testing.T) {
		context.allocator = runtime.heap_allocator()
		app, s := bench_app(t)
		app.announcer.mode = .Window   // (no notification asked of this desktop: its state is set below)
		c, f := dl_fake_conn(app, "0123456789")
		defer { downloads_stop(app); app.conn = nil }
		f.hold_after = 1
		target := fmt.tprintf("%s/n.bin", dl_dir(t, "noted"))
		d := download_start(app, c, download_read_path("/srv", "/srv/n.bin"), "n.bin", target)
		testing.expect(t, dl_until(app, dl_got, d), "the first chunk came")
		d.note, d.note_id = .Shown, 1   // (the system said it shows it)
		defer d.note = .Off   // (its end sends nothing to this desktop)
		session.frames(s, 2)
		testing.expect(t, pill_says(app, i18n.percent(0.4)), "the pill says its progress")
		session.click(s, "downloads")
		session.frames(s, 2)
		testing.expect(t, session.find_text(s, fmt.tprintf(i18n.tr("Cancel %s, %s"), d.name, download_progress_words(d))) != nil, "its Cancel in the pill's menu")
		session.key(s, .Escape)
		session.frames(s, 2)
	})
}

// The session's files (Ctrl+P): a file's row menu offers Download, a folder's offers nothing.
@(test)
a_file_of_the_browser_can_be_downloaded :: proc(t: ^testing.T) {
	unwatched.run(t, proc(t: ^testing.T) {
		context.allocator = runtime.heap_allocator()
		app, s := bench_app(t)
		pane := main_pane(app)
		app.conn = bench_conn(app)
		defer { bench_clear(app); app.conn = nil }
		files_open(app, pane)
		session.frames(s, 3)
		bench_answer(app, bench_take(t, .Server_Files_List), 200, `{"data":[{"path":"src/","type":"directory"},{"path":"README.md","type":"file"}]}`)
		session.wait_idle(s)
		session.key(s, .Down)   // (the folder)
		session.key(s, .F10, {.Shift})
		session.frames(s, 2)
		testing.expect(t, session.find_text(s, "Download") == nil, "no Download on a folder")
		session.key(s, .Down)   // (README.md)
		session.key(s, .F10, {.Shift})
		session.frames(s, 2)
		testing.expect(t, session.find_text(s, "Download") != nil, "Download in a file's row menu")
		session.key(s, .Escape)
		session.key(s, .Escape)
		session.wait_until(s, proc(s: ^session.Session) -> bool { return !ui.file_dialog_shown(&(^App)(s.user).state) }, "closed")
	})
}
