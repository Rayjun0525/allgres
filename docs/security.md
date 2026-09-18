# Security model

Part of the [documentation index](../README.md). Read this before putting
Allgres anywhere that matters — see also the top-level
[SECURITY.md](../SECURITY.md) for how to report a vulnerability.

## Exposure

`ALLGRES_DASHBOARD_TOKEN` is the base authentication layer everyone
sharing this install has in common, and it is empty by default. Real
per-operator accounts (username/password, Settings → Users) exist and can
be layered on top, but are optional — see below for exactly what changes
once the first one is created.

The web worker therefore **refuses to bind a non-loopback address when no token
is set**, unless `ALLGRES_ALLOW_INSECURE_HTTP=1` says the surrounding network
already protects the port. `docker-compose.yml` sets that flag and publishes
both ports on `127.0.0.1` only.

Anyone who can reach `/api/v1/*` can create agents, rewrite system prompts, and
register provider API keys. Put it behind TLS and a reverse proxy before
exposing it.

This is the whole security model in the default, single-operator
deployment mode: no accounts have ever been created, so there is nothing
for a login session to gate, and the bearer token above is doing all the
work. The moment an operator creates even one account (Settings' Users
section), that changes: `allgres_private.require_admin_if_accounts_exist`
starts requiring a real admin *session*, on top of the bearer token, for
every action on the platform-configuration surface — creating or editing
an agent (system or not), providers, the SQL sandbox allowlist, and OAuth
connect — checked fresh on every call against whether `allgres_private.
users` is still empty, not cached. Before that point, holding the token
is enough for all of it, by design; after it, the token alone is no
longer sufficient for any of the actions above.

## Cross-origin requests

No CORS headers are ever emitted and `OPTIONS` always returns 405, so a
cross-origin preflight can never succeed. On top of that, `/api/v1/*` requires
an `X-Allgres-Client` header (which a form or `<img>` cannot set) and rejects a
mismatched `Origin`. `/api/v1/events` is exempt from the header rule because
`EventSource` cannot set one; it is a read-only endpoint whose response a
cross-origin page cannot read.

Dashboard HTML is served with a per-response CSP nonce, `frame-ancestors
'none'`, and `nosniff`.

## Event stream auth and rate limiting

`EventSource` cannot set request headers, so `/api/v1/events` has always had
to carry auth in the query string somehow. It no longer carries the durable
dashboard token itself: `POST /api/v1/events/ticket` (gated by the real
bearer token, exactly like every other route) mints a single-use ticket good
for one connection within 30 seconds; `/api/v1/events?ticket=...` consumes
it. This keeps the long-lived credential out of proxy access logs, browser
history, and the Referrer header. Because a ticket cannot be replayed, the
dashboard reconnects itself (mints a fresh ticket, opens a new
`EventSource`) rather than relying on the browser's native retry against the
same URL.

`/api/v1/*` also enforces a per-IP sliding-window rate limit (120
requests/60s), and a separate, much tighter one specifically on failed-auth
responses (20/300s) — checked before the token comparison itself runs, so a
locked-out IP cannot keep spending a thread and a constant-time compare on
every attempt. Both return `429`. This does not slow an attacker rotating
source IPs; it is one layer, not a substitute for a real token.

## Outbound requests (SSRF)

One guard covers every outbound path — the LLM endpoint, the `http_get` and
`http_request` tools, and the OAuth token exchange:

- `https` only, unless the provider is explicitly marked
  `allow_private_network`;
- loopback, RFC1918, CGNAT, link-local (including `169.254.169.254`), IPv6
  unique-local and link-local, IPv4-mapped IPv6, and non dotted-quad spellings
  such as `2130706433` or `0x7f000001` are all rejected;
- URLs containing `userinfo@host` are rejected outright rather than parsed;
- the HTTP client follows **zero** redirects, so an allowlisted host cannot
  redirect into an internal one;
- `http_get`/`http_request` additionally require a per-agent `http_host`
  permission for the target host;
- `http_request` adds method (GET/POST/PUT/PATCH/DELETE), headers, and a
  body, plus an optional named `allgres_private.api_connections` credential
  (Settings → API connections). A connection's secret is resolved and
  injected only at claim time, the same as an LLM provider's api_key — it is
  never written into `outbound_calls.request_headers`. When a connection is
  named, the agent supplies a path relative to that connection's own
  `base_url`, never a full URL, so a stored credential can never be sent to
  a host the agent chooses;
- every one of these checks so far is against the URL's host **string**,
  which says nothing about where DNS actually points it: a hostname that
  resolves to a public address when the agent's request is validated can
  resolve to `127.0.0.1` or an RFC1918 address by the time the worker
  connects (DNS rebinding). The Rust worker closes that with a custom `ureq`
  resolver (`GuardedResolver`) that re-checks every address DNS actually
  returns — the same blocked ranges, reimplemented once in Rust to match the
  SQL check exactly — immediately before connecting, on the same call that
  will use it. There is no separate resolve-then-connect step for a rebind
  to land in: ureq only ever dials an address this resolver returned.

A per-agent `llm_config` can no longer set `base_url`. The endpoint comes only
from the operator-managed provider row, which is validated on write and again at
request-build time. Previously anyone with dashboard access could point the
worker — carrying the provider API key — at an arbitrary address.

Enable a local Ollama or an in-cluster gateway by ticking "Allow loopback /
private-network endpoint" on that provider in Settings.

## External call idempotency

An outside review raised a real gap: a crash (or a lost worker, or a
`fn_watchdog` reclaim) between an external side effect actually landing —
the worker's HTTP call to a third-party API succeeded — and this extension
recording that it did (`fn_complete_outbound` never runs for that
`outbound_calls` row) leaves the row `in_flight` until `fn_watchdog` marks
it `'lost'`. From the agent's point of view that reads as "did not
complete," and its own retry logic may reasonably queue the identical
`http_request` call again — at which point a destination with no
deduplication of its own would perform the effect (create the ticket, charge
the card, send the message) a second time.

The mitigation: every mutating `http_request` call (`POST`/`PUT`/`PATCH`/
`DELETE`) is queued with a deterministic `idempotency-key` header —
`md5(task_id || method || url || body)`, mirrored onto
`outbound_calls.idempotency_key` for visibility — unless the agent already
set that header itself, which is honored as-is. The key is derived from
the request's own content, not from `call_id` (a fresh value on every
queued row, including a genuine retry), so an agent retrying the *exact
same* request reproduces the *identical* key; a materially different
request (a changed body, say) gets a different one. This is the same
header Stripe, GitHub, PayPal, and Square already accept and deduplicate
on.

**This is a mitigation, not a guarantee.** It only protects a call against
a destination that actually implements idempotency-key deduplication —
plenty of third-party APIs do not, and against one of those, this header
is inert: sent, ignored, and the underlying at-least-once-delivery risk
above is unchanged. There is also no cross-check on this extension's own
side — nothing here calls back to ask "did you already see this key," so
a `'lost'` call's true outcome (delivered, or never sent at all) stays
genuinely unknown to this extension.

What changed (another outside review, same finding pressed further): that
"deciding whether to retry is a judgment call this extension cannot make
for you" used to mean the agent's own retry logic just fired again anyway
-- `fn_watchdog` fed every `'lost'` call back as a plain
`{"type":"error","message":"outbound timeout"}`, indistinguishable from
any other failure, and the agent had no signal that *this* retry might
duplicate a real side effect. `fn_watchdog` now tells the two cases apart
by HTTP method: a `GET` (or an `'llm'`/`'embedding'`/`'recall'` call,
which has no external side effect to duplicate in the first place) is
idempotent, so it still gets the same plain retryable error as always. A
mutating `http_request` call (`POST`/`PUT`/`PATCH`/`DELETE`) that never
came back instead pauses the *task itself* for a human to confirm --
`waiting_human`, a `human_approvals` row explaining which call and why,
visible in the dashboard's Approvals tab exactly like any other
`await_human` pause -- rather than letting the agent retry blindly. This
still cannot answer "did it actually execute" (only checking the
destination system can); it stops the extension from *guessing* on the
agent's behalf when a wrong guess means a duplicate ticket, charge, or
message.

## Secrets at rest

Set `ALLGRES_SECRET_KEY` (Docker) or `allgres.secret_key` in `postgresql.conf`,
with `pgcrypto` installed, and provider API keys, OAuth client secrets and
tokens are encrypted with `pgp_sym_encrypt`. Without a key they are stored in
plaintext and the dashboard shows a banner saying so. The dashboard never
returns a secret, only whether one is set.

That covers `llm_secrets`, the one table meant to hold a credential. A
decrypted key never reaches any other table: `allgres_private.outbound_calls`
(the queue an LLM call sits in between being built and actually sent) holds
only `provider_id` and which header name a credential belongs in
(`auth_kind`) — never the credential itself. `fn_claim_outbound` resolves and
injects the real `Authorization`/`x-api-key` header at claim time, into the
response it hands the runtime worker over the RPC socket; that value is
never written back to a row. The key exists only in that one response and
then in the worker's memory for the HTTP request it is used for — never in
WAL, a physical backup, a PITR archive, a replica, or a plain `SELECT` on
`outbound_calls`.

OAuth uses the same claim-time injection shape in its own queue table
(`allgres_private.oauth_calls`). Authorization-code providers queue the code
exchange through `providers.oauth_callback`. The seeded `xai_oauth` provider
uses RFC 8628 device authorization: `providers.oauth_device_start` requests a
user code, the dashboard displays xAI's verification link, and
`providers.oauth_device_status` reports the worker's approval polling state.
The worker also queues a refresh grant before an access token expires.

The queue stores neither device codes nor refresh tokens in plaintext.
`fn_claim_oauth` decrypts the short-lived credential only when the worker
claims its HTTP request. `fn_complete_oauth` encrypts issued access and refresh
tokens directly into `llm_secrets`; the dashboard sees only the user code,
verification URL, and coarse connection state. Once connected, the access
token is injected into xAI inference requests through the same path as a
provider API key. An xAI account may still return `403` for inference if its
subscription does not include API/Grok CLI access.

**Rotating the key.** There is no key-*versioning* scheme -- every stored
secret is still a single `enc:v1:`-prefixed value, and there is exactly
one key the live server currently reads (`ALLGRES_SECRET_KEY`/
`allgres.secret_key`) at any moment. But `allgres_public.
fn_rotate_secret_key(old_key, new_key)` re-encrypts everything already
stored (`llm_secrets.api_key`/`oauth_client_secret`/`access_token`/
`refresh_token`, `api_connection_secrets.api_key`,
`oauth_device_sessions.device_code`) from the old key to the new one, in
one transaction, using both keys as plain arguments -- it never reads or
writes the live GUC itself. Rotating for real, in this order:

1. `psql -c "SELECT allgres_public.fn_rotate_secret_key('<old key>', '<new key>')"`
   **while the live config still says the old key** -- it returns
   `{"ok": true, "rewrapped": N, "failed": M}`; `failed` counts a value
   that didn't decrypt under the old key you gave it (a typo in that
   argument, or ciphertext from some earlier key already) and leaves that
   one row completely untouched, not corrupted or dropped.
2. Immediately update the actual configured value to the new key (Docker:
   change `ALLGRES_SECRET_KEY` and recreate the container; bare-metal:
   change `allgres.secret_key` in `postgresql.conf` and reload) and
   restart/reload.

Between those two steps, what's stored is encrypted under the new key
while the live config still says the old one -- any decrypt attempted in
that exact window fails closed the same way an unset key always has (a
provider looks like it silently lost its credential, exactly the failure
mode this function exists to eliminate everywhere *except* this one short
window). Make the window as short as operationally possible; stopping the
runtime/web workers first removes it entirely, if that matters more than
avoiding a restart.

Deliberately **not** reachable through `dashboard_rpc` the way almost
every other mutating function in this file is (see [Everything the
dashboard does, `psql` can do too](architecture.md#everything-the-dashboard-does-psql-can-do-too))
-- both key values passed to this function are the real encryption key,
not one provider's own credential the way `provider.update`'s `api_key`
already is, and must never transit the HTTP layer at all. `psql` only, by
an operator who already holds both keys.

## Privileges

Five fixed roles: `allgres_owner` (owns every schema, table, view, and
`SECURITY DEFINER` function this extension creates — a real object owner,
`NOLOGIN NOINHERIT`, nobody connects as it directly), `allgres_role_admin`
(owns exactly one function, `fn_provision_agent_role`, the only thing that
runs a dynamic `CREATE ROLE` — kept separate and scoped to just that
function, `CREATEROLE` on top of `allgres_owner` would hand every other
`SECURITY DEFINER` function the same power for no reason any of the rest
need it), `operator`, `worker`, `sandbox`.

The runtime worker connects as the bootstrap superuser — a role that does not
exist yet must never crash-loop a background worker at startup — and then calls
`allgres.assume_worker_role()` at the top of every transaction, so ordinary work
runs as `worker`. Set `ALLGRES_DROP_PRIVILEGES=0` to disable that; every call
site checks whether the drop actually succeeded and skips its own work if not,
rather than proceeding as the bootstrap superuser.

The control-plane functions are `SECURITY DEFINER` and owned by `allgres_owner`,
so a caller's own role does not change what runs inside them — this is defence
in depth rather than the primary boundary for most of the control plane; the
primary boundary for model-generated SQL is the `sandbox` role — or, for an
agent with its own role (below), that role. PostgreSQL grants `EXECUTE` on a
new function to `PUBLIC` by default, unlike tables; every function in the
`allgres`/`allgres_private`/`allgres_public` schemas has that revoked
explicitly (a blanket revoke plus `ALTER DEFAULT PRIVILEGES` for anything
added later), with access granted back only to the specific role that needs
it — confirmed necessary live: this had been missed for roughly forty
functions, `allgres_private.secret_key()` (the key that encrypts every
provider secret) among them.

### Per-agent roles

A persistent agent gets its own real PostgreSQL identity, not just a row.
`fn_create_agent` provisions a `NOLOGIN` role (`allgres_agent_<uuid, no
dashes>`) as a member of `sandbox` — inheriting exactly the grants `sandbox`
already has, nothing duplicated per agent — and of `worker` (so the runtime
worker, the only thing that ever assumes it, can `SET LOCAL ROLE` to it,
membership being what that requires). `fn_run_sandboxed_sql` runs an agent's
`execute_sql` as *that* role instead of the one shared `sandbox` role every
agent used to be indistinguishable under. An agent created before this
existed stays on the shared `sandbox` role — `agents.pg_role` is `NULL` for
it — until `fn_provision_agent_role` is called for it explicitly; this is an
additive migration, not a breaking one.

`allgres_private.current_agent_id()` prefers this role identity
(`current_user`, parsed back against the naming scheme, no table lookup)
over the `allgres.agent_id` GUC the worker also sets, falling back to the GUC
only for an unprovisioned agent. It is deliberately `SECURITY INVOKER` and
called directly by `v_sales`/`v_my_tasks`'s own `WHERE` clauses, never from
inside another `SECURITY DEFINER` function: `SECURITY DEFINER` changes
`current_user` to the function's *owner* for everything nested inside it,
`current_agent_id()` included, which silently breaks role-based identity if
it is ever called that way — confirmed live while building this (every
agent's own view read as "no permission" against its own data, because
`current_user` inside `agent_may_read`, which has to stay `SECURITY
DEFINER`, was always the function owner, never the querying agent's role).
`agent_may_read` takes the resolved agent_id as a parameter instead, for
exactly this reason.

`execution_logs` is append-only, enforced by trigger and by `REVOKE`.

### The SQL console

`allgres_public.fn_admin_execute_sql` (`dashboard_rpc` action
`sql.execute`, the dashboard's own SQL nav page) is the one deliberate
exception to "everything reachable from the dashboard is `SECURITY
DEFINER`-scoped, never a raw SQL surface" — an admin asked for a query
console so they never need a separate client (DBeaver etc.) just to run
one query. It
runs as `allgres_owner`, not `sandbox` and not the bootstrap superuser:
full `DDL`/`DML` power over everything `allgres_owner` owns — which is
essentially every table, function, and schema this extension creates,
this security model's own enforcement code included — but no server-wide
reach (`ALTER SYSTEM`, other databases, filesystem access). No new
privilege is granted to `allgres_owner` to make this possible; the
function only ever exercises privileges that role already has, the same
way every other `SECURITY DEFINER` function here does.

Gated by `require_admin_if_accounts_exist`, the same guard as every other
platform-configuration action — nothing looser, and confirmed rejected
live for a non-admin session token (`{"ok": false, "error": "admin role
required"}`) even with a real, logged-in account. Every call is written
to `allgres_private.audit_log` (action `sql_console.execute`, the SQL
text itself in `details`) *before* it runs, not after, so a query that
errors or times out still leaves a record of what was attempted. One
statement per call, checked explicitly against `allgres.analyze_sql`'s
own `statements` count (the same native `raw_parser` call `execute_sql`'s
own validation already uses, [sql-sandbox.md](sql-sandbox.md)) — not left
to `EXECUTE` to enforce on its own, which it does not: `EXECUTE 'SELECT
1; SELECT 2'` runs both statements silently, reporting only the last
one's outcome, confirmed live after an admin's own `SELECT now();`
(trailing `;` alone, not a deliberate multi-statement attempt) reached
that exact path and came back as a row *count* instead of the actual
timestamp.

## Self-modification

An agent can emit `{"action":"propose_change","changes":{...},"reason":"..."}`
alongside its other actions. This is the one place Allgres lets an agent
change its own future behavior — deliberately narrow, and split cleanly
between what the agent can touch and what only an operator can:

- **The agent can improve its own knowledge and behavior spec.** `changes`
  may contain `system_prompt` and/or `llm_config.{model,temperature,
  max_tokens}` — nothing else. Any other key anywhere in the payload
  (`max_steps`, `max_retries`, `max_concurrent_tasks`, `max_turn_seconds`,
  `max_delegation_depth`, `max_session_tasks`, `llm_config.provider`/
  `base_url`, permissions — anything at all) is rejected outright, not
  silently dropped, and nothing is applied.
- **The agent can never expand its own trust boundary.** Its resource
  envelope stays operator-only via `agents.update`, unchanged by this
  action; `llm_config.provider`/`base_url` stay locked to the
  operator-managed provider row regardless (`sanitize_llm_config`, applies
  here exactly as it does to a normal `agents.update`).
- **A proposal never touches the live policy by itself.** It only inserts a
  `pending` row into `allgres_private.change_proposals`; the task that
  proposed it keeps running unaffected, unlike `await_human`, which blocks.
- **An operator decides it explicitly** — `fn_decide_proposal` /
  `proposals.decide`, approve or reject, with an optional reply. Approving
  applies the change through the *same* `fn_set_policy` path any operator
  edit takes, so a promoted proposal versions into `policy_history` exactly
  like a manual change would. If the live policy has moved on since the
  proposal was made (an operator edit, or another proposal already
  applied — tracked via `change_proposals.base_generation` against the
  live `policies.generation`), approving does not blindly overwrite it:
  the proposal is marked `stale` instead, changing nothing.
- **Any policy version can be rolled back** — `fn_rollback_policy` /
  `policy.rollback` restores a `policy_history` snapshot through
  `fn_set_policy` too, so a rollback is never a mutation of history, only
  ever a new version that happens to match an old one.

Reachable from the dashboard: the `Proposals` page (a pending/decided
inbox, optionally filtered to one agent from that agent's editor) and a
"Rollback to this version" button on each row of an agent's policy
history.

Deliberately not built: automatic evaluation of a proposal before it
reaches an operator (no test-case/scoring/LLM-judge pipeline) — every
proposal is a human decision, not an auto-merge; and no memory/provenance
subsystem for *why* an agent proposed what it did beyond the free-text
`reason` field.

## RPC socket

The runtime worker listens on a unix socket at
`$PGDATA/allgres/runtime.sock`, mode 0600, inside a 0700 directory
(`ALLGRES_SOCKET_DIR` overrides the location). `dashboard_rpc` is
`SECURITY DEFINER`, so a world-accessible socket would have been a complete
bypass of the dashboard token.
