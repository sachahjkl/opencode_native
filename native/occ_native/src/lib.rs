//! HTTP for the opencode client, as C functions.
//!
//! * `occ_client_new` makes a client for one server (base URL, Basic credentials); it is shared by every thread.
//! * `occ_request` makes one request and returns the status and the whole body.
//! * `occ_sse_open` / `occ_sse_next` / `occ_sse_free` read a server-sent event stream, one event's data per call.
//!
//! Bytes cross as (pointer, length) pairs; a body handed out is an `OccBuf` the caller gives back to `occ_buf_free`.
//! No call unwinds into the caller: a panic is caught and reported as a transport failure.

use std::io::{BufRead, BufReader, Read};
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::time::Duration;

use base64::Engine;
use ureq::Agent;

// Linux: the toolkit's text backend lives in this library (its exported gt_* functions are what font/backend_native.odin calls)
#[cfg(target_os = "linux")]
pub extern crate gt_text;

pub struct Client {
    base: String,
    auth: Option<String>,
    agent: Agent,  // requests: bounded in time
    stream: Agent, // event streams: no limit on the body, a limit on silence
}

pub struct Sse {
    reader: BufReader<Box<dyn Read + Send>>,
    line: Vec<u8>,
}

#[repr(C)]
pub struct OccBuf {
    pub ptr: *mut u8,
    pub len: usize,
    pub cap: usize,
}

impl OccBuf {
    fn from_vec(mut v: Vec<u8>) -> OccBuf {
        let b = OccBuf { ptr: v.as_mut_ptr(), len: v.len(), cap: v.capacity() };
        std::mem::forget(v);
        b
    }
    fn empty() -> OccBuf {
        OccBuf { ptr: std::ptr::null_mut(), len: 0, cap: 0 }
    }
}

unsafe fn text<'a>(p: *const u8, n: usize) -> &'a str {
    if p.is_null() || n == 0 {
        return "";
    }
    std::str::from_utf8(std::slice::from_raw_parts(p, n)).unwrap_or("")
}

unsafe fn bytes<'a>(p: *const u8, n: usize) -> &'a [u8] {
    if p.is_null() || n == 0 {
        return &[];
    }
    std::slice::from_raw_parts(p, n)
}

/// An event stream silent this long is taken for dead: a machine that slept, a network that went away without a word leave the
/// socket open, and only the server's heartbeats tell it from a quiet server. Several of them may be missed. (Any bytes count,
/// heartbeats are comments or events.)
const STREAM_IDLE: Duration = Duration::from_secs(95);

/// `per_read`: the longest wait for bytes, in the middle of a body too.
fn agent(body_limit: Option<Duration>, per_read: Option<Duration>) -> Agent {
    let tls = ureq::tls::TlsConfig::builder().root_certs(ureq::tls::RootCerts::PlatformVerifier).build();
    Agent::config_builder()
        .http_status_as_error(false)
        .timeout_connect(Some(Duration::from_secs(5)))
        .timeout_recv_response(Some(Duration::from_secs(60)))
        .timeout_recv_body(body_limit)
        .timeout_per_read(per_read)
        .tls_config(tls)
        .user_agent("opencode-native/0.1")
        .build()
        .into()
}

/// A client for `base` ("http://127.0.0.1:4096"); with a password, every request carries Basic credentials.
#[no_mangle]
pub unsafe extern "C" fn occ_client_new(base: *const u8, base_len: usize, user: *const u8, user_len: usize, pass: *const u8, pass_len: usize) -> *mut Client {
    catch_unwind(|| {
        let pass = text(pass, pass_len);
        let auth = if pass.is_empty() {
            None
        } else {
            let creds = format!("{}:{}", text(user, user_len), pass);
            Some(format!("Basic {}", base64::engine::general_purpose::STANDARD.encode(creds)))
        };
        Box::into_raw(Box::new(Client {
            base: text(base, base_len).trim_end_matches('/').to_string(),
            auth,
            agent: agent(Some(Duration::from_secs(120)), None),
            stream: agent(None, Some(STREAM_IDLE)),
        }))
    })
    .unwrap_or(std::ptr::null_mut())
}

#[no_mangle]
pub unsafe extern "C" fn occ_client_free(c: *mut Client) {
    if !c.is_null() {
        drop(Box::from_raw(c));
    }
}

#[no_mangle]
pub unsafe extern "C" fn occ_buf_free(b: OccBuf) {
    if !b.ptr.is_null() {
        drop(Vec::from_raw_parts(b.ptr, b.len, b.cap));
    }
}

fn send(c: &Client, agent: &Agent, method: &str, path: &str, body: &[u8], accept: &str) -> Result<ureq::http::Response<ureq::Body>, ureq::Error> {
    let url = format!("{}{}", c.base, path);
    let mut req = ureq::http::Request::builder().method(method).uri(&url).header("Accept", accept);
    if let Some(a) = &c.auth {
        req = req.header("Authorization", a.as_str());
    }
    if !body.is_empty() || matches!(method, "POST" | "PUT" | "PATCH") {
        req = req.header("Content-Type", "application/json");
    }
    let req = req.body(body.to_vec()).map_err(|e| ureq::Error::BadUri(e.to_string()))?;
    agent.run(req)
}

/// One request. Returns 0 with the status and the body, or -1 when the server could not be reached (`out_body` then
/// holds the reason, as text).
#[no_mangle]
pub unsafe extern "C" fn occ_request(
    c: *const Client,
    method: *const u8,
    method_len: usize,
    path: *const u8,
    path_len: usize,
    body: *const u8,
    body_len: usize,
    out_status: *mut i32,
    out_body: *mut OccBuf,
) -> i32 {
    *out_status = 0;
    *out_body = OccBuf::empty();
    if c.is_null() {
        return -1;
    }
    let r = catch_unwind(AssertUnwindSafe(|| {
        let c = &*c;
        let resp = send(c, &c.agent, text(method, method_len), text(path, path_len), bytes(body, body_len), "application/json")?;
        let status = resp.status().as_u16() as i32;
        let data = resp.into_body().with_config().limit(256 * 1024 * 1024).read_to_vec()?;
        Ok::<_, ureq::Error>((status, data))
    }));
    match r {
        Ok(Ok((status, data))) => {
            *out_status = status;
            *out_body = OccBuf::from_vec(data);
            0
        }
        Ok(Err(e)) => {
            *out_body = OccBuf::from_vec(e.to_string().into_bytes());
            -1
        }
        Err(_) => {
            *out_body = OccBuf::from_vec(b"internal error (panic)".to_vec());
            -1
        }
    }
}

/// Opens an event stream. Returns it (status 200), or null with the status (0: unreachable).
#[no_mangle]
pub unsafe extern "C" fn occ_sse_open(c: *const Client, path: *const u8, path_len: usize, out_status: *mut i32) -> *mut Sse {
    *out_status = 0;
    if c.is_null() {
        return std::ptr::null_mut();
    }
    let r = catch_unwind(AssertUnwindSafe(|| {
        let c = &*c;
        let resp = send(c, &c.stream, "GET", text(path, path_len), &[], "text/event-stream").ok()?;
        let status = resp.status().as_u16() as i32;
        *out_status = status;
        if status != 200 {
            return None;
        }
        let reader: Box<dyn Read + Send> = Box::new(resp.into_body().into_reader());
        Some(Box::into_raw(Box::new(Sse { reader: BufReader::with_capacity(64 * 1024, reader), line: Vec::with_capacity(1024) })))
    }));
    match r {
        Ok(Some(p)) => p,
        _ => std::ptr::null_mut(),
    }
}

/// The data of the next event (its `data:` lines joined by "\n"). Returns 1 with an event, 0 at the end of the stream,
/// -1 on an error, silence past STREAM_IDLE among them. Blocks until an event comes; comments (heartbeats) are skipped, and count
/// as life.
#[no_mangle]
pub unsafe extern "C" fn occ_sse_next(s: *mut Sse, out: *mut OccBuf) -> i32 {
    *out = OccBuf::empty();
    if s.is_null() {
        return -1;
    }
    let r = catch_unwind(AssertUnwindSafe(|| {
        let s = &mut *s;
        let mut data: Vec<u8> = Vec::new();
        let mut any = false;
        loop {
            s.line.clear();
            if s.reader.read_until(b'\n', &mut s.line)? == 0 {
                return Ok::<_, std::io::Error>(None);
            }
            let mut l: &[u8] = &s.line;
            while let [rest @ .., b'\n' | b'\r'] = l {
                l = rest;
            }
            if l.is_empty() {
                if any {
                    return Ok(Some(data));
                }
                continue;
            }
            if let Some(v) = l.strip_prefix(b"data:") {
                let v = v.strip_prefix(b" ").unwrap_or(v);
                if any {
                    data.push(b'\n');
                }
                data.extend_from_slice(v);
                any = true;
            }
        }
    }));
    match r {
        Ok(Ok(Some(d))) => {
            *out = OccBuf::from_vec(d);
            1
        }
        Ok(Ok(None)) => 0,
        _ => -1,
    }
}

/// Decodes an image (PNG, JPEG, WebP, GIF, BMP), given as its bytes, as base64 text (`base64` = 1), or as a data URL
/// ("data:image/png;base64,..."; `base64` = 2), scaled down to fit `max_dim` x `max_dim` when larger. Returns 0 with
/// straight-alpha RGBA8 pixels in `out` (w x h, tight rows), or -1 (`out` then holds the reason).
#[no_mangle]
pub unsafe extern "C" fn occ_image_decode(data: *const u8, len: usize, base64: i32, max_dim: u32, out_w: *mut u32, out_h: *mut u32, out: *mut OccBuf) -> i32 {
    *out_w = 0;
    *out_h = 0;
    *out = OccBuf::empty();
    let r = catch_unwind(AssertUnwindSafe(|| -> Result<(u32, u32, Vec<u8>), String> {
        let input = bytes(data, len);
        let owned;
        let raw: &[u8] = match base64 {
            0 => input,
            _ => {
                let mut text = input;
                if base64 == 2 {
                    let comma = text.iter().position(|&c| c == b',').ok_or("not a data URL")?;
                    text = &text[comma + 1..];
                }
                let clean: Vec<u8> = text.iter().copied().filter(|c| !c.is_ascii_whitespace()).collect();
                owned = base64::engine::general_purpose::STANDARD.decode(&clean).map_err(|e| e.to_string())?;
                &owned
            }
        };
        let img = image::load_from_memory(raw).map_err(|e| e.to_string())?;
        let img = if max_dim > 0 && (img.width() > max_dim || img.height() > max_dim) {
            img.resize(max_dim, max_dim, image::imageops::FilterType::Triangle)
        } else {
            img
        };
        let rgba = img.into_rgba8();
        Ok((rgba.width(), rgba.height(), rgba.into_raw()))
    }));
    match r {
        Ok(Ok((w, h, px))) => {
            *out_w = w;
            *out_h = h;
            *out = OccBuf::from_vec(px);
            0
        }
        Ok(Err(e)) => {
            *out = OccBuf::from_vec(e.into_bytes());
            -1
        }
        Err(_) => {
            *out = OccBuf::from_vec(b"internal error (panic)".to_vec());
            -1
        }
    }
}

#[no_mangle]
pub unsafe extern "C" fn occ_sse_free(s: *mut Sse) {
    if !s.is_null() {
        drop(Box::from_raw(s));
    }
}

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
    pub unsafe extern "C" fn occ_webview_new(parent: isize, data: *const u8, data_len: usize, cb: Callback, user: *mut c_void) -> *mut Web {
        catch_unwind(AssertUnwindSafe(|| match webview::create(parent, text(data, data_len), cb, user) {
            Some(w) => Box::into_raw(w),
            None => std::ptr::null_mut(),
        })).unwrap_or(std::ptr::null_mut())
    }

    #[no_mangle]
    pub unsafe extern "C" fn occ_webview_parent(w: *const Web, hwnd: isize) {
        if !w.is_null() {
            (*w).parent(hwnd);
        }
    }

    #[no_mangle]
    pub unsafe extern "C" fn occ_webview_place(w: *const Web, x: i32, y: i32, width: i32, height: i32, visible: i32) {
        if let Some(w) = w.as_ref() { let _ = catch_unwind(AssertUnwindSafe(|| w.place(x, y, width, height, visible != 0))); }
    }

    #[no_mangle]
    pub unsafe extern "C" fn occ_webview_navigate(w: *const Web, url: *const u8, len: usize) {
        if let Some(w) = w.as_ref() { let _ = catch_unwind(AssertUnwindSafe(|| w.navigate(text(url, len)))); }
    }

    #[no_mangle]
    pub unsafe extern "C" fn occ_webview_act(w: *const Web, what: i32) {
        if let Some(w) = w.as_ref() { let _ = catch_unwind(AssertUnwindSafe(|| w.act(what))); }
    }

    #[no_mangle]
    pub unsafe extern "C" fn occ_webview_script(w: *const Web, code: *const u8, len: usize, id: u64) {
        if let Some(w) = w.as_ref() { let _ = catch_unwind(AssertUnwindSafe(|| w.script(text(code, len), id))); }
    }

    #[no_mangle]
    pub unsafe extern "C" fn occ_webview_capture(w: *const Web, id: u64) {
        if let Some(w) = w.as_ref() { let _ = catch_unwind(AssertUnwindSafe(|| w.capture(id))); }
    }

    /// 0 back, 1 forward: whether the page has a place to go. (No view: none.)
    #[no_mangle]
    pub unsafe extern "C" fn occ_webview_can(w: *const Web, what: i32) -> i32 {
        match w.as_ref() {
            Some(w) => catch_unwind(AssertUnwindSafe(|| w.can(what))).unwrap_or(false) as i32,
            None => 0,
        }
    }

    #[no_mangle]
    pub unsafe extern "C" fn occ_webview_free(w: *mut Web) {
        if !w.is_null() {
            let b = Box::from_raw(w);
            b.close();
        }
    }
}

////////////////////////////////
// A WebSocket to the server: the client hosts its browser tools on it (client-mcp). One thread reads, others may send.

pub struct Ws {
    sock: std::sync::Mutex<tungstenite::WebSocket<tungstenite::stream::MaybeTlsStream<std::net::TcpStream>>>,
}

fn ws_connect(c: &Client, path: &str) -> Option<Ws> {
    use tungstenite::client::IntoClientRequest;
    use tungstenite::stream::MaybeTlsStream;
    let url = format!("{}{}", c.base.replacen("http", "ws", 1), path);
    let mut req = url.into_client_request().ok()?;
    if let Some(a) = &c.auth {
        req.headers_mut().insert("Authorization", a.parse().ok()?);
    }
    let (sock, _) = tungstenite::connect(req).ok()?;
    // (a read gives way often: a thread that sends takes the same lock)
    let limit = Some(Duration::from_millis(50));
    match sock.get_ref() {
        MaybeTlsStream::Plain(s) => { s.set_read_timeout(limit).ok()?; }
        MaybeTlsStream::Rustls(s) => { s.get_ref().set_read_timeout(limit).ok()?; }
        _ => {}
    }
    Some(Ws { sock: std::sync::Mutex::new(sock) })
}

/// `path` on the client's server; null: no connection.
#[no_mangle]
pub unsafe extern "C" fn occ_ws_open(c: *const Client, path: *const u8, path_len: usize) -> *mut Ws {
    let Some(c) = c.as_ref() else { return std::ptr::null_mut() };
    catch_unwind(AssertUnwindSafe(|| match ws_connect(c, text(path, path_len)) {
        Some(w) => Box::into_raw(Box::new(w)),
        None => std::ptr::null_mut(),
    }))
    .unwrap_or(std::ptr::null_mut())
}

/// The next message, text or binary: 1 one is in `out`, 0 none for now (ask again), -1 the connection ended.
#[no_mangle]
pub unsafe extern "C" fn occ_ws_read(w: *const Ws, out: *mut OccBuf) -> i32 {
    use std::io::ErrorKind;
    use tungstenite::{Error, Message};
    let Some(w) = w.as_ref() else { return -1 };
    catch_unwind(AssertUnwindSafe(|| {
        let mut s = match w.sock.lock() { Ok(s) => s, Err(_) => return -1 };
        match s.read() {
            Ok(Message::Text(t)) => {
                *out = OccBuf::from_vec(t.as_bytes().to_vec());
                1
            }
            Ok(Message::Binary(b)) => {
                *out = OccBuf::from_vec(b.to_vec());
                1
            }
            Ok(Message::Close(_)) => -1,
            Ok(_) => 0,
            Err(Error::Io(e)) if matches!(e.kind(), ErrorKind::WouldBlock | ErrorKind::TimedOut) => 0,
            Err(_) => -1,
        }
    }))
    .unwrap_or(-1)
}

#[no_mangle]
pub unsafe extern "C" fn occ_ws_send(w: *const Ws, data: *const u8, len: usize) -> i32 {
    use tungstenite::Message;
    let Some(w) = w.as_ref() else { return -1 };
    catch_unwind(AssertUnwindSafe(|| {
        let mut s = match w.sock.lock() { Ok(s) => s, Err(_) => return -1 };
        if s.send(Message::text(text(data, len).to_string())).is_ok() { 0 } else { -1 }
    }))
    .unwrap_or(-1)
}

/// How long a read waits, in ms: what also bounds the wait of what is to be sent by the thread that reads.
#[no_mangle]
pub unsafe extern "C" fn occ_ws_read_timeout(w: *const Ws, ms: u32) {
    use tungstenite::stream::MaybeTlsStream;
    let Some(w) = w.as_ref() else { return };
    let _ = catch_unwind(AssertUnwindSafe(|| {
        let Ok(s) = w.sock.lock() else { return };
        let limit = Some(Duration::from_millis(ms as u64));
        match s.get_ref() {
            MaybeTlsStream::Plain(s) => { let _ = s.set_read_timeout(limit); }
            MaybeTlsStream::Rustls(s) => { let _ = s.get_ref().set_read_timeout(limit); }
            _ => {}
        }
    }));
}

#[no_mangle]
pub unsafe extern "C" fn occ_ws_free(w: *mut Ws) {
    if !w.is_null() {
        let b = Box::from_raw(w);
        if let Ok(mut s) = b.sock.lock() {
            let _ = s.close(None);
        };
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;
    use std::net::TcpListener;

    // What the socket gives, read after read: no socket, no clock, a failure is there the moment it is asked for.
    struct Script(std::collections::VecDeque<std::io::Result<&'static [u8]>>);

    impl Read for Script {
        fn read(&mut self, buf: &mut [u8]) -> std::io::Result<usize> {
            match self.0.pop_front() {
                Some(Ok(b)) => {
                    buf[..b.len()].copy_from_slice(b);
                    Ok(b.len())
                }
                Some(Err(e)) => Err(e),
                None => Ok(0),
            }
        }
    }

    fn scripted(steps: Vec<std::io::Result<&'static [u8]>>) -> Sse {
        let reader: Box<dyn Read + Send> = Box::new(Script(steps.into()));
        Sse { reader: BufReader::new(reader), line: Vec::new() }
    }

    fn next(s: &mut Sse) -> (i32, Vec<u8>) {
        unsafe {
            let mut out = OccBuf::empty();
            let got = occ_sse_next(s, &mut out);
            let data = bytes(out.ptr, out.len).to_vec();
            occ_buf_free(out);
            (got, data)
        }
    }

    #[test]
    fn a_silent_stream_ends() {
        let silence = std::io::Error::from(std::io::ErrorKind::TimedOut); // what a read past the limit gives
        let mut s = scripted(vec![Ok(b"data: one\n\n"), Ok(b": beat\n\n"), Ok(b"data: two\n\n"), Err(silence)]);
        assert_eq!(next(&mut s), (1, b"one".to_vec()));
        assert_eq!(next(&mut s), (1, b"two".to_vec()), "a heartbeat is skipped");
        assert_eq!(next(&mut s).0, -1, "silence ends it");
    }

    #[test]
    fn a_stream_cut_inside_an_event_gives_nothing_of_it() {
        let cut = std::io::Error::from(std::io::ErrorKind::ConnectionReset);
        let mut s = scripted(vec![Ok(b"data: ha"), Err(cut)]);
        assert_eq!(next(&mut s), (-1, Vec::new()));
    }

    #[test]
    fn a_stream_the_server_closes_ends_without_an_error() {
        let mut s = scripted(vec![Ok(b"data: one\n\n")]);
        assert_eq!(next(&mut s), (1, b"one".to_vec()));
        assert_eq!(next(&mut s).0, 0);
    }

    // Without this limit on the stream's reads, nothing ever comes to say a dead link is dead.
    #[test]
    fn the_stream_of_a_client_has_the_limit() {
        unsafe {
            let base = "http://127.0.0.1:1";
            let c = occ_client_new(base.as_ptr(), base.len(), std::ptr::null(), 0, std::ptr::null(), 0);
            assert_eq!((*c).stream.config().timeout_per_read(), Some(STREAM_IDLE));
            drop(Box::from_raw(c));
        }
    }

    #[test]
    fn a_refused_stream_says_its_status() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();
        let server = std::thread::spawn(move || {
            let (mut s, _) = listener.accept().unwrap();
            let mut head = [0u8; 2048];
            let _ = s.read(&mut head);
            s.write_all(b"HTTP/1.1 401 Unauthorized\r\nContent-Length: 0\r\n\r\n").unwrap();
        });
        let c = Client { base: format!("http://127.0.0.1:{}", port), auth: None, agent: agent(None, None), stream: agent(None, None) };
        unsafe {
            let path = "/api/event";
            let mut status = 0;
            assert!(occ_sse_open(&c, path.as_ptr(), path.len(), &mut status).is_null());
            assert_eq!(status, 401);
        }
        server.join().unwrap();
    }
}
