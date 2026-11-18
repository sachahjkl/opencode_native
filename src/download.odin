// A file of the server's computer, which may be another one, downloaded to this computer: asked from a tool call's menu, a
// path selected in a message, or the palette; saved where the person says, in ranges on the downloads' own workers, to a
// temp file renamed at the end. src/md/features/remote-download.md says why it is made this way.
package ocn

import "base:runtime"
import tk_json "gt:json"
import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:os"
import "core:strings"
import "core:sync"
import "core:time"
import fsx "gt:fsx"
import "gt:platform"
import tasks "gt:tasks"
import "gt:timefmt"
import "gt:ui"
import lucide "gt:lucide"
import i18n "gt:i18n"

// One request per chunk: the memory a download holds, and how late a cancel is at most.
DOWNLOAD_CHUNK_BYTES :: 4 << 20
// Downloads at once; the others wait their turn. Not the connection's workers: a long one would hold one of theirs.
DOWNLOAD_WORKERS :: 3
// How long the program's end waits for its downloads to see their stop.
DOWNLOAD_STOP_BOUND :: 3 * time.Second
// The menu of the status bar's pill.
DOWNLOADS_MENU_KEY :: "downloads_menu"

Download_State :: enum u8 { Queued, Running, Done, Failed, Cancelled }

Download :: struct {
	app:    ^App,
	conn:   ^Conn,     // held until its end (download_ended): it goes by the server it was asked of
	n:      int,       // its number in this run: its temp's name, its menu's lines
	name:   string,    // the file's name (owned)
	read:   string,    // the GET's path and query (owned)
	target: string,    // where it goes (owned)
	temp:   string,    // beside it, renamed to it at the end (owned)
	chunk:  i64,
	// (the interface's) only download_ended moves it to an end
	state:  Download_State,
	// (atomic) written by its worker, read by the interface
	got:       i64,
	total:     i64,    // -1: not known yet
	running:   bool,
	stop:      bool,   // asked: by Cancel, or the program's end
	temp_gone: bool,   // its worker renamed or removed the temp
	// written by its worker before it posts its end
	ended: Download_State,
	why:   string,     // Failed: the reason, said once (owned)
}

Downloads :: struct {
	list:    [dynamic]^Download,   // in the order asked
	pool:    tasks.Pool,
	started: bool,
	seq:     int,
	folder:  string,   // this computer's Downloads folder (owned), known once a chore read it
	known:   bool,
	chunk:   i64,      // 0: DOWNLOAD_CHUNK_BYTES (a test's is smaller)
	shown:   string,   // the last file downloaded: a click on its toast shows it (owned)
}

// A test sees each file operation of a download here, on the thread that makes it: never the interface's. nil: none.
download_io_hook: proc(path: string)

////////////////////////////////
// What a person asks for

// The GET of `path` on the server (absolute, or from `dir`): from the session's folder when the file is in it (a folder the
// server has loaded), else from the file's own folder. The server reads an absolute path in the address as a relative one.
download_read_path :: proc(dir, path: string) -> string {
	p := path_clean(path)
	d := path_clean(dir)
	absolute := strings.has_prefix(p, "/") || (len(p) >= 3 && p[1] == ':' && p[2] == '/')
	loc, rel := d, p
	switch {
	case !absolute:
	case d != "" && strings.has_prefix(p, d) && len(p) > len(d) && p[len(d)] == '/':
		rel = p[len(d) + 1:]
	case:
		cut := strings.last_index_byte(p, '/')
		loc, rel = p[:max(cut, 1)], p[cut + 1:]   // ("/x": the root's)
		if len(loc) == 2 && loc[1] == ':' { loc = p[:cut + 1] }   // ("C:/x": the drive's root)
	}
	q := location_query(loc)
	return q != "" ? fmt.tprintf("/api/fs/read/%s?%s", path_escape(rel), q) : fmt.tprintf("/api/fs/read/%s", path_escape(rel))
}

// What is shown of a path of the server: its last part, whatever its system's separators.
download_name :: proc(path: string) -> string {
	p := path_clean(path)
	return p[strings.last_index_byte(p, '/') + 1:]
}

// A selection that reads as a path: one line, no space at its ends, a separator or a dot in it.
download_path_of :: proc(sel: string) -> (path: string, ok: bool) {
	s := strings.trim(strings.trim_space(sel), "`'\"")
	if s == "" || len(s) > 1024 || strings.contains_any(s, "\n\r\t<>|*?") { return }
	if strings.has_prefix(s, "http://") || strings.has_prefix(s, "https://") { return }
	if !strings.contains_any(s, `/\.`) || strings.has_suffix(s, "/") || strings.has_suffix(s, `\`) { return }
	return s, true
}

@(private = "file")
Download_Ask :: struct {
	app:  ^App,
	conn: ^Conn,     // held while the dialog asks
	name: string,    // (owned)
	read: string,    // (owned)
}

// "Download…": where to put the file `path` of the server (absolute, or from `dir`) is asked, then it comes. The save
// dialog starts in this computer's Downloads folder, which a chore reads the first time.
download_ask :: proc(app: ^App, path, dir: string) {
	if app.conn == nil || app.conn.transport.range == nil {
		ui.announce(&app.announcer, .Warn, i18n.tr("Not connected"))
		return
	}
	name := download_name(path)
	if name == "" { return }
	a := new(Download_Ask)
	a^ = {app, app.conn, strings.clone(name), strings.clone(download_read_path(dir, path))}
	conn_hold(a.conn)
	if app.downloads.known { download_dialog(a); return }
	Folder :: struct { ask: ^Download_Ask, path: string }
	f := new(Folder, runtime.heap_allocator())
	f.ask = a
	ui.task(&app.state, proc(data: rawptr) {
		f := (^Folder)(data)
		f.path = platform.known_folder_path(.Downloads, runtime.heap_allocator())
	}, proc(data: rawptr, _: u64) {
		f := (^Folder)(data)
		d := &f.ask.app.downloads
		if !d.known { d.folder, d.known = strings.clone(f.path), true }
		delete(f.path, runtime.heap_allocator())
		a := f.ask
		free(f, runtime.heap_allocator())
		download_dialog(a)
	}, f, lost = proc(data: rawptr) {
		f := (^Folder)(data)
		delete(f.path, runtime.heap_allocator())
		free(f, runtime.heap_allocator())
	})
}

@(private = "file")
download_dialog :: proc(a: ^Download_Ask) {
	app := a.app
	ui.file_dialog(&app.state, .Save, {owner = app.win, title = fmt.tprintf(i18n.tr("Download %s"), a.name), start_dir = app.downloads.folder, suggested_name = a.name, remember_id = "download", overwrite_prompt = true, act = i18n.tr("Download")}, proc(r: platform.Dialog_Result, user: rawptr) {
		a := (^Download_Ask)(user)
		defer {
			conn_release(a.app, a.conn)
			delete(a.name); delete(a.read)
			free(a)
		}
		if r.status != .Chosen || len(r.paths) == 0 { return }
		download_start(a.app, a.conn, a.read, a.name, r.paths[0])
	}, a)
}

// "Download a file…" (the palette): the server's files in the file browser, one chosen, then where it goes.
download_pick :: proc(app: ^App) {
	pane := main_pane(app)
	dir := pane_dir(app, pane)
	if dir == "" { dir = pane.chat.new_dir }
	places: []platform.File_Place
	if dir != "" { places = {{name = base_name(dir), path = dir}} }
	Pick :: struct { app: ^App, dir: string }
	p := new(Pick)
	p^ = {app, strings.clone(dir)}
	ui.file_dialog(&app.state, .Open, {owner = app.win, title = i18n.tr("Download a file"), start_dir = dir, places = places, all_files = true, find_deep = true, act = i18n.tr("Download"), remember_id = "download_pick"}, proc(r: platform.Dialog_Result, user: rawptr) {
		p := (^Pick)(user)
		defer { delete(p.dir); free(p) }
		if r.status == .Chosen && len(r.paths) > 0 { download_ask(p.app, r.paths[0], p.dir) }
	}, p, source = folders_are_here(app) ? nil : server_files(app, dir))
}

// The download, on its way: `c` is held for it until its end.
download_start :: proc(app: ^App, c: ^Conn, read, name, target: string) -> ^Download {
	ds := &app.downloads
	if !ds.started {
		tasks.start(&ds.pool, {threads = DOWNLOAD_WORKERS})
		ds.started = true
	}
	ds.seq += 1
	d := new(Download)
	d^ = {app = app, conn = c, n = ds.seq, name = strings.clone(name), read = strings.clone(read), target = strings.clone(target), total = -1, chunk = ds.chunk > 0 ? ds.chunk : DOWNLOAD_CHUNK_BYTES}
	d.temp = fmt.aprintf("%s.ocn-%d.part", target, d.n)
	conn_hold(c)
	append(&ds.list, d)
	if !tasks.add(&ds.pool, download_run, d) {
		d.ended, d.why = .Failed, strings.clone(i18n.tr("the program is ending"), runtime.heap_allocator())
		download_ended(d, 0)
	}
	return d
}

download_cancel :: proc(d: ^Download) { sync.atomic_store(&d.stop, true) }

// The finished ones leave the pill's menu.
downloads_clear :: proc(app: ^App) {
	ds := &app.downloads
	for i := 0; i < len(ds.list); {
		d := ds.list[i]
		if d.state == .Done || d.state == .Failed {
			ordered_remove(&ds.list, i)
			download_free(d)
		} else {
			i += 1
		}
	}
}

@(private = "file")
download_free :: proc(d: ^Download) {
	delete(d.name); delete(d.read); delete(d.target); delete(d.temp)
	delete(d.why, runtime.heap_allocator())
	free(d)
}

////////////////////////////////
// On its worker

@(private = "file")
download_run :: proc(data: rawptr) {
	d := (^Download)(data)
	// (the pool's context is the one it started in, a test's tracker maybe: what this thread allocates is the heap's)
	context.allocator = runtime.heap_allocator()
	sync.atomic_store(&d.running, true)
	_ = ui.post(&d.app.state, download_moved, d)
	d.ended = download_transfer(d)
	_ = ui.post(&d.app.state, download_ended, d)
}

// The ranges, one after the other, appended to the temp; the temp renamed to the target at the end, removed on any other.
@(private = "file")
download_transfer :: proc(d: ^Download) -> Download_State {
	c := d.conn
	from: i64 = 0
	etag := ""
	defer delete(etag)
	end := Download_State.Done
	why := ""
	written := false   // the temp exists
	loop: for {
		if sync.atomic_load(&d.stop) { end = .Cancelled; break }
		a := c.transport.range(c, d.read, from, from + d.chunk - 1, etag, context.allocator)
		defer range_answer_destroy(&a, context.allocator)
		if !a.ok { end, why = .Failed, a.why; break }
		whole := false
		switch a.status {
		case 206:
			if from == 0 {
				etag = strings.clone(a.etag)
				sync.atomic_store(&d.total, a.total)
			}
			if len(a.body) == 0 { end, why = .Failed, i18n.tr("the server sent no bytes"); break loop }
		case 200:
			// (a file changed since the first range comes whole: not a file made of two versions)
			if from > 0 { end, why = .Failed, i18n.tr("the file changed during the download"); break loop }
			whole = true
			sync.atomic_store(&d.total, i64(len(a.body)))
		case 416:
			if from == 0 && a.total == 0 {   // (an empty file has no first byte)
				sync.atomic_store(&d.total, 0)
				whole = true
				break
			}
			end, why = .Failed, download_refusal(a); break loop
		case 401:
			end, why = .Failed, i18n.tr("Authentication refused by the server"); break loop
		case:
			end, why = .Failed, download_refusal(a); break loop
		}
		if w := download_append(d.temp, a.body, !written); w != "" { end, why = .Failed, w; break }
		written = true
		from += i64(len(a.body))
		sync.atomic_store(&d.got, from)
		_ = ui.post(&d.app.state, download_moved, d)
		total := sync.atomic_load(&d.total)
		if whole || (total >= 0 && from >= total) { break }
		// (a long download's words of each range; not on a way out: `why` may be among them)
		free_all(context.temp_allocator)
	}
	if end == .Done && sync.atomic_load(&d.stop) { end = .Cancelled }
	if end == .Done {
		if download_io_hook != nil { download_io_hook(d.target) }
		if !fsx.replace(d.temp, d.target, false) { end, why = .Failed, i18n.tr("the file could not be put in its place") }
	}
	if end != .Done && written {
		if download_io_hook != nil { download_io_hook(d.temp) }
		_ = os.remove(d.temp)
	}
	sync.atomic_store(&d.temp_gone, true)
	if why != "" { d.why = strings.clone(why, runtime.heap_allocator()) }
	return end
}

// What the server said when it refused: its message, else its status.
@(private = "file")
download_refusal :: proc(a: Range_Answer) -> string {
	v, _ := json.parse(a.body, parse_integers = true, allocator = context.temp_allocator)
	if msg := tk_json.text(v, "message"); msg != "" { return fmt.tprintf("%s (%d)", msg, a.status) }
	return fmt.tprintf(i18n.tr("the server answered %d"), a.status)
}

// `bytes` at the end of `path` (`first`: made, or emptied). Opened and closed each time: the program's end can then remove
// a temp a worker still has, on Windows too. The reason when it failed ("": written).
@(private = "file")
download_append :: proc(path: string, bytes: []u8, first: bool) -> string {
	if download_io_hook != nil { download_io_hook(path) }
	flags := first ? os.File_Flags{.Write, .Create, .Trunc} : os.File_Flags{.Write, .Append}
	f, err := os.open(path, flags, os.Permissions_Default_File)
	if err != nil { return os.error_string(err) }
	rest := bytes
	for len(rest) > 0 {
		n, werr := os.write(f, rest)
		if werr != nil { os.close(f); return os.error_string(werr) }
		rest = rest[n:]
	}
	if cerr := os.close(f); cerr != nil { return os.error_string(cerr) }
	return ""
}

////////////////////////////////
// Back on the interface's thread

// Its worker moved: the post woke the window, the pill reads the counts.
@(private = "file")
download_moved :: proc(data: rawptr, word: u64) {
	d := (^Download)(data)
	if d.state == .Queued { d.state = .Running }
}

// Its end, said once. A cancel says nothing: the person did it, and it leaves the menu.
@(private = "file")
download_ended :: proc(data: rawptr, word: u64) {
	d := (^Download)(data)
	app := d.app
	d.state = d.ended
	conn_release(app, d.conn)
	d.conn = nil
	switch d.state {
	case .Queued, .Running:
	case .Done:
		delete(app.downloads.shown)
		app.downloads.shown = strings.clone(d.target)
		ui.announce(&app.announcer, .Good, fmt.tprintf(i18n.tr("Downloaded %s"), d.name), d.target, action = proc(user: rawptr) {
			a := (^App)(user)
			if a.downloads.shown != "" { reveal_path(a.downloads.shown) }
		}, user = app)
	case .Failed:
		ui.announce(&app.announcer, .Bad, fmt.tprintf(i18n.tr("%s was not downloaded"), d.name), d.why)
	case .Cancelled:
		ds := &app.downloads
		for x, i in ds.list { if x == d { ordered_remove(&ds.list, i); break } }
		download_free(d)
	}
}

// The program's end: every download stops; what a worker still in a request left is removed here (the window is gone,
// nothing waits for a frame, as stores_close).
downloads_stop :: proc(app: ^App, bound := DOWNLOAD_STOP_BOUND) {
	ds := &app.downloads
	if !ds.started { return }
	for d in ds.list { download_cancel(d) }
	_ = tasks.stop(&ds.pool, bound = bound)
	ds.started = false
	for d in ds.list {
		if sync.atomic_load(&d.running) && !sync.atomic_load(&d.temp_gone) { _ = os.remove(d.temp) }
	}
}

////////////////////////////////
// The status bar's pill and its menu

// Where a download stands, in words: "45 % (12 MB of 27 MB)", "12 MB" when the server said no size, "waiting". The sizes
// are a file's, as the file managers count them (powers of 1024).
download_progress_words :: proc(d: ^Download) -> string {
	got, total := sync.atomic_load(&d.got), sync.atomic_load(&d.total)
	if !sync.atomic_load(&d.running) { return i18n.tr("waiting") }
	if total > 0 { return fmt.tprintf(i18n.tr("%s (%s of %s)"), i18n.percent(f64(got) / f64(total)), timefmt.size(got), timefmt.size(total)) }
	return timefmt.size(got)
}

// The share of the running ones' bytes that came, and how many run (share < 0: no total known).
downloads_share :: proc(app: ^App) -> (share: f64, running: int) {
	got, total: i64
	known := true
	for d in app.downloads.list {
		if d.state != .Queued && d.state != .Running { continue }
		running += 1
		t := sync.atomic_load(&d.total)
		if t < 0 { known = false; continue }
		got += sync.atomic_load(&d.got)
		total += t
	}
	if running == 0 || !known || total == 0 { return -1, running }
	return f64(got) / f64(total), running
}

downloads_pill :: proc(app: ^App, em: f32) {
	ds := &app.downloads
	if len(ds.list) == 0 { return }
	share, running := downloads_share(app)
	label: string
	switch {
	case running > 0 && share >= 0: label = i18n.percent(share)
	case running > 0:               label = fmt.tprintf("%d", running)
	case:                           label = fmt.tprintf("%d", len(ds.list))
	}
	sig := ui.button("###downloads", label, lucide.DOWNLOAD, o = {face = .Ghost, height = math.round(em * PILL_H_EM)})
	if sig.clicked { ui.menu_open(DOWNLOADS_MENU_KEY, sig.box.rect, sig.box.key, search = false, align = .End) }
	ui.space(ui.SPACE_2)
	if ui.menu(DOWNLOADS_MENU_KEY) { downloads_menu(app) }
}

@(private = "file")
downloads_menu :: proc(app: ^App) {
	ds := &app.downloads
	finished := 0
	for d in ds.list {
		switch d.state {
		case .Queued, .Running:
			if ui.menu_item(fmt.tprintf(i18n.tr("Cancel %s, %s"), d.name, download_progress_words(d)), icon = lucide.X, keep_open = true).clicked { download_cancel(d) }
		case .Done:
			finished += 1
			if ui.menu_item(fmt.tprintf(i18n.tr("Open %s"), d.name), icon = lucide.FILE).clicked { ui.open(d.target, .Path) }
			if ui.menu_item(fmt.tprintf(i18n.tr("Show %s in its folder"), d.name), icon = lucide.FOLDER).clicked { reveal_path(d.target) }
		case .Failed:
			finished += 1
			_ = ui.menu_item(fmt.tprintf("%s: %s", d.name, d.why), icon = lucide.CIRCLE_X, disabled = true)
		case .Cancelled:
		}
	}
	ui.menu_separator()
	if ui.menu_item(i18n.tr("Clear the finished ones"), icon = lucide.CHECK, disabled = finished == 0).clicked { downloads_clear(app) }
}
