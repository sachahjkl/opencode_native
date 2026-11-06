// The web view of the Preview panel on Windows: WebView2, by the client's Rust library (native/occ_native/src/webview.rs). Its
// profile is a folder of its own beside the preferences: what an agent does in the page does not touch the user's browser.
package occ

import "base:runtime"
import "core:path/filepath"
import "core:strings"
import win "core:sys/windows"
import "gt:platform"
import "gt:render"

Web_Act :: enum i32 { Back, Forward, Reload, Stop, Focus }

@(private = "file") VK_CONTROL :: 0x11

@(private = "file")
web: rawptr

@(private = "file")
composed_below: bool   // composition_below_children ran

web_available :: proc() -> bool {
	key := win.utf8_to_wstring(`SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}`)
	h: win.HKEY
	if win.RegOpenKeyExW(win.HKEY_LOCAL_MACHINE, key, 0, win.KEY_READ, &h) == 0 { win.RegCloseKey(h); return true }
	if win.RegOpenKeyExW(win.HKEY_CURRENT_USER, key, 0, win.KEY_READ, &h) == 0 { win.RegCloseKey(h); return true }
	return false
}

// This may run inside a build (a modal dialog pumps the window's messages): it only keeps what it is told, and touches nothing else, the
// temporary memory of the frame above all. (preview.odin web_events_drain)
@(private = "file")
on_web :: proc "c" (user: rawptr, kind: i32, id: u64, data: [^]u8, n: uint) {
	context = runtime.default_context()
	k := Web_Event_Kind(kind)
	web_event_add((^App)(user), k, id, data[:n], k == .Key && win.GetKeyState(VK_CONTROL) < 0)
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

// The view exists, or is on its way. One that failed is made anew: a failure holds for this attempt, not for ever.
web_start :: proc(app: ^App) {
	p := &app.preview
	switch _ in p.web {
	case Web_Creating, Web_Ready: return
	case Web_Failed:              web_close(app)
	case nil:
	}
	if app.win == nil { return }   // (no window: nothing to put it in)
	if !composed_below {
		composed_below = true
		composition_below_children(app)
	}
	folder := pjoin({filepath.dir(prefs_path()), "webview"})
	web = occ_webview_new(int(uintptr(rawptr(app.win.hwnd))), raw_data(folder), len(folder), on_web, app)
	if web == nil {
		web_state_set(p, Web_Failed{strings.clone("the WebView2 runtime did not start")})
	} else {
		web_state_set(p, Web_Creating{})
	}
}

// The view is destroyed, and what it would still say is dropped with it. (A view on its way closes itself when it comes: native.)
web_close :: proc(app: ^App) {
	if web != nil { occ_webview_free(web) }
	web = nil
	web_state_set(&app.preview, nil)
}

// The page goes into this window: the panel's, as long as it has one of its own.
web_parent :: proc(w: ^platform.Window) {
	if web != nil { occ_webview_parent(web, int(uintptr(rawptr(w.hwnd)))) }
}

web_navigate :: proc(app: ^App, url: string) {
	if web == nil { web_start(app) }
	occ_webview_navigate(web, raw_data(url), len(url))
}

web_act :: proc(app: ^App, what: Web_Act) { occ_webview_act(web, i32(what)) }

// Whether the page has a place to go Back or Forward to.
web_can :: proc(what: Web_Act) -> bool { return occ_webview_can(web, i32(what)) != 0 }

web_script :: proc(code: string, id: u64) { occ_webview_script(web, raw_data(code), len(code), id) }

web_capture :: proc(id: u64) { occ_webview_capture(web, id) }

web_place :: proc(app: ^App, x, y, w, h: int, visible: bool) {
	if web == nil { return }
	occ_webview_place(web, i32(x), i32(y), i32(w), i32(h), visible ? 1 : 0)
}

