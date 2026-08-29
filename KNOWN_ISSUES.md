# Known issues and future work

Status as of 0.2.0. Verified natively on PostgreSQL 16.15 with pgrx 0.19.2
(Docker/PG17, this environment's actual deployment target, could not be
reached to verify against — see item 3): `fn_selftest` 78/78, `tests/smoke.sql`
and `tests/e2e_mock.sql` pass, and the full path browser → web worker → unix
socket → runtime SPI thread → PL/pgSQL works end to end over real HTTP
(`curl` against `/api/v1/rpc`, CSRF checks included), including a live
`dashboard_rpc` round trip for every action added so far (`projects.*`,
`approvals.*`, `sessions.cancel`/`.list`/`.get`, `permissions.*`,
`allowlist.*`, `policy.history`, `policy.rollback`, `proposals.*`) and the
`web/index.html` pages that call them (`Projects`, `Sessions`, `Approvals`,
`Proposals`, plus the extended `Agents` and `Settings`). Earlier builds
were verified on PostgreSQL 18.6; nothing here is PG-version-specific.

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
  enforced in `fn_watchdog`, terminal like `max_steps` — straight to
  `failed`, no retry. It measures against `tasks.started_at` (set once, in
  `fn_next_step`, the first time a task leaves `'queued'`), not
  `created_at` — an earlier version used `created_at`, which meant a task
  held back by `max_concurrent_tasks` could get killed by `max_turn_seconds`
  before it ever ran a single turn, one limit starving a task the other
  limit hadn't even started timing yet. See item 12.

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

## 12. Six correctness/security regressions from items 10 and 11, found by external review

An external review of the branch (before merge) found six real bugs in the
work described in items 10 and 11 above — none caught by `fn_selftest` at
the time, because the tests checked that a row got written, not that the
row was ever read back by the code path that mattered. All six are fixed
and each now has selftest coverage that checks the actual consuming path,
not just the write; two were also reproduced and re-verified live against
the real background worker (not just through `fn_selftest`'s direct calls)
before and after the fix. `fn_selftest` was 56/56 throughout — all six bugs
were sitting under passing tests.

- **`execute_sql` raced the next LLM call.** `fn_dispatch_tasks` checked
  `outbound_calls` for in-flight work before redispatching a task, but not
  `sql_calls`. A task that had just emitted `execute_sql` stayed `'running'`
  with no `outbound_calls` row at all — the SQL result queued into
  `sql_calls` instead — so the next pump would call `fn_next_step` on it
  again, rebuild the same dangling `execute_sql` request from
  `execution_logs` (no tool result existed for it yet), and fire a second,
  racing LLM call before the pending SQL result was ever seen. Fixed by
  adding the same `NOT EXISTS` guard for `sql_calls` that already existed
  for `outbound_calls`. Reproduced and re-verified live: queuing a real
  `execute_sql` turn and watching the actual background worker's pump loop
  now produces exactly one `sql_calls` row and exactly one follow-up
  `outbound_calls` row, in order, with no duplicate or racing call.
  Selftest: `dispatch_holds_back_pending_sql_task`.
- **An operator's `await_human` reply never reached the model.**
  `fn_decide_approval` correctly wrote the reply as an `'operator'`-role log
  row (item 10), but `fn_next_step`'s message-assembly loop only recognized
  `('system', 'user', 'assistant', 'tool')` — `'operator'` fell through
  silently. The reply was visible on the dashboard; the agent's next
  `call_llm` never carried it. Fixed by adding `'operator'` to that list,
  mapped to a `'user'` turn the same way `'tool'` already is. Selftest
  (`approval_reply_feeds_back_into_log`) only ever checked that the log row
  existed; it now also asserts the reply string appears in
  `fn_next_step`'s own `messages` output
  (`operator_reply_reaches_llm_messages`).
- **`fn_cancel_session` didn't stop what was already queued.** It set the
  task to `'cancelled'` but left any `'queued'`/`'in_flight'`
  `outbound_calls`/`sql_calls` row untouched, and `fn_claim_outbound` /
  `fn_claim_sql` claimed by row status alone with no join back to the
  task — so a cancelled session's SQL or HTTP request could still fire.
  Fixed two ways: `fn_cancel_session` now marks those rows `'lost'` itself
  (matching what `fn_complete_outbound`/`fn_complete_sql` already do when a
  result comes back for a no-longer-running task), and both claim functions
  now join to `tasks` and only claim a row whose task is still `'running'`,
  as defense in depth against the same race for *any* terminal transition,
  not only cancel. `fn_watchdog`'s `max_turn_seconds` reclaim got the same
  cleanup for the same reason. Selftest: `cancel_session_voids_pending_calls`.
- **The SQL sandbox's function check let `current_setting()` through.**
  `fn_validate_sql` only checked `provolatile <> 'v'` — but `STABLE` means
  "cannot change within one statement," not "safe to expose to an agent."
  `current_setting()` is `STABLE`. `SELECT current_setting('allgres.secret_key',
  true)` — the key that encrypts every provider secret in the system —
  validated as ordinary safe SQL and, run under the `sandbox` role exactly
  as the sandbox executes real agent SQL, returned the key. Reproduced and
  confirmed live before fixing. Closed with three more gates on top of the
  volatility check: `pg_catalog` only (rules out every user-defined
  `SECURITY DEFINER` function — Allgres's own control-plane functions
  included — and every extension function), `NOT prosecdef`, and an
  explicit denylist of `pg_catalog` functions that disclose configuration,
  session, or process state despite being non-volatile (`current_setting`,
  `set_config`, `version`, `inet_server_addr`, `txid_current`, and similar
  — see `fn_validate_sql`'s `c_denied_fns` for the full list). Re-verified
  live after the fix, including that the block survives an uppercase call
  and a schema-qualified one (`pg_catalog.current_setting(...)`). Selftest:
  five new `sandbox_reject` cases, including the exact secret-key query and
  a call to Allgres's own `argo_private.secret_key()`.
- **SSRF: the outbound guard checked a hostname string, never the address it
  resolves to.** `argo_private.is_blocked_host` (used at SQL build/queue
  time) and the Rust HTTP client's own DNS resolution were two separate
  steps with nothing tying them together: a hostname that resolves to a
  public address when the agent's request is validated can resolve to
  `127.0.0.1` or an RFC1918 address by the time the worker actually
  connects (DNS rebinding), and no amount of re-checking the string closes
  that. Fixed with a custom `ureq` resolver (`GuardedResolver` in
  `src/lib.rs`) that re-checks every address DNS actually returns against
  the same blocked ranges (reimplemented once in Rust,
  `is_blocked_ip`/`is_blocked_ipv4`, to match the SQL check), immediately
  before ureq connects to it — not a separate resolve-then-check step a
  rebind could land in between, the resolver *is* the thing ureq dials.
  Threading the per-call "is this provider allowed to hit private
  addresses" decision through required a new `outbound_calls.allow_private`
  column, set from `llm_providers.allow_private_network` when a call is
  queued (`http_get` never sets it — the tool path always validates with
  `p_allow_private = false`). Reproduced and confirmed live: a provider
  pointed at a hostname resolving to `127.0.0.1`, on a port where a real
  mock server was listening, failed with "host not found" rather than
  reaching it, over three retries.
- **`max_turn_seconds` could kill a task before its first turn.** It
  measured against `created_at`, which includes time spent `'queued'`
  waiting for a `max_concurrent_tasks` slot — so a busy agent's own
  concurrency cap could starve a task long enough for the wall-clock limit
  to fail it having never run once. Fixed by adding `tasks.started_at`, set
  once by `fn_next_step` the first time a task leaves `'queued'`, and
  measuring from there instead; a task still `'queued'` has `started_at
  IS NULL` and the watchdog leaves it alone entirely, however old
  `created_at` is. Selftest: `max_turn_seconds_spares_queued_task`
  (new) alongside the existing `max_turn_seconds_expires_stale_task`,
  which now backdates `started_at` rather than `created_at`.

None of these were architectural — every fix is local to the function that
had the gap. The pattern across all six is the same one item 6 already
names for the two untested watchdog reclaim loops: something was wired up
and superficially tested, but the test checked that a write happened, not
that the thing reading it back behaved correctly. Worth treating as a
standing question for anything still on this list: does the test for it
check the write, or the read?

## 13. Two more from a second review round: `started_at` resetting, and provider credentials in plaintext

- **`started_at` reset on every human-approval resume.** Item 12's own fix
  had a bug: `fn_next_step`'s `queued -> running` transition set
  `started_at = now()` unconditionally, but a task revisits `'queued'`
  every time it resumes from `waiting_human` (`fn_decide_approval` puts it
  back there), not only on its first turn. That silently turned
  `max_turn_seconds` into "time since most recently resumed" instead of
  "time since this task first started running," for any task that ever
  waits on a human — defeating the wall-clock ceiling `started_at` exists
  for, one release after it was added. Fixed with
  `COALESCE(started_at, now())`, so only the first transition sets it.
  Selftest: `started_at_survives_human_resume`.
- **A provider's decrypted API key sat in a table in plaintext.**
  `build_llm_http` decrypted the key and baked it into the
  `Authorization`/`x-api-key` header it returned; `fn_dispatch_tasks` wrote
  that header straight into `argo_private.outbound_calls.request_headers`
  — an ordinary table column, not a transient value. From the moment a
  call was queued until it was harvested (and after, since nothing purges
  it), the plaintext key sat in WAL, in any physical backup or PITR
  archive, on any replica, and was readable by a plain `SELECT` on that
  table by any role with access to it. Confirmed live before fixing:
  registered a distinctive test key, ran a real session through it, found
  the key sitting in `outbound_calls.request_headers`.

  Fixed by moving credential resolution from build/queue time to claim
  time. `outbound_calls` gained `provider_id` and `auth_kind` (which header
  name, not the secret) instead of holding the assembled header;
  `build_llm_http` no longer touches `provider_secret` at all;
  `fn_claim_outbound` now decrypts the key and merges the real header only
  into the JSON response it hands the runtime worker over the RPC socket
  — never back into the table. The key exists only in that one response
  and then in the worker's memory for the single HTTP request it is used
  for. (`build_llm_http`, `fn_dispatch_tasks`, and `fn_claim_outbound` all
  changed signature for this — `p_fallback_key` moved from the first two
  to the third, since it is claim time that now needs it.)

  Reproduced and reverified live the way the review asked: registered a
  distinctive test key, ran a real session through it end to end (real
  background worker, real mock HTTP endpoint, actual completion), then
  searched every column of `outbound_calls` and `execution_logs` for the
  key string — zero rows, while the session still completed normally,
  confirming the header was still built and sent correctly and this
  wasn't just breaking the feature to hide the bug.

  One side effect worth naming: `outbound_calls.provider_id` is a real
  foreign key to `llm_providers`, so a provider with call history can no
  longer be deleted out from under it. There was no delete-provider path
  before this change either (only `fn_set_provider`, never a remove), so
  nothing user-facing regresses — but the constraint is there now and
  would need a decision (cascade? block? soft-delete the provider row?) if
  provider deletion is ever added.

Both were found the same way item 12's six were: an external review reading
the actual code path end to end, not the tests passing. `fn_selftest` was
green through both.

## 14. SQL sandbox function check switched from denylist to positive allowlist

Item 12 closed the `current_setting()` leak by adding `c_denied_fns`, an
explicit denylist of `pg_catalog` functions that disclose configuration,
session, or process state despite being non-volatile. A second review round
pointed out the structural problem with that: a denylist can only ever name
functions already known to be dangerous, and `pg_catalog` has hundreds of
them. `pg_show_all_settings()` is `STABLE`, not `SECURITY DEFINER`, lives in
`pg_catalog`, and was on no denylist that only thought to name
`current_setting`/`set_config`/`version`/etc — it passed every gate that
existed. Confirmed live before fixing:
`SELECT setting FROM pg_catalog.pg_show_all_settings() WHERE name =
'allgres.secret_key'` validated as ordinary safe SQL and would have handed
back the same secret item 12 had just closed one specific path to.

Fixed by adding `argo_private.sql_function_allowlist`, seeded with the
aggregate/string/math/date/json functions an analyst actually needs
(`sum`, `count`, `extract`, `generate_series`, `jsonb_build_object`, and
similar — see the seed `INSERT` in `sql/control_plane.sql` for the full
list). `fn_validate_sql` now requires a function to be on this allowlist
*in addition to* every gate item 12 added (non-volatile, `pg_catalog` only,
`NOT prosecdef`, not on the denylist — kept as one more backstop, not
removed). This is a real shift in failure mode: previously an unnamed
dangerous function slipped through silently; now a legitimate function
nobody thought to seed yet fails loudly and has to be added to the
allowlist. That is the safe direction to get this wrong in.

Reproduced and reverified live: the `pg_show_all_settings()` query above,
validated and rejected; a realistic analyst query
(`SELECT region, sum(amount), count(*) FROM argo_public.v_sales GROUP BY
region ORDER BY sum(amount) DESC`) run through the real background worker
end to end, executed correctly under the new allowlist. `fn_selftest`
68/68 (two new cases: the `pg_show_all_settings()` bypass rejected, and an
unseeded-but-otherwise-safe function, `pg_get_userbyid`, rejected too —
proving default-deny holds for anything not explicitly listed, not only
the specific names already known to leak). `tests/smoke.sql` and
`tests/e2e_mock.sql` green.

The allowlist itself is seeded in `sql/control_plane.sql`, not yet exposed
through the dashboard (no `sql_function_allowlist.list`/`.add`/`.remove`
`dashboard_rpc` actions) — extending it today means editing the seed and
reinstalling, the same as `sql_sandbox_allowlist` (the view/relation
allowlist) worked before its own dashboard exposure landed. Worth the same
treatment later if the seeded set turns out to be too narrow in practice.

## 15. Agent-as-PostgreSQL-role, slice one: per-agent identity for the SQL sandbox

A second-round review (the same one that found items 13 and 14) argued
Allgres's strongest differentiator from other agent frameworks is
PostgreSQL's own role/ACL system as the actual trust boundary, not an
application-level permission table alone — an agent as a real `NOLOGIN`
role, gated by native `GRANT`/RLS, rather than "an agent ID a
`SECURITY DEFINER` function happens to check." The full version of that is
a large redesign: capability roles, RLS across every agent-scoped table,
sub-agent capabilities enforced as a strict subset of the parent's, a
broader provisioner. This is a first, deliberately narrow slice: does the
core mechanism — a real per-agent PostgreSQL identity, actually used to
gate something — work at all, end to end, verified live, before any of
the rest is built on top of it.

**What exists now**: `agents.pg_role`, `NULL` until
`fn_provision_agent_role` runs (`fn_create_agent` calls it for every new
agent; an agent from before this column existed stays `NULL`, opt-in not
breaking). Provisioning creates a `NOLOGIN` role named only from the
agent's own uuid (`allgres_agent_<uuid, no dashes>` — never from any
operator- or agent-supplied text, so there is no injection surface in the
dynamic `CREATE ROLE`), a member of `sandbox` (inherits its grants,
nothing duplicated per agent) and of `worker` (so the runtime worker,
the only thing that ever assumes it, can `SET LOCAL ROLE` to it).
`fn_run_sandboxed_sql` now runs an agent's `execute_sql` as that role
instead of the one shared `sandbox` role every agent used to be
indistinguishable under; an unprovisioned agent still falls back to
`sandbox`, unchanged. `fn_claim_sql`/`run_sandboxed_sql` in `src/lib.rs`
thread the role name through the same claim/complete shape as everything
else, with a Rust-side format check (`valid_pg_role`) before it is ever
interpolated into a `SET LOCAL ROLE` string, since that statement has no
parameterized form.

This did not need a new privilege boundary, on inspection: whatever
installs the extension already creates `argo_owner`/`operator`/`worker`/
`sandbox` in the roles bootstrap, so it already has `CREATE ROLE` power
(typically as a superuser); `fn_provision_agent_role`, like every other
`SECURITY DEFINER` function in this file, is owned by that same installer
and asks for nothing new.

**A real bug this slice caught, live, before it shipped**: the first
version of `current_agent_id()` looked `pg_role` up in
`argo_private.agents` by `current_user`, and was `SECURITY DEFINER` (it
has to read a table `sandbox` has no grant on). That silently broke
every agent's own permission check — confirmed live: an agent granted
its own view read back zero rows. The reason is a `SECURITY DEFINER`
property easy to forget: it changes `current_user` to the function's
*owner*, for everything nested inside it, for the rest of that function's
execution — `agent_may_read` is already `SECURITY DEFINER` (it reads
`argo_private.permissions`/`sql_sandbox_allowlist`), so calling
`current_agent_id()` from inside it saw `current_user` as
`agent_may_read`'s owner on every single call, never the querying agent's
actual role. Fixed by making `current_agent_id()` table-free (the
agent_id is parsed back out of the role name string, which the naming
scheme makes exactly reversible) so it can stay `SECURITY INVOKER`, and by
having `v_sales`/`v_my_tasks` call it *directly*, before crossing into
`agent_may_read`'s `SECURITY DEFINER` boundary, with the result threaded
in as a parameter (`agent_may_read(p_ref, p_agent_id)`) rather than
`agent_may_read` resolving it itself. `current_user` is only ever the real
caller up to the point something `SECURITY DEFINER` runs — never past it,
regardless of what the nested function's own security mode is.

**Verified live, not just via `fn_selftest`** (same reasoning as items 12
and 13: this is exactly the kind of bug a test that only checks a write
happened would miss): two freshly created agents, each running real
`execute_sql` under its own role via `fn_run_sandboxed_sql`, one able to
read its own `v_my_tasks` row, the other — same view permission, no task
of its own — reading zero rows, proving row visibility follows PostgreSQL
role identity and not the permission table alone (`tests/smoke.sql`).
Separately, a brand-new agent's `execute_sql` was run through the actual
Rust background worker (queued via `fn_submit_result`, picked up by the
real `pump_sql` loop, not called directly) and correctly saw only its own
task. `fn_selftest` also gained `provision_agent_role_is_idempotent` and
`provision_agent_role_rejects_unknown_agent` — using one reused, fixed-name
test agent rather than creating a fresh one (and its role, a real
cluster-wide object) on every call, since `fn_selftest` is meant to be
callable repeatedly. Confirmed calling it twice in a row still leaves
exactly one `allgres_agent_*` role behind, not two.

**Deliberately not in this slice** (the rest of the review's proposal,
left for later, on purpose — not attempted shallowly here):

- capability roles (`allgres_cap_llm_call`, etc.) as an intermediate grant
  layer — right now a provisioned agent's role inherits `sandbox` as a
  whole, the same fixed grant set every agent gets, not a per-agent subset;
- RLS on any table other than what `v_sales`/`v_my_tasks` already enforced
  before this slice — `sessions`, `tasks`, `execution_logs`, `memories` (if
  one existed) are still gated by `SECURITY DEFINER` functions checking an
  `agent_id` parameter, not by PostgreSQL RLS keyed on role identity;
- sub-agent capabilities enforced as a subset of the parent's — `delegate`
  targets an existing agent, it does not create one, so there is no
  agent-driven role-provisioning path to restrict yet;
- provisioning is not exposed through the dashboard (no
  `agents.provision_role` RPC action) — today it only happens implicitly,
  inside `fn_create_agent`;
- role backup/restore: `agents.pg_role` values are cluster-global
  PostgreSQL roles, so `pg_dump` alone will not carry them —
  `pg_dumpall --globals-only` or an equivalent role manifest is needed for
  a full restore, and this has not been written or tested (see item 7's
  and item 4's existing backup/upgrade gaps, now with one more thing they
  need to cover).

## 16. Stale-completion fencing, and silent errors that used to hide real failures

Phase 3 of the second review round: "실행 정합성과 복구" (execution
consistency and recovery) — lease/fencing, a reconciler, cancellation
semantics, dead-letter/retry policy, and no silently swallowed errors.
Most of the list turned out to already be covered by what earlier passes
built, once checked against the actual code rather than assumed missing:

- **Reconciler** — `fn_watchdog` already is one: it reclaims stuck
  in-flight outbound/SQL calls, expires unanswered approvals, and fails a
  task that blew its wall-clock budget, all on its own periodic schedule,
  not as a manual operator action. Nothing new needed here beyond what
  items 10–15 already added to it.
- **Dead-letter / retry policy** — already exists: `fn_submit_result`
  counts `error`-role log entries per task and fails it permanently once
  `max_retries` is exceeded, no further retry. A per-call (rather than
  per-task) retry ceiling was never built, and still isn't; each new
  `execute_sql`/`call_llm` attempt is a fresh row, not a retried one.
- **Cancellation semantics** — item 12 already closed the main gap
  (queued/in-flight calls voided on cancel, claim functions joined to task
  status). What's still true and not fixed here: an *already in-flight*
  HTTP request or an *already executing* sandboxed query cannot be
  interrupted mid-flight — there is no separate backend to send
  `pg_cancel_backend()` at (sandboxed SQL runs on the runtime worker's own
  SPI thread, the same one running everything else), and no HTTP
  cancellation token wired into the pool threads. Cancel stops new work
  from starting and stops a stale result from being recorded (see below);
  it does not abort work already underway.

What genuinely was missing, found by reading the actual claim/complete
code rather than assuming the durable-queue shape was enough on its own:

- **No fencing on `fn_complete_outbound`/`fn_complete_sql`.** Both
  unconditionally overwrote the row to `'harvested'` and called
  `fn_submit_result` regardless of the row's current status. Concretely: a
  call gets claimed (`'in_flight'`); the worker hangs long enough for
  `fn_watchdog` to reclaim it as `'lost'`, which pushes a timeout error
  into the task and lets it retry; the *original* worker, unaware it was
  reclaimed, eventually finishes anyway and calls
  `fn_complete_outbound`/`fn_complete_sql` on the same `call_id` — and
  that belated result got recorded, into whatever the task is doing *now*,
  which by then may be a completely different turn. Fixed by checking the
  row is still `'in_flight'` (under the same `FOR UPDATE` lock already
  held) before touching anything; a call that has already moved on returns
  `{"action": "stale", ...}` and changes nothing. The row's own state is
  the fence — no separate token or table needed. Selftest:
  `complete_sql_fences_stale_result`, `complete_outbound_fences_stale_result`
  (mark a row `'lost'` the way `fn_watchdog` does, then complete it, assert
  nothing changed and no log was written).
- **Silent errors that hid real failures, not just benign ones.** The
  worst: `fn_dispatch_tasks`'s `EXCEPTION WHEN others THEN CONTINUE` around
  `fn_next_step` had no logging at all — a *persistent* (not transient)
  bug affecting one task would get silently retried, and silently skipped,
  every single dispatch tick, forever, with nothing anywhere to say so.
  Fixed with `RAISE WARNING` (always) plus a best-effort push into the
  task's own error/retry accounting via `fn_submit_result` (so a
  persistent failure eventually reaches `failed` via the existing
  `max_retries` dead-letter path, rather than looping forever). The same
  treatment went to `fn_watchdog`'s two nested
  `fn_submit_result`-inside-timeout-handling swallows (now
  `RAISE WARNING` instead of bare `NULL`), and to four Rust-side
  `let _ = Spi::run(...)` sites (`drop_privileges`, the `fn_watchdog`/
  `fn_dispatch_tasks` calls in `dispatch_and_claim`, and both
  `submit_http_result`/`submit_sql_result`) — each now logs via
  `pgrx::warning!` on failure instead of discarding the `Result` outright.
  `drop_privileges`'s case is the sharpest one: a silently discarded
  failure there used to mean every following statement in that transaction
  ran as the bootstrap superuser instead of `worker`, with zero trace.
  None of these become hard failures — the self-healing shape (watchdog
  reclaim, retry accounting) stays exactly as resilient as before — this
  is purely about an operator being able to *see* a persistent problem in
  the PostgreSQL log instead of it being invisible. Confirmed live: forced
  a `fn_next_step` failure (deleted an agent's policy row) and saw the
  `RAISE WARNING` fire with the task ID and `SQLERRM` in it; confirmed the
  healthy path (a full `fn_selftest`/`tests/smoke.sql`/`tests/e2e_mock.sql`
  run) produces no warnings at all, so this isn't just moving the noise
  problem from "invisible" to "log spam" in the other direction.

Still not done, deliberately out of scope for this slice: a full
`task_attempts` table with heartbeats and fencing tokens (the row-status
check above is a lighter-weight fence that closes the concrete race that
existed, not the general primitive the review describes); actually
interrupting in-flight work on cancel; a per-call retry ceiling separate
from the per-task one.

## 17. Agent self-modification (`propose_change`), operator-governed

Phase 4 of the second review round: "안전한 자가성장" (safe self-growth) —
the review's own framing was that an agent should be able to improve its
knowledge and behavior spec, but never expand its own trust boundary.
Before this pass, Allgres had zero self-modification capability at all:
the action set was exactly `{final_answer, execute_sql, call_tool,
delegate, await_human}`, and `fn_set_policy` was reachable only from
`dashboard_rpc`'s operator-only `agents.update`. This is a new capability
built from scratch, not a hardening of something that already existed —
scoped deliberately by the user up front to exclude a regression-
evaluation engine (test cases, scoring, an LLM judge) and the separate
memory/provenance subsystem the same review round proposed; both stay out
of scope.

**What was built**: a `propose_change` agent action
(`fn_submit_result`), a new `argo_private.change_proposals` table, and two
new operator-only functions (`fn_decide_proposal`, `fn_rollback_policy`),
exposed through three new `dashboard_rpc` actions
(`proposals.list`/`proposals.decide`/`policy.rollback`) and a new
`Proposals` dashboard page plus a rollback button on each row of the
existing policy-history view. Full design and the exact allowed-field list
are in README, "Self-modification" — not duplicated here.

The trust-boundary line is enforced at the point of insertion, not just
described: `fn_submit_result` checks every key in `changes` (and every key
inside `changes.llm_config`, if present) against a fixed allow-list before
a proposal row is even created; anything outside it is rejected with a
logged `error` entry and no row written, rather than silently dropped or
partially applied. Approval reuses the existing `fn_set_policy`/
`policy_history` versioning machinery as-is (the same merge semantics —
`llm_config` merges key-by-key, `NULL` leaves a field unchanged — and the
same field-by-field `IS DISTINCT FROM` no-op detection), so a promoted
proposal is indistinguishable in history from a manual operator edit, and
a rollback is a new version, never a mutation of an old one.

**Staleness, not blind overwrite**: `change_proposals.base_generation`
captures `policies.generation` at propose time; `fn_decide_proposal`
compares it against the *current* generation before applying an approval.
A live policy that moved on in the meantime — an operator edit, or another
proposal approved first — makes the decision `stale` instead of silently
clobbering whatever changed it.

**A table-ordering bug caught before it shipped**: `change_proposals` was
first placed early in `control_plane.sql`, alongside `policy_history`,
with a `REFERENCES argo_private.tasks(task_id)` foreign key — but `tasks`
is not defined until much later in the same file, which replays linearly
in one transaction. `CREATE EXTENSION allgres;` failed outright
(`relation "argo_private.tasks" does not exist`) rather than doing
anything silently wrong. Fixed by moving the table definition to
immediately after `tasks`'s own indexes, matching the file's existing
dependency-order convention.

Verified the same way as every prior pass: rebuilt against local
PostgreSQL 16.15, `fn_selftest` 78/78 (six new cases: a proposal queues
without touching the live policy; disallowed fields — `max_steps`,
`llm_config.provider` — are rejected with no row created; reject leaves
the policy untouched; approve versions and applies; a stale base is
detected and does not overwrite; rollback restores a prior version as a
new generation), `tests/smoke.sql` and `tests/e2e_mock.sql` both green.
Also driven through the real `dashboard_rpc` entry point end to end, not
just `fn_selftest`'s direct calls: a real agent's `execute_sql`-adjacent
`propose_change` action queued through the actual `fn_submit_result` path,
listed via `proposals.list`, approved via `proposals.decide`, confirmed
the live `system_prompt`/`generation` actually changed and a *new*
session for that agent picks up the new prompt (not just that the row
says so), then rolled back via `policy.rollback` and confirmed the
original prompt came back under a further-incremented generation, not a
history rewrite.

What's deliberately not here, beyond the two exclusions named above: no
confirmation dialog before a dashboard rollback beyond the browser's
own — same caveat item 11 already names for `sessions.cancel`; no operator
identity attached to a decision or a rollback, for the same reason item
10 gives (no accounts system yet); no rate limit or cooldown on how often
one agent can propose (a persistently misbehaving agent can fill the
pending queue, though every entry still requires an explicit operator
decision — nothing auto-applies).
