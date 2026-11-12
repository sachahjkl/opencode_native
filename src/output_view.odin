package ocn

// A command's output as a terminal shows it, with nothing to type into: colours, what a progress bar redraws, the scrollback, a selection. A
// dialog, or a window of its own for a large or a second screen. A command that runs is followed; when it ends the view says so and offers to
// close, as watching no longer serves. One that has ended shows what it printed.
//
// It is a Term of the terminal's, connected to nothing (Term.read_only): the bytes come from GET /api/shell/:id/output, which is the server's
// for as long as it keeps the command, or from the call's own text once it does not. A pipe's lines end in a bare newline where a terminal
// expects the return with it: output_view_feed adds it.

import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:strings"
import "gt:draw"
import "gt:platform"
import "gt:ui"
import lucide "gt:lucide"

Output_View :: struct {
	term:     ^Term,           // (not in the terminal's list: no tab, no socket)
	panel:    u32,             // the id of its window, from OUTPUT_PANEL_BASE
	shell:    string,          // the server's command ("": what a call handed back, in its text) (owned)
	tool:     string,          // the call it came from, "": none (owned)
	command:  string,          // (owned)
	dir:      string,          // the folder the server has that command in (owned)
	fallback: string,          // what the call handed back, if the server no longer has the command (owned)
	raw:      [dynamic]u8,     // what came, for Copy: its end, past OUTPUT_KEEP_BYTES
	last:     u8,              // the last byte that came: a line's end may fall between two reads
	cursor:   int,             // of the output read so far
	status:   Job_Status,
	exit:     int,
	has_exit: bool,
	started, ended: f64,
	watched:  bool,            // it was seen running
	over:     bool,            // it ended, and all it printed is here
	seen_end: bool,            // ... while it was being looked at: the view says so
	draining: bool,            // it ended, what it printed last is still to be read
	lost:     bool,            // the server no longer has it, and it ended who knows how
	dropped:  bool,            // the server kept only the end of what it printed
	gone:     bool,            // closed: it goes after the frame, what was built for it is still to be drawn
}

Output_Views :: struct {
	list:   [dynamic]^Output_View,
	shown:  ^Output_View,   // in the dialog
	window: ^Output_View,   // to go to a window of its own, after the frame
	next:   u32,
}

output_view_of_panel :: proc(app: ^App, panel: u32) -> ^Output_View {
	if panel < OUTPUT_PANEL_BASE { return nil }
	for v in app.cx.outputs.list { if v.panel == panel { return v } }
	return nil
}

// The view whose grid `t` is (nil: a shell of the tabs).
output_view_of_term :: proc(app: ^App, t: ^Term) -> ^Output_View {
	for v in app.cx.outputs.list { if v.term == t { return v } }
	return nil
}

@(private = "file")
output_view_of_shell :: proc(app: ^App, id: string) -> ^Output_View {
	for v in app.cx.outputs.list { if v.shell == id && !v.gone { return v } }
	return nil
}

@(private = "file")
output_view_new :: proc(app: ^App, shell, tool, command, dir: string) -> ^Output_View {
	o := &app.cx.outputs
	v := new(Output_View)
	o.next += 1
	v.panel = OUTPUT_PANEL_BASE + o.next
	v.shell, v.tool, v.command, v.dir = strings.clone(shell), strings.clone(tool), strings.clone(command), strings.clone(dir)
	v.status = .Running
	v.term = term_new(shell != "" ? shell : tool, command, dir)
	v.term.read_only, v.term.detached, v.term.panel = true, true, v.panel   // (detached: no part in the main window's input)
	term_feed(v.term, "\x1b[?25l")   // (nothing is typed here: no cursor)
	output_view_echo(v)
	append(&o.list, v)
	return v
}

// What is on the screen comes forward, rather than a second view of the same thing.
@(private = "file")
output_view_show :: proc(app: ^App, v: ^Output_View) {
	if w := detached_window(app, v.panel); w != nil {
		platform.raise_window(w)
		return
	}
	app.cx.outputs.shown = v
	app.settle = max(app.settle, FRAMES_AFTER_INPUT)
}

// A command of the server, running or ended.
output_view_open_shell :: proc(app: ^App, id, command, dir: string, tool := "", fallback := "") -> ^Output_View {
	v := output_view_of_shell(app, id)
	if v == nil {
		v = output_view_new(app, id, tool, command, dir)
		v.fallback = strings.clone(fallback)
		output_view_ask_state(app, v)
	}
	output_view_show(app, v)
	return v
}

// What a call handed back: of the command it ran if the server says which, else its text.
output_view_open_part :: proc(app: ^App, p: ^Part) {
	command := p.command
	if command == "" { command = p.subject }
	if p.shell_id != "" {
		output_view_open_shell(app, p.shell_id, command, chat_dir(app), p.tool_id, p.output)
		return
	}
	for x in app.cx.outputs.list {
		if x.tool == p.tool_id && !x.gone { output_view_show(app, x); return }
	}
	x := output_view_new(app, "", p.tool_id, command, chat_dir(app))
	output_view_feed(x, p.output)
	x.status, x.over = .Exited, true
	x.has_exit, x.exit = p.status == .Error, 1
	x.started, x.ended = p.started_ms, p.ended_ms
	output_view_show(app, x)
}

// Whether there is anything to look at, for a button that says so.
output_view_can :: proc(p: ^Part) -> bool { return p.shell_id != "" || p.output != "" }

// The command at the head of the grid, as it was typed after a prompt: whole, in the scrollback with what it printed, not cut in
// the bar. (Not in what is copied of the output: it is the terminal's, not the command's.)
@(private = "file")
output_view_echo :: proc(v: ^Output_View) {
	if strings.trim_space(v.command) == "" { return }
	b := strings.builder_make(context.temp_allocator)
	for line, i in strings.split_lines(strings.trim_right_space(v.command), context.temp_allocator) {
		strings.write_string(&b, i == 0 ? OUTPUT_PROMPT : OUTPUT_PROMPT_MORE)
		strings.write_string(&b, OUTPUT_ECHO_ON)
		strings.write_string(&b, strings.trim_right(line, "\r"))
		strings.write_string(&b, "\x1b[0m\r\n")
	}
	term_feed(v.term, strings.to_string(b))
}

// Bytes as the terminal wants them.
output_view_feed :: proc(v: ^Output_View, s: string) {
	if s == "" { return }
	append(&v.raw, s)
	if over := len(v.raw) - OUTPUT_KEEP_BYTES; over > 0 { remove_range(&v.raw, 0, over) }
	b := strings.builder_make(0, len(s) + len(s) / 16, context.temp_allocator)
	for c in transmute([]u8)s {
		if c == '\n' && v.last != '\r' { strings.write_byte(&b, '\r') }
		strings.write_byte(&b, c)
		v.last = c
	}
	term_feed(v.term, strings.to_string(b))
}

@(private = "file")
output_view_query :: proc(v: ^Output_View) -> string { return location_query(v.dir) }

// What follows the cursor. (`wait`: a sleeping thread, no frame: a command that prints nothing costs its readings and no more.)
@(private = "file")
output_view_read :: proc(app: ^App, v: ^Output_View, wait := 0) {
	q := output_view_query(v)
	request_later(app, .Output_Read, fmt.tprintf("/api/shell/%s/output?cursor=%d&limit=%s%s%s", v.shell, v.cursor, ACT_OUTPUT_CHUNK, q != "" ? "&" : "", q), wait, v.shell)
}

@(private = "file")
output_view_ask_state :: proc(app: ^App, v: ^Output_View) {
	q := output_view_query(v)
	request(app, .Output_State, "GET", fmt.tprintf("/api/shell/%s%s%s", v.shell, q != "" ? "?" : "", q), tag = v.shell)
}

// All it printed is here, and how it ended. Seen as it happened, it is said; a command that had ended before it opened has nothing to announce.
@(private = "file")
output_view_ends :: proc(app: ^App, v: ^Output_View, seen: bool) {
	v.over, v.draining, v.seen_end = true, false, seen
	if v.cursor == 0 && len(v.raw) == 0 && v.fallback != "" { output_view_feed(v, v.fallback) }
	app.settle = max(app.settle, FRAMES_AFTER_INPUT)
}

// GET /api/shell/:id/output. Printing, it is read again at once while there is more; at rest, what is to say is whether it ended.
output_view_output_load :: proc(app: ^App, data: json.Value, id: string) {
	v := output_view_of_shell(app, id)
	if v == nil { return }
	out := jstr(data, "data", "output")
	if jbool(data, "data", "truncated") { v.dropped = true }
	if c := int(jnum(data, "data", "cursor")); c > v.cursor { v.cursor = c }
	output_view_feed(v, out)
	if out != "" { app.settle = max(app.settle, FRAMES_AFTER_INPUT) }
	switch {
	case v.cursor < int(jnum(data, "data", "size")): output_view_read(app, v)
	case v.draining:                                 output_view_ends(app, v, v.watched)
	case out != "":                                  output_view_read(app, v, OUTPUT_POLL_MS)
	case:                                            output_view_ask_state(app, v)
	}
}

// GET /api/shell/:id.
output_view_state_load :: proc(app: ^App, data: json.Value, id: string) {
	v := output_view_of_shell(app, id)
	if v == nil { return }
	job: Shell_Job
	job_fill(&job, jget(data, "data"))
	v.status, v.exit, v.has_exit, v.started, v.ended = job.status, job.exit, job.has_exit, job.started, job.ended
	if job.status == .Running {
		output_view_read(app, v, v.watched ? OUTPUT_POLL_MS : 0)
		v.watched = true
		return
	}
	v.draining = true
	output_view_read(app, v)   // (what it printed as it ended)
}

// The server no longer has it: what the call handed back is what there is. Not reached says nothing: asked again, at the pace of the rest.
output_view_failed :: proc(app: ^App, r: ^Request) {
	v := output_view_of_shell(app, r.tag)
	if v == nil { return }
	if r.ok && r.status >= 400 {
		v.lost = !v.draining
		v.status = .Exited
		output_view_ends(app, v, v.watched)
		return
	}
	output_view_read(app, v, OUTPUT_POLL_MS)
}

// It goes after the frame, or with its window.
output_view_close :: proc(app: ^App, v: ^Output_View) {
	o := &app.cx.outputs
	v.gone = true
	if o.shown == v { o.shown = nil }
	if o.window == v { o.window = nil }
	detached_closing(app, v.panel)
	app.settle = max(app.settle, FRAMES_AFTER_INPUT)
}

@(private = "file")
output_view_free :: proc(app: ^App, v: ^Output_View) {
	o := &app.cx.outputs
	s := &app.cx.terms
	if s.pressed == v.term { term_press_end(s) }
	for x, i in o.list {
		if x == v { ordered_remove(&o.list, i); break }
	}
	v.term.detached = false   // (it has no window to leave)
	term_free(v.term)
	delete(v.shell); delete(v.tool); delete(v.command); delete(v.dir); delete(v.fallback); delete(v.raw)
	free(v)
}

// Its window closed, by whatever way.
output_view_window_left :: proc(app: ^App, panel: u32) {
	if v := output_view_of_panel(app, panel); v != nil { output_view_free(app, v) }
}

// After the frame: nothing of what was built holds them any more, and a window is not made in a build.
output_views_tick :: proc(app: ^App) {
	o := &app.cx.outputs
	if v := o.window; v != nil {
		o.window = nil
		if o.shown == v { o.shown = nil }
		panel_detach(app, v.panel)
		if !panel_detached(app, v.panel) { o.shown = v }   // (no window: the renderer refused it)
	}
	#reverse for v in o.list {
		if v.gone && !panel_detached(app, v.panel) { output_view_free(app, v) }
	}
}

// The server left: what is shown of its commands goes with it.
output_views_forget :: proc(app: ^App) {
	for v in app.cx.outputs.list { output_view_close(app, v) }
}

// What the dialog's grid is given, before anything else sees it. What it does not take (Escape above all) goes on to the dialog.
output_view_events :: proc(app: ^App, events: []platform.Event) -> []platform.Event {
	v := app.cx.outputs.shown
	if v == nil || v.term.vt == nil { return events }
	s := &app.cx.terms
	keyboard := s.focused
	s.only, s.focused = v.term, v.term
	left := term_events(app, events)
	s.only, s.focused = nil, keyboard
	return left
}

// What it says of how it stands, in a word, and the colour of that.
output_view_word :: proc(v: ^Output_View) -> (word: string, color: Color) {
	switch {
	case v.lost:                 return "ended", hex(HEX_WEAK)
	case !v.over:                return "running", hex(HEX_YELLOW)
	case v.status == .Killed:    return "killed", hex(HEX_RED)
	case v.status == .Timeout:   return "timed out", hex(HEX_RED)
	case v.has_exit && v.exit != 0: return fmt.tprintf("exit %d", v.exit), hex(HEX_RED)
	case v.has_exit:             return "exit 0", hex(HEX_GREEN)
	}
	return "ended", hex(HEX_GREEN)
}

// A line along its top: the grid above is the view, this is only what goes with it.
@(private = "file")
output_bar_draw :: proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
	draw.rect(dc, {b.rect.min, {b.rect.max.x, b.rect.min.y + px1()}}, hex(HEX_LINE))
}

// How it stands, and what can be done with it, under the grid. It stays where it is whatever the size of the window; what gives way is the
// text in its middle. Ended as one watched, that text says so, and Close is what stands out.
@(private = "file")
output_view_bar :: proc(app: ^App, v: ^Output_View, em: f32, in_window: bool) {
	running := !v.over
	word, color := output_view_word(v)
	note := ui.Style_Mod{font = app.mono, font_size = math.round(em * FS_CAPTION)}
	ui.next({width = ui.fill(), height = ui.px(math.round(em * OUTPUT_BAR_H_EM)), axis = .X, cross = .Center})
	bar := ui.build_box({}, "###out_bar")
	bar.custom = output_bar_draw
	if ui.parent(bar) {
		ui.spacer(ui.px(em * 0.8))
		state_mark("###st", color, running, size = em * 0.7)
		ui.spacer(ui.px(em * 0.45))
		text("s", word, color, note)
		if dur := duration(v.started, v.ended > 0 ? v.ended : (running ? now_epoch_ms() : 0)); dur != "" {
			ui.spacer(ui.px(em * 0.6))
			text("e", dur, hex(HEX_FAINT), note)
		}
		ui.spacer(ui.px(em * 1.1))
		switch {
		case v.lost:     text("m", "The server no longer has this command.", hex(HEX_WEAK), note, ui.fill())
		case v.seen_end: text("m", "Finished: nothing more will come.", hex(HEX_TEXT_SOFT), note, ui.fill())
		case v.dropped:  text("m", "The server kept the end of it.", hex(HEX_FAINT), note, ui.fill())
		case:            ui.spacer(ui.fill())   // (the command is at the head of the grid)
		}
		ui.spacer(ui.px(em * 0.8))
		h := math.round(em * BUTTON_SMALL_H_EM)
		if bevel_button("###out_copy", "Copy", lucide.COPY, .Ghost, height = h, disabled = len(v.raw) == 0, quiet = true).clicked {
			clip_set(plain_output(string(v.raw[:])))
			ui.toast(.Good, "Output copied")
		}
		if !in_window {
			ui.spacer(ui.px(em * 0.2))
			if bevel_button("###out_win", "Window", lucide.APP_WINDOW, .Ghost, height = h, quiet = true).clicked { app.cx.outputs.window = v }
		}
		if !in_window || v.seen_end {
			ui.spacer(ui.px(em * 0.2))
			if bevel_button("###out_close", "Close", "", v.seen_end ? .Normal : .Ghost, height = h, quiet = !v.seen_end).clicked { output_view_close(app, v) }
		}
		ui.spacer(ui.px(em * 0.5))
	}
}

// The grid, all the room there is, and the bar. (In the dialog, an edge: its corners are round, the grid's are not.)
output_view_body :: proc(app: ^App, v: ^Output_View, em: f32, in_window: bool) {
	if !v.over { animate(app) }
	inset := in_window ? 0 : math.round(em * 0.55)
	ui.spacer(ui.px(inset))
	ui.next({width = ui.fill(), height = ui.fill(), axis = .X})
	if ui.row(id = "###out_body") {
		ui.spacer(ui.px(inset))
		ui.next({width = ui.fill(), height = ui.fill(), axis = .Y})
		if ui.column(id = "###out_grid") { terminal_panel(app, em, v.term) }
		ui.spacer(ui.px(inset))
	}
	output_view_bar(app, v, em, in_window)
}

output_view_dialog :: proc(app: ^App, em: f32) {
	v := app.cx.outputs.shown
	if v == nil { return }
	open := true
	if ui.modal_sized("output", DIALOG_PREFERRED_EM[.Output] * em, &app.cx.dialogs[.Output], &open, DIALOG_MIN_EM[.Output] * em) {
		dialog_backdrop()
		output_view_body(app, v, em, false)   // (its bar has the Close)
	}
	if !open { output_view_close(app, v) }
}
