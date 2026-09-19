//! Real PL/pgSQL Procedures -- the `run_procedure` action's other half
//! (see sql/control_plane.sql's `allgres_private.procedures` and this
//! module's close mirror, src/function_exec.rs, whose `dollar_quote`/
//! `valid_sql_ident` helpers this module reuses). Builds a Procedure's
//! real Postgres object as `allgres_function_admin`, and later calls it
//! as the invoking agent's own role -- identical reasoning to
//! src/function_exec.rs's own module comment, just `CALL` instead of
//! `SELECT` and an `INOUT` result parameter instead of a return value,
//! since PL/pgSQL procedures have no `RETURNS` clause of their own.
//! A procedure's own body calling a bound Function is an ordinary nested
//! statement in this same already-role-switched session -- no second
//! queue round trip, since the SET ROLE dance only exists to get *into*
//! this session in the first place, not for every call made once inside
//! it.

use crate::function_exec::{dollar_quote, valid_sql_ident};
use crate::rpc::valid_uuid;
use crate::runtime_worker::drop_privileges;
use crate::sandbox::{run_in_subtransaction, valid_pg_role, PG_STATEMENT_TIMEOUT_ID};
use crate::{PROCEDURE_CALL_TIMEOUT_MS, SQL_CLAIM_LIMIT};
use pgrx::bgworkers::BackgroundWorker;
use pgrx::prelude::*;
use pgrx::JsonB;
use serde_json::{json, Value};

unsafe extern "C" {
    fn enable_timeout_after(id: std::ffi::c_int, delay_ms: std::ffi::c_int);
    fn disable_timeout(id: std::ffi::c_int, keep_indicator: bool);
}

pub(crate) fn claim_procedure_build_jobs(limit: i32) -> Value {
    BackgroundWorker::transaction(|| {
        if !drop_privileges() {
            return json!({ "count": 0, "builds": [] });
        }
        Spi::get_one_with_args::<JsonB>("SELECT allgres_public.fn_claim_procedure_builds($1)", &[limit.into()])
            .ok()
            .flatten()
            .map(|j| j.0)
            .unwrap_or_else(|| json!({ "count": 0, "builds": [] }))
    })
}

/// Builds one Procedure's real Postgres object. `SECURITY INVOKER` is
/// fixed here, in the statement this function itself constructs, not
/// something the author's `body` can override -- same reasoning as
/// function_exec.rs's `run_function_build`. `INOUT p_result jsonb` is
/// the only way a PL/pgSQL procedure hands anything back to its caller
/// (procedures have no `RETURNS` clause); the body is expected to end by
/// assigning it, the same convention a plpgsql Function's body ending in
/// `RETURN` already establishes.
fn run_procedure_build(sql_ident: &str, body: &str) -> Result<(), String> {
    if !valid_sql_ident(sql_ident, "proc_") {
        return Err("invalid sql_ident".to_string());
    }
    let (_tag, quoted_body) = dollar_quote(body);
    let ddl = format!(
        "CREATE OR REPLACE PROCEDURE allgres_functions.{sql_ident}(p_args jsonb, INOUT p_result jsonb) LANGUAGE plpgsql SECURITY INVOKER AS {quoted_body};"
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

fn submit_procedure_build_result(procedure_id: &str, outcome: Result<(), String>) {
    let (ok, error) = match outcome {
        Ok(()) => (true, None),
        Err(e) => (false, Some(e)),
    };
    BackgroundWorker::transaction(|| {
        if !drop_privileges() {
            pgrx::warning!(
                "Allgres: skipping fn_complete_procedure_build for {} -- privilege drop failed",
                procedure_id
            );
            return;
        }
        if let Err(e) = Spi::run_with_args(
            "SELECT allgres_public.fn_complete_procedure_build($1::uuid, $2, $3)",
            &[procedure_id.into(), ok.into(), error.into()],
        ) {
            pgrx::warning!("Allgres: fn_complete_procedure_build failed for {}: {}", procedure_id, e);
        }
    });
}

/// Claims and builds up to `SQL_CLAIM_LIMIT` pending Procedures. Same
/// tier and reasoning as pump_function_builds: SPI thread, one claim per
/// tick, `SQL_STATEMENT_TIMEOUT_MS`-bounded.
pub(crate) fn pump_procedure_builds() -> usize {
    let claimed = claim_procedure_build_jobs(SQL_CLAIM_LIMIT);
    let mut n = 0usize;
    let Some(builds) = claimed.get("builds").and_then(Value::as_array) else {
        return 0;
    };
    for b in builds {
        let (Some(procedure_id), Some(sql_ident), Some(body)) = (
            b.get("procedure_id").and_then(Value::as_str),
            b.get("sql_ident").and_then(Value::as_str),
            b.get("body").and_then(Value::as_str),
        ) else {
            continue;
        };
        if !valid_uuid(procedure_id) {
            continue;
        }
        let outcome = run_procedure_build(sql_ident, body);
        submit_procedure_build_result(procedure_id, outcome);
        n += 1;
    }
    n
}

pub(crate) fn claim_procedure_call_jobs(limit: i32) -> Value {
    BackgroundWorker::transaction(|| {
        if !drop_privileges() {
            return json!({ "count": 0, "calls": [] });
        }
        Spi::get_one_with_args::<JsonB>("SELECT allgres_public.fn_claim_procedure_calls($1)", &[limit.into()])
            .ok()
            .flatten()
            .map(|j| j.0)
            .unwrap_or_else(|| json!({ "count": 0, "calls": [] }))
    })
}

/// Runs one already-built Procedure as the calling agent's own role, same
/// fallback-to-`sandbox` shape as run_function_call. `CALL proc(args,
/// result)` returns a one-row result exactly like `SELECT fn(args)`
/// does when the procedure has an OUT/INOUT parameter (documented
/// Postgres behavior since procedures were introduced in PG11) -- so the
/// same `Spi::get_one_with_args::<JsonB>` read that works for a Function
/// call also works here, just against a `CALL` statement instead of a
/// `SELECT`. The second argument is the INOUT parameter's initial value,
/// required syntactically even though the body always overwrites it.
/// Bounded by `PROCEDURE_CALL_TIMEOUT_MS`, not the shorter
/// `SQL_STATEMENT_TIMEOUT_MS` a plain Function call uses: unlike a
/// Function, a Procedure's body may call `allgres_private.fn_llm_complete`
/// (Phase 3e), a real synchronous HTTP round trip on this same thread.
fn run_procedure_call(sql_ident: &str, args: &Value, pg_role: Option<&str>) -> Result<Value, String> {
    if !valid_sql_ident(sql_ident, "proc_") {
        return Err("invalid sql_ident".to_string());
    }
    let role = pg_role.filter(|r| valid_pg_role(r)).unwrap_or("sandbox");
    let sql = format!("CALL allgres_functions.{sql_ident}($1::jsonb, '{{}}'::jsonb)");
    let args = args.clone();
    BackgroundWorker::transaction(|| {
        run_in_subtransaction(|| {
            let dropped = drop_privileges()
                && Spi::run(&format!("SET LOCAL ROLE {role}")).is_ok()
                && Spi::run("SET LOCAL search_path = pg_temp").is_ok()
                && Spi::run(&format!("SET LOCAL statement_timeout = '{PROCEDURE_CALL_TIMEOUT_MS}ms'")).is_ok();
            if !dropped {
                return Err("procedure role unavailable".to_string());
            }
            unsafe {
                enable_timeout_after(PG_STATEMENT_TIMEOUT_ID, PROCEDURE_CALL_TIMEOUT_MS);
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

fn submit_procedure_call_result(call_id: &str, outcome: Result<Value, String>) {
    let (ok, result, error) = match outcome {
        Ok(v) => (true, Some(v), None),
        Err(e) => (false, None, Some(e)),
    };
    BackgroundWorker::transaction(|| {
        if !drop_privileges() {
            pgrx::warning!(
                "Allgres: skipping fn_complete_procedure_call for call {} -- privilege drop failed",
                call_id
            );
            return;
        }
        if let Err(e) = Spi::get_one_with_args::<JsonB>(
            "SELECT allgres_public.fn_complete_procedure_call($1::uuid, $2, $3, $4)",
            &[call_id.into(), ok.into(), result.map(JsonB).into(), error.into()],
        ) {
            pgrx::warning!("Allgres: fn_complete_procedure_call failed for call {}: {}", call_id, e);
        }
    });
}

/// Claims up to `SQL_CLAIM_LIMIT` queued procedure calls and runs each to
/// completion. Same idle-backoff contract as pump_function_calls.
pub(crate) fn pump_procedure_calls() -> usize {
    let claimed = claim_procedure_call_jobs(SQL_CLAIM_LIMIT);
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
        let outcome = run_procedure_call(sql_ident, &args, pg_role);
        submit_procedure_call_result(call_id, outcome);
        n += 1;
    }
    n
}
