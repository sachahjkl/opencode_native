// opencode, native: a desktop client for the opencode v2 server, on gui_toolkit (Direct3D 11, DirectWrite).
//   build.bat            -> build\opencode-native.exe
//   opencode-native.exe [--url=http://127.0.0.1:4096] [--password=...]
// Without arguments it finds this computer's opencode server (~/.local/state/opencode/service.json, else ~/.config/opencode/service.json).
package ocn

import "core:fmt"
import tasks "gt:tasks"
import "core:mem/virtual"
import "core:math"
import "core:os"
import "core:time"
import prefs_page "gt:prefs_page"
import "gt:cli"
import "gt:config"
import "gt:devtools"
import "gt:draw"
import "gt:font"
import "gt:host"
import instance "gt:instance"
import "gt:platform"
import pictures "gt:pictures"
import "gt:render"
import "gt:term"
import setup "gt:setup"
import crash_bar "gt:crash_bar"
import process "gt:process"
import "gt:ui"
import lucide "gt:lucide"
import i18n "gt:i18n"
import update "gt:update"

// A face of the fonts. (Inside App, `font` names the face of the interface, from host.Shared: not the package.)
Face_Id :: font.Font_Id

App :: struct {
	using gfx:    host.Shared,   // the renderer, the drawing, the fonts, the theme, the interface's face (font)
	using window: host.Host,     // the main window: win, its interface (state), its pacing, what it still owes (settle)
	prose, mono, mono_bold, icons, tk_icons: Face_Id,   // (Face_Id: in here, font is the interface's face, host.Shared's)
	term_font, term_font_bold: Face_Id,   // the shells' (appearance.terminal_font)
	own:           Own_Faces,
	prose_scale:   f32,        // the answers' size, of the text around them
	// the shells' family (appearance.terminal_font), loaded on a chore by the toolkit (the others are its text faces)
	term_family:   ui.Family_Face,
	fonts_serial:  u64,        // the faces' changes fonts_follow last took (ui.text_faces_serial and term_family's)
	fonts_followed: bool,      // fonts_follow ran once
	term_picker:   ui.Font_Picker,     // the terminal font's control (font_button)
	term_families: ui.Font_Families,   // its families, read at its first opening

	cx:             App_Context,       // what the window keeps from frame to frame, beside the panels' own state
	server_files:   Server_Files,      // the server's files, for the toolkit's file browser (folders.odin)

	// the server
	servers:        [dynamic]Server,   // (servers.odin) this computer's first
	server:         int,               // the one connected
	conn:           ^Conn,             // its connection
	server_edit:    Server_Edit,
	activity:       Activity,          // what runs behind the conversation (activity.odin)
	palette:        Palette,           // Ctrl+K: the toolkit's palette and ocn's sources; the composer's chooser (palette.odin)
	changelog:      prefs_page.Changelog,   // What's new: CHANGELOG.md on a page of the settings, said once after an update
	jump:           Jump,              // Ctrl+Alt+G: Jump to message, a chooser of the session's prompts (jump.odin)
	term_zooms:     ui.Zoom_Memory,    // each shell's zoom, by its id: its grid's zone (terminal.odin)
	session_zooms:  ui.Zoom_Memory,    // each session's conversation zoom, by its id: every pane's zone (conversation.odin)
	stores:         Stores,            // what it remembers beside the preferences, written on workers (stores.odin)
	preview:        Preview,           // the page beside the conversation (preview.odin)
	browser:        Browser,           // the agents' tools on that page (browser_mcp.odin)
	updater:        ^update.Updater,   // a new version: checked, downloaded, in place (updates.odin; nil: none started)
	update_serial:  int,               // the updater's state last said (updates_follow)
	program_views:  ui.Views,          // the dialogs, the sidebar, the panels, the windows of their own, and how each was last shown (window_views.odin; `views` is host.Shared's: their windows)
	rename:         Rename,            // a session's title (context_menus.odin)
	scale:          f32,               // --scale=<factor>: the interface's scale whatever the screen says (0: the screen's)
	servers_in_clear: bool,            // passwords read in clear from the file: a save seals them, if a store takes them
	passwords_in_clear: bool,          // the last save of the servers found no store for a password: the dialog says so
	rediscover_ms:  f64,               // when this computer's server was last looked for (servers_rediscover)
	connect_seq:     u64,              // the connection last asked for (server_connect): one read for an earlier one is not connected
	rediscover_busy: bool,             // ... a look is under way, on a chore
	pending:        i32,       // (atomic) requests in flight

	using known:     Server_Known,      // what we know, as long as that server is the one
	panes:           [PANES_MAX]Chat_Pane,   // the conversations shown: MAIN_PANE is the main view (chat_pane.odin)
	btw:             int,               // the slot of the pane the /btw panel shows (0: none; btw.odin)
	drafts:          map[string]Draft,  // each session's composer while no pane shows it (drafts.odin; keys owned)
	// the parts opened by the user, by the hash of their id: an id names one part of one session, so one set serves every pane, and the
	// stats panel's sections too
	expanded:        map[u64]bool,

	// the interface's own state, by feature (each struct is in the file of its feature)
	escape_stop:      Escape_Stop,    // escape_stop.odin
	free_limit:       Free_Limit,     // free_limit.odin
	sidebar:          Sidebar,        // sidebar.odin
	chrome:           Chrome,         // chrome.odin
	nav:              Nav,            // subagents.odin
	settings:         Settings_View,  // settings.odin
	stats:            Stats_View,     // stats.odin
	viewer:           Image_Viewer,   // images.odin
	diagram_view:     Diagram_Viewer, // diagrams.odin
	previews:         Previews,       // preview_views.odin
	ctx_menu:         Ctx_Menu,       // context_menus.odin
	quote:            Quote_Chip,     // context_menus.odin
	notices:          Notices,        // settings.odin
	missed:           Missed,         // what the person missed: its log and its view (missed.odin, missed_view.odin)
	film:             Film,           // film.odin
	start_session:    string,
	cli:              Cli_Options,    // the command line, read once at start (cli_options.odin)
	cfg_prefs:        config.Prefs,   // the preferences (settings.odin)
	prefs_file:       string,         // where they are saved ("": nowhere)
	announcer:        ui.Announcer,     // says what an act did (Copied, Exported): the system's notifications or the window's toasts (general.messages)
	licence:          prefs_page.Licence,   // the licence that supports the program (licence.odin): the settings' Licence page
	standard:         prefs_page.Standard_Watch,   // applies the toolkit's settings as they change (settings.odin prefs_init)
	// the person's keys and aliases (keys.custom, keys.aliases: standard_watch reads and writes them); every window's
	// state reads it, the commands' keys through it (commands_keys)
	keymap:           ui.Keymap,
	prefs_writer:     config.User_Writer,   // writes them off the loop, once a round when they changed (main_after_frame)
	prefs:            Prefs,          // their plain values
	facts:            Server_Facts,   // what the server said for the settings pages
	mcp_events:       [dynamic]Mcp_Event,   // the MCP servers' last events, oldest first (mcp_events.odin)
	seek_subagent:    bool,   // --seek-subagent (tests): scroll to the first sub-agent card
	logo:             Logo,
	pictures:         pictures.Cache,   // the textures of the images, by Image_Ref.key and size (images.odin)
	devtools:         ^devtools.Server,   // TOOLKIT_DEVTOOLS=<port>: driven over the Chrome DevTools Protocol (the toolkit's tk cdp, or gt:cdp in ocntools)
	install:          prefs_page.Install,   // the install: its offer, its dialog, the settings' Installation page (setup.odin)
	crash_bar:        crash_bar.Bar,        // the last session's crash, said in a bar under the title bar
	quit:             bool,
	launch_after:     string,   // Restart: the file started at main's very end, once the single instance is let go ("": none)
	frame_times:      Frame_Times,   // the last frame's steps
}

// What a server told, and nothing else: it starts from zero with the next one (server_known_end). A field added here does too. (What has a
// Remote stays out: a late answer of the last server compares its ticket with it, and a count that started over could match.)
Server_Known :: struct {
	link:            Conn_State,
	server_version:  string,
	server_urls:     [dynamic]string,   // where the server is reached (GET /api/info `urls`, owned): pairing (pair.odin)
	pair:            Pair,              // the dialog that pairs a device (pair.odin)
	sessions:        [dynamic]Session_Info,
	session_at:      map[string]int,    // app.sessions by id (in sess_arena: sessions_changed)
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
	home_lists:     Home_Lists,        // what the home page lists of the sessions (home.odin)
	catalog_version: u64,             // counts the changes of the agents and the models (the pickers keep their lists until it moves)
	theme:               Theme_State,          // the themes, the one shown, its colours (theme.odin)
	conns:          [dynamic]^Conn,    // every connection not freed yet: their threads stop at close (servers.odin threads_stop)
	chores:         tasks.Pool,         // what the interface must not wait for and keeps its order: the keyring, where the server runs (conn.odin)
	outgoing:       [dynamic]^Outgoing,   // prompts between the composer and the server (outgoing.odin)
	outgoing_last:  u64,               // ... the last one's id
	waits_unread:   bool,              // the stream just came up: what sessions wait on, asked before it, is read from the next list
	answers_spent:  [dynamic]^virtual.Arena,   // what this frame's answers were read into (net.odin)
	effects:        [dynamic]Effect,   // what the model asked of the interface, done by the build (effects.odin)
	flights:        [dynamic]Flight,   // what is on its way (net.odin)
	stream_seq:     Seq,               // events applied so far: the clock of what is newer than an answer (Request.asked_at)
	busy_seq:       map[string]Seq,    // when the stream last said a session started or ended (keys owned)
	waits_gone:     Gone_List,         // permissions and forms answered, the last WAITS_GONE_MAX
	due:            [Due]ui.Deferred,     // what was put off (remote.odin)
	reopen:         Nav_Place,         // what was shown when this computer's server moved (servers_rediscover), owned, id "": none
	gliding:        bool,              // a panel's height moves in this build
	was_gliding:    bool,              // ... it did in the last one
	no_schedules, no_artifacts: bool,     // the server does not offer them (experimental.odin)
	terms:          Terminals,            // the Terminal panel (terminal.odin)
	outputs:        Output_Views,         // commands' output, read as a terminal shows it (output_view.odin)
	schedules:      Schedules,            // schedules.odin
	artifacts:      Artifacts,
	diff_full:      Diff_Full,            // diff_full.odin
	plugins:        Plugins,
	integrations:   Integrations,         // the Connections page (integrations.odin)
	background:     map[string]bool,      // the sessions with commands running in the background, and their parents (activity.odin; keys owned)
	changes:        Changes,              // what a session changed, or would undo (session_tools.odin)
	forms:          [dynamic]^Form_Req,   // what agents ask and wait for (forms.odin), of every session
	shared_moved:   bool,                 // something of what every window shows may have changed this frame (posts_moved)
	posts_run_seen: u64,                  // ... the count of posts run at the last frame, the events of the stream left out (posts_moved)
	events_run:     u64,                  // the events of the stream applied (event_take: each says itself whether it moved anything)
	unreadable:     Unreadable_Log,       // what could not be read as JSON (unreadable.odin)
	commands_due:   [dynamic]^Command, // to run after this frame, in order (commands.odin)
	slash:          [dynamic]Slash,    // the server's commands
	have_slash:     bool,
	diagrams:       map[u64]Diagram,   // the Mermaid diagrams laid out (diagrams.odin)
	placement:      prefs_page.Placement_Keeper,   // the window's place, the toolkit's window.placement
	// What is made from the sessions is kept until one of these moves. Here, not in Server_Known: a count that started over with
	// another server could meet the one a cache was made at.
	sessions_ver:   u64,               // the list of sessions (sessions_changed)
	marks_ver:      u64,               // what deals a session into a section or lights its row (marks_changed)
	waiting:        Waiting_Kept,      // the sessions that wait for the person (forms.odin)
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
clip_set :: proc(text: string) { ui.window_clipboard_set(text) }

// The main window is a host.Host (host_adopt: the window, the device loaded on a thread and the fonts are this program's own start). Its
// frame is the toolkit's, in the order its parts must come (host.host_frame); what is this program's goes in its hooks. The windows
// of the views come after it, in it; then the page of the Preview goes where its panel was laid out, in whichever window.
frame :: proc(app: ^App, inner := false) {
	host.host_frame(&app.window, inner)
	if !inner { preview_after_frames(app) }
}

main_window_adopt :: proc(app: ^App) {
	host.host_adopt(&app.window, &app.gfx, app.win, nil, app)
	h := &app.window
	h.after_input = FRAMES_AFTER_INPUT
	h.background = draw.hex(theme_colors().steps[1])   // (before any build: the theme's own page)
	h.dragging = main_dragging
	h.before_input = proc(h: ^host.Host) {
		app := (^App)(h.user)
		film_slow_tick(app)
		pictures.frame(&app.pictures)   // (before the builds ask for pictures)
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
	moving := ui.now_ms() - app.cx.pointer_ms < POINTER_MOVING_MS || app.cx.gliding   // (a panel that opens: read as closely)
	return ui.active_key() != 0 || moving
}

FRAMES_AFTER_INPUT :: 3        // still drawn after an event, and at start: what it set off settles
ANCHOR_BUILDS_MAX  :: 4        // builds spent on keeping a part header in place
SNAP_BUILDS_MAX    :: 4        // builds spent on reaching the bottom of a page just read, while what they build moves it

// How soon an action is followed by reading again what it changed: a burst of events reads once.
REFRESH_DEBOUNCE_MS  :: 1200
FACTS_DEBOUNCE_MS    :: 700
CHILDREN_DEBOUNCE_MS :: 800

// What a build of any window is given: they differ by their size and what came to them.
build_params :: proc(app: ^App, win: ^platform.Window, size: draw.Vec2, events: []platform.Event, dt: f32) -> ui.Build_Params {
	return {
		window_size = size, events = events, dt = dt, animations = animations_on(app),
		dpi_scale = app.scale > 0 ? app.scale : win.dpi_scale, window = win,
		// (the client's own face: begin_build puts the family the person chose in its place, ui.set_text_faces)
		base = ui.Style{pref = {.X = ui.text_size(), .Y = ui.px(30)}, font = app.own.ui[0], font_size = app.prefs.font_size, text_pad = 6, cursor = .Arrow, radius = 6},
		clipboard_set = clip_set,   // (no clipboard_get: a paste asks the window's clipboard and waits for nothing, ui.paste_request)
	}
}

// What a window's input is, before the interface sees it: what goes to a shell or a command's output shown in that window is
// taken out. The windows of the views have this hook too (host.view_windows: their owner's): there, only that.
@(private = "file")
main_input :: proc(h: ^host.Host, read: []platform.Event) -> []platform.Event {
	app := (^App)(h.user)
	if h.owner != nil { return term_events(app, &h.state, read) }   // (a view's window: its grids' keys, nothing of the main window's)
	theme_follow_system(app)   // (the system went light or dark: an integer compared)
	events := read
	app.cx.shared_moved = false
	for e in events { if e.kind != .Mouse_Move && e.kind != .Scroll { app.cx.shared_moved = true } }   // (a pointer that passes over this window changes nothing in another)
	events = term_events(app, &app.state, events)
	for e in events {
		if e.kind == .Mouse_Move || e.kind == .Scroll { app.cx.pointer_ms = ui.now_ms() }
		if e.kind == .Scroll || e.kind == .Key_Press {   // (the reader goes elsewhere: the view is theirs)
			for &pane in app.panes { chat_scroll_event(&pane, Scroll_Signal.Restore_End) }
		}
		attach_drop_event(app, e)
		notify_event(app, e)
		// the side buttons of the mouse, as in a browser
		if e.kind == .Mouse_Press && !overlay_open(app) {
			if e.button == .Back { if c := command_find("nav.back"); command_enabled(app, c) { command_run(app, c) } }
			if e.button == .Forward { nav_step(app, 1) }
		}
	}
	return events
}

// The builds of a frame. Its dt is the host's, of the interface's clock: the film's slowed one, a test's, one refresh after a
// rest. (A dt of the system's clock moved a test's animations by the time its frames took, not by the frames it made.)
@(private = "file")
main_builds :: proc(h: ^host.Host, size: draw.Vec2, events: []platform.Event, dt: f32) {
	app := (^App)(h.user)
	if !h.rested && dt < FPS_RESTED_S { app.chrome.frame_ms += (dt * 1000 - app.chrome.frame_ms) * FPS_SMOOTH }   // (a rest is no frame rate)
	app.frame_times = {}
	t_build := time.tick_now()
	main_build(app, size, events, dt)
	prefs_track_zoom(app)
	// A part opened or closed in this build: the build drew it in its old state (the click comes after its body). Build
	// again in its new state, then scroll by what its header moved so that it stays under the pointer, and build once
	// more at that offset: the frame shows the result, never the steps. (A page read above is held the same way: Keeping became
	// Anchored in this build. Anchored through these builds, the bottom stays let go of; Frame_Done ends it.) Each pane is held in
	// turn: a build is the whole window's.
	for &pane, i in app.panes {
		if pane_is_shown(app, i) { main_builds_held(app, &pane, size) }
	}
	for &pane, i in app.panes {
		if !pane_is_shown(app, i) { continue }
		if b := pane.conversation.scroll_box; b != nil { pane.conversation.height = b.view_bounds.y }
		chat_scroll_event(&pane, Scroll_Signal.Frame_Done)
		if b := pane.conversation.scroll_box; b != nil { load_older(app, &pane, b) }
	}
	app.frame_times.build = time.tick_since(t_build)
}

// One build of the main window. `again`: another build of this frame. It runs no answer: a page read there would come after what
// the first build placed, and its anchor would be dropped with the frame's. It waits for the next frame, which needs_frame asks for.
@(private = "file")
main_build :: proc(app: ^App, size: draw.Vec2, events: []platform.Event, dt: f32, again := false) {
	app.cx.was_gliding = app.cx.gliding
	app.cx.gliding = false
	app.state.post_budget = again ? 0 : POSTS_PER_BUILD
	ui.begin_build(&app.state, build_params(app, app.win, size, events, dt))
	missed_sync(app)     // (after the events, before their effects: a notification finds its entry)
	if !again { themes_poll(app) }   // (the user's themes.txt changed: shown at once)
	effects_apply(app)   // (what the events begin_build ran asked for: shown in this very build)
	// (only now: the answers begin_build ran read the last build's, a page placed by chat_load above all)
	for &pane in app.panes { pane.conversation.scroll_box = nil }
	build_ui(app)
	ui.end_build()
	terminals_end(app)   // (after the views built at the end of the build)
	app.frame_times.builds += 1
}

// The builds again of a frame that a pane's place asks for (main_builds).
@(private = "file")
main_builds_held :: proc(app: ^App, pane: ^Chat_Pane, size: draw.Vec2) {
	build :: main_build
	if a, anchored := pane.view.chat_scroll.(Scroll_Anchored); anchored {
		build(app, size, nil, 0, again = true)
		// (again while it moves: what this offset builds around it is measured only then, a page read before it above all)
		for _ in 0 ..< ANCHOR_BUILDS_MAX {
			b := pane.conversation.scroll_box
			if b == nil { break }
			delta := a.box.rect.min.y - a.y
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
	if f, following := pane.view.chat_scroll.(Scroll_Following); following && pane.conversation.scroll_box != nil {
		b := pane.conversation.scroll_box
		limit := ui.view_limit(b)
		grew := b.view_bounds.y > pane.conversation.height + 0.5 && b.view_off.y < limit - 0.5
		if b.view_off.y > limit + 1 || f.jump || grew {
			b.view_anim[1].active = false   // (the glide stops where it is: the second build reaches the bottom at once)
			bounds := b.view_bounds.y
			chat_scroll_event(pane, Scroll_Signal.Snap)
			build(app, size, nil, 0, again = true)
			// (the bottom it reached was reckoned with the guessed heights of the messages the lazy column had not built: those
			// it built there were measured, and the bottom moved. Again while it moves, so that the frame shows the bottom)
			for _ in 0 ..< SNAP_BUILDS_MAX {
				nb := pane.conversation.scroll_box
				if nb == nil || abs(nb.view_bounds.y - bounds) <= 0.5 { break }
				bounds = nb.view_bounds.y
				nb.view_anim[1].active = false
				chat_scroll_event(pane, Scroll_Signal.Snap)
				build(app, size, nil, 0, again = true)
			}
		}
	}
}

// Between two frames: what the frame set off, what the page said, what is due. (The windows of the views come after it: host_frame.)
@(private = "file")
main_after_frame :: proc(h: ^host.Host) {
	app := (^App)(h.user)
	app.frame_times.draw, app.frame_times.render = h.times.draw, h.times.present
	work := f32(time.duration_milliseconds(app.frame_times.build + app.frame_times.draw + app.frame_times.render))
	app.chrome.work_ms += (work - app.chrome.work_ms) * FPS_SMOOTH
	h.times = {}   // (a frame held draws nothing: it costs nothing either)
	answers_spent_free(app)
	config.user_writer_save(&app.prefs_writer, &app.cfg_prefs)
	if config.user_writer_failed(&app.prefs_writer) { ui.announce(&app.announcer, .Bad, i18n.tr("The preferences could not be saved")) }
	posts_moved(app, ui.post_stats(&app.state).run)
	terminals_reap(app)
	output_views_tick(app)
	web_events_drain(app)   // (the one place: what the page said during the frame, a modal dialog's message loop included)
	nav_apply(app)
	commands_apply(app)
	preview_follow(app)
	terms_close_due(app)
	browser_tick(app)
	servers_rediscover(app)
	activity_tick(app)
	deferred_tick(app)
}

// What the posts run in this frame may have changed in every window: an answer, a shell's output, a word of the stream's link. An event of the
// stream is left out: it says itself (event_take), and most of them are another session's deltas that no window shows.
posts_moved :: proc(app: ^App, run: u64) {
	others := run - app.cx.events_run
	if others == app.cx.posts_run_seen { return }
	app.cx.posts_run_seen = others
	app.cx.shared_moved = true
}

// A conversation just opened, its first page on its way: an empty page shown for the instant that takes is a blink, from what was there to
// nothing to the conversation. What was there stays on the screen meanwhile, and the page comes the moment it is read: it waits for
// nothing. Only what is shown is held: input is read and built as ever. How long more, in ms (0: show the frame). A server that takes
// longer gets its "Loading"; a window with nothing on it yet, or of another size, has no picture to keep.
frame_held_ms :: proc(app: ^App, size: draw.Vec2) -> int {
	pane := main_pane(app)
	if chat_view(app, pane) != .Loading || app.shown != {int(size.x), int(size.y)} { return 0 }   // (shown: the size of the last picture)
	return max(int(OPEN_HOLD_MS - (ui.now_ms() - pane.view.opened_ms)), 0)
}

due_run :: proc(app: ^App, k: Due) {
	switch k {
	case .Refresh:   refresh_sessions(app)
	case .Facts:     if ui.view_is_open(&app.program_views, SETTINGS_VIEW) { server_facts_load(app) }   // (an action of the settings: connect an MCP server, revoke a permission)
	case .Children:  for &pane, i in app.panes { if pane_is_shown(app, i) { load_children(app, &pane) } }
	case .Context:   if app.stats.open { context_ask(app) }
	case .Term_Size: terms_size_due(app)
	case .Side_Wake: app.settle = max(app.settle, FRAMES_AFTER_INPUT)   // (the build sees the pointer has rested)
	case .Drafts:    drafts_save(app)
	}
}

due_tick :: proc(app: ^App, k: Due) {
	if !ui.deferred_take(&app.cx.due[k]) { return }
	due_run(app, k)
	app.cx.shared_moved = true
}

// What was put off: done if it is time, and a wake for the rest. A window at rest wakes only while something is due: the window
// may sleep on, and a read that waits for the next input would wait for good.
deferred_tick :: proc(app: ^App) {
	cx := &app.cx
	for k in Due { due_tick(app, k) }
	if chat_scroll_due(app) { app.cx.shared_moved = true }
	soonest := 0
	for &d in cx.due { if ms := ui.deferred_in_ms(&d); ms > 0 { soonest = soonest == 0 ? ms : min(soonest, ms) } }
	for &pane in app.panes { if ms := ui.deferred_in_ms(&pane.view.restore_due); ms > 0 { soonest = soonest == 0 ? ms : min(soonest, ms) } }
	for ms in ([?]int{activity_in_ms(app), rediscover_in_ms(app), browser_in_ms(app)}) {
		if ms > 0 { soonest = soonest == 0 ? ms : min(soonest, ms) }
	}
	if soonest > 0 { ui.wake_within(&app.state, soonest) }
}

// The client's own faces (open licences, Latin: assets/fonts): the interface, the answers, code. Weights as the code asks them.
Own_Faces :: struct { ui, prose, mono: [4]font.Font_Id, mono_bold: font.Font_Id, term: [2]font.Font_Id }   // regular, bold, italic, bold italic; the shells' regular and bold
PROSE_OWN_SCALE  :: 1.08   // Newsreader's small letters are low: larger than the text around it, to read as large
PROSE_LINE_RATIO :: 1.36   // of the answers' size: the height of their lines


// The fonts that do not change: the icons (Lucide, embedded), the toolkit's own glyphs and the client's own faces of
// the text. The families the person chooses are the toolkit's to load and apply (fonts_follow).
load_fonts :: proc(app: ^App) -> bool {
	ok: bool
	if app.icons, ok = font.load_embedded(&app.fonts, lucide.DATA); !ok { return false }
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
	// the shells': Fira Mono, no ligatures (what a shell prints is read sign by sign)
	term := own(app, #load("../assets/fonts/fira-mono-400.ttf"), regular)
	app.own.term = {term, own(app, #load("../assets/fonts/fira-mono-700.ttf"), term)}
	fonts_from_dir(app)
	// (the faces in use until the first build follows the toolkit's: fonts_follow)
	app.font, app.prose, app.mono, app.mono_bold = app.own.ui[0], app.own.prose[0], app.own.mono[0], app.own.mono_bold
	app.prose_scale = PROSE_OWN_SCALE
	app.term_font, app.term_font_bold = app.own.term[0], app.own.term[1]
	return ok
}

// The client's own text faces, which the settings' Default draws in (prefs_page.Standard_Targets.faces).
own_text_faces :: proc(app: ^App) -> ui.Text_Faces {
	return {.Interface = app.own.ui[0], .Mono = app.own.mono[0], .Prose = app.own.prose[0]}
}

// --font-dir=<folder>: the client's own faces tried from files, nothing installed (ocntools font_proposals): ui,
// ui-bold, ui-italic, ui-bold-italic, mono, mono-bold and, for the answers when they are another family than the
// interface, prose, prose-bold, prose-italic, prose-bold-italic (.ttf). A file that is not there leaves the embedded one.
@(private = "file")
fonts_from_dir :: proc(app: ^App) {
	dir := app.cli.font_dir
	if dir == "" { return }
	face :: proc(app: ^App, dir, name: string, or_else_face: font.Font_Id) -> font.Font_Id {
		f, ok := font.load_from_file(&app.fonts, pjoin({dir, fmt.tprintf("%s.ttf", name)}))
		return ok ? f : or_else_face
	}
	regular := face(app, dir, "ui", app.own.ui[0])
	bold := face(app, dir, "ui-bold", regular)
	app.own.ui = {regular, bold, face(app, dir, "ui-italic", regular), face(app, dir, "ui-bold-italic", bold)}
	mono := face(app, dir, "mono", app.own.mono[0])
	app.own.mono = {mono, mono, mono, mono}
	app.own.mono_bold = face(app, dir, "mono-bold", mono)
	prose := face(app, dir, "prose", regular)
	app.own.prose = app.own.ui
	if prose != regular {
		app.own.prose = {prose, face(app, dir, "prose-bold", prose), face(app, dir, "prose-italic", prose), face(app, dir, "prose-bold-italic", prose)}
	}
}

// The faces in use, taken from the toolkit's text faces (the family the person chose, loaded on the toolkit's chores,
// else the client's own) and from the shells' family, when one of them changed (their serials): at the start of a
// build, after the answers begin_build ran. What is derived from them follows: the bold of code and of the shells (gt:ui
// loaded it with the family, off this thread), the answers' size.
fonts_follow :: proc(app: ^App) {
	s := &app.state
	serial := ui.text_faces_serial(s) + app.term_family.serial
	if app.fonts_followed && serial == app.fonts_serial { return }
	app.fonts_followed, app.fonts_serial = true, serial
	app.font = ui.state_text_face(s, .Interface)
	app.mono = ui.state_text_face(s, .Mono)
	app.prose = ui.state_text_face(s, .Prose)
	if app.font == 0 { app.font = app.own.ui[0] }   // (a test's State with no faces of the client's)
	if app.mono == 0 { app.mono = app.own.mono[0] }
	if app.prose == 0 { app.prose = app.own.prose[0] }
	app.mono_bold = app.mono == app.own.mono[0] ? app.own.mono_bold : font.styled_face(&app.fonts, app.mono, true, false)
	// (Newsreader's small letters are low: only the client's own face of the answers is drawn larger)
	app.prose_scale = app.prose == app.own.prose[0] ? PROSE_OWN_SCALE : 1
	app.term_font, app.term_font_bold = app.own.term[0], app.own.term[1]
	if f := app.term_family.face; f != 0 { app.term_font, app.term_font_bold = f, font.styled_face(&app.fonts, f, true, false) }
	// (the client's own families: their bold and italic are files of its own; a family of the system finds its own)
	ui.set_family(s, app.own.ui[0], app.own.ui[1], app.own.ui[2], app.own.ui[3])
	ui.set_family(s, app.own.prose[0], app.own.prose[1], app.own.prose[2], app.own.prose[3])
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
	app.changelog.english = CHANGELOG   // (the settings' What's new page, a test's app too)
	ui.init(&app.state, &app.fonts, &app.theme)
	app.state.icon_font = app.icons   // (Lucide: the menus' icons are its characters)
	ui.keymap_use(&app.state, &app.keymap)   // (the views' own windows read their owner's)
	prefs_init(app, prefs_file)   // (after ui.init: it sets the zoom, the density, the rounding and the palette)
	views_start(app, views_path(prefs_file))   // (ui.init selected the state: the sidebar's owner)
	palette_start(app)   // (after the preferences: the settings source reads them)
	prefs_page.install_init(&app.install, &app.cfg_prefs, setup_options())
	app.install.vendor_mark, _ = setup.logo_make(&app.r, APP_PUBLISHER_MARK)   // (the setup's "By" line, as the site's foot)
	licence_init(app)
	zooms_load(app)
	ui.post_configure(&app.state, capacity = POSTS_CAPACITY, overflow = .Block, per_build = POSTS_PER_BUILD, on_drop = on_drop)
	tasks.start(&app.cx.chores, {threads = CHORES_WORKERS})
	pictures.cache_init(&app.pictures, &app.r, &app.state)   // (after the renderer: it reads its largest texture)
}

// The zooms remembered (the toolkit's zoom memories over their stores): each shell's and each session's. Their values are
// written through the stores from then on (a test's stores are in memory). Every pane's zone shares the sessions' memory:
// the same session in two panes is one zoom. The shells' are by their id on the server, which keeps a shell's title and
// size only: a shell found again (the program started again, the server come back) has its own.
zooms_load :: proc(app: ^App) {
	app.session_zooms.min, app.session_zooms.max = CONTENT_ZOOM_MIN, CONTENT_ZOOM_MAX
	app.session_zooms.default = app.prefs.content_zoom
	ui.zoom_memory_load(&app.session_zooms, &app.stores.session_zooms)
	app.term_zooms.min, app.term_zooms.max = term.ZOOM_MIN, term.ZOOM_MAX
	ui.zoom_memory_load(&app.term_zooms, &app.stores.zooms)
	for &pane in app.panes { pane.zone.memory = &app.session_zooms }
}

zooms_destroy :: proc(app: ^App) {
	for &pane in app.panes { ui.zoom_zone_destroy(&pane.zone) }
	ui.zoom_memory_destroy(&app.session_zooms)
	ui.zoom_memory_destroy(&app.term_zooms)
}

// The fonts, before the renderer: they load while the graphics device is made (render.preload_device).
fonts_init :: proc(app: ^App) -> bool {
	settings := font.DEFAULT_SETTINGS
	// small text drawn from outlines (Slug) has its baseline and x-height on whole pixels: unhinted, round and flat letters stood
	// at slightly different heights and a line seemed to bounce
	settings.slug_hint_ppem = TEXT_HINT_PPEM
	font.init(&app.fonts, settings)
	return load_fonts(app)
}

main :: proc() {
	opts := cli_start()   // (--help, --version, a line not understood: said, no window; everything else reads app.cli)
	started := time.tick_now()
	folders_move()   // (before anything reads the folders: --status and the single instance key on the configuration's)
	// --install / --uninstall / --status: the install, without a window
	if setup.command_alone(opts.command) { cli.exit(setup.command_run(opts.command, setup_options(), process.console_write)) }
	// one window per person: a second start hands what it asks to the first and ends, before it writes or shows anything
	forwarded, owner, owns := instance_acquire(opts)
	if forwarded { os.exit(0) }
	logger, crashed := log_start()
	context.logger = logger
	// the graphics device on a thread of its own while the rest starts (the driver's load is the longest step: 160 ms here)
	render.preload_device()
	set_app_id()           // (before the first window: the taskbar groups it under the shortcuts)

	app := new(App)
	the_app = app
	app.cli = opts
	app.start_session = opts.session   // --session=<id>: the session opened at start (else the latest)
	app.scale = opts.scale
	app.seek_subagent = opts.seek_subagent   // (the view follows the bottom: Chat_Scroll's zero state)
	chat_home(app)

	stores_open(app)   // (before the window and its loop: the servers and the last session decide the first frame)
	servers_init(app)

	// a composition swap chain whose buffers keep the monitor's size while the window is resized: the window shows their
	// top-left part 1:1, clipped by its client area, so a frame of the old size is never stretched over the new one (as
	// Wren's browser.window.fixed_surface). Where DirectComposition is missing it is an ordinary swap chain.
	app.win = platform.open_window(APP_TITLE, {WINDOW_W, WINDOW_H}, transparent = true, integrated_title = true)
	if app.win == nil { fmt.eprintln("opencode-native: no window"); os.exit(1) }
	title_apply(app)   // (the preferences were read before the window was there)
	if !fonts_init(app) { fmt.eprintln("opencode-native: no UI font"); os.exit(1) }
	if wh, ok := opts.size.?; ok {   // --size=<w>x<h>: the window's size in pixels, whichever screen it opens on (ocntools shots)
		platform.set_size(app.win, {int(math.round(wh.x / app.win.dpi_scale)), int(math.round(wh.y / app.win.dpi_scale))})
	}
	if !render.init_window(&app.r, app.win, app.win.size, transparent = true) { fmt.eprintln("opencode-native: no renderer"); os.exit(1) }
	if !opts.no_fixed_surface { render.set_fixed_surface(&app.r, platform.monitor_size(app.win)) }
	_ = platform.drop_target_enable(app.win, true)   // (files dropped on the window are attached: attach_drop)
	app_init(app, prefs_path())
	// (after app_init: the usage memory is read by a task of the state; a test gives none, it keeps it in memory)
	ui.palette_memory_open(&app.palette.pal, &app.state, pjoin({config_dir(), "palette_choices.txt"}))
	placement_restore(app)
	drafts_load(app)   // (what was typed before, in each session: the home page's comes back now)
	app.previews.host = web_host_system()
	platform.set_dark_title(app.win, !app.cx.theme.light)
	app.devtools = devtools.start_from_env(app.win, "opencode")
	main_window_adopt(app)
	app.announcer = {mode = prefs_page.announce_mode(&app.cfg_prefs), window = app.win, state = &app.state}
	// (the host was made after the preferences: the user's rendering.partial_redraw, if any, over its own default)
	// (the client's own faces again: standard_apply sets the text faces it is given)
	prefs_page.standard_apply(&app.cfg_prefs, &app.state, {partial_redraw = &app.window.partial_redraw, faces = own_text_faces(app)})
	crash_bar.init(&app.crash_bar, crashed)
	delete(crashed)
	app.settle = FRAMES_AFTER_INPUT

	// the event stream: its first connection loads everything (stream_up)
	server_connect(app, app.server, all = true)   // (once what it needs is read, on a chore)

	if frames := opts.frames; frames >= 0 {   // --frames=N: N frames of the hidden window, then exit (a check that it runs)
		first: time.Duration   // from the start of main to the end of the first frame
		for i in 0 ..< frames {
			frame(app)
			if i == 0 { first = time.tick_since(started) }
			time.sleep(CHECK_FRAME_SLEEP_MS * time.Millisecond)
		}
		fmt.printfln("opencode-native: %d frames, %d boxes, online=%v, %d sessions, %d messages, first frame %.1f ms", frames, app.state.boxes_built, online(app), len(app.sessions), len(main_pane(app).chat.messages), time.duration_milliseconds(first))
		stores_close(app)
		log_stop(logger)
		os.exit(0)
	}

	updates_start(app)   // (a server or none: this program's own updates)
	// (after an update, once: a message that stays opens the settings at What's new)
	prefs_page.changelog_after_update(&app.changelog, &app.cfg_prefs, APP_VERSION, &app.announcer, proc(user: rawptr) {
		settings_open_on((^App)(user), prefs_page.CHANGELOG_PAGE)
	}, app)
	// (the install read on a task: the installed copy cleans what an update left; OPENCODE_NATIVE_NO_SETUP: never offered)
	prefs_page.install_offer(&app.install, &app.state, offer = opts.command != .Setup && os.get_env("OPENCODE_NATIVE_NO_SETUP", context.temp_allocator) == "")
	cli_show(app, opts)   // what the line asks to see at start
	if opts.slow_motion != 0 { film_slow_start(app, opts.slow_motion) }
	// (the posts' queue exists: a second start's message reaches the window from here on)
	server: ^instance.Server
	if owns { server = instance_serve(app, owner) }
	platform.show_window(app.win)
	// (the windows of the views are the main window's: host_frame makes their frames after its own, hosts_wait counts them)
	hosts := [1]^host.Host{&app.window}
	for !platform.is_closed(app.win) && !app.quit {
		if due, _ := host.hosts_due(hosts[:]); !due {
			film_slow_tick(app)
			host.hosts_wait(hosts[:])
		}
		frame(app)   // (what it still owes goes down there: host_frame)
		placement_track(app)
	}
	// (the name let go before the long end: a start from now on owns it; Restart's copy starts last, below)
	instance.serve_stop(server)
	// (after the last build: which views were open is written, their windows close)
	ui.views_destroy(&app.program_views)
	threads_stop(app)
	updates_stop(app)   // (before the state's posts close: no news after it)
	if app.cx.due[.Drafts].due_ms != 0 { drafts_save(app) }   // (what was typed in the last second)
	config.user_writer_stop(&app.prefs_writer, &app.cfg_prefs)
	stores_close(app)   // (waits for the disk: the window is gone, nothing waits on a frame)
	ui.keymap_destroy(&app.keymap)   // (after the preferences' writer: the palette changes it no more)
	zooms_destroy(app)
	ui.post_close(&app.state)
	prefs_page.install_end(&app.install)
	crash_bar.destroy(&app.crash_bar)
	prefs_page.install_launch(&app.install)   // (the window is gone: the installed copy the install's dialog opened starts)
	app_launch_after(app)
	log_stop(logger)
	os.exit(0)
}

// The window opens where it was, on the monitor it was on (set_placement brings it onto one that is there), unless --size asks
// for a size. Before it is shown; the surface then takes that monitor's size. (Wayland: the compositor places it; only
// maximized comes back.)
placement_restore :: proc(app: ^App) {
	if app.cli.size != nil { return }
	if !prefs_page.placement_restore(&app.cx.placement, &app.cfg_prefs, app.win) { return }
	if !app.cli.no_fixed_surface { render.set_fixed_surface(&app.r, platform.monitor_size(app.win)) }
}

// Where the window is, kept when it changes (the toolkit's window.placement, looked at every PLACEMENT_CHECK_MS): an
// update's restart, a crash or a close all find it saved. (It runs in the main loop, after show_window.)
placement_track :: proc(app: ^App) {
	if prefs_page.placement_track(&app.cx.placement, &app.cfg_prefs, app.win, ui.now_ms()) { prefs_refresh(app) }
}
