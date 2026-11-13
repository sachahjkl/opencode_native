// The window: an integrated title bar, the sessions on the left (grouped by project folder), the conversation and its
// composer on the right, a status bar along the bottom. Each part is in its own file: chrome.odin (the bars), sidebar_rows.odin,
// conversation.odin, composer.odin.
package ocn

import "core:math"
import "core:strings"
import "gt:draw"
import crash_bar "gt:crash_bar"
import prefs_page "gt:prefs_page"
import "gt:ui"
import lucide "gt:lucide"
import remote "gt:remote"
import i18n "gt:i18n"


TOAST_TOP_EM          :: 5.5
CONVERSATION_MIN_PX   :: 420   // what the sidebar's splitter leaves it

build_ui :: proc(app: ^App) {
	em := ui.font_size()
	global_keys(app)
	ui.next({width = ui.fill(), height = ui.fill(), axis = .Y})
	if ui.column(id = "###root") {
		title_bar(app, em)
		crash_bar.bar(&app.crash_bar, {name = APP_NAME, version = APP_VERSION, repository = "sachahjkl/opencode_native"})
		ui.next({width = ui.fill(), height = ui.fill()})
		if ui.row(id = "###body") {
			if !app.sidebar.hidden {
				sidebar(app, em)
				room := ui.parent_box().size.x / ui.scale()
				ui.next({height = ui.fill()})
				ui.a11y({name = i18n.tr("Sidebar width")})
				groove_y: f32
				if ui.parent(ui.prev_box("###sidebar")) { if g := ui.prev_box("###sg"); g != nil { groove_y = (g.rect.min.y + g.rect.max.y) * 0.5 } }
				split := ui.splitter("###side_split", .X, &app.sidebar.width, SIDEBAR_W_MIN, SIDEBAR_W_MAX, {default_size = SIDEBAR_W_DEFAULT, total = room, min_other = CONVERSATION_MIN_PX})
				side_handle(split, groove_y, app.state.focus_visible)
			}
			main_area(app, em)
		}
		status_bar(app, em)
	}
	delete_dialog(app, em)
	setup_frame(app, em)
	server_dialog(app, em)
	settings_dialog(app, em)
	image_viewer(app, em)
	diagram_viewer(app, em)
	rename_dialog(app, em)
	help_dialog(app, em)
	pair_dialog(app, em)
	integrations_watch(app)
	schedules_dialog(app, em)
	artifacts_dialog(app, em)
	changes_dialog(app, em)
	diff_full_dialog(app, em)
	output_view_dialog(app, em)
	files_dialog(app, em)
	palette_dialog(app, em)
	missed_dialog(app, em)
	context_menu(app, em)
	// (only this way: a dialog opened by what was built after it, a menu, is open and not built until the next build)
	when ODIN_DEBUG { assert(len(app.state.modals_built) == 0 || overlay_open(app), "a dialog built that is not in App_Context.open: the program's keys would act behind it") }
	// (under the header: a message at the top does not cover it)
	ui.set_toast_area({{0, em * TOAST_TOP_EM}, app.state.window_size})
	// (last: what is open and a field that has it took Escape before it gets here)
	if app.chat.busy && !overlay_open(app) && !mention_takes_escape(app) && ui.key_press(.Escape) { interrupt_session(app, app.chat.id) }
}

app_menu :: proc(app: ^App, key: string, em: f32) {
	if ui.menu(key) {   // (as wide as its longest item)
		if ui.menu_item(i18n.tr("Command palette…"), "Ctrl+K", icon = lucide.COMMAND).clicked { palette_toggle(app) }
		ui.menu_separator()
		if ui.menu_item(i18n.tr("Home"), "Ctrl+H", icon = lucide.HOME).clicked { command_run(app, command_find("nav.home")) }
		if ui.menu_item(i18n.tr("New session"), "Ctrl+N", icon = lucide.PLUS).clicked { command_run(app, command_find("session.new")) }
		if ui.menu_item(i18n.tr("Refresh"), "F5", icon = lucide.REFRESH_CW).clicked {
			refresh_sessions(app)
			if app.chat.id != "" { load_messages(app, app.chat.id) }
		}
		if ui.menu_item(i18n.tr("Settings…"), "Ctrl+,", icon = lucide.SLIDERS_HORIZONTAL).clicked { settings_open(app) }
		if ui.menu_item(i18n.tr("Add a server…"), icon = lucide.PLUG).clicked { server_edit_open(app, -1) }
		if ui.menu_item(i18n.tr("Statistics panel"), "Ctrl+I", app.stats.open, icon = lucide.GAUGE, disabled = app.chat.id == "").clicked { stats_toggle(app) }
		if preview_available() {
			if ui.menu_item(i18n.tr("Preview panel"), "Ctrl+Shift+B", app.preview.open, icon = lucide.GLOBE).clicked { command_run(app, command_find("view.preview")) }
		}
		if ui.menu_item(i18n.tr("What you missed"), "Ctrl+Shift+N", icon = lucide.BELL).clicked { command_run(app, command_find("view.notices")) }
		if ui.menu_item(i18n.tr("Keyboard shortcuts"), "F1", icon = lucide.KEYBOARD).clicked { app.cx.open[.Help] = true }
		if ui.menu_item(i18n.tr("Sub-agent sessions in the list"), "", app.prefs.subagents == "flat", icon = lucide.BOT).clicked { pref_set(app, "sidebar.subagents", app.prefs.subagents == "flat" ? "nested" : "flat") }
		ui.menu_separator()
		// (the settings' Installation page says the version, where the install is, and acts on it)
		if ui.menu_item(i18n.tr("About opencode native"), icon = lucide.INFO).clicked { settings_open_on(app, prefs_page.INSTALL_PAGE) }
		ui.menu_separator()
		if ui.menu_item(i18n.tr("Quit"), "Alt+F4", icon = lucide.LOG_OUT).clicked { app.quit = true }
	}
}

global_keys :: proc(app: ^App) {
	find_keys(app)
	commands_keys(app)
}

new_session :: proc(app: ^App) {
	nav_visit(app, app.chat.id, "")
	for s in app.nav.drilled { delete(s) }   // (the way back up is the session's: none from here)
	clear(&app.nav.drilled)
	dir := ""
	if s := find_session(app, app.chat.id); s != nil { dir = s.directory } else if len(app.sessions) > 0 { dir = app.sessions[0].directory }
	chat_home(app)
	remote.reset(&app.cx.chat_read)
	chat_view_start(app, 0)   // (a way back under way ends: its place is in the conversation left)
	app.chat.new_dir = strings.clone(dir, app.chat.alloc)
	chat_shown_changed(app)
	app.composer.focus_next = true
}

@(private = "file")
Side_Handle_Draw :: struct { hot: bool, groove_y: f32 }

// The sidebar's edge and the handle that resizes it are one thing: the handle goes on with the sidebar's surface, and the one
// line between the sidebar and the conversation is at its right. The sidebar's own groove comes all the way to that line.
@(private = "file")
side_handle :: proc(split: ui.Splitter_Result, groove_y: f32, focus_visible: bool) {
	d := ui.frame_new(Side_Handle_Draw)
	d^ = {split.hovering || split.dragging || split.focused && focus_visible, groove_y}   // (focused by the keys only: a drag leaves the focus on it, not the colour)
	split.box.custom_user = d
	split.box.custom = proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
		d := (^Side_Handle_Draw)(user)
		r := b.rect
		draw.rect(dc, r, hex(HEX_BG1))
		line := 2 * px1()
		if d.groove_y > 0 {
			y := math.round(d.groove_y) - px1()
			draw_groove(dc, {r.min.x, y}, {r.max.x - line, y})
		}
		if d.hot {
			draw.rect(dc, {{r.max.x - line, r.min.y}, r.max}, accent())
		} else {
			draw_groove(dc, {r.max.x - line, r.min.y}, {r.max.x - line, r.max.y}, true)
		}
	}
}
