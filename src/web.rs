//! The `allgres web` background worker: an HTTP listener with no SPI
//! access at all (see the crate-level doc comment in lib.rs). Every
//! dashboard/API request is forwarded to the `allgres runtime` worker
//! over the unix socket in `crate::config`/`crate::rpc`; one thread per
//! connection, bounded, so a slow client cannot stall the accept loop.

use crate::config::{configured_http_addr, rpc_socket_path};
use crate::http_protocol::{parse_form_body, read_http_request, HttpRequest};
use crate::{DASHBOARD_HTML, MAX_WEB_THREADS, SSE_INTERVAL, SSE_TICKET_TTL, SSE_TOTAL};
use pgrx::bgworkers::{BackgroundWorker, SignalWakeFlags};
use pgrx::prelude::*;
use serde_json::{json, Value};
use std::collections::HashMap;
use std::fs;
use std::io::{Read, Write};
use std::net::{IpAddr, Shutdown, TcpListener, TcpStream};
use std::os::unix::net::UnixStream;
use std::path::PathBuf;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, LazyLock, Mutex};
use std::time::{Duration, Instant};

// ---------------------------------------------------------------------------
// Web worker
// ---------------------------------------------------------------------------

#[derive(Clone)]
pub(crate) struct WebConfig {
    pub(crate) token: String,
    pub(crate) socket: PathBuf,
    pub(crate) mock_enabled: bool,
}

static WEB_THREADS: AtomicUsize = AtomicUsize::new(0);

pub(crate) static SSE_TICKETS: LazyLock<Mutex<HashMap<String, Instant>>> =
    LazyLock::new(|| Mutex::new(HashMap::new()));

/// Mints a fresh single-use SSE ticket, sweeping expired ones first so this
/// map cannot grow without bound from tickets nobody ever redeemed.
pub(crate) fn mint_sse_ticket() -> String {
    let ticket = nonce();
    let now = Instant::now();
    let mut tickets = SSE_TICKETS.lock().unwrap();
    tickets.retain(|_, issued| now.duration_since(*issued) < SSE_TICKET_TTL);
    tickets.insert(ticket.clone(), now);
    ticket
}

/// Consumes a ticket if it exists and has not expired -- removing it either
/// way, so the same ticket can never authorize a second connection.
pub(crate) fn consume_sse_ticket(t: &str) -> bool {
    let now = Instant::now();
    let mut tickets = SSE_TICKETS.lock().unwrap();
    tickets.retain(|_, issued| now.duration_since(*issued) < SSE_TICKET_TTL);
    tickets.remove(t).is_some()
}

/// Per-IP request accounting for `rate_limited`.  Two independent windows:
/// `general` (every request) and `auth_fail` (only 401 responses, a much
/// tighter cap) so one slow analyst tab can never itself trip the lockout
/// meant for a token-guessing script.  IPs are swept lazily, on the same
/// call that would insert a new one, rather than on a timer -- there is no
/// background thread appropriate to own that here.
pub(crate) struct RateWindows {
    pub(crate) general: HashMap<IpAddr, Vec<Instant>>,
    pub(crate) auth_fail: HashMap<IpAddr, Vec<Instant>>,
}
pub(crate) static RATE_LIMIT: LazyLock<Mutex<RateWindows>> = LazyLock::new(|| {
    Mutex::new(RateWindows { general: HashMap::new(), auth_fail: HashMap::new() })
});
pub(crate) const RATE_GENERAL_LIMIT: usize = 120;
pub(crate) const RATE_GENERAL_WINDOW: Duration = Duration::from_secs(60);
pub(crate) const RATE_AUTH_FAIL_LIMIT: usize = 20;
const RATE_AUTH_FAIL_WINDOW: Duration = Duration::from_secs(300);

/// Records one hit against `ip` in `window` (via `pick`) and reports whether
/// it is still under `limit` -- sliding window, not a fixed bucket: entries
/// older than the window are dropped before counting, on every call, so a
/// burst right at a window boundary cannot double an attacker's effective
/// budget the way a fixed-bucket reset would.
fn rate_check(
    map: &mut HashMap<IpAddr, Vec<Instant>>,
    ip: IpAddr,
    window: Duration,
    limit: usize,
) -> bool {
    let now = Instant::now();
    let hits = map.entry(ip).or_default();
    hits.retain(|t| now.duration_since(*t) < window);
    if hits.len() >= limit {
        return false;
    }
    hits.push(now);
    // An IP with no recent hits after the retain above is dead weight; drop
    // it here rather than in a separate sweep pass so the map never holds
    // more live entries than there are IPs that have hit it inside the
    // window right now.
    map.retain(|_, v| !v.is_empty());
    true
}

/// `false` means "reject with 429" -- called once per request, before auth,
/// for the general cap; `record_auth_failure` is called separately, only
/// after a 401, for the tighter one.
pub(crate) fn rate_limited(ip: IpAddr) -> bool {
    let mut w = RATE_LIMIT.lock().unwrap();
    !rate_check(&mut w.general, ip, RATE_GENERAL_WINDOW, RATE_GENERAL_LIMIT)
}

pub(crate) fn auth_failures_exceeded(ip: IpAddr) -> bool {
    let mut w = RATE_LIMIT.lock().unwrap();
    let hits = w.auth_fail.entry(ip).or_default();
    let now = Instant::now();
    hits.retain(|t| now.duration_since(*t) < RATE_AUTH_FAIL_WINDOW);
    hits.len() >= RATE_AUTH_FAIL_LIMIT
}

pub(crate) fn record_auth_failure(ip: IpAddr) {
    let mut w = RATE_LIMIT.lock().unwrap();
    w.auth_fail.entry(ip).or_default().push(Instant::now());
}

pub(crate) fn constant_time_eq(a: &[u8], b: &[u8]) -> bool {
    if a.len() != b.len() {
        return false;
    }
    let mut diff = 0u8;
    for (x, y) in a.iter().zip(b.iter()) {
        diff |= x ^ y;
    }
    diff == 0
}

pub(crate) fn percent_decode(s: &str) -> String {
    let bytes = s.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        match bytes[i] {
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
            b'+' => {
                out.push(b' ');
                i += 1;
            }
            b => {
                out.push(b);
                i += 1;
            }
        }
    }
    String::from_utf8_lossy(&out).into_owned()
}

fn query_param(query: &str, key: &str) -> Option<String> {
    query
        .split('&')
        .filter_map(|kv| kv.split_once('='))
        .find(|(k, _)| *k == key)
        .map(|(_, v)| percent_decode(v))
}

pub(crate) fn authorized(r: &HttpRequest, cfg: &WebConfig) -> bool {
    if cfg.token.is_empty() {
        return true;
    }
    if let Some(v) = r.header("authorization") {
        if let Some(t) = v.strip_prefix("Bearer ") {
            if constant_time_eq(t.as_bytes(), cfg.token.as_bytes()) {
                return true;
            }
        }
    }
    // EventSource cannot set request headers, so the stream endpoint accepts a
    // short-lived, single-use ticket (see `mint_sse_ticket`/`consume_sse_ticket`)
    // as a query parameter instead of the durable token itself. Minting one
    // still requires the real bearer token, via POST /api/v1/events/ticket,
    // which is not exempted from the check above.
    if r.route() == "/api/v1/events" {
        if let Some(t) = query_param(r.query(), "ticket") {
            return consume_sse_ticket(&t);
        }
    }
    false
}

/// A cross-origin browser request must fail even when no token is configured.
/// Two rules do that: reject a mismatched `Origin`, and require a custom header
/// that a form or `<img>` cannot set (which forces a preflight we never allow).
pub(crate) fn csrf_ok(r: &HttpRequest) -> bool {
    if let Some(origin) = r.header("origin") {
        let host = r.header("host").unwrap_or("");
        let origin_host = origin.split("://").nth(1).unwrap_or("");
        if origin_host.is_empty() || !origin_host.eq_ignore_ascii_case(host) {
            return false;
        }
    }
    // A cross-origin EventSource can never read our response because we emit no
    // CORS headers, and the endpoint has no side effects.
    if r.route() == "/api/v1/events" {
        return true;
    }
    r.header("x-allgres-client").is_some()
}

fn nonce() -> String {
    let mut buf = [0u8; 16];
    let filled = fs::File::open("/dev/urandom")
        .and_then(|mut f| f.read_exact(&mut buf))
        .is_ok();
    if !filled {
        let nanos = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_nanos())
            .unwrap_or(0);
        let pid = std::process::id() as u128;
        let mix = nanos ^ (pid << 64) ^ (&buf as *const _ as u128);
        buf.copy_from_slice(&mix.to_le_bytes());
    }
    buf.iter().map(|b| format!("{b:02x}")).collect()
}

fn security_headers() -> &'static str {
    "X-Content-Type-Options: nosniff\r\n\
     X-Frame-Options: DENY\r\n\
     Referrer-Policy: no-referrer\r\n\
     Cross-Origin-Resource-Policy: same-origin\r\n"
}

fn respond(s: &mut TcpStream, status: &str, content_type: &str, body: &str, extra: &str) {
    let head = format!(
        "HTTP/1.1 {status}\r\n\
         Content-Type: {content_type}\r\n\
         Content-Length: {len}\r\n\
         Cache-Control: no-store\r\n\
         Connection: close\r\n\
         {sec}{extra}\r\n",
        len = body.as_bytes().len(),
        sec = security_headers(),
    );
    let _ = s.write_all(head.as_bytes());
    let _ = s.write_all(body.as_bytes());
    let _ = s.flush();
}

fn respond_json(s: &mut TcpStream, status: &str, body: &str) {
    respond(s, status, "application/json", body, "");
}

fn rpc(cfg: &WebConfig, req: &Value) -> Value {
    let mut stream = match UnixStream::connect(&cfg.socket) {
        Ok(s) => s,
        Err(e) => return json!({"ok": false, "error": format!("runtime unavailable: {e}")}),
    };
    let _ = stream.set_read_timeout(Some(Duration::from_secs(5)));
    let _ = stream.set_write_timeout(Some(Duration::from_secs(5)));

    if stream.write_all(req.to_string().as_bytes()).is_err() {
        return json!({"ok": false, "error": "rpc_write_failed"});
    }
    let _ = stream.shutdown(Shutdown::Write);

    let mut out = String::new();
    if stream.read_to_string(&mut out).is_err() {
        return json!({"ok": false, "error": "rpc_read_failed"});
    }
    serde_json::from_str(&out).unwrap_or_else(|_| json!({"ok": false, "error": "invalid_rpc_response"}))
}

fn body_json(r: &HttpRequest) -> Value {
    serde_json::from_str(&r.body).unwrap_or_else(|_| json!({}))
}

fn api_route(cfg: &WebConfig, r: &HttpRequest) -> Option<Value> {
    let path = r.route();
    match (r.method.as_str(), path) {
        ("GET", "/api/v1/status") => Some(rpc(cfg, &json!({"action": "overview"}))),
        ("GET", "/api/v1/agents") => Some(rpc(cfg, &json!({"action": "agents.list"}))),
        ("POST", "/api/v1/agents") => {
            let mut b = body_json(r);
            b["action"] = json!("agents.create");
            Some(rpc(cfg, &b))
        }
        ("POST", "/api/v1/run") => {
            let mut b = body_json(r);
            b["action"] = json!("run");
            Some(rpc(cfg, &b))
        }
        // Both admin-only monitoring views (dashboard_rpc gates them with
        // require_admin_if_accounts_exist). Unlike the POST-based legacy
        // routes above, a GET here carries no body for the browser to put
        // session_token in -- read from a header instead of a query
        // string, which would otherwise land the token in server access
        // logs, browser history, and the Referer header, the same
        // long-lived-credential-in-a-URL concern /api/v1/events' own
        // ticket system exists to avoid.
        ("GET", "/api/v1/tasks") => Some(rpc(cfg, &json!({
            "action": "tasks.list", "limit": 200,
            "session_token": r.header("x-allgres-session")
        }))),
        ("GET", "/api/v1/logs") => Some(rpc(cfg, &json!({
            "action": "logs.list", "limit": 250,
            "session_token": r.header("x-allgres-session")
        }))),
        ("GET", "/api/v1/settings") => Some(rpc(cfg, &json!({"action": "settings.get"}))),
        ("POST", "/api/v1/selftest") => Some(rpc(cfg, &json!({"action": "selftest"}))),
        ("POST", "/api/v1/settings/provider") => {
            let mut b = body_json(r);
            b["action"] = json!("provider.update");
            Some(rpc(cfg, &b))
        }
        ("PATCH", p) if p.starts_with("/api/v1/agents/") => {
            let mut b = body_json(r);
            b["action"] = json!("agents.update");
            b["agent_id"] = json!(p.trim_start_matches("/api/v1/agents/"));
            Some(rpc(cfg, &b))
        }
        // Generic passthrough: the request body IS the dashboard_rpc request
        // (it just needs an "action" key). allgres.dashboard_rpc is already
        // the actual trust boundary -- it decides what's a valid action, and
        // runs SECURITY DEFINER regardless of how the call reached it -- so a
        // named Rust route per action added nothing but boilerplate that
        // needed a recompile for every new SQL-side capability. The routes
        // above predate this and stay for compatibility; every action added
        // since (projects.*, approvals.*, sessions.*, permissions.*,
        // allowlist.*, policy.history, ...) reaches here instead.
        ("POST", "/api/v1/rpc") => {
            let b = body_json(r);
            if b.get("action").and_then(Value::as_str).is_none() {
                return Some(json!({"ok": false, "error": "action_required"}));
            }
            Some(rpc(cfg, &b))
        }
        _ => None,
    }
}

/// A real event stream: one connection, a snapshot per second, no
/// Content-Length.  The previous version sent a single framed snapshot and
/// closed, which made `retry:` the actual polling mechanism.
fn stream_events(s: &mut TcpStream, cfg: &WebConfig) {
    let head = format!(
        "HTTP/1.1 200 OK\r\n\
         Content-Type: text/event-stream; charset=utf-8\r\n\
         Cache-Control: no-store\r\n\
         Connection: close\r\n\
         X-Accel-Buffering: no\r\n\
         {sec}\r\n",
        sec = security_headers(),
    );
    // No `retry:` field: a single-use ticket cannot authorize the browser's
    // native retry-with-the-same-URL, so reconnection is client-driven
    // instead (`startEvents` in web/index.html mints a fresh ticket and opens
    // a new EventSource on every `error` event).
    let _ = s.set_write_timeout(Some(Duration::from_secs(5)));
    if s.write_all(head.as_bytes()).is_err() {
        return;
    }

    let deadline = Instant::now() + SSE_TOTAL;
    while Instant::now() < deadline {
        let snapshot = rpc(cfg, &json!({"action": "events"}));
        // serde_json never emits a raw newline, so this stays a single SSE frame.
        let frame = format!("event: snapshot\ndata: {snapshot}\n\n");
        if s.write_all(frame.as_bytes()).is_err() || s.flush().is_err() {
            return;
        }
        std::thread::sleep(SSE_INTERVAL);
    }
}

fn handle_web_connection(mut s: TcpStream, cfg: &WebConfig) {
    let peer_ip = s.peer_addr().map(|a| a.ip()).ok();
    if let Some(ip) = peer_ip {
        if rate_limited(ip) {
            respond(&mut s, "429 Too Many Requests", "application/json",
                    "{\"ok\":false,\"error\":\"rate_limited\"}", "Retry-After: 60\r\n");
            return;
        }
    }

    let Some(r) = read_http_request(&mut s) else { return };
    let path = r.route();

    if r.method == "OPTIONS" {
        // No CORS headers, ever: this makes every cross-origin preflight fail.
        respond(&mut s, "405 Method Not Allowed", "application/json",
                "{\"ok\":false,\"error\":\"method_not_allowed\"}", "Allow: GET, POST, PATCH\r\n");
        return;
    }

    if path == "/healthz" {
        respond_json(&mut s, "200 OK", "{\"ok\":true}");
        return;
    }

    if path == "/mock/chat/completions" || path == "/mock/slow/chat/completions" {
        if !cfg.mock_enabled {
            respond_json(&mut s, "404 Not Found", "{\"ok\":false,\"error\":\"not_found\"}");
            return;
        }
        // The /mock/slow variant exists only for scripts/fault_injection_drill.sh:
        // a deliberately slow response gives that drill a genuine multi-second
        // window in which a real outbound_calls row is in_flight on a real HTTP
        // pool thread, wide enough to reliably SIGKILL the worker mid-request
        // before this ever replies (see KNOWN_ISSUES.md item 6/26 -- proving a
        // worker crash between claim and complete is recovered from needs an
        // actual in-flight call to kill, not a synthetic 'in_flight' row).
        // Comfortably under HTTP_TIMEOUT (45s) so an unkilled request here still
        // completes normally -- used again by that same drill's automatic-retry
        // phase, which lets this one actually finish.
        if path == "/mock/slow/chat/completions" {
            std::thread::sleep(Duration::from_secs(15));
        }
        let body = json!({
            "id": "allgres-mock",
            "object": "chat.completion",
            "choices": [{
                "index": 0,
                "message": {
                    "role": "assistant",
                    "content": "{\"action\":\"final_answer\",\"answer\":\"Allgres mock runtime OK\"}"
                },
                "finish_reason": "stop"
            }]
        })
        .to_string();
        respond_json(&mut s, "200 OK", &body);
        return;
    }

    // A mock OAuth token endpoint, gated the same way as /mock/chat/completions:
    // lets tests/e2e_mock.sql drive the real fn_claim_oauth -> perform_http
    // (send_form) -> fn_complete_oauth path through the actual background
    // worker, without a real external OAuth provider. Echoes the exchanged
    // `code` and `client_secret` back into the response so the test can prove
    // both actually arrived here -- not just that a request was sent.
    if path == "/mock/oauth/token" {
        if !cfg.mock_enabled {
            respond_json(&mut s, "404 Not Found", "{\"ok\":false,\"error\":\"not_found\"}");
            return;
        }
        let form = parse_form_body(&r.body);
        let code = form.get("code").cloned().unwrap_or_default();
        let secret = form.get("client_secret").cloned().unwrap_or_default();
        if code.is_empty() || secret != "allgres-mock-oauth-secret" {
            respond_json(&mut s, "401 Unauthorized", "{\"error\":\"invalid_client\"}");
            return;
        }
        let body = json!({
            "access_token": format!("allgres-mock-access-{code}"),
            "refresh_token": "allgres-mock-refresh",
            "expires_in": 3600,
            "token_type": "bearer"
        })
        .to_string();
        respond_json(&mut s, "200 OK", &body);
        return;
    }

    // A mock embeddings endpoint, gated the same way as /mock/chat/completions:
    // lets a test drive the real fn_claim_agent_embedding/fn_claim_outbound ->
    // perform_http (send_json) -> fn_complete_agent_embedding/
    // fn_complete_outbound path through the actual background worker, without
    // a real embedding provider. Deterministic and test-legible rather than a
    // real model's output: each of a small fixed keyword list gets its own
    // dimension, 1.0 if that keyword appears (case-insensitively) anywhere in
    // the request's `input` text, else a small non-zero baseline (so an
    // input matching none of them still embeds to a well-defined, if
    // uninformative, direction instead of the zero vector cosine_similarity
    // treats as undefined). A test can therefore pick exact expected
    // rankings from the keywords it puts in an agent's system_prompt vs. a
    // search query, rather than asserting on an opaque real model's output.
    if path == "/mock/embeddings" {
        if !cfg.mock_enabled {
            respond_json(&mut s, "404 Not Found", "{\"ok\":false,\"error\":\"not_found\"}");
            return;
        }
        const KEYWORDS: [&str; 8] =
            ["alpha", "beta", "gamma", "delta", "epsilon", "zeta", "eta", "theta"];
        let input = serde_json::from_str::<Value>(&r.body)
            .ok()
            .and_then(|v| v.get("input").and_then(Value::as_str).map(str::to_string))
            .unwrap_or_default()
            .to_ascii_lowercase();
        let embedding: Vec<f64> = KEYWORDS
            .iter()
            .map(|k| if input.contains(k) { 1.0 } else { 0.05 })
            .collect();
        let body = json!({
            "data": [{ "embedding": embedding, "index": 0 }],
            "model": "allgres-mock-embed",
            "object": "list"
        })
        .to_string();
        respond_json(&mut s, "200 OK", &body);
        return;
    }

    if path == "/" {
        let n = nonce();
        let html = DASHBOARD_HTML.replace("__CSP_NONCE__", &n);
        let csp = format!(
            "Content-Security-Policy: default-src 'none'; \
             script-src 'nonce-{n}'; style-src 'nonce-{n}'; \
             connect-src 'self'; img-src 'self' data:; \
             base-uri 'none'; form-action 'none'; frame-ancestors 'none'\r\n"
        );
        respond(&mut s, "200 OK", "text/html; charset=utf-8", &html, &csp);
        return;
    }

    if !path.starts_with("/api/v1/") {
        respond_json(&mut s, "404 Not Found", "{\"ok\":false,\"error\":\"not_found\"}");
        return;
    }

    if !csrf_ok(&r) {
        respond_json(&mut s, "403 Forbidden", "{\"ok\":false,\"error\":\"cross_origin_request_rejected\"}");
        return;
    }

    // Checked ahead of the real auth comparison, not after it, so a locked-out
    // IP cannot keep spending a thread and a constant-time compare on every
    // attempt -- only the failures that got this far ever counted against it.
    if let Some(ip) = peer_ip {
        if auth_failures_exceeded(ip) {
            respond(&mut s, "429 Too Many Requests", "application/json",
                    "{\"ok\":false,\"error\":\"rate_limited\"}", "Retry-After: 300\r\n");
            return;
        }
    }

    if !authorized(&r, cfg) {
        if let Some(ip) = peer_ip {
            record_auth_failure(ip);
        }
        respond(&mut s, "401 Unauthorized", "application/json",
                "{\"ok\":false,\"error\":\"unauthorized\"}", "WWW-Authenticate: Bearer\r\n");
        return;
    }

    if path == "/api/v1/events/ticket" {
        if r.method != "POST" {
            respond(&mut s, "405 Method Not Allowed", "application/json",
                    "{\"ok\":false,\"error\":\"method_not_allowed\"}", "Allow: POST\r\n");
            return;
        }
        let ticket = mint_sse_ticket();
        let body = json!({"ok": true, "ticket": ticket, "expires_in": SSE_TICKET_TTL.as_secs()}).to_string();
        respond_json(&mut s, "200 OK", &body);
        return;
    }

    if path == "/api/v1/events" {
        stream_events(&mut s, cfg);
        return;
    }

    match api_route(cfg, &r) {
        Some(v) => {
            let status = if v.get("ok").and_then(Value::as_bool) == Some(false) {
                "400 Bad Request"
            } else {
                "200 OK"
            };
            respond_json(&mut s, status, &v.to_string());
        }
        None => respond_json(&mut s, "404 Not Found", "{\"ok\":false,\"error\":\"not_found\"}"),
    }
}

fn is_loopback_addr(addr: &str) -> bool {
    let host = match addr.rfind(':') {
        Some(i) => &addr[..i],
        None => addr,
    };
    let host = host.trim_start_matches('[').trim_end_matches(']');
    host == "127.0.0.1" || host == "::1" || host == "localhost" || host.starts_with("127.")
}

/// Refuse the combination that turns this into an open agent console: a public
/// bind address with no dashboard token.  Container deployments that publish
/// the port themselves opt in with ALLGRES_ALLOW_INSECURE_HTTP=1.
pub(crate) fn check_exposure(addr: &str, token: &str) -> Result<(), String> {
    if is_loopback_addr(addr) || !token.is_empty() {
        return Ok(());
    }
    if std::env::var("ALLGRES_ALLOW_INSECURE_HTTP").as_deref() == Ok("1") {
        return Ok(());
    }
    Err(format!(
        "refusing to bind {addr} with no ALLGRES_DASHBOARD_TOKEN. \
         Set a token, bind to 127.0.0.1, or set ALLGRES_ALLOW_INSECURE_HTTP=1 if the \
         port is already protected by the surrounding network."
    ))
}

#[unsafe(no_mangle)]
#[pg_guard]
pub extern "C-unwind" fn allgres_web_main(_arg: pg_sys::Datum) {
    BackgroundWorker::attach_signal_handlers(SignalWakeFlags::SIGHUP | SignalWakeFlags::SIGTERM);

    let addr = configured_http_addr();
    let cfg = WebConfig {
        token: std::env::var("ALLGRES_DASHBOARD_TOKEN").unwrap_or_default(),
        socket: rpc_socket_path(),
        mock_enabled: std::env::var("ALLGRES_ENABLE_MOCK").as_deref() == Ok("1"),
    };

    if let Err(msg) = check_exposure(&addr, &cfg.token) {
        pgrx::warning!("Allgres web: {}", msg);
        return;
    }

    let listener = match TcpListener::bind(&addr) {
        Ok(l) => l,
        Err(e) => {
            pgrx::warning!("Allgres web bind {}: {}", addr, e);
            return;
        }
    };
    if let Err(e) = listener.set_nonblocking(true) {
        pgrx::warning!("Allgres web nonblocking: {}", e);
        return;
    }

    let cfg = Arc::new(cfg);

    while BackgroundWorker::wait_latch(Some(Duration::from_millis(50))) {
        loop {
            match listener.accept() {
                Ok((s, _)) => {
                    if WEB_THREADS.load(Ordering::Relaxed) >= MAX_WEB_THREADS {
                        let mut s = s;
                        respond_json(&mut s, "503 Service Unavailable", "{\"ok\":false,\"error\":\"busy\"}");
                        continue;
                    }
                    let _ = s.set_nonblocking(false);
                    WEB_THREADS.fetch_add(1, Ordering::Relaxed);
                    let cfg = Arc::clone(&cfg);
                    let spawned = std::thread::Builder::new()
                        .name("allgres-web-conn".into())
                        .spawn(move || {
                            handle_web_connection(s, &cfg);
                            WEB_THREADS.fetch_sub(1, Ordering::Relaxed);
                        });
                    if spawned.is_err() {
                        WEB_THREADS.fetch_sub(1, Ordering::Relaxed);
                    }
                }
                Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => break,
                Err(e) => {
                    pgrx::warning!("Allgres web accept: {}", e);
                    break;
                }
            }
        }
    }
}
