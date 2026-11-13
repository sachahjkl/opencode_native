// The program's command line: every option it reads, in one table (gui_toolkit's cli). --help says them, an option not here
// is refused before a window opens (it started the program as if nothing was said, the terminal held by it).
package ocn

import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import cli "gt:cli"
import setup "gt:setup"

OPTIONS := []cli.Option{
	{name = "url", group = "Server", value = "url", help = "another server"},
	{name = "password", value = "password", help = "its password"},
	{name = "server", value = "name", help = "a saved server at start"},
	{name = "session", group = "Start", value = "id", help = "open that session at start"},
	{name = "search", value = "text", help = "the sidebar's search, filled at start"},
	{name = "find", value = "text", help = "open the find bar with that text"},
	{name = "settings", value = "page", optional = true, help = "open the settings at start (on that page: general, connections, install...)"},
	{name = "add-server", help = "open the dialog that adds a server at start"},
	{name = "image", value = "file", help = "open the image viewer on a file"},
	{name = "pref", group = "Look", value = "name=value", separate = true, help = "set a preference for the run (e.g. appearance.theme=Nord)"},
	{name = "scale", value = "factor", help = "the interface's scale whatever the screen's (1: 100 %)"},
	{name = "size", value = "w>x<h", help = "the window's size in pixels"},
	{name = "frames", group = "Checks", value = "n", help = "n frames of a hidden window, then exit (a check that it runs)"},
	// (what the tools and the tests pass)
	{name = "font-dir", value = "folder", hidden = true},
	{name = "attach", value = "file", hidden = true},
	{name = "diff", value = "file", hidden = true},
	{name = "slow-motion", value = "factor", hidden = true},
	{name = "seek-subagent", hidden = true},
	{name = "no-fixed-surface", hidden = true},
}

// The program's options, then the install's (--install, --uninstall, --setup: the same in every program, gt:setup).
all_options :: proc() -> []cli.Option {
	return slice.concatenate([][]cli.Option{OPTIONS, setup.COMMAND_OPTIONS[:]}, context.temp_allocator)
}

// The command line, read once at start: --help, --version, or an option this program does not have is said, and the
// process ends (no window); else what it asks (cli_read).
cli_start :: proc() -> Cli_Options {
	program := cli.Program{name = "opencode-native", summary = "a native desktop client for opencode", version = APP_VERSION,
		examples = {
			{"opencode-native --session=ses_abc", "open that session"},
			{"opencode-native --url=http://host:4096 --password=…", "another server, for this run"},
			{"opencode-native --pref appearance.theme=Kernel", "a preference, for this run"},
			{"opencode-native --settings=connections", "the settings, on their page Connections"},
			{"opencode-native --install", "install this copy for you"},
			{"opencode-native --status", "is it installed? (exit code)"},
		},
		environment = {
			{"OPENCODE_NATIVE_NO_SETUP=1", "never offer Setup"},
			{"TOOLKIT_DEVTOOLS=<port>", "let the Chrome DevTools Protocol drive the window on 127.0.0.1 (development)"},
		},
		footer = "Files: ~/.config/opencode-native/ (Windows: %APPDATA%\\opencode-native\\): prefs.txt, servers.txt, themes.txt."}
	if out, code, stop := cli.check(program, all_options(), os.args[1:]); stop {
		say("%s", out)
		os.exit(code)
	}
	return cli_read(os.args[1:])
}

// What the command line asks, read once at start (cli_start) and kept in the App: each place reads its field, nothing reads
// os.args again. A value not given is its zero, unless said.
Cli_Options :: struct {
	url, password, server: string,    // another server and its password; a saved server
	session, search, find: string,    // the session opened, the sidebar's search, the find bar's text
	settings:      bool,              // the settings open at start ...
	settings_page: string,            // ... on this page (its category; "": the last one)
	command:       setup.Command,     // --install, --uninstall, --status (no window), --setup (the install's dialog at start)
	add_server:    bool,              // the dialog that adds a server
	image:         string,            // a file in the image viewer
	prefs:         []string,          // "name=value", each --pref in order
	scale:         f32,               // the interface's scale, within SCALE_MIN..SCALE_MAX (0: the screen's)
	size:          Maybe([2]f32),     // the window's size in pixels
	frames:        int,               // a check: this many frames, then exit (-1: run)
	font_dir:      string,            // faces from files (fonts_from_dir)
	attach:        []string,          // files attached at start, in order
	diff:          string,            // a patch in the full view
	slow_motion:   f64,               // the film's slowing (0: none)
	seek_subagent: bool,
	no_fixed_surface: bool,
}

// The options of `args` (the line without the program; cli.check accepted it). The strings are slices of `args`; the lists
// are in the default allocator, for the program's life.
cli_read :: proc(args: []string) -> (o: Cli_Options) {
	given := cli.parse(all_options(), args, context.temp_allocator)
	o.command, _ = setup.command_of(args)
	o.url, _ = cli.value(given, "url")
	o.password, _ = cli.value(given, "password")
	o.server, _ = cli.value(given, "server")
	o.session, _ = cli.value(given, "session")
	o.search, _ = cli.value(given, "search")
	o.find, _ = cli.value(given, "find")
	o.settings = cli.has(given, "settings")
	o.settings_page, _ = cli.value(given, "settings")
	o.add_server = cli.has(given, "add-server")
	o.image, _ = cli.value(given, "image")
	o.prefs = cli.values(given, "pref", context.allocator)
	if v, ok := cli.value(given, "scale"); ok {
		if f, f_ok := strconv.parse_f32(v); f_ok && f >= SCALE_MIN && f <= SCALE_MAX { o.scale = f }
	}
	if v, ok := cli.value(given, "size"); ok {   // "<w>x<h>"
		w_text, _, h_text := strings.partition(v, "x")
		w, w_ok := strconv.parse_f32(w_text)
		h, h_ok := strconv.parse_f32(h_text)
		if w_ok && h_ok { o.size = [2]f32{w, h} }
	}
	o.frames = -1
	if v, ok := cli.value(given, "frames"); ok { o.frames, _ = strconv.parse_int(v) }   // (not a number: 0 frames, the check fails)
	o.font_dir, _ = cli.value(given, "font-dir")
	o.attach = cli.values(given, "attach", context.allocator)
	o.diff, _ = cli.value(given, "diff")
	if v, ok := cli.value(given, "slow-motion"); ok { o.slow_motion, _ = strconv.parse_f64(v) }
	o.seek_subagent = cli.has(given, "seek-subagent")
	o.no_fixed_surface = cli.has(given, "no-fixed-surface")
	return
}
