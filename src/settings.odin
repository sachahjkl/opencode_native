// Settings: the client's own preferences (the toolkit's typed registry, gt:config: named, bounded, documented, saved to
// %APPDATA%\opencode-native\prefs.txt, applied at once) and what the opencode server lets one see and change (its shell,
// its MCP servers, its saved permissions, its usage, its providers, agents, skills, commands, its configuration files).
package ocn

import "base:runtime"

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
import "gt:font"
import "gt:platform"
import i18n "gt:i18n"
import prefs_page "gt:prefs_page"
import "gt:ui"
import diff "gt:diff"
import lucide "gt:lucide"
import notices "gt:notices"
import remote "gt:remote"

////////////////////////////////
// The preferences

HEX_ROSE :: 0xf28ba8ff

// The bounds of the preferences (PREF_DEFS) that their sliders share.
COLUMN_W_MIN          :: 560
COLUMN_W_MAX          :: 1800
TOOL_LINES_MIN        :: 5
TOOL_LINES_MAX        :: 1000
PAGE_SIZE_MIN         :: 20
PAGE_SIZE_MAX         :: 200

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

PREF_DEFS := [?]config.Def{
	{name = "appearance.text.terminal_font", title = i18n.later("Terminal font"), description = i18n.later("The face of the shells: the client's own (automatic: Fira Mono, no ligatures), the system's usual monospace, or any installed family."), kind = .String, default = {s = ""}},
	{name = "appearance.content_zoom", title = i18n.later("Content zoom"), description = i18n.later("Zoom of the conversation alone, whatever the interface's: each session's until it has its own (Ctrl + = / - over it, Ctrl + wheel; Ctrl + 0 brings it back to this one)."), kind = .Float, default = {f = 1}, bounded = true, min = CONTENT_ZOOM_MIN, max = CONTENT_ZOOM_MAX},
	{name = "conversation.width", title = i18n.later("Width"), description = i18n.later("Widest the conversation column gets, in logical pixels."), kind = .Int, default = {i = 880}, bounded = true, min = COLUMN_W_MIN, max = COLUMN_W_MAX},
	{name = "conversation.reasoning", title = i18n.later("Reasoning"), description = i18n.later("How the model's reasoning shows: folded under a line, unfolded, or not at all."), kind = .String, default = {s = "collapsed"}, choices = {"collapsed", "expanded", "hidden"}, choice_labels = {i18n.later("Collapsed"), i18n.later("Expanded"), i18n.later("Hidden")}},
	{name = "conversation.expand_tools", title = i18n.later("Expand tools"), description = i18n.later("Tool calls open with their input and output shown."), kind = .Bool, default = {b = false}},
	{name = "conversation.diff_layout", description = "How a diff's full view shows it: old and new stacked, or side by side.", kind = .String, default = {s = "stacked"}, choices = {"stacked", "split"}, hidden = true},
	{name = "conversation.tool_lines", title = i18n.later("Tool lines"), description = i18n.later("Lines of a tool's output shown before the rest is counted."), kind = .Int, default = {i = 60}, bounded = true, min = TOOL_LINES_MIN, max = TOOL_LINES_MAX},
	{name = "conversation.page_size", title = i18n.later("Page size"), description = i18n.later("Messages read at a time (scrolling up reads the next page by itself)."), kind = .Int, default = {i = 80}, bounded = true, min = PAGE_SIZE_MIN, max = PAGE_SIZE_MAX},
	{name = "conversation.follow", title = i18n.later("Follow"), description = i18n.later("Follow new messages to the bottom while you are there."), kind = .Bool, default = {b = true}},
	{name = "conversation.prompt_rail", title = i18n.later("Prompt rail"), description = i18n.later("A rail beside the conversation with a dot for each of your prompts, the part in view a band over it: the pointer over a dot shows the prompt, a click goes to it at once. A filter at its top keeps the prompts that say what you type."), kind = .Bool, default = {b = true}},
	{name = "conversation.usage", title = i18n.later("Usage"), description = i18n.later("Tokens and cost under each answer."), kind = .Bool, default = {b = true}},
	{name = "conversation.while_running", title = i18n.later("While running"), description = i18n.later("What Enter does while a turn runs: steer the message into the turn (at its next step), or queue it for the end of the turn. Ctrl+Enter does the other. A message waiting in the list can be sent now: that stops what the agent is doing."), kind = .String, default = {s = "steer"}, choices = {"queue", "steer"}, choice_labels = {i18n.later("Queue"), i18n.later("Steer")}},
	{name = "conversation.image_viewer_size", title = i18n.later("Image viewer size"), description = i18n.later("The size of the image viewer, as a share of the most the window gives a picture. A picture opens no larger than its pixels; drag the viewer's edges or corners to make it larger or smaller."), kind = .Float, default = {f = 1}, bounded = true, min = VIEWER_SCALE_MIN, max = 1},
	{name = "conversation.clock", title = i18n.later("Clock"), description = i18n.later("Times of messages in 24-hour or 12-hour form."), kind = .String, default = {s = "24h"}, choices = {"24h", "12h"}},
	{name = "composer.send", title = i18n.later("Send"), description = i18n.later("The key that sends: Enter (Shift+Enter breaks the line) or Ctrl+Enter (Enter breaks the line)."), kind = .String, default = {s = "enter"}, choices = {"enter", "ctrl+enter"}, choice_labels = {i18n.later("Enter"), i18n.later("Ctrl+enter")}},
	{name = "sidebar.subagents", title = i18n.later("Subagents"), description = i18n.later("Sub-agent sessions: under their parent, in the list with the others, or not shown."), kind = .String, default = {s = "nested"}, choices = {"nested", "flat", "hidden"}, choice_labels = {i18n.later("Nested"), i18n.later("Flat"), i18n.later("Hidden")}},
	{name = "sidebar.mode", title = i18n.later("Mode"), description = i18n.later("What the sidebar shows: what needs you first across projects (what waits for you, what finished and you have not seen, what runs, the rest), or sessions by project."), kind = .String, default = {s = "inbox"}, choices = {"inbox", "projects"}, choice_labels = {i18n.later("Inbox"), i18n.later("Projects")}},
	{name = "notify.finished", title = i18n.later("Finished"), description = i18n.later("When a session that is not in front of you ends its run: nothing, a toast, a toast and the taskbar button flashing, or a notification of the system (a click on it opens the session)."), kind = .String, default = {s = "system"}, choices = {"off", "toast", "flash", "system"}, choice_labels = {i18n.later("Off"), i18n.later("Toast"), i18n.later("Flash"), i18n.later("System")}},
	{name = "permission.new_sessions", title = i18n.later("New sessions"), description = i18n.later("The approvals a session made here starts with, set on the server (the composer's shield changes them for one session): the server's configured rules, file edits allowed, everything allowed (a policy's deny stays), or every action asked."), kind = .String, default = {s = "configured"}, choices = {"configured", "allow_edits", "allow_all", "ask_all"}, choice_labels = {i18n.later("Configured"), i18n.later("Allow edits"), i18n.later("Allow all"), i18n.later("Ask all")}},
	{name = "notify.permission", title = i18n.later("Permission"), description = i18n.later("When a session asks for a permission or a question and the window is not in front: the taskbar button flashes, and with notifications of the system, one says it."), kind = .Bool, default = {b = true}},
	{name = "notices.badge", title = i18n.later("Badge"), description = i18n.later("The count of what you missed on the bell of the title bar: runs that ended, questions and permissions that wait, commands, scheduled runs and sub-agents that ended."), kind = .Bool, default = {b = true}},
	{name = "notices.keep", title = i18n.later("Keep"), description = i18n.later("How many entries that you acknowledged \"What you missed\" keeps in its history. What is not acknowledged yet always stays."), kind = .Int, default = {i = notices.CAP}, bounded = true, min = NOTICES_KEEP_MIN, max = NOTICES_KEEP_MAX},
	{name = "appearance.throbber", title = i18n.later("Throbber"), description = i18n.later("What says that a run goes on: a board that spells what the agent does, dots in orbit, the scanner, or nothing."), kind = .String, default = {s = "board"}, choices = {"board", "orbit", "scanner", "none"}, choice_labels = {i18n.later("Board"), i18n.later("Orbit"), i18n.later("Scanner"), i18n.later("None")}},
	{name = "session.agent", description = "The agent a new session starts with: the one chosen last.", kind = .String, default = {s = ""}, hidden = true},
	{name = "session.model", description = "The model a new session starts with: the one chosen last.", kind = .String, default = {s = ""}, hidden = true},
	{name = "session.provider", description = "The provider of that model.", kind = .String, default = {s = ""}, hidden = true},
	{name = "session.variant", description = "How hard that model thinks (one of its variants; empty: its default).", kind = .String, default = {s = ""}, hidden = true},
	{name = "browser.tools", title = i18n.later("Tools"), description = i18n.later("Let the agents drive the Preview panel (open pages, read them, click, run scripts): the browser tools, while this window is open."), kind = .Bool, default = {b = true}},
	{name = "layout.dock", description = "Where the panels are, as the dock writes it.", kind = .String, default = {s = ""}, hidden = true},
	{name = "layout.dialogs", description = "The sizes the dialogs were given (settings, statistics, shortcuts), in ems.", kind = .String, default = {s = ""}, hidden = true},
	{name = "window.placement", description = "Where the window was (platform.placement_text): it opens there again.", kind = .String, default = {s = ""}, hidden = true},
	{name = "general.start", title = i18n.later("Start"), description = i18n.later("What the window opens on: the home page, or the session it showed when it closed (the latest one if it showed none yet)."), kind = .String, default = {s = "last"}, choices = {"home", "last"}, choice_labels = {i18n.later("Home"), i18n.later("Last")}},
	{name = "advanced.experimental", title = i18n.later("Experimental"), description = i18n.later("Turn on the experimental options of a server on this computer, in its configuration file. What you set there yourself stays."), kind = .Bool, default = {b = true}},
	{name = "advanced.fps", title = i18n.later("FPS"), description = i18n.later("The frame rate and what a frame costs, in the status bar."), kind = .Bool, default = {b = false}},
	{name = "advanced.frame_rate", title = i18n.later("Frame rate"), description = i18n.later("The most frames a second, when there is something to draw (nothing moving, nothing is drawn): what the screen takes, a number, or no limit. Above the screen's rate it shows the newest of them: not smoother, but quicker to answer, for more power. What you type and click is read at once whatever this says."), kind = .String, default = {s = "screen"}, choices = {"screen", "30", "60", "120", "240", "uncapped"}, choice_labels = {i18n.later("Screen"), "30", "60", "120", "240", i18n.later("Uncapped")}},
}

// The preferences as plain values (read on every frame: no lookups by name there).
Prefs :: struct {
	accent_hex:   u32,
	finish:       ui.Finish,   // appearance.finish
	mode:         string,  // appearance.mode: system, dark, light (the preference's own text: not owned)
	font_size:    f32,
	zoom:         f32,
	glow:         bool,   // appearance.glow above 0, in a finish with halos
	autohide_scrollbars: bool,   // scrolling.autohide_scrollbars: the detached windows' states take it too
	column_w:     f32,
	reasoning:    string,
	expand_tools: bool,
	tool_lines:   int,
	page_size:    int,
	follow:       bool,
	prompt_rail:  bool,   // conversation.prompt_rail (prompt_rail.odin)
	usage:        bool,
	clock24:      bool,
	ctrl_enter:   bool,
	steer_first:  bool,   // while a turn runs, Enter sends into it (conversation.while_running)
	subagents:    string,
	sidebar_mode: Sidebar_Mode,
	diff_layout:  diff.Layout,
	notify:       string,
	notify_perm:  bool,
	notices_badge: bool,  // notices.badge: the bell's count
	notices_keep: int,    // notices.keep: the history of "What you missed"
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
	system_title: bool,    // window.system_title (title_apply)
	new_sessions: Approval,   // permission.new_sessions: the preset a session made here starts with
}

CONTENT_ZOOM_MIN :: 0.5
CONTENT_ZOOM_MAX :: 3

// The program's texts in other languages (English is the code's own), beside the toolkit's: tools/ocntools `i18n fr`
// writes the catalogue from the tr calls.
PROGRAM_CATALOGUES :: []i18n.Catalog{{"fr", #load("../i18n/fr.txt", string)}}

prefs_path :: proc() -> string { return pjoin({filepath.dir(settings_path()), "prefs.txt"}) }

// The toolkit's common settings (the look, the text, scrolling, input, delays, rendering, updates, the session), then
// this program's own.
prefs_register :: proc(p: ^config.Prefs) {
	d := prefs_page.STANDARD_DEFAULTS
	d.theme, d.app_name, d.update_channel = "OpenCode", APP_NAME, "stable"
	d.values = STANDARD_VALUES[:]
	prefs_page.standard_register(p, prefs_page.STANDARD_ALL, d)
	config.register(p, PREF_DEFS[:])
	// (the titles the settings page made from the names, said here so that they are translated; order 0: their places stay)
	for g in PREF_GROUPS { config.title_register(p, g[0], g[1]) }
}

// This program's own defaults of standard settings: the messages at the top right (at the bottom they hid the send
// button: views.odin set_toast_area), each frame repainting only what changed.
STANDARD_VALUES := [?]prefs_page.Standard_Value{{"window.toast_position", "top_right"}, {"rendering.partial_redraw", "true"}}

PREF_GROUPS := [?][2]string{
	{"conversation", i18n.later("Conversation")}, {"composer", i18n.later("Composer")}, {"sidebar", i18n.later("Sidebar")},
	{"notify", i18n.later("Notify")}, {"notices", i18n.later("Notices")}, {"permission", i18n.later("Permission")},
	{"browser", i18n.later("Browser")}, {"advanced", i18n.later("Advanced")},
}

// `file` "": the defaults, nothing read or saved (a test).
prefs_init :: proc(app: ^App, file: string) {
	app.cfg_prefs = config.prefs_make()
	prefs_register(&app.cfg_prefs)
	app.prefs_file = strings.clone(file)
	themes_init(app)
	if file != "" {
		config.load_file(&app.cfg_prefs, file, .User)
		config.user_writer_start(&app.prefs_writer, &app.cfg_prefs, file)
	}
	for spec in app.cli.prefs {   // --pref name=value (a value out of range or unknown: the preference keeps its own)
		if eq := strings.index_byte(spec, '='); eq > 0 { config.set_from_string(&app.cfg_prefs, spec[:eq], spec[eq + 1:], .Command_Line) }
	}
	// the language, once general.language is read (the file and --pref) and before any text is shown; not in a test (no
	// file): its texts are the English keys, whatever the system's language
	if file != "" { prefs_page.language_start(&app.cfg_prefs, PROGRAM_CATALOGUES) }
	// the toolkit's settings applied to it now, then each one as it changes (config.watch): its zoom, density, rounding,
	// motion, scrolling, delays, text rendering
	targets := prefs_page.Standard_Targets{}
	if app.win != nil { targets = {renderer = &app.r, fonts = &app.fonts, partial_redraw = &app.window.partial_redraw} }
	prefs_page.standard_watch(&app.standard, &app.cfg_prefs, &app.state, targets)
	prefs_refresh(app)
}

// The plain values from the registry, and what follows from them (theme, zoom, density, rounding).
prefs_refresh :: proc(app: ^App) {
	p := &app.cfg_prefs
	s := &app.prefs
	look := prefs_page.appearance_read(p, context.temp_allocator)
	s.finish = look.finish
	s.mode = config.string_of(p, prefs_page.MODE_PREF)
	theme_set(app, theme_index(app, look.theme), theme_wants_light(s.mode))
	theme_windows(app)
	s.accent_hex = themed(HEX_PEACH)
	s.font_size = look.font_size
	s.zoom = f32(config.float_of(p, "appearance.zoom"))
	s.glow = look.glow > 0 && look.finish != .Flat   // (no halos in the flat finish)
	s.autohide_scrollbars = config.bool_of(p, "scrolling.autohide_scrollbars")
	s.column_w = f32(config.int_of(p, "conversation.width"))
	s.reasoning = config.string_of(p, "conversation.reasoning")
	s.expand_tools = config.bool_of(p, "conversation.expand_tools")
	s.tool_lines = int(config.int_of(p, "conversation.tool_lines"))
	s.page_size = int(config.int_of(p, "conversation.page_size"))
	s.follow = config.bool_of(p, "conversation.follow")
	s.prompt_rail = config.bool_of(p, "conversation.prompt_rail")
	s.usage = config.bool_of(p, "conversation.usage")
	s.clock24 = config.string_of(p, "conversation.clock") == "24h"
	s.ctrl_enter = config.string_of(p, "composer.send") == "ctrl+enter"
	s.steer_first = config.string_of(p, "conversation.while_running") == "steer"
	s.subagents = config.string_of(p, "sidebar.subagents")
	s.sidebar_mode = sidebar_mode_of(config.string_of(p, "sidebar.mode"))
	s.diff_layout = diff_layout_of(config.string_of(p, "conversation.diff_layout"))
	s.notify = config.string_of(p, "notify.finished")
	s.notify_perm = config.bool_of(p, "notify.permission")
	s.notices_badge = config.bool_of(p, "notices.badge")
	s.notices_keep = int(config.int_of(p, "notices.keep"))
	if app.missed.opened { app.missed.log.cap = s.notices_keep }   // (the history past it goes at the next entry)
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
	s.system_title = config.bool_of(p, "window.system_title")
	app.announcer.mode = prefs_page.announce_mode(p)
	s.new_sessions = approval_of_pref(config.string_of(p, "permission.new_sessions"))
	update_channel_follow(app)
	title_apply(app)

	// the faces, when either preference changed (a family is opened once: the font state keeps it)
	if wanted := fmt.tprintf("%s\n%s\n%s\n%s", config.string_of(p, "appearance.text.ui_font"), config.string_of(p, "appearance.text.mono_font"), config.string_of(p, "appearance.text.prose_font"), config.string_of(p, "appearance.text.terminal_font")); wanted != app.fonts_wanted {
		fonts_apply(app)
	}

	theme_refresh(&app.theme)
	terms_recolour(app)
}

// The window's title bar: the program's, or the system's when asked and the system can draw it (not on GNOME: there the
// program's always). Its buttons follow (ui.window_buttons draws none under the system's).
title_apply :: proc(app: ^App) {
	if app.win == nil { return }
	platform.set_integrated_title(app.win, !(app.prefs.system_title && platform.system_title_available(app.win)))
}

// Sets a preference from its text and applies it (the loop's writer saves it: main_after_frame).
pref_set :: proc(app: ^App, name, value: string) {
	if err := config.set_from_string(&app.cfg_prefs, name, value, .User); err != nil {
		ui.announce(&app.announcer, .Bad, fmt.tprintf("%s: %s", name, config.set_error_text(err)))
		return
	}
	prefs_refresh(app)
}

// Sets a number preference to `v` at 3 decimals (the file shows 1.1, not the float's noise) and applies it.
pref_set_float :: proc(app: ^App, name: string, v: f32) {
	if err := config.set_float(&app.cfg_prefs, name, math.round(f64(v) * 1000) / 1000); err != nil {
		ui.announce(&app.announcer, .Bad, fmt.tprintf("%s: %s", name, config.set_error_text(err)))
		return
	}
	prefs_refresh(app)
}

// The accent colour (buttons, selection, lamps of attention): the theme's, as every colour of hex (prefs_refresh sets the theme).
accent :: proc() -> Color { return hex(HEX_PEACH) }

// Ctrl + wheel changed the zoom: keep it.
prefs_track_zoom :: proc(app: ^App) {
	z := ui.zoom(&app.state)
	if abs(z - app.prefs.zoom) > ZOOM_EPSILON {
		app.prefs.zoom = z
		config.set_float(&app.cfg_prefs, "appearance.zoom", math.round(f64(z) * 1000) / 1000)
		}
}

// Whether the system asks for motion (Build_Params.animations): the user's word on it (appearance.animations) is the
// toolkit's, over it (ui.set_animations, by standard_watch).
animations_on :: proc(app: ^App) -> bool {
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

// A run ended in the session `sid`: told when it is not the one in front of the user. `key`: its entry of what was missed
// (missed.odin; "": none), which keeps the notification of the system and closes it once acknowledged.
notify_finished :: proc(app: ^App, key, sid, outcome: string) {
	mode := app.prefs.notify
	if mode == "off" { return }
	front := window_in_front(app)
	if sid == app.chat.id && front { return }
	if find_child(&app.chat, sid) != nil && front { return }   // (its card and the strip say it)
	word := outcome == "failed" ? i18n.tr("Failed") : outcome == "interrupted" ? i18n.tr("Stopped") : i18n.tr("Done")
	// (in front, the toast says it: a notification of the system is for a window you are not looking at)
	if mode == "system" && !front && notify_system(app, key, sid, word, "") { return }
	kind: ui.Toast_Kind = outcome == "failed" ? .Bad : outcome == "interrupted" ? .Warn : .Good
	toast_session(app, kind, sid, word, "")
	if mode != "toast" && !front { flash_taskbar(app) }
}

// A session waits for you (a permission, a question) while the window is not in front: `what` and `detail` (what it asks).
// `key`: the wait's entry of what was missed: its answer closes the notification.
notify_waiting :: proc(app: ^App, key, sid, what, detail: string) {
	if !app.prefs.notify_perm || window_in_front(app) { return }
	flash_taskbar(app)
	if app.prefs.notify != "system" { return }
	notify_system(app, key, sid, what, detail)
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

// The sessions that the toasts shown are about: a click on one opens its session. (A notification of the system is an entry's
// of what was missed: missed.odin.)
Notices :: struct {
	toast_targets: [TOAST_TARGETS]string,   // the sessions a click on a toast opens, a ring (owned: toast_session)
	toast_next:    int,
}

toast_session :: proc(app: ^App, kind: ui.Toast_Kind, sid, what, detail: string) {
	body := detail != "" ? fmt.tprintf("%s: %s", what, detail) : what
	title := session_title_of(app, sid)
	if sid == "" { ui.announce(&app.announcer, kind, title, body); return }
	k := app.notices.toast_next
	app.notices.toast_next = (k + 1) % TOAST_TARGETS
	delete(app.notices.toast_targets[k])
	app.notices.toast_targets[k] = strings.clone(sid)
	ui.announce(&app.announcer, kind, title, body, action = proc(user: rawptr) {
		app := the_app
		sid := app.notices.toast_targets[int(uintptr(user))]
		if sid != "" && sid != app.chat.id { open_root(app, sid) }
	}, user = rawptr(uintptr(k)))
}

// A notification of the system: the session's title, what happened and what it is about. It is the entry `key`'s (missed.odin):
// a second one replaces the first, acknowledging the entry closes it, a click on it brings the window and opens the session
// (main_input). Without an entry (the session shown, the window behind), a click brings the window. False: the system shows none.
@(private = "file")
// (Sent without a wait: D-Bus answers at a next turn of the window's loop. A server that then refuses it: the toast says it.)
notify_system :: proc(app: ^App, key, sid, what, detail: string) -> bool {
	if app.win == nil { return false }
	body := detail != "" ? fmt.tprintf("%s: %s", what, detail) : what
	h := runtime.heap_allocator()
	n := new(Notify_Sent, h)
	n^ = {app = app, key = strings.clone(key, h), sid = strings.clone(sid, h), what = strings.clone(what, h)}
	sent := platform.notify_async(app.win, {title = session_title_of(app, sid), body = body, replace = missed_system_of(app, key)}, proc(user: rawptr, id: platform.Notification_Id, ok: bool) {
		n := (^Notify_Sent)(user)
		if ok { missed_system_set(n.app, n.key, id) } else { toast_session(n.app, .Info, n.sid, n.what, "") }
		notify_sent_free(n)
	}, n)
	if !sent { notify_sent_free(n) }
	return sent
}

@(private = "file")
Notify_Sent :: struct { app: ^App, key, sid, what: string }

@(private = "file")
notify_sent_free :: proc(n: ^Notify_Sent) {
	h := runtime.heap_allocator()
	delete(n.key, h); delete(n.sid, h); delete(n.what, h)
	free(n, h)
}

// What a notification of the system came back with: a click opens its session, in front; closed, its entry no longer has it.
notify_event :: proc(app: ^App, e: platform.Event) {
	#partial switch e.kind {
	case .Notification_Click, .Notification_Action:
		missed_notification_click(app, e.notification.id)
	case .Notification_Closed:
		missed_notification_closed(app, e.notification.id)
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
	reads:     [Fact]remote.Remote,
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
		remote.reset(&f.reads[k])
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
		remote.begin(&f.reads[k])
		request(app, FACT_READS[k].kind, "GET", FACT_READS[k].path, reading = &f.reads[k])
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
	ui.announce(&app.announcer, .Good, i18n.tr("Shell set"))
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
	for d in DIALOGS_SIZED { fmt.sbprintf(&b, "%.1fx%.1f ", cx.dialogs[d].x, cx.dialogs[d].y) }
	pref_set(app, "layout.dialogs", strings.trim_space(strings.to_string(b)))
}

// The options of a dialog that the person resizes: its preferred and smallest sizes, and the size kept (layout.dialogs).
dialog_options :: proc(app: ^App, d: Dialog, top: Maybe(f32) = nil) -> ui.Modal_Options {
	return {
		width_em = DIALOG_PREFERRED_EM[d].x, height_em = DIALOG_PREFERRED_EM[d].y,
		min_width_em = DIALOG_MIN_EM[d].x, min_height_em = DIALOG_MIN_EM[d].y,
		size = &app.cx.dialogs[d], top = top,
	}
}

////////////////////////////////
// The dialog

// The settings dialog: its pages (prefs_page: the client's preferences, from the registry, and the server's pages).
Settings_View :: struct {
	prefs:        prefs_page.Page,
	show_licence: bool,   // Ghostty's
}

// The pages of the settings, in their order. The client's preferences first: the toolkit's groups and this program's
// (Behaviour and Advanced gather small groups of its own by name). Then what the opencode server shows: pages of this
// program's own, which the search does not look in. A category names its page (settings_open_on, --settings=<page>).
SETTINGS_PAGES := [?]prefs_page.Page_Info{
	{category = "general", title = i18n.later("General"), icon = lucide.SETTINGS, heading = i18n.later("CLIENT")},
	{category = "appearance", title = i18n.later("Appearance"), icon = lucide.PALETTE},
	{category = "window", title = i18n.later("Window"), icon = lucide.APP_WINDOW},
	{category = "conversation", title = i18n.later("Conversation"), icon = lucide.MESSAGE_SQUARE},
	{category = "behaviour", title = i18n.later("Behaviour"), icon = lucide.BELL, names = {"composer.send", "sidebar.mode", "sidebar.subagents", "notify.finished", "permission.new_sessions", "notify.permission", "notices.badge", "notices.keep"}},
	{category = "scrolling", title = i18n.later("Scrolling"), icon = lucide.SCROLL},
	{category = "input", title = i18n.later("Input"), icon = lucide.KEYBOARD},
	{category = "timing", title = i18n.later("Delays and menus"), icon = lucide.TIMER},
	{category = "update", title = i18n.later("Updates"), icon = lucide.REFRESH_CW},
	{category = "rendering", title = i18n.later("Rendering"), icon = lucide.MONITOR},
	{category = "advanced", title = i18n.later("Advanced"), icon = lucide.WRENCH, names = {"browser.tools", "advanced.experimental", "advanced.fps", "advanced.frame_rate"}},
	{category = "server", title = i18n.later("Server & shell"), icon = lucide.SQUARE_TERMINAL, heading = "OPENCODE", build = proc(user: rawptr, em: f32) { page_server((^App)(user), em) }},
	{category = "connections", title = i18n.later("Connections"), icon = lucide.USER, build = proc(user: rawptr, em: f32) { page_connections((^App)(user), em) }},
	{category = "mcp", title = i18n.later("MCP servers"), icon = lucide.PLUG, build = proc(user: rawptr, em: f32) { page_mcp((^App)(user), em) }},
	{category = "plugins", title = i18n.later("Plugins"), icon = lucide.ZAP, build = proc(user: rawptr, em: f32) { page_plugins((^App)(user), em) }},
	{category = "usage", title = i18n.later("Usage & limits"), icon = lucide.GAUGE, build = proc(user: rawptr, em: f32) { page_usage((^App)(user), em) }},
	{category = "permissions", title = i18n.later("Permissions"), icon = lucide.SHIELD, build = proc(user: rawptr, em: f32) { page_permissions((^App)(user), em) }},
	{category = "catalog", title = i18n.later("Providers & skills"), icon = lucide.LIST, build = proc(user: rawptr, em: f32) { page_catalog((^App)(user), em) }},
}

// The channels this program's releases come on (update.channel: the toolkit's, a free text without them).
@(private = "file") UPDATE_CHANNELS       := [?]string{"stable", "beta"}
@(private = "file") UPDATE_CHANNEL_LABELS := [?]string{i18n.later("Stable"), i18n.later("Beta")}

// The font preferences: their control is this program's (font_button: its faces, the installed families).
@(private = "file")
FONT_PREFS := [?]string{"appearance.text.ui_font", "appearance.text.prose_font", "appearance.text.mono_font", "appearance.text.terminal_font"}

settings_open :: proc(app: ^App) {
	app.cx.open[.Settings] = true
	prefs_page.focus_search(&app.settings.prefs)
	server_facts_load(app)
}

// The settings open on the page `category` (its Page_Info.category), as a click on it in the sidebar shows it.
settings_open_on :: proc(app: ^App, category: string) {
	p := &app.settings.prefs
	delete(p.current)
	p.current = strings.clone(category)
	ui.line_edit_set(&p.query, "")   // (a search would hide the page)
	settings_open(app)
}

// What the client's settings page is given (prefs_page.Page_Options).
settings_options :: proc(app: ^App) -> prefs_page.Page_Options {
	return {
		user = app,
		changed = proc(user: rawptr, _: string) { prefs_refresh((^App)(user)) },   // (main_after_frame's writer saves)
		pages = SETTINGS_PAGES[:],   // (in English: the toolkit's page translates their titles and headings)
		icon_font = app.icons, search_icon = lucide.SEARCH, reset_icon = lucide.ROTATE_CCW,
		file = app.prefs_file,
		version = fmt.tprintf("%s %s", APP_NAME, APP_VERSION),
		themes = themes(app), themes_light = app.cx.theme.light,
		themes_file = app.cx.theme.file.path != "" ? &app.cx.theme.file : nil,
		choices = proc(_: rawptr, name: string) -> (labels, values: []string) {
			if name == "update.channel" { return UPDATE_CHANNEL_LABELS[:], UPDATE_CHANNELS[:] }   // (English: prefs_page translates where it shows)
			return nil, nil
		},
		custom_names = FONT_PREFS[:],
		custom = proc(user: rawptr, name: string, em: f32) { font_button((^App)(user), name, em) },
		page_foot = settings_page_foot,
	}
}

settings_dialog :: proc(app: ^App, em: f32) {
	if ui.modal("settings", &app.cx.open[.Settings], dialog_options(app, .Settings)) {
		dialog_backdrop()
		if ui.dialog_header("settings_head", i18n.tr("Settings"), {close = true}) {}
		// one sidebar for every page: the toolkit's page holds the client's preferences and the server's pages alike
		ui.next({width = ui.fill(), height = ui.fill()})
		prefs_page.build(&app.settings.prefs, &app.cfg_prefs, settings_options(app))
	}
}

// Under a page's preferences: what is not a setting (the updates' state and buttons; the folder, the program, the
// terminal's licence; where Setup is).
@(private = "file")
settings_page_foot :: proc(user: rawptr, category: string, em: f32) {
	app := (^App)(user)
	switch category {
	case "behaviour":
		ui.spacer(ui.px(em * 0.6))
		info_line(app, "###hint_setup", i18n.tr(SETUP_HINT), em)
	case "update":
		u := &app.updater
		state := i18n.tr("Up to date, as far as is known")
		switch _ in u.state {
		case nil:
			if u.result != "" { state = u.result }
		case Update_Checking:    state = i18n.tr("Looking for a new version…")
		case Update_Ready:       state = fmt.tprintf(i18n.tr("Version %s is available"), update_version(u))
		case Update_Downloading: state = fmt.tprintf(i18n.tr("Downloading %s…"), update_version(u))
		case Update_Installed:   state = fmt.tprintf(i18n.tr("Version %s is installed: restart to use it"), update_version(u))
		}
		ui.spacer(ui.px(em * 0.6))
		ui.next({width = ui.fill(), height = ui.children_sum(), axis = .Y})
		if ui.well("###upd") {
			ui.spacer(ui.px(em * 0.4))
			fact("###u1", "version", APP_VERSION, em)
			fact("###u2", "channel", app.prefs.update_channel, em)
			fact("###u3", i18n.tr("state"), state, em)
			ui.spacer(ui.px(em * 0.4))
		}
		ui.spacer(ui.px(em * 0.7))
		ui.next({width = ui.fill(), height = ui.children_sum(), axis = .X, cross = .Center})
		if ui.row(.Center, id = "###upd_b") {
			if ui.button("u_check", i18n.tr("Check now"), lucide.REFRESH_CW, {disabled = update_is_downloading(u)}).clicked { update_check(app, true) }
			ui.spacer(ui.px(em * 0.5))
			if update_is_ready(u) {
				if ui.button("u_inst", ui.text_shown(fmt.tprintf(i18n.tr("Install %s"), update_version(u))), lucide.CHECK, {intent = .Success}).clicked { update_install(app) }
			}
			if update_is_installed(u) {
				if ui.button("u_rest", i18n.tr("Restart now"), lucide.REFRESH_CW, {intent = .Success}).clicked { app_restart(app) }
			}
		}
		ui.spacer(ui.px(em * 0.6))
		info_line(app, "###hint_sig", i18n.tr("Only what is signed with the key built into this program is installed: the channel, the version and the file's checksum are all in the signature."), em)
	case "advanced":
		ui.spacer(ui.px(em * 0.6))
		info_line(app, "###adv_about", fmt.tprintf(i18n.tr("%s %s, a client of the OpenCode server. %s"), APP_NAME, APP_VERSION, i18n.tr(APP_NOT_THEIRS)), em)
		licence_section(app, em)
		ui.spacer(ui.px(em * 0.7))
		ui.next({width = ui.fill(), height = ui.children_sum(), axis = .X, cross = .Center})
		if ui.row(.Center, id = "###adv_b") {
			if ui.button("adv_dir", i18n.tr("Open the settings folder"), lucide.FOLDER).clicked { ui.open(filepath.dir(prefs_path())) }
			ui.spacer(ui.px(em * 0.4))
			if ui.button("adv_lic", ui.text_shown(app.settings.show_licence ? i18n.tr("Hide the terminal's licence") : i18n.tr("The terminal's licence")), o = {face = .Ghost}).clicked { app.settings.show_licence = !app.settings.show_licence }
		}
		if app.settings.show_licence {
			ui.spacer(ui.px(em * 0.5))
			info_line(app, "###adv_lic_say", i18n.tr("The terminal's emulation is Ghostty's, through libghostty-vt."), em)
			ui.spacer(ui.px(em * 0.3))
			code_block("###adv_lic_text", "text", GHOSTTY_LICENSE, app.mono, version = 1)
		}
	}
}

// The button of a font preference (its face) and its picker: Automatic (the client's own), the other choice, then the
// installed families, matched as one types.
font_button :: proc(app: ^App, name: string, em: f32) {
	term := name == "appearance.text.terminal_font"
	mono := name == "appearance.text.mono_font" || term
	prose := name == "appearance.text.prose_font"
	want := config.string_of(&app.cfg_prefs, name)
	face := term ? app.term_face : mono ? app.mono_face : prose ? app.prose_face : app.ui_face
	own := term ? "Fira Mono" : mono ? "DM Mono" : prose ? "Newsreader" : "Hanken Grotesk"
	second := prose ? FONT_SAME : FONT_SYSTEM
	// the button names the face in use; a faint word before it says how it was chosen
	mode, shown: string
	switch want {
	case "", FONT_BUILTIN: mode, shown = i18n.tr("auto"), own
	case FONT_SYSTEM:      mode, shown = i18n.tr("system"), face != "" ? face : own
	case FONT_SAME:        mode, shown = i18n.tr("same"), app.ui_face != "" ? app.ui_face : "Hanken Grotesk"
	case:                  mode, shown = face == want ? "" : i18n.tr("not installed"), want
	}
	if mode != "" {
		text("fm", mode, hex(HEX_FAINT), ui.Style_Mod{font_size = math.round(em * FS_SMALL), height = ui.px(em * 1.5)})
		ui.spacer(ui.px(em * 0.5))
	}
	sig := ui.button(fmt.tprintf("fb_%s", name), ui.text_shown(shown), o = {width = ui.px(em * 13)})
	if sig.clicked {
		if app.cx.open[.Picker] && app.picker.id == name { app.cx.open[.Picker] = false } else { picker_open(app, name, sig.box.rect) }
	}
	if !(app.cx.open[.Picker] && app.picker.id == name) { return }
	if app.font_families == nil { app.font_families = font.system_families(&app.fonts) }
	items := make([dynamic]Pick_Item, context.temp_allocator)
	append(&items, Pick_Item{label = i18n.tr("Automatic"), detail = fmt.tprintf(i18n.tr("%s, built in"), own), current = want == "" || want == FONT_BUILTIN})
	append(&items, Pick_Item{label = prose ? i18n.tr("As the interface") : i18n.tr("System"), detail = prose ? i18n.tr("the interface's face") : i18n.tr("the system's usual face"), current = want == second})
	for fam in app.font_families { append(&items, Pick_Item{label = fam, current = fam == want}) }
	if k := picker(app, &app.picker, name, mono ? i18n.tr("Search code fonts") : i18n.tr("Search fonts"), items[:], em, align_right = true); k >= 0 {
		switch k {
		case 0: pref_set(app, name, "")
		case 1: pref_set(app, name, second)
		case:   pref_set(app, name, app.font_families[k - 2])
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
	section(app, i18n.tr("SERVER"), em)
	ui.next({width = ui.fill(), height = ui.children_sum(), axis = .Y})
	if ui.well("###srv") {
		ui.spacer(ui.px(em * 0.4))
		fact("###s1", i18n.tr("address"), server_base(app), em)
		fact("###s2", i18n.tr("status"), online(app) ? i18n.tr("connected") : i18n.tr("not connected"), em, online(app) ? hex(HEX_GREEN) : hex(HEX_YELLOW))
		fact("###s3", i18n.tr("version"), app.server_version != "" ? app.server_version : "?", em)
		fact("###s0", i18n.tr("name"), i18n.tr(server_name(app)), em)
		fact("###s4", i18n.tr("auth"), app.servers[app.server].password == "" ? i18n.tr("none") : app.servers[app.server].local ? i18n.tr("Basic (password from service.json)") : "Basic", em)
		fact("###s5", i18n.tr("sessions"), fmt.tprintf(i18n.tr("%d loaded · %d running"), len(app.sessions), len(app.busy)), em)
		fact("###s6", i18n.tr("client"), fmt.tprintf("opencode native %s", APP_VERSION), em)
		ui.spacer(ui.px(em * 0.4))
	}
	section(app, i18n.tr("SHELL"), em)
	info_line(app, "###shh", i18n.tr("The shell the agents run their commands in (written to the configuration's \"shell\")."), em)
	ui.spacer(ui.px(em * 0.4))
	if read_shown(app, "###sh_read", &f.reads[.Shells], em, server_facts_load) {
		sel := -1
		for s, i in f.shells { if f.shell != "" && desktop.same_path(s.path, f.shell) { sel = i } }
		for s, i in f.shells {
			ui.next({width = ui.fill(), height = ui.px(math.round(em * SETTINGS_ROW_H_EM)), axis = .X, cross = .Center})
			if ui.row(.Center, id = fmt.tprintf("###sh%d", i)) {
				if ui.button(fmt.tprintf("shb%d", i), ui.text_shown(s.name), lucide.SQUARE_TERMINAL, {face = sel == i ? .Toggled : .Raised, width = ui.px(em * 9), height = math.round(em * BUTTON_COMPACT_H_EM), disabled = !s.ok}).clicked { shell_set(app, s) }
				ui.spacer(ui.px(em * 0.7))
				text("p", s.path, hex(HEX_FAINT), ui.Style_Mod{font = app.mono, font_size = math.round(em * FS_CAPTION)}, ui.fill())
			}
			ui.spacer(ui.px(em * 0.25))
		}
		if sel < 0 { info_line(app, "###shd", i18n.tr("None set: the server picks one."), em, hex(HEX_FAINT)) }
	}
	section(app, i18n.tr("CONFIGURATION FILES"), em)
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
				if ui.button("open", i18n.tr("Open"), lucide.FILE, {height = math.round(em * BUTTON_SMALL_H_EM)}).clicked { ui.open(c.path) }
				ui.spacer(ui.px(em * 0.3))
				if ui.button("dir", icon = lucide.FOLDER, o = {face = .Raised, height = math.round(em * BUTTON_SMALL_H_EM)}).clicked { ui.open(filepath.dir(c.path)) }
			}
		}
		ui.spacer(ui.px(em * 0.4))
	}
	if len(f.files) == 0 { info_line(app, "###nocf", i18n.tr("No configuration file (the defaults apply)."), em, hex(HEX_FAINT)) }
}

page_mcp :: proc(app: ^App, em: f32) {
	f := &app.facts
	info_line(app, "###mh", i18n.tr("Model Context Protocol servers give the agents more tools. Connecting or disconnecting one applies to the server now."), em)
	ui.spacer(ui.px(em * 0.6))
	if !read_shown(app, "###mcp_read", &f.reads[.Mcp], em, server_facts_load) { return }
	if len(f.mcp) == 0 {
		info_line(app, "###none", i18n.tr("No MCP server is configured."), em, hex(HEX_FAINT))
		return
	}
	for &m, i in f.mcp {
		connected := m.status == .Connected
		going := mcp_going(f, m.name)
		col := connected ? hex(HEX_GREEN) : m.status == .Failed || m.error != "" ? hex(HEX_RED) : hex(HEX_FAINT)
		word := going != nil ? (going.connecting ? i18n.tr("connecting…") : i18n.tr("disconnecting…")) : m.word != "" ? m.word : "?"
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
						if ui.button("dc", i18n.tr("Disconnect"), o = {intent = .Danger, height = math.round(em * BUTTON_SMALL_H_EM)}).clicked { mcp_switch(app, m.name, false) }
					} else {
						if ui.button("co", i18n.tr("Connect"), o = {intent = .Success, height = math.round(em * BUTTON_SMALL_H_EM)}).clicked { mcp_switch(app, m.name, true) }
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
		info_line(app, "###none", i18n.tr("The server reports no usage limit (a provider of your own, or no OpenCode workspace)."), em, hex(HEX_FAINT))
		return
	}
	if f.workspace != "" {
		ui.next({width = ui.fill(), height = ui.px(em * SETTINGS_ROW_H_EM), axis = .X, cross = .Center})
		if ui.row(.Center, id = "###ws") {
			text("w", fmt.tprintf(i18n.tr("Workspace “%s”"), f.workspace), hex(HEX_WORKSPACE_NAME), ui.Style_Mod{font_size = math.round(em * FS_LABEL)}, ui.fill())
			if f.usage_url != "" {
				if ui.button("web", i18n.tr("Usage on opencode.ai"), lucide.GLOBE, {height = math.round(em * BUTTON_SMALL_H_EM)}).clicked { link_open(f.usage_url) }
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
			text("r", l.resets > now ? fmt.tprintf(i18n.tr("resets in %s"), duration_text(now, l.resets)) : "", hex(HEX_FAINT), ui.Style_Mod{font = app.mono, font_size = math.round(em * FS_CAPTION)}, ui.px(em * 9))
		}
	}
	if len(f.budgets) > 0 { section(app, i18n.tr("BUDGETS"), em) }
	for b, i in f.budgets {
		ui.next({width = ui.fill(), height = ui.px(math.round(em * SETTINGS_ROW_H_EM)), axis = .X, cross = .Center})
		if ui.row(.Center, id = fmt.tprintf("###bud%d", i)) {
			text("n", b.scope != "" ? b.scope : i18n.tr("budget"), hex(HEX_FACT_NAME), ui.Style_Mod{font = app.mono, font_size = math.round(em * FS_SMALL)}, ui.px(em * 6))
			t := b.limit > 0 ? f32(b.spent / b.limit) : 0
			ui.next({width = ui.fill(), height = ui.px(math.round(em * 0.7))})
			ui.progress("###bar", t)
			ui.spacer(ui.px(em * 0.7))
			text("p", fmt.tprintf("$%.2f / $%.0f", b.spent, b.limit), t >= BUDGET_WARN_SHARE ? hex(HEX_YELLOW) : hex(HEX_GREEN), ui.Style_Mod{font = app.mono_bold, font_size = math.round(em * FS_SMALL)}, ui.px(em * 8))
			text("r", b.resets > now ? fmt.tprintf(i18n.tr("resets in %s"), duration_text(now, b.resets)) : "", hex(HEX_FAINT), ui.Style_Mod{font = app.mono, font_size = math.round(em * FS_CAPTION)}, ui.px(em * 9))
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
	info_line(app, "###ph", i18n.tr("Answers given with “Always”: the server applies them without asking again. Revoke one to be asked next time."), em)
	ui.spacer(ui.px(em * 0.6))
	if read_shown(app, "###sp_read", &f.reads[.Saved], em, server_facts_load) {
		if len(f.saved) == 0 { info_line(app, "###none", i18n.tr("No saved permission."), em, hex(HEX_FAINT)) }
		for &s, i in f.saved {
			ui.next({width = ui.fill(), height = ui.px(math.round(em * 2.4)), axis = .X, cross = .Center})
			if ui.row(.Center, id = fmt.tprintf("###sp%d", i)) {
				col := s.effect == "deny" ? hex(HEX_RED) : s.effect == "allow" ? hex(HEX_GREEN) : hex(HEX_YELLOW)
				pill("###e", s.effect != "" ? s.effect : "?", col)
				ui.spacer(ui.px(em * 0.5))
				text("a", s.action, hex(HEX_SETTING_NAME), ui.Style_Mod{font = app.mono_bold, font_size = math.round(em * FS_NOTE)})
				ui.spacer(ui.px(em * 0.5))
				text("r", s.resource, hex(HEX_WEAK), ui.Style_Mod{font = app.mono, font_size = math.round(em * FS_SMALL)}, ui.fill())
				if ui.button("rv", i18n.tr("Revoke"), lucide.TRASH_2, {intent = .Danger, height = math.round(em * BUTTON_SMALL_H_EM), disabled = saved_revoking(f, s.id)}).clicked { saved_revoke(app, s.id) }
			}
		}
	}
	section(app, i18n.tr("RULES OF THE AGENTS"), em)
	for a in app.agents {
		info_line(app, fmt.tprintf("###ag_%s", a.id), fmt.tprintf("%s (%s): %s", a.name != "" ? a.name : a.id, a.mode, first_line(a.description)), em)
		ui.spacer(ui.px(em * 0.3))
	}
}

page_catalog :: proc(app: ^App, em: f32) {
	f := &app.facts
	list :: proc(app: ^App, title: string, items: []Named, em: f32, read: ^remote.Remote = nil) {
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
	list(app, i18n.tr("PROVIDERS"), f.providers[:], em, &f.reads[.Providers])
	models := make([]Named, len(app.models), context.temp_allocator)
	for m, i in app.models { models[i] = {m.name != "" ? m.name : m.id, fmt.tprintf(i18n.tr("%s · %s context"), m.provider, kfmt(m.ctx_len))} }
	list(app, i18n.tr("MODELS"), models, em)
	agents := make([]Named, len(app.agents), context.temp_allocator)
	for a, i in app.agents { agents[i] = {a.name != "" ? a.name : a.id, fmt.tprintf("%s · %s", a.mode, first_line(a.description))} }
	list(app, i18n.tr("AGENTS"), agents, em)
	list(app, i18n.tr("SKILLS"), f.skills[:], em, &f.reads[.Skills])
	list(app, i18n.tr("COMMANDS"), f.commands[:], em, &f.reads[.Commands])
}
