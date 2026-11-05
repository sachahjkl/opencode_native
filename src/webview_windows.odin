// The web view of the Preview panel on Windows: WebView2, by the client's Rust library (native/occ_native/src/webview.rs). Its
// profile is a folder of its own beside the preferences: what an agent does in the page does not touch the user's browser.
package occ

import "base:runtime"
import "core:path/filepath"
import "core:strings"
import win "core:sys/windows"
import "gt:render"

Web_Act :: enum i32 { Back, Forward, Reload, Stop, Focus }

@(private = "file") EV_READY     :: 1
@(private = "file") EV_FAILED    :: 2
@(private = "file") EV_SOURCE    :: 3
@(private = "file") EV_TITLE     :: 4
@(private = "file") EV_LOADED    :: 5
@(private = "file") EV_SCRIPT    :: 6
@(private = "file") EV_CAPTURE   :: 7
@(private = "file") EV_KEY       :: 8
@(private = "file") EV_NAV_START :: 9

@(private = "file") VK_CONTROL :: 0x11

@(private = "file")
web: rawptr

web_available :: proc() -> bool {
	key := win.utf8_to_wstring(`SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}`)
	h: win.HKEY
	if win.RegOpenKeyExW(win.HKEY_LOCAL_MACHINE, key, 0, win.KEY_READ, &h) == 0 { win.RegCloseKey(h); return true }
	if win.RegOpenKeyExW(win.HKEY_CURRENT_USER, key, 0, win.KEY_READ, &h) == 0 { win.RegCloseKey(h); return true }
	return false
}

@(private = "file")
on_web :: proc "c" (user: rawptr, kind: i32, id: u64, data: [^]u8, n: uint) {
	context = runtime.default_context()
	app := (^App)(user)
	p := &app.preview
	s := string(data[:n])
	app.frames = max(app.frames, FRAMES_AFTER_INPUT)
	switch kind {
	case EV_READY:
		p.ready = true
		if p.asked != "" {
			web_navigate(app, p.asked)
			delete(p.asked)
			p.asked = ""
		}
	case EV_FAILED:
		delete(p.failed)
		p.failed = strings.clone(s)
	case EV_SOURCE:    preview_set_url(app, s)
	case EV_TITLE:     preview_set_title(app, s)
	case EV_NAV_START: p.loading = true
	case EV_LOADED:
		p.loading = false
		browser_page_loaded(app, id != 0)
	case EV_SCRIPT:    browser_script_done(app, id, s)
	case EV_CAPTURE:   browser_capture_done(app, id, data[:n])
	case EV_KEY:
		// (the page has the keyboard: what the program answers to must still reach it)
		if win.GetKeyState(VK_CONTROL) < 0 && id == u64('K') { command_run(app, command_find("app.palette")) }
		if id == u64(win.VK_F1) { command_run(app, command_find("app.help")) }
	}
	free_all(context.temp_allocator)
}

// The window's picture is a composition, on top of its child windows: the page would load, unseen, under it. Its target is
// made again below them. (Once: nothing changes for those who never open the panel.)
@(private = "file")
composition_below_children :: proc(app: ^App) {
	r := &app.r
	if r.dcomp == nil || r.dcomp_target == nil { return }
	r.dcomp_target->Release()
	r.dcomp_target = nil
	target: ^render.IDCompositionTarget
	if win.SUCCEEDED(r.dcomp->CreateTargetForHwnd(app.win.hwnd, false, &target)) {
		r.dcomp_target = target
		target->SetRoot(r.dcomp_visual)
		r.dcomp->Commit()
	}
}

// The view exists, or is on its way.
web_start :: proc(app: ^App) {
	if web != nil { return }
	composition_below_children(app)
	folder := pjoin({filepath.dir(prefs_path()), "webview"})
	web = occ_webview_new(int(uintptr(rawptr(app.win.hwnd))), raw_data(folder), len(folder), on_web, app)
	if web == nil { app.preview.failed = strings.clone("the WebView2 runtime did not start") }
}

web_navigate :: proc(app: ^App, url: string) {
	if web == nil { web_start(app) }
	occ_webview_navigate(web, raw_data(url), len(url))
}

web_act :: proc(app: ^App, what: Web_Act) { occ_webview_act(web, i32(what)) }

web_script :: proc(code: string, id: u64) { occ_webview_script(web, raw_data(code), len(code), id) }

web_capture :: proc(id: u64) { occ_webview_capture(web, id) }

web_place :: proc(app: ^App, x, y, w, h: int, visible: bool) {
	if web == nil { return }
	occ_webview_place(web, i32(x), i32(y), i32(w), i32(h), visible ? 1 : 0)
}

