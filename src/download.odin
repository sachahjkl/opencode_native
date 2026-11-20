// A file of the server's computer, which may be another one, downloaded to this computer: asked from a tool call's menu, a
// path selected in a message, the palette, or a row of the file browser; one streamed request on the downloads' own
// workers, through a temp that takes the target's name at the end; its progress in the status bar's pill, and in a
// notification of the system when there is one. src/md/features/remote-download.md says why it is made this way.
package ocn

import "base:runtime"
import "core:fmt"
import "core:math"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sync"
import "core:time"
import fsx "gt:fsx"
import "gt:host"
import tk_http "gt:http"
import "gt:platform"
import tasks "gt:tasks"
import "gt:timefmt"
import "gt:ui"
import lucide "gt:lucide"
import i18n "gt:i18n"

// Downloads at once; the others wait their turn. Not the connection's workers: a long one would hold one of theirs.
DOWNLOAD_WORKERS :: 3
// How long the program's end waits for its downloads to see their stop.
DOWNLOAD_STOP_BOUND :: 3 * time.Second
// How often the interface looks at a download's bytes while they come: the pill's percent and the notification's bar
// move this often, and the window rests once a look finds nothing new.
DOWNLOAD_STEP_MS :: 250
// The menu of the status bar's pill.
DOWNLOADS_MENU_KEY :: "downloads_menu"
// The buttons of a download's notification.
DOWNLOAD_ACT_CANCEL :: 1
DOWNLOAD_ACT_OPEN :: 2
DOWNLOAD_ACT_SHOW :: 3

Download_State :: enum u8 { Queued, Running, Done, Failed, Cancelled }

// Where a download is shown: Off and Gone are the pill's (no notification, or the person closed it).
Download_Note :: enum u8 { Off, Asking, Shown, Gone }

Download :: struct {
	app:    ^App,
	conn:   ^Conn,     // held until its end (download_ended): it goes by the server it was asked of
	n:      int,       // its number in this run
	name:   string,    // the file's name (owned)
	read:   string,    // the GET's path and query (owned)
	target: string,    // where it goes (heap). "" with `to_downloads`: its worker chooses it before it starts
	to_downloads: bool,   // the row action's: into this computer's Downloads, under a name not taken there
	// (the interface's) only download_ended moves it to an end
	state:  Download_State,
	// (atomic) written by its worker, read by the interface
	got:     i64,
	total:   i64,    // -1: not known
	running: bool,
	// the interface looks at the counts every step (downloads_look): a chunk then posts nothing. False: the next chunk
	// posts, and the looks start again
	watched: bool,
	stop:    tk_http.Stop,   // asked: by Cancel, or the program's end
	shown:   i64,            // (the interface's) the bytes its last look showed
	// the temp's name between its worker and the program's end (under lock)
	lock:      sync.Mutex,
	temp:      string,   // (heap) "" until the writer opened
	temp_gone: bool,     // its worker committed or aborted it, or the end removed it
	ending:    bool,     // the program's end came: the worker opens no file and commits nothing
	// written by its worker before it posts its end
	ended: Download_State,
	why:   string,     // Failed: the reason, said once (heap)
	// its notification (the interface's)
	note:       Download_Note,
	note_id:    platform.Notification_Id,
	note_again: bool,   // it changed while the first one was asked: sent once its id came
}

Downloads :: struct {
	list:    [dynamic]^Download,   // in the order asked
	pool:    tasks.Pool,
	started: bool,
	seq:     int,
	shown:   string,   // the last file of the pill downloaded: a click on its toast shows it (owned)
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

// A connection that can download, else said.
@(private = "file")
download_conn :: proc(app: ^App) -> ^Conn {
	if app.conn == nil || app.conn.transport.receive == nil {
		ui.announce(&app.announcer, .Warn, i18n.tr("Not connected"))
		return nil
	}
	return app.conn
}

@(private = "file")
Download_Ask :: struct {
	app:  ^App,
	conn: ^Conn,     // held while the dialog asks
	name: string,    // (owned)
	read: string,    // (owned)
}

// "Download…": where to put the file `path` of the server (absolute, or from `dir`) is asked, then it comes. The save
// dialog starts where the last download went, else in this computer's Downloads (the toolkit asks the system).
download_ask :: proc(app: ^App, path, dir: string) {
	c := download_conn(app)
	if c == nil { return }
	name := download_name(path)
	if name == "" { return }
	a := new(Download_Ask)
	a^ = {app, c, strings.clone(name), strings.clone(download_read_path(dir, path))}
	conn_hold(c)
	ui.file_dialog(&app.state, .Save, {owner = app.win, title = fmt.tprintf(i18n.tr("Download %s"), a.name), start_known = .Downloads, suggested_name = a.name, remember_id = "download", overwrite_prompt = true, act = i18n.tr("Download")}, proc(r: platform.Dialog_Result, user: rawptr) {
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

// The file browser's "Download" on a row: the file goes straight to this computer's Downloads, and the browser stays
// open (one toolkit dialog shows at a time: a Save dialog would close it).
download_row_action :: proc(app: ^App) -> platform.File_Row_Action {
	return {label = i18n.tr("Download"), icon = lucide.DOWNLOAD, act = proc(user: rawptr, path: string) {
		app := (^App)(user)
		c := download_conn(app)
		name := download_name(path)
		if c == nil || name == "" { return }
		download_start(app, c, download_read_path(pane_dir(app, main_pane(app)), path), name, "")
	}, user = app}
}

// "Download a file…" (the palette): the server's files in the file browser, one chosen, then where it goes; a row's
// Download sends a file to Downloads at once.
download_pick :: proc(app: ^App) {
	pane := main_pane(app)
	dir := pane_dir(app, pane)
	if dir == "" { dir = pane.chat.new_dir }
	places: []platform.File_Place
	if dir != "" { places = {{name = base_name(dir), path = dir}} }
	Pick :: struct { app: ^App, dir: string }
	p := new(Pick)
	p^ = {app, strings.clone(dir)}
	acts := []platform.File_Row_Action{download_row_action(app)}
	ui.file_dialog(&app.state, .Open, {owner = app.win, title = i18n.tr("Download a file"), start_dir = dir, places = places, all_files = true, find_deep = true, act = i18n.tr("Download"), remember_id = "download_pick", row_actions = acts}, proc(r: platform.Dialog_Result, user: rawptr) {
		p := (^Pick)(user)
		defer { delete(p.dir); free(p) }
		if r.status == .Chosen && len(r.paths) > 0 { download_ask(p.app, r.paths[0], p.dir) }
	}, p, source = folders_are_here(app) ? nil : server_files(app, dir))
}

// The download, on its way: `c` is held for it until its end. `target` "": into this computer's Downloads.
download_start :: proc(app: ^App, c: ^Conn, read, name, target: string) -> ^Download {
	ds := &app.downloads
	if !ds.started {
		tasks.start(&ds.pool, {threads = DOWNLOAD_WORKERS})
		ds.started = true
	}
	ds.seq += 1
	h := runtime.heap_allocator()
	d := new(Download)
	d^ = {app = app, conn = c, n = ds.seq, name = strings.clone(name), read = strings.clone(read), target = strings.clone(target, h), to_downloads = target == "", total = -1}
	conn_hold(c)
	append(&ds.list, d)
	// (a system's notification when the person's messages go to the system; else the pill)
	if app.win != nil && app.announcer.mode == .System && !app.announcer.missing {
		d.note = .Asking
		if !platform.notify_async(app.win, download_notification(d), download_noted, d) { d.note = .Off }
	}
	if !tasks.add(&ds.pool, download_run, d) {
		d.ended, d.why = .Failed, strings.clone(i18n.tr("the program is ending"), h)
		download_ended(d, 0)
	}
	return d
}

download_cancel :: proc(d: ^Download) { tk_http.stop_ask(&d.stop) }

// The finished ones of the pill leave it.
downloads_clear :: proc(app: ^App) {
	ds := &app.downloads
	for i := 0; i < len(ds.list); {
		d := ds.list[i]
		if download_in_pill(d) && (d.state == .Done || d.state == .Failed) {
			ordered_remove(&ds.list, i)
			download_free(d)
		} else {
			i += 1
		}
	}
}

// A download the pill shows: every one that runs, whether its notification shows or not (a toast the system muted
// cannot be told from one it shows: the window is the one place sure to be seen); a finished one when it has no
// notification to say its end.
download_in_pill :: proc(d: ^Download) -> bool {
	#partial switch d.state {
	case .Queued, .Running: return true
	}
	return d.note == .Off || d.note == .Gone
}

// Out of the list, and freed.
@(private = "file")
download_drop :: proc(d: ^Download) {
	ds := &d.app.downloads
	for x, i in ds.list { if x == d { ordered_remove(&ds.list, i); break } }
	download_free(d)
}

@(private = "file")
download_free :: proc(d: ^Download) {
	h := runtime.heap_allocator()
	delete(d.name); delete(d.read)
	delete(d.target, h); delete(d.temp, h); delete(d.why, h)
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
	download_wake(d)
	d.ended = download_transfer(d)
	free_all(context.temp_allocator)
	_ = ui.post(&d.app.state, download_ended, d)
}

// What a transfer's chunks share, on the request's thread.
@(private = "file")
Download_Sink :: struct {
	d:    ^Download,
	w:    fsx.Writer,
	open: bool,
	why:  string,      // the disk refused: the reason (static)
}

// The interface told that bytes came, unless it already looks at them every step. (A wake per step from here would leave
// the bytes of the step's end unshown while the server is silent: only the interface's own timer comes back for them.)
@(private = "file")
download_wake :: proc(d: ^Download) {
	if !sync.atomic_exchange(&d.watched, true) { _ = ui.post(&d.app.state, download_moved, d) }
}

// The stream to the writer; the writer committed at a whole body, aborted on any other end.
@(private = "file")
download_transfer :: proc(d: ^Download) -> Download_State {
	if d.to_downloads {
		t, why := download_free_target(d.name)
		if why != "" { d.why = strings.clone(why); return .Failed }
		d.target = t
	}
	s := Download_Sink{d = d}
	a := d.conn.transport.receive(d.conn, d.read, download_part, &s, &d.stop)
	got, total := sync.atomic_load(&d.got), sync.atomic_load(&d.total)
	end := Download_State.Done
	why := ""
	switch {
	case s.why != "":
		end, why = .Failed, s.why
	case sync.atomic_load(&d.stop.asked) || a.err == .Stopped:
		end = .Cancelled
	case a.err != .None:
		end, why = .Failed, got > 0 ? i18n.tr("the connection was cut during the download") : tk_http.error_text(a.err)
	case a.status < 200 || a.status > 299:
		end, why = .Failed, download_refusal(a.status)
	case total >= 0 && got != total:
		// (a file truncated or rewritten while it is read ends before the length the server announced)
		end, why = .Failed, i18n.tr("the file changed or the connection was cut during the download")
	case !s.open:
		// (an empty file: a whole body, and no chunk)
		if !download_open(d, &s) { end, why = .Failed, i18n.tr("the file could not be made") }
	}
	sync.lock(&d.lock)
	if s.open {
		if end == .Done && !d.ending {
			if download_io_hook != nil { download_io_hook(d.target) }
			if !fsx.writer_commit(&s.w) { end, why = .Failed, i18n.tr("the file could not be put in its place") }
		} else {
			if download_io_hook != nil { download_io_hook(s.w.temp) }
			fsx.writer_abort(&s.w)
			if end == .Done { end = .Cancelled }
		}
	}
	d.temp_gone = true
	sync.unlock(&d.lock)
	if why != "" { d.why = strings.clone(why) }
	return end
}

// One chunk to the temp; the interface told when it does not look already.
@(private = "file")
download_part :: proc(user: rawptr, part: tk_http.Body_Part) -> tk_http.Keep_Going {
	s := (^Download_Sink)(user)
	d := s.d
	context.allocator = runtime.heap_allocator()
	if sync.atomic_load(&d.stop.asked) { return .Stop }
	if !s.open {
		if !download_open(d, s) { s.why = i18n.tr("the file could not be made"); return .Stop }
		sync.atomic_store(&d.total, part.length)
	}
	if download_io_hook != nil { download_io_hook(s.w.temp) }
	if !fsx.writer_append(&s.w, part.bytes) { s.why = i18n.tr("the file could not be written"); return .Stop }
	sync.atomic_store(&d.got, part.received)
	download_wake(d)
	return .Continue
}

// The writer opened beside the target, its temp's name published for the program's end. False: it cannot be made, or
// the program is ending.
@(private = "file")
download_open :: proc(d: ^Download, s: ^Download_Sink) -> bool {
	sync.lock(&d.lock)
	defer sync.unlock(&d.lock)
	if d.ending { return false }
	if download_io_hook != nil { download_io_hook(d.target) }
	if !fsx.writer_open(&s.w, d.target) { return false }
	d.temp = strings.clone(s.w.temp, runtime.heap_allocator())
	s.open = true
	return true
}

// A path in this computer's Downloads for `name` that no file takes: "a.txt", else "a (1).txt", "a (2).txt"...
@(private = "file")
download_free_target :: proc(name: string) -> (path, why: string) {
	folder := platform.known_folder_path(.Downloads, context.temp_allocator)
	if folder == "" { return "", i18n.tr("this computer has no Downloads folder") }
	stem, ext := name, ""
	if dot := strings.last_index_byte(name, '.'); dot > 0 { stem, ext = name[:dot], name[dot:] }
	for i in 0 ..< 1000 {
		n := i == 0 ? name : fmt.tprintf("%s (%d)%s", stem, i, ext)
		p, _ := filepath.join({folder, n}, context.temp_allocator)
		if download_io_hook != nil { download_io_hook(p) }
		if !os.exists(p) { return strings.clone(p), "" }
	}
	return "", i18n.tr("the Downloads folder has too many files of this name")
}

// Why the server refused, from its status: receive gives no body of a refusal.
@(private = "file")
download_refusal :: proc(status: int) -> string {
	switch status {
	case 404: return i18n.tr("the file is not on the server")
	case 401: return i18n.tr("Authentication refused by the server")
	case 403: return i18n.tr("the server refused to give this file")
	}
	return fmt.tprintf(i18n.tr("the server answered %d"), status)
}

////////////////////////////////
// Back on the interface's thread

// Its worker started, or bytes came while the interface did not look: the post woke the window, whose build reads the
// counts; the looks start.
@(private = "file")
download_moved :: proc(data: rawptr, word: u64) {
	d := (^Download)(data)
	if d.state == .Queued { d.state = .Running }
	download_shown(d)
	downloads_look_ask(d.app)
}

// What came is shown: the pill reads the counts at its build; a notification is sent again.
@(private = "file")
download_shown :: proc(d: ^Download) {
	d.shown = sync.atomic_load(&d.got)
	if d.state == .Running { download_note_send(d) }
}

@(private = "file")
downloads_look_ask :: proc(app: ^App) {
	if app.cx.due[.Downloads].due_ms == 0 { ui.deferred_ask(&app.cx.due[.Downloads], DOWNLOAD_STEP_MS) }
}

// A step after the last look (Due.Downloads, after a frame): the bytes that came since are shown, and the looks go on;
// a download with none goes back to its worker's post, and the window rests. A frame per step while bytes come, one
// more after they stop: never a wake while nothing comes.
downloads_look :: proc(app: ^App) {
	again := false
	for d in app.downloads.list {
		if d.state != .Running || !sync.atomic_load(&d.watched) { continue }
		if sync.atomic_load(&d.got) != d.shown {
			download_shown(d)
			again = true
			continue
		}
		sync.atomic_store(&d.watched, false)
		// (a chunk between the look and the store found it watched, and posted nothing)
		if sync.atomic_load(&d.got) != d.shown && !sync.atomic_exchange(&d.watched, true) {
			download_shown(d)
			again = true
		}
	}
	if again {
		host.host_settle(&app.window)   // (after the frame's build: the next one shows it)
		downloads_look_ask(app)
	}
}

// Its end, said once: in its notification, else by a toast. A cancel says nothing: the person did it.
@(private = "file")
download_ended :: proc(data: rawptr, word: u64) {
	d := (^Download)(data)
	app := d.app
	d.state = d.ended
	conn_release(app, d.conn)
	d.conn = nil
	switch d.state {
	case .Queued, .Running:
	case .Done, .Failed:
		if download_in_pill(d) { download_announce(d) } else { download_note_send(d) }
	case .Cancelled:
		switch d.note {
		case .Asking:   // (its answer drops it)
		case .Shown:
			platform.notify_close(app.win, d.note_id)
			download_drop(d)
		case .Off, .Gone:
			download_drop(d)
		}
	}
}

// The end of a download of the pill, as a toast.
@(private = "file")
download_announce :: proc(d: ^Download) {
	app := d.app
	#partial switch d.state {
	case .Done:
		delete(app.downloads.shown)
		app.downloads.shown = strings.clone(d.target)
		ui.announce(&app.announcer, .Good, fmt.tprintf(i18n.tr("Downloaded %s"), d.name), d.target, action = proc(user: rawptr) {
			a := (^App)(user)
			if a.downloads.shown != "" { reveal_path(a.downloads.shown) }
		}, user = app)
	case .Failed:
		ui.announce(&app.announcer, .Bad, fmt.tprintf(i18n.tr("%s was not downloaded"), d.name), d.why)
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
		sync.lock(&d.lock)
		d.ending = true
		if d.temp != "" && !d.temp_gone {
			_ = os.remove(d.temp)
			d.temp_gone = true
		}
		sync.unlock(&d.lock)
	}
}

////////////////////////////////
// Its notification

// The share of its bytes that came: 0 to 1; -1 when no size is known.
download_share :: proc(d: ^Download) -> f32 {
	got, total := sync.atomic_load(&d.got), sync.atomic_load(&d.total)
	return total > 0 ? f32(f64(got) / f64(total)) : -1
}

// The notification of `d` as it stands: its bar and Cancel while it runs; what came of it at its end (another shape: the
// system shows it again). Its texts are in the temp allocator.
download_notification :: proc(d: ^Download) -> platform.Notification {
	#partial switch d.state {
	case .Done:
		acts := make([]platform.Notification_Action, 2, context.temp_allocator)
		acts[0], acts[1] = {DOWNLOAD_ACT_OPEN, i18n.tr("Open")}, {DOWNLOAD_ACT_SHOW, i18n.tr("Show in folder")}
		return {title = fmt.tprintf(i18n.tr("Downloaded %s"), d.name), body = d.target, actions = acts, replace = d.note_id}
	case .Failed:
		return {title = fmt.tprintf(i18n.tr("%s was not downloaded"), d.name), body = d.why, replace = d.note_id}
	}
	acts := make([]platform.Notification_Action, 1, context.temp_allocator)
	acts[0] = {DOWNLOAD_ACT_CANCEL, i18n.tr("Cancel")}
	return {title = d.name, actions = acts, silent = true, replace = d.note_id, progress = {shown = true, value = download_share(d), status = download_progress_words(d)}}
}

// Its notification sent again as it stands, when it has one.
@(private = "file")
download_note_send :: proc(d: ^Download) {
	switch d.note {
	case .Off, .Gone: return
	case .Asking:     d.note_again = true; return
	case .Shown:
	}
	if !platform.notify_async(d.app.win, download_notification(d)) {
		d.note = .Gone
		if d.state == .Done || d.state == .Failed { download_announce(d) }
	}
}

// The system's answer to its first notification: its id, or none (the pill then).
@(private = "file")
download_noted :: proc(user: rawptr, id: platform.Notification_Id, ok: bool) {
	d := (^Download)(user)
	again := d.note_again
	d.note_again = false
	d.note, d.note_id = ok ? .Shown : .Off, ok ? id : 0
	switch d.state {
	case .Queued, .Running:
		if again { download_note_send(d) }
	case .Done, .Failed:
		if ok { download_note_send(d) } else { download_announce(d) }
	case .Cancelled:
		if ok { platform.notify_close(d.app.win, id) }
		download_drop(d)
	}
}

// What a download's notification came back with. False: the id is no download's.
downloads_notification_event :: proc(app: ^App, e: platform.Event) -> bool {
	d: ^Download
	for x in app.downloads.list { if x.note == .Shown && x.note_id == e.notification.id { d = x; break } }
	if d == nil { return false }
	#partial switch e.kind {
	case .Notification_Action:
		switch e.notification.action {
		case DOWNLOAD_ACT_CANCEL: download_cancel(d)
		case DOWNLOAD_ACT_OPEN:   if d.state == .Done { ui.open(d.target, .Path) }
		case DOWNLOAD_ACT_SHOW:   if d.state == .Done { reveal_path(d.target) }
		}
	case .Notification_Click:
		if d.state == .Done { reveal_path(d.target) }
	case .Notification_Closed:
		// (an end said and seen goes; a running one the person closed goes on in the pill, its Cancel there)
		if d.state == .Done || d.state == .Failed { download_drop(d) } else { d.note = .Gone }
	}
	return true
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

// The share of the pill's running ones' bytes that came, and how many run (share < 0: no total known).
downloads_share :: proc(app: ^App) -> (share: f64, running: int) {
	got, total: i64
	known := true
	for d in app.downloads.list {
		if !download_in_pill(d) || (d.state != .Queued && d.state != .Running) { continue }
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
	shown := 0
	for d in app.downloads.list { if download_in_pill(d) { shown += 1 } }
	if shown == 0 { return }
	share, running := downloads_share(app)
	label: string
	switch {
	case running > 0 && share >= 0: label = i18n.percent(share)
	case running > 0:               label = fmt.tprintf("%d", running)
	case:                           label = fmt.tprintf("%d", shown)
	}
	sig := ui.button("###downloads", label, lucide.DOWNLOAD, o = {face = .Ghost, height = math.round(em * PILL_H_EM)})
	if sig.clicked { ui.menu_open(DOWNLOADS_MENU_KEY, sig.box.rect, sig.box.key, align = .End) }
	ui.space(ui.SPACE_2)
	if ui.menu(DOWNLOADS_MENU_KEY) { downloads_menu(app) }
}

@(private = "file")
downloads_menu :: proc(app: ^App) {
	finished := 0
	for d in app.downloads.list {
		if !download_in_pill(d) { continue }
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
