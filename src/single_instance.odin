// One window per person (src/md/features/single-instance.md): a second start hands what it asks to the window that runs
// (gt:instance) and ends; --status pings that window and --quit asks it to end as Quit does (setup.Setup_Options.running
// and quit).
package ocn

import "base:runtime"
import "core:os"
import "core:path/filepath"
import "core:strings"
import instance "gt:instance"
import "gt:platform"
import prefs_page "gt:prefs_page"
import "gt:ui"

// How long a second start waits for the first while it is starting or closing.
@(private = "file") INSTANCE_WAIT_MS :: 2000
// The separator of the message's words: a value of the command line can hold a new line, never a NUL.
@(private = "file") MESSAGE_SEPARATOR :: "\x00"
// Marks the first word as the launcher's activation token: no option starts with it.
@(private = "file") MESSAGE_TOKEN :: "\x01"

// The person's name: their folder of state; a debug build has its own channel. (Letters, digits and dots only.)
@(private = "file")
instance_options :: proc() -> instance.Instance_Options {
	return {name = instance.key(ODIN_DEBUG ? "opencodenative.dev" : "opencodenative", config_dir()), wait_ms = INSTANCE_WAIT_MS}
}

// Whether an opencode native runs and answers (--status: setup.Setup_Options.running).
instance_running :: proc() -> bool {
	return instance.send(instance_options(), transmute([]u8)string(instance.MESSAGE_PING)) == .Forwarded
}

// Asks the window that runs to end as its Quit does (--quit: setup.Setup_Options.quit); true when it took the request.
instance_quit :: proc() -> bool {
	return instance.send(instance_options(), transmute([]u8)string(instance.MESSAGE_QUIT)) == .Forwarded
}

// A start that changes the run itself (another server, a look, a check, the tools): it neither hands over nor takes the
// name, so a tool's window never takes the person's starts.
instance_own_run :: proc(o: Cli_Options) -> bool {
	return o.url != "" || o.password != "" || o.server != "" || len(o.prefs) > 0 || o.scale != 0 || o.size != nil ||
		o.frames >= 0 || o.font_dir != "" || o.slow_motion != 0 || o.seek_subagent || o.no_fixed_surface ||
		os.get_env("TOOLKIT_DEVTOOLS", context.temp_allocator) != ""
}

// At the start, before the log and the window: hands `o` to a window that runs. `forwarded`: it took it, this start
// ends. Else `owner` is this start's to serve once the window is up (`owns`), or nothing (an own run, another that
// does not answer).
instance_acquire :: proc(o: Cli_Options) -> (forwarded: bool, owner: instance.Owner, owns: bool) {
	if instance_own_run(o) { return false, {}, false }
	message := instance_message_make(o, platform.activation_token_from_env(context.temp_allocator))
	outcome, got := instance.acquire(instance_options(), transmute([]u8)message)
	switch outcome {
	case .Forwarded:      return true, {}, false
	case .First:          return false, got, true
	case .Other_Instance: // (identity "": not given)
	case .Unresponsive:   say("opencode-native: the window that runs does not answer: this start opens its own\n")
	}
	return false, {}, false
}

// The words of what `o` asks to show (the options a second start hands over), its token first. Paths are absolute:
// the owner runs in another folder.
instance_message_make :: proc(o: Cli_Options, token: string) -> string {
	// (joined, not filepath.abs: on Linux that opens the file, and a path not there would stay relative to another folder)
	abs :: proc(p: string) -> string {
		if filepath.is_abs(p) { return p }
		cwd, err := os.get_working_directory(context.temp_allocator)
		if err != nil { return p }
		joined, _ := filepath.join({cwd, p}, context.temp_allocator)
		return joined
	}
	words := make([dynamic]string, context.temp_allocator)
	append(&words, strings.concatenate({MESSAGE_TOKEN, token}, context.temp_allocator))
	word :: proc(words: ^[dynamic]string, name, value: string) {
		if value != "" { append(words, strings.concatenate({"--", name, "=", value}, context.temp_allocator)) }
	}
	word(&words, "session", o.session)
	word(&words, "search", o.search)
	word(&words, "find", o.find)
	if o.settings { append(&words, o.settings_page != "" ? strings.concatenate({"--settings=", o.settings_page}, context.temp_allocator) : "--settings") }
	if o.add_server { append(&words, "--add-server") }
	if o.command == .Setup { append(&words, "--setup") }
	if o.image != "" { word(&words, "image", abs(o.image)) }
	for f in o.attach { word(&words, "attach", abs(f)) }
	if o.diff != "" { word(&words, "diff", abs(o.diff)) }
	return strings.join(words[:], MESSAGE_SEPARATOR, context.temp_allocator)
}

// The token and the options of a message (instance_message_make); the strings point into `text` (the lists: temp).
instance_message_read :: proc(text: string) -> (token: string, o: Cli_Options) {
	words := strings.split(text, MESSAGE_SEPARATOR, context.temp_allocator)
	args := make([dynamic]string, context.temp_allocator)
	for w in words {
		if strings.has_prefix(w, MESSAGE_TOKEN) { token = w[len(MESSAGE_TOKEN):]; continue }
		if w != "" { append(&args, w) }
	}
	// (cli_read keeps its lists for the program's life: this one's are the message's)
	context.allocator = context.temp_allocator
	return token, cli_read(args[:])
}

// Serves the name once the posts' queue exists (app_init): the loop sleeps until the window has an event, so a thread of
// its own takes the messages.
instance_serve :: proc(app: ^App, owner: instance.Owner) -> ^instance.Server {
	return instance.serve_start(owner, instance_message, app)
}

// (the instance's thread) A message: what acts is handed to the interface's thread. (Not private: the tests deliver
// messages to it.)
instance_message :: proc(user: rawptr, message: []byte) {
	app := (^App)(user)
	switch string(message) {
	case instance.MESSAGE_PING: return   // (the answer alone tells --status that a copy runs)
	case instance.MESSAGE_QUIT:
		// (the Quit command, on the interface's thread: the loop's end writes the drafts, the preferences, the stores)
		ui.post(&app.state, proc(data: rawptr, _: u64) {
			if c := command_find("app.quit"); c != nil { command_run((^App)(data), c) }
		}, app)
		return
	}
	text := strings.clone(string(message), runtime.heap_allocator())   // (the call's own: valid only during it)
	if !ui.post(&app.state, instance_show, rawptr(raw_data(text)), u64(len(text))) { delete(text, runtime.heap_allocator()) }
}

// (the interface's thread) A second start's options: what a start shows, the session as a new root; the window to the
// front.
@(private = "file")
instance_show :: proc(data: rawptr, word: u64) {
	text := string(([^]u8)(data)[:word])
	defer delete(text, runtime.heap_allocator())
	app := the_app
	if app == nil { return }
	token, o := instance_message_read(text)
	if o.session != "" { open_root(app, o.session) }
	cli_show(app, o)
	platform.raise_window_token(app.win, token)
	app.settle = max(app.settle, FRAMES_AFTER_INPUT)
}

// What the command line asks to see (a start's, or a second start's handed over), the session left out: a start opens
// it once the sessions are read.
cli_show :: proc(app: ^App, o: Cli_Options) {
	if o.search != "" { ui.line_edit_set(&app.sidebar.search, o.search) }
	if o.command == .Setup { prefs_page.install_open(&app.install) }
	if o.add_server { server_edit_open(app, -1) }
	if o.find != "" { find_open(app, main_pane(app)); ui.line_edit_set(&main_pane(app).find.field, o.find) }
	if o.image != "" { image_view_start(app, o.image) }
	for file in o.attach { attach_path(app, main_pane(app), file) }   // (what a paste gives, without the clipboard)
	if o.diff != "" { diff_full_open_file(app, o.diff) }   // (a patch in the full view)
	if o.settings {   // --settings[=page number]
		if o.settings_page != "" { settings_open_on(app, o.settings_page) } else { settings_open(app) }
	}
}
