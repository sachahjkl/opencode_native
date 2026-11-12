// Settings: the client's own preferences (the toolkit's typed registry, gt:config: named, bounded, documented, saved to
// %APPDATA%\opencode-native\prefs.txt, applied at once) and what the opencode server lets one see and change (its shell,
// its MCP servers, its saved permissions, its usage, its providers, agents, skills, commands, its configuration files).
package ocn

import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:mem"
import "core:mem/virtual"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import "gt:config"
import desktop "gt:desktop"
import "gt:draw"
import "gt:font"
import "gt:platform"
import "gt:ui"
import lucide "gt:lucide"

////////////////////////////////
// The preferences

HEX_ROSE :: 0xf28ba8ff

// The bounds of the preferences (PREF_DEFS) that their sliders share.
FONT_SIZE_MIN         :: 11
FONT_SIZE_MAX         :: 20
ZOOM_MIN              :: 0.6
ZOOM_MAX              :: 2.5
COLUMN_W_MIN          :: 560
COLUMN_W_MAX          :: 1800
TOOL_LINES_MIN        :: 5
TOOL_LINES_MAX        :: 1000
PAGE_SIZE_MIN         :: 20
PAGE_SIZE_MAX         :: 200

COMPACT_DENSITY     :: 0.8
ZOOM_EPSILON        :: 0.001
SLIDER_EPSILON      :: 1e-4
TOAST_TITLE_CHARS   :: 60
SETTINGS_ROW_H_EM   :: 2.2
USAGE_WARN_PERCENT  :: 80
BUDGET_WARN_SHARE   :: 0.8

HEX_SETTING_NAME   :: 0xeeeeeeff
HEX_SWATCH_WELL    :: 0x0a0a0aff
HEX_FACT_VALUE     :: 0xd0d0d0ff
HEX_FACT_NAME      :: 0xd8d8d8ff
HEX_MCP_TOP        :: 0x171717ff
HEX_MCP_BOTTOM     :: 0x121212ff
HEX_MCP_NAME       :: 0xf0f0f0ff
HEX_WORKSPACE_NAME :: 0xe0e0e0ff
HEX_CATALOG_NAME   :: 0xe8e8e8ff

TEXT_SMOOTHINGS :: []string{"auto", "rgb", "bgr", "grey"}

PREF_DEFS := [?]config.Def{
	{name = "appearance.theme", description = "The colours of the whole interface: opencode's black with an accent of its own, or an editor's palette. Themes of your own go in themes.txt beside the preferences.", kind = .String, default = {s = "OpenCode"}},
	{name = "appearance.mode", description = "Each theme in its dark or its light version: as the system's apps are, or always one.", kind = .String, default = {s = "system"}, choices = {"system", "dark", "light"}},
	{name = "appearance.style", description = "Machined: raised buttons, sunken wells, carved lines, glowing lamps. Edged: the same reliefs drawn crisp, a lit line along the top of each, square corners. Flat: plain surfaces and thin lines. A theme made for one style (Kernel: edged) brings it.", kind = .String, default = {s = "machined"}, choices = {"machined", "edged", "flat"}},
	{name = "appearance.system_title", description = "The system's title bar above the window, with its own buttons, instead of the one drawn here. The bar with the menu, the way back and the session's name stays under it. Shown where the system can draw it (Windows, X11, KDE; not GNOME).", kind = .Bool, default = {b = false}},
	{name = "appearance.font", description = "The face of the interface's text: the client's own (automatic), the system's usual one, or any installed family.", kind = .String, default = {s = ""}},
	{name = "appearance.prose_font", description = "The face of the answers: the client's own (automatic), the interface's, or any installed family.", kind = .String, default = {s = ""}},
	{name = "appearance.mono_font", description = "The face of code, paths and figures: the client's own (automatic), the system's usual one, or any installed family.", kind = .String, default = {s = ""}},
	{name = "appearance.terminal_font", description = "The face of the shells: the client's own (automatic: Fira Mono, no ligatures), the system's usual monospace, or any installed family.", kind = .String, default = {s = ""}},
	{name = "appearance.font_size", description = "Size of the interface's text, in points at 100 % zoom.", kind = .Int, default = {i = 14}, bounded = true, min = FONT_SIZE_MIN, max = FONT_SIZE_MAX},
	{name = "appearance.text_smoothing", description = "Text smoothed per colour stripe of the screen's pixels: sharper at few pixels per letter, with faint colours on its edges. Automatic: as the system says (ClearType on Windows, fontconfig on Linux).", kind = .String, default = {s = "auto"}, choices = TEXT_SMOOTHINGS},
	{name = "appearance.zoom", description = "Zoom of the interface: bars, sidebar, menus (Ctrl + Shift + = / - / 0, Ctrl + wheel outside the conversation).", kind = .Float, default = {f = 1}, bounded = true, min = ZOOM_MIN, max = ZOOM_MAX},
	{name = "appearance.content_zoom", description = "Zoom of the conversation alone, whatever the interface's (Ctrl + = / - / 0, Ctrl + wheel over it).", kind = .Float, default = {f = 1}, bounded = true, min = CONTENT_ZOOM_MIN, max = CONTENT_ZOOM_MAX},
	{name = "appearance.density", description = "Compact rows fit more on screen at the same text size.", kind = .String, default = {s = "comfortable"}, choices = {"comfortable", "compact"}},
	{name = "appearance.rounding", description = "Corner rounding of buttons, fields and menus (0: square).", kind = .Float, default = {f = 1}, bounded = true, min = 0, max = 2},
	{name = "appearance.animations", description = "Interface animations: the system's setting, always, or never.", kind = .String, default = {s = "system"}, choices = {"system", "on", "off"}},
	{name = "appearance.smooth_scroll", description = "Scrolling glides to where the wheel or the keys send it, even when the system turns animations off.", kind = .Bool, default = {b = true}},
	{name = "appearance.autohide_scrollbars", description = "Scroll bars show only while the pointer is over what they scroll.", kind = .Bool, default = {b = true}},
	{name = "appearance.glow", description = "Halos around lit buttons, lamps and running sub-agents.", kind = .Bool, default = {b = true}},
	{name = "conversation.width", description = "Widest the conversation column gets, in logical pixels.", kind = .Int, default = {i = 880}, bounded = true, min = COLUMN_W_MIN, max = COLUMN_W_MAX},
	{name = "conversation.reasoning", description = "How the model's reasoning shows: folded under a line, unfolded, or not at all.", kind = .String, default = {s = "collapsed"}, choices = {"collapsed", "expanded", "hidden"}},
	{name = "conversation.expand_tools", description = "Tool calls open with their input and output shown.", kind = .Bool, default = {b = false}},
	{name = "conversation.diff_layout", description = "How a diff's full view shows it: old and new stacked, or side by side.", kind = .String, default = {s = "stacked"}, choices = {"stacked", "split"}, hidden = true},
	{name = "conversation.tool_lines", description = "Lines of a tool's output shown before the rest is counted.", kind = .Int, default = {i = 60}, bounded = true, min = TOOL_LINES_MIN, max = TOOL_LINES_MAX},
	{name = "conversation.page_size", description = "Messages read at a time (scrolling up reads the next page by itself).", kind = .Int, default = {i = 80}, bounded = true, min = PAGE_SIZE_MIN, max = PAGE_SIZE_MAX},
	{name = "conversation.follow", description = "Follow new messages to the bottom while you are there.", kind = .Bool, default = {b = true}},
	{name = "conversation.usage", description = "Tokens and cost under each answer.", kind = .Bool, default = {b = true}},
	{name = "conversation.while_running", description = "What Enter does while a turn runs: steer the message into the turn (at its next step), or queue it for the end of the turn. Ctrl+Enter does the other. A message waiting in the list can be sent now: that stops what the agent is doing.", kind = .String, default = {s = "steer"}, choices = {"queue", "steer"}},
	{name = "conversation.image_viewer_size", description = "The size of the image viewer, as a share of the most the window gives a picture. A picture opens no larger than its pixels; drag the viewer's edges or corners to make it larger or smaller.", kind = .Float, default = {f = 1}, bounded = true, min = VIEWER_SCALE_MIN, max = 1},
	{name = "conversation.clock", description = "Times of messages in 24-hour or 12-hour form.", kind = .String, default = {s = "24h"}, choices = {"24h", "12h"}},
	{name = "composer.send", description = "The key that sends: Enter (Shift+Enter breaks the line) or Ctrl+Enter (Enter breaks the line).", kind = .String, default = {s = "enter"}, choices = {"enter", "ctrl+enter"}},
	{name = "sidebar.subagents", description = "Sub-agent sessions: under their parent, in the list with the others, or not shown.", kind = .String, default = {s = "nested"}, choices = {"nested", "flat", "hidden"}},
	{name = "sidebar.mode", description = "What the sidebar shows: what needs you first across projects (what waits for you, what finished and you have not seen, what runs, the rest), or sessions by project.", kind = .String, default = {s = "inbox"}, choices = {"inbox", "projects"}},
	{name = "notify.finished", description = "When a session that is not in front of you ends its run: nothing, a toast, a toast and the taskbar button flashing, or a notification of the system (a click on it opens the session).", kind = .String, default = {s = "system"}, choices = {"off", "toast", "flash", "system"}},
	{name = "permission.new_sessions", description = "The approvals a session made here starts with, set on the server (the composer's shield changes them for one session): the server's configured rules, file edits allowed, everything allowed (a policy's deny stays), or every action asked.", kind = .String, default = {s = "configured"}, choices = {"configured", "allow_edits", "allow_all", "ask_all"}},
	{name = "notify.permission", description = "When a session asks for a permission or a question and the window is not in front: the taskbar button flashes, and with notifications of the system, one says it.", kind = .Bool, default = {b = true}},
	{name = "appearance.throbber", description = "What says that a run goes on: a board that spells what the agent does, dots in orbit, the scanner, or nothing.", kind = .String, default = {s = "board"}, choices = {"board", "orbit", "scanner", "none"}},
	{name = "session.agent", description = "The agent a new session starts with: the one chosen last.", kind = .String, default = {s = ""}, hidden = true},
	{name = "session.model", description = "The model a new session starts with: the one chosen last.", kind = .String, default = {s = ""}, hidden = true},
	{name = "session.provider", description = "The provider of that model.", kind = .String, default = {s = ""}, hidden = true},
	{name = "session.variant", description = "How hard that model thinks (one of its variants; empty: its default).", kind = .String, default = {s = ""}, hidden = true},
	{name = "browser.tools", description = "Let the agents drive the Preview panel (open pages, read them, click, run scripts): the browser tools, while this window is open.", kind = .Bool, default = {b = true}},
	{name = "layout.dock", description = "Where the panels are, as the dock writes it.", kind = .String, default = {s = ""}, hidden = true},
	{name = "layout.dialogs", description = "The sizes the dialogs were given (settings, statistics, shortcuts), in logical pixels.", kind = .String, default = {s = ""}, hidden = true},
	{name = "update.channel", description = "Which releases this copy follows: the stable ones, or the betas too.", kind = .String, default = {s = "stable"}, choices = {"stable", "beta"}},
	{name = "update.auto", description = "Look for a new version at start (it is only installed when you say so).", kind = .Bool, default = {b = true}},
	{name = "window.placement", description = "Where the window was (platform.placement_text): it opens there again.", kind = .String, default = {s = ""}, hidden = true},
	{name = "update.base_url", description = "Where releases are read from (empty: GitHub). Whatever the place, only what the built-in key signed is installed.", kind = .String, default = {s = ""}, hidden = true},
	{name = "general.start", description = "What the window opens on: the home page, or the session it showed when it closed (the latest one if it showed none yet).", kind = .String, default = {s = "last"}, choices = {"home", "last"}},
	{name = "advanced.experimental", description = "Turn on the experimental options of a server on this computer, in its configuration file. What you set there yourself stays.", kind = .Bool, default = {b = true}},
	{name = "advanced.fps", description = "The frame rate and what a frame costs, in the status bar.", kind = .Bool, default = {b = false}},
	{name = "advanced.frame_rate", description = "The most frames a second, when there is something to draw (nothing moving, nothing is drawn): what the screen takes, a number, or no limit. Above the screen's rate it shows the newest of them: not smoother, but quicker to answer, for more power. What you type and click is read at once whatever this says.", kind = .String, default = {s = "screen"}, choices = {"screen", "30", "60", "120", "240", "uncapped"}},
}

// The preferences as plain values (read on every frame: no lookups by name there).
Prefs :: struct {
	accent_hex:   u32,
	finish:       ui.Finish,   // appearance.style
	mode:         string,  // appearance.mode: system, dark, light (the preference's own text: not owned)
	font_size:    f32,
	zoom:         f32,
	density:      f32,
	rounding:     f32,
	animations:   string,
	glow:         bool,
	smooth_scroll: bool,
	autohide_scrollbars: bool,
	column_w:     f32,
	reasoning:    string,
	expand_tools: bool,
	tool_lines:   int,
	page_size:    int,
	follow:       bool,
	usage:        bool,
	clock24:      bool,
	ctrl_enter:   bool,
	steer_first:  bool,   // while a turn runs, Enter sends into it (conversation.while_running)
	subagents:    string,
	sidebar_mode: Sidebar_Mode,
	diff_layout:  Diff_Layout,
	notify:       string,
	notify_perm:  bool,
	content_zoom: f32,
	viewer_scale: f32,   // conversation.image_viewer_size (images.odin: viewer_frame)
	start:        string,
	show_fps:     bool,
	target_hz:    f64,    // advanced.frame_rate: the most frames a second, above the screen too (0: the screen's)
	uncapped:     bool,
	throbber:     string,
	browser_tools: bool,
	experimental: bool,
	update_channel: string,
	update_auto:  bool,
	system_title: bool,    // appearance.system_title (title_apply)
	new_sessions: Approval,   // permission.new_sessions: the preset a session made here starts with
}

CONTENT_ZOOM_MIN :: 0.5
CONTENT_ZOOM_MAX :: 3

prefs_path :: proc() -> string { return pjoin({filepath.dir(settings_path()), "prefs.txt"}) }

// `file` "": the defaults, nothing read or saved (a test).
prefs_init :: proc(app: ^App, file: string) {
	app.cfg_prefs = config.prefs_make()
	config.register(&app.cfg_prefs, PREF_DEFS[:])
	app.prefs_file = strings.clone(file)
	if file != "" { config.load_file(&app.cfg_prefs, file, .User) }
	for spec in app.cli.prefs {   // --pref name=value (a value out of range or unknown: the preference keeps its own)
		if eq := strings.index_byte(spec, '='); eq > 0 { config.set_from_string(&app.cfg_prefs, spec[:eq], spec[eq + 1:], .Command_Line) }
	}
	prefs_refresh(app)
}

// The plain values from the registry, and what follows from them (theme, zoom, density, rounding).
prefs_refresh :: proc(app: ^App) {
	p := &app.cfg_prefs
	s := &app.prefs
	s.finish = ui.finish_of(config.string_of(p, "appearance.style"))
	s.mode = config.string_of(p, "appearance.mode")
	theme_load(app)
	theme_set(app, theme_index(app, config.string_of(p, "appearance.theme")), theme_wants_light(s.mode))
	theme_windows(app)
	s.accent_hex = themed(HEX_PEACH)
	s.font_size = f32(config.int_of(p, "appearance.font_size"))
	s.zoom = f32(config.float_of(p, "appearance.zoom"))
	s.density = config.string_of(p, "appearance.density") == "compact" ? COMPACT_DENSITY : 1
	s.rounding = f32(config.float_of(p, "appearance.rounding"))
	s.animations = config.string_of(p, "appearance.animations")
	s.glow = config.bool_of(p, "appearance.glow") && config.string_of(p, "appearance.style") != "flat"   // (no halos in the flat style)
	s.smooth_scroll = config.bool_of(p, "appearance.smooth_scroll")
	s.autohide_scrollbars = config.bool_of(p, "appearance.autohide_scrollbars")
	s.column_w = f32(config.int_of(p, "conversation.width"))
	s.reasoning = config.string_of(p, "conversation.reasoning")
	s.expand_tools = config.bool_of(p, "conversation.expand_tools")
	s.tool_lines = int(config.int_of(p, "conversation.tool_lines"))
	s.page_size = int(config.int_of(p, "conversation.page_size"))
	s.follow = config.bool_of(p, "conversation.follow")
	s.usage = config.bool_of(p, "conversation.usage")
	s.clock24 = config.string_of(p, "conversation.clock") == "24h"
	s.ctrl_enter = config.string_of(p, "composer.send") == "ctrl+enter"
	s.steer_first = config.string_of(p, "conversation.while_running") == "steer"
	s.subagents = config.string_of(p, "sidebar.subagents")
	s.sidebar_mode = sidebar_mode_of(config.string_of(p, "sidebar.mode"))
	s.diff_layout = diff_layout_of(config.string_of(p, "conversation.diff_layout"))
	s.notify = config.string_of(p, "notify.finished")
	s.notify_perm = config.bool_of(p, "notify.permission")
	s.content_zoom = f32(config.float_of(p, "appearance.content_zoom"))
	s.viewer_scale = f32(config.float_of(p, "conversation.image_viewer_size"))
	s.start = config.string_of(p, "general.start")
	s.show_fps = config.bool_of(p, "advanced.fps")
	rate := config.string_of(p, "advanced.frame_rate")
	s.uncapped = rate == "uncapped"
	s.target_hz = strconv.parse_f64(rate) or_else 0
	s.throbber = config.string_of(p, "appearance.throbber")
	s.browser_tools = config.bool_of(p, "browser.tools")
	s.experimental = config.bool_of(p, "advanced.experimental")
	s.update_channel = config.string_of(p, "update.channel")
	s.update_auto = config.bool_of(p, "update.auto")
	s.system_title = config.bool_of(p, "appearance.system_title")
	s.new_sessions = approval_of_pref(config.string_of(p, "permission.new_sessions"))
	update_channel_follow(app)
	title_apply(app)

	// the faces, when either preference changed (a family is opened once: the font state keeps it)
	if wanted := fmt.tprintf("%s\n%s\n%s\n%s", config.string_of(p, "appearance.font"), config.string_of(p, "appearance.mono_font"), config.string_of(p, "appearance.prose_font"), config.string_of(p, "appearance.terminal_font")); wanted != app.fonts_wanted {
		fonts_apply(app)
	}

	ui.set_zoom(&app.state, s.zoom)
	ui.set_density(&app.state, s.density)
	ui.set_rounding(&app.state, s.rounding)
	theme_refresh(&app.theme)
	terms_recolour(app)
}

// The window's title bar: the program's, or the system's when asked and the system can draw it (not on GNOME: there the
// program's always). Its buttons follow (ui.window_buttons draws none under the system's).
title_apply :: proc(app: ^App) {
	if app.win == nil { return }
	platform.set_integrated_title(app.win, !(app.prefs.system_title && platform.system_title_available(app.win)))
}

prefs_save :: proc(app: ^App) {
	if app.prefs_file == "" { return }
	if !config.save_user(&app.cfg_prefs, app.prefs_file) { ui.toast(.Bad, "The preferences could not be saved") }
}

// Sets a preference from its text, saves the user's changes, applies them.
pref_set :: proc(app: ^App, name, value: string) {
	if err := config.set_from_string(&app.cfg_prefs, name, value, .User); err != nil {
		ui.toast(.Bad, "%s: %s", name, config.set_error_text(err))
		return
	}
	prefs_save(app)
	prefs_refresh(app)
}

// The accent colour (buttons, selection, lamps of attention): the theme's, as every colour of hex (prefs_refresh sets the theme).
accent :: proc() -> Color { return hex(HEX_PEACH) }

// Ctrl + wheel changed the zoom: keep it.
prefs_track_zoom :: proc(app: ^App) {
	z := ui.zoom(&app.state)
	if abs(z - app.prefs.zoom) > ZOOM_EPSILON {
		app.prefs.zoom = z
		config.set_from_string(&app.cfg_prefs, "appearance.zoom", fmt.tprintf("%.3f", z), .User)
		prefs_save(app)
	}
}

animations_on :: proc(app: ^App) -> bool {
	switch app.prefs.animations {
	case "on":  return true
	case "off": return false
	}
	// (the system's setting, read now and then: it is asked at every build)
	@(static) read_ms: f64
	@(static) enabled: bool
	if now := ui.now_ms(); read_ms == 0 || now - read_ms > OS_SETTINGS_READ_MS {
		read_ms = max(now, 1)
		enabled = platform.os_animations_enabled()
	}
	return enabled
}

////////////////////////////////
// Notifications

window_in_front :: proc(app: ^App) -> bool { return app.win.active }

// A run ended in the session `sid`: told when it is not the one in front of the user.
notify_finished :: proc(app: ^App, sid, outcome: string) {
	mode := app.prefs.notify
	if mode == "off" { return }
	front := window_in_front(app)
	if sid == app.chat.id && front { return }
	if find_child(&app.chat, sid) != nil && front { return }   // (its card and the strip say it)
	word := outcome == "failed" ? "Failed" : outcome == "interrupted" ? "Stopped" : "Done"
	// (in front, the toast says it: a notification of the system is for a window you are not looking at)
	if mode == "system" && !front && notify_system(app, sid, word, "") { return }
	kind: ui.Toast_Kind = outcome == "failed" ? .Bad : outcome == "interrupted" ? .Warn : .Good
	toast_session(app, kind, sid, word, "")
	if mode != "toast" && !front { flash_taskbar(app) }
}

// A session waits for you (a permission, a question) while the window is not in front: `what` and `detail` (what it asks).
notify_waiting :: proc(app: ^App, sid, what, detail: string) {
	if !app.prefs.notify_perm || window_in_front(app) { return }
	flash_taskbar(app)
	if app.prefs.notify != "system" { return }
	notify_system(app, sid, what, detail)
}

// A session's title, as a notification names it ("" a session not listed: the start of its id).
session_title_of :: proc(app: ^App, sid: string) -> string {
	if s := find_session(app, sid); s != nil && s.title != "" { return s.title }
	if sid == app.chat.id && app.chat.have_self && app.chat.self.title != "" { return app.chat.self.title }
	return sid
}

// What a permission asks, in a line: the server's message, else its action and what it is on.
permission_words :: proc(req: json.Value) -> string {
	if m := strings.trim_space(jstr(req, "message")); m != "" { return first_line(m) }
	what := jstr(req, "action")
	if res := jarr(req, "resources"); len(res) > 0 { if r, ok := res[0].(json.String); ok { what = fmt.tprintf("%s %s", what, string(r)) } }
	return what
}

// What a form asks, in a line: its title, else its first field's.
form_words :: proc(form: json.Value) -> string {
	if t := strings.trim_space(jstr(form, "title")); t != "" { return first_line(t) }
	if f := jarr(form, "fields"); len(f) > 0 { return first_line(jstr(f[0], "title")) }
	return ""
}

// A toast about the session `sid`: its title on the first line, `what` and `detail` under it; a click on it opens the session.
TOAST_TARGETS :: 16   // (more than the toasts that can stand at once: a toast's session is still there when it is clicked)

// The sessions that the system's notifications and the toasts shown are about: a click on one opens its session.
Notices :: struct {
	notified:      map[platform.Notification_Id]string,   // the notifications of the system shown, their sessions (owned: notify_event)
	toast_targets: [TOAST_TARGETS]string,   // the sessions a click on a toast opens, a ring (owned: toast_session)
	toast_next:    int,
}

toast_session :: proc(app: ^App, kind: ui.Toast_Kind, sid, what, detail: string) {
	body := detail != "" ? fmt.tprintf("%s: %s", what, detail) : what
	title := session_title_of(app, sid)
	if sid == "" { ui.toast_titled(kind, title, body); return }
	k := app.notices.toast_next
	app.notices.toast_next = (k + 1) % TOAST_TARGETS
	delete(app.notices.toast_targets[k])
	app.notices.toast_targets[k] = strings.clone(sid)
	ui.toast_titled(kind, title, body, proc(user: rawptr) {
		app := the_app
		sid := app.notices.toast_targets[int(uintptr(user))]
		if sid != "" && sid != app.chat.id { open_root(app, sid) }
	}, rawptr(uintptr(k)))
}

// A notification of the system: the session's title, what happened and what it is about. A click on it brings the window and
// opens the session (main_input). False: the system shows none.
@(private = "file")
notify_system :: proc(app: ^App, sid, what, detail: string) -> bool {
	if app.win == nil || !platform.notify_supported() { return false }
	body := detail != "" ? fmt.tprintf("%s: %s", what, detail) : what
	id, ok := platform.notify(app.win, {title = session_title_of(app, sid), body = body})
	if !ok { return false }
	app.notices.notified[id] = strings.clone(sid)
	return true
}

// What a notification of the system came back with: a click opens its session, in front.
notify_event :: proc(app: ^App, e: platform.Event) {
	#partial switch e.kind {
	case .Notification_Click, .Notification_Action:
		sid, ok := app.notices.notified[e.notification.id]
		if !ok { return }
		platform.raise_window(app.win)
		if sid != "" && sid != app.chat.id { open_root(app, sid) }
	case .Notification_Closed:
		if e.notification.id in app.notices.notified {
			_, sid := delete_key(&app.notices.notified, e.notification.id)
			delete(sid)
		}
	}
}

////////////////////////////////
// What the server says (read when the settings open)

Mcp_Status :: enum u8 { Other, Connected, Failed }   // (Other: the server's word says the rest: disabled, needs_auth...)
Mcp_Server :: struct {
	name, error: string,
	status: Mcp_Status,
	word:   string,   // as the server says it
}
Mcp_Going :: struct { name: string, connecting: bool }   // (name owned)
Shell_Info :: struct { name, path: string, ok: bool }
Saved_Perm :: struct { id, action, resource, effect, project: string }
Config_File :: struct { path: string, keys: []string }
Limit :: struct { name: string, percent: f64, limited: bool, resets: f64 }
Budget :: struct { scope: string, limit, spent: f64, resets: f64 }
Named :: struct { name, detail: string }

// What the pages read, each on its own: one that fails says so alone, and an answer replaces only what it is about. (Its Remote and its
// arena are here, and they stay: a ticket that went back to 0 would match an old answer.)
Fact :: enum u8 { Cfg, Shells, Mcp, Saved, Usage, Providers, Skills, Commands }

FACT_READS := [Fact]struct { kind: Req_Kind, path: string }{
	.Cfg       = {.Cfg, "/api/config"},
	.Shells    = {.Shells, "/api/config/shell"},
	.Mcp       = {.Mcp, "/api/mcp"},
	.Saved     = {.Saved, "/api/permission/saved"},
	.Usage     = {.Usage, "/api/experimental/usage/limits"},
	.Providers = {.Providers, "/api/provider"},
	.Skills    = {.Skills, "/api/skill"},
	.Commands  = {.Commands, "/api/command"},
}

Server_Facts :: struct {
	reads:     [Fact]Remote,
	arenas:    [Fact]virtual.Arena,
	shells:    [dynamic]Shell_Info,
	shell:     string,              // the one set in the configuration ("" : the server's choice)
	mcp:       [dynamic]Mcp_Server,
	going:     [dynamic]Mcp_Going,  // connecting or disconnecting, from the click to the server's answer, whatever is read meanwhile
	saved:     [dynamic]Saved_Perm,
	revoking:  [dynamic]string,     // the ids being revoked, until the server answers, whatever is read meanwhile (owned)
	files:     [dynamic]Config_File,
	limits:    [dynamic]Limit,
	budgets:   [dynamic]Budget,
	usage_url: string,
	workspace: string,
	providers: [dynamic]Named,
	skills:    [dynamic]Named,
	commands:  [dynamic]Named,
}

// What a page holds is emptied and its arena started over.
@(private = "file")
fact_clear :: proc(f: ^Server_Facts, k: Fact) -> (a: mem.Allocator) {
	virtual.arena_destroy(&f.arenas[k])
	f.arenas[k] = {}
	_ = virtual.arena_init_growing(&f.arenas[k])
	a = virtual.arena_allocator(&f.arenas[k])
	switch k {
	case .Cfg:       f.files = make([dynamic]Config_File, a); f.shell = ""
	case .Shells:    f.shells = make([dynamic]Shell_Info, a)
	case .Mcp:       f.mcp = make([dynamic]Mcp_Server, a)
	case .Saved:     f.saved = make([dynamic]Saved_Perm, a)
	case .Usage:     f.limits = make([dynamic]Limit, a); f.budgets = make([dynamic]Budget, a); f.usage_url = ""; f.workspace = ""
	case .Providers: f.providers = make([dynamic]Named, a)
	case .Skills:    f.skills = make([dynamic]Named, a)
	case .Commands:  f.commands = make([dynamic]Named, a)
	}
	return
}

server_facts_forget :: proc(app: ^App) {
	f := &app.facts
	for k in Fact {
		_ = fact_clear(f, k)
		remote_reset(&f.reads[k])
	}
	for g in f.going { delete(g.name) }
	clear(&f.going)
	for r in f.revoking { delete(r) }
	clear(&f.revoking)
}

// Every page, again. What each shows stays until its answer: a read after an action does not blank what is looked at.
server_facts_load :: proc(app: ^App) {
	f := &app.facts
	for k in Fact {
		remote_begin(&f.reads[k])
		request(app, FACT_READS[k].kind, "GET", FACT_READS[k].path, remote = &f.reads[k])
	}
}

// An answer of one of those requests (net.odin on_answer).
server_facts_answer :: proc(app: ^App, kind: Req_Kind, v: json.Value) {
	f := &app.facts
	fact := Fact.Cfg
	for k in Fact { if FACT_READS[k].kind == kind { fact = k } }
	a := fact_clear(f, fact)
	data := jget(v, "data")
	list := jarr(v, "data")
	if data == nil { if arr, ok := v.(json.Array); ok { list = arr } }
	#partial switch kind {
	case .Cfg:
		arr, _ := v.(json.Array)
		if arr == nil { arr = list }
		for doc in arr {
			if sh := jstr(doc, "info", "shell"); sh != "" { f.shell = strings.clone(sh, a) }
			path := jstr(doc, "path")
			if path == "" { continue }
			keys := make([dynamic]string, a)
			if obj, ok := jget(doc, "info").(json.Object); ok { for k in obj { append(&keys, strings.clone(k, a)) } }
			append(&f.files, Config_File{path = strings.clone(path, a), keys = keys[:]})
		}
	case .Shells:
		for it in list { append(&f.shells, Shell_Info{strings.clone(jstr(it, "name"), a), strings.clone(jstr(it, "path"), a), jbool(it, "acceptable")}) }
	case .Mcp:
		for it in list {
			st := jstr(it, "status", "status")
			if st == "" { st = jstr(it, "status") }
			status := st == "connected" ? Mcp_Status.Connected : st == "failed" ? Mcp_Status.Failed : Mcp_Status.Other
			append(&f.mcp, Mcp_Server{name = strings.clone(jstr(it, "name"), a), status = status, word = strings.clone(st, a), error = strings.clone(jstr(it, "status", "error"), a)})
		}
	case .Saved:
		for it in list {
			append(&f.saved, Saved_Perm{
				id = strings.clone(jstr(it, "id"), a), action = strings.clone(jstr(it, "action"), a), resource = strings.clone(jstr(it, "resource"), a),
				effect = strings.clone(jstr(it, "effect"), a), project = strings.clone(jstr(it, "projectID"), a),
			})
		}
	case .Usage:
		f.workspace = strings.clone(jstr(data, "workspace", "name"), a)
		f.usage_url = strings.clone(jstr(data, "workspace", "usageURL"), a)
		if goo, ok := jget(data, "go").(json.Object); ok {
			for name in ([]string{"rolling", "weekly", "monthly"}) {
				w := goo[name] or_else nil
				if w == nil { continue }
				append(&f.limits, Limit{name, jnum(w, "percent"), jbool(w, "limited"), jnum(w, "resetsAt")})
			}
		}
		for b in jarr(data, "budgets") {
			append(&f.budgets, Budget{strings.clone(jstr(b, "scope"), a), jnum(b, "limit"), jnum(b, "spent"), jnum(b, "resetsAt")})
		}
	case .Providers:
		for it in list { append(&f.providers, Named{strings.clone(jstr(it, "name"), a), strings.clone(jstr(it, "id"), a)}) }
	case .Skills:
		for it in list { append(&f.skills, Named{strings.clone(jstr(it, "name"), a), strings.clone(first_line(jstr(it, "description")), a)}) }
	case .Commands:
		for it in list { append(&f.commands, Named{strings.clone(jstr(it, "name"), a), strings.clone(first_line(jstr(it, "description")), a)}) }
	}
}

// Where a server stands on its way to connecting or disconnecting (nil: it is not).
mcp_going :: proc(f: ^Server_Facts, name: string) -> ^Mcp_Going {
	for &g in f.going { if g.name == name { return &g } }
	return nil
}

// One at a time: what it becomes is read once the server has answered, not while it works on it.
mcp_switch :: proc(app: ^App, name: string, connect: bool) {
	f := &app.facts
	if mcp_going(f, name) != nil { return }
	append(&f.going, Mcp_Going{strings.clone(name), connect})
	request(app, .Mcp_Done, "POST", fmt.tprintf("/api/experimental/mcp/%s/%s", url_escape(name), connect ? "connect" : "disconnect"), tag = name)
}

// However it ended: what the server says now is what shows.
mcp_done :: proc(app: ^App, name: string) {
	f := &app.facts
	for g, i in f.going {
		if g.name != name { continue }
		delete(g.name)
		ordered_remove(&f.going, i)
		break
	}
	facts_soon(app)
}

// Shown as set at once; `was` comes back if the server says no, and what it says then is read.
shell_set :: proc(app: ^App, s: Shell_Info) {
	f := &app.facts
	request(app, .Shell_Set, "PATCH", "/api/experimental/config", fmt.tprintf(`{{"shell":%s}}`, jquote(s.path)), tag = f.shell)
	f.shell = strings.clone(s.path, virtual.arena_allocator(&f.arenas[.Cfg]))
}

shell_failed :: proc(app: ^App, was: string) {
	f := &app.facts
	f.shell = strings.clone(was, virtual.arena_allocator(&f.arenas[.Cfg]))
	facts_soon(app)
}

// What the answers to the settings' requests do (net.odin REQ_FACTS). A page that could not be read says it where it would have been
// (read_shown): those fail quietly.
server_facts_on_ok :: proc(app: ^App, r: ^Request, v: json.Value) { server_facts_answer(app, r.kind, v) }

shell_set_on_ok :: proc(app: ^App, r: ^Request, v: json.Value) {
	ui.toast(.Good, "Shell set")
	facts_soon(app)   // (a reading that crossed it said the one before)
}

shell_set_on_fail :: proc(app: ^App, r: ^Request, f: Failure, message: string) -> (told: bool) {
	shell_failed(app, r.tag)
	return false
}

mcp_done_on_ok :: proc(app: ^App, r: ^Request, v: json.Value) { mcp_done(app, r.tag) }

mcp_done_on_fail :: proc(app: ^App, r: ^Request, f: Failure, message: string) -> (told: bool) {
	mcp_done(app, r.tag)
	return false
}

saved_done_on_ok :: proc(app: ^App, r: ^Request, v: json.Value) { saved_revoke_done(app, r.tag) }

saved_done_on_fail :: proc(app: ^App, r: ^Request, f: Failure, message: string) -> (told: bool) {
	saved_revoke_done(app, r.tag)
	return false
}

////////////////////////////////
// The sizes of the dialogs

// What layout.dialogs says, once, then what the person changed, written when the pointer lets go.
dialogs_track :: proc(app: ^App) {
	cx := &app.cx
	if !cx.dialogs_read {
		cx.dialogs_read = true
		rest := config.string_of(&app.cfg_prefs, "layout.dialogs")
		// (by position: the size of a dialog that went must not fall on the next one)
		if len(strings.fields(rest, context.temp_allocator)) == DIALOGS_SAVED_WITH_STATS {
			first, _ := strings.split_iterator(&rest, " ")
			_, _ = strings.split_iterator(&rest, " ")
			rest = fmt.tprintf("%s %s", first, rest)
		}
		for d in DIALOGS_SIZED {
			field, _ := strings.split_iterator(&rest, " ")
			wh := strings.split(field, "x", context.temp_allocator)
			if len(wh) != 2 { continue }
			cx.dialogs[d] = {f32(strconv.parse_f64(wh[0]) or_else 0), f32(strconv.parse_f64(wh[1]) or_else 0)}
		}
		cx.dialogs_saved = cx.dialogs
	}
	if cx.dialogs == cx.dialogs_saved || ui.active_key() != 0 { return }
	cx.dialogs_saved = cx.dialogs
	b := strings.builder_make(context.temp_allocator)
	for d in DIALOGS_SIZED { fmt.sbprintf(&b, "%.0fx%.0f ", cx.dialogs[d].x, cx.dialogs[d].y) }
	pref_set(app, "layout.dialogs", strings.trim_space(strings.to_string(b)))
}

////////////////////////////////
// The dialog

Settings_Page :: enum u8 { Appearance, Conversation, Behaviour, Updates, Advanced, Server, Connections, Mcp, Plugins, Usage, Permissions, Catalog }

// The settings dialog: its page, its search, the slider held, what is unfolded in it.
Settings_View :: struct {
	page:              Settings_Page,
	// the slider held (its preference, a constant name; "": none) and where it is: ui.slider moves its value only while the
	// button is down, so the value is kept here between frames and written at the release
	slider_held:       string,
	slider_held_value: f32,
	query:             ui.Text_Field,    // the search: while it has text, the matching settings of every client page
	search:            config.Search,    // what that text shows, this frame (settings_dialog)
	row_hidden:        bool,             // the row being built does not match the search: setting_end has nothing to close
	themes_open:       bool,             // the themes as a grid, not one line (theme_cards)
	show_licence:      bool,             // Ghostty's
}

SETTINGS_PAGES := [Settings_Page]struct { title, icon: string, opencode: bool }{
	.Appearance   = {"Appearance", lucide.PALETTE, false},
	.Conversation = {"Conversation", lucide.MESSAGE_SQUARE, false},
	.Behaviour    = {"Behaviour", lucide.SLIDERS_HORIZONTAL, false},
	.Updates      = {"Updates", lucide.REFRESH_CW, false},
	.Advanced     = {"Advanced", lucide.WRENCH, false},
	.Server       = {"Server & shell", lucide.SQUARE_TERMINAL, true},
	.Connections  = {"Connections", lucide.USER, true},
	.Mcp          = {"MCP servers", lucide.PLUG, true},
	.Plugins      = {"Plugins", lucide.ZAP, true},
	.Usage        = {"Usage & limits", lucide.GAUGE, true},
	.Permissions  = {"Permissions", lucide.SHIELD, true},
	.Catalog      = {"Providers & skills", lucide.LIST, true},
}

settings_open :: proc(app: ^App) {
	app.cx.open[.Settings] = true
	server_facts_load(app)
}

// The client's pages, the ones the search goes through (the OPENCODE ones show what the server says, not preferences).
SETTINGS_CLIENT_PAGES :: [?]Settings_Page{.Appearance, .Conversation, .Behaviour, .Updates, .Advanced}

// A search is typed: the page area shows what matches in every client page, and only that.
settings_searching :: proc(app: ^App) -> bool { return config.searching(&app.settings.search) }

settings_dialog :: proc(app: ^App, em: f32) {
	if ui.modal_sized("settings", DIALOG_PREFERRED_EM[.Settings] * em, &app.cx.dialogs[.Settings], &app.cx.open[.Settings], DIALOG_MIN_EM[.Settings] * em) {
		dialog_backdrop()
		config.search_begin(&app.settings.search, ui.field_string(&app.settings.query))
		ui.next({width = ui.fill(), height = ui.fill(), axis = .X})
		if ui.row(id = "###settings_body") {
			// the pages (their icons alone in a narrow dialog: the page needs the room more)
			narrow := ui.parent_box().size.x < em * SETTINGS_NARROW_EM
			ui.next({width = ui.px(em * (narrow ? SETTINGS_NAV_ICONS_EM : SETTINGS_NAV_EM)), height = ui.fill(), axis = .Y})
			if ui.column(id = "###settings_nav") {
				// (the list scrolls: a short window must not push it out of the dialog; the foot stays)
				ui.spacer(ui.px(em * 1.1))
				if !narrow { settings_search_field(app, em) }
				ui.next({width = ui.fill(), height = ui.fill()})
				if ui.scroll_y("###settings_nav_list") {
					ui.spacer(ui.px(em * 0.6))
					if !narrow { nav_heading("CLIENT", app.mono_bold, em) }
					for page in Settings_Page {
						info := SETTINGS_PAGES[page]
						if page == .Server { ui.spacer(ui.px(em * 0.6)); if !narrow { nav_heading("OPENCODE", app.mono_bold, em) } }
						ui.next({width = ui.fill(), height = ui.children_sum(), axis = .X})
						if ui.row(id = fmt.tprintf("###nv%d", int(page))) {
							ui.spacer(ui.px(em * 0.7))
							current := app.settings.page == page && !settings_searching(app)
							if bevel_button(fmt.tprintf("###nav%d", int(page)), narrow ? "" : info.title, info.icon, current ? .Toggled : .Ghost, ui.fill(), math.round(em * BUTTON_H_EM), left = true).clicked {
								app.settings.page = page
								ui.field_set(&app.settings.query, "")   // (a page chosen: the search is done)
							}
							ui.spacer(ui.px(em * 0.9))   // (the scroll bar's place)
						}
						ui.spacer(ui.px(em * 0.2))
					}
				}
				if !narrow {
					// (the program and its version, above where its preferences are: what a report of a problem says first)
					ui.next({width = ui.fill(), height = ui.children_sum(), axis = .X})
					if ui.row(id = "###nav_version") {
						ui.spacer(ui.px(em * 0.9))
						text("v", fmt.tprintf("opencode native %s", APP_VERSION), hex(HEX_WEAK), ui.Style_Mod{font_size = math.round(em * FS_CAPTION), height = ui.px(em * 1.4)})
					}
					ui.next({width = ui.fill(), height = ui.children_sum(), axis = .X})
					if ui.row(id = "###nav_foot") {
						ui.spacer(ui.px(em * 0.9))
						text("f", fmt.tprintf("prefs: %s", filepath.base(prefs_path())), hex(HEX_FAINT), ui.Style_Mod{font = app.mono, font_size = math.round(em * FS_CAPTION), height = ui.px(em * 1.4)})
					}
					ui.spacer(ui.px(em * 0.9))
				}
			}
			groove("###settings_div")
			// the page
			ui.next({width = ui.fill(), height = ui.fill()})
			if ui.scroll_y("###settings_page") {
				ui.next({width = ui.fill(), height = ui.children_sum(), axis = .X})
				if ui.row(id = "###pg") {
					ui.spacer(ui.px(em * DIALOG_MARGIN_EM))
					ui.next({width = ui.fill(), height = ui.children_sum(), axis = .Y})
					if ui.column() {
						ui.spacer(ui.px(em * 1.1))
						if settings_searching(app) {
							settings_results(app, em)
						} else {
							info := SETTINGS_PAGES[app.settings.page]
							text("pt", info.title, hex(HEX_BRIGHT), ui.Style_Mod{font_size = math.round(em * FS_TITLE), height = ui.px(em * 2)}, ui.fill())
							ui.spacer(ui.px(em * 0.6))
							settings_page_draw(app, app.settings.page, em)
						}
						ui.spacer(ui.px(em * 1.5))
					}
					ui.spacer(ui.px(em * DIALOG_MARGIN_EM))
				}
			}
		}
		dialog_close(&app.cx.open[.Settings])
	}
}

// The field of the settings' search, above the pages.
@(private = "file")
settings_search_field :: proc(app: ^App, em: f32) {
	ui.next({width = ui.fill(), height = ui.children_sum(), axis = .X})
	if ui.row(id = "###settings_search") {
		ui.spacer(ui.px(em * 0.7))
		ui.next({width = ui.fill(), height = ui.px(math.round(em * FIELD_H_EM)), axis = .X, cross = .Center})
		if well("###settings_search_well", .X, radius = 7) {
			ui.spacer(ui.px(em * 0.5))
			glyph(lucide.SEARCH, hex(HEX_FAINT), math.round(em * ICON_SMALL))
			if ui.tags("bare") {
				ui.next({width = ui.fill(), height = ui.pct(1), text_pad = em * 0.3})
				ui.line_edit("###settings_query", &app.settings.query, "Search settings")
			}
		}
		ui.spacer(ui.px(em * 0.9))
	}
}

// What the search finds in every client page, under each page's title (config.Search), the controls live.
@(private = "file")
settings_results :: proc(app: ^App, em: f32) {
	text("pt", "Search", hex(HEX_BRIGHT), ui.Style_Mod{font_size = math.round(em * FS_TITLE), height = ui.px(em * 2)}, ui.fill())
	for page in SETTINGS_CLIENT_PAGES {
		config.search_page(&app.settings.search, SETTINGS_PAGES[page].title)
		settings_page_draw(app, page, em)
	}
	if app.settings.search.found == 0 {
		ui.spacer(ui.px(em * 0.6))
		info_line(app, "###settings_none", "No setting matches.", em, hex(HEX_FAINT))
	}
}

@(private = "file")
settings_page_draw :: proc(app: ^App, page: Settings_Page, em: f32) {
	switch page {
	case .Appearance:   page_appearance(app, em)
	case .Conversation: page_conversation(app, em)
	case .Behaviour:    page_behaviour(app, em)
	case .Updates:      page_updates(app, em)
	case .Advanced:     page_advanced(app, em)
	case .Server:       page_server(app, em)
	case .Connections:  page_connections(app, em)
	case .Mcp:          page_mcp(app, em)
	case .Plugins:      page_plugins(app, em)
	case .Usage:        page_usage(app, em)
	case .Permissions:  page_permissions(app, em)
	case .Catalog:      page_catalog(app, em)
	}
	}

@(private = "file")
nav_heading :: proc(s: string, face: Face_Id, em: f32) {
	ui.next({width = ui.fill(), height = ui.px(em * 1.5), axis = .X, cross = .Center})
	if ui.row(.Center, id = fmt.tprintf("###nh_%s", s)) {
		ui.spacer(ui.px(em * 1.1))
		text("h", s, hex(HEX_FAINT), ui.Style_Mod{font = face, font_size = math.round(em * FS_CAPTION)})
	}
}

// `if setting(name) { control }`: a row with the preference's title and description on the left, its control on the
// right, and a reset button when it is not at its default.
@(deferred_in = setting_end)
setting :: proc(app: ^App, name: string, em: f32) -> bool {
	p := &app.cfg_prefs
	show, heading := config.search_shows(&app.settings.search, p, name)
	if !show { app.settings.row_hidden = true; return false }
	if heading != "" { section_draw(heading, em) }   // (a search: the page's title before its first match)
	r := config.ref_of(p, name)
	e := config.entry(p, r)
	ui.next({width = ui.fill(), height = ui.children_sum(), axis = .Y})
	ui.push_parent(ui.build_box({}, fmt.tprintf("###set_%s", name)))
	ui.next({width = ui.fill(), height = ui.children_sum(), axis = .X, cross = .Center})
	ui.push_parent(ui.build_box({}, "###line"))
	ui.next({width = ui.fill(), height = ui.children_sum(), axis = .Y})
	if ui.column(id = "###words") {
		text("t", config.title_of(e.def), hex(HEX_SETTING_NAME), ui.Style_Mod{font_size = math.round(em * FS_LABEL), height = ui.px(em * 1.5)}, ui.fill())
		ui.next({width = ui.fill(), font_size = math.round(em * FS_NOTE), flags = {.Text_Wrap}, fg = hex(HEX_WEAK), text_pad = 0})
		ui.paragraph(fmt.tprintf("%s###d", e.def.description))
		ui.spacer(ui.px(em * 0.2))
	}
	ui.spacer(ui.px(em * 0.8))
	if !config.is_default(p, r) {
		ui.a11y({name = "Reset to default"})
		if glyph_button("###reset", lucide.REFRESH_CW, math.round(em * 1.6)).clicked {
			config.reset(p, name)
			prefs_save(app)
			prefs_refresh(app)
		}
		ui.spacer(ui.px(em * 0.3))
	}
	return true
}

@(private = "file")
setting_end :: proc(app: ^App, name: string, _: f32) {
	if app.settings.row_hidden { app.settings.row_hidden = false; return }
	ui.pop_parent()   // ###line
	em := ui.font_size()
	ui.spacer(ui.px(em * 0.5))
	groove()
	ui.spacer(ui.px(em * 0.4))
	ui.pop_parent()   // ###set_
}

// The controls, each bound to a preference.

@(private = "file")
pref_choice :: proc(app: ^App, name: string, labels: []string, em: f32, width: f32 = 0) {
	d := config.entry(&app.cfg_prefs, config.ref_of(&app.cfg_prefs, name)).def
	cur := config.string_of(&app.cfg_prefs, name)
	sel := 0
	for c, i in d.choices { if c == cur { sel = i } }
	w := width > 0 ? width : em * 7.6 * f32(len(labels))
	// (never narrower than its words: the segments are of one width, the longest label's with its room around it)
	widest: f32
	for l in labels { widest = max(widest, ui.text_width(app.font, ui.font_size(), l)) }
	w = max(w, f32(len(labels)) * (widest + em * SEGMENT_PAD_EM))
	// Too wide beside its words, it goes under them: the words keep the line, it has the room. (setting_end closes this line as it would
	// have closed the first one.)
	line := ui.parent_box()
	if room := line.rect.max.x - line.rect.min.x; room > 0 && w > room * WIDE_CHOICE_SHARE {
		ui.pop_parent()   // ###line
		ui.spacer(ui.px(em * 0.4))
		ui.next({width = ui.fill(), height = ui.children_sum(), axis = .X, cross = .Center})
		ui.push_parent(ui.build_box({}, "###under"))
	}
	ui.next({width = ui.px(math.round(w)), height = ui.px(math.round(em * 2))})
	if choice("###seg", labels, &sel) { pref_set(app, name, d.choices[sel]) }
}

@(private = "file")
pref_switch :: proc(app: ^App, name: string, em: f32) {
	v := config.bool_of(&app.cfg_prefs, name)
	ui.next({width = ui.px(em * 3.6), height = ui.px(math.round(em * 2))})
	ui.a11y({name = config.title_of(config.entry(&app.cfg_prefs, config.ref_of(&app.cfg_prefs, name)).def)})
	if ui.toggle("###sw", "", &v).clicked { pref_set(app, name, v ? "true" : "false") }
}

// What a focused slider makes of `v` with no key pressed: it snaps it to its step and its range.
slider_idle :: proc(v, lo, hi, step: f32) -> f32 {
	return clamp(step > 0 ? math.round(v / step) * step : v, lo, hi)
}

@(private = "file")
pref_slider :: proc(app: ^App, name: string, lo, hi, step: f32, format: string, em: f32) {
	p := &app.cfg_prefs
	d := config.entry(p, config.ref_of(p, name)).def
	held := app.settings.slider_held == name
	v := held ? app.settings.slider_held_value : (d.kind == .Int ? f32(config.int_of(p, name)) : f32(config.float_of(p, name)))
	ui.next({width = ui.px(em * 15), height = ui.px(math.round(em * 2))})
	ui.a11y({name = config.title_of(d)})
	idle := slider_idle(v, lo, hi, step)
	sig := ui.slider("###sl", &v, lo, hi, step, format)
	// while the button is down the value is the app's (the preference is read again at each frame); at the release it is written
	if sig.pointer_pressed || sig.dragging {
		app.settings.slider_held, app.settings.slider_held_value = name, v
	} else if held {
		app.settings.slider_held = ""
	}
	// written when the drag ends (or at each key step): the file is not rewritten at the pointer's rate, nor by the focus alone
	if (sig.released || (sig.focused && !sig.dragging && abs(v - idle) > SLIDER_EPSILON)) && (d.kind == .Int ? i64(math.round(v)) != config.int_of(p, name) : abs(f64(v) - config.float_of(p, name)) > SLIDER_EPSILON) {
		pref_set(app, name, d.kind == .Int ? fmt.tprintf("%d", i64(math.round(v))) : fmt.tprintf("%.2f", v))
	} else if sig.dragging && d.kind == .Float && name == "appearance.rounding" {
		ui.set_rounding(&app.state, v)   // (live while dragged)
	}
}

@(private = "file")
Theme_Card :: struct { cols: ^ui.Theme_Colors, chosen: bool }

// The themes, each in its own colours: its surface, its name in its text, its colours as dots, a ring of its accent around the
// one shown. On one line that scrolls sideways; "Show all" lays them out as a grid (gui_toolkit's strip_grid).
@(private = "file")
theme_cards :: proc(app: ^App, em: f32) {
	all := themes(app)
	cur := app.cx.theme.at
	gap := em * 0.5
	if ui.strip_grid("###themes", &app.settings.themes_open, {gap, gap}) {
		for &def, i in all {
			ui.next({width = ui.px(math.round(em * THEME_CARD_W_EM)), height = ui.px(math.round(em * THEME_CARD_H_EM)), axis = .Y, cursor = .Hand})
			ui.a11y({role = .Radio_Button, name = def.name, toggled = i == cur ? .True : .False})
			b := ui.build_box({.Clickable, .Focusable}, fmt.tprintf("###th%d", i))
			d := ui.frame_new(Theme_Card)
			cols := ui.frame_new(ui.Theme_Colors)
			cols^, _ = ui.theme_version(def, app.cx.theme.light)   // (in the version shown)
			d^ = {cols, i == cur}
			b.custom, b.custom_user = theme_card_draw, d
			if ui.signal(b).clicked && i != cur { pref_set(app, "appearance.theme", def.name) }
			if ui.parent(b) {
				ui.spacer(ui.px(em * 0.55))
				ui.next({width = ui.fill(), height = ui.children_sum(), axis = .X})
				if ui.row(id = "###n") {
					ui.spacer(ui.px(em * 0.8))
					text("t", def.name, draw.hex(cols.texts[2]), ui.Style_Mod{font_size = math.round(em * FS_LABEL), height = ui.px(em * 1.4)}, ui.fill())
				}
			}
		}
	}
	ui.spacer(ui.px(em * 0.5))
}

// Where a theme card's dots go: their size, the first one's left, their top. `em`: the font's size as drawn (frame pixels,
// the screen's scale in it already: scaled once more, at 200 % the dots rose onto the name).
theme_card_dots :: proc(r: Rect, em: f32) -> (dot, x, y: f32) {
	dot = math.round((r.max.y - r.min.y) * 0.16)
	x = r.min.x + math.round(0.8 * em)
	y = r.max.y - math.round(0.55 * em) - dot
	return
}

@(private = "file")
theme_card_draw :: proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
	d := (^Theme_Card)(user)
	t := d.cols
	r := b.rect
	s := ui.scale()
	radius := math.round(THEME_CARD_RADIUS * s * corners())
	draw.rect(dc, r, draw.hex(t.steps[3]), radius)
	accent := draw.hex(t.hues[0])
	edge := d.chosen ? accent : draw.mix(draw.hex(t.steps[5]), draw.hex(t.texts[1]), 0.35 * b.hot_t)
	draw.rect(dc, r, edge, radius, d.chosen ? 2 * px1() : px1())
	// its colours, as dots along the bottom: the accent first, larger
	dot, x, y := theme_card_dots(r, ui.font_size())
	prev := draw.set_circular_corners(dc, true)
	defer draw.set_circular_corners(dc, prev)
	for h, i in t.hues {
		if i == 2 || i == 7 { continue }   // (purple and rose: the accent and the others say enough)
		sz := i == 0 ? dot * 1.5 : dot
		cy := y + dot * 0.5
		draw.rect(dc, {{x, cy - sz * 0.5}, {x + sz, cy + sz * 0.5}}, draw.hex(h), sz * 0.5)
		x += sz + math.round(dot * 0.6)
	}
}

page_appearance :: proc(app: ^App, em: f32) {
	theme := false
	if setting(app, "appearance.theme", em) { theme = true }   // (its title and its words; the cards under them)
	if theme {
		theme_cards(app, em)
		if hint_action("###themes_file", "Themes of your own: themes.txt", em) { themes_file_open(app) }
		ui.spacer(ui.px(em * 0.6))
	}
	if setting(app, "appearance.mode", em) { pref_choice(app, "appearance.mode", {"System", "Dark", "Light"}, em, em * 16) }
	if setting(app, "appearance.style", em) { pref_choice(app, "appearance.style", {"Machined", "Edged", "Flat"}, em, em * 18) }
	if app.win != nil && platform.system_title_available(app.win) {   // (GNOME: no title bar of the system to choose)
		if setting(app, "appearance.system_title", em) { pref_switch(app, "appearance.system_title", em) }
	}
	if setting(app, "appearance.font", em) { font_button(app, "appearance.font", em) }
	if setting(app, "appearance.prose_font", em) { font_button(app, "appearance.prose_font", em) }
	if setting(app, "appearance.mono_font", em) { font_button(app, "appearance.mono_font", em) }
	if setting(app, "appearance.terminal_font", em) { font_button(app, "appearance.terminal_font", em) }
	if setting(app, "appearance.font_size", em) { pref_slider(app, "appearance.font_size", FONT_SIZE_MIN, FONT_SIZE_MAX, 1, "%.0f pt", em) }
	if setting(app, "appearance.text_smoothing", em) { pref_choice(app, "appearance.text_smoothing", {"Auto", "RGB", "BGR", "Grey"}, em, em * 18) }
	if setting(app, "appearance.zoom", em) { pref_slider(app, "appearance.zoom", ZOOM_MIN, ZOOM_MAX, 0.05, "%.2f×", em) }
	if setting(app, "appearance.content_zoom", em) { pref_slider(app, "appearance.content_zoom", CONTENT_ZOOM_MIN, CONTENT_ZOOM_MAX, 0.05, "%.2f×", em) }
	if setting(app, "appearance.throbber", em) { pref_choice(app, "appearance.throbber", {"Board", "Orbit", "Scanner", "None"}, em, em * 18) }
	if setting(app, "appearance.density", em) { pref_choice(app, "appearance.density", {"Comfortable", "Compact"}, em) }
	if setting(app, "appearance.rounding", em) { pref_slider(app, "appearance.rounding", 0, 2, 0.05, "%.2f", em) }
	if setting(app, "appearance.animations", em) { pref_choice(app, "appearance.animations", {"System", "On", "Off"}, em) }
	if setting(app, "appearance.smooth_scroll", em) { pref_switch(app, "appearance.smooth_scroll", em) }
	if setting(app, "appearance.autohide_scrollbars", em) { pref_switch(app, "appearance.autohide_scrollbars", em) }
	if setting(app, "appearance.glow", em) { pref_switch(app, "appearance.glow", em) }
}

// The button of a font preference (its face) and its picker: Automatic (the client's own), the other choice, then the
// installed families, matched as one types.
font_button :: proc(app: ^App, name: string, em: f32) {
	term := name == "appearance.terminal_font"
	mono := name == "appearance.mono_font" || term
	prose := name == "appearance.prose_font"
	want := config.string_of(&app.cfg_prefs, name)
	face := term ? app.term_face : mono ? app.mono_face : prose ? app.prose_face : app.ui_face
	own := term ? "Fira Mono" : mono ? "DM Mono" : prose ? "Newsreader" : "Hanken Grotesk"
	second := prose ? FONT_SAME : FONT_SYSTEM
	// the button names the face in use; a faint word before it says how it was chosen
	mode, shown: string
	switch want {
	case "", FONT_BUILTIN: mode, shown = "auto", own
	case FONT_SYSTEM:      mode, shown = "system", face != "" ? face : own
	case FONT_SAME:        mode, shown = "same", app.ui_face != "" ? app.ui_face : "Hanken Grotesk"
	case:                  mode, shown = face == want ? "" : "not installed", want
	}
	if mode != "" {
		text("fm", mode, hex(HEX_FAINT), ui.Style_Mod{font_size = math.round(em * FS_SMALL), height = ui.px(em * 1.5)})
		ui.spacer(ui.px(em * 0.5))
	}
	sig := bevel_button(fmt.tprintf("###fb_%s", name), shown, "", .Normal, ui.px(em * 13))
	if sig.clicked {
		if app.cx.open[.Picker] && app.picker.id == name { app.cx.open[.Picker] = false } else { picker_open(app, name, sig.box.rect) }
	}
	if !(app.cx.open[.Picker] && app.picker.id == name) { return }
	if app.font_families == nil { app.font_families = font.system_families(&app.fonts) }
	items := make([dynamic]Pick_Item, context.temp_allocator)
	append(&items, Pick_Item{label = "Automatic", detail = fmt.tprintf("%s, built in", own), current = want == "" || want == FONT_BUILTIN})
	append(&items, Pick_Item{label = prose ? "As the interface" : "System", detail = prose ? "the interface's face" : "the system's usual face", current = want == second})
	for fam in app.font_families { append(&items, Pick_Item{label = fam, current = fam == want}) }
	if k := picker(app, &app.picker, name, mono ? "code fonts" : "fonts", items[:], em, align_right = true); k >= 0 {
		switch k {
		case 0: pref_set(app, name, "")
		case 1: pref_set(app, name, second)
		case:   pref_set(app, name, app.font_families[k - 2])
		}
	}
}

page_conversation :: proc(app: ^App, em: f32) {
	if setting(app, "conversation.width", em) { pref_slider(app, "conversation.width", COLUMN_W_MIN, COLUMN_W_MAX, 20, "%.0f px", em) }
	if setting(app, "conversation.reasoning", em) { pref_choice(app, "conversation.reasoning", {"Folded", "Unfolded", "Hidden"}, em) }
	if setting(app, "conversation.expand_tools", em) { pref_switch(app, "conversation.expand_tools", em) }
	if setting(app, "conversation.tool_lines", em) { pref_slider(app, "conversation.tool_lines", TOOL_LINES_MIN, TOOL_LINES_MAX, 5, "%.0f lines", em) }
	if setting(app, "conversation.page_size", em) { pref_slider(app, "conversation.page_size", PAGE_SIZE_MIN, PAGE_SIZE_MAX, 10, "%.0f", em) }
	if setting(app, "conversation.follow", em) { pref_switch(app, "conversation.follow", em) }
	if setting(app, "conversation.usage", em) { pref_switch(app, "conversation.usage", em) }
	if setting(app, "conversation.while_running", em) { pref_choice(app, "conversation.while_running", {"Queue", "Steer"}, em) }
	if setting(app, "conversation.image_viewer_size", em) { pref_slider(app, "conversation.image_viewer_size", VIEWER_SCALE_MIN, 1, 0.05, "%.2f", em) }
	if setting(app, "conversation.clock", em) { pref_choice(app, "conversation.clock", {"24 h", "12 h"}, em) }
}

page_behaviour :: proc(app: ^App, em: f32) {
	if setting(app, "composer.send", em) { pref_choice(app, "composer.send", {"Enter", "Ctrl+Enter"}, em, em * 14) }
	if setting(app, "sidebar.mode", em) { pref_choice(app, "sidebar.mode", {SIDEBAR_MODES[.Inbox].label, SIDEBAR_MODES[.Projects].label}, em, em * 14) }
	if setting(app, "sidebar.subagents", em) { pref_choice(app, "sidebar.subagents", {"Nested", "Flat", "Hidden"}, em) }
	if setting(app, "notify.finished", em) { pref_choice(app, "notify.finished", {"Off", "Toast", "Flash", "System"}, em) }
	if setting(app, "permission.new_sessions", em) { pref_choice(app, "permission.new_sessions", {"As configured", "Allow edits", "Allow all", "Ask all"}, em, em * 26) }
	if setting(app, "notify.permission", em) { pref_switch(app, "notify.permission", em) }
	if setting(app, "general.start", em) { pref_choice(app, "general.start", {"Home", "Latest session"}, em, em * 14) }
	if !settings_searching(app) {
		ui.spacer(ui.px(em * 0.6))
		info_line(app, "###hint_setup", "Installation and " + LBL_PIECES + " are in Setup… (title bar menu).", em)
	}
}

page_updates :: proc(app: ^App, em: f32) {
	if !settings_searching(app) {   // (the state and the buttons: a page's, not a setting's)
		u := &app.updater
		state := "Up to date, as far as is known"
		switch _ in u.state {
		case nil:
			if u.result != "" { state = u.result }
		case Update_Checking:    state = "Looking for a new version…"
		case Update_Ready:       state = fmt.tprintf("Version %s is available", update_version(u))
		case Update_Downloading: state = fmt.tprintf("Downloading %s…", update_version(u))
		case Update_Installed:   state = fmt.tprintf("Version %s is installed: restart to use it", update_version(u))
		}
		ui.next({width = ui.fill(), height = ui.children_sum(), axis = .Y})
		if well("###upd", radius = 7, base = HEX_FACTS_WELL) {
			ui.spacer(ui.px(em * 0.4))
			fact("###u1", "version", APP_VERSION, em)
			fact("###u2", "channel", app.prefs.update_channel, em)
			fact("###u3", "state", state, em)
			ui.spacer(ui.px(em * 0.4))
		}
		ui.spacer(ui.px(em * 0.7))
		ui.next({width = ui.fill(), height = ui.children_sum(), axis = .X, cross = .Center})
		if ui.row(.Center, id = "###upd_b") {
			if bevel_button("###u_check", "Check now", lucide.REFRESH_CW, .Normal, disabled = update_is_downloading(u)).clicked { update_check(app, true) }
			ui.spacer(ui.px(em * 0.5))
			if update_is_ready(u) {
				if bevel_button("###u_inst", fmt.tprintf("Install %s", update_version(u)), lucide.CHECK, .Accent).clicked { update_install(app) }
			}
			if update_is_installed(u) {
				if bevel_button("###u_rest", "Restart now", lucide.REFRESH_CW, .Accent).clicked { app_restart(app) }
			}
		}
		ui.spacer(ui.px(em * 0.9))
	}
	if setting(app, "update.channel", em) { pref_choice(app, "update.channel", {"Stable", "Beta"}, em, em * 14) }
	if setting(app, "update.auto", em) { pref_switch(app, "update.auto", em) }
	if !settings_searching(app) {
		ui.spacer(ui.px(em * 0.6))
		info_line(app, "###hint_sig", "Only what is signed with the key built into this program is installed: the channel, the version and the file's checksum are all in the signature.", em)
	}
}

page_advanced :: proc(app: ^App, em: f32) {
	section(app, "PREVIEW", em)
	if setting(app, "browser.tools", em) { pref_switch(app, "browser.tools", em) }
	section(app, "ABOUT", em)
	if !settings_searching(app) { info_line(app, "###adv_about", fmt.tprintf("%s %s, a client of the OpenCode server. %s", APP_NAME, APP_VERSION, APP_NOT_THEIRS), em) }
	section(app, "SERVER", em)
	if setting(app, "advanced.experimental", em) { pref_switch(app, "advanced.experimental", em) }
	section(app, "DIAGNOSTICS", em)
	if setting(app, "advanced.fps", em) { pref_switch(app, "advanced.fps", em) }
	if setting(app, "advanced.frame_rate", em) { pref_choice(app, "advanced.frame_rate", {"Screen", "30", "60", "120", "240", "Uncapped"}, em, em * 24) }
	if !settings_searching(app) {   // (the folder, the licence: not settings)
		ui.spacer(ui.px(em * 0.7))
		ui.next({width = ui.fill(), height = ui.children_sum(), axis = .X, cross = .Center})
		if ui.row(.Center, id = "###adv_b") {
			if bevel_button("###adv_dir", "Open the settings folder", lucide.FOLDER, .Normal).clicked { _ = platform.open_path(filepath.dir(prefs_path())) }
			ui.spacer(ui.px(em * 0.4))
			if bevel_button("###adv_lic", app.settings.show_licence ? "Hide the terminal's licence" : "The terminal's licence", "", .Ghost).clicked { app.settings.show_licence = !app.settings.show_licence }
		}
		if app.settings.show_licence {
			ui.spacer(ui.px(em * 0.5))
			info_line(app, "###adv_lic_say", "The terminal's emulation is Ghostty's, through libghostty-vt.", em)
			ui.spacer(ui.px(em * 0.3))
			code_block("###adv_lic_text", "text", GHOSTTY_LICENSE, app.mono, version = 1)
		}
	}
}

// A line of quiet text.
info_line :: proc(app: ^App, id, s: string, em: f32, color := Color{}) {
	ui.next({width = ui.fill(), font_size = math.round(em * FS_NOTE), flags = {.Text_Wrap}, fg = color.a > 0 ? color : hex(HEX_WEAK), text_pad = 0})
	ui.paragraph(fmt.tprintf("%s%s", label_safe(s), id))
}

// A key / value line in a well.
@(private = "file")
fact :: proc(id, k, v: string, em: f32, col := Color{}) {
	kv_row(id, k, v, em, {h = 1.5, key_w = 8.5, key_fs = FS_SMALL, val_fs = FS_SMALL, pad_l = 0.8, pad_r = 0.6, val = HEX_FACT_VALUE}, col)
}

section :: proc(app: ^App, s: string, em: f32) {
	if settings_searching(app) { return }   // (a search shows the pages' titles, not their groups)
	section_draw(s, em)
}

@(private = "file")
section_draw :: proc(s: string, em: f32) {
	ui.spacer(ui.px(em * 0.6))
	section_label(fmt.tprintf("sec_%s", s), s, em)
}

// A path the server names as a configuration file is opened by the system: only an absolute path on this computer (no
// share, no scheme) to a file of a kind that opens in an editor, not one that runs.
config_file_shaped :: proc(path: string) -> bool {
	when ODIN_OS == .Windows {
		drive := len(path) >= 3 && ((path[0] >= 'a' && path[0] <= 'z') || (path[0] >= 'A' && path[0] <= 'Z')) && path[1] == ':' && (path[2] == '\\' || path[2] == '/')
	} else {
		drive := strings.has_prefix(path, "/") && !strings.has_prefix(path, "//")
	}
	ext := strings.to_lower(filepath.ext(path), context.temp_allocator)
	return drive && (ext == ".json" || ext == ".jsonc")
}

page_server :: proc(app: ^App, em: f32) {
	f := &app.facts
	section(app, "SERVER", em)
	ui.next({width = ui.fill(), height = ui.children_sum(), axis = .Y})
	if well("###srv", radius = 7, base = HEX_FACTS_WELL) {
		ui.spacer(ui.px(em * 0.4))
		fact("###s1", "address", server_base(app), em)
		fact("###s2", "status", online(app) ? "connected" : "not connected", em, online(app) ? hex(HEX_GREEN) : hex(HEX_YELLOW))
		fact("###s3", "version", app.server_version != "" ? app.server_version : "?", em)
		fact("###s0", "name", server_name(app), em)
		fact("###s4", "auth", app.servers[app.server].password == "" ? "none" : app.servers[app.server].local ? "Basic (password from service.json)" : "Basic", em)
		fact("###s5", "sessions", fmt.tprintf("%d loaded · %d running", len(app.sessions), len(app.busy)), em)
		fact("###s6", "client", fmt.tprintf("opencode native %s", APP_VERSION), em)
		ui.spacer(ui.px(em * 0.4))
	}
	section(app, "SHELL", em)
	info_line(app, "###shh", "The shell the agents run their commands in (written to the configuration's \"shell\").", em)
	ui.spacer(ui.px(em * 0.4))
	if read_shown(app, "###sh_read", &f.reads[.Shells], em, server_facts_load) {
		sel := -1
		for s, i in f.shells { if f.shell != "" && desktop.same_path(s.path, f.shell) { sel = i } }
		for s, i in f.shells {
			ui.next({width = ui.fill(), height = ui.px(math.round(em * SETTINGS_ROW_H_EM)), axis = .X, cross = .Center})
			if ui.row(.Center, id = fmt.tprintf("###sh%d", i)) {
				if bevel_button(fmt.tprintf("###shb%d", i), s.name, lucide.SQUARE_TERMINAL, sel == i ? .Accent : .Normal, ui.px(em * 9), math.round(em * BUTTON_COMPACT_H_EM), disabled = !s.ok).clicked { shell_set(app, s) }
				ui.spacer(ui.px(em * 0.7))
				text("p", s.path, hex(HEX_FAINT), ui.Style_Mod{font = app.mono, font_size = math.round(em * FS_CAPTION)}, ui.fill())
			}
			ui.spacer(ui.px(em * 0.25))
		}
		if sel < 0 { info_line(app, "###shd", "None set: the server picks one.", em, hex(HEX_FAINT)) }
	}
	section(app, "CONFIGURATION FILES", em)
	if !read_shown(app, "###cf_read", &f.reads[.Cfg], em, server_facts_load) { return }
	for c, i in f.files {
		ui.next({width = ui.fill(), height = ui.children_sum(), axis = .X, cross = .Center})
		if ui.row(.Center, id = fmt.tprintf("###cf%d", i)) {
			ui.next({width = ui.fill(), height = ui.children_sum(), axis = .Y})
			if ui.column() {
				text("p", c.path, hex(HEX_FACT_NAME), ui.Style_Mod{font = app.mono, font_size = math.round(em * FS_SMALL), height = ui.px(em * 1.5)}, ui.fill())
				text("k", strings.join(c.keys, " · ", context.temp_allocator), hex(HEX_FAINT), ui.Style_Mod{font = app.mono, font_size = math.round(em * FS_CAPTION), height = ui.px(em * 1.3)}, ui.fill())
			}
			// (only this computer's server speaks of this computer's files)
			if app.servers[app.server].local && config_file_shaped(c.path) && os.is_file(c.path) {
				if bevel_button("###open", "Open", lucide.FILE, .Normal, height = math.round(em * BUTTON_SMALL_H_EM)).clicked { platform.open_path(c.path) }
				ui.spacer(ui.px(em * 0.3))
				if bevel_button("###dir", "", lucide.FOLDER, .Normal, height = math.round(em * BUTTON_SMALL_H_EM)).clicked { platform.open_path(filepath.dir(c.path)) }
			}
		}
		ui.spacer(ui.px(em * 0.4))
	}
	if len(f.files) == 0 { info_line(app, "###nocf", "No configuration file (the defaults apply).", em, hex(HEX_FAINT)) }
}

page_mcp :: proc(app: ^App, em: f32) {
	f := &app.facts
	info_line(app, "###mh", "Model Context Protocol servers give the agents more tools. Connecting or disconnecting one applies to the server now.", em)
	ui.spacer(ui.px(em * 0.6))
	if !read_shown(app, "###mcp_read", &f.reads[.Mcp], em, server_facts_load) { return }
	if len(f.mcp) == 0 {
		info_line(app, "###none", "No MCP server is configured.", em, hex(HEX_FAINT))
		return
	}
	for &m, i in f.mcp {
		connected := m.status == .Connected
		going := mcp_going(f, m.name)
		col := connected ? hex(HEX_GREEN) : m.status == .Failed || m.error != "" ? hex(HEX_RED) : hex(HEX_FAINT)
		word := going != nil ? (going.connecting ? "connecting…" : "disconnecting…") : m.word != "" ? m.word : "?"
		ui.next({width = ui.fill(), height = ui.children_sum(), axis = .Y})
		if plate(fmt.tprintf("###mcp%d", i), top = HEX_MCP_TOP, bottom = HEX_MCP_BOTTOM, radius = 8, shadow = 4) {
			ui.next({width = ui.fill(), height = ui.px(math.round(em * 2.8)), axis = .X, cross = .Center})
			if ui.row(.Center) {
				ui.spacer(ui.px(em * 0.9))
				lamp("###l", col, connected ? 1 : 0.4, size = em * 0.9)
				ui.spacer(ui.px(em * 0.5))
				text("n", m.name, hex(HEX_MCP_NAME), ui.Style_Mod{font = app.mono_bold, font_size = math.round(em * FS_LABEL)})
				ui.spacer(ui.px(em * 0.6))
				text("s", word, col, ui.Style_Mod{font = app.mono, font_size = math.round(em * FS_SMALL)}, ui.fill())
				// (what goes on says itself: no button says the opposite meanwhile)
				if going == nil {
					if connected {
						if bevel_button("###dc", "Disconnect", "", .Normal, height = math.round(em * BUTTON_SMALL_H_EM)).clicked { mcp_switch(app, m.name, false) }
					} else {
						if bevel_button("###co", "Connect", "", .Accent, height = math.round(em * BUTTON_SMALL_H_EM)).clicked { mcp_switch(app, m.name, true) }
					}
				}
				ui.spacer(ui.px(em * 0.8))
			}
			if m.error != "" {
				ui.next({width = ui.fill(), height = ui.children_sum(), axis = .X})
				if ui.row() {
					ui.spacer(ui.px(em * 2.2))
					info_line(app, "###err", m.error, em, hex(HEX_ERROR_TEXT))
					ui.spacer(ui.px(em))
				}
				ui.spacer(ui.px(em * 0.5))
			}
		}
		ui.spacer(ui.px(em * 0.5))
	}
}

page_usage :: proc(app: ^App, em: f32) {
	f := &app.facts
	if !read_shown(app, "###use_read", &f.reads[.Usage], em, server_facts_load) { return }
	if len(f.limits) == 0 && len(f.budgets) == 0 {
		info_line(app, "###none", "The server reports no usage limit (a provider of your own, or no OpenCode workspace).", em, hex(HEX_FAINT))
		return
	}
	if f.workspace != "" {
		ui.next({width = ui.fill(), height = ui.px(em * SETTINGS_ROW_H_EM), axis = .X, cross = .Center})
		if ui.row(.Center, id = "###ws") {
			text("w", fmt.tprintf("Workspace “%s”", f.workspace), hex(HEX_WORKSPACE_NAME), ui.Style_Mod{font_size = math.round(em * FS_LABEL)}, ui.fill())
			if f.usage_url != "" {
				if bevel_button("###web", "Usage on opencode.ai", lucide.GLOBE, .Normal, height = math.round(em * BUTTON_SMALL_H_EM)).clicked { link_open(f.usage_url) }
			}
		}
	}
	now := now_epoch_ms()
	if len(f.limits) > 0 { section(app, "OPENCODE GO", em) }
	for l, i in f.limits {
		ui.next({width = ui.fill(), height = ui.px(math.round(em * SETTINGS_ROW_H_EM)), axis = .X, cross = .Center})
		if ui.row(.Center, id = fmt.tprintf("###lim%d", i)) {
			text("n", l.name, hex(HEX_FACT_NAME), ui.Style_Mod{font = app.mono, font_size = math.round(em * FS_SMALL)}, ui.px(em * 6))
			ui.next({width = ui.fill(), height = ui.px(math.round(em * 0.7))})
			ui.progress("###bar", f32(l.percent / 100))
			ui.spacer(ui.px(em * 0.7))
			col := l.limited ? hex(HEX_RED) : l.percent >= USAGE_WARN_PERCENT ? hex(HEX_YELLOW) : hex(HEX_WEAK)
			text("p", fmt.tprintf("%.0f %%", l.percent), col, ui.Style_Mod{font = app.mono_bold, font_size = math.round(em * FS_SMALL)}, ui.px(em * 3.5))
			text("r", l.resets > now ? fmt.tprintf("resets in %s", duration_text(now, l.resets)) : "", hex(HEX_FAINT), ui.Style_Mod{font = app.mono, font_size = math.round(em * FS_CAPTION)}, ui.px(em * 9))
		}
	}
	if len(f.budgets) > 0 { section(app, "BUDGETS", em) }
	for b, i in f.budgets {
		ui.next({width = ui.fill(), height = ui.px(math.round(em * SETTINGS_ROW_H_EM)), axis = .X, cross = .Center})
		if ui.row(.Center, id = fmt.tprintf("###bud%d", i)) {
			text("n", b.scope != "" ? b.scope : "budget", hex(HEX_FACT_NAME), ui.Style_Mod{font = app.mono, font_size = math.round(em * FS_SMALL)}, ui.px(em * 6))
			t := b.limit > 0 ? f32(b.spent / b.limit) : 0
			ui.next({width = ui.fill(), height = ui.px(math.round(em * 0.7))})
			ui.progress("###bar", t)
			ui.spacer(ui.px(em * 0.7))
			text("p", fmt.tprintf("$%.2f / $%.0f", b.spent, b.limit), t >= BUDGET_WARN_SHARE ? hex(HEX_YELLOW) : hex(HEX_GREEN), ui.Style_Mod{font = app.mono_bold, font_size = math.round(em * FS_SMALL)}, ui.px(em * 8))
			text("r", b.resets > now ? fmt.tprintf("resets in %s", duration_text(now, b.resets)) : "", hex(HEX_FAINT), ui.Style_Mod{font = app.mono, font_size = math.round(em * FS_CAPTION)}, ui.px(em * 9))
		}
	}
}

saved_revoking :: proc(f: ^Server_Facts, id: string) -> bool {
	for r in f.revoking { if r == id { return true } }
	return false
}

// One DELETE: the second click of a double click finds it on its way. (Read again once it is gone: net.odin.)
saved_revoke :: proc(app: ^App, id: string) {
	f := &app.facts
	if saved_revoking(f, id) { return }
	append(&f.revoking, strings.clone(id))
	request(app, .Saved_Done, "DELETE", fmt.tprintf("/api/permission/saved/%s", id), tag = id)
}

// It went, or not: the button is back, and the list says which.
saved_revoke_done :: proc(app: ^App, id: string) {
	f := &app.facts
	for r, i in f.revoking {
		if r != id { continue }
		delete(r)
		ordered_remove(&f.revoking, i)
		break
	}
	facts_soon(app)
}

page_permissions :: proc(app: ^App, em: f32) {
	f := &app.facts
	info_line(app, "###ph", "Answers given with “Always”: the server applies them without asking again. Revoke one to be asked next time.", em)
	ui.spacer(ui.px(em * 0.6))
	if read_shown(app, "###sp_read", &f.reads[.Saved], em, server_facts_load) {
		if len(f.saved) == 0 { info_line(app, "###none", "No saved permission.", em, hex(HEX_FAINT)) }
		for &s, i in f.saved {
			ui.next({width = ui.fill(), height = ui.px(math.round(em * 2.4)), axis = .X, cross = .Center})
			if ui.row(.Center, id = fmt.tprintf("###sp%d", i)) {
				col := s.effect == "deny" ? hex(HEX_RED) : s.effect == "allow" ? hex(HEX_GREEN) : hex(HEX_YELLOW)
				pill("###e", s.effect != "" ? s.effect : "?", col)
				ui.spacer(ui.px(em * 0.5))
				text("a", s.action, hex(HEX_SETTING_NAME), ui.Style_Mod{font = app.mono_bold, font_size = math.round(em * FS_NOTE)})
				ui.spacer(ui.px(em * 0.5))
				text("r", s.resource, hex(HEX_WEAK), ui.Style_Mod{font = app.mono, font_size = math.round(em * FS_SMALL)}, ui.fill())
				if bevel_button("###rv", "Revoke", lucide.TRASH_2, .Danger, height = math.round(em * BUTTON_SMALL_H_EM), disabled = saved_revoking(f, s.id)).clicked { saved_revoke(app, s.id) }
			}
		}
	}
	section(app, "RULES OF THE AGENTS", em)
	for a in app.agents {
		info_line(app, fmt.tprintf("###ag_%s", a.id), fmt.tprintf("%s (%s): %s", a.name != "" ? a.name : a.id, a.mode, first_line(a.description)), em)
		ui.spacer(ui.px(em * 0.3))
	}
}

page_catalog :: proc(app: ^App, em: f32) {
	f := &app.facts
	list :: proc(app: ^App, title: string, items: []Named, em: f32, read: ^Remote = nil) {
		section(app, fmt.tprintf("%s (%d)", title, len(items)), em)
		if read != nil && !read_shown(app, fmt.tprintf("###%s_read", title), read, em, server_facts_load) { return }
		for it, i in items {
			ui.next({width = ui.fill(), height = ui.children_sum(), axis = .X})
			if ui.row(id = fmt.tprintf("###%s%d", title, i)) {
				text("n", it.name, hex(HEX_CATALOG_NAME), ui.Style_Mod{font = app.mono_bold, font_size = math.round(em * FS_SMALL), height = ui.px(em * 1.5)}, ui.px(em * 13))
				ui.next({width = ui.fill(), font_size = math.round(em * FS_SMALL), flags = {.Text_Wrap}, fg = hex(HEX_WEAK), text_pad = 0})
				ui.paragraph(fmt.tprintf("%s###d", label_safe(it.detail)))
			}
			ui.spacer(ui.px(em * 0.25))
		}
	}
	list(app, "PROVIDERS", f.providers[:], em, &f.reads[.Providers])
	models := make([]Named, len(app.models), context.temp_allocator)
	for m, i in app.models { models[i] = {m.name != "" ? m.name : m.id, fmt.tprintf("%s · %s context", m.provider, kfmt(m.ctx_len))} }
	list(app, "MODELS", models, em)
	agents := make([]Named, len(app.agents), context.temp_allocator)
	for a, i in app.agents { agents[i] = {a.name != "" ? a.name : a.id, fmt.tprintf("%s · %s", a.mode, first_line(a.description))} }
	list(app, "AGENTS", agents, em)
	list(app, "SKILLS", f.skills[:], em, &f.reads[.Skills])
	list(app, "COMMANDS", f.commands[:], em, &f.reads[.Commands])
}
