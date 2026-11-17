// Updates: gui_toolkit's Updater (gt:update, its docs/update.md) on this program's channels, run by the toolkit's
// prefs_page.updates_* as in every program of the toolkit. A release publishes a signed manifest per platform and channel
// (docs/updates.md); the Updater checks it on its own thread, downloads the program it names and puts it in place of the
// running one, with this program's product (src/update). The settings' Updates page is the toolkit's: update.auto (the
// installed copy only), update.channel (a choice of UPDATE_CHANNELS) and update.base_url, the state under them and their
// buttons; the installed copy's manifest takes the new version on a chore. A Nix package is never updated here: Nix
// updates it. What stays here: the words said once, and Restart.
package ocn

import "core:log"
import "core:math"
import host "gt:host"
import i18n "gt:i18n"
import prefs_page "gt:prefs_page"
import setup "gt:setup"
import "gt:ui"
import update "gt:update"
import ocn_update "update"

// The channels of the releases, and the folder of each one's files (ocntools release publish: the latest release, and the
// rolling pre-release channel-beta, which every release and every beta goes to).
UPDATE_CHANNELS := [?]update.Channel{
	{"stable", "https://github.com/sachahjkl/opencode_native/releases/latest/download/"},
	{"beta", "https://github.com/sachahjkl/opencode_native/releases/download/channel-beta/"},
}

// Their names and words, for the standard Updates set (settings.odin prefs_register).
UPDATE_CHANNEL_NAMES  := [?]string{"stable", "beta"}
UPDATE_CHANNEL_LABELS := [?]string{i18n.later("Stable"), i18n.later("Beta")}

// At the start, once the preferences are read. A run without a preferences' file (a test) starts none.
updates_start :: proc(app: ^App) {
	if app.updates.updater != nil || app.prefs_file == "" { return }
	prefs_page.updates_start(&app.updates, {
		product = ocn_update.PRODUCT, repository = "sachahjkl/opencode_native", version = APP_VERSION,
		channels = UPDATE_CHANNELS[:], prefs = &app.cfg_prefs, install = &app.install, state = &app.state, window = app.win,
	})
}

// At the end, before the interface's state goes: no news after it.
updates_stop :: proc(app: ^App) { prefs_page.updates_stop(&app.updates) }

// Each frame (main_window_adopt's before_input): the window woke for the updater's news, or the preferences or the
// install changed what update.auto asks. What changed is said once. The status bar's pill shows the phase and its button
// (a version on offer, its download, a restart): a toast says only what the pill cannot (update.notice).
updates_follow :: proc(app: ^App) {
	changed, st := prefs_page.updates_follow(&app.updates)
	if !changed { return }
	host.host_settle(&app.window)   // (the status bar and the settings show the state)
	if words, bad := update.notice(st); words != "" { ui.announce(&app.announcer, bad ? .Bad : .Good, words) }
}

// "Check for updates" (the palette): its answer is said whatever it is.
update_check_now :: proc(app: ^App) {
	if app.updates.updater != nil { update.check_now(app.updates.updater) }
}

update_install_now :: proc(app: ^App) {
	if app.updates.updater != nil { update.install_now(app.updates.updater) }
}

update_phase :: proc(app: ^App) -> update.Phase {
	if app.updates.updater == nil { return .Idle }
	return update.status(app.updates.updater).phase
}

// The program starts again: this one ends, then another of it starts from the same file (the same one, or the one an update
// put there). The new one starts at main's very end, once the single instance is let go: started before, it would hand its
// start to this window, which then ends (src/md/features/single-instance.md).
app_restart :: proc(app: ^App) {
	// (app.exe, not the system's name of the running file: after an update that is <exe>.old, and a name read in the
	// frame's temp memory would be gone by main's end)
	app.launch_after = app.exe
	app.quit = true
}

// main's very end: the copy Restart asked for. (The window is gone: a failure is the log's.)
app_launch_after :: proc(app: ^App) {
	if app.launch_after == "" { return }
	// (setup.launch: on Windows the new copy may take the foreground, so it comes back in front, not behind)
	if !setup.launch(app.launch_after) { log.errorf("restart: %s could not be started", app.launch_after) }
}

// The status bar's part: what the Updater has to say now, as a button (the toolkit's, as in every program).
update_pill :: proc(app: ^App, em: f32) {
	// (the height is for the badge alone: when it has nothing to say, nothing is built, and no other box may take it)
	#partial switch update_phase(app) {
	case .Available, .Downloading, .Installed:
	case: return
	}
	ui.next({height = ui.px(math.round(em * PILL_H_EM))})
	if prefs_page.update_badge(app.updates.updater, proc(user: rawptr) { app_restart((^App)(user)) }, app) != nil { ui.space(ui.SPACE_2) }
}
