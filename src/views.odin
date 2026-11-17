// The window: an integrated title bar, the conversation and its composer, a status bar along the bottom. The views go
// around the conversation (window_views.odin): the sessions' sidebar at the left, the Preview and the Statistics at the
// right, the shells along the bottom, wherever the user moved them; the dialogs over it all. Each part is in its own file:
// chrome.odin (the bars), sidebar_rows.odin, conversation.odin, composer.odin.
package ocn

import crash_bar "gt:crash_bar"
import prefs_page "gt:prefs_page"
import "gt:ui"
import lucide "gt:lucide"
import remote "gt:remote"
import i18n "gt:i18n"
import "core:strings"


TOAST_TOP_EM          :: 5.5

build_ui :: proc(app: ^App) {
	pane := main_pane(app)
	fonts_follow(app)   // (a family the toolkit loaded since the last build: this build draws in it)
	em := ui.font_size()
	views_answers(app)
	palette_build(app)   // (its keys read with the window's, before the views read theirs)
	app.stats.built = false
	terminals_begin(app)
	ui.next({width = ui.fill(), height = ui.fill(), axis = .Y})
	if ui.column(id = "###root") {
		title_bar(app, em)
		crash_bar.bar(&app.crash_bar, {name = APP_TITLE, version = APP_VERSION, repository = "sachahjkl/opencode_native"})
		ui.next({width = ui.fill(), height = ui.fill()})
		// (the views docked and floating are built first: one that has the keyboard reads its keys first)
		if ui.views_frame(&app.program_views) {
			global_keys(app)
			main_area(app, em)
		}
		status_bar(app, em)
	}
	rename_follow(app)
	setup_frame(app, em)
	integrations_watch(app)
	image_view_wait(app)
	window_overlays(app, em)
	// (under the header: a message at the top does not cover it)
	ui.set_toast_area({{0, em * TOAST_TOP_EM}, app.state.window_size})
	// (last: what is open and a field that has it took Escape before it gets here)
	if pane.chat.busy && !overlay_open(app) && !focus_in_view(app) && !mention_takes_escape(app, pane) && ui.key_press(.Escape) { escape_stop(app, pane) }
}

app_menu :: proc(app: ^App, key: string, em: f32) {
	pane := main_pane(app)
	if ui.menu(key) {   // (as wide as its longest item)
		pc := ui.palette_command()
		if ui.menu_item(i18n.tr("Command palette…"), ui.command_shortcut(pc), icon = pc.icon).clicked { palette_show(app) }
		ui.menu_separator()
		if ui.menu_item(i18n.tr("Home"), command_shortcut(app, "nav.home"), icon = lucide.HOME).clicked { command_run(app, command_find("nav.home")) }
		if ui.menu_item(i18n.tr("New session"), command_shortcut(app, "session.new"), icon = lucide.PLUS).clicked { command_run(app, command_find("session.new")) }
		if ui.menu_item(i18n.tr("Refresh"), command_shortcut(app, "app.refresh"), icon = lucide.REFRESH_CW).clicked {
			refresh_sessions(app)
			if pane.chat.id != "" { load_messages(app, pane, pane.chat.id) }
		}
		if ui.menu_item(i18n.tr("Settings…"), command_shortcut(app, "app.settings"), icon = lucide.SLIDERS_HORIZONTAL).clicked { settings_open(app) }
		if ui.menu_item(i18n.tr("Add a server…"), icon = lucide.PLUG).clicked { server_edit_open(app, -1) }
		if ui.menu_item(i18n.tr("Statistics panel"), command_shortcut(app, "session.stats"), app.stats.open, icon = lucide.GAUGE, disabled = pane.chat.id == "").clicked { stats_toggle(app) }
		if preview_available() {
			if ui.menu_item(i18n.tr("Preview panel"), command_shortcut(app, "view.preview"), app.preview.open, icon = lucide.GLOBE).clicked { command_run(app, command_find("view.preview")) }
		}
		if ui.menu_item(i18n.tr("What you missed"), command_shortcut(app, "view.notices"), icon = lucide.BELL).clicked { command_run(app, command_find("view.notices")) }
		if ui.menu_item(i18n.tr("Keyboard shortcuts"), command_shortcut(app, "app.help"), icon = lucide.KEYBOARD).clicked { help_open(app) }
		if ui.menu_item(i18n.tr("Sub-agent sessions in the list"), "", app.prefs.subagents == "flat", icon = lucide.BOT).clicked { pref_set(app, "sidebar.subagents", app.prefs.subagents == "flat" ? "nested" : "flat") }
		ui.menu_separator()
		// (the settings' Installation page says the version, where the install is, and acts on it)
		if ui.menu_item(i18n.tr("About Opencode Native"), icon = lucide.INFO).clicked { settings_open_on(app, prefs_page.INSTALL_PAGE) }
		ui.menu_separator()
		if ui.menu_item(i18n.tr("Quit"), command_shortcut(app, "app.quit"), icon = lucide.LOG_OUT).clicked { app.quit = true }
	}
}

global_keys :: proc(app: ^App) {
	commands_keys(app)
}

new_session :: proc(app: ^App) {
	pane := main_pane(app)
	nav_visit(app, pane.chat.id, "")
	for s in app.nav.drilled { delete(s) }   // (the way back up is the session's: none from here)
	clear(&app.nav.drilled)
	dir := ""
	if s := find_session(app, pane.chat.id); s != nil { dir = s.directory } else if len(app.sessions) > 0 { dir = app.sessions[0].directory }
	chat_home(app)
	remote.reset(&pane.read)
	chat_view_start(pane, 0)   // (a way back under way ends: its place is in the conversation left)
	pane.chat.new_dir = strings.clone(dir, pane.chat.alloc)
	chat_shown_changed(app)
	pane.composer.focus_next = true
}

// The conversation: the window's content, what the views go around. Its width is the window's less what is beside it,
// as the last layout had it (the box's own size is the last frame's: a window being resized would lag a frame behind).
main_area :: proc(app: ^App, em: f32) {
	pane := main_pane(app)
	c := &pane.conversation
	b := ui.parent_box()
	if w := b.rect.max.x - b.rect.min.x; w > 0 && c.layout_win_w > 0 { c.beside_px = max(c.layout_win_w - w, 0) }
	c.layout_win_w = f32(app.win.size.x)
	conversation(app, pane, em, f32(app.win.size.x) - c.beside_px)
}
