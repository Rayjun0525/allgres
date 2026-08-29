# Known issues and future work

Status as of 0.2.0. Verified natively on PostgreSQL 16.15 with pgrx 0.19.2
(Docker/PG17, this environment's actual deployment target, could not be
reached to verify against — see item 3): `fn_selftest` 56/56, `tests/smoke.sql`
and `tests/e2e_mock.sql` pass, and the full path browser → web worker → unix
socket → runtime SPI thread → PL/pgSQL works end to end over real HTTP
(`curl` against `/api/v1/rpc`, CSRF checks included), including a live
`dashboard_rpc` round trip for every action added so far (`projects.*`,
`approvals.*`, `sessions.cancel`/`.list`/`.get`, `permissions.*`,
`allowlist.*`, `policy.history`) and the `web/index.html` pages that call
them (`Projects`, `Sessions`, `Approvals`, plus the extended `Agents` and
`Settings`). Earlier builds were verified on PostgreSQL 18.6; nothing here
is PG-version-specific.

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
- `fn_watchdog` reclaiming a genuinely stuck **in-flight** call, for either
  `outbound_calls` or `sql_calls` (a runtime worker crash between claim and
  complete). `fn_watchdog` now has four reclaim loops total; the other two
  (pending-approval expiry, `max_turn_seconds` — see item 11) got selftest
  coverage in the same pass that added them, using the same technique this
  pair would need (mark a row in the relevant state, backdate its timestamp,
  call `fn_watchdog`, assert the reclaim) — nothing stops writing the same
  tests here, it just hasn't been done yet.

`await_human` / `fn_decide_approval` themselves are no longer on this list —
see item 10. Neither is task/session cancellation, permission and allowlist
management, or per-agent concurrency/wall-clock limits — see item 11.

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

## 10. Projects and a real `await_human` reply loop

`fn_decide_approval` used to be a bare approve/reject bit: the human's actual
reasoning was never fed back to the agent, which resumed with no idea what was
decided or why. It now takes an optional `p_reply text`, appends it to
`execution_logs` as an `operator`-role message (a role the log's `CHECK`
constraint has allowed since day one but that nothing ever wrote), and the
resumed agent sees it on its next turn. `argo_private.human_approvals` also
gained `expires_at` (`fn_submit_result` sets a 24h default) and `fn_watchdog`
auto-rejects a `waiting_human` task nobody ever answers, the same
durable-queue-plus-watchdog shape used for `outbound_calls`/`sql_calls`, on
human timescales instead of machine ones.

`argo_private.projects` was added to group sessions (agents stay
project-agnostic and reusable across projects, the way a bot can sit in
several Slack channels); `fn_create_session` takes an optional `p_project_id`.
`dashboard_rpc` exposes `projects.list` / `projects.create` / `projects.update`
and `approvals.list` / `approvals.decide`; there is no dashboard UI for any of
it yet (no thread view, no project switcher, no approve/reject button) —
that's the next layer, not this one.

Deliberately out of scope for this pass, worth revisiting:

- the 24h approval expiry is a hardcoded default, not configurable per call or
  per agent;
- neither `fn_decide_approval` nor `projects.*` records *who* decided or
  created something — there is no per-operator identity anywhere in the
  system (the dashboard has one shared token, not accounts), so "who approved
  this" is unanswerable by design, not by oversight. Adding real identity
  would be a bigger change than this one.

## 11. Fine-grained operator controls

The gaps this pass filled:

- **`fn_cancel_session`** — nothing could stop a running agent before this;
  cancels every open task in a session, rejects any pending approval so it
  doesn't linger, logs why on each cancelled task, and closes the session as
  `'cancelled'` — a status distinct from `'failed'`, since an operator
  stopping something is a different signal than the agent's own logic giving
  up. Wired to `dashboard_rpc` as `sessions.cancel`.
- **`permissions.grant`/`.revoke`/`.list`/`.options` and `allowlist.add`/
  `.remove`/`.list`** — `fn_grant_permission`, `fn_revoke_permission`,
  `fn_allowlist_add`, `fn_allowlist_del` existed but were reachable only by
  raw SQL; there was no way to grant an agent a view/tool/delegate-target/
  http_host, or add a view to the SQL sandbox allowlist, without a direct
  database connection. `permissions.options` queries `pg_catalog.pg_views`
  live for the view picker rather than hardcoding a list.
- **`sessions.list`/`sessions.get`** — the backing query for a thread view:
  one session's full `execution_logs` across all its tasks, in order. Did not
  exist before; `logs.list` only ever returned a flat, unscoped, 150-row-capped
  slice of every agent's logs mixed together.
- **Policy version history** — `argo_private.policies` gained `generation`;
  `argo_private.policy_history` is an append-only snapshot of every prior
  version, written by `fn_set_policy` immediately before it overwrites the
  live row. Versions only on an actual change (compared field by field with
  `IS DISTINCT FROM`) — `agents.update` calls `fn_set_policy` on every save,
  including a bare `is_active` toggle, and that must not manufacture a
  version. Exposed as `policy.history`.
- **`max_concurrent_tasks`/`max_turn_seconds`** — `max_steps`/`max_retries`
  bound a runaway *loop* within one task; neither bounded how many tasks one
  agent runs at once or how long any single task may take start to finish.
  `max_concurrent_tasks` (default 4) is enforced in `fn_dispatch_tasks`, which
  now skips a candidate task if its agent already has that many tasks
  `running`/`waiting_human`. `max_turn_seconds` (default: uncapped) is
  enforced in `fn_watchdog` against `created_at`, terminal like `max_steps` —
  straight to `failed`, no retry.

All of it now has a dashboard UI. `web/index.html` gained three pages
(`Projects`, `Sessions`, `Approvals`) and extended two existing ones
(`Agents`, `Settings`), all through one new generic client-side helper,
`rpc(action, body)`, that POSTs to a single new HTTP route.

That route was the actual gap: every `dashboard_rpc` action added in this
pass and the previous one (`projects.*`, `approvals.*`, `sessions.*`,
`permissions.*`, `allowlist.*`, `policy.history`) had no way to reach the
runtime from a browser. `src/lib.rs`'s `api_route()` used to be a fixed
match table, one named Rust route per action, so *every* new SQL-side
capability needed a Rust recompile before the UI could call it — the same
kind of unnecessary layer "Postgres Is All You Need" argues against
elsewhere. It now also matches a generic `POST /api/v1/rpc`, whose body
*is* the `dashboard_rpc` request (it just needs an `"action"` key); the
named routes predating this stay for compatibility, but nothing new needs
one. `allgres.dashboard_rpc` was already the real trust boundary — it
decides what's a valid action and runs `SECURITY DEFINER` regardless of
how the call reached it — so the per-route table was never doing
security work, only adding friction.

What's now reachable from a browser: cancel a session
(`sessions.cancel`, from the new thread view or the Sessions list); grant
or revoke a permission and browse a live view/tool/agent picker
(`permissions.*`/`.options`, from an Agents-page editor); add or remove an
SQL sandbox allowlist entry (`allowlist.*`, from Settings); read an
agent's policy version history (`policy.history`); create/list/toggle
projects and pick one when starting a run (`projects.*`); and the thread
view itself (`sessions.get`) — one session's full message log across all
its tasks, with a pending `await_human` approval, if any, rendered as a
reply box with Approve/Reject inline, backed by the same
`approvals.decide` the standalone Approvals inbox page uses.

Verified the same way as every prior change in this file: rebuilt against
local PostgreSQL 16.15, `fn_selftest` 56/56, `tests/smoke.sql` and
`tests/e2e_mock.sql` both green, and every new action driven through the
actual browser-facing path — HTTP → `allgres web` → unix socket →
`allgres runtime`'s SPI thread → `dashboard_rpc` — via `curl` against the
new `/api/v1/rpc` route, not just called directly in SQL: a full session
create → thread-view → cancel round trip, a permission grant → list →
revoke round trip, a policy edit → version-history round trip, an
allowlist add → list → remove round trip, and a full `await_human` →
operator reply → resumed-task round trip. The CSRF checks (`X-Allgres-Client`
header, `Origin` match) already enforced in Rust ahead of `api_route`
apply to the new route exactly as they do to every other one — confirmed
both are still rejected on it.

What's deliberately not here: no live-updating thread view (it's a
request/response fetch on open, not a poll or a push); no operator
identity attached to a cancel, grant, or approval decision, for the same
reason item 10 gives (no accounts system yet); no confirmation dialog
before `sessions.cancel` beyond the browser's own — an operator fat-fingering
Cancel loses a running task with no undo.
