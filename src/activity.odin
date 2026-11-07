// What runs behind the conversation, at a glance: the session's sub-agents, the shell commands of its folder, its todo list.
// A line over the composer says how many; Down from the composer (or a click on that line) opens the tray under it: a row
// each, with the tail of what it prints, so that one can watch them without going into them. The focus stays in the
// composer: while the tray is open the arrows, Enter, Delete and Escape are the tray's, and typing closes it.
package occ

import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:strings"
import "gt:draw"
import "gt:ui"

Job_Status :: enum u8 { Exited, Running, Killed, Timeout }

Shell_Job :: struct {
	id, command, cwd: string,           // (owned)
	status:        Job_Status,
	exit:          int,
	has_exit:      bool,
	started, ended: f64,
	cursor:        int,                 // of the output read so far
	tail:          [dynamic]u8,         // the end of the output
	reading:       bool,                // a read is on its way
	seen:          bool,                // in the last answer of the list
}

Todo :: struct { content, status: string }   // (in Activity.todo_arena's allocator: context of todos_read)

Peek :: struct { text: string, reading: bool, read_ms: f64 }   // the end of a sub-agent's work (text owned)

Activity :: struct {
	open:       bool,
	sel:        int,
	opened:     string,             // the row opened with Enter (owned)
	poll_ms:    f64,
	reveal:     bool,
	height:     f32,                // the tray's, measured at the last layout
	jobs:       [dynamic]Shell_Job,
	peeks:      map[string]Peek,    // by session (keys owned)
	todos:      [dynamic]Todo,      // (strings owned)
	todos_sig:  u64,
	dir:        string,             // the folder the commands were read for (owned)
	listing:    bool,
	mouse:      Vec2,
	mouse_moved: bool,              // since the last build: the row under it is the selected one
	by_keys:    bool,               // the selection came from the keyboard: the selected row opens
}

Act_Kind :: enum u8 { Agent, Shell, Tool }

Act_Row :: struct {
	kind:    Act_Kind,
	id:      string,    // a session, a command
	name:    string,    // the agent, the shell's mark
	title:   string,
	what:    string,    // quietly after it
	preview: string,    // what it printed last
	state:   Sub_State,
	started, ended: f64,
}

activity_reset :: proc(app: ^App) {
	a := &app.activity
	for &j in a.jobs { job_free(&j) }
	clear(&a.jobs)
	for k, p in a.peeks { delete(k); delete(p.text) }
	clear(&a.peeks)
	a.sel, a.reveal, a.listing = 0, false, false
	a.poll_ms = 0
	todos_clear(a)
	a.todos_sig = 0
}

@(private = "file")
job_free :: proc(j: ^Shell_Job) {
	delete(j.id); delete(j.command); delete(j.cwd); delete(j.tail)
}

@(private = "file")
todos_clear :: proc(a: ^Activity) {
	for t in a.todos { delete(t.content); delete(t.status) }
	clear(&a.todos)
}

// The server left: what was read of it goes, and what was on its way cannot lower its flag any more.
activity_forget :: proc(app: ^App) {
	a := &app.activity
	activity_reset(app)
	delete(a.opened); delete(a.dir)
	a.opened, a.dir = "", ""
	a.open = false
}

activity_open :: proc(app: ^App) {
	a := &app.activity
	a.open, a.sel, a.reveal, a.by_keys = true, 0, true, true
	a.poll_ms = 0   // (read now)
}

activity_close :: proc(app: ^App) { app.activity.open = false }

activity_toggle :: proc(app: ^App) { if app.activity.open { activity_close(app) } else { activity_open(app) } }

////////////////////////////////
// Reading

// The folder of the session shown: commands are the server's by folder.
chat_dir :: proc(app: ^App) -> string {
	if app.chat.have_self { return app.chat.self.directory }
	if s := find_session(app, app.chat.id); s != nil { return s.directory }
	return ""
}

location_query :: proc(dir: string) -> string {
	return dir != "" ? fmt.tprintf("location[directory]=%s", url_escape(dir)) : ""
}

// Whether what runs is to be read again at its pace. (A session whose folder is not known yet waits: read without one, the list
// would be of the server's default folder.)
@(private = "file")
activity_polls :: proc(app: ^App) -> bool {
	a := &app.activity
	if app.chat.id == "" || !online(app) || app.conn == nil { return false }
	if chat_dir(app) == "" && !app.chat.have_self { return false }
	for &j in a.jobs { if j.status == .Running { return true } }
	return a.poll_ms == 0 || a.open
}

// After each frame: what runs is read again, often while one looks at it.
activity_tick :: proc(app: ^App) {
	a := &app.activity
	if !activity_polls(app) { return }
	if d := ui.now_ms() - a.poll_ms; a.poll_ms != 0 && d < (a.open ? ACT_POLL_MS : ACT_IDLE_POLL_MS) { return }
	a.poll_ms = ui.now_ms()
	activity_read(app)
}

// When the next reading is due (deferred_tick). 0: none.
activity_in_ms :: proc(app: ^App) -> int {
	a := &app.activity
	if !activity_polls(app) { return 0 }
	return max(int(a.poll_ms + (a.open ? ACT_POLL_MS : ACT_IDLE_POLL_MS) - ui.now_ms()) + 1, 1)
}

// A command started or ended, says the stream.
activity_poke :: proc(app: ^App) { app.activity.poll_ms = 0 }

@(private = "file")
activity_read :: proc(app: ^App) {
	a := &app.activity
	dir := chat_dir(app)
	if dir != a.dir { delete(a.dir); a.dir = strings.clone(dir) }
	q := location_query(dir)
	if !a.listing {
		a.listing = true
		request(app, .Shell_List, "GET", q != "" ? fmt.tprintf("/api/shell?%s", q) : "/api/shell", tag = dir)
	}
	for &j in a.jobs { if j.status == .Running { job_read(app, &j) } }
	if !a.open { return }
	for &s in app.chat.children {
		busy := app.busy[s.id] or_else false
		p, known := a.peeks[s.id]
		if p.reading || (known && !busy) { continue }   // (one that is over does not change)
		peek_read(app, s.id)
	}
}

@(private = "file")
job_read :: proc(app: ^App, j: ^Shell_Job) {
	if j.reading { return }
	j.reading = true
	q := location_query(app.activity.dir)
	request(app, .Shell_Output, "GET", fmt.tprintf("/api/shell/%s/output?cursor=%d&limit=%s%s%s", j.id, j.cursor, ACT_OUTPUT_CHUNK, q != "" ? "&" : "", q), tag = j.id)
}

@(private = "file")
peek_read :: proc(app: ^App, id: string) {
	a := &app.activity
	p, known := a.peeks[id]
	key := id
	if !known { key = strings.clone(id) }
	p.reading = true
	a.peeks[key] = p
	request(app, .Peek, "GET", fmt.tprintf("/api/session/%s/message?limit=%s&order=desc", id, ACT_PEEK_MESSAGES), tag = id)
}

@(private = "file")
job_find :: proc(a: ^Activity, id: string) -> ^Shell_Job {
	for &j in a.jobs { if j.id == id { return &j } }
	return nil
}

job_fill :: proc(j: ^Shell_Job, it: json.Value) {
	switch jstr(it, "status") {
	case "running": j.status = .Running
	case "killed":  j.status = .Killed
	case "timeout": j.status = .Timeout
	case:           j.status = .Exited
	}
	j.started = jnum(it, "time", "started")
	j.ended = jnum(it, "time", "completed")
	if _, has := jget(it, "exit").(json.Null); !has && jget(it, "exit") != nil {
		j.exit, j.has_exit = int(jnum(it, "exit")), true
	}
}

// The answer to GET /api/shell: the commands running now. One that is no longer there has ended: read how.
activity_shells_load :: proc(app: ^App, v: json.Value, dir: string) {
	a := &app.activity
	a.listing = false
	if dir != a.dir { return }
	for &j in a.jobs { j.seen = false }
	for it in jarr(v, "data") {
		id := jstr(it, "id")
		if id == "" { continue }
		j := job_find(a, id)
		if j == nil {
			append(&a.jobs, Shell_Job{id = strings.clone(id), command = strings.clone(jstr(it, "command")), cwd = strings.clone(jstr(it, "cwd"))})
			j = &a.jobs[len(a.jobs) - 1]
			job_read(app, j)
		}
		job_fill(j, it)
		j.seen = true
	}
	q := location_query(a.dir)
	for &j in a.jobs {
		if j.seen || j.status != .Running { continue }
		request(app, .Shell_One, "GET", fmt.tprintf("/api/shell/%s%s%s", j.id, q != "" ? "?" : "", q), tag = j.id)
	}
	for len(a.jobs) > ACT_JOBS_MAX {
		at := 0
		for &j, i in a.jobs { if j.status != .Running { at = i; break } }
		job_free(&a.jobs[at])
		ordered_remove(&a.jobs, at)
	}
}

// GET /api/shell/:id, of one that left the list.
activity_shell_load :: proc(app: ^App, v: json.Value, id: string) {
	j := job_find(&app.activity, id)
	if j == nil { return }
	job_fill(j, jget(v, "data"))
	job_read(app, j)   // (what it printed last)
}

// GET /api/shell/:id/output: what follows the cursor.
activity_output_load :: proc(app: ^App, v: json.Value, id: string) {
	j := job_find(&app.activity, id)
	if j == nil { return }
	j.reading = false
	out := jstr(v, "data", "output")
	if out != "" {
		append(&j.tail, out)
		if over := len(j.tail) - ACT_TAIL_BYTES; over > 0 { remove_range(&j.tail, 0, over) }
	}
	if c := int(jnum(v, "data", "cursor")); c > j.cursor { j.cursor = c }
}

activity_request_failed :: proc(app: ^App, r: ^Request) {
	a := &app.activity
	#partial switch r.kind {
	case .Shell_List:
		a.listing = false
	case .Shell_Output:
		if j := job_find(a, r.tag); j != nil { j.reading = false }
	case .Shell_One:
		// (the server no longer knows it: it is over, however it ended. Not reached says nothing: the next list asks again)
		if j := job_find(a, r.tag); j != nil && r.status == 404 { j.status = .Exited }
	case .Peek:
		if p, ok := &a.peeks[r.tag]; ok { p.reading = false }
	}
}

// The last things a sub-agent did: its tool calls in a line each, the end of what it wrote.
activity_peek_load :: proc(app: ^App, v: json.Value, id: string) {
	a := &app.activity
	p, ok := &a.peeks[id]
	if !ok { return }
	p.reading = false
	p.read_ms = ui.now_ms()
	lines := make([dynamic]string, context.temp_allocator)
	items := jarr(v, "data")
	#reverse for it in items {   // (newest first in the answer)
		if jstr(it, "type") != "assistant" { continue }
		for c in jarr(it, "content") {
			switch jstr(c, "type") {
			case "text":
				rest := jstr(c, "text")
				for line in strings.split_lines_iterator(&rest) {
					if t := strings.trim_space(line); t != "" { append(&lines, t) }
				}
			case "tool":
				tmp: Part
				tool_set_input(&tmp, jget(c, "state", "input"), context.temp_allocator)
				append(&lines, fmt.tprintf("› %s%s%s", jstr(c, "name"), tmp.subject != "" ? "  " : "", tmp.subject))
			}
		}
	}
	first := max(0, len(lines) - ACT_PEEK_LINES)
	delete(p.text)
	p.text = strings.join(lines[first:], "\n")
}

// The todo list: the last call of the tool that writes it, in the pages read. Read again when the last messages change.
todos_update :: proc(app: ^App) {
	a := &app.activity
	c := &app.chat
	sig := c.gen * 1_000_003 + u64(len(c.messages)) * 1009
	if n := len(c.messages); n > 0 {
		for &p in c.messages[n - 1].parts { sig = sig * 31 + u64(p.status) + 1 + u64(len(p.input)) }
	}
	if sig == a.todos_sig { return }
	a.todos_sig = sig
	#reverse for &m in c.messages {
		#reverse for &p in m.parts {
			if p.kind != .Tool || !strings.contains(p.tool_name, "todo") || p.input == "" { continue }
			v, err := json.parse_string(p.input, allocator = context.temp_allocator)
			if err != nil { continue }
			list := jarr(v, "todos")
			if list == nil { continue }
			todos_clear(a)
			for t in list { append(&a.todos, Todo{strings.clone(jstr(t, "content")), strings.clone(jstr(t, "status"))}) }
			return
		}
	}
	todos_clear(a)
}

@(private = "file")
todos_done :: proc(a: ^Activity) -> (done: int, doing: string) {
	for t in a.todos {
		if t.status == "completed" || t.status == "cancelled" { done += 1 }
		if t.status == "in_progress" && doing == "" { doing = t.content }
	}
	return
}

////////////////////////////////
// The rows

// `s` without what a terminal would act on: colour sequences, carriage returns.
plain_output :: proc(s: string) -> string {
	b := strings.builder_make(0, len(s), context.temp_allocator)
	i := 0
	for i < len(s) {
		c := s[i]
		if c == 0x1b && i + 1 < len(s) && s[i + 1] == '[' {
			i += 2
			for i < len(s) && !(s[i] >= 0x40 && s[i] <= 0x7e) { i += 1 }
			i += 1
			continue
		}
		if c != '\r' { strings.write_byte(&b, c) }
		i += 1
	}
	return strings.to_string(b)
}

// The last `n` lines of `s` that say something.
tail_lines :: proc(s: string, n: int) -> []string {
	all := strings.split_lines(plain_output(s), context.temp_allocator)
	out := make([dynamic]string, context.temp_allocator)
	#reverse for l in all {
		t := strings.trim_right_space(l)
		if strings.trim_space(t) == "" { continue }
		inject_at(&out, 0, t)
		if len(out) == n { break }
	}
	return out[:]
}

@(private = "file")
job_state :: proc(j: ^Shell_Job) -> Sub_State {
	switch j.status {
	case .Running:         return .Running
	case .Killed, .Timeout: return .Cancelled
	case .Exited:
	}
	return j.has_exit && j.exit != 0 ? .Failed : .Done
}

@(private = "file")
job_word :: proc(j: ^Shell_Job) -> string {
	switch j.status {
	case .Running: return "running"
	case .Killed:  return "killed"
	case .Timeout: return "timeout"
	case .Exited:
	}
	return "exited"
}

// A running call of a shell tool whose command is not in the list of the server's commands.
@(private = "file")
tool_rows :: proc(app: ^App, rows: ^[dynamic]Act_Row) {
	c := &app.chat
	first := max(0, len(c.messages) - ACT_PEEK_LINES)
	for &m in c.messages[first:] {
		for &p in m.parts {
			if p.kind != .Tool || p.status != .Running || !(strings.contains(p.tool_name, "shell") || strings.contains(p.tool_name, "bash")) { continue }
			v, _ := json.parse_string(p.input, allocator = context.temp_allocator)
			command := jstr(v, "command")
			listed := false
			for &j in app.activity.jobs { if j.command == command { listed = true } }
			if listed { continue }
			append(rows, Act_Row{kind = .Tool, id = p.tool_id, name = "$", title = command != "" ? first_line(command) : p.subject, what = "in the conversation", state = .Running, started = p.started_ms})
		}
	}
}

@(private = "file")
activity_rows :: proc(app: ^App) -> []Act_Row {
	a := &app.activity
	rows := make([dynamic]Act_Row, context.temp_allocator)
	agent :: proc(app: ^App, rows: ^[dynamic]Act_Row, s: ^Session_Info) {
		v := sub_view(app, s.id)
		preview := v.result
		if p, ok := app.activity.peeks[s.id]; ok && p.text != "" { preview = p.text }
		what := v.has_live ? v.live.activity : ""
		name := v.agent != "" ? v.agent : "sub-agent"
		append(rows, Act_Row{kind = .Agent, id = s.id, name = name, title = v.desc != "" ? v.desc : s.title, what = what, preview = preview, state = v.state, started = v.started, ended = v.ended})
	}
	for &s in app.chat.children { if app.busy[s.id] or_else false { agent(app, &rows, &s) } }
	#reverse for &j in a.jobs {
		if j.status == .Running { append(&rows, Act_Row{kind = .Shell, id = j.id, name = "$", title = first_line(j.command), what = base_name(j.cwd), preview = string(j.tail[:]), state = .Running, started = j.started}) }
	}
	tool_rows(app, &rows)
	#reverse for &j in a.jobs {
		if j.status == .Running { continue }
		what := j.has_exit ? fmt.tprintf("exit %d", j.exit) : job_word(&j)
		append(&rows, Act_Row{kind = .Shell, id = j.id, name = "$", title = first_line(j.command), what = what, preview = string(j.tail[:]), state = job_state(&j), started = j.started, ended = j.ended})
	}
	shown := 0
	for &s in app.chat.children {
		if app.busy[s.id] or_else false { continue }
		if shown == ACT_FINISHED_SHOWN { break }
		agent(app, &rows, &s)
		shown += 1
	}
	return rows[:]
}

// How much runs: what the line over the composer says, and whether it has anything to say.
@(private = "file")
activity_counts :: proc(app: ^App) -> (agents, shells: int) {
	agents = len(active_children(app))
	for &j in app.activity.jobs { if j.status == .Running { shells += 1 } }
	return
}

////////////////////////////////
// The keyboard

@(private = "file")
row_act :: proc(app: ^App, r: Act_Row) {
	a := &app.activity
	switch r.kind {
	case .Agent:
		drill_down(app, r.id)
		activity_close(app)
	case .Shell:
		same := a.opened == r.id
		delete(a.opened)
		a.opened = same ? "" : strings.clone(r.id)
		a.reveal = true
	case .Tool:
	}
}

@(private = "file")
row_stop :: proc(app: ^App, r: Act_Row) {
	if r.state != .Running && r.state != .Starting { return }
	switch r.kind {
	case .Agent: interrupt_session(app, r.id)
	case .Shell:
		q := location_query(app.activity.dir)
		request(app, .Action, "DELETE", fmt.tprintf("/api/shell/%s%s%s", r.id, q != "" ? "?" : "", q), tag = r.id)
		activity_poke(app)
	case .Tool: interrupt_session(app, app.chat.id)
	}
}

// Its output as a terminal shows it. (A call whose command the list does not have: the call's own view of it.)
@(private = "file")
row_inspect :: proc(app: ^App, r: Act_Row) {
	switch r.kind {
	case .Agent:
	case .Shell:
		if j := job_find(&app.activity, r.id); j != nil { output_view_open_shell(app, j.id, j.command, app.activity.dir) }
	case .Tool:
		for &m in app.chat.messages {
			for &p in m.parts { if p.kind == .Tool && p.tool_id == r.id { output_view_open_part(app, &p); return } }
		}
	}
}

// Before the composer's own keys, while the tray is open. Up past the first row is the way back to the composer.
activity_keys :: proc(app: ^App) {
	a := &app.activity
	rows := activity_rows(app)
	n := len(rows)
	if ui.key_press(.Escape) { activity_close(app); return }
	if ui.key_press(.Up) {
		if a.sel <= 0 { activity_close(app); return }
		a.sel -= 1
		a.reveal, a.by_keys = true, true
	}
	if ui.key_press(.Down) && a.sel < n - 1 { a.sel += 1; a.reveal, a.by_keys = true, true }
	a.sel = clamp(a.sel, 0, max(n - 1, 0))
	if n == 0 { return }
	// (a prompt written in the composer goes first: Enter sends it, Delete edits it)
	if strings.trim_space(ui.area_string(&app.composer)) != "" { return }
	if ui.key_press(.Return) { row_act(app, rows[a.sel]) }
	if ui.key_press(.Delete) { row_stop(app, rows[a.sel]) }
}

////////////////////////////////
// The line over the composer

// `n` of `word`, in the plural when it takes one.
@(private = "file")
count_of :: proc(n: int, word: string) -> string { return fmt.tprintf("%d %s%s", n, word, n == 1 ? "" : "s") }

activity_strip :: proc(app: ^App, em: f32) {
	a := &app.activity
	todos_update(app)
	agents, shells := activity_counts(app)
	done, doing := todos_done(a)
	open_todos := len(a.todos) > 0 && done < len(a.todos)
	if agents + shells == 0 && !open_todos && !a.open { return }
	running := agents + shells > 0
	if running { app.animating = true }
	ui.next({width = ui.fill(), height = ui.px(math.round(em * BUTTON_COMPACT_H_EM)), axis = .X, cross = .Center})
	ui.a11y({role = .Button, name = "Activity"})
	b := ui.build_box({.Clickable, .Focusable}, "###act_strip")
	b.custom = proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
		if b.hot_t > FADE_VISIBLE { draw.rect(dc, b.rect, {1, 1, 1, 0.03 * b.hot_t}, BUTTON_RADIUS * ui.scale()) }
	}
	sig := ui.signal(b)
	if sig.clicked { activity_toggle(app) }
	if ui.parent(b) {
		note := ui.Style_Mod{font = app.mono, font_size = math.round(em * FS_SMALL)}
		ui.spacer(ui.px(em * 0.5))
		if running {
			lamp("###l", hex(HEX_YELLOW), 1, pulse = true, size = em * CARD_MARK_EM)
			ui.spacer(ui.px(em * 0.35))
		}
		if agents > 0 {
			text("a", count_of(agents, "agent"), hex(HEX_TEXT_SOFT), note)
			ui.spacer(ui.px(em * 0.8))
		}
		if shells > 0 {
			glyph(ICO_TERMINAL, hex(HEX_WEAK), math.round(em * ICON_SMALL))
			ui.spacer(ui.px(em * 0.25))
			text("s", count_of(shells, "command"), hex(HEX_TEXT_SOFT), note)
			ui.spacer(ui.px(em * 0.8))
		}
		if open_todos {
			glyph(ICO_LIST, hex(HEX_WEAK), math.round(em * ICON_SMALL))
			ui.spacer(ui.px(em * 0.25))
			text("t", fmt.tprintf("%d/%d", done, len(a.todos)), hex(HEX_TEXT_SOFT), note)
			ui.spacer(ui.px(em * 0.45))
			if doing != "" { text("d", doing, hex(HEX_WEAK), ui.Style_Mod{font_size = math.round(em * FS_NOTE)}, ui.fill()) }
		}
		if !open_todos || doing == "" { ui.spacer(ui.fill()) } else { ui.spacer(ui.px(em * 0.8)) }
		text("k", a.open ? "Esc  close" : "↓  details", hex(HEX_FAINT), ui.Style_Mod{font = app.mono, font_size = math.round(em * FS_CAPTION)})
		ui.spacer(ui.px(em * 0.5))
	}
	ui.spacer(ui.px(em * 0.25))
}

////////////////////////////////
// The tray

@(private = "file")
Row_Draw :: struct { selected: bool }

@(private = "file")
row_draw :: proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
	s := ui.scale()
	r := draw.rect_pad(b.rect, -1 * s)
	r.min.x += 6 * s
	r.max.x -= 6 * s
	if (^Row_Draw)(user).selected {
		draw.rect(dc, r, hex(HEX_ACT_ROW_SELECTED), 6 * s)
		draw.rect(dc, {{r.min.x + 2 * s, r.min.y + 5 * s}, {r.min.x + 4 * s, r.max.y - 5 * s}}, accent(), 1 * s)
	} else if b.hot_t > FADE_VISIBLE {
		draw.rect(dc, r, {1, 1, 1, 0.025 * b.hot_t}, 6 * s)
	}
}

@(private = "file")
activity_row :: proc(app: ^App, r: Act_Row, i: int, em: f32, now: f64) {
	a := &app.activity
	selected := a.open && i == a.sel
	opened := r.kind == .Shell && a.opened == r.id
	running := r.state == .Running || r.state == .Starting
	if running { app.animating = true }
	ui.next({width = ui.fill(), height = ui.children_sum(), axis = .Y})
	ui.a11y({role = .Button, name = fmt.tprintf("%s, %s: %s", sub_state_label(r.state), r.name, r.title)})
	b := ui.build_box({.Clickable, .Hot_Within}, fmt.tprintf("###row_%s", r.id))
	d := ui.frame_new(Row_Draw)
	d.selected = selected
	b.custom = row_draw
	b.custom_user = d
	sig := ui.signal(b)
	if sig.hovering && a.mouse_moved { a.sel = i; a.by_keys = false }
	if sig.clicked { a.sel = i; row_act(app, r) }
	if ui.parent(b) {
		ui.spacer(ui.px(em * 0.3))
		ui.next({width = ui.fill(), height = ui.px(math.round(em * 1.5)), axis = .X, cross = .Center})
		if ui.row(.Center, id = "###l1") {
			ui.spacer(ui.px(em * TRAY_PAD_EM))
			state_mark("###st", sub_state_color(r.state), running, size = em * 0.8)
			ui.spacer(ui.px(em * 0.4))
			text("n", r.name, running ? hex(HEX_WEAK) : hex(HEX_FAINT), ui.Style_Mod{font = app.mono_bold, font_size = math.round(em * FS_SMALL)})
			ui.spacer(ui.px(em * 0.5))
			text("t", r.title, running ? hex(HEX_TEXT) : hex(HEX_WEAK), ui.Style_Mod{font = r.kind == .Agent ? app.font : app.mono, font_size = math.round(em * (r.kind == .Agent ? FS_LABEL : FS_SMALL))}, ui.fill())
			ui.spacer(ui.px(em * 0.5))
			if r.what != "" {
				text("w", ellipsize(r.what, CHIP_ACTIVITY_CHARS), hex(HEX_FAINT), ui.Style_Mod{font = app.mono, font_size = math.round(em * FS_CAPTION)})
				ui.spacer(ui.px(em * 0.5))
			}
			end := r.ended > 0 ? r.ended : (running ? now : 0)
			if dur := duration(r.started, end); dur != "" {
				text("d", dur, hex(HEX_FAINT), ui.Style_Mod{font = app.mono, font_size = math.round(em * FS_CAPTION)})
				ui.spacer(ui.px(em * 0.4))
			}
			if selected || sig.hovering {
				if running {
					if bevel_button("###stop", "Stop", "", .Ghost, height = math.round(em * BUTTON_SMALL_H_EM * 0.82), quiet = true).clicked { row_stop(app, r) }
					ui.spacer(ui.px(em * 0.2))
				}
				if r.kind == .Agent && bevel_button("###open", "Open", "", .Ghost, height = math.round(em * BUTTON_SMALL_H_EM * 0.82), quiet = true).clicked { row_act(app, r) }
				if r.kind != .Agent && bevel_button("###inspect", "Inspect", "", .Ghost, height = math.round(em * BUTTON_SMALL_H_EM * 0.82), quiet = true).clicked { row_inspect(app, r) }
				if r.kind == .Shell && r.preview != "" && bevel_button("###copy", "Copy", "", .Ghost, height = math.round(em * BUTTON_SMALL_H_EM * 0.82), quiet = true).clicked {
					clip_set(plain_output(r.preview))
					ui.toast(.Good, "Output copied")
				}
				ui.spacer(ui.px(em * 0.3))
			}
		}
		// The pointer only lights a row: under a pointer that passes, rows that open would move what it is going to. The keys
		// open it, and its height glides.
		n := opened ? ACT_LINES_OPEN : selected && a.by_keys ? ACT_LINES_SELECTED : ACT_LINES_REST
		lines := tail_lines(r.preview, n)
		line_h := math.round(em * 1.2)
		lines_h := f32(len(lines)) * line_h
		h := ui.anim(ui.key_from_string(b.key, "lines"), lines_h, ACT_ANIM_RATE, initial = lines_h)
		app.cx.gliding = app.cx.gliding || abs(h - lines_h) > 0.5
		ui.next({width = ui.fill(), height = ui.px(math.round(h)), axis = .Y})
		if ui.column(flags = {.Clip}, id = "###out") {
			for l, k in lines {
				ui.next({width = ui.fill(), height = ui.px(line_h), axis = .X, cross = .Center})
				if ui.row(.Center, id = fmt.tprintf("###o%d", k)) {
					ui.spacer(ui.px(em * (TRAY_PAD_EM + 1.2)))
					text("x", ellipsize(l, ACT_LINE_CHARS), hex(k == len(lines) - 1 && running ? HEX_TEXT_SOFT : HEX_TOOL_OUTPUT), ui.Style_Mod{font = app.mono, font_size = math.round(em * FS_CAPTION)}, ui.fill())
					ui.spacer(ui.px(em * 0.5))
				}
			}
		}
		ui.spacer(ui.px(em * 0.3))
	}
}

// One item of a todo list, whole: its text wraps, a list is there to be read.
todo_row :: proc(app: ^App, t: Todo, k: int, em: f32) {
	ui.next({width = ui.fill(), height = ui.children_sum(), axis = .X})
	if ui.row(id = fmt.tprintf("###td%d", k)) {
		ui.spacer(ui.px(em * TRAY_PAD_EM))
		ui.next({width = ui.px(em * 1.2), height = ui.px(math.round(em * TODO_MARK_H_EM)), axis = .X, cross = .Center})
		if ui.row(.Center, id = "###m") {
			switch t.status {
			case "completed": glyph(ICO_CHECK, hex(HEX_GREEN), math.round(em * ICON_SMALL), em * 1.1)
			case "cancelled": glyph(ICO_CANCEL, hex(HEX_FAINT), math.round(em * ICON_SMALL), em * 1.1)
			case "in_progress":
				state_mark("###s", hex(HEX_YELLOW), true, size = em * 0.8)
				app.animating = true
			case: glyph(ICO_RIGHT, hex(HEX_FAINT), math.round(em * ICON_TINY), em * 1.1)
			}
		}
		ui.spacer(ui.px(em * 0.25))
		col := t.status == "in_progress" ? hex(HEX_TEXT) : t.status == "pending" ? hex(HEX_TEXT_SOFT) : hex(HEX_FAINT)
		runs := [1]ui.Rich_Run{{text = t.content, style = {color = col}}}
		ui.next({width = ui.fill(), font_size = math.round(em * FS_NOTE), flags = {.Selectable}})
		ui.rich_paragraph("###c", runs[:])
		ui.spacer(ui.px(em * 0.6))
	}
	ui.spacer(ui.px(em * 0.15))
}

@(private = "file")
activity_todos :: proc(app: ^App, em: f32) {
	a := &app.activity
	done, _ := todos_done(a)
	ui.next({width = ui.fill(), height = ui.px(math.round(em * 1.5)), axis = .X, cross = .Center})
	if ui.row(.Center, id = "###td_head") {
		ui.spacer(ui.px(em * TRAY_PAD_EM))
		text("h", fmt.tprintf("TODO  %d/%d", done, len(a.todos)), hex(HEX_FAINT), ui.Style_Mod{font = app.mono_bold, font_size = math.round(em * FS_CAPTION)})
	}
	ui.spacer(ui.px(em * 0.2))
	for t, k in a.todos { if t.status == "in_progress" || t.status == "pending" { todo_row(app, t, k, em) } }   // (what remains first)
	for t, k in a.todos { if t.status != "in_progress" && t.status != "pending" { todo_row(app, t, k, em) } }
}

// What runs, a row each.
@(private = "file")
activity_list :: proc(app: ^App, sb: ^ui.Box, em: f32) {
	a := &app.activity
	rows := activity_rows(app)
	running := 0
	for r in rows { if r.state == .Running || r.state == .Starting { running += 1 } }
	ui.next({width = ui.fill(), height = ui.px(math.round(em * 1.5)), axis = .X, cross = .Center})
	if ui.row(.Center, id = "###act_head") {
		ui.spacer(ui.px(em * TRAY_PAD_EM))
		text("h", fmt.tprintf("ACTIVITY  %d running", running), hex(HEX_FAINT), ui.Style_Mod{font = app.mono_bold, font_size = math.round(em * FS_CAPTION)})
		ui.spacer(ui.fill())
		if app.column_w > em * ACT_KEYS_MIN_EM { text("k", "↑↓ move   Enter open   Del stop   ", hex(HEX_FAINT), ui.Style_Mod{font = app.mono, font_size = math.round(em * FS_CAPTION)}) }
		if hint_action("###act_close", "Esc close", em, app.mono) { activity_close(app) }
		ui.spacer(ui.px(em * TRAY_PAD_EM))
	}
	ui.spacer(ui.px(em * 0.2))
	if len(rows) == 0 {
		ui.next({width = ui.fill(), height = ui.px(em * 2), axis = .X, cross = .Center})
		if ui.row(.Center, id = "###act_none") {
			ui.spacer(ui.px(em * TRAY_PAD_EM))
			text("n", "Nothing runs in the background of this session.", hex(HEX_FAINT), ui.Style_Mod{font_size = math.round(em * FS_NOTE)})
		}
	}
	now := now_epoch_ms()
	for r, i in rows { activity_row(app, r, i, em, now) }
	// the selected row in view (by the last layout: its rectangle is a frame old, a step is a row)
	if a.reveal && len(rows) > 0 {
		a.reveal = false
		if rb := ui.prev_box(fmt.tprintf("###row_%s", rows[clamp(a.sel, 0, len(rows) - 1)].id)); rb != nil {
			top := rb.rect.min.y - sb.rect.min.y
			bottom := rb.rect.max.y - sb.rect.min.y
			if top < 0 { sb.view_target.y += top }
			if bottom > sb.size.y { sb.view_target.y += bottom - sb.size.y }
		}
	}
}

// A flat surface with a fine edge, inside its own box: while it opens a clip cuts its bottom, and a well's shadows and lip,
// which go past the box, were cut with it and left the corners ragged.
tray_draw :: proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
	r := TRAY_RADIUS * ui.scale()
	draw.rect(dc, b.rect, hex(HEX_ACT_WELL), r)
	draw.rect(dc, b.rect, hex(HEX_LINE), r, px1())
}

// Under the composer: it opens downward, as the key says. Its height glides to what it holds, up to a part of the window.
activity_tray :: proc(app: ^App, em: f32) {
	a := &app.activity
	// One value moves, the height shown. What is inside keeps its full size whatever that is: the clip uncovers it, nothing in
	// it is laid out differently from one frame to the next. (Its height is the last one measured: known before it opens.)
	if a.height <= 0 { a.height = em * ACT_FIRST_H_EM }
	full := min(a.height, f32(app.win.size.y) * ACT_MAX_H_FRACTION)
	target := a.open ? full : 0
	h := ui.anim(ui.key_from_string(0, "act_tray"), target, ACT_ANIM_RATE, initial = 0)
	app.cx.gliding = app.cx.gliding || abs(h - target) > 0.5
	if h < 0.5 && !a.open { return }
	mouse := ui.mouse_pos()
	a.mouse_moved = abs(mouse.x - a.mouse.x) + abs(mouse.y - a.mouse.y) > 0.5
	a.mouse = mouse
	ui.spacer(ui.px(em * 0.45 * min(h / max(full, 1), 1)))
	ui.next({width = ui.fill(), height = ui.px(math.round(h)), axis = .Y})
	if ui.column(flags = {.Clip}, id = "###act_clip") {
		ui.next({width = ui.fill(), height = ui.px(full), axis = .Y})
		tray := ui.build_box({}, "###act_well")
		tray.custom = tray_draw
		if ui.parent(tray) {
			ui.next({width = ui.fill(), height = ui.fill()})
			if ui.scroll_y("###act_scroll") {
				sb := ui.parent_box()
				ui.next({width = ui.fill(), height = ui.children_sum(), axis = .Y})
				if ui.column(id = "###act_body") {
					body := ui.parent_box()
					if body.size.y > 0 { a.height = body.size.y + 2 * px1() }
					ui.spacer(ui.px(em * 0.4))
					has_todos := len(a.todos) > 0
					if has_todos && app.column_w > em * ACT_COLUMNS_MIN_EM {
						// side by side: what runs, and the list beside it, whole
						ui.next({width = ui.fill(), height = ui.children_sum(), axis = .X})
						if ui.row(id = "###act_cols") {
							ui.next({width = ui.pct(1 - ACT_TODO_SHARE), height = ui.children_sum(), axis = .Y})
							if ui.column(id = "###act_left") { activity_list(app, sb, em) }
							ui.next({width = ui.pct(ACT_TODO_SHARE), height = ui.children_sum(), axis = .Y})
							if ui.column(id = "###act_right") { activity_todos(app, em) }
						}
					} else {
						if has_todos { activity_todos(app, em) }
						activity_list(app, sb, em)
					}
					ui.spacer(ui.px(em * 0.4))
				}
			}
		}
	}
}
