# Known issues and future work

Status as of 0.2.0. Verified on PostgreSQL 18.6 with pgrx 0.19.2: `fn_selftest`
40/40, 27 Rust unit tests, `tests/smoke.sql` and `tests/e2e_mock.sql` pass, and
the full path browser → web worker → unix socket → runtime SPI thread →
PL/pgSQL works end to end.

Everything below is either not implemented or not verified. Nothing here is
believed to be broken in a way that is currently exploitable, but each item is
a gap between what the code does and what it should do.

## 1. ~~Agent SQL does not run as the `sandbox` role~~ — fixed

`fn_execute_sql` validated *and* executed in one `SECURITY DEFINER` call, which
is exactly what made `SET ROLE sandbox` illegal (PostgreSQL refuses `SET ROLE`
inside a security-definer function, and the restriction covers the whole call
stack below one). It is now split: `fn_validate_sql` only validates and
returns the normalized statement text; the runtime worker queues that text in
`argo_private.sql_calls` and its SPI thread claims and runs it
(`fn_run_sandboxed_sql`) as a **top-level** statement — issued directly by the
worker, no enclosing `SECURITY DEFINER` frame — under `SET LOCAL ROLE
sandbox`, the same claim/complete shape (`fn_claim_sql` / `fn_complete_sql`)
already used for outbound LLM and tool calls. See README, "The SQL sandbox".

`tests/smoke.sql` asserts the role is actually assumed (`SET LOCAL ROLE
sandbox; SELECT current_user`) against a live session, since `fn_selftest`
cannot: it is `SECURITY DEFINER` itself, so it cannot `SET ROLE` either.
`fn_selftest` instead covers the validate → queue → claim → complete state
machine, including a worker-side execution failure being logged and retried
rather than treated as a validation gap.

One consequence: `execute_sql` now costs two step-count ticks (queue, then
result) instead of one, matching how `call_tool` already worked — relevant
only to `policies.max_steps` budgeting.

## 2. `statement_timeout` is now real, but only bounds sandboxed execution

Fixed by 1 for the part that matters: `fn_run_sandboxed_sql` runs as a
top-level statement, so `SET LOCAL statement_timeout` set by the runtime
worker right before calling it actually arms. `fn_validate_sql`'s own
`statement_timeout` (bounding parsing and the `EXPLAIN` cost check) is still
set from inside a `SECURITY DEFINER` function and so is still nominal in the
same nested-statement sense as before; the planner cost ceiling is what
actually bounds that half.

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
- `fn_watchdog` reclaiming a genuinely stuck in-flight call, for either
  `outbound_calls` or the new `sql_calls` (a runtime worker crash between
  `fn_claim_sql` and `fn_complete_sql`).

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
