//! Minimal hand-rolled HTTP/1.1 request parsing for the `allgres web`
//! worker's own listener -- no external HTTP-server crate, since this
//! only ever needs to read one request off a connection this process
//! already accepted.

use crate::{MAX_REQUEST_BYTES, REQUEST_DEADLINE};
use std::collections::HashMap;
use std::io::Read;
use std::net::TcpStream;
use std::time::{Duration, Instant};

pub(crate) struct HttpRequest {
    pub(crate) method: String,
    pub(crate) path: String,
    pub(crate) headers: Vec<(String, String)>,
    pub(crate) body: String,
}

impl HttpRequest {
    pub(crate) fn route(&self) -> &str {
        self.path.split('?').next().unwrap_or(&self.path)
    }

    pub(crate) fn query(&self) -> &str {
        self.path.split_once('?').map(|(_, q)| q).unwrap_or("")
    }

    pub(crate) fn header(&self, name: &str) -> Option<&str> {
        self.headers
            .iter()
            .find(|(k, _)| k.eq_ignore_ascii_case(name))
            .map(|(_, v)| v.as_str())
    }
}

pub(crate) fn parse_http_request(data: &[u8]) -> Option<HttpRequest> {
    let split = data.windows(4).position(|w| w == b"\r\n\r\n")? + 4;
    let head = String::from_utf8_lossy(&data[..split]);
    let mut lines = head.lines();

    let mut first = lines.next()?.split_whitespace();
    let method = first.next()?.to_string();
    let path = first.next()?.to_string();

    let headers: Vec<(String, String)> = lines
        .filter_map(|l| l.split_once(':').map(|(k, v)| (k.trim().to_ascii_lowercase(), v.trim().to_string())))
        .collect();

    let body = String::from_utf8_lossy(&data[split..]).to_string();
    Some(HttpRequest { method, path, headers, body })
}

fn content_length(data: &[u8], header_end: usize) -> usize {
    let head = String::from_utf8_lossy(&data[..header_end]);
    for line in head.lines() {
        if let Some((k, v)) = line.split_once(':') {
            if k.eq_ignore_ascii_case("content-length") {
                return v.trim().parse().unwrap_or(0);
            }
        }
    }
    0
}

/// Decodes one application/x-www-form-urlencoded body into a map -- only
/// used by the /mock/oauth/token test double above, to read back what
/// send_form actually put on the wire.
pub(crate) fn parse_form_body(body: &str) -> HashMap<String, String> {
    fn decode(s: &str) -> String {
        let bytes = s.as_bytes();
        let mut out = Vec::with_capacity(bytes.len());
        let mut i = 0;
        while i < bytes.len() {
            match bytes[i] {
                b'+' => {
                    out.push(b' ');
                    i += 1;
                }
                b'%' if i + 2 < bytes.len() => {
                    let hex = std::str::from_utf8(&bytes[i + 1..i + 3]).ok();
                    match hex.and_then(|h| u8::from_str_radix(h, 16).ok()) {
                        Some(b) => {
                            out.push(b);
                            i += 3;
                        }
                        None => {
                            out.push(bytes[i]);
                            i += 1;
                        }
                    }
                }
                b => {
                    out.push(b);
                    i += 1;
                }
            }
        }
        String::from_utf8_lossy(&out).into_owned()
    }
    body.split('&')
        .filter_map(|pair| pair.split_once('='))
        .map(|(k, v)| (decode(k), decode(v)))
        .collect()
}

pub(crate) fn read_http_request(stream: &mut TcpStream) -> Option<HttpRequest> {
    let _ = stream.set_read_timeout(Some(Duration::from_secs(2)));
    let deadline = Instant::now() + REQUEST_DEADLINE;

    let mut data = Vec::<u8>::new();
    let mut buf = [0u8; 8192];
    let mut header_end: Option<usize> = None;
    let mut want = 0usize;

    loop {
        // A client that dribbles bytes forever holds one pool thread, not the
        // accept loop, and only until this deadline.
        if Instant::now() > deadline {
            return None;
        }
        let n = stream.read(&mut buf).ok()?;
        if n == 0 {
            break;
        }
        data.extend_from_slice(&buf[..n]);
        if data.len() > MAX_REQUEST_BYTES {
            return None;
        }
        if header_end.is_none() {
            if let Some(p) = data.windows(4).position(|w| w == b"\r\n\r\n") {
                header_end = Some(p + 4);
                want = content_length(&data, p + 4);
            }
        }
        if let Some(h) = header_end {
            if data.len() >= h + want {
                break;
            }
        }
    }

    parse_http_request(&data)
}

