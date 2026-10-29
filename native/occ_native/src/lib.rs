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

pub struct Client {
    base: String,
    auth: Option<String>,
    agent: Agent,  // requests: bounded in time
    stream: Agent, // event streams: no limit on the body
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

fn agent(body_limit: Option<Duration>) -> Agent {
    let tls = ureq::tls::TlsConfig::builder().root_certs(ureq::tls::RootCerts::PlatformVerifier).build();
    Agent::config_builder()
        .http_status_as_error(false)
        .timeout_connect(Some(Duration::from_secs(5)))
        .timeout_recv_response(Some(Duration::from_secs(60)))
        .timeout_recv_body(body_limit)
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
            agent: agent(Some(Duration::from_secs(120))),
            stream: agent(None),
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
/// -1 on an error. Blocks until an event comes; comments (heartbeats) are skipped.
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
