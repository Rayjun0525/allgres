#![allow(long_running_const_eval)]

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

use pgrx::bgworkers::{BackgroundWorkerBuilder, BgWorkerStartTime};
use pgrx::prelude::*;
use pgrx::JsonB;
use serde_json::json;
use std::collections::HashMap;
use std::fs;
use std::time::Duration;

pgrx::pg_module_magic!();

const VERSION: &str = env!("CARGO_PKG_VERSION");
pub(crate) const DEFAULT_DB: &str = "postgres";
/// Loopback by default.  Binding to a public address without a dashboard token
/// is refused unless the operator opts in explicitly (see `check_exposure`).
pub(crate) const DEFAULT_HTTP_ADDR: &str = "127.0.0.1:8088";
pub(crate) const DASHBOARD_HTML: &str = include_str!("../web/index.html");

/// Outbound HTTP threads, and therefore the maximum number of calls claimed
/// per pump.  The SQL watchdog timeout must stay above `HTTP_TIMEOUT`.
pub(crate) const HTTP_THREADS: usize = 4;
pub(crate) const HTTP_TIMEOUT: Duration = Duration::from_secs(45);
pub(crate) const MAX_RESPONSE_BYTES: usize = 200_000;

pub(crate) const PUMP_BUSY: Duration = Duration::from_millis(150);
pub(crate) const PUMP_IDLE_MIN: Duration = Duration::from_millis(500);
pub(crate) const PUMP_IDLE_MAX: Duration = Duration::from_secs(4);

/// Sandboxed SQL executes on the SPI thread itself (it needs SPI, so it can't
/// go on an HTTP pool thread the way outbound calls do), one call at a time,
/// bounded by `SQL_STATEMENT_TIMEOUT_MS` each.  Claiming only one per tick, not a
/// batch, keeps a burst of agent queries from shutting the RPC/dashboard path
/// out for several statement-timeouts in a row.
pub(crate) const SQL_CLAIM_LIMIT: i32 = 1;
/// Milliseconds, the unit both `SET LOCAL statement_timeout` (as a string)
/// and `enable_timeout_after` (as an integer -- see run_sandboxed_sql's own
/// comment on why that call exists at all) need; kept as one constant so
/// the two can never drift apart.
pub(crate) const SQL_STATEMENT_TIMEOUT_MS: i32 = 5000;

pub(crate) const MAX_WEB_THREADS: usize = 64;
pub(crate) const MAX_REQUEST_BYTES: usize = 1 << 20;
pub(crate) const REQUEST_DEADLINE: Duration = Duration::from_secs(5);
pub(crate) const SSE_TOTAL: Duration = Duration::from_secs(30);
pub(crate) const SSE_INTERVAL: Duration = Duration::from_secs(1);
/// A ticket minted by `POST /api/v1/events/ticket` (bearer-token gated) is
/// good for one connection attempt, within this window.  This keeps the
/// long-lived dashboard token out of the one URL that has to carry auth in
/// the query string at all -- `EventSource` cannot set request headers --
/// and therefore out of proxy access logs, browser history, and the
/// Referrer header.  Reconnection is client-driven (see `startEvents` in
/// web/index.html), not the browser's native retry-with-the-same-URL, since
/// a single-use ticket cannot be replayed for that.
pub(crate) const SSE_TICKET_TTL: Duration = Duration::from_secs(30);

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
        JsonB(crate::sql_parser::analyze_dump(&crate::sql_parser::raw_parse_dump(sql)))
    }

    /// Host-level metrics the Overview page shows alongside PostgreSQL's own
    /// `pg_stat_activity` counts (SQL can read those directly -- this is
    /// only for what SQL cannot see: OS CPU load and memory). Linux-only, by
    /// design -- `/proc` is the one interface that needs neither a
    /// subprocess nor a C library binding, matching this file's existing
    /// preference (see `raw_parse_dump` above) for the most direct
    /// interface available rather than the most portable one. Best-effort:
    /// a missing/unreadable file (a non-Linux host, or a locked-down
    /// container) yields `null` for that section rather than an error, so
    /// Overview still renders the parts it can.
    #[pg_extern]
    fn native_host_stats() -> JsonB {
        let load = fs::read_to_string("/proc/loadavg").ok().and_then(|s| {
            let mut it = s.split_whitespace();
            let one: f64 = it.next()?.parse().ok()?;
            let five: f64 = it.next()?.parse().ok()?;
            let fifteen: f64 = it.next()?.parse().ok()?;
            Some(json!({"load1": one, "load5": five, "load15": fifteen}))
        });

        let mem = fs::read_to_string("/proc/meminfo").ok().and_then(|s| {
            let mut kv: HashMap<&str, u64> = HashMap::new();
            for line in s.lines() {
                let mut parts = line.splitn(2, ':');
                let key = parts.next()?;
                let rest = parts.next()?.trim();
                let n: u64 = rest.split_whitespace().next()?.parse().ok()?;
                kv.insert(key, n);
            }
            let total_kb = *kv.get("MemTotal")?;
            // MemAvailable (kernel-estimated, accounts for reclaimable cache)
            // is what every modern `free`-alike reports as "available";
            // MemFree alone overstates memory pressure by not counting cache
            // the kernel would gladly release under pressure.
            let avail_kb = *kv.get("MemAvailable")?;
            let used_kb = total_kb.saturating_sub(avail_kb);
            Some(json!({
                "total_mb": total_kb / 1024,
                "used_mb": used_kb / 1024,
                "available_mb": avail_kb / 1024,
                "used_pct": if total_kb > 0 { (used_kb as f64 / total_kb as f64) * 100.0 } else { 0.0 },
            }))
        });

        let cpu_count = std::thread::available_parallelism().map(|n| n.get()).unwrap_or(0);

        JsonB(json!({
            "load": load,
            "memory": mem,
            "cpu_count": cpu_count,
        }))
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
            "rpc_socket": crate::config::rpc_socket_path().display().to_string(),
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

mod config;
mod http_protocol;
mod outbound;
mod rpc;
mod runtime_worker;
mod sandbox;
mod sql_parser;
mod web;
#[cfg(test)]
mod tests;

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

pub(crate) fn truncate_utf8(s: &str, max: usize) -> &str {
    if s.len() <= max {
        return s;
    }
    let mut end = max;
    while end > 0 && !s.is_char_boundary(end) {
        end -= 1;
    }
    &s[..end]
}
