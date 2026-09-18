# Operator audit log

Part of the [documentation index](../README.md). See also:
[Architecture](architecture.md#everything-the-dashboard-does-psql-can-do-too).

`allgres_private.audit_log` answers "who did this" for every consequential
mutation: creating or editing an agent, granting or revoking a permission,
deciding an approval or a proposal, rolling back a policy, cancelling a
session, editing the SQL sandbox allowlist or a project, updating a
provider, connecting an OAuth provider, creating or editing a user account,
or writing/removing a memory.

Each of those mutations writes its own row itself, from inside the plain
SQL function (`allgres_private.audit(...)`, called at the end of e.g.
`fn_create_agent`, `fn_grant_permission`, `fn_set_policy`) — not from a
centralized list keyed on `dashboard_rpc` action names the way an earlier
version of this worked. That distinction is the whole point: this project's
other stated goal is that "[everything the dashboard does, psql can do
too](architecture.md#everything-the-dashboard-does-psql-can-do-too)," and a mutation audited only from inside `dashboard_rpc`
left a direct SQL call to that exact same function with no audit trail at
all — an outside review of an earlier version of this file caught exactly
that gap. Every row now carries:

- `operator_name` — a self-reported label, present only when the call
  arrived through the dashboard: the browser sends whatever name is set in
  Settings (`sessionStorage`, per browser tab, the same way the dashboard
  token itself is), and `dashboard_rpc` stamps the current transaction with
  it (`allgres_private.set_audit_context`) before dispatching, so every
  function it calls already knows to attach it. **This alone is not access
  control and does not claim to be** — anyone holding the one shared
  dashboard token can type any name, or leave it blank — `operator_name`
  on its own answers "who claimed responsibility for this," not "who was
  authorized to do it." See `user_id`/`username` below for the real answer
  once an account exists.
- `user_id`/`username` — the *real*, server-verified identity, present only
  when the call carried a `session_token` that `allgres_private.
  session_user` resolved to an active account (the same resolution every
  admin-gated action already does). Unlike `operator_name`, this cannot be
  spoofed by typing a different name in Settings: it comes from the actual
  logged-in session, not anything the caller sends directly.
  `set_audit_context` resolves and stamps it the same way as
  `operator_name`, alongside it, not instead of it — a row can carry a
  verified `username` and a completely different self-reported
  `operator_name` at the same time, and the dashboard's Audit Log page
  shows both when they disagree. `NULL` on both means either no account
  exists yet (single-operator mode) or the call didn't carry a valid
  session (most consequential actions require one once accounts exist, but
  auditing itself doesn't gate on that). Deliberately no foreign key to
  `users`: this table is append-only (below), and a user account can be
  reasoned about independently of whether it still exists later.
- `origin` — `'web'` when the call arrived through `dashboard_rpc`,
  `'sql'` otherwise (the fail-safe default): a plain `psql -c "SELECT
  fn_grant_permission(...)"` shows up as `'sql'` with no `operator_name`
  or `user_id`, exactly as it should.
- `db_role` — the actual authenticated PostgreSQL role for the call,
  always populated regardless of origin, independent of whatever
  `operator_name` self-reports.

The row itself is trustworthy (append-only, enforced by a trigger that
applies even to the table's own owner, not just `REVOKE`); `operator_name`
is exactly as reliable as the person typing it chooses to be, while
`origin`/`db_role`/`user_id`/`username` are not — they come from the
actual call path and either PostgreSQL's own session identity or a
resolved login session, never anything the caller can self-report.
`fn_selftest` proves this end to end: a direct SQL call to a mutating
function records `origin = 'sql'` with no `operator_name` or `user_id`,
the same action reached through `dashboard_rpc` with only an operator name
records `origin = 'web'` with that name attached and `user_id` still NULL,
and reached with a real account's `session_token` records that account's
own `user_id`/`username` regardless of what `operator_name` said.

Browsable from the **Audit Log** dashboard page (`audit.list`), newest
first — the verified `username` shown in bold when present, falling back
to the self-reported `operator_name` otherwise, with a banner explaining
the difference; `fn_selftest`'s own fixture noise is filtered out of that
listing the same way every other operator-facing listing in this file
already hides it.
