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

// A version on offer: signed, and of the channel and the folder it was found in, whatever the preference says since. (owned)
Update_Offer :: struct {
	manifest: update.Manifest,
	path:     string,
	channel:  string,
}

// What each state holds is what it needs. (nil: nothing going on.) Only update_go moves it, and frees what the next state does not keep.
Update_Checking    :: struct { asked: bool, offer: ^Update_Offer }   // `asked`: what it finds is said, even "nothing"; `offer`: what stands if it fails
Update_Ready       :: struct { offer: ^Update_Offer }
Update_Downloading :: struct { offer: ^Update_Offer }
Update_Installed   :: struct { version: string }   // (owned)
Update_State       :: union { Update_Checking, Update_Ready, Update_Downloading, Update_Installed }

Updater :: struct {
	state:    Update_State,
	checked:  bool,            // the check of the start was made
	result:   string,          // what the last check found, for the settings' page (owned)
	channel:  string,          // the channel of the preference, last seen (owned)
}

@(private = "file")
update_offer_of :: proc(s: Update_State) -> ^Update_Offer {
	switch v in s {
	case Update_Checking:    return v.offer
	case Update_Ready:       return v.offer
	case Update_Downloading: return v.offer
	case Update_Installed:
	}
	return nil
}

update_go :: proc(u: ^Updater, next: Update_State) {
	if o := update_offer_of(u.state); o != nil && o != update_offer_of(next) {
		update.manifest_destroy(&o.manifest)
		delete(o.path); delete(o.channel)
		free(o)
	}
	if i, is := u.state.(Update_Installed); is { delete(i.version) }
	u.state = next
}

@(private = "file")
update_result :: proc(u: ^Updater, s: string) {
	delete(u.result)
	u.result = strings.clone(s)
}

update_is_ready :: proc(u: ^Updater) -> bool { _, is := u.state.(Update_Ready); return is }
update_is_installed :: proc(u: ^Updater) -> bool { _, is := u.state.(Update_Installed); return is }
update_is_downloading :: proc(u: ^Updater) -> bool { _, is := u.state.(Update_Downloading); return is }

// The version on offer, or being put in place ("": none).
update_version :: proc(u: ^Updater) -> string {
	if i, is := u.state.(Update_Installed); is { return i.version }
	if o := update_offer_of(u.state); o != nil { return o.manifest.version }
	return ""
}

Update_Job :: struct {
	app:             ^App,      // (for its thread: the_app is the interface's)
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

// `missing`: the server was reached, and it has no such file.
@(private = "file")
fetch :: proc(h: ^Http, path: string) -> (data: string, ok, missing: bool) {
	status, body, reached := http_request(h, "GET", path)
	if !reached || status != 200 { delete(body); return "", false, update_says_missing(status, reached) }
	return body, true, false
}

// Only this says that a channel has no release. No network, a 5xx: nothing was learned, and "up to date" would be a guess that loses what is
// on offer.
update_says_missing :: proc(status: int, reached: bool) -> bool { return reached && status == 404 }

@(private = "file")
check_job :: proc(j: ^Update_Job) {
	h: Http
	if !http_init(&h, j.base, "", "") { j.err = strings.clone("the HTTP client failed to start"); return }
	name := fmt.tprintf("update-%s-%s.json", update.PLATFORM_WINDOWS_X64, j.channel)
	manifest, m_ok, missing := fetch(&h, fmt.tprintf("%s%s", j.path, name))
	if !m_ok {
		if missing { j.nothing_new = true } else { j.err = strings.clone("the server could not be read") }   // (missing: no release on this channel yet)
		return
	}
	defer delete(manifest)
	sig, s_ok, _ := fetch(&h, fmt.tprintf("%s%s.sig", j.path, name))
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
	data, ok, _ := fetch(&h, fmt.tprintf("%s%s", j.path, j.manifest.file))
	if !ok { j.err = strings.clone("the update could not be downloaded"); return }
	defer delete(data)
	bytes := transmute([]byte)data
	if e := update.check_binary(j.manifest, bytes); e != .None { j.err = strings.clone(update.error_text(e)); return }
	if msg := update_place(j.exe, bytes, j.manifest); msg != "" { j.err = strings.clone(msg) }
}

@(private = "file")
on_update :: proc(data: rawptr, word: u64) { update_answered(the_app, (^Update_Job)(data)) }

update_answered :: proc(app: ^App, j: ^Update_Job) {
	defer {
		delete(j.base); delete(j.path); delete(j.channel); delete(j.exe); delete(j.err)
		free(j)
	}
	app.frames = max(app.frames, FRAMES_AFTER_INPUT)
	if j.install { update_installed(app, j) } else { update_checked(app, j) }
}

@(private = "file")
update_installed :: proc(app: ^App, j: ^Update_Job) {
	u := &app.updater
	d, is := u.state.(Update_Downloading)
	if !is { return }
	if j.err != "" {
		update_go(u, Update_Ready{d.offer})
		ui.toast(.Bad, "Update: %s", j.err)
		return
	}
	version := strings.clone(d.offer.manifest.version)
	update_go(u, Update_Installed{version})
	ui.toast_action(.Good, proc(user: rawptr) { update_restart((^App)(user)) }, app, "%s is installed: click to restart", version)
}

@(private = "file")
update_checked :: proc(app: ^App, j: ^Update_Job) {
	u := &app.updater
	c, is := u.state.(Update_Checking)
	if !is {   // (nothing waits for it)
		if j.err == "" && !j.nothing_new { update.manifest_destroy(&j.found) }
		return
	}
	if j.channel != app.prefs.update_channel {   // (the channel changed under it: the question is another one)
		if j.err == "" && !j.nothing_new { update.manifest_destroy(&j.found) }
		update_job_start(app, new(Update_Job))
		return
	}
	switch {
	case j.err != "":
		update_result(u, j.err)
		if c.asked { ui.toast(.Bad, "Update: %s", j.err) }
		// (a check that failed says nothing against what was on offer)
		if c.offer != nil { update_go(u, Update_Ready{c.offer}) } else { update_go(u, nil) }
	case j.nothing_new:
		update_result(u, "Up to date")
		if c.asked { ui.toast(.Good, "opencode native %s is the latest", APP_VERSION) }
		update_go(u, nil)
	case:
		o := new(Update_Offer)
		o^ = {j.found, strings.clone(j.path), strings.clone(j.channel)}
		update_result(u, fmt.tprintf("Version %s is available", o.manifest.version))
		update_go(u, Update_Ready{o})
		ui.toast_action(.Good, proc(user: rawptr) { update_install((^App)(user)) }, app, "opencode native %s is available: click to install", o.manifest.version)
	}
}

// The check's folder is the channel's; an install's is that of its offer.
@(private = "file")
update_job_start :: proc(app: ^App, j: ^Update_Job) {
	j.app = app
	j.base = strings.clone(update_base(app))
	if !j.install {
		j.channel = strings.clone(app.prefs.update_channel)
		j.path = strings.clone(channel_dir(app.prefs.update_channel))
	}
	when ODIN_TEST {   // (kept for the test to answer)
		bench_update_job = j
		return
	}
	thread.create_and_start_with_poly_data(j, proc(j: ^Update_Job) {
		if j.install { install_job(j) } else { check_job(j) }
		_ = ui.post(&j.app.ui_state, on_update, j)
		free_all(context.temp_allocator)
	}, self_cleanup = true)
}

// Asked by the user (the palette, the settings) or at start. What is on offer does not stop a check: it may be asked again; a check
// running takes the asking over, and says what it finds.
update_check :: proc(app: ^App, asked: bool) {
	u := &app.updater
	if ODIN_OS != .Windows { if asked { ui.toast(.Warn, "Updates install by hand on this system") }; return }
	switch &v in u.state {
	case Update_Checking:
		v.asked = v.asked || asked
		return
	case Update_Downloading:
		return
	case Update_Installed:
		if asked { ui.toast_action(.Good, proc(user: rawptr) { update_restart((^App)(user)) }, app, "%s is installed: click to restart", v.version) }
		return
	case Update_Ready:
		update_go(u, Update_Checking{asked, v.offer})
	case nil:
		update_go(u, Update_Checking{asked, nil})
	}
	update_job_start(app, new(Update_Job))
}

update_check_now :: proc(app: ^App) { update_check(app, true) }

// The channel changed: what is on offer was the other one's, and nothing of it goes on. (A download under way ends: it was asked for.)
update_channel_follow :: proc(app: ^App) {
	u := &app.updater
	if u.channel == app.prefs.update_channel { return }
	first := u.channel == ""
	delete(u.channel)
	u.channel = strings.clone(app.prefs.update_channel)
	if first { return }
	update_result(u, "")
	#partial switch v in u.state {
	case Update_Ready:    update_go(u, nil)
	case Update_Checking: update_go(u, Update_Checking{v.asked, nil})
	}
}

update_install :: proc(app: ^App) {
	u := &app.updater
	r, is := u.state.(Update_Ready)
	if !is { return }
	update_go(u, Update_Downloading{r.offer})
	j := new(Update_Job)
	j.install, j.manifest = true, r.offer.manifest
	j.path, j.channel = strings.clone(r.offer.path), strings.clone(r.offer.channel)
	j.exe = strings.clone(running_exe())
	update_job_start(app, j)
}

// The new program takes over.
update_restart :: proc(app: ^App) {
	args := []string{running_exe()}
	if _, err := os.process_start({command = args}); err != nil { ui.toast(.Bad, "Restart it by hand: it could not be started"); return }
	app.quit = true
}

// At the start of the program, whatever the server does: what an earlier update left, and whether there is another.
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
	switch _ in u.state {
	case Update_Ready:       label = fmt.tprintf("Update to %s", update_version(u))
	case Update_Downloading: label = "Downloading the update…"
	case Update_Installed:   label = "Restart to update"
	case Update_Checking:    return
	case nil:                return
	}
	if pill_button("###update", label, accent(), ICO_REFRESH).clicked {
		if update_is_ready(u) { update_install(app) } else if update_is_installed(u) { update_restart(app) }
	}
	ui.spacer(ui.px(em * 0.6))
}
