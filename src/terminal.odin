// The Terminal panel: shells of the server (its PTYs), wherever the server runs, shown and typed in here. Emulation is libghostty-vt's
// (vt.odin): the bytes of a PTY go in, the grid comes out, and the keys go through its encoders, so that what programs ask of a terminal
// is answered as Ghostty answers it.
//
// A thread per shell owns its WebSocket: it reads, posts what comes, and sends what waits in the shell's outbox between two reads. The
// interface only ever puts bytes in that box: it never waits for the network, whatever the shell does. The keys of a focused terminal are taken out of the frame's events
// before the interface sees them (term_events): Ctrl+K belongs to the shell there, and Escape does not stop a run. Ctrl+Shift+C and V
// copy and paste. A shell outlives the program: it is found again when the panel opens, its output replayed by the server.
package occ

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:unicode/utf8"
import "gt:draw"
import "gt:font"
import "gt:platform"
import "gt:ui"

// In the program, which is one file: the licence asks to go with the code.
GHOSTTY_LICENSE :: #load("../assets/GHOSTTY-LICENSE.txt", string)

// What a shell's thread shares with the interface. (Never freed: a thread may still look at it after the shell is gone, and it is small.)
Term_Conn :: struct {
	stop: bool,
	lock: sync.Mutex,
	out:  [dynamic]u8,   // what goes to the shell
}

Term :: struct {
	id, title, dir: string,   // (owned)
	ended:  bool,
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
	lines:  [dynamic]string,   // the text of the rows shown, for a copy (owned)
	selecting: bool,           // the left button is held on the grid
	has_selection: bool,
	sel_from, sel_to: [2]int,  // column, row
}

Terminals :: struct {
	open:    bool,
	asked:   bool,             // the shells of the server were looked for
	list:    [dynamic]^Term,
	active:  int,
	box:     ui.Key,
	rect:    draw.Rect,        // the grid, as last laid out
	focused: bool,
	want_focus: bool,
	font_size, cell_w, cell_h, ascent: f32,
}

@(private = "file")
term_location :: proc(dir: string) -> string {
	return dir != "" ? fmt.tprintf("location[directory]=%s", url_escape(dir)) : ""
}

@(private = "file")
term_path :: proc(t: ^Term, tail := "") -> string {
	q := term_location(t.dir)
	return fmt.tprintf("/api/pty/%s%s%s%s", url_escape(t.id), tail, q != "" ? "?" : "", q)
}

// The emulation of a shell, connected to nothing yet.
term_new :: proc(id, title, dir: string, cols: u16 = TERM_COLS, rows: u16 = TERM_ROWS) -> ^Term {
	t := new(Term)
	t.id, t.title, t.dir = strings.clone(id), strings.clone(title), strings.clone(dir)
	t.cols, t.rows = cols, rows
	if ghostty_terminal_new(nil, &t.vt, cols, rows) != VT_OK { return t }
	ghostty_render_state_new(nil, &t.state)
	ghostty_render_state_row_iterator_new(nil, &t.rows_it)
	ghostty_render_state_row_cells_new(nil, &t.cells)
	ghostty_key_encoder_new(nil, &t.key_enc)
	ghostty_key_event_new(nil, &t.key_ev)
	ghostty_mouse_encoder_new(nil, &t.mouse_enc)
	ghostty_mouse_event_new(nil, &t.mouse_ev)
	lines: uint = TERM_SCROLLBACK_LINES
	ghostty_terminal_set(t.vt, VT_OPT_SCROLLBACK_MAX_LINES, &lines)
	ghostty_terminal_set(t.vt, VT_OPT_USERDATA, t)
	ghostty_terminal_set(t.vt, VT_OPT_WRITE_PTY, rawptr(term_answers))
	ghostty_terminal_set(t.vt, VT_OPT_TITLE_CHANGED, rawptr(term_title_changed))
	bg, fg := rgb_of(HEX_TERM_BG), rgb_of(HEX_TEXT)
	ghostty_terminal_set(t.vt, VT_OPT_COLOR_BACKGROUND, &bg)
	ghostty_terminal_set(t.vt, VT_OPT_COLOR_FOREGROUND, &fg)
	track := true
	ghostty_mouse_encoder_setopt(t.mouse_enc, VT_MOUSE_OPT_TRACK_LAST_CELL, &track)
	return t
}

@(private = "file")
rgb_of :: proc(x: u32) -> Vt_Rgb { return {u8(x >> 24), u8(x >> 16), u8(x >> 8)} }   // (0xRRGGBBAA)

@(private = "file")
color_of :: proc(c: Vt_Rgb) -> Color { return hex(u32(c.r) << 24 | u32(c.g) << 16 | u32(c.b) << 8 | 0xff) }

term_free :: proc(t: ^Term) {
	if t.conn != nil { sync.atomic_store(&t.conn.stop, true) }
	if t.vt != nil {
		ghostty_mouse_event_free(t.mouse_ev)
		ghostty_mouse_encoder_free(t.mouse_enc)
		ghostty_key_event_free(t.key_ev)
		ghostty_key_encoder_free(t.key_enc)
		ghostty_render_state_row_cells_free(t.cells)
		ghostty_render_state_row_iterator_free(t.rows_it)
		ghostty_render_state_free(t.state)
		ghostty_terminal_free(t.vt)
	}
	for l in t.lines { delete(l) }
	delete(t.lines); delete(t.id); delete(t.title); delete(t.dir)
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

term_send :: proc(t: ^Term, s: string) {
	if t.conn == nil || len(s) == 0 { return }
	sync.lock(&t.conn.lock)
	append(&t.conn.out, s)
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
	if len(data) > 0 { _ = occ_ws_send(ws, raw_data(data), len(data)) }
	free_all(context.temp_allocator)
}

////////////////////////////////
// The shell's thread

@(private = "file")
Term_Thread :: struct { app: ^App, conn: ^Term_Conn, http: ^Http, id, path: string }

@(private = "file")
Term_Data :: struct { id, text: string, ended: bool }

@(private = "file")
term_connect :: proc(app: ^App, t: ^Term) {
	t.conn = new(Term_Conn)
	job := new(Term_Thread)
	job^ = {app, t.conn, &app.conn.http, strings.clone(t.id), strings.clone(term_path(t, "/connect"))}
	thread.create_and_start_with_poly_data(job, proc(job: ^Term_Thread) {
		app := job.app
		post :: proc(app: ^App, id, text: string, ended: bool) {
			d := new(Term_Data)
			d^ = {strings.clone(id), text, ended}
			if !ui.post(&app.ui_state, term_answer, d) { delete(d.id); delete(d.text); free(d) }
		}
		path := fmt.aprintf("%s%scursor=0", job.path, strings.contains(job.path, "?") ? "&" : "?")
		ws := occ_ws_open(job.http.client, raw_data(path), len(path))
		delete(path)
		if ws != nil {
			occ_ws_read_timeout(ws, TERM_READ_MS)
			for !sync.atomic_load(&job.conn.stop) {
				term_flush(ws, job.conn)
				out: Occ_Buf
				r := occ_ws_read(ws, &out)
				if r < 0 { break }
				if r == 0 { continue }   // (the read waited, a little: this is what sends come between)
				text := string(out.ptr[:out.len])
				if len(text) > 0 && text[0] != 0 { post(app, job.id, strings.clone(text), false) }   // (a zero first: where the server is, not output)
				occ_buf_free(out)
			}
			occ_ws_free(ws)
		}
		if !sync.atomic_load(&job.conn.stop) { post(app, job.id, "", true) }
		delete(job.id); delete(job.path)
		free(job)
	}, self_cleanup = true)
}

// On the interface's thread.
@(private = "file")
term_answer :: proc(data: rawptr, word: u64) {
	app := the_app
	d := (^Term_Data)(data)
	defer { delete(d.id); delete(d.text); free(d) }
	t := term_find(app, d.id)
	if t == nil { return }
	if d.ended {
		t.ended = true
	} else {
		term_feed(t, d.text)
	}
	app.frames = max(app.frames, FRAMES_AFTER_INPUT)
}

term_feed :: proc(t: ^Term, s: string) {
	if t.vt != nil && len(s) > 0 { ghostty_terminal_vt_write(t.vt, raw_data(s), len(s)) }
}

term_find :: proc(app: ^App, id: string) -> ^Term {
	for t in app.cx.terms.list { if t.id == id { return t } }
	return nil
}

////////////////////////////////
// The shells of the server

terminal_toggle :: proc(app: ^App) {
	s := &app.cx.terms
	s.open = !s.open
	if s.open {
		dock_setup(app)
		ui.dock_activate(&app.dock, u32(Panel.Terminal))
		s.want_focus = true
		if !s.asked {
			s.asked = true
			q := term_location(chat_dir(app))
			request(app, .Pty_List, "GET", fmt.tprintf("/api/pty%s%s", q != "" ? "?" : "", q), tag = chat_dir(app))
		}
	} else {
		s.focused = false
		ui.dock_close(&app.dock, u32(Panel.Terminal))
	}
	app.frames = max(app.frames, FRAMES_AFTER_INPUT)
}

@(private = "file")
term_add :: proc(app: ^App, it: json.Value, dir: string) {
	s := &app.cx.terms
	id := jstr(it, "id")
	if id == "" || term_find(app, id) != nil { return }
	t := term_new(id, jstr(it, "title"), dir)
	append(&s.list, t)
	s.active = len(s.list) - 1
	term_connect(app, t)
}

// What was left running comes back; else a first shell.
terminals_load :: proc(app: ^App, dir: string, v: json.Value) {
	for it in jarr(v, "data") { if jstr(it, "status") == "running" { term_add(app, it, dir) } }
	if len(app.cx.terms.list) == 0 { term_create(app) }
}

term_create :: proc(app: ^App) {
	dir := chat_dir(app)
	q := term_location(dir)
	request(app, .Pty_Made, "POST", fmt.tprintf("/api/pty%s%s", q != "" ? "?" : "", q), fmt.tprintf(`{{"title":"Terminal %d"}}`, len(app.cx.terms.list) + 1), dir)
}

term_made :: proc(app: ^App, dir: string, v: json.Value) {
	term_add(app, jget(v, "data"), dir)
	app.cx.terms.want_focus = true
}

@(private = "file")
term_close :: proc(app: ^App, i: int) {
	s := &app.cx.terms
	t := s.list[i]
	request(app, .Action, "DELETE", term_path(t))
	ordered_remove(&s.list, i)
	term_free(t)
	s.active = clamp(s.active, 0, max(len(s.list) - 1, 0))
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
	ghostty_key_encoder_setopt_from_terminal(t.key_enc, t.vt)
	ghostty_key_event_set_key(t.key_ev, key)
	ghostty_key_event_set_action(t.key_ev, repeat ? VT_ACTION_REPEAT : VT_ACTION_PRESS)
	ghostty_key_event_set_mods(t.key_ev, mods_of(mods))
	ghostty_key_event_set_consumed_mods(t.key_ev, 0)
	ghostty_key_event_set_unshifted_codepoint(t.key_ev, unshifted)
	ghostty_key_event_set_utf8(t.key_ev, nil, 0)
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
	on: bool
	return ghostty_terminal_get(t.vt, VT_DATA_MOUSE_TRACKING, &on) == VT_OK && on
}

@(private = "file")
term_cell_at :: proc(s: ^Terminals, p: [2]f32) -> [2]int {
	x := int((p.x - s.rect.min.x - TERM_PAD) / max(s.cell_w, 1))
	y := int((p.y - s.rect.min.y - TERM_PAD) / max(s.cell_h, 1))
	return {max(x, 0), max(y, 0)}
}

@(private = "file")
term_mouse :: proc(t: ^Term, s: ^Terminals, action, button: i32, pos: [2]f32, mods: platform.Modifiers, held: bool) {
	ghostty_mouse_encoder_setopt_from_terminal(t.mouse_enc, t.vt)
	size := Vt_Mouse_Size{
		size = size_of(Vt_Mouse_Size), screen_width = u32(s.rect.max.x - s.rect.min.x), screen_height = u32(s.rect.max.y - s.rect.min.y),
		cell_width = u32(s.cell_w), cell_height = u32(s.cell_h),
		padding_top = u32(TERM_PAD), padding_bottom = u32(TERM_PAD), padding_right = u32(TERM_PAD), padding_left = u32(TERM_PAD),
	}
	ghostty_mouse_encoder_setopt(t.mouse_enc, VT_MOUSE_OPT_SIZE, &size)
	any := held
	ghostty_mouse_encoder_setopt(t.mouse_enc, VT_MOUSE_OPT_ANY_PRESSED, &any)
	ghostty_mouse_event_set_action(t.mouse_ev, action)
	if button != 0 { ghostty_mouse_event_set_button(t.mouse_ev, button) } else { ghostty_mouse_event_clear_button(t.mouse_ev) }
	ghostty_mouse_event_set_mods(t.mouse_ev, mods_of(mods))
	ghostty_mouse_event_set_position(t.mouse_ev, {pos.x - s.rect.min.x, pos.y - s.rect.min.y})
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

@(private = "file")
term_selection_text :: proc(t: ^Term) -> string {
	a, b := t.sel_from, t.sel_to
	if a.y > b.y || (a.y == b.y && a.x > b.x) { a, b = b, a }
	out := strings.builder_make(context.temp_allocator)
	for y in a.y ..= b.y {
		if y >= len(t.lines) { break }
		runes := utf8.string_to_runes(t.lines[y], context.temp_allocator)
		from := y == a.y ? min(a.x, len(runes)) : 0
		to := y == b.y ? min(b.x + 1, len(runes)) : len(runes)
		for r in runes[from:max(from, to)] { strings.write_rune(&out, r) }
		if y < b.y { strings.write_byte(&out, '\n') }
	}
	return strings.to_string(out)
}

// Before the interface sees them: what goes to the shell is taken out. Returns what is left.
term_events :: proc(app: ^App, events: []platform.Event) -> []platform.Event {
	s := &app.cx.terms
	if !s.open || len(s.list) == 0 || overlay_open(app) { return events }
	t := s.list[clamp(s.active, 0, len(s.list) - 1)]
	if t.vt == nil { return events }
	kept := 0
	for e in events {
		inside := draw.rect_contains(s.rect, e.pos)
		take := false
		#partial switch e.kind {
		case .Key_Press:
			if !s.focused { break }
			take = true
			switch {
			case e.key == .C && e.mods == {.Ctrl, .Shift}:
				if t.has_selection { clip_set(term_selection_text(t)) }
			case e.key == .V && e.mods == {.Ctrl, .Shift}:
				term_paste(app, t)
			case e.key == .Page_Up && e.mods == {.Shift}:
				ghostty_terminal_scroll_viewport(t.vt, {tag = .Delta, value = -i64(t.rows)})
			case e.key == .Page_Down && e.mods == {.Shift}:
				ghostty_terminal_scroll_viewport(t.vt, {tag = .Delta, value = i64(t.rows)})
			case e.key == .Shift || e.key == .Ctrl || e.key == .Alt:
			case:
				if s := term_encode_key(t, e.key, e.mods, e.repeat); s != "" {
					term_send(t, s)
					ghostty_terminal_scroll_viewport(t.vt, {tag = .Bottom})
					t.has_selection = false
				}
			}
		case .Key_Release:
			take = s.focused
		case .Text:
			if !s.focused { break }
			take = true
			if e.text >= ' ' && e.text != 127 {
				b, n := utf8.encode_rune(e.text)
				term_send(t, string(b[:n]))
				ghostty_terminal_scroll_viewport(t.vt, {tag = .Bottom})
				t.has_selection = false
			}
		case .Scroll:
			if !inside { break }
			take = true
			if term_tracks_mouse(t) {
				button: i32 = e.delta.y > 0 ? VT_MOUSE_FIVE : VT_MOUSE_FOUR
				term_mouse(t, s, VT_MOUSE_PRESS, button, e.pos, e.mods, false)
				term_mouse(t, s, VT_MOUSE_RELEASE, button, e.pos, e.mods, false)
			} else {
				ghostty_terminal_scroll_viewport(t.vt, {tag = .Delta, value = i64(math.round(e.delta.y * TERM_WHEEL_LINES))})
			}
		case .Mouse_Press:
			if !inside { break }
			if term_tracks_mouse(t) && .Shift not_in e.mods {
				term_mouse(t, s, VT_MOUSE_PRESS, mouse_button_of(e.button), e.pos, e.mods, true)
			} else if e.button == .Left {
				t.selecting, t.has_selection = true, false
				t.sel_from = term_cell_at(s, e.pos)
				t.sel_to = t.sel_from
			}
		case .Mouse_Release:
			if t.selecting {
				t.selecting = false
				t.has_selection = t.sel_from != t.sel_to
			} else if inside && term_tracks_mouse(t) {
				term_mouse(t, s, VT_MOUSE_RELEASE, mouse_button_of(e.button), e.pos, e.mods, false)
			}
		case .Mouse_Move:
			if t.selecting {
				t.sel_to = term_cell_at(s, e.pos)
			} else if inside && term_tracks_mouse(t) {
				term_mouse(t, s, VT_MOUSE_MOTION, 0, e.pos, e.mods, e.buttons != {})
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

terminal_panel :: proc(app: ^App, em: f32) {
	s := &app.cx.terms
	strip := math.round(em * BUTTON_COMPACT_H_EM)
	ui.next({width = ui.fill(), height = ui.children_sum(), axis = .X, cross = .Center})
	if ui.row(.Center, id = "###term_tabs") {
		ui.spacer(ui.px(em * 0.4))
		for t, i in s.list {
			if bevel_button(fmt.tprintf("###term_t%d", i), label_safe(term_label(t)), "", i == s.active ? .Toggled : .Ghost, height = strip).clicked {
				s.active, s.want_focus = i, true
			}
			if i == s.active {
				if glyph_button(fmt.tprintf("###term_x%d", i), ICO_CANCEL, strip).clicked {
					term_close(app, i)
					s.want_focus = true
					break
				}
			}
			ui.spacer(ui.px(em * 0.2))
		}
		if bevel_button("###term_new", "", ICO_ADD, .Ghost, height = strip).clicked { term_create(app) }
	}
	ui.next({width = ui.fill(), height = ui.fill(), cursor = .Text})
	b := ui.build_box({.Clickable, .Focusable, .Clip}, "###term_box")
	s.box = b.key
	sig := ui.signal(b)
	if sig.pressed || s.want_focus {
		ui.set_focus(b.key)
		s.want_focus = false
	}
	s.focused = ui.focus_key() == b.key
	s.rect = b.rect
	s.font_size = math.round(em * FS_NOTE)
	s.cell_w = math.ceil(font.text_width(&app.fonts, app.mono, s.font_size, "M"))
	m := font.metrics(&app.fonts, app.mono, s.font_size)
	s.cell_h = math.ceil(m.line_height)
	s.ascent = m.ascent
	if len(s.list) == 0 { return }
	t := s.list[clamp(s.active, 0, len(s.list) - 1)]
	term_fit(app, t, b.rect)
	b.custom, b.custom_user = term_draw, t
}

// A shell names itself by the path of its program: the program is enough.
@(private = "file")
term_label :: proc(t: ^Term) -> string {
	name := base_name(t.title)
	name = strings.trim_suffix(strings.trim_suffix(name, ".exe"), ".EXE")
	return ellipsize(t.ended ? fmt.tprintf("%s (ended)", name) : name, TERM_TAB_CHARS)
}

// The grid follows the panel, and the shell the grid.
@(private = "file")
term_fit :: proc(app: ^App, t: ^Term, r: draw.Rect) {
	s := &app.cx.terms
	if t.vt == nil || s.cell_w <= 0 { return }
	cols := u16(clamp((r.max.x - r.min.x - 2 * TERM_PAD) / s.cell_w, 2, 1000))
	rows := u16(clamp((r.max.y - r.min.y - 2 * TERM_PAD) / s.cell_h, 2, 1000))
	if r.max.x - r.min.x < 1 || (cols == t.cols && rows == t.rows) { return }
	t.cols, t.rows = cols, rows
	ghostty_terminal_resize(t.vt, cols, rows, u32(s.cell_w), u32(s.cell_h))
	request(app, .Action, "PUT", term_path(t), fmt.tprintf(`{{"size":{{"rows":%d,"cols":%d}}}}`, rows, cols))
}

@(private = "file")
Term_Run :: struct { x: f32, text: string, color: Color, bold: bool }

@(private = "file")
in_selection :: proc(t: ^Term, x, y: int) -> bool {
	if !t.has_selection && !t.selecting { return false }
	a, b := t.sel_from, t.sel_to
	if a.y > b.y || (a.y == b.y && a.x > b.x) { a, b = b, a }
	if y < a.y || y > b.y { return false }
	if y == a.y && x < a.x { return false }
	if y == b.y && x > b.x { return false }
	return true
}

// Cells of the same look go together, so that a row is a few runs of text and not one draw per cell; what is not ASCII stands alone, at
// the column it belongs to, whatever width the fallback face gives it.
@(private = "file")
term_draw :: proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
	app := the_app
	s := &app.cx.terms
	t := (^Term)(user)
	if t.vt == nil { return }
	draw.rect(dc, b.rect, hex(HEX_TERM_BG))
	if ghostty_render_state_update(t.state, t.vt) != VT_OK { return }
	colors := Vt_Colors{size = size_of(Vt_Colors)}
	if ghostty_render_state_colors_get(t.state, &colors) != VT_OK { return }
	if ghostty_render_state_get(t.state, VT_STATE_ROW_ITERATOR, &t.rows_it) != VT_OK { return }
	origin := b.rect.min + TERM_PAD
	for l in t.lines { delete(l) }
	clear(&t.lines)
	runs := make([dynamic]Term_Run, context.temp_allocator)
	row := strings.builder_make(context.temp_allocator)
	line := strings.builder_make(context.temp_allocator)
	y := 0
	for ghostty_render_state_row_iterator_next(t.rows_it) {
		defer y += 1
		if ghostty_render_state_row_get(t.rows_it, VT_ROW_CELLS, &t.cells) != VT_OK { continue }
		top := origin.y + f32(y) * s.cell_h
		clear(&runs)
		strings.builder_reset(&row)
		strings.builder_reset(&line)
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
			left := origin.x + f32(x) * s.cell_w
			n: u32
			ghostty_render_state_row_cells_get(t.cells, VT_CELL_GRAPHEMES_LEN, &n)
			style := Vt_Style{size = size_of(Vt_Style)}
			ghostty_render_state_row_cells_get(t.cells, VT_CELL_STYLE, &style)
			fg := colors.foreground
			ghostty_render_state_row_cells_get(t.cells, VT_CELL_FG, &fg)
			bg := colors.background
			has_bg := ghostty_render_state_row_cells_get(t.cells, VT_CELL_BG, &bg) == VT_OK
			if style.inverse { fg, bg, has_bg = bg, fg, true }
			cell := draw.Rect{{left, top}, {left + s.cell_w, top + s.cell_h}}
			if in_selection(t, x, y) {
				draw.rect(dc, cell, hex(HEX_TERM_SELECTION))
			} else if has_bg {
				draw.rect(dc, cell, color_of(bg))
			}
			color := color_of(fg)
			if style.faint { color.a *= TERM_FAINT }
			glyphs: [8]u32
			if n > 0 && n <= len(glyphs) { ghostty_render_state_row_cells_get(t.cells, VT_CELL_GRAPHEMES_BUF, &glyphs) }
			if style.invisible { n = 0 }
			if style.underline != 0 { draw.rect(dc, {{left, top + s.ascent + 1}, {left + s.cell_w, top + s.ascent + 2}}, color) }
			if style.strikethrough { draw.rect(dc, {{left, top + s.cell_h * 0.55}, {left + s.cell_w, top + s.cell_h * 0.55 + 1}}, color) }
			ascii := n == 1 && glyphs[0] < 0x80
			if n == 0 {
				strings.write_byte(&line, ' ')
				if strings.builder_len(row) > 0 { strings.write_byte(&row, ' ') }
				continue
			}
			for g in glyphs[:min(n, len(glyphs))] { strings.write_rune(&line, rune(g)) }
			if !ascii || color != run_color || style.bold != run_bold || strings.builder_len(row) == 0 {
				flush(&runs, &row, run_x, run_color, run_bold)
				run_x, run_color, run_bold = left, color, style.bold
			}
			for g in glyphs[:min(n, len(glyphs))] { strings.write_rune(&row, rune(g)) }
			if !ascii { flush(&runs, &row, run_x, run_color, run_bold) }
		}
		flush(&runs, &row, run_x, run_color, run_bold)
		for r in runs { draw.text(dc, r.bold ? app.mono_bold : app.mono, s.font_size, {r.x, top + s.ascent}, r.color, r.text) }
		append(&t.lines, strings.clone(strings.trim_right_space(strings.to_string(line))))
	}
	term_draw_cursor(t, s, dc, origin, &colors)
	term_draw_scrollbar(t, b.rect, dc)
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
	left, top := origin.x + f32(cx) * s.cell_w, origin.y + f32(cy) * s.cell_h
	r := draw.Rect{{left, top}, {left + s.cell_w, top + s.cell_h}}
	switch {
	case !s.focused:
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

@(private = "file")
term_draw_scrollbar :: proc(t: ^Term, r: draw.Rect, dc: ^draw.Context) {
	bar: Vt_Scrollbar
	if ghostty_terminal_get(t.vt, VT_DATA_SCROLLBAR, &bar) != VT_OK || bar.total <= bar.len { return }
	h := r.max.y - r.min.y
	thumb := max(h * f32(bar.len) / f32(bar.total), 12 * px1())
	top := r.min.y + (h - thumb) * f32(bar.offset) / f32(bar.total - bar.len)
	draw.rect(dc, {{r.max.x - 4 * px1(), top}, {r.max.x - px1(), top + thumb}}, hex(HEX_FAINT))
}
