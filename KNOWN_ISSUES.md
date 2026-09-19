# Known issues and future work

Status as of `0.1.0-alpha`, this project's actual first launch (see the
version-number note below and item 69). Verified natively on PostgreSQL
16.15 with pgrx 0.19.2: `fn_selftest` 332/332, `tests/smoke.sql` and
`tests/e2e_mock.sql` pass, and the full path browser → web worker → unix
socket → runtime SPI thread → PL/pgSQL works end to end over real HTTP
(`curl` against `/api/v1/rpc`, CSRF checks included). A physical
(`pg_basebackup`/PITR) and logical (`pg_dump`) backup/restore drill are
also verified — see item 18. Earlier builds were verified on PostgreSQL
17 and 18; nothing here is PG-version-specific (16, 17, and 18 are all
supported and CI-checked).

Everything below is either not implemented or not verified. Nothing here is
believed to be broken in a way that is currently exploitable, but each item is
a gap between what the code does and what it should do.

**A note on version numbers**: this project has never had an actual release.
`Cargo.toml`/`allgres.control` bumped through `0.2.0`–`0.5.0` during
development (each bump documented, at the time, in the item below it); none
of those were ever published anywhere, so none of them are a real prior
version an operator could actually be running. The version has been reset to
`0.1.0` and its matching `sql/allgres--<from>--<to>.sql` upgrade scripts for
those never-shipped versions removed. Item 69 goes one step further: the
`sql/allgres--0.2.0.sql` frozen pre-rename (Argo-named) snapshot item 19
describes, the `ALTER ROLE`/`SCHEMA ... RENAME` migration path built for it,
and `scripts/gen-upgrade.sh` itself are all removed too — none of it ever
had a real install to protect, so it was carried weight with no real target.
`0.1.0-alpha` is this project's actual first launch; the version number will
move again only to mark a real subsequent release. Every item below keeps
whatever version number was live in the codebase at the time it was
written — read them as a dated development diary, not as claims about the
current version, and read items 4, 18, and 19's own upgrade-path/rename
content as superseded by item 69.

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

## 3. ~~Docker image path is unverified in this environment~~ — fixed, now green in CI

Written when the build had only been verified natively (no Docker daemon
reachable in that environment) and `docker-smoke`/`native-matrix` had just
been added to `.github/workflows/ci.yml` but had not yet actually run on
GitHub's infrastructure — "added to CI" is not the same claim as "verified
there." It has since run, repeatedly: `docker-smoke` (`docker compose build
+ smoke`, plus the full install flow — first admin, one real agent task to
completion) and `native-matrix` (`fn_selftest`/`tests/smoke.sql`/
`tests/e2e_mock.sql` against real PG16/17/18 native installs) are both green
on every push to `main`, this one included.

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

- ~~the OAuth flow~~ — fixed, see item 24: the token exchange HTTP call is
  now actually performed, by the runtime worker, and covered by both
  `fn_selftest` and a real `tests/e2e_mock.sql` round trip.
- ~~the `delegate` action end to end~~ — fixed by item 23: `delegate_depth_
  exceeded_rejected`, `delegate_cycle_rejected`, `delegate_session_task_
  limit_rejected`, and `delegate_succeeds_within_budget` now cover it in
  `fn_selftest`.
- ~~`fn_watchdog` reclaiming a genuinely stuck **in-flight** call~~ — fixed,
  see item 26: `scripts/fault_injection_drill.sh` actually kills the real
  worker mid-call, for both `outbound_calls` and `sql_calls`, and proves the
  real, unattended recovery cycle, not a synthetic 'lost' row.

`await_human` / `fn_decide_approval` themselves are no longer on this list —
see item 10. Neither is task/session cancellation, permission and allowlist
management, or per-agent concurrency/wall-clock limits — see item 11.

## 7. ~~Secret key rotation~~ — fixed

Changing `allgres.secret_key` used to make every existing `enc:v1:` value
undecryptable; `decrypt_secret` returned NULL and the provider silently
lost its credential, with re-entering every secret by hand as the only
recovery. Fixed much later (prompted by an outside production-readiness
review) -- see item 42.

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

- the 24h approval expiry is a hardcoded default, not configurable per call
  or per agent -- still true;
- ~~neither `fn_decide_approval` nor `projects.*` records *who* decided or
  created something -- there is no per-operator identity anywhere in the
  system (the dashboard has one shared token, not accounts), so "who
  approved this" is unanswerable by design, not by oversight.~~ Closed,
  once the accounts system this item predates actually existed: see the
  follow-up below.

**Follow-up (much later, prompted by an outside production-readiness
review): "who approved this" is answerable now.** `allgres_private.
audit_log` gained `user_id`/`username`, resolved from `session_token` by
`dashboard_rpc` itself (`allgres_private.session_user`, the same
resolution every admin-gated action already used) and stamped alongside
`operator_name` rather than replacing it -- a row can carry a verified
`username` and a completely different self-reported `operator_name` at
once, and the two are shown separately in the dashboard's Audit Log page.
Deliberately no FK from `audit_log.user_id` to `users`: `audit_log` is
append-only (a trigger enforces it even against the table's own owner),
and an `ON DELETE SET NULL` -- the obvious first instinct -- is itself an
`UPDATE`, which that exact trigger would reject the moment a referenced
user account was ever deleted; caught by `fn_selftest`'s own fixture
cleanup the first time this was tried, before it ever became a production
issue. This closes the gap for every audited mutation uniformly
(`fn_decide_approval`, `projects.*`, and everything else that already
calls `allgres_private.audit`) without touching any of those functions
individually -- the identity now flows through the one place they all
already record to. One new selftest case
(`audit_log_records_real_logged_in_user_id`, 317 up from 316); verified
live over real HTTP too, not only via `fn_selftest`: logged in as a real
account, made a call with a *different* self-reported `operator_name`, and
confirmed the resulting row carried the account's own `user_id`/`username`
rather than the self-reported name. Verified on both a fresh
`CREATE EXTENSION` and a rerun in the same database; `cargo test --lib`'s
30 cases unaffected (SQL-only change).

Still not done, and not part of this fix: `human_approvals`/
`change_proposals` rows themselves still carry no `decided_by`/
`created_by` column of their own -- the answer lives in `audit_log`, a
separate table, not on the row it's about. Fine for "who approved this,"
read as a question about the event; a real column would be needed to
answer it as a property of the approval/proposal row itself (e.g. to
`JOIN` and filter approvals by decider directly, without going through
`audit_log`'s own text-matching on `action`/`details`).

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
  status). ~~What's still true and not fixed here: an *already in-flight*
  HTTP request or an *already executing* sandboxed query cannot be
  interrupted mid-flight~~ — fixed, see item 39: both now abort within
  roughly 50-80ms of `fn_cancel_session`, live-verified, worker survival
  included.

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

  Done in item 24, exactly on that template: `fn_oauth_token_request` no
  longer returns anything secret, so the explicit revoke-from-operator this
  bullet describes is gone too — `fn_oauth_start`/`fn_oauth_token_request`
  are back under the ordinary blanket grant, the same as
  `fn_claim_outbound`/`fn_complete_outbound` always were despite handling
  the LLM credential internally (ownership, not the caller's grants, is
  what actually runs their body — ibid.). `fn_oauth_store_tokens` itself is
  gone outright rather than merely re-revoked.
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

## 24. OAuth token exchange, actually performed, queued the way item 13 already fixed the same leak once

Item 6 named this from the start: OAuth had three functions
(`fn_oauth_start`, `fn_oauth_token_request`, `fn_oauth_store_tokens`) and no
code path that ever performed the token exchange HTTP call. Item 20 found
`fn_oauth_token_request` was also actively unsafe the moment anything called
it: it decrypted the provider's `oauth_client_secret` and returned the built
request straight to its caller, which the blanket
`GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA allgres_public TO operator` (see
item 20's own account) would have handed to `operator` the instant a
dashboard action reached it. Both gaps are closed together, since finishing
the feature and fixing the leak turned out to be the same change.

**What was built**: a new queue, `allgres_private.oauth_calls`, shaped
exactly like `outbound_calls`/`sql_calls` (`queued -> in_flight ->
harvested/lost`) but with no `task_id` — connecting a provider is an
operator dashboard action, not an agent turn, so there is no task to route a
result back into. `fn_oauth_token_request` now only builds the exchange
request and queues it, without ever touching `oauth_client_secret`; a new
`fn_claim_oauth` (worker-only) resolves the secret and merges it into the
request body it hands back over the RPC socket — never written to
`oauth_calls.request_body` — the identical claim-time-only shape
`fn_claim_outbound` already uses for an LLM provider's `api_key` (item 13).
A new `fn_complete_oauth` (worker-only) parses the token endpoint's
response, stores `access_token`/`refresh_token` encrypted into
`llm_secrets`, and fences a belated result the same way
`fn_complete_outbound`/`fn_complete_sql` already do (a row only completes
from `in_flight`; a watchdog-reclaimed `lost` row's result is discarded, not
recorded). `fn_watchdog` gained a fourth reclaim loop, for `oauth_calls`
stuck `in_flight` past a worker crash between claim and complete — the
same technique item 6 already named as owed for the two `outbound_calls`/
`sql_calls` loops, applied here from the start rather than added later.

`fn_oauth_store_tokens` is not merely re-revoked from `operator` the way
item 20 left it — it is gone. Its storage logic moved inside
`fn_complete_oauth`, and nothing outside the runtime worker ever needs to
call it, so there is no public entry point left to leak through in the
first place. `fn_oauth_start`/`fn_oauth_token_request` are back under the
ordinary blanket grant to `operator`, safely now: both return only a
redirect URL / a queued `call_id`, nothing secret, the same reasoning that
already lets `fn_claim_outbound`/`fn_complete_outbound` sit under that same
blanket grant despite resolving a real credential internally — ownership,
not the caller's own grants, is what actually runs a `SECURITY DEFINER`
function's body.

On the Rust side, `perform_http` gained a third branch alongside its
existing `tool` (GET) and `llm` (JSON POST) ones: `oauth` sends a standard
`application/x-www-form-urlencoded` submission (`ureq`'s `send_form`, RFC
6749 4.1.3 — a token endpoint does not speak JSON on the request side, only
the response). OAuth jobs run on the same HTTP thread pool as every other
outbound call, tagged with which queue they came from
(`OutboundQueue::Outbound`/`::Oauth`) so the harvest step in the main loop
routes each result to `fn_complete_outbound` or `fn_complete_oauth`
correctly — the two queues share infrastructure but are otherwise unrelated
tables with unrelated completion semantics.

Reachable from the dashboard: a `kind='oauth'` provider's editor in
Settings gained Authorization URL / Token URL / Client ID / Client secret
fields and a "Connect via OAuth" button (`providers.oauth_start`, a new
`dashboard_rpc` action alongside `providers.oauth_callback`), which does a
real full-page redirect to the provider's login screen; the provider's own
redirect back to the dashboard's URL (`?code=&state=`) is picked up by a
boot-time handler that completes the flow (`providers.oauth_callback`) and
returns to Settings. Neither RPC action, nor the redirect itself, ever
carries a secret — the callback's own return value is `{ok, queued,
call_id, provider_id}`.

**Verified live**, the same standard as items 12–23: rebuilt against local
PostgreSQL 16.15 (rustc 1.98, since pgrx 0.19.2 needs rustc ≥1.96 — this
session's toolchain started at 1.94 and had to be updated first),
`fn_selftest` 88/88 (five new cases: queuing never touches the secret table
and the return value contains no trace of it; claiming injects the secret
only into the response, never back into the row; a stale completion is
discarded, not stored; a successful exchange stores both tokens encrypted;
a response missing `access_token` is recorded as an error rather than
silently doing nothing), `tests/smoke.sql`, and a new section in
`tests/e2e_mock.sql` that adds a mock OAuth token endpoint
(`/mock/oauth/token`, gated by `ALLGRES_ENABLE_MOCK` exactly like the
existing `/mock/chat/completions`) and drives the real background worker
through it end to end: `fn_claim_oauth` → `perform_http`'s `send_form`
branch → the mock endpoint (which itself refuses the exchange unless the
real client secret arrived, and echoes the exchanged code back into the
access token, so a correct token landing in `llm_secrets` proves both the
code and the claim-time-injected secret actually made it over the wire) →
`fn_complete_oauth` → `llm_secrets`, decrypted and checked, then every
column of `oauth_calls` searched for the secret and both tokens (zero
matches) — the same "search every column" proof item 13 used live for the
identical class of leak. Also driven through the real HTTP path, not just
SQL: `curl` against `/api/v1/rpc` for `providers.oauth_start` and
`providers.oauth_callback`, and a headless-browser (Playwright/Chromium)
screenshot of the Settings provider editor confirming the new fields and
the Connect button render and the "connected" status reflects a stored
token. A real `ALTER EXTENSION allgres UPDATE TO '0.3.0'` from a real
0.2.0 install (seeded with an agent beforehand, on a cluster with every
`allgres_*`/`argo_*` role and schema removed first — see item 19's own
account of the leftover-role trap this exact check has fallen into
before) confirms `oauth_calls` exists post-upgrade, `fn_oauth_store_tokens`
does not, and `fn_selftest` stays 88/88. `scripts/backup_drill.sh` (item
18) re-run end to end, both the physical (PITR) and logical (`pg_dump`)
paths, confirms the new `pg_extension_config_dump` registration for
`oauth_calls` doesn't break either.

`oauth_calls` is registered for `pg_extension_config_dump`, unconditionally,
the same as `outbound_calls`/`sql_calls` — unlike `oauth_states` (still
deliberately excluded: short-lived, in-progress flow state) it is a real
audit trail worth keeping, and unlike `llm_secrets` it never holds a
plaintext secret or token to begin with: there is no `response_body` column
on it at all, only a status code and, on failure, the provider's own error
text.

~~**Deliberately not built**: token *refresh* — an expired `access_token`
has to be reconnected from Settings by hand; nothing calls a provider's
`refresh_token` grant automatically~~ -- no longer true and this paragraph
went stale without anyone coming back to fix it: `allgres_private.
queue_oauth_maintenance` (called from the same `fn_pump` polling loop as
everything else in this item) queues a `refresh_token` grant on its own
once `llm_secrets.expires_at` is within two minutes, using exactly the
`expires_at` this paragraph originally said was "recorded and available
for that later." Caught by an outside readiness review of the whole project that checked
this specific claim against the actual code rather than trusting this
file; see README's "Known limitations" for the matching fix there.

`oauth_scope` has no operator setter
(`fn_set_provider` never gained one) — it can only be seeded directly,
same limitation the schema already had before this pass, just not removed
by it either. No confirmation dialog before "Connect via OAuth" navigates
away from the dashboard, beyond the browser's own — same caveat items 11
and 17 already name for `sessions.cancel` and a proposal rollback. No
per-operator identity attached to who connected a provider, for the reason
item 10 gives throughout: no accounts system yet.

## 25. Long-term agent memory, slice one

Before this pass, Allgres had no cross-session memory at all: `execution_logs`
is the verbatim, append-only transcript of one task, replayed into that
task's own next `call_llm`, and nothing else. An agent that learned
something in session 1 had no way to carry it into session 2 — a real gap
for anything meant to act like a *personal* agent rather than a one-shot
tool. This is a first, deliberately narrow slice, the same framing item 15
used for per-agent PostgreSQL roles: does the core mechanism — an agent
writing something durable, and getting it back automatically on a later
turn — work at all, end to end, verified live, before building retrieval
ranking, embeddings, or a curation UI on top of it.

**What was built**: a new table, `allgres_private.agent_memories`
(`memory_id`, `agent_id`, `subject_id`, `memory_type` — `semantic`/
`episodic`/`preference`/`instruction`/`relationship`/`working` —, `content`,
`importance`, `confidence`, `source_session_id`/`source_task_id`,
`created_at`, `last_accessed_at`, `expires_at`, `metadata`), and a new agent
action, `remember`, alongside `final_answer`/`execute_sql`/`call_tool`/
`delegate`/`await_human`/`propose_change`. Unlike `execute_sql`/`call_tool`
this needed no queue: it never leaves PostgreSQL, so `fn_submit_result`
writes the row synchronously, the same shape `propose_change`'s own `INSERT`
already uses. It also needed no resource-permission check the way
`execute_sql` (a view) or `delegate` (a target agent) do — an agent can only
ever write to its own memory, which cannot expand its privileges or touch
anything another agent owns, the same reasoning `await_human`/
`propose_change` already skip a permission grant for.

`fn_next_step` reads a bounded set of that agent's own memories back on
every turn — live ones only (`expires_at IS NULL OR expires_at > now()`),
ranked by importance then recency, capped at 15 rows and 500 characters
each — into a new `# memory` block in the same system message that already
carries the policy prompt and the view/tool bounds. `last_accessed_at` is
touched for exactly the rows actually recalled, not on write, so it reflects
"last time this reached a prompt," not "last time it was mentioned." Recall
is strictly scoped to `agent_id`, with no cross-agent read at all — verified
live (below), not just asserted.

Both the agent's own write path (`fn_submit_result`'s `remember` handler)
and a new operator-authored one (`fn_remember`/`fn_forget`, exposed as
`dashboard_rpc`'s `memories.create`/`memories.remove`, and a new Memories
dashboard page) share one private function, `allgres_private.write_memory`
— same validation, same fixed eviction, same insert, so the two paths
cannot drift. It returns `{ok:false, error:...}` rather than raising,
since the two callers handle a rejected write differently (one logs an
`'error'`-role turn and continues the task; the other just reports failure
to the dashboard).

A fixed cap, 500 rows per agent, evicts the least important — then oldest —
memories past that count on every write, rather than let the table (and
every future prompt's memory block) grow without bound; this is a constant
in `write_memory`, not an operator-configurable policy field, the same kind
of deliberate simplification item 24 made for the OAuth queue's claim
limit. `fn_watchdog` gained a fifth loop that garbage-collects any row past
its `expires_in_days` — not a correctness fix (an expired row is already
excluded from `fn_next_step`'s own recall query regardless of whether it
has been swept), just hygiene, the same self-healing shape every other
`fn_watchdog` loop already has.

**A real bug caught while writing the test for it, before it shipped**: the
first version of the 500-row eviction query ordered
`importance ASC, created_at ASC` and deleted everything past
`OFFSET 500` — which skips the 500 *least* important rows and deletes
whatever comes after them in that ascending order, i.e. the *most*
important ones. Exactly backwards: it would have evicted an agent's most
valuable memories and kept the least valuable 500. Caught by writing
`memory_cap_evicts_least_important` (insert one low-importance marker, 499
filler rows, one high-importance marker, assert the low one is gone and the
high one survives) before assuming the query was correct — the same
standing question item 12 already named ("does the test check the write, or
the read?") applied here to the query's own direction, not just whether it
ran. Fixed by ordering `DESC` instead, so the OFFSET skips the *keepers*.

**Verified live**, the same standard as items 12–24: rebuilt against local
PostgreSQL 16.15, `fn_selftest` 94/94 (six new cases: malformed `remember`
input — empty content, an unknown `memory_type` — is rejected without
failing the task or writing a row; a well-formed `remember` writes a row
*and* is recalled, verbatim, into a separate later task's own
`fn_next_step` output, not just present in the table;
`selftest_delegate_b`'s own `fn_next_step` never sees
`selftest_delegate_a`'s memory; the 500-cap eviction test described above;
`fn_watchdog` sweeping an expired row and reporting it in
`memories_expired`; and `fn_remember`/`fn_forget` round-tripping a
write and delete with no `source_session_id`/`source_task_id`, the
operator-authored path). `tests/smoke.sql` and `tests/e2e_mock.sql` both
still green (this slice touches no Rust code and no outbound path, so
neither needed a new section). Also checked directly against a live
session, not just `fn_selftest`'s own calls: `memories.create` over a real
`curl` against `/api/v1/rpc`, a fresh `fn_next_step` call for that same
agent confirmed to contain the exact memory content, `memories.remove` over
the same route, and a headless-browser (Playwright/Chromium) round trip
through the new Memories page (fill the form, Save, see the row; click
Forget, see the empty state) with the underlying table checked directly
before and after. A real `ALTER EXTENSION allgres UPDATE TO '0.3.0'` from a
real 0.2.0 install (seeded with an agent beforehand, on a fully cleaned
cluster — see item 19's own account of the leftover-role trap this check
keeps falling into) confirms `agent_memories`, `fn_remember`, and
`fn_forget` all exist post-upgrade and `fn_selftest` stays 94/94.
`scripts/backup_drill.sh` (item 18) re-run end to end, both the physical
(PITR) and logical (`pg_dump`) paths, confirms the new
`pg_extension_config_dump` registration for `agent_memories` doesn't break
either.

`agent_memories` is registered for `pg_extension_config_dump`,
unconditionally — real agent/operator state worth keeping, the same
treatment `execution_logs`/`sessions`/`tasks` already get.

**Deliberately not built**, the same "narrow slice, revisit later" shape
item 15 used: semantic (embedding/vector) search — recall is
importance/recency ranking over structured rows only, no `pgvector`
dependency added; an explicit `recall` action for an agent to query beyond
what `fn_next_step` already injects automatically; row-level security on
`agent_memories` (gated by `write_memory`'s own `agent_id` parameter and
`fn_next_step`'s own `WHERE agent_id = ...`, the same `SECURITY DEFINER`
pattern nearly every other table in this project uses — `v_sales`/
`v_my_tasks` remain the one place real Postgres RLS is used, per item 15);
an operator-configurable per-agent memory cap (the 500-row limit is a fixed
constant); a confirmation step before an operator's "Forget" deletes a
memory, beyond the browser's own, the same caveat item 11 already names for
`sessions.cancel`; and no identity for *who* (operator or agent) is telling
the truth about a `subject_id` — it is free text an agent or operator
chooses to write, not tied to any real accounts system, because there isn't
one yet (item 10).

## 26. A genuine fault-injection drill: killing the real worker mid-call, not simulating it

Item 6 named this from the start and every pass since kept deferring it:
`fn_watchdog` reclaiming a call stuck `in_flight` because the runtime worker
crashed between claim and complete had selftest coverage only in the
*synthetic* sense — `complete_sql_fences_stale_result`/
`complete_outbound_fences_stale_result` and the pair added for OAuth (item
24) all prove the fencing logic is correct by `UPDATE ...SET status =
'lost'` and then calling the complete function directly. That proves the
*state machine* is correct. It proves nothing about whether a real crash of
the real worker process, at the real point where it is genuinely blocked on
a genuinely long-running call, actually gets noticed and recovered from by
the real, periodic `fn_watchdog` pass running unattended in a process that
had to restart itself first. Those are different claims, and only one of
them had ever been checked live.

**What this is**: `scripts/fault_injection_drill.sh`, a new runnable,
re-runnable drill in the same family as `scripts/backup_drill.sh` (item
18) — not a `fn_selftest` case, because what it tests cannot be expressed
as one: it needs a real OS-level `kill -9` against a real backend PID,
which no SQL function can do to itself. Two phases, one for each queue item
6 named:

- **Phase 1, `sql_calls`.** A real agent, a real session, a real
  `execute_sql` action (`SELECT count(*) FROM generate_series(1,
  200000000) g` — an allowlisted, legitimately slow query, not
  `pg_sleep()`, which the sandbox denies) submitted through
  `fn_submit_result` exactly as the runtime worker would after a real LLM
  turn. The drill polls until the real worker's real `pump_sql()` claims it
  (`sql_calls.status = 'in_flight'`), reads the real worker's PID out of
  `pg_stat_activity` (`backend_type = 'allgres runtime'`), and sends it a
  real `SIGKILL` while the query is genuinely executing on that worker's
  SPI thread.
- **Phase 2, `outbound_calls`.** The same shape, for a real LLM/HTTP call
  instead: a new mock endpoint, `/mock/slow/chat/completions` (`src/lib.rs`,
  gated by `ALLGRES_ENABLE_MOCK` exactly like the existing
  `/mock/chat/completions`), sleeps 15 seconds — comfortably under
  `HTTP_TIMEOUT` (45s) — before replying, giving a real window in which a
  real `outbound_calls` row is genuinely `in_flight` on a real HTTP pool
  thread inside the worker process. Same kill, same recovery check.

**What killing the worker actually does, confirmed live, not assumed**:
PostgreSQL treats an unexpected exit of *any* backend attached to shared
memory — a background worker with `enable_spi_access()` (`src/lib.rs`)
included — exactly like any other backend crash: it tears down every other
connection and replays crash recovery for the whole instance. This is
standard PostgreSQL behavior, not something specific to Allgres or this
drill, and the drill's own header says so explicitly: it kills and restarts
the *entire* instance it is pointed at, on purpose, and must never be run
against a cluster serving real traffic. The `allgres runtime` worker
relaunches itself once recovery finishes, with no operator action, via the
`set_restart_time` already configured in its `BackgroundWorkerBuilder`
(`src/lib.rs`) — nothing new added for this drill, just verified live for
the first time.

After the kill, the drill:

1. confirms the log actually shows a crash (`terminated by signal` /
   `crash of another server process`) followed by `database system is
   ready to accept connections` — refusing to pass if recovery merely
   *looked* clean without an actual crash being logged;
2. confirms the row is still `in_flight` immediately after recovery — it
   was committed by `fn_claim_sql`/`fn_claim_outbound` in its own
   transaction *before* the slow call ever started running in a separate
   one, so a crash mid-call cannot roll the claim back;
3. waits — up to 130s, no shortened threshold — for the row to reach
   `'lost'` **on its own**, checking only what the real, restarted worker's
   own periodic `fn_watchdog` pass did, never calling `fn_watchdog`
   directly itself. The real threshold is `2 × HTTP_TIMEOUT` = 90s
   (`dispatch_and_claim`, `src/lib.rs`), not a drill-only fast path, so
   this genuinely waits as long as a real crash would before recovery
   starts;
4. confirms the timeout is visible in the task's own `execution_logs`, not
   silently swallowed;
5. then does **nothing further by hand** — no manual resubmission — and
   instead waits for the real, unattended `fn_dispatch_tasks` (also running
   inside the same real restarted worker) to redispatch the task on its own
   and reach `'completed'`.

**A real design mistake in the drill itself, caught by the drill failing on
its first live run**: the first version left the throwaway agent on its
seed default LLM provider. The moment `fn_watchdog` logged the timeout, the
real `fn_dispatch_tasks` — which advances *any* `'running'` task with
nothing pending, unconditionally, on its own schedule — immediately queued
a real LLM call against that real (unreachable, from here) provider, which
failed on a real TLS error twice and exhausted `max_retries` (2) before the
script's own polling loop ever got to check anything: `status='failed'`
where `'running'` was expected. Not a bug in `fn_watchdog` or the reclaim
path — both had already worked correctly by that point, confirmed by the
row correctly reaching `'lost'` — but a real gap in the drill's own design:
it had implicitly assumed the task would sit still between the reclaim and
whatever the script did next, when the real production pump loop never
sits still for anyone. Fixed by pointing the agent at the same mock
provider `tests/e2e_mock.sql` already uses (phase 1) and the new
`/mock/slow` one (phase 2) *before* the crash, so the automatic redispatch
that was always going to happen either way now succeeds instead of racing
a real network call to nowhere. This makes the drill prove the *whole* real
cycle — claim → crash → recovery → reclaim → automatic redispatch →
completion — rather than only the reclaim step in isolation, which was the
more valuable claim to prove regardless.

**Verified live, both phases, end to end, twice** (once before and once
after adding the `/mock/slow` endpoint required a rebuild): `cargo build`/
`cargo test` (30/30) clean, `fn_selftest` clean before and after each run,
`tests/smoke.sql`/`tests/e2e_mock.sql` unaffected. `scripts/
fault_injection_drill.sh` itself passing both phases is the primary
evidence — a `SIGKILL` against a live, genuinely-in-flight backend, a real
crash logged, real recovery, real unattended reclaim after the real
production timeout, and real unattended completion afterward, for both
queues item 6 named.

**Deliberately not covered**: `oauth_calls` (item 24) is not exercised by
this drill — its own reclaim loop is identical in shape to the two tested
here and was already added defensively when that item shipped, but a
genuine crash-mid-exchange test would need a real, unconsumed authorization
code to retry with, which a mock OAuth provider cannot supply after the
fact (the code is single-use by design, see item 24's own account of why
the state row is deleted at queue time, not completion time) — a real
retry after that kind of crash is a fresh operator-initiated "Connect"
click in production, not something this drill can simulate. Also not
covered: a crash of the `allgres web` worker (dashboard HTTP listener)
mid-request — that worker holds no durable claim a watchdog would need to
reclaim, so there is no analogous state to test recovery of; a dropped
in-flight dashboard request simply fails and the browser retries, which is
already how any ordinary HTTP client behaves against any server restart.

## 27. Maintenance/auditor agents, slice one: two diagnostic views and a read-only seeded agent

A second-round review's proposal (the same one this file's later items have
been working through) argued for a layer of system-facing agents above the
user-facing ones — a health agent, a security/policy auditor, a memory
curator, a performance advisor — each reading operational state and either
reporting a finding or, for anything that needs to actually change, routing
through a proposal an operator decides, never mutating directly. This is a
first, deliberately narrow slice of that, the same framing items 15 and 25
already used: does the core mechanism work — an ordinary agent reading real
operational signals through the existing permission-gated view mechanism,
with genuinely no path to mutate anything — before building a curation UI,
a scheduler, or a proposal-routed remediation flow on top of it.

**What was built**: two new views, `allgres_public.v_system_health` (worker
presence, per-queue backlog counts for `outbound_calls`/`sql_calls`/
`oauth_calls`, running/failed task counts, pending approvals, unswept
expired memories) and `allgres_public.v_permission_audit` (every agent's
`(resource_type, resource_ref, granted_at)` grants, joined to the agent's
name and `is_active`) — no new table, no new action, no new trust boundary.
Both are system-wide rather than per-agent-owned data, so neither needed
the `agent_id IS NOT DISTINCT FROM current_agent_id()` row filter
`v_sales`/`v_my_tasks` use; `agent_may_read` alone gates the whole row set,
the same function and the same two-layer check (allowlist ∩ permission)
every sandboxed view already goes through — a maintenance agent's read
access is exactly as revocable, and exactly as auditable, as any other
agent's `execute_sql` permission, nothing bespoke.

A seeded agent, `health_monitor`, ships with both views granted and nothing
else: no `v_sales`, no tools, no `delegate`, and — deliberately, matching
how conservative this slice chose to be — no `propose_change` in its own
seeded prompt either, even though the action exists and would work if
added. It uses only what every agent already has: `execute_sql` against
the two new views, `remember` to persist a finding for comparison against
its next run (a nice fit with item 25's own memory feature — a maintenance
agent's whole "compare against last time" behavior is just ordinary recall,
no special case), and `final_answer` to report what it found, in the same
Sessions thread view any other agent's run already surfaces. There is no
scheduler; an operator (or an external `cron` job hitting
`POST /api/v1/run`, no different from automating any other agent) decides
when it runs.

**Verified live**, the same standard as items 12–26: rebuilt against local
PostgreSQL 16.15, `fn_selftest` 95/95 (one new case,
`maintenance_views_enforce_permission`: `health_monitor` sees both views
populated, `analyst` — granted neither — sees zero rows from both,
mirroring `views_enforce_permission`'s own technique for `v_sales`).
`tests/smoke.sql`/`tests/e2e_mock.sql` unaffected (no Rust change in this
pass). A real `ALTER EXTENSION allgres UPDATE TO '0.3.0'` from a real
0.2.0 install (on a fully cleaned cluster, per item 19's own account of the
leftover-role trap) confirms both views and the seeded agent exist
post-upgrade and `fn_selftest` stays 95/95. `scripts/backup_drill.sh`
(item 18) re-run end to end, both physical and logical paths, confirms the
`sql_sandbox_allowlist`/`agents`/`policies`/`permissions` seed-exclusion
filters (now naming `health_monitor` alongside `analyst`) don't collide on
restore. Also driven through the real pipeline, not just `fn_selftest`:
`health_monitor` pointed at the same mock LLM provider
`tests/e2e_mock.sql` uses and run through a real session via the real
background worker end to end, reaching `'completed'`; a headless-browser
(Playwright/Chromium) pass confirming it renders correctly in the Agents
page.

`v_system_health`'s `workers_online` count carries the same caveat item 5
already names for the dashboard's own Workers panel: `allgres web` has no
database connection and so never appears in `pg_stat_activity` at all —
confirmed live (`workers_online` read `1` with both workers actually
healthy) rather than assumed from the existing item 5 text, and now noted
directly in the view's own comment so a future reader of *this* view
doesn't have to rediscover it.

**Deliberately not built**: the scheduler that would make a maintenance
agent actually "maintain" anything unattended — this slice only proves an
agent *can* read and report; making that happen automatically needs either
a `pg_cron` dependency or a new recurring-task primitive in the runtime
worker, either a materially bigger and separately-considered change than
this one; any way for a maintenance agent to act on a finding beyond
reporting it — `propose_change` is available to any agent already, but
`health_monitor`'s own seeded prompt doesn't use it, on purpose, so a real
recommendation still requires an operator to read the session and decide,
not an auto-applied policy; the other roles the review proposed (a policy
auditor beyond raw permission grants, a memory curator, a performance
advisor) — `v_permission_audit` gives a security/policy auditor its raw
material but nothing analyzes it yet, and a memory curator is really just
an agent with `memories.list`-equivalent read access plus a prompt, not
attempted here; and no operator identity attached to who triggered a
maintenance run, for the reason item 10 gives throughout.

## 28. A lightweight operator audit log — self-reported, not authenticated, and explicit about the difference

Item 10 has said throughout this file that "who approved this" is
unanswerable by design, because the dashboard has one shared bearer token,
not per-operator accounts. That remains true — a real fix needs a real
authentication model, a materially heavier and riskier change than
anything else in this pass, and was explicitly scoped out in favor of this
lighter version: not an accounts system, an audit trail built on a
self-reported label instead of a real login. It answers a narrower, still
useful question — "who claimed responsibility for this" — and is explicit,
everywhere it appears, that it does not answer the harder one.

**What was built**: `allgres_private.audit_log` (`operator_name`, `action`,
`details` jsonb, `created_at`), append-only the same way `execution_logs`
already is — a `BEFORE UPDATE OR DELETE` trigger, not just a `REVOKE`.
`dashboard_rpc` writes one row per consequential action — `agents.create`/
`agents.update`, `policy.rollback`, `proposals.decide`, `permissions.grant`/
`revoke`, `allowlist.add`/`remove`, `projects.create`/`update`,
`sessions.cancel`, `memories.create`/`remove`, `provider.update`,
`providers.oauth_callback`, `approvals.decide` — in the same transaction as
the mutation itself, before the action's own `CASE` branch runs: if that
branch later raises, PL/pgSQL's implicit savepoint at `dashboard_rpc`'s own
`BEGIN` rolls the audit insert back right along with it, so a row only ever
exists for something that actually committed, never a failed attempt.
`operator_name` is whatever the browser sent, unauthenticated; `details` is
the request minus `action`/`operator_name` and a fixed list of fields that
could carry a secret (`api_key`, `oauth_client_secret`, `code`, `state`) —
generic by construction, so a newly audited action needs only its name
added to the list, no bespoke field mapping.

Deliberately not a REVOKE against the table's own owner: a PostgreSQL table
owner's DML rights on their own table cannot be revoked by ACL at all — only
the trigger actually stops that path, and it applies regardless of who
issues the UPDATE/DELETE, ownership included. (The file's `audit_log`
section says this explicitly, so a future reader does not have to
rediscover it by trying a `REVOKE ... FROM allgres_owner` that would
silently do nothing.)

The dashboard sends `operator_name` from `sessionStorage` (`opName()`),
the same per-tab storage the dashboard token itself already uses, on every
call through the generic `rpc()` helper; three legacy named routes that
bypass it (`agents.create`, `agents.update`, `provider.update`) were
patched individually to include it in their own request bodies. A new
**Audit Log** page lists entries newest-first (`audit.list`), with a
banner repeating the same "self-reported, not authentication" framing the
README's own "Operator audit log" section leads with — the point where
this is easiest to misread as real access control is exactly the page
someone would open to check who did something, so the caveat lives there
too, not only in documentation nobody reading the dashboard would see.

**Verified live**, the same standard as items 12–27: rebuilt against local
PostgreSQL 16.15, `fn_selftest` 96/96 (one new case,
`audit_log_records_consequential_actions_only`: a consequential action
writes exactly one row with the correct `operator_name` and `details`; a
read-only action (`overview`) writes none; a request carrying an `api_key`
never leaks it into `audit_log.details`; and `UPDATE`/`DELETE` against the
table both raise, confirmed by catching the actual exception rather than
assuming the trigger fires). Also driven through the real HTTP path, not
just `fn_selftest`: `curl` against `/api/v1/rpc` for `allowlist.add`/
`allowlist.remove` with an `operator_name`, confirmed to land correctly and
with secrets stripped from a `provider.update` call carrying a real
`api_key`; a headless-browser (Playwright/Chromium) pass setting an
operator name from Settings, performing an audited action, and reading it
back correctly labeled on the new Audit Log page.

**A real side effect from the browser test itself, caught and fixed before
being called done**: the first Playwright pass clicked the first `.remove`
button on the allowlist panel to undo its own test entry, but the panel had
re-rendered in a different order and it actually removed
`allgres_public.v_my_tasks` — a real, seeded, load-bearing allowlist entry,
not a leftover from the test. The audit log itself is what caught it (the
row correctly read `allowlist.remove` / `v_my_tasks`, proving the log was
accurate about something the *test* got wrong, not a bug in `dashboard_rpc`
or the trigger) — confirmed by checking `sql_sandbox_allowlist` directly
afterward and finding the row genuinely gone. Restored by hand
(re-`INSERT`ing `v_my_tasks`) before re-running `fn_selftest`, which passed
clean afterward — a case of a test's own imprecision producing a real,
correctly-recorded consequence, not a false pass.

**Deliberately not built**: real per-operator authentication — this is the
whole point of choosing the lighter version item 10 keeps deferring;
anything that reads `audit_log` as proof of who was *authorized*, rather
than who *claimed* an action, would be a misuse of what this actually is,
which is why every surface it appears on (the table's own comment, the
README section, the dashboard page) repeats the same caveat rather than
stating it once and trusting it to travel; audit coverage for read-only
actions (`*.list`, `settings.get`) — deliberately excluded, since the
question this answers is "who changed something," not "who looked"; and
any UI affordance to filter or search the Audit Log page beyond a flat,
newest-first list of the most recent 300 entries.

## 29. Four real product gaps found by actually using the installed dashboard: a fake default model, no way to add a provider, no chat, and selftest fixtures showing up as if they were real work

Everything through item 28 was found by code review or external review of
the diff. This batch is different: it came from someone actually installing
Allgres end to end (Rocky Linux 9, PostgreSQL 18) and using the dashboard,
which surfaced four things no amount of reading the SQL would have caught.

**A fresh install looked like a provider had already been picked and
authenticated when nothing had.** `allgres_private.ensure_policy()` — the
trigger that gives every newly created agent a starting policy row — set
`llm_config` to `{"provider":"xai","model":"grok-4.5",...}` unconditionally.
The seeded `analyst` demo agent's own policy did the same in its one-time
seed block. Neither of these is a credential leak (no `xai` API key or
OAuth token is ever seeded), but the visible effect was exactly what got
reported: every agent, seeded or freshly created, showed a real-looking
model selection despite OAuth never having been run. Both now leave
`llm_config` at `{}`, matching what `health_monitor`'s seed already did.
That alone wasn't enough: `allgres_private.build_llm_http` still defaulted
an *empty* `llm_config` to `provider: 'xai', model: 'grok-4.5'` before
resolving it against `llm_providers` — meaning an agent with nothing
configured at all would still build a real request pointed at xai's actual
endpoint. It now raises a clear "no llm_config.provider/model configured"
error instead, the same fail-closed shape item 23 already gave a
*misconfigured* provider name; only a real, explicit choice ever reaches an
endpoint.

**There was no way to add an LLM provider — only edit one of the five
seeded ones.** `fn_set_provider` only ever `UPDATE`s a row that already
exists; nothing in this file could `INSERT` a new one, so an operator who
wanted anything beyond xai/openai/anthropic/ollama/openai_compat had no
path but editing the database by hand. `fn_create_provider(name, kind,
base_url, api_key, allow_private_network)` is the missing counterpart —
same endpoint/SSRF validation `fn_set_provider` already applies on edit,
applied at creation time too — wired into `dashboard_rpc` as
`provider.create` and into the audited-action list next to
`provider.update`. The Settings page gained an "Add provider" form for it.
The agent editor's Provider field was a free-text `<input>` with no
base_url or api_key fields at all — the exact complaint, "there's no way to
configure a model by URL, no API key field, nothing." It is now a `<select>`
populated from currently-enabled providers (an agent can no longer be
pointed at a provider name that was just typed and might not exist); Model
stays free text, since one provider can host many model names.

**There was no way to have a conversation.** `fn_create_session` builds
exactly one task and that task runs once; there was no function to send a
follow-up in the same session, only "start an entirely new session that
remembers nothing." Before adding one, this needed an answer to a real
design question: delegated child tasks (`fn_submit_result`'s `delegate`
branch) share their parent's `session_id`, so a naive "pull every task in
this session's logs" would blend a user-facing conversation with whatever
sub-agent delegation happened to occur inside it. The fix distinguishes
root-level tasks (`parent_task_id IS NULL` — a user-facing turn) from
delegated ones (`parent_task_id IS NOT NULL` — a sub-agent's own isolated
turn): `fn_next_step`'s message assembly now pulls every root-level task's
log in the session, ordered by `created_at` across tasks instead of
`step_number` within one, when the task being run is itself root-level;
a delegated task stays scoped to only its own log, exactly as before.
`fn_continue_session(session_id, message)` creates a new root-level task in
an existing session (fresh `step_count`/`max_steps` budget per turn,
deliberately, so an exhausted earlier turn can't block a later one),
appends the message as a `user` log entry, and reopens the session
(`status = 'open'`, `completed_at = NULL`) if it had already finished —
rejecting a second message outright while an earlier turn in the same
session is still `queued`/`running`/`waiting_human`, rather than racing
`fn_next_step`'s own read of the session's task list. Wired into
`dashboard_rpc` as `sessions.continue`.

**Sessions created by running `fn_selftest` were permanently visible in the
dashboard, indistinguishable from real work.** `selftest_cleanup()`
existed, but only ever `UPDATE`d matching rows to a terminal status
(`failed`/`cancelled`) — it never removed them, so every past
`fn_selftest` run left real, permanent rows behind. The obvious fix —
make it actually `DELETE` — does not work: `execution_logs` has a
`BEFORE UPDATE OR DELETE` trigger (`forbid_log_mutation`) making it
genuinely append-only, rejecting `DELETE` the same as `UPDATE`, for
*anyone*, including this function's own owner — confirmed by trying it and
watching PostgreSQL reject it live (`ERROR: execution_logs are
append-only`), not by reading the trigger and assuming. Deleting
`sql_calls`/`tasks`/`sessions` instead and leaving the now-orphaned
`execution_logs` rows behind would either violate the `tasks`/`sessions`
foreign key (nothing here cascades) or leave a log with no task to belong
to. So selftest fixtures are still never deleted — `selftest_cleanup` only
terminates anything an interrupted run left non-terminal, now called
defensively at the *start* of `fn_selftest` too, not just the end — and
every operator-facing listing (`overview`'s counts and `recent_tasks`,
`sessions.list`, `tasks.list`, `logs.list`, the SSE `events` snapshot)
filters out `goal LIKE 'selftest%'` instead. The dashboard never shows them;
the database still has an honest, immutable record of every test run.

**Verified live**, the same standard as items 12–28: rebuilt against local
PostgreSQL 16.15, `fn_selftest` 104/104 (8 new cases: the fail-closed
provider/model checks, a fresh agent's `llm_config` starting empty,
`fn_create_provider`'s success/bad-kind/SSRF-rejection paths, both ends of
`fn_continue_session` — rejecting a second message mid-turn and reopening a
finished session with context intact — and `selftest_cleanup` actually
being invisible to `tasks.list`/`sessions.list`/`events` rather than gone).
`tests/smoke.sql` and `tests/e2e_mock.sql` both pass. Beyond the SQL-only
suite: driven through the real async runtime worker end to end against the
`allgres_mock` provider `tests/e2e_mock.sql` already sets up — one session
run to completion, then `fn_continue_session` called against it directly,
confirmed to flip the session back to `open`, dispatch a genuinely new
task, and — read back from `execution_logs` across both root tasks,
ordered by `created_at` — carry both turns' `user`/`assistant` messages in
one continuous, correctly ordered thread. (One real environment trap found
along the way, not a bug in this diff: the runtime worker connects to
whichever database `ALLGRES_DATABASE` names, `postgres` by default, not
whatever database `psql` happens to be pointed at — testing against a
different database than the workers' own left tasks permanently `queued`
with no error logged anywhere, since `extension_is_installed()` correctly
reported `false` for a database that never had the extension created in
it. Worth naming here since it is exactly the kind of silent, misleading
non-failure someone else debugging this project could burn real time on.)

**Deliberately not built in this pass**: the two chat *modes* (a Slack-style
`@agent_name` channel where an unaddressed message posts without triggering
a reply, versus a plain 1:1 conversation) and the real accounts/login system
with admin/user roles and per-user agent assignment that the dashboard UI
for `fn_continue_session` will sit on top of — both underway as a follow-up
to this same round of feedback, tracked separately rather than folded into
this entry after the fact. See item 30.

## 30. Real accounts (admin/user roles, per-user agent assignment) and the two chat modes item 29 deferred

A follow-up to item 29's own "deliberately not built in this pass" note,
from the same round of feedback: a real username/password login distinct
from the dashboard's one shared bearer token, admin vs. regular-user roles,
an explicit per-user agent assignment list, and two ways to talk to an
agent from the dashboard -- a plain 1:1 chat and a Slack-style channel
where addressing a message with `@agent_name` is what routes it to that
agent, everything else just posts.

**Accounts.** `allgres_private.users` (username, a pgcrypto bcrypt
`password_hash`, `role` in `('admin','user')`) and `allgres_private.
web_sessions` (a bearer token distinct from the dashboard's own, resolved
server-side by `allgres_private.session_user` rather than trusted at face
value). Unlike provider-secret encryption, which degrades to plaintext
storage with a loud warning when pgcrypto is missing (see "Secrets at
rest"), a password hash has no safe degraded mode: `fn_create_user`/
`fn_login` raise `pgcrypto is required` and refuse outright rather than
ever hashing or comparing a password in plaintext -- confirmed live by
temporarily uninstalling pgcrypto and watching both calls fail closed, then
reinstalling and confirming they work. A failed login (wrong username or
wrong password) is intentionally indistinguishable from the caller's
side -- the same error message, plus a fixed `pg_sleep(0.2)` on the
unknown-username path so it cannot be timed apart from a
wrong-password one.

**Roles.** `allgres_private.require_admin(token)` gates the new admin-only
actions (`users.create`, `users.list`, `users.set_active`, `users.
set_role`, `assignments.set`, `assignments.list`). `allgres_private.
require_agent_access(token, agent_id)` is the one check every chat/
messenger/model-config action for a specific agent goes through: an admin
reaches any active agent with no assignment row needed at all; a regular
user only one explicitly listed in `allgres_private.
user_agent_assignments` (item 29's "explicit allowed set" pattern, not
"everything visible unless removed"). Neither of these touches the
dashboard's own shared token or `operator_name` -- a `session_token` in the
request body identifies the logged-in user instead, alongside the existing
mechanisms rather than replacing them. This is deliberately narrower than
a full rewrite of the security model: the existing shared-token-gated
`dashboard_rpc` surface (agent CRUD, permissions, providers, the SQL
sandbox allowlist, and so on) is unchanged and still reachable by anyone
holding that one token, same as before every item through 29. Real
per-operator authorization for *that* surface remains the deferred item
KNOWN_ISSUES.md, item 10, has always described -- this adds a second,
separate identity layer for the new conversational surface specifically,
not a retrofit of the first one.

**Simple chat.** `allgres_private.user_agent_chat_sessions` maps one
(user, agent) pair to one continuing session -- created via
`fn_create_session` on the first message, resumed via `fn_continue_session`
(item 29) on every one after, never a fresh, contextless session per
message. `fn_chat_send`/`fn_chat_history` are the two calls the Chat page
uses; `chat.send`/`chat.history` in `dashboard_rpc`.

**Messenger.** `allgres_private.channel_messages` is a flat, append-style
feed: every plain post is just stored (`mentioned_agent_id`/`session_id`
both `NULL`); a post containing `@agent_name` additionally resolves that
agent (through the same `require_agent_access` a direct `chat.send` would
apply) and routes the *same* message through `fn_chat_send` -- so
mentioning an agent in the channel and messaging it from the 1:1 Chat page
share one conversation per (user, agent), not two divergent histories,
confirmed live: a `chat.send` message and a later `@mention` in the
channel landed in the same `session_id`, and the channel mention correctly
picked up the earlier turn's context. `messenger.list` joins each
mentioned row back to `allgres_private.sessions` for `status`/
`final_answer` rather than duplicating the agent's reply into
`channel_messages` itself -- the reply lives in exactly one place.

**Dashboard.** A login screen gates the whole app -- on top of, not instead
of, the existing dashboard-token prompt: that token still decides whether
a browser reaches the HTTP surface at all, this decides who, having
reached it, is using it. Nav is now role-scoped: an admin keeps every
existing page, plus new **Users** (create an account, activate/deactivate,
change role, manage one user's agent assignments), **Chat**, and
**Messenger** pages; a regular user sees only **Chat**, **Messenger**, and
**My Agents** -- their assigned agents, each with an inline Provider
(dropdown of configured providers, the same as the operator-facing agent
editor -- see item 29) / Model editor wired to `fn_set_my_model`, never the
full `agents.update` surface (no prompt, budgets, or permissions).

**Verified live**, the same standard as items 12–29: `fn_selftest` 113/113
(9 new cases -- fail-closed without pgcrypto, wrong-password rejection, a
correct login, `require_agent_access` admin-bypass vs. assigned-only-user,
a plain messenger post carrying no mention, an unassigned `@mention`
rejected, `fn_set_my_model` updating only an assigned agent and rejecting
an unassigned one, and `fn_logout` invalidating a token idempotently), all
using a throwaway agent created and torn down within the test, never the
real seeded `analyst`/`health_monitor` fixtures. `tests/smoke.sql` and
`tests/e2e_mock.sql` both still pass. Beyond the SQL suite: driven through
an actual headless-Chromium (Playwright) pass against the real dashboard --
the login gate blocking the app until signed in; an admin's full nav
(including the three new pages) versus a freshly created regular user's
three-item nav; creating a user and assigning an agent from the Users
page; sending a chat message and reading it back on the Chat page; posting
a plain message and an `@analyst` mention on the Messenger page and
watching the mention's reply (`"Allgres mock runtime OK"`, from
`tests/e2e_mock.sql`'s own mock provider) appear inline; and a regular
user's My Agents page correctly listing only their one assigned agent
with a provider dropdown.

**Deliberately not built**: any UI affordance to search/paginate the
Users or Messenger pages beyond a flat list (matching the Audit Log
page's own accepted limitation, item 28); typing-indicator or read-receipt
niceties for the messenger; and, as above, gating the pre-existing
shared-token `dashboard_rpc` surface by role -- that remains the same
single shared secret it always was, now with a second, narrower,
per-user identity layer sitting alongside it for chat/messenger/my-model
specifically.

## 31. A system agent family: one root, five children, per-agent autonomy levels, and three new consequential actions

A follow-up requested directly: built-in agents that operate the platform
itself rather than a user's workload -- summarizing a long session,
routing a multi-mention Messenger message, helping create new agents,
proposing a fix for what `health_monitor` finds, and tuning another
agent's cost -- structured as one inheritance hierarchy, with an
admin-configurable dial on how much of each one's own consequential
actions run unattended. This item is the backend half of that request;
the SQL-side inbox (Approvals/Proposals plus a new Fixes queue) is real
and role-scoped, but Overview's cluster monitoring, the Chat page's
General/Messenger/Project mode switch, nav consolidation, and i18n/theme
remain a follow-up pass, tracked separately.

**Hierarchy.** `allgres_private.agents` gains `is_system boolean`,
`parent_agent_id uuid` (self-referencing), and `autonomy_level text` in
`('auto', 'self_approve', 'admin_approval')`, default `admin_approval`.
One `system_root` agent carries no operational job of its own; five
children -- `session_compactor`, `orchestrator`, `creator`, `fixer`,
`self_improve` -- hang off it with `parent_agent_id = system_root`.
`allgres_private.agent_has_permission`/`agent_permission_refs` replace
every direct `SELECT ... FROM allgres_private.permissions WHERE agent_id =
...` check in the file (`call_tool`'s tool/http_host grants, `delegate`'s
target-agent grant, `execute_sql`'s view grant via `agent_may_read` and
`fn_validate_sql`) with a recursive walk up `parent_agent_id` -- a grant on
`system_root` reaches every child without being restated five times, and
is invisible to every non-system agent, confirmed live (`selftest_agent`,
an ordinary agent, does not see a permission granted only to
`system_root`). `allgres_private.agent_effective_prompt` does the same for
`system_prompt` text -- a child's own prompt is appended after its
ancestors', root-first -- and `fn_next_step`'s "bounds" text (what an
agent is told it may do) now reads from `agent_permission_refs` rather
than the agent's own direct grants, so a system agent's displayed
capabilities match what `agent_has_permission` will actually let it do.
`allgres_private.require_admin_for_system_agent(token, agent_id)` is a
no-op for an ordinary agent (the pre-existing shared-token-only surface,
completely unaffected) and requires an admin session the moment the
target `is_system` -- wired into `agents.update`, `policy.rollback`, and
`permissions.grant`/`.revoke`, the first real narrowing of that
shared-token surface by role since item 30 explicitly deferred it.
`fn_set_agent_autonomy` (RPC: `agents.set_autonomy`, always admin-only,
regardless of target) is the dial's own setter.

**The three new actions**, each gated to exactly the one agent whose job
it is (checked by name, since only that one agent is ever seeded with the
matching prompt) and each respecting its own `autonomy_level`:
`admin_approval` queues a request in the existing (or, for `propose_fix`,
new) inbox for a human to accept or reject; `auto` or `self_approve` apply
immediately, no human step in the path at all -- the nuance between those
two is left to the agent's own prompt (an agent at `self_approve` is told
it may still choose `await_human` itself when unsure, rather than the
platform forcing an escalation on every call).

- `create_agent` (`creator` only): `{"action":"create_agent","name":
  "...","system_prompt":"..."}`. Queued as a new `change_proposals.kind =
  'create_agent'` row (that table's existing `agent_id`/`base_generation`/
  `target_agent_id` columns are meaningless for this kind -- there is no
  existing policy to go stale); `fn_decide_proposal` calls
  `fn_create_agent` on approval, same as if an admin had typed it into the
  Agents page.
- `propose_fix` (`fixer` only): `{"action":"propose_fix","fix_kind":
  "revoke_permission"|"deactivate_agent","target_agent_id":"...","detail":
  {...}}`. A new table, `allgres_private.fix_proposals`, shaped like
  `change_proposals` but for a fix's payload rather than a policy edit;
  `allgres_private.apply_fix` (shared by `fn_decide_fix` and the
  `auto`/`self_approve` immediate path) is the one place that turns a
  `fix_kind` into a real `fn_revoke_permission`/`fn_set_agent_active`
  call. `fixer` is seeded with the same two read-only views
  `health_monitor` already watches (`v_system_health`,
  `v_permission_audit`) -- it can look at exactly what `health_monitor`
  looks at, never anything more, and proposes rather than silently acts
  by default.
- Cross-agent `propose_change` (`self_improve` only): the existing
  `propose_change` action, extended with an optional `target_agent_id` --
  every other agent's `propose_change` is rejected outright
  (`propose_change_cross_agent_not_permitted`) the moment it names one,
  preserving item-whatever's original "an agent may only ever propose
  a change to itself" invariant for everyone except this one agent.
  `change_proposals.target_agent_id` records who it actually targets;
  `base_generation` is read from *that* agent's policy, not
  `self_improve`'s own, so the staleness check protects the right row;
  `fn_decide_proposal` writes to `COALESCE(target_agent_id, agent_id)` on
  approval. Confirmed live: an approved cross-agent proposal changed the
  target's `system_prompt` and left `self_improve`'s own untouched.

**Approvals, Proposals, and the new Fixes queue, opened to regular
users.** `allgres_private.visible_agent_ids(token)` returns `NULL`
(unrestricted -- no session, i.e. the original shared-token-only caller,
or an admin) or a regular user's own `user_agent_assignments` list.
`approvals.list`/`.decide`, `proposals.list`/`.decide`, and the new
`fixes.list`/`.decide` all scope by it: a regular user sees and may decide
only the rows whose underlying agent (a `propose_change`'s
`COALESCE(target_agent_id, agent_id)`, a fix's `target_agent_id`) is one
of their own assigned agents; `create_agent` proposals have no existing
target to scope by and stay admin-only. Both inboxes also gained a
`reason NOT LIKE 'selftest%'` filter, closing the same "fn_selftest
fixtures visible as if real" gap item 29 fixed for Sessions/Tasks --
confirmed live, `fixes.list` and `proposals.list` are empty of selftest
rows immediately after a `fn_selftest` run.

**Verified live**: `fn_selftest` grew from 105 to 129 cases (root-and-five
seeded correctly under one parent; a `system_root` grant reaching every
child and no unrelated agent; a child's effective prompt containing the
root's framing text ahead of its own; `is_system` edits rejected without
an admin session and unaffected for an ordinary agent; a bad
`autonomy_level` rejected with a clear error; `create_agent` queuing then
actually creating the agent on approval, rejected outright from any other
agent, and applying immediately under `autonomy_level = 'auto'`;
`propose_fix` queuing then applying a deactivation on approval;
`self_improve`'s cross-agent proposal landing on the target's own
generation and policy, and rejected from every other agent;
`visible_agent_ids` scoping a regular user to their assigned agents and
widening the moment one is assigned) -- all passing, and idempotent
across repeated runs (checked twice back to back). `tests/smoke.sql`
passes end to end, including a live `dashboard_rpc` round trip for
`agents.set_autonomy`/`fixes.list`/`proposals.list`. The whole 0.4.0 ->
0.5.0 upgrade path was exercised for real: an extension created at
`'0.4.0'`, a real operator edit made to the seeded `analyst` agent's
`system_prompt`, `ALTER EXTENSION allgres UPDATE TO '0.5.0'` run against
it, and both the operator's edit and every new system agent/column
confirmed present afterward.

**Deliberately not built in this pass**: `session_compactor`'s actual
trigger (summarizing a session automatically once it grows long -- today
it is seeded with a prompt describing that job, but nothing calls it yet)
and `orchestrator`'s multi-mention routing in Messenger (same -- seeded,
not wired to a real multi-`@mention` code path); the Overview page's
Postgres-version-plus-cluster-monitoring redesign; the Chat page's three
mode buttons (General/Messenger/Project) replacing today's separate Chat/
Messenger pages, and the matching extension of `allgres_private.projects`
with an `agent_id` and preset prompt; folding Sessions/Tasks/Logs/Events
into Audit and Users into Settings; and language (en/ko) and dark/light
theme switches in Settings. All tracked as the immediate next pass on
this same branch.

## 32. The rest of item 31's own list, plus a real extension-tooling gap it exposed

The immediate follow-up item 31 named: `session_compactor`'s actual
trigger, `orchestrator`'s multi-mention routing, Overview's cluster
monitoring, the Chat page's three-mode switch and Project mode, nav
consolidation, and language/theme switches. All built and verified live
in this pass; a genuine bug in `scripts/gen-upgrade.sh` itself (not in any
SQL logic) was also found and fixed along the way -- see "Verified live"
below for how it surfaced.

**session_compactor, actually triggered.** `allgres_private.
maybe_trigger_compaction(session_id, task_ids)`, called from
`fn_next_step` on every root-level step: counts this session's own
not-yet-summarized logs (everything after `sessions.compacted_before`, or
all of them the first time -- counting every row ever written would stay
past threshold forever, since raw logs are append-only and never
deleted), and past 60 queues a real background task for `session_compactor`
carrying the oldest of them (everything but the most recent 10) plus
whatever it summarized last time, so a second compaction folds both into
one updated summary instead of silently dropping the first one. Nothing
sets `compacted_before` except `session_compactor`'s own `remember`
landing (`fn_submit_result`) -- the trigger itself never does -- so a turn
can never see neither the raw logs nor a finished summary; worst case, a
few extra turns while compaction is still in flight. Once set,
`fn_next_step` excludes logs older than the cutoff and prepends the latest
summary as a system message instead. Confirmed live end to end with
explicit, distinct `created_at` timestamps 1 second apart: 70 synthetic
turns in one session, `fn_next_step` correctly triggering a compaction
task, simulating that task's own `remember` + `final_answer`, and a
following turn on the original session showing the summary and the most
recent turns but not the compacted-away ones. (First attempt used a tight
PL/pgSQL loop with the implicit `now()`, which is frozen for the whole
transaction -- every row got the *same* timestamp, so the cutoff logic
had nothing to compare against and silently kept everything. The fix
belongs to the test, not the product: real turns, each its own
transaction with real elapsed time between them, never collide like this.)

**orchestrator, actually exercised -- advisory only.** `fn_messenger_post`
now extracts every distinct `@mention` in text order (not just the
first), validates and delivers to each via `fn_chat_send` the same way a
single mention always did, and records the full ordered list
(`channel_messages.mentioned_agent_ids`, `messenger.list`'s new
`mentioned_agents` array). When more than one agent is mentioned,
`allgres_private.queue_orchestrator_opinion` also fires a real task for
`orchestrator` carrying the message and each candidate's own prompt, so it
is genuinely exercised against real messages rather than sitting
permanently idle -- but its opinion is not yet what decides delivery
order; that stays text order for now. A real reordering-before-delivery
pass needs the async completion hook this doesn't build (orchestrator's
task completes on its own schedule, well after `fn_messenger_post` has
already returned) and is tracked as further work, not silently dropped.

**Project mode.** `allgres_private.projects` gains `agent_id`/
`preset_prompt`; `fn_next_step` appends `preset_prompt` after the bound
agent's own effective prompt when the session belongs to that project.
`allgres_private.user_project_chat_sessions` +
`fn_project_chat_send`/`fn_project_chat_history` mirror the General-mode
chat surface exactly, keyed by project instead of by agent and
deliberately its own table/session rather than reusing that agent's
General-mode one -- a project's preset context must never leak into a
plain chat with the same agent, or the other way around.
`allgres_private.require_project_access` is `require_agent_access` plus
"the project is active and bound to an agent at all" -- a regular user
needs the same assignment a Project's agent would require in General
mode; there is no separate project-level allow-list. Confirmed live: a
project bound to `analyst` with a haiku-only preset, chatted with through
`fn_project_chat_send`, and `fn_next_step`'s system message contained the
preset text.

**Overview's cluster monitoring.** A new native function,
`allgres.native_host_stats()` (Linux-only by design -- `/proc/loadavg`/
`/proc/meminfo`, the most direct interface available, degrading to `null`
sections rather than an error if unavailable, the same reasoning
`analyze_sql` already used for PostgreSQL's own parser instead of a
hand-rolled one), plus `current_setting('server_version')` and a
`pg_stat_activity` count scoped to `current_database()`, all folded into
the existing `overview` RPC action rather than a new one.

**Nav consolidation, language, and theme -- all in `web/index.html`.**
Sessions/Tasks/Logs/the audit trail become one **Audit** page with four
tabs; Users becomes a section of **Settings**; Approvals/Proposals/the new
Fixes queue become three tabs of one **Approvals** page (open to regular
users, per item 31); Chat/Messenger/Project become three mode buttons of
one **Chat** page. `assignments.toggle`/`.for_agent` (admin-only, added
alongside this) let an admin grant/revoke one user's access to one agent
directly from the Agents page's edit modal -- the reverse direction of
`assignments.set`/`.list`, which stay built for the Users page's own
per-user checkbox list and would otherwise require reading a user's whole
assignment list just to flip one entry. Language (English/한국어) and
theme (dark/light) are both a plain `localStorage` preference, no
server-side state at all; language covers navigation, page chrome, and
common actions/empty-states -- not every field label in every modal, and
never data from the database itself (an agent's own name, a log's own
content), which was never translatable content to begin with.

**A real bug in `scripts/gen-upgrade.sh` itself, caught by actually
running the upgrade.** `sql/control_plane.sql` is hand-written SQL only
(tables, PL/pgSQL) -- a native function declared in `src/lib.rs` via
`#[pg_extern]` (`native_host_stats` above) is not in it at all; pgrx
generates that function's own `CREATE FUNCTION ... LANGUAGE c` statement
and splices it into the *fresh-install* file only
(`allgres--<version>.sql`). `gen-upgrade.sh` had always just dumped
`control_plane.sql` verbatim, which was never wrong before because every
native function already existed since 0.1.0 -- `native_host_stats` is the
first one ever added mid-project. Caught live: `ALTER EXTENSION allgres
UPDATE TO '0.5.0'` against a real 0.4.0 database left `overview` failing
with `function allgres.native_host_stats() does not exist` despite every
fresh install passing, because `fn_next_step`/`fn_selftest` (hand-written
SQL) upgraded correctly while the native function they call did not.
Fixed in the script itself, not by hand-patching the generated file (which
its own header says not to edit): it now extracts every native
(`LANGUAGE c`) function declaration from the fresh-install file it just
built, rewrites each as `CREATE OR REPLACE FUNCTION` (idempotent against a
target that already has an older, or for one that predates this fix, no
version of it), and prepends them before the `control_plane.sql` dump --
so any future native function added mid-project is included automatically,
not by remembering to hand-patch an upgrade script again. A second,
smaller version of the identical rule (CREATE OR REPLACE cannot land a
grown parameter list, see this file's own "Drop objects whose signature...
changed" section) applied to `fn_create_project` gaining
`agent_id`/`preset_prompt` -- without an explicit
`DROP FUNCTION IF EXISTS fn_create_project(text, text)`, an upgrade would
leave both the old 2-arg and new 4-arg overloads installed side by side,
and a single-argument call (`fn_selftest`'s own project fixture) becomes
ambiguous between them.

**Verified live**: `fn_selftest` grew from 129 to 140 cases (all of the
above, plus `assignments.toggle`/`.for_agent`), passing and idempotent
across repeated runs on a fresh install. The corrected `0.4.0 -> 0.5.0`
upgrade was re-verified for real end to end after the `gen-upgrade.sh`
fix: a real 0.4.0 database, a real operator edit to `analyst`'s
`system_prompt`, `ALTER EXTENSION ... UPDATE TO '0.5.0'`, and both the
edit and `overview`'s new fields (which had failed before the fix)
confirmed working afterward, with `fn_selftest` at 140/140 on the upgraded
database too -- not just on a fresh install, which is exactly the gap that
let the `native_host_stats` bug through the first time. `tests/smoke.sql`
passes. Beyond the SQL suite: a full headless-Chromium (Playwright) pass
against the real running dashboard -- admin's consolidated 9-page nav;
Agents showing every system agent's `autonomy_level` inline and the
edit modal's autonomy selector plus its new "Assigned users" button and
modal; Approvals' three tabs (Approvals/Proposals/Fixes); Projects showing
a project's bound chat agent; Chat's three mode buttons each actually
sending and receiving a reply (General, an `@mention` in Messenger, and a
Project-mode message with its preset applied); Settings showing the
embedded Users section and switching the whole nav to 한국어 and the page
to light theme live; Audit's four tabs; and a regular user's restricted
three-item nav still reaching the Approvals page scoped to their own
assignments -- zero console errors across the whole pass.

## 33. `agents.list` never filtered `fn_selftest`'s own fixtures either -- caught by an actual CI failure

Item 29 hid `fn_selftest`'s scratch sessions/tasks from Sessions/Tasks/
Overview (`goal NOT LIKE 'selftest%'`); item 31 did the same for the new
Proposals/Fixes queues. `agents.list` (the Agents page, and
`/api/v1/agents`) never got the equivalent `name NOT LIKE 'selftest%'`
filter -- every scratch agent `fn_selftest` creates (`selftest_delegate_a`/
`_b`, `selftest_fix_target`, `selftest_mention_target`, an epoch-suffixed
`selftest_created_by_creator_<ts>`/`selftest_auto_created_<ts>` pair per
run, and more) has always accumulated there, real rows never deleted,
same as the sessions/tasks case before item 29's fix.

This stayed a cosmetic wart, not a real cost, back when `fn_selftest` only
created a handful of scratch agents with short prompts. Item 32's five
system agents each carry a multi-paragraph prompt, and item 36's new
`create_agent`/`propose_fix` selftest cases add two more scratch agents
per run -- so a CI job that calls `fn_selftest` more than once in the
same database (this project's own `docker-smoke` job does, directly and
through `tests/smoke.sql`) accumulates agents with long prompts fast.
Caught live: a `docker-smoke` run failed with `curl: (23) Failure writing
output to destination` (exit code 23) partway through printing a `curl`
response -- the response itself (confirmed by reproducing locally) was
`/api/v1/agents`, grown large enough after a few `fn_selftest` calls in
one container's lifetime to trip a write failure logging it. The specific
PR run this was caught on had already gone green on a later, unrelated
push by the time this was investigated, but the underlying growth is
real, cumulative within any one long-lived database (a real dashboard
install, or a CI container that runs `fn_selftest` more than once), and
was going to resurface.

Fixed by adding the same `name NOT LIKE 'selftest%'` filter to
`agents.list`'s query, exactly the pattern items 29 and 31 already
established for every other listing. Confirmed live: three `fn_selftest`
runs against one fresh database, `allgres_private.agents` growing to 23
real rows, `agents.list` correctly still returning exactly the 8 real
ones (`analyst`, `health_monitor`, and the six `is_system` agents --
`system_root` and its five children) at a
reasonable ~11KB response size instead of all 23 and growing.
`fn_selftest` (140/140) and `tests/smoke.sql` both still pass.

## 34. Generic `agent_config` -- every system agent's hardcoded behavior tunable, dashboard included

Every system agent had at least one behavior constant baked into the SQL
that decides how it fires: `session_compactor`'s trigger threshold (60
uncompacted logs) and how many recent ones it leaves alone (10), and
`orchestrator`'s minimum mention count to bother routing (more than one).
None of these were reachable from anywhere -- changing them meant editing
`control_plane.sql` and reinstalling the extension. Asked directly: how
deep does control over the system agents actually go today, and can the
compaction threshold specifically be tuned from the dashboard -- the
honest answer was "not at all, it's compiled in." This item generalizes
that to every such parameter, present and future, not just compaction's.

Rather than a column per parameter (a migration for every future knob) or
folding these into the existing `policies` table (versioned, audited,
config-shaped for `system_prompt`/`llm_config`/limits -- the wrong
lifecycle for "what number does this specific agent kind read"), agents
got one new column: `allgres_private.agents.agent_config jsonb NOT NULL
DEFAULT '{}'`. A new `fn_set_agent_config(agent_id, config)` merges
(`agent_config || p_config`, then `jsonb_strip_nulls`) rather than
replaces, so setting one key never disturbs another, and sending a key
with JSON `null` clears it back to the coded default -- the same idiom
`fn_set_project_config` already established for `preset_prompt`. Every
reader applies `COALESCE((agent_config->>'key')::type, <old hardcoded
value>)`, so an agent nobody has ever touched behaves exactly as before.

`dashboard_rpc`'s `agents.list` now returns each agent's `agent_config`;
`agents.update` accepts an `agent_config` key and calls
`fn_set_agent_config`, reusing the same `require_admin_for_system_agent`
gate every other field on a system agent already goes through -- editing
an ordinary agent's config needs no admin session, editing
`session_compactor`'s or `orchestrator`'s does, exactly like their
`system_prompt` or `max_steps`. Two readers were migrated to prove the
mechanism end to end: `maybe_trigger_compaction` now reads
`compaction_threshold`/`compaction_keep_recent` from `session_compactor`'s
own row (moving its lookup earlier, since the threshold itself now lives
there instead of being a literal), and `fn_messenger_post`'s
orchestrator-routing check reads `min_mentions_to_route` from
`orchestrator`'s row instead of a bare `> 1`.

The Agents page's edit modal gained a named, labeled number field per
known parameter (`session_compactor`'s two, `orchestrator`'s one) shown
only when editing that agent by name, plus a raw-JSON `agent_config`
textarea shown for every agent as the forward-compatible fallback for any
key not yet given a named field -- named fields win on save (merged over
whatever the textarea holds), so the two never fight over the same key.
Blank on a named field means the same thing blank already means on Max
turn seconds: clear it, revert to default.

Driving this through an actual browser surfaced a real, pre-existing bug
this feature would otherwise have inherited silently: the edit modal's
main Save button (`PATCH /api/v1/agents/:id`) never sent `session_token`
in its body at all -- only the separate Autonomy-level dropdown did (it
goes through the `rpc()` helper, which adds it automatically). Since
`agents.update` requires an admin session for any field on a system
agent, every save of `system_prompt`/`max_steps`/permissions/etc. on any
of the six system agents from the dashboard has always failed with `not
logged in`, silently working around it only for admins who never actually
tried to change one. Fixed by adding `session_token:sessTok()` to that
PATCH body, the same value `rpc()` already sends. Without this fix
`agent_config` would have been unreachable from the dashboard for the
exact two agents (`session_compactor`, `orchestrator`) it was built for.

**Verified live**: `fn_selftest` grew from 140 to 147 cases (admin gating
on ordinary vs. system agents, merge-not-replace persistence, `null`
clearing a key, the compaction threshold actually firing early at a
lowered value, and `orchestrator`'s routing threshold actually suppressing
and restoring), passing and idempotent across three repeated runs on a
fresh install; `tests/smoke.sql` 147/147. Beyond the SQL suite, a real
headless-Chromium (Playwright) pass against the running dashboard: logged
in as a real admin, opened `session_compactor`'s edit modal, filled both
named fields, saved, confirmed a `200` response and the exact values
(`{"compaction_threshold": 30, "compaction_keep_recent": 5}`) landing in
the database; reopened the same modal and confirmed both the named fields
and the raw-JSON textarea reflected the saved values back; repeated for
`orchestrator`'s `min_mentions_to_route`; and confirmed a non-system,
non-special agent (`analyst`) shows no named fields at all and persists an
arbitrary key (`{"custom_key": 42}`) typed into the raw-JSON textarea --
the forward-compatible path working for a parameter that doesn't have a
named field yet.

## 35. Agent embeddings and semantic delegate search -- pgvector as a genuine add-on, not a dependency

Asked directly what "tool/skill search" should mean here: an agent IS the
unit of capability in this platform, so it means finding another agent to
`delegate` to by describing the task, not maintaining a separate tool
registry. `delegate` itself has always required the caller to already know
the exact `agent_name` string -- there was no way for an agent to discover
which of the (possibly many) agents it holds `agent` permission for
actually fits a given job.

The harder constraint, stated explicitly up front: pgvector must be a
genuine add-on, never a dependency the extension requires or silently
enables. Concretely that means every embedding is stored as a plain
`double precision[]` (a type every PostgreSQL has), never pgvector's own
`vector` type -- a table or function naming `vector` directly would fail
to even install on a server that never ran `CREATE EXTENSION vector`, the
same problem pgcrypto already has an established answer for
(`allgres_private.encrypt_secret`'s dynamic-SQL, schema-qualified-by-
`%I`-lookup pattern, reused here as `vector_schema()`/`vector_available()`).
Ranking always has a correct, unindexed `allgres_private.
cosine_similarity()` path in plain SQL; when pgvector *is* installed,
`allgres_private.ensure_vector_index()` -- called opportunistically on
every embedding write, no separate "enable" admin step -- builds an HNSW
expression index for whatever dimension is actually in use and rebuilds it
if that dimension ever changes (an operator switching embedding models).
Every dynamic-SQL string that names `vector`/`vector_cosine_ops`/`<=>`
schema-qualifies them (`%I.vector`, `OPERATOR(%I.<=>)`) rather than relying
on search_path, since `<=>` does not resolve as bare text even when its
operand types do.

Mechanism: `llm_providers` gained a `purpose` column (`chat`/`embedding`,
the latter restricted to `kind='openai_compat'` and requiring an
`embedding_model`) and `agents` gained `embedding double precision[]` +
`embedding_model`/`embedding_updated_at`. A new `embedding_calls` table
(shaped exactly like `oauth_calls` -- queued/in_flight/harvested/lost, no
`task_id`, claimed by the same runtime HTTP pool) regenerates an agent's
identity embedding (name + system_prompt) whenever `fn_create_agent`/
`agents.update` touches it; failure at any point (no embedding provider
configured, endpoint rejected) is a silent no-op, never a failed agent
write, since this is an optional feature end to end. A new `search_agents`
agent action queues its query text as `outbound_calls.kind='embedding'`
(alongside `llm`/`tool`, reusing `fn_claim_outbound`/`perform_http`
entirely unchanged -- an embeddings POST is just another JSON body);
`fn_complete_outbound`'s new `'embedding'` branch calls
`allgres_private.rank_agents_by_embedding`, which excludes the requester
itself, any agent it lacks an `agent` permission grant for (the identical
check `delegate` enforces -- a search can never surface a name the caller
could not actually delegate to), and any embedding of a different
dimension, then hands the ranked list back as a `tool_result` on the next
step, exactly like `execute_sql`/`call_tool` already look to the agent.

Two real bugs surfaced only by actually running this against a live mock
embedding provider, not by reading the code:

- The runtime worker's privilege-dropped role had no `EXECUTE` grant on
  the two new `fn_claim_agent_embedding`/`fn_complete_agent_embedding`
  functions -- every claim attempt raised `permission denied`, silently
  crash-looping the whole `allgres runtime` background worker every 5
  seconds (its own `restart_time`) with nothing surfacing anywhere but
  the Postgres log. Fixed with the same `GRANT EXECUTE ... TO worker`
  every other claim/complete pair already has.
- Installing pgvector broke the SQL sandbox's function allowlist for the
  *unrelated* built-in `sum`/`avg` names: pgvector adds its own
  `sum(vector)`/`avg(vector)` aggregate overloads in `public`, and
  `fn_validate_sql`'s allowlist check counted every same-named function
  across *all* schemas, demanding all of them be non-volatile/non-
  security-definer/pg_catalog -- so a plain `sum(amount)` over a numeric
  column started failing the moment pgvector merely existed in the
  database, regardless of whether this feature was ever used. The fix is
  also a simplification: `sandbox` (the role every agent SQL statement
  actually executes as) has `search_path = pg_temp`, so an unqualified
  name can only ever resolve to `pg_catalog` at execution time (pg_catalog
  is always implicitly searched, `public` is not) -- the check now counts
  overloads in `pg_catalog` only (or the explicit schema, when the call is
  schema-qualified) instead of every namespace in the database. This was a
  real, exploitable-by-accident regression for anyone who installs
  pgvector for any unrelated reason, not specific to this feature.

The Docker image installs the `postgresql-17-pgvector` package so it is
available to `CREATE EXTENSION vector;` out of the box, but never runs
that statement itself -- identical to how `pgcrypto` is already handled in
`001-create-extension.sql`. Settings' provider form gained a Purpose
selector (`chat`/`embedding`) and an embedding-model field, shown only for
an embedding-purpose provider; the providers table shows both.

**Verified live**: `fn_selftest` grew from 147 to 149 cases (`allgres_private.
rank_agents_by_embedding`'s ordering/permission-filtering/dimension-
exclusion all in one assertion, and `search_agents` degrading to a
friendly `continue` with no embedding provider configured), passing and
idempotent across three runs, on a fresh install both with and without
pgvector present. `tests/e2e_mock.sql` extended with a real end-to-end
round trip through the actual runtime worker and a new `/mock/embeddings`
endpoint (deterministic, keyword-based vectors so a test can assert an
exact expected ranking rather than eyeballing a real model's output):
`fn_create_agent` for two agents with distinct keyword identities, waiting
for the worker to actually generate and store both embeddings via a real
HTTP round trip, then a real `search_agents` action from a third agent
correctly ranking the matching one first -- run and passing both with
pgvector installed (confirmed the HNSW index gets created and used) and
without it (confirmed the brute-force path returns the identical ranking,
same values up to floating-point precision). Semantic recall over
long-term agent memory (item 25), using this same embedding
infrastructure, is deliberately left for a follow-up slice.

## 36. Three real gaps found by an outside review of item 35's own commit: a flaky CI mechanism, an unvalidated agent_config, and an embedding-model mix-up

An external review of the merged commit (b539afc) flagged three things
worth checking against the real code rather than taking on faith. All
three turned out to be real.

**`docker-smoke` was failing on `main`, not just a stale PR run.** The
review caught this live: `native-matrix (16/17/18)` all green, but
`docker-smoke` red on both the merge that landed item 35 and the *previous*
merge (PR #3) before it -- a pre-existing, recurring failure, not something
this session's own changes introduced. `scripts/smoke.sh`'s own log showed
the actual failing line every time: `curl: (23) Failure writing output to
destination`, immediately after `dashboard stayed responsive under
outbound load` and before one of the CSP-header assertions. The
`set -euo pipefail` script piped `curl` straight into `grep -q`/`grep -qv`
in three places; `-q` makes grep exit the instant it finds (or definitively
rules out) a match, closing its end of the pipe while curl may still be
mid-write, so curl gets a broken-pipe write failure (exit 23) for what was
actually a *successful* assertion -- and `pipefail` turns that broken-pipe
exit into a script failure regardless of what grep found. This is a
textbook `curl | grep -q` race, not a size limit or a real HTTP problem:
confirmed live by fetching the exact same responses with `curl | wc -c`
(reads to EOF, no early-exiting consumer) against a real running server --
same bytes, no failure, including the by-now-fairly-large `/api/v1/agents`
response. Fixed by capturing each response into a shell variable first
(`body=$(curl ...)`) and grepping the variable via a here-string
(`grep -q pattern <<<"$body"`) instead of a live pipe -- command
substitution waits for curl to fully exit before grep ever runs, so there
is no pipe left to race. All three occurrences in `scripts/smoke.sh` fixed
the same way; a repo-wide grep confirms no other script has the same
pattern.

**`agent_config`'s known integer keys had no value validation.** Item 35's
own `fn_set_agent_config` only ever checked that the whole value was a
JSON object -- `compaction_threshold: "not_a_number"` or
`min_mentions_to_route: 0` would both write successfully and only surface
as a runtime error the next time `maybe_trigger_compaction` or
`fn_messenger_post` actually cast the value with `::int`, mid-turn, on
whatever task happened to trigger it next -- exactly the "fails late
instead of fails fast" gap the review named. Fixed with
`allgres_private.validate_agent_config`, called from `fn_set_agent_config`
before the merge: for each of the file's own known integer-typed keys
present and non-null in the incoming config, it must be a whole number
within a sane range, or the write is rejected with a friendly error naming
the key -- the same "friendly rejection instead of a raw error" shape
`fn_set_agent_autonomy` already has for a bad `autonomy_level`. A key not
on this list is completely unvalidated and always was -- that is still the
entire point of `agent_config` being a generic bag rather than one column
per tunable; only names this file's own readers already cast get checked.

**Embedding-model mix-up: same dimension, different model, ranked as if
comparable.** `rank_agents_by_embedding` already refused to compare
embeddings of different *dimension* (item 35), but two different embedding
models can produce the same dimension while meaning something completely
different per axis -- switching the configured provider/model would have
silently started ranking an old embedding against a new query in an
incomparable vector space, with nothing about the shape of the data to
catch it. Fixed: `rank_agents_by_embedding` takes a new
`p_expected_model` parameter and only considers agents whose
`embedding_model` matches it exactly, in both the pgvector-accelerated and
brute-force paths. `fn_complete_outbound`'s `'embedding'` branch derives
the expected model from the *actual* call that was just completed
(`request_body->>'model'` plus that row's own `provider_id` looked up
against `llm_providers.name`) rather than re-querying "the" current
embedding provider, which could have changed between when the query was
queued and when it completed.

**Verified live**: `fn_selftest` grew from 149 to 153 cases (rejecting a
non-numeric and an out-of-range known key, confirming the rejected value
was never persisted, confirming an unknown key stays fully unvalidated,
and extending the ranking test with a same-dimension-different-model agent
that must be excluded even though it would otherwise rank first),
idempotent across repeated runs, on a fresh install both with and without
pgvector. `tests/e2e_mock.sql`'s real end-to-end round trip (item 35) still
passes both ways with the model filter in place, confirming the
provider-name/request-body-model reconstruction actually matches what
`fn_complete_agent_embedding` stamped onto `agents.embedding_model` in the
first place. The three fixed `scripts/smoke.sh` assertions were run
directly against a real live server (not just `bash -n`), each one
succeeding exactly as it should.

## 37. The same outside review's fourth finding: admin gating across `dashboard_rpc`'s platform-configuration actions was never consistent, just accidentally uniform until item 28 added real accounts

Item 28 layered a real login system (`users`, `session_tokens`, roles) on
top of a dashboard that had always been governed by one thing: possession
of the shared bearer token in `Authorization: Bearer ...`. Before item 28,
"logged in" didn't exist as a concept, so nothing in `dashboard_rpc` needed
to check it. After item 28, a handful of actions were updated to call
`require_admin(session_token)` -- but only the ones item 28 itself touched
directly (`users.*`, `assignments.*`) plus, later, item 32's
`require_admin_for_system_agent`, which is unconditional the instant its
target happens to be a system agent, and a no-op otherwise. Nothing ever
went back and gated the rest of the platform-configuration surface:
`agents.create`, `agents.update`/`policy.rollback`/`permissions.grant`/
`permissions.revoke`/`agents.set_autonomy` for an *ordinary* (non-system)
agent, `provider.create`, `provider.update`, `allowlist.add`,
`allowlist.remove`, and `providers.oauth_start`/`providers.oauth_callback`.
Every one of these was reachable by anyone holding the shared dashboard
token alone, with no relationship to whether that caller was logged in or
as what role -- confirmed by reading each branch in `dashboard_rpc`
directly, not inferred. A real gap between the accounts system and the
admin-only surface that predates it, not a deliberate two-tier design.

The fix cannot be a bare `require_admin` the way
`require_admin_for_system_agent` already is for a system-agent target:
that would break the deployment mode this whole accounts system was
always additive to (see `dashboard_rpc`'s own "Accounts, roles, ..."
section comment) -- a single-operator install that has never created a
user account at all, where the shared bearer token alone has always been
the entire security model and still needs to be enough on its own. Added
`allgres_private.require_admin_if_accounts_exist(p_token text)`: a no-op
if `allgres_private.users` has zero rows (accounts never configured --
preserves the historical single-operator behavior exactly), otherwise it
delegates to `require_admin`. Checked fresh on every call, not cached, so
the very next request after the first account is created is already
covered. Wired into every action named above; `agents.update` and its
sibling system-agent-target actions keep `require_admin_for_system_agent`
*alongside* the new gate, not replaced by it -- one call stays
unconditional the moment the target is a system agent, the other now also
covers an ordinary agent, but only once accounts exist. `users.*` and
`assignments.*` were deliberately left untouched: those were already
correctly strict (`require_admin` has no bootstrap fallback, which is
right for account management specifically -- the first admin account is
expected to be bootstrapped via direct SQL, not through the dashboard).

**Deliberately out of scope for this pass**: `run`, `sessions.cancel`, and
`sessions.continue` still have no session/scoping check at all and can act
on any `agent_id`/`session_id` regardless of `user_agent_assignments` --
a separate, arguably larger gap than what this finding named, left for a
follow-up rather than folded into this fix.

**Verified live**: `fn_selftest` grew from 153 to 160 cases -- a bootstrap
no-op check (`admin_gate_is_a_noop_before_any_account_exists`, run at the
one point in the whole suite where `allgres_private.users` is guaranteed
still empty, confirming `agents.create` still works with no session_token
at all before any account exists), the `agent_config`-on-ordinary-agent
case rewritten to reflect that it now needs an admin session once accounts
exist (its old premise, "no admin needed," stopped being true by design),
and five representative spot-checks across the newly gated actions
(`agents.create`, `provider.create`, `allowlist.add`, `permissions.grant`)
each confirmed rejected without a session and confirmed to actually take
effect with one. Idempotent across three consecutive runs on the same
database, on a fresh install both with and without pgcrypto and both with
and without pgvector. `tests/smoke.sql` and `tests/e2e_mock.sql` still pass
unchanged -- neither exercises any of the newly gated actions through
`dashboard_rpc` (the mock providers `e2e_mock.sql` needs are seeded via
direct `INSERT`, not `provider.create`), confirming this fix didn't need
to touch either script.

## 38. ~~`sql/control_plane.sql` has grown large enough to trip a real rustc compile-time safety lint~~ -- fixed by actually splitting the file

Adding semantic memory recall's schema/functions pushed `sql/
control_plane.sql` past a genuine limit: `pgrx`'s `extension_sql_file!`
macro embeds the whole file as a compile-time byte constant, copied one
byte per const-eval step, and the build started failing outright with
`error: constant evaluation is taking a long time` /
`#[deny(long_running_const_eval)]` -- rustc's own safety net against a
truly infinite const-eval loop, not a sign anything is logically wrong,
but a real signal the file's size was no longer just a maintainability
nice-to-have (an earlier outside review had already flagged the then-
~12,900-line file as worth eventually splitting by source unit while
keeping single-extension deployment, "not urgent"). First worked around
with `#![allow(long_running_const_eval)]` -- muting the lint, not fixing
the growth, and said so explicitly at the time.

Fixed for real the same day, in two passes: the file's own existing
structure already had 14 clearly numbered sections with a documented
dependency order, so no redesign was needed, only extraction along seams
that already existed.

**Phase 1** split into three files, always loaded together in this exact
order:

- `sql/control_plane.sql` -- sections 1-10 (roles through seed data), ~8.8k
  lines, down from ~13.7k.
- `sql/selftest.sql` -- section 11 (`fn_selftest`), ~3.4k lines on its own
  (it had been about a quarter of the original file).
- `sql/grants_and_facade.sql` -- sections 12-14 (grants, the allgres facade
  + `dashboard_rpc`, and the final ownership pass), ~1.6k lines.

The real wrinkle, worth recording for the next split: `pgrx` allows only
*one* `finalize`-marked `extension_sql_file!` in the whole crate (a second
one is a hard build error, caught immediately) -- section 14's ownership
pass is the one genuine "must run after literally everything" piece, so
only `grants_and_facade.sql` carries `finalize`; the other files are
"normal" position, ordered relative to each other with `requires = [...]`
(pgrx's `name = "..."` / `requires = ["that name"]` pair), which pgrx
enforces regardless of declaration order in `src/lib.rs`. `fn_selftest`
itself needed no special handling to move: it is `LANGUAGE plpgsql`, so
nothing inside its body is checked against the catalog until it is
actually called, long after every file has finished loading -- the same
forward-reference tolerance this codebase already relied on throughout one
file. The one real cross-file dependency was `REVOKE ALL ON FUNCTION
allgres_public.fn_selftest() FROM PUBLIC` living in the old section 12,
which needs the function to already exist (a `REVOKE` is not deferred the
way a plpgsql body reference is) -- moved into `selftest.sql` itself,
right after the function it revokes, so that file is fully self-contained
and the cross-file ordering concern disappears entirely rather than being
merely managed.

**Phase 2**, the same day: `sql/control_plane.sql` (still ~8.8k lines
after phase 1) was still large enough to be the file most likely to trip
the same lint again as it keeps growing, so section 9 (the operator API,
~2.9k lines -- by far the largest remaining section) and section 10 (seed
data) were split out too, along the same numbered-section seams:

- `sql/operator_agents_and_policies.sql` -- section 9a: agents, projects,
  policies, procedures, permissions, fixes.
- `sql/operator_runtime_and_integrations.sql` -- section 9b: sessions,
  schedules, providers, connections, OAuth, embeddings.
- `sql/operator_accounts_and_chat.sql` -- section 9c: approvals, allowlist,
  memories, accounts/auth, chat/messenger.
- `sql/seed_data.sql` -- section 10 (seed data) and 10b (extension
  configuration tables / `pg_extension_config_dump`).

`sql/control_plane.sql` itself is now sections 1-8 only, ~5.4k lines.
Seven files total now, chained with `requires` in their original numbered
order (`control_plane` → `operator_agents_and_policies` →
`operator_runtime_and_integrations` → `operator_accounts_and_chat` →
`seed_data` → `selftest` → `grants_and_facade`, `finalize` still only on
the last). All of section 9's split-out functions are `LANGUAGE plpgsql`
same as `fn_selftest`, so the same forward-reference tolerance applies;
section 10 turned out to have no real CREATE-time dependency on section 9
at all (it never calls an operator-API function, only raw `INSERT`/`DO`
blocks against tables sections 1-8 already created) despite being loaded
after it to preserve original file position.

`scripts/gen-upgrade.sh` (which used to `cat` `control_plane.sql` alone,
then all three phase-1 files) was updated again to concatenate all seven
files, in the same order, so `ALTER EXTENSION ... UPDATE` keeps installing
every operator-API function, seed data, `fn_selftest`, every grant, and
the dashboard facade -- not just sections 1-8.

**Verified live**: fresh `CREATE EXTENSION` after each split, with the
generated combined SQL inspected directly to confirm sections still land
in the original order (1 → schema creation → 9a → 9b → 9c → 10 → 11 → 12 →
14); representative functions from every new file (`fn_create_agent` from
9a, `fn_create_session` from 9b, `fn_create_user` from 9c, `fn_selftest`
from `selftest.sql`) confirmed owned by `allgres_owner` (not left at their
installing-superuser default), and `fn_selftest` confirmed to still have
`PUBLIC`'s `EXECUTE` privilege revoked -- the concrete things that would
have silently broken had the `requires` chain been wrong anywhere along
the seven-file chain, per the "Final ownership pass" comment's own account
of exactly this failure mode happening once before, pre-split. After each
phase: `fn_selftest` run three times consecutively (252/252 each time,
matching the pre-split count exactly) plus once more with a real admin
account present, `tests/smoke.sql`, `tests/e2e_mock.sql`, and `cargo test`
(30/30) all green. The build now succeeds with
`#![allow(long_running_const_eval)]` removed entirely -- confirming this
was the real fix, not a second mute alongside a smaller number.

## 39. A real-time "stop" button -- item 16's cancellation gap actually closed, plus the RPC contract frozen

Item 16 left one honest gap: `fn_cancel_session` stopped new work from
starting and fenced a stale result from being recorded, but could not
touch a call already executing -- an in-flight sandboxed SQL statement or
outbound HTTP/LLM request ran to completion (or its own timeout)
regardless of an operator hitting cancel. Closed for both halves,
separately, because they run on different threads with different
interrupt mechanisms.

**SQL sandbox half.** The obvious approach -- `fn_signal_cancel_worker()`
(new, owned by a new `allgres_signal_admin` role so the `pg_signal_backend`
grant it needs stays scoped to this one function instead of handed to
`allgres_owner` wholesale) calling `pg_cancel_backend()` against the
`allgres runtime` worker's own pid -- crashed the worker outright the first
time it was tried live. Root cause, found by direct minimal reproduction in
psql: plain PL/pgSQL `EXCEPTION WHEN OTHERS` does not trap a query
cancellation (`query_canceled`, SQLSTATE 57014) at all, no matter how it is
nested, so `fn_run_sandboxed_sql`'s own exception block never got a chance
to run. Fixed one level below plpgsql's own exception semantics: `src/lib.rs`'s
`run_in_subtransaction` mirrors what `BeginInternalSubTransaction`/
`RollbackAndReleaseCurrentSubTransaction` do internally in C, using pgrx's
`PgTryBuilder` (its own `PG_TRY`/`PG_CATCH` equivalent) to catch the
cancellation as a Rust-level error instead of letting it unwind into the
worker's top-level `pg_guard` and take the whole process down.

Two further layered bugs surfaced only once the crash was fixed and the
signal was actually being delivered:

- `allgres_signal_admin` is itself `NOLOGIN NOINHERIT` (same reasoning as
  `allgres_owner`/`allgres_role_admin` -- nobody connects as it directly), so
  a plain `GRANT pg_signal_backend TO allgres_signal_admin` granted
  membership without inheriting the privilege; a `SECURITY DEFINER` call
  running as that role could not actually signal anything until the grant
  was reissued `WITH INHERIT TRUE` (PG16+). Confirmed live via
  `pg_auth_members.inherit_option` flipping `f` → `t`.
- `statement_timeout` was not firing at all, independent of cancellation:
  `BackgroundWorker::transaction()`'s raw `StartTransactionCommand()`/
  `CommitTransactionCommand()` bypasses `tcop/postgres.c`'s per-query
  dispatch, which is what normally arms the timer in an ordinary client
  backend. `SET LOCAL statement_timeout` set the GUC value and nothing else
  -- confirmed live with a 30-second `pg_sleep` cross join that ran
  untouched past its configured 5s limit. Fixed by hand-declaring
  `enable_timeout_after`/`disable_timeout` (`utils/timeout.h`, not in
  pgrx's generated bindings -- outside its bindgen allowlist) and calling
  them directly around the sandboxed statement in `run_sandboxed_sql`.

**HTTP/LLM half.** A separate mechanism, because outbound calls run on the
runtime worker's HTTP thread pool, not its SPI thread, and "an HTTP thread
must never touch Postgres" (this module's own long-standing rule).
`OUTBOUND_CANCEL_FLAGS` (`src/outbound.rs`) is a `call_id -> Arc<AtomicBool>`
registry; `perform_http` registers one (RAII `CancelGuard`, removed on every
return path) and runs the request through `CancellableConnector`/
`CancellableTransport`, which wrap `ureq`'s own connector/transport and
slice every blocking read/write wait into 150ms steps, checking the flag
between slices. The main SPI-thread loop -- never the HTTP thread itself --
flips a flag to `true` once per tick, via `propagate_outbound_cancellations()`
calling `fn_check_lost_outbound` (new, `SECURITY DEFINER`, granted to
`worker`) to ask which of the registry's current call_ids `fn_cancel_session`
has since marked `'lost'` in `outbound_calls`, without needing to grant the
dropped-privilege worker role raw `SELECT` on that table.

**Verified live**, both halves, after learning the hard way that
`DROP EXTENSION`/`CREATE EXTENSION` does **not** reload an already-running
background worker's loaded `.so` -- only a full `service postgresql restart`
does, which is why several earlier test runs in this same effort produced
confusing (stale-binary) results before that was caught: a queued
sandboxed statement and a queued outbound call against a deliberately slow
mock endpoint, each cancelled mid-flight via `fn_cancel_session`, aborted in
roughly 60-75ms and 50-80ms respectively; the worker's own pid and
`backend_start` were unchanged afterward (no crash, no restart) in every
run; and `statement_timeout` was separately confirmed to fire on its own at
its configured 5s. `fn_selftest` covers the parts that do not need a live
process (`check_lost_outbound_returns_only_lost_ids`); the crash-safety and
signal-delivery claims above are the parts it structurally cannot, being
`SECURITY DEFINER` itself, which is why they are recorded here as live
verification rather than a selftest case.

**The RPC contract frozen, alongside this.** `dashboard_rpc`'s action set
had no enforcement against silent drift -- adding, removing, or renaming an
action was not a visible, deliberate act. `CONTRACT.md` now documents every
action's guard class; `scripts/gen_rpc_catalog.py` regenerates
`sql/rpc_catalog.json` from the live `CASE` statement; and `fn_selftest`'s
`dashboard_rpc_actions_match_frozen_catalog` case fails loudly if the live
dispatch and a hardcoded frozen array of all 82 action names ever disagree.
Two real, pre-existing bugs were caught while building this frozen
baseline, not introduced by it: `visible_agent_ids` returned `NULL`
(unrestricted, the same value a real admin gets) for "nobody is logged in"
unconditionally, rather than only before any account existed -- confirmed
live by reproducing the exploit (an unauthenticated `proposals.decide` call
silently overwriting an agent's `system_prompt`) and then confirming the
fix blocks it; and four `dashboard_rpc` actions
(`projects.create`/`.update`, `memories.create`/`.remove`) had no admin or
agent-access guard at all.

Also landed in the same effort, unrelated to any of the above:
`src/lib.rs` (2782 lines) split into nine focused modules (`sql_parser`,
`config`, `sandbox`, `outbound`, `rpc`, `runtime_worker`, `http_protocol`,
`web`, `tests`) by concern -- pure reorganization, verified equivalent by
identical `cargo test --lib` (30/30), identical `fn_selftest` count, and
identical `cargo clippy` lint count before and after (diffed directly via
`git stash`, confirming the split introduced no lints of its own).

## 40. Per-tool/per-procedure model override, and a self_improve-run canary experiment to find one

Before this, one agent's `policies.llm_config` was a single provider/model
for its *every* turn -- including a turn that exists only to process the
result of a fixed, narrow `procedure_tool` (a status ping, a canned lookup)
and hand it back as a sentence. There was no way to route that specific
turn to a cheaper model while the agent's own open-ended reasoning kept
using whatever it was actually configured for.

**The override itself.** `procedures` and `procedure_tools` each gained a
nullable `llm_override jsonb` column (`{"provider":"...","model":"..."}`,
the same two keys `sanitize_llm_config` already accepts). `fn_next_step`
resolves it only for the turn that immediately follows a procedure-bound
`call_tool`: if the most recent `execution_logs` row for the task is a
`'tool'` result carrying `procedure_tool_id` (stamped by `fn_submit_result`'s
`call_tool` branch when the call resolved through a procedure grant, and
carried into the log entry itself by `fn_complete_outbound` so no later
join is needed), that tool's own override wins, then its procedure's, then
the agent's own `llm_config` -- unchanged when none is set. Every existing
task with no such log entry behaves exactly as before.

**The canary.** A `model_experiments` row (`tool_id`, `candidate_provider`/
`candidate_model`, `canary_percent`, `status`) lets `fn_next_step` roll a
die for that specific turn only: `canary_percent`% of the time it uses the
candidate instead of the tool's current override/the agent default, and
stamps this turn's `outbound_calls` row with the `experiment_id` so its
outcome can be attributed. Only one `'running'` experiment per tool at a
time (a partial unique index). `outbound_calls` also gained `outcome`
(`'success'`/`'failure'`), filled in by `fn_complete_outbound` for any
`'llm'`-kind call tied to a `procedure_tool_id`: **a purely operational
signal, deliberately not a quality judgment** -- failure means the model's
own output was unusable (`unknown_action`, `payload_rejected`,
`final_answer_missing_answer`, or an exception in `fn_submit_result`
itself), success means anything else, including a `final_answer` nobody
would call especially good. No LLM grades another LLM's answer here; that
was a deliberate scope cut (see below), not an oversight.

**Who runs it.** Reuses the existing `self_improve` system agent (cost/
efficiency is already its whole job) rather than adding a new system agent
kind. `change_proposals` gained a `'tool_override'` kind and a
`target_tool_id` column, alongside the existing `'policy_change'`/
`'create_agent'`; `propose_change` with a `target_tool_id` present is
routed to an entirely separate validation path in `fn_submit_result`
(self_improve-only, same as cross-agent `target_agent_id` already was),
with three ops: `start_experiment` (rejected outright if one is already
`'running'` for that tool), `promote` (copies the still-running
experiment's candidate onto the tool's live `llm_override`, closes it),
`reject` (closes it, leaves the live override untouched) -- both `promote`/
`reject` require naming a `'running'` experiment on that exact tool, so a
stale or already-decided reference is rejected at propose time, not
silently reapplied. `fn_decide_proposal` gained the matching approval
branch; `start_experiment`'s approval is also where `baseline_success_rate`
is frozen -- computed once, from that tool's own prior (non-experiment)
call history, specifically so a later promote/reject decision compares
against a fixed number instead of one that keeps moving while the
experiment runs. Every step (start, promote, reject) is gated by
self_improve's own `autonomy_level` exactly like its existing agent-policy
proposals -- `admin_approval` by default, same as everything else in this
platform. `allgres.dashboard_rpc`'s new `tool_experiments.list` action (83rd
frozen action, `require_admin_if_accounts_exist`) gives an operator
read-only visibility into `sample_size`/`success_count`/
`candidate_success_rate` alongside `baseline_success_rate`, computed live
from `outbound_calls.outcome` rather than a maintained counter -- a plain
aggregate query is always consistent and never races a counter update.

**Deliberately cut from this pass, not forgotten:**
- **No LLM-judged quality score.** Considered and rejected: it would cost
  real tokens to run, and introduces "who judges the judge" -- the
  operational signal above is free and matches this platform's existing
  evaluation philosophy (`agent_success_rate_for_generation` also only
  ever asks "did the task complete", never "was the answer good").
- **No procedure-level experiment**, only a procedure-level *default*
  (the fallback an unset tool override falls through to). A procedure has
  no discrete "this turn was for procedure X" trigger the way a specific
  `call_tool` does, so there is nothing clean to attribute a canary
  outcome to at that granularity yet.
- **No SQL-execution cost signal** (`EXPLAIN`/`pg_stat_statements`) feeds
  into any of this. That measures database work, not how much reasoning
  the model needed to interpret a result correctly -- a different axis,
  and one `execute_sql`'s own real, measured latency could be added
  against later if it turns out to matter.

**Follow-up (same effort): three real gaps an outside review found, all fixed.**
`model_experiments` was never registered with `pg_extension_config_dump` --
the exact class of bug the backup/PITR drill above already found once for
a different table; a `pg_dump`/restore would have silently lost every
experiment's history. `start_experiment` accepted any `candidate_provider`
text with no check that it names a real, enabled `llm_providers` row --
`fn_bulk_set_model` already makes this exact check for its own provider
argument, this path just missed it; now checked at `start_experiment` and,
since an operator can disable a provider at any point while an experiment
is still running, re-checked at `promote` too (rejected outright rather
than silently promoting a dead provider into the tool's live
`llm_override`). And a canary-tagged `outbound_calls` row `fn_watchdog`
reclaims as `'lost'` (the worker never came back) never got an `outcome`
recorded at all -- the first fix for this only covered `experiment_id IS
NOT NULL` (the candidate side), which left `baseline_success_rate`
computed from the exact same column exposed to the identical hole from
the *other* direction; corrected to score every `procedure_tool_id`-tagged
row the same way, whichever side of the comparison it is on. Six new
selftest cases (302, up from 296); verified on both a fresh
`CREATE EXTENSION` and a rerun in the same database.

**Follow-up (same effort): `autonomy_level` now actually governs how much
of this is automated, tiered per op rather than uniform -- the three ops
are not equally risky (starting a small canary barely touches production
traffic, rejecting only ever reverts to the already-safe status quo,
promoting rewrites the tool's live default for everyone). The three
mutations (`start_experiment`/`promote`/`reject`) were factored out of
`fn_decide_proposal` into `allgres_private.apply_tool_experiment_*`
helpers so an autonomy-driven auto-apply (`fn_submit_result`) and an
admin's manual approval (`fn_decide_proposal`) run the identical code,
never two implementations that could drift apart.
- `admin_approval` (default): nothing auto-applies, unchanged.
- `self_approve`: `start_experiment` auto-applies only at
  `canary_percent <= 20` (a larger ask still queues); `reject` always
  auto-applies; `promote` always still queues -- self_approve is trusted
  to try small, cheap experiments and to back out of them, not to make
  the actual go-live call.
- `auto`: `start_experiment` auto-applies at any `canary_percent`;
  `reject` always auto-applies; `promote` auto-applies only when the
  experiment has reached its own `min_sample_size`, has a real (non-NULL)
  `baseline_success_rate`, and the candidate's live success rate is at or
  above it -- otherwise it falls through to the same admin queue an
  `admin_approval` agent would use (a disabled-provider failure inside
  the auto-promote attempt is caught the same way, falling through to
  the queue rather than erroring the whole turn out). This closes the
  "no minimum sample size enforced before promote" gap listed below as
  still open in the very same commit that introduced it -- auto-promote
  was the first caller that actually needed the floor enforced in code,
  not just documented as a risk.

Eight new selftest cases (310, up from 302) exercise every tier;
verified on both a fresh `CREATE EXTENSION` and a rerun in the same
database.

~~**Still open, on purpose:** no UI copy on `tool_experiments.list` stating
that `candidate_success_rate` is a format-validity signal, not a quality
judgment.~~ -- closed by the dashboard-panel follow-up further below, which
carries that exact caveat as the panel's own copy.

**Follow-up (same effort): the two tier thresholds are tunable, not
hardcoded, plus three named presets.** `self_approve`'s canary_percent
ceiling and `auto`'s promote rate floor were fixed at 20 and "candidate
>= baseline exactly" in the commit that introduced them -- reasonable
defaults, but a real operator's risk tolerance is a dial, not a fixed
point, and Claude Code's own multi-level permission model was the
concrete comparison raised for why this shouldn't be just three hardcoded
stops. Both are now `self_improve`'s own `agent_config` (the same jsonb
bag `compaction_threshold`/`min_mentions_to_route` already use, validated
in `validate_agent_config`):
- `tool_override_self_approve_canary_cap` (1-100, default 20): the
  `canary_percent` ceiling `self_approve` auto-starts under.
- `tool_override_auto_promote_slack_pct` (0-100, default 0): how many
  percentage points below `baseline_success_rate` `auto`'s own promote
  will still accept (0 = candidate must be at or above baseline exactly,
  the original behavior).

Continuous tuning is `fn_set_agent_config` directly (any value, not just
a preset). `fn_set_tool_override_autonomy_preset` adds three named
starting points on the same scale for an operator who does not already
have a number in mind: `conservative` (10, 0), `balanced` (20, 0, the
original defaults), `aggressive` (50, 5). New `dashboard_rpc` action
`agents.set_tool_override_autonomy_preset` (84th frozen action,
`require_admin_if_accounts_exist`) exposes the preset only -- an operator
who wants a value between or outside the three presets still calls
`fn_set_agent_config` with the exact numbers, same as any other
`agent_config` tunable.

Four new selftest cases (314, up from 310): an unknown preset name is
rejected, the `aggressive` preset writes both keys, a widened canary cap
changes `self_approve`'s own auto-start behavior, and a generous
`slack_pct` set directly (not through a preset) auto-promotes a candidate
that the default floor would have queued instead. Verified on both a
fresh `CREATE EXTENSION` and a rerun in the same database.

**Follow-up (same effort): the sticky-retry gap above is closed.** A
`build_llm_http` failure, a `fn_watchdog`-reclaimed timeout, or an
unparseable/invalid model response used to drop the override/canary
context entirely -- `fn_next_step` located the turn's context by looking
at the single most recent `execution_logs` row, and any of those failure
paths appends a `role='error'` row that then *became* "the most recent
row", silently falling back to the agent's own default model on retry
(a safe direction to fail in, but not a designed guarantee, and the
retried turn's outcome was never attributed to the running experiment
either way -- it just vanished from the sample in both directions).

`tasks` gained a nullable `tool_override_state jsonb` column: the frozen
`{procedure_tool_id, experiment_id, provider, model}` decision for the
turn currently in flight. `fn_next_step` now distinguishes a genuine retry
from a fresh turn by whether an `'error'` row exists *after* the last
`'tool'` result -- not by simply excluding `'error'` rows from the lookup,
which turned out not to be enough on its own: `fn_submit_result`'s
`llm_response` handling always logs the raw `'assistant'` content **and**,
if it doesn't parse, an `'error'` row at the *same* `step_number`, so a
naive `role <> 'error'` filter still landed on that raw assistant row
instead of the `'tool'` row underneath it. The fix excludes any
`step_number` that has an `'error'` row at all, not just `'error'` rows
themselves. Only when that check finds a genuine retry does `fn_next_step`
reuse the frozen decision (never re-rolling the canary die, never
re-reading since-changed `llm_override`/experiment config); a fresh
`call_tool` (no error after its own `'tool'` result) always re-resolves
from live config, exactly as before this fix.

Two new selftest cases (316, up from 314), on a fully isolated
tool/procedure/session so mutating the experiment's status couldn't
disturb the shared fixtures other cases in this item still depend on:
`retry_after_error_reuses_frozen_override_decision` (an unparseable
response is retried, the running experiment is rejected out from under
it, and the retry still returns the pre-rejection candidate model) and
`fresh_call_tool_breaks_stickiness_and_reresolves` (a genuinely new
`call_tool` on the same task afterward re-resolves from the now-rejected,
override-less live config instead of inheriting the stale cached
decision). Verified on both a fresh `CREATE EXTENSION` and a rerun in the
same database; `cargo test --lib`'s 30 cases are unaffected (SQL-only
change).

**Follow-up (same effort): a dashboard panel for both `tool_experiments.list`
and `agents.set_tool_override_autonomy_preset`.** Both existed only as
`dashboard_rpc` actions -- an operator could see canary experiments or
retune self_improve's autonomy dials only via raw RPC calls or `psql`, the
one genuine gap in an otherwise-UI-reachable feature. Settings gained a
"Tool model experiments" panel: a read-only table of every
`model_experiments` row (tool, candidate provider/model, canary percent,
status, sample size and success rate, baseline), self_improve's current
`tool_override_self_approve_canary_cap`/`tool_override_auto_promote_slack_pct`
values read straight from its own `agent_config`, and a preset selector
(`conservative`/`balanced`/`aggressive`) wired to
`fn_set_tool_override_autonomy_preset`. Verified live rather than only by
selftest: rebuilt, restarted postgres to load the new binary, confirmed
the panel's markup is actually served, and exercised both RPC actions over
HTTP the same way the dashboard's own JS calls them --
`tool_experiments.list` returns the expected shape and
`agents.set_tool_override_autonomy_preset` actually updates self_improve's
`agent_config`, visible again through `agents.list`.

## 41. Cost/usage budgets, closing the "deliberately not here" gap `schedules` carried since item 6

Prompted by an outside production-readiness review's P0 finding, verified
against the code first: `schedules`' own header comment admitted nothing
in this codebase parsed token usage out of an LLM response or priced a
provider/model, so a cost cap on a schedule would only ever compare
against a number nothing populated. For an agent running unattended
overnight on a schedule, that was named as the real accident path -- a
runaway or misconfigured schedule with no dollar ceiling, only `max_runs`/
`ends_at`.

**Usage.** `allgres_private.llm_usage_from_http(p_body)` is a sibling to
the existing `llm_text_from_http`: same two response shapes (OpenAI-
compatible `usage.prompt_tokens`/`completion_tokens`, Anthropic
`usage.input_tokens`/`output_tokens`), normalized to one shape, `NULL` --
not a jsonb of `NULL`s -- when neither is present. `fn_complete_outbound`
calls it only for a genuinely successful `'llm'` completion and stores the
result on `outbound_calls.prompt_tokens`/`completion_tokens`.

**Price sheet.** `allgres_private.llm_model_prices` (`provider_id`,
`model`, `input_price_per_1k`, `output_price_per_1k`) is a manual table an
admin maintains (`fn_set_model_price`/`fn_delete_model_price`, Settings'
new "Model prices" panel) -- there is no live pricing API this reads from,
by design; an unpriced model is invisible to every dollar figure this
feature computes, never silently treated as free. `cost_usd` on each
`outbound_calls` row is computed against whatever price was on file at
completion time and frozen there, so a later price edit can never reprice
a call that already happened -- the same reasoning `audit_log`'s
denormalized `username` snapshot already uses (item 40's own follow-up)
applied to a second, unrelated feature independently.

**Schedule attribution and the budget itself.** `sessions` gained
`schedule_id`, stamped by `fn_create_session` the moment
`fn_run_schedules`/`fn_run_schedule_now` spawns a session on a schedule's
behalf (nullable -- every other session, the dashboard's Run page
included, is completely unaffected). `schedules` gained `max_cost_usd`
(optional, same shape as `max_runs`) and `spent_cost_usd` (a running
total). `fn_complete_outbound` adds a completed call's own `cost_usd` into
its task's schedule, if any, and deactivates that schedule the instant
`spent_cost_usd` crosses `max_cost_usd` -- eagerly, in the same
transaction the cost was recorded in, not only the next time
`fn_run_schedules` ticks. `fn_run_schedules`/`fn_run_schedule_now` both
also check the same three stop conditions (`max_runs`/`ends_at`/
`max_cost_usd`) before firing, exactly the existing "honoured between
ticks, not just at create time" pattern `max_runs`/`ends_at` already had
-- `fn_run_schedule_now` needed the identical fix (it had never checked
`max_runs`/`ends_at` symmetrically with `fn_run_schedules` either, a small
pre-existing gap in the "Run now" button caught while wiring this through
it).

Deliberately not in this pass: a per-agent or per-session budget
independent of a schedule (every `cost_usd` this computes is queryable
directly for that today, just not enforced as its own stop condition); any
live pricing API integration (the price sheet stays something an operator
types in by hand, on purpose); and a `retry_safe`/`needs_operator`
classification for tool calls with real external side effects, a
different gap the same outside review named that this item does not
address.

Five new selftest cases (322, up from 317): `llm_usage_from_http` parses
both dialects and returns `NULL` for neither; a schedule-spawned call's
usage becomes a real `cost_usd` on the row and accrues into
`spent_cost_usd`; that crossing `max_cost_usd` deactivates the schedule
immediately, not just on schedule-list's own is_active bit; and an
unpriced model leaves `cost_usd` `NULL` and never accrues anything.
Verified on both a fresh `CREATE EXTENSION` and a rerun in the same
database; `cargo test --lib`'s 30 cases unaffected. Also verified live
over real HTTP end to end, not only via `fn_selftest`: created a real
provider and price via the dashboard RPC actions, created a schedule with
`max_cost_usd` set, fired it (`schedules.run_now`), confirmed the spawned
session carried the schedule's own `schedule_id`, completed a synthetic
`'llm'` outbound call for that task with a real `usage` block, and
confirmed the resulting `cost_usd`/`spent_cost_usd` matched the expected
arithmetic and the schedule deactivated itself in the same request --
`schedules.list` reflected all of it immediately afterward, exactly as the
dashboard's own Schedules panel (updated with a Cost column and a max-cost
field) would show it.

## 42. Secret key rotation, for real -- item 7 closed

Item 7 named the gap the day it was found and it sat open the longest of
anything in this file: changing `allgres.secret_key` made every existing
`enc:v1:` value silently undecryptable, and the only recovery was
re-entering every provider secret by hand. The same outside
production-readiness review that prompted items 40's follow-up and 41
named this the more urgent of the two remaining gaps once cost/usage
budgets landed -- a key that can't be rotated without an operational
incident isn't really rotatable at all.

`allgres_private.rewrap_secret(p_stored, p_old_key, p_new_key)` is the
building block: decrypts one `enc:v1:` value under an explicit old key and
re-encrypts it under an explicit new key, never touching the live
`allgres.secret_key` GUC, returning the value unchanged if it wasn't an
`enc:v1:` value to begin with (a plaintext fallback has nothing to
rotate) and `NULL` -- distinguishable from "nothing to do" only because
the caller already checked the prefix -- when decryption under the given
old key fails outright, never raising on a single bad row.

`allgres_public.fn_rotate_secret_key(p_old_key, p_new_key)` calls it
across every table that ever holds an `enc:v1:` value --
`llm_secrets.api_key`/`oauth_client_secret`/`access_token`/`refresh_token`,
`api_connection_secrets.api_key`, `oauth_device_sessions.device_code` --
in one transaction, and reports `{"rewrapped": N, "failed": M}` (`failed`
rows are left completely untouched, not corrupted or dropped -- a wrong
old key argument is a safe no-op per row, not data loss). Only the counts
are audited (`secrets.rotate_key`), never either key value.

Deliberately **not** wired into `dashboard_rpc`, unlike nearly everything
else mutating in this codebase (see README, "Everything the dashboard
does, `psql` can do too") -- both arguments to this function are the
actual encryption key, not a single credential the way `provider.update`'s
own `api_key` already flows through that same HTTP surface, and must never
transit it. `psql` only, by an operator who already holds both keys, same
posture as `ALLGRES_SECRET_KEY` itself always having been an environment
variable/`postgresql.conf` entry, never something sent over HTTP.

What this does not attempt: true zero-downtime rotation. This function
re-encrypts what's *stored*; the live `allgres.secret_key`
(`postgresql.conf`/`ALLGRES_SECRET_KEY`) still has to be updated and the
server restarted/reloaded as a separate step immediately after, and any
decrypt attempted in the window between those two steps fails closed the
same way an unset key always has. README's "Rotating the key" names this
window explicitly and says how to make it as short as operationally
possible (stop the runtime/web workers first, if a guaranteed zero-failure
window matters more than avoiding a restart) rather than overclaiming a
guarantee this single-function, no-external-coordinator design cannot
actually make.

Six new selftest cases (328, up from 322), gated behind pgcrypto actually
being installed (nothing to rotate otherwise) and using a
transaction-scoped `set_config` on the placeholder `allgres.secret_key`
GUC to stand up a real encrypted round trip regardless of what the
surrounding live database happens to have configured, reset back to empty
before anything later in the same run could be affected: a real secret
encrypts under an old key, `fn_rotate_secret_key` reports it rewrapped,
the value reads correctly under the new key, the same value genuinely
stops decrypting under the old key (a real rotation, not a second copy
left behind), and a wrong old-key argument is reported as failed while
leaving the stored value provably untouched. Verified on both a fresh
`CREATE EXTENSION` and a rerun in the same database; `cargo test --lib`'s
30 cases unaffected. Also verified live, across genuinely separate `psql`
sessions rather than only inside one `fn_selftest` transaction: created a
real provider with a real secret under one key, confirmed it decrypted,
rotated to a second key in a fresh session, confirmed the secret decrypted
correctly under the new key and no longer decrypted under the old one, and
confirmed the audit trail recorded only counts, never either key value.
Also confirmed directly that the `operator` role (a human's own direct
database access) can call this function while the sandboxed `worker` role
cannot, and that `dashboard_rpc`'s own dispatch has no branch that reaches
it at all -- the HTTP surface cannot trigger this regardless of role
grants, by construction, not just by omission.

## 43. A `'lost'` mutating outbound call pauses for a human instead of retrying blindly

The same outside production-readiness review, working down its own
priority list once items 41/42 closed: README's "External call
idempotency" already named the real risk -- a `'lost'` outbound call
(the worker crashed or a network drop, not a real HTTP response) is
genuinely ambiguous, it may already have executed on the destination --
but `fn_watchdog` fed every single one back to the agent as a plain
`{"type":"error","message":"outbound timeout"}`, identical to any other
failure. A `GET` or an `'llm'`/`'embedding'`/`'recall'` call has no
external side effect to duplicate, so retrying it is always safe; a
mutating `http_request` call (`POST`/`PUT`/`PATCH`/`DELETE`) does, and an
agent that just sees "error, try again" has every reason to reissue the
identical call -- the idempotency-key mitigation only helps if the
destination happens to honor it.

`fn_watchdog` now branches on `outbound_calls.kind`/`method` at the exact
point it reclaims a timed-out `'in_flight'` row: `kind <> 'tool'` or
`method = 'GET'` keeps the existing plain-error path unchanged, byte for
byte. Anything else -- a mutating `http_request` call -- instead pauses
the task (`tasks.status = 'waiting_human'`) and inserts a
`human_approvals` row explaining which call, which method, which URL, and
why, with a 24h `expires_at` the same as any other approval. This is
*not* a new mechanism: it is the identical `waiting_human`/
`human_approvals` shape `fn_submit_result`'s own `await_human` branch
already uses when the *agent itself* asks to pause, just triggered by the
watchdog instead of a model turn -- `fn_decide_approval` needed zero
changes to resume it correctly, and the dashboard's existing Approvals
tab renders it with no changes either (it already surfaces
`payload->>'reason'` generically for any pending approval, whoever
created it).

What this still cannot do, and does not claim to: know whether the call
actually executed. Only checking the destination system answers that; an
operator (or the agent, once resumed with the operator's reply as
context) still has to make that call. The fix is about who gets asked --
a human before any retry, instead of nobody until a duplicate side effect
already happened -- not about resolving the ambiguity itself, which no
information inside this database can resolve on its own.

Three new selftest cases (331, up from 328):
`watchdog_lost_get_call_still_reports_plain_retryable_error` (the
existing behavior, unchanged, for the safe case), `watchdog_lost_
mutating_call_pauses_for_human_instead_of_retrying` (a lost `POST` pauses
the task and records the right reason/call-id instead of logging a plain
error), and `ambiguous_outbound_approval_resumes_task_normally` (approving
it resumes the task through the ordinary `fn_decide_approval` path, no
special-casing needed). Verified on both a fresh `CREATE EXTENSION` and a
rerun in the same database; `cargo test --lib`'s 30 cases unaffected. Also
verified live over real HTTP end to end: created a real task, simulated a
lost `POST` outbound call directly, ran `fn_watchdog`, confirmed
`approvals.list` surfaced the exact reason text with no dashboard changes
needed, and confirmed `approvals.decide` resumed the task
(`status = 'queued'`) the normal way.

## 44. A no-restart install path -- `allgres.reloadable` and dynamic background workers

Both workers (`allgres runtime`, `allgres web`) are registered from
`_PG_init`, gated on `process_shared_preload_libraries_in_progress` --
legal only during preload, which is why installing onto an already-running
PostgreSQL server has always meant `shared_preload_libraries = 'allgres'`
plus a full restart (a plain reload does not re-run preload processing).
Raised as a direct operational question, not a review finding: an operator
who cannot get a restart window onto the server they're installing onto
has had no path in at all.

PostgreSQL has a second, un-taken registration path for exactly this:
`RegisterDynamicBackgroundWorker`, callable from any ordinary backend, no
preload involved -- the same mechanism `pg_cron` and similar extensions use
for on-demand workers. `runtime_worker_builder()`/`web_worker_builder()`
(`src/lib.rs`) now build the identical `BackgroundWorkerBuilder`
configuration either way; `_PG_init` still finishes with `.load()`, and the
new `allgres.native_start_dynamic_workers()` finishes with
`.load_dynamic()` instead. `allgres_public.fn_start_dynamic_workers()`
wraps it, gated on a new placeholder GUC (`allgres.reloadable`, exactly the
`allgres.secret_key` pattern -- no `DefineCustomStringVariable`, no preload
needed to read it): `CREATE EXTENSION allgres;` with `allgres.reloadable =
on` set, then one call, and both workers are running -- no restart, ever,
for the initial install.

Two real gaps found and fixed while wiring this up, both caught live before
they ever shipped:

- Reading `shared_preload_libraries` (to refuse cleanly when `allgres`
  actually is preloaded, rather than fight the postmaster for ownership of
  the same worker names) needs `pg_read_all_settings` membership -- a PG14+
  restriction; a plain `current_setting()` on it raises "permission denied
  to examine..." for any role that isn't a member. Checking whether
  `allgres runtime` is already running (so a second call is a no-op, not a
  duplicate launch) needs `pg_read_all_stats` too -- without it,
  `pg_stat_activity` doesn't error, it silently returns *zero rows* for any
  backend belonging to a different user, which is worse: this was caught
  live by the exact failure it was supposed to prevent -- a second call to
  `fn_start_dynamic_workers()` believed nothing was running and launched a
  real duplicate pair of workers alongside the first, still-alive one.
  Fixed with a new role, `allgres_settings_reader` (`NOLOGIN NOINHERIT`,
  same shape as `allgres_signal_admin`), holding both memberships `WITH
  INHERIT TRUE` (PG16+ syntax -- a NOINHERIT role's own memberships are
  invisible even to itself without it) and owning nothing but
  `fn_start_dynamic_workers` -- neither broad-read privilege reaches
  `allgres_owner`, and therefore not the many other `SECURITY DEFINER`
  functions it owns either.
- The project's own two-pass ownership-fixing convention (`sql/
  grants_and_facade.sql`, "12. Grants" and its later re-run in "14. Final
  ownership pass" -- the second exists specifically to catch native
  functions pgrx splices in after the first pass already ran, item 32's own
  precedent, `native_host_stats`) has an exclusion list in *each* pass
  for functions with a narrow, non-`allgres_owner` owner
  (`fn_provision_agent_role`, `fn_signal_cancel_worker`). Adding
  `fn_start_dynamic_workers` to only the first list left the second pass
  silently reassigning it straight back to `allgres_owner` moments later --
  caught live the same way as the grant gap above, by the function raising
  the exact permission error the new role was supposed to prevent. Both
  lists needed the addition, not one.

Two new selftest cases (333, up from 331) cover what a `shared_preload_
libraries = 'allgres'` cluster (every CI run, the Docker image) can
actually reach: `dynamic_start_refused_when_reloadable_not_on` and
`dynamic_start_refused_when_already_preloaded`. The dynamic launch itself
is not reachable from inside `fn_selftest` on such a cluster by
construction, so it was verified live instead, against a real, separate,
non-preloaded cluster stood up for exactly this: `allgres.reloadable = on`
set, `CREATE EXTENSION` with no `shared_preload_libraries` entry,
`fn_start_dynamic_workers()` returning real PIDs for both workers, the web
worker actually answering `curl` on its configured port, a second call
correctly reporting `already_running: true` with no duplicate processes,
and the `off`/`preloaded` refusal cases confirmed on that same cluster and
the normal preloaded one respectively. Verified on both a fresh `CREATE
EXTENSION` and a rerun in the same database; `cargo test --lib`'s 30 cases
unaffected (Rust-only refactor of the builder setup, no behavior change to
the static path).

Not solved, by design (README, "Installing without a restart"): a dynamic
registration does not survive a full PostgreSQL restart, for any reason --
nothing persists it anywhere, unlike `shared_preload_libraries`, which the
postmaster re-reads and re-registers from on every start. There is no
watchdog that notices and re-calls `fn_start_dynamic_workers()`
automatically; that stays the operator's own step, after install and again
after every subsequent restart. A crash of either worker *without* a full
restart still self-heals exactly like the static path does, though -- the
postmaster's restart timer is honored the same way regardless of which
registration method started the worker.

## 45. CNPG (CloudNativePG) deployment via Image Volume Extensions -- not verified live

README's own "Not yet built" list named Helm charts, Kubernetes manifests,
and CNPG support as a flat gap. Raised as a direct request: don't build a
whole custom CNPG operand image the classic way (`FROM ghcr.io/
cloudnative-pg/postgresql:...`, `COPY` allgres in, replacing what CNPG
actually runs) -- CNPG's newer Image Volume Extensions mechanism lets
allgres ship as its own small extension-only image instead, mounted
read-only alongside the *unmodified* official operand image, so there is
nothing of CNPG's own release cadence to keep this image in sync with.

`cnpg/Dockerfile` builds that extension image: a `cargo pgrx package`
build stage FROM the exact CNPG operand image being targeted (so the
compiled `.so` links against that image's own libpq/postgres internals,
not a generic `postgres:18` build that could silently mismatch), then a
`FROM scratch` final stage carrying only `allgres.so` (`/lib/`) and the
`.control`/`.sql` files (`/share/extension/`) -- the exact layout CNPG's
own `postgres-extensions-containers` repo's `pgvector` image uses, read
directly from that repo rather than guessed. `cnpg/cluster-example.yaml`
wires it up: `Cluster.spec.postgresql.extensions` mounts the image,
`Cluster.spec.postgresql.shared_preload_libraries` is *still* required
separately (allgres's two background workers need preload-time
registration same as ever; the image-volume mechanism only makes files
discoverable, it doesn't touch `shared_preload_libraries` for you), and a
companion `Database` CR's `spec.extensions` is what actually runs `CREATE
EXTENSION allgres;`.

Requires PostgreSQL 18+ (the mechanism needs a preload-time GUC CNPG
contributed upstream for locating extension files, only present from
PG18) and Kubernetes 1.33+ (`ImageVolume` feature gate, default-on from
1.35).

Not verified end to end against a real running cluster: this environment
had no Kubernetes cluster to apply the CR against. The image build itself
*has* been tested for real since, though (not by this environment, which
had no Docker daemon either) -- two rounds:

- The one assumption flagged at the time (that the CNPG operand image's
  own apt sources carry `postgresql-server-dev-${PG_MAJOR}`, not just the
  prebuilt `postgresql-${PG_MAJOR}-pgvector` package `pgvector`'s own
  Dockerfile installs) held up: `apt-get install` for it succeeded.
- The actual failure hit was a build-context mistake: `COPY . .` only ever
  sees the build *context*, and building with `cnpg/` itself as the
  context (rather than the repo root) copies just that directory's own two
  files, so `cargo pgrx package` fails with "could not find `Cargo.toml`"
  -- a real, easy mistake given the Dockerfile lives in a subdirectory.
  Fixed with an explicit `test -f Cargo.toml` check right after `COPY . .`
  in `cnpg/Dockerfile`, so this now fails immediately with a clear message
  naming the fix (`docker build -f cnpg/Dockerfile .` from the repo root)
  instead of surfacing as a confusing `cargo-pgrx` internal error. README's
  own build instructions gained the same warning inline.

The built image is now published to GHCR too
(`ghcr.io/rayjun0525/allgres-cnpg-ext`), same `publish-image.yml` workflow
and same native-per-arch-then-merge shape as the plain-Docker image, so
using it no longer requires building it locally at all.

A second real-testing round, applying `cnpg/cluster-example.yaml` against
an actual cluster, hit the next real prerequisite gap: the CNPG operator
itself wasn't installed, so `kubectl apply` failed with "no matches for
kind Cluster in version postgresql.cnpg.io/v1 -- ensure CRDs are installed
first" -- `Cluster`/`Database` are CRDs the operator registers, not
built into Kubernetes itself. Neither the example file nor this README
said so anywhere. Both now document the one-line Helm install
(`helm upgrade --install cnpg --namespace cnpg-system --create-namespace
cnpg/cloudnative-pg`, after `helm repo add cnpg
https://cloudnative-pg.github.io/charts`) as an explicit prerequisite.

With the operator installed, two more real findings from the same testing
round:

- **Runtime requirement, not just a Kubernetes version**: the `Cluster`'s
  `bootstrap-controller` init container failed with `Error response from
  daemon: invalid volume specification: ':/extensions/allgres:ro'` --
  that exact wording is Docker Engine's (`dockerd`), not containerd's or
  CRI-O's. `ImageVolume` is a CRI feature only containerd 2.1+ and CRI-O
  1.31+ implement; Rancher Desktop's `dockerd` (moby) container engine
  does not support it at all, and there is no workaround for that short
  of switching Rancher Desktop's engine to containerd. README and
  `cnpg/cluster-example.yaml` both now call this out explicitly rather
  than only listing a Kubernetes version.
- **A personally-pushed image is private by default**: after switching
  engines, the next failure was `403 Forbidden` pulling a build pushed to
  a personal GHCR namespace (`ghcr.io/<user>/allgres:...`) -- GHCR
  packages default to private, and an anonymous Kubernetes pull has no
  credentials to authenticate with. Since `ghcr.io/rayjun0525/allgres-
  cnpg-ext` (this repo's own published image, added the same day) is
  confirmed public and multi-arch (`docker buildx imagetools`/an
  anonymous-token `curl` both checked it), pointing at that instead of a
  personal build sidesteps this rather than needing to fix package
  visibility. Note it currently only carries a `:main` tag (no version has
  been tagged yet), not `:latest` -- README and the example file corrected
  to say so.

Still open: whether the `Database` CR's `CREATE EXTENSION allgres;` step
and the dashboard's actual runtime behavior are correct once reachable --
verification against a properly configured (containerd) runtime and the
community operand image is in progress.

## 46. The dashboard's "Connect via OAuth" button never worked for the seeded `xai_oauth` device-code provider

Raised as "there's nothing about where/how to connect" for the OpenAI/xAI
OAuth providers. The SQL side was already complete and already documented
as working (README, "Secrets at rest": "the dashboard displays xAI's
verification link") -- but `web/index.html`'s `providerModal` only ever
called `providers.oauth_start`, the authorization-code redirect flow.
`fn_oauth_start` itself rejects a device-code provider outright (`RAISE
EXCEPTION 'provider uses device-code oauth'`), and the dashboard had no
call to `providers.oauth_device_start`/`providers.oauth_device_status`
anywhere (confirmed by grep before fixing -- zero matches). So clicking
Connect on the seeded `xai_oauth` provider -- the only oauth-kind provider
seeded out of the box -- always failed with that exact backend error, with
no path to complete it from the dashboard at all. This was pure doc lag:
the backend (`fn_oauth_device_start`/`fn_oauth_device_status`, both already
wired into `dashboard_rpc`) and the README description were both correct;
only the dashboard's own JS never called them.

Fixed by branching `providerModal` on `p.oauth_flow==='device_code'`:
that path now calls `providers.oauth_device_start`, then polls
`providers.oauth_device_status` every 2-3s, showing the returned
`verification_uri`/`user_code` once the session reaches `awaiting_user`
and a final "Connected."/failure message once it reaches `connected` or a
terminal failure status (`denied`/`expired`/`error`). The pre-existing
authorization-code path is unchanged, but now also shows the exact
`redirect_uri` (`location.origin+location.pathname`) an operator must
register with their own OAuth app -- previously computed only in client-
side JS an operator would have had to read to find out, which was the
other half of "where/how to connect."

There is still no dashboard path to set `oauth_flow`/`oauth_device_url`
for a custom provider added via "Add provider" -- `fn_create_provider`/
`fn_set_provider` only ever accept authorization-code fields
(`oauth_auth_url`/`oauth_token_url`/`oauth_client_id`/`oauth_client_secret`);
device-code flow only exists for the seeded `xai_oauth` row today. Not
fixed here, since no second real device-code provider exists yet to design
that surface against.

`openai`'s own provider row is seeded `kind='openai_compat'`, not
`'oauth'` -- OpenAI does not publish a public device/authorization-code
OAuth flow for direct API access the way xAI does for Grok CLI, so there
is deliberately no "openai oauth" to connect: the `openai` provider is
configured with a plain API key, same as `anthropic`/`ollama`/
`openai_compat`. Verified via a fresh `fn_selftest()` run (`"failed": 0`)
after the `web/index.html` change; no SQL changed, so no rebuild/reinstall
cycle was needed for this fix.

## 47. A real "Test connection" and fetched model list for LLM providers, closing the is_enabled-vs-actually-reachable gap

Raised directly after item 46's OAuth fix: `is_enabled` in the providers
list was the only signal an operator had for whether a provider actually
works, and it only ever meant "an operator turned this on" -- a typo'd API
key, a wrong base URL, or a provider that has since started rejecting the
stored credential all still showed the same green-ish "running" badge as a
provider that genuinely answers. Separately, every Model field (agent
editor, bulk-apply-to-all-agents, model prices) was pure free text with no
way to see what models a provider actually serves -- an operator had to
already know or go look it up externally.

Both gaps share one real fix: an actual `GET {base_url}/models` (`/v1/
models` for `anthropic`, matching `fn_dispatch_tasks`' own URL shape for
that kind) against the provider's own listing endpoint, queued the same
way the OAuth device-flow calls in item 46 are (no `task_id` -- a dashboard
action, not an agent turn), and claimed by the same runtime worker HTTP
pool everything else uses. OpenAI, xAI, and Anthropic's `/models`/`/v1/
models` endpoints all return the identical `{"data":[{"id":...}]}` shape,
so one parse in `fn_complete_provider_probe` covers every seeded kind. A
2xx response is both a live-reachability signal (`last_probe_status='ok'`)
and a model list (`available_models`) at once; anything else is stored as
`last_probe_status='error'` with the response body (or a transport error)
as `last_probe_error`, without touching a previously-fetched model list --
one bad probe should not make a working model list disappear.

New: `allgres_private.provider_probes` (queued/claimed/completed exactly
like `embedding_calls` -- no `task_id`, not registered for `pg_dump`, same
precedent as `embedding_calls` itself: re-triggerable at will, nothing an
operator needs preserved across a restore); `llm_providers.last_probe_
status`/`last_probe_at`/`last_probe_error`/`available_models`;
`fn_provider_probe_start`/`fn_claim_provider_probe`/
`fn_complete_provider_probe`, and dashboard_rpc actions `providers.
probe_start`/`providers.probe_status` (`sql/rpc_catalog.json` regenerated,
`sql/selftest.sql`'s frozen-catalog arrays updated, both in the same
commit per this project's own contract). A new `OutboundQueue::
ProviderProbe` variant in `src/outbound.rs`/`src/runtime_worker.rs` mirrors
`AgentEmbedding` exactly, with one difference: the queued call's `kind` is
forced to `"tool"` (not left at `perform_http`'s `"llm"` default), because
a probe is a plain GET with no body, and the default branch for anything
that isn't `"tool"`/`"oauth"` always sends a JSON-POST body.

Verified with the full loop: `cargo pgrx install` (PG16), fresh
`DROP EXTENSION`/`CREATE EXTENSION`, `fn_selftest()` 333/0 on two separate
connections (including `dashboard_rpc_actions_match_frozen_catalog`
specifically), `cargo test --lib` 30/30. Then live, against the actual
`allgres runtime` background worker (not just `fn_selftest`, per this
project's own rule for anything touching a new external call) -- caught a
real test-setup mistake in the process, not a code bug: the worker
connects to `ALLGRES_DATABASE` (default `postgres`), not whatever database
`psql` happens to be pointed at, so a first round of manual testing against
a different database never got claimed at all (looked identical to the
worker silently doing nothing). Once corrected, a local mock HTTP server
returning `{"data":[{"id":"mock-model-a"},{"id":"mock-model-b"}]}` on `/v1/
models` confirmed the full success path end to end (`last_probe_status`
`'ok'`, `available_models` populated, table row `harvested`) and the
failure path (a 404 on a wrong path: `last_probe_status` `'error'`,
`last_probe_error` `'not found'`, previous `available_models` left
intact). Also probed the real `anthropic` provider with no stored key:
correctly built `https://api.anthropic.com/v1/models` and reported a real
transport failure (`io: invalid peer certificate: UnknownIssuer` -- this
sandbox's own egress proxy, not a bug) as `last_probe_status='error'`
rather than crashing or hanging, which is exactly the failure-handling
this was meant to guarantee.

## 48. Chat had no way to change provider/model inline -- only a separate "My Agents" page did

Raised directly: "채팅쪽에서도 모델을 자유롭게 바꿀 수 있게" (let Chat change the
model freely too). `fn_set_my_model`/`agents.set_my_model` already existed
and already let any user (admin included, via `require_agent_access`'s
admin bypass) repoint an agent they can reach at a different provider/
model -- but the only place that surface was wired up in the dashboard was
the regular-user-only "My Agents" page, a separate screen from the actual
conversation.

Added the same Provider/Model row (a `<select>` + a model `<input>` backed
by the same `available_models` datalist item 47 introduced, + Save) inline
above the message thread in Chat's General mode (the seeded `general`
agent) and Project mode (whichever agent that project is bound to) --
`chatModelPicker`/`wireChatModelPicker` in `web/index.html`, shared by
both since each mode always talks to exactly one agent. Messenger mode
stays without one: a mention can route to any of several agents, so there
is no single agent to point a picker at. Project mode's picker needed
`agents.mine` fetched there too (previously only General mode called it) --
`require_project_access`'s own comment already established that a
project's bound agent must be assigned to the user the same way General
mode's agent is, so it is always present in that same list, no separate
lookup required.

No SQL changed -- pure `web/index.html` UI wiring onto an existing,
already-tested backend function. Verified live: rebuilt, reinstalled,
restarted the cluster, then in a real browser (Playwright) against the
actual dashboard -- picked `anthropic`/`claude-sonnet-5` for the `general`
agent from Chat's General mode, saved, reloaded the page from scratch, and
confirmed the choice was still there (a real `fn_set_my_model` write, not
just client-side state); then switched to Project mode and confirmed the
same project-bound agent's saved provider/model shows there too. `fn_
selftest()` 333/0 on two separate connections (unaffected, as expected for
a web-only change).

## 49. Link visibility and a small design pass after a full page sweep

Raised alongside item 48's own spacing regression: "다른곳들도 확인해줘. 그리고
링크 같은것들 가시성도 안좋아" (check the other pages too, and link visibility
is bad). Swept every page (Overview, Agents + its edit modal, Chat's three
modes, Approvals' three tabs, Projects + its New project modal, Run,
Memories, Audit's four tabs, Settings' full scroll) with real screenshots
against the live dashboard -- confirmed no other instance of item 46's
"row touching the panel below it" pattern (already fixed everywhere it
existed), so this narrowed to two real, scoped gaps:

- **No `a` rule existed at all.** The one real link in the app (the
  device-code flow's verification URL, item 46) fell back to the browser
  default blue/purple, which does not match this app's own palette at
  all and reads poorly against the dark theme. Added `a{color:var(
  --accent2)}` (`a:hover` underlines, `a:visited` stays the same color --
  a login-gated internal tool has no reason to fade a previously-opened
  link) using the same `--accent2` token already defined for both themes;
  computed WCAG contrast confirms it clears AA comfortably against both
  the dark (`5.92:1`) and light (`4.74:1`) background.
- **Flat, borderless list rows and panels.** Added a subtle `.table
  tbody tr:hover{background:var(--panel2)}` (list scanability -- Apple's
  own store page, given as a loose reference, uses hover feedback
  throughout, though nothing here approaches copying its visual language)
  and a soft `box-shadow` on `.panel`/`.dialog` for a touch of depth
  instead of perfectly flat cards.

Deliberately did **not** touch the primary-button/badge `--accent` token
itself, despite it measuring under WCAG AA (`3.56:1`) for normal-weight
white-on-accent text: `.btn.primary` is bold (`font-weight:650`), which
places it under WCAG's large-text threshold (`3:1`) instead, where it
passes; darkening `--accent` to fix that ratio would only trade it for a
worse one against the dark background everywhere `--accent` is used as a
foreground color instead (status text, the online dot) -- not a genuine
gap the way the missing `a` rule was, and `web/index.html`'s own comment
on this override layer ("Keep this override separate ... so future
refactors cannot accidentally reintroduce neon accents") is a deliberate
guardrail against exactly this kind of speculative palette change.

No SQL changed. Verified: rebuilt, reinstalled, restarted the cluster,
`fn_selftest()` 333/0 on two separate connections, `cargo test --lib`
30/30, and the link/hover/shadow changes checked visually in a real
browser (Playwright) -- a link injected into the actual running page (the
real device-code path needs live xAI network access this sandbox's own
egress policy blocks, per item 46/47) renders in the new color, and an
Agents-table row hover shows the new background.

## 50. README split into docs/, and Quick start rebuilt around three real install paths

Raised as two related complaints: "왜 도커 컴포즈로 올려? 도커이미지 하나면
되는거 아니야?" (why docker-compose, isn't one image enough?) and "리드미가
논문수준이야" (README reads like a paper). Both were accurate.

**Docker-compose vs. a single image.** `Dockerfile` already builds one
self-contained image (official `postgres:17-bookworm` plus the extension
baked in, one `ENTRYPOINT`) and `docker-compose.yml` already runs exactly
one service — there was never a real multi-container architecture here.
Compose's actual job is declaring ~10 env vars, two port mappings, and a
named volume without a long `docker run` line, plus letting
`docker-compose.prod.yml` layer production hardening on top without
hand-editing the base file. But the documented Quick start defaulted to
`git clone` + `./scripts/bootstrap.sh` (a local `docker compose build`)
even though a pre-built image was already published to GHCR — a real
`docker pull`/`docker run` one-liner existed only as a secondary mention
deep in "Docker install, in detail." Fixed by making that one-liner the
lead path in the new Quick start (see below), with the scripted/verified
`docker compose` flow kept as the documented alternative for anyone who
wants `scripts/bootstrap.sh`'s own end-to-end proof (a real admin, a real
agent task run to completion) instead of just a running container.

**README length.** 1777 lines across 24 sections, mixing a newcomer's
"how do I start" with deep internals (the SQL sandbox's parse-tree gates,
the full security model, backup/restore two-pass restore mechanics, and
so on). Split into `docs/` (14 topic files) plus `docs/deployment/`
(docker.md, source-install.md, cnpg.md) — one file per subject, each
starting with "Part of the [documentation index](../README.md)" and
cross-linking the others where the original README's own prose already
did. `README.md` itself dropped to intro + a **three-path Quick start**
(Docker/Source/CNPG, RPM intentionally not added yet — explicitly
deferred by request) + a condensed feature list + a documentation table
linking every `docs/*.md` file + Known limitations (still a KNOWN_ISSUES.md
pointer) + License: 1777 lines to 188, with the actual content preserved
in `docs/`, not deleted (1828 lines total across `docs/*.md`, roughly
matching the original once cross-link scaffolding is subtracted).

Every internal markdown link across `README.md`/`docs/**/*.md`/
`SECURITY.md`/`CONTRACT.md`/`CLAUDE.md`/`KNOWN_ISSUES.md` was checked
programmatically (a small script resolving each `[text](path#anchor)`
against the actual file tree and each target file's real headings) --
0 broken links/anchors across 21 files. `SECURITY.md`'s three literal
`README.md#security-model`/`#exposure` links (the only literal
cross-file anchors outside README.md itself) were repointed to
`docs/security.md`; its `README.md#known-limitations` link needed no
change, since that heading stays in README.md itself. `CLAUDE.md`'s own
doc-maintenance guidance was updated to point future changes at the
matching `docs/*.md` file instead of "the relevant README section," since
that section mostly no longer exists in README.md.

No SQL or Rust changed -- pure documentation reorganization. Not run
through `fn_selftest()` for that reason (nothing it exercises reads these
files), but `make install`/`make quickstart` and the Docker `docker
pull`/`docker run` one-liner in the new Quick start were checked against
this project's own actual `Dockerfile`/`docker-compose.yml`/`src/*.rs`
defaults (`ALLGRES_ALLOW_INSECURE_HTTP` must be exactly `"1"`,
`ALLGRES_DATABASE` defaults to `postgres` same as the runtime worker's own
`DEFAULT_DB`) rather than assumed.

## 51. `make install` failed with a bare "failed to compile cargo-pgrx" on a machine with no C toolchain

Raised directly, already correctly self-diagnosed: "make, gcc가
안깔려있으면 동작을 안하니까 사전에 설치해야하는 패키지 리드미에 추가하고"
(if make/gcc aren't installed it doesn't work -- add the prerequisite
packages to the README). The actual failure:

```
warning: build failed, waiting for other jobs to finish...
error: failed to compile `cargo-pgrx v0.19.2`, intermediate artifacts can
be found at `/tmp/cargo-install4sAZof`.
make: *** [Makefile:46: build] Error 101
```

Root cause: the `Makefile`'s `check` target only ever verified `pg_config`
was on `PATH` -- it said nothing about a C toolchain. `build`'s `cargo
install --locked cargo-pgrx` (before it ever reaches this extension's own
source) needs one anyway: `cargo-pgrx` depends on `bindgen` for Postgres
FFI generation, which needs `libclang` specifically, and several of its
other dependencies need a plain C compiler for their own `build.rs`.
Neither the `Makefile` nor `docs/deployment/source-install.md` (nor
README.md's own Quick start, pre-item-50-split) ever named these as
prerequisites -- only `pg_config`/the `-server-dev` package was mentioned,
so a machine with PostgreSQL's dev headers but no general-purpose build
tools hit this exact wall. The repo-root `Dockerfile` and `cnpg/Dockerfile`
already knew the real list (`build-essential clang libclang-dev
pkg-config`) -- they just never fed it back into the docs read by anyone
installing straight onto their own machine.

Fixed two ways:

- **Fail fast with a clear message.** `Makefile`'s `check` target now also
  verifies `cc`/`gcc` and `clang` are on `PATH`, each with its own
  `$(error ...)` naming the missing tool and the exact `apt install`
  line -- the same "catch the mistake here, with a real message, instead
  of inside cargo-pgrx with a much less obvious one" pattern
  `cnpg/Dockerfile`'s own `Cargo.toml` existence check already uses (see
  item 45's own entry). Verified live: with `PATH` narrowed to a
  directory holding nothing but `pg_config` (`/tmp/fake-path`, wired to
  the real one via a wrapper script) and `PG_MAJOR` forced so the
  `pg_config`-detection shell calls themselves (which need `tail`, not
  reachable in that narrowed `PATH`) weren't what was under test, `make
  check` correctly errored on the missing compiler, then on missing
  `clang` once a bare `cc` was added back, then passed clean once both
  were restored -- three separate runs, one per state.
- **Document it.** README.md's Quick start "Source" path and
  `docs/deployment/source-install.md` both now list the C toolchain
  alongside the `-server-dev` package as a prerequisite, naming the exact
  Debian/Ubuntu packages and pointing at `make check`'s own new fast-fail
  as the thing that catches it if skipped.

Also fixed in passing: three places in the `Makefile`'s own comments and
`install`/`quickstart` target output still said "see README.md, 'X'" for
sections item 50 had already moved into `docs/deployment/source-install.md`
-- stale since that split, now pointing at the right file. Verified live:
`make check`, `make install`, and `make quickstart` all run clean end to
end in this environment (which already had the full toolchain), and a
fresh `fn_selftest()` after the rebuild still passes 333/0. No SQL or Rust
changed.

## 52. `make install` failed on `openssl-sys` — item 51's toolchain check still missed a machine without OpenSSL dev files

The very next failure after item 51's fix, on a different machine
(`$HOST = aarch64-unknown-linux-gnu`): a bare C toolchain and `clang` were
both present, so `check` passed, but `build` still died compiling
`cargo-pgrx` itself, this time inside `openssl-sys`'s build script:

```
Could not find openssl via pkg-config:
  pkg-config exited with status code 1
  Package openssl was not found in the pkg-config search path.
The PKG_CONFIG_PATH environment variable is not set.
Could not find directory of OpenSSL installation, and this `-sys` crate
cannot proceed without this knowledge.
make: *** [Makefile:62: build] Error 101
```

Root cause: the same class of gap item 51 closed for the compiler, one
dependency further down. `cargo-pgrx` pulls in `openssl-sys` (for its own
HTTPS-capable dependencies, unrelated to PostgreSQL's own OpenSSL
linkage), and `openssl-sys`'s build script needs `pkg-config` on `PATH`
*and* `pkg-config` able to resolve `openssl.pc` — i.e. the OpenSSL
development package, not just the runtime library most systems already
have. This sandbox's own environment already had `libssl-dev` installed,
which is exactly why the previous fix's own `make install` re-run never
caught this: the test environment wasn't representative of a machine
missing it. Checked why the repo's own `Dockerfile`/`cnpg/Dockerfile`/CI
never listed it and still built fine: `apt-cache show libpq-dev` shows
`Depends: ..., libssl-dev`, and `postgresql-server-dev-NN` depends on
`libpq-dev` — so on Debian/Ubuntu, installing the `-server-dev` package
already prerequisite for `pg_config` transitively drags in `libssl-dev`
via a hard `Depends`, even with `--no-install-recommends`. That chain
doesn't hold on every distro or non-apt PostgreSQL install, which is
exactly the gap the user's machine fell into.

Fixed the same way as item 51:

- **Fail fast with a clear message.** `Makefile`'s `check` target now also
  verifies `pkg-config` is on `PATH` and that `pkg-config --exists
  openssl` succeeds, each with its own `$(error ...)` naming the missing
  piece, the Debian/Ubuntu and Fedora/RHEL package names, and the
  `PKG_CONFIG_PATH` escape hatch for an OpenSSL installed somewhere
  pkg-config isn't searching. Verified live with the same non-destructive
  isolation technique as item 51 -- an isolated `PATH` directory
  (`/tmp/fake-path2`, symlinking in only `pg_config`, `cc`, `clang`, and
  the handful of coreutils the check script itself needs) with
  `pkg-config` deliberately left out fired the pkg-config-missing error;
  restoring `pkg-config` but pointing `PKG_CONFIG_LIBDIR=/tmp/empty-
  pkgconfig PKG_CONFIG_PATH=` at an empty directory (so `openssl.pc`
  can't be found without touching the real system OpenSSL install) fired
  the openssl-not-found error; removing both overrides passed clean again
  -- three runs, one per state, nothing uninstalled from the shared
  sandbox.
- **Document it.** README.md's Quick start "Source" path and
  `docs/deployment/source-install.md` now list OpenSSL's development
  files (`libssl-dev`/`openssl-devel`) as a third explicit prerequisite
  alongside `-server-dev` and the C toolchain, with the aarch64 case
  called out as a concrete "this isn't universal" example.
- **Close the same gap in the images that already worked by accident.**
  `Dockerfile` and `cnpg/Dockerfile` now install `libssl-dev` explicitly
  instead of relying on the undocumented transitive `libpq-dev` chain
  above, and all three `apt-get install` lines in
  `.github/workflows/ci.yml` do the same -- so the docs' claim that "all
  three package lists above are the exact ones the repo-root `Dockerfile`
  and `cnpg/Dockerfile` already install" stays true instead of aspirational.
  The Docker/CI changes are **not live-build-verified** -- no Docker
  daemon is reachable in this sandbox (`docker ps` fails to connect to
  `unix:///var/run/docker.sock` at all), the same limitation
  `cnpg/Dockerfile`'s own pre-existing "UNVERIFIED" comment already
  discloses for a different assumption in the same file; `libssl-dev` is
  additive to an install line that already worked, and on Debian/Ubuntu
  it's a package apt already pulls in transitively today, so the risk is
  low, but it hasn't been run for real.

Verified live in this sandbox (which already had `libssl-dev`): `make
check`, `make install`, and a fresh `cargo pgrx install` all still pass
clean after the `Makefile` change, and `fn_selftest()` still reports
`"failed": 0, "passed": 333` across two genuinely separate `psql`
connections (not two calls in one `SELECT` -- see this file's own
variable-hygiene notes on why that distinction matters here too). No SQL
or Rust changed.

## 53. `make install` failed with `bindgen`'s own "cannot find include/server" — `pg_config` on `PATH` isn't proof the dev headers are actually there

A third, distinct failure in the same sequence as items 51 and 52, on a
PGDG RPM-style install (home directory `/var/lib/pgsql`, `pg_config`
resolving PostgreSQL 18 under `/usr/pgsql-18/`):

```
Error: bindgen failed for pg18
Caused by:
   0: cannot find "/usr/pgsql-18/include/server" for C header files
   1: No such file or directory (os error 2)
make: *** [Makefile:80: build] Error 1
```

Root cause: unlike items 51/52 (a whole tool or library genuinely
missing), here `pg_config` itself was found, resolved a supported major
version, and even reported `CLANG = Some("/usr/bin/clang")` correctly —
the `check` target's existing `pg_config`-on-`PATH` test passed cleanly.
The actual gap was one level deeper: `pg_config --includedir-server`
pointed at a directory that doesn't exist, because on this machine only
the PostgreSQL 18 *server/runtime* package was installed, not the
separate `-devel` package that ships the C headers `cargo-pgrx`'s own
`bindgen` step compiles against (PGDG's RPM naming splits these into
`postgresql18-server` and `postgresql18-devel`; Debian/Ubuntu's single
`postgresql-server-dev-NN` package happens to cover both, which is
exactly why this class of gap hadn't surfaced on the Debian-based
sandbox this project's own tooling was developed and tested in).

Fixed the same way as items 51 and 52 — extend `check`, don't just
document around it:

- **Fail fast with a clear message.** `Makefile` now also computes
  `PG_INCLUDEDIR_SERVER := $(shell $(PG_CONFIG) --includedir-server
  2>/dev/null)` and verifies that directory actually exists on disk,
  with a `$(error ...)` naming both the Debian/Ubuntu package and the
  RHEL/Rocky/Alma/Fedora PGDG one (`postgresql$(PG_MAJOR)-devel`,
  explicitly distinguished from `postgresql$(PG_MAJOR)-server`, since
  conflating the two is the exact mistake this item exists to catch).
  Verified live with the same non-destructive technique as items 51/52:
  a wrapper `pg_config` script (`/tmp/fake-pg-config-badinclude/
  pg_config`) that forwards every real flag to the system `pg_config`
  except `--includedir-server`, which it hardcodes to the user's own
  bogus `/usr/pgsql-18/include/server` path — `make check
  PG_CONFIG=/tmp/fake-pg-config-badinclude/pg_config` correctly fired
  the new error with that exact path quoted back, and a plain `make
  check` (real `pg_config`, real existing includedir) still passed
  clean immediately after. Cleaned up (`rm -rf`) once confirmed.
- **Document it.** Both README.md's Quick start "Source" path and
  `docs/deployment/source-install.md`'s first prerequisite bullet now
  name the RHEL/Fedora PGDG package (`postgresqlNN-devel`) alongside
  Debian/Ubuntu's `postgresql-server-dev-NN`, and say explicitly that
  `pg_config` being on `PATH` is not itself proof the headers are
  installed — this was the one prerequisite this project's docs had
  always implicitly conflated with "`pg_config` resolves," across all
  three prior doc passes (the original README, item 50's split, and
  item 51/52's own additions), because the Debian-based dev environment
  this project has always been built and tested in never had a reason
  to separate them.

Verified live: `make check` and `make install` both pass clean in this
(Debian-based) sandbox after the `Makefile` change, and `fn_selftest()`
still reports `"failed": 0, "passed": 333` across two genuinely separate
`psql` connections. No SQL or Rust changed. The RHEL/PGDG package name
itself (`postgresqlNN-devel`) is documented from PGDG's own well-known
packaging convention, not independently verified against a live RPM
install in this sandbox (no RPM-based PostgreSQL install available
here) — if it turns out wrong for some PGDG release, `make check`'s own
error message (which prints the actual missing path, not just the
package name) is still the thing that catches the underlying problem.

## 54. `dnf install postgresqlNN-devel` itself failed, before `make check` was ever reached — CRB not enabled on RHEL9-family systems

The very next step after item 53's fix, on the same PGDG RPM install
(`rhel9.8`, aarch64): trying to actually install the `-devel` package
item 53's docs now recommend failed at the `dnf` level, before `pg_config`
or `make` ever ran:

```
$ dnf -y install postgresql18-devel
Error:
 Problem: cannot install the best candidate for the job
  - nothing provides perl(IPC::Run) needed by postgresql18-devel...
  - nothing provides perl-IPC-Run needed by postgresql18-devel...
```

Root cause: `postgresqlNN-devel`'s own dependency list includes
`perl-IPC-Run` (used by PostgreSQL's TAP test tooling that ships
alongside the dev headers, nothing allgres itself touches), and on a
default RHEL9-family install (RHEL, Rocky, Alma 9) it isn't enabled out
of the box: `perl-IPC-Run` lives in the CRB (CodeReady Builder — the EL9
rename of EL8's PowerTools) repo. This is a step *before* anything in
this repo's own `Makefile`/`check` target runs — `make check` needs
`pg_config` to already exist to check anything about it, and `dnf` never
got that far. Not something a `Makefile` fail-fast check can catch or
fix; this is purely an OS package-repository-enablement gap in the
install instructions themselves, the same category as item 53's
package-name gap, one step further upstream.

First documented from PostgreSQL's own well-known PGDG yum-repo install
instructions (which also suggest enabling EPEL alongside CRB on EL9),
without having reproduced it live. **Confirmed live shortly after, on
the user's actual RHEL9-family aarch64 machine**: CRB alone, enabled for
just that one install via `--enablerepo=crb`, was sufficient —
`perl-IPC-Run` resolved and `postgresql18-devel` installed cleanly with
no EPEL involved at all. Corrected the docs to match what was actually
observed rather than the more conservative original guess:

```bash
sudo dnf -y --enablerepo=crb install postgresql17-devel
```

with permanently enabling CRB (`dnf config-manager --set-enabled crb`,
or `subscription-manager repos --enable
codeready-builder-for-rhel-9-$(arch)-rpms` on true RHEL 9) offered as the
alternative to repeating `--enablerepo=crb` on every future `-devel`
install.

Not added to README.md's own condensed Quick start — this is exactly the
kind of RHEL9-specific detail README.md already defers to `docs/
deployment/source-install.md` for (README's Source section already links
there for "why `pg_config` on `PATH` isn't proof enough"); duplicating a
distro-specific `dnf`/`subscription-manager` branch into the condensed
version would undercut the whole point of the docs split from item 50.
No `Makefile`, SQL, or Rust changed; this is a documentation-only fix,
one step upstream of anything `make check` can reach.

## 55. `make install` prompted for an unusable password — "add `sudo`" didn't say *where*

The very next step after items 51–54's prerequisites were all sorted,
same live RHEL9-family install: `make install` (run as the `postgres`
system account, where `cargo`/`cargo-pgrx` had already been installed
and used successfully for the whole `build` step) stopped mid-install on
an interactive password prompt it had no way to satisfy:

```
Using sudo to copy extension files from ...
       Running sudo cp .../allgres.control /usr/pgsql-18/share/extension/allgres.control
[sudo] password for postgres:
```

Root cause: `install`'s own recipe already does the right thing --
`cargo pgrx install $(if $(filter 0,$(shell id -u)),,--sudo) ...` only
adds `--sudo` when not already root -- but the Quick start's own comment
next to `make install`, `# add \`sudo\` if this PostgreSQL's own lib/share
dirs need it`, never said *where* to add it. Read literally it suggests
`sudo make install`; running plain `make install` as a non-root account
instead (exactly what following the docs' own earlier "no Docker" path
leads to, since `cargo`/`cargo-pgrx` and the whole build were already
done as the `postgres` service account) makes the Makefile fall back to
its own `--sudo`-flag branch, and `cargo-pgrx` then shells out to a real
interactive `sudo cp` *per copied file*. A `postgres` system account
typically has no usable login password at all (locked/nologin, meant
only for PostgreSQL's own peer authentication) -- so that prompt isn't
just an inconvenience, it can have no correct answer to type in.

Fixed by making the recommended invocation explicit instead of
"add `sudo`" left to guesswork:

- `Makefile`'s own comment above the `install` target now spells out
  `sudo env "PATH=$PATH" make install` as the way to run the whole
  install as root from the start -- which makes the Makefile's existing
  `id -u`-based branch take its empty-flag path, so `cargo-pgrx` never
  needs a nested `sudo` call at all, and the single outer `sudo` prompt
  is asked once, for whichever account actually has real sudo rights,
  not for a service account's unusable password. `env "PATH=$PATH"`
  matters specifically for the `postgres`-service-account workflow this
  project's own docs walk through: `cargo`/`cargo-pgrx`/`pg_config` were
  installed under that account's own `$HOME`, and root's own default
  `$PATH` won't include them without it.
- README.md's and `docs/deployment/source-install.md`'s Quick start
  comments next to `make install` now point at "the note just below"
  instead of the ambiguous "add `sudo`", and `docs/deployment/
  source-install.md` spells out the full `sudo env "PATH=$PATH" make
  install` form plus why the naive alternative (a bare, non-root `make
  install`) triggers a per-file prompt a service account often can't
  answer.

Verified: `make check` still passes clean and `make -n install` (dry
run) still shows the expected recipe after the comment-only `Makefile`
change; no functional line changed, so no rebuild or `fn_selftest()`
re-run was needed. Not reproduced against a real passwordless `postgres`
service account in this sandbox (this sandbox's own `postgres` role has
no OS-level login account at all, so `sudo -u postgres` here behaves
differently) -- the fix follows directly from reading the Makefile's own
already-correct `id -u` branch alongside the live transcript of what the
user's `make install` actually printed, not from reproducing the exact
prompt locally.

## 56. Web worker up, port "open," still unreachable — `ALLGRES_HTTP_ADDR`'s loopback default was never mentioned on the Source install path

The install itself finished clean (all of items 51-55 behind it) and both
workers came up, confirmed live via `ps -ef` (`allgres web`, `allgres
runtime` both running) -- but the dashboard still wasn't reachable.
`ss -tlnp | grep 8088` showed why:

```
LISTEN 0  128  127.0.0.1:8088  0.0.0.0:*  users:(("postgres",pid=34907,fd=6))
```

Not a bug -- `allgres web` was doing exactly what `src/web.rs`'s
`check_exposure` is supposed to do: refuse a non-loopback bind unless a
token is set or `ALLGRES_ALLOW_INSECURE_HTTP=1` says the network already
protects the port, defaulting to `127.0.0.1:8088` otherwise (see
[Security model, "Exposure"](docs/security.md#exposure), already
documented and already correct). The actual gap: this user was source-
installing *inside a container* (hostname `9bccf441ad3d`, a bare RHEL9
container, not the project's own prebuilt Docker image), where a loopback
bind is unreachable from outside the container for a second, independent
reason on top of the exposure guard -- Docker's own `-p` port-forwarding
targets the container's real network interface, never its loopback, so
even a deliberately-relaxed bind still needs `0.0.0.0`, not just a token.
README's own Docker Quick start already spells out the fix
(`-e ALLGRES_HTTP_ADDR=0.0.0.0:8088 -e ALLGRES_ALLOW_INSECURE_HTTP=1`) --
but `docs/deployment/source-install.md`, the page an operator installing
from source (in or out of a container) actually reads, only ever
mentioned the default address, never how or why to change it. The same
recurring shape as items 51-55: real operational information that
existed for the Docker path never got carried over to the Source path.

Fixed by adding a paragraph to `docs/deployment/source-install.md`
immediately after where it already mentions the default address,
covering the two things that tripped this live: `ALLGRES_HTTP_ADDR` is a
plain process environment variable read once at worker startup (not a
GUC -- needs exporting into the shell `postgres` itself starts from, then
a real `pg_ctl restart`, not `SET`/reload), and the concrete `export
ALLGRES_HTTP_ADDR=0.0.0.0:8088` / `export ALLGRES_ALLOW_INSECURE_HTTP=1`
/ `pg_ctl restart` sequence, with the same "fine behind a trusted network
boundary, never a substitute for a real token on anything actually
reachable by others" caveat the Docker path's own README section already
carries, so the two pages stay consistent instead of the Source page
being the permissive one by omission.

No `Makefile`, SQL, or Rust changed -- `check_exposure` and the loopback
default were already correct; this is a documentation-only fix carrying
existing, correct behavior across to a page that never mentioned it. Not
independently re-verified against a real container restart in this
sandbox (this sandbox's own `postgres` role has no supervising `pg_ctl`
setup matching the user's exact container arrangement) -- confirmed
instead directly from `src/web.rs`'s own `check_exposure`/
`configured_http_addr` source and the user's own live `ss`/`ps` output,
which is what the fix is written from.

## 57. `make quickstart` silently never created `allgres` when `pgcrypto` was genuinely unavailable, not just uncreated

Found live while chasing item 56: the same user's PostgreSQL log, a few
lines above the restart sequence, had this sitting unexamined:

```
2026-09-18 01:51:35.860 UTC [34523] ERROR:  extension "pgcrypto" is not available
HINT:  The extension must first be installed on the system where PostgreSQL is running.
STATEMENT:  SET allgres.reloadable = 'on';   CREATE EXTENSION IF NOT EXISTS pgcrypto;
  CREATE EXTENSION IF NOT EXISTS allgres;   SELECT allgres_public.fn_start_dynamic_workers();
```

No further lines followed for that statement -- no `CREATE EXTENSION`
success, no `fn_start_dynamic_workers` result -- meaning the *real* `make
install`/`make quickstart` an operator ran earlier in this same
troubleshooting session had never actually created the `allgres`
extension at all, despite both background workers showing up in `ps -ef`
(explained by `shared_preload_libraries` registering them unconditionally
at postmaster start, independent of whether `CREATE EXTENSION allgres`
ever ran anywhere).

Root cause: `quickstart`'s Makefile recipe sent all four statements
(`SET`, two `CREATE EXTENSION`s, the `SELECT`) as one `psql -c` string.
PostgreSQL's simple query protocol wraps a multi-statement string like
that in a single implicit transaction; when `pgcrypto` isn't just
uncreated but genuinely missing from the system (no `postgresqlNN-
contrib` package, e.g.), `CREATE EXTENSION IF NOT EXISTS pgcrypto`
errors regardless of `IF NOT EXISTS` (there's no control file for it to
find), which aborts the whole implicit transaction -- silently taking
`CREATE EXTENSION allgres` down with it, even though pgcrypto is
explicitly optional (README's own Runtime requirements: "pgcrypto
(optional, for encrypted provider secrets)"). An operator whose system
never had pgcrypto installed would run `make install && make quickstart`
exactly as the Quick start instructs, see workers listed in `ps -ef`,
and have no working `allgres_public.*`/`allgres_private.*` schema at all
-- with no obvious signal beyond a single `ERROR` line buried in the
PostgreSQL log, several statements before the point where troubleshooting
would normally start.

Reproduced live in this sandbox without touching any real package or
extension: rather than uninstalling pgcrypto (this sandbox's shared, and
removing system packages isn't something to do to chase a docs bug), the
same failure mode was reproduced by substituting a genuinely nonexistent
extension name (`nonexistent_ext_xyz`) for `pgcrypto` in the old
combined-statement form, on a disposable scratch database
(`allgres_quickstart_test`, dropped again once done) -- confirmed the old
form left `allgres` uncreated (`SELECT extname FROM pg_extension WHERE
extname='allgres'` came back empty), then confirmed the fixed form
created it successfully even with the same missing-extension failure in
play.

Fixed by splitting `pgcrypto` into its own, independently-failable `psql`
call ahead of the essential one:

```makefile
quickstart:
	@psql -d $(QUICKSTART_DB) -c "CREATE EXTENSION IF NOT EXISTS pgcrypto;" >/dev/null 2>&1 || \
	  echo "pgcrypto not available on this system -- skipping it (optional; ...)"
	psql -v ON_ERROR_STOP=1 -d $(QUICKSTART_DB) -c "SET allgres.reloadable = 'on'; \
	  CREATE EXTENSION IF NOT EXISTS allgres; \
	  SELECT allgres_public.fn_start_dynamic_workers();"
```

so a missing `pgcrypto` can never again abort `CREATE EXTENSION allgres`
in the same implicit transaction -- the two calls are now genuinely
independent statements/transactions from PostgreSQL's own point of view.

Verified: `make check` still passes clean (comment/recipe-only change to
`quickstart`, nothing `check` touches); `make -n quickstart` shows the
expected two-call recipe; live-tested both the normal case (`pgcrypto`
already installed -- ran clean, `"already exists, skipping"` then the
real `CREATE EXTENSION allgres`/`fn_start_dynamic_workers` calls
succeeded) and the substituted-missing-extension case on the disposable
scratch database described above, both confirmed by directly querying
`pg_extension` afterward rather than trusting `psql`'s own exit status
alone. No SQL or Rust changed -- this is a `Makefile`-only fix; nothing
about `fn_selftest` exercises `make quickstart` itself, so no selftest
re-run was needed or would have caught this class of bug in the first
place.

## 58. `export` + `pg_ctl restart` never changed `ALLGRES_HTTP_ADDR` — PostgreSQL was systemd-managed

Immediately after item 56's fix was suggested, on the same live install:
the user reported `export ALLGRES_HTTP_ADDR=0.0.0.0:8088; pg_ctl restart`
had no effect at all -- `ss -tlnp | grep 8088` still showed
`127.0.0.1:8088` after several restarts. Asking directly surfaced the
reason: PostgreSQL on this machine was started via `systemctl`, not a
bare `pg_ctl start` from an interactive shell.

Root cause: a systemd service's process environment comes entirely from
its own unit (`Environment=`/`EnvironmentFile=` directives), never from
whatever happens to be `export`ed in the shell that runs `systemctl
restart` -- `export` only affects the current shell and its direct
children, and `systemctl` talks to PID 1's systemd manager over a socket
rather than forking the service as its own child, so the exported
variable never reaches the new `postgres` process at all. Item 56's own
fix, written and verified from `src/web.rs` alone without knowing how
this specific user's PostgreSQL was actually being started, silently
assumed a bare `pg_ctl`-managed install -- a reasonable default (it's
what `make quickstart`'s own docs assume throughout), but wrong for a
PGDG RPM install, where the packaged install very commonly *is*
systemd-managed from the start.

Fixed by extending the same `docs/deployment/source-install.md`
paragraph item 56 added, rather than opening a new one, with the systemd
case right after the plain `pg_ctl` form: `sudo systemctl edit
postgresql-NN` to create a drop-in (never hand-edit the vendor unit --
a package upgrade overwrites it) with

```ini
[Service]
Environment=ALLGRES_HTTP_ADDR=0.0.0.0:8088
Environment=ALLGRES_ALLOW_INSECURE_HTTP=1
```

followed by `systemctl daemon-reload && systemctl restart postgresql-NN`.

Not independently reproduced in this sandbox (PostgreSQL here runs under
`pg_ctlcluster`, Debian's own cluster-management wrapper, not systemd) --
written directly from the user's own confirmation of how their instance
starts, the same way item 55's `sudo`-placement fix was derived from a
live transcript rather than a local repro. No `Makefile`, SQL, or Rust
changed; purely an extension of item 56's own documentation-only fix.

## 59. Dashboard's Korean toggle was half-translated -- nav labels only, everything else stayed English

Reported live against a real install (the first time anyone had actually
looked at the dashboard past login this session): a screenshot showing
the Agents page with the sidebar and page `<h1>` in Korean ("에이전트")
but the "New agent" button, every table header, and all body copy still
in English -- an inconsistent, half-finished look, not a rendering bug.

Root cause: `web/index.html`'s `I18N`/`t()` system only ever had entries
for nav labels and a couple dozen short UI words (`save`, `edit`,
`signIn`, section headers, ...); every other string on every page --
button labels, table column headers, panel copy, empty-state text, toast
messages -- was hardcoded English, never routed through `t()` at all.
Selecting 한국어 in Settings therefore never produced a real Korean
dashboard, only ever this English-with-a-translated-frame look. Reported
alongside two smaller, related points: the *default* language actually
was already `en` in code (`localStorage.getItem('allgres_lang')||'en'`)
-- contrary to how it read from the screenshot, a real default-to-Korean
bug was never present, just a stale `ko` value some earlier session
(browser or this same testing) had left in that browser's own
`localStorage` -- and the "design doesn't match the reference" point
from the same message, which a live re-screenshot of the current
(already design-swept, item 0bd7956) build did not reproduce -- current
Overview/Agents/Settings pages screenshotted clean, properly spaced,
consistent with the earlier design-sweep work; most likely the same
explanation as the language confusion, an older cached build or an
earlier point in this same troubleshooting session, not a live gap in
the current code.

Asked directly rather than guessing given the size of the alternative
(fully translating a 5000+ line single-file dashboard's every string):
remove the toggle and go English-only, keep English-by-default with the
half-translated toggle still reachable, or commit to actually finishing
a complete Korean translation. Chosen: remove it entirely -- matches
this project's own "don't half-build a feature, and don't add generality
beyond what's needed" stance, and a half-finished i18n surface is worse
than none, actively confusing rather than merely incomplete.

Fixed in `web/index.html`:

- Collapsed `I18N` from `{en:{...}, ko:{...}}` to a single flat string
  table, and `t(key)` from `` const d=I18N[lang()]||I18N.en; return
  d[key]??I18N.en[key]??key `` down to `return I18N[key]??key` -- every
  existing `t('someKey')` call site needed no change at all, since a
  call for a key neither dictionary ever defined was already falling
  through to `key` itself unchanged (which is why most body copy was
  already effectively "translated" to itself); only the nav labels and
  short UI words that *did* have real dictionary entries changed
  behavior, and only by permanently resolving to their `en` value.
- Deleted `lang()`/`setLang()` and the Settings page's language toggle
  row (the `langBtn` buttons and their click handler) entirely, along
  with the now-dead `language` dictionary key; the "Language / Theme"
  panel is now just "Theme".
- No migration needed for a browser with a stale `allgres_lang=ko`
  already in `localStorage`: `t()` no longer reads that key at all, so
  the page silently and permanently reverts to English on next load
  regardless of what's still stored there -- confirmed live (see below).

Verified: `cargo pgrx install --no-default-features --features pg16`
rebuilt clean (`web/index.html` is compiled in via `include_str!` in
`src/lib.rs`, so this was a real rebuild+reinstall+restart, not just an
edit); `cargo test --lib --no-default-features --features pg16` still
30/30, including `dashboard_html_carries_the_csp_nonce_placeholder`
(confirms the compiled-in HTML still carries its CSP nonce placeholder
intact); `fn_selftest()` still `"failed": 0, "passed": 333` across two
separate `psql` connections. Live browser check (Playwright,
`/opt/pw-browsers/chromium-1194`) against the rebuilt worker: logged in
with `allgres_lang` deliberately pre-set to `'ko'` in `localStorage`
first (simulating exactly the stale-toggle browser this bug was reported
from) -- Agents and Settings pages both rendered fully in English, no
mixed-language strings anywhere, Settings' language row gone and Theme
row intact. A throwaway admin account created for this test
(`admin_test`) was deactivated and deleted afterward. No SQL changed.

## 60. Every inline `style="..."` attribute in the dashboard has been dead on arrival, silently, since the CSP was tightened to `style-src 'nonce-...'`

The actual root cause behind this whole session's recurring "boxes are
still stuck together" reports -- reported again after item 59, this
time pushed on hard enough ("너가 보내준거 뉴 에이전트랑 간격 붙어있는데?" --
"the one you sent me still has New Agent stuck to the table") to force
an actual pixel measurement instead of trusting a screenshot by eye,
which is what finally surfaced it:

```js
// Playwright, against this session's own rebuilt worker
document.getElementById('newAgent').parentElement.getAttribute('style')
// -> "margin-bottom:22px"   (present in the DOM, exactly as authored)
getComputedStyle(document.getElementById('newAgent').parentElement).marginBottom
// -> "0px"                  (never applied)
```

and the browser console, which nothing in this session had actually
opened until this point:

```
Refused to apply inline style because it violates the following Content
Security Policy directive: "style-src 'nonce-...'". Either the
'unsafe-inline' keyword, a hash (...), or a nonce ('nonce-...') is
required to enable inline execution. Note that hashes do not apply to
... style attributes ... unless the 'unsafe-hashes' keyword is present.
```

Root cause: `src/web.rs`'s CSP header sends `style-src 'nonce-{n}'` with
no `'unsafe-inline'` -- a deliberate, extra-strict choice (most CSPs stop
at nonce'd `script-src`; this one nonced `style-src` too). What nobody
building or reviewing this had internalized is a real, easy-to-miss CSP
subtlety: **a nonce on `style-src` only ever authorizes `<style>`
elements carrying that same nonce (and equivalent `<link>` stylesheets)
-- it does not, and per spec cannot, authorize the `style="..."` HTML
*attribute*, on any element, ever.** Only `'unsafe-inline'` (or a
per-value hash, impractical at this count) covers that attribute. This
project's own dashboard leans on `style="..."` constantly for one-off
spacing/sizing -- 139 occurrences across 62 distinct values, all through
this session's own earlier "spacing fix" and "design sweep" commits
included -- and every single one of them has silently done nothing in
any real, CSP-enforcing browser since whenever that policy was first
tightened this strictly, predating this session's own diagnosis of it by
an unknown amount. Two of this session's own earlier commits (the
spacing fixes referenced in the design-sweep summary, and the chat model
picker's 14px-to-22px fix) *edited* one of these dead attributes,
correctly, and still fixed nothing -- because the attribute was never
live to begin with. Every prior screenshot taken this session for
verification was eyeballed, never pixel-measured or checked against the
browser console, so this went uncaught through several rounds of "looks
fixed" -- the actual lesson of item 55's `sudo`-placement bug and this
one both: verifying a UI change means checking the thing the fix is
supposed to change (a real computed value, a real console), not the
overall gestalt of a screenshot.

Fixed in `web/index.html`, without touching the CSP itself (weakening
`style-src` to `'unsafe-inline'` was the one-line alternative, rejected:
it would silence this exact protection against a future injected-style
attack for every one of these 139 call sites at once, and this project
has clearly invested deliberately in the stricter policy) and without
rewriting any of the 139 call sites (safer: zero chance of a transcription
error breaking one of them):

- 62 attribute-selector CSS rules (`[style="exact literal value"]{same
  declarations}`) added to the second, "override" `<style nonce="...">`
  block -- one per distinct static `style="..."` string still used
  anywhere in the file, generated programmatically from the file's own
  current content (`grep -o 'style="[^"]*"' | sort -u`) so every value
  is copied verbatim, not retyped. `[style="..."]` is an ordinary CSS
  *attribute selector*, matching on the attribute's string value like
  any other attribute selector (`[data-foo="bar"]`) -- entirely distinct
  from the browser's separate "apply this attribute's own declarations
  as inline style" mechanism, which is the one thing CSP actually blocks;
  a rule written this way lives inside a real, nonce-carrying `<style>`
  element and is therefore fully CSP-compliant.
- The one dynamic exception (`style="font-size:14px;font-weight:600;
  color:${color}"`, a verdict badge whose color came from a 3-way
  lookup) was converted properly instead: two new one-line classes
  (`.verdict-label`, `.txt-accent`, `.txt-bad`, reusing the existing
  `.muted` for the third case) and the JS now picks a class name from
  the same 3-way lookup instead of building a CSS value string.
- A blunt, impossible-to-miss comment sits directly above the new rule
  block explaining exactly this trap and what adding a *new*
  `style="..."` attribute in this file actually requires now (a matching
  rule here, or -- preferred -- a real class): the fix closes today's
  139 cases; nothing stops a 140th from being added the same broken way
  without that warning in the obvious place someone reaches for next.

Deliberately not fixed further in this pass: the browser still logs a
CSP violation warning for each `style="..."` attribute's own blocked
"native" application, once per element per page load, since the dead
attributes themselves are still present in the markup (only the new
attribute-selector rules elsewhere make them visually effective). This
is inert console noise, not a functional or visual gap -- confirmed by
walking every nav tab and comparing declared vs. computed values, all
13 distinct strings actually rendered live matched their intended CSS
exactly -- but a fully silent console would mean deleting all 139
`style="..."` attributes outright (a much larger, no-longer-purely-additive
edit across the file's giant single-line template strings) for a
devtools-only cosmetic improvement invisible to every real user; left
as a known, explicitly-documented trade-off rather than scope creep.

Verified: rebuilt and reinstalled the extension (`cargo pgrx install
--no-default-features --features pg16`) after confirming the embedded JS
still parses (`new Function()` against the extracted `<script>` body);
`cargo test --lib --no-default-features --features pg16` still 30/30;
`fn_selftest()` still `"failed": 0, "passed": 333` across two separate
`psql` connections. Live Playwright re-check against the rebuilt worker:
`getComputedStyle(...).marginBottom` on the Agents page's `New agent`
row now reads `22px` (was `0px`), the real rendered gap between the
button and the table panel measures `22px` via `getBoundingClientRect()`
(not eyeballed), and a full click-through of every nav tab (Overview,
Agents, Chat, Approvals, Projects, Run, Memories, Audit, Settings)
turned up no declared `style="..."` value without a matching rule. A
throwaway admin account created for this verification (`admin_probe`)
was deactivated and deleted afterward. No SQL changed.

## 61. Added a built-in admin SQL console (its own nav page) -- one query, no separate DB client

Requested directly: an admin wanted to run ad hoc queries against the
database without opening a separate client (DBeaver named specifically)
just for that. Before building anything, the real open design question
was put to the user rather than assumed: what privilege level should an
admin-run query actually have? Three options, materially different in
blast radius -- full superuser (equivalent to a real DBeaver connection:
`ALTER SYSTEM`, other databases, everything), read-only `SELECT`-only, or
scoped to `allgres_owner` (full DDL/DML over everything allgres's own
schemas contain, no server-wide reach). Chosen: `allgres_owner`.

Built as `allgres_public.fn_admin_execute_sql(p_sql text)`
(`sql/operator_accounts_and_chat.sql`), a `SECURITY DEFINER` function
owned by `allgres_owner` -- no new privilege granted to that role to make
this possible, it only ever exercises what it already has -- reached
through a new `sql.execute` dashboard_rpc action, gated by
`require_admin_if_accounts_exist` like the rest of the
platform-configuration surface, confirmed live rejected for a real
logged-in non-admin session token. Design notes worth recording:

- **One statement per call, for free.** PL/pgSQL's `EXECUTE` uses the
  extended query protocol under the hood, which refuses a string
  containing more than one command -- no separate parsing/validation
  needed to enforce "one query at a time," unlike `execute_sql`'s own
  `allgres.analyze_sql` gate (sql-sandbox.md), which exists for a
  different reason (deciding what a *sandboxed* statement may touch, not
  how many of them there are).
- **Row-shaped results, including `RETURNING`.** A plain `SELECT`, a
  `WITH ... SELECT`, and `INSERT`/`UPDATE`/`DELETE ... RETURNING` are all
  tried first, wrapped as `WITH __q AS (<sql>) SELECT to_jsonb(t) FROM
  __q t` -- the `WITH`-CTE form specifically because a data-modifying
  statement can only appear as a CTE body in real PostgreSQL syntax, not
  a plain `FROM (...)` subquery, which is what makes a `RETURNING`
  clause's own output come back as real rows instead of just a count.
  Confirmed live across five shapes: plain `SELECT`, a multi-row
  `SELECT`, bare `CREATE TABLE`, `INSERT` with no `RETURNING`, and
  `UPDATE ... RETURNING` -- the last one correctly returned the updated
  rows, not just an affected-count.
- **A statement that cannot be a CTE body (DDL, or DML with no
  `RETURNING`) fails that wrap at PostgreSQL's own parse stage, before
  anything executes.** The inner `BEGIN`/`EXCEPTION WHEN OTHERS` around
  just the wrap attempt is a real PL/pgSQL savepoint, so *any* failure
  there -- parse-time or a genuine runtime error -- rolls back cleanly
  and falls through to running the statement directly, reporting rows
  affected via `GET DIAGNOSTICS` instead. This was reasoned through
  rather than assumed: PL/pgSQL's savepoint-per-exception-block semantics
  are what make it safe to catch broadly here without any risk of a
  doomed statement's partial effects leaking past the retry.
- **A genuine error (bad SQL, a constraint violation) is deliberately
  left uncaught inside the function itself** -- it propagates out to
  `dashboard_rpc`'s own pre-existing top-level `EXCEPTION WHEN OTHERS`
  handler, the same path every other dashboard_rpc action's errors
  already take, turning it into a clean `{"ok":false,"error":SQLERRM,
  "sqlstate":SQLSTATE}` instead of a second, redundant error-handling
  layer. Confirmed live: a bad table name came back as
  `{"ok":false,"error":"relation \"...\" does not exist",...}` through
  the full dashboard_rpc path, not a raw exception or a 500.
- **Audited before running, not after** (`allgres_private.audit`,
  action `sql_console.execute`, the SQL text itself in `details`) -- a
  query that errors, or that runs out the 60s `statement_timeout` this
  function sets, still leaves a record of what was attempted, matching
  this project's own "every consequential mutation" audit-log standard
  rather than treating this one surface as exempt because it's already
  gated. Confirmed live via a direct `audit_log` query, correctly
  distinguishing `web`-origin (username attached) from `sql`-origin
  (called directly) calls.

Frontend: a new `SQL` admin-only nav page (`adminPages`, not
`userPages`) -- a textarea, a Run button (Ctrl/Cmd+Enter, matching every
real SQL client's own shortcut), and a result panel that renders a real
table for row-shaped results or a plain "N row(s) affected" line for the
DDL/DML-without-`RETURNING` shape, reusing existing `.table`/`.panel`/
`.banner` classes throughout. Every `style="..."` value the new markup
needed was already covered by item 60's own attribute-selector rules
(confirmed programmatically, not just by eye, before shipping this) --
the first real test of that fix's own warning comment actually being
followed by later code, not just describing the problem it fixed.

`CONTRACT.md`'s own `require_admin_if_accounts_exist` action count was
also stale independent of this change -- it said 34, the real
(pre-this-feature) count was already 40 -- fixed to the current 41 (with
`sql.execute` added to the representative list) alongside this feature
rather than left for a future, unrelated discovery.

Verified: `sql/rpc_catalog.json` regenerated (`scripts/gen_rpc_catalog.py`)
and both of `fn_selftest`'s `dashboard_rpc_actions_match_frozen_catalog`
arrays updated in the same commit, per `CONTRACT.md`'s own rule. Fresh
install (`DROP EXTENSION ... CASCADE` → `CREATE EXTENSION`) plus
`fn_selftest()` across two separate `psql` connections both report
`"failed": 0, "passed": 333`; `cargo test --lib --no-default-features
--features pg16` still 30/30. Live Playwright pass through the actual
dashboard UI (not just direct SQL calls): logged in as a real admin
account, ran a `SELECT`, a `CREATE TABLE`, a query against a
nonexistent table (clean error banner, not a crash), and a cleanup
`DROP TABLE` -- all rendered correctly, no CSP style-src violations
traced back to any of the new markup. A second, non-admin account
confirmed `sql.execute` rejected server-side (`"admin role required"`),
not merely hidden from that account's own nav. Both throwaway accounts
deactivated and deleted afterward.

## 62. `SELECT now();` in the new SQL console came back as a row count, not a timestamp -- and how it was upgraded made it worse

Two real, distinct problems surfaced in quick succession after item 61
shipped, both live-reported by the same admin trying to actually use it.

**First: `permission denied for function fn_admin_execute_sql`,
immediately after upgrading.** The advice given at the time -- pull the
two changed `sql/*.sql` files and re-apply them directly with `psql -f`,
to avoid `DROP EXTENSION ... CASCADE` destroying real data -- was itself
wrong in a way only obvious in hindsight. `grants_and_facade.sql`'s own
ownership-fixing pass (its own comment: "CREATE EXTENSION ... records
every object this file creates as an extension member as it creates it")
only reassigns ownership for objects PostgreSQL's `pg_depend` already
knows belong to the `allgres` extension -- a brand-new function created
by running its defining file directly via `psql -f`, outside `CREATE
EXTENSION`/`ALTER EXTENSION`, is never recorded as an extension member at
all, so that pass silently skipped it, leaving it owned by whichever
role ran the file (not `allgres_owner`) with no `EXECUTE` grant for the
role `dashboard_rpc` actually runs as. Reproduced live by deliberately
recreating the same state (`ALTER EXTENSION allgres DROP FUNCTION ...`
+ `ALTER FUNCTION ... OWNER TO postgres`) and confirming the identical
error, then confirming the real fix resolves it with no data loss:

```sql
ALTER EXTENSION allgres ADD FUNCTION allgres_public.fn_admin_execute_sql(text);
ALTER FUNCTION allgres_public.fn_admin_execute_sql(text) OWNER TO allgres_owner;
```

Only relevant the *first* time a brand-new function is deployed this way
-- modifying an *existing*, already-registered function's body via a
plain `CREATE OR REPLACE FUNCTION` (as the second bug below needed) does
not touch ownership or extension membership at all, confirmed live
later in this same item with no `ALTER EXTENSION ADD FUNCTION` step
needed.

**Second, after that was fixed: `SELECT now();` -- the single most
ordinary query anyone would type first, semicolon included out of sheer
habit -- came back `{"ok": true, "rows_affected": 1}` instead of the
actual timestamp.** Root cause: `fn_admin_execute_sql`'s row-shaped-query
wrap is `WITH __allgres_console_q AS (%s) SELECT to_jsonb(t) FROM
__allgres_console_q t` -- and `(SELECT now();)` is not valid SQL, a
statement terminator *inside* the parentheses ends the statement
prematurely. That parse failure was indistinguishable, from inside the
function, from "this isn't a row-shaped statement at all" (DDL, or DML
with no `RETURNING`), so it silently took the exact same fallback path a
`CREATE TABLE` takes -- correct behavior for a `CREATE TABLE`, wrong for
a `SELECT` with nothing more than a habitual trailing `;`.

While fixing it, a second, independent mistake in item 61's own design
was caught: its "one statement per call, by construction" claim --
"PL/pgSQL's `EXECUTE` uses the extended query protocol under the hood,
which refuses a string containing more than one command" -- is simply
false, confirmed directly (`DO $$ BEGIN EXECUTE 'SELECT 1; SELECT 2';
END $$;` succeeds, running both). That restriction is real for a
parameterized `EXECUTE ... USING`, not for a bare literal SQL string,
which is exactly what this function passes. Nothing in item 61's own
testing had actually tried a genuine multi-statement string against the
*fallback* path specifically (only against the wrap-then-fallback flow
as a whole, where the earlier trailing-semicolon-shaped test cases never
exercised it) -- so this sat undetected through that item's own
verification.

Fixed together, since both come from the same place -- normalizing
`p_sql` before either code path sees it:

- A single trailing `;` (plus any trailing whitespace) is stripped with
  `regexp_replace(btrim(p_sql), ';\s*$', '')` before anything else --
  leaves a genuine multi-statement attempt (`SELECT 1; SELECT 2`, with
  no trailing `;` of its own on the second statement) completely
  unaffected, since only the outermost terminator is ever a style
  artifact, never a second statement.
- The statement count is now checked for real: `allgres.analyze_sql`
  (the same native `raw_parser` call `execute_sql`'s own validation
  already relies on, sql-sandbox.md) reports a `statements` field
  directly; anything other than exactly `1` is rejected with a clear
  `exactly one SQL statement per run (found N)` error before either
  execution path runs. `analyze_sql` also raises a real syntax error for
  genuinely unparseable input, which is treated as a feature here, not a
  gap to guard against -- it propagates out to `dashboard_rpc`'s own
  top-level exception handler exactly like any other genuine error this
  function produces, just discovered one step earlier than before.

Verified: reproduced the exact `SELECT now();` failure live before the
fix (`{"ok": true, "rows_affected": 1}`) and confirmed it now returns the
real row after; confirmed `SELECT 1; SELECT 2` is now cleanly rejected
(`exactly one SQL statement per run (found 2)`) where before it silently
ran both; confirmed DDL, DML-without-`RETURNING`, and DML-with-
`RETURNING` (each with and without a trailing `;`) all still behave
exactly as item 61 originally verified. Function ownership stayed
`allgres_owner` after re-applying via `CREATE OR REPLACE FUNCTION`
against the already-registered function (no `ALTER EXTENSION ADD
FUNCTION` step needed this time -- confirmed directly, closing the loop
on the first bug in this item). Fresh install (`DROP EXTENSION ...
CASCADE` → `CREATE EXTENSION`) plus `fn_selftest()` across two separate
connections both report `"failed": 0, "passed": 333`; `cargo test --lib
--no-default-features --features pg16` still 30/30. Live Playwright
re-check through the real dashboard UI, logged in as a genuine admin
account: `SELECT now();` now renders the actual timestamp in a real
table, not a row count. A throwaway admin account created for this
verification was deactivated and deleted afterward.

The corrected claim about `allgres.analyze_sql`'s role here is also now
reflected in [Security model, "The SQL
console"](docs/security.md#the-sql-console), replacing the false one
item 61 originally shipped.

## 63. SQL console: multi-column results came back alphabetized, not in SELECT order

Reported immediately after item 62 landed: `SELECT 3 AS zebra, 1 AS
apple, 2 AS mango` rendered as `apple | mango | zebra` in the results
table -- alphabetical, not the `zebra, apple, mango` order actually
written. Root cause, once isolated with a bare comparison —

```sql
SELECT to_jsonb(t) FROM (SELECT 3 AS zebra, 1 AS apple, 2 AS mango) t;
-- {"apple": 1, "mango": 2, "zebra": 3}
SELECT to_json(t)  FROM (SELECT 3 AS zebra, 1 AS apple, 2 AS mango) t;
-- {"zebra":3,"apple":1,"mango":2}
```

— is a real, documented, by-design property of `jsonb` as a type, not a
bug in `to_jsonb` or anything upstream of it: `jsonb`'s binary storage
format sorts and deduplicates object keys as part of how it's stored,
the exact thing that makes indexed `jsonb` lookups fast; `json` (text)
has no such structure and preserves whatever order the input had. This
is not a corner this function could route around by simply switching
`to_jsonb` for `to_json` internally, either -- `dashboard_rpc` itself
`RETURNS jsonb`, so no matter what type an intermediate value holds,
everything is normalized to jsonb's own canonical key-sorted form by the
time it reaches the actual HTTP response. A JSON *array*'s element
order, unlike an object's key order, does survive jsonb storage (arrays
are ordered sequences, not key-addressed) -- so the only way to actually
preserve column order end to end is to never put it in object keys at
all.

Fixed by changing `fn_admin_execute_sql`'s return shape from one `jsonb`
object per row (`SETOF jsonb`, keyed by column name) to a single `jsonb`
value shaped `{"cols": [...], "rows": [[...], [...]]}` -- columns
named once, each row a plain positional array matching that order. The
extraction uses `json_each(to_json(t)) WITH ORDINALITY`: `to_json`
(text, order-preserving) turns a row into a JSON object with real column
order intact, `json_each` walks it back out as an ordered set of
key/value pairs (an ordered *set*, not an ordered *object*, is exactly
where order survives becoming jsonb again), and `WITH ORDINALITY` gives
each pair a stable position to aggregate by. `cols` is read from one
representative row (`LIMIT 1`); every row of a single query result
always shares the same columns in the same order, so this is correct,
not just convenient. The function's own return type changed
(`RETURNS TABLE(row_data jsonb)` → `RETURNS jsonb`, a single value, not
a set), which meant `dashboard_rpc`'s own `sql.execute` branch changed
too, from aggregating a set (`jsonb_agg(row_data) FROM
fn_admin_execute_sql(...)`) to a plain call merged with `||` (`jsonb_
build_object('ok', true) || fn_admin_execute_sql(...)`, so both the
row-shaped `{"cols":...,"rows":...}` result and the DDL/DML
`{"rows_affected":...}` result end up with a matching top-level `"ok":
true`). The dashboard's own `sqlConsolePage`/`renderSqlResult` were
updated to read `cols`/`rows` and render each row positionally instead
of via `Object.keys()` on a per-row object (which had been reading back
whatever order *JavaScript's* own key enumeration happened to produce,
compounding the same underlying problem client-side).

Deploying this one was more involved than items 61/62's own fixes,
worth recording since it will recur for any future signature change to
this function: `CREATE OR REPLACE FUNCTION` cannot change an existing
function's return type at all (`cannot change return type of existing
function`) -- confirmed live, attempting the same `psql -f`
re-application items 61/62 used for a body-only change failed outright
this time. A signature change needs the function actually dropped and
recreated, which (per item 62's own first bug) requires manually
walking the extension-membership bookkeeping again since a plain `DROP
FUNCTION`/re-`psql -f` cycle leaves the new object unregistered exactly
like a brand-new function does:

```sql
ALTER EXTENSION allgres DROP FUNCTION allgres_public.fn_admin_execute_sql(text);
DROP FUNCTION allgres_public.fn_admin_execute_sql(text);
-- (re-run sql/operator_accounts_and_chat.sql, e.g. psql -f)
ALTER EXTENSION allgres ADD FUNCTION allgres_public.fn_admin_execute_sql(text);
ALTER FUNCTION allgres_public.fn_admin_execute_sql(text) OWNER TO allgres_owner;
```

`sql/grants_and_facade.sql` also needed re-applying in the same pass
(its `dashboard_rpc` branch referenced the old `row_data` column name,
confirmed live as `column "row_data" does not exist` when skipped) --
`dashboard_rpc`'s own signature didn't change, so that file's own
re-application needed no extension-membership dance, only
`fn_admin_execute_sql`'s did.

Verified: direct SQL calls confirmed correct column order for a
multi-column single row, a multi-row result, a bare `SELECT now();`
(trailing `;`, one column), DDL, and DML with `RETURNING` (now also
`{"cols":...,"rows":...}`-shaped rather than a bare keyed object, for
consistency); a genuine multi-statement attempt still cleanly rejected.
Confirmed the full `dashboard_rpc` path end to end with a real admin
session token. Fresh install (`DROP EXTENSION ... CASCADE` → `CREATE
EXTENSION`) plus `fn_selftest()` across two separate connections both
report `"failed": 0, "passed": 333`; `cargo test --lib
--no-default-features --features pg16` still 30/30. Live Playwright
re-check through the real dashboard UI as a genuine admin account:
`SELECT 3 AS zebra, 1 AS apple, 2 AS mango` now renders columns
`ZEBRA | APPLE | MANGO`, in that order. A throwaway admin account
created for this verification was deactivated and deleted afterward.

## 64. `<select>` dropdowns rendered visibly taller than buttons and inputs next to them

Reported directly: dropdown boxes looked inconsistent in height next to
other controls on the same row (the SQL console page's own provider
picker, Settings' "Apply provider/model to every agent" panel, and every
other `<select class="select">` in the file, all sharing one CSS rule).
Measured before touching anything, rather than guessing at a fix: on the
same row, `.select` rendered `38px`, `.input` `41px`, `.btn` `36px` --
`.btn` already had an explicit `min-height:36px` in the file's own
"override" stylesheet (added, per that stylesheet's own header comment,
specifically to restore consistency after the dashboard source split);
`.input`/`.textarea`/`.select` never got the same treatment, left at
whatever `padding:9px 10px` plus each element's own native rendering
happened to produce.

Adding `min-height:36px` alone (matching `.btn`) closed most of the gap
(`.select` `38px` → still `38px`, `.input` `41px` → `36.8px`) but not all
of it for `<select>` specifically -- confirmed live via `getComputedStyle`
that `line-height` wasn't actually taking effect on the `<select>`
element the way it does on `<input>`/`<button>`, and that `appearance:
auto` (the browser's own native dropdown chrome, arrow icon included) was
still driving the element's real height independent of the CSS box model
PostgreSQL's -- Allgres's own stylesheet -- was trying to set. Confirmed
directly: setting `appearance:none` plus an explicit `height:36px` (not
just `min-height`) closed the remaining gap to an exact match, in an
isolated test page before touching the real file.

Fixed by giving `.select` `-webkit-appearance:none;-moz-appearance:none;
appearance:none` (removing the native dropdown chrome entirely, which is
what was resisting a pure-CSS height match) plus an explicit `height:
36px`, with a small inline SVG chevron (`background-image`, a data URI,
inside the file's own nonce'd `<style>` block -- not an inline `style=`
attribute, so item 60's CSP fix doesn't apply here and doesn't need to)
replacing the native arrow that `appearance:none` removes, positioned via
`background-position` with matching right-padding so text never runs
under it. One fixed arrow color (`#8b949e`) rather than a separate one
per theme -- confirmed live it reads clearly against both the dark and
light theme's own panel backgrounds, and a single value is simpler to
maintain than duplicating the rule under `:root[data-theme="light"]` for
a purely decorative affordance.

Verified: `getBoundingClientRect().height` on the same three elements
(`#bulkProvider` select, `#bulkModel` input, `#bulkApply` button) now
reads `36 / 36.8 / 36` (was `38 / 41 / 36`) -- the remaining sub-pixel
input difference is font-metric rounding, not a visible gap. Live
Playwright screenshots in both dark and light theme confirm the chevron
renders correctly and the row reads as one consistent height by eye, not
just by the numbers. `cargo test --lib --no-default-features --features
pg16` still 30/30; `fn_selftest()` still `"failed": 0, "passed": 333`
(sanity-checked even though this is a CSS-only change touching no SQL).
No CSP violation traced to the new rule specifically -- confirmed by
diffing the unique violation set before and after, all pre-existing item
60 noise. A throwaway admin account created for this verification was
deactivated and deleted afterward.

## 65. Login screen showed no "Allgres" branding at all

Reported directly: the login gate (`renderLogin()`, in front of the whole
app) just showed "Sign in" with no product name anywhere on screen. Root
cause was structural, not missing markup: the sidebar's own `.brand`
("Allgres") and `.tag` ("Postgres Is All You Need.") elements already
exist in the page, but they live inside `<div class="app">`, which
`renderLogin()` itself hides (`$('.app').classList.add('hidden')`) before
showing the login `#modal` -- so pre-login, nothing carrying the product
name was ever visible.

Fixed by reusing the same `.brand`/`.tag` elements (not new ones) inside
the login dialog itself, in `renderLogin()`
(`web/index.html`): `<div class="brand">Allgres</div><div class="tag"
style="margin-bottom:20px">Postgres Is All You Need.</div>` ahead of the
existing "Sign in" heading. The `margin-bottom:20px` value is a new
`style="..."` attribute, so per item 60's now-documented rule this
requires its own attribute-selector rule in the CSP override `<style>`
block -- added (`[style="margin-bottom:20px"]{margin-bottom:20px}`)
rather than skipped.

Verified live: served the built `web/index.html` (nonce substituted,
matching the real `Content-Security-Policy: style-src 'nonce-...'`
header from `src/web.rs`) and loaded it in Playwright. `boot()`'s own
`auth.me` RPC fails with no backend running, which already falls through
to `renderLogin()` the same way a logged-out real session would.
`getComputedStyle(tagEl).marginBottom` read `20px` (matching the
attribute, not `0px`) confirming the new attribute-selector rule was
live, not just present in markup -- the same check item 60 established
as necessary after a prior fix looked right by eye but wasn't applied.
Screenshot confirms "Allgres" / "Postgres Is All You Need." render above
the sign-in form. No SQL changed; no Rust rebuild needed for this
HTML/CSS-only change.

## 66. Long chat/messenger threads looked cut off at the bottom instead of showing the newest message

Reported directly: once a thread (General/Project chat, Messenger) grew
past the fixed-height scroll box it's rendered into (`#chatThread`/
`#projectChatThread`/`#msgFeed`, each `max-height:...vh;overflow:auto`),
the newest message was invisible below the fold. Root cause: each of the
three render functions (`renderChatThread`, `renderProjectChatThread`,
`renderMessengerFeed`) fully replaces the container's `innerHTML` on
every call -- initial page load, right after the viewer's own send, and
every 1.5s poll tick for an async reply -- and a browser resets a
scrollable element's `scrollTop` to `0` whenever its content is replaced
this way, so the box stayed pinned to the *oldest* visible message
instead of following new ones in.

Fixed with one shared helper (`scrollBottom(id)`, next to `esc`/`toast`)
setting `el.scrollTop = el.scrollHeight` after each render, called from
all three functions right after their `innerHTML` assignment -- same
"stick to bottom" behavior as any ordinary chat UI, no per-thread special
case.

Verified live: served the built `web/index.html` (nonce substituted,
real `style-src`/`script-src` CSP header from `src/web.rs`) under
Playwright, with `/api/v1/rpc` and `/api/v1/settings` intercepted to
return a logged-in admin and 40 synthetic `chat.history` messages
(mocking the network layer only -- the served HTML/JS/CSP is the real,
unmodified shipped file). After navigating to Chat, `#chatThread` showed
all 40 bubbles and read `scrollTop === scrollHeight - clientHeight`
(within float rounding) -- pinned to the bottom, message 40 visible in
the screenshot, not message 1. No SQL changed; no Rust rebuild needed
(the same `include_str!`-embedded `web/index.html` a real `allgres web`
worker serves, verified once already for item 65's CSP/nonce handling).

## 67. Chat page centered into a Claude-style column, with a themed thin scrollbar

Requested directly: the chat page's panel stretched to `.main`'s full
width (up to 1500px), so message bubbles spread edge to edge on a wide
screen instead of reading as a narrow, centered conversation column the
way claude.ai's own chat does; the request also asked for a Chrome-style
scrollbar rather than each browser's own default. Asked which of two
scrollbar directions before building anything (a plain themed
Chrome-style scrollbar vs. a VSCode-style content-minimap one) rather
than picking one unasked -- the minimap direction doesn't map cleanly
onto a bubble list anyway (nothing to miniaturize the way a minimap
condenses lines of code); confirmed: the plain themed scrollbar.

Fixed in `web/index.html`:
- `chatPage()`'s own top-level markup now wraps the mode-switch buttons
  and `#chatModeBody` in one `<div class="chatPanel">` instead of
  rendering them straight into `#view` -- General/Messenger/Project all
  share this one wrapper, so switching modes doesn't need its own
  per-mode centering.
- New rule `.chatPanel{max-width:760px;margin:0 auto;width:100%}` in the
  file's override `<style>` block. `width:100%` alongside `max-width` is
  what makes this responsive with no media query needed: it centers with
  fixed side margins once the viewport is wider than 760px, and simply
  fills the available width below that (down to the existing `.main`
  breakpoints) -- confirmed live rather than assumed.
- Thin, themed scrollbars on the three chat scroll boxes
  (`#chatThread`, `#projectChatThread`, `#msgFeed`) via ID-selector
  `::-webkit-scrollbar*` rules (10px, transparent track, `--line`
  thumb, `--muted` on hover, rounded via `border-radius` +
  `background-clip:padding-box`) plus `scrollbar-width:thin` for
  Firefox. Targeting these by ID rather than a shared class needed no
  new `style="..."` attribute, so none of this touches item 60's
  CSP/attribute-selector list.

One bug caught before shipping: the thumb rules were first written as
the `background:var(--line)` shorthand: `getComputedStyle` on the real
pseudo-element (`getComputedStyle(el, '::-webkit-scrollbar-thumb')`,
which Chromium does support querying) came back with `background-color`
resolving to nothing even though the rule parsed -- rewriting it as the
`background-color:var(--line)` longhand fixed it. Root cause not fully
chased down (the shorthand expands fine in ordinary elements; something
about mixing it with the following `border`/`background-clip`
declarations on this vendor pseudo-element specifically didn't resolve
it) -- the longhand form is what every browser's own devtools examples
for this exact pattern use anyway, so this is the more idiomatic fix,
not just a workaround.

Verified live: served the built `web/index.html` (nonce substituted,
real CSP header) under Playwright with `/api/v1/rpc` mocked to a
logged-in admin and 40 synthetic messages, same harness as item 66.
- Wide viewport (1600px): `.chatPanel` measured `760px` wide with an
  equal `312px` gap on both sides of `.main` -- true centering, not
  eyeballed.
- Narrow viewport (500px, below the existing 900px sidebar-collapse
  breakpoint): `.chatPanel` filled the available width with equal
  `14px` margins matching `.main`'s own padding -- confirmed the same
  markup degrades correctly with no separate mobile-specific rule.
- `getComputedStyle(chatThreadEl, '::-webkit-scrollbar-thumb')
  .backgroundColor` read `rgb(50, 57, 70)`, matching
  `getPropertyValue('--line')` (`#323946`) exactly; `::-webkit-scrollbar`
  width read `10px`. This headless Chromium renders overlay scrollbars
  (`offsetWidth === clientWidth`, no reserved gutter), so a plain
  screenshot doesn't show the thumb the way a classic-scrollbar browser
  would -- the computed-style check above is what actually confirms the
  rule takes effect, not a screenshot by eye.

No SQL changed; no Rust rebuild needed (HTML/CSS-only, same
`include_str!`-embedded file items 65/66 already established this
verification method for).

## 68. The 'general' agent's seoul-weather tool call was silently rejected as "not permitted" -- for every user, admin included

Reported directly, from a real chat transcript: asking the 'general'
agent about Seoul weather made it emit `{"action":"call_tool","name":
"seoul_weather","args":{}}`, then reply that the tool call "isn't
permitted" and suggest checking wttr.in manually. Read as a permissions
bug at first (the human account was admin), but the human's own role was
never in play here -- tool/procedure grants in this system are per
*agent*, not inherited from the operator's dashboard role at all (see
docs/procedures.md), and 'general' already held the right grant
(`resource_type = 'procedure', resource_ref = 'seoul-weather'`, seeded in
`sql/seed_data.sql` and asserted by selftest's own
`general_agent_seeded_with_seoul_weather_procedure` case). So the grant
was correct; something else was rejecting the call.

Root cause, found by reading `fn_next_step`'s own `call_tool` branch
(`sql/control_plane.sql`): it reads the tool name from
`v_parsed->>'tool'` -- but the transcript's own JSON used the key
`"name"`, not `"tool"`. With `"tool"` absent, `v_tool` is `NULL`,
`agent_has_permission(..., 'tool', NULL)` is false, the
procedure-tool-binding fallback lookup (`lower(pt.name) =
lower(COALESCE(v_tool, ''))`) matches nothing either since there is no
tool named `''`, and the call falls into the exact same `tool_not_
permitted` branch a genuinely-unauthorized tool name would -- which is
why it read like a permissions failure instead of a malformed-request
one. Traced back further: 'general's own seeded system prompt (`sql/
seed_data.sql`) never documented `call_tool`'s shape at all -- its
`Allowed:` block only ever listed `final_answer`/`await_human`, on the
original design assumption (this agent's own comment, until this fix)
that 'general' would "never" need `execute_sql`/`call_tool`. The later
seoul-weather procedure grant (further down the same file) broke that
assumption without anyone going back to update the prompt: it hands
'general' a real callable tool and tells it, in the procedure's own
prose, to "call the `seoul_weather` tool" -- but never shows the model
the exact JSON field name (`"tool"`, not e.g. `"name"`) required to do
that, unlike the 'analyst' agent's prompt, which has documented
`{"action":"call_tool","tool":"http_get","args":{"url":"https://..."}}`
correctly since it was written. The model picked a plausible key on its
own and guessed wrong -- not a bug in the model, a gap in what it was
told.

Fixed in `sql/seed_data.sql`: 'general's seeded prompt now documents
`{"action":"call_tool","tool":"...","args":{}}` in its `Allowed:` block,
plus a line telling it to use call_tool with the exact granted tool name
in the `"tool"` field when a procedure names one -- the same shape
'analyst' already uses, not a new one invented for this. The stale
comment claiming 'general' never offers call_tool was corrected in the
same commit (this file's own create-only-data policy means an existing
install's already-seeded prompt does not pick this up by re-running the
file -- see this file's own header comment -- so an operator upgrading an
existing install needs to update the stored prompt directly, e.g.
through the dashboard's own SQL console (item 61) or the Agents page's
edit-policy UI, both of which end up calling the same
`allgres_public.fn_set_policy`).

Verified: rebuilt and reinstalled (`cargo pgrx install --no-default-
features --features pg16`); fresh install's `fn_selftest()` read
`"failed": 0, "passed": 332` across two separate `psql` connections,
`general_agent_seeded_with_seoul_weather_procedure` still `ok: true`
(unaffected -- it asserts the permission grant, not the prompt text);
`cargo test --lib --no-default-features --features pg16` still 30/30.
Reproduced the exact failure directly against `fn_submit_result` before
fixing anything: a `call_tool` parsed result using `"name"` instead of
`"tool"` returned `{"action":"continue"}` with an `execution_logs` row
`{"reason":"tool_not_permitted","tool":null}` -- the same shape the
live transcript showed. Then confirmed the fix's target shape actually
resolves: the same call with `"tool":"seoul_weather"` (what the
corrected prompt now teaches the model to send) returned a real queued
call, `{"action":"call_tool","tool":"http_get","args":{"url":
"https://wttr.in/Seoul?format=j1"},"call_id":"..."}` -- the procedure-
tool-binding fallback resolving 'seoul_weather' to its bound `http_get`
handler and fixed URL exactly as designed. No Rust changed.

## 69. Removed the extension-upgrade-path machinery entirely -- this project never shipped a real release to upgrade from

Requested directly, on explicit direction: this repository's own version
history (items 4, 18, 19) built a genuinely real, tested `ALTER EXTENSION
... UPDATE` path -- `scripts/gen-upgrade.sh`, a frozen `sql/allgres--
0.2.0.sql` base snapshot (item 18), and an `ALTER ROLE`/`SCHEMA ...
RENAME` migration in `sql/control_plane.sql` (item 19) to carry a real
prior install's data through the project's own rename from its original
name, Argo, to Allgres. All of it was already dormant: the version-number
note at the top of this file already recorded that "this project has
never had an actual release" and that the crate version was reset to
`0.1.0` with no release ever shipped under it -- `docs/testing.md` said
the same thing about why upgrade testing was never wired into CI. There
was no real Argo-named install anywhere to migrate, and no real 0.2.0
install to upgrade from; the whole apparatus was protecting against a
scenario that had never actually happened. Rather than keep carrying
tested-but-purposeless infrastructure into what is now genuinely this
project's first real launch (`0.1.0-alpha`), it is gone:

- Deleted `sql/allgres--0.2.0.sql` (the frozen pre-rename snapshot --
  itself already found stale during an unrelated dead-code sweep this
  session: it still referenced the old `argo_public.*` names in two
  places, confirming nothing had touched it in a long time) and
  `scripts/gen-upgrade.sh`.
- Removed the `ALTER ROLE argo_owner RENAME`/`ALTER SCHEMA argo_private/
  argo_public RENAME` migration block from the top of "1. Roles" in
  `sql/control_plane.sql` (roughly 110 lines including its own review-
  history comment), and the role-attribute-renormalization block right
  after it that existed only to fix up a renamed role's `LOGIN`/`INHERIT`
  attributes -- both now unreachable dead code with the rename path gone,
  since `CREATE ROLE ... NOLOGIN NOINHERIT` already sets these correctly
  on first creation and there is no more rename path that could leave
  them wrong.
- Removed the `cp -f sql/allgres--*.sql ...` steps that placed frozen
  base snapshots and generated upgrade scripts into the extension
  directory, from both `Dockerfile` and `.github/workflows/ci.yml` --
  `cargo pgrx install` already writes the current version's own
  fresh-install script; there is nothing else to place now.
- Removed the "업그레이드 (upgrade)" not-automated note from
  `docs/testing.md` and the whole "## Upgrades" section from
  `docs/deployment/source-install.md`, and reworded README.md's feature
  list and documentation table to drop the upgrade-path claim, keeping
  the still-real backup/restore drill claim.
- Rewrote this file's own top "Status as of" line and version-number
  note: no longer claims `0.3.0` or an `ALTER EXTENSION ... UPDATE TO
  '0.3.0'` verification: the version is `0.1.0-alpha`, this project's
  actual first launch, and items 4/18/19's upgrade-path/rename content is
  now historical record of removed work, not a description of anything
  still in the codebase.

What was deliberately left alone: the unrelated "Drop objects whose
signature or return type changed since 0.1.0" block further down in
`sql/control_plane.sql` (`DROP FUNCTION IF EXISTS ...` for a handful of
functions) -- that exists so this same file can be safely replayed
against a database that already has an earlier iteration of *this*
0.1.0-alpha development cycle installed (ordinary `cargo pgrx install`
iteration, not a cross-version upgrade), which is still a real, needed
case; only the cross-version/cross-rename machinery was removed.

Verified: rebuilt and reinstalled (`cargo pgrx install --no-default-
features --features pg16`) -- confirmed only `allgres--0.1.0.sql` (no
stray `allgres--0.2.0.sql`) lands in the extension directory now. Fresh
install's `fn_selftest()` read `"failed": 0, "passed": 332` across two
separate `psql` connections. Confirmed live that `allgres_private`/
`allgres_public`/`allgres_owner` and the four scoped roles
(`allgres_role_admin`, `allgres_signal_admin`, `allgres_settings_reader`,
plus `operator`/`worker`/`sandbox`) all come out with the correct
NOLOGIN/NOINHERIT attributes on a fresh install with the renormalization
block gone. `cargo test --lib --no-default-features --features pg16`
still 30/30. Grepped every tracked file for `argo`/`Argo` afterward: the
only remaining hits are this file's own historical entries (items 4, 18,
19, here) and one unrelated coincidence in `sql/selftest.sql` -- the
sandbox-allowlist test's fixture list includes the literal string
`'select * from ARGO_PRIVATE.SESSIONS'` as an example of a schema name
that is *not* on the allowlist (a plausible-looking name that happens to
share the old project's name, not a reference to the removed rename
machinery) -- left as-is.

## 70. v2 redesign, Phase 1: a real PostgreSQL role per user, chained to every agent that user creates

First slice of the "권한 시스템" redesign (`claude/allgres-v2-redesign` branch):
real Postgres ROLE-based privilege, not just the procedural `permissions`
table + `agent_has_permission()` checks every SECURITY DEFINER function
runs today. The end goal is real `GRANT`/RLS enforcement once agents call
real PL/pgSQL functions/procedures under their own identity; this phase is
just the foundation those later phases build on -- creating the roles and
chaining them correctly, nothing yet actually gated by them.

Discovered before writing anything: agents already have their own real
PostgreSQL role (`fn_provision_agent_role`, `allgres_agent_<uuid>`,
`sql/operator_agents_and_policies.sql`) -- built for an unrelated reason
(PostgreSQL refuses `SET ROLE` inside a `SECURITY DEFINER` function, so
`execute_sql`'s sandbox validates in one DEFINER call and executes in a
second, non-DEFINER one, issued top-level by the runtime worker, where
`SET LOCAL ROLE` is legal -- item 1). The redesign's own working plan had
assumed agents would carry no PostgreSQL identity at all, only users would
-- reading the actual code first turned up a real, load-bearing mechanism
already doing exactly what a from-scratch design would have had to
reinvent. Kept it rather than ripping it out: an agent is, in effect, an
AI identity subordinate to whichever real human made it -- the same shape
a service account under a human owner has anywhere else -- so the existing
per-agent role is the right unit to chain under a new per-user role, not
something to replace.

Added:

- `allgres_private.users.pg_role` (mirrors `agents.pg_role` exactly) and
  `allgres_private.fn_provision_user_role(uuid)`, owned by
  `allgres_role_admin` (the one role scoped to `CREATEROLE`, never
  `allgres_owner` -- same reasoning `fn_provision_agent_role` already
  documents). Creates `allgres_user_<uuid>`, `NOLOGIN`. `fn_create_user`
  calls it for every new account and returns `pg_role` alongside the
  existing fields.
- `allgres_private.agents.created_by_user_id` (nullable; NULL for every
  system agent and for 'general', a shared front door rather than any one
  user's possession -- non-NULL only for a user-defined agent). Added
  *after* the `users` table in `sql/control_plane.sql`, not alongside
  `agents`' other columns further up the same file -- this file creates
  `agents` long before `users` exists, and the FK needs both.
- `fn_provision_agent_role` gained an optional `p_owner_pg_role text`
  parameter: when given, `GRANT`s that role to the new agent's role right
  after creating it, applied only on first provisioning (an agent's owner
  is fixed at creation, never reassigned). `fn_create_agent` gained a
  matching optional `p_creator_user_id uuid`, resolves that user's own
  `pg_role`, and passes it through.

One real bug caught by the verification loop, not by review: the first
version of `fn_provision_user_role` followed a false analogy to how
`sandbox`/`worker` membership is granted in "12. Grants" (`GRANT sandbox
TO allgres_role_admin WITH ADMIN OPTION`, needed there because those are
*pre-existing* fixed roles `allgres_role_admin` never created) and tried
`GRANT <new user role> TO allgres_role_admin WITH ADMIN OPTION` right
after creating it. That failed outright on the very first `fn_create_user`
call in a fresh install's own `fn_selftest`: `ERROR: ADMIN option cannot
be granted back to your own grantor` -- creating a role already makes the
creator its grantor, so re-granting it back to itself is a cycle
PostgreSQL refuses. Confirmed live (a `SET ROLE allgres_role_admin`
session, `CREATE ROLE` a probe role, `GRANT` it straight to a second probe
role with no self-grant in between) that no such step is needed at all:
`CREATEROLE` plus having created a role is already sufficient to grant
that role to anyone else. Removed the erroneous self-grant entirely rather
than working around the error.

Verified: rebuilt and reinstalled (`cargo pgrx install --no-default-
features --features pg16`); fresh install's `fn_selftest()` read `"failed":
0, "passed": 332` across two separate `psql` connections; `cargo test
--lib --no-default-features --features pg16` still 30/30. Then the actual
mechanism, live, not just "it installs": created a real user
(`fn_create_user`) and a real agent owned by it (`fn_create_agent` with
`p_creator_user_id` set), confirmed via `pg_auth_members` that the agent's
role is a member of both `sandbox` (unchanged baseline) and the new user
role; `GRANT`ed `SELECT` on a throwaway probe table to the user role only,
then confirmed under `SET ROLE <agent's role>` the `SELECT` succeeded
(inherited from the owner, nothing granted to the agent directly) while
`SET ROLE sandbox` on the same table correctly hit `insufficient_privilege`
-- the grant reached exactly the intended chain and nowhere else. Probe
table and roles dropped afterward.

Not yet done, later phases: nothing actually runs under `SET ROLE
<owner>` yet (this phase only makes the chain exist); the Function/
Procedure layer itself (real `SECURITY INVOKER` PL/pgSQL, replacing the
current `procedure_tools`/`call_tool` shape); the chat-driven "ask general
to create an agent for me" flow regular users would actually reach
`fn_create_agent`'s new parameter through; and the `permissions` table's
own redefinition as a GRANT mirror rather than the enforcement source it
still is today.

## 71. v2 redesign, Phase 2: retired the `orchestrator` agent; system agents are no longer dashboard-editable at all

Two independent pieces of the "에이전트 모델" redesign.

**`orchestrator` removed.** Investigated before touching anything, since
the working plan had assumed it needed replacing with a new "system
function" once one existed (Phase 3): reading `fn_messenger_post`'s actual
code showed it never did real multi-agent routing at all -- delivery to
every `@mentioned` agent already happens unconditionally, in text order;
`orchestrator` only ever got a one-shot advisory task queued alongside
that, whose own `final_answer` nothing downstream ever reads or acts on
(the function's own comment: "delivery above already happened in text
order regardless... a real reordering-before-delivery pass is future
work"). Two of this file's own earlier comments (task-orchestration.md,
and two spots in `sql/control_plane.sql`) claimed `orchestrator` used
`delegate` for this -- checked against its actual seeded prompt and it
never did; corrected rather than left stale. Confirmed nothing else
depended on it before deleting: removed the seed block (`sql/seed_data.
sql`), `allgres_private.queue_orchestrator_opinion` (`sql/control_plane.
sql`), the `fn_messenger_post` branch that called it, the `web/index.html`
UI for its one `agent_config` field (`min_mentions_to_route`, also
dropped from `validate_agent_config`'s known-key list), and the three
selftest cases that only ever exercised this dead path -- one selftest
case (`agent_config_rejects_out_of_range_known_key`) that happened to use
`min_mentions_to_route` purely as a convenient known-integer-range example
was repointed to `compaction_keep_recent` instead, unrelated to
orchestrator itself. Four system agents remain (`session_compactor`,
`creator`, `fixer`, `self_improve`, under the shared `system_root`), down
from five.

**System agents are now fully locked out of dashboard editing**, not just
admin-gated. Before this, `agents.update`/`policy.rollback`/
`permissions.grant`/`permissions.revoke` on a system-agent target required
`require_admin_for_system_agent` (an admin session) -- an admin *could*
edit a system agent's prompt, config, or grants straight from the
dashboard. On explicit direction, this is now a hard `RAISE EXCEPTION`
(`allgres_private.forbid_system_agent_edit`, new), admin session or not:
changing a system agent's identity now requires a direct database
connection. One deliberate carve-out, confirmed with the user before
building it: `agents.set_autonomy` stays exactly as it was
(`require_admin_for_system_agent`, admin-gated but not blocked) --
`autonomy_level` is an ordinary operator dial (this is the one thing
admins actually tune on `creator`/`fixer`/`self_improve` day to day from
the Agents page), not an identity edit, and locking it too would remove
the only reason that field has a dashboard control at all.
`web/index.html`'s Agents edit modal reflects this directly rather than
just relying on the backend rejection: a system-agent target now renders
every identity field (`name`, prompt, provider/model, step/retry/
concurrency limits, active toggle, `agent_config`) `disabled`, shows a
banner explaining why, hides the permission grant form and every
`Revoke` button, and `historyModal` hides its `Rollback to this version`
button for a system agent -- only the `Autonomy level` field stays live,
and Save is relabeled "Save autonomy level" for that one case.

Verified: rebuilt and reinstalled; fresh install's `fn_selftest()` read
`"failed": 0, "passed": 330` across two separate `psql` connections (down
from 332 -- three orchestrator-only cases removed, two new
system-agent-lockout cases added, net one existing case repointed rather
than removed); `cargo test --lib --no-default-features --features pg16`
still 30/30. Live, not just selftest: confirmed `orchestrator` seeds zero
rows on a fresh install and exactly four `is_system` agents besides
`system_root` exist; called `agents.update` against `creator` (a real
system agent) with a real admin session and confirmed `{"ok":false,
"error":"system agents cannot be edited from the dashboard..."}`, with
the prompt actually unchanged afterward, while `agents.set_autonomy`
against the same agent with the same session still succeeded. UI: served
the built `web/index.html` (nonce substituted, real CSP header) under
Playwright with `/api/v1/agents` mocked to one system and one ordinary
agent -- opening the system agent's edit modal showed the banner, every
identity field's `disabled` property `true`, no grant form, no `Revoke`
button, `Autonomy level` present and enabled, and the Save button
relabeled; the ordinary agent's modal was unaffected on every one of
those same checks.

## 72. v2 redesign, Phase 3a: renamed "Tool" to "Function" throughout, including the `call_tool`/`tool` wire protocol keys

Pure rename, no behavior change -- prep work before Phase 3b (real
PL/pgSQL Function bodies), 3c (Procedure -> real `CREATE PROCEDURE`), and
3d (an MCP-client Function handler), all still to come. "Tool" was a
confusing name once agents can author their own callable units and call
other agents too -- the user asked for "Function" throughout, including
the JSON the LLM actually emits, not just internal naming.

Renamed: table `allgres_private.procedure_tools` -> `allgres_private.
functions` (PK `tool_id` -> `function_id`); `procedure_tool_bindings` ->
`procedure_function_bindings`; `fn_create_procedure_tool` -> `fn_create_
function`; `fn_bind_procedure_tool` -> `fn_bind_procedure_function`;
`outbound_calls.procedure_tool_id`/`.kind = 'tool'` -> `.procedure_
function_id`/`.kind = 'function'`; `model_experiments.tool_id` ->
`.function_id`; `change_proposals.target_tool_id`/`kind = 'tool_
override'` -> `.target_function_id`/`'function_override'`;
`apply_tool_experiment_start/promote/reject` -> `apply_function_
experiment_*`; `fn_set_tool_override_autonomy_preset` -> `fn_set_
function_override_autonomy_preset`; `agent_config` keys `tool_override_
self_approve_canary_cap`/`tool_override_auto_promote_slack_pct` ->
`function_override_*`; `execution_logs.role = 'tool'` -> `'function'`;
`permissions.resource_type = 'tool'` -> `'function'`. Wire protocol: the
LLM's `{"action":"call_tool","tool":"...","args":{...}}` is now
`{"action":"call_function","function":"...","args":{...}}`; reason
strings `tool_not_permitted`/`unknown_tool` -> `function_not_permitted`/
`unknown_function`; result type `tool_result` -> `function_result`.
dashboard_rpc actions: `procedure_tools.list`/`.create`/`.bind` ->
`functions.list`/`.create`/`.bind`; `tool_experiments.list` -> `function_
experiments.list`; `agents.set_tool_override_autonomy_preset` -> `agents.
set_function_override_autonomy_preset`. `sql/rpc_catalog.json`
regenerated (`scripts/gen_rpc_catalog.py`) and the two frozen-catalog
arrays in `fn_selftest` updated to match, same commit. `web/index.html`:
the permission-type picker's `tool` option, `opts.tools`/`state.
toolExperiments`, the "Tool model experiments" panel, and every RPC/field
reference that follows from the renames above. `src/outbound.rs`/`src/
runtime_worker.rs`: the two `kind == "tool"`/`json!("tool")` string
comparisons that classify an outbound call (no Rust identifier was ever
named "tool" -- confirmed by grep before changing anything). Docs
(`procedures.md`, `security.md`, `architecture.md`, `sql-sandbox.md`,
`system-agents.md`, `memory-and-search.md`, `README.md`) updated to
match; `procedures.md`'s own "Procedure tool functions" section also
dropped a stale claim of a "Settings -> Procedure tool functions" UI
panel that was never actually built (a real doc/implementation mismatch,
unrelated to this rename, fixed while already touching this file) in
favor of naming the `functions.create`/`.bind` dashboard_rpc actions
directly. `KNOWN_ISSUES.md` itself (this file) is left untouched for
every *past* entry -- it is a dated engineering log of what happened at
the time, not a document that tracks current naming, so old entries keep
saying "tool" where that was the real name when they were written.

Mechanical approach: rather than hand-editing ~600 occurrences across six
`sql/*.sql` files, wrote a small Python script (substring replacement, no
regex) with a short list of explicit pre-rules for the two cases a pure
`tool -> function` swap would get wrong -- the bare table name needing
its `procedure_` prefix dropped entirely (-> `functions`, not `procedure_
functions`), and preventing the pre-existing `v_tools` and `v_procedure_
tools` local variables (two distinct declarations in the same `fn_next_
step` scope) from both collapsing onto the same `v_functions` name, which
would have been a genuine duplicate-variable compile error -- then a
blanket `tool`/`Tool` -> `function`/`Function` substring sweep for
everything else. Reviewed the full diff afterward rather than trusting
the script blindly: caught and hand-fixed three "Tool Function" ->
"Function Function" doubled-word artifacts in comments (should just read
"Function"), confirmed zero accidental matches inside unrelated English
usage (`docs/deployment/source-install.md`'s "the tool" meaning
`cargo-pgrx`, `docs/self-improvement.md`'s "wrong tool for judging" idiom,
`sql/operator_accounts_and_chat.sql`'s "admin-only power tool" idiom --
all three grepped for and confirmed untouched), and grepped the whole
repo afterward for a residual case-insensitive `tool` in every `sql/`,
`src/`, and `web/index.html` file: zero matches outside those three
confirmed-unrelated idioms.

Verified: rebuilt and reinstalled; fresh install's `fn_selftest()` read
`"failed": 0, "passed": 331` across two separate `psql` connections
(identical on both); confirmed via `git diff` that the number of defined
test cases in `sql/selftest.sql` is unchanged at 295 before and after
(the rename touches names, not test count -- a small run-to-run
difference in the *passed* count against Phase 2's reported 330 appears
unrelated to this change, since no case was added, removed, or made
conditional by a pure identifier rename); `cargo test --lib --no-
default-features --features pg16` still 30/30. No separate live-HTTP
proof beyond `fn_selftest` for this entry: nothing about permission
logic, role scoping, or worker behavior changed, only names, and the
existing selftest suite already exercises every renamed call path
(function permission grants, procedure-bound function calls, the canary
experiment lifecycle, the frozen RPC catalog) under both its "should
succeed" and "should be rejected" cases.

## 73. v2 redesign, Phase 3b: real PL/pgSQL Functions -- SECURITY INVOKER, built and called under the calling agent's own role

Added a second Function handler, `plpgsql`, alongside the existing
`http_get`. Confirmed with the user before building: it must be authorable
and editable from the dashboard, an agent must also be able to author one
for itself, and it must run under the calling agent's *own* Postgres
role so a real `GRANT` -- not a procedural check re-derived on every call
-- is what actually bounds it.

**Why this needed the same split `execute_sql`'s sandbox already has.**
PostgreSQL forbids `SET ROLE` inside a `SECURITY DEFINER` function, and
`dashboard_rpc`/`fn_submit_result` are `SECURITY DEFINER` (they run as
`allgres_owner`). So neither *building* a Function's real Postgres object
(which has to happen as a role that can `CREATE` in a dedicated schema,
not `allgres_owner`) nor *calling* it (which has to happen as the calling
agent's own role, not `allgres_owner`) can happen from inside those
functions. Both are instead queued and picked up by the runtime worker,
which issues them as genuinely top-level SPI statements -- exactly
`fn_run_sandboxed_sql`'s own pattern, applied twice: once for DDL, once
for the call.

**Schema (`sql/control_plane.sql`).** `allgres_private.functions` gained
`handler` widened to `('http_get', 'plpgsql')`, plus `body`,
`param_schema`, `sql_ident` (`fn_<function_id, dashes stripped>` --
derived from the row's own id, never the author-chosen `name`, so
renaming a Function never touches the real object or its grants),
`build_status` (`pending` / `building` / `built` / `failed`),
`build_error`, and `created_by_agent_id`, with a `CHECK` tying `handler`
to whether `body` is set. A new table, `allgres_private.function_calls`,
queues one *call* against an already-built Function -- deliberately not
folded into `outbound_calls` (which is HTTP-shaped: a mandatory `url`,
`method`, `headers` every row must carry, and picked up by the HTTP
thread pool), since a plpgsql call is a local `SET LOCAL ROLE` + `SELECT`
on the SPI thread, not an outbound request at all. Both new
tables/queues get the same claim/complete/`'lost'`-on-timeout shape
`outbound_calls`/`sql_calls` already use (`fn_claim_function_builds`,
`fn_complete_function_build`, `fn_claim_function_calls`,
`fn_complete_function_call`, plus two new `fn_watchdog` reclaim loops --
a stuck `'building'` row resets to `'pending'` rather than staying stuck
forever, since there is no task to notify for a build).

A new role, `allgres_function_admin` (`NOLOGIN`, owns nothing but `CREATE`
on a new schema, `allgres_functions`), owns every dynamically-built
Function object -- scoped this narrowly rather than handed to
`allgres_owner`, the same reasoning `allgres_role_admin`'s own comment in
"1. Roles" already gives for `fn_provision_agent_role`: a bug in the one
function that does this dynamic `CREATE` should never also be a bug in
every other `SECURITY DEFINER` function `allgres_owner` owns. `worker` is
granted membership in `allgres_function_admin` (so it can `SET LOCAL
ROLE` to it, the same way it already can to `sandbox`), and `sandbox`
gets `USAGE` on `allgres_functions` (every agent role is already a member
of `sandbox`, which is what a call actually runs as when an agent
predates per-agent roles -- identical fallback to `fn_run_sandboxed_sql`).

**Authoring (`sql/operator_runtime_and_integrations.sql`).**
`fn_create_function`/`fn_update_function` widened to accept
`body`/`param_schema` for the `plpgsql` handler, validated by a new
`allgres_private.validate_function_body`: non-empty, under 20000
characters, and -- defense in depth, not the real boundary -- rejects a
body that tries to declare `SECURITY DEFINER` or change role. The real
boundary is the role switch at build/call time, which holds regardless of
what the body says about itself.

**Agent-authored Functions (`sql/control_plane.sql`'s `fn_submit_result`,
`sql/operator_agents_and_policies.sql`'s `fn_decide_proposal`).** New
actions `create_function`/`update_function`, deliberately *not*
restricted to one named system agent the way `create_agent` is restricted
to `creator` -- since a Function's real security boundary holds no matter
who authored the body, there is no equivalent reason to gate authorship
itself. Gated only by the calling agent's own `autonomy_level`, the exact
same `admin_approval` (queues a `change_proposals` row,
`kind='create_function'`/`'update_function'`) vs. `self_approve`/`auto`
(applies immediately) split `create_agent` already uses.
`fn_next_step`'s bounds gained a `create_function`/`update_function`
authoring guide (the required `p_args jsonb -> jsonb` signature, that
`SECURITY INVOKER` runs it under the caller's own role, what
`param_schema` means) so an agent can actually write a valid body, not
just be told the action exists.

**Calling one (`fn_submit_result`'s `call_function` branch).** When a
procedure-bound Function resolves to `handler = 'plpgsql'`, the call is
queued into `function_calls` with the agent's own `args` (unlike
`http_get`, never replaced by a fixed template -- the security property
here is the role switch, not fixing the arguments) and returns
immediately; a Function whose build is not yet `'built'` (`'pending'`,
`'building'`, or `'failed'`) is rejected up front with reason
`function_not_built`, never silently queued against a stale or
nonexistent `allgres_functions` object.

**Rust (`src/function_exec.rs`, new -- mirrors `src/sandbox.rs` closely).**
`pump_function_builds`: claims pending builds, dollar-quotes the body with
a tag verified absent from it (so arbitrary body content, including a
literal `$$`, is embedded verbatim with no further escaping needed or
possible), and runs `SET LOCAL ROLE allgres_function_admin; CREATE OR
REPLACE FUNCTION allgres_functions.<sql_ident>(p_args jsonb) RETURNS
jsonb LANGUAGE plpgsql SECURITY INVOKER AS <dollar-quoted body>;` as a
top-level SPI statement inside `run_in_subtransaction` (reused from
`sandbox.rs`, made `pub(crate)` for this). `pump_function_calls`: claims
queued calls, `SET LOCAL ROLE <the agent's own pg_role, or 'sandbox' as
fallback>`, then `SELECT allgres_functions.<sql_ident>($1::jsonb)` --
unlike `fn_run_sandboxed_sql`, no intermediate wrapper function is
needed, since the built Function *is* the sandboxed artifact, there is no
separately-validated SQL text to reshape. Both wired into
`runtime_worker.rs`'s existing pump loop, same tier as `pump_sql` (SPI
thread, one claim per tick, `SQL_STATEMENT_TIMEOUT_MS`-bounded).

**Wiring (`sql/grants_and_facade.sql`).** No new ownership-exclusion
entries needed -- the ownership-fixing passes scan only
`allgres_private`/`allgres_public`/`allgres`, never `allgres_functions`,
so a dynamically-built Function is never touched by them (confirmed by
reading the exact `WHERE n.nspname IN (...)` clause before assuming this,
rather than guessing). The four new claim/complete functions got explicit
`GRANT EXECUTE ... TO worker` (mirroring `fn_claim_sql`/`fn_complete_sql`
exactly); `fn_create_function`/`fn_update_function` needed no new grant at
all -- they're called only from functions `allgres_owner` already owns,
and the file's existing blanket `REVOKE EXECUTE ON ALL FUNCTIONS IN
SCHEMA allgres_public FROM PUBLIC` / `GRANT EXECUTE ON ALL FUNCTIONS IN
SCHEMA allgres_public TO operator` already cover anything newly defined
in an earlier-loaded file by the time this one runs last (confirmed by
reading those two statements' exact scope before assuming a per-function
grant was needed). `functions.list`/`functions.create` extended with
`body`/`param_schema`/`build_status`/`build_error`; new
`functions.update` action; `rpc_catalog.json` regenerated and both frozen
arrays in `fn_selftest` updated to match.

**Caught a real table-ordering bug before the first build attempt** (the
same class of mistake CLAUDE.md's own written-down history already warns
about): first placed `function_calls` right next to `functions`/
`procedure_function_bindings`, early in "2. Schemas, tables" -- but its
`REFERENCES allgres_private.tasks(task_id)` failed with "relation
allgres_private.tasks does not exist", since `tasks` is not defined until
much later in the file. Fixed by moving the whole table (plus its index)
to right after `outbound_calls`'s own definition, which already needs
`tasks` and is therefore already correctly ordered after it.

**Caught a real selftest idempotency bug on the second, separate-
connection run** (again, exactly the class of bug CLAUDE.md's own history
warns this project has hit before): a new `call_function_rejects_a_
function_not_yet_built` test case granted the shared `analyst` fixture
(`v_agent`) a `procedure` permission and never revoked it. On a second
`fn_selftest()` call within the same database, that leftover grant made
`v_agent` already hold *a* procedure permission, which broke two
unrelated, textually-earlier tests that assume `v_agent` starts with
zero (`procedure_hidden_from_prompt_without_permission`,
`disabled_procedure_hidden_even_with_permission` -- both failed only on
the second run, passed on the first). Fixed by calling
`fn_revoke_permission` immediately after the test that needed the grant,
restoring `v_agent` to the state every other test assumes.

Verified: rebuilt and reinstalled; fresh install's `fn_selftest()` read
`"failed": 0, "passed": 338` across two separate `psql` connections,
identical both times (confirming the idempotency fix above actually
worked, not just that it compiled); `cargo test --lib --no-default-
features --features pg16` still 30/30. Live, beyond `fn_selftest` (this
phase genuinely needed it -- new external-call-shaped worker behavior and
new role-scoping, exactly what the verification loop calls out): created
a `plpgsql` Function whose body ran `SELECT count(*) FROM allgres_private.
llm_secrets` and confirmed it actually appeared in `pg_proc` owned by
`allgres_function_admin` with `security_definer = false`; drove a real
task through `fn_submit_result`'s `call_function` path as the seeded
`general` agent (falling back to the shared `sandbox` role, since a fresh
install's seeded agents have no per-agent `pg_role` yet) and confirmed the
execution log recorded `"function secret_probe failed: permission denied
for schema allgres_private"` -- a genuine Postgres permission error, not
a procedural rejection. Ran the identical pipeline with a second,
benign Function (`RETURN jsonb_build_object('answer', (p_args->>'x')::int
+ 1)`) and confirmed it returned `{"result": {"answer": 42}, "function":
"add_one"}` in the execution log, proving the positive path works and the
first result was a real permission boundary, not something broken more
generally. Also confirmed live that `DROP EXTENSION ... CASCADE` cleanly
drops every dynamically-built object in `allgres_functions` too (it
cascades through the schema, which the extension owns, regardless of who
owns the individual functions inside it) -- no orphaned objects survive
an uninstall. One environment-specific thing learned along the way, not a
bug: the "allgres runtime" worker connects to whichever single database
`ALLGRES_DATABASE` (or its default) names, set at `shared_preload_
libraries` load time -- a fresh `CREATE DATABASE` for verification has no
worker of its own unless dynamically started (`fn_start_dynamic_workers`,
which itself refuses to run when already statically preloaded), so live
Function-pipeline testing has to happen against the database the real
worker is actually attached to, not an arbitrary scratch database.

Deliberately not in this slice: no Settings UI for authoring a `plpgsql`
Function (same gap `http_get` already had, per Phase 3a's own note); an
MCP-client handler (Phase 3d); Procedure becoming a real `CREATE
PROCEDURE` that calls Functions in code (Phase 3c); `call_llm()` for a
future Procedure body's own mid-pipeline judgment calls (Phase 3e).

## 74. v2 redesign, Phase 3c: Procedure becomes a real `CREATE PROCEDURE` that calls Functions in code

`allgres_private.procedures` gains the exact same `body`/`sql_ident`/
`build_status`/`build_error` shape Phase 3b already gave
`allgres_private.functions`, plus a `run_procedure` action, so a
procedure is no longer only free-text guidance (`content`, unchanged) an
agent reads and acts on call by call -- it can now be real PL/pgSQL code
that runs to completion in one step. `content` and `body` are
independent; a procedure with no `body` behaves exactly as before.

**Design decision, confirmed with the user before building it, and
worth writing down because it simplified the whole phase**: a
Procedure's own body calling a bound Function does *not* need a second
queue/`SET ROLE` round trip. Phase 3b's queue exists purely to get a
Function call *into* a role-scoped SPI session in the first place
(`dashboard_rpc`/`fn_submit_result` are `SECURITY DEFINER` and cannot
`SET ROLE` themselves). Once a Procedure's own `CALL` has already put the
worker into that session under the calling agent's role, a Function it
calls from inside its own body is just an ordinary nested SQL statement
in the same session -- no new plumbing needed for that at all. This is
also why the scope is bounded the way it is: an `http_get`/`http_request`
Function needs a real outbound HTTP round trip, which a single blocking
`CALL` cannot wait on without tying up the SPI thread, so a Procedure
body may only call something synchronous (another `plpgsql` Function,
ordinary SQL) -- calling an HTTP-shaped Function, and `call_llm()` for a
Procedure's own mid-pipeline judgment calls, both need a fundamentally
different (resumable) execution model and stay future work, unchanged
from Phase 3b's own note. Procedures also stay operator-authored only in
this slice, unlike Functions -- widening that is not asked for here and
kept out to bound scope.

**Schema/SQL, closely mirroring Phase 3b's own shape throughout**
(`sql/control_plane.sql`): `procedures.body`/`sql_ident`
(`proc_<procedure_id, dashes stripped>`)/`build_status`/`build_error`;
`procedure_history.body` alongside its existing `content`; a new
`allgres_private.procedure_calls` table, deliberately separate from
`function_calls` (a distinct queue per real object type, not because the
shape differs) and from `outbound_calls` (still HTTP-shaped, still not
what this is). `fn_claim_procedure_builds`/`fn_complete_procedure_build`/
`fn_claim_procedure_calls`/`fn_complete_procedure_call` mirror their
Function equivalents exactly, including two new `fn_watchdog` reclaim
loops. `execution_logs.role` gained `'procedure'` (distinct from
`'function'`, both still remapped to `'user'` for the LLM's own view) so
the audit trail says accurately which kind of call actually happened.
`fn_create_procedure`/`fn_set_procedure`/`fn_rollback_procedure`
(`sql/operator_agents_and_policies.sql`) widened for `body`, reusing
`allgres_private.validate_function_body` directly rather than adding a
same-behavior wrapper function with its own name (`allgres_private.
validate_procedure_body` would have been the third body-shape guardrail
with the same first two rules -- SECURITY DEFINER, SET ROLE -- with
nothing to justify a separate identity yet).

**`run_procedure` (`fn_submit_result`, new action, alongside
`call_function`)**: checks the same `'procedure'` permission a
procedure grant already requires to show its `content` at all, resolves
the named procedure, rejects `'procedure_not_permitted'` /
`'unknown_procedure'` / `'procedure_not_built'` (body `NULL` or
`build_status <> 'built'`) up front, then queues into `procedure_calls`
with the agent's own `args`. Result comes back once as a
`procedure_result`, handled in its own branch parallel to
`function_result` -- deliberately *not* wired into the existing per-
function/per-procedure model-override and canary-experiment machinery
(functions/procedures' own `llm_override`, `model_experiments`): that
system exists to pick a cheaper model for the *next* LLM turn's reasoning
about one function call's result, which has no equivalent for a batch
result a procedure's own code already finished acting on.
`fn_next_step`'s bounds gained a `run_procedure` guide alongside
`create_function`/`update_function`'s own.

**Rust (`src/procedure_exec.rs`, new -- mirrors `src/function_exec.rs`
almost exactly)**: `pump_procedure_builds`/`pump_procedure_calls`, wired
into `runtime_worker.rs`'s pump loop at the same tier as the Function
pair. `CREATE OR REPLACE PROCEDURE ... INOUT p_result jsonb ...
SECURITY INVOKER AS <dollar-quoted body>` for the build; `CALL
allgres_functions.<sql_ident>($1::jsonb, '{}'::jsonb)` for the call --
Postgres returns a procedure's `OUT`/`INOUT` parameters as a one-row
result exactly like a function's return value (documented behavior since
procedures were introduced in PG11), which is what let the identical
`Spi::get_one_with_args::<JsonB>` read work for both a `SELECT` and a
`CALL` with no new SPI-handling code. `dollar_quote`/`valid_sql_ident`
(the latter now taking a `prefix` argument, `"fn_"` or `"proc_"`) made
`pub(crate)` in `function_exec.rs` and reused rather than duplicated.

**Two real bugs caught during verification, both before this shipped:**

1. The new `run_procedure` authoring-guide text in `fn_next_step`'s
   prompt literally contained the substring `"# procedures"` inside an
   example (`"<name from # procedures below>"`) -- which is also the
   exact heading text the *conditional* procedures section uses,
   present in the prompt only when an agent actually holds a procedure
   grant. This made two long-standing, unrelated tests
   (`procedure_hidden_from_prompt_without_permission`,
   `disabled_procedure_hidden_even_with_permission`) fail on the very
   first `fn_selftest()` run, not a second-run idempotency issue like
   item 73's bug -- caught immediately rather than requiring a second
   connection to surface. Fixed by rewording the example to avoid the
   literal heading text.
2. A new `run_procedure_rejects_an_unknown_procedure` test assumed
   `run_procedure` would reach its "does this procedure exist" check
   before its permission check -- but permission is checked first (the
   same order `call_function` already uses), so a name the agent was
   never granted hit `'procedure_not_permitted'`, not
   `'unknown_procedure'`, and the test's assertion was simply checking
   the wrong reason string. Fixed by splitting it into two cases: one
   proving the ordinary "not granted" rejection
   (`run_procedure_rejects_an_ungranted_procedure`), and one that first
   grants a name matching no real procedure row (permissions have no FK
   to `procedures.name`) to actually reach `'unknown_procedure'`.

Verified: rebuilt and reinstalled; fresh install's `fn_selftest()` read
`"failed": 0, "passed": 345` across two separate `psql` connections,
identical both times; `cargo test --lib --no-default-features --features
pg16` still 30/30. Live, beyond `fn_selftest` (a new external-call-
shaped worker path and new role-scoping again, same reasoning as item
73): created a plpgsql Function (`proc_helper_double`, doubles its `n`
argument) and a Procedure (`double_and_check`) whose body called that
Function *directly in its own code* -- `v_r :=
allgres_functions.fn_<ident>(p_args);` -- then branched on the result
with a plain `IF`; granted it to the seeded `general` agent, drove a real
task through `run_procedure`, and confirmed the execution log recorded
`{"result": {"note": "small", "value": 14}, "procedure":
"double_and_check"}` for `n=7` -- the correct doubled value, correctly
branched, with no second queue round trip for the nested Function call
(confirmed by there being no corresponding `function_calls` row at all
for that call, only the one `procedure_calls` row). Separately created a
second Procedure whose body read `allgres_private.llm_secrets` directly
(no nested Function involved) and confirmed it failed with the identical
genuine `permission denied for schema allgres_private` a Function body
gets, proving the Procedure's own `SECURITY INVOKER` role-scoping
independently of Function-level role-scoping, not merely inherited by
association. Confirmed via `pg_proc` that both built objects showed
`prosecdef = false`, owned by `allgres_function_admin`, matching a
Function's own build.
