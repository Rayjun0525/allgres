//! Sandboxed SQL execution -- the other half of sql/control_plane.sql's
//! fn_validate_sql (see that section's own comment below): claims a
//! validated agent statement and runs it as a top-level SPI call issued
//! directly by this worker, which is where `SET ROLE sandbox` is legal.

use crate::rpc::valid_uuid;
use crate::runtime_worker::drop_privileges;
use crate::{SQL_CLAIM_LIMIT, SQL_STATEMENT_TIMEOUT_MS};
use pgrx::bgworkers::BackgroundWorker;
use pgrx::pg_sys::pg_try::PgTryBuilder;
use pgrx::prelude::*;
use pgrx::JsonB;
use serde_json::{json, Value};

// ---------------------------------------------------------------------------
// Sandboxed SQL.  sql/control_plane.sql's fn_validate_sql (SECURITY DEFINER)
// checks an agent statement and hands back its normalized text; PostgreSQL
// forbids SET ROLE inside a SECURITY DEFINER function, so it cannot also run
// it.  These functions are the other half: they claim a validated statement
// and run it as a top-level SPI call, issued directly by this worker with no
// enclosing SECURITY DEFINER frame, which is exactly where SET ROLE sandbox
// is legal.
// ---------------------------------------------------------------------------

pub(crate) fn claim_sql_jobs(limit: i32) -> Value {
    BackgroundWorker::transaction(|| {
        if !drop_privileges() {
            return json!({ "count": 0, "calls": [] });
        }
        Spi::get_one_with_args::<JsonB>("SELECT allgres_public.fn_claim_sql($1)", &[limit.into()])
            .ok()
            .flatten()
            .map(|j| j.0)
            .unwrap_or_else(|| json!({ "count": 0, "calls": [] }))
    })
}

/// A role fn_provision_agent_role could actually have produced: a fixed
/// prefix plus a uuid with its dashes stripped, hex digits only. SET LOCAL
/// ROLE has no parameterized form, so this is what stands between a
/// database value and a string built with `format!` -- belt and suspenders
/// alongside the fact that the column this comes from is only ever written
/// by that one function, never by anything agent- or operator-controlled.
fn valid_pg_role(s: &str) -> bool {
    s.strip_prefix("allgres_agent_")
        .is_some_and(|hex| hex.len() == 32 && hex.bytes().all(|b| b.is_ascii_hexdigit()))
}

/// Runs `f` inside its own subtransaction so a Postgres ERROR raised while
/// it runs is caught and the enclosing transaction kept alive afterward,
/// instead of the error propagating out of the pump loop and terminating
/// the whole worker process. Needed specifically for query cancellation
/// (`pg_cancel_backend`, the real-time "stop" button's own mechanism for a
/// stuck sandboxed statement): confirmed live that a plain PL/pgSQL
/// `BEGIN ... EXCEPTION WHEN OTHERS ... END` around a cancelled `pg_sleep`
/// never reaches its handler at all -- plpgsql's own exception handling
/// does not trap a query cancellation, full stop, no matter how it is
/// nested -- so `fn_run_sandboxed_sql`'s own exception block (needed for
/// every *other* kind of SQL error an agent's own query can raise) cannot
/// cover this one case. Before this existed, cancelling an in-flight
/// sandboxed statement crashed the "allgres runtime" worker outright
/// (`SIGINT` from `pg_cancel_backend` reached this backend, became a real
/// `ERROR`, and nothing between here and `allgres_runtime_main`'s own
/// top-level pg_guard caught it) -- restarted automatically
/// (`set_restart_time`), but every agent's task processing paused for the
/// few seconds that took, on every single cancel, not just this one.
///
/// Mirrors the same `BeginInternalSubTransaction` /
/// `RollbackAndReleaseCurrentSubTransaction` pattern PL/pgSQL's own
/// exception handling uses internally in C -- one level below plpgsql's
/// own exception semantics, where a cancellation is just as catchable as
/// any other error. Per `BeginInternalSubTransaction`'s own doc comment,
/// the caller is responsible for restoring `CurrentMemoryContext` and
/// `CurrentResourceOwner` itself after a rollback, which is what the
/// explicit switches/restores below are for.
///
/// This only protects against a cancellation once one is actually
/// delivered to and processed by this worker's current statement -- see
/// `fn_signal_cancel_worker`'s own comment in `sql/control_plane.sql` for
/// why that delivery itself is not yet confirmed reliable: this worker
/// requests only `SIGHUP`/`SIGTERM` wake flags, and a stuck sandboxed
/// query was observed live to keep running well past both a
/// `pg_cancel_backend` call against this exact pid and its own
/// `statement_timeout`, with no cancellation error ever logged.
fn run_in_subtransaction<F>(f: F) -> Result<Value, String>
where
    F: FnOnce() -> Result<Value, String> + std::panic::UnwindSafe,
{
    let old_context = unsafe { pg_sys::CurrentMemoryContext };
    let old_owner = unsafe { pg_sys::CurrentResourceOwner };

    unsafe {
        pg_sys::BeginInternalSubTransaction(std::ptr::null());
        // BeginInternalSubTransaction switches to the subtransaction's own
        // memory context; run the closure in the caller's own context
        // instead so nothing it builds is freed out from under it when the
        // subtransaction ends.
        pg_sys::MemoryContextSwitchTo(old_context);
    }

    let result = PgTryBuilder::new(f)
        .catch_others(|caught| {
            let message = match &caught {
                pg_sys::panic::CaughtError::PostgresError(e)
                | pg_sys::panic::CaughtError::ErrorReport(e) => e.message().to_string(),
                pg_sys::panic::CaughtError::RustPanic { ereport, .. } => ereport.message().to_string(),
            };
            unsafe {
                pg_sys::MemoryContextSwitchTo(old_context);
                pg_sys::RollbackAndReleaseCurrentSubTransaction();
                pg_sys::MemoryContextSwitchTo(old_context);
                pg_sys::CurrentResourceOwner = old_owner;
            }
            Err(message)
        })
        .execute();

    if result.is_ok() {
        unsafe {
            pg_sys::MemoryContextSwitchTo(old_context);
            pg_sys::ReleaseCurrentSubTransaction();
            pg_sys::MemoryContextSwitchTo(old_context);
            pg_sys::CurrentResourceOwner = old_owner;
        }
    }

    result
}

/// Runs one already-validated agent statement as the agent's own sandboxed
/// role if it has one (see fn_provision_agent_role), or the shared
/// `sandbox` role for an agent that predates per-agent roles. `sql` must be
/// `fn_validate_sql`'s return value, never raw agent input: this function
/// trusts it completely and so does the database function it calls.
/// Not in pgrx's generated bindings (utils/timeout.h is outside its
/// bindgen allowlist), declared by hand instead. TimeoutId's first four
/// entries -- STARTUP_PACKET_TIMEOUT=0, DEADLOCK_TIMEOUT=1, LOCK_TIMEOUT=2,
/// STATEMENT_TIMEOUT=3 -- have held this order across every Postgres major
/// version that has ever shipped `utils/timeout.h`'s `TimeoutId` enum;
/// every timeout reason added since has been appended after them, never
/// inserted before, which is what makes hardcoding 3 here safe across
/// pg16/17/18 rather than something that needs a per-version binding.
const PG_STATEMENT_TIMEOUT_ID: std::ffi::c_int = 3;

unsafe extern "C" {
    fn enable_timeout_after(id: std::ffi::c_int, delay_ms: std::ffi::c_int);
    fn disable_timeout(id: std::ffi::c_int, keep_indicator: bool);
}

fn run_sandboxed_sql(agent_id: &str, sql: &str, pg_role: Option<&str>) -> Result<Value, String> {
    let role = pg_role.filter(|r| valid_pg_role(r)).unwrap_or("sandbox");
    BackgroundWorker::transaction(|| {
        run_in_subtransaction(|| {
            let dropped = drop_privileges()
                && Spi::run(&format!("SET LOCAL ROLE {role}")).is_ok()
                && Spi::run("SET LOCAL search_path = pg_temp").is_ok()
                && Spi::run("SET LOCAL transaction_read_only = on").is_ok()
                && Spi::run(&format!("SET LOCAL statement_timeout = '{SQL_STATEMENT_TIMEOUT_MS}ms'")).is_ok()
                && Spi::run_with_args(
                    "SELECT set_config('allgres.agent_id', $1, true)",
                    &[agent_id.into()],
                )
                .is_ok();
            if !dropped {
                return Err("sandbox role unavailable".to_string());
            }
            // SET LOCAL statement_timeout (above) only sets the GUC value --
            // it does not by itself arm the actual timer. In a normal
            // client backend that happens once per query in
            // tcop/postgres.c's own dispatch (exec_simple_query), which
            // this background worker's BackgroundWorker::transaction (a
            // bare StartTransactionCommand/CommitTransactionCommand pair,
            // nothing that goes through postgres.c at all) never runs.
            // Confirmed live: without this call, a 30-second pg_sleep ran
            // to completion untouched with statement_timeout showing '5s'
            // the whole time -- the GUC was set, nothing was ever
            // listening for it. This is what actually bounds a stuck
            // sandboxed statement (and, combined with
            // fn_signal_cancel_worker's pg_cancel_backend, is also what
            // makes the operator "stop" button interrupt one in real
            // time: same run_in_subtransaction recovery either way).
            unsafe {
                enable_timeout_after(PG_STATEMENT_TIMEOUT_ID, SQL_STATEMENT_TIMEOUT_MS);
            }
            let r = match Spi::get_one_with_args::<JsonB>(
                "SELECT allgres_public.fn_run_sandboxed_sql($1)",
                &[sql.into()],
            ) {
                Ok(Some(JsonB(v))) => Ok(v),
                Ok(None) => Err("sandboxed execution returned nothing".to_string()),
                Err(e) => Err(e.to_string()),
            };
            unsafe {
                disable_timeout(PG_STATEMENT_TIMEOUT_ID, false);
            }
            r
        })
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
        if !drop_privileges() {
            // Same reasoning as submit_http_result: the row stays
            // 'in_flight' and fn_watchdog's existing reclaim-as-'lost'
            // path picks it up, rather than this recording a result under
            // the bootstrap superuser.
            pgrx::warning!(
                "Allgres: skipping fn_complete_sql for call {} -- privilege drop failed",
                call_id
            );
            return;
        }
        if let Err(e) = Spi::get_one_with_args::<JsonB>(
            "SELECT allgres_public.fn_complete_sql($1::uuid, $2, $3, $4, $5, $6)",
            &[
                call_id.into(),
                ok.into(),
                rows.map(JsonB).into(),
                row_count.into(),
                truncated.into(),
                error.into(),
            ],
        ) {
            pgrx::warning!("Allgres: fn_complete_sql failed for call {}: {}", call_id, e);
        }
    });
}

/// Claims up to `SQL_CLAIM_LIMIT` queued sandboxed-SQL calls and runs each to
/// completion.  Returns how many it processed, so the pump loop's idle
/// backoff treats this like any other unit of work.
pub(crate) fn pump_sql() -> usize {
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
        let pg_role = call.get("pg_role").and_then(Value::as_str);
        let outcome = run_sandboxed_sql(agent_id, sql, pg_role);
        submit_sql_result(call_id, outcome);
        n += 1;
    }
    n
}

