//! Outbound HTTP, on pool threads. Nothing here may touch Postgres --
//! see this file's own comments (and `crate::runtime_worker`'s module
//! doc) for why.

use crate::truncate_utf8;
use crate::{HTTP_TIMEOUT, MAX_RESPONSE_BYTES};
use serde_json::{json, Value};
use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{Receiver, Sender};
use std::sync::{Arc, LazyLock, Mutex};
use std::time::{Duration, Instant};

// ---------------------------------------------------------------------------
// Outbound HTTP, on pool threads.  Nothing here may touch Postgres.
// ---------------------------------------------------------------------------

/// Which SQL-side queue a job came from, so the harvest step in the main
/// loop knows whether to complete it via fn_complete_outbound or
/// fn_complete_oauth -- both queues share this one HTTP thread pool, but
/// they are unrelated tables with unrelated completion semantics (one is
/// tied to a task_id and fn_submit_result, the other to an OAuth provider
/// and no task at all).
#[derive(Clone, Copy, PartialEq)]
pub(crate) enum OutboundQueue {
    Outbound,
    Oauth,
    AgentEmbedding,
}

pub(crate) struct OutboundJob {
    pub(crate) call_id: String,
    pub(crate) queue: OutboundQueue,
    pub(crate) call: Value,
}

pub(crate) struct OutboundResult {
    pub(crate) call_id: String,
    pub(crate) queue: OutboundQueue,
    pub(crate) status: i32,
    pub(crate) body: String,
}

/// Mirrors `allgres_private.is_blocked_host`'s IPv4-literal ranges exactly, so
/// the two blocklists cannot drift: loopback, RFC1918, CGNAT (100.64/10),
/// link-local (including the cloud-metadata address 169.254.169.254),
/// TEST-NET/protocol-assignment (192.0.0/24, 192.0.2/24), benchmarking
/// (198.18/15), and multicast/reserved/broadcast (224-255).
fn is_blocked_ipv4(v4: &std::net::Ipv4Addr) -> bool {
    let o = v4.octets();
    o[0] == 0
        || o[0] == 10
        || o[0] == 127
        || (o[0] == 169 && o[1] == 254)
        || (o[0] == 172 && (16..=31).contains(&o[1]))
        || (o[0] == 192 && o[1] == 168)
        || (o[0] == 192 && o[1] == 0 && (o[2] == 0 || o[2] == 2))
        || (o[0] == 198 && (o[1] == 18 || o[1] == 19))
        || (o[0] == 100 && (64..=127).contains(&o[1]))
        || o[0] >= 224
}

/// Same idea for IPv6: loopback/unspecified, IPv4-mapped (reduces to the v4
/// check), fc00::/7 unique-local, and fe80::/10 link-local.
fn is_blocked_ip(ip: &std::net::IpAddr) -> bool {
    match ip {
        std::net::IpAddr::V4(v4) => is_blocked_ipv4(v4),
        std::net::IpAddr::V6(v6) => {
            if let Some(v4) = v6.to_ipv4_mapped() {
                return is_blocked_ipv4(&v4);
            }
            if v6.is_loopback() || v6.is_unspecified() {
                return true;
            }
            let first = v6.segments()[0];
            (first & 0xfe00) == 0xfc00 || (first & 0xffc0) == 0xfe80
        }
    }
}

/// Wraps ureq's `DefaultResolver` to re-check every address DNS actually
/// hands back, immediately before ureq connects to it. The SQL layer already
/// checks the URL's host *string* at queue time (`check_outbound_url`), but
/// that is a check on a name, not on where the name points: a hostname that
/// resolves to a public address when the agent's request is validated can
/// resolve to 127.0.0.1 or an RFC1918 address by the time this worker thread
/// actually connects (DNS rebinding), and no amount of re-checking the
/// string closes that gap. Filtering here instead of after resolving
/// separately closes it completely rather than narrowing it to a race
/// window: ureq connects only to what this resolver returns, so a blocked
/// address is never dialed at all, not even once.
#[derive(Debug)]
struct GuardedResolver {
    allow_private: bool,
}

impl ureq::unversioned::resolver::Resolver for GuardedResolver {
    fn resolve(
        &self,
        uri: &ureq::http::Uri,
        config: &ureq::config::Config,
        timeout: ureq::unversioned::transport::NextTimeout,
    ) -> Result<ureq::unversioned::resolver::ResolvedSocketAddrs, ureq::Error> {
        let addrs = ureq::unversioned::resolver::DefaultResolver::default()
            .resolve(uri, config, timeout)?;
        if !self.allow_private {
            for addr in &addrs {
                if is_blocked_ip(&addr.ip()) {
                    return Err(ureq::Error::HostNotFound);
                }
            }
        }
        Ok(addrs)
    }
}

/// Every in-flight outbound HTTP call's cooperative cancellation flag, keyed
/// by call_id -- the real-time "stop" button's mechanism for a session that
/// is currently blocked inside `perform_http` on an HTTP thread, not the
/// SPI thread (see `run_in_subtransaction`'s own comment for the sandboxed
/// SQL half of the same feature). Entries live only as long as
/// `perform_http` is actually running that call: inserted at the top,
/// removed via `CancelGuard`'s `Drop` on every return path. The main loop
/// (not this thread -- an HTTP thread must never touch Postgres, see this
/// module's own header comment) is the one place that ever sets a flag to
/// true, on noticing `outbound_calls.status` for that call_id flip to
/// 'lost' (fn_cancel_session's own doing) while it is still in this map.
pub(crate) static OUTBOUND_CANCEL_FLAGS: LazyLock<Mutex<HashMap<String, Arc<AtomicBool>>>> =
    LazyLock::new(|| Mutex::new(HashMap::new()));

struct CancelGuard {
    pub(crate) call_id: String,
    flag: Arc<AtomicBool>,
}

impl CancelGuard {
    fn register(call_id: &str) -> Self {
        let flag = Arc::new(AtomicBool::new(false));
        if let Ok(mut map) = OUTBOUND_CANCEL_FLAGS.lock() {
            map.insert(call_id.to_string(), flag.clone());
        }
        CancelGuard { call_id: call_id.to_string(), flag }
    }
}

impl Drop for CancelGuard {
    fn drop(&mut self) {
        if let Ok(mut map) = OUTBOUND_CANCEL_FLAGS.lock() {
            map.remove(&self.call_id);
        }
    }
}

/// Wraps ureq's real connector so every `Transport` it produces carries this
/// call's own cancellation flag -- see `CancellableTransport`.
#[derive(Debug)]
struct CancellableConnector {
    inner: ureq::unversioned::transport::DefaultConnector,
    cancel: Arc<AtomicBool>,
}

impl ureq::unversioned::transport::Connector for CancellableConnector {
    type Out = CancellableTransport;

    fn connect(
        &self,
        details: &ureq::unversioned::transport::ConnectionDetails,
        chained: Option<()>,
    ) -> Result<Option<Self::Out>, ureq::Error> {
        match self.inner.connect(details, chained)? {
            Some(inner) => Ok(Some(CancellableTransport { inner, cancel: self.cancel.clone() })),
            None => Ok(None),
        }
    }
}

/// How often a wait against the real transport is interrupted to re-check
/// the cancellation flag. Small enough that a "stop" click lands well
/// under a second, large enough not to busy-loop.
const CANCEL_POLL_INTERVAL: Duration = Duration::from_millis(150);

/// Delegates every real read/write to ureq's own transport, but slices
/// `await_input`/`transmit_output`'s own timeout into `CANCEL_POLL_INTERVAL`
/// steps so a cancellation flagged mid-wait is noticed promptly instead of
/// only at the next natural timeout (which, for an LLM response, can be the
/// entire per-call HTTP_TIMEOUT away).
#[derive(Debug)]
struct CancellableTransport {
    inner: Box<dyn ureq::unversioned::transport::Transport>,
    cancel: Arc<AtomicBool>,
}

impl CancellableTransport {
    fn check_cancelled(&self) -> Result<(), ureq::Error> {
        if self.cancel.load(Ordering::Relaxed) {
            Err(ureq::Error::Io(std::io::Error::new(
                std::io::ErrorKind::ConnectionAborted,
                "cancelled by operator",
            )))
        } else {
            Ok(())
        }
    }

    /// ureq's own `Duration`/`Instant` (`ureq::unversioned::transport::time`)
    /// are distinct types from `std::time`'s, needed only at the boundary
    /// of a call into `self.inner` -- everywhere else here just tracks a
    /// plain `std::time::Duration` deadline. `Duration` derefs to
    /// `std::time::Duration` (`NotHappening` as `u64::MAX` seconds), which
    /// is what makes a "no timeout configured" `NextTimeout` safe to treat
    /// the same as any other.
    fn sliced(
        after: std::time::Duration,
        reason: ureq::Timeout,
    ) -> ureq::unversioned::transport::NextTimeout {
        ureq::unversioned::transport::NextTimeout {
            after: ureq::unversioned::transport::time::Duration::Exact(after.min(CANCEL_POLL_INTERVAL)),
            reason,
        }
    }
}

impl ureq::unversioned::transport::Transport for CancellableTransport {
    fn buffers(&mut self) -> &mut dyn ureq::unversioned::transport::Buffers {
        self.inner.buffers()
    }

    fn transmit_output(
        &mut self,
        amount: usize,
        timeout: ureq::unversioned::transport::NextTimeout,
    ) -> Result<(), ureq::Error> {
        let deadline = Instant::now() + *timeout.after;
        loop {
            self.check_cancelled()?;
            let remaining = deadline.saturating_duration_since(Instant::now());
            if remaining.is_zero() {
                return self.inner.transmit_output(amount, timeout);
            }
            match self.inner.transmit_output(amount, Self::sliced(remaining, timeout.reason)) {
                Ok(()) => return Ok(()),
                Err(ureq::Error::Timeout(_)) => continue,
                Err(e) => return Err(e),
            }
        }
    }

    fn maybe_await_input(&mut self, timeout: ureq::unversioned::transport::NextTimeout) -> Result<bool, ureq::Error> {
        if self.buffers().can_use_input() {
            return Ok(true);
        }
        self.await_input(timeout)
    }

    fn await_input(&mut self, timeout: ureq::unversioned::transport::NextTimeout) -> Result<bool, ureq::Error> {
        let deadline = Instant::now() + *timeout.after;
        loop {
            self.check_cancelled()?;
            let remaining = deadline.saturating_duration_since(Instant::now());
            if remaining.is_zero() {
                return self.inner.await_input(timeout);
            }
            match self.inner.await_input(Self::sliced(remaining, timeout.reason)) {
                Ok(true) => return Ok(true),
                Ok(false) => continue,
                // A sliced sub-timeout expiring is not the real deadline -- only
                // the outer `deadline` (derived from the caller's own original
                // `timeout.after`) means the actual wait ran out. Without this,
                // the very first 150ms slice with no data yet available would
                // surface as a genuine timeout error to the caller instead of
                // looping, which is exactly what made a real 15s-slow response
                // fail in ~50ms during live testing.
                Err(ureq::Error::Timeout(_)) => continue,
                Err(e) => return Err(e),
            }
        }
    }

    fn is_open(&mut self) -> bool {
        self.inner.is_open()
    }

    fn is_tls(&self) -> bool {
        self.inner.is_tls()
    }
}

fn perform_http(call_id: &str, call: &Value) -> (i32, String) {
    let cancel_guard = CancelGuard::register(call_id);
    let cancel_flag = cancel_guard.flag.clone();
    let Some(url) = call.get("url").and_then(Value::as_str) else {
        return (0, "missing outbound URL".into());
    };
    // The SQL layer validates scheme and host before queueing; this is a cheap
    // second check so a malformed row can never become a file:// fetch.
    let lowered = url.to_ascii_lowercase();
    if !(lowered.starts_with("http://") || lowered.starts_with("https://")) {
        return (0, "outbound URL scheme not allowed".into());
    }

    let kind = call.get("kind").and_then(Value::as_str).unwrap_or("llm");
    let headers = call.get("headers").and_then(Value::as_object);
    let body = call.get("body").cloned().unwrap_or_else(|| json!({}));
    // Only an LLM provider can ever carry this, and only when the operator
    // opted it in (allow_private_network); http_get always queues false. See
    // GuardedResolver.
    let allow_private = call.get("allow_private").and_then(Value::as_bool).unwrap_or(false);

    let config = ureq::Agent::config_builder()
        .timeout_global(Some(HTTP_TIMEOUT))
        .http_status_as_error(false)
        // A redirect would be followed without re-running the host guard, which
        // is the standard way to turn an allowlisted URL into an SSRF.
        .max_redirects(0)
        .build();
    let agent = ureq::Agent::with_parts(
        config,
        CancellableConnector {
            inner: ureq::unversioned::transport::DefaultConnector::default(),
            cancel: cancel_flag,
        },
        GuardedResolver { allow_private },
    );

    let outcome = if kind == "tool" {
        // http_get always queued "GET" here (the column defaults to it); the
        // 'http_request' tool is the first caller that ever queues anything
        // else. GET/DELETE take no body (ureq's WithoutBody builder has no
        // send_json at all); POST/PUT/PATCH always send one, defaulting to
        // an empty JSON object when the SQL layer didn't attach a real body.
        let method = call.get("method").and_then(Value::as_str).unwrap_or("GET").to_ascii_uppercase();
        match method.as_str() {
            "POST" | "PUT" | "PATCH" => {
                let mut req = match method.as_str() {
                    "POST" => agent.post(url),
                    "PUT" => agent.put(url),
                    _ => agent.patch(url),
                };
                if let Some(h) = headers {
                    for (k, v) in h {
                        if let Some(s) = v.as_str() {
                            req = req.header(k, s);
                        }
                    }
                }
                req.send_json(&body)
            }
            _ => {
                let mut req = if method == "DELETE" { agent.delete(url) } else { agent.get(url) };
                if let Some(h) = headers {
                    for (k, v) in h {
                        if let Some(s) = v.as_str() {
                            req = req.header(k, s);
                        }
                    }
                }
                req.call()
            }
        }
    } else if kind == "oauth" {
        // An OAuth token endpoint expects a standard form submission, not
        // JSON (RFC 6749 4.1.3). send_form sets its own content-type header
        // (application/x-www-form-urlencoded) and percent-encodes every
        // field, including client_secret -- fn_claim_oauth merged it into
        // `body` at claim time, so it exists only in this one process's
        // memory for this one request.
        let mut req = agent.post(url);
        if let Some(h) = headers {
            for (k, v) in h {
                if k.eq_ignore_ascii_case("content-type") {
                    continue;
                }
                if let Some(s) = v.as_str() {
                    req = req.header(k, s);
                }
            }
        }
        let form: Vec<(String, String)> = body
            .as_object()
            .map(|obj| {
                obj.iter()
                    .filter_map(|(k, v)| v.as_str().map(|s| (k.clone(), s.to_string())))
                    .collect()
            })
            .unwrap_or_default();
        req.send_form(form)
    } else {
        let mut req = agent.post(url);
        if let Some(h) = headers {
            for (k, v) in h {
                if let Some(s) = v.as_str() {
                    req = req.header(k, s);
                }
            }
        }
        req.send_json(&body)
    };

    match outcome {
        Ok(mut r) => {
            let status = r.status().as_u16() as i32;
            let text = r.body_mut().read_to_string().unwrap_or_default();
            (status, truncate_utf8(&text, MAX_RESPONSE_BYTES).to_string())
        }
        Err(e) => (0, e.to_string()),
    }
}

pub(crate) fn spawn_http_pool(threads: usize) -> (Sender<OutboundJob>, Receiver<OutboundResult>) {
    let (job_tx, job_rx) = std::sync::mpsc::channel::<OutboundJob>();
    let (res_tx, res_rx) = std::sync::mpsc::channel::<OutboundResult>();
    let shared = Arc::new(Mutex::new(job_rx));

    for i in 0..threads {
        let jobs = Arc::clone(&shared);
        let out = res_tx.clone();
        let _ = std::thread::Builder::new()
            .name(format!("allgres-http-{i}"))
            .spawn(move || loop {
                let job = {
                    let guard = match jobs.lock() {
                        Ok(g) => g,
                        Err(poisoned) => poisoned.into_inner(),
                    };
                    guard.recv()
                };
                let Ok(job) = job else { return };
                let (status, body) = perform_http(&job.call_id, &job.call);
                if out
                    .send(OutboundResult { call_id: job.call_id, queue: job.queue, status, body })
                    .is_err()
                {
                    return;
                }
            });
    }

    (job_tx, res_rx)
}

