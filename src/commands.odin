// Everything the program can be asked to do, in one table: the keyboard, the palette (palette.odin) and the help read it, so
// that a key shown is a key that works. A command runs after the frame (command_run): it may drop what the boxes of this
// frame still read.
package ocn

import "core:fmt"
import "gt:config"
import prefs_page "gt:prefs_page"
import "gt:ui"
import lucide "gt:lucide"
import i18n "gt:i18n"

Command :: struct {
	id, title, group, icon: string,
	tags:    string,                // other words the palette finds it by, that its title does not say ("exit close" for Quit)
	// its own keys; what acts and what is shown is the keymap's (app.keymap: a person's key replaces them, or takes one)
	keys:    []ui.Chord,
	// its own keys are read by what has them (the Preview's address bar, the conversation's zoom zone, the system's
	// Alt+F4): the menus, the palette and the help show them, commands_keys does not read them. A person's key on it is
	// read as any.
	keys_elsewhere: bool,
	run:     proc(app: ^App),
	enabled: proc(app: ^App) -> bool,   // nil: always
	checked: proc(app: ^App) -> bool,   // nil: not a toggle
	over:    proc(app: ^App) -> bool,   // its key with a dialog over the window (overlay_open): when it still works; nil: never
	// .Window: the window's (the keys, the settings, quit; the palette's is the toolkit's): its key works in every page, whatever has the
	// keyboard, over a view shown as a dialog too (the settings are one): the toolkit takes it from wherever the focus is
	scope:   ui.Command_Scope,
	// what it takes in the palette: the palette's form asks for them, and `take` gets their values instead of `run` (its key and
	// its menu lines still call `run`, which asks in its own way; src/md/features/palette.md)
	arguments: []config.Def,
	take:      proc(app: ^App, values: []string),
}

// Rename the session's argument: its new title.
RENAME_ARGUMENTS := [?]config.Def{
	// (empty: a default is read as the form opens, so one that followed the title would be freed under an open form)
	{name = "title", title = i18n.later("Title"), description = i18n.later("The session's new title."), kind = .String, default = {s = ""}},
}

@(private = "file") has_session :: proc(app: ^App) -> bool { return main_pane(app).chat.id != "" }
@(private = "file") is_busy :: proc(app: ^App) -> bool { return main_pane(app).chat.busy }
@(private = "file") can_go_back :: proc(app: ^App) -> bool { return nav_can(app, -1) || back_target(app) != "" }
// (Find is the main view's: chat-panes.md, Layer 2; a panel with the keyboard keeps Ctrl+F from it)
@(private = "file") can_find :: proc(app: ^App) -> bool { return has_session(app) && keys_pane(app) == main_pane(app) }

COMMANDS := [?]Command{
	{id = "app.help", title = i18n.later("Keyboard shortcuts"), tags = "keys keybindings hotkeys help cheatsheet", group = i18n.later("General"), icon = lucide.LIST, keys = {{.F1, {}}}, run = help_toggle, scope = .Window},
	{id = "app.settings", title = i18n.later("Settings"), tags = "preferences options configuration prefs", group = i18n.later("General"), icon = lucide.SLIDERS_HORIZONTAL, keys = {{.Comma, {.Ctrl}}}, run = settings_open, scope = .Window},
	{id = "app.refresh", title = i18n.later("Refresh"), tags = "reload sync update fetch", group = i18n.later("General"), icon = lucide.REFRESH_CW, keys = {{.F5, {}}}, run = proc(app: ^App) {
		refresh_sessions(app)
		for &pane, i in app.panes { if pane_is_shown(app, i) && pane.chat.id != "" { load_messages(app, &pane, pane.chat.id) } }
	}},
	{id = "app.add_server", title = i18n.later("Add a server…"), tags = "connect host remote url", group = i18n.later("General"), icon = lucide.PLUG, run = proc(app: ^App) { server_edit_open(app, -1) }},
	{id = "app.pair", title = i18n.later("Pair a device…"), tags = "phone mobile qr link", group = i18n.later("General"), icon = lucide.GLOBE, run = pair_open, enabled = online},
	{id = "app.setup", title = i18n.later("Installation and about"), tags = "about version install uninstall setup path info", group = i18n.later("General"), icon = lucide.PACKAGE, run = proc(app: ^App) { settings_open_on(app, prefs_page.INSTALL_PAGE) }},
	{id = "app.diagnostics", title = i18n.later("Diagnostics"), tags = "gpu graphics slow performance frames renderer report", group = i18n.later("General"), icon = lucide.ACTIVITY, run = proc(app: ^App) { settings_open_on(app, prefs_page.DIAGNOSTICS_PAGE) }},
	{id = "app.update", title = i18n.later("Check for updates"), tags = "upgrade version new release", group = i18n.later("General"), icon = lucide.REFRESH_CW, run = update_check_now},
	{id = "app.update_install", title = i18n.later("Install the update"), tags = "upgrade download version", group = i18n.later("General"), icon = lucide.REFRESH_CW, run = update_install_now, enabled = proc(app: ^App) -> bool { return update_phase(app) == .Available }},
	{id = "app.update_restart", title = i18n.later("Restart to update"), tags = "relaunch reload reboot upgrade", group = i18n.later("General"), icon = lucide.REFRESH_CW, run = app_restart, enabled = proc(app: ^App) -> bool { return update_phase(app) == .Installed }},
	{id = "app.restart", title = i18n.later("Restart Opencode Native"), tags = "relaunch reload reboot reopen", group = i18n.later("General"), icon = lucide.POWER, run = app_restart},
	{id = "app.quit", title = i18n.later("Quit"), tags = "exit close leave", group = i18n.later("General"), icon = lucide.X, keys = {{.F4, {.Alt}}}, keys_elsewhere = true, run = proc(app: ^App) { app.quit = true }, scope = .Window},

	{id = "nav.home", title = i18n.later("Home"), tags = "start welcome new", group = i18n.later("Go to"), icon = lucide.MESSAGE_SQUARE, keys = {{.H, {.Ctrl}}}, run = new_session},
	{id = "nav.back", title = i18n.later("Back"), tags = "previous return history", group = i18n.later("Go to"), icon = lucide.ARROW_LEFT, keys = {{.Left, {.Alt}}}, enabled = can_go_back, run = proc(app: ^App) { if nav_can(app, -1) { nav_step(app, -1) } else { go_back(app) } }},
	{id = "nav.forward", title = i18n.later("Forward"), tags = "next history", group = i18n.later("Go to"), icon = lucide.ARROW_RIGHT, keys = {{.Right, {.Alt}}}, enabled = proc(app: ^App) -> bool { return nav_can(app, 1) }, run = proc(app: ^App) { nav_step(app, 1) }},
	{id = "nav.composer", title = i18n.later("Focus the composer"), tags = "input prompt type message write", group = i18n.later("Go to"), icon = lucide.PENCIL, keys = {{.L, {.Ctrl}}}, run = proc(app: ^App) { main_pane(app).composer.focus_next = true }},

	{id = "session.new", title = i18n.later("New session"), tags = "chat conversation create start", group = i18n.later("Session"), icon = lucide.PLUS, keys = {{.N, {.Ctrl}}}, run = new_session},
	{id = "session.background", title = i18n.later("Push the running command to the background"), tags = "detach background shell job", group = i18n.later("Session"), icon = lucide.SEND_TO_BACK, run = proc(app: ^App) { background_session(app, main_pane(app).chat.id) }, enabled = foreground_command},
	{id = "session.stop", title = i18n.later("Stop the run"), tags = "cancel abort interrupt halt kill", group = i18n.later("Session"), icon = lucide.SQUARE, keys = {{.Escape, {.Ctrl}}}, run = proc(app: ^App) { interrupt_session(app, main_pane(app).chat.id) }, enabled = is_busy},
	{id = "session.activity", title = i18n.later("What runs in the background"), tags = "jobs tasks processes activity running", group = i18n.later("Session"), icon = lucide.SQUARE_TERMINAL, keys = {{.J, {.Ctrl}}}, run = activity_toggle, enabled = has_session},
	{id = "session.quote", title = i18n.later("Quote what is selected"), tags = "reply cite selection", group = i18n.later("Session"), icon = lucide.PENCIL, keys = {{.Q, {.Ctrl}}}, run = quote_selection, enabled = proc(app: ^App) -> bool { return ui.has_selection(&app.state) }},
	{id = "session.find", title = i18n.later("Find in the conversation"), tags = "search look locate", group = i18n.later("Session"), icon = lucide.SEARCH, keys = {{.F, {.Ctrl}}}, run = proc(app: ^App) { find_open(app, main_pane(app)) }, enabled = can_find},
	{id = "session.stats", title = i18n.later("Show or hide the Statistics panel"), tags = "stats tokens cost usage numbers", group = i18n.later("Session"), icon = lucide.GAUGE, keys = {{.I, {.Ctrl}}}, run = stats_toggle, enabled = has_session, checked = proc(app: ^App) -> bool { return app.stats.open }},
	{id = "session.rename", title = i18n.later("Rename the session…"), tags = "title name", group = i18n.later("Session"), icon = lucide.PENCIL, keys = {{.F2, {}}}, run = proc(app: ^App) { rename_open(app, main_pane(app).chat.id) }, enabled = has_session,
		arguments = RENAME_ARGUMENTS[:], take = proc(app: ^App, values: []string) { if len(values) == 1 { rename_to(app, main_pane(app).chat.id, values[0]) } }},
	{id = "session.jump", title = i18n.later("Jump to message…"), tags = "prompt find go earlier history search", group = i18n.later("Session"), icon = lucide.MESSAGE_SQUARE_TEXT, keys = {{.G, {.Ctrl, .Alt}}}, run = jump_show, enabled = has_session},
	{id = "session.copy_id", title = i18n.later("Copy the session ID"), tags = "identifier ses clipboard", group = i18n.later("Session"), icon = lucide.HASH, run = proc(app: ^App) { session_id_copy(app, main_pane(app).chat.id) }, enabled = has_session},
	{id = "session.fork", title = i18n.later("Fork the session"), tags = "branch copy duplicate split", group = i18n.later("Session"), icon = lucide.COPY, run = proc(app: ^App) { fork_session(app, main_pane(app).chat.id, "") }, enabled = has_session},
	{id = "session.compact", title = i18n.later("Compact the conversation"), tags = "summarize shrink compress context", group = i18n.later("Session"), icon = lucide.LIST, run = proc(app: ^App) { request(app, .Action, "POST", fmt.tprintf("/api/session/%s/compact", main_pane(app).chat.id), "{}", main_pane(app).chat.id) }, enabled = has_session},
	{id = "session.tools_background", title = i18n.later("Send running tools to the background"), tags = "detach background jobs", group = i18n.later("Session"), icon = lucide.SQUARE_TERMINAL, run = proc(app: ^App) { request(app, .Action, "POST", fmt.tprintf("/api/session/%s/background", main_pane(app).chat.id), "", main_pane(app).chat.id) }, enabled = is_busy},
	{id = "app.connections", title = i18n.later("Connect an account"), tags = "login provider oauth sign auth", group = i18n.later("General"), icon = lucide.USER, run = proc(app: ^App) { settings_open_on(app, "connections") }},
	{id = "view.terminal", title = i18n.later("Terminal"), tags = "shell console bash pty", group = i18n.later("View"), icon = lucide.SQUARE_TERMINAL, keys = {{.T, {.Ctrl, .Shift}}}, run = terminal_toggle},
	{id = "view.terminal_new", title = i18n.later("New terminal"), tags = "shell console bash pty open", group = i18n.later("View"), icon = lucide.SQUARE_TERMINAL, run = terminal_new},
	{id = "session.schedules", title = i18n.later("Schedules of this session"), tags = "cron timer planned recurring", group = i18n.later("Session"), icon = lucide.HISTORY, run = proc(app: ^App) { schedules_open(app, main_pane(app).chat.id) }, enabled = proc(app: ^App) -> bool { return main_pane(app).chat.id != "" && !app.cx.no_schedules }},
	{id = "session.artifacts", title = i18n.later("Artifacts of this folder"), tags = "outputs files html pages", group = i18n.later("Session"), icon = lucide.FILE, run = artifacts_open, enabled = proc(app: ^App) -> bool { return !app.cx.no_artifacts }},
	{id = "session.files", title = i18n.later("Browse the files"), tags = "explorer tree folder open", group = i18n.later("Session"), icon = lucide.FOLDER, keys = {{.P, {.Ctrl}}}, run = proc(app: ^App) { files_open(app, main_pane(app)) }},
	{id = "session.changes", title = i18n.later("What this session changed"), tags = "diff changes edits modified", group = i18n.later("Session"), icon = lucide.FILE, run = proc(app: ^App) { changes_open(app, main_pane(app).chat.id) }, enabled = has_session},
	{id = "session.archive", title = i18n.later("Archive the session, or bring it back"), tags = "hide restore unarchive", group = i18n.later("Session"), icon = lucide.FILE_ARCHIVE, run = proc(app: ^App) { session_archive(app, main_pane(app).chat.id, !session_is_archived(app, main_pane(app).chat.id)) }, enabled = has_session},
	{id = "session.terminal", title = i18n.later("Open a terminal in the session's folder"), tags = "shell console bash cwd", group = i18n.later("Session"), icon = lucide.SQUARE_TERMINAL, run = proc(app: ^App) { terminal_open(chat_dir(app)) }, enabled = has_session},
	{id = "session.move", title = i18n.later("Move the session to a folder"), tags = "directory relocate path", group = i18n.later("Session"), icon = lucide.FOLDER, run = proc(app: ^App) { session_move_pick(app, main_pane(app).chat.id) }, enabled = has_session},
	{id = "session.export", title = i18n.later("Export the session"), tags = "save download markdown json share", group = i18n.later("Session"), icon = lucide.FILE, run = proc(app: ^App) { session_export(app, main_pane(app).chat.id) }, enabled = has_session},
	{id = "session.export_redacted", title = i18n.later("Export the session without its text"), tags = "redact anonymize share save", group = i18n.later("Session"), icon = lucide.FILE, run = proc(app: ^App) { session_export(app, main_pane(app).chat.id, redacted = true) }, enabled = has_session},
	{id = "composer.attach", title = i18n.later("Attach files"), tags = "upload image file add", group = i18n.later("Session"), icon = lucide.PAPERCLIP, run = proc(app: ^App) { attach_pick(app, main_pane(app)) }},
	{id = "session.import", title = i18n.later("Import a session"), tags = "load open json", group = i18n.later("Session"), icon = lucide.FILE, run = session_import_pick},

	{id = "view.preview", title = i18n.later("Show or hide the Preview panel"), tags = "browser web page", group = i18n.later("View"), icon = lucide.GLOBE, keys = {{.B, {.Ctrl, .Shift}}}, run = preview_toggle, checked = proc(app: ^App) -> bool { return app.preview.open }},
	// (Their own keys are the panel's, read while it has the keyboard: elsewhere Ctrl+W is a shell's, and a composer's to ignore.)
	{id = "view.preview_tab", title = i18n.later("New browser tab"), tags = "preview web page url", group = i18n.later("View"), icon = lucide.PLUS, keys = {{.T, {.Ctrl}}}, keys_elsewhere = true, run = preview_tab_new},
	{id = "view.preview_tab_close", title = i18n.later("Close browser tab"), tags = "preview web page", group = i18n.later("View"), icon = lucide.X, keys = {{.W, {.Ctrl}}}, keys_elsewhere = true, run = preview_tab_close_front, enabled = preview_tab_can_close},
	{id = "view.sidebar", title = i18n.later("Show or hide the sidebar"), tags = "sessions list toggle collapse", group = i18n.later("View"), icon = lucide.MENU, keys = {{.B, {.Ctrl}}}, run = sidebar_toggle, checked = proc(app: ^App) -> bool { return ui.view_is_open(&app.program_views, SIDEBAR_VIEW) }},
	{id = "view.prompt_rail", title = i18n.later("Show or hide the prompt marks"), tags = "minimap rail scrollbar overview ruler timeline prompts messages navigate jump outline", group = i18n.later("View"), icon = lucide.LIST, run = proc(app: ^App) { pref_set(app, "conversation.prompt_rail", app.prefs.prompt_rail ? "false" : "true") }, checked = proc(app: ^App) -> bool { return app.prefs.prompt_rail }},
	{id = "view.notices", title = i18n.later("What you missed"), tags = "notifications inbox missed events log bell unread", group = i18n.later("View"), icon = lucide.BELL, keys = {{.N, {.Ctrl, .Shift}}}, run = missed_toggle, over = proc(app: ^App) -> bool { return ui.view_is_open(&app.program_views, MISSED_VIEW) }},
	{id = "notices.next", title = i18n.later("Next missed"), tags = "notifications queue next unread inbox", group = i18n.later("Go to"), icon = lucide.ARROW_RIGHT, run = missed_next},
	{id = "view.sidebar_mode", title = i18n.later("Switch the sidebar's mode (inbox, projects)"), tags = "inbox projects folders group", group = i18n.later("View"), icon = lucide.LIST, run = sidebar_mode_next},
	{id = "view.content_in", title = i18n.later("Zoom in the conversation"), tags = "bigger larger font size text", group = i18n.later("View"), icon = lucide.PLUS, keys = ui.ZOOM_IN_KEYS[:], keys_elsewhere = true, run = proc(app: ^App) { ui.zoom_zone_by(&main_pane(app).zone, ui.feel(&app.state).zoom_step) }},
	{id = "view.content_out", title = i18n.later("Zoom out the conversation"), tags = "smaller font size text", group = i18n.later("View"), icon = lucide.CHEVRON_DOWN, keys = ui.ZOOM_OUT_KEYS[:], keys_elsewhere = true, run = proc(app: ^App) { ui.zoom_zone_by(&main_pane(app).zone, 1 / ui.feel(&app.state).zoom_step) }},
	{id = "view.content_reset", title = i18n.later("Reset the conversation's zoom"), tags = "default font size text", group = i18n.later("View"), icon = lucide.UNDO_2, keys = ui.ZOOM_RESET_KEYS[:], keys_elsewhere = true, run = proc(app: ^App) { ui.zoom_zone_reset(&main_pane(app).zone) }},
	// (the conversation's zoom keys are its zone's, read where the keyboard is in it; outside it the same keys zoom the
	// interface: these have no key of their own)
	{id = "view.chrome_in", title = i18n.later("Zoom in the interface"), tags = "bigger larger scale ui", group = i18n.later("View"), icon = lucide.PLUS, run = proc(app: ^App) { ui.set_zoom(&app.state, ui.zoom(&app.state) * ui.feel(&app.state).zoom_step) }},
	{id = "view.chrome_out", title = i18n.later("Zoom out the interface"), tags = "smaller scale ui", group = i18n.later("View"), icon = lucide.CHEVRON_DOWN, run = proc(app: ^App) { ui.set_zoom(&app.state, ui.zoom(&app.state) / ui.feel(&app.state).zoom_step) }},
	{id = "view.chrome_reset", title = i18n.later("Reset the interface's zoom"), tags = "default scale ui", group = i18n.later("View"), icon = lucide.UNDO_2, run = proc(app: ^App) { ui.set_zoom(&app.state, 1) }},
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

// Whether its key does something now: what is open over the window has the keyboard, unless the command is meant to work
// there. A window command's works over a view shown as a dialog (the settings, the sheet, the palette and the
// composer's chooser); a menu and the file dialog keep the keys while they are open (their Escape and their letters are
// their own).
command_keyed :: proc(app: ^App, c: ^Command) -> bool {
	if !command_enabled(app, c) { return false }
	if c.scope == .Window { return len(app.state.menus) == 0 && !ui.file_dialog_shown(&app.state) }
	return !overlay_open(app) || (c.over != nil && c.over(app))
}

// The keys of the table, at the start of a build (the palette's are the toolkit's: palette_build), through the keymap: a
// person's key replaces a command's own (ui.command_pressed). A shell with the keyboard took its keys out before
// (term_events): Ctrl+K and the rest are the shell's there, Ctrl+Shift+T alone comes through. The toolkit's table is the
// palette's (palette_table_keep), one for one with COMMANDS.
commands_keys :: proc(app: ^App) {
	table := app.palette.table
	for &c, i in COMMANDS {
		// (own keys read elsewhere: only a person's key is read here; a disabled command still holds its person's chord)
		disabled := !command_keyed(app, &c) || (c.keys_elsewhere && c.id not_in app.keymap.bindings)
		if ui.command_pressed(table[i], disabled) { command_run(app, &c) }
	}
}

// The text of a command's first key in effect, for a menu's line ("" none): the person's, else its own.
command_shortcut :: proc(app: ^App, id: string) -> string {
	for c, i in COMMANDS { if c.id == id { return ui.command_shortcut(app.palette.table[i]) } }
	return ""
}

// The toolkit's sheet of the keys: the commands' table (the palette's: made first if no palette was shown yet), and the
// keys that widgets read themselves, which no command holds.
help_open :: proc(app: ^App) {
	p := &app.palette
	if !p.made { palette_table_keep(app) }
	help_lines(p)
	ui.shortcuts_sheet_open(&p.sheet, p.table, version = p.version, extra = p.sheet_lines[:])
}

// The sheet's lines that no command holds. Keys in English, as a command's: the sheet names them in the language in
// use; "Middle click" names no key, so it is this program's word to translate (again at each language).
help_lines :: proc(p: ^Palette) {
	p.sheet_lines = {
		{group = i18n.later("Composer"), keys = "Up / Down", label = i18n.later("Go through what you sent in this session")},
		{group = i18n.later("Composer"), keys = "Down", label = i18n.later("On the last line: what runs in the background")},
		{group = i18n.later("Composer"), keys = "Ctrl+V", label = i18n.later("Paste text, an image or files")},
		{group = i18n.later("Composer"), keys = i18n.tr("Middle click"), label = i18n.later("Scroll by the pointer")},
		{group = i18n.later("Composer"), keys = "Esc, Esc", label = i18n.later("Stop the run, what was sent during it goes next")},
	}
}

help_toggle :: proc(app: ^App) {
	if ui.shortcuts_sheet_is_open(&app.palette.sheet) { ui.shortcuts_sheet_close(&app.palette.sheet) } else { help_open(app) }
}
