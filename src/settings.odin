// Settings: the client's own preferences (the toolkit's typed registry, gt:config: named, bounded, documented, saved to
// %APPDATA%\opencode-native\prefs.txt, applied at once) and what the opencode server lets one see and change (its shell,
// its MCP servers, its saved permissions, its usage, its providers, agents, skills, commands, its configuration files).
package occ

import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:mem/virtual"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "gt:config"
import "gt:draw"
import "gt:font"
import "gt:platform"
import "gt:ui"

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
SETTINGS_DIALOG_TOP :: 0.08   // of the window's height
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

ACCENTS := [?]string{"peach", "blue", "purple", "green", "cyan", "rose"}
ACCENT_HEX := [?]u32{HEX_PEACH, HEX_BLUE, HEX_PURPLE, HEX_GREEN, HEX_CYAN, HEX_ROSE}

PREF_DEFS := [?]config.Def{
	{name = "appearance.accent", description = "The colour of primary buttons, the selection, links of attention and focus rings.", kind = .String, default = {s = "peach"}, choices = ACCENTS[:]},
	{name = "appearance.font", description = "The face of the interface's text: the system's usual one (automatic), the one built into the program, or any installed family.", kind = .String, default = {s = ""}},
	{name = "appearance.mono_font", description = "The face of code, paths and figures: automatic, built in, or any installed family.", kind = .String, default = {s = ""}},
	{name = "appearance.font_size", description = "Size of the interface's text, in points at 100 % zoom.", kind = .Int, default = {i = 14}, bounded = true, min = FONT_SIZE_MIN, max = FONT_SIZE_MAX},
	{name = "appearance.zoom", description = "Zoom of the whole window (Ctrl + wheel, Ctrl + / -, Ctrl 0 change it too).", kind = .Float, default = {f = 1}, bounded = true, min = ZOOM_MIN, max = ZOOM_MAX},
	{name = "appearance.density", description = "Compact rows fit more on screen at the same text size.", kind = .String, default = {s = "comfortable"}, choices = {"comfortable", "compact"}},
	{name = "appearance.rounding", description = "Corner rounding of buttons, fields and menus (0: square).", kind = .Float, default = {f = 1}, bounded = true, min = 0, max = 2},
	{name = "appearance.animations", description = "Interface animations: the system's setting, always, or never.", kind = .String, default = {s = "system"}, choices = {"system", "on", "off"}},
	{name = "appearance.smooth_scroll", description = "Scrolling glides to where the wheel or the keys send it, even when the system turns animations off.", kind = .Bool, default = {b = true}},
	{name = "appearance.glow", description = "Halos around lit buttons, lamps and running sub-agents.", kind = .Bool, default = {b = true}},
	{name = "conversation.width", description = "Widest the conversation column gets, in logical pixels.", kind = .Int, default = {i = 880}, bounded = true, min = COLUMN_W_MIN, max = COLUMN_W_MAX},
	{name = "conversation.reasoning", description = "How the model's reasoning shows: folded under a line, unfolded, or not at all.", kind = .String, default = {s = "collapsed"}, choices = {"collapsed", "expanded", "hidden"}},
	{name = "conversation.expand_tools", description = "Tool calls open with their input and output shown.", kind = .Bool, default = {b = false}},
	{name = "conversation.tool_lines", description = "Lines of a tool's output shown before the rest is counted.", kind = .Int, default = {i = 60}, bounded = true, min = TOOL_LINES_MIN, max = TOOL_LINES_MAX},
	{name = "conversation.page_size", description = "Messages read at a time (scrolling up reads the next page by itself).", kind = .Int, default = {i = 80}, bounded = true, min = PAGE_SIZE_MIN, max = PAGE_SIZE_MAX},
	{name = "conversation.follow", description = "Follow new messages to the bottom while you are there.", kind = .Bool, default = {b = true}},
	{name = "conversation.usage", description = "Tokens and cost under each answer.", kind = .Bool, default = {b = true}},
	{name = "conversation.clock", description = "Times of messages in 24-hour or 12-hour form.", kind = .String, default = {s = "24h"}, choices = {"24h", "12h"}},
	{name = "composer.send", description = "The key that sends: Enter (Shift+Enter breaks the line) or Ctrl+Enter (Enter breaks the line).", kind = .String, default = {s = "enter"}, choices = {"enter", "ctrl+enter"}},
	{name = "sidebar.subagents", description = "Sub-agent sessions: under their parent, in the list with the others, or not shown.", kind = .String, default = {s = "nested"}, choices = {"nested", "flat", "hidden"}},
	{name = "notify.finished", description = "When a session that is not in front of you ends its run: nothing, a toast, or a toast and the taskbar button flashing.", kind = .String, default = {s = "flash"}, choices = {"off", "toast", "flash"}},
	{name = "notify.permission", description = "Flash the taskbar button when a session asks for a permission and the window is not in front.", kind = .Bool, default = {b = true}},
}

// The preferences as plain values (read on every frame: no lookups by name there).
Prefs :: struct {
	accent:       Color,
	accent_hex:   u32,
	font_size:    f32,
	zoom:         f32,
	density:      f32,
	rounding:     f32,
	animations:   string,
	glow:         bool,
	smooth_scroll: bool,
	column_w:     f32,
	reasoning:    string,
	expand_tools: bool,
	tool_lines:   int,
	page_size:    int,
	follow:       bool,
	usage:        bool,
	clock24:      bool,
	ctrl_enter:   bool,
	subagents:    string,
	notify:       string,
	notify_perm:  bool,
}

prefs_path :: proc() -> string { return pjoin({filepath.dir(settings_path()), "prefs.txt"}) }

prefs_init :: proc(app: ^App) {
	app.cfg_prefs = config.prefs_make()
	config.register(&app.cfg_prefs, PREF_DEFS[:])
	config.load_file(&app.cfg_prefs, prefs_path(), .User)
	config.apply_args(&app.cfg_prefs, os.args[1:])   // --pref name=value
	prefs_refresh(app)
}

// The plain values from the registry, and what follows from them (theme, zoom, density, rounding).
prefs_refresh :: proc(app: ^App) {
	p := &app.cfg_prefs
	s := &app.prefs
	acc := config.string_of(p, "appearance.accent")
	s.accent_hex = HEX_PEACH
	for name, i in ACCENTS { if name == acc { s.accent_hex = ACCENT_HEX[i] } }
	s.accent = hex(s.accent_hex)
	s.font_size = f32(config.int_of(p, "appearance.font_size"))
	s.zoom = f32(config.float_of(p, "appearance.zoom"))
	s.density = config.string_of(p, "appearance.density") == "compact" ? COMPACT_DENSITY : 1
	s.rounding = f32(config.float_of(p, "appearance.rounding"))
	s.animations = config.string_of(p, "appearance.animations")
	s.glow = config.bool_of(p, "appearance.glow")
	s.smooth_scroll = config.bool_of(p, "appearance.smooth_scroll")
	s.column_w = f32(config.int_of(p, "conversation.width"))
	s.reasoning = config.string_of(p, "conversation.reasoning")
	s.expand_tools = config.bool_of(p, "conversation.expand_tools")
	s.tool_lines = int(config.int_of(p, "conversation.tool_lines"))
	s.page_size = int(config.int_of(p, "conversation.page_size"))
	s.follow = config.bool_of(p, "conversation.follow")
	s.usage = config.bool_of(p, "conversation.usage")
	s.clock24 = config.string_of(p, "conversation.clock") == "24h"
	s.ctrl_enter = config.string_of(p, "composer.send") == "ctrl+enter"
	s.subagents = config.string_of(p, "sidebar.subagents")
	s.notify = config.string_of(p, "notify.finished")
	s.notify_perm = config.bool_of(p, "notify.permission")

	// the faces, when either preference changed (a family is opened once: the font state keeps it)
	if wanted := fmt.tprintf("%s\n%s", config.string_of(p, "appearance.font"), config.string_of(p, "appearance.mono_font")); wanted != app.fonts_wanted {
		fonts_apply(app)
	}

	ui.set_zoom(&app.ui_state, s.zoom)
	ui.set_density(&app.ui_state, s.density)
	ui.set_rounding(&app.ui_state, s.rounding)
	pal := OPENCODE_PALETTE
	pal.accent = s.accent_hex
	ui.apply_palette(&app.theme, pal)
	ui.theme_set(&app.theme, "selection", with_alpha(s.accent, SELECTION_ALPHA))
}

prefs_save :: proc(app: ^App) {
	if !config.save_user(&app.cfg_prefs, prefs_path()) { ui.toast(.Bad, "The preferences could not be saved") }
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

// The accent colour (buttons, selection, lamps of attention).
accent :: proc() -> Color { return the_app.prefs.accent }

// Ctrl + wheel changed the zoom: keep it.
prefs_track_zoom :: proc(app: ^App) {
	z := ui.zoom(&app.ui_state)
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
	return platform.os_animations_enabled()
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
	title := sid
	if s := find_session(app, sid); s != nil { title = s.title } else if sid == app.chat.id && app.chat.have_self { title = app.chat.self.title }
	switch outcome {
	case "failed":      ui.toast(.Bad, "Failed: %s", ellipsize(title, TOAST_TITLE_CHARS))
	case "interrupted": ui.toast(.Warn, "Stopped: %s", ellipsize(title, TOAST_TITLE_CHARS))
	case:               ui.toast(.Good, "Done: %s", ellipsize(title, TOAST_TITLE_CHARS))
	}
	if mode == "flash" && !front { flash_taskbar(app) }
}

////////////////////////////////
// What the server says (read when the settings open)

Mcp_Server :: struct { name, status, error: string }
Shell_Info :: struct { name, path: string, ok: bool }
Saved_Perm :: struct { id, action, resource, effect, project: string }
Config_File :: struct { path: string, keys: []string }
Limit :: struct { name: string, percent: f64, limited: bool, resets: f64 }
Budget :: struct { scope: string, limit, spent: f64, resets: f64 }
Named :: struct { name, detail: string }

Server_Facts :: struct {
	arena:     virtual.Arena,
	ready:     bool,
	shells:    [dynamic]Shell_Info,
	shell:     string,              // the one set in the configuration ("" : the server's choice)
	mcp:       [dynamic]Mcp_Server,
	saved:     [dynamic]Saved_Perm,
	files:     [dynamic]Config_File,
	limits:    [dynamic]Limit,
	budgets:   [dynamic]Budget,
	usage_url: string,
	workspace: string,
	providers: [dynamic]Named,
	skills:    [dynamic]Named,
	commands:  [dynamic]Named,
}

server_facts_reset :: proc(app: ^App) {
	f := &app.facts
	app.facts_gen += 1
	virtual.arena_destroy(&f.arena)
	f^ = {}
	_ = virtual.arena_init_growing(&f.arena)
	a := virtual.arena_allocator(&f.arena)
	f.shells = make([dynamic]Shell_Info, a)
	f.mcp = make([dynamic]Mcp_Server, a)
	f.saved = make([dynamic]Saved_Perm, a)
	f.files = make([dynamic]Config_File, a)
	f.limits = make([dynamic]Limit, a)
	f.budgets = make([dynamic]Budget, a)
	f.providers = make([dynamic]Named, a)
	f.skills = make([dynamic]Named, a)
	f.commands = make([dynamic]Named, a)
}

server_facts_load :: proc(app: ^App) {
	server_facts_reset(app)
	app.facts.ready = true
	request(app, .Cfg, "GET", "/api/config")
	request(app, .Shells, "GET", "/api/config/shell")
	request(app, .Mcp, "GET", "/api/mcp")
	request(app, .Saved, "GET", "/api/permission/saved")
	request(app, .Usage, "GET", "/api/experimental/usage/limits")
	request(app, .Providers, "GET", "/api/provider")
	request(app, .Skills, "GET", "/api/skill")
	request(app, .Commands, "GET", "/api/command")
}

// An answer of one of those requests (net.odin on_answer).
server_facts_answer :: proc(app: ^App, kind: Req_Kind, v: json.Value) {
	f := &app.facts
	if !f.ready { return }
	a := virtual.arena_allocator(&f.arena)
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
			append(&f.mcp, Mcp_Server{strings.clone(jstr(it, "name"), a), strings.clone(st, a), strings.clone(jstr(it, "status", "error"), a)})
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

////////////////////////////////
// The dialog

Settings_Page :: enum u8 { Appearance, Conversation, Behaviour, Server, Mcp, Usage, Permissions, Catalog }

SETTINGS_PAGES := [Settings_Page]struct { title, icon: string, opencode: bool }{
	.Appearance   = {"Appearance", ICO_PALETTE, false},
	.Conversation = {"Conversation", ICO_CHAT, false},
	.Behaviour    = {"Behaviour", ICO_SLIDERS, false},
	.Server       = {"Server & shell", ICO_TERMINAL, true},
	.Mcp          = {"MCP servers", ICO_PLUG, true},
	.Usage        = {"Usage & limits", ICO_GAUGE, true},
	.Permissions  = {"Permissions", ICO_SHIELD, true},
	.Catalog      = {"Providers & skills", ICO_LIST, true},
}

settings_open :: proc(app: ^App) {
	app.settings_open = true
	server_facts_load(app)
}

settings_dialog :: proc(app: ^App, em: f32) {
	if ui.modal("settings", em * 52, &app.settings_open, SETTINGS_DIALOG_TOP) {
		dialog_backdrop()
		h := math.round(min(em * 36, app.ui_state.window_size.y * 0.8))
		ui.next({width = ui.fill(), height = ui.px(h), axis = .X})
		if ui.row(id = "###settings_body") {
			// the pages
			ui.next({width = ui.px(em * 14), height = ui.fill(), axis = .Y})
			if ui.column(id = "###settings_nav") {
				ui.spacer(ui.px(em * 1.1))
				nav_heading("CLIENT", em)
				for page in Settings_Page {
					info := SETTINGS_PAGES[page]
					if page == .Server { ui.spacer(ui.px(em * 0.6)); nav_heading("OPENCODE", em) }
					ui.next({width = ui.fill(), height = ui.children_sum(), axis = .X})
					if ui.row(id = fmt.tprintf("###nv%d", int(page))) {
						ui.spacer(ui.px(em * 0.7))
						if bevel_button(fmt.tprintf("###nav%d", int(page)), info.title, info.icon, app.settings_page == page ? .Toggled : .Ghost, ui.fill(), math.round(em * BUTTON_H_EM), left = true).clicked {
							app.settings_page = page
						}
						ui.spacer(ui.px(em * 0.4))
					}
					ui.spacer(ui.px(em * 0.2))
				}
				ui.spacer(ui.fill())
				ui.next({width = ui.fill(), height = ui.children_sum(), axis = .X})
				if ui.row(id = "###nav_foot") {
					ui.spacer(ui.px(em * 0.9))
					text("f", fmt.tprintf("prefs: %s", filepath.base(prefs_path())), hex(HEX_FAINT), ui.Style_Mod{font = app.mono, font_size = math.round(em * FS_CAPTION), height = ui.px(em * 1.4)})
				}
				ui.spacer(ui.px(em * 0.9))
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
						info := SETTINGS_PAGES[app.settings_page]
						text("pt", info.title, hex(HEX_BRIGHT), ui.Style_Mod{font_size = math.round(em * FS_TITLE), height = ui.px(em * 2)}, ui.fill())
						ui.spacer(ui.px(em * 0.6))
						switch app.settings_page {
						case .Appearance:   page_appearance(app, em)
						case .Conversation: page_conversation(app, em)
						case .Behaviour:    page_behaviour(app, em)
						case .Server:       page_server(app, em)
						case .Mcp:          page_mcp(app, em)
						case .Usage:        page_usage(app, em)
						case .Permissions:  page_permissions(app, em)
						case .Catalog:      page_catalog(app, em)
						}
						ui.spacer(ui.px(em * 1.5))
					}
					ui.spacer(ui.px(em * DIALOG_MARGIN_EM))
				}
			}
		}
		dialog_close(&app.settings_open)
	}
}

@(private = "file")
nav_heading :: proc(s: string, em: f32) {
	ui.next({width = ui.fill(), height = ui.px(em * 1.5), axis = .X, cross = .Center})
	if ui.row(.Center, id = fmt.tprintf("###nh_%s", s)) {
		ui.spacer(ui.px(em * 1.1))
		text("h", s, hex(HEX_FAINT), ui.Style_Mod{font = the_app.mono_bold, font_size = math.round(em * FS_CAPTION)})
	}
}

// `if setting(name) { control }`: a row with the preference's title and description on the left, its control on the
// right, and a reset button when it is not at its default.
@(deferred_none = setting_end)
setting :: proc(app: ^App, name: string, em: f32) -> bool {
	p := &app.cfg_prefs
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
		if glyph_button("###reset", ICO_REFRESH, math.round(em * 1.6)).clicked {
			config.reset(p, name)
			prefs_save(app)
			prefs_refresh(app)
		}
		ui.spacer(ui.px(em * 0.3))
	}
	return true
}

@(private = "file")
setting_end :: proc() {
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
	ui.next({width = ui.px(w), height = ui.px(math.round(em * 2))})
	if ui.segmented("###seg", labels, &sel) { pref_set(app, name, d.choices[sel]) }
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
	v := d.kind == .Int ? f32(config.int_of(p, name)) : f32(config.float_of(p, name))
	ui.next({width = ui.px(em * 15), height = ui.px(math.round(em * 2))})
	ui.a11y({name = config.title_of(d)})
	idle := slider_idle(v, lo, hi, step)
	sig := ui.slider("###sl", &v, lo, hi, step, format)
	// written when the drag ends (or at each key step): the file is not rewritten at the pointer's rate, nor by the focus alone
	if (sig.released || (sig.focused && !sig.dragging && abs(v - idle) > SLIDER_EPSILON)) && (d.kind == .Int ? i64(math.round(v)) != config.int_of(p, name) : abs(f64(v) - config.float_of(p, name)) > SLIDER_EPSILON) {
		pref_set(app, name, d.kind == .Int ? fmt.tprintf("%d", i64(math.round(v))) : fmt.tprintf("%.2f", v))
	} else if sig.dragging && d.kind == .Float && name == "appearance.rounding" {
		ui.set_rounding(&app.ui_state, v)   // (live while dragged)
	}
}

page_appearance :: proc(app: ^App, em: f32) {
	if setting(app, "appearance.accent", em) {
		// swatches: a lit bead per colour
		for name, i in ACCENTS {
			ui.next({width = ui.px(math.round(em * 2.1)), height = ui.px(math.round(em * 2.1))})
			ui.a11y({role = .Radio_Button, name = name, toggled = config.string_of(&app.cfg_prefs, "appearance.accent") == name ? .True : .False})
			b := ui.build_box({.Clickable, .Focusable}, fmt.tprintf("###acc%d", i))
			col := ui.frame_new(Color)
			col^ = hex(ACCENT_HEX[i])
			b.custom_user = col
			b.custom = proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
				c := (^Color)(user)^
				sel := b.text == "*"
				sz := min(b.rect.max.x - b.rect.min.x, b.rect.max.y - b.rect.min.y)
				if sel { draw_well(dc, b.rect, sz * 0.5, hex(HEX_SWATCH_WELL), 1, c) }
				draw_lamp(dc, draw.rect_center(b.rect), sz * (sel ? 0.55 : 0.5 + 0.06 * b.hot_t), c, sel ? 1 : 0.55 + 0.45 * b.hot_t)
			}
			if config.string_of(&app.cfg_prefs, "appearance.accent") == name { b.text = "*" }
			if ui.signal(b).clicked { pref_set(app, "appearance.accent", name) }
			ui.spacer(ui.px(em * 0.2))
		}
	}
	if setting(app, "appearance.font", em) { font_button(app, "appearance.font", em) }
	if setting(app, "appearance.mono_font", em) { font_button(app, "appearance.mono_font", em) }
	if setting(app, "appearance.font_size", em) { pref_slider(app, "appearance.font_size", FONT_SIZE_MIN, FONT_SIZE_MAX, 1, "%.0f pt", em) }
	if setting(app, "appearance.zoom", em) { pref_slider(app, "appearance.zoom", ZOOM_MIN, ZOOM_MAX, 0.05, "%.2f×", em) }
	if setting(app, "appearance.density", em) { pref_choice(app, "appearance.density", {"Comfortable", "Compact"}, em) }
	if setting(app, "appearance.rounding", em) { pref_slider(app, "appearance.rounding", 0, 2, 0.05, "%.2f", em) }
	if setting(app, "appearance.animations", em) { pref_choice(app, "appearance.animations", {"System", "On", "Off"}, em) }
	if setting(app, "appearance.smooth_scroll", em) { pref_switch(app, "appearance.smooth_scroll", em) }
	if setting(app, "appearance.glow", em) { pref_switch(app, "appearance.glow", em) }
}

// The button of a font preference (its face, in that face) and its picker: Automatic, Built in, then the installed
// families, matched as one types.
font_button :: proc(app: ^App, name: string, em: f32) {
	mono := name == "appearance.mono_font"
	want := config.string_of(&app.cfg_prefs, name)
	face := mono ? app.mono_face : app.ui_face
	// the button names the face in use; a faint word before it says how it was chosen
	mode, shown: string
	switch want {
	case "":           mode, shown = "auto", face != "" ? face : (mono ? "Inconsolata" : "Roboto")
	case FONT_BUILTIN: mode, shown = "built in", mono ? "Inconsolata" : "Roboto"
	case:              mode, shown = face == want ? "" : "not installed", want
	}
	if mode != "" {
		text("fm", mode, hex(HEX_FAINT), ui.Style_Mod{font_size = math.round(em * FS_SMALL), height = ui.px(em * 1.5)})
		ui.spacer(ui.px(em * 0.5))
	}
	sig := bevel_button(fmt.tprintf("###fb_%s", name), shown, "", .Normal, ui.px(em * 13))
	if sig.clicked {
		if app.picker.open && app.picker.id == name { app.picker.open = false } else { picker_open(&app.picker, name, sig.box.rect) }
	}
	if !(app.picker.open && app.picker.id == name) { return }
	if app.font_families == nil { app.font_families = font.system_families(&app.fonts) }
	items := make([dynamic]Pick_Item, context.temp_allocator)
	append(&items, Pick_Item{label = "Automatic", detail = "the system's usual face", current = want == ""})
	append(&items, Pick_Item{label = "Built in", detail = mono ? "Inconsolata" : "Roboto", current = want == FONT_BUILTIN})
	for fam in app.font_families { append(&items, Pick_Item{label = fam, current = fam == want}) }
	if k := picker(app, &app.picker, name, mono ? "code fonts" : "fonts", items[:], em, align_right = true); k >= 0 {
		switch k {
		case 0: pref_set(app, name, "")
		case 1: pref_set(app, name, FONT_BUILTIN)
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
	if setting(app, "conversation.clock", em) { pref_choice(app, "conversation.clock", {"24 h", "12 h"}, em) }
}

page_behaviour :: proc(app: ^App, em: f32) {
	if setting(app, "composer.send", em) { pref_choice(app, "composer.send", {"Enter", "Ctrl+Enter"}, em, em * 14) }
	if setting(app, "sidebar.subagents", em) { pref_choice(app, "sidebar.subagents", {"Nested", "Flat", "Hidden"}, em) }
	if setting(app, "notify.finished", em) { pref_choice(app, "notify.finished", {"Off", "Toast", "Flash"}, em) }
	if setting(app, "notify.permission", em) { pref_switch(app, "notify.permission", em) }
	ui.spacer(ui.px(em * 0.6))
	info_line(app, "###hint_setup", "Installation and " + LBL_PIECES + " are in Setup… (title bar menu).", em)
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

@(private = "file")
section :: proc(s: string, em: f32) {
	ui.spacer(ui.px(em * 0.6))
	section_label(fmt.tprintf("sec_%s", s), s, em)
}

@(private = "file")
loading :: proc(app: ^App, em: f32) -> bool {
	if int(app.pending) > 0 {
		info_line(app, "###ld", "Asking the server…", em)
		return true
	}
	return false
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
	section("SERVER", em)
	ui.next({width = ui.fill(), height = ui.children_sum(), axis = .Y})
	if well("###srv", radius = 7, base = HEX_FACTS_WELL) {
		ui.spacer(ui.px(em * 0.4))
		fact("###s1", "address", server_base(app), em)
		fact("###s2", "status", app.online ? "connected" : "not connected", em, app.online ? hex(HEX_GREEN) : hex(HEX_YELLOW))
		fact("###s3", "version", app.server_version != "" ? app.server_version : "?", em)
		fact("###s0", "name", server_name(app), em)
		fact("###s4", "auth", app.servers[app.server].password == "" ? "none" : app.servers[app.server].local ? "Basic (password from service.json)" : "Basic", em)
		fact("###s5", "sessions", fmt.tprintf("%d loaded · %d running", len(app.sessions), len(app.busy)), em)
		fact("###s6", "client", fmt.tprintf("opencode native %s", APP_VERSION), em)
		ui.spacer(ui.px(em * 0.4))
	}
	section("SHELL", em)
	info_line(app, "###shh", "The shell the agents run their commands in (written to the configuration's \"shell\").", em)
	ui.spacer(ui.px(em * 0.4))
	if len(f.shells) == 0 && loading(app, em) { return }
	sel := -1
	for s, i in f.shells { if f.shell != "" && same_path(s.path, f.shell) { sel = i } }
	for s, i in f.shells {
		ui.next({width = ui.fill(), height = ui.px(math.round(em * SETTINGS_ROW_H_EM)), axis = .X, cross = .Center})
		if ui.row(.Center, id = fmt.tprintf("###sh%d", i)) {
			if bevel_button(fmt.tprintf("###shb%d", i), s.name, ICO_TERMINAL, sel == i ? .Accent : .Normal, ui.px(em * 9), math.round(em * BUTTON_COMPACT_H_EM), disabled = !s.ok).clicked {
				body := fmt.tprintf(`{{"shell":%s}}`, jquote(s.path))
				request(app, .Action, "PATCH", "/api/experimental/config", body)
				app.facts.shell = strings.clone(s.path, virtual.arena_allocator(&app.facts.arena))
				ui.toast(.Good, "Shell: %s", s.name)
			}
			ui.spacer(ui.px(em * 0.7))
			text("p", s.path, hex(HEX_FAINT), ui.Style_Mod{font = app.mono, font_size = math.round(em * FS_CAPTION)}, ui.fill())
		}
		ui.spacer(ui.px(em * 0.25))
	}
	if sel < 0 { info_line(app, "###shd", "None set: the server picks one.", em, hex(HEX_FAINT)) }
	section("CONFIGURATION FILES", em)
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
				if bevel_button("###open", "Open", ICO_DOC, .Normal, height = math.round(em * BUTTON_SMALL_H_EM)).clicked { platform.open_path(c.path) }
				ui.spacer(ui.px(em * 0.3))
				if bevel_button("###dir", "", ICO_FOLDER, .Normal, height = math.round(em * BUTTON_SMALL_H_EM)).clicked { platform.open_path(filepath.dir(c.path)) }
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
	if len(f.mcp) == 0 {
		if !loading(app, em) { info_line(app, "###none", "No MCP server is configured.", em, hex(HEX_FAINT)) }
		return
	}
	for &m, i in f.mcp {
		connected := m.status == "connected"
		col := connected ? hex(HEX_GREEN) : m.status == "failed" || m.error != "" ? hex(HEX_RED) : hex(HEX_FAINT)
		ui.next({width = ui.fill(), height = ui.children_sum(), axis = .Y})
		if plate(fmt.tprintf("###mcp%d", i), top = HEX_MCP_TOP, bottom = HEX_MCP_BOTTOM, radius = 8, shadow = 4) {
			ui.next({width = ui.fill(), height = ui.px(math.round(em * 2.8)), axis = .X, cross = .Center})
			if ui.row(.Center) {
				ui.spacer(ui.px(em * 0.9))
				lamp("###l", col, connected ? 1 : 0.4, size = em * 0.9)
				ui.spacer(ui.px(em * 0.5))
				text("n", m.name, hex(HEX_MCP_NAME), ui.Style_Mod{font = app.mono_bold, font_size = math.round(em * FS_LABEL)})
				ui.spacer(ui.px(em * 0.6))
				text("s", m.status != "" ? m.status : "?", col, ui.Style_Mod{font = app.mono, font_size = math.round(em * FS_SMALL)}, ui.fill())
				if connected {
					if bevel_button("###dc", "Disconnect", "", .Normal, height = math.round(em * BUTTON_SMALL_H_EM)).clicked {
						request(app, .Action, "POST", fmt.tprintf("/api/experimental/mcp/%s/disconnect", url_escape(m.name)))
						m.status = "disconnecting…"
						app.facts_due = true
					}
				} else {
					if bevel_button("###co", "Connect", "", .Accent, height = math.round(em * BUTTON_SMALL_H_EM)).clicked {
						request(app, .Action, "POST", fmt.tprintf("/api/experimental/mcp/%s/connect", url_escape(m.name)))
						m.status = "connecting…"
						app.facts_due = true
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
	if len(f.limits) == 0 && len(f.budgets) == 0 {
		if !loading(app, em) { info_line(app, "###none", "The server reports no usage limit (a provider of your own, or no OpenCode workspace).", em, hex(HEX_FAINT)) }
		return
	}
	if f.workspace != "" {
		ui.next({width = ui.fill(), height = ui.px(em * SETTINGS_ROW_H_EM), axis = .X, cross = .Center})
		if ui.row(.Center, id = "###ws") {
			text("w", fmt.tprintf("Workspace “%s”", f.workspace), hex(HEX_WORKSPACE_NAME), ui.Style_Mod{font_size = math.round(em * FS_LABEL)}, ui.fill())
			if f.usage_url != "" {
				if bevel_button("###web", "Usage on opencode.ai", ICO_GLOBE, .Normal, height = math.round(em * BUTTON_SMALL_H_EM)).clicked { link_open(f.usage_url) }
			}
		}
	}
	now := now_epoch_ms()
	if len(f.limits) > 0 { section("OPENCODE GO", em) }
	for l, i in f.limits {
		ui.next({width = ui.fill(), height = ui.px(math.round(em * SETTINGS_ROW_H_EM)), axis = .X, cross = .Center})
		if ui.row(.Center, id = fmt.tprintf("###lim%d", i)) {
			text("n", l.name, hex(HEX_FACT_NAME), ui.Style_Mod{font = app.mono, font_size = math.round(em * FS_SMALL)}, ui.px(em * 6))
			ui.next({width = ui.fill(), height = ui.px(math.round(em * 0.7))})
			ui.progress("###bar", f32(l.percent / 100))
			ui.spacer(ui.px(em * 0.7))
			col := l.limited ? hex(HEX_RED) : l.percent >= USAGE_WARN_PERCENT ? hex(HEX_YELLOW) : hex(HEX_WEAK)
			text("p", fmt.tprintf("%.0f %%", l.percent), col, ui.Style_Mod{font = app.mono_bold, font_size = math.round(em * FS_SMALL)}, ui.px(em * 3.5))
			text("r", l.resets > now ? fmt.tprintf("resets in %s", duration(now, l.resets)) : "", hex(HEX_FAINT), ui.Style_Mod{font = app.mono, font_size = math.round(em * FS_CAPTION)}, ui.px(em * 9))
		}
	}
	if len(f.budgets) > 0 { section("BUDGETS", em) }
	for b, i in f.budgets {
		ui.next({width = ui.fill(), height = ui.px(math.round(em * SETTINGS_ROW_H_EM)), axis = .X, cross = .Center})
		if ui.row(.Center, id = fmt.tprintf("###bud%d", i)) {
			text("n", b.scope != "" ? b.scope : "budget", hex(HEX_FACT_NAME), ui.Style_Mod{font = app.mono, font_size = math.round(em * FS_SMALL)}, ui.px(em * 6))
			t := b.limit > 0 ? f32(b.spent / b.limit) : 0
			ui.next({width = ui.fill(), height = ui.px(math.round(em * 0.7))})
			ui.progress("###bar", t)
			ui.spacer(ui.px(em * 0.7))
			text("p", fmt.tprintf("$%.2f / $%.0f", b.spent, b.limit), t >= BUDGET_WARN_SHARE ? hex(HEX_YELLOW) : hex(HEX_GREEN), ui.Style_Mod{font = app.mono_bold, font_size = math.round(em * FS_SMALL)}, ui.px(em * 8))
			text("r", b.resets > now ? fmt.tprintf("resets in %s", duration(now, b.resets)) : "", hex(HEX_FAINT), ui.Style_Mod{font = app.mono, font_size = math.round(em * FS_CAPTION)}, ui.px(em * 9))
		}
	}
}

page_permissions :: proc(app: ^App, em: f32) {
	f := &app.facts
	info_line(app, "###ph", "Answers given with “Always”: the server applies them without asking again. Revoke one to be asked next time.", em)
	ui.spacer(ui.px(em * 0.6))
	if len(f.saved) == 0 {
		if !loading(app, em) { info_line(app, "###none", "No saved permission.", em, hex(HEX_FAINT)) }
	}
	for &s, i in f.saved {
		ui.next({width = ui.fill(), height = ui.px(math.round(em * 2.4)), axis = .X, cross = .Center})
		if ui.row(.Center, id = fmt.tprintf("###sp%d", i)) {
			col := s.effect == "deny" ? hex(HEX_RED) : s.effect == "allow" ? hex(HEX_GREEN) : hex(HEX_YELLOW)
			pill("###e", s.effect != "" ? s.effect : "?", col)
			ui.spacer(ui.px(em * 0.5))
			text("a", s.action, hex(HEX_SETTING_NAME), ui.Style_Mod{font = app.mono_bold, font_size = math.round(em * FS_NOTE)})
			ui.spacer(ui.px(em * 0.5))
			text("r", s.resource, hex(HEX_WEAK), ui.Style_Mod{font = app.mono, font_size = math.round(em * FS_SMALL)}, ui.fill())
			if bevel_button("###rv", "Revoke", ICO_DELETE, .Danger, height = math.round(em * BUTTON_SMALL_H_EM)).clicked {
				request(app, .Action, "DELETE", fmt.tprintf("/api/permission/saved/%s", s.id))
				app.facts_due = true
			}
		}
	}
	section("RULES OF THE AGENTS", em)
	for a in app.agents {
		info_line(app, fmt.tprintf("###ag_%s", a.id), fmt.tprintf("%s (%s): %s", a.name != "" ? a.name : a.id, a.mode, first_line(a.description)), em)
		ui.spacer(ui.px(em * 0.3))
	}
}

page_catalog :: proc(app: ^App, em: f32) {
	f := &app.facts
	list :: proc(app: ^App, title: string, items: []Named, em: f32) {
		section(fmt.tprintf("%s (%d)", title, len(items)), em)
		for it, i in items {
			ui.next({width = ui.fill(), height = ui.children_sum(), axis = .X})
			if ui.row(id = fmt.tprintf("###%s%d", title, i)) {
				text("n", it.name, hex(HEX_CATALOG_NAME), ui.Style_Mod{font = the_app.mono_bold, font_size = math.round(em * FS_SMALL), height = ui.px(em * 1.5)}, ui.px(em * 13))
				ui.next({width = ui.fill(), font_size = math.round(em * FS_SMALL), flags = {.Text_Wrap}, fg = hex(HEX_WEAK), text_pad = 0})
				ui.paragraph(fmt.tprintf("%s###d", label_safe(it.detail)))
			}
			ui.spacer(ui.px(em * 0.25))
		}
	}
	if len(f.providers) + len(f.skills) + len(f.commands) == 0 && loading(app, em) { return }
	list(app, "PROVIDERS", f.providers[:], em)
	models := make([]Named, len(app.models), context.temp_allocator)
	for m, i in app.models { models[i] = {m.name != "" ? m.name : m.id, fmt.tprintf("%s · %s context", m.provider, kfmt(m.ctx_len))} }
	list(app, "MODELS", models, em)
	agents := make([]Named, len(app.agents), context.temp_allocator)
	for a, i in app.agents { agents[i] = {a.name != "" ? a.name : a.id, fmt.tprintf("%s · %s", a.mode, first_line(a.description))} }
	list(app, "AGENTS", agents, em)
	list(app, "SKILLS", f.skills[:], em)
	list(app, "COMMANDS", f.commands[:], em)
}
