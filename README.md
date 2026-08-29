# Allgres

**Postgres Is All You Need.**

Allgres is a PostgreSQL-native agent control plane. It packages the PL/pgSQL
state machine, a Rust/pgrx native runtime worker, outbound HTTP/HTTPS, and an
embedded browser control panel into one PostgreSQL extension.

Version 0.3.0. This is an MVP: read [Security model](#security-model) before
putting it anywhere that matters.

## Status

Implemented and verified (natively on PostgreSQL 16.15; see [Known
limitations](#known-limitations) for what the PG17/Docker path still needs):

- **Agent control plane** — policy, permissions, delegation, retries,
  per-agent concurrency (`max_concurrent_tasks`) and wall-clock
  (`max_turn_seconds`) caps, and a versioned policy history.
- **SQL sandbox** — parse-tree-based analysis, execution under the
  unprivileged `sandbox` role, and a per-view allowlist.
- **Outbound calls** — LLM provider calls and the `http_get` tool, both
  behind the SSRF guard described below.
- **Human-in-the-loop** — `await_human`, operator approve/reject with a
  reply that feeds back into the agent's own log, and timed expiry via the
  watchdog.
- **Projects & sessions** — sessions can be grouped into projects, an
  operator can cancel a running session, and a full per-session thread
  view is available.
- **Self-modification, operator-governed** — an agent can propose a change
  to its own `system_prompt`/`llm_config` tuning; it can never expand its
  own resource envelope, permissions, or provider endpoint. Every proposal
  is queued for an explicit operator approve/reject, applied through the
  same versioned policy path an operator's own edit takes, and any version
  can be rolled back later. See [Self-modification](#self-modification).
- **Dashboard** — a single static HTML file (no build step) covering
  Overview, Agents, Projects, Run, Sessions, Approvals, Proposals, Tasks,
  Logs, and Settings, all reachable through one generic `/api/v1/rpc` route.
- **Dashboard auth hardening** — a per-IP rate limit on `/api/v1/*` (a
  tighter, separate cap on failed-auth responses specifically), and the
  event stream authenticates with a short-lived single-use ticket instead
  of the durable token sitting in a URL. See [Security
  model](#security-model).
- **A real, tested extension upgrade path and backup/restore drill** — a
  frozen prior-version base makes `ALTER EXTENSION ... UPDATE` an actual
  operation instead of an aspirational one, and a runnable drill
  (`scripts/backup_drill.sh`) proves both a physical (`pg_basebackup`/PITR)
  and a logical (`pg_dump`) backup/restore round-trip real data, including
  per-agent role identity. See [Upgrades](#upgrades) and [Backup and
  restore](#backup-and-restore).

Not yet built:

- Helm charts, Kubernetes manifests, and CNPG dynamic loading — only a
  native install and `docker-compose` exist today.
- Per-operator identity/accounts — the dashboard has one shared token, not
  user accounts, so "who approved this" is unanswerable by design.
- OAuth token exchange, secret key rotation.

See [KNOWN_ISSUES.md](KNOWN_ISSUES.md) for the complete, itemized list.

## Runtime requirements

- PostgreSQL 17+
- `allgres` extension
- `shared_preload_libraries = 'allgres'`
- `pgcrypto` (optional, for encrypted provider secrets)

No Node, Python, Redis, RabbitMQ, pg_net, pg_cron, or external web server is
required at runtime.

## Docker

```bash
docker compose down -v
docker compose build --no-cache
docker compose up
```

Then open <http://127.0.0.1:8088/>. Both published ports are bound to host
loopback; see [Exposure](#exposure) before changing that.

```bash
curl http://127.0.0.1:8088/healthz
./scripts/smoke.sh      # full smoke + end-to-end + security checks
```

## Architecture

```text
Browser
  | HTTP + SSE
  v
Allgres web BGWorker (Rust, no SPI, one thread per connection)
  | unix socket, 0600 inside a 0700 directory under PGDATA
  v
Allgres runtime BGWorker
  |  SPI thread ......... short transactions only (pump, dashboard RPC)
  |  HTTP thread pool ... blocking LLM / tool calls, never touches Postgres
  v
PL/pgSQL control plane
  +--> agent state, policy, queue, retries, audit log
  +--> outbound request construction and validation
```

The Rust layer owns I/O and process lifecycle only. Agent state, policies,
queues, retries, audit logs, and dashboard operations remain in PostgreSQL.

Outbound HTTP runs on pool threads, so the SPI thread stays free for the
dashboard: an in-flight LLM call no longer blocks `/api/v1/*`. All SQL issued
from Rust uses bound parameters; nothing concatenates a value into a statement.

## The SQL sandbox

Agents can emit `{"action":"execute_sql","sql":"SELECT ..."}`. What that
statement is allowed to touch is decided from **PostgreSQL's own parse tree**:
`allgres.analyze_sql` calls `raw_parser` and reads the resulting nodes. Nothing
is planned, rewritten, or executed during analysis.

This replaced a regex layer. Text scanning has to re-implement lexing, and every
piece of that is a way to be wrong in one direction or the other — comment
injection (`FROM v_sales --x\n, argo_private.sessions`), quoted identifiers,
comma joins, `extract(year FROM col)`, dollar quotes, a schema name that is
really just a string literal. The grammar has already settled all of it.

Validated statements do not run inline. PostgreSQL refuses `SET ROLE` inside a
security-definer function (`cannot set parameter "role" within
security-definer function`, SQLSTATE 42501), and `fn_validate_sql` is
`SECURITY DEFINER` — it has to be, since it reads `argo_private.permissions`
and `pg_proc` regardless of who is asking. So it only validates and returns
the normalized statement text; it queues that text in `argo_private.sql_calls`
and the runtime worker's SPI thread claims it and runs it as a **top-level**
statement, issued directly by the worker with no enclosing `SECURITY DEFINER`
frame — the same claim/complete shape already used for outbound LLM and tool
calls. `SET ROLE sandbox` is legal there.

Layered, strongest first:

1. the statement only ever executes as `sandbox`, never as `fn_validate_sql`'s
   owner;
2. `search_path = pg_temp`, so an unqualified relation name cannot resolve to
   anything at all;
3. the agent-visible views return no rows unless the current agent holds the
   matching permission (`argo_private.agent_may_read`), so authorisation does
   not depend on the analysis being complete;
4. `transaction_read_only` and a 5s `statement_timeout` — both real now that
   execution is a top-level statement instead of nested inside one;
5. a function must be on `argo_private.sql_function_allowlist` — a seeded,
   positive allowlist of the aggregate, string, math, date and json
   functions an analyst actually needs — **and** pass every other gate:
   non-volatile (the property that separates a read from a side effect;
   `pg_read_file`, `pg_ls_dir`, `lo_import`, `dblink`, `nextval` and
   `pg_sleep` are all volatile), `pg_catalog` only (rules out every
   user-defined `SECURITY DEFINER` function, Allgres's own control-plane
   functions included, and every extension function such as `pgcrypto`'s or
   `dblink`'s), `NOT prosecdef` as defense in depth, and not on an explicit
   denylist as one more backstop. The allowlist is the one that actually
   matters: a denylist can only ever name what is already known to be
   dangerous, and volatility alone is not a security boundary either —
   `current_setting('allgres.secret_key', true)` and
   `pg_show_all_settings()` are both `STABLE`, not volatile, and both
   confirmed live (before each was closed) to hand back the key that
   encrypts every provider secret in the system, or every GUC on the server
   outright. A denylist has to be told about each of those by name; an
   allowlist doesn't. Unknown names, and anything failing any of these
   gates, are rejected rather than assumed safe;
6. the parse tree must be exactly one non-writing `SELECT` (this also catches
   `SELECT ... INTO` and data-modifying CTEs, which are `SelectStmt` nodes);
7. every relation named must be schema-qualified, outside the reserved schemas,
   and present in the allowlist ∩ that agent's permissions.

## Known limitations

Outstanding gaps — the unverified Docker/PG17 build, the untested upgrade path
and OAuth flow, secret key rotation, and more — are tracked in
[KNOWN_ISSUES.md](KNOWN_ISSUES.md). Read it before deploying.

`argo_public.fn_selftest()` exercises the validate/queue/claim/complete state
machine and every shape that defeated the old text scanner, and runs as part
of `tests/smoke.sql`. It cannot exercise the role drop itself, though, being
`SECURITY DEFINER` too; `tests/smoke.sql` separately asserts that against a
live session (`SET LOCAL ROLE sandbox; SELECT current_user`).

## Security model

### Exposure

The dashboard has no user accounts. `ALLGRES_DASHBOARD_TOKEN` is the only
authentication, and it is empty by default.

The web worker therefore **refuses to bind a non-loopback address when no token
is set**, unless `ALLGRES_ALLOW_INSECURE_HTTP=1` says the surrounding network
already protects the port. `docker-compose.yml` sets that flag and publishes
both ports on `127.0.0.1` only.

Anyone who can reach `/api/v1/*` can create agents, rewrite system prompts, and
register provider API keys. Put it behind TLS and a reverse proxy before
exposing it.

### Cross-origin requests

No CORS headers are ever emitted and `OPTIONS` always returns 405, so a
cross-origin preflight can never succeed. On top of that, `/api/v1/*` requires
an `X-Allgres-Client` header (which a form or `<img>` cannot set) and rejects a
mismatched `Origin`. `/api/v1/events` is exempt from the header rule because
`EventSource` cannot set one; it is a read-only endpoint whose response a
cross-origin page cannot read.

Dashboard HTML is served with a per-response CSP nonce, `frame-ancestors
'none'`, and `nosniff`.

### Event stream auth and rate limiting

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

### Outbound requests (SSRF)

One guard covers every outbound path — the LLM endpoint, the `http_get` tool,
and the OAuth token exchange:

- `https` only, unless the provider is explicitly marked
  `allow_private_network`;
- loopback, RFC1918, CGNAT, link-local (including `169.254.169.254`), IPv6
  unique-local and link-local, IPv4-mapped IPv6, and non dotted-quad spellings
  such as `2130706433` or `0x7f000001` are all rejected;
- URLs containing `userinfo@host` are rejected outright rather than parsed;
- the HTTP client follows **zero** redirects, so an allowlisted host cannot
  redirect into an internal one;
- `http_get` additionally requires a per-agent `http_host` permission;
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

### Secrets at rest

Set `ALLGRES_SECRET_KEY` (Docker) or `allgres.secret_key` in `postgresql.conf`,
with `pgcrypto` installed, and provider API keys, OAuth client secrets and
tokens are encrypted with `pgp_sym_encrypt`. Without a key they are stored in
plaintext and the dashboard shows a banner saying so. The dashboard never
returns a secret, only whether one is set.

That covers `llm_secrets`, the one table meant to hold a credential. A
decrypted key never reaches any other table: `argo_private.outbound_calls`
(the queue an LLM call sits in between being built and actually sent) holds
only `provider_id` and which header name a credential belongs in
(`auth_kind`) — never the credential itself. `fn_claim_outbound` resolves and
injects the real `Authorization`/`x-api-key` header at claim time, into the
response it hands the runtime worker over the RPC socket; that value is
never written back to a row. The key exists only in that one response and
then in the worker's memory for the HTTP request it is used for — never in
WAL, a physical backup, a PITR archive, a replica, or a plain `SELECT` on
`outbound_calls`.

### Privileges

Four fixed roles: `argo_owner` (deploy only), `operator`, `worker`, `sandbox`.

The runtime worker connects as the bootstrap superuser — a role that does not
exist yet must never crash-loop a background worker at startup — and then calls
`allgres.assume_worker_role()` at the top of every transaction, so ordinary work
runs as `worker`. Set `ALLGRES_DROP_PRIVILEGES=0` to disable that.

The control-plane functions are `SECURITY DEFINER`, so this is defence in depth
rather than the primary boundary; the primary boundary for model-generated SQL
is the `sandbox` role — or, for an agent with its own role (below), that role.

#### Per-agent roles

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

`argo_private.current_agent_id()` prefers this role identity
(`current_user`, parsed back against the naming scheme, no table lookup)
over the `argo.agent_id` GUC the worker also sets, falling back to the GUC
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

### Self-modification

An agent can emit `{"action":"propose_change","changes":{...},"reason":"..."}`
alongside its other actions. This is the one place Allgres lets an agent
change its own future behavior — deliberately narrow, and split cleanly
between what the agent can touch and what only an operator can:

- **The agent can improve its own knowledge and behavior spec.** `changes`
  may contain `system_prompt` and/or `llm_config.{model,temperature,
  max_tokens}` — nothing else. Any other key anywhere in the payload
  (`max_steps`, `max_retries`, `max_concurrent_tasks`, `max_turn_seconds`,
  `llm_config.provider`/`base_url`, permissions — anything at all) is
  rejected outright, not silently dropped, and nothing is applied.
- **The agent can never expand its own trust boundary.** Its resource
  envelope stays operator-only via `agents.update`, unchanged by this
  action; `llm_config.provider`/`base_url` stay locked to the
  operator-managed provider row regardless (`sanitize_llm_config`, applies
  here exactly as it does to a normal `agents.update`).
- **A proposal never touches the live policy by itself.** It only inserts a
  `pending` row into `argo_private.change_proposals`; the task that
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

### RPC socket

The runtime worker listens on a unix socket at
`$PGDATA/allgres/runtime.sock`, mode 0600, inside a 0700 directory
(`ALLGRES_SOCKET_DIR` overrides the location). `dashboard_rpc` is
`SECURITY DEFINER`, so a world-accessible socket would have been a complete
bypass of the dashboard token.

## Configuration

| Variable | Default | Meaning |
| --- | --- | --- |
| `ALLGRES_DATABASE` | `postgres` | Database the runtime worker attaches to |
| `ALLGRES_HTTP_ADDR` | `127.0.0.1:8088` | Dashboard listen address |
| `ALLGRES_DASHBOARD_TOKEN` | empty | Bearer token for `/api/v1/*` |
| `ALLGRES_ALLOW_INSECURE_HTTP` | unset | Permit a public bind with no token |
| `ALLGRES_SOCKET_DIR` | `$PGDATA/allgres` | RPC socket directory |
| `ALLGRES_SECRET_KEY` | empty | Encrypts provider secrets at rest |
| `ALLGRES_ENABLE_MOCK` | unset | Serve `/mock/chat/completions` (tests only) |
| `ALLGRES_DROP_PRIVILEGES` | `1` | Runtime worker drops to the `worker` role |

## Extension installation

Install the extension files, set:

```conf
shared_preload_libraries = 'allgres'
```

restart PostgreSQL, then:

```sql
CREATE EXTENSION IF NOT EXISTS pgcrypto;   -- optional
CREATE EXTENSION allgres;
```

### Upgrades

`sql/control_plane.sql` is idempotent — `CREATE OR REPLACE`, `IF NOT EXISTS`,
`ON CONFLICT DO NOTHING`, create-only seeds (an upgrade never overwrites an
edited prompt or policy), and explicit `DROP`s for anything whose signature or
return type changed. `scripts/gen-upgrade.sh <from> <to>` turns it into a
versioned upgrade script:

```bash
./scripts/gen-upgrade.sh 0.2.0 0.3.0    # writes sql/allgres--0.2.0--0.3.0.sql
```

```sql
ALTER EXTENSION allgres UPDATE TO '0.3.0';
```

Every released version after 0.2.0 keeps a frozen base install script
(`sql/allgres--0.2.0.sql`, and one more at each version bump from here on) —
a real snapshot of what that version's schema actually was, not just the
generated upgrade diff. That is what makes `ALTER EXTENSION ... UPDATE` a
real, testable operation: `CREATE EXTENSION allgres VERSION '0.2.0'` installs
an actual prior version, and `ALTER EXTENSION allgres UPDATE TO '0.3.0'` from
there is the same operation an in-place production upgrade would run. See
KNOWN_ISSUES.md, item 18, for how this was verified and what version 0.2.0
meant before this file existed.

## Backup and restore

`scripts/backup_drill.sh` is a runnable, re-runnable drill against a real
local PostgreSQL 16 install (bare-metal, not `docker-compose` — that path is
`scripts/smoke.sh`) that proves both backup strategies below actually work
with Allgres installed, not just that the commands exist. It is what first
caught the two bugs described in KNOWN_ISSUES.md, item 18; run it again if
either regresses.

**Physical (`pg_basebackup` + WAL archiving + PITR).** Covers everything,
including per-agent PostgreSQL roles (`agents.pg_role`) automatically, since
it copies the actual data files. Standard PostgreSQL procedure — take a
base backup, archive WAL, restore with a `recovery_target_time` — nothing
Allgres-specific to it.

**Logical (`pg_dump` + `pg_dumpall --globals-only`).** Needs two things this
extension does that a generic `pg_dump` would otherwise miss silently:

- **Roles are cluster-global.** `agents.pg_role` values (real `NOLOGIN`
  PostgreSQL roles, see [Per-agent roles](#per-agent-roles)) are not part of
  any database dump — restoring onto a fresh cluster needs
  `pg_dumpall --globals-only` applied first, or every agent's row-level
  isolation is gone even though the row data itself restored fine.
- **Restore in two passes, not one.** `sql/control_plane.sql` registers
  every table holding real operator/agent state via
  `pg_extension_config_dump()` (agents, sessions, tasks, policies and their
  history, permissions, projects, execution logs, human approvals, change
  proposals, provider secrets, and the outbound/SQL call queues), so a plain
  `pg_dump` now actually includes this extension's data — it silently did
  not, before KNOWN_ISSUES.md item 18. Restoring it needs
  `pg_restore --schema-only` first (creates the extension and its own seed
  data), then `pg_restore --data-only --disable-triggers` (loads everything
  else with triggers off — `agents_ensure_policy`, see [Per-agent
  roles](#per-agent-roles), would otherwise create a default policy row for
  each restored agent that collides with that agent's real one arriving
  right behind it in the same dump). A single-pass `pg_restore dump.file`
  will fail on that collision; `--disable-triggers` alone does not fix it
  either, since `pg_restore --help` documents that the flag only takes
  effect during a `--data-only` restore.
- One accepted, permanent limitation of the exclusion-filter approach: an
  operator's own edit to a *built-in* provider row (base_url, is_enabled,
  allow_private_network, a stored secret) does not survive a
  `pg_dump`-based restore — only a wholly new provider row would. Physical
  backup has no such gap.

## Tests

```bash
cargo pgrx test --features pg17   # Rust unit tests (request parsing, auth, parse-tree reader)
./scripts/smoke.sh                # container smoke, end-to-end, and security checks
psql -c "SELECT argo_public.fn_selftest()"
```

## License

Apache-2.0. See [LICENSE](LICENSE).
