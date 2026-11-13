// Everything the program can be asked to do, in one table: the keyboard, the palette (palette.odin) and the help read it, so
// that a key shown is a key that works. A command runs after the frame (command_run): it may drop what the boxes of this
// frame still read.
package ocn

import "core:fmt"
import "core:math"
import "core:strings"
import "gt:draw"
import "gt:platform"
import prefs_page "gt:prefs_page"
import "gt:ui"
import lucide "gt:lucide"
import i18n "gt:i18n"

Command :: struct {
	id, title, group, icon: string,
	tags:    string,                // other words the palette finds it by, that its title does not say ("exit close" for Quit)
	keys:    string,                // as shown
	key:     platform.Key,          // .None: no key of its own here (the keys of a widget, or none)
	mods:    platform.Modifiers,
	run:     proc(app: ^App),
	enabled: proc(app: ^App) -> bool,   // nil: always
	checked: proc(app: ^App) -> bool,   // nil: not a toggle
	over:    proc(app: ^App) -> bool,   // its key with a dialog over the window (overlay_open): when it still works; nil: never
}

@(private = "file") has_session :: proc(app: ^App) -> bool { return app.chat.id != "" }
@(private = "file") is_busy :: proc(app: ^App) -> bool { return app.chat.busy }
@(private = "file") can_go_back :: proc(app: ^App) -> bool { return nav_can(app, -1) || back_target(app) != "" }

COMMANDS := [?]Command{
	{id = "app.palette", title = i18n.later("Command palette"), tags = "commands actions search launcher", group = i18n.later("General"), icon = lucide.SEARCH, keys = "Ctrl+K, Ctrl+Shift+P", key = .K, mods = {.Ctrl}, run = palette_toggle, over = proc(app: ^App) -> bool { return app.cx.open[.Palette] }},
	{id = "app.help", title = i18n.later("Keyboard shortcuts"), tags = "keys keybindings hotkeys help cheatsheet", group = i18n.later("General"), icon = lucide.LIST, keys = "F1", key = .F1, run = proc(app: ^App) { app.cx.open[.Help] = !app.cx.open[.Help] }, over = proc(app: ^App) -> bool { return app.cx.open[.Help] }},
	{id = "app.settings", title = i18n.later("Settings"), tags = "preferences options configuration prefs", group = i18n.later("General"), icon = lucide.SLIDERS_HORIZONTAL, keys = "Ctrl+,", key = .Comma, mods = {.Ctrl}, run = settings_open},
	{id = "app.refresh", title = i18n.later("Refresh"), tags = "reload sync update fetch", group = i18n.later("General"), icon = lucide.REFRESH_CW, keys = "F5", key = .F5, run = proc(app: ^App) {
		refresh_sessions(app)
		if app.chat.id != "" { load_messages(app, app.chat.id) }
	}},
	{id = "app.add_server", title = i18n.later("Add a server…"), tags = "connect host remote url", group = i18n.later("General"), icon = lucide.PLUG, run = proc(app: ^App) { server_edit_open(app, -1) }},
	{id = "app.pair", title = i18n.later("Pair a device…"), tags = "phone mobile qr link", group = i18n.later("General"), icon = lucide.GLOBE, run = pair_open, enabled = online},
	{id = "app.setup", title = i18n.later("Installation and about"), tags = "about version install uninstall setup path info", group = i18n.later("General"), icon = lucide.PACKAGE, run = proc(app: ^App) { settings_open_on(app, prefs_page.INSTALL_PAGE) }},
	{id = "app.diagnostics", title = i18n.later("Diagnostics"), tags = "gpu graphics slow performance frames renderer report", group = i18n.later("General"), icon = lucide.ACTIVITY, run = proc(app: ^App) { settings_open_on(app, prefs_page.DIAGNOSTICS_PAGE) }},
	{id = "app.update", title = i18n.later("Check for updates"), tags = "upgrade version new release", group = i18n.later("General"), icon = lucide.REFRESH_CW, run = update_check_now},
	{id = "app.update_install", title = i18n.later("Install the update"), tags = "upgrade download version", group = i18n.later("General"), icon = lucide.REFRESH_CW, run = update_install_now, enabled = proc(app: ^App) -> bool { return update_phase(app) == .Available }},
	{id = "app.update_restart", title = i18n.later("Restart to update"), tags = "relaunch reload reboot upgrade", group = i18n.later("General"), icon = lucide.REFRESH_CW, run = app_restart, enabled = proc(app: ^App) -> bool { return update_phase(app) == .Installed }},
	{id = "app.restart", title = i18n.later("Restart opencode native"), tags = "relaunch reload reboot reopen", group = i18n.later("General"), icon = lucide.POWER, run = app_restart},
	{id = "app.quit", title = i18n.later("Quit"), tags = "exit close leave", group = i18n.later("General"), icon = lucide.X, keys = "Alt+F4", run = proc(app: ^App) { app.quit = true }},

	{id = "nav.home", title = i18n.later("Home"), tags = "start welcome new", group = i18n.later("Go to"), icon = lucide.MESSAGE_SQUARE, keys = "Ctrl+H", key = .H, mods = {.Ctrl}, run = new_session},
	{id = "nav.back", title = i18n.later("Back"), tags = "previous return history", group = i18n.later("Go to"), icon = lucide.ARROW_LEFT, keys = "Alt+Left", key = .Left, mods = {.Alt}, enabled = can_go_back, run = proc(app: ^App) { if nav_can(app, -1) { nav_step(app, -1) } else { go_back(app) } }},
	{id = "nav.forward", title = i18n.later("Forward"), tags = "next history", group = i18n.later("Go to"), icon = lucide.ARROW_RIGHT, keys = "Alt+Right", key = .Right, mods = {.Alt}, enabled = proc(app: ^App) -> bool { return nav_can(app, 1) }, run = proc(app: ^App) { nav_step(app, 1) }},
	{id = "nav.composer", title = i18n.later("Focus the composer"), tags = "input prompt type message write", group = i18n.later("Go to"), icon = lucide.PENCIL, keys = "Ctrl+L", key = .L, mods = {.Ctrl}, run = proc(app: ^App) { app.composer.focus_next = true }},

	{id = "session.new", title = i18n.later("New session"), tags = "chat conversation create start", group = i18n.later("Session"), icon = lucide.PLUS, keys = "Ctrl+N", key = .N, mods = {.Ctrl}, run = new_session},
	{id = "session.background", title = i18n.later("Push the running command to the background"), tags = "detach background shell job", group = i18n.later("Session"), icon = lucide.SEND_TO_BACK, run = proc(app: ^App) { background_session(app, app.chat.id) }, enabled = foreground_command},
	{id = "session.stop", title = i18n.later("Stop the run"), tags = "cancel abort interrupt halt kill", group = i18n.later("Session"), icon = lucide.SQUARE, keys = "Ctrl+Esc", key = .Escape, mods = {.Ctrl}, run = proc(app: ^App) { interrupt_session(app, app.chat.id) }, enabled = is_busy},
	{id = "session.activity", title = i18n.later("What runs in the background"), tags = "jobs tasks processes activity running", group = i18n.later("Session"), icon = lucide.SQUARE_TERMINAL, keys = "Ctrl+J", key = .J, mods = {.Ctrl}, run = activity_toggle, enabled = has_session},
	{id = "session.quote", title = i18n.later("Quote what is selected"), tags = "reply cite selection", group = i18n.later("Session"), icon = lucide.PENCIL, keys = "Ctrl+Q", key = .Q, mods = {.Ctrl}, run = quote_selection, enabled = proc(app: ^App) -> bool { return ui.has_selection(&app.state) }},
	{id = "session.find", title = i18n.later("Find in the conversation"), tags = "search look locate", group = i18n.later("Session"), icon = lucide.SEARCH, keys = "Ctrl+F", run = find_open, enabled = has_session},
	{id = "session.stats", title = i18n.later("Show or hide the Statistics panel"), tags = "stats tokens cost usage numbers", group = i18n.later("Session"), icon = lucide.GAUGE, keys = "Ctrl+I", key = .I, mods = {.Ctrl}, run = stats_toggle, enabled = has_session, checked = proc(app: ^App) -> bool { return app.stats.open }},
	{id = "session.rename", title = i18n.later("Rename the session…"), tags = "title name", group = i18n.later("Session"), icon = lucide.PENCIL, keys = "F2", key = .F2, run = proc(app: ^App) { rename_open(app, app.chat.id) }, enabled = has_session},
	{id = "session.fork", title = i18n.later("Fork the session"), tags = "branch copy duplicate split", group = i18n.later("Session"), icon = lucide.COPY, run = proc(app: ^App) { fork_session(app, app.chat.id, "") }, enabled = has_session},
	{id = "session.compact", title = i18n.later("Compact the conversation"), tags = "summarize shrink compress context", group = i18n.later("Session"), icon = lucide.LIST, run = proc(app: ^App) { request(app, .Action, "POST", fmt.tprintf("/api/session/%s/compact", app.chat.id), "{}", app.chat.id) }, enabled = has_session},
	{id = "session.background", title = i18n.later("Send running tools to the background"), tags = "detach background jobs", group = i18n.later("Session"), icon = lucide.SQUARE_TERMINAL, run = proc(app: ^App) { request(app, .Action, "POST", fmt.tprintf("/api/session/%s/background", app.chat.id), "", app.chat.id) }, enabled = is_busy},
	{id = "app.connections", title = i18n.later("Connect an account"), tags = "login provider oauth sign auth", group = i18n.later("General"), icon = lucide.USER, run = proc(app: ^App) { settings_open_on(app, "connections") }},
	{id = "view.terminal", title = i18n.later("Terminal"), tags = "shell console bash pty", group = i18n.later("View"), icon = lucide.SQUARE_TERMINAL, keys = "Ctrl+Shift+T", key = .T, mods = {.Ctrl, .Shift}, run = terminal_toggle},
	{id = "view.terminal_new", title = i18n.later("New terminal"), tags = "shell console bash pty open", group = i18n.later("View"), icon = lucide.SQUARE_TERMINAL, run = terminal_new},
	{id = "session.schedules", title = i18n.later("Schedules of this session"), tags = "cron timer planned recurring", group = i18n.later("Session"), icon = lucide.HISTORY, run = proc(app: ^App) { schedules_open(app, app.chat.id) }, enabled = proc(app: ^App) -> bool { return app.chat.id != "" && !app.cx.no_schedules }},
	{id = "session.artifacts", title = i18n.later("Artifacts of this folder"), tags = "outputs files html pages", group = i18n.later("Session"), icon = lucide.FILE, run = artifacts_open, enabled = proc(app: ^App) -> bool { return !app.cx.no_artifacts }},
	{id = "session.files", title = i18n.later("Browse the files"), tags = "explorer tree folder open", group = i18n.later("Session"), icon = lucide.FOLDER, keys = "Ctrl+P", key = .P, mods = {.Ctrl}, run = files_open},
	{id = "session.changes", title = i18n.later("What this session changed"), tags = "diff changes edits modified", group = i18n.later("Session"), icon = lucide.FILE, run = proc(app: ^App) { changes_open(app, app.chat.id) }, enabled = has_session},
	{id = "session.archive", title = i18n.later("Archive the session, or bring it back"), tags = "hide restore unarchive", group = i18n.later("Session"), icon = lucide.FILE_ARCHIVE, run = proc(app: ^App) { session_archive(app, app.chat.id, !session_is_archived(app, app.chat.id)) }, enabled = has_session},
	{id = "session.terminal", title = i18n.later("Open a terminal in the session's folder"), tags = "shell console bash cwd", group = i18n.later("Session"), icon = lucide.SQUARE_TERMINAL, run = proc(app: ^App) { terminal_open(chat_dir(app)) }, enabled = has_session},
	{id = "session.move", title = i18n.later("Move the session to a folder"), tags = "directory relocate path", group = i18n.later("Session"), icon = lucide.FOLDER, run = proc(app: ^App) { session_move_pick(app, app.chat.id) }, enabled = has_session},
	{id = "session.export", title = i18n.later("Export the session"), tags = "save download markdown json share", group = i18n.later("Session"), icon = lucide.FILE, run = proc(app: ^App) { session_export(app, app.chat.id) }, enabled = has_session},
	{id = "session.export_redacted", title = i18n.later("Export the session without its text"), tags = "redact anonymize share save", group = i18n.later("Session"), icon = lucide.FILE, run = proc(app: ^App) { session_export(app, app.chat.id, redacted = true) }, enabled = has_session},
	{id = "composer.attach", title = i18n.later("Attach files"), tags = "upload image file add", group = i18n.later("Session"), icon = lucide.PAPERCLIP, run = attach_pick},
	{id = "session.import", title = i18n.later("Import a session"), tags = "load open json", group = i18n.later("Session"), icon = lucide.FILE, run = session_import_pick},
	{id = "session.copy_id", title = i18n.later("Copy the session ID"), tags = "clipboard identifier", group = i18n.later("Session"), icon = lucide.COPY, run = proc(app: ^App) { clip_set(app.chat.id) }, enabled = has_session},

	{id = "view.panel_window", title = i18n.later("Open this panel in a window"), tags = "detach popout float separate", group = i18n.later("View"), icon = lucide.APP_WINDOW, run = panel_window_open, enabled = panel_window_can},
	{id = "view.preview", title = i18n.later("Show or hide the Preview panel"), tags = "browser web page", group = i18n.later("View"), icon = lucide.GLOBE, keys = "Ctrl+Shift+B", key = .B, mods = {.Ctrl, .Shift}, run = preview_toggle, checked = proc(app: ^App) -> bool { return app.preview.open }},
	// (Their keys are the panel's, read while it has the keyboard: elsewhere Ctrl+W is a shell's, and a composer's to ignore.)
	{id = "view.preview_tab", title = i18n.later("New browser tab"), tags = "preview web page url", group = i18n.later("View"), icon = lucide.PLUS, keys = "Ctrl+T", run = preview_tab_new},
	{id = "view.preview_tab_close", title = i18n.later("Close browser tab"), tags = "preview web page", group = i18n.later("View"), icon = lucide.X, keys = "Ctrl+W", run = preview_tab_close_front, enabled = preview_tab_can_close},
	{id = "view.sidebar", title = i18n.later("Show or hide the sidebar"), tags = "sessions list toggle collapse", group = i18n.later("View"), icon = lucide.MENU, keys = "Ctrl+B", key = .B, mods = {.Ctrl}, run = proc(app: ^App) { app.sidebar.hidden = !app.sidebar.hidden }, checked = proc(app: ^App) -> bool { return !app.sidebar.hidden }},
	{id = "view.prompt_rail", title = i18n.later("Show or hide the prompt marks"), tags = "minimap rail scrollbar overview ruler timeline prompts messages navigate jump outline", group = i18n.later("View"), icon = lucide.LIST, run = proc(app: ^App) { pref_set(app, "conversation.prompt_rail", app.prefs.prompt_rail ? "false" : "true") }, checked = proc(app: ^App) -> bool { return app.prefs.prompt_rail }},
	{id = "view.notices", title = i18n.later("What you missed"), tags = "notifications inbox missed events log bell unread", group = i18n.later("View"), icon = lucide.BELL, keys = "Ctrl+Shift+N", key = .N, mods = {.Ctrl, .Shift}, run = missed_toggle, over = proc(app: ^App) -> bool { return app.cx.open[.Notices] }},
	{id = "notices.next", title = i18n.later("Next missed"), tags = "notifications queue next unread inbox", group = i18n.later("Go to"), icon = lucide.ARROW_RIGHT, run = missed_next},
	{id = "view.sidebar_mode", title = i18n.later("Switch the sidebar's mode (inbox, projects)"), tags = "inbox projects folders group", group = i18n.later("View"), icon = lucide.LIST, run = sidebar_mode_next},
	{id = "view.content_in", title = i18n.later("Zoom in the conversation"), tags = "bigger larger font size text", group = i18n.later("View"), icon = lucide.PLUS, keys = "Ctrl+=", run = proc(app: ^App) { content_zoom_by(app, ui.feel(&app.state).zoom_step) }},
	{id = "view.content_out", title = i18n.later("Zoom out the conversation"), tags = "smaller font size text", group = i18n.later("View"), icon = lucide.CHEVRON_DOWN, keys = "Ctrl+-", run = proc(app: ^App) { content_zoom_by(app, 1 / ui.feel(&app.state).zoom_step) }},
	{id = "view.content_reset", title = i18n.later("Reset the conversation's zoom"), tags = "default font size text", group = i18n.later("View"), icon = lucide.UNDO_2, keys = "Ctrl+0", run = proc(app: ^App) { content_zoom_reset(app) }},
	{id = "view.chrome_in", title = i18n.later("Zoom in the interface"), tags = "bigger larger scale ui", group = i18n.later("View"), icon = lucide.PLUS, keys = "Ctrl+Shift+=", run = proc(app: ^App) { ui.set_zoom(&app.state, ui.zoom(&app.state) * ui.feel(&app.state).zoom_step) }},
	{id = "view.chrome_out", title = i18n.later("Zoom out the interface"), tags = "smaller scale ui", group = i18n.later("View"), icon = lucide.CHEVRON_DOWN, keys = "Ctrl+Shift+-", run = proc(app: ^App) { ui.set_zoom(&app.state, ui.zoom(&app.state) / ui.feel(&app.state).zoom_step) }},
	{id = "view.chrome_reset", title = i18n.later("Reset the interface's zoom"), tags = "default scale ui", group = i18n.later("View"), icon = lucide.UNDO_2, keys = "Ctrl+Shift+0", run = proc(app: ^App) { ui.set_zoom(&app.state, 1) }},
}

command_enabled :: proc(app: ^App, c: ^Command) -> bool { return c.enabled == nil || c.enabled(app) }

command_find :: proc(id: string) -> ^Command {
	for &c in COMMANDS { if c.id == id { return &c } }
	return nil
}

// Asked for now, done after the frame, in the order asked.
command_run :: proc(app: ^App, c: ^Command) { append(&app.cx.commands_due, c) }

commands_apply :: proc(app: ^App) {
	if len(app.cx.commands_due) == 0 { return }
	for i := 0; i < len(app.cx.commands_due); i += 1 { app.cx.commands_due[i].run(app) }
	clear(&app.cx.commands_due)
	app.settle = max(app.settle, FRAMES_AFTER_INPUT)
}

// Whether its key does something now: what is open over the window has the keyboard, unless the command is meant to work there.
command_keyed :: proc(app: ^App, c: ^Command) -> bool {
	if !command_enabled(app, c) { return false }
	return !overlay_open(app) || (c.over != nil && c.over(app))
}

// The keys of the table, at the start of a build. The palette has its other name.
commands_keys :: proc(app: ^App) {
	for &c in COMMANDS {
		if c.key == .None || !command_keyed(app, &c) { continue }
		if ui.key_pressed_peek(c.key, c.mods) && ui.key_press(c.key, c.mods) { command_run(app, &c) }
	}
	if c := command_find("app.palette"); command_keyed(app, c) && ui.key_press(.P, {.Ctrl, .Shift}) { command_run(app, c) }
}

// A dialog, a picker or a menu is over the window. What reads the keyboard behind them asks here. A new dialog is a Dialog, and
// its being open is App_Context.open: then it is in this answer. What is not there says it in its own state:
// - Changes: its state machine (Changes_State) says whether it is on screen; a bool beside it could disagree with it.
// - Output: the view shown is the dialog's subject; nil is its being closed.
// - The install's dialog: the toolkit's prefs_page.Install keeps its own (install_open_now).
// - the toolkit's menus (ui.menu), which the toolkit's state holds.
overlay_open :: proc(app: ^App) -> bool {
	return app.cx.open != {} || changes_shown(&app.cx.changes) || app.cx.outputs.shown != nil || prefs_page.install_open_now(&app.install) || len(app.state.menus) > 0
}

// The conversation's zoom: the session shown's own, or the preference (appearance.content_zoom), which is every session's that has
// none of its own and the home page's.
content_zoom :: proc(app: ^App) -> f32 { return zoom_of(&app.session_zooms, app.chat.id, app.prefs.content_zoom) }

// The session shown's zoom (kept in session_zoom.txt); on the home page, the preference.
content_zoom_set :: proc(app: ^App, z: f32) {
	zoom := clamp(z, CONTENT_ZOOM_MIN, CONTENT_ZOOM_MAX)
	if app.chat.id == "" {
		pref_set_float(app, "appearance.content_zoom", zoom)
		return
	}
	zoom_keep(&app.session_zooms, &app.stores.session_zooms, app.chat.id, zoom, app.prefs.content_zoom)
}

content_zoom_by :: proc(app: ^App, factor: f32) { content_zoom_set(app, content_zoom(app) * factor) }

// Back to the preference: the session follows it again.
content_zoom_reset :: proc(app: ^App) {
	if app.chat.id == "" { content_zoom_set(app, 1) } else { zoom_forget(&app.session_zooms, &app.stores.session_zooms, app.chat.id) }
}

// What the toolkit would make of the window's zoom, where it is the conversation's that is meant: Ctrl and the wheel over
// the conversation, Ctrl and = - 0 without Shift (with it: the interface, which the toolkit does). Before the build.
content_zoom_events :: proc(app: ^App, events: []platform.Event) {
	for &e in events {
		#partial switch e.kind {
		case .Scroll:
			// (a dialog over the conversation has the wheel: the diagram viewer's zooms its diagram)
			if .Ctrl not_in e.mods || overlay_open(app) || !draw.rect_contains(app.conversation.rect, e.pos) { continue }
			z := content_zoom(app)
			content_zoom_set(app, e.delta.y < 0 ? z * ui.feel(&app.state).zoom_step : z / ui.feel(&app.state).zoom_step)
			e.kind = .None
		case .Key_Press:
			if e.mods != {.Ctrl} { continue }
			#partial switch e.key {
			case .Equal, .Num_Add:      content_zoom_by(app, ui.feel(&app.state).zoom_step)
			case .Minus, .Num_Subtract: content_zoom_by(app, 1 / ui.feel(&app.state).zoom_step)
			case .N0:                   content_zoom_reset(app)
			case: continue
			}
			e.kind = .None
		}
	}
}

// The keys of the table as a dialog: what can be done, by group.
help_dialog :: proc(app: ^App, em: f32) {
	if ui.modal("help", &app.cx.open[.Help], dialog_options(app, .Help)) {
		dialog_backdrop()
		ui.next({width = ui.fill(), height = ui.fill()})
		if ui.scroll_y("###help_scroll") {
		ui.spacer(ui.px(em))
		ui.next({width = ui.fill(), height = ui.children_sum(), axis = .X})
		if ui.row(id = "###help") {
			ui.spacer(ui.px(em * 1.2))
			ui.next({width = ui.fill(), height = ui.children_sum(), axis = .Y})
			if ui.column() {
				text("t", i18n.tr("Keyboard shortcuts"), hex(HEX_BRIGHT), ui.Style_Mod{font_size = math.round(em * FS_TITLE), height = ui.px(em * 2)}, ui.fill())
				row :: proc(app: ^App, id, keys, what: string, em: f32) {
					ui.next({width = ui.fill(), height = ui.px(em * 1.6), axis = .X, cross = .Center})
					if ui.row(.Center, id = id) {
						text("w", what, hex(HEX_TEXT_SOFT), ui.Style_Mod{font_size = math.round(em * FS_LABEL)}, ui.fill())
						text("k", keys, hex(HEX_WEAK), ui.Style_Mod{font = app.mono, font_size = math.round(em * FS_SMALL)})
					}
				}
				group := ""
				for &c, i in COMMANDS {
					if c.keys == "" { continue }
					if c.group != group {
						group = c.group
						ui.spacer(ui.px(em * 0.4))
						section_label(fmt.tprintf("g%d", i), strings.to_upper(i18n.tr(group), context.temp_allocator), em)
					}
					row(app, fmt.tprintf("###h%d", i), c.keys, i18n.tr(c.title), em)
				}
				ui.spacer(ui.px(em * 0.4))
				section_label("gc", strings.to_upper(i18n.tr("Composer"), context.temp_allocator), em)
				row(app, "###hc1", i18n.tr("Up / Down"), i18n.tr("Go through what you sent in this session"), em)
				row(app, "###hc2", i18n.tr("Down"), i18n.tr("On the last line: what runs in the background"), em)
				row(app, "###hc3", "Ctrl+V", i18n.tr("Paste text, an image or files"), em)
				row(app, "###hc4", i18n.tr("Middle click"), i18n.tr("Scroll by the pointer"), em)
				row(app, "###hc5", "Esc", i18n.tr("Stop the run, what was sent during it goes next"), em)
				ui.spacer(ui.px(em))
			}
			ui.spacer(ui.px(em * 1.2))
		}
		}
	}
}
