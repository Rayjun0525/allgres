# Allgres

**Postgres Is All You Need.**

Allgres is a PostgreSQL-native agent control plane. It packages the PL/pgSQL
state machine, a Rust/pgrx native runtime worker, outbound HTTP/HTTPS, and an
embedded browser control panel into one PostgreSQL extension.

Version 0.1.0 -- pre-release; the version number tracks an actual release,
not every development milestone (see KNOWN_ISSUES.md's versioning note).
This is an MVP: read [Security model](#security-model) before
putting it anywhere that matters.

## Quick start

You need [Docker](https://docs.docker.com/get-docker/) with Compose v2
(the `docker compose` command, not the older standalone `docker-compose`).
Nothing else -- no PostgreSQL, no Rust, no Node.

```bash
git clone https://github.com/Rayjun0525/allgres.git
cd allgres
./scripts/bootstrap.sh
```

That one script builds the image, starts the container on its own data
volume, waits for PostgreSQL to actually accept connections, creates a
throwaway admin account, and runs one real agent task end to end to prove
the whole thing works -- not just that the container started. The first
run builds the extension from source, so it takes a few minutes; every
run after that is fast, since Docker caches the build.

When it finishes, open **<http://127.0.0.1:8088>** in a browser. There is
no login token by default (see [Exposure](#exposure)) and no dashboard
password unless you create one, so you land straight on the dashboard.

Want a real admin account waiting for you instead of the script's
throwaway one? Set these two variables *before* the first run (they only
take effect the very first time the database is created):

```bash
ALLGRES_BOOTSTRAP_ADMIN_USER=you ALLGRES_BOOTSTRAP_ADMIN_PASSWORD=change-me ./scripts/bootstrap.sh
```

To stop it: `docker compose stop`. To stop and delete all data:
`docker compose down -v`. Everything below this section is detail for
when you need it -- production hardening, a non-Docker install, upgrades,
backups -- not required to get a working instance running.

## Status

Implemented and verified: natively against PostgreSQL 16, 17, and 18
(`native-matrix` in CI, every push), and via the shipped Docker image
(`docker-smoke` in CI: a real `docker compose build`, the full install flow
end to end, and `scripts/smoke.sh`). See [Known
limitations](#known-limitations) for what is genuinely still open.

- **Agent control plane** — policy, permissions, delegation (bounded by a
  per-agent depth cap, an ancestor-cycle check, and a per-session total-task
  cap — see `max_delegation_depth`/`max_session_tasks` below), retries,
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
  Memories, Logs, Audit Log, and Settings, all reachable through one generic
  `/api/v1/rpc` route.
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
- **OAuth login and token refresh** — an operator can connect a conventional
  authorization-code provider or use the seeded `xai_oauth` provider's RFC
  8628 device-code login (the same browser-account flow used by Hermes/Grok
  CLI). Device approval is polled by the runtime worker, access and rotating
  refresh tokens are encrypted at rest, credentials are injected only at
  claim time, and expiring tokens refresh automatically.
- **Long-term agent memory** — an agent can `remember` something worth
  recalling in a future session (a fact, a preference, an instruction);
  `fn_next_step` reads a bounded set of that agent's own memories, ranked by
  importance then recency, back into every turn's own prompt, the same way
  its policy and permission bounds already are. An operator can also seed or
  remove a memory directly from the new Memories page. See
  [Memory](#memory).
- **Maintenance agents** — an ordinary agent can be pointed at two new
  system-wide, permission-gated diagnostic views (worker/queue health,
  every agent's permission grants) and asked to report what it finds; a
  seeded example, `health_monitor`, ships read-only with both. See
  [Maintenance agents](#maintenance-agents).
- **Operator audit log** — every consequential mutating SQL function writes
  its own append-only row (`agents.create`, a permission grant, a decided
  approval or proposal, a policy rollback, a cancelled session, and more),
  whether it was reached through the dashboard or called directly via SQL,
  recording `origin` (`web`/`sql`), the real authenticated `db_role`, and —
  only for a dashboard call — a self-reported `operator_name`. Answers "who
  claimed responsibility for this," not "who was authorized" — see
  [Operator audit log](#operator-audit-log) for exactly what that
  distinction means and doesn't.
- **Real accounts** — username/password login (`fn_login`/`fn_create_user`,
  bcrypt via `pgcrypto`), `admin`/`user` roles, and per-user agent
  assignment, layered on top of (not instead of) the dashboard's own shared
  bearer token: creating even one account starts requiring a real admin
  *session* for every action on the platform-configuration surface, on top
  of the token. See [Exposure](#exposure) for exactly how the two layers
  interact.
- **Semantic memory recall** — the same embedding infrastructure
  [semantic delegate search](#semantic-delegate-search) uses, applied to an
  agent's own `agent_memories` instead of cross-agent discovery: a new
  `recall` agent action ranks an agent's own memories by relevance to a
  query, alongside (not instead of) the automatic importance/recency
  injection every turn already gets. See [Semantic memory
  recall](#semantic-memory-recall).

Not yet built:

- Helm charts, Kubernetes manifests, and CNPG dynamic loading — only a
  native install and `docker-compose` exist today.
- Secret key rotation.

See [KNOWN_ISSUES.md](KNOWN_ISSUES.md) for the complete, itemized list.

## Runtime requirements

- PostgreSQL 16, 17, or 18 — all three are natively CI-verified on every
  push (`native-matrix`); the Docker image ships PostgreSQL 17
- `allgres` extension
- `shared_preload_libraries = 'allgres'`
- `pgcrypto` (optional, for encrypted provider secrets)
- `pgvector` (optional, accelerates semantic delegate search — see
  [Semantic delegate search](#semantic-delegate-search); everything works
  without it, just unindexed)

No Node, Python, Redis, RabbitMQ, pg_net, pg_cron, or external web server is
required at runtime.

## Docker install, in detail

This is what [Quick start](#quick-start)'s `./scripts/bootstrap.sh` actually
does, for anyone who wants to run the steps by hand or understand what just
happened. It builds the image locally from this repo's own `Dockerfile`
(there is no published image to pull — `docker-compose.yml`'s `build: .`
is the whole story), starts it on its own named data volume, and the
defaults below (`docker-compose.yml`) are chosen so this works with zero
configuration for a first run and local evaluation — `ALLGRES_ENABLE_MOCK`
on, `ALLGRES_ALLOW_INSECURE_HTTP` set, no `ALLGRES_SECRET_KEY` — **none of
that is a production posture**; see [Exposure](#exposure) and [Secrets at
rest](#secrets-at-rest) for what to change before this ever serves real
traffic or real provider keys.

```bash
docker compose up -d --build       # allgres_pgdata is a named volume (docker-compose.yml),
                                    # not an anonymous one -- `docker volume ls` finds it,
                                    # and `docker compose down` (without -v) keeps it.
./scripts/bootstrap.sh             # waits for healthy, makes sure a first admin exists,
                                    # then runs one real agent task through to completion
```

Both published ports (`5432`, `8088`) are bound to host loopback only; see
[Exposure](#exposure) before changing that.

`scripts/bootstrap.sh` is the install's actual completion criterion: a
container reporting healthy only means PostgreSQL accepted a connection,
not that an agent can do anything. Set `ALLGRES_BOOTSTRAP_ADMIN_USER`/
`ALLGRES_BOOTSTRAP_ADMIN_PASSWORD` (read by `002-bootstrap-admin.sh`,
which only ever runs once, the first time `$PGDATA` is initialized) to
have a real admin ready to log in as when the container first comes up;
leave them unset and the script proves the same flow with its own
throwaway admin instead — either way, the same one-liner this project's
own development has relied on all along (`psql -c "SELECT
fn_create_user(...)"`) is still exactly what happens under the hood, just
scripted instead of typed by hand.

The script runs two checks, deliberately kept apart:

1. **A mock smoke check, always run.** `analyst` (the seeded default
   agent) deliberately ships with no provider configured — see
   [Model configuration](#model-configuration-and-conversations) — so
   nothing would actually complete out of the box otherwise. The script
   seeds the built-in `allgres_mock` provider row (idempotent — it only
   ever touches that one, reserved-name row) and creates its own
   disposable agent to run against: login, `run`, a real LLM round trip,
   `completed`; then a real `agents.update` config change (`max_steps`)
   and model swap, confirmed persisted, and a second task proving the
   change didn't break execution — roadmap item 9's "설정 변경, 모델 교체"
   scenarios, exercised over real HTTP with a real session token. The
   disposable agent is deactivated afterward and no operator-created agent
   is ever touched by this check.
2. **An optional real-provider check, only when `AGENT_NAME` is set.**
   Point it at an agent you've already configured with a working, non-mock
   provider to prove that provider actually answers — a task can only
   reach `completed` if it genuinely did. This check only ever reads that
   agent and runs one task through it; it never modifies its configuration
   in any way. (An earlier version of this script ran the mock
   config-change check directly against `AGENT_NAME` and left it
   permanently repointed at a mock model with no restore — the two checks
   are separate now specifically so that can't happen again.)

Want to check the container without the full bootstrap flow, or run the
broader test suite against it?

```bash
curl http://127.0.0.1:8088/healthz
./scripts/smoke.sh      # full smoke + end-to-end + security checks
```

Forcing a clean rebuild (after changing the `Dockerfile` or `Cargo.toml`,
or to rule out a stale layer) drops the data volume — only run this when
you mean to discard whatever is in it:

```bash
docker compose down -v             # drops allgres_pgdata -- confirm you mean this
docker compose build --no-cache
docker compose up -d
```

See [Extension installation](#extension-installation) for a bare-metal
(non-Docker) install and version upgrades, and [Backup and
restore](#backup-and-restore) for both backup strategies — both apply
identically whichever way the extension got installed.

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

### Everything the dashboard does, `psql` can do too

`allgres.dashboard_rpc(jsonb)` is the *only* thing the web layer calls into
PostgreSQL for — the browser and `/api/v1/*` are one client of it, not a
privileged one. Every mutation it exposes is a thin, gate-then-delegate
wrapper around a plain PL/pgSQL function (`fn_create_agent`,
`fn_set_policy`, `fn_create_provider`, `fn_grant_permission`,
`fn_set_user_active`, ...) that takes typed arguments, not a jsonb request
body — the same function an operator can call directly from `psql` with no
HTTP, no dashboard, and no JSON in sight, exactly the way this project's
own development creates its very first admin account
(`psql -c "SELECT fn_create_user(...)"`, see [Docker install, in
detail](#docker-install-in-detail)). `dashboard_rpc`'s own job is strictly session
resolution, admin gating, and the operator audit log entry — never logic a
direct SQL caller would be missing out on. A handful of mutations
(`users.set_active`/`set_role`, a user's agent assignments) used to be the
exception, with their real `UPDATE`/`INSERT`/`DELETE` written inline in
`dashboard_rpc` itself and reachable only through the jsonb envelope;
`fn_set_user_active`/`fn_set_user_role`/`fn_set_user_assignments`/
`fn_set_user_assignment` closed that gap, each verified live with a plain
`SELECT` and no `dashboard_rpc` call anywhere in the session. Read-only
listings (`agents.list`, `sessions.list`, `overview`, ...) are the one
deliberate exception to "wrapped in a function": they're ad hoc queries
shaped for the API response, and an operator wanting the same data via SQL
can just query the underlying tables directly — that's more SQL-native
than calling a read wrapper, not less.

## The SQL sandbox

Agents can emit `{"action":"execute_sql","sql":"SELECT ..."}`. What that
statement is allowed to touch is decided from **PostgreSQL's own parse tree**:
`allgres.analyze_sql` calls `raw_parser` and reads the resulting nodes. Nothing
is planned, rewritten, or executed during analysis.

This replaced a regex layer. Text scanning has to re-implement lexing, and every
piece of that is a way to be wrong in one direction or the other — comment
injection (`FROM v_sales --x\n, allgres_private.sessions`), quoted identifiers,
comma joins, `extract(year FROM col)`, dollar quotes, a schema name that is
really just a string literal. The grammar has already settled all of it.

Validated statements do not run inline. PostgreSQL refuses `SET ROLE` inside a
security-definer function (`cannot set parameter "role" within
security-definer function`, SQLSTATE 42501), and `fn_validate_sql` is
`SECURITY DEFINER` — it has to be, since it reads `allgres_private.permissions`
and `pg_proc` regardless of who is asking. So it only validates and returns
the normalized statement text; it queues that text in `allgres_private.sql_calls`
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
   matching permission (`allgres_private.agent_may_read`), so authorisation does
   not depend on the analysis being complete;
4. `transaction_read_only` and a 5s `statement_timeout` — both real now that
   execution is a top-level statement instead of nested inside one;
5. a function must be on `allgres_private.sql_function_allowlist` — a seeded,
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

## Memory

An agent can emit `{"action":"remember","content":"...","memory_type":
"semantic|episodic|preference|instruction|relationship|working",
"importance":0.0-1.0,"subject_id":"...","expires_in_days":N}` alongside its
other actions. `content` and a valid `memory_type` are the only required
fields; `memory_type` and `importance` default to `semantic`/`0.5`,
`subject_id` is free text (there is no user-accounts system yet — see
[Security model](#security-model) — so it can't be tied to a real identity,
only tagged by the agent), and `expires_in_days` is optional.

Every future turn, `fn_next_step` reads that agent's own memories back —
live ones only, ranked by importance then recency, capped at 15 rows and 500
characters each — into a `# memory` block in the same system message that
already carries its policy and permission bounds. Recall is strictly scoped
to `agent_id`: nothing an agent remembers is ever visible to another agent's
own prompt, delegation included. A memory does not need any resource
permission the way `execute_sql` (a view) or `delegate` (a target agent) do
— an agent can only ever write to its own memory, which cannot expand its
privileges or touch anything another agent owns, the same reasoning that
already lets `propose_change`/`await_human` skip a permission grant.

A fixed cap (500 rows per agent) evicts the least important, then oldest,
memories on write, so an agent cannot grow its own prompt context — or the
table — without bound; there is no operator-configurable policy field for
this in the current slice. `fn_watchdog` separately garbage-collects any row
past its `expires_in_days`, though an expired row is already excluded from
recall regardless of whether it has been swept yet.

An operator can also seed or remove a memory directly from the **Memories**
dashboard page (`fn_remember`/`fn_forget`, exposed as `memories.create`/
`memories.remove`) — useful for correcting something an agent got wrong, or
telling it something once rather than waiting for it to learn the fact
itself.

The same page's **Search history** panel (`history.search`) searches past
work, decisions, and failures across three sources at once — an agent's own
explicit memories, a task's `role='error'` log entries, and a completed
session's `final_answer` — and every result links back to the session/task
it came from. It is a plain PostgreSQL text search (`tsvector`/`ILIKE`, the
`simple` config so it works on non-English content too), not a vector
search, and is scoped exactly like `memories.list`: a regular user sees only
their own assigned agents' history, an admin sees everything, and either can
narrow further to one agent or one project.

Deliberately not in this slice: semantic (embedding/vector) search — recall
is importance/recency ranking over structured rows only, no `pgvector`
dependency; an explicit `recall` action for an agent to query beyond what is
already injected automatically; and row-level security on
`agent_memories` — like most of this project's tables, it is gated by a
`SECURITY DEFINER` function's own `agent_id` parameter rather than Postgres
RLS (see "Per-agent roles" below for the one place RLS is actually used
today).

## Procedures

Roadmap item 4: a **procedure** (`allgres_private.procedures`) is a named,
versioned, reusable "how to do X" an operator curates once from the
**Settings → Procedures** panel — free text: a checklist, a SQL template, a
delegation plan, whatever shape is useful. It is distinct from a memory in
every way that matters here: shared rather than private to one agent,
explicitly granted rather than automatically written, and versioned —
`fn_set_procedure` snapshots the previous content into `procedure_history`
only on an actual change (the same "only a real change bumps generation"
rule `fn_set_policy` already applies to an agent's own policy), and
`fn_rollback_procedure` restores a past version by creating a *new* one
that happens to match it, the same non-destructive shape `fn_rollback_policy`
uses — nothing is ever overwritten in place.

An agent sees a procedure's current content in its own prompt, on every
turn, only once granted the matching permission — `resource_type =
'procedure'`, `resource_ref = '<name>'` — through the exact same
`agent_has_permission`/`agent_permission_refs` machinery (inheritance
through a system agent's parent chain included) that already gates a view
or a tool. A disabled procedure (`is_active = false`) never shows even to
an agent holding the grant, the same way a disabled `llm_providers` row
stops being reachable without losing its history.

Deliberately not in this slice: no agent-authored procedures yet — an
operator is the only one who can create, edit, or roll one back today.
Letting an agent *propose* a new or improved procedure (through the same
admin_approval/self_approve/auto autonomy-level flow `propose_change`
already gives an agent for its own policy) is real future work, not done
here.

### Procedure tool functions

A procedure may also bind one or more named **tool functions**. A tool
function is the callable half of a procedure: its name and description are
shown with the procedure in the agent's `tools` bounds, while its handler and
arguments stay operator-curated in `allgres_private.procedure_tools`.

The first handler is deliberately narrow: `http_get` with one fixed HTTPS
URL. An agent calls the function name (for example, `seoul_weather`) with an
empty argument object. `fn_submit_result` replaces any returned arguments
with the saved template before queuing the request, then still runs the usual
outbound URL validation. A procedure grant therefore authorizes precisely
the reviewed operation without also granting arbitrary `http_get` access or
an open-ended host permission.

Create and bind functions from **Settings → Procedure tool functions**. The
seeded `seoul-weather` procedure demonstrates the pattern: it binds
`seoul_weather` to `https://wttr.in/Seoul?format=j1` and grants the procedure
to the General agent. To make a new function usable, bind it to a procedure,
then grant that procedure to the intended agent in the usual permission UI.
This keeps the naming model clear: **Procedure** is the reusable capability;
a **tool function** is one fixed operation inside it. More handlers,
parameter schemas, versioning, and agent-authored proposals remain future
work.

## Maintenance agents

An agent can be a system-facing operator instead of a user-facing one: read
`allgres_public.v_system_health` (worker presence, queue backlogs, pending
approvals, failures in the last 24h, expired-but-unswept memories) and
`allgres_public.v_permission_audit` (every agent's permission grants), form
an opinion, and report it — the same `execute_sql`/`final_answer`/`remember`
actions any other agent has, no special agent "kind" or new action type
needed. Both views are system-wide, not per-agent data, so there is nothing
to row-scope: `agent_may_read` alone decides whether an agent sees them at
all — zero rows without the grant, the full picture with it.

A seeded example, `health_monitor`, ships with both views granted and
nothing else — no `execute_sql` access to any business-data view, no
`delegate`, no tools, and deliberately no `propose_change` in its prompt
either: this first slice is read-and-report only, more conservative than a
maintenance agent strictly needs to be, on purpose. It compares against
what it `remember`ed on its last run (already sitting in its own context,
the same recall every other agent gets) and gives a short human-readable
summary as its `final_answer` — visible in the Sessions thread view like
any other run.

There is no scheduler: nothing runs `health_monitor` automatically. An
operator triggers it from the Run page, or an external `cron` job hits
`POST /api/v1/run` the same way any other automation would. Deliberately
not built: an internal recurring-task primitive (a `pg_cron` dependency or
a new scheduling loop in the runtime worker); a way for a maintenance agent
to *act* on what it finds — even `propose_change` isn't wired into its
seeded prompt, so a real finding still requires an operator to read the
session and decide, the same review-before-apply shape self-modification
already uses; and any auditor beyond the two views above (a memory curator,
a performance advisor) — the review that proposed this pattern named
several; this ships the two with the clearest, most immediately useful
read surface already in place.

## Operator audit log

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
too](#architecture)," and a mutation audited only from inside `dashboard_rpc`
left a direct SQL call to that exact same function with no audit trail at
all — an outside review of an earlier version of this file caught exactly
that gap. Every row now carries:

- `operator_name` — a self-reported label, present only when the call
  arrived through the dashboard: the browser sends whatever name is set in
  Settings (`sessionStorage`, per browser tab, the same way the dashboard
  token itself is), and `dashboard_rpc` stamps the current transaction with
  it (`allgres_private.set_audit_context`) before dispatching, so every
  function it calls already knows to attach it. **This is not access
  control and does not claim to be** — anyone holding the one shared
  dashboard token can type any name, or leave it blank — `operator_name`
  answers "who claimed responsibility for this," not "who was authorized to
  do it." A real per-operator answer needs the accounts system above
  (`fn_login`/`users`), which most of these actions already require the
  caller to hold an admin session for.
- `origin` — `'web'` when the call arrived through `dashboard_rpc`,
  `'sql'` otherwise (the fail-safe default): a plain `psql -c "SELECT
  fn_grant_permission(...)"` shows up as `'sql'` with no `operator_name`,
  exactly as it should.
- `db_role` — the actual authenticated PostgreSQL role for the call,
  always populated regardless of origin, independent of whatever
  `operator_name` self-reports.

The row itself is trustworthy (append-only, enforced by a trigger that
applies even to the table's own owner, not just `REVOKE`); `operator_name`
is exactly as reliable as the person typing it chooses to be, while
`origin`/`db_role` are not — they come from the actual call path and
PostgreSQL session identity, not anything the caller can self-report.
`fn_selftest` proves both directions: a direct SQL call to a mutating
function records `origin = 'sql'` with no `operator_name`, and the same
action reached through `dashboard_rpc` with an operator name records
`origin = 'web'` with that name attached.

Browsable from the **Audit Log** dashboard page (`audit.list`), newest
first, with the same self-reported-not-authentication banner for
`operator_name` repeated there; `fn_selftest`'s own fixture noise is
filtered out of that listing the same way every other operator-facing
listing in this file already hides it.

## Model configuration and conversations

A fresh agent's `llm_config` starts empty — `{}` — whether it was just
created or is the seeded `analyst` demo agent. Nothing runs until an
operator explicitly picks a provider and model; there is no fallback
provider or model name baked in anywhere, so an agent with nothing
configured fails closed with a clear error (`agent has no llm_config.provider
configured`) instead of quietly reaching a real endpoint.

Providers are managed from **Settings**: `provider.create`
(`fn_create_provider`) adds a new one (name, kind, base URL, an optional API
key, and whether it may point at a loopback/private-network address) — not
just the five seeded ones (`xai`, `openai`, `anthropic`, `ollama`,
`openai_compat`) — and `provider.update` (`fn_set_provider`) edits an
existing one, including OAuth fields and connecting via the OAuth flow (see
above). In the agent editor, Provider is a dropdown populated from
currently-enabled providers, not a free-text field an agent could be
pointed at a nonexistent name with; Model stays free text, since one
provider can host many model names.

A session is no longer a single one-shot exchange. `fn_continue_session`
adds a follow-up message to an existing session — a new task in the same
session, sharing its `agent_id` — and `fn_next_step` assembles the full
conversation for it: every root-level task's log in that session, in
chronological order, not just the one task currently running. A delegated
sub-agent task (`parent_task_id` set — see `delegate` in the SQL sandbox
section above) stays scoped to only its own log, so a sub-agent's turn
never sees the parent conversation, or a sibling delegate's, just because
they share a `session_id`. A session that already finished is reopened
(`status` back to `open`) by a new message, the same way a chat thread
resumes when someone replies to it; sending a second message while an
earlier turn in the same session is still in flight is rejected outright
rather than racing it. Wired into `dashboard_rpc` as `sessions.continue`.

A real login gates the dashboard on top of the token above, not instead of
it: the token still decides whether a browser reaches the HTTP surface at
all, login decides who, having reached it, is using it. An **admin**
account sees every existing page plus **Users** (create an account,
activate/deactivate it, change its role, and manage which agents it can
reach), **Chat**, and **Messenger**. A **user** account sees only three
pages: **Chat** (a plain, continuing 1:1 conversation with one of their
assigned agents at a time — `fn_chat_send`/`fn_chat_history`, one ongoing
session per (user, agent) pair, resumed via `fn_continue_session` above),
**Messenger** (a Slack-style shared channel — a plain post is just stored;
a post containing `@agent_name` additionally routes that message to the
agent the same way Chat would, sharing the same conversation rather than
starting a second, divergent one — `fn_messenger_post`/`messenger.list`),
and **My Agents** (their assigned agents, each with an inline Provider/
Model editor — `fn_set_my_model` — never the full agent editor's
prompt/budget/permission fields). Which agents a regular user can reach at
all is an explicit allow-list (`allgres_private.user_agent_assignments`,
managed by an admin from the Users page), not everything minus a
block-list. See KNOWN_ISSUES.md, item 30, for what this deliberately does
not change: the pre-existing shared-token `dashboard_rpc` surface (agent
CRUD, permissions, providers, the SQL sandbox allowlist) is untouched and
still reachable by anyone holding that one token, same as every version
before this — login adds a second, narrower identity layer for chat/
messenger/my-model specifically, not a retrofit of the first one (that
remains KNOWN_ISSUES.md, item 10).

## System agents

Beyond the two demo/maintenance agents above, five built-in agents operate
the platform itself, seeded under one shared parent (`system_root`) so a
grant or a framing sentence added to the root reaches all five without
being restated per agent: `session_compactor` (summarizes a session's
older turns once its log passes a threshold — `allgres_private.
maybe_trigger_compaction`, called on every `fn_next_step`), `orchestrator`
(records an advisory opinion on response order whenever a Messenger post
`@mentions` more than one agent — delivery itself is still text order; see
KNOWN_ISSUES item 31 for what "advisory" means here), `creator`, `fixer`,
and `self_improve`. `agent_id`/`name`/`system_prompt` inheritance is real —
`allgres_private.agent_has_permission`/`agent_effective_prompt` walk
`parent_agent_id` so a child sees its own grants plus everything the root
was granted, and its own prompt appended after the root's shared framing.
Every one of the five is `is_system = true`: editing its policy or
permissions from the Agents page always requires an admin session
(`require_admin_for_system_agent`), unconditionally. An ordinary,
non-system agent used to be unaffected by this specific check — but see
[Security model](#security-model): once any account has ever been
created, the platform-configuration surface as a whole (agent creation
and edits, providers, the allowlist, OAuth connect) requires an admin
session too, system agent or not.

Any behavior constant a specific agent kind needs — `session_compactor`'s
trigger threshold and how many recent logs it leaves uncompacted,
`orchestrator`'s minimum `@mention` count before it bothers routing —
lives in a generic `agent_config jsonb` column on every agent rather than
being compiled in, so a future parameter never needs a schema migration.
`fn_set_agent_config` merges into it (a key sent as `null` clears back to
the coded default), through the same admin gate as every other
system-agent field. The Agents page's edit modal exposes each known key
as a labeled number field for the agent it belongs to, plus a raw-JSON
`agent_config` textarea on every agent as the fallback for anything not
given a named field yet (see KNOWN_ISSUES item 34).

`creator`, `fixer`, and `self_improve` can each take one real,
consequential action, gated by a per-agent `autonomy_level` an admin sets
from the Agents page (`agents.set_autonomy`): `admin_approval` (default)
queues it for a human to accept or reject; `auto`/`self_approve` apply it
immediately.

- **creator** proposes a brand-new agent (`create_agent`); approval calls
  the same `fn_create_agent` the Agents page itself uses.
- **fixer** reads the same two read-only views `health_monitor` does
  (`v_system_health`, `v_permission_audit`) and, instead of only
  reporting, proposes a concrete remediation (`propose_fix`: revoke a
  permission, or deactivate an agent) into a new Fixes queue.
- **self_improve** is the one agent allowed to `propose_change` against an
  *other* agent's policy (every other agent's `propose_change` stays
  self-only) — aimed at cost/efficiency, not behavior.

Approvals, Proposals, and the new Fixes queue are no longer admin-only
inboxes: a regular user sees and may decide the ones whose target is one
of their own assigned agents (`allgres_private.visible_agent_ids`); an
admin still sees everything. Both inboxes also filter out
`fn_selftest`'s own fixtures, the same as Sessions/Tasks already did.

An admin can also grant/revoke a user's access to one agent directly from
the Agents page's own edit modal (`assignments.toggle`/`.for_agent`), not
only from Settings' Users section — the reverse direction of the same
`user_agent_assignments` table, one pair at a time rather than replacing a
user's whole list.

## Task dependencies

Roadmap item 5: `delegate` on its own is a one-shot, fire-and-forget hand-off
— the moment a child task is queued, the parent task completes. That is
still the default, unchanged, and is exactly what orchestrator's own
multi-mention routing and self_improve's cross-agent proposals already rely
on. `delegate` also now accepts `"wait": true`: instead of completing, the
parent stays `running`, so its very next turn can delegate again (fanning
out to more agents) or call the new `await_children` action — which pauses
the task (`waiting_children`) until *every* task it has delegated, however
many, reaches a terminal state, then resumes with what each one actually
did (agent, status, output, error) appended to its own log. `await_children`
is rejected outright if there is nothing pending to wait on.

This is a real dependency edge, not a worker-memory illusion: the only
state involved is `tasks.status = 'waiting_children'` and the ordinary
`parent_task_id` link every delegated task already has. The wake side lives
in `fn_watchdog` (already polled every tick) as a plain re-scan — "is any
task `waiting_children` whose children are now all done" — so a worker or
database restart mid-wait loses nothing; the next tick just finds the same
row again. A `waiting_children` task counts toward `max_concurrent_tasks`
and `max_turn_seconds` exactly like `running`/`waiting_human` do (a child
that never finishes does not let its parent wait forever), and
`fn_cancel_session` reaches it the same way too.

Deliberately not in this slice: a single `delegate` call still spawns
exactly one child, so a genuine fan-out to several agents at once takes
several `wait: true` delegate calls across several of the parent's own
turns before the one `await_children`, not one call naming a list of
targets; and there is no dedicated dashboard view of the dependency graph
itself yet — a paused task and its children are visible today the same way
any other task is, through Audit → Sessions/Tasks.

## Schedules

Roadmap item 6: a schedule (Settings → Schedules) runs an agent against a
goal on a recurring interval — each firing calls `fn_create_session` exactly
as if an operator had typed the goal in by hand, so a fired run is an
ordinary session, visible and inspectable the same way any other one is
(Audit → Sessions). Firing is a plain `next_run_at <= now()` poll
(`fn_run_schedules`, called from `fn_pump` alongside `fn_watchdog`/
`fn_dispatch_tasks`) — no `pg_cron` or other external scheduler, and no
state held in worker memory, so a worker or database restart between ticks
loses nothing: the next tick just finds the same due row. A schedule that
missed several intervals (the extension was down, or simply never got a
tick) fires once to catch up, never in a burst — `next_run_at` is always
recomputed as `now() + interval_seconds`, never by walking forward in fixed
steps from where it was.

A schedule's own `name`/`goal` plus its `run_count`/`last_run_at`/
`last_session_id` *are* the durable long-term-goal-tracking record — how
many times has this actually been checked on, most recently when, against
which session — queryable in PostgreSQL like everything else here, not a
separate concept kept anywhere else. Two independent, optional stop
conditions — `max_runs` (a run budget) and `ends_at` (a wall-clock deadline)
— are enforced on every tick, not only at create time: a schedule that
reaches either is deactivated (`is_active = false`) rather than fired one
run past the limit. `schedules.run_now` fires one immediately regardless of
`next_run_at`, still subject to both stop conditions — the closest thing in
this slice to a genuinely event-driven trigger (an operator, or an external
system calling the same RPC action, is the "event").

Deliberately not in this slice: a real *cost*-based stop condition (a
dollar or token budget) — nothing in this codebase parses token usage out
of an LLM response or prices a provider/model today, so a cost cap would
only ever compare against a number nothing populates; and a genuinely
event/webhook-triggered schedule (fired by an external condition, not a
timer or a manual call) — `schedules.run_now` covers the manual case today,
a real inbound trigger is future work.

## Evaluation-gated self-improvement

Roadmap item 7: every prior slice let `self_improve` (or an operator)
change an agent's policy, but nothing ever recorded whether that change
actually helped. **What this measures is task throughput (the
completed/failed ratio of an agent's own root-level tasks), not semantic
correctness** — a task can finish `completed` having produced a wrong or
useless answer, and nothing here can tell the difference. Read `improved`/
`regressed` as "this policy finishes more (or fewer) of its own tasks than
the one before it," not "this policy is smarter." A real correctness judge
would need task-specific success criteria (something to grade the actual
output against) and is out of scope here — see "Deliberately out of
scope" below.

`agent_recent_success_rate(agent_id, limit=20)` is the coarse version of
that signal: the completed/failed ratio over an agent's most recent
root-level tasks (`parent_task_id IS NULL`), regardless of which policy
version they ran under. It excludes delegated children (a child's own
outcome never blurs the delegating agent's own score) and any session
whose `goal LIKE 'selftest%'`, and returns `NULL` (not `0`) when there is
no evaluable data yet, so a brand new agent is never read as "0% success."
It still backs `v_agent_health`'s "how is this agent doing lately,
overall" column, but an outside review pointed out it is the wrong tool
for judging one specific change: "most recent 20 tasks" can span several
policy versions, so a handful of tasks from just before a change and a
handful from just after can land in the same window and get averaged
together — enough to call a real regression "unchanged," or the reverse.

`allgres_private.agent_success_rate_for_generation(agent_id, generation,
limit=20)` is the fix: every root task is stamped at creation time
(`tasks.policy_generation`) with whichever `policies.generation` was live
when it was queued, and this computes the same completed/failed ratio
scoped to exactly one generation's own tasks. `fn_set_policy` now snapshots
`policy_history.success_rate_at_change` from this (the outgoing
generation's own rate, not a mixed recent window) at the exact moment a
version is replaced. `fn_evaluate_last_change(agent_id, min_samples=5)`
compares the agent's current-generation rate against its immediately
prior generation's rate — both computed fresh from their own isolated
task sets, live, every time this is called, not a frozen snapshot on one
side — and returns one of five verdicts: `improved`, `regressed`,
`unchanged`, `insufficient_data`, or `no_change_recorded_yet` (the agent
has never had a policy change at all). `insufficient_data` fires whenever
either side has fewer than `min_samples` evaluable tasks (default 5, not
just "any data at all") — a single task on either side is not enough to
call a trend, and the response reports `current_sample_size`/
`before_sample_size` alongside the verdict so a caller can see exactly why
judgment was withheld. Right after a change, before the new generation has
run a single task yet, this correctly reports `insufficient_data` — never
a false `unchanged` implying "checked, no difference."

`v_agent_health` is the same permission-gated shape as `v_system_health`,
one row per agent instead of a single aggregate, and `self_improve` is
granted read access to it by default (both at seed time and, for an
existing install, via an unconditional grant so upgrading picks it up
too). `self_improve`'s system prompt now points it at both
`v_agent_health` and `fn_evaluate_last_change` so it can check the outcome
of its own prior proposals before making a new one.

Both are exposed read-only, the same way `policy.history` already is:
`dashboard_rpc` action `agents.evaluate` (wraps `fn_evaluate_last_change`
directly) and the extended `policy.history` output (`success_rate_at_change`
per version). The Agents page's edit modal has a new "Evaluate last
change" button next to History that shows the verdict and both rates, and
the History modal itself now shows each version's `success_rate_at_change`
inline.

Deliberately out of scope: a mechanical block on `self_improve` proposing
a change (e.g. refusing a new proposal until the last one shows
`improved`) — `self_improve`'s stated purpose is token/time cost, not
correctness, and a hard gate on that basis would be enforcing something
this feature was never meant to guarantee. This makes a change's outcome
*evaluable*, not automatically enforced: no automatic rollback on
`regressed` either, only a computed verdict for a human, or a future
`self_improve` turn reading its own history, to act on. Also deferred: a
per-task correctness judge (grading actual output against a task-specific
success criterion, rather than just "did the task finish"), and a real
cost-based signal (tokens or dollars per change, the same deferred item
Schedules above already named) — nothing in this codebase prices a
provider or parses token usage out of a response yet, so a cost dimension
here would only ever compare against a number nothing populates.

## Semantic delegate search

`delegate` has always required an agent to already know the exact
`agent_name` of who to hand a task to. A new `search_agents` action lets
it describe the task instead: register a `purpose='embedding'` provider in
Settings (`kind` must be `openai_compat` — an OpenAI-shaped `/embeddings`
endpoint, real or a local server), and every agent's name + system_prompt
is embedded and kept current automatically whenever it's created or its
prompt changes. `search_agents` embeds the query the same way and ranks
every agent the caller actually holds an `agent` permission for by cosine
similarity — the identical permission check `delegate` itself enforces, so
a search can never surface a name the caller could not actually delegate
to — returning the ranked list as a `tool_result` on the next step.

Embeddings are stored as a plain array (`agents.embedding`), never
[pgvector](https://github.com/pgvector/pgvector)'s own `vector` type, so
none of this requires pgvector at all — ranking falls back to an unindexed
but exactly-correct SQL cosine similarity. Installing pgvector
(`CREATE EXTENSION vector;`, entirely the operator's own opt-in step —
allgres never runs it, the same as `pgcrypto`; the Docker image installs
the package so it's available if wanted) only adds an HNSW index for
speed, built and kept in sync with whatever embedding dimension is
actually in use automatically the first time it would help. See
KNOWN_ISSUES.md item 35 for the full mechanism and two real bugs this
found (a missing worker grant, and pgvector's own `sum(vector)` overload
breaking the SQL sandbox's unrelated function allowlist).

## Semantic memory recall

[Memory](#memory)'s automatic every-turn injection stays exactly what it
was — an agent's own live memories, ranked by importance then recency,
capped at 15 rows — because that has to run synchronously while a prompt
is being assembled, and a query embedding is itself an outbound HTTP call
that cannot complete inline. `recall` is the explicit alternative for
"find something specific," reusing the identical embedding infrastructure
[semantic delegate search](#semantic-delegate-search) already built: the
same shape (`{"action":"recall","query":"..."}`), the same queue-then-
continue flow (`outbound_calls` kind `'recall'` instead of `'embedding'`),
the same plain-array-not-pgvector storage, and the same automatic
opportunistic HNSW indexing once pgvector is installed.

Every `agent_memories` row gets its own embedding (`agent_memories.
embedding`/`embedding_model`), generated the moment it's written —
`write_memory`, the one insertion point both the agent's own `remember`
action and the operator-authored `fn_remember`/`memories.create` share —
via the same `embedding_calls` queue agent-identity embeddings already
use, generalized to carry either an agent or a memory as its target.
`allgres_private.rank_memories_by_embedding` then ranks by cosine
similarity, scoped strictly to the calling agent's own memories (`WHERE
agent_id =`, not a cross-agent search — this is semantic search over an
agent's own private store, never another agent's) and excluding anything
already expired, with the same dimension/model mismatch guards
`rank_agents_by_embedding` already enforces so a since-changed embedding
provider can never silently rank across two incomparable vector spaces.

An optional feature's absence is never fatal: `recall` with no
`purpose='embedding'` provider configured is a friendly `continue`, the
same as `search_agents`, and a memory written before one existed simply
stays ineligible for semantic ranking (still fully recalled by importance/
recency) until it is re-embedded.

## Chat: General, Messenger, and Project modes

The Chat page is one page with three mode buttons, not three separate nav
entries: **General** (a plain, continuing 1:1 conversation — unchanged from
before), **Messenger** (the Slack-style shared channel — unchanged, now
also delivering to every agent a post `@mentions`, in text order, when more
than one is addressed), and **Project** — a project (Settings/Projects,
admin-managed) may be bound to one agent with a `preset_prompt` appended
after that agent's own system prompt (`fn_next_step`), giving it a focused,
reusable context (e.g. "only ever answer about the Seoul region") without
touching the agent's own policy. Project mode has its own continuing
session per (user, project) pair (`user_project_chat_sessions`,
`fn_project_chat_send`/`fn_project_chat_history`) — deliberately separate
from that same agent's General-mode conversation, so a project's preset
context never leaks into a plain chat with the same agent or vice versa.

## Overview: cluster monitoring

Overview also reports PostgreSQL's own version and this database's
`pg_stat_activity` session counts (active/idle/idle-in-transaction), plus
host-level CPU load and memory — the one thing SQL cannot see on its own,
read from `/proc/loadavg`/`/proc/meminfo` by a new native function,
`allgres.native_host_stats()` (Linux-only by design, the same reasoning as
`analyze_sql`'s use of PostgreSQL's own parser: the most direct interface
available, not the most portable one — it degrades to `null` sections
rather than an error if `/proc` is unavailable).

## Navigation, language, and theme

Sessions/Tasks/Logs and the audit trail are one **Audit** page with four
tabs now, not four separate nav entries; Users is a section of **Settings**
rather than its own page; Approvals/Proposals/Fixes are three tabs of one
**Approvals** page, open to regular users too (see "System agents" above).
Settings also has a language switch (English/한국어) and a dark/light theme
switch — both a plain per-browser `localStorage` preference with nothing
server-side to configure. The language switch covers navigation, page
chrome, and common actions/empty-states, not every field label in every
modal, and never data that came from the database itself (an agent's own
name, a log's own content) — see KNOWN_ISSUES item 31 for the exact scope.

## Known limitations

Outstanding gaps — secret key rotation, no automatic OAuth token refresh,
no per-task correctness judge behind [evaluation-gated
self-improvement](#evaluation-gated-self-improvement), and more — are
tracked in [KNOWN_ISSUES.md](KNOWN_ISSUES.md). Read it before deploying.

`allgres_public.fn_selftest()` exercises the validate/queue/claim/complete state
machine and every shape that defeated the old text scanner, and runs as part
of `tests/smoke.sql`. It cannot exercise the role drop itself, though, being
`SECURITY DEFINER` too; `tests/smoke.sql` separately asserts that against a
live session (`SET LOCAL ROLE sandbox; SELECT current_user`).

## Security model

### Exposure

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

### External call idempotency

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
genuinely unknown until an operator checks the destination system
directly or the agent's own next turn does. Treat a `'lost'` outbound call
as *ambiguous*, not *failed*, for anything with a real external side
effect — deciding whether to retry a specific one is a judgment call this
extension cannot make for you.

### Secrets at rest

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

### Privileges

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

### Self-modification

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
| `ALLGRES_ENABLE_MOCK` | unset | Serve `/mock/chat/completions` and `/mock/oauth/token` (tests only) |
| `ALLGRES_DROP_PRIVILEGES` | `1` | Runtime worker drops to the `worker` role |

## Extension installation

No Docker: install straight onto an existing PostgreSQL 16, 17, or 18
server. You need `cargo-pgrx` (`cargo install --locked cargo-pgrx --version
0.19.2`) and that PostgreSQL version's own `-dev`/`-server-dev` package
installed first (`pg_config` must be on `PATH`), then:

```bash
cargo pgrx install --release --features pg17   # or --features pg16 / pg18
```

This compiles the extension and copies the `.so`/`.control`/`.sql` files
into that PostgreSQL installation's own extension directory — no manual
file copying. Then set:

```conf
shared_preload_libraries = 'allgres'
```

restart PostgreSQL (a plain reload is not enough — this registers a
background worker, which only happens at postmaster start), and create
the extension:

```sql
CREATE EXTENSION IF NOT EXISTS pgcrypto;   -- optional, encrypts secrets at rest
CREATE EXTENSION allgres;
```

Open the address `ALLGRES_HTTP_ADDR` defaults to
(`http://127.0.0.1:8088`) the same as the Docker path above. See
[Configuration](#configuration) for every environment variable the
runtime worker reads.

### Upgrades

`sql/control_plane.sql`, `sql/operator_agents_and_policies.sql`,
`sql/operator_runtime_and_integrations.sql`,
`sql/operator_accounts_and_chat.sql`, `sql/seed_data.sql`,
`sql/selftest.sql`, and `sql/grants_and_facade.sql`
(seven files, always loaded together in that order — split out of what used
to be one file once it grew large enough to trip a real rustc compile-time
limit; see KNOWN_ISSUES.md item 38) are idempotent — `CREATE OR REPLACE`,
`IF NOT EXISTS`, `ON CONFLICT DO NOTHING`, create-only seeds (an upgrade
never overwrites an edited prompt or policy), and explicit `DROP`s for
anything whose signature or return type changed. `scripts/gen-upgrade.sh
<from> <to>` concatenates all seven, in that same order, into a versioned
upgrade script:

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
- **Restore in two passes, not one.** `sql/control_plane.sql` and
  `sql/seed_data.sql` register
  every table holding real operator/agent state via
  `pg_extension_config_dump()` (agents, sessions, tasks, policies and their
  history, permissions, projects, execution logs, human approvals, change
  proposals, provider secrets, agent memories, and the outbound/SQL/OAuth
  call queues), so a plain
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
psql -c "SELECT allgres_public.fn_selftest()"
./scripts/bootstrap.sh            # install completion: a real agent task runs to 'completed'
```

`fn_selftest` is a live diagnostic, not a fresh-install-only check: every
fixture it creates is either uniquely named and hard-deleted before it
returns, or left behind deactivated and hidden from every operator-facing
listing by `goal LIKE 'selftest%'` (see `selftest_fixtures_hidden_not_deleted`
in `sql/selftest.sql`) — the same convention real accounts, real
agents, real policy history, and real queued work all already rely on not
being disturbed by. Run it against a database that has been in production
for months exactly the same way as right after `CREATE EXTENSION allgres`;
nothing in it assumes an empty install, an exact row count anywhere in the
schema, or that no admin account exists yet (confirmed live: a full
`fn_selftest()` pass with a real admin account, and real agent/session/task
history already in the database, both taken before every commit that
touches any of `sql/control_plane.sql`, `sql/operator_agents_and_policies.sql`,
`sql/operator_runtime_and_integrations.sql`,
`sql/operator_accounts_and_chat.sql`, `sql/seed_data.sql`,
`sql/selftest.sql`, or `sql/grants_and_facade.sql`).

`scripts/fault_injection_drill.sh` is a separate, runnable drill (bare-metal,
like `scripts/backup_drill.sh`) that sends a real `SIGKILL` to the real
`allgres runtime` worker while a real sandboxed-SQL call and a real LLM/HTTP
call are genuinely in flight, and proves the whole claim → crash → recovery
→ `fn_watchdog` reclaim → automatic retry → completion cycle happens on its
own — not a `fn_selftest` case, since that would need a SQL function to kill
its own OS process. It kills and restarts the entire instance it is pointed
at, on purpose; never run it against anything serving real traffic — a
GitHub-hosted CI runner is exactly the disposable instance this warning
allows, so `fault-injection-drill` in `.github/workflows/ci.yml` runs it on
every push, covering roadmap item 9's "재시작, 재시도" (restart, retry)
scenarios the same way `docker-smoke` covers "계정 생성 후 사용, 설정 변경,
모델 교체" (account-creation-then-use, config change, model swap) via
`scripts/bootstrap.sh`. See KNOWN_ISSUES.md, item 26.

The one named scenario deliberately not automated: "업그레이드" (upgrade).
`scripts/gen-upgrade.sh` and `ALTER EXTENSION ... UPDATE` are real and
manually verified (KNOWN_ISSUES.md, item 18), but there is currently no
real *next* version to upgrade the checked-in schema to — the version was
deliberately reset to `0.1.0` with no release ever shipped under it (see
KNOWN_ISSUES.md's own note on version numbers), so a CI job exercising
"upgrade" today would have to invent a fake target version and compare
against it, the same faking-a-metric-with-no-real-data problem this
project has refused elsewhere (see [Evaluation-gated
self-improvement](#evaluation-gated-self-improvement)'s own deferred-scope
note). This becomes real, automatable CI coverage the moment an actual
version is released and a second one begins development against it.

## License

Apache-2.0. See [LICENSE](LICENSE).
