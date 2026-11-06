//! A web view as a child window (WebView2): what the client's Preview panel shows. Every function runs on the thread of the
//! window; WebView2 answers through that thread's message loop, in `Callback`. The Edge runtime is the system's: nothing to
//! ship, and `occ_webview_new` fails where it is missing.

use std::cell::RefCell;
use std::ffi::c_void;
use std::rc::Rc;

use webview2_com::Microsoft::Web::WebView2::Win32::*;
use webview2_com::*;
use windows::core::{HSTRING, PCWSTR, PWSTR};
use windows::Win32::Foundation::{HWND, RECT};
use windows::Win32::System::Com::{CoInitializeEx, CoTaskMemFree, IStream, COINIT_APARTMENTTHREADED, STREAM_SEEK_SET};
use windows::Win32::UI::Shell::SHCreateMemStream;

pub type Callback = extern "C" fn(user: *mut c_void, kind: i32, id: u64, data: *const u8, len: usize);

// What `Callback` is told.
const EV_READY: i32 = 1; // the view exists: it can be shown and navigated
const EV_FAILED: i32 = 2; // it could not be made (data: why)
const EV_SOURCE: i32 = 3; // the address changed (data: it)
const EV_TITLE: i32 = 4; // the title changed (data: it)
const EV_LOADED: i32 = 5; // a navigation ended (id: which; data: one byte, 1 when it succeeded)
const EV_SCRIPT: i32 = 6; // a script's result, JSON (id: the caller's)
const EV_CAPTURE: i32 = 7; // a picture, PNG (id: the caller's)
const EV_KEY: i32 = 8; // a key with Ctrl or a function key, while the page has the focus (id: virtual key)
const EV_NAV_START: i32 = 9; // a navigation began (id: which; a redirection keeps it)

struct Inner {
    controller: Option<ICoreWebView2Controller>,
    view: Option<ICoreWebView2>,
    bounds: RECT,
    visible: bool,
    pending: Option<String>, // an address asked for before the view was there
    closed: bool,            // closed before it came: when it does, it is closed at once and nobody is told
}

pub struct Web {
    inner: Rc<RefCell<Inner>>,
    cb: Callback,
    user: *mut c_void,
}

#[derive(Clone, Copy)]
struct Sink {
    cb: Callback,
    user: *mut c_void,
}

impl Sink {
    fn send(&self, kind: i32, id: u64, data: &[u8]) {
        (self.cb)(self.user, kind, id, data.as_ptr(), data.len());
    }
}

fn take_pwstr(p: PWSTR) -> String {
    if p.is_null() {
        return String::new();
    }
    let s = unsafe { p.to_string().unwrap_or_default() };
    unsafe { CoTaskMemFree(Some(p.0 as *const c_void)) };
    s
}

fn hook(view: &ICoreWebView2, controller: &ICoreWebView2Controller, sink: Sink) -> windows::core::Result<()> {
    let mut token = 0i64;
    unsafe {
        view.add_SourceChanged(
            &SourceChangedEventHandler::create(Box::new(move |sender, _| {
                if let Some(v) = sender {
                    let mut p = PWSTR::null();
                    if v.Source(&mut p).is_ok() {
                        sink.send(EV_SOURCE, 0, take_pwstr(p).as_bytes());
                    }
                }
                Ok(())
            })),
            &mut token,
        )?;
        view.add_DocumentTitleChanged(
            &DocumentTitleChangedEventHandler::create(Box::new(move |sender, _| {
                if let Some(v) = sender {
                    let mut p = PWSTR::null();
                    if v.DocumentTitle(&mut p).is_ok() {
                        sink.send(EV_TITLE, 0, take_pwstr(p).as_bytes());
                    }
                }
                Ok(())
            })),
            &mut token,
        )?;
        view.add_NavigationStarting(
            &NavigationStartingEventHandler::create(Box::new(move |_, args| {
                let mut id = 0u64;
                if let Some(a) = args {
                    let _ = a.NavigationId(&mut id);
                }
                sink.send(EV_NAV_START, id, &[]);
                Ok(())
            })),
            &mut token,
        )?;
        view.add_NavigationCompleted(
            &NavigationCompletedEventHandler::create(Box::new(move |_, args| {
                let mut ok = windows::core::BOOL(0);
                let mut id = 0u64;
                if let Some(a) = args {
                    let _ = a.IsSuccess(&mut ok);
                    let _ = a.NavigationId(&mut id);
                }
                sink.send(EV_LOADED, id, &[ok.as_bool() as u8]);
                Ok(())
            })),
            &mut token,
        )?;
        controller.add_AcceleratorKeyPressed(
            &AcceleratorKeyPressedEventHandler::create(Box::new(move |_, args| {
                if let Some(a) = args {
                    let mut kind = COREWEBVIEW2_KEY_EVENT_KIND_KEY_DOWN;
                    let mut vk = 0u32;
                    a.KeyEventKind(&mut kind)?;
                    a.VirtualKey(&mut vk)?;
                    if kind == COREWEBVIEW2_KEY_EVENT_KIND_KEY_DOWN {
                        sink.send(EV_KEY, vk as u64, &[]);
                    }
                }
                Ok(())
            })),
            &mut token,
        )?;
    }
    Ok(())
}

fn made(inner: &Rc<RefCell<Inner>>, controller: ICoreWebView2Controller, sink: Sink) -> windows::core::Result<()> {
    if inner.borrow().closed {
        return unsafe { controller.Close() };
    }
    let view = unsafe { controller.CoreWebView2()? };
    hook(&view, &controller, sink)?;
    let (bounds, visible, pending) = {
        let mut i = inner.borrow_mut();
        (i.bounds, i.visible, i.pending.take())
    };
    unsafe {
        controller.SetBounds(bounds)?;
        controller.SetIsVisible(visible)?;
        if let Some(url) = pending {
            view.Navigate(&HSTRING::from(url))?;
        }
    }
    let mut i = inner.borrow_mut();
    i.controller = Some(controller);
    i.view = Some(view);
    drop(i);
    sink.send(EV_READY, 0, &[]);
    Ok(())
}

/// A web view in the window `parent`, its profile in the folder `data` (made if need be). It comes in `Callback`, `EV_READY`.
pub fn create(parent: isize, data: &str, cb: Callback, user: *mut c_void) -> Option<Box<Web>> {
    unsafe {
        let _ = CoInitializeEx(None, COINIT_APARTMENTTHREADED);
    }
    let inner = Rc::new(RefCell::new(Inner { controller: None, view: None, bounds: RECT::default(), visible: false, pending: None, closed: false }));
    let sink = Sink { cb, user };
    let held = inner.clone();
    let hwnd = HWND(parent as *mut c_void);
    let folder = HSTRING::from(data);
    let handler = CreateCoreWebView2EnvironmentCompletedHandler::create(Box::new(move |result, env| {
        if held.borrow().closed {
            return Ok(());
        }
        let env = match (result, env) {
            (Ok(()), Some(env)) => env,
            (r, _) => {
                sink.send(EV_FAILED, 0, format!("{:?}", r.err()).as_bytes());
                return Ok(());
            }
        };
        let inner = held.clone();
        let made_handler = CreateCoreWebView2ControllerCompletedHandler::create(Box::new(move |result, controller| {
            let closed = inner.borrow().closed;
            match (result, controller) {
                (Ok(()), Some(c)) => {
                    if let Err(e) = made(&inner, c, sink) {
                        sink.send(EV_FAILED, 0, format!("{e:?}").as_bytes());
                    }
                }
                (r, _) if !closed => sink.send(EV_FAILED, 0, format!("{:?}", r.err()).as_bytes()),
                _ => {}
            }
            Ok(())
        }));
        unsafe { env.CreateCoreWebView2Controller(hwnd, &made_handler) }
    }));
    let r = unsafe { CreateCoreWebView2EnvironmentWithOptions(PCWSTR::null(), &folder, None, &handler) };
    if r.is_err() {
        return None;
    }
    Some(Box::new(Web { inner, cb, user }))
}

impl Web {
    fn sink(&self) -> Sink {
        Sink { cb: self.cb, user: self.user }
    }

    pub fn place(&self, x: i32, y: i32, w: i32, h: i32, visible: bool) {
        let mut i = self.inner.borrow_mut();
        let r = RECT { left: x, top: y, right: x + w, bottom: y + h };
        let moved = i.bounds != r;
        let shown = i.visible != visible;
        i.bounds = r;
        i.visible = visible;
        if let Some(c) = &i.controller {
            unsafe {
                if moved {
                    let _ = c.SetBounds(r);
                }
                if shown {
                    let _ = c.SetIsVisible(visible);
                }
            }
        }
    }

    /// Into another window of the program: a panel in a window of its own, and back.
    pub fn parent(&self, hwnd: isize) {
        let i = self.inner.borrow();
        if let Some(c) = &i.controller {
            unsafe {
                let _ = c.SetParentWindow(HWND(hwnd as *mut c_void));
            }
        }
    }

    pub fn navigate(&self, url: &str) {
        let mut i = self.inner.borrow_mut();
        if let Some(v) = &i.view {
            unsafe {
                let _ = v.Navigate(&HSTRING::from(url));
            }
        } else {
            i.pending = Some(url.to_string());
        }
    }

    /// 0 back, 1 forward, 2 reload, 3 stop, 4 give the page the focus
    pub fn act(&self, what: i32) {
        let i = self.inner.borrow();
        if let (Some(v), Some(c)) = (&i.view, &i.controller) {
            unsafe {
                let _ = match what {
                    0 => v.GoBack(),
                    1 => v.GoForward(),
                    2 => v.Reload(),
                    3 => v.Stop(),
                    _ => c.MoveFocus(COREWEBVIEW2_MOVE_FOCUS_REASON_PROGRAMMATIC),
                };
            }
        }
    }

    /// 0 back, 1 forward
    pub fn can(&self, what: i32) -> bool {
        let i = self.inner.borrow();
        let Some(v) = &i.view else { return false };
        let mut yes = windows::core::BOOL(0);
        let asked = unsafe {
            match what {
                0 => v.CanGoBack(&mut yes),
                _ => v.CanGoForward(&mut yes),
            }
        };
        asked.is_ok() && yes.as_bool()
    }

    pub fn script(&self, code: &str, id: u64) {
        let sink = self.sink();
        let i = self.inner.borrow();
        let Some(v) = &i.view else {
            sink.send(EV_SCRIPT, id, b"null");
            return;
        };
        let handler = ExecuteScriptCompletedHandler::create(Box::new(move |result, json| {
            let text = if result.is_ok() { json } else { "null".to_string() };
            sink.send(EV_SCRIPT, id, text.as_bytes());
            Ok(())
        }));
        unsafe {
            if v.ExecuteScript(&HSTRING::from(code), &handler).is_err() {
                sink.send(EV_SCRIPT, id, b"null");
            }
        }
    }

    pub fn capture(&self, id: u64) {
        let sink = self.sink();
        let i = self.inner.borrow();
        let Some(v) = &i.view else {
            sink.send(EV_CAPTURE, id, &[]);
            return;
        };
        let Some(stream) = (unsafe { SHCreateMemStream(None) }) else {
            sink.send(EV_CAPTURE, id, &[]);
            return;
        };
        let held: IStream = stream.clone();
        let handler = CapturePreviewCompletedHandler::create(Box::new(move |result| {
            let mut data = Vec::new();
            if result.is_ok() {
                unsafe {
                    let _ = held.Seek(0, STREAM_SEEK_SET, None);
                    let mut chunk = [0u8; 65536];
                    loop {
                        let mut n = 0u32;
                        let r = held.Read(chunk.as_mut_ptr() as *mut c_void, chunk.len() as u32, Some(&mut n));
                        if r.is_err() || n == 0 {
                            break;
                        }
                        data.extend_from_slice(&chunk[..n as usize]);
                    }
                }
            }
            sink.send(EV_CAPTURE, id, &data);
            Ok(())
        }));
        unsafe {
            if v.CapturePreview(COREWEBVIEW2_CAPTURE_PREVIEW_IMAGE_FORMAT_PNG, &stream, &handler).is_err() {
                sink.send(EV_CAPTURE, id, &[]);
            }
        }
    }

    pub fn close(&self) {
        let mut i = self.inner.borrow_mut();
        i.closed = true;
        if let Some(c) = i.controller.take() {
            unsafe {
                let _ = c.Close();
            }
        }
        i.view = None;
    }
}
