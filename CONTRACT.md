# Allgres dashboard/API contract

This is the frozen public surface of `allgres.dashboard_rpc` — every
`action` it accepts, one JSON object in, one JSON object out
(`{"ok": true, ...}` or `{"ok": false, "error": "...", "sqlstate": "..."}`).
It exists so adding, removing, or renaming an action is a visible,
deliberate act instead of silent drift an operator only discovers from a
404 in production.

## The generated catalog

`sql/rpc_catalog.json` is generated, not hand-maintained:

```bash
python3 scripts/gen_rpc_catalog.py   # rewrites sql/rpc_catalog.json
```

It lists every action with the guard function(s) its own `dashboard_rpc`
branch calls directly, and the `p_request` keys that branch reads.
`fn_selftest`'s `dashboard_rpc_actions_match_frozen_catalog` case carries
its own frozen copy of the action-name list and fails loudly if it and the
live `CASE` in `sql/control_plane.sql` ever disagree — that selftest case,
not this file, is what actually enforces the freeze. **Whenever
`dashboard_rpc`'s `CASE` changes: regenerate the JSON, update that
selftest case's array to match, and run `fn_selftest()` before
committing.**

## Guard classes

Every action falls into exactly one of these. A guard is invoked with the
request's `session_token` (or, for `providers.oauth_*`, resolved by other
means) and either raises (caught by `dashboard_rpc`'s own top-level
`EXCEPTION WHEN OTHERS`, returned as `{"ok": false, ...}`) or returns a
scope the branch then checks.

- **`require_admin`** (8 actions: `users.*`, `assignments.*`) — always
  requires a logged-in admin. No bootstrap exception; these only exist
  once the accounts system does.
- **`require_admin_if_accounts_exist`** (29 actions: most
  platform-configuration surface — `agents.create`/`.update`,
  `permissions.grant`/`.revoke`, `provider.*`, `connections.*`,
  `procedures.*`, `procedure_tools.*`, `schedules.*`, `allowlist.add`/
  `.remove`, `projects.create`/`.update`, `sessions.list`/`.get`,
  `tasks.list`, `logs.list`, `providers.oauth_*`, …) — a no-op while
  `allgres_private.users` is empty (single-operator, shared-token-only
  deployment), otherwise requires a logged-in admin. Checked fresh on
  every call, never cached.
- **`require_admin_for_system_agent`** (paired with the above on
  `agents.update`, `policy.rollback`, `permissions.grant`/`.revoke`) —
  additionally requires admin whenever the *target* agent is a system
  agent (`is_system = true`), regardless of account state.
- **`require_agent_access_if_accounts_exist`** (5 actions: `run`,
  `sessions.cancel`, `sessions.continue`, `memories.create`,
  `memories.remove`) — same bootstrap exception as above, but scoped to
  one specific `agent_id` in the request: once accounts exist, the caller
  must be logged in AND (unless admin) have that agent in
  `user_agent_assignments`.
- **`visible_agent_ids`** (8 actions: `proposals.list`/`.decide`,
  `fixes.list`/`.decide`, `approvals.list`/`.decide`, `memories.list`,
  `history.search`) — returns `NULL` (unrestricted) for a real admin,
  a regular user's assigned-agent array otherwise, and — **only** while
  no account exists yet — `NULL` for an unauthenticated caller too. Once
  any account exists, an absent/unknown/expired `session_token` returns
  an *empty* array (sees/can decide nothing). Getting this bootstrap
  exception right is the entire point of this function; see its own
  comment in `sql/control_plane.sql` for the live exploit this was fixed
  against.
- **`session_user`** (3 actions: `auth.me`, `agents.mine`,
  `messenger.list`) — resolves the token directly rather than through one
  of the helpers above; each of these three checks `user_id IS NULL`
  itself (`auth.me` returns `logged_in: false` rather than raising, since
  it is a status check, not an authorization gate).
- **No guard in the `dashboard_rpc` branch itself** (25 actions) — two
  different reasons, and the difference matters:
  - **Delegates the check to the SQL function it calls.**
    `project_chat.send`/`.history` (`fn_project_chat_send`/`_history`'s own
    `require_project_access`), `chat.send`/`.history`
    (`fn_chat_send`/`_history`'s own `require_agent_access`),
    `messenger.post` (`fn_messenger_post`'s own resolution),
    `agents.set_my_model` (`fn_set_my_model`'s own check). These are
    **not** open — `gen_rpc_catalog.py` only sees the literal branch text,
    not into a called function's body.
  - **Genuinely open by design**, on the same reasoning
    `agents.evaluate`'s own comment states explicitly ("read-only, open
    the same way `policy.history` already is"): `overview`, `agents.list`,
    `policy.history`, `agents.evaluate`, `permissions.list`,
    `permissions.options`, `allowlist.list`, `projects.list`,
    `audit.list`, `settings.get`, `connections.list`, `procedures.list`,
    `procedures.get`, `procedure_tools.list`, `schedules.list` — every one
    of these is a read-only listing of operator-curated configuration or
    an agent's own history, not agent-instance data or a secret
    (`settings.get`/`connections.list`/`provider.*` expose `has_secret`
    booleans, never the secret itself). The shared HTTP dashboard bearer
    token is the entire security boundary for this class, the same as it
    always was before the accounts system (item 28) existed. `auth.login`/
    `.logout` are the login mechanism itself. `events` is the SSE
    endpoint, gated separately by its own single-use ticket. `selftest`
    is a live diagnostic, deliberately safe to run against a real,
    populated database (see README, "Tests").

## Agent-facing actions are a separate, already-fixed set

The action set an *agent* itself may emit from a model turn
(`final_answer`, `execute_sql`, `call_tool`, `delegate`, `await_children`,
`await_human`, `propose_change`, `remember`, `search_agents`) is a fixed
`IF`/`ELSIF` chain in `fn_submit_result`, not a `jsonb`-keyed dispatch —
there is no separate catalog for it because there is no dynamic dispatch
to drift. `sql/control_plane.sql`'s own comment on `fn_next_step` lists
these as the allowed actions shown to the model.

## What this file is not

Not a request/response JSON Schema per action (the params list in
`rpc_catalog.json` is derived from which `p_request` keys a branch reads,
not a validated schema — most fields are still read with
`COALESCE`/`NULLIF` at the point of use, same as before this file
existed). Not a stability promise about `settings.get`'s response shape
or any other read action's exact output fields. Extending either is real
future work, not done here.
