// Everything the program can be asked to do, in one table: the keyboard, the palette (palette.odin) and the help read it, so
// that a key shown is a key that works. A command runs after the frame (command_run): it may drop what the boxes of this
// frame still read.
package ocn

import "core:fmt"
import "core:math"
import "core:strings"
import "gt:platform"
import "gt:ui"
import lucide "gt:lucide"

Command :: struct {
	id, title, group, icon: string,
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
	{id = "app.palette", title = "Command palette", group = "General", icon = lucide.SEARCH, keys = "Ctrl+K, Ctrl+Shift+P", key = .K, mods = {.Ctrl}, run = palette_toggle, over = proc(app: ^App) -> bool { return app.palette.open }},
	{id = "app.help", title = "Keyboard shortcuts", group = "General", icon = lucide.LIST, keys = "F1", key = .F1, run = proc(app: ^App) { app.cx.help_open = !app.cx.help_open }, over = proc(app: ^App) -> bool { return app.cx.help_open }},
	{id = "app.settings", title = "Settings", group = "General", icon = lucide.SLIDERS_HORIZONTAL, keys = "Ctrl+,", key = .Comma, mods = {.Ctrl}, run = settings_open},
	{id = "app.refresh", title = "Refresh", group = "General", icon = lucide.REFRESH_CW, keys = "F5", key = .F5, run = proc(app: ^App) {
		refresh_sessions(app)
		if app.chat.id != "" { load_messages(app, app.chat.id) }
	}},
	{id = "app.add_server", title = "Add a server…", group = "General", icon = lucide.PLUG, run = proc(app: ^App) { server_edit_open(app, -1) }},
	{id = "app.pair", title = "Pair a device…", group = "General", icon = lucide.GLOBE, run = pair_open, enabled = online},
	{id = "app.setup", title = "Setup and about", group = "General", icon = lucide.LIGHTBULB, run = setup_open},
	{id = "app.update", title = "Check for updates", group = "General", icon = lucide.REFRESH_CW, run = update_check_now},
	{id = "app.update_install", title = "Install the update", group = "General", icon = lucide.REFRESH_CW, run = update_install, enabled = proc(app: ^App) -> bool { return update_is_ready(&app.updater) }},
	{id = "app.update_restart", title = "Restart to update", group = "General", icon = lucide.REFRESH_CW, run = update_restart, enabled = proc(app: ^App) -> bool { return update_is_installed(&app.updater) }},
	{id = "app.quit", title = "Quit", group = "General", icon = lucide.X, keys = "Alt+F4", run = proc(app: ^App) { app.quit = true }},

	{id = "nav.home", title = "Home", group = "Go to", icon = lucide.MESSAGE_SQUARE, keys = "Ctrl+H", key = .H, mods = {.Ctrl}, run = new_session},
	{id = "nav.back", title = "Back", group = "Go to", icon = lucide.ARROW_LEFT, keys = "Alt+Left", key = .Left, mods = {.Alt}, enabled = can_go_back, run = proc(app: ^App) { if nav_can(app, -1) { nav_step(app, -1) } else { go_back(app) } }},
	{id = "nav.forward", title = "Forward", group = "Go to", icon = lucide.ARROW_RIGHT, keys = "Alt+Right", key = .Right, mods = {.Alt}, enabled = proc(app: ^App) -> bool { return nav_can(app, 1) }, run = proc(app: ^App) { nav_step(app, 1) }},
	{id = "nav.composer", title = "Focus the composer", group = "Go to", icon = lucide.PENCIL, keys = "Ctrl+L", key = .L, mods = {.Ctrl}, run = proc(app: ^App) { app.cx.focus_composer = true }},

	{id = "session.new", title = "New session", group = "Session", icon = lucide.PLUS, keys = "Ctrl+N", key = .N, mods = {.Ctrl}, run = new_session},
	{id = "session.background", title = "Push the running command to the background", group = "Session", icon = lucide.SEND_TO_BACK, run = proc(app: ^App) { background_session(app, app.chat.id) }, enabled = foreground_command},
	{id = "session.stop", title = "Stop the run", group = "Session", icon = lucide.SQUARE, keys = "Ctrl+Esc", key = .Escape, mods = {.Ctrl}, run = proc(app: ^App) { interrupt_session(app, app.chat.id) }, enabled = is_busy},
	{id = "session.activity", title = "What runs in the background", group = "Session", icon = lucide.SQUARE_TERMINAL, keys = "Ctrl+J", key = .J, mods = {.Ctrl}, run = activity_toggle, enabled = has_session},
	{id = "session.quote", title = "Quote what is selected", group = "Session", icon = lucide.PENCIL, keys = "Ctrl+Q", key = .Q, mods = {.Ctrl}, run = quote_selection, enabled = proc(app: ^App) -> bool { return ui.has_selection(&app.state) }},
	{id = "session.find", title = "Find in the conversation", group = "Session", icon = lucide.SEARCH, keys = "Ctrl+F", run = find_open, enabled = has_session},
	{id = "session.stats", title = "Show or hide the Statistics panel", group = "Session", icon = lucide.GAUGE, keys = "Ctrl+I", key = .I, mods = {.Ctrl}, run = stats_toggle, enabled = has_session, checked = proc(app: ^App) -> bool { return app.stats_open }},
	{id = "session.rename", title = "Rename the session…", group = "Session", icon = lucide.PENCIL, keys = "F2", key = .F2, run = proc(app: ^App) { rename_open(app, app.chat.id) }, enabled = has_session},
	{id = "session.fork", title = "Fork the session", group = "Session", icon = lucide.COPY, run = proc(app: ^App) { fork_session(app, app.chat.id, "") }, enabled = has_session},
	{id = "session.compact", title = "Compact the conversation", group = "Session", icon = lucide.LIST, run = proc(app: ^App) { request(app, .Action, "POST", fmt.tprintf("/api/session/%s/compact", app.chat.id), "{}", app.chat.id) }, enabled = has_session},
	{id = "session.background", title = "Send running tools to the background", group = "Session", icon = lucide.SQUARE_TERMINAL, run = proc(app: ^App) { request(app, .Action, "POST", fmt.tprintf("/api/session/%s/background", app.chat.id), "", app.chat.id) }, enabled = is_busy},
	{id = "app.connections", title = "Connect an account", group = "General", icon = lucide.USER, run = proc(app: ^App) { app.settings_page = .Connections; settings_open(app) }},
	{id = "view.terminal", title = "Terminal", group = "View", icon = lucide.SQUARE_TERMINAL, keys = "Ctrl+Shift+T", key = .T, mods = {.Ctrl, .Shift}, run = terminal_toggle},
	{id = "view.terminal_new", title = "New terminal", group = "View", icon = lucide.SQUARE_TERMINAL, run = terminal_new},
	{id = "session.schedules", title = "Schedules of this session", group = "Session", icon = lucide.HISTORY, run = proc(app: ^App) { schedules_open(app, app.chat.id) }, enabled = proc(app: ^App) -> bool { return app.chat.id != "" && !app.cx.no_schedules }},
	{id = "session.artifacts", title = "Artifacts of this folder", group = "Session", icon = lucide.FILE, run = artifacts_open, enabled = proc(app: ^App) -> bool { return !app.cx.no_artifacts }},
	{id = "session.files", title = "Browse the files", group = "Session", icon = lucide.FOLDER, keys = "Ctrl+P", key = .P, mods = {.Ctrl}, run = files_open},
	{id = "session.changes", title = "What this session changed", group = "Session", icon = lucide.FILE, run = proc(app: ^App) { changes_open(app, app.chat.id) }, enabled = has_session},
	{id = "session.move", title = "Move the session to a folder", group = "Session", icon = lucide.FOLDER, run = proc(app: ^App) { session_move_pick(app, app.chat.id) }, enabled = has_session},
	{id = "session.export", title = "Export the session", group = "Session", icon = lucide.FILE, run = proc(app: ^App) { session_export(app, app.chat.id) }, enabled = has_session},
	{id = "session.export_redacted", title = "Export the session without its text", group = "Session", icon = lucide.FILE, run = proc(app: ^App) { session_export(app, app.chat.id, redacted = true) }, enabled = has_session},
	{id = "composer.attach", title = "Attach files", group = "Session", icon = lucide.PAPERCLIP, run = attach_pick},
	{id = "session.import", title = "Import a session", group = "Session", icon = lucide.FILE, run = session_import_pick},
	{id = "session.copy_id", title = "Copy the session ID", group = "Session", icon = lucide.COPY, run = proc(app: ^App) { clip_set(app.chat.id) }, enabled = has_session},

	{id = "view.panel_window", title = "Open this panel in a window", group = "View", icon = lucide.APP_WINDOW, run = panel_window_open, enabled = panel_window_can},
	{id = "view.preview", title = "Show or hide the Preview panel", group = "View", icon = lucide.GLOBE, keys = "Ctrl+Shift+B", key = .B, mods = {.Ctrl, .Shift}, run = preview_toggle, checked = proc(app: ^App) -> bool { return app.preview.open }},
	// (Their keys are the panel's, read while it has the keyboard: elsewhere Ctrl+W is a shell's, and a composer's to ignore.)
	{id = "view.preview_tab", title = "New browser tab", group = "View", icon = lucide.PLUS, keys = "Ctrl+T", run = preview_tab_new},
	{id = "view.preview_tab_close", title = "Close browser tab", group = "View", icon = lucide.X, keys = "Ctrl+W", run = preview_tab_close_front, enabled = preview_tab_can_close},
	{id = "view.sidebar", title = "Show or hide the sidebar", group = "View", icon = lucide.MENU, keys = "Ctrl+B", key = .B, mods = {.Ctrl}, run = proc(app: ^App) { app.cx.sidebar_hidden = !app.cx.sidebar_hidden }, checked = proc(app: ^App) -> bool { return !app.cx.sidebar_hidden }},
	{id = "view.sidebar_mode", title = "Switch the sidebar's mode (inbox, projects)", group = "View", icon = lucide.LIST, run = sidebar_mode_next},
	{id = "view.content_in", title = "Zoom in the conversation", group = "View", icon = lucide.PLUS, keys = "Ctrl+=", run = proc(app: ^App) { content_zoom_by(app, ZOOM_FACTOR) }},
	{id = "view.content_out", title = "Zoom out the conversation", group = "View", icon = lucide.CHEVRON_DOWN, keys = "Ctrl+-", run = proc(app: ^App) { content_zoom_by(app, 1 / ZOOM_FACTOR) }},
	{id = "view.content_reset", title = "Reset the conversation's zoom", group = "View", icon = lucide.UNDO_2, keys = "Ctrl+0", run = proc(app: ^App) { content_zoom_set(app, 1) }},
	{id = "view.chrome_in", title = "Zoom in the interface", group = "View", icon = lucide.PLUS, keys = "Ctrl+Shift+=", run = proc(app: ^App) { ui.set_zoom(&app.state, ui.zoom(&app.state) * ZOOM_FACTOR) }},
	{id = "view.chrome_out", title = "Zoom out the interface", group = "View", icon = lucide.CHEVRON_DOWN, keys = "Ctrl+Shift+-", run = proc(app: ^App) { ui.set_zoom(&app.state, ui.zoom(&app.state) / ZOOM_FACTOR) }},
	{id = "view.chrome_reset", title = "Reset the interface's zoom", group = "View", icon = lucide.UNDO_2, keys = "Ctrl+Shift+0", run = proc(app: ^App) { ui.set_zoom(&app.state, 1) }},
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

// A dialog, a picker or a menu is over the window: the one list of them. What reads the keyboard behind them asks here.
overlay_open :: proc(app: ^App) -> bool {
	return changes_shown(&app.cx.changes) || app.cx.diff_full.open || app.cx.outputs.shown != nil || app.cx.files.open || app.cx.schedules.open || app.cx.artifacts.open || app.settings_open || app.delete_open || app.view_open || app.setup.open || app.server_edit.open || app.picker.open || app.palette.open || app.cx.help_open || app.pair.open || app.rename.open || len(app.state.menus) > 0
}

content_zoom_set :: proc(app: ^App, z: f32) {
	pref_set(app, "appearance.content_zoom", fmt.tprintf("%.3f", clamp(z, CONTENT_ZOOM_MIN, CONTENT_ZOOM_MAX)))
}

content_zoom_by :: proc(app: ^App, factor: f32) { content_zoom_set(app, app.prefs.content_zoom * factor) }

// What the toolkit would make of the window's zoom, where it is the conversation's that is meant: Ctrl and the wheel over
// the conversation, Ctrl and = - 0 without Shift (with it: the interface, which the toolkit does). Before the build.
content_zoom_events :: proc(app: ^App, events: []platform.Event) {
	for &e in events {
		#partial switch e.kind {
		case .Scroll:
			if .Ctrl not_in e.mods || !rect_contains(app.cx.main_rect, e.pos) { continue }
			z := app.prefs.content_zoom
			content_zoom_set(app, e.delta.y < 0 ? z * ZOOM_FACTOR : z / ZOOM_FACTOR)
			e.kind = .None
		case .Key_Press:
			if e.mods != {.Ctrl} { continue }
			#partial switch e.key {
			case .Equal, .Num_Add:      content_zoom_by(app, ZOOM_FACTOR)
			case .Minus, .Num_Subtract: content_zoom_by(app, 1 / ZOOM_FACTOR)
			case .N0:                   content_zoom_set(app, 1)
			case: continue
			}
			e.kind = .None
		}
	}
}

rect_contains :: proc(r: Rect, p: Vec2) -> bool { return p.x >= r.min.x && p.x < r.max.x && p.y >= r.min.y && p.y < r.max.y }

// The keys of the table as a dialog: what can be done, by group.
help_dialog :: proc(app: ^App, em: f32) {
	if ui.modal_sized("help", DIALOG_PREFERRED_EM[.Help] * em, &app.cx.dialogs[.Help], &app.cx.help_open, DIALOG_MIN_EM[.Help] * em) {
		dialog_backdrop()
		ui.next({width = ui.fill(), height = ui.fill()})
		if ui.scroll_y("###help_scroll") {
		ui.spacer(ui.px(em))
		ui.next({width = ui.fill(), height = ui.children_sum(), axis = .X})
		if ui.row(id = "###help") {
			ui.spacer(ui.px(em * 1.2))
			ui.next({width = ui.fill(), height = ui.children_sum(), axis = .Y})
			if ui.column() {
				text("t", "Keyboard shortcuts", hex(HEX_BRIGHT), ui.Style_Mod{font_size = math.round(em * FS_TITLE), height = ui.px(em * 2)}, ui.fill())
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
						section_label(fmt.tprintf("g%d", i), strings.to_upper(group, context.temp_allocator), em)
					}
					row(app, fmt.tprintf("###h%d", i), c.keys, c.title, em)
				}
				ui.spacer(ui.px(em * 0.4))
				section_label("gc", "COMPOSER", em)
				row(app, "###hc1", "Up / Down", "Go through what you sent in this session", em)
				row(app, "###hc2", "Down", "On the last line: what runs in the background", em)
				row(app, "###hc3", "Ctrl+V", "Paste text, an image or files", em)
				row(app, "###hc4", "Middle click", "Scroll by the pointer", em)
				row(app, "###hc5", "Esc", "Stop the run, what was sent during it goes next", em)
				ui.spacer(ui.px(em))
			}
			ui.spacer(ui.px(em * 1.2))
		}
		}
	}
}
