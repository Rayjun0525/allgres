# Allgres

**Postgres Is All You Need.**

Allgres is a PostgreSQL-native agent control plane. It packages the PL/pgSQL
state machine, a Rust/pgrx native runtime worker, outbound HTTP/HTTPS, and an
embedded browser control panel into one PostgreSQL extension.

Version 0.2.0. This is an MVP: read [Security model](#security-model) before
putting it anywhere that matters.

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

Analysis is still not the security boundary. Layered, strongest first:

1. `search_path = pg_temp`, so an unqualified relation name cannot resolve to
   anything at all;
2. the agent-visible views return no rows unless the current agent holds the
   matching permission (`argo_private.agent_may_read`), so authorisation does
   not depend on the analysis being complete;
3. `transaction_read_only` and a 5s `statement_timeout`;
4. only non-volatile functions, checked against `pg_proc`. Volatility is the
   property that separates a read from a side effect: `pg_read_file`,
   `pg_ls_dir`, `lo_import`, `dblink`, `nextval` and `pg_sleep` are volatile,
   while the aggregates, string, date and json functions an analyst needs are
   not. Unknown names are rejected rather than assumed safe;
5. the parse tree must be exactly one non-writing `SELECT` (this also catches
   `SELECT ... INTO` and data-modifying CTEs, which are `SelectStmt` nodes);
6. every relation named must be schema-qualified, outside the reserved schemas,
   and present in the allowlist ∩ that agent's permissions.

## Known limitations

**The `sandbox` role is not reachable from the current call path.** PostgreSQL
refuses `SET ROLE` inside a security-definer function (`cannot set parameter
"role" within security-definer function`, SQLSTATE 42501), and the restriction
applies to the whole call stack below one. `fn_execute_sql` is reached only
through `fn_submit_result`, which is `SECURITY DEFINER`, so agent SQL executes
as the function owner rather than as `sandbox`.

Earlier revisions of this file attempted the role drop anyway and converted the
failure into `sandbox role unavailable or cannot be assumed`, which meant the
`execute_sql` action never worked at all — it failed closed, but it failed. The
volatility check in step 4 is the compensating control.

The proper fix is to execute agent SQL as a top-level statement from the runtime
worker, the same way outbound HTTP already works: SQL validates and hands back
the statement, the worker runs it under `SET LOCAL ROLE sandbox` outside any
security-definer frame, then submits the rows back. That is a pump-shaped change
and has not been made yet.

`argo_public.fn_selftest()` exercises all of this, including the shapes that
defeated the old text scanner. It runs as part of `tests/smoke.sql`.

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
- `http_get` additionally requires a per-agent `http_host` permission.

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

### Privileges

Four roles: `argo_owner` (deploy only), `operator`, `worker`, `sandbox`.

The runtime worker connects as the bootstrap superuser — a role that does not
exist yet must never crash-loop a background worker at startup — and then calls
`allgres.assume_worker_role()` at the top of every transaction, so ordinary work
runs as `worker`. Set `ALLGRES_DROP_PRIVILEGES=0` to disable that.

The control-plane functions are `SECURITY DEFINER`, so this is defence in depth
rather than the primary boundary; the primary boundary for model-generated SQL
is the `sandbox` role.

`execution_logs` is append-only, enforced by trigger and by `REVOKE`.

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
./scripts/gen-upgrade.sh 0.1.0 0.2.0    # writes sql/allgres--0.1.0--0.2.0.sql
```

```sql
ALTER EXTENSION allgres UPDATE TO '0.2.0';
```

## Tests

```bash
cargo pgrx test --features pg17   # Rust unit tests (request parsing, auth, parse-tree reader)
./scripts/smoke.sh                # container smoke, end-to-end, and security checks
psql -c "SELECT argo_public.fn_selftest()"
```

## License

Apache-2.0. See [LICENSE](LICENSE).
