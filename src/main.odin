// opencode, native: a desktop client for the opencode v2 server, on gui_toolkit (Direct3D 11, DirectWrite).
//   build.bat            -> build\opencode-native.exe
//   opencode-native.exe [--url=http://127.0.0.1:4096] [--password=...]
// Without arguments it finds this computer's opencode server (~/.local/state/opencode/service.json, else ~/.config/opencode/service.json).
package occ

import "core:fmt"
import "core:mem/virtual"
import "core:math"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:time"
import "gt:config"
import "gt:devtools"
import "gt:draw"
import "gt:font"
import "gt:host"
import "gt:platform"
import "gt:render"
import "gt:ui"

// A face of the fonts. (Inside App, `font` names the face of the interface, from host.Shared: not the package.)
Face_Id :: font.Font_Id

App :: struct {
	using gfx:    host.Shared,   // the renderer, the drawing, the fonts, the theme, the interface's face (font)
	using window: host.Host,     // the main window: win, its interface (state), its pacing, what it still owes (settle)
	prose, mono, mono_bold, icons, tk_icons: Face_Id,   // (Face_Id: in here, font is the interface's face, host.Shared's)
	own:           Own_Faces,
	prose_scale:   f32,        // the answers' size, of the text around them
	prose_face:    string,     // the system face of the answers ("": not one)
	ui_face:       string,     // the system face of the interface ("": the embedded one)
	mono_face:     string,     // the same for code
	fonts_wanted:  string,     // the two font preferences fonts_apply last applied (prefs_refresh compares)
	font_families: []string,   // the installed families (read when a font picker first opens)

	cx:             App_Context,       // what the window keeps from frame to frame, beside the panels' own state

	// the server
	servers:        [dynamic]Server,   // (servers.odin) this computer's first
	server:         int,               // the one connected
	conn:           ^Conn,             // its connection
	server_edit:    Server_Edit,
	picker:         Picker,            // the composer's agent or model picker (picker.odin)
	history:        History,           // what was sent, Up and Down in the composer (history.odin)
	activity:       Activity,          // what runs behind the conversation (activity.odin)
	palette:        Palette,           // Ctrl+K (palette.odin)
	throbber:       Throbber,          // what says a run goes on (throbber.odin)
	preview:        Preview,           // the page beside the conversation (preview.odin)
	browser:        Browser,           // the agents' tools on that page (browser_mcp.odin)
	updater:        Updater,           // a new version: checked, downloaded, in place (updater.odin)
	dock:           ui.Dock,           // ... and the panels' layout
	rename:         Rename,            // a session's title (context_menus.odin)
	find:           Find,              // find in the conversation (find.odin)
	scale:          f32,               // --scale=<factor>: the interface's scale whatever the screen says (0: the screen's)
	servers_in_clear: bool,            // read passwords in clear from an older version's file: saved protected at start
	rediscover_ms:  f64,               // when this computer's server was last looked for (servers_rediscover)
	pending:        i32,       // (atomic) requests in flight

	using known:     Server_Known,      // what we know, as long as that server is the one
	chat:            Chat,
	using view:      Chat_View_State,   // where the conversation shown is read (one per session shown: open_chat starts it over)

	// the interface's own state
	composer:         ui.Text_Area,
	composer_focused: bool,
	search:           ui.Text_Field,
	nav:              [dynamic]string, // the sessions drilled down from, outermost first (owned): Back returns to the last
	nav_steps:        [dynamic]Nav_Step, // navigation asked for in this frame (subagents.odin)
	sub_open:         map[u64]bool,   // sidebar: sessions whose sub-agents are listed under them
	start_session:    string,
	cfg_prefs:        config.Prefs,   // the preferences (settings.odin)
	prefs_file:       string,         // where they are saved ("": nowhere)
	prefs:            Prefs,          // their plain values
	facts:            Server_Facts,   // what the server said for the settings pages
	settings_open:    bool,
	settings_page:    Settings_Page,
	settings_query:   ui.Text_Field,    // the settings' search: while it has text, the matching settings of every client page
	settings_search:  config.Search,    // what that text shows, this frame (settings_dialog)
	setting_hidden:   bool,             // the row being built does not match the search: setting_end has nothing to close
	seek_subagent:    bool,   // --seek-subagent (tests): scroll to the first sub-agent card
	sidebar_w:        f32,
	expanded:         map[u64]bool,   // tool and reasoning parts opened by the user (hash of their id)
	folded:           map[u64]bool,   // sidebar groups folded (hash of the directory)
	delete_id:        string,
	delete_open:      bool,
	menu_session:     string,         // the session the context menu is about (owned)
	logo:             Logo,
	column_w:         f32,    // the conversation column, frame pixels (this frame)
	chat_sb:          ^ui.Box, // the conversation scroll box, when built this frame
	stats_open:       bool,           // the Statistics panel of the session shown (stats.odin)
	proj_stats:       Project_Stats,
	images:           map[u64]Image_Entry,   // decoded images, by key and size (images.odin)
	frame_no:         u64,
	view_open:        bool,                  // the image viewer
	view_key:         u64,
	view_ref:         Image_Ref,             // what is shown: what Copy decodes again whole (its data and name owned)
	view_zoom:        f32,                   // times what fits (image_viewer)
	view_pan:         [2]f32,                // of the picture's centre from the view's, frame pixels
	view_grab:        [2]f32,                // view_pan when the drag began
	view_resize_from: [3]f32,                // a grip of the viewer held: the dialog's size (logical pixels) and scale at its press ({}: none)
	view_start:       Image_Ref,             // --image=<file>: opened in the viewer once it is decoded (its data owned)
	devtools:         ^devtools.Server,   // TOOLKIT_DEVTOOLS=<port>: driven over the Chrome DevTools Protocol (the toolkit's tk cdp, or gt:cdp in occtools)
	setup:            Setup_UI,
	quit:             bool,
	last_tick:        time.Tick,
	frame_times:      Frame_Times,   // the last frame's steps
}

// Where the conversation shown is read, and how it moves: it starts over with another session.
Chat_View_State :: struct {
	opened_ms:    f64,       // when it was opened (it follows its bottom at first)
	stick_bottom: bool,
	stick_jump:   bool,      // the second build of a frame: the bottom is reached at once, no glide
	snap_bottom:  bool,      // its first page arrived: shown at its bottom in that frame (frame)
	chat_target:  f32,       // its scroll target at the end of the last build (a drag before this one moved it)
	anchor:       ^ui.Box,   // a part header just clicked: kept where it is on screen (part_toggle, frame)
	anchor_y:     f32,
}

// What a server told, and nothing else: it starts from zero with the next one (server_known_end). A field added here does too. (What has a
// Remote stays out: a late answer of the last server compares its ticket with it, and a count that started over could match.)
Server_Known :: struct {
	link:            Conn_State,
	server_version:  string,
	sessions:        [dynamic]Session_Info,
	sess_arena:      virtual.Arena,
	sessions_loaded: bool,
	opened_first:    bool,
	busy:            map[string]bool,   // sessions running (keys owned)
	agents:          [dynamic]Agent_Info,
	models:          [dynamic]Model_Info,
	permissions:     [dynamic]Permission,
	projects:        map[string]Project_Logo,   // by project id (in proj_arena)
	proj_arena:      virtual.Arena,
}

// What the window keeps from one frame to the next that belongs to no panel: what is due, what is open, where things are.
App_Context :: struct {
	column_drag_from:    f32,                  // the conversation's width when a handle of it was pressed (views.odin column_handles)
	composer_fit:        struct { level: int, at: [2]f32 },   // what the composer's toolbar leaves out, and at which widths (views.odin composer_fit)
	theme:               Theme_State,          // the themes, the one shown, its colours (theme.odin)
	film_slow:           f64,                  // --slow-motion (film.odin): 0, the interface's time is the system's
	film_clock:          f64,                  // what ui.now_ms says then
	film_clock_at:       f64,
	film_begun:          time.Tick,
	pending_since:       f64,                  // when requests went from none to some (the status bar)
	system_stripes:      font.Subpixel_Text,   // what the system does with text (text_mode_follow)
	system_stripes_read: bool,
	conns:          [dynamic]^Conn,    // every connection made: their threads stop at close (servers.odin threads_stop)
	outgoing:       [dynamic]^Outgoing,   // prompts between the composer and the server (outgoing.odin)
	outgoing_last:  u64,               // ... the last one's id
	waits_unread:   bool,              // the stream just came up: what sessions wait on, asked before it, is read from the next list
	built:          ^ui.State,         // the state of a window of its own, while it is built (nil: the main one)
	answers_spent:  [dynamic]^virtual.Arena,   // what this frame's answers were read into (net.odin)
	image_queue:    [dynamic]^Decode_Job,      // images waiting for a decoder, the last asked for first (images.odin)
	image_decoding: int,                       // ... decoders at work
	flights:        [dynamic]Flight,   // what is on its way (net.odin)
	stream_seq:     Seq,               // events applied so far: the clock of what is newer than an answer (Request.asked_at)
	busy_seq:       map[string]Seq,    // when the stream last said a session started or ended (keys owned)
	waits_gone:     Gone_List,         // permissions and forms answered, the last WAITS_GONE_MAX
	chat_read:      Remote,            // the newest page of the conversation shown
	stats_read:     Remote,            // the project's totals (stats.odin)
	stats_context:  Stats_Context,     // what fills the context of the session shown
	context_read:   Remote,            // ... its reading
	stats_w:        f32,               // the panel's width, at this build
	queue:          Queue,             // what waits in the inbox of the session shown (queue.odin)
	due:            [Due]Deferred,     // what was put off (remote.odin)
	reopen:         Nav_Place,         // what was shown when this computer's server moved (servers_rediscover), owned, id "": none
	quote_open:     bool,              // the chip at the end of a selection (context_menus.odin)
	quote_at:       Rect,
	quote_kept:     string,            // ... what it quotes (owned)
	quote_serial, quote_done: u64,     // ... which selection, and the last one quoted
	gliding:        bool,              // a panel's height moves in this build
	was_gliding:    bool,              // ... it did in the last one
	docked_w:       f32,               // the conversation's room as a panel of the dock (0: it is not one)
	help_open:      bool,              // the keyboard's dialog (commands.odin)
	dialogs:        [Dialog]Vec2,      // the sizes given to the dialogs (logical pixels, {}: what they prefer)
	dialogs_saved:  [Dialog]Vec2,
	dialogs_read:   bool,
	no_schedules, no_artifacts: bool,     // the server does not offer them (experimental.odin)
	chat_height:    f32,                  // of the conversation, at the last frame
	was_docked:     bool,                 // the conversation was in the dock (preview.odin main_area)
	show_licence:   bool,                 // Ghostty's, in the settings
	terms:          Terminals,            // the Terminal panel (terminal.odin)
	outputs:        Output_Views,         // commands' output, read as a terminal shows it (output_view.odin)
	schedules:      Schedules,            // schedules.odin
	artifacts:      Artifacts,
	diff_full:      Diff_Full,            // diff_full.odin
	detached:       [dynamic]^Detached,   // detached.odin
	web_host:       Web_Host,             // what makes web views (preview_views.odin)
	web_views:      [dynamic]^Web_View,   // ... those alive, every session's tabs together
	previews:       map[string]^Preview,  // the browsers of the sessions not shown, by session (keys: their own)
	preview_clock:  u64,                  // ... what Preview_Tab.used counts in
	preview_tabs_made: u64,               // ... what their ids count
	plugins:        Plugins,
	integrations:   Integrations,         // the Connections page (integrations.odin)
	mentions:       Mentions,             // @ in the composer (files.odin)
	slash_pick:     Slash_Pick,           // / in the composer (slash.odin)
	background:     map[string]bool,      // the sessions with commands running in the background, and their parents (activity.odin; keys owned)
	drafts:         map[string]Draft,     // each session's composer while another is shown (drafts.odin; keys owned)
	drafts_seen:    string,               // the composer's text when drafts_track last looked (owned)
	files:          Files,                // the dialog of the folder's files
	changes:        Changes,              // what a session changed, or would undo (session_tools.odin)
	forms:          [dynamic]^Form_Req,   // what agents ask and wait for (forms.odin), of every session
	nav_hist:       [dynamic]Nav_Place,   // where one has been (subagents.odin nav_visit)
	nav_at:         int,                  // where one is in it
	nav_moving:     bool,                 // a step of the history: nothing to add to it
	restore_msg:    string,               // the message the view goes back to (owned, "": none) and how far into it
	restore_dy:     f32,
	restore_still:  int,                  // builds it stayed there
	shared_moved:   bool,                 // something of what every window shows may have changed this frame (detached_still)
	posts_run_seen: u64,                  // ... the count of posts run at the last frame
	wheeled:        bool,                 // a wheel turned in this frame (views.odin: a hand moved the conversation)
	commands_due:   [dynamic]^Command, // to run after this frame, in order (commands.odin)
	slash:          [dynamic]Slash,    // the server's commands
	have_slash:     bool,
	attachments:    [dynamic]Attachment,   // what goes with the prompt (attachments.odin)
	ctx:            Ctx_Target,        // what the menu of a right click is about (context_menus.odin)
	ctx_taken:      bool,              // a right press of this build found its target
	focus_composer: bool,              // the composer takes the focus at its next build
	fork_prompt:    string,            // the prompt a fork left out, for the composer of the new session (owned)
	sidebar_hidden: bool,
	side_hold:      Side_Hold,         // the order of the sidebar, under the pointer (sidebar.odin)
	main_rect:      Rect,              // the conversation's place (Ctrl and the wheel over it zoom it)
	frame_ms:       f32,               // what the status bar's rate says: between two frames, smoothed
	work_ms:        f32,               // ... what a frame costs (build, draw, render)
	pointer_ms:       f64,    // when the pointer or the wheel last moved (pace)
}

// How long the steps of a frame took (bench_test.odin reads them).
Frame_Times :: struct {
	build:   time.Duration,   // every build of the frame (input, layout)
	draw:    time.Duration,   // the boxes drawn into the draw lists
	render:  time.Duration,   // the lists submitted and the frame presented
	builds:  int,
}

@(thread_local) the_app: ^App   // (the interface's thread: a thread of work is given its App)

// (the window being built's, or the main one's)
clip_get :: proc() -> string { return ui.window_clipboard_get() }
clip_set :: proc(text: string) { ui.window_clipboard_set(text) }

// The main window is a host.Host (host_adopt: the window, the device loaded on a thread and the fonts are this program's own start). Its
// frame is the toolkit's, in the order its parts must come (host.host_frame); what is this program's goes in its hooks.
frame :: proc(app: ^App, inner := false) { host.host_frame(&app.window, inner) }

main_window_adopt :: proc(app: ^App) {
	host.host_adopt(&app.window, &app.gfx, app.win, nil, app)
	h := &app.window
	h.after_input = FRAMES_AFTER_INPUT
	h.background = hex(HEX_BG0)
	h.partial_redraw = true   // each frame repaints only what changed
	h.dragging = main_dragging
	h.before_input = proc(h: ^host.Host) {
		app := (^App)(h.user)
		film_slow_tick(app)
		app.frame_no += 1
		devtools.service(app.devtools, &app.state, &app.r)
	}
	h.input = main_input
	h.builds = main_builds
	h.hold = proc(h: ^host.Host, size: draw.Vec2) -> int { return frame_held_ms((^App)(h.user), size) }
	h.after_frame = main_after_frame
}

// How the frame is paced: the toolkit's pacer (render/pacer.odin, on the cadence model). What matters most here is the resize step: a frame
// at a new size is presented at once (no wait for the swap chain, none for the refresh, two frames queued); waiting, the compositor shows
// the last frame stretched over the new size until one of that size arrives. A splitter or a scroll bar held paces as a drag: one frame per
// slot. So does a pointer or a wheel that moves with no button down: what follows it (a row lit under it, a page that scrolls) is read
// against the pointer itself, which the system draws at the screen's top rate. On a variable refresh screen that Windows reports at 60 Hz
// (here 180), as Continuous frames those waited for a 60 Hz refresh: every hover came 2 or 3 of the pointer's frames late.
@(private = "file")
main_dragging :: proc(h: ^host.Host) -> bool {
	app := (^App)(h.user)
	app.pacer.choices.target_hz = app.prefs.target_hz
	app.pacer.cadence.uncapped = app.prefs.uncapped
	moving := ui.now_ms() - app.cx.pointer_ms < POINTER_MOVING_MS || app.cx.gliding   // (a panel that opens: read as closely)
	return ui.active_key() != 0 || moving
}

FRAMES_AFTER_INPUT :: 3        // still drawn after an event, and at start: what it set off settles
DT_MIN_S           :: 0.0005
DT_MAX_S           :: 0.1      // after a long stall the animations go on, they do not jump
ANCHOR_BUILDS_MAX  :: 4        // builds spent on keeping a part header in place

// How soon an action is followed by reading again what it changed: a burst of events reads once.
REFRESH_DEBOUNCE_MS  :: 1200
FACTS_DEBOUNCE_MS    :: 700
CHILDREN_DEBOUNCE_MS :: 800

// A coverage per colour stripe sharpens text most at few pixels per letter: that is where it is automatic, if the system smooths
// that way. (The window may go from one screen to another. Smoothing along the rows alone, DirectWrite's Natural, is not an answer to
// anything here: without the smoothing across, these faces, which have no hinting, come out hard and stepped.)
text_mode_follow :: proc(app: ^App) {
	scale := app.scale > 0 ? app.scale : app.win.dpi_scale
	stripes: font.Subpixel_Text
	switch config.string_of(&app.cfg_prefs, "appearance.text_smoothing") {
	case "rgb":  stripes = .Rgb
	case "bgr":  stripes = .Bgr
	case "grey": stripes = .Off
	case:
		if !app.cx.system_stripes_read { app.cx.system_stripes, app.cx.system_stripes_read = font.system_subpixel_text(), true }
		if scale < TEXT_SMOOTH_SCALE { stripes = app.cx.system_stripes }
	}
	if app.fonts.settings.subpixel_text == stripes { return }
	settings := app.fonts.settings
	settings.subpixel_text = stripes
	font.set_settings(&app.fonts, settings)
}

// What a build of any window is given: they differ by their size and what came to them.
build_params :: proc(app: ^App, win: ^platform.Window, size: draw.Vec2, events: []platform.Event, dt: f32) -> ui.Build_Params {
	return {
		window_size = size, events = events, dt = dt, animations = animations_on(app),
		smooth_scroll = app.prefs.smooth_scroll ? .On : .Off,
		dpi_scale = app.scale > 0 ? app.scale : win.dpi_scale, window = win,
		base = ui.Style{pref = {.X = ui.text_size(), .Y = ui.px(30)}, font = app.font, font_size = app.prefs.font_size, text_pad = 6, cursor = .Arrow, radius = 6},
		clipboard_get = clip_get, clipboard_set = clip_set,
	}
}

// What the main window's input is, before the interface sees it: what goes to a shell or a command's output is taken out.
@(private = "file")
main_input :: proc(h: ^host.Host, read: []platform.Event) -> []platform.Event {
	app := (^App)(h.user)
	theme_follow_system(app)   // (the system went light or dark: an integer compared)
	events := read
	app.cx.shared_moved = false
	for e in events { if e.kind != .Mouse_Move && e.kind != .Scroll { app.cx.shared_moved = true } }   // (a pointer that passes over this window changes nothing in another)
	events = output_view_events(app, events)
	app.cx.wheeled = false
	events = term_events(app, events)
	for e in events {
		if e.kind == .Mouse_Move || e.kind == .Scroll { app.cx.pointer_ms = ui.now_ms() }
		if e.kind == .Scroll { app.cx.wheeled = true }
		if e.kind == .Scroll || e.kind == .Key_Press { nav_restore_clear(app) }   // (the reader goes elsewhere: the view is theirs)
		attach_drop_event(app, e)
		// the side buttons of the mouse, as in a browser
		if e.kind == .Mouse_Press && !overlay_open(app) {
			if e.button == .Back { if c := command_find("nav.back"); command_enabled(app, c) { command_run(app, c) } }
			if e.button == .Forward { nav_step(app, 1) }
		}
	}
	content_zoom_events(app, events)
	dialogs_track(app)
	text_mode_follow(app)
	return events
}

// The builds of a frame. (Its own dt: the film's slow motion has one, and the status bar's rate is read from it.)
@(private = "file")
main_builds :: proc(h: ^host.Host, size: draw.Vec2, events: []platform.Event, _: f32) {
	app := (^App)(h.user)
	now := time.tick_now()
	dt := film_slow_dt(app, clamp(f32(time.duration_seconds(time.tick_diff(app.last_tick, now))), DT_MIN_S, DT_MAX_S))
	app.last_tick = now
	if dt < FPS_RESTED_S { app.cx.frame_ms += (dt * 1000 - app.cx.frame_ms) * FPS_SMOOTH }   // (a rest is no frame rate)
	// `again`: another build of this frame. It runs no answer: a page read there would come after what the first build placed,
	// and its anchor would be dropped with the frame's. It waits for the next frame, which needs_frame asks for.
	build :: proc(app: ^App, size: draw.Vec2, events: []platform.Event, dt: f32, again := false) {
		app.cx.was_gliding = app.cx.gliding
		app.cx.gliding = false
		ui.set_scrollbar_autohide(&app.state, app.prefs.autohide_scrollbars)
		app.state.post_budget = again ? 0 : POSTS_PER_BUILD
		ui.begin_build(&app.state, build_params(app, app.win, size, events, dt))
		app.chat_sb = nil   // (only now: the answers begin_build ran read the last build's, a page placed by chat_load above all)
		build_ui(app)
		ui.end_build()
		app.frame_times.builds += 1
	}
	app.frame_times = {}
	t_build := time.tick_now()
	build(app, size, events, dt)
	prefs_track_zoom(app)
	// A part opened or closed in this build: the build drew it in its old state (the click comes after its body). Build
	// again in its new state, then scroll by what its header moved so that it stays under the pointer, and build once
	// more at that offset: the frame shows the result, never the steps.
	if a := app.anchor; a != nil {
		defer app.anchor = nil   // (kept through these builds: the bottom stays let go of)
		build(app, size, nil, 0, again = true)
		// (again while it moves: what this offset builds around it is measured only then, a page read before it above all)
		for _ in 0 ..< ANCHOR_BUILDS_MAX {
			b := app.chat_sb
			if b == nil { break }
			delta := a.rect.min.y - app.anchor_y
			if abs(delta) <= 0.5 { break }
			ui.view_jump(b, clamp(b.view_off.y + delta, 0, ui.view_limit(b)))   // (no glide toward an older target)
			build(app, size, nil, 0, again = true)
		}
	}
	// The conversation follows its bottom, placed from the last layout's content height: when this layout made it shorter
	// (a wider window re-wraps every paragraph on fewer lines), the picture would be scrolled past the end, empty, for a
	// frame. Build it again, placed from this layout (no events: they were the first build's). Content that grew too: a step of a run comes
	// all at once, and a glide to catch it up would push the bottom out of place and bring it back. The bottom stays, what is above moves.
	// A conversation's first page just arrived (a session opened): this build placed it from the empty one's bounds, at
	// its top. Build it again at its bottom, at once: no frame at the top, no glide down.
	if b := app.chat_sb; b != nil && app.stick_bottom {
		limit := ui.view_limit(b)
		grew := b.view_bounds.y > app.cx.chat_height + 0.5 && b.view_off.y < limit - 0.5
		if b.view_off.y > limit + 1 || app.snap_bottom || grew {
			b.view_anim[1].active = false   // (the glide stops where it is: the second build reaches the bottom at once)
			app.stick_jump = true
			build(app, size, nil, 0, again = true)
			app.stick_jump = false
		}
	}
	if b := app.chat_sb; b != nil { app.cx.chat_height = b.view_bounds.y }
	app.snap_bottom = false
	app.chat.keep_id = ""
	if b := app.chat_sb; b != nil { load_older(app, b) }
	app.frame_times.build = time.tick_since(t_build)
}

// Between two frames: what the frame set off, what the page said, what is due, then the windows of their own.
@(private = "file")
main_after_frame :: proc(h: ^host.Host) {
	app := (^App)(h.user)
	app.frame_times.draw, app.frame_times.render = h.times.draw, h.times.present
	work := f32(time.duration_milliseconds(app.frame_times.build + app.frame_times.draw + app.frame_times.render))
	app.cx.work_ms += (work - app.cx.work_ms) * FPS_SMOOTH
	h.times = {}   // (a frame held draws nothing: it costs nothing either)
	answers_spent_free(app)
	if run := ui.post_stats(&app.state).run; run != app.cx.posts_run_seen {   // (an answer, a shell's output, an event of the server)
		app.cx.posts_run_seen = run
		app.cx.shared_moved = true
	}
	terminals_reap(app)
	output_views_tick(app)
	web_events_drain(app)   // (the one place: what the page said during the frame, a modal dialog's message loop included)
	nav_apply(app)
	commands_apply(app)
	preview_follow(app)
	terms_close_due(app)
	if !panel_detached(app, u32(Panel.Preview)) { preview_place(app, overlay_open(app) || ui.dock_held(&app.dock)) }
	browser_tick(app)
	servers_rediscover(app)
	activity_tick(app)
	deferred_tick(app)
	detached_frames(app)
}

// A conversation just opened, its first page on its way: an empty page shown for the instant that takes is a blink, from what was there to
// nothing to the conversation. What was there stays on the screen meanwhile, and the page comes the moment it is read: it waits for
// nothing. Only what is shown is held: input is read and built as ever. How long more, in ms (0: show the frame). A server that takes
// longer gets its "Loading"; a window with nothing on it yet, or of another size, has no picture to keep.
frame_held_ms :: proc(app: ^App, size: draw.Vec2) -> int {
	if chat_view(app) != .Loading || app.shown != {int(size.x), int(size.y)} { return 0 }   // (shown: the size of the last picture)
	return max(int(OPEN_HOLD_MS - (ui.now_ms() - app.opened_ms)), 0)
}

due_run :: proc(app: ^App, k: Due) {
	switch k {
	case .Refresh:   refresh_sessions(app)
	case .Facts:     if app.settings_open { server_facts_load(app) }   // (an action of the settings: connect an MCP server, revoke a permission)
	case .Children:  load_children(app)
	case .Context:   if app.stats_open { context_ask(app) }
	case .Restore:   nav_restore_clear(app)
	case .Term_Size: terms_size_due(app)
	case .Side_Wake: app.settle = max(app.settle, FRAMES_AFTER_INPUT)   // (the build sees the pointer has rested)
	case .Drafts:    drafts_save(app)
	}
}

due_tick :: proc(app: ^App, k: Due) {
	if !deferred_take(&app.cx.due[k]) { return }
	due_run(app, k)
	app.cx.shared_moved = true
}

// What was put off: done if it is time, and a wake for the rest. A window at rest wakes only while something is due: the window
// may sleep on, and a read that waits for the next input would wait for good.
deferred_tick :: proc(app: ^App) {
	cx := &app.cx
	for k in Due { due_tick(app, k) }
	soonest := 0
	for &d in cx.due { if ms := deferred_in_ms(&d); ms > 0 { soonest = soonest == 0 ? ms : min(soonest, ms) } }
	for ms in ([?]int{activity_in_ms(app), rediscover_in_ms(app), browser_in_ms(app)}) {
		if ms > 0 { soonest = soonest == 0 ? ms : min(soonest, ms) }
	}
	if soonest > 0 { ui.wake_within(&app.state, soonest) }
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

// --font-dir=<folder>: faces tried from files, nothing installed (occtools font_proposals): ui, ui-bold, ui-italic,
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
	app.state.mono_font = app.mono
	bold := face(app, dir, "ui-bold", app.font)
	italic := face(app, dir, "ui-italic", app.font)
	bi := face(app, dir, "ui-bold-italic", bold)
	ui.rich_set_faces(&app.state, app.font, bold, italic, bi)
	app.prose = face(app, dir, "prose", app.font)
	if app.prose != app.font {
		ui.rich_set_faces(&app.state, app.prose, face(app, dir, "prose-bold", app.prose), face(app, dir, "prose-italic", app.prose), face(app, dir, "prose-bold-italic", app.prose))
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
	app.state.mono_font = app.mono
	ui_set := app.ui_face != "" ? system_set(app, app.ui_face, app.font) : app.own.ui
	ui.rich_set_faces(&app.state, app.font, ui_set[1], ui_set[2], ui_set[3])
	// the answers: their own face, the interface's, or a family of the system
	prose_face := ""
	prose_own := want_prose == "" || want_prose == FONT_BUILTIN
	app.prose = app.font
	if prose_own {
		app.prose = app.own.prose[0]
		ui.rich_set_faces(&app.state, app.prose, app.own.prose[1], app.own.prose[2], app.own.prose[3])
	} else if want_prose != FONT_SAME {
		if f, ok := font.load_system(&app.fonts, want_prose); ok {
			app.prose, prose_face = f, want_prose
			set := system_set(app, want_prose, f)
			ui.rich_set_faces(&app.state, f, set[1], set[2], set[3])
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
ANIMATION_WAIT_MS    :: 16    // the longest sleep while something pulses (33 made a stutter of what glides)

// What the window's interface needs once it has a renderer (and the fonts, fonts_init): the state, the theme, the
// preferences (read from `prefs_file`; "": the defaults), the queue of what the threads post. A test makes the same on an
// offscreen window.
app_init :: proc(app: ^App, prefs_file: string) {
	draw.init(&app.dc, &app.r, &app.fonts)
	logo_load(app)
	theme_setup(&app.theme)
	ui.init(&app.state, &app.fonts, &app.theme)
	app.state.icon_font = app.tk_icons
	ui.set_toast_position(&app.state, .Top_Right)
	ui.set_autoscroll_enabled(&app.state, true)   // a click of the wheel scrolls by the pointer, as in the browsers
	prefs_init(app, prefs_file)   // (after ui.init: it sets the zoom, the density, the rounding and the palette)
	history_init(app, prefs_file != "" ? pjoin({filepath.dir(prefs_file), "history.jsonl"}) : "")
	palette_init(app, prefs_file != "" ? pjoin({filepath.dir(prefs_file), "palette_usage.txt"}) : "")
	ui.post_configure(&app.state, capacity = POSTS_CAPACITY, overflow = .Block, per_build = POSTS_PER_BUILD, on_drop = on_drop)
}

// The fonts, before the renderer: they load while the graphics device is made (render.preload_device).
fonts_init :: proc(app: ^App) -> bool {
	font.init(&app.fonts)
	return load_fonts(app)
}

main :: proc() {
	started := time.tick_now()
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
	// the graphics device on a thread of its own while the rest starts (the driver's load is the longest step: 160 ms here)
	render.preload_device()
	set_app_id()           // (before the first window: the taskbar groups it under the shortcuts)
	desktop_clean_old()

	app := new(App)
	the_app = app
	app.sidebar_w = SIDEBAR_W_DEFAULT
	app.start_session = start_session
	app.scale = forced_scale
	app.seek_subagent = slice.contains(os.args, "--seek-subagent")
	app.stick_bottom = true
	chat_home(app)

	servers_init(app)

	// a composition swap chain whose buffers keep the monitor's size while the window is resized: the window shows their
	// top-left part 1:1, clipped by its client area, so a frame of the old size is never stretched over the new one (as
	// Wren's browser.window.fixed_surface). Where DirectComposition is missing it is an ordinary swap chain.
	app.win = platform.open_window(APP_NAME, {WINDOW_W, WINDOW_H}, transparent = true, integrated_title = true)
	if app.win == nil { fmt.eprintln("opencode-native: no window"); os.exit(1) }
	if !fonts_init(app) { fmt.eprintln("opencode-native: no UI font"); os.exit(1) }
	for a in os.args[1:] {   // --size=<w>x<h>: the window's size in pixels, whichever screen it opens on (occtools shots)
		if !strings.has_prefix(a, "--size=") { continue }
		wh := strings.split(a[len("--size="):], "x", context.temp_allocator)
		if len(wh) != 2 { continue }
		w, w_ok := strconv.parse_f32(wh[0])
		h, h_ok := strconv.parse_f32(wh[1])
		if w_ok && h_ok { platform.set_size(app.win, {int(math.round(w / app.win.dpi_scale)), int(math.round(h / app.win.dpi_scale))}) }
	}
	if !render.init_window(&app.r, app.win, app.win.size, transparent = true) { fmt.eprintln("opencode-native: no renderer"); os.exit(1) }
	if !slice.contains(os.args, "--no-fixed-surface") { render.set_fixed_surface(&app.r, platform.monitor_size(app.win)) }
	_ = platform.drop_target_enable(app.win, true)   // (files dropped on the window are attached: attach_drop)
	app_init(app, prefs_path())
	drafts_load(app)   // (what was typed before, in each session: the home page's comes back now)
	app.cx.web_host = web_host_system()
	if app.servers_in_clear { servers_save(app) }
	platform.set_dark_title(app.win, !app.cx.theme.light)
	app.devtools = devtools.start_from_env(app.win, "opencode")
	main_window_adopt(app)
	app.last_tick = time.tick_now()
	app.settle = FRAMES_AFTER_INPUT

	// the event stream: its first connection loads everything (stream_up)
	server_connect(app, app.server)
	if app.conn == nil { fmt.eprintln("opencode-native: the HTTP client failed to start"); os.exit(1) }

	if frames >= 0 {
		first: time.Duration   // from the start of main to the end of the first frame
		for i in 0 ..< frames {
			frame(app)
			if i == 0 { first = time.tick_since(started) }
			time.sleep(CHECK_FRAME_SLEEP_MS * time.Millisecond)
		}
		fmt.printfln("opencode-native: %d frames, %d boxes, online=%v, %d sessions, %d messages, first frame %.1f ms", frames, app.state.boxes_built, online(app), len(app.sessions), len(app.chat.messages), time.duration_milliseconds(first))
		os.exit(0)
	}

	update_startup(app)   // (a server or none: a check of this program's own version)
	setup_offer_at_start(app)
	for a in os.args[1:] {   // --search=<text>: the sidebar's search, filled at start; --setup: the Setup dialog
		if strings.has_prefix(a, "--search=") { ui.field_set(&app.search, a[len("--search="):]) }
		if a == "--setup" { setup_open(app) }
		if a == "--add-server" { server_edit_open(app, -1) }
		if strings.has_prefix(a, "--find=") { find_open(app); ui.field_set(&app.find.field, a[len("--find="):]) }
		if strings.has_prefix(a, "--image=") { image_view_start(app, a[len("--image="):]) }
		if strings.has_prefix(a, "--attach=") { attach_path(app, a[len("--attach="):]) }   // (what a paste gives, without the clipboard)
		if strings.has_prefix(a, "--diff=") { diff_full_open_file(app, a[len("--diff="):]) }   // (a patch in the full view)
		if strings.has_prefix(a, "--slow-motion=") { if n, ok := strconv.parse_f64(a[len("--slow-motion="):]); ok { film_slow_start(app, n) } }
	}
	for a in os.args[1:] {   // --settings[=page number]: the settings open at start
		if a == "--settings" || strings.has_prefix(a, "--settings=") {
			settings_open(app)
			if n, ok := strconv.parse_int(strings.trim_prefix(a, "--settings=")); ok && n >= 0 && n < len(Settings_Page) { app.settings_page = Settings_Page(n) }
		}
	}
	platform.show_window(app.win)
	for !platform.is_closed(app.win) && !app.quit {
		if app.settle == 0 && !ui.needs_frame(&app.state) {
			film_slow_tick(app)
			platform.wait_event(app.win, ui.wake_in_ms(&app.state))
			app.slept = true
		}
		frame(app)   // (what it still owes goes down there: host_frame)
	}
	threads_stop(app)
	if app.cx.due[.Drafts].due_ms != 0 { drafts_save(app) }   // (what was typed in the last second)
	ui.post_close(&app.state)
	setup_finish(app)
	os.exit(0)
}


