//! The client's native library: what the toolkit has no Odin equivalent for.
//!
//! * The toolkit's Mermaid diagrams and WebP decoding (every system) and its text backend (Linux), linked in here.
//! * Windows: the Preview panel's WebView2 (webview.rs), as C functions.
//!
//! No call unwinds into the caller: a panic is caught.

// The toolkit's Mermaid diagrams live in this library (gt_mermaid_render is what the mermaid package calls)
pub extern crate gt_mermaid;

// The toolkit's WebP lives in this library too (gt_webp_* is what gt:image calls for a WebP picture)
pub extern crate gt_webp;

// Linux: the toolkit's text backend lives in this library (its exported gt_* functions are what font/backend_native.odin calls)
#[cfg(target_os = "linux")]
pub extern crate gt_text;

////////////////////////////////
// The web view of the Preview panel (webview.rs)

#[cfg(windows)]
mod webview;

#[cfg(windows)]
mod webview_c {
    use super::webview::{self, Callback, Web};
    use std::ffi::c_void;
    use std::panic::{catch_unwind, AssertUnwindSafe};

    unsafe fn text<'a>(p: *const u8, n: usize) -> &'a str {
        if p.is_null() { return ""; }
        std::str::from_utf8(std::slice::from_raw_parts(p, n)).unwrap_or("")
    }

    #[no_mangle]
    pub unsafe extern "C" fn ocn_webview_new(parent: isize, data: *const u8, data_len: usize, cb: Callback, user: *mut c_void) -> *mut Web {
        catch_unwind(AssertUnwindSafe(|| match webview::create(parent, text(data, data_len), cb, user) {
            Some(w) => Box::into_raw(w),
            None => std::ptr::null_mut(),
        })).unwrap_or(std::ptr::null_mut())
    }

    #[no_mangle]
    pub unsafe extern "C" fn ocn_webview_parent(w: *const Web, hwnd: isize) {
        if !w.is_null() {
            (*w).parent(hwnd);
        }
    }

    #[no_mangle]
    pub unsafe extern "C" fn ocn_webview_place(w: *const Web, x: i32, y: i32, width: i32, height: i32, visible: i32) {
        if let Some(w) = w.as_ref() { let _ = catch_unwind(AssertUnwindSafe(|| w.place(x, y, width, height, visible != 0))); }
    }

    #[no_mangle]
    pub unsafe extern "C" fn ocn_webview_navigate(w: *const Web, url: *const u8, len: usize) {
        if let Some(w) = w.as_ref() { let _ = catch_unwind(AssertUnwindSafe(|| w.navigate(text(url, len)))); }
    }

    #[no_mangle]
    pub unsafe extern "C" fn ocn_webview_act(w: *const Web, what: i32) {
        if let Some(w) = w.as_ref() { let _ = catch_unwind(AssertUnwindSafe(|| w.act(what))); }
    }

    #[no_mangle]
    pub unsafe extern "C" fn ocn_webview_script(w: *const Web, code: *const u8, len: usize, id: u64) {
        if let Some(w) = w.as_ref() { let _ = catch_unwind(AssertUnwindSafe(|| w.script(text(code, len), id))); }
    }

    #[no_mangle]
    pub unsafe extern "C" fn ocn_webview_capture(w: *const Web, id: u64) {
        if let Some(w) = w.as_ref() { let _ = catch_unwind(AssertUnwindSafe(|| w.capture(id))); }
    }

    /// 0 back, 1 forward: whether the page has a place to go. (No view: none.)
    #[no_mangle]
    pub unsafe extern "C" fn ocn_webview_can(w: *const Web, what: i32) -> i32 {
        match w.as_ref() {
            Some(w) => catch_unwind(AssertUnwindSafe(|| w.can(what))).unwrap_or(false) as i32,
            None => 0,
        }
    }

    #[no_mangle]
    pub unsafe extern "C" fn ocn_webview_free(w: *mut Web) {
        if !w.is_null() {
            let b = Box::from_raw(w);
            b.close();
        }
    }
}
