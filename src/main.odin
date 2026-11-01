// opencode, native: a desktop client for the opencode v2 server, on gui_toolkit (Direct3D 11, DirectWrite).
//   build.bat            -> build\opencode-native.exe
//   opencode-native.exe [--url=http://127.0.0.1:4096] [--password=...]
// Without arguments it finds this computer's opencode server (~/.local/state/opencode/service.json, else ~/.config/opencode/service.json).
package occ

import "core:fmt"
import "core:mem/virtual"
import "core:math"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:time"
import "gt:config"
import "gt:devtools"
import "gt:draw"
import "gt:font"
import "gt:platform"
import "gt:render"
import "gt:ui"

App :: struct {
	win:      ^platform.Window,
	r:        render.Renderer,
	fonts:    font.State,
	dc:       draw.Context,
	theme:    ui.Theme,
	ui_state: ui.State,
	prose, font, mono, mono_bold, icons, tk_icons: font.Font_Id,
	own:           Own_Faces,
	prose_scale:   f32,        // the answers' size, of the text around them
	prose_face:    string,     // the system face of the answers ("": not one)
	ui_face:       string,     // the system face of the interface ("": the embedded one)
	mono_face:     string,     // the same for code
	fonts_wanted:  string,     // the two font preferences fonts_apply last applied (prefs_refresh compares)
	font_families: []string,   // the installed families (read when a font picker first opens)

	// the server
	servers:        [dynamic]Server,   // (servers.odin) this computer's first
	server:         int,               // the one connected
	conn:           ^Conn,             // its connection
	server_edit:    Server_Edit,
	picker:         Picker,            // the composer's agent or model picker (picker.odin)
	find:           Find,              // find in the conversation (find.odin)
	scale:          f32,               // --scale=<factor>: the interface's scale whatever the screen says (0: the screen's)
	servers_in_clear: bool,            // read passwords in clear from an older version's file: saved protected at start
	rediscover_ms:  f64,               // when this computer's server was last looked for (servers_rediscover)
	pending:        i32,       // (atomic) requests in flight
	online:         bool,
	auth_failed:    bool,
	server_version: string,

	// what we know
	sessions:        [dynamic]Session_Info,
	sess_arena:      virtual.Arena,
	sessions_loaded: bool,
	opened_first:    bool,
	busy:            map[string]bool,   // sessions running (keys owned)
	chat:            Chat,
	agents:          [dynamic]Agent_Info,
	models:          [dynamic]Model_Info,
	have_agents, have_models: bool,
	permissions:     [dynamic]Permission,

	// the interface's own state
	composer:         ui.Text_Area,
	composer_focused: bool,
	search:           ui.Text_Field,
	pending_prompt:   string,
	refresh_due:      bool,
	children_due:     bool,           // the sub-agents of the session shown changed: read them again (debounced)
	children_ms:      f64,
	nav:              [dynamic]string, // the sessions drilled down from, outermost first (owned): Back returns to the last
	nav_steps:        [dynamic]Nav_Step, // navigation asked for in this frame (subagents.odin)
	sub_open:         map[u64]bool,   // sidebar: sessions whose sub-agents are listed under them
	start_session:    string,
	cfg_prefs:        config.Prefs,   // the preferences (settings.odin)
	prefs:            Prefs,          // their plain values
	facts:            Server_Facts,   // what the server said for the settings pages
	facts_gen:        u64,            // which reading of them is the current one
	facts_due:        bool,
	facts_ms:         f64,
	settings_open:    bool,
	settings_page:    Settings_Page,
	opened_ms:        f64,            // when the conversation shown was opened (it follows its bottom at first)
	seek_subagent:    bool,   // --seek-subagent (tests): scroll to the first sub-agent card
	refresh_ms:       f64,
	stick_bottom:     bool,
	sidebar_w:        f32,
	expanded:         map[u64]bool,   // tool and reasoning parts opened by the user (hash of their id)
	folded:           map[u64]bool,   // sidebar groups folded (hash of the directory)
	delete_id:        string,
	delete_open:      bool,
	animating:        bool,           // something pulses this frame: keep drawing
	menu_session:     string,         // the session the context menu is about (owned)
	logo:             Logo,
	column_w:         f32,    // the conversation column, frame pixels (this frame)
	chat_sb:          ^ui.Box, // the conversation scroll box, when built this frame
	first_msg:        ^ui.Box, // the conversation's first message, when built at the last build (an answer arrives before the next one: begin_build)
	stick_jump:       bool,    // the second build of a frame: the bottom is reached at once, no glide
	snap_bottom:      bool,           // the conversation's first page arrived: shown at its bottom in that frame (frame)
	chat_target:      f32,     // the conversation's scroll target at the end of the last build (a drag before this one moved it)
	stats_open:       bool,           // the statistics of the session shown (stats.odin)
	proj_stats:       Project_Stats,
	stats_pending:    bool,           // --stats (tests): open them once the session is loaded
	images:           map[u64]Image_Entry,   // decoded images, by key (images.odin)
	frame_no:         u64,
	view_open:        bool,                  // the image viewer
	view_key:         u64,
	view_name:        string,
	view_zoom:        f32,                   // times what fits (image_viewer)
	view_pan:         [2]f32,                // of the picture's centre from the view's, frame pixels
	view_grab:        [2]f32,                // view_pan when the drag began
	view_start:       Image_Ref,             // --image=<file>: opened in the viewer once it is decoded (its data owned)
	projects:         map[string]Project_Logo,   // by project id (in proj_arena)
	proj_arena:       virtual.Arena,
	anchor:           ^ui.Box, // a part header just clicked: kept where it is on screen (part_toggle, frame)
	anchor_y:         f32,
	// pacing (frame / pace)
	pacer:            render.Pacer,   // the toolkit's frame pacing (render/pacer.odin)
	devtools:         ^devtools.Server,   // TOOLKIT_DEVTOOLS=<port>: driven over the Chrome DevTools Protocol (tools/cdp.mjs)
	idled:            bool,   // the loop slept before this frame
	setup:            Setup_UI,
	quit:             bool,
	last_tick:        time.Tick,
	frames:           int,
}

the_app: ^App

clip_get :: proc() -> string { return platform.get_clipboard(the_app.win, context.temp_allocator) }
clip_set :: proc(text: string) { platform.set_clipboard(the_app.win, text) }

// When the frame starts and how it is shown: the toolkit's pacer (render/pacer.odin, on the cadence model). What matters
// most here is the resize step: a frame at a new size is presented at once (no wait for the swap chain, none for the
// refresh, two frames queued); waiting, the compositor shows the last frame stretched over the new size until one of that
// size arrives. Input after a rest is answered at once too. `inner`: a frame asked for from a loop of the system (the
// live resize's WM_PAINT). A splitter or a scroll bar held paces as a drag: one frame per slot.
pace :: proc(app: ^App, inner: bool) -> (at_once: bool) {
	return render.pace_frame(&app.pacer, &app.r, app.win, idled = app.idled, dragging = ui.active_key() != 0, inner = inner)
}

FRAMES_AFTER_INPUT :: 3        // still drawn after an event, and at start: what it set off settles
DT_MIN_S           :: 0.0005
DT_MAX_S           :: 0.1      // after a long stall the animations go on, they do not jump
ANCHOR_BUILDS_MAX  :: 4        // builds spent on keeping a part header in place

// How soon an action is followed by reading again what it changed: a burst of events reads once.
REFRESH_DEBOUNCE_MS  :: 1200
FACTS_DEBOUNCE_MS    :: 700
CHILDREN_DEBOUNCE_MS :: 800

frame :: proc(app: ^App, inner := false) {
	if ui.building() { return }
	app.frame_no += 1
	at_once := pace(app, inner)
	app.idled = false
	devtools.service(app.devtools, &app.ui_state, &app.r)
	events := platform.poll_events(app.win, false)
	render.mark_input(&app.r)
	if len(events) > 0 { app.frames = max(app.frames, FRAMES_AFTER_INPUT) }
	render.resize(&app.r, app.win.size)
	size := draw.Vec2{f32(app.win.size.x), f32(app.win.size.y)}
	now := time.tick_now()
	dt := clamp(f32(time.duration_seconds(time.tick_diff(app.last_tick, now))), DT_MIN_S, DT_MAX_S)
	app.last_tick = now
	build :: proc(app: ^App, size: draw.Vec2, events: []platform.Event, dt: f32) {
		app.animating = false
		app.chat_sb = nil
		ui.set_scrollbar_autohide(&app.ui_state, app.prefs.autohide_scrollbars)
		ui.begin_build(&app.ui_state, {
			window_size = size, events = events, dt = dt, animations = animations_on(app),
			smooth_scroll = app.prefs.smooth_scroll ? .On : .Off,
			dpi_scale = app.scale > 0 ? app.scale : app.win.dpi_scale, window = app.win,
			base = ui.Style{pref = {.X = ui.text_size(), .Y = ui.px(30)}, font = app.font, font_size = app.prefs.font_size, text_pad = 6, cursor = .Arrow, radius = 6},
			clipboard_get = clip_get, clipboard_set = clip_set,
		})
		build_ui(app)
		ui.end_build()
	}
	build(app, size, events, dt)
	prefs_track_zoom(app)
	// A part opened or closed in this build: the build drew it in its old state (the click comes after its body). Build
	// again in its new state, then scroll by what its header moved so that it stays under the pointer, and build once
	// more at that offset: the frame shows the result, never the steps.
	if a := app.anchor; a != nil {
		defer app.anchor = nil   // (kept through these builds: the bottom stays let go of)
		build(app, size, nil, 0)
		// (again while it moves: what this offset builds around it is measured only then, a page read before it above all)
		for _ in 0 ..< ANCHOR_BUILDS_MAX {
			b := app.chat_sb
			if b == nil { break }
			delta := a.rect.min.y - app.anchor_y
			if abs(delta) <= 0.5 { break }
			limit := max(0, b.view_bounds.y - b.size.y)
			y := clamp(b.view_off.y + delta, 0, limit)
			b.view_off.y, b.view_target.y = y, y
			b.view_anim[1] = {}   // (no glide toward an older target)
			build(app, size, nil, 0)
		}
	}
	// The conversation follows its bottom, placed from the last layout's content height: when this layout made it shorter
	// (a wider window re-wraps every paragraph on fewer lines), the picture would be scrolled past the end, empty, for a
	// frame. Build it again, placed from this layout (no events: they were the first build's). (Content that grew is
	// caught up by the scroll's own glide.)
	// A conversation's first page just arrived (a session opened): this build placed it from the empty one's bounds, at
	// its top. Build it again at its bottom, at once: no frame at the top, no glide down.
	if b := app.chat_sb; b != nil && app.stick_bottom {
		limit := max(0, b.view_bounds.y - b.size.y)
		if b.view_off.y > limit + 1 || app.snap_bottom {
			b.view_anim[1] = {}
			app.stick_jump = true
			build(app, size, nil, 0)
			app.stick_jump = false
		}
	}
	app.snap_bottom = false
	app.chat.keep_id = ""
	if b := app.chat_sb; b != nil { load_older(app, b) }
	platform.set_cursor(app.win, ui.cursor(&app.ui_state))
	draw.begin_frame(&app.dc, size)
	render.frame_begin(&app.r, hex(HEX_BG0))
	ui.draw_tree(&app.ui_state, &app.dc)
	draw.end_frame(&app.dc)
	render.frame_end(&app.r, !at_once)
	render.paced_present(&app.pacer)
	free_all(context.temp_allocator)

	nav_apply(app)
	if app.refresh_due && ui.now_ms() - app.refresh_ms > REFRESH_DEBOUNCE_MS {
		app.refresh_due = false
		app.refresh_ms = ui.now_ms()
		refresh_sessions(app)
	}
	if app.stats_pending && app.chat.loaded && app.chat.have_self { app.stats_pending = false; stats_open(app) }
	servers_rediscover(app)
	if app.facts_due && ui.now_ms() - app.facts_ms > FACTS_DEBOUNCE_MS {
		// an action of the settings (connect an MCP server, revoke a permission): read the pages again
		app.facts_due = false
		app.facts_ms = ui.now_ms()
		if app.settings_open { server_facts_load(app) }
	}
	if app.children_due && ui.now_ms() - app.children_ms > CHILDREN_DEBOUNCE_MS {
		app.children_due = false
		app.children_ms = ui.now_ms()
		load_children(app)
	}
}

// The faces looked for when the preference is "" (automatic), in order; the toolkit's embedded Roboto and Inconsolata
// when none is installed (or when the preference says "built-in").
when ODIN_OS == .Windows {
	UI_FACES   :: []string{"Segoe UI Variable Text", "Segoe UI"}
	MONO_FACES :: []string{"Cascadia Mono", "Cascadia Code", "JetBrains Mono", "Consolas"}
} else {
	UI_FACES   :: []string{"Inter", "Cantarell", "Noto Sans", "Ubuntu", "DejaVu Sans"}
	MONO_FACES :: []string{"JetBrains Mono", "Cascadia Mono", "Fira Code", "Noto Sans Mono", "Ubuntu Mono", "DejaVu Sans Mono"}
}
FONT_BUILTIN :: "built-in"   // an older preference's value for the embedded face: as automatic
FONT_SYSTEM  :: "system"     // the preferences' value for the system's usual face
FONT_SAME    :: "interface"  // appearance.prose_font: the answers in the interface's face

// The client's own faces (open licences, Latin: assets/fonts): the interface, the answers, code. Weights as the code asks them.
Own_Faces :: struct { ui, prose, mono: [4]font.Font_Id, mono_bold: font.Font_Id }   // regular, bold, italic, bold italic
PROSE_OWN_SCALE  :: 1.08   // Newsreader's small letters are low: larger than the text around it, to read as large
PROSE_LINE_RATIO :: 1.36   // of the answers' size: the height of their lines

LUCIDE_TTF :: #load("../assets/fonts/lucide.ttf")

// The fonts that do not change: the icons (Lucide, embedded) and the toolkit's own glyphs. The faces of the text come
// from the preferences (fonts_apply).
load_fonts :: proc(app: ^App) -> bool {
	ok: bool
	if app.icons, ok = font.load_embedded(&app.fonts, LUCIDE_TTF); !ok { return false }
	app.tk_icons, _ = font.load_embedded(&app.fonts, ui.ICON_FONT_DATA)
	app.font, ok = font.load_embedded(&app.fonts, font.FALLBACK_UI_DATA)   // (until the preferences are read)
	app.mono, _ = font.load_embedded(&app.fonts, font.FALLBACK_MONO_DATA)
	app.mono_bold = app.mono
	app.prose = app.font
	own :: proc(app: ^App, data: []u8, or_else_face: font.Font_Id) -> font.Font_Id {
		f, loaded := font.load_embedded(&app.fonts, data)
		return loaded ? f : or_else_face
	}
	app.own.ui = {own(app, #load("../assets/fonts/hanken-grotesk-400.ttf"), app.font), own(app, #load("../assets/fonts/hanken-grotesk-600.ttf"), app.font),
		own(app, #load("../assets/fonts/hanken-grotesk-400-italic.ttf"), app.font), own(app, #load("../assets/fonts/hanken-grotesk-600-italic.ttf"), app.font)}
	app.own.prose = {own(app, #load("../assets/fonts/newsreader-400.ttf"), app.font), own(app, #load("../assets/fonts/newsreader-600.ttf"), app.font),
		own(app, #load("../assets/fonts/newsreader-400-italic.ttf"), app.font), own(app, #load("../assets/fonts/newsreader-600-italic.ttf"), app.font)}
	regular := own(app, #load("../assets/fonts/dm-mono-400.ttf"), app.mono)
	app.own.mono = {regular, regular, regular, regular}
	app.own.mono_bold = own(app, #load("../assets/fonts/dm-mono-500.ttf"), regular)
	return ok
}

// The face of `want` ("" automatic: the client's own; FONT_SYSTEM: the first of `auto` installed; else that family, the
// client's own when it is not installed). `name` "": the client's own.
@(private = "file")
face_resolve :: proc(app: ^App, want: string, auto: []string, builtin: font.Font_Id) -> (id: font.Font_Id, name: string) {
	if want == FONT_SYSTEM {
		for a in auto { if f, ok := font.load_system(&app.fonts, a); ok { return f, a } }
	} else if want != "" && want != FONT_BUILTIN {
		if f, ok := font.load_system(&app.fonts, want); ok { return f, want }
	}
	return builtin, ""
}

// Regular, bold, italic, bold italic of a family of the system (what it lacks: the regular).
@(private = "file")
system_set :: proc(app: ^App, family: string, regular: font.Font_Id) -> (set: [4]font.Font_Id) {
	set = {regular, regular, regular, regular}
	if f, ok := font.load_system(&app.fonts, family, WEIGHT_UI_BOLD); ok { set[1] = f }
	if f, ok := font.load_system(&app.fonts, family, WEIGHT_REGULAR, .Italic); ok { set[2] = f }
	if f, ok := font.load_system(&app.fonts, family, WEIGHT_UI_BOLD, .Italic); ok { set[3] = f }
	return
}

WEIGHT_MONO_BOLD :: 700
WEIGHT_UI_BOLD   :: 600
WEIGHT_REGULAR   :: 400

// --font-dir=<folder>: faces tried from files, nothing installed (tools/font_proposals.mjs): ui, ui-bold, ui-italic,
// ui-bold-italic, mono, mono-bold and, for the answers when they are another family than the interface, prose, prose-bold,
// prose-italic, prose-bold-italic (.ttf). A file that is not there leaves what the preferences gave.
@(private = "file")
fonts_from_dir :: proc(app: ^App) {
	dir := ""
	for a in os.args[1:] { if strings.has_prefix(a, "--font-dir=") { dir = a[len("--font-dir="):] } }
	if dir == "" { return }
	face :: proc(app: ^App, dir, name: string, or_else_face: font.Font_Id) -> font.Font_Id {
		f, ok := font.load_from_file(&app.fonts, pjoin({dir, fmt.tprintf("%s.ttf", name)}))
		return ok ? f : or_else_face
	}
	app.font = face(app, dir, "ui", app.font)
	app.mono = face(app, dir, "mono", app.mono)
	app.mono_bold = face(app, dir, "mono-bold", app.mono)
	app.ui_state.mono_font = app.mono
	bold := face(app, dir, "ui-bold", app.font)
	italic := face(app, dir, "ui-italic", app.font)
	bi := face(app, dir, "ui-bold-italic", bold)
	ui.rich_set_faces(&app.ui_state, app.font, bold, italic, bi)
	app.prose = face(app, dir, "prose", app.font)
	if app.prose != app.font {
		ui.rich_set_faces(&app.ui_state, app.prose, face(app, dir, "prose-bold", app.prose), face(app, dir, "prose-italic", app.prose), face(app, dir, "prose-bold-italic", app.prose))
	}
}

// The text faces from the preferences appearance.font and appearance.mono_font (at start, and when either changes).
fonts_apply :: proc(app: ^App) {
	want_ui := config.string_of(&app.cfg_prefs, "appearance.font")
	want_mono := config.string_of(&app.cfg_prefs, "appearance.mono_font")
	want_prose := config.string_of(&app.cfg_prefs, "appearance.prose_font")
	app.font, app.ui_face = face_resolve(app, want_ui, UI_FACES, app.own.ui[0])
	mono_face: string
	app.mono, mono_face = face_resolve(app, want_mono, MONO_FACES, app.own.mono[0])
	app.mono_bold = app.own.mono_bold
	if mono_face != "" {
		app.mono_bold = app.mono
		if b, ok := font.load_system(&app.fonts, mono_face, WEIGHT_MONO_BOLD); ok { app.mono_bold = b }
	}
	app.ui_state.mono_font = app.mono
	ui_set := app.ui_face != "" ? system_set(app, app.ui_face, app.font) : app.own.ui
	ui.rich_set_faces(&app.ui_state, app.font, ui_set[1], ui_set[2], ui_set[3])
	// the answers: their own face, the interface's, or a family of the system
	prose_face := ""
	prose_own := want_prose == "" || want_prose == FONT_BUILTIN
	app.prose = app.font
	if prose_own {
		app.prose = app.own.prose[0]
		ui.rich_set_faces(&app.ui_state, app.prose, app.own.prose[1], app.own.prose[2], app.own.prose[3])
	} else if want_prose != FONT_SAME {
		if f, ok := font.load_system(&app.fonts, want_prose); ok {
			app.prose, prose_face = f, want_prose
			set := system_set(app, want_prose, f)
			ui.rich_set_faces(&app.ui_state, f, set[1], set[2], set[3])
		}
	}
	app.prose_scale = prose_own ? PROSE_OWN_SCALE : 1
	delete(app.prose_face)
	app.prose_face = strings.clone(prose_face)
	fonts_from_dir(app)
	delete(app.mono_face)
	app.mono_face = strings.clone(mono_face)
	delete(app.fonts_wanted)
	app.fonts_wanted = strings.concatenate({want_ui, "\n", want_mono, "\n", want_prose})
}

SCALE_MIN            :: 0.5   // what --scale= accepts
SCALE_MAX            :: 4
WINDOW_W             :: 1320
WINDOW_H             :: 860
POSTS_CAPACITY       :: 4096
POSTS_PER_BUILD      :: 4000
CHECK_FRAME_SLEEP_MS :: 50    // --frames=N
ANIMATION_WAIT_MS    :: 33    // the longest sleep while something pulses

main :: proc() {
	frames := -1   // --frames=N: N frames of the hidden window, then exit (a check that it runs)
	forced_scale: f32 = 0   // --scale=<factor>
	start_session := ""   // --session=<id>: the session opened at start (else the latest)
	for a in os.args[1:] {
		if strings.has_prefix(a, "--frames=") { frames, _ = strconv.parse_int(a[len("--frames="):]) }
		if strings.has_prefix(a, "--session=") { start_session = a[len("--session="):] }
		if strings.has_prefix(a, "--scale=") { if v, ok := strconv.parse_f32(a[len("--scale="):]); ok && v >= SCALE_MIN && v <= SCALE_MAX { forced_scale = v } }
	}
	// --install / --uninstall / --status: the desktop integration, without a window
	if handled, code := desktop_cli(); handled { os.exit(code) }
	set_app_id()           // (before the first window: the taskbar groups it under the shortcuts)
	desktop_clean_old()

	app := new(App)
	the_app = app
	app.sidebar_w = SIDEBAR_W_DEFAULT
	app.start_session = start_session
	app.scale = forced_scale
	app.seek_subagent = slice.contains(os.args, "--seek-subagent")
	app.stats_pending = slice.contains(os.args, "--stats")
	app.stick_bottom = true
	chat_reset(&app.chat)

	servers_init(app)

	font.init(&app.fonts)
	// a composition swap chain whose buffers keep the monitor's size while the window is resized: the window shows their
	// top-left part 1:1, clipped by its client area, so a frame of the old size is never stretched over the new one (as
	// Wren's browser.window.fixed_surface). Where DirectComposition is missing it is an ordinary swap chain.
	app.win = platform.open_window("opencode", {WINDOW_W, WINDOW_H}, transparent = true, integrated_title = true)
	if app.win == nil { fmt.eprintln("opencode-native: no window"); os.exit(1) }
	for a in os.args[1:] {   // --size=<w>x<h>: the window's size in pixels, whichever screen it opens on (tools/screenshots.mjs)
		if !strings.has_prefix(a, "--size=") { continue }
		wh := strings.split(a[len("--size="):], "x", context.temp_allocator)
		if len(wh) != 2 { continue }
		w, w_ok := strconv.parse_f32(wh[0])
		h, h_ok := strconv.parse_f32(wh[1])
		if w_ok && h_ok { platform.set_size(app.win, {int(math.round(w / app.win.dpi_scale)), int(math.round(h / app.win.dpi_scale))}) }
	}
	if !render.init_window(&app.r, app.win, app.win.size, transparent = true) { fmt.eprintln("opencode-native: no renderer"); os.exit(1) }
	if !slice.contains(os.args, "--no-fixed-surface") { render.set_fixed_surface(&app.r, platform.monitor_size(app.win)) }
	if !load_fonts(app) { fmt.eprintln("opencode-native: no UI font"); os.exit(1) }
	draw.init(&app.dc, &app.r, &app.fonts)
	logo_load(app)
	theme_setup(&app.theme)
	ui.init(&app.ui_state, &app.fonts, &app.theme)
	app.ui_state.icon_font = app.tk_icons
	ui.set_toast_position(&app.ui_state, .Top_Right)
	prefs_init(app)   // (after ui.init: it sets the zoom, the density, the rounding and the palette)
	if app.servers_in_clear { servers_save(app) }
	ui.post_configure(&app.ui_state, capacity = POSTS_CAPACITY, overflow = .Block, per_build = POSTS_PER_BUILD, on_drop = on_drop)
	platform.set_dark_title(app.win, true)
	app.devtools = devtools.start_from_env(app.win, "opencode")
	app.win.user = app
	app.win.on_frame = proc(user: rawptr) { frame((^App)(user), inner = true) }
	app.last_tick = time.tick_now()
	app.frames = FRAMES_AFTER_INPUT

	// the event stream: its first connection loads everything (stream_state)
	server_connect(app, app.server)
	if app.conn == nil { fmt.eprintln("opencode-native: the HTTP client failed to start"); os.exit(1) }

	if frames >= 0 {
		for _ in 0 ..< frames { frame(app); time.sleep(CHECK_FRAME_SLEEP_MS * time.Millisecond) }
		fmt.printfln("opencode-native: %d frames, %d boxes, online=%v, %d sessions, %d messages", frames, app.ui_state.boxes_built, app.online, len(app.sessions), len(app.chat.messages))
		os.exit(0)
	}

	setup_offer_at_start(app)
	for a in os.args[1:] {   // --search=<text>: the sidebar's search, filled at start; --setup: the Setup dialog
		if strings.has_prefix(a, "--search=") { ui.field_set(&app.search, a[len("--search="):]) }
		if a == "--setup" { setup_open(app) }
		if a == "--add-server" { server_edit_open(app, -1) }
		if strings.has_prefix(a, "--find=") { find_open(app); ui.field_set(&app.find.field, a[len("--find="):]) }
		if strings.has_prefix(a, "--image=") { image_view_start(app, a[len("--image="):]) }
	}
	for a in os.args[1:] {   // --settings[=page number]: the settings open at start
		if a == "--settings" || strings.has_prefix(a, "--settings=") {
			settings_open(app)
			if n, ok := strconv.parse_int(strings.trim_prefix(a, "--settings=")); ok && n >= 0 && n < len(Settings_Page) { app.settings_page = Settings_Page(n) }
		}
	}
	platform.show_window(app.win)
	for !platform.is_closed(app.win) && !app.quit {
		if app.frames == 0 && !ui.needs_frame(&app.ui_state) {
			wait := ui.wake_in_ms(&app.ui_state)
			if app.animating { wait = wait > 0 ? min(wait, ANIMATION_WAIT_MS) : ANIMATION_WAIT_MS }
			platform.wait_event(app.win, wait)
			app.idled = true
		}
		frame(app)
		if app.frames > 0 { app.frames -= 1 }
	}
	// the event thread may be blocked in a read: the process ends with it
	sync.atomic_store(&app.conn.stop, true)
	ui.post_close(&app.ui_state)
	os.exit(0)
}

