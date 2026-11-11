// The program's command line: every option it reads, in one table (gui_toolkit's cli). --help says them, an option not here
// is refused before a window opens (it started the program as if nothing was said, the terminal held by it).
package ocn

import "core:os"
import cli "gt:cli"

OPTIONS := []cli.Option{
	{name = "url", group = "Server", value = "url", help = "another server"},
	{name = "password", value = "password", help = "its password"},
	{name = "server", value = "name", help = "a saved server at start"},
	{name = "session", group = "Start", value = "id", help = "open that session at start"},
	{name = "search", value = "text", help = "the sidebar's search, filled at start"},
	{name = "find", value = "text", help = "open the find bar with that text"},
	{name = "settings", value = "n", optional = true, help = "open the settings at start (on page n)"},
	{name = "setup", help = "open Setup at start"},
	{name = "add-server", help = "open the dialog that adds a server at start"},
	{name = "image", value = "file", help = "open the image viewer on a file"},
	{name = "pref", group = "Look", value = "name=value", separate = true, help = "set a preference for the run (e.g. appearance.theme=Nord)"},
	{name = "scale", value = "factor", help = "the interface's scale whatever the screen's (1: 100 %)"},
	{name = "size", value = "w>x<h", help = "the window's size in pixels"},
	{name = "install", group = "Install", help = "install this copy for the user, or repair the install"},
	{name = "desktop", help = "with --install: a shortcut on the Desktop too"},
	{name = "uninstall", help = "remove it (it asks first)"},
	{name = "quiet", help = "with --uninstall: do not ask"},
	{name = "status", help = "print the install's state (exit code 0 installed, 2 needs repair, 1 not installed)"},
	{name = "frames", group = "Checks", value = "n", help = "n frames of a hidden window, then exit (a check that it runs)"},
	// (what the tools and the tests pass)
	{name = "font-dir", value = "folder", hidden = true},
	{name = "attach", value = "file", hidden = true},
	{name = "diff", value = "file", hidden = true},
	{name = "slow-motion", value = "factor", hidden = true},
	{name = "seek-subagent", hidden = true},
	{name = "no-fixed-surface", hidden = true},
}

// --help, --version, or an option this program does not have: said, and the process ends (no window).
cli_check :: proc() {
	program := cli.Program{name = "opencode-native", summary = "a native desktop client for opencode", version = APP_VERSION,
		examples = {
			{"opencode-native --session=ses_abc", "open that session"},
			{"opencode-native --url=http://host:4096 --password=…", "another server, for this run"},
			{"opencode-native --pref appearance.theme=Kernel", "a preference, for this run"},
			{"opencode-native --settings=1", "the settings, on their second page"},
			{"opencode-native --status", "is it installed? (exit code)"},
		},
		environment = {
			{"OPENCODE_NATIVE_NO_SETUP=1", "never offer Setup"},
			{"TOOLKIT_DEVTOOLS=<port>", "let the Chrome DevTools Protocol drive the window on 127.0.0.1 (development)"},
		},
		footer = "Files: ~/.config/opencode-native/ (Windows: %APPDATA%\\opencode-native\\): prefs.txt, servers.txt, themes.txt."}
	if out, code, stop := cli.check(program, OPTIONS, os.args[1:]); stop {
		say("%s", out)
		os.exit(code)
	}
}
