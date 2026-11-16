package ocn

// The views (gui_toolkit's views, its docs/views.md): every dialog, the sessions' sidebar and the panels beside the
// conversation (the Preview, the Statistics, /btw's aside, each shell). Each is a build procedure on the program's data, declared once
// (views_start). The toolkit builds it where the user puts it: a dialog, a floating window inside the window, a window
// of its own, or a panel docked at an edge of the conversation. It keeps that choice, the sizes, the panels' places and
// which were open at the last quit in views.txt beside the preferences. The conversation is the window's content, not a
// view.
//
// The program's state says whether a panel is open (Preview.open, Stats_View.open, Terminals.open, a command's output):
// what opens or closes it opens or closes its view at once, and the user's close of a view comes back as its answer
// (views_answers), which closes it in the program's state too.

import "gt:host"
import "gt:ui"
import lucide "gt:lucide"
import i18n "gt:i18n"

SIDEBAR_VIEW   :: "sidebar"
PREVIEW_VIEW   :: "preview"
STATS_VIEW     :: "stats"
TERMINAL_VIEW  :: "terminal"   // an instance per shell (its server's id); "": what stands there while there is no shell
OUTPUT_VIEW    :: "output"     // an instance per command (Output_View.name)
SETTINGS_VIEW  :: "settings"
CHANGES_VIEW   :: "changes"
SCHEDULES_VIEW :: "schedules"
ARTIFACTS_VIEW :: "artifacts"
DIFF_VIEW      :: "diff"
IMAGE_VIEW     :: "image"
SERVER_VIEW    :: "server"
PAIR_VIEW      :: "pair"
MISSED_VIEW    :: "missed"
DIAGRAM_VIEW   :: "diagram"
// The toolkit's ready-made views that the program opens: the question before a session is deleted, its new title.
DELETE_VIEW    :: "delete"
RENAME_VIEW    :: "rename"

// The panels' first sizes (ems): the zone takes the first one's, then the user's.
SIDEBAR_EM      :: 20
SIDEBAR_MIN_EM  :: 14
PREVIEW_EM      :: 32
TERMINAL_EM     :: 16
PANEL_MIN_EM    :: 18

// Where the views' memory is: beside the preferences; none (in memory only) for a test, whose App reads no file.
views_path :: proc(prefs_file: string) -> string {
	if prefs_file == "" { return "" }
	return pjoin({config_dir(), "views.txt"})
}

// Once the main window's State is made, before anything opens a view: the memory read, every view declared, the
// sidebar open again as it was (open at the very first start).
views_start :: proc(app: ^App, path: string) {
	vs := &app.program_views
	ui.views_init(vs, {path = path})
	ui.set_views(&app.state, vs)
	// (one backend for every window: a view's window is a Host on the program's renderer, made after the main window's frames)
	ui.views_set_windows(vs, host.view_windows(&app.gfx))
	// (a menu or a chip opened in a view's window is that window's State's: built at the end of each such window's build,
	// as the main window's build ends with it; chat-panes.md)
	ui.views_set_window_end(vs, proc(user: rawptr, _: ^ui.View) { window_overlays((^App)(user), ui.font_size()) }, app)
	ui.view_register(vs, SIDEBAR_VIEW, sidebar_pane, ui.View_Options{title = i18n.later("Sessions"), icon = lucide.MENU,
		home = .Panel, home_place = {edge = .Left}, extent_em = SIDEBAR_EM, width_em = SIDEBAR_EM, min_width_em = SIDEBAR_MIN_EM,
		// (its zone minimised keeps this column, and builds it as the rail: sidebar_pane)
		rail_em = SIDEBAR_RAIL_EM})
	panels_register(app)
	dialogs_register(app)
	_ = ui.view_restore(vs, SIDEBAR_VIEW, app, first_start_open = true, owner = &app.state)
}

// The panels beside the conversation: the Preview and the Statistics share a stack at its right (a tab each), the shells
// are tabs along its bottom.
@(private = "file")
panels_register :: proc(app: ^App) {
	vs := &app.program_views
	ui.view_register(vs, PREVIEW_VIEW, preview_view, ui.View_Options{title = i18n.later("Preview"), icon = lucide.GLOBE,
		home = .Panel, home_place = {edge = .Right}, extent_em = PREVIEW_EM, width_em = PREVIEW_EM, min_width_em = PANEL_MIN_EM,
		// (its page is a child window of the system's: its window of its own has one, and the page follows the view)
		under_children = true, moved = preview_moved})
	ui.view_register(vs, STATS_VIEW, stats_view, ui.View_Options{title = i18n.later("Statistics"), icon = lucide.GAUGE,
		home = .Panel, home_place = {edge = .Right}, extent_em = PREVIEW_EM, width_em = PREVIEW_EM, min_width_em = PANEL_MIN_EM})
	// (/btw's fork: its tab, shown with the panel alone, says its title; its strip has "Open in the main view": btw.odin)
	ui.view_register(vs, BTW_VIEW, btw_view, ui.View_Options{title = i18n.later("Aside"), icon = lucide.MESSAGE_CIRCLE,
		home = .Panel, home_place = {edge = .Right}, extent_em = PREVIEW_EM, width_em = PREVIEW_EM, height_em = 40, min_width_em = PANEL_MIN_EM,
		tabs_always = true})
	// (the shells' strip shows with one shell too: its tab says which, its "+" makes another, as a terminal's does. Its
	// label is translated once here: the language is read before (prefs_init))
	ui.view_register(vs, TERMINAL_VIEW, terminal_view, ui.View_Options{title = i18n.later("Terminal"), icon = lucide.SQUARE_TERMINAL,
		home = .Panel, home_place = {edge = .Bottom}, extent_em = TERMINAL_EM, width_em = 60, height_em = 30, min_width_em = PANEL_MIN_EM,
		tabs_always = true, new_tab = proc(data: rawptr) { term_create((^App)(data)) }, new_tab_label = i18n.tr("New terminal")})
}

// The dialogs, each with the size it opens at and the least the user can make it (the views' memory keeps theirs).
@(private = "file")
dialogs_register :: proc(app: ^App) {
	vs := &app.program_views
	sized :: proc(vs: ^ui.Views, id: string, build: $B, title, icon: string, size, least: [2]f32) {
		ui.view_register(vs, id, build, ui.View_Options{title = title, icon = icon, width_em = size.x, height_em = size.y,
			min_width_em = least.x, min_height_em = least.y, resizable = true, backdrop = view_backdrop})
	}
	sized(vs, SETTINGS_VIEW, settings_view, i18n.later("Settings"), lucide.SLIDERS_HORIZONTAL, {62, 44}, {40, 24})
	sized(vs, CHANGES_VIEW, changes_view, i18n.later("What this session changed"), lucide.FILE, {62, 46}, {34, 20})
	sized(vs, ARTIFACTS_VIEW, artifacts_view, i18n.later("Artifacts of this folder"), lucide.FILE, {70, 46}, {44, 22})
	sized(vs, DIFF_VIEW, diff_full_view, i18n.later("Diff"), lucide.FILE, {130, 80}, {50, 24})
	sized(vs, OUTPUT_VIEW, output_view_view, i18n.later("Output"), lucide.SQUARE_TERMINAL, {96, 56}, {44, 20})
	sized(vs, MISSED_VIEW, missed_view, i18n.later("What you missed"), lucide.BELL, {60, 42}, {36, 18})
	sized(vs, DIAGRAM_VIEW, diagram_view, i18n.later("Mermaid diagram"), lucide.GIT_FORK, {80, 52}, {26, 14})
	// (as a dialog it opens around its picture: ui.view_size; the size its grips give it is kept, and sets the share of the window
	// the next pictures take)
	ui.view_register(vs, IMAGE_VIEW, image_view, ui.View_Options{title = i18n.later("Image"), icon = lucide.IMAGE, width_em = 72, height_em = 50,
		min_width_em = VIEWER_MIN_W_EM, resizable = true, backdrop = view_backdrop})
	ui.view_register(vs, SCHEDULES_VIEW, schedules_view, ui.View_Options{title = i18n.later("Schedules of this session"), icon = lucide.HISTORY,
		width_em = SCHEDULES_W_EM, top = SCHEDULES_TOP, backdrop = view_backdrop})
	ui.view_register(vs, SERVER_VIEW, server_view, ui.View_Options{title = i18n.later("Add a server"), icon = lucide.GLOBE,
		width_em = 32, top = SERVER_DIALOG_TOP, backdrop = view_backdrop})
	ui.view_register(vs, PAIR_VIEW, pair_view, ui.View_Options{title = i18n.later("Pair a device"), icon = lucide.SMARTPHONE,
		width_em = 40, backdrop = view_backdrop})
}

// The window behind a dialog shows through its scrim, blurred and darkened. Only behind a dialog: a floating window,
// a window of its own and a panel have no scrim.
view_backdrop :: proc(v: ^ui.View, _: rawptr) {
	if v.presentation == .Dialog { dialog_backdrop() }
}

// What the user's close of a view does to the program's state, read once per build of the main window. (A view the
// program closes gives no answer: it knows why it closed it.)
views_answers :: proc(app: ^App) {
	vs := &app.program_views
	if _, ok := ui.view_ended(vs, PREVIEW_VIEW); ok { preview_close(app) }
	if _, ok := ui.view_ended(vs, STATS_VIEW); ok { app.stats.open = false }
	if _, ok := ui.view_ended(vs, BTW_VIEW); ok { btw_close(app) }
	if _, ok := ui.view_ended(vs, TERMINAL_VIEW); ok { terminals_hide(app) }
	s := &app.cx.terms
	for i := len(s.list) - 1; i >= 0; i -= 1 {
		t := s.list[i]
		if _, ok := ui.view_ended(vs, TERMINAL_VIEW, t.id); ok { term_close(app, t) }
	}
	for v in app.cx.outputs.list {
		if _, ok := ui.view_ended(vs, OUTPUT_VIEW, v.name); ok { output_view_close(app, v) }
	}
	if _, ok := ui.view_ended(vs, CHANGES_VIEW); ok { changes_close(app) }
	changes_follow(app)
	if _, ok := ui.view_ended(vs, DIFF_VIEW); ok { diff_full_close(&app.cx.diff_full) }
	if _, ok := ui.view_ended(vs, PAIR_VIEW); ok { pair_closed(app) }
	delete_answer(app)
	rename_answer(app)
}

// Whether something holds the window's keys: a dialog (the palettes are views), a menu of the window being built (a view's
// window of its own has its own menus: one open in the main window does not stop a right click there), the file dialog. What
// reads the keyboard behind them asks here.
overlay_open :: proc(app: ^App) -> bool {
	return ui.views_hold_keys(&app.program_views) || len(built_state(app).menus) > 0 || ui.file_dialog_shown(&app.state)
}

// The State `pane` is built in: the panel's window of its own when it has one, else the main window's.
pane_window :: proc(app: ^App, pane: ^Chat_Pane) -> ^ui.State {
	if pane != main_pane(app) && pane == btw_pane(app) { return view_state(app, BTW_VIEW) }
	return &app.state
}

// The keyboard is in a view that floats, is docked beside the conversation or is in a window of its own, the sidebar apart
// (its keys are the window's: typing there searches the sessions). What the conversation does with a key it does not take
// (Escape stops a run) waits then.
focus_in_view :: proc(app: ^App) -> bool {
	id, _, ok := ui.views_focus(&app.program_views)
	return ok && id != SIDEBAR_VIEW
}

// Whether a panel can be seen: one at an edge can be a tab under another; elsewhere it is in front.
// (`built`: its build ran in the last frame.)
view_seen :: proc(app: ^App, id: string, built: bool, instance := "") -> bool {
	if !ui.view_is_open(&app.program_views, id, instance) { return false }
	return ui.view_presentation(&app.program_views, id, instance) != .Panel || built
}

// The State a view is built in: its window's, else the main one's.
view_state :: proc(app: ^App, id: string, instance := "") -> ^ui.State {
	if st := ui.view_window_state(&app.program_views, id, instance); st != nil { return st }
	return &app.state
}

// The State being built, else the main one (what a pulse wakes, what a rounding reads).
built_state :: proc(app: ^App) -> ^ui.State {
	if s := ui.current_state(); s != nil { return s }
	return &app.state
}

// The sidebar: the sessions, the search, the servers. Docked at the window's left, the bars' line goes on from its
// zone's handle (chrome.odin side_line). Its zone minimised (its Minimise, or a window too narrow): the rail.
@(private = "file")
sidebar_pane :: proc(v: ^ui.View, app: ^App) {
	if v.rail { sidebar_rail(app, ui.font_size()) } else { sidebar(app, ui.font_size()) }
}

// Ctrl+B: the sidebar shows or goes, wherever the user put it.
sidebar_toggle :: proc(app: ^App) {
	if ui.view_is_open(&app.program_views, SIDEBAR_VIEW) { ui.view_close(&app.program_views, SIDEBAR_VIEW) } else { ui.view_open(&app.program_views, SIDEBAR_VIEW, app) }
}
