// Updates, from Wren: a release publishes a signed manifest per channel (src/update, docs/updates.md), and this checks it,
// downloads the program it names, checks that against the signature, and puts it in place of the running one. A running
// program on Windows can be renamed, not overwritten: it goes aside as .old and is removed at the next start. Nothing here
// waits on the interface's thread. Windows only for now: elsewhere a new version is said, and installed by hand.
package occ

import "core:fmt"
import "core:os"
import "core:strings"
import "core:thread"
import "gt:config"
import "gt:ui"
import update "update"

Update_State :: enum u8 { Idle, Checking, Ready, Downloading, Installed }

Updater :: struct {
	state:    Update_State,
	version:  string,          // what is on offer (owned)
	manifest: update.Manifest, // ... signed (owned)
	base:     string,          // where it came from (owned)
	checked:  bool,            // the check of the start was made
	asked:    bool,            // the user asked: what the check finds is said, even "nothing"
	result:   string,          // what the last check found, for the settings' page (owned)
}

@(private = "file")
Update_Job :: struct {
	base, path:      string,    // (owned)
	channel:         string,    // (owned)
	manifest:        update.Manifest,
	install:         bool,
	exe:             string,    // (owned)
	// the answer
	err:             string,    // (owned)
	nothing_new:     bool,
	found:           update.Manifest,
}

@(private = "file")
channel_dir :: proc(channel: string) -> string {
	return channel == "beta" ? UPDATE_BETA_DIR : UPDATE_STABLE_DIR
}

@(private = "file")
update_base :: proc(app: ^App) -> string {
	if b := config.string_of(&app.cfg_prefs, "update.base_url"); b != "" { return b }
	return UPDATE_HOST
}

@(private = "file")
fetch :: proc(h: ^Http, path: string) -> (data: string, ok: bool) {
	status, body, reached := http_request(h, "GET", path)
	if !reached || status != 200 { delete(body); return "", false }
	return body, true
}

@(private = "file")
check_job :: proc(j: ^Update_Job) {
	h: Http
	if !http_init(&h, j.base, "", "") { j.err = strings.clone("the HTTP client failed to start"); return }
	name := fmt.tprintf("update-%s-%s.json", update.PLATFORM_WINDOWS_X64, j.channel)
	manifest, m_ok := fetch(&h, fmt.tprintf("%s%s", j.path, name))
	if !m_ok { j.nothing_new = true; return }   // (no release on this channel yet)
	defer delete(manifest)
	sig, s_ok := fetch(&h, fmt.tprintf("%s%s.sig", j.path, name))
	if !s_ok { j.err = strings.clone("the update has no signature: refused"); return }
	defer delete(sig)
	m, err := update.check_release(transmute([]byte)manifest, sig, update.UPDATE_PUBLIC_KEY, update.PLATFORM_WINDOWS_X64, j.channel, APP_VERSION, "")
	#partial switch err {
	case .None:      j.found = m
	case .Not_Newer: j.nothing_new = true
	case:            j.err = strings.clone(update.error_text(err))
	}
}

// `exe` becomes the program of `data`: written beside it, read back, then swapped by two renames.
update_place :: proc(exe: string, data: []byte, m: update.Manifest) -> string {
	if len(data) < 2 || data[0] != 'M' || data[1] != 'Z' { return "the download is not a program" }
	next := fmt.tprintf("%s.update", exe)
	if os.write_entire_file(next, data) != nil { return "the update could not be written beside the program" }
	back, err := os.read_entire_file(next, context.temp_allocator)
	if err != nil || update.check_binary(m, back) != .None { _ = os.remove(next); return "the update was not written whole" }
	old := fmt.tprintf("%s.old", exe)
	_ = os.remove(old)
	if os.rename(exe, old) != nil { _ = os.remove(next); return "the running program could not be moved aside" }
	if os.rename(next, exe) != nil {
		_ = os.rename(old, exe)   // (back as it was)
		return "the update could not be put in place"
	}
	return ""
}

@(private = "file")
install_job :: proc(j: ^Update_Job) {
	h: Http
	if !http_init(&h, j.base, "", "") { j.err = strings.clone("the HTTP client failed to start"); return }
	data, ok := fetch(&h, fmt.tprintf("%s%s", j.path, j.manifest.file))
	if !ok { j.err = strings.clone("the update could not be downloaded"); return }
	defer delete(data)
	bytes := transmute([]byte)data
	if e := update.check_binary(j.manifest, bytes); e != .None { j.err = strings.clone(update.error_text(e)); return }
	if msg := update_place(j.exe, bytes, j.manifest); msg != "" { j.err = strings.clone(msg) }
}

@(private = "file")
on_update :: proc(data: rawptr, word: u64) {
	app := the_app
	j := (^Update_Job)(data)
	u := &app.updater
	defer {
		delete(j.base); delete(j.path); delete(j.channel); delete(j.exe); delete(j.err)
		free(j)
	}
	asked := u.asked
	u.asked = false
	app.frames = max(app.frames, FRAMES_AFTER_INPUT)
	if j.install {
		if j.err != "" {
			u.state = .Ready
			ui.toast(.Bad, "Update: %s", j.err)
			return
		}
		u.state = .Installed
		ui.toast(.Good, "%s is installed: restart to use it", u.version)
		return
	}
	u.state = .Idle
	delete(u.result)
	u.result = strings.clone(j.err != "" ? j.err : "Up to date")
	switch {
	case j.err != "":
		if asked { ui.toast(.Bad, "Update: %s", j.err) }
	case j.nothing_new:
		if asked { ui.toast(.Good, "opencode native %s is the latest", APP_VERSION) }
	case:
		update.manifest_destroy(&u.manifest)
		u.manifest = j.found
		delete(u.version)
		u.version = strings.clone(j.found.version)
		u.state = .Ready
		ui.toast(.Good, "opencode native %s is available", u.version)
	}
}

@(private = "file")
update_job_start :: proc(app: ^App, j: ^Update_Job) {
	j.base = strings.clone(update_base(app))
	j.channel = strings.clone(app.prefs.update_channel)
	j.path = strings.clone(channel_dir(app.prefs.update_channel))
	thread.create_and_start_with_poly_data(j, proc(j: ^Update_Job) {
		if j.install { install_job(j) } else { check_job(j) }
		_ = ui.post(&the_app.ui_state, on_update, j)
		free_all(context.temp_allocator)
	}, self_cleanup = true)
}

// Asked by the user (the palette, the Setup) or at start.
update_check :: proc(app: ^App, asked: bool) {
	u := &app.updater
	if ODIN_OS != .Windows { if asked { ui.toast(.Warn, "Updates install by hand on this system") }; return }
	if u.state != .Idle { return }
	u.state = .Checking
	u.asked = asked
	update_job_start(app, new(Update_Job))
}

update_check_now :: proc(app: ^App) { update_check(app, true) }

update_install :: proc(app: ^App) {
	u := &app.updater
	if u.state != .Ready { return }
	u.state = .Downloading
	j := new(Update_Job)
	j.install, j.manifest = true, u.manifest
	j.exe = strings.clone(running_exe())
	update_job_start(app, j)
}

// The new program takes over.
update_restart :: proc(app: ^App) {
	args := []string{running_exe()}
	if _, err := os.process_start({command = args}); err != nil { ui.toast(.Bad, "Restart it by hand: it could not be started"); return }
	app.quit = true
}

// Once online, once: what an earlier update left, and whether there is another.
update_startup :: proc(app: ^App) {
	u := &app.updater
	if u.checked { return }
	u.checked = true
	if ODIN_OS == .Windows { _ = os.remove(fmt.tprintf("%s.old", running_exe())) }
	if app.prefs.update_auto && app.prefs_file != "" { update_check(app, false) }
}

// A pill in the status bar, while there is something to do.
update_pill :: proc(app: ^App, em: f32) {
	u := &app.updater
	label := ""
	#partial switch u.state {
	case .Ready:       label = fmt.tprintf("Update to %s", u.version)
	case .Downloading: label = "Downloading the update…"
	case .Installed:   label = "Restart to update"
	case:              return
	}
	if pill_button("###update", label, accent(), ICO_REFRESH).clicked {
		#partial switch u.state {
		case .Ready:     update_install(app)
		case .Installed: update_restart(app)
		}
	}
	ui.spacer(ui.px(em * 0.6))
}
