//! The `allgres runtime` background worker: SPI thread + a pool of HTTP
//! threads (see the crate-level doc comment in lib.rs for the two-worker
//! split). The SPI thread here only ever runs short transactions (pump,
//! RPC); every blocking network call happens on a pool thread in
//! `crate::outbound`, and sandboxed agent SQL runs in `crate::sandbox`,
//! on this same SPI thread since it needs SPI directly, with no enclosing
//! SECURITY DEFINER frame.

use crate::config::{bind_rpc_socket, configured_database, rpc_socket_path, socket_dir};
use crate::outbound::{spawn_http_pool, OutboundJob, OutboundQueue, OUTBOUND_CANCEL_FLAGS};
use crate::rpc::{handle_rpc_stream, valid_uuid};
use crate::sandbox::pump_sql;
use crate::truncate_utf8;
use crate::{HTTP_THREADS, HTTP_TIMEOUT, MAX_RESPONSE_BYTES, PUMP_BUSY, PUMP_IDLE_MAX, PUMP_IDLE_MIN};
use pgrx::bgworkers::{BackgroundWorker, SignalWakeFlags};
use pgrx::prelude::*;
use pgrx::JsonB;
use serde_json::{json, Value};
use std::fs;
use std::sync::atomic::Ordering;
use std::sync::mpsc::TryRecvError;
use std::time::{Duration, Instant};

pub(crate) fn extension_is_installed() -> bool {
    BackgroundWorker::transaction(|| {
        Spi::get_one::<bool>("SELECT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'allgres')")
            .ok()
            .flatten()
            .unwrap_or(false)
    })
}

/// Privilege drop, run at the top of every runtime transaction. The worker
/// connects as the bootstrap superuser so a not-yet-created role can never
/// crash-loop it at startup; this puts ordinary work back on `worker`.
/// Returns whether the drop actually landed. Every call site below checks
/// this and skips its own SPI calls when it is false, rather than
/// proceeding with `current_user` still the bootstrap superuser: this used
/// to only log a warning and continue regardless (silent before that, and
/// silently fail-open even after -- an external review caught the second
/// half). Most of what these call sites invoke is SECURITY DEFINER control-
/// plane functions, so which role called them does not change what runs
/// inside (SECURITY DEFINER always executes as the function's *owner*,
/// which "12. Grants"' ownership-transfer block makes allgres_owner, not
/// whoever is connected) -- but `run_sandboxed_sql` is the one path where
/// current_user is the actual, primary trust boundary (agent-generated SQL
/// runs as a top-level statement specifically so it *can* SET ROLE, see
/// "The SQL sandbox" in README), and treating every call site the same way
/// is what keeps that boundary from silently depending on which code path
/// happens to reach it, now or after some future change.
pub(crate) fn drop_privileges() -> bool {
    if std::env::var("ALLGRES_DROP_PRIVILEGES").as_deref() == Ok("0") {
        return true;
    }
    match Spi::get_one::<bool>("SELECT allgres.assume_worker_role()") {
        Ok(Some(true)) => true,
        Ok(Some(false)) => {
            pgrx::warning!("Allgres: assume_worker_role() reports the worker role is not ready");
            false
        }
        Ok(None) => {
            pgrx::warning!("Allgres: assume_worker_role() returned no result");
            false
        }
        Err(e) => {
            pgrx::warning!("Allgres: assume_worker_role() failed: {}", e);
            false
        }
    }
}

/// The SPI-thread half of real-time HTTP/LLM cancellation: for every
/// outbound call an HTTP thread is *currently* running (present in
/// `OUTBOUND_CANCEL_FLAGS`), check whether fn_cancel_session has since
/// marked its `outbound_calls` row 'lost' -- and if so, flip that call's
/// flag so `CancellableTransport` notices within one `CANCEL_POLL_INTERVAL`
/// instead of only when the request would otherwise time out on its own.
/// An HTTP thread must never touch Postgres itself (this module's own
/// header comment), which is exactly why this lives here instead of in
/// `perform_http`. A no-op query (empty id list) when nothing is in
/// flight, so this costs nothing on an idle worker.
fn propagate_outbound_cancellations() {
    let ids: Vec<String> = match OUTBOUND_CANCEL_FLAGS.lock() {
        Ok(map) => map.keys().cloned().collect(),
        Err(_) => return,
    };
    if ids.is_empty() {
        return;
    }
    let lost: Vec<String> = BackgroundWorker::transaction(|| {
        if !drop_privileges() {
            return Vec::new();
        }
        match Spi::get_one_with_args::<JsonB>(
            "SELECT to_jsonb(allgres_public.fn_check_lost_outbound($1::text[]::uuid[]))",
            &[ids.into()],
        ) {
            Ok(Some(JsonB(v))) => v
                .as_array()
                .map(|a| a.iter().filter_map(|x| x.as_str().map(str::to_string)).collect())
                .unwrap_or_default(),
            _ => Vec::new(),
        }
    });
    if lost.is_empty() {
        return;
    }
    if let Ok(map) = OUTBOUND_CANCEL_FLAGS.lock() {
        for call_id in &lost {
            if let Some(flag) = map.get(call_id) {
                flag.store(true, Ordering::Relaxed);
            }
        }
    }
}

fn dispatch_and_claim(limit: usize) -> Value {
    BackgroundWorker::transaction(|| {
        if !drop_privileges() {
            return json!({ "count": 0, "calls": [] });
        }
        if let Err(e) = Spi::get_one_with_args::<JsonB>(
            "SELECT allgres_public.fn_watchdog($1)",
            &[(HTTP_TIMEOUT.as_secs() as i32 * 2).into()],
        ) {
            pgrx::warning!("Allgres: fn_watchdog failed: {}", e);
        }
        if let Err(e) = Spi::get_one::<JsonB>("SELECT allgres_public.fn_dispatch_tasks()") {
            pgrx::warning!("Allgres: fn_dispatch_tasks failed: {}", e);
        }
        Spi::get_one_with_args::<JsonB>(
            "SELECT allgres_public.fn_claim_outbound($1)",
            &[(limit as i32).into()],
        )
        .ok()
        .flatten()
        .map(|j| j.0)
        .unwrap_or_else(|| json!({ "count": 0, "calls": [] }))
    })
}

/// Claims queued OAuth token-exchange rows for the HTTP pool -- the client
/// secret is already resolved and merged into each call's body by
/// fn_claim_oauth itself (claim-time credential injection, the same shape as
/// dispatch_and_claim's fn_claim_outbound), so this is a plain claim with no
/// separate secret-fetch step here.
fn claim_oauth_jobs(limit: i32) -> Value {
    BackgroundWorker::transaction(|| {
        if !drop_privileges() {
            return json!({ "count": 0, "calls": [] });
        }
        Spi::get_one_with_args::<JsonB>("SELECT allgres_public.fn_claim_oauth($1)", &[limit.into()])
            .ok()
            .flatten()
            .map(|j| j.0)
            .unwrap_or_else(|| json!({ "count": 0, "calls": [] }))
    })
}

/// Claims queued agent-identity embedding regeneration rows -- same claim
/// shape as claim_oauth_jobs, a different table (embedding_calls) with no
/// task_id, feeding the same HTTP pool. See allgres_private.
/// queue_agent_embedding's own comment for what this is regenerating and why
/// it never blocks an agent create/update on failure.
fn claim_agent_embedding_jobs(limit: i32) -> Value {
    BackgroundWorker::transaction(|| {
        if !drop_privileges() {
            return json!({ "count": 0, "calls": [] });
        }
        Spi::get_one_with_args::<JsonB>(
            "SELECT allgres_public.fn_claim_agent_embedding($1)",
            &[limit.into()],
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
        if !drop_privileges() {
            // Not fn_complete_outbound's fault, and not a lost result: the
            // call stays 'in_flight' and fn_watchdog reclaims it as 'lost'
            // on the same timeout it already uses for a worker that died
            // mid-call -- the same recovery path, not a new failure mode.
            pgrx::warning!(
                "Allgres: skipping fn_complete_outbound for call {} -- privilege drop failed",
                call_id
            );
            return;
        }
        if let Err(e) = Spi::get_one_with_args::<JsonB>(
            "SELECT allgres_public.fn_complete_outbound($1::uuid, $2, $3)",
            &[call_id.into(), status.into(), body.as_str().into()],
        ) {
            pgrx::warning!("Allgres: fn_complete_outbound failed for call {}: {}", call_id, e);
        }
    });
}

/// Same completion shape as submit_http_result, for an OAuth token-exchange
/// call instead. fn_complete_oauth has no task_id to fall back on if the
/// privilege drop fails, so the same reasoning applies: leave the row
/// 'in_flight' and let fn_watchdog reclaim it as 'lost' rather than
/// recording under the bootstrap superuser.
fn submit_oauth_result(call_id: &str, status: i32, body: &str) {
    let body = truncate_utf8(&body.replace('\0', ""), MAX_RESPONSE_BYTES).to_string();
    BackgroundWorker::transaction(|| {
        if !drop_privileges() {
            pgrx::warning!(
                "Allgres: skipping fn_complete_oauth for call {} -- privilege drop failed",
                call_id
            );
            return;
        }
        if let Err(e) = Spi::get_one_with_args::<JsonB>(
            "SELECT allgres_public.fn_complete_oauth($1::uuid, $2, $3)",
            &[call_id.into(), status.into(), body.as_str().into()],
        ) {
            pgrx::warning!("Allgres: fn_complete_oauth failed for call {}: {}", call_id, e);
        }
    });
}

/// Same completion shape again, for an agent-identity embedding call.
/// fn_complete_agent_embedding has no task_id to fall back on either, so the
/// same "leave it in_flight, let fn_watchdog reclaim it as lost" reasoning
/// applies on a privilege-drop failure.
fn submit_agent_embedding_result(call_id: &str, status: i32, body: &str) {
    let body = truncate_utf8(&body.replace('\0', ""), MAX_RESPONSE_BYTES).to_string();
    BackgroundWorker::transaction(|| {
        if !drop_privileges() {
            pgrx::warning!(
                "Allgres: skipping fn_complete_agent_embedding for call {} -- privilege drop failed",
                call_id
            );
            return;
        }
        if let Err(e) = Spi::get_one_with_args::<JsonB>(
            "SELECT allgres_public.fn_complete_agent_embedding($1::uuid, $2, $3)",
            &[call_id.into(), status.into(), body.as_str().into()],
        ) {
            pgrx::warning!("Allgres: fn_complete_agent_embedding failed for call {}: {}", call_id, e);
        }
    });
}

pub(crate) fn dashboard_rpc(request: &str) -> String {
    BackgroundWorker::transaction(|| {
        if !drop_privileges() {
            return json!({"ok": false, "error": "privilege_drop_failed"}).to_string();
        }
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
                    match r.queue {
                        OutboundQueue::Outbound => submit_http_result(&r.call_id, r.status, &r.body),
                        OutboundQueue::Oauth => submit_oauth_result(&r.call_id, r.status, &r.body),
                        OutboundQueue::AgentEmbedding => {
                            submit_agent_embedding_result(&r.call_id, r.status, &r.body)
                        }
                    }
                }
                Err(TryRecvError::Empty) | Err(TryRecvError::Disconnected) => break,
            }
        }

        // 2b. Real-time cancel: notice any in-flight outbound call an
        // operator just cancelled, every tick (not gated by next_pump's
        // slower idle backoff below) so "stop" stays fast.
        propagate_outbound_cancellations();

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
                    let job = OutboundJob { call_id: id.to_string(), queue: OutboundQueue::Outbound, call: call.clone() };
                    if jobs.send(job).is_err() {
                        break;
                    }
                    in_flight += 1;
                    queued += 1;
                }
            }
        }

        // 3b. OAuth token exchanges, on the same pool: an operator-initiated
        // dashboard action rather than an agent turn, so it is claimed
        // separately from dispatch_and_claim (fn_claim_oauth, not
        // fn_claim_outbound) but shares the same HTTP threads and the same
        // capacity budget.
        if ready && in_flight < capacity {
            let claimed = claim_oauth_jobs((capacity - in_flight) as i32);
            if let Some(calls) = claimed.get("calls").and_then(Value::as_array) {
                for call in calls {
                    let Some(id) = call.get("call_id").and_then(Value::as_str) else { continue };
                    if !valid_uuid(id) {
                        continue;
                    }
                    let mut call = call.clone();
                    if let Some(obj) = call.as_object_mut() {
                        obj.insert("kind".to_string(), json!("oauth"));
                    }
                    let job = OutboundJob { call_id: id.to_string(), queue: OutboundQueue::Oauth, call };
                    if jobs.send(job).is_err() {
                        break;
                    }
                    in_flight += 1;
                    queued += 1;
                }
            }
        }

        // 3c. Agent-identity embedding regeneration -- an admin editing an
        // agent's system_prompt from the dashboard, not an agent turn, so
        // it is claimed separately (fn_claim_agent_embedding, not
        // fn_claim_outbound) but shares the same HTTP threads and capacity
        // budget as everything else here. Optional feature: if no
        // purpose='embedding' provider is configured, this claims nothing
        // every tick, which costs one cheap empty SELECT.
        if ready && in_flight < capacity {
            let claimed = claim_agent_embedding_jobs((capacity - in_flight) as i32);
            if let Some(calls) = claimed.get("calls").and_then(Value::as_array) {
                for call in calls {
                    let Some(id) = call.get("call_id").and_then(Value::as_str) else { continue };
                    if !valid_uuid(id) {
                        continue;
                    }
                    let mut call = call.clone();
                    if let Some(obj) = call.as_object_mut() {
                        obj.insert("kind".to_string(), json!("embedding"));
                    }
                    let job = OutboundJob { call_id: id.to_string(), queue: OutboundQueue::AgentEmbedding, call };
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
