// The web views of the Preview panel on Windows: WebView2, by the client's Rust library (native/ocn_native/src/webview.rs). Their
// profile is a folder of its own beside the preferences, one for every view: what an agent does in a page does not touch the user's browser.
package ocn

import "base:runtime"
import "core:path/filepath"
import win "core:sys/windows"
import "gt:platform"
import "gt:render"

@(private = "file") VK_CONTROL :: 0x11
@(private = "file") VK_SHIFT   :: 0x10

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
	// (Ctrl alone: with Shift it is another key of the program's, a shell's Ctrl+Shift+T above all)
	web_event_add((^Web_View)(user), k, id, data[:n], k == .Key && win.GetKeyState(VK_CONTROL) < 0 && win.GetKeyState(VK_SHIFT) >= 0)
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

@(private = "file")
hwnd_of :: proc(w: ^platform.Window) -> int { return int(uintptr(rawptr(w.hwnd))) }

// A view on its way. (All of them in the one folder: the system gives views of the same folder one browser and its processes.)
@(private = "file")
system_open :: proc(app: ^App, v: ^Web_View, parent: ^platform.Window) -> rawptr {
	if !composed_below {
		composed_below = true
		composition_below_children(app)
	}
	folder := pjoin({filepath.dir(prefs_path()), "webview"})
	return ocn_webview_new(hwnd_of(parent), raw_data(folder), len(folder), on_web, v)
}

web_host_system :: proc() -> Web_Host {
	return {
		open = system_open,
		close = proc(native: rawptr) { ocn_webview_free(native) },
		parent = proc(native: rawptr, w: ^platform.Window) { ocn_webview_parent(native, hwnd_of(w)) },
		navigate = proc(native: rawptr, url: string) { ocn_webview_navigate(native, raw_data(url), len(url)) },
		act = proc(native: rawptr, what: Web_Act) { ocn_webview_act(native, i32(what)) },
		can = proc(native: rawptr, what: Web_Act) -> bool { return ocn_webview_can(native, i32(what)) != 0 },
		script = proc(native: rawptr, code: string, id: u64) { ocn_webview_script(native, raw_data(code), len(code), id) },
		capture = proc(native: rawptr, id: u64) { ocn_webview_capture(native, id) },
		place = proc(native: rawptr, x, y, w, h: int, visible: bool) { ocn_webview_place(native, i32(x), i32(y), i32(w), i32(h), visible ? 1 : 0) },
	}
}
