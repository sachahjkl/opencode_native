// The Terminal panel: shells of the server (its PTYs), wherever the server runs, shown and typed in here. Emulation is libghostty-vt's
// (vt.odin): the bytes of a PTY go in, the grid comes out, and the keys go through its encoders, so that what programs ask of a terminal
// is answered as Ghostty answers it.
//
// A shell is a tab of the dock (preview.odin): moved, stacked, split and closed like any panel. Its panel id is its own, from
// TERM_PANEL_BASE; the saved layout names it by the server's id, and a name no shell answers to is dropped there. Panel.Terminal is
// what stands in the dock while there is no shell yet: the reading of the list, a failure and its Try again.
//
// A thread per shell owns its WebSocket: it reads, posts what comes, and sends what waits in the shell's outbox between two reads. The
// interface only ever puts bytes in that box: it never waits for the network, whatever the shell does. The keys of the focused shell are taken out of the frame's events
// before the interface sees them (term_events): Ctrl+K belongs to the shell there, and Escape does not stop a run. Ctrl+Shift+C and V
// copy and paste. A shell outlives the program and a lost socket: it is found again when the panel opens, its output replayed by the
// server, and a socket that drops is opened again where it stopped. A shell lives on one server: Term.server is the connection everything
// about it goes by, and leaving that server leaves its shells running there (terminals_forget).
package ocn

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import "core:unicode/utf8"
import "gt:draw"
import "gt:font"
import "gt:platform"
import "gt:ui"
import lucide "gt:lucide"

// In the program, which is one file: the licence asks to go with the code.
GHOSTTY_LICENSE :: #load("../assets/GHOSTTY-LICENSE.txt", string)

// Where a shell's socket stands. Only its thread moves it, by term_news.
Term_Link :: enum u8 {
	Connecting,   // the first socket is on its way: what is typed waits in the outbox
	Attached,
	Lost,         // the socket went and the shell may run on: its thread tries again (Term.given_up: it stopped trying)
	Closed,       // the server says the shell is over
}

// What a shell's thread shares with the interface. (Never freed: a thread may still look at it after the shell is gone, and it is small.)
Term_Conn :: struct {
	stop:   bool,
	renew:  bool,          // (atomic) the socket may be dead without knowing it: opened again, from the cursor
	lock:   sync.Mutex,
	out:    [dynamic]u8,   // what goes to the shell
	cursor: i64,           // how far its output was read, as the server counts: where the next socket starts (the thread's while it runs)
}

Term :: struct {
	id, title, dir: string,   // (owned)
	server: ^Conn,            // the server it lives on: what is asked about it goes there
	panel:  u32,              // its tab in the dock
	link:   Term_Link,
	given_up: bool,           // Lost, and its thread is over: a click, or the server coming back, starts another
	vt:     Vt_Terminal,
	state:  Vt_State,
	rows_it: Vt_Rows,
	cells:  Vt_Cells,
	key_enc: Vt_Key_Encoder,
	key_ev:  Vt_Key_Event,
	mouse_enc: Vt_Mouse_Encoder,
	mouse_ev:  Vt_Mouse_Event,
	conn:   ^Term_Conn,
	cols, rows: u16,
	size_sent, size_asked: [2]u16,   // what the server was last told, what is on its way
	size_flying: bool,         // one at a time: the size that goes next is the last one
	grid_ms:  f64,             // when the grid last changed
	told_ms:  f64,             // when the shell took a size: what it paints then comes in pieces (0: nothing is awaited)
	fed_ms:   f64,             // when it last wrote
	asked_ms: f64,             // when the size on its way left (0: none is)
	drawn:    bool,            // its state was read once: there is a picture to keep
	fitted: bool,              // its grid was laid out: until then its size says nothing (a shell found again under another tab has its own)
	shown:  bool,              // its panel was built in this build
	read_only: bool,           // nothing goes to it (output_view.odin): the keys that are not for reading are the program's
	detached: bool,            // in a window of its own (detached.odin): no tab, and no part in the main window's input
	box:    ui.Key,
	rect:   draw.Rect,         // the grid, as last laid out
	// The selection is the emulation's own (VT_OPT_SELECTION): its ends follow their text as rows come, the view moves, the
	// scrollback drops its oldest rows or the grid is wrapped again. Only typing drops it.
	selecting: bool,           // the left button is held on the grid
	sel_anchor: Vt_Tracked_Ref, // the cell the drag began on (nil: none)
	sel_press:  [2]int,        // that cell, in the view at the press: a selection begins when the pointer leaves it
	formatter:  Vt_Formatter,  // what a copy reads the text through
	zoom:    f32,              // its own, times the program's size (Ctrl and the wheel, Ctrl+= - 0): kept by its id (term_zoom_set)
	zoom_ms: f64,              // when it last changed: the grid keeps its columns and rows until the zoom rests (term_fit)
	bar_at:  f32,              // where the grid's view put its box's scroll (term_scroll_sync): another place is its bar, moved
	metrics: Term_Metrics,     // as last laid out
}

// What the left button (or another, for a program) holds on a grid. Its release comes wherever the pointer is: a program that was told
// of the press is told of that too.
Term_Press :: enum u8 { None, Select, Program }

// The user asked for a shell to have the keyboard. It takes it when it is there, unless the focus went elsewhere meanwhile: an answer
// does not move the keyboard by itself. (`panel` 0: the next shell, the one on its way.)
Term_Focus_Ask :: struct { on: bool, panel: u32, from: ui.Key }

Terminals :: struct {
	only:    ^Term,            // while a window of its own is built: the one shell input may reach
	open:    bool,             // the shells have their tabs (hidden: they run on, out of the dock)
	read:    Remote,           // the list of the server's shells
	made:    Remote,           // a new shell on its way
	make_after: bool,          // one was asked for while the list was read: what it says comes first
	list:    [dynamic]^Term,
	gone:    [dynamic]^Term,   // closed in this frame: what was built for them is still to be drawn (terminals_reap)
	next_panel: u32,
	last_panel: u32,           // the last shell that had the keyboard: a new one goes beside it
	replaces:   u32,           // a shell restarted: the new one takes its tab
	close_due:  u32,           // a tab to close once the frame is built
	focused: ^Term,            // has the keyboard, in the last build (shown, and its grid has the focus)
	ask:     Term_Focus_Ask,
	press:   Term_Press,
	pressed: ^Term,
	press_button: platform.Mouse_Button,
	press_pos:    [2]f32,
	menu_for: ^Term,           // a right click asked for its menu (at menu_at): its next build opens it
	menu_at:  [2]f32,
}

// A grid's cells: its face's size (the program's size times its own zoom) and what follows from it.
Term_Metrics :: struct {
	font_size, cell_w, cell_h, ascent: f32,
	spacing, spacing_bold: f32,   // what a letter of the face (its bold) is short of a cell: a run is drawn on the grid
}

@(private = "file")
term_path :: proc(t: ^Term, tail := "") -> string {
	q := location_query(t.dir)
	return fmt.tprintf("/api/pty/%s%s%s%s", url_escape(t.id), tail, q != "" ? "?" : "", q)
}

// The emulation of a shell, connected to nothing yet.
term_new :: proc(id, title, dir: string, cols: u16 = TERM_COLS, rows: u16 = TERM_ROWS) -> ^Term {
	t := new(Term)
	t.id, t.title, t.dir = strings.clone(id), strings.clone(title), strings.clone(dir)
	t.cols, t.rows, t.zoom = cols, rows, 1
	if ghostty_terminal_new(nil, &t.vt, cols, rows) != VT_OK { return t }
	ghostty_render_state_new(nil, &t.state)
	ghostty_render_state_row_iterator_new(nil, &t.rows_it)
	ghostty_render_state_row_cells_new(nil, &t.cells)
	ghostty_key_encoder_new(nil, &t.key_enc)
	ghostty_key_event_new(nil, &t.key_ev)
	ghostty_mouse_encoder_new(nil, &t.mouse_enc)
	ghostty_mouse_event_new(nil, &t.mouse_ev)
	ghostty_formatter_terminal_new(nil, &t.formatter, t.vt)
	unwrap := true   // (a line the grid wrapped is copied as the program wrote it, as Ghostty copies)
	ghostty_formatter_set(t.formatter, VT_FORMAT_UNWRAP, &unwrap)
	lines: uint = TERM_SCROLLBACK_LINES
	ghostty_terminal_set(t.vt, VT_OPT_SCROLLBACK_MAX_LINES, &lines)
	ghostty_terminal_set(t.vt, VT_OPT_USERDATA, t)
	ghostty_terminal_set(t.vt, VT_OPT_WRITE_PTY, rawptr(term_answers))
	ghostty_terminal_set(t.vt, VT_OPT_TITLE_CHANGED, rawptr(term_title_changed))
	term_recolour(t)
	track := true
	ghostty_mouse_encoder_set(t.mouse_enc, VT_MOUSE_OPT_TRACK_LAST_CELL, &track)
	return t
}

rgb_of :: proc(x: u32) -> Vt_Rgb { return {u8(x >> 24), u8(x >> 16), u8(x >> 8)} }   // (0xRRGGBBAA)

// A colour the grid has: the program's own, as it asked for it (a theme moves only what the terminal chose: term_recolour).
@(private = "file")
color_of :: proc(c: Vt_Rgb) -> Color { return draw.hex(u32(c.r) << 24 | u32(c.g) << 16 | u32(c.b) << 8 | 0xff) }

// The grid's own background and text, the theme's.
term_recolour :: proc(t: ^Term) {
	if t.vt == nil { return }
	bg, fg := rgb_of(themed(HEX_TERM_BG)), rgb_of(themed(HEX_TEXT))
	ghostty_terminal_set(t.vt, VT_OPT_COLOR_BACKGROUND, &bg)
	ghostty_terminal_set(t.vt, VT_OPT_COLOR_FOREGROUND, &fg)
	palette := term_palette(bg, fg)
	ghostty_terminal_set(t.vt, VT_OPT_COLOR_PALETTE, &palette)
}

// The 256 colours a program asks for by number, in the theme shown: the 16 named ones are the theme's hues (as the code's and
// the diffs' are), the cube and the greys after them made between its background and its text (libghostty-vt's
// palette_generate). Ghostty's own were a console's, the same in every theme.
term_palette :: proc(bg, fg: Vt_Rgb) -> (palette: [256]Vt_Rgb) {
	named := [16]u32{
		HEX_BG3, HEX_RED, HEX_GREEN, HEX_YELLOW, HEX_BLUE, HEX_PURPLE, HEX_CYAN, HEX_TEXT_SOFT,
		HEX_FAINT, HEX_RED, HEX_GREEN, HEX_YELLOW, HEX_BLUE, HEX_PURPLE, HEX_CYAN, HEX_BRIGHT,
	}
	for c, i in named {
		x := themed(c)
		// (the bright eight: a step toward white, as terminals draw them)
		if i >= 9 && i <= 14 { l := lighten(draw.hex(x), 0.25); x = u32(l.r * 255) << 24 | u32(l.g * 255) << 16 | u32(l.b * 255) << 8 | 0xff }
		palette[i] = rgb_of(x)
	}
	keep: Vt_Palette_Mask
	keep.bits[0] = 0xffff   // (the 16 named: kept, the rest made from them)
	b, f := bg, fg
	ghostty_color_palette_generate(&palette[0], &keep, &b, &f, false, &palette[0])
	return
}

// Another theme: every grid's own colours follow it.
terms_recolour :: proc(app: ^App) {
	for t in app.cx.terms.list { term_recolour(t) }
	for v in app.cx.outputs.list { term_recolour(v.term) }
}

term_free :: proc(t: ^Term) {
	if t.detached { detached_forget(the_app, t.panel) }
	if t.conn != nil { sync.atomic_store(&t.conn.stop, true) }
	if t.vt != nil {
		ghostty_tracked_grid_ref_free(t.sel_anchor)
		ghostty_formatter_free(t.formatter)
		ghostty_mouse_event_free(t.mouse_ev)
		ghostty_mouse_encoder_free(t.mouse_enc)
		ghostty_key_event_free(t.key_ev)
		ghostty_key_encoder_free(t.key_enc)
		ghostty_render_state_row_cells_free(t.cells)
		ghostty_render_state_row_iterator_free(t.rows_it)
		ghostty_render_state_free(t.state)
		ghostty_terminal_free(t.vt)
	}
	delete(t.id); delete(t.title); delete(t.dir)
	free(t)
}

// What a program asks of the terminal is answered to it (device status, modes): it would wait for ever otherwise.
@(private = "file")
term_answers :: proc "c" (vt: Vt_Terminal, user: rawptr, data: [^]u8, n: uint) {
	context = runtime.default_context()
	term_send((^Term)(user), string(data[:n]))
}

@(private = "file")
term_title_changed :: proc "c" (vt: Vt_Terminal, user: rawptr) {
	context = runtime.default_context()
	t := (^Term)(user)
	s: Vt_String
	if ghostty_terminal_get(vt, VT_DATA_TITLE, &s) != VT_OK || s.len == 0 { return }
	delete(t.title)
	t.title = strings.clone(string(s.ptr[:s.len]))
}

// (Nothing reads the outbox of a shell without a socket: keys typed then are dropped, and they would run later, unseen.)
term_send :: proc(t: ^Term, s: string) {
	if t.conn == nil || len(s) == 0 || t.link >= .Lost { return }
	sync.lock(&t.conn.lock)
	if len(t.conn.out) + len(s) <= TERM_OUT_MAX { append(&t.conn.out, s) }
	sync.unlock(&t.conn.lock)
}

// (on the shell's thread)
@(private = "file")
term_flush :: proc(ws: rawptr, c: ^Term_Conn) {
	sync.lock(&c.lock)
	data := make([]u8, len(c.out), context.temp_allocator)
	copy(data, c.out[:])
	clear(&c.out)
	sync.unlock(&c.lock)
	if len(data) > 0 { _ = ocn_ws_send(ws, raw_data(data), len(data)) }
	free_all(context.temp_allocator)
}

////////////////////////////////
// The shell's thread

@(private = "file")
Term_Thread :: struct { app: ^App, conn: ^Term_Conn, http: ^Http, id, path, list_path: string }

// What a shell's thread says: output, or where its socket stands.
@(private = "file")
Term_News :: struct { conn: ^Term_Conn, text: string, is_link: bool, link: Term_Link, given_up: bool }

// A frame of the socket: the output it holds moves the cursor. The server counts what a JavaScript string counts, 16-bit units, whatever
// the bytes on the wire; a frame with a zero first and a cursor says where it stands and is not output. (A zero that only starts the output is.)
term_frame :: proc(c: ^Term_Conn, frame: string) -> (output: bool) {
	if len(frame) == 0 { return false }
	if frame[0] == 0 {
		v, err := json.parse_string(frame[1:], parse_integers = true, allocator = context.temp_allocator)
		if err == nil && jget(v, "cursor") != nil {
			c.cursor = i64(jnum(v, "cursor"))
			return false
		}
	}
	for b in transmute([]u8)frame {
		if b & 0xC0 != 0x80 { c.cursor += 1 }   // (a character)
		if b >= 0xF0 { c.cursor += 1 }          // (... beyond 16 bits: two units)
	}
	return true
}

// How long before the `tries`-th attempt.
term_backoff_ms :: proc(tries: int) -> int { return min(TERM_RETRY_MS << uint(clamp(tries - 1, 0, 16)), TERM_RETRY_MOST_MS) }

// Whether the server's list of shells has this one running.
term_listed :: proc(list: string, id: string) -> bool {
	v, err := json.parse_string(list, parse_integers = true, allocator = context.temp_allocator)
	if err != nil { return true }   // (nothing can be said from that: tried again)
	for it in jarr(v, "data") { if jstr(it, "id") == id { return jstr(it, "status") == "running" } }
	return false
}

@(private = "file")
term_post :: proc(job: ^Term_Thread, news: Term_News) {
	d := new(Term_News)
	d^ = news
	d.conn = job.conn
	if !ui.post(&job.app.state, term_news, d) { delete(d.text); free(d) }
}

// Reads until the socket goes.
@(private = "file")
term_read :: proc(job: ^Term_Thread, ws: rawptr) {
	ws_pump(WS_OPS, ws, job,
		proc(job: ^Term_Thread) -> bool { return !sync.atomic_load(&job.conn.stop) && !sync.atomic_load(&job.conn.renew) },
		proc(job: ^Term_Thread, ws: rawptr) { term_flush(ws, job.conn) },
		proc(job: ^Term_Thread, text: string) { if term_frame(job.conn, text) { term_post(job, {text = strings.clone(text)}) } })
}

// A socket that ends says nothing of why: the list of the server does. A shell that exited is over, at once; a server that does not answer
// may come back, so the socket is tried again, TERM_RETRIES times, each wait longer, from where the output stopped.
@(private = "file")
term_thread :: proc(job: ^Term_Thread) {
	c := job.conn
	tries := 0
	for !sync.atomic_load(&c.stop) {
		path := fmt.aprintf("%s%scursor=%d", job.path, strings.contains(job.path, "?") ? "&" : "?", c.cursor)
		ws := ocn_ws_open(job.http.client, raw_data(path), len(path))
		delete(path)
		if ws != nil {
			began := time.tick_now()
			ocn_ws_read_timeout(ws, TERM_READ_MS)
			term_post(job, {is_link = true, link = .Attached})
			term_read(job, ws)
			ocn_ws_free(ws)
			if time.duration_milliseconds(time.tick_since(began)) >= TERM_STABLE_MS { tries = 0 }
		}
		if sync.atomic_load(&c.stop) { break }
		if sync.atomic_exchange(&c.renew, false) { continue }   // (asked for: nothing happened to the shell)
		status, body, reached := http_request(job.http, "GET", job.list_path)
		gone := reached && status == 200 && !term_listed(body, job.id)
		delete(body)
		free_all(context.temp_allocator)
		if gone { term_post(job, {is_link = true, link = .Closed}); break }
		tries += 1
		if tries > TERM_RETRIES { term_post(job, {is_link = true, link = .Lost, given_up = true}); break }
		term_post(job, {is_link = true, link = .Lost})
		for left := term_backoff_ms(tries); left > 0 && !sync.atomic_load(&c.stop); left -= TERM_RETRY_STEP_MS { time.sleep(TERM_RETRY_STEP_MS * time.Millisecond) }
	}
	delete(job.id); delete(job.path); delete(job.list_path)
	free(job)
}

// The event stream came back after a loss. A socket reads nothing on a link that died in silence and cannot tell it from a quiet shell, and
// what is typed goes nowhere: the stream, which has a limit on silence, is what knows. From the cursor, opening a healthy one again repeats
// nothing.
terminals_renew :: proc(app: ^App) {
	for t in app.cx.terms.list { if t.server == app.conn && t.conn != nil { sync.atomic_store(&t.conn.renew, true) } }
}

@(private = "file")
term_connect :: proc(app: ^App, t: ^Term) {
	if t.conn == nil { t.conn = new(Term_Conn) }
	when ODIN_TEST { return }   // (no socket: the test says what its thread would)
	job := new(Term_Thread)
	job^ = {app, t.conn, &t.server.http, strings.clone(t.id), strings.clone(term_path(t, "/connect")), strings.clone(term_list_path(t.dir))}
	thread.create_and_start_with_poly_data(job, term_thread, self_cleanup = true)
}

// On the interface's thread.
@(private = "file")
term_news :: proc(data: rawptr, word: u64) {
	app := the_app
	d := (^Term_News)(data)
	defer { delete(d.text); free(d) }
	t := term_of_conn(app, d.conn)
	if t == nil { return }   // (a shell closed, a server left)
	if d.is_link { term_link_set(app, t, d.link, d.given_up) } else { term_feed(t, d.text) }
	if t.told_ms != 0 { deferred_ask(&app.cx.due[.Term_Size], TERM_PAINT_QUIET_MS, TERM_PAINT_MOST_MS) }
	app.settle = max(app.settle, FRAMES_AFTER_INPUT)
}

term_link_set :: proc(app: ^App, t: ^Term, link: Term_Link, given_up := false) {
	t.link, t.given_up = link, given_up
	if link >= .Lost && t.conn != nil {
		sync.lock(&t.conn.lock)
		clear(&t.conn.out)
		sync.unlock(&t.conn.lock)
	}
	if link == .Attached {
		t.size_sent = {}   // (a shell found again, a server back: it is told, once)
		term_size_send(app, t)
	}
}

term_feed :: proc(t: ^Term, s: string) {
	if t.vt == nil || len(s) == 0 { return }
	t.fed_ms = ui.now_ms()
	ghostty_terminal_vt_write(t.vt, raw_data(s), len(s))
}

term_find :: proc(app: ^App, id: string) -> ^Term {
	for t in app.cx.terms.list { if t.id == id { return t } }
	return nil
}

@(private = "file")
term_of_conn :: proc(app: ^App, c: ^Term_Conn) -> ^Term {
	for t in app.cx.terms.list { if t.conn == c { return t } }
	return nil
}

term_of_panel :: proc(app: ^App, panel: u32) -> ^Term {
	if panel < TERM_PANEL_BASE { return nil }
	for t in app.cx.terms.list { if t.panel == panel { return t } }
	if v := output_view_of_panel(app, panel); v != nil { return v.term }
	return nil
}

////////////////////////////////
// The shells of the server

@(private = "file")
term_list_path :: proc(dir: string) -> string {
	q := location_query(dir)
	return fmt.tprintf("/api/pty%s%s", q != "" ? "?" : "", q)
}

// The server's shells are read: a new reading, when the panel opens, on Try again, when the server answers again.
terminals_ask :: proc(app: ^App) {
	s := &app.cx.terms
	dir := chat_dir(app)
	remote_begin(&s.read)
	request(app, .Pty_List, "GET", term_list_path(dir), tag = dir, remote = &s.read)
}

// The next shell built, or `panel`'s, takes the keyboard. Only the user asks.
term_focus_ask :: proc(app: ^App, panel: u32 = 0) {
	app.cx.terms.ask = {on = true, panel = panel, from = ui.focus_key()}
}

// (a build of `t` asks: the request ends here, whichever way. A shell on its way is not the one already shown.)
term_takes_focus :: proc(s: ^Terminals, t: ^Term, focus: ui.Key) -> bool {
	a := &s.ask
	if !a.on || a.panel != t.panel { return false }
	a.on = false
	return focus == a.from
}

// Every shell has its tab, and nothing else does: Panel.Terminal while there is no shell to show.
terminals_dock :: proc(app: ^App) {
	s := &app.cx.terms
	d := &app.dock
	stand_in := u32(Panel.Terminal)
	if !s.open {
		for t in s.list { ui.dock_close(d, t.panel) }
		ui.dock_close(d, stand_in)
		return
	}
	if len(s.list) == 0 {
		if !ui.dock_has(d, stand_in) { ui.dock_add(d, stand_in, ui.Dock_Target{place = .Edge_Bottom}) }
		return
	}
	for t in s.list { term_dock(app, t) }
	ui.dock_close(d, stand_in)
}

// A shell with no tab goes where the shells are: in the stand-in's place, beside the last one used, else along the bottom edge.
@(private = "file")
term_dock :: proc(app: ^App, t: ^Term) {
	s := &app.cx.terms
	d := &app.dock
	if t.detached || ui.dock_has(d, t.panel) { return }
	beside := u32(Panel.Terminal)
	if !ui.dock_has(d, beside) { beside = s.last_panel }
	if beside == 0 || !ui.dock_has(d, beside) {
		beside = 0
		for o in s.list { if o != t && ui.dock_has(d, o.panel) { beside = o.panel } }
	}
	ui.dock_add(d, t.panel, beside != 0 ? ui.dock_with(d, beside) : ui.Dock_Target{place = .Edge_Bottom})
}

// Whether one of the shells can be seen.
@(private = "file")
terminals_seen :: proc(app: ^App) -> bool {
	for t in app.cx.terms.list { if ui.dock_shown(&app.dock, t.panel) { return true } }
	return ui.dock_shown(&app.dock, u32(Panel.Terminal))
}

// Shown, hidden: the shells run on either way. (Open, but under another tab: it comes up. What the key is for is to see them.)
terminal_toggle :: proc(app: ^App) {
	s := &app.cx.terms
	switch {
	case !s.open:
		terminals_show(app)
	case !terminals_seen(app):
		panel := s.last_panel != 0 && term_of_panel(app, s.last_panel) != nil ? s.last_panel : len(s.list) > 0 ? s.list[0].panel : u32(Panel.Terminal)
		ui.dock_activate(&app.dock, panel)
		term_focus_ask(app, panel >= TERM_PANEL_BASE ? panel : 0)
	case:
		panel_close(app, u32(Panel.Terminal))
	}
	app.settle = max(app.settle, FRAMES_AFTER_INPUT)
}

// (the palette) Another shell, the panel opened for it if need be.
terminal_new :: proc(app: ^App) {
	if !app.cx.terms.open { terminals_show(app) }
	if len(app.cx.terms.list) > 0 { term_create(app) }
}

@(private = "file")
terminals_show :: proc(app: ^App) {
	s := &app.cx.terms
	s.open = true
	dock_setup(app)
	panel := len(s.list) > 0 ? s.list[0].panel : 0
	if term_of_panel(app, s.last_panel) != nil { panel = s.last_panel }
	term_focus_ask(app, panel)
	if panel != 0 { ui.dock_activate(&app.dock, panel) }
	switch {
	case s.read.state == .Loading:
	case !remote_shows(&s.read):  terminals_ask(app)
	case len(s.list) == 0:        term_create(app)
	}
}

// Out of the dock, every tab: the shells stay, their threads read on, and the keyboard goes back to the conversation.
terminals_hide :: proc(app: ^App) {
	s := &app.cx.terms
	had_keys := s.focused != nil
	term_press_end(s)
	s.open = false
	s.focused = nil
	s.ask = {}
	s.make_after = false
	terminals_dock(app)
	if had_keys { app.cx.focus_composer = true }
}

// (a shell the list and this client both know is left as it is: the reading only adds)
@(private = "file")
term_add :: proc(app: ^App, it: json.Value, dir: string) -> ^Term {
	s := &app.cx.terms
	id := jstr(it, "id")
	if id == "" || term_find(app, id) != nil { return nil }
	t := term_new(id, jstr(it, "title"), dir)
	t.zoom = app.term_zooms.by_id[id] or_else 1
	t.server = app.conn
	t.panel = TERM_PANEL_BASE + s.next_panel
	s.next_panel += 1
	append(&s.list, t)
	term_connect(app, t)
	return t
}

// What was left running comes back, in the places the layout keeps for it; else a first shell, if the panel still waits for one.
terminals_load :: proc(app: ^App, dir: string, v: json.Value) {
	s := &app.cx.terms
	added := false
	for it in jarr(v, "data") { if jstr(it, "status") == "running" && term_add(app, it, dir) != nil { added = true } }
	if s.open {
		if added { dock_setup(app) }
		if len(s.list) == 0 || s.make_after {
			term_make(app, dir, term_next_title(s))
		} else if s.ask.on && s.ask.panel == 0 {
			s.ask.panel = s.list[len(s.list) - 1].panel   // (what was asked for is what was found)
			ui.dock_activate(&app.dock, s.ask.panel)
		}
	}
	s.make_after = false
}

@(private = "file")
term_next_title :: proc(s: ^Terminals) -> string { return fmt.tprintf("Terminal %d", len(s.list) + 1) }

// A new shell, asked for by the user. While the list is read, its answer decides: one shell is enough to answer both.
term_create :: proc(app: ^App) {
	s := &app.cx.terms
	term_focus_ask(app)
	if s.read.state == .Ready {
		term_make(app, chat_dir(app), term_next_title(s))
		return
	}
	s.make_after = true
	if s.read.state != .Loading { terminals_ask(app) }
}

// (one at a time)
@(private = "file")
term_make :: proc(app: ^App, dir, title: string) {
	s := &app.cx.terms
	if s.made.state == .Loading { return }
	remote_begin(&s.made)
	request(app, .Pty_Made, "POST", term_list_path(dir), fmt.tprintf(`{{"title":%s}}`, jquote(title)), dir, remote = &s.made)
}

term_made :: proc(app: ^App, dir: string, v: json.Value) {
	s := &app.cx.terms
	t := term_add(app, jget(v, "data"), dir)
	if t == nil {
		remote_settle(&s.made, .Failed, "Unreadable answer")
		s.replaces = 0
		return
	}
	if s.ask.on && s.ask.panel == 0 { s.ask.panel = t.panel }
	replaced := term_of_panel(app, s.replaces)
	s.replaces = 0
	if !s.open { if replaced != nil { term_forget_one(app, replaced) }; return }
	d := &app.dock
	if replaced != nil {
		// (its place in its strip, its stack, its split: what was restarted is the same tab to the reader)
		at := 0
		leaf := ui.dock_leaf_of(d, replaced.panel)
		for p, k in ui.dock_tabs(d, leaf) { if p == replaced.panel { at = k } }
		if leaf != ui.DOCK_NONE { ui.dock_add(d, t.panel, ui.Dock_Target{place = .Tab, node = leaf, index = at}) }
		term_forget_one(app, replaced)
	}
	term_dock(app, t)
	ui.dock_close(d, u32(Panel.Terminal))
	ui.dock_activate(d, t.panel)
}

// What failed for a new shell: told in the panel while there is no other, by a toast else.
term_made_failed :: proc(app: ^App) -> (told: bool) {
	s := &app.cx.terms
	s.replaces = 0
	return s.open && len(s.list) == 0
}

// A shell made on a server left, with nobody to use it: it does not stay there.
term_made_left :: proc(app: ^App, r: ^Request, v: json.Value) {
	id := jstr(v, "data", "id")
	if id == "" { return }
	q := location_query(r.tag)
	request(app, .Action, "DELETE", fmt.tprintf("/api/pty/%s%s%s", url_escape(id), q != "" ? "?" : "", q), conn = r.conn)
}

// Out of the client, and of the dock. It is freed after the frame (terminals_reap): this build's box may still draw it.
@(private = "file")
term_forget_one :: proc(app: ^App, t: ^Term) {
	s := &app.cx.terms
	if s.pressed == t { term_press_end(s) }
	if s.focused == t { s.focused = nil }
	ui.dock_close(&app.dock, t.panel)
	for o, i in s.list { if o == t { ordered_remove(&s.list, i); break } }
	if t.conn != nil { sync.atomic_store(&t.conn.stop, true) }
	append(&s.gone, t)
}

// A tab closed: the shell is closed on its server (unless it is over already). The last one closes the area.
term_close :: proc(app: ^App, t: ^Term) {
	s := &app.cx.terms
	had_keys := s.focused == t
	if t.link != .Closed { request(app, .Action, "DELETE", term_path(t), conn = t.server) }
	term_zoom_forget(app, t.id)
	term_forget_one(app, t)
	if len(s.list) == 0 {
		s.open = false
		s.ask = {}
		if had_keys { app.cx.focus_composer = true }
	} else if had_keys {
		for o in s.list { if ui.dock_shown(&app.dock, o.panel) { term_focus_ask(app, o.panel); break } }
	}
}

// A shell that ended begins again, in the same tab, the same folder.
term_restart :: proc(app: ^App, t: ^Term) {
	s := &app.cx.terms
	if s.made.state == .Loading { return }
	s.replaces = t.panel
	term_focus_ask(app)
	term_make(app, t.dir, t.title)
}

// A socket given up on is tried again.
term_reconnect :: proc(app: ^App, t: ^Term) {
	if t.link != .Lost || !t.given_up { return }
	t.link, t.given_up = .Connecting, false
	term_connect(app, t)
}

// The server answers again: what was not read is, and the sockets given up on are tried again.
terminals_reread :: proc(app: ^App) {
	s := &app.cx.terms
	if s.open && remote_failed(&s.read) { terminals_ask(app) }
	for t in s.list { term_reconnect(app, t) }
}

// The server is left. Its shells run on there and this client lets go of them: nothing is asked of it, nothing of theirs stays here, the
// panel closes (the next server's list is read when it opens: no shell is made on a server for having been open on another).
terminals_forget :: proc(app: ^App) {
	s := &app.cx.terms
	term_press_end(s)
	for len(s.list) > 0 { term_forget_one(app, s.list[len(s.list) - 1]) }
	ui.dock_close(&app.dock, u32(Panel.Terminal))
	app.dock.drag = {}   // (a tab held: it would come back when dropped)
	s.open = false
	s.focused = nil
	s.ask = {}
	s.make_after = false
	s.last_panel, s.replaces, s.close_due = 0, 0, 0
	remote_reset(&s.read)
	remote_reset(&s.made)
}

// After the frame: what was closed in it has been drawn.
terminals_reap :: proc(app: ^App) {
	s := &app.cx.terms
	for t in s.gone { term_free(t) }
	clear(&s.gone)
}

// The window closes: the shells' threads go with it. (Nothing to close on the server: they outlive the program.)
terminals_stop :: proc(app: ^App) {
	for t in app.cx.terms.list { if t.conn != nil { sync.atomic_store(&t.conn.stop, true) } }
}

////////////////////////////////
// Input

// The encoder's key of one of ours (0: none); `printable`: its text comes as a Text event.
term_key :: proc(k: platform.Key) -> (key: i32, printable: bool, unshifted: u32) {
	#partial switch k {
	case .A ..= .Z:    return VT_KEY_A + i32(k) - i32(platform.Key.A), true, 'a' + u32(k) - u32(platform.Key.A)
	case .N0 ..= .N9:  return VT_KEY_DIGIT_0 + i32(k) - i32(platform.Key.N0), true, '0' + u32(k) - u32(platform.Key.N0)
	case .F1 ..= .F12: return VT_KEY_F1 + i32(k) - i32(platform.Key.F1), false, 0
	case .Space:     return VT_KEY_SPACE, true, ' '
	case .Comma:     return VT_KEY_COMMA, true, ','
	case .Period:    return VT_KEY_PERIOD, true, '.'
	case .Slash:     return VT_KEY_SLASH, true, '/'
	case .Minus:     return VT_KEY_MINUS, true, '-'
	case .Equal:     return VT_KEY_EQUAL, true, '='
	case .Num_Add:   return VT_KEY_NUMPAD_ADD, true, '+'
	case .Num_Subtract: return VT_KEY_NUMPAD_SUBTRACT, true, '-'
	case .Escape:    return VT_KEY_ESCAPE, false, 0
	case .Return:    return VT_KEY_ENTER, false, 0
	case .Tab:       return VT_KEY_TAB, false, 0
	case .Backspace: return VT_KEY_BACKSPACE, false, 0
	case .Delete:    return VT_KEY_DELETE, false, 0
	case .Insert:    return VT_KEY_INSERT, false, 0
	case .Left:      return VT_KEY_ARROW_LEFT, false, 0
	case .Right:     return VT_KEY_ARROW_RIGHT, false, 0
	case .Up:        return VT_KEY_ARROW_UP, false, 0
	case .Down:      return VT_KEY_ARROW_DOWN, false, 0
	case .Home:      return VT_KEY_HOME, false, 0
	case .End:       return VT_KEY_END, false, 0
	case .Page_Up:   return VT_KEY_PAGE_UP, false, 0
	case .Page_Down: return VT_KEY_PAGE_DOWN, false, 0
	case .Menu:      return VT_KEY_CONTEXT_MENU, false, 0
	}
	return 0, false, 0
}

@(private = "file")
mods_of :: proc(m: platform.Modifiers) -> u16 {
	v: u16
	if .Shift in m { v |= VT_MODS_SHIFT }
	if .Ctrl in m { v |= VT_MODS_CTRL }
	if .Alt in m { v |= VT_MODS_ALT }
	return v
}

// What the shell gets for a key, in the temporary allocator. A printable key alone gives nothing: its Text event says the character,
// with the layout of the keyboard. Ctrl and Alt together are AltGr on many: a character too.
term_encode_key :: proc(t: ^Term, k: platform.Key, mods: platform.Modifiers, repeat: bool) -> string {
	key, printable, unshifted := term_key(k)
	if key == 0 { return "" }
	if printable && (mods & {.Ctrl, .Alt} == {} || mods & {.Ctrl, .Alt} == {.Ctrl, .Alt}) { return "" }
	ghostty_key_encoder_set_from_terminal(t.key_enc, t.vt)
	ghostty_key_event_set_key(t.key_ev, key)
	ghostty_key_event_set_action(t.key_ev, repeat ? VT_ACTION_REPEAT : VT_ACTION_PRESS)
	ghostty_key_event_set_mods(t.key_ev, mods_of(mods))
	ghostty_key_event_set_consumed_mods(t.key_ev, 0)
	ghostty_key_event_set_unshifted_codepoint(t.key_ev, unshifted)
	ghostty_key_event_set_utf8(t.key_ev, {})
	buf := make([]u8, TERM_KEY_BYTES, context.temp_allocator)
	n: uint
	if ghostty_key_encoder_encode(t.key_enc, t.key_ev, raw_data(buf), len(buf), &n) != VT_OK { return "" }
	return string(buf[:n])
}

@(private = "file")
term_mode :: proc(t: ^Term, mode: u16) -> bool {
	m := Vt_Mode{mode = mode & 0x7FFF}
	return ghostty_terminal_get(t.vt, VT_DATA_MODE, &m) == VT_OK && m.value
}

// What is pasted, as the program wants it. Without the brackets, a line break in a paste runs what comes before it.
term_paste_text :: proc(t: ^Term, s: string) -> string {
	if term_mode(t, VT_MODE_BRACKETED_PASTE) { return fmt.tprintf("\x1b[200~%s\x1b[201~", s) }
	flat, _ := strings.replace_all(s, "\r\n", "\r", context.temp_allocator)
	flat, _ = strings.replace_all(flat, "\n", "\r", context.temp_allocator)
	return flat
}

@(private = "file")
term_tracks_mouse :: proc(t: ^Term) -> bool {
	if t.read_only { return false }   // (nobody to tell: the pointer selects)
	on: bool
	return ghostty_terminal_get(t.vt, VT_DATA_MOUSE_TRACKING, &on) == VT_OK && on
}

@(private = "file")
term_cell_at :: proc(t: ^Term, s: ^Terminals, p: [2]f32) -> [2]int {
	x := int((p.x - t.rect.min.x - TERM_PAD) / max(t.metrics.cell_w, 1))
	y := int((p.y - t.rect.min.y - TERM_PAD) / max(t.metrics.cell_h, 1))
	return {max(x, 0), max(y, 0)}
}

term_at_bottom :: proc(t: ^Term) -> bool {
	bar: Vt_Scrollbar
	if t.vt == nil || ghostty_terminal_get(t.vt, VT_DATA_SCROLLBAR, &bar) != VT_OK { return true }
	return bar.offset + bar.len >= bar.total
}

// No selection, and no drag making one.
term_selection_drop :: proc(t: ^Term) {
	t.selecting = false
	ghostty_tracked_grid_ref_free(t.sel_anchor)
	t.sel_anchor = nil
	if t.vt != nil { ghostty_terminal_set(t.vt, VT_OPT_SELECTION, nil) }
}

term_has_selection :: proc(t: ^Term) -> bool {
	sel: Vt_Selection
	return t.vt != nil && ghostty_terminal_get(t.vt, VT_DATA_SELECTION, &sel) == VT_OK
}

// A drag's first press: the cell it began on is followed, whatever comes before the pointer moves.
term_select_begin :: proc(t: ^Term, cell: [2]int) {
	term_selection_drop(t)
	t.selecting, t.sel_press = true, cell
	ghostty_terminal_grid_ref_track(t.vt, vt_point(VT_POINT_VIEWPORT, cell), &t.sel_anchor)
}

// The drag is over `cell` (in the view): from where it began to there, once it has left the cell it began on.
term_select_to :: proc(t: ^Term, cell: [2]int) {
	if !t.selecting || t.sel_anchor == nil { return }
	if cell == t.sel_press && !term_has_selection(t) { return }
	sel: Vt_Selection
	if ghostty_tracked_grid_ref_snapshot(t.sel_anchor, &sel.start) != VT_OK { return }
	if ghostty_terminal_grid_ref(t.vt, vt_point(VT_POINT_VIEWPORT, term_cell_clamp(t, cell)), &sel.end) != VT_OK { return }
	ghostty_terminal_set(t.vt, VT_OPT_SELECTION, &sel)
}

// All of it, the scrollback with the screen.
term_select_all :: proc(t: ^Term) {
	bar: Vt_Scrollbar
	if t.vt == nil || ghostty_terminal_get(t.vt, VT_DATA_SCROLLBAR, &bar) != VT_OK || bar.total == 0 { return }
	term_selection_drop(t)
	sel: Vt_Selection
	if ghostty_terminal_grid_ref(t.vt, vt_point(VT_POINT_SCREEN, {0, 0}), &sel.start) != VT_OK { return }
	if ghostty_terminal_grid_ref(t.vt, vt_point(VT_POINT_SCREEN, {max(int(t.cols) - 1, 0), int(bar.total) - 1}), &sel.end) != VT_OK { return }
	ghostty_terminal_set(t.vt, VT_OPT_SELECTION, &sel)
}

@(private = "file")
vt_point :: proc(tag: i32, cell: [2]int) -> Vt_Point {
	p := Vt_Point{tag = tag}
	p.value.coord = {u16(max(cell.x, 0)), u32(max(cell.y, 0))}
	return p
}

// (a cell past the grid's edge is none of its cells: the nearest that is)
@(private = "file")
term_cell_clamp :: proc(t: ^Term, cell: [2]int) -> [2]int {
	return {clamp(cell.x, 0, max(int(t.cols) - 1, 0)), clamp(cell.y, 0, max(int(t.rows) - 1, 0))}
}

// The shell whose grid is under `p`: shown, and no floating panel over it.
term_at :: proc(app: ^App, p: [2]f32) -> ^Term {
	d := &app.dock
	if t := app.cx.terms.only; t != nil { return draw.rect_contains(t.rect, p) ? t : nil }
	for t in app.cx.terms.list {
		if !t.shown || t.detached || !draw.rect_contains(t.rect, p) { continue }
		leaf := ui.dock_leaf_at(d, p - d.origin)
		if leaf == ui.DOCK_NONE || leaf == ui.dock_leaf_of(d, t.panel) { return t }
	}
	return nil
}

// What the button held on a grid stops, wherever it was let go or whatever took it away: the selection is what it is by now, and a
// program told of a press is told of its release.
term_press_end :: proc(s: ^Terminals) {
	t := s.pressed
	press := s.press
	s.press, s.pressed = .None, nil
	if t == nil { return }
	switch press {
	case .None:
	case .Select:
		t.selecting = false
		ghostty_tracked_grid_ref_free(t.sel_anchor)
		t.sel_anchor = nil
	case .Program:
		term_mouse(t, s, VT_MOUSE_RELEASE, mouse_button_of(s.press_button), s.press_pos, {}, false)
	}
}

// (a position outside the grid is not one an encoder can say: the nearest in it)
@(private = "file")
term_inside :: proc(t: ^Term, p: [2]f32) -> [2]f32 {
	return {clamp(p.x, t.rect.min.x, t.rect.max.x - 1), clamp(p.y, t.rect.min.y, t.rect.max.y - 1)}
}

@(private = "file")
term_mouse :: proc(t: ^Term, s: ^Terminals, action, button: i32, at: [2]f32, mods: platform.Modifiers, held: bool) {
	if t.vt == nil { return }
	pos := term_inside(t, at)
	ghostty_mouse_encoder_set_from_terminal(t.mouse_enc, t.vt)
	size := Vt_Mouse_Size{
		size = size_of(Vt_Mouse_Size), screen_width = u32(t.rect.max.x - t.rect.min.x), screen_height = u32(t.rect.max.y - t.rect.min.y),
		cell_width = u32(t.metrics.cell_w), cell_height = u32(t.metrics.cell_h),
		padding_top = u32(TERM_PAD), padding_bottom = u32(TERM_PAD), padding_right = u32(TERM_PAD), padding_left = u32(TERM_PAD),
	}
	ghostty_mouse_encoder_set(t.mouse_enc, VT_MOUSE_OPT_SIZE, &size)
	any := held
	ghostty_mouse_encoder_set(t.mouse_enc, VT_MOUSE_OPT_ANY_PRESSED, &any)
	ghostty_mouse_event_set_action(t.mouse_ev, action)
	if button != 0 { ghostty_mouse_event_set_button(t.mouse_ev, button) } else { ghostty_mouse_event_clear_button(t.mouse_ev) }
	ghostty_mouse_event_set_mods(t.mouse_ev, mods_of(mods))
	ghostty_mouse_event_set_position(t.mouse_ev, {pos.x - t.rect.min.x, pos.y - t.rect.min.y})
	buf: [TERM_KEY_BYTES]u8
	n: uint
	if ghostty_mouse_encoder_encode(t.mouse_enc, t.mouse_ev, &buf[0], len(buf), &n) == VT_OK && n > 0 { term_send(t, string(buf[:n])) }
}

@(private = "file")
mouse_button_of :: proc(b: platform.Mouse_Button) -> i32 {
	#partial switch b {
	case .Left:   return VT_MOUSE_LEFT
	case .Right:  return VT_MOUSE_RIGHT
	case .Middle: return VT_MOUSE_MIDDLE
	}
	return 0
}

// The text selected, wherever it is now (scrolled out of the view too). "": none.
term_selection_text :: proc(t: ^Term) -> string {
	sel: Vt_Selection
	if t.vt == nil || ghostty_terminal_get(t.vt, VT_DATA_SELECTION, &sel) != VT_OK { return "" }
	ghostty_formatter_set(t.formatter, VT_FORMAT_SELECTION, &sel)
	defer ghostty_formatter_set(t.formatter, VT_FORMAT_SELECTION, nil)
	return term_format(t)
}

// The text of the screen, its scrollback with it.
term_text :: proc(t: ^Term) -> string {
	if t.vt == nil { return "" }
	return term_format(t)
}

@(private = "file")
term_format :: proc(t: ^Term) -> string {
	need: uint
	if ghostty_formatter_format_buf(t.formatter, nil, 0, &need) != VT_OUT_OF_SPACE || need == 0 { return "" }
	buf := make([]u8, need, context.temp_allocator)
	got: uint
	if ghostty_formatter_format_buf(t.formatter, raw_data(buf), need, &got) != VT_OK { return "" }
	return string(buf[:got])
}

// A key for the shell with the keyboard. False: it is the program's (the key that hides the shells must work from inside them).
@(private = "file")
term_key_event :: proc(app: ^App, t: ^Term, e: platform.Event) -> (take: bool) {
	if e.key == .T && e.mods == {.Ctrl, .Shift} { return false }
	switch {
	case (e.key == .C && (e.mods == {.Ctrl, .Shift} || (t.read_only && e.mods == {.Ctrl}))) || (e.key == .Insert && e.mods == {.Ctrl}):   // (Ctrl+C alone is a shell's)
		if term_has_selection(t) { clip_set(term_selection_text(t)) }
	case ((e.key == .V && e.mods == {.Ctrl, .Shift}) || (e.key == .Insert && e.mods == {.Shift})) && !t.read_only:   // (Shift+Insert: the terminals' other paste)
		term_paste(app, t)
	case e.key == .Page_Up && e.mods == {.Shift}:
		ghostty_terminal_scroll_viewport(t.vt, {tag = .Delta, value = -i64(t.rows)})
	case e.key == .Page_Down && e.mods == {.Shift}:
		ghostty_terminal_scroll_viewport(t.vt, {tag = .Delta, value = i64(t.rows)})
	case t.read_only:
		return false
	case e.key == .Shift || e.key == .Ctrl || e.key == .Alt:
	case:
		if s := term_encode_key(t, e.key, e.mods, e.repeat); s != "" {
			term_send(t, s)
			ghostty_terminal_scroll_viewport(t.vt, {tag = .Bottom})
			term_selection_drop(t)
		}
	}
	return true
}

// Before the interface sees them: what goes to a shell is taken out. Returns what is left. The keys go to the shell that has the keyboard,
// the pointer to the one it is over: both are shown, as the last build says, or there is none.
term_events :: proc(app: ^App, events: []platform.Event) -> []platform.Event {
	s := &app.cx.terms
	if s.only == nil && (!s.open || len(s.list) == 0) { return events }   // (the tabs hidden, a shell in its window still hears; a command's output is no shell of the list)
	if s.only == nil && overlay_open(app) {
		if s.pressed == nil || !s.pressed.read_only { term_press_end(s) }   // (a selection in the dialog: that overlay is its own)
		return events
	}
	kept := 0
	for e in events {
		take := false
		keys := s.focused
		if keys != nil && keys.vt == nil { keys = nil }
		typed := keys != nil && !keys.read_only
		#partial switch e.kind {
		case .Key_Press:
			if keys != nil && e.mods == {.Ctrl} {
				#partial switch e.key {
				case .Equal, .Num_Add:      term_zoom_set(app, keys, keys.zoom * ZOOM_FACTOR); take = true
				case .Minus, .Num_Subtract: term_zoom_set(app, keys, keys.zoom / ZOOM_FACTOR); take = true
				case .N0:                   term_zoom_set(app, keys, 1); take = true
				}
			}
			if keys != nil && !take { take = term_key_event(app, keys, e) }
		case .Key_Release:
			take = typed
		case .Text:
			if !typed { break }
			take = true
			if e.text >= ' ' && e.text != 127 {
				b, n := utf8.encode_rune(e.text)
				term_send(keys, string(b[:n]))
				ghostty_terminal_scroll_viewport(keys.vt, {tag = .Bottom})
				term_selection_drop(keys)
			}
		case .Scroll:
			t := term_at(app, e.pos)
			if t == nil || t.vt == nil { break }
			take = true
			if .Ctrl in e.mods {
				term_zoom_set(app, t, e.delta.y < 0 ? t.zoom * ZOOM_FACTOR : t.zoom / ZOOM_FACTOR)
			} else if term_tracks_mouse(t) {
				button: i32 = e.delta.y > 0 ? VT_MOUSE_FIVE : VT_MOUSE_FOUR
				term_mouse(t, s, VT_MOUSE_PRESS, button, e.pos, e.mods, false)
				term_mouse(t, s, VT_MOUSE_RELEASE, button, e.pos, e.mods, false)
			} else {
				n := platform.wheel_lines()   // (the lines the system says; where it says a page, a page less a line)
				if n <= 0 { n = f32(max(int(t.rows) - 1, 1)) }
				ghostty_terminal_scroll_viewport(t.vt, {tag = .Delta, value = i64(math.round(e.delta.y * n))})
			}
		case .Mouse_Press:
			t := term_at(app, e.pos)
			if t == nil || t.vt == nil { break }
			if term_on_bar(t, e.pos) {
				// (the grid's scroll bar is the toolkit's: its press goes to the interface, whatever the program asks of the mouse)
			} else if e.button == .Right && (!term_tracks_mouse(t) || .Shift in e.mods) {
				s.menu_for, s.menu_at = t, e.pos
				take = true
			} else if term_tracks_mouse(t) && .Shift not_in e.mods {
				term_mouse(t, s, VT_MOUSE_PRESS, mouse_button_of(e.button), e.pos, e.mods, true)
				if s.press == .None { s.press, s.pressed, s.press_button, s.press_pos = .Program, t, e.button, e.pos }
			} else if e.button == .Left && s.press == .None {
				s.press, s.pressed, s.press_button, s.press_pos = .Select, t, e.button, e.pos
				term_select_begin(t, term_cell_at(t, s, e.pos))
			}
		case .Mouse_Release:
			if s.press != .None && e.button == s.press_button {
				s.press_pos = e.pos
				term_press_end(s)
			} else if t := term_at(app, e.pos); t != nil && t.vt != nil && term_tracks_mouse(t) {
				term_mouse(t, s, VT_MOUSE_RELEASE, mouse_button_of(e.button), e.pos, e.mods, false)
			}
		case .Mouse_Move:
			switch s.press {
			case .Select:
				term_select_to(s.pressed, term_cell_at(s.pressed, s, e.pos))
			case .Program:
				s.press_pos = e.pos
				term_mouse(s.pressed, s, VT_MOUSE_MOTION, 0, e.pos, e.mods, true)
			case .None:
				if t := term_at(app, e.pos); t != nil && t.vt != nil && term_tracks_mouse(t) {
					term_mouse(t, s, VT_MOUSE_MOTION, 0, e.pos, e.mods, e.buttons != {})
				}
			}
		}
		if !take {
			events[kept] = e
			kept += 1
		}
	}
	return events[:kept]
}

@(private = "file")
term_paste :: proc(app: ^App, t: ^Term) {
	text := platform.get_clipboard(app.win, context.temp_allocator)
	term_send(t, term_paste_text(t, text))
}

////////////////////////////////
// The panel

// Before the panels of a build: what was shown is shown again only if it is built.
terminals_begin :: proc(app: ^App) {
	for t in app.cx.terms.list { if !t.detached { t.shown = false } }
}

// After them: who has the keyboard now, from what was really built. A shell hidden, under another tab, in a folded stack has neither the keys
// nor the pointer. A button held on a grid that is gone, or that lost the press to something else (a menu, another box), is let go.
terminals_settle :: proc(app: ^App) {
	s := &app.cx.terms
	s.focused = nil
	focus := ui.focus_key()
	for t in s.list {
		if t.shown && !t.detached && focus != 0 && t.box == focus {
			s.focused = t
			s.last_panel = t.panel
		}
	}
	if t := s.pressed; t != nil && !t.detached && (!t.shown || overlay_open(app) || ui.active_key() != t.box) { term_press_end(s) }
}

// What says a shell is not there, and what can be done about it.
@(private = "file")
term_banner :: proc(app: ^App, t: ^Term, em: f32) {
	s := &app.cx.terms
	if t.link < .Lost { return }
	words := t.link == .Closed ? "This shell ended." : t.given_up ? "The connection to this shell was lost." : "The connection to this shell was lost: trying again…"
	ui.next({width = ui.fill(), height = ui.px(math.round(em * TERM_BANNER_H_EM)), axis = .X, cross = .Center})
	if ui.row(.Center, id = "###term_banner") {
		ui.spacer(ui.px(em * 0.6))
		text("w", words, hex(t.link == .Closed ? HEX_WEAK : HEX_YELLOW), ui.Style_Mod{font_size = math.round(em * FS_NOTE)}, ui.fill())
		h := math.round(em * BUTTON_COMPACT_H_EM)
		if t.link == .Closed {
			if bevel_button("###term_restart", "Restart", lucide.REFRESH_CW, .Normal, height = h, disabled = s.made.state == .Loading).clicked { term_restart(app, t) }
		} else if t.given_up {
			if bevel_button("###term_again", "Reconnect", lucide.REFRESH_CW, .Normal, height = h).clicked { term_reconnect(app, t) }
		}
		ui.spacer(ui.px(em * 0.3))
		if bevel_button("###term_close", "Close", lucide.X, .Ghost, height = h).clicked { s.close_due = t.panel }
		ui.spacer(ui.px(em * 0.6))
	}
}

// A shell, in its panel.
terminal_panel :: proc(app: ^App, em: f32, t: ^Term) {
	s := &app.cx.terms
	term_banner(app, t, em)
	// (a box that scrolls, over a space as tall as the scrollback: its scroll bar is the toolkit's, in the theme's look, held,
	// pressed in its track, as every list's; term_scroll_sync keeps it and the grid's view together)
	ui.next({width = ui.fill(), height = ui.fill(), cursor = .Text})
	b := ui.build_box({.Clickable, .Focusable, .Clip, .View_Scroll_Y, .View_Clamp_Y}, "###term_box")
	sig := ui.signal(b)
	if sig.pressed || term_takes_focus(s, t, ui.focus_key()) { ui.set_focus(b.key) }
	t.box, t.rect, t.shown = b.key, b.rect, true
	t.metrics.font_size = math.round(em * FS_NOTE * t.zoom)
	advance := font.text_width(&app.fonts, app.term_font, t.metrics.font_size, "M")
	t.metrics.cell_w = math.ceil(advance)
	t.metrics.spacing = t.metrics.cell_w - advance
	t.metrics.spacing_bold = t.metrics.cell_w - font.text_width(&app.fonts, app.term_font_bold, t.metrics.font_size, "M")
	m := font.metrics(&app.fonts, app.term_font, t.metrics.font_size)
	t.metrics.cell_h = math.ceil(m.line_height)
	t.metrics.ascent = m.ascent
	term_fit(app, t, b.rect)
	term_scroll_sync(t, b)
	// the space the box scrolls over: as tall as the scrollback, the view its part (the bar's thumb)
	if ui.parent(b) {
		ui.next({width = ui.fill(), height = ui.px(term_scroll_height(t, b))})
		ui.build_box({}, "###term_space")
	}
	b.custom, b.custom_user = term_draw, t
	menu := ui.key_from_string(b.key, "term_menu")
	if s.menu_for == t { ui.ctx_menu_open(menu, s.menu_at); s.menu_for = nil }
	if ui.ctx_menu(menu, em * TERM_MENU_EM) { term_menu(app, t) }
}

// What a right click on a shell's grid offers: its selection, what the clipboard holds, the whole screen; a command's output, all of it.
@(private = "file")
term_menu :: proc(app: ^App, t: ^Term) {
	if ui.menu_item("Copy", t.read_only ? "Ctrl+C" : "Ctrl+Shift+C", icon = lucide.COPY, enabled = term_has_selection(t)).clicked {
		clip_set(term_selection_text(t))
	}
	if !t.read_only && ui.menu_item("Paste", "Ctrl+Shift+V", icon = lucide.CLIPBOARD_PASTE).clicked { term_paste(app, t) }
	if ui.menu_item("Select all", icon = lucide.TEXT_CURSOR_INPUT, enabled = t.vt != nil).clicked { term_select_all(t) }
	ui.menu_separator()
	if ui.menu_item("Zoom in", "Ctrl+=", icon = lucide.PLUS).clicked { term_zoom_set(app, t, t.zoom * ZOOM_FACTOR) }
	if ui.menu_item("Zoom out", "Ctrl+-", icon = lucide.CHEVRON_DOWN).clicked { term_zoom_set(app, t, t.zoom / ZOOM_FACTOR) }
	reset := t.zoom != 1 ? fmt.tprintf("Reset the zoom (%d%%)", int(math.round(t.zoom * 100))) : "Reset the zoom"
	if ui.menu_item(reset, "Ctrl+0", icon = lucide.UNDO_2, enabled = t.zoom != 1).clicked { term_zoom_set(app, t, 1) }
	if v := output_view_of_term(app, t); v != nil {
		ui.menu_separator()
		if ui.menu_item("Copy all the output", icon = lucide.COPY, enabled = len(v.raw) > 0).clicked { clip_set(plain_output(string(v.raw[:]))) }
	}
}

// What stands in the dock while there is no shell: the reading of the list or of the new shell, and how it ended.
terminal_waiting :: proc(app: ^App, em: f32) {
	s := &app.cx.terms
	ui.spacer(ui.px(em * 0.8))
	ui.next({width = ui.fill(), height = ui.children_sum(), axis = .X})
	if ui.row(id = "###term_wait") {
		ui.spacer(ui.px(em))
		ui.next({width = ui.fill(), height = ui.children_sum(), axis = .Y})
		if ui.column() {
			if read_shown(app, "###term_read", &s.read, em, terminals_ask) { read_shown(app, "###term_made", &s.made, em, term_create) }
		}
		ui.spacer(ui.px(em))
	}
}

// The end of a strip that holds a shell: the way to another. (Panel.Terminal's too: the list on its way answers for it.)
terminal_strip_end :: proc(app: ^App, d: ^ui.Dock, leaf: i32, em: f32) {
	s := &app.cx.terms
	any: ^Term
	stand_in := false
	for p in ui.dock_tabs(d, leaf) {
		if p == u32(Panel.Terminal) { stand_in = true }
		if t := term_of_panel(app, p); t != nil && any == nil { any = t }
	}
	if any == nil && !stand_in { return }
	ui.a11y({role = .Button, name = "New terminal"})
	if glyph_button("###term_new", lucide.PLUS, math.round(em * TERM_NEW_EM)).clicked {
		if any != nil { s.last_panel = any.panel }   // (in this stack, whichever had the keyboard)
		term_create(app)
	}
}

// A shell names itself by the path of its program: the program is enough.
term_label :: proc(t: ^Term) -> string {
	name := base_name(t.title)
	name = strings.trim_suffix(strings.trim_suffix(name, ".exe"), ".EXE")
	tail := t.link == .Closed ? " (ended)" : t.link == .Lost ? " (lost)" : ""
	return ellipsize(fmt.tprintf("%s%s", name, tail), TERM_TAB_CHARS)
}

// The grid follows the panel at once. The shell is told the last size, one request at a time, once the grid has rested. A window being
// dragged would otherwise send one for each step, on as many threads, in no order, and the last to arrive would be any of them; and a
// shell paints its whole screen again for each size it takes, in pieces, which the grid would show: its text a few rows off, for a frame.
//
// A zoom that moves (the wheel turned notch after notch) keeps the grid as it is, drawn in the new cells, until it rests: each
// new number of columns rewraps every row of the scrollback, thousands of them, at every notch.
@(private = "file")
term_fit :: proc(app: ^App, t: ^Term, r: draw.Rect) {
	if t.vt == nil || t.metrics.cell_w <= 0 || r.max.x - r.min.x < 1 { return }
	if t.fitted && t.zoom_ms != 0 && ui.now_ms() - t.zoom_ms < TERM_ZOOM_REST_MS { return }
	cols := u16(clamp((r.max.x - r.min.x - 2 * TERM_PAD) / t.metrics.cell_w, 2, 1000))
	rows := u16(clamp((r.max.y - r.min.y - 2 * TERM_PAD) / t.metrics.cell_h, 2, 1000))
	term_resize(app, t, cols, rows, u32(t.metrics.cell_w), u32(t.metrics.cell_h))
}

term_resize :: proc(app: ^App, t: ^Term, cols, rows: u16, cell_w, cell_h: u32) {
	t.fitted = true
	if cols != t.cols || rows != t.rows {
		t.cols, t.rows = cols, rows
		ghostty_terminal_resize(t.vt, cols, rows, cell_w, cell_h)
		t.grid_ms = ui.now_ms()
		app.cx.due[.Term_Size] = {}   // (from this step, the last so far: an earlier wake would find the grid not rested, and nothing would come after it)
		deferred_ask(&app.cx.due[.Term_Size], TERM_SIZE_QUIET_MS)
	}
	term_size_send(app, t)
}

// Has the grid rested? (The first size goes at once: a shell starts at the size it will have.)
term_size_rested :: proc(now, grid_ms: f64, told_once: bool) -> bool {
	return !told_once || now - grid_ms >= TERM_SIZE_QUIET_MS
}

// Is what the shell paints after a new size still coming? The picture before it stays until then: never one of its pieces.
term_painting :: proc(now, told_ms, fed_ms, asked_ms: f64) -> bool {
	if asked_ms != 0 && now - asked_ms < TERM_PAINT_MOST_MS { return true }   // (an answer that never comes holds nothing for long)
	if told_ms == 0 || now - told_ms >= TERM_PAINT_MOST_MS { return false }
	return now - max(told_ms, fed_ms) < TERM_PAINT_QUIET_MS
}

// (Only to a shell attached: one that ended has no size to take; what happened meanwhile goes when it is attached, term_link_set.)
term_size_send :: proc(app: ^App, t: ^Term) {
	size := [2]u16{t.cols, t.rows}
	if t.link != .Attached || !t.fitted || t.size_flying || size == t.size_sent { return }
	if !term_size_rested(ui.now_ms(), t.grid_ms, t.size_sent != {}) { return }
	t.size_flying, t.size_asked, t.asked_ms = true, size, ui.now_ms()
	request(app, .Pty_Size, "PUT", term_path(t), fmt.tprintf(`{{"size":{{"rows":%d,"cols":%d}}}}`, t.rows, t.cols), t.id, conn = t.server)
}

// Refused, it is not asked again for the same size: the frames would ask for ever.
term_size_answered :: proc(app: ^App, id: string) {
	t := term_find(app, id)
	if t == nil { return }
	t.size_flying, t.size_sent = false, t.size_asked
	t.told_ms, t.asked_ms = ui.now_ms(), 0
	deferred_ask(&app.cx.due[.Term_Size], TERM_PAINT_QUIET_MS, TERM_PAINT_MOST_MS)
	term_size_send(app, t)
}

// The banner's Close, in the dock or in a window of its own: after the frame, whichever built it.
terms_close_due :: proc(app: ^App) {
	s := &app.cx.terms
	if s.close_due == 0 { return }
	panel_close(app, s.close_due)
	s.close_due = 0
}

// What comes due after a size: the shell is told, or its picture shown. (A frame, where the window may be at rest.)
terms_size_due :: proc(app: ^App) {
	s := &app.cx.terms
	now := ui.now_ms()
	for t in s.list {
		term_size_send(app, t)
		if t.told_ms == 0 { continue }
		if term_painting(now, t.told_ms, t.fed_ms, t.asked_ms) {
			deferred_ask(&app.cx.due[.Term_Size], TERM_PAINT_QUIET_MS, TERM_PAINT_MOST_MS)
		} else {
			t.told_ms = 0
		}
	}
	app.settle = max(app.settle, FRAMES_AFTER_INPUT)
}

@(private = "file")
Term_Run :: struct { x: f32, text: string, color: Color, bold: bool }

// Cells of the same look go together, so that a row is a few runs of text and not one draw per cell; what is not ASCII stands alone, at
// the column it belongs to, whatever width the fallback face gives it.
@(private = "file")
term_draw :: proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
	app := the_app
	s := &app.cx.terms
	t := (^Term)(user)
	if t.vt == nil { return }
	draw.rect(dc, b.rect, hex(HEX_TERM_BG))
	// (the state read last holds the picture from before the shell's new size)
	if !term_painting(ui.now_ms(), t.told_ms, t.fed_ms, t.asked_ms) || !t.drawn {
		if ghostty_render_state_update(t.state, t.vt) != VT_OK { return }
		t.drawn = true
	}
	colors := Vt_Colors{size = size_of(Vt_Colors)}
	if ghostty_render_state_get(t.state, VT_STATE_COLORS, &colors) != VT_OK { return }
	if ghostty_render_state_get(t.state, VT_STATE_ROW_ITERATOR, &t.rows_it) != VT_OK { return }
	origin := b.rect.min + TERM_PAD
	runs := make([dynamic]Term_Run, context.temp_allocator)
	row := strings.builder_make(context.temp_allocator)
	y := 0
	for ghostty_render_state_row_iterator_next(t.rows_it) {
		defer y += 1
		if ghostty_render_state_row_get(t.rows_it, VT_ROW_CELLS, &t.cells) != VT_OK { continue }
		picked := Vt_Row_Selection{size = size_of(Vt_Row_Selection)}
		has_picked := ghostty_render_state_row_get(t.rows_it, VT_ROW_SELECTION, &picked) == VT_OK
		top := origin.y + f32(y) * t.metrics.cell_h
		clear(&runs)
		strings.builder_reset(&row)
		run_x: f32
		run_color: Color
		run_bold := false
		flush :: proc(runs: ^[dynamic]Term_Run, row: ^strings.Builder, x: f32, color: Color, bold: bool) {
			trimmed := strings.trim_right_space(strings.to_string(row^))
			if trimmed != "" { append(runs, Term_Run{x, strings.clone(trimmed, context.temp_allocator), color, bold}) }
			strings.builder_reset(row)
		}
		x := 0
		for ghostty_render_state_row_cells_next(t.cells) {
			defer x += 1
			left := origin.x + f32(x) * t.metrics.cell_w
			style: Vt_Style
			ghostty_render_state_row_cells_get(t.cells, VT_CELL_STYLE, &style)
			bold := style.flags & VT_STYLE_BOLD != 0
			fg := colors.foreground
			ghostty_render_state_row_cells_get(t.cells, VT_CELL_FG, &fg)
			bg := colors.background
			has_bg := ghostty_render_state_row_cells_get(t.cells, VT_CELL_BG, &bg) == VT_OK
			if style.flags & VT_STYLE_INVERSE != 0 { fg, bg, has_bg = bg, fg, true }
			cell := draw.Rect{{left, top}, {left + t.metrics.cell_w, top + t.metrics.cell_h}}
			if has_picked && x >= int(picked.start_x) && x <= int(picked.end_x) {
				draw.rect(dc, cell, hex(HEX_TERM_SELECTION))
			} else if has_bg {
				draw.rect(dc, cell, color_of(bg))
			}
			color := color_of(fg)
			if style.flags & VT_STYLE_FAINT != 0 { color.a *= TERM_FAINT }
			glyphs: [8]u32
			read := Vt_Codepoints{ptr = &glyphs[0], cap = len(glyphs)}
			ghostty_render_state_row_cells_get(t.cells, VT_CELL_GRAPHEMES_BUF, &read)   // (more than it holds: the first of them)
			n := min(read.len, len(glyphs))
			if style.flags & VT_STYLE_INVISIBLE != 0 { n = 0 }
			if style.flags & VT_STYLE_UNDERLINE != 0 { draw.rect(dc, {{left, top + t.metrics.ascent + 1}, {left + t.metrics.cell_w, top + t.metrics.ascent + 2}}, color) }
			if style.flags & VT_STYLE_STRIKETHROUGH != 0 { draw.rect(dc, {{left, top + t.metrics.cell_h * 0.55}, {left + t.metrics.cell_w, top + t.metrics.cell_h * 0.55 + 1}}, color) }
			ascii := n == 1 && glyphs[0] < 0x80
			if n == 0 {
				if strings.builder_len(row) > 0 { strings.write_byte(&row, ' ') }
				continue
			}
			if !ascii || color != run_color || bold != run_bold || strings.builder_len(row) == 0 {
				flush(&runs, &row, run_x, run_color, run_bold)
				run_x, run_color, run_bold = left, color, bold
			}
			for g in glyphs[:n] { strings.write_rune(&row, rune(g)) }
			if !ascii { flush(&runs, &row, run_x, run_color, run_bold) }
		}
		flush(&runs, &row, run_x, run_color, run_bold)
		// (each letter a cell wide: at the face's own advance a run fell behind the grid, and the next run, at its cell,
		// left a gap after every change of colour)
		for r in runs {
			draw.text_ex(dc, r.bold ? app.term_font_bold : app.term_font, t.metrics.font_size, {r.x, top + t.metrics.ascent}, r.color, r.text, {letter_spacing = r.bold ? t.metrics.spacing_bold : t.metrics.spacing})
		}
	}
	term_draw_cursor(t, s, dc, origin, &colors)
}

@(private = "file")
term_draw_cursor :: proc(t: ^Term, s: ^Terminals, dc: ^draw.Context, origin: [2]f32, colors: ^Vt_Colors) {
	visible, in_view: bool
	ghostty_render_state_get(t.state, VT_STATE_CURSOR_VISIBLE, &visible)
	ghostty_render_state_get(t.state, VT_STATE_CURSOR_IN_VIEW, &in_view)
	if !visible || !in_view { return }
	cx, cy: u16
	ghostty_render_state_get(t.state, VT_STATE_CURSOR_X, &cx)
	ghostty_render_state_get(t.state, VT_STATE_CURSOR_Y, &cy)
	look: i32
	ghostty_render_state_get(t.state, VT_STATE_CURSOR_STYLE, &look)
	color := color_of(colors.cursor_has_value ? colors.cursor : colors.foreground)
	left, top := origin.x + f32(cx) * t.metrics.cell_w, origin.y + f32(cy) * t.metrics.cell_h
	r := draw.Rect{{left, top}, {left + t.metrics.cell_w, top + t.metrics.cell_h}}
	switch {
	case s.focused != t:
		t1 := px1()
		draw.rect(dc, {r.min, {r.max.x, r.min.y + t1}}, color)
		draw.rect(dc, {{r.min.x, r.max.y - t1}, r.max}, color)
		draw.rect(dc, {r.min, {r.min.x + t1, r.max.y}}, color)
		draw.rect(dc, {{r.max.x - t1, r.min.y}, r.max}, color)
	case look == VT_CURSOR_BAR:       draw.rect(dc, {r.min, {r.min.x + 2 * px1(), r.max.y}}, color)
	case look == VT_CURSOR_UNDERLINE: draw.rect(dc, {{r.min.x, r.max.y - 2 * px1()}, r.max}, color)
	case:
		color.a *= TERM_CURSOR_ALPHA
		draw.rect(dc, r, color)
	}
}

////////////////////////////////
// The grid's scroll bar

// How tall the space the grid's box scrolls over is: the box as many times as the scrollback holds its view (the box's own
// height: nothing to scroll).
@(private = "file")
term_scroll_height :: proc(t: ^Term, b: ^ui.Box) -> f32 {
	bar: Vt_Scrollbar
	h := max(b.size.y, 1)
	if t.vt == nil || ghostty_terminal_get(t.vt, VT_DATA_SCROLLBAR, &bar) != VT_OK || bar.total <= bar.len || bar.len == 0 { return h }
	return h * f32(bar.total) / f32(bar.len)
}

// The box's scroll and the grid's view, together: the bar moved (held, pressed in its track) moves the view to the row it says;
// else the view (the wheel, what the shell writes, Shift+Page Up) puts the box's scroll where it is.
@(private = "file")
term_scroll_sync :: proc(t: ^Term, b: ^ui.Box) {
	bar: Vt_Scrollbar
	if t.vt == nil || ghostty_terminal_get(t.vt, VT_DATA_SCROLLBAR, &bar) != VT_OK || bar.total <= bar.len { t.bar_at = 0; return }
	limit := ui.view_limit(b)
	if limit <= 0 { return }
	room := f32(bar.total - bar.len)
	if abs(b.view_target.y - t.bar_at) > 0.5 {
		want := i64(math.round(clamp(b.view_target.y / limit, 0, 1) * room))
		ghostty_terminal_scroll_viewport(t.vt, {tag = .Delta, value = want - i64(bar.offset)})
		t.bar_at = b.view_target.y
		return
	}
	y := limit * f32(bar.offset) / room
	ui.view_jump(b, y)
	t.bar_at = y
}

// Whether `p` is on the grid's scroll bar (where the toolkit takes a press on it): that press is the interface's, not the shell's.
@(private = "file")
term_on_bar :: proc(t: ^Term, p: [2]f32) -> bool {
	b := ui.box_from_key(t.box)
	if b == nil { return false }
	_, on := ui.scrollbar_under(b, p)
	return on
}

////////////////////////////////
// Each shell's zoom

// The shells' zooms, by their id on the server: a shell found again (the program started again, the server come back) has
// its own. The server keeps a shell's title and size only: the zooms are the client's, in terminal_zoom.txt beside the
// preferences, one "id<TAB>zoom" a line. A shell closed from here leaves the file.
Term_Zooms :: struct {
	file:  string,              // ("": nowhere, as in the tests)
	by_id: map[string]f32,      // (keys owned; 1 is not kept)
}

term_zooms_load :: proc(app: ^App, file: string) {
	z := &app.term_zooms
	z.file = strings.clone(file)
	if file == "" { return }
	data, err := os.read_entire_file(file, context.temp_allocator)
	if err != nil { return }
	rest := string(data)
	for line in strings.split_lines_iterator(&rest) {
		id, _, value := strings.partition(line, "\t")
		v, ok := strconv.parse_f32(value)
		if id != "" && ok && v != 1 && id not_in z.by_id { z.by_id[strings.clone(id)] = clamp(v, TERM_ZOOM_MIN, TERM_ZOOM_MAX) }
	}
}

// A shell's zoom, within its bounds; kept when the shell is one of the server's (an output's grid has its own for the time
// it is open).
term_zoom_set :: proc(app: ^App, t: ^Term, zoom: f32) {
	t.zoom = clamp(zoom, TERM_ZOOM_MIN, TERM_ZOOM_MAX)
	if abs(t.zoom - 1) < 0.01 { t.zoom = 1 }   // (steps of 1.1 back and forth come back near 1, not to it)
	// (a frame when it rests: the grid takes its new columns and rows then, term_fit)
	t.zoom_ms = ui.now_ms()
	app.cx.due[.Term_Size] = {}
	deferred_ask(&app.cx.due[.Term_Size], TERM_ZOOM_REST_MS)
	if term_find(app, t.id) != t { return }
	z := &app.term_zooms
	if t.zoom == 1 {
		term_zoom_forget(app, t.id)
		return
	}
	if t.id not_in z.by_id { z.by_id[strings.clone(t.id)] = t.zoom } else { z.by_id[t.id] = t.zoom }
	term_zooms_save(z)
}

term_zoom_forget :: proc(app: ^App, id: string) {
	z := &app.term_zooms
	if id not_in z.by_id { return }
	key, _ := delete_key(&z.by_id, id)
	delete(key)
	term_zooms_save(z)
}

@(private = "file")
term_zooms_save :: proc(z: ^Term_Zooms) {
	if z.file == "" { return }
	b := strings.builder_make(context.temp_allocator)
	for id, v in z.by_id { fmt.sbprintf(&b, "%s\t%v\n", id, v) }   // (%v: read back, the same number)
	_ = os.write_entire_file(z.file, transmute([]u8)strings.to_string(b))
}
