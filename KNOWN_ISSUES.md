# Known issues and future work

Status as of 0.2.0. Verified on PostgreSQL 18.6 with pgrx 0.19.2: `fn_selftest`
40/40, 27 Rust unit tests, `tests/smoke.sql` and `tests/e2e_mock.sql` pass, and
the full path browser → web worker → unix socket → runtime SPI thread →
PL/pgSQL works end to end.

Everything below is either not implemented or not verified. Nothing here is
believed to be broken in a way that is currently exploitable, but each item is
a gap between what the code does and what it should do.

## 1. Agent SQL does not run as the `sandbox` role

**Severity: high — this is the intended primary boundary for model-generated SQL.**

PostgreSQL refuses `SET ROLE` inside a security-definer function (`cannot set
parameter "role" within security-definer function`, SQLSTATE 42501), and the
restriction covers the whole call stack below one. `fn_execute_sql` is reached
only through `fn_submit_result`, which is `SECURITY DEFINER`, so agent SQL
executes as the function owner.

Compensating controls in place: `search_path = pg_temp`, per-agent enforcement
inside the views (`argo_private.agent_may_read`), `transaction_read_only`, a
planner cost ceiling, non-volatile functions only, and parse-tree validation of
every relation. See README, "The SQL sandbox".

**Fix:** execute agent SQL as a top-level statement from the runtime worker, the
same shape the outbound HTTP pump already uses — SQL validates and hands back
the statement, the worker runs it under `SET LOCAL ROLE sandbox` outside any
security-definer frame, then submits the rows back. This also restores a real
`statement_timeout` (see 2). It is a pump-shaped change and has not been made.

## 2. `statement_timeout` is ineffective when nested

`statement_timeout` is armed when a top-level statement begins, so setting it
inside a function does not re-arm the statement already running. `SELECT
pg_sleep(30)` ran the full 30 seconds under a nominal 5s limit until volatile
functions were banned.

The planner cost ceiling in `fn_execute_sql` bounds the work instead, but a
query that is cheap to plan and slow to run is still unbounded. Fixed properly
by 1.

## 3. Docker image path is unverified

The build was verified natively against PostgreSQL 18. The `Dockerfile` targets
`postgres:17-bookworm` and builds `--features pg17`, and `scripts/smoke.sh`
requires Docker; neither has been run. The PG17 build in particular has not been
compiled since the parse-tree work landed.

`nodeToString` field names and `RawParseMode` are stable across 17 and 18, so
this is expected to work, but "expected" is not "tested".

## 4. Extension upgrade has only been installed fresh

`sql/allgres--0.1.0--0.2.0.sql` is generated and installed, but
`ALTER EXTENSION allgres UPDATE TO '0.2.0'` has never been run against a real
0.1.0 install. The script is the idempotent control plane replayed, so the risk
is in the `DROP FUNCTION` statements for changed signatures and in the
create-only seeds, not in the bulk of it.

## 5. `allgres web` does not appear in `pg_stat_activity`

The web worker deliberately has no database connection, and background workers
without one are not listed in `pg_stat_activity`. The dashboard's Workers panel
therefore only ever shows `allgres runtime`, which reads as though the web
worker is down while it is serving the page you are looking at.

## 6. Untested control-plane paths

No test covers these; they are wired up but unexercised:

- the OAuth flow (`fn_oauth_start`, `fn_oauth_token_request`,
  `fn_oauth_store_tokens`) — including the fact that nothing currently performs
  the token exchange HTTP call;
- the `delegate` action end to end (child task creation is covered by unit-level
  assertions only);
- the `await_human` action and `fn_decide_approval`;
- `fn_watchdog` reclaiming a genuinely stuck in-flight call.

## 7. Secret key rotation

Changing `allgres.secret_key` makes every existing `enc:v1:` value undecryptable;
`decrypt_secret` returns NULL and the provider silently loses its credential.
There is no re-encryption path and no warning. An operator rotating the key today
has to re-enter every provider secret.

## 8. No rate limiting on the dashboard API

`/api/v1/*` has a connection cap (64 threads) but no per-client rate limit. With
a token set and loopback binding this is minor; it matters if the dashboard is
ever exposed through a proxy.

## 9. Non-ASCII identifiers in the parse-tree reader

`analyze_dump` reads the node dump byte-wise, so a relation or function name
containing multi-byte UTF-8 is mangled. The failure is closed — a mangled name
matches no allowlist entry and no `pg_proc` row, so the statement is rejected —
but the error message will be confusing.
