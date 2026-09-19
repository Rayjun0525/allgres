//! Real PL/pgSQL Functions -- the `plpgsql` handler's other half (see
//! sql/control_plane.sql's `allgres_private.functions` and this module's
//! close mirror, src/sandbox.rs): builds a Function's real Postgres
//! object as `allgres_function_admin`, and later calls it as the
//! invoking agent's own role, both as top-level SPI statements this
//! worker issues directly -- the only place `SET ROLE` is legal
//! (PostgreSQL forbids it inside a SECURITY DEFINER function, the same
//! restriction sandbox.rs's own module comment explains).

use crate::rpc::valid_uuid;
use crate::runtime_worker::drop_privileges;
use crate::sandbox::{run_in_subtransaction, valid_pg_role, PG_STATEMENT_TIMEOUT_ID};
use crate::{SQL_CLAIM_LIMIT, SQL_STATEMENT_TIMEOUT_MS};
use pgrx::bgworkers::BackgroundWorker;
use pgrx::prelude::*;
use pgrx::JsonB;
use serde_json::{json, Value};
use std::time::{SystemTime, UNIX_EPOCH};

unsafe extern "C" {
    fn enable_timeout_after(id: std::ffi::c_int, delay_ms: std::ffi::c_int);
    fn disable_timeout(id: std::ffi::c_int, keep_indicator: bool);
}

/// A sql_ident fn_create_function/fn_create_procedure could actually have
/// produced: `prefix` (`fn_` or `proc_`) plus a uuid with its dashes
/// stripped. Same belt-and-suspenders reasoning as sandbox.rs's
/// `valid_pg_role` -- this is interpolated directly into a
/// schema-qualified object name (`format!`, no parameterized form exists
/// for that), and the column it comes from is only ever written by those
/// two functions, never by anything agent- or operator-controlled. Also
/// used by src/procedure_exec.rs, for its own `proc_` idents.
pub(crate) fn valid_sql_ident(s: &str, prefix: &str) -> bool {
    s.strip_prefix(prefix)
        .is_some_and(|hex| hex.len() == 32 && hex.bytes().all(|b| b.is_ascii_hexdigit()))
}

pub(crate) fn claim_function_build_jobs(limit: i32) -> Value {
    BackgroundWorker::transaction(|| {
        if !drop_privileges() {
            return json!({ "count": 0, "builds": [] });
        }
        Spi::get_one_with_args::<JsonB>("SELECT allgres_public.fn_claim_function_builds($1)", &[limit.into()])
            .ok()
            .flatten()
            .map(|j| j.0)
            .unwrap_or_else(|| json!({ "count": 0, "builds": [] }))
    })
}

/// Dollar-quotes `body` with a tag that does not itself appear in it, so
/// the CREATE FUNCTION statement's own body text is exactly `body`,
/// verbatim, regardless of what characters or keywords it contains --
/// there is no further escaping needed or possible for a PL/pgSQL
/// function body. The tag only has to be unique against this one body,
/// not globally or cryptographically random.
pub(crate) fn dollar_quote(body: &str) -> (String, String) {
    let nanos = SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_nanos()).unwrap_or(0);
    let mut tag = format!("body_{nanos:x}");
    while body.contains(&format!("${tag}$")) {
        tag.push('x');
    }
    let quoted = format!("${tag}$\n{body}\n${tag}$");
    (tag, quoted)
}

/// Builds one Function's real Postgres object. `SECURITY INVOKER` is
/// fixed here, in the statement this function itself constructs, not
/// something the author's `body` can override -- see
/// allgres_private.validate_function_body's own rejection of a body that
/// tries to declare `SECURITY DEFINER` for the same reason, defense in
/// depth against the same confused-deputy attempt.
fn run_function_build(sql_ident: &str, body: &str) -> Result<(), String> {
    if !valid_sql_ident(sql_ident, "fn_") {
        return Err("invalid sql_ident".to_string());
    }
    let (_tag, quoted_body) = dollar_quote(body);
    let ddl = format!(
        "CREATE OR REPLACE FUNCTION allgres_functions.{sql_ident}(p_args jsonb) RETURNS jsonb LANGUAGE plpgsql SECURITY INVOKER AS {quoted_body};"
    );
    BackgroundWorker::transaction(|| {
        run_in_subtransaction(|| {
            if !drop_privileges() || Spi::run("SET LOCAL ROLE allgres_function_admin").is_err() {
                return Err("allgres_function_admin role unavailable".to_string());
            }
            Spi::run(&ddl).map(|_| Value::Null).map_err(|e| e.to_string())
        })
    })
    .map(|_| ())
}

fn submit_function_build_result(function_id: &str, outcome: Result<(), String>) {
    let (ok, error) = match outcome {
        Ok(()) => (true, None),
        Err(e) => (false, Some(e)),
    };
    BackgroundWorker::transaction(|| {
        if !drop_privileges() {
            // Same reasoning as submit_sql_result: the row stays 'building'
            // and fn_watchdog's own reclaim-to-'pending' path picks it up
            // for the next build cycle, rather than this recording a
            // result under the bootstrap superuser.
            pgrx::warning!(
                "Allgres: skipping fn_complete_function_build for {} -- privilege drop failed",
                function_id
            );
            return;
        }
        if let Err(e) = Spi::run_with_args(
            "SELECT allgres_public.fn_complete_function_build($1::uuid, $2, $3)",
            &[function_id.into(), ok.into(), error.into()],
        ) {
            pgrx::warning!("Allgres: fn_complete_function_build failed for {}: {}", function_id, e);
        }
    });
}

/// Claims and builds up to `SQL_CLAIM_LIMIT` pending Functions. Same
/// one-at-a-time-per-tick reasoning as pump_sql: this runs on the SPI
/// thread itself, bounded by `SQL_STATEMENT_TIMEOUT_MS` (a build is
/// DDL, not agent-authored `SELECT`, but the same statement_timeout via
/// `SET LOCAL` still bounds a pathological body's compile time).
pub(crate) fn pump_function_builds() -> usize {
    let claimed = claim_function_build_jobs(SQL_CLAIM_LIMIT);
    let mut n = 0usize;
    let Some(builds) = claimed.get("builds").and_then(Value::as_array) else {
        return 0;
    };
    for b in builds {
        let (Some(function_id), Some(sql_ident), Some(body)) = (
            b.get("function_id").and_then(Value::as_str),
            b.get("sql_ident").and_then(Value::as_str),
            b.get("body").and_then(Value::as_str),
        ) else {
            continue;
        };
        if !valid_uuid(function_id) {
            continue;
        }
        let outcome = run_function_build(sql_ident, body);
        submit_function_build_result(function_id, outcome);
        n += 1;
    }
    n
}

pub(crate) fn claim_function_call_jobs(limit: i32) -> Value {
    BackgroundWorker::transaction(|| {
        if !drop_privileges() {
            return json!({ "count": 0, "calls": [] });
        }
        Spi::get_one_with_args::<JsonB>("SELECT allgres_public.fn_claim_function_calls($1)", &[limit.into()])
            .ok()
            .flatten()
            .map(|j| j.0)
            .unwrap_or_else(|| json!({ "count": 0, "calls": [] }))
    })
}

/// Runs one already-built Function as the calling agent's own role if it
/// has one, or the shared `sandbox` role for an agent that predates
/// per-agent roles -- identical fallback to sandbox.rs's
/// `run_sandboxed_sql`. Unlike that function, there is no separately
/// validated SQL text to shape here: the built Function *is* the
/// sandboxed artifact, so this just calls it with the agent's own args.
fn run_function_call(sql_ident: &str, args: &Value, pg_role: Option<&str>) -> Result<Value, String> {
    if !valid_sql_ident(sql_ident, "fn_") {
        return Err("invalid sql_ident".to_string());
    }
    let role = pg_role.filter(|r| valid_pg_role(r)).unwrap_or("sandbox");
    let sql = format!("SELECT allgres_functions.{sql_ident}($1::jsonb)");
    let args = args.clone();
    BackgroundWorker::transaction(|| {
        run_in_subtransaction(|| {
            let dropped = drop_privileges()
                && Spi::run(&format!("SET LOCAL ROLE {role}")).is_ok()
                && Spi::run("SET LOCAL search_path = pg_temp").is_ok()
                && Spi::run(&format!("SET LOCAL statement_timeout = '{SQL_STATEMENT_TIMEOUT_MS}ms'")).is_ok();
            if !dropped {
                return Err("function role unavailable".to_string());
            }
            // See run_sandboxed_sql's own comment on why this call is
            // needed at all: SET LOCAL statement_timeout alone never arms
            // the timer outside a normal client backend's own dispatch.
            unsafe {
                enable_timeout_after(PG_STATEMENT_TIMEOUT_ID, SQL_STATEMENT_TIMEOUT_MS);
            }
            let r = match Spi::get_one_with_args::<JsonB>(&sql, &[JsonB(args).into()]) {
                Ok(Some(JsonB(v))) => Ok(v),
                Ok(None) => Ok(Value::Null),
                Err(e) => Err(e.to_string()),
            };
            unsafe {
                disable_timeout(PG_STATEMENT_TIMEOUT_ID, false);
            }
            r
        })
    })
}

fn submit_function_call_result(call_id: &str, outcome: Result<Value, String>) {
    let (ok, result, error) = match outcome {
        Ok(v) => (true, Some(v), None),
        Err(e) => (false, None, Some(e)),
    };
    BackgroundWorker::transaction(|| {
        if !drop_privileges() {
            pgrx::warning!(
                "Allgres: skipping fn_complete_function_call for call {} -- privilege drop failed",
                call_id
            );
            return;
        }
        if let Err(e) = Spi::get_one_with_args::<JsonB>(
            "SELECT allgres_public.fn_complete_function_call($1::uuid, $2, $3, $4)",
            &[call_id.into(), ok.into(), result.map(JsonB).into(), error.into()],
        ) {
            pgrx::warning!("Allgres: fn_complete_function_call failed for call {}: {}", call_id, e);
        }
    });
}

/// Claims up to `SQL_CLAIM_LIMIT` queued Function calls and runs each to
/// completion. Returns how many it processed, same idle-backoff
/// contract as pump_sql/pump_function_builds.
pub(crate) fn pump_function_calls() -> usize {
    let claimed = claim_function_call_jobs(SQL_CLAIM_LIMIT);
    let mut n = 0usize;
    let Some(calls) = claimed.get("calls").and_then(Value::as_array) else {
        return 0;
    };
    for call in calls {
        let (Some(call_id), Some(sql_ident)) = (
            call.get("call_id").and_then(Value::as_str),
            call.get("sql_ident").and_then(Value::as_str),
        ) else {
            continue;
        };
        if !valid_uuid(call_id) {
            continue;
        }
        let args = call.get("args").cloned().unwrap_or_else(|| json!({}));
        let pg_role = call.get("pg_role").and_then(Value::as_str);
        let outcome = run_function_call(sql_ident, &args, pg_role);
        submit_function_call_result(call_id, outcome);
        n += 1;
    }
    n
}
