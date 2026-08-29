# Known issues and future work

Status as of 0.2.0. Verified natively on PostgreSQL 16.15 with pgrx 0.19.2
(Docker/PG17, this environment's actual deployment target, could not be
reached to verify against — see item 3): `fn_selftest` 66/66, `tests/smoke.sql`
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
