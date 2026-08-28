//! Allgres native runtime.
//!
//! Two background workers, neither of which owns any agent state:
//!
//!   `allgres runtime`  SPI thread + a pool of HTTP threads.  The SPI thread
//!                      only ever runs short transactions (pump, RPC); every
//!                      blocking network call happens on a pool thread, so a
//!                      slow LLM can never stall the dashboard.  Sandboxed
//!                      agent SQL also runs here, on the SPI thread, since it
//!                      needs SPI: PostgreSQL's SET ROLE restriction means it
//!                      can only be a top-level statement issued directly by
//!                      this worker, never nested inside a SECURITY DEFINER
//!                      function -- see `run_sandboxed_sql`.
//!
//!   `allgres web`      HTTP listener.  No SPI at all: it forwards to the
//!                      runtime worker over a unix socket.  One thread per
//!                      connection, bounded, so a slow client cannot stall the
//!                      accept loop either.
//!
//! All SQL is executed with bound parameters.  Nothing in this file builds a
//! statement by concatenating a value into a string.  `run_sandboxed_sql`
//! passes agent-generated SQL to Postgres as a bind parameter too; the one
//! place it gets wrapped into a larger statement by concatenation is
//! sql/control_plane.sql's `fn_run_sandboxed_sql`, and only after
//! `fn_validate_sql` has confirmed it parses as exactly one non-writing
//! SELECT, which is what makes that safe.

use pgrx::bgworkers::{BackgroundWorker, BackgroundWorkerBuilder, BgWorkerStartTime, SignalWakeFlags};
use pgrx::prelude::*;
use pgrx::JsonB;
use serde_json::{json, Value};
use std::ffi::CStr;
use std::fs;
use std::io::{Read, Write};
use std::net::{Shutdown, TcpListener, TcpStream};
use std::os::unix::fs::{DirBuilderExt, PermissionsExt};
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::mpsc::{Receiver, Sender, TryRecvError};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

pgrx::pg_module_magic!();

const VERSION: &str = env!("CARGO_PKG_VERSION");
const DEFAULT_DB: &str = "postgres";
/// Loopback by default.  Binding to a public address without a dashboard token
/// is refused unless the operator opts in explicitly (see `check_exposure`).
const DEFAULT_HTTP_ADDR: &str = "127.0.0.1:8088";
const DASHBOARD_HTML: &str = include_str!("../web/index.html");

/// Outbound HTTP threads, and therefore the maximum number of calls claimed
/// per pump.  The SQL watchdog timeout must stay above `HTTP_TIMEOUT`.
const HTTP_THREADS: usize = 4;
const HTTP_TIMEOUT: Duration = Duration::from_secs(45);
const MAX_RESPONSE_BYTES: usize = 200_000;

const PUMP_BUSY: Duration = Duration::from_millis(150);
const PUMP_IDLE_MIN: Duration = Duration::from_millis(500);
const PUMP_IDLE_MAX: Duration = Duration::from_secs(4);

/// Sandboxed SQL executes on the SPI thread itself (it needs SPI, so it can't
/// go on an HTTP pool thread the way outbound calls do), one call at a time,
/// bounded by `SQL_STATEMENT_TIMEOUT` each.  Claiming only one per tick, not a
/// batch, keeps a burst of agent queries from shutting the RPC/dashboard path
/// out for several statement-timeouts in a row.
const SQL_CLAIM_LIMIT: i32 = 1;
const SQL_STATEMENT_TIMEOUT: &str = "5s";

const MAX_WEB_THREADS: usize = 64;
const MAX_REQUEST_BYTES: usize = 1 << 20;
const REQUEST_DEADLINE: Duration = Duration::from_secs(5);
const SSE_TOTAL: Duration = Duration::from_secs(30);
const SSE_INTERVAL: Duration = Duration::from_secs(1);

extension_sql_file!("../sql/control_plane.sql", finalize);

#[pg_schema]
mod allgres {
    use super::*;

    #[pg_extern]
    fn native_version() -> &'static str {
        VERSION
    }

    /// Structural analysis of a candidate agent statement, using PostgreSQL's
    /// own grammar.  See `raw_parse_dump` for why this is not a hand-written
    /// parser and not a regex.
    ///
    /// Raises on a syntax error (callers wrap this in an exception block).
    #[pg_extern(immutable, parallel_safe)]
    fn analyze_sql(sql: &str) -> JsonB {
        JsonB(analyze_dump(&raw_parse_dump(sql)))
    }

    #[pg_extern]
    fn native_status() -> JsonB {
        let preload = Spi::get_one::<String>("SELECT current_setting('shared_preload_libraries', true)")
            .ok()
            .flatten()
            .unwrap_or_default();
        JsonB(json!({
            "name": "Allgres",
            "tagline": "Postgres Is All You Need.",
            "version": VERSION,
            "preloaded": preload.split(',').any(|x| x.trim() == "allgres"),
            "runtime_worker": "allgres runtime",
            "web_worker": "allgres web",
            "web_default": DEFAULT_HTTP_ADDR,
            "rpc_socket": rpc_socket_path().display().to_string(),
        }))
    }
}

#[pg_guard]
pub extern "C-unwind" fn _PG_init() {
    // Registering a background worker is only legal from the postmaster during
    // shared_preload_libraries processing.  Without this guard a plain
    // `LOAD 'allgres'` in a normal backend errors out.
    if !unsafe { *(&raw const pg_sys::process_shared_preload_libraries_in_progress) } {
        return;
    }

    BackgroundWorkerBuilder::new("allgres runtime")
        .set_function("allgres_runtime_main")
        .set_library("allgres")
        .set_start_time(BgWorkerStartTime::RecoveryFinished)
        .set_restart_time(Some(Duration::from_secs(5)))
        .enable_spi_access()
        .load();

    BackgroundWorkerBuilder::new("allgres web")
        .set_function("allgres_web_main")
        .set_library("allgres")
        .set_start_time(BgWorkerStartTime::RecoveryFinished)
        .set_restart_time(Some(Duration::from_secs(5)))
        .load();
}

// ---------------------------------------------------------------------------
// SQL analysis, via PostgreSQL's own parser
//
// The SQL sandbox used to decide what an agent statement touched by running
// regexes over the statement text.  That approach has to re-implement lexing --
// comments, dollar quotes, string literals, quoted identifiers, `extract(x FROM
// y)`, comma joins, CTE scoping -- and every one of those was a way to be wrong.
//
// Because Allgres is already a C extension we can call `raw_parser`, the exact
// grammar the server uses, and read the resulting tree.  Nothing is planned,
// rewritten, or executed: this is parse only.  `nodeToString` then gives a
// canonical serialization of that tree, which is what `analyze_dump` reads.
//
// Reading a machine-generated node dump is not the same thing as pattern
// matching user text: by this point the grammar has already resolved every
// lexical ambiguity, so a string literal can never be mistaken for a table and
// a comment cannot hide one.
// ---------------------------------------------------------------------------

fn raw_parse_dump(sql: &str) -> String {
    let Ok(c_sql) = std::ffi::CString::new(sql) else {
        // An interior NUL cannot reach the parser; treat it as unparseable.
        return String::new();
    };
    unsafe {
        let list = pg_sys::raw_parser(c_sql.as_ptr(), pg_sys::RawParseMode::RAW_PARSE_DEFAULT);
        if list.is_null() {
            return String::new();
        }
        let s = pg_sys::nodeToString(list as *const std::ffi::c_void);
        if s.is_null() {
            return String::new();
        }
        CStr::from_ptr(s).to_string_lossy().into_owned()
    }
}

/// Read one `outToken`-encoded value: `<>` is NULL, `""` is empty, and any
/// other token ends at the first unescaped delimiter.
fn read_token(s: &str) -> (Option<String>, usize) {
    let bytes = s.as_bytes();
    if bytes.starts_with(b"<>") {
        return (None, 2);
    }
    if bytes.starts_with(b"\"\"") {
        return (Some(String::new()), 2);
    }
    let mut out = String::new();
    let mut i = 0;
    while i < bytes.len() {
        let b = bytes[i];
        if b == b'\\' {
            // outToken escapes the delimiters, and prefixes a leading '<', '"'
            // or digit so it cannot be confused with NULL or a number.
            if i + 1 < bytes.len() {
                out.push(bytes[i + 1] as char);
                i += 2;
                continue;
            }
            i += 1;
            continue;
        }
        if b.is_ascii_whitespace() || b == b'}' || b == b')' || b == b'{' || b == b'(' {
            break;
        }
        out.push(b as char);
        i += 1;
    }
    (Some(out), i)
}

/// The substring covering one node, starting just after its `{TAG` opener.
fn node_body(s: &str) -> &str {
    let bytes = s.as_bytes();
    let mut depth = 0usize;
    let mut i = 0;
    while i < bytes.len() {
        match bytes[i] {
            b'\\' => i += 1,
            b'{' => depth += 1,
            b'}' => {
                if depth == 0 {
                    return &s[..i];
                }
                depth -= 1;
            }
            _ => {}
        }
        i += 1;
    }
    s
}

/// The substring covering one parenthesised list, starting just after its `(`.
fn paren_body(s: &str) -> &str {
    let bytes = s.as_bytes();
    let mut depth = 0usize;
    let mut i = 0;
    while i < bytes.len() {
        match bytes[i] {
            b'\\' => i += 1,
            b'(' => depth += 1,
            b')' => {
                if depth == 0 {
                    return &s[..i];
                }
                depth -= 1;
            }
            _ => {}
        }
        i += 1;
    }
    s
}

/// String nodes inside a List serialise as `"name"`, not as `{STRING ...}`,
/// so a funcname list looks like `("pg_catalog" "generate_series")`.
fn quoted_strings(body: &str) -> Vec<String> {
    let bytes = body.as_bytes();
    let mut out = Vec::new();
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] != b'"' {
            i += 1;
            continue;
        }
        i += 1;
        let mut s = String::new();
        while i < bytes.len() && bytes[i] != b'"' {
            if bytes[i] == b'\\' && i + 1 < bytes.len() {
                s.push(bytes[i + 1] as char);
                i += 2;
            } else {
                s.push(bytes[i] as char);
                i += 1;
            }
        }
        i += 1;
        out.push(s);
    }
    out
}

/// Value of `:name` within a node body, ignoring nested nodes' own fields for
/// names that are unique to the node type we are reading.
fn field(body: &str, name: &str) -> Option<String> {
    let needle = format!(":{name} ");
    let at = body.find(&needle)? + needle.len();
    read_token(&body[at..]).0
}

fn read_ident(s: &str) -> String {
    s.chars()
        .take_while(|c| c.is_ascii_alphanumeric() || *c == '_')
        .collect()
}

fn analyze_dump(dump: &str) -> Value {
    if dump.is_empty() {
        return json!({"ok": false, "error": "unparseable"});
    }

    // Top-level statement tags.
    let mut kinds: Vec<String> = Vec::new();
    let mut idx = 0;
    while let Some(p) = dump[idx..].find("{RAWSTMT") {
        let start = idx + p;
        let body = node_body(&dump[start + "{RAWSTMT".len()..]);
        if let Some(q) = body.find(":stmt {") {
            kinds.push(read_ident(&body[q + ":stmt {".len()..]));
        }
        idx = start + "{RAWSTMT".len();
    }

    let mut relations = Vec::new();
    let mut idx = 0;
    while let Some(p) = dump[idx..].find("{RANGEVAR ") {
        let start = idx + p + "{RANGEVAR ".len();
        let body = node_body(&dump[start..]);
        let name = field(body, "relname");
        if let Some(name) = name {
            relations.push(json!({
                "schema": field(body, "schemaname"),
                "name": name,
            }));
        }
        idx = start;
    }

    // A RangeVar naming a CTE is indistinguishable from a table at parse time,
    // so the caller needs the CTE names to tell them apart.
    let mut ctes = Vec::new();
    let mut idx = 0;
    while let Some(p) = dump[idx..].find(":ctename ") {
        let start = idx + p + ":ctename ".len();
        if let (Some(name), _) = read_token(&dump[start..]) {
            ctes.push(Value::String(name));
        }
        idx = start;
    }

    // Every function the statement calls.  PostgreSQL forbids SET ROLE inside a
    // security-definer function, so the statement cannot be dropped to an
    // unprivileged role; the caller vets these against pg_proc instead.
    // funcname is a List of String nodes: ("pg_catalog" "generate_series").
    let mut functions = Vec::new();
    let mut idx = 0;
    while let Some(p) = dump[idx..].find(":funcname (") {
        let start = idx + p + ":funcname (".len();
        let mut parts = quoted_strings(paren_body(&dump[start..]));
        if let Some(name) = parts.pop() {
            functions.push(json!({ "schema": parts.pop(), "name": name }));
        }
        idx = start;
    }

    // `SELECT ... INTO t` and data-modifying CTEs are SelectStmts that write.
    let has_into = dump.contains(":intoClause {");
    let has_dml = ["{INSERTSTMT", "{UPDATESTMT", "{DELETESTMT", "{MERGESTMT"]
        .iter()
        .any(|tag| dump.contains(tag));

    let kind = if kinds.len() == 1 && kinds[0] == "SELECTSTMT" {
        "select"
    } else {
        "other"
    };

    json!({
        "ok": true,
        "statements": kinds.len(),
        "kind": kind,
        "writes": has_into || has_dml,
        "relations": relations,
        "functions": functions,
        "ctes": ctes,
    })
}

// ---------------------------------------------------------------------------
// Configuration
// ---------------------------------------------------------------------------

fn env_opt(key: &str) -> Option<String> {
    std::env::var(key).ok().filter(|v| !v.is_empty())
}

fn configured_database() -> String {
    env_opt("ALLGRES_DATABASE").unwrap_or_else(|| DEFAULT_DB.to_string())
}

fn configured_http_addr() -> String {
    env_opt("ALLGRES_HTTP_ADDR").unwrap_or_else(|| DEFAULT_HTTP_ADDR.to_string())
}

/// `DataDir` is set by the postmaster before any background worker is forked,
/// so both workers derive the same path without needing SPI.
fn data_directory() -> Option<PathBuf> {
    let ptr = unsafe { *(&raw const pg_sys::DataDir) };
    if ptr.is_null() {
        return None;
    }
    let s = unsafe { CStr::from_ptr(ptr) }.to_str().ok()?;
    (!s.is_empty()).then(|| PathBuf::from(s))
}

/// A 0700 directory, instance-private.  The RPC socket used to live at a fixed
/// `/tmp` path with default permissions, which let any local user call
/// `dashboard_rpc` and bypass the dashboard token entirely.
fn socket_dir() -> PathBuf {
    if let Some(dir) = env_opt("ALLGRES_SOCKET_DIR") {
        return PathBuf::from(dir);
    }
    match data_directory() {
        Some(base) => base.join("allgres"),
        None => std::env::temp_dir().join("allgres"),
    }
}

fn rpc_socket_path() -> PathBuf {
    socket_dir().join("runtime.sock")
}

fn ensure_socket_dir(dir: &Path) -> std::io::Result<()> {
    if !dir.exists() {
        fs::DirBuilder::new().recursive(true).mode(0o700).create(dir)?;
    }
    let meta = fs::metadata(dir)?;
    if !meta.is_dir() {
        return Err(std::io::Error::other(format!(
            "{} exists and is not a directory",
            dir.display()
        )));
    }
    // Tighten an inherited or pre-created directory rather than trusting it.
    if meta.permissions().mode() & 0o077 != 0 {
        fs::set_permissions(dir, fs::Permissions::from_mode(0o700))?;
    }
    Ok(())
}

fn bind_rpc_socket() -> std::io::Result<UnixListener> {
    let dir = socket_dir();
    ensure_socket_dir(&dir)?;
    let path = dir.join("runtime.sock");
    let _ = fs::remove_file(&path);
    let listener = UnixListener::bind(&path)?;
    fs::set_permissions(&path, fs::Permissions::from_mode(0o600))?;
    Ok(listener)
}

// ---------------------------------------------------------------------------
// SPI, always with bound parameters
// ---------------------------------------------------------------------------

fn extension_is_installed() -> bool {
    BackgroundWorker::transaction(|| {
        Spi::get_one::<bool>("SELECT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'allgres')")
            .ok()
            .flatten()
            .unwrap_or(false)
    })
}

/// Best-effort privilege drop, run at the top of every runtime transaction.
/// The worker connects as the bootstrap superuser so a not-yet-created role can
/// never crash-loop it at startup; this puts ordinary work back on `worker`.
fn drop_privileges() {
    if std::env::var("ALLGRES_DROP_PRIVILEGES").as_deref() == Ok("0") {
        return;
    }
    let _ = Spi::get_one::<bool>("SELECT allgres.assume_worker_role()");
}

fn dispatch_and_claim(limit: usize) -> Value {
    BackgroundWorker::transaction(|| {
        drop_privileges();
        let _ = Spi::get_one_with_args::<JsonB>(
            "SELECT argo_public.fn_watchdog($1)",
            &[(HTTP_TIMEOUT.as_secs() as i32 * 2).into()],
        );
        let _ = Spi::get_one::<JsonB>("SELECT argo_public.fn_dispatch_tasks(NULL)");
        Spi::get_one_with_args::<JsonB>(
            "SELECT argo_public.fn_claim_outbound($1)",
            &[(limit as i32).into()],
        )
        .ok()
        .flatten()
        .map(|j| j.0)
        .unwrap_or_else(|| json!({ "count": 0, "calls": [] }))
    })
}

fn submit_http_result(call_id: &str, status: i32, body: &str) {
    // Postgres text cannot hold NUL; this is sanitisation, not escaping.
    let body = truncate_utf8(&body.replace('\0', ""), MAX_RESPONSE_BYTES).to_string();
    BackgroundWorker::transaction(|| {
        drop_privileges();
        let _ = Spi::get_one_with_args::<JsonB>(
            "SELECT argo_public.fn_complete_outbound($1::uuid, $2, $3)",
            &[call_id.into(), status.into(), body.as_str().into()],
        );
    });
}

fn dashboard_rpc(request: &str) -> String {
    BackgroundWorker::transaction(|| {
        drop_privileges();
        Spi::get_one_with_args::<JsonB>(
            "SELECT allgres.dashboard_rpc($1::jsonb)",
            &[request.into()],
        )
        .ok()
        .flatten()
        .map(|j| j.0.to_string())
        .unwrap_or_else(|| json!({"ok": false, "error": "empty_rpc_result"}).to_string())
    })
}

// ---------------------------------------------------------------------------
// Sandboxed SQL.  sql/control_plane.sql's fn_validate_sql (SECURITY DEFINER)
// checks an agent statement and hands back its normalized text; PostgreSQL
// forbids SET ROLE inside a SECURITY DEFINER function, so it cannot also run
// it.  These functions are the other half: they claim a validated statement
// and run it as a top-level SPI call, issued directly by this worker with no
// enclosing SECURITY DEFINER frame, which is exactly where SET ROLE sandbox
// is legal.
// ---------------------------------------------------------------------------

fn claim_sql_jobs(limit: i32) -> Value {
    BackgroundWorker::transaction(|| {
        drop_privileges();
        Spi::get_one_with_args::<JsonB>("SELECT argo_public.fn_claim_sql($1)", &[limit.into()])
            .ok()
            .flatten()
            .map(|j| j.0)
            .unwrap_or_else(|| json!({ "count": 0, "calls": [] }))
    })
}

/// Runs one already-validated agent statement as the `sandbox` role.  `sql`
/// must be `fn_validate_sql`'s return value, never raw agent input: this
/// function trusts it completely and so does the database function it calls.
fn run_sandboxed_sql(agent_id: &str, sql: &str) -> Result<Value, String> {
    BackgroundWorker::transaction(|| {
        drop_privileges();
        let dropped = Spi::run("SET LOCAL ROLE sandbox").is_ok()
            && Spi::run("SET LOCAL search_path = pg_temp").is_ok()
            && Spi::run("SET LOCAL transaction_read_only = on").is_ok()
            && Spi::run(&format!("SET LOCAL statement_timeout = '{SQL_STATEMENT_TIMEOUT}'")).is_ok()
            && Spi::run_with_args(
                "SELECT set_config('argo.agent_id', $1, true)",
                &[agent_id.into()],
            )
            .is_ok();
        if !dropped {
            return Err("sandbox role unavailable".to_string());
        }
        match Spi::get_one_with_args::<JsonB>(
            "SELECT argo_public.fn_run_sandboxed_sql($1)",
            &[sql.into()],
        ) {
            Ok(Some(JsonB(v))) => Ok(v),
            Ok(None) => Err("sandboxed execution returned nothing".to_string()),
            Err(e) => Err(e.to_string()),
        }
    })
}

fn submit_sql_result(call_id: &str, outcome: Result<Value, String>) {
    let (ok, rows, row_count, truncated, error) = match outcome {
        Ok(v) if v.get("ok").and_then(Value::as_bool) == Some(true) => (
            true,
            v.get("rows").cloned(),
            v.get("row_count").and_then(Value::as_i64).map(|n| n as i32),
            v.get("truncated").and_then(Value::as_bool).unwrap_or(false),
            None,
        ),
        Ok(v) => (
            false,
            None,
            None,
            false,
            Some(
                v.get("error")
                    .and_then(Value::as_str)
                    .unwrap_or("sql execution failed")
                    .to_string(),
            ),
        ),
        Err(e) => (false, None, None, false, Some(e)),
    };
    BackgroundWorker::transaction(|| {
        drop_privileges();
        let _ = Spi::get_one_with_args::<JsonB>(
            "SELECT argo_public.fn_complete_sql($1::uuid, $2, $3, $4, $5, $6)",
            &[
                call_id.into(),
                ok.into(),
                rows.map(JsonB).into(),
                row_count.into(),
                truncated.into(),
                error.into(),
            ],
        );
    });
}

/// Claims up to `SQL_CLAIM_LIMIT` queued sandboxed-SQL calls and runs each to
/// completion.  Returns how many it processed, so the pump loop's idle
/// backoff treats this like any other unit of work.
fn pump_sql() -> usize {
    let claimed = claim_sql_jobs(SQL_CLAIM_LIMIT);
    let mut n = 0usize;
    let Some(calls) = claimed.get("calls").and_then(Value::as_array) else {
        return 0;
    };
    for call in calls {
        let (Some(call_id), Some(agent_id), Some(sql)) = (
            call.get("call_id").and_then(Value::as_str),
            call.get("agent_id").and_then(Value::as_str),
            call.get("sql").and_then(Value::as_str),
        ) else {
            continue;
        };
        if !valid_uuid(call_id) || !valid_uuid(agent_id) {
            continue;
        }
        let outcome = run_sandboxed_sql(agent_id, sql);
        submit_sql_result(call_id, outcome);
        n += 1;
    }
    n
}

// ---------------------------------------------------------------------------
// Outbound HTTP, on pool threads.  Nothing here may touch Postgres.
// ---------------------------------------------------------------------------

struct OutboundJob {
    call_id: String,
    call: Value,
}

struct OutboundResult {
    call_id: String,
    status: i32,
    body: String,
}

fn perform_http(call: &Value) -> (i32, String) {
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

    let config = ureq::Agent::config_builder()
        .timeout_global(Some(HTTP_TIMEOUT))
        .http_status_as_error(false)
        // A redirect would be followed without re-running the host guard, which
        // is the standard way to turn an allowlisted URL into an SSRF.
        .max_redirects(0)
        .build();
    let agent = ureq::Agent::new_with_config(config);

    let outcome = if kind == "tool" {
        let mut req = agent.get(url);
        if let Some(h) = headers {
            for (k, v) in h {
                if let Some(s) = v.as_str() {
                    req = req.header(k, s);
                }
            }
        }
        req.call()
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

fn spawn_http_pool(threads: usize) -> (Sender<OutboundJob>, Receiver<OutboundResult>) {
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
                let (status, body) = perform_http(&job.call);
                if out
                    .send(OutboundResult { call_id: job.call_id, status, body })
                    .is_err()
                {
                    return;
                }
            });
    }

    (job_tx, res_rx)
}

// ---------------------------------------------------------------------------
// Runtime worker
// ---------------------------------------------------------------------------

fn valid_uuid(s: &str) -> bool {
    s.len() == 36
        && s.as_bytes().iter().enumerate().all(|(i, b)| match i {
            8 | 13 | 18 | 23 => *b == b'-',
            _ => b.is_ascii_hexdigit(),
        })
}

fn handle_rpc_stream(mut stream: UnixStream, ready: bool) {
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

#[unsafe(no_mangle)]
#[pg_guard]
pub extern "C-unwind" fn allgres_runtime_main(_arg: pg_sys::Datum) {
    BackgroundWorker::attach_signal_handlers(SignalWakeFlags::SIGHUP | SignalWakeFlags::SIGTERM);
    BackgroundWorker::connect_worker_to_spi(Some(&configured_database()), None);

    let rpc = match bind_rpc_socket() {
        Ok(l) => l,
        Err(e) => {
            pgrx::warning!("Allgres RPC bind failed ({}): {}", socket_dir().display(), e);
            return;
        }
    };
    if let Err(e) = rpc.set_nonblocking(true) {
        pgrx::warning!("Allgres RPC nonblocking failed: {}", e);
        return;
    }

    let (jobs, results) = spawn_http_pool(HTTP_THREADS);
    let capacity = HTTP_THREADS * 2;
    let mut in_flight: usize = 0;
    let mut ready = false;
    let mut next_pump = Instant::now();
    let mut idle_delay = PUMP_IDLE_MIN;

    while BackgroundWorker::wait_latch(Some(Duration::from_millis(100))) {
        // 1. Dashboard RPC first: it must never queue behind network I/O.
        loop {
            match rpc.accept() {
                Ok((s, _)) => handle_rpc_stream(s, ready),
                Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => break,
                Err(e) => {
                    pgrx::warning!("Allgres RPC accept: {}", e);
                    break;
                }
            }
        }

        // 2. Harvest whatever the HTTP threads finished since the last tick.
        loop {
            match results.try_recv() {
                Ok(r) => {
                    in_flight = in_flight.saturating_sub(1);
                    submit_http_result(&r.call_id, r.status, &r.body);
                }
                Err(TryRecvError::Empty) | Err(TryRecvError::Disconnected) => break,
            }
        }

        // 3. Pump, on its own schedule and only with spare HTTP capacity.
        if Instant::now() < next_pump {
            continue;
        }

        ready = extension_is_installed();
        let mut queued = 0usize;

        if ready && in_flight < capacity {
            let claimed = dispatch_and_claim(capacity - in_flight);
            if let Some(calls) = claimed.get("calls").and_then(Value::as_array) {
                for call in calls {
                    let Some(id) = call.get("call_id").and_then(Value::as_str) else { continue };
                    if !valid_uuid(id) {
                        continue;
                    }
                    let job = OutboundJob { call_id: id.to_string(), call: call.clone() };
                    if jobs.send(job).is_err() {
                        break;
                    }
                    in_flight += 1;
                    queued += 1;
                }
            }
        }

        // 4. Sandboxed SQL.  This has to run right here on the SPI thread (see
        // the module doc comment), so it is claimed and executed one call at a
        // time rather than handed to the HTTP pool.
        let sql_ran = if ready { pump_sql() } else { 0 };

        if queued > 0 || sql_ran > 0 {
            idle_delay = PUMP_IDLE_MIN;
            next_pump = Instant::now() + PUMP_BUSY;
        } else {
            next_pump = Instant::now() + idle_delay;
            idle_delay = (idle_delay * 2).min(PUMP_IDLE_MAX);
        }
    }

    // Dropping the sender releases the pool threads; the process is exiting, so
    // there is nothing to gain from joining a thread parked in a socket read.
    drop(jobs);
    let _ = fs::remove_file(rpc_socket_path());
}

// ---------------------------------------------------------------------------
// HTTP request parsing
// ---------------------------------------------------------------------------

struct HttpRequest {
    method: String,
    path: String,
    headers: Vec<(String, String)>,
    body: String,
}

impl HttpRequest {
    fn route(&self) -> &str {
        self.path.split('?').next().unwrap_or(&self.path)
    }

    fn query(&self) -> &str {
        self.path.split_once('?').map(|(_, q)| q).unwrap_or("")
    }

    fn header(&self, name: &str) -> Option<&str> {
        self.headers
            .iter()
            .find(|(k, _)| k.eq_ignore_ascii_case(name))
            .map(|(_, v)| v.as_str())
    }
}

fn parse_http_request(data: &[u8]) -> Option<HttpRequest> {
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

fn read_http_request(stream: &mut TcpStream) -> Option<HttpRequest> {
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

// ---------------------------------------------------------------------------
// Web worker
// ---------------------------------------------------------------------------

#[derive(Clone)]
struct WebConfig {
    token: String,
    socket: PathBuf,
    mock_enabled: bool,
}

static WEB_THREADS: AtomicUsize = AtomicUsize::new(0);

fn constant_time_eq(a: &[u8], b: &[u8]) -> bool {
    if a.len() != b.len() {
        return false;
    }
    let mut diff = 0u8;
    for (x, y) in a.iter().zip(b.iter()) {
        diff |= x ^ y;
    }
    diff == 0
}

fn percent_decode(s: &str) -> String {
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

fn authorized(r: &HttpRequest, cfg: &WebConfig) -> bool {
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
    // EventSource cannot set request headers, so the stream endpoint accepts the
    // token as a query parameter.  Nothing else does.
    if r.route() == "/api/v1/events" {
        if let Some(t) = query_param(r.query(), "token") {
            return constant_time_eq(t.as_bytes(), cfg.token.as_bytes());
        }
    }
    false
}

/// A cross-origin browser request must fail even when no token is configured.
/// Two rules do that: reject a mismatched `Origin`, and require a custom header
/// that a form or `<img>` cannot set (which forces a preflight we never allow).
fn csrf_ok(r: &HttpRequest) -> bool {
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
        ("GET", "/api/v1/tasks") => Some(rpc(cfg, &json!({"action": "tasks.list", "limit": 200}))),
        ("GET", "/api/v1/logs") => Some(rpc(cfg, &json!({"action": "logs.list", "limit": 250}))),
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
    let _ = s.set_write_timeout(Some(Duration::from_secs(5)));
    if s.write_all(head.as_bytes()).is_err() {
        return;
    }
    if s.write_all(b"retry: 2000\n\n").is_err() {
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

    if path == "/mock/chat/completions" {
        if !cfg.mock_enabled {
            respond_json(&mut s, "404 Not Found", "{\"ok\":false,\"error\":\"not_found\"}");
            return;
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

    if !authorized(&r, cfg) {
        respond(&mut s, "401 Unauthorized", "application/json",
                "{\"ok\":false,\"error\":\"unauthorized\"}", "WWW-Authenticate: Bearer\r\n");
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
fn check_exposure(addr: &str, token: &str) -> Result<(), String> {
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

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn truncate_utf8(s: &str, max: usize) -> &str {
    if s.len() <= max {
        return s;
    }
    let mut end = max;
    while end > 0 && !s.is_char_boundary(end) {
        end -= 1;
    }
    &s[..end]
}

// ---------------------------------------------------------------------------
// Tests.  These cover the pure request/auth logic and need no database; run
// them with `cargo pgrx test --features pg17`.
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    fn req(raw: &str) -> HttpRequest {
        parse_http_request(raw.as_bytes()).expect("parses")
    }

    #[test]
    fn parses_method_path_headers_and_body() {
        let r = req("POST /api/v1/run?x=1 HTTP/1.1\r\nHost: a:8088\r\nContent-Length: 2\r\n\r\n{}");
        assert_eq!(r.method, "POST");
        assert_eq!(r.route(), "/api/v1/run");
        assert_eq!(r.query(), "x=1");
        assert_eq!(r.header("host"), Some("a:8088"));
        assert_eq!(r.body, "{}");
    }

    #[test]
    fn header_lookup_is_case_insensitive() {
        let r = req("GET / HTTP/1.1\r\nX-Allgres-Client: dashboard\r\n\r\n");
        assert_eq!(r.header("x-allgres-client"), Some("dashboard"));
        assert_eq!(r.header("X-ALLGRES-CLIENT"), Some("dashboard"));
    }

    #[test]
    fn truncated_request_is_rejected() {
        assert!(parse_http_request(b"GET / HTTP/1.1\r\nHost: a").is_none());
    }

    #[test]
    fn constant_time_eq_matches_semantics_of_eq() {
        assert!(constant_time_eq(b"secret", b"secret"));
        assert!(!constant_time_eq(b"secret", b"secreT"));
        assert!(!constant_time_eq(b"secret", b"secret1"));
        assert!(constant_time_eq(b"", b""));
    }

    #[test]
    fn csrf_requires_custom_header_on_api_calls() {
        assert!(!csrf_ok(&req("GET /api/v1/tasks HTTP/1.1\r\nHost: a\r\n\r\n")));
        assert!(csrf_ok(&req(
            "GET /api/v1/tasks HTTP/1.1\r\nHost: a\r\nX-Allgres-Client: dashboard\r\n\r\n"
        )));
    }

    #[test]
    fn csrf_rejects_foreign_origin_and_opaque_origin() {
        assert!(!csrf_ok(&req(
            "POST /api/v1/run HTTP/1.1\r\nHost: a\r\nOrigin: http://evil.test\r\nX-Allgres-Client: d\r\n\r\n"
        )));
        assert!(!csrf_ok(&req(
            "POST /api/v1/run HTTP/1.1\r\nHost: a\r\nOrigin: null\r\nX-Allgres-Client: d\r\n\r\n"
        )));
        assert!(csrf_ok(&req(
            "POST /api/v1/run HTTP/1.1\r\nHost: a\r\nOrigin: http://a\r\nX-Allgres-Client: d\r\n\r\n"
        )));
    }

    #[test]
    fn event_stream_is_exempt_from_the_custom_header() {
        assert!(csrf_ok(&req("GET /api/v1/events HTTP/1.1\r\nHost: a\r\n\r\n")));
    }

    #[test]
    fn token_is_required_when_configured() {
        let cfg = WebConfig {
            token: "s3cr3t".into(),
            socket: PathBuf::from("/dev/null"),
            mock_enabled: false,
        };
        assert!(!authorized(&req("GET /api/v1/tasks HTTP/1.1\r\n\r\n"), &cfg));
        assert!(!authorized(
            &req("GET /api/v1/tasks HTTP/1.1\r\nAuthorization: Bearer nope\r\n\r\n"),
            &cfg
        ));
        assert!(authorized(
            &req("GET /api/v1/tasks HTTP/1.1\r\nAuthorization: Bearer s3cr3t\r\n\r\n"),
            &cfg
        ));
    }

    #[test]
    fn query_token_is_accepted_only_for_the_event_stream() {
        let cfg = WebConfig {
            token: "s3cr3t".into(),
            socket: PathBuf::from("/dev/null"),
            mock_enabled: false,
        };
        assert!(authorized(&req("GET /api/v1/events?token=s3cr3t HTTP/1.1\r\n\r\n"), &cfg));
        assert!(!authorized(&req("GET /api/v1/tasks?token=s3cr3t HTTP/1.1\r\n\r\n"), &cfg));
    }

    #[test]
    fn percent_decoding_handles_escapes_and_plus() {
        assert_eq!(percent_decode("a%20b+c"), "a b c");
        assert_eq!(percent_decode("%2F"), "/");
        assert_eq!(percent_decode("100%"), "100%");
    }

    #[test]
    fn exposure_check_blocks_public_bind_without_token() {
        assert!(check_exposure("127.0.0.1:8088", "").is_ok());
        assert!(check_exposure("0.0.0.0:8088", "token").is_ok());
        assert!(check_exposure("0.0.0.0:8088", "").is_err());
    }

    #[test]
    fn uuid_shape_is_validated_before_it_reaches_a_cast() {
        assert!(valid_uuid("0f6f1b7c-3c2e-4f5a-9a1b-2c3d4e5f6a7b"));
        assert!(!valid_uuid("0f6f1b7c-3c2e-4f5a-9a1b-2c3d4e5f6a7"));
        assert!(!valid_uuid("'; DROP TABLE agents; --"));
    }

    #[test]
    fn truncation_keeps_utf8_boundaries() {
        assert_eq!(truncate_utf8("héllo", 2), "h");
        assert_eq!(truncate_utf8("hello", 99), "hello");
    }

    #[test]
    fn dashboard_html_carries_the_csp_nonce_placeholder() {
        assert_eq!(DASHBOARD_HTML.matches("__CSP_NONCE__").count(), 2);
    }

    // --- node-dump reader -------------------------------------------------
    //
    // These exercise `analyze_dump` against the shape `nodeToString` produces.
    // The end-to-end path (real parser -> real dump) is covered by
    // argo_public.fn_selftest, which runs inside the database.

    fn rangevar(schema: &str, rel: &str) -> String {
        format!("{{RANGEVAR :schemaname {schema} :relname {rel} :inh true :relpersistence p :alias <> :location 14}}")
    }

    fn select_dump(inner: &str) -> String {
        format!("({{RAWSTMT :stmt {{SELECTSTMT :distinctClause <> :intoClause <> :targetList <> :fromClause ({inner}) }} :stmt_location 0 :stmt_len 40}})")
    }

    #[test]
    fn reads_a_schema_qualified_relation() {
        let d = analyze_dump(&select_dump(&rangevar("argo_public", "v_sales")));
        assert_eq!(d["kind"], "select");
        assert_eq!(d["statements"], 1);
        assert_eq!(d["writes"], false);
        assert_eq!(d["relations"][0]["schema"], "argo_public");
        assert_eq!(d["relations"][0]["name"], "v_sales");
    }

    #[test]
    fn reads_every_relation_in_a_comma_join() {
        let inner = format!("{} {}", rangevar("argo_public", "v_sales"), rangevar("argo_private", "sessions"));
        let d = analyze_dump(&select_dump(&inner));
        let rels = d["relations"].as_array().unwrap();
        assert_eq!(rels.len(), 2);
        assert_eq!(rels[1]["schema"], "argo_private");
    }

    #[test]
    fn unqualified_relation_reports_a_null_schema() {
        let d = analyze_dump(&select_dump(&rangevar("<>", "sessions")));
        assert!(d["relations"][0]["schema"].is_null());
        assert_eq!(d["relations"][0]["name"], "sessions");
    }

    #[test]
    fn collects_cte_names() {
        let dump = select_dump(&format!(
            "{{COMMONTABLEEXPR :ctename x :aliascolnames <> :ctequery <> :location 5}} {}",
            rangevar("<>", "x")
        ));
        let d = analyze_dump(&dump);
        assert_eq!(d["ctes"][0], "x");
    }

    #[test]
    fn flags_select_into_and_data_modifying_ctes() {
        let into = "({RAWSTMT :stmt {SELECTSTMT :intoClause {INTOCLAUSE :rel <>} }})";
        assert_eq!(analyze_dump(into)["writes"], true);
        let dml = "({RAWSTMT :stmt {SELECTSTMT :intoClause <> :withClause {INSERTSTMT :relation <>} }})";
        assert_eq!(analyze_dump(dml)["writes"], true);
    }

    #[test]
    fn counts_statements_and_rejects_non_select_kinds() {
        let two = format!("({} {})",
            "{RAWSTMT :stmt {SELECTSTMT :intoClause <>}}",
            "{RAWSTMT :stmt {SELECTSTMT :intoClause <>}}");
        assert_eq!(analyze_dump(&two)["statements"], 2);
        assert_eq!(analyze_dump(&two)["kind"], "other");

        let update = "({RAWSTMT :stmt {UPDATESTMT :relation <>}})";
        assert_eq!(analyze_dump(update)["kind"], "other");
    }

    #[test]
    fn token_reader_handles_escapes_null_and_empty() {
        assert_eq!(read_token("<> :relname x").0, None);
        assert_eq!(read_token("\"\" :x").0, Some(String::new()));
        assert_eq!(read_token("plain rest").0, Some("plain".into()));
        // outToken escapes embedded delimiters and prefixes a leading digit.
        assert_eq!(read_token("odd\\ name rest").0, Some("odd name".into()));
        assert_eq!(read_token("\\2fast rest").0, Some("2fast".into()));
        assert_eq!(read_token("last}").0, Some("last".into()));
    }

    #[test]
    fn collects_function_names_from_a_funcname_list() {
        // Verified against real PG18 nodeToString output: String nodes inside a
        // List serialise as "name", not as {STRING :sval name}.
        let dump = "({RAWSTMT :stmt {SELECTSTMT :intoClause <> :targetList ({RESTARGET :val \
                    {FUNCCALL :funcname (\"pg_sleep\") :args ({A_CONST :val 30})}})}})";
        let d = analyze_dump(dump);
        assert_eq!(d["functions"][0]["name"], "pg_sleep");
        assert!(d["functions"][0]["schema"].is_null());
    }

    #[test]
    fn keeps_the_schema_of_a_qualified_function() {
        let dump = "({RAWSTMT :stmt {SELECTSTMT :intoClause <> \
                    :fromClause ({FUNCCALL :funcname (\"pg_catalog\" \"generate_series\") :args <>})}})";
        let d = analyze_dump(dump);
        assert_eq!(d["functions"][0]["schema"], "pg_catalog");
        assert_eq!(d["functions"][0]["name"], "generate_series");
    }

    #[test]
    fn paren_body_stops_at_its_own_closing_paren() {
        assert_eq!(paren_body("\"a\" \"b\") :args (x)"), "\"a\" \"b\"");
        assert_eq!(paren_body("(nested) tail) rest"), "(nested) tail");
    }

    #[test]
    fn quoted_strings_unescapes() {
        assert_eq!(quoted_strings("\"a\" \"b\""), vec!["a", "b"]);
        assert_eq!(quoted_strings("\"od\\\"d\""), vec!["od\"d"]);
        assert!(quoted_strings("no quotes here").is_empty());
    }

    #[test]
    fn node_body_stops_at_its_own_closing_brace() {
        let s = " :alias {ALIAS :aliasname a} :location 3} :trailing";
        assert!(node_body(s).contains(":aliasname a"));
        assert!(!node_body(s).contains(":trailing"));
    }

    #[test]
    fn unparseable_input_is_reported_rather_than_silently_empty() {
        assert_eq!(analyze_dump("")["ok"], false);
    }
}
