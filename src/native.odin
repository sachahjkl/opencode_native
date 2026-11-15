// The client's Rust library (native/ocn_native; ocntools build -> build/native): what the toolkit has no Odin equivalent
// for. On every system it holds the toolkit's Mermaid (gt_mermaid) and WebP (gt_webp) crates, on Linux its text backend
// (gt_text), on Windows the Preview panel's WebView2. The toolkit's packages call their gt_* functions without linking
// them (the *_NATIVE_LINK=false defines): this import is what links them, hence @(require).
package ocn

when ODIN_OS == .Windows {
	@(require)
	foreign import ocn_native {
		"../build/native/ocn_native.lib",
		"system:ws2_32.lib",
		"system:advapi32.lib",
		"system:userenv.lib",
		"system:ntdll.lib",
		"system:kernel32.lib",
		"system:bcrypt.lib",
		"system:ole32.lib",
		"system:oleaut32.lib",
	}

	Web_Callback :: proc "c" (user: rawptr, kind: i32, id: u64, data: [^]u8, n: uint)

	@(default_calling_convention = "c")
	foreign ocn_native {   // (webview_windows.odin)
		ocn_webview_new :: proc(parent: int, data: [^]u8, data_len: uint, cb: Web_Callback, user: rawptr) -> rawptr ---
		ocn_webview_parent :: proc(w: rawptr, hwnd: int) ---
		ocn_webview_place :: proc(w: rawptr, x, y, width, height, visible: i32) ---
		ocn_webview_navigate :: proc(w: rawptr, url: [^]u8, n: uint) ---
		ocn_webview_act :: proc(w: rawptr, what: i32) ---
		ocn_webview_script :: proc(w: rawptr, code: [^]u8, n: uint, id: u64) ---
		ocn_webview_capture :: proc(w: rawptr, id: u64) ---
		ocn_webview_can :: proc(w: rawptr, what: i32) -> i32 ---
		ocn_webview_free :: proc(w: rawptr) ---
	}
} else {
	@(require)
	foreign import ocn_native { "../build/native/libocn_native.a", "system:dl", "system:pthread", "system:m" }
}
