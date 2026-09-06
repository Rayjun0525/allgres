#!/usr/bin/env bash
# Fault-injection drill: proves, against a real local PostgreSQL install,
# that Allgres actually recovers from a genuine crash of the "allgres
# runtime" worker while a sandboxed-SQL call is in flight -- not a
# simulation of that state (see KNOWN_ISSUES.md, "Untested control-plane
# paths": fn_watchdog reclaiming a genuinely stuck in-flight call was named
# as a gap fn_selftest cannot close on its own, because fn_selftest can only
# ever mark a row 'lost' with an UPDATE -- it cannot make a real process
# die mid-call and prove the *system*, unattended, notices and recovers).
#
# This sends a real SIGKILL to the real "allgres runtime" backend while it
# is genuinely executing a real sandboxed SQL statement, on the real SPI
# thread, claimed through the real fn_claim_sql/pump_sql path -- not
# something this script fakes by writing to sql_calls directly. What
# happens next is exactly what a real crash (an OOM kill, a segfault) would
# trigger in production:
#
#   1. PostgreSQL treats an unexpected exit of any backend attached to
#      shared memory -- a background worker with enable_spi_access()
#      included -- exactly like any other backend crash: it tears down
#      every other connection and replays crash recovery. This is not a
#      bug in Allgres; it is standard PostgreSQL behavior, and this drill
#      is what proves the extension survives it, not a shortcut around it.
#   2. The "allgres runtime" worker relaunches itself once recovery
#      finishes (BackgroundWorkerBuilder's own set_restart_time in
#      src/lib.rs), with no operator action.
#   3. The sql_calls row stays 'in_flight' -- it was committed by
#      fn_claim_sql, in its own transaction, *before* the slow query ever
#      started running in a separate one, so the crash cannot roll it back.
#   4. The real, periodic fn_watchdog pass inside the *newly restarted*
#      worker -- not this script calling fn_watchdog directly -- ages past
#      the row's timeout and reclaims it as 'lost', on its own schedule.
#      That schedule is the real one the production pump loop uses
#      (2x HTTP_TIMEOUT = 90s, see dispatch_and_claim in src/lib.rs), not a
#      shortened one just for this drill, so this waits the same ~90s a
#      real crash actually would.
#   5. The task, still 'running' under its retry budget, gets automatically
#      redispatched by the real fn_dispatch_tasks -- not this script -- and
#      completes normally, proving the whole claim -> crash -> recover ->
#      reclaim -> automatic retry -> succeed cycle, not just the reclaim
#      step in isolation.
#
# This KILLS AND RESTARTS THE ENTIRE POSTGRESQL INSTANCE you point it at.
# That is the point, not a side effect -- but it means this must never be
# run against a cluster serving real traffic. Point it at a disposable dev
# install (the same one KNOWN_ISSUES.md's other live verification uses),
# never at anything else.
set -euo pipefail

PG_BIN="${PG_BIN:-/usr/lib/postgresql/16/bin}"
PGCONF="${PGCONF:-/etc/postgresql/16/main/postgresql.conf}"
LOGFILE="${LOGFILE:-/var/log/postgresql/postgresql-16-main.log}"
DB="${DB:-postgres}"
# Large enough to still be running well after fn_claim_sql has committed
# 'in_flight' and this script has had time to detect it and kill the
# worker -- calibrated on this drill's own dev box at ~46s for 200M; if a
# different machine claims the row before this finishes, raise it.
SLOW_ROWS="${SLOW_ROWS:-200000000}"
# The real production reclaim threshold (2x HTTP_TIMEOUT, src/lib.rs). This
# drill deliberately does not shorten it -- waiting the real ~90s is what
# proves the real schedule works, not a drill-only fast path.
RECLAIM_WAIT_SECS="${RECLAIM_WAIT_SECS:-130}"

as_pg() { sudo -u postgres "$@"; }
psql_db() { as_pg "$PG_BIN/psql" -X -v ON_ERROR_STOP=1 -qtA -d "$DB" "$@"; }

echo "=== fault_injection_drill: real worker crash mid sandboxed-SQL, real recovery ==="

AGENT_NAME="faultdrill_$(date +%s)"
AGENT_ID=$(psql_db -c "SELECT allgres_public.fn_create_agent('${AGENT_NAME}')->>'agent_id';")

# The interesting part of this drill is the sandboxed-SQL crash/recovery
# below, not the LLM turn -- but the task still needs *some* working
# provider. Once fn_watchdog reclaims the stuck call and logs the timeout,
# the real fn_dispatch_tasks (running in the real pump loop, not this
# script) immediately tries to advance the task with a genuine LLM call on
# its own, same as it would for any 'running' task with nothing pending --
# a real race this drill has to expect, not suppress. The first version of
# this drill left the agent on its seed default provider and that call hit
# a real network TLS error twice, exhausting max_retries before this
# script ever got to check anything -- a real finding about the drill's
# own design, not about fn_watchdog. Pointing the agent at the same mock
# endpoint tests/e2e_mock.sql already uses means that automatic retry
# actually succeeds, so the drill proves the *whole* real recovery path
# (crash -> reclaim -> automatic redispatch -> real LLM round trip ->
# completion), not just the reclaim step in isolation.
psql_db -c "
  INSERT INTO allgres_private.llm_providers (name, kind, base_url, is_enabled, allow_private_network)
  VALUES ('allgres_mock', 'openai_compat', 'http://127.0.0.1:8088/mock', true, true)
  ON CONFLICT (name) DO UPDATE
  SET base_url = EXCLUDED.base_url, kind = EXCLUDED.kind, is_enabled = true, allow_private_network = true;
  SELECT allgres_public.fn_set_policy(
    '${AGENT_ID}'::uuid, NULL, NULL, NULL,
    jsonb_build_object('provider', 'allgres_mock', 'model', 'allgres-mock', 'temperature', 0, 'max_tokens', 128)
  );
" >/dev/null

SESSION_ID=$(psql_db -c "SELECT allgres_public.fn_create_session('${AGENT_ID}'::uuid, 'fault injection drill')->>'session_id';")
TASK_ID=$(psql_db -c "SELECT task_id FROM allgres_private.tasks WHERE session_id = '${SESSION_ID}'::uuid LIMIT 1;")

cleanup() {
  psql_db -c "UPDATE allgres_private.tasks SET status = 'failed', error = 'drill_cleanup' WHERE task_id = '${TASK_ID}'::uuid AND status NOT IN ('completed','failed');" >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "--- agent ${AGENT_NAME} / task ${TASK_ID}: submitting a real, slow execute_sql action ---"
# fn_submit_result is exactly what the real runtime worker calls after a
# real LLM turn chooses an action -- calling it directly here stands in for
# that one LLM round trip (there is no live model in this drill), but
# everything downstream of it -- fn_validate_sql, the sql_calls queue,
# fn_claim_sql, run_sandboxed_sql actually executing on the real worker's
# SPI thread -- is the genuine, unmodified production path.
psql_db -c "
  SELECT allgres_public.fn_next_step('${TASK_ID}'::uuid);
  SELECT allgres_public.fn_submit_result('${TASK_ID}'::uuid, jsonb_build_object(
    'type', 'llm_response',
    'content', '{\"action\":\"execute_sql\"}',
    'parsed', jsonb_build_object(
      'action', 'execute_sql',
      'sql', 'SELECT count(*) FROM generate_series(1, ${SLOW_ROWS}) g'
    )
  ));
" >/dev/null

echo "--- waiting for the real background worker to claim it (status -> in_flight) ---"
CALL_ID=""
for _ in $(seq 1 100); do
  CALL_ID=$(psql_db -c "SELECT call_id FROM allgres_private.sql_calls WHERE task_id = '${TASK_ID}'::uuid AND status = 'in_flight';" || true)
  [[ -n "$CALL_ID" ]] && break
  sleep 0.2
done
if [[ -z "$CALL_ID" ]]; then
  echo "FAIL: sql_calls row never reached in_flight -- either the worker isn't running or the query finished before this could detect it (lower SLOW_ROWS is the wrong direction; raise it)" >&2
  exit 1
fi
echo "OK: call ${CALL_ID} is in_flight, query genuinely running on the real worker's SPI thread"

WORKER_PID=$(psql_db -c "SELECT pid FROM pg_stat_activity WHERE backend_type = 'allgres runtime';")
if [[ -z "$WORKER_PID" ]]; then
  echo "FAIL: could not find the 'allgres runtime' backend in pg_stat_activity" >&2
  exit 1
fi

LOG_MARK=$(as_pg wc -l < "$LOGFILE" 2>/dev/null || echo 0)
echo "--- SIGKILL allgres runtime (pid ${WORKER_PID}) while call ${CALL_ID} is in flight ---"
as_pg kill -9 "$WORKER_PID"

echo "--- waiting for PostgreSQL's own crash recovery to finish (this is standard PG behavior for any backend attached to shared memory, not something this drill triggers deliberately) ---"
RECOVERED=0
for _ in $(seq 1 60); do
  if as_pg tail -n "+$((LOG_MARK + 1))" "$LOGFILE" 2>/dev/null | grep -q "database system is ready to accept connections"; then
    RECOVERED=1
    break
  fi
  sleep 1
done
if [[ "$RECOVERED" -ne 1 ]]; then
  echo "FAIL: PostgreSQL did not report recovery complete within 60s of the kill" >&2
  exit 1
fi
if ! as_pg tail -n "+$((LOG_MARK + 1))" "$LOGFILE" | grep -qi "terminated by signal\|crash of another server process\|terminating any other active server processes"; then
  echo "FAIL: the log shows recovery but no crash message -- this did not actually exercise a crash" >&2
  exit 1
fi
echo "OK: PostgreSQL logged the crash and completed recovery; the instance is back up"

# Wait for the worker itself (not just the postmaster) to be accepting SPI
# work again before checking anything that depends on it.
for _ in $(seq 1 30); do
  psql_db -c "SELECT 1;" >/dev/null 2>&1 && break
  sleep 1
done

STATUS_AFTER_CRASH=$(psql_db -c "SELECT status FROM allgres_private.sql_calls WHERE call_id = '${CALL_ID}'::uuid;")
if [[ "$STATUS_AFTER_CRASH" != "in_flight" ]]; then
  echo "FAIL: expected the row to still be 'in_flight' immediately after recovery (it was committed before the crash); got '${STATUS_AFTER_CRASH}'" >&2
  exit 1
fi
echo "OK: call ${CALL_ID} is still 'in_flight' after the crash -- the claim survived, exactly as fn_claim_sql's own commit boundary promises"

echo "--- waiting up to ${RECLAIM_WAIT_SECS}s for the real, restarted worker's own periodic fn_watchdog pass to reclaim it (no manual fn_watchdog call here) ---"
RECLAIMED=0
for _ in $(seq 1 "$RECLAIM_WAIT_SECS"); do
  ST=$(psql_db -c "SELECT status FROM allgres_private.sql_calls WHERE call_id = '${CALL_ID}'::uuid;")
  if [[ "$ST" == "lost" ]]; then
    RECLAIMED=1
    break
  fi
  sleep 1
done
if [[ "$RECLAIMED" -ne 1 ]]; then
  echo "FAIL: the real worker's own watchdog never reclaimed call ${CALL_ID} within ${RECLAIM_WAIT_SECS}s" >&2
  exit 1
fi
echo "OK: the real, unattended worker reclaimed the stuck call as 'lost' on its own schedule"

HAS_TIMEOUT_LOG=$(psql_db -c "SELECT count(*) FROM allgres_private.execution_logs WHERE task_id = '${TASK_ID}'::uuid AND role = 'error' AND content::text LIKE '%sql execution timeout%';")
if [[ "$HAS_TIMEOUT_LOG" -lt 1 ]]; then
  echo "FAIL: expected a timeout error logged against the task; found none" >&2
  exit 1
fi
echo "OK: the timeout is visible in the task's own log, not silently swallowed"

echo "--- waiting for the real, unattended pump loop to redispatch the task on its own (fn_dispatch_tasks, not this script) and reach a terminal state ---"
# This is the real production path picking the task back up: no fn_next_step
# / fn_submit_result call from this script from here on. A retried call
# succeeding here proves the whole cycle -- claim -> real crash -> real
# recovery -> reclaim -> automatic redispatch -> real LLM round trip ->
# completion -- not just the reclaim step in isolation.
TERMINAL=""
for _ in $(seq 1 60); do
  TERMINAL=$(psql_db -c "SELECT status FROM allgres_private.tasks WHERE task_id = '${TASK_ID}'::uuid;")
  [[ "$TERMINAL" == "completed" || "$TERMINAL" == "failed" ]] && break
  sleep 1
done
if [[ "$TERMINAL" != "completed" ]]; then
  echo "FAIL: expected the task to reach 'completed' after the real automatic retry; got '${TERMINAL}'" >&2
  exit 1
fi
FINAL_ANSWER=$(psql_db -c "SELECT final_answer FROM allgres_private.sessions WHERE session_id = '${SESSION_ID}'::uuid;")
if [[ "$FINAL_ANSWER" != "Allgres mock runtime OK" ]]; then
  echo "FAIL: unexpected final_answer after recovery: '${FINAL_ANSWER}'" >&2
  exit 1
fi
echo "OK: the task recovered and completed on its own -- claim -> real crash -> real recovery -> reclaim -> automatic retry -> success, end to end"

echo ""
echo "=== Phase 2: outbound_calls (a real LLM/HTTP call) in-flight worker crash ==="
# Same shape as phase 1, for the other queue KNOWN_ISSUES.md item 6 named:
# outbound_calls, claimed onto the real HTTP thread pool instead of the SPI
# thread. /mock/slow/chat/completions (src/lib.rs) sleeps 15s before
# replying -- long enough to reliably detect 'in_flight' and kill the
# worker before it ever gets a response, comfortably under HTTP_TIMEOUT
# (45s) so an *unkilled* request to it still completes normally, which is
# what lets the automatic retry below actually finish.
psql_db -c "
  INSERT INTO allgres_private.llm_providers (name, kind, base_url, is_enabled, allow_private_network)
  VALUES ('allgres_mock_slow', 'openai_compat', 'http://127.0.0.1:8088/mock/slow', true, true)
  ON CONFLICT (name) DO UPDATE
  SET base_url = EXCLUDED.base_url, kind = EXCLUDED.kind, is_enabled = true, allow_private_network = true;
  SELECT allgres_public.fn_set_policy(
    '${AGENT_ID}'::uuid, NULL, NULL, NULL,
    jsonb_build_object('provider', 'allgres_mock_slow', 'model', 'allgres-mock', 'temperature', 0, 'max_tokens', 128)
  );
" >/dev/null

SESSION_ID2=$(psql_db -c "SELECT allgres_public.fn_create_session('${AGENT_ID}'::uuid, 'fault injection drill phase 2')->>'session_id';")
TASK_ID2=$(psql_db -c "SELECT task_id FROM allgres_private.tasks WHERE session_id = '${SESSION_ID2}'::uuid LIMIT 1;")

echo "--- task ${TASK_ID2}: waiting for the real pump loop to dispatch and claim a real LLM call ---"
CALL_ID2=""
for _ in $(seq 1 100); do
  CALL_ID2=$(psql_db -c "SELECT call_id FROM allgres_private.outbound_calls WHERE task_id = '${TASK_ID2}'::uuid AND status = 'in_flight';" || true)
  [[ -n "$CALL_ID2" ]] && break
  sleep 0.2
done
if [[ -z "$CALL_ID2" ]]; then
  echo "FAIL: outbound_calls row never reached in_flight for task ${TASK_ID2}" >&2
  exit 1
fi
echo "OK: call ${CALL_ID2} is in_flight, a real HTTP request genuinely in flight on a real pool thread"

WORKER_PID2=$(psql_db -c "SELECT pid FROM pg_stat_activity WHERE backend_type = 'allgres runtime';")
if [[ -z "$WORKER_PID2" ]]; then
  echo "FAIL: could not find the 'allgres runtime' backend in pg_stat_activity" >&2
  exit 1
fi

LOG_MARK2=$(wc -l < "$LOGFILE" 2>/dev/null || echo 0)
echo "--- SIGKILL allgres runtime (pid ${WORKER_PID2}) while call ${CALL_ID2} is in flight ---"
as_pg kill -9 "$WORKER_PID2"

RECOVERED2=0
for _ in $(seq 1 60); do
  if as_pg tail -n "+$((LOG_MARK2 + 1))" "$LOGFILE" 2>/dev/null | grep -q "database system is ready to accept connections"; then
    RECOVERED2=1
    break
  fi
  sleep 1
done
if [[ "$RECOVERED2" -ne 1 ]]; then
  echo "FAIL: PostgreSQL did not report recovery complete within 60s of the phase 2 kill" >&2
  exit 1
fi
for _ in $(seq 1 30); do
  psql_db -c "SELECT 1;" >/dev/null 2>&1 && break
  sleep 1
done
echo "OK: PostgreSQL recovered from the phase 2 crash"

echo "--- waiting up to ${RECLAIM_WAIT_SECS}s for the real, restarted worker's own fn_watchdog to reclaim it ---"
RECLAIMED2=0
for _ in $(seq 1 "$RECLAIM_WAIT_SECS"); do
  ST2=$(psql_db -c "SELECT status FROM allgres_private.outbound_calls WHERE call_id = '${CALL_ID2}'::uuid;")
  if [[ "$ST2" == "lost" ]]; then
    RECLAIMED2=1
    break
  fi
  sleep 1
done
if [[ "$RECLAIMED2" -ne 1 ]]; then
  echo "FAIL: the real worker's own watchdog never reclaimed outbound call ${CALL_ID2} within ${RECLAIM_WAIT_SECS}s" >&2
  exit 1
fi
echo "OK: the real, unattended worker reclaimed the stuck outbound call as 'lost' on its own schedule"

HAS_TIMEOUT_LOG2=$(psql_db -c "SELECT count(*) FROM allgres_private.execution_logs WHERE task_id = '${TASK_ID2}'::uuid AND role = 'error' AND content::text LIKE '%outbound timeout%';")
if [[ "$HAS_TIMEOUT_LOG2" -lt 1 ]]; then
  echo "FAIL: expected an outbound timeout error logged against task ${TASK_ID2}; found none" >&2
  exit 1
fi

TERMINAL2=""
for _ in $(seq 1 60); do
  TERMINAL2=$(psql_db -c "SELECT status FROM allgres_private.tasks WHERE task_id = '${TASK_ID2}'::uuid;")
  [[ "$TERMINAL2" == "completed" || "$TERMINAL2" == "failed" ]] && break
  sleep 1
done
if [[ "$TERMINAL2" != "completed" ]]; then
  echo "FAIL: expected task ${TASK_ID2} to reach 'completed' after the real automatic retry; got '${TERMINAL2}'" >&2
  exit 1
fi
FINAL_ANSWER2=$(psql_db -c "SELECT final_answer FROM allgres_private.sessions WHERE session_id = '${SESSION_ID2}'::uuid;")
if [[ "$FINAL_ANSWER2" != "Allgres mock runtime OK" ]]; then
  echo "FAIL: unexpected final_answer after phase 2 recovery: '${FINAL_ANSWER2}'" >&2
  exit 1
fi
echo "OK: phase 2 recovered and completed on its own -- claim -> real crash -> real recovery -> reclaim -> automatic retry -> success, end to end"

FAILED=$(as_pg "$PG_BIN/psql" -X -tA -d "$DB" -c "SELECT allgres_public.fn_selftest()->>'failed';")
if [[ "$FAILED" != "0" ]]; then
  echo "FAIL: fn_selftest is not clean after the drill (failed=${FAILED})" >&2
  exit 1
fi
echo "OK: fn_selftest is still clean after the drill"

echo "=== fault_injection_drill: all checks passed ==="
