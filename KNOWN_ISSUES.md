# Known issues and future work

Status as of 0.3.0. Verified natively on PostgreSQL 16.15 with pgrx 0.19.2
(Docker/PG17, this environment's actual deployment target, could not be
reached to verify against — see item 3): `fn_selftest` 78/78, `tests/smoke.sql`
and `tests/e2e_mock.sql` pass, and the full path browser → web worker → unix
socket → runtime SPI thread → PL/pgSQL works end to end over real HTTP
(`curl` against `/api/v1/rpc`, CSRF checks included), including a live
`dashboard_rpc` round trip for every action added so far (`projects.*`,
`approvals.*`, `sessions.cancel`/`.list`/`.get`, `permissions.*`,
`allowlist.*`, `policy.history`, `policy.rollback`, `proposals.*`) and the
`web/index.html` pages that call them (`Projects`, `Sessions`, `Approvals`,
`Proposals`, plus the extended `Agents` and `Settings`). A real
`ALTER EXTENSION allgres UPDATE TO '0.3.0'` from a real prior version, and a
physical (`pg_basebackup`/PITR) and logical (`pg_dump`) backup/restore drill,
are also verified — see item 18. Earlier builds were verified on
PostgreSQL 18.6; nothing here is PG-version-specific.

Everything below is either not implemented or not verified. Nothing here is
believed to be broken in a way that is currently exploitable, but each item is
a gap between what the code does and what it should do.

## 1. ~~Agent SQL does not run as the `sandbox` role~~ — fixed

`fn_execute_sql` validated *and* executed in one `SECURITY DEFINER` call, which
is exactly what made `SET ROLE sandbox` illegal (PostgreSQL refuses `SET ROLE`
inside a security-definer function, and the restriction covers the whole call
stack below one). It is now split: `fn_validate_sql` only validates and
returns the normalized statement text; the runtime worker queues that text in
`allgres_private.sql_calls` and its SPI thread claims and runs it
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

## 3. Docker image path is unverified in this environment (but now in CI)

The build was verified natively against PostgreSQL 18. The `Dockerfile` targets
`postgres:17-bookworm` and builds `--features pg17`, and `scripts/smoke.sh`
requires Docker; neither has been run *in this environment* (no Docker daemon
reachable here). `.github/workflows/ci.yml`'s `docker-smoke` job now runs
`scripts/smoke.sh` on every push, and `native-matrix` builds and runs
`fn_selftest`/`tests/smoke.sql`/`tests/e2e_mock.sql` against real PG16/17/18
native installs the same way this file's other native verification has always
been done — see item 18. Until that workflow has actually run once on GitHub's
infrastructure, "added to CI" is not the same claim as "verified there."

`nodeToString` field names and `RawParseMode` are stable across 17 and 18, so
this is expected to work, but "expected" is not "tested".

## 4. ~~Extension upgrade has only been installed fresh~~ — fixed

`sql/allgres--0.1.0--0.2.0.sql` used to be generated and installed but never
actually exercised: no real, distinct "0.1.0" install had ever existed in
this repository to upgrade *from* (see item 18 for the full account and the
fix — a frozen, real `sql/allgres--0.2.0.sql` base and a version bump to
0.3.0). `ALTER EXTENSION allgres UPDATE TO '0.3.0'` is now a real, tested
operation: installed at a real prior version, seeded with realistic data
across every subsystem, upgraded, and confirmed byte-for-byte identical
afterward, plus `fn_selftest`/`tests/smoke.sql`/`tests/e2e_mock.sql` all
green post-upgrade.

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

## 8. ~~No rate limiting on the dashboard API~~ — fixed

`/api/v1/*` had a connection cap (64 threads) but no per-client rate limit.
Fixed in item 18: a per-IP sliding-window cap on every request, plus a
separate, tighter cap specifically on failed-auth (401) responses so a
token-guessing script locks out faster than an ordinary slow client ever
could trip the general cap.

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
resumed agent sees it on its next turn. `allgres_private.human_approvals` also
gained `expires_at` (`fn_submit_result` sets a 24h default) and `fn_watchdog`
auto-rejects a `waiting_human` task nobody ever answers, the same
durable-queue-plus-watchdog shape used for `outbound_calls`/`sql_calls`, on
human timescales instead of machine ones.

`allgres_private.projects` was added to group sessions (agents stay
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
- **Policy version history** — `allgres_private.policies` gained `generation`;
  `allgres_private.policy_history` is an append-only snapshot of every prior
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
  a call to Allgres's own `allgres_private.secret_key()`.
- **SSRF: the outbound guard checked a hostname string, never the address it
  resolves to.** `allgres_private.is_blocked_host` (used at SQL build/queue
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
  that header straight into `allgres_private.outbound_calls.request_headers`
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

Fixed by adding `allgres_private.sql_function_allowlist`, seeded with the
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
(`SELECT region, sum(amount), count(*) FROM allgres_public.v_sales GROUP BY
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
installs the extension already creates `allgres_owner`/`operator`/`worker`/
`sandbox` in the roles bootstrap, so it already has `CREATE ROLE` power
(typically as a superuser); `fn_provision_agent_role`, like every other
`SECURITY DEFINER` function in this file, is owned by that same installer
and asks for nothing new.

**A real bug this slice caught, live, before it shipped**: the first
version of `current_agent_id()` looked `pg_role` up in
`allgres_private.agents` by `current_user`, and was `SECURITY DEFINER` (it
has to read a table `sandbox` has no grant on). That silently broke
every agent's own permission check — confirmed live: an agent granted
its own view read back zero rows. The reason is a `SECURITY DEFINER`
property easy to forget: it changes `current_user` to the function's
*owner*, for everything nested inside it, for the rest of that function's
execution — `agent_may_read` is already `SECURITY DEFINER` (it reads
`allgres_private.permissions`/`sql_sandbox_allowlist`), so calling
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
(`fn_submit_result`), a new `allgres_private.change_proposals` table, and two
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
with a `REFERENCES allgres_private.tasks(task_id)` foreign key — but `tasks`
is not defined until much later in the same file, which replays linearly
in one transaction. `CREATE EXTENSION allgres;` failed outright
(`relation "allgres_private.tasks" does not exist`) rather than doing
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

## 18. Phase 5: operational stability — dashboard auth/SSE hardening, a real extension upgrade path, a PG-version CI matrix, and a backup/PITR drill that found two real bugs

Phase 5 of the second review round: "운영 안정성" (operational stability) —
backup/PITR, extension upgrade/rollback, a PG-version CI matrix, and
dashboard auth/SSE hardening. Four mostly-independent pieces; each is
described where it landed rather than duplicated here.

- **SSE auth no longer puts the durable token in a URL.** `/api/v1/events`
  used to accept the dashboard token itself as a query parameter (documented
  necessity: `EventSource` cannot set request headers). That put a long-lived
  credential in a place proxy access logs, browser history, and the
  Referrer header can all see. Fixed with a short-lived (30s), single-use
  ticket: `POST /api/v1/events/ticket` (gated by the real bearer token, same
  as every other route) mints one; `GET /api/v1/events?ticket=...` consumes
  it. Because a ticket cannot be replayed, reconnection is now client-driven
  (`startEvents` in `web/index.html` mints a fresh ticket and opens a new
  `EventSource` on every `error` event) rather than relying on the browser's
  native retry-with-the-same-URL, which the server's own `retry:` field used
  to invite every ~30s (the server deliberately closes the stream on that
  cycle; see `stream_events` in `src/lib.rs`). Verified live end-to-end
  through a real headless browser (Playwright/Chromium): token set, page
  loaded, health line reaches "workers online," survives one full ~30s
  server-side stream-close-and-reconnect cycle, zero console errors. Unit
  tests: a ticket authorizes exactly once and expires; the raw token in the
  query string no longer authorizes anything.
- **Per-IP rate limiting on the dashboard API.** Two independent sliding
  windows (`src/lib.rs`, `rate_limited`/`auth_failures_exceeded`): a general
  cap (120 requests/60s) on every request, and a much tighter one (20
  failed-auth responses/300s) specifically on 401s, checked *before* the
  real token comparison runs so a locked-out IP cannot keep spending a
  thread and a constant-time compare on every attempt. Both return 429.
  Verified live against the real HTTP listener: hammering `/healthz`
  actually trips 429 at the real socket layer, not just in a unit test.
  Known limitation, inherent to any per-IP scheme: an attacker rotating
  source IPs is not slowed by this at all.
- **A real, tested extension upgrade path.** `sql/allgres--0.1.0--0.2.0.sql`
  (item 4, before this fix) was never actually testable: this repository
  never had a genuine, distinct "0.1.0" — every commit since the first one
  regenerated that file as a byte-for-byte copy of whatever
  `sql/control_plane.sql` said *right now*, so `ALTER EXTENSION ... UPDATE`
  had nothing real to upgrade *from*. Fixed by freezing an actual base:
  `sql/allgres--0.2.0.sql` is a real snapshot of the schema as it stood at
  the end of 0.2.0 development (commit `12e1df7`), the crate version bumped
  to 0.3.0, and `sql/allgres--0.2.0--0.3.0.sql` regenerated for real against
  that base. The `Dockerfile` and `.github/workflows/ci.yml` both now copy
  every `sql/allgres--*.sql` file into the extension directory (base
  snapshots included, not only `--from--to` upgrade scripts, which is all
  the old glob matched). Verified live: installed fresh at a real 0.2.0,
  seeded realistic data across every subsystem (agents, sessions, tasks,
  policies with history, pending/decided proposals, projects, a provider
  secret), ran `ALTER EXTENSION allgres UPDATE TO '0.3.0'`, confirmed every
  piece of seeded state came back byte-for-byte identical (hashed
  comparison) and reachable through the real `dashboard_rpc` entry point,
  then `fn_selftest`/`tests/smoke.sql`/`tests/e2e_mock.sql` all green
  post-upgrade. Going forward, each future version bump freezes one more
  base snapshot the same way.
- **A PG-version CI matrix** (`.github/workflows/ci.yml`, new). A
  `native-matrix` job builds and runs `fn_selftest`/`tests/smoke.sql`/
  `tests/e2e_mock.sql` against real, natively-installed PostgreSQL 16, 17,
  and 18 (PGDG apt packages), plus the Rust unit test suite, on every push
  and PR. A separate `docker-smoke` job runs the existing
  `scripts/smoke.sh` (the Dockerfile/docker-compose path). Neither job has
  actually run on GitHub's infrastructure yet as of this writing — see item
  3 for what "added to CI" does and does not claim until it has.
- **A backup/PITR drill that found two real bugs**, both now fixed and both
  covered by `scripts/backup_drill.sh`, a runnable, re-runnable script (not
  just documentation) that this session actually ran, repeatedly, against a
  real local PostgreSQL 16 install:
  - **`pg_dump` silently excluded 100% of Allgres's runtime data.**
    PostgreSQL excludes data belonging to an extension's own tables from a
    logical dump by default — schema only, regenerated fresh by
    `CREATE EXTENSION` on restore — unless a table is explicitly registered
    via `pg_extension_config_dump()`. Nothing in `sql/control_plane.sql`
    ever called it. Confirmed live before fixing: a real agent, session,
    and task, dumped with `pg_dump -Fc` and restored into a fresh cluster,
    came back with *none* of it — every agent, session, task, policy, log,
    and secret gone, with no error anywhere to say so; the restored
    database looked like a normal, working, empty install. Fixed by
    registering every table that holds real operator/agent state (agents,
    policies, permissions, demo_sales, llm_providers, and
    sql_sandbox_allowlist with a filter excluding exactly the rows section
    10's own seed inserts, since those get recreated fresh by
    `CREATE EXTENSION` either way; policy_history, projects, sessions,
    tasks, execution_logs, human_approvals, change_proposals, llm_secrets,
    outbound_calls, and sql_calls unconditionally). `sql_function_allowlist`
    and `oauth_states` are deliberately left unregistered — see the comment
    at "10b." in `sql/control_plane.sql` for why. One real, permanent cost
    of the seed-row exclusion: an operator's own edit to a *built-in*
    provider row (base_url, is_enabled, allow_private_network, a stored
    secret) does not survive a `pg_dump`-based restore — only a wholly new
    provider row would. Physical backup (`pg_basebackup`/PITR) has no such
    gap.
  - **Built-in LLM provider rows had random, per-install ids.** Excluding
    the seeded `llm_providers` rows from the dump (above) only works if
    every install's 'openai' row has the *same* `provider_id` — otherwise
    any dumped row that references it by id (`llm_secrets`, `outbound_calls`)
    points at an id that doesn't exist on the restore target, and the
    restore fails on a foreign key violation. It used to be
    `gen_random_uuid()`, different every install. Confirmed live: exactly
    this failure, on the first attempt. Fixed by giving each of the five
    built-in providers a fixed, hardcoded `provider_id` in the seed insert.
    Forward-only, by construction of `ON CONFLICT (name) DO NOTHING`: an
    install that already seeded these rows before this fix keeps its old
    random id (the row already exists by name, so the fixed-id insert is
    skipped); only a fresh install, or a restore onto one, gets the fixed
    id from here on. No migration is provided for an already-seeded
    install to adopt the fixed id retroactively — out of scope for this
    pass.
  - **The correct restore technique needed a real fix too, not just a flag.**
    `pg_restore --disable-triggers` is the standard companion to
    `pg_extension_config_dump` (it is meant to stop exactly the
    `agents_ensure_policy` trigger, item 15, from firing while the dumped
    `agents` rows load and creating a default `policies` row that then
    collides with that same agent's real one arriving right behind it) —
    but `pg_restore --help` says outright that the flag only takes effect
    during a `--data-only` restore; combined with a full restore it is
    silently a no-op, discovered live when it did not fix anything. The
    correct technique, confirmed live, is two passes: `pg_restore
    --schema-only` (creates the extension and its own seed data), then
    `pg_restore --data-only --disable-triggers` (loads everything else,
    triggers off). `scripts/backup_drill.sh` and README, "Upgrades," both
    now say this explicitly rather than a bare `pg_restore dump.file`.
  - Also verified, once both bugs above were fixed: point-in-time recovery
    actually lands at the intended timestamp, not just "replay everything"
    (an agent created before the recovery target is present after restore;
    one created after it is not); a per-agent PostgreSQL role
    (`agents.pg_role`, item 15) and the row-level isolation it gates both
    survive a full logical dump/restore into a wholly fresh cluster, not
    only a physical one; `fn_selftest` is clean on both restored instances.
  - `scripts/backup_drill.sh` is safely re-runnable (confirmed three times
    in a row): it cannot clean up a previous run's test data by deleting it
    (`execution_logs` is append-only by design — enforced by trigger and by
    `REVOKE`, not just convention — so a repeat run's cleanup attempt itself
    failed loudly the first time this was tried, which is the append-only
    invariant working as intended, not a script bug to route around), so
    each run's test agents get a unique per-run suffix instead and the tiny
    rows a run leaves behind are permanent, exactly like every other
    agent's audit trail in this database.

Still not done, deliberately out of scope for this pass: automated backup
scheduling or retention (this is a drill an operator runs, not a cron job);
a migration path for an already-seeded install to adopt the new fixed
provider ids; secret key rotation (item 7, unrelated to this pass but still
open); per-operator dashboard accounts (items 10/11, still open — the SSE
ticket mechanism authenticates the *session*, not a *person*).

## 19. Argo fully retired: internal schema/role names are now `allgres_*`

The project's original name, Argo, had never been fully removed: three
internal identifiers — the `argo_private`/`argo_public` schemas and the
`argo_owner` role — still carried it, kept for what the file's own header
comment called "upgrade compatibility." That reasoning did not hold up:
this project has never had a real prior release to be compatible *with* —
item 18 already established that "0.1.0" was never a genuine install, only
a placeholder — so nothing was actually gated on the old names surviving.
Renamed everywhere, on explicit direction: `argo_private` →
`allgres_private`, `argo_public` → `allgres_public`, `argo_owner` →
`allgres_owner`, across `sql/control_plane.sql`, `src/lib.rs`,
`tests/*.sql`, `scripts/backup_drill.sh`, `web/index.html`, and this
project's own docs — roughly 2,800 occurrences, all three identifiers used
consistently enough that a global substitution was safe (confirmed by
enumerating every distinct `argo_*` token in the codebase first: there
were exactly these three, nothing else).

**This is not just a text rename — it changes what `ALTER EXTENSION ...
UPDATE` has to do**, since the *just-shipped* item 18 froze a real
`sql/allgres--0.2.0.sql` base under the *old* names (a true historical
snapshot — it stays that way; do not edit it to match this rename). Without
a real migration, upgrading from that frozen 0.2.0 base to 0.3.0 would have
either failed outright (a plain `CREATE SCHEMA IF NOT EXISTS
allgres_private` next to an existing, still-populated `argo_private` leaves
two parallel schemas, one dead) or silently orphaned every row already
sitting under the old names. Fixed with an explicit migration block at the
top of "1. Roles" in `sql/control_plane.sql`: `ALTER ROLE argo_owner RENAME
TO allgres_owner` and `ALTER SCHEMA argo_private/argo_public RENAME TO
allgres_private/allgres_public`, guarded by `IF EXISTS <old> AND NOT EXISTS
<new>` so it is a no-op on a fresh install (neither old name ever existed)
and a real rename-in-place on an upgrade from 0.2.0 or earlier — every
object and every row stays exactly where it is, just reachable under the
new name. This has to run *before* the ordinary `CREATE ROLE`/`CREATE
SCHEMA IF NOT EXISTS` block that follows it, not after: that block, finding
no `allgres_owner` yet, would otherwise create an empty one first, and the
rename's own `NOT EXISTS <new>` guard would then block the real rename from
ever running — caught in review before it shipped, not live, this once.

Verified live, both directions:

- **Fresh install** (`CREATE EXTENSION allgres;`, no history): produces
  `allgres_private`, `allgres_public`, `allgres_owner` directly; the
  migration guards are no-ops since neither old name exists.
  `fn_selftest` 78/78, `tests/smoke.sql` and `tests/e2e_mock.sql` green.
- **Upgrade from a real 0.2.0** (`CREATE EXTENSION allgres VERSION
  '0.2.0';`, seeded with a real agent, a session, a granted permission, and
  a provider secret under the *old* schema names, then `ALTER EXTENSION
  allgres UPDATE TO '0.3.0';`): confirmed `argo_owner`/`argo_private`/
  `argo_public` are gone afterward (not left behind alongside the new
  ones), `allgres_owner` exists exactly once (not duplicated), and every
  piece of seeded data — the agent, its per-agent PostgreSQL role, the
  session, the decrypted provider secret — reads back correctly under
  `allgres_private`/`allgres_public`. `fn_selftest`, `tests/smoke.sql`, and
  `tests/e2e_mock.sql` all green on the migrated instance too. A first
  attempt at this test gave a false pass: a leftover `allgres_owner` role
  from earlier ad hoc testing in the same PostgreSQL cluster (roles are
  cluster-global, not per-database) satisfied the migration's `NOT EXISTS
  <new>` guard by coincidence, masking whether the rename logic itself was
  correct. Redone from a fully clean cluster (both old and new role/schema
  names dropped first) to get an uncontaminated result.
- `scripts/backup_drill.sh` (item 18) re-run end to end against the
  renamed schema: both the physical (PITR) and logical (`pg_dump`) paths
  still pass unmodified beyond the identifier rename itself.

One operational note for anyone applying this upgrade to a real 0.2.0
install outside this repo: `CREATE EXTENSION allgres VERSION '0.2.0';`
must run in a database with no other `allgres_owner`/`allgres_private`/
`allgres_public` already present in that cluster (which, for a real prior
install, should never be the case) — the same ambiguity the "false pass"
above hit in testing. The migration deliberately does not force a rename
when the new name already exists (it would either fail on a real conflict
or silently clobber something), so that specific case needs a human to
look at what is actually there before proceeding, rather than the upgrade
script guessing.

## 20. A second-round external review of items 18 and 19: real CI failure, silent PUBLIC access on ~50 functions (one of them the encryption key itself), fail-open privilege drop, and a decorative owner role

An external review of the branch found six real, verified problems in the
work items 18 and 19 describe — most of them worse in practice than the
review itself estimated once checked against the actual database. Every
item below was independently confirmed (not just accepted on the review's
say-so) before being fixed, and several were found only *because* of that
verification, not named by the review at all.

- **CI was actually failing, for a mundane reason.** Item 18's CI matrix
  had never run on GitHub's own infrastructure. It failed on all three
  PostgreSQL versions at the same step: `cargo pgrx install` writing to
  `/usr/lib/postgresql/*/lib/`, owned by root on the GitHub-hosted runner,
  whose default user is not root — `Permission denied (os error 13)`, from
  the actual job log. This session's own local testing never caught it
  because this sandbox runs as root throughout. Fixed by `chown`ing the
  target directories to the runner user before the unprivileged `cargo
  pgrx install` call, rather than wrapping the whole cargo invocation in
  `sudo` (which would need to correctly preserve rustup's PATH/HOME).
  Verified against the actual log; the fix has not yet run in CI as of
  this writing (that requires an actual push).
- **The rename migration (item 19) could silently rename an unrelated
  object, and silently orphaned data on a real collision.** Both real:
  confirmed live, "argo_private exists" alone was accepted as proof it was
  Allgres's own schema, and old-name-plus-new-name-both-exist was silently
  skipped rather than raising. Fixed with two independent changes: each
  schema is now checked for one object only Allgres would have put there
  (`argo_private.agents`, `argo_public.fn_selftest`) before being touched,
  and every ambiguous state (old and new both present) now `RAISE
  EXCEPTION`s with a message naming exactly what to resolve, instead of
  proceeding. Both failure modes reproduced live before the fix (a
  same-named-but-foreign schema correctly refused; both names present
  correctly refused) and confirmed a real 0.2.0-to-0.3.0 upgrade still
  works end to end after the fix.
- **`allgres_owner` existed but owned nothing — confirmed independently,
  and it was worse than the review's own framing.** Every schema and every
  `SECURITY DEFINER` function in a fresh install was owned by whichever
  superuser ran `CREATE EXTENSION`, `allgres_owner` was a role nothing
  actually used. Fixed with an idempotent ownership-transfer pass (new,
  end of "12. Grants") that iterates every table/view/sequence/function in
  the three Allgres schemas and reassigns ownership to `allgres_owner`,
  replayed on every install/upgrade. One function is deliberately
  excepted: `fn_provision_agent_role`, the only thing in this file that
  runs a dynamic `CREATE ROLE`, is owned by a new, separate,
  narrowly-scoped `allgres_role_admin` role (`NOLOGIN NOINHERIT
  CREATEROLE`) instead — giving `allgres_owner` itself `CREATEROLE` so
  that one function could work would hand every other function sharing
  that owner the same power, for no reason any of the rest of them need
  it. Getting this to actually work live surfaced three more real,
  narrower gaps the ownership split itself introduced (each found by
  running `fn_selftest`/`tests/smoke.sql`/`tests/e2e_mock.sql` against the
  result, not by inspection): the `allgres` schema itself was left out of
  the transfer at first (`fn_selftest` broke: "permission denied for
  schema allgres"); the cross-owner call from `fn_create_agent`
  (`allgres_owner`) to `fn_provision_agent_role` (`allgres_role_admin`)
  needed its own `EXECUTE` grant, which two same-owner functions never
  needed before (`fn_create_agent` broke: "permission denied for function
  fn_provision_agent_role"); and `allgres_role_admin` needed `ADMIN
  OPTION` on `sandbox`/`worker`, not just membership, to grant those roles
  to the agent roles it provisions (`CREATEROLE` alone was not enough,
  confirmed live, contrary to this session's own first assumption about
  PostgreSQL 16's relaxed `CREATEROLE` semantics). `ALTER ROLE ... RENAME`
  also does not touch a role's other attributes, so a renamed `argo_owner`
  (`LOGIN`, from any 0.2.0-era install) stayed `LOGIN` after becoming
  `allgres_owner` — caught the same way, fixed with an unconditional
  `ALTER ROLE allgres_owner NOLOGIN NOINHERIT;` replayed every install,
  not only at creation time.
- **PostgreSQL's PUBLIC-executes-by-default was open on ~50 functions,
  independently confirmed to be far more severe than the review's own
  report.** The review named one instance
  (`fn_oauth_token_request` returning a decrypted OAuth client secret to
  any caller). Checking every function in the three Allgres schemas the
  same way found that only about a dozen, out of roughly fifty, had ever
  had `PUBLIC`'s default `EXECUTE` explicitly revoked — the rest,
  including `allgres_private.secret_key()` (the literal `pgcrypto` key
  that encrypts every provider API key in the system) and the entire
  operator-facing API (`fn_create_agent`, `fn_grant_permission`,
  `fn_decide_approval`, `fn_set_policy`, `fn_cancel_session`, and more),
  were callable by *any* role that could merely connect to the database —
  no Allgres role membership needed at all. Fixed with a blanket
  `REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA ... FROM PUBLIC` for all
  three schemas (plus `ALTER DEFAULT PRIVILEGES` for whatever gets added
  later), which — because it is a snapshot against what exists at the
  point it runs, not a standing rule — needed a second copy near the end
  of "13." specifically for the four native-facade functions
  (`create_agent`, `create_session`, `pump`, `assume_worker_role`) defined
  after the first one runs; confirmed live that these four were still
  `PUBLIC`-executable after only the first revoke. Verifying this against
  the real `sandbox` role (not `fn_selftest`, itself `SECURITY DEFINER`
  and so exempt from exactly this class of gap the same way testing as
  superuser is) surfaced two functions that legitimately needed an
  explicit grant restored, both called directly from `v_sales`/
  `v_my_tasks`'s own `WHERE` clause rather than from inside another
  owned function: `current_agent_id()` (`SECURITY INVOKER` by design, so
  it runs as whoever queries the view, not as an owner) and
  `agent_may_read()` (`SECURITY DEFINER`, which was the wrong reason to
  assume it needed no caller-side grant — `SECURITY DEFINER` changes what
  a function's own body runs as once it is allowed to start, it does not
  waive the `EXECUTE` check needed to call it at all). Both now have an
  explicit `GRANT ... TO sandbox`, inherited by every per-agent role via
  `sandbox` membership.  The OAuth instance the review named is separately
  carved out of `operator`'s existing blanket grant on `allgres_public`
  (see below) rather than left to the general schema-wide revoke alone,
  since `operator` legitimately has broad access to that whole schema by
  design and would otherwise still reach it.
- **`fn_oauth_token_request` returns a decrypted secret to its caller,**
  confirmed, and worse once ownership was fixed: `operator` reaches it
  through the existing `GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA
  allgres_public TO operator` (a deliberate, broad, pre-existing grant —
  not new), which breaks the same "the dashboard never returns a secret,
  only whether one is set" invariant `provider_secret()` being revoked
  from `operator` two lines below it already exists to enforce.  Nothing
  calls any of the three OAuth functions today (the token exchange HTTP
  call itself was never implemented — see item 6), so this is not
  breaking a working feature: `fn_oauth_start`/`fn_oauth_token_request`/
  `fn_oauth_store_tokens` are now explicitly revoked from `operator`
  again, right after the blanket grant, until OAuth is finished with a
  real design for this — the outbound-queue pattern that already fixed
  the identical class of leak for LLM provider keys (item 13: resolve the
  credential at claim time, inject it only into the runtime worker's own
  response, never write it back anywhere a caller's result or a table
  could expose it) is the template, not attempted here.
- **`drop_privileges()` failing was logged but not actually fail-closed** —
  confirmed real, though independent analysis found the practical
  severity lower than the review's framing for five of its six call
  sites: `dispatch_and_claim`, `submit_http_result`, `dashboard_rpc`,
  `claim_sql_jobs`, and `submit_sql_result` all only ever call `SECURITY
  DEFINER` control-plane functions, which run as their *owner* (now
  `allgres_owner`, per the ownership fix above) regardless of the
  caller's role — so whether the drop succeeded was already not changing
  what ran inside them. `run_sandboxed_sql` is the one call site where it
  actually was the primary boundary (agent-generated SQL runs as a
  top-level statement specifically so it *can* `SET ROLE`, see "The SQL
  sandbox"), and it already built its own `dropped` flag from the
  subsequent `SET LOCAL ROLE <agent>` chain and failed closed on that —
  just without `drop_privileges()`'s own result folded in. Fixed
  everywhere anyway, both for the narrower real gap and so the boundary
  does not silently start depending on which code path happens to reach
  it after some future change: `drop_privileges()` now returns whether
  the drop landed, and all six call sites skip their own work when it did
  not, rather than logging a warning and proceeding as the bootstrap
  superuser. Verified live: `fn_selftest`, `tests/smoke.sql`, and
  `tests/e2e_mock.sql` (the last of which exercises the real background
  worker end to end) all still pass, and the PostgreSQL log is clean —
  the fail-closed paths exist but do not fire on the healthy path.
- **`scripts/backup_drill.sh` (item 18) had three real gaps of its own,**
  found on review rather than live failure: `rm -rf "$SCRATCH"` trusted an
  overridable environment variable with no validation (now refuses
  anything not under `/var/lib/postgresql/`); the globals-restore `psql`
  call had no error checking at all, meaning a real failure alongside the
  one expected, harmless one (`CREATE ROLE postgres` erroring because
  initdb already created it) would have gone unnoticed (now captures the
  log and fails the drill on any `ERROR:` line that isn't the expected
  one); and the role-isolation check assumed a role straight from the
  `postgres` superuser session, which can `SET ROLE` to anything
  regardless of actual membership grants, so it was not actually proving
  the real runtime path (`drop_privileges()` → `worker`, then
  `run_sandboxed_sql`'s own `SET LOCAL ROLE <agent>`) survives a restore —
  only that the agent role exists at all. Fixed by hopping through
  `worker` first, the same as the real path, so the second `SET ROLE`
  only succeeds if `worker`'s membership in the agent role actually
  survived the dump/restore. All three fixes verified live, including
  three consecutive clean re-runs to confirm nothing about the new checks
  broke the drill's own re-runnability.

  Applying those fixes surfaced a fourth, unrelated bug in the script,
  live: the PITR restore's wait loop only polled `pg_isready`, which
  reports success as soon as the server accepts connections — true during
  hot-standby WAL replay, *before* `recovery_target_action = 'promote'`
  has actually finished promoting to a writable primary. Two different
  failures came from the same race, on different runs: a stale read
  (`before=0 after=0`, recovery had not replayed up to the target LSN
  yet) and, once that looked fixed by luck, `fn_selftest` failing outright
  with "cannot execute UPDATE in a read-only transaction" — still not
  promoted. Fixed by waiting on `pg_is_in_recovery() = false` specifically
  instead of just connectivity. Confirmed with two further consecutive
  clean runs after the fix.

Also raised, deliberately not changed: **the plaintext-secret fallback
when `ALLGRES_SECRET_KEY` is unset.** Checked against the actual code —
this is an existing, explicit, already-documented design choice (the
source comment literally reads "a deliberate choice"; `secret_storage_mode()`
reports exactly which of several plaintext reasons applies; the dashboard
shows a warning banner derived from it), not a silent gap of the kind
every item above is. The review's suggestion — refuse to store a secret
at all without a key, or require an explicit opt-in env var to allow
plaintext — is a legitimate, reasonable hardening option, but it is a
product/policy trade-off (it would make the tool refuse to run without a
key for anyone currently relying on plaintext mode for a quick local
setup, which matches this project's own stated "one person's small
setup" scope) rather than a bug that contradicts what the code already
claims to do, so it was surfaced as a decision rather than changed
unilaterally.

## 21. CI, round two: PG17/PG18 never got a cluster to install into

Item 20's `cargo pgrx install` permission fix worked exactly as intended —
confirmed from the actual next CI run: all three matrix legs now build,
`cargo test` passes, and `cargo pgrx install` completes cleanly with no
`EACCES` on 16, 17, *and* 18. `native-matrix (16)` went fully green. 17 and
18 failed one step later, in "Configure and restart the cluster":
`tee: /etc/postgresql/18/main/postgresql.conf: No such file or directory`.

Root cause, confirmed by diffing the two jobs' actual logs line by line:
GitHub's `ubuntu-latest` runner image preinstalls PostgreSQL 16 with a
running `16/main` cluster already created at image-build time, but ships
`postgresql-common` configured with `create_main_cluster = false` — so
installing any *other* major version's PGDG package (`postgresql-17`,
`postgresql-18`) only unpacks the binaries; nothing calls
`pg_createcluster` for them, and `/etc/postgresql/{17,18}/main/` never
comes into existence. The workflow's "Install PostgreSQL N (PGDG)" step
looked identical for all three versions and reported success for all
three — the actual apt install truly did succeed in every case — so this
was invisible without reading the full install-step output side by side
for a passing version and a failing one, not just the failing job's error
line.

Fixed with a one-line guard right after the package install, in the same
step: if `/etc/postgresql/${{ matrix.pg }}/main/postgresql.conf` doesn't
already exist, run `sudo pg_createcluster ${{ matrix.pg }} main` before
moving on. A no-op for 16 (the file already exists), and creates the
missing cluster for 17/18.

That fix alone was not enough, confirmed from the very next CI run on
this same commit: `native-matrix (18)` got past cluster creation and the
config `tee` cleanly, but then failed at `CREATE EXTENSION` with
`connection to server on socket "/var/run/postgresql/.s.PGSQL.5432"
failed: No such file or directory`. The PostgreSQL log for the same run
showed the real cause: `listening on Unix socket
"/var/run/postgresql/.s.PGSQL.5433"` — the runner image's preinstalled
default PostgreSQL service already holds port 5432 (that default service
is what 16/main actually is, on this image), so `pg_createcluster 18
main` auto-assigned the next free port, 5433, and every downstream `psql`/
`pg_isready` call in the workflow assumed the default 5432 with no `-p`.
Fixed by reading back the real port with `pg_lsclusters` right after the
restart and threading it through explicitly (`-p "$PGPORT"`) to the
`pg_isready` wait loop and every `psql` invocation in the next step,
passed through `$GITHUB_ENV` between steps and interpolated into each
command line rather than relied on as environment `sudo -u postgres`
would inherit (it does not, reliably). A no-op for 16, where the port
happens to already be 5432.

Both fixes verified by reasoning about the actual observed state (job
logs, PostgreSQL's own log lines) rather than assumption at each step, but
neither has yet been confirmed green end-to-end on GitHub's infrastructure
as of this writing — the same "added" vs. "verified" distinction item 3
already draws for the rest of this CI matrix.

## 22. A third review round: fresh-install ownership gap, a name-only migration check, and two smaller fixes

A third-round review of items 19-21 found the CI port fix (item 21) real
and working, then named three merge blockers and two smaller issues, all
now fixed and verified live (fresh install, a real 0.2.0 → 0.3.0 upgrade
seeded with real data, `fn_selftest`/`tests/smoke.sql`/`tests/e2e_mock.sql`
on both, and a deliberate negative test) — the same "confirmed against the
real database, not the review's own wording" standard as items 18-21.

- **The ownership-transfer pass never covered five objects on a fresh
  install.** Item 20's fix ran once, in "12. Grants" — but
  `allgres.create_agent`/`create_session`/`pump`/`assume_worker_role`/
  `dashboard_rpc` and the `allgres.agents`/`tasks`/`projects` views are all
  defined later, in "13.", which runs *after* that pass. On a fresh
  install (the only place this shows: an upgrade's own objects already
  existed, under whatever owner that install's history left them, before
  this file's ownership pass ever touched them) those five functions and
  three views stayed owned by whichever superuser ran `CREATE EXTENSION`
  — `allgres_owner` existed and owned almost everything, but not quite
  everything a real security boundary needs it to. Confirmed live before
  fixing: a fresh install, cluster fully cleaned of every Allgres role
  first (leftover roles from earlier test runs can mask exactly this kind
  of gap — see item 19's own account of the same trap), left those five
  functions owned by `postgres`.

  Fixed with a second pass, "14. Final ownership pass," identical logic to
  item 20's — reused, not hand-duplicated — run again after every object
  in the file, section 13 included, actually exists. Also tightened while
  here, per the same review: both passes now scope to actual `pg_depend`
  members of the `allgres` extension (`deptype = 'e'`) instead of
  "everything currently sitting in these three schema namespaces," so an
  unrelated object a user happened to create inside
  `allgres_private`/`allgres_public`/`allgres` is left alone rather than
  silently annexed. Verified live: a completely clean fresh install now
  shows every extension-member function and view in all three schemas
  owned by `allgres_owner` (or `allgres_role_admin` for
  `fn_provision_agent_role` alone) with zero exceptions — checked by
  query, not by re-reading the file — and the same check on a real
  0.2.0 → 0.3.0 upgrade (seeded with a real agent first) comes back
  equally clean. `fn_selftest` 78/78 and `tests/smoke.sql`/
  `tests/e2e_mock.sql` both green on both paths.

- **The rename migration's genuineness check was still just a name-shaped
  guess.** Item 19 added a check that `argo_private` has an `agents`
  table (and `argo_public` an `fn_selftest` function) before trusting it
  as a real prior Allgres install — real hardening over the original
  unconditional rename, but a review round pointed out it is still not
  proof: an unrelated schema that happens to be named `argo_private` and
  happens to contain a table named `agents` would pass exactly the same
  way. The actually reliable signal was already sitting in `pg_depend`:
  `CREATE EXTENSION` (and `ALTER EXTENSION UPDATE`, which keeps the same
  `pg_extension` row across a version bump) automatically records every
  object it creates as a member of that extension the moment it creates
  it — a schema this file itself created, in any prior version, is
  therefore always a real `pg_depend` member of the `allgres` extension
  specifically, which no coincidentally-named unrelated schema could ever
  be regardless of what tables happen to live in it.

  Fixed by making extension membership the primary check, ahead of the
  existing object-existence check (kept as a secondary sanity assertion —
  a genuine but somehow-corrupted old install should still fail with a
  clearer message than a bare "not an extension member" would give).
  Reproduced and confirmed live exactly the way the review posed it:
  created a schema named `argo_private` with its own unrelated `agents`
  table, *not* created by the `allgres` extension, then ran
  `CREATE EXTENSION allgres;` — it refused with `schema "argo_private"
  exists but is not a member of the "allgres" extension`, rather than
  silently renaming an unrelated schema out from under whatever was using
  it. Roles are unaffected by this change: `argo_owner` is cluster-global,
  not owned by any one database's extension, so `pg_depend` membership
  does not apply to it the way it does to a schema — it keeps the existing
  "only rename once at least one schema was independently confirmed
  genuine" rule, which does not have the same coincidence problem a role
  named `argo_owner` alone would.

  The review's alternative suggestion — move the rename logic into a
  dedicated 0.2.0→0.3.0-only upgrade script, checked against
  `pg_extension.extversion` — does not fit how this project's upgrades
  actually work: `sql/control_plane.sql` is a single idempotent file
  replayed as both the fresh-install body and the entire content of every
  generated upgrade script (`scripts/gen-upgrade.sh`), guarded throughout
  with `IF NOT EXISTS`/`CREATE OR REPLACE`/explicit drops rather than
  split into separate from-version-specific files. Splitting one block out
  into a different mechanism the rest of the file doesn't use would be a
  bigger, differently-shaped change than the gap it closes; the
  `pg_depend` fix above closes the same gap the review actually cared
  about (a name collision fooling the check) without it.

- **The dashboard's `overview` action reported a hardcoded, stale
  version.** `'version', '0.2.0'` was a string literal, never updated when
  the crate moved to 0.3.0 — confirmed live: the RPC returned `"0.2.0"`
  against an actual 0.3.0 install. Fixed to call
  `allgres.native_version()`, which already existed (returns
  `CARGO_PKG_VERSION` at compile time) and was already used for exactly
  this elsewhere, just never wired into this one call site. Confirmed
  live: now returns `"0.3.0"`.

- **`scripts/backup_drill.sh`'s `SCRATCH` validation was still too wide.**
  Item 21 added a check requiring `SCRATCH` to be under
  `/var/lib/postgresql/` before `rm -rf`-ing it — real hardening against
  an empty or wildly wrong override, but a review round pointed out that
  pattern still admits `/var/lib/postgresql/16/main`, a real cluster's own
  data directory, since the whole point of that path prefix is that every
  real cluster lives under it too. Fixed three ways: the default `SCRATCH`
  is now `/var/lib/postgresql/allgres-backup-drill` (a name specific to
  this script, not a generic subdirectory of the tree every cluster
  shares); the prefix check is narrowed to match that name specifically;
  and the value is run through `realpath -m` before the check, so neither
  a relative path nor a `..` component can walk it out of the directory
  the check just approved. A marker file
  (`.allgres_backup_drill_marker`), written once a run's own `SCRATCH`
  directory is created and checked for on every subsequent run before any
  `rm -rf`, is defense in depth beyond the path check alone. Confirmed
  live: `SCRATCH=/var/lib/postgresql/16/main` and a `..`-traversal variant
  of the same path are both now refused before touching anything, the
  live cluster answers a query unaffected either time, and a full drill
  run with the new default `SCRATCH` still passes both phases end to end.

None of the five were architectural — same pattern as items 12 and 18:
each fix is local to the function or block that had the gap. Also
verified once more, across all of it: `fn_selftest` 78/78,
`tests/smoke.sql`/`tests/e2e_mock.sql` green on a fresh install and on a
real 0.2.0 → 0.3.0 upgrade seeded with a real agent beforehand, and
`scripts/backup_drill.sh` green end to end.

## 23. Two more external reviews: a silent LLM provider fallback, unbounded delegation, and a real leftover "ARGO" name

Two independent full-repository reviews of 0.3.0 (one broad architectural
pass, one security-focused) named two P0s in agent behavior — not
infrastructure this time, the actual state machine — plus a genuine
leftover of the retired project name that item 19's rename swept missed
because it lived in seed *data*, not an identifier. All three confirmed
against the real code before fixing, then re-verified live: fresh install,
a real 0.2.0 → 0.3.0 upgrade seeded beforehand, `fn_selftest` (83/83, five
new cases), `tests/smoke.sql`/`tests/e2e_mock.sql`, and the dashboard_rpc
round trip for the two new operator-configurable fields this added.

- **`build_llm_http` silently rerouted a prompt to a different LLM
  provider.** If an agent's (or operator's) configured `llm_config.provider`
  didn't resolve to an enabled row — disabled, mistyped, never
  configured — the function fell back to whichever *other* enabled
  provider sorted first by name, with no error and no log entry
  distinguishing "sent where configured" from "sent wherever was first
  alphabetically." Confirmed by reading the function: this was not a
  defensive fallback for "no provider at all" (that case already raised);
  it specifically covered "the requested one doesn't exist or is
  disabled" by substituting a different one. An operator who disables a
  provider, or an agent whose `llm_config.provider` has a typo, could have
  every subsequent prompt silently sent to a completely different LLM
  vendor — a real privacy/security issue, not a convenience. Fixed by
  removing the substitution entirely: an unresolvable provider now raises
  `llm provider "%" is not configured or not enabled -- refusing to
  silently substitute a different provider`, which `fn_dispatch_tasks`'s
  existing exception handling already turned into a task-level error (the
  same plumbing the old "no enabled llm provider" case already used) — no
  new error path needed, just removing the one that quietly avoided it.
  There is no configurable explicit fallback (a `fallback_provider_id` or
  similar) added here; if cross-provider fallback is ever wanted, it needs
  to be a real, named, operator-opted-in policy, not a default. Selftest:
  `llm_provider_fails_closed_not_substituted` (calls `build_llm_http`
  directly with an unconfigured provider name, asserts it raises rather
  than returning a substituted provider's spec).

- **`delegate` had no resource bound of its own at all.** A child task
  created by `delegate` got its own fresh `max_steps`/`max_retries`/
  `max_turn_seconds` budget, gated only by `max_concurrent_tasks` (how
  many tasks may run *at once*, not how many a chain may ever create).
  With mutual delegate permissions granted between two agents — a
  legitimate, operator-granted setup for real collaboration, not a
  misconfiguration — nothing stopped an unbounded `A -> B -> A -> B -> ...`
  chain. Fixed with three independent checks in `fn_submit_result`'s
  `delegate` branch, none of which alone would have been enough:
  - `tasks.delegation_depth` (new column; 0 for a root task, always
    `parent.delegation_depth + 1` for a delegate child) checked against a
    new operator-configurable `policies.max_delegation_depth` (default 5,
    same envelope-field pattern and `propose_change` exclusion as
    `max_concurrent_tasks`/`max_turn_seconds` — see item above and
    `fn_submit_result`'s `propose_change` handling for the allow-list this
    was added to *not* be part of).
  - An ancestor-cycle check: a chain that keeps revisiting the same two
    agents can stay well within a generous depth cap forever, so a
    recursive CTE walks the current task's own `parent_task_id` chain (the
    task itself included as the base case) and refuses to delegate to any
    agent already in it, regardless of depth headroom.
  - A new `policies.max_session_tasks` (default 100) caps a session's
    total task count outright — the guard a long, *never-repeating* chain
    (`A -> B -> C -> D -> ...`) cannot evade, since it revisits no agent
    and can stay under any reasonable depth cap.
  All three are checked in the delegating task's own agent's policy, so
  the strictest agent to actually attempt a delegate hop in a chain is the
  one whose caps apply at that hop — a defense-in-depth choice, not a
  precise global invariant, but the actual security property (nothing
  unbounded) holds regardless of which agent's policy happened to be
  consulted. `fn_set_policy` gained two parameters (`p_max_delegation_depth`,
  `p_max_session_tasks`), threaded through `policy_history`,
  `fn_rollback_policy`, and `dashboard_rpc`'s `agents.list`/`agents.update`/
  `policy.history` exactly like `max_concurrent_tasks`/`max_turn_seconds`
  already were; the web UI's agent editor and policy-history view gained
  matching fields. Since `fn_set_policy`'s signature grew (8 args to 10),
  the file's own established rule for this applies — `CREATE OR REPLACE
  FUNCTION` does not replace a shorter-signature function, it creates a
  second overload, which an upgrade would otherwise leave installed
  alongside the new one — so the previous 8-arg signature gets its own
  explicit `DROP FUNCTION IF EXISTS`, confirmed live on a real 0.2.0 →
  0.3.0 upgrade: exactly one `fn_set_policy` overload (the new 10-arg one)
  exists afterward. Selftest: `delegate_depth_exceeded_rejected`,
  `delegate_cycle_rejected`, `delegate_session_task_limit_rejected` (each
  built by placing a task directly at the boundary being tested — an
  already-at-cap depth, an ancestor chain, a session already at its task
  cap — rather than driving a real chain hop by hop, since only the
  enforcement at the final hop is under test), and
  `delegate_succeeds_within_budget` (a legitimate delegate inside every
  budget still succeeds, and the child's `delegation_depth` is set
  correctly for a later hop's own check). `delegate` previously had *no*
  `fn_selftest` coverage at all — KNOWN_ISSUES item 6 named this
  explicitly ("child task creation is covered by unit-level assertions
  only").

- **A real "ARGO" leftover, in seed data rather than an identifier.**
  Item 19's rename swept every internal schema/role/GUC name, but the
  default seed agent (`analyst`)'s own `system_prompt` — real,
  user-visible product content, not an internal identifier — still read
  literally "You are ARGO analyst." on a fresh install. Confirmed by
  grep, fixed to "You are the Allgres analyst." This is create-only seed
  data (see "10. Seed data"'s own header comment: replaying this file
  must not clobber an operator's edited prompt), so an *existing* install
  that already seeded the old prompt keeps it — this only changes what a
  fresh install (or a restore onto one) gets from here on, the same
  forward-only shape as the fixed provider ids in item 18.
