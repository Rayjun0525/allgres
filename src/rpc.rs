//! The dashboard-facing RPC unix socket the runtime worker listens on,
//! and the uuid shape check every claimed call_id is validated against
//! before it reaches a `::uuid` cast.

use crate::runtime_worker::dashboard_rpc;
use crate::MAX_REQUEST_BYTES;
use serde_json::{json, Value};
use std::io::{Read, Write};
use std::os::unix::net::UnixStream;
use std::time::Duration;

pub(crate) fn valid_uuid(s: &str) -> bool {
    s.len() == 36
        && s.as_bytes().iter().enumerate().all(|(i, b)| match i {
            8 | 13 | 18 | 23 => *b == b'-',
            _ => b.is_ascii_hexdigit(),
        })
}

pub(crate) fn handle_rpc_stream(mut stream: UnixStream, ready: bool) {
    let _ = stream.set_read_timeout(Some(Duration::from_secs(2)));
    let _ = stream.set_write_timeout(Some(Duration::from_secs(2)));

    let mut body = Vec::new();
    // UnixStream is both Read and Write, so by_ref needs disambiguating.
    let mut limited = std::io::Read::by_ref(&mut stream).take(MAX_REQUEST_BYTES as u64);
    if limited.read_to_end(&mut body).is_err() {
        let _ = stream.write_all(json!({"ok": false, "error": "rpc_read_failed"}).to_string().as_bytes());
        return;
    }

    let reply = match std::str::from_utf8(&body) {
        // Reject malformed JSON here rather than letting a ::jsonb cast abort
        // the transaction inside Postgres.
        Ok(text) if serde_json::from_str::<Value>(text).is_ok() => {
            if ready {
                dashboard_rpc(text)
            } else {
                json!({"ok": false, "error": "extension_not_installed"}).to_string()
            }
        }
        _ => json!({"ok": false, "error": "invalid_json_request"}).to_string(),
    };

    let _ = stream.write_all(reply.as_bytes());
    let _ = stream.flush();
}
