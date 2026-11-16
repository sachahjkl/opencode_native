// Updates: gui_toolkit's Updater (gt:update, its docs/update.md) on this program's channels, as in every program of the
// toolkit. A release publishes a signed manifest per platform and channel (docs/updates.md); the Updater checks it on its
// own thread, downloads the program it names and puts it in place of the running one, with this program's product
// (src/update). The settings' Updates page is the toolkit's: update.auto, update.channel (a choice of UPDATE_CHANNELS) and
// update.base_url, the state under them and their buttons. A Nix package is never updated here: Nix updates it.
package ocn

import "base:runtime"

import "core:fmt"
import "core:log"
import "core:math"
import "core:strings"
import process "gt:process"
import prefs_page "gt:prefs_page"
import setup "gt:setup"
import "gt:ui"
import ocn_update "update"
import update "gt:update"
import i18n "gt:i18n"

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
	if app.updater != nil || app.prefs_file == "" { return }
	folder, channel := prefs_page.update_source(&app.cfg_prefs)
	app.updater = update.updater_start({
		product = ocn_update.PRODUCT, folder = folder, channels = UPDATE_CHANNELS[:], channel = channel, current = APP_VERSION,
		exe = process.executable_path(), user_agent = fmt.tprintf("opencode-native/%s", APP_VERSION),
		// (the updater's thread: its news comes to the interface's thread, which reads the state there)
		news = proc(user: rawptr) { _ = ui.post(&(^App)(user).state, on_update_news, user) }, user = app,
	})
	updates_prefs(app)
}

// update.auto and update.channel, read again when the preferences change.
updates_prefs :: proc(app: ^App) {
	if app.updater == nil { return }
	update.set_auto(app.updater, app.prefs.update_auto ? .Install : .Off)
	_, channel := prefs_page.update_source(&app.cfg_prefs)
	update.set_channel(app.updater, channel)
}

// At the end, before the interface's state goes: no news after it.
updates_stop :: proc(app: ^App) {
	update.updater_stop(app.updater)
	app.updater = nil
}

@(private = "file")
on_update_news :: proc(data: rawptr, _: u64) { updates_follow((^App)(data)) }

// What changed is said once. The status bar's pill shows the phase and its button (a version on offer, its download, a
// restart): a toast says only what the pill cannot (update.notice).
updates_follow :: proc(app: ^App) {
	if app.updater == nil { return }
	st := update.status(app.updater)
	if st.serial == app.update_serial { return }
	app.update_serial = st.serial
	app.settle = max(app.settle, FRAMES_AFTER_INPUT)   // (the status bar and the settings show the state)
	if words, bad := update.notice(st); words != "" { ui.announce(&app.announcer, bad ? .Bad : .Good, words) }
	if st.phase == .Installed { installed_record(app, st.version) }
}

// The installed copy: its manifest and its system's record take the new version (desktop_updated), on a task: they are
// files and, on Windows, the registry.
@(private = "file")
installed_record :: proc(app: ^App, version: string) {
	v := new(string, runtime.heap_allocator())
	v^ = strings.clone(version, runtime.heap_allocator())
	ui.task(&app.state, proc(data: rawptr) {
		defer version_free(data)
		v := (^string)(data)
		if ok, why := desktop_updated(process.executable_path(), v^); !ok { log.errorf("the update is in place, but %s", why) }
	}, nil, v, version_free)
}

@(private = "file")
version_free :: proc(data: rawptr) {
	v := (^string)(data)
	delete(v^, runtime.heap_allocator())
	free(v, runtime.heap_allocator())
}

// "Check for updates" (the palette): its answer is said whatever it is.
update_check_now :: proc(app: ^App) {
	if app.updater != nil { update.check_now(app.updater) }
}

update_install_now :: proc(app: ^App) {
	if app.updater != nil { update.install_now(app.updater) }
}

update_phase :: proc(app: ^App) -> update.Phase {
	if app.updater == nil { return .Idle }
	return update.status(app.updater).phase
}

// The program starts again: this one ends, then another of it starts from the same file (the same one, or the one an update
// put there). The new one starts at main's very end, once the single instance is let go: started before, it would hand its
// start to this window, which then ends (src/md/features/single-instance.md).
app_restart :: proc(app: ^App) {
	app.launch_after = process.executable_path()
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
	if prefs_page.update_badge(app.updater, proc(user: rawptr) { app_restart((^App)(user)) }, app) != nil { ui.space(ui.SPACE_2) }
}
