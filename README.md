# Allgres

**Postgres Is All You Need.**

Allgres is a PostgreSQL-native agent control plane. It packages the PL/pgSQL
state machine, a Rust/pgrx native runtime worker, outbound HTTP/HTTPS, and an
embedded browser control panel into one PostgreSQL extension. Point it at an
LLM provider, create an agent, and it plans, calls tools, delegates to other
agents, and reports back — all through ordinary SQL tables you can query
yourself.

Version 0.1.0 -- pre-release; the version number tracks an actual release,
not every development milestone (see KNOWN_ISSUES.md's versioning note).
This is an early alpha: read [Security model](docs/security.md) before
putting it anywhere that matters. Found a vulnerability? See
[SECURITY.md](SECURITY.md) rather than opening a public issue.

## Quick start

Pick whichever matches how you want to run PostgreSQL. All three end at the
same place: a dashboard at **http://127.0.0.1:8088** (or wherever your own
PostgreSQL already listens, for the source install) with no login token
by default and no dashboard password until you create one.

### Docker

One image, one container -- Postgres and the extension are baked into a
single published image, nothing else to run alongside it:

```bash
docker pull ghcr.io/rayjun0525/allgres:latest
docker run -d --name allgres \
  -e POSTGRES_PASSWORD=allgres \
  -e ALLGRES_HTTP_ADDR=0.0.0.0:8088 -e ALLGRES_ALLOW_INSECURE_HTTP=1 \
  -p 127.0.0.1:5432:5432 -p 127.0.0.1:8088:8088 \
  -v allgres_pgdata:/var/lib/postgresql/data \
  ghcr.io/rayjun0525/allgres:latest
```

Wait for it to come up (`docker logs -f allgres`, or poll
`curl http://127.0.0.1:8088/healthz`), then open the dashboard. `-e
ALLGRES_ALLOW_INSECURE_HTTP=1` is what lets the container bind and publish a
non-loopback address with no token set -- fine for a local try, not for
anything reachable by anyone else (see [Exposure](docs/security.md#exposure)).

Want the scripted path instead -- builds from source, waits for health,
creates a first admin, and proves one real agent task runs end to end
before calling the install done? That's `git clone` + `./scripts/
bootstrap.sh` (uses `docker compose` under the hood), and a
production-hardening overlay (`docker-compose.prod.yml`) for anything
serving real traffic. See [Docker install, in
detail](docs/deployment/docker.md).

### Source (no Docker)

Install straight onto an existing PostgreSQL 16, 17, or 18 server. You need
that PostgreSQL version's own `-dev`/`-server-dev` package installed first
(`pg_config` on `PATH`), plus a C toolchain and OpenSSL's development
files (`build-essential clang libclang-dev pkg-config libssl-dev` on
Debian/Ubuntu — `cargo-pgrx` itself needs these to build, via `bindgen`
and `openssl-sys`, not just this extension's own source; `make check`
fails fast with the same message per missing piece). Rust and `cargo-pgrx`
are handled for you if they aren't already there:

```bash
git clone https://github.com/Rayjun0525/allgres.git
cd allgres
make install     # add `sudo` if this PostgreSQL's own lib/share dirs need it
make quickstart  # CREATE EXTENSION + start, no restart required
```

See [Source install](docs/deployment/source-install.md) for what the
Makefile is actually doing, the classic `shared_preload_libraries` +
restart path, and version upgrades.

### CNPG (Kubernetes)

For a [CloudNativePG](https://cloudnative-pg.io)-managed cluster: allgres
ships as a small extension-only image mounted into CNPG's own unmodified
operand image (its Image Volume Extensions mechanism), not a full custom
Postgres image to keep in sync. Requires PostgreSQL 18+, Kubernetes 1.33+
on a containerd/CRI-O node, and the CNPG operator already installed.

```bash
docker pull ghcr.io/rayjun0525/allgres-cnpg-ext:main
```

See [CNPG (CloudNativePG)](docs/deployment/cnpg.md) and
`cnpg/cluster-example.yaml` for the full `Cluster`/`Database` wiring.

*(A native RPM package is planned but not built yet.)*

## What's inside

Implemented and verified: natively against PostgreSQL 16, 17, and 18
(`native-matrix` in CI, every push), and via the shipped Docker image
(`docker-smoke` in CI: a real `docker compose build`, the full install flow
end to end, and `scripts/smoke.sh`).

- **Agent control plane** — policy, permissions, delegation, retries,
  per-agent concurrency/wall-clock caps, and a versioned policy history.
- **The SQL sandbox** — an agent's own `execute_sql` action, gated by
  PostgreSQL's own parse tree and run under an unprivileged role. See
  [The SQL sandbox](docs/sql-sandbox.md).
- **Outbound calls** — LLM provider calls and the `http_get`/`http_request`
  tools, all behind an SSRF guard. See [Security model](docs/security.md).
- **Human-in-the-loop** — `await_human`, operator approve/reject, and timed
  expiry via the watchdog.
- **Self-modification, operator-governed** — an agent can propose a change
  to its own prompt/model, never its own permissions or budget; every
  proposal is queued for an explicit approve/reject. See [Security
  model](docs/security.md#self-modification).
- **Memory and semantic search** — an agent can `remember` and later
  `recall`, and can find a delegate by description instead of exact name.
  See [Memory and semantic search](docs/memory-and-search.md).
- **Procedures** — a named, versioned, reusable "how to do X" an operator
  grants to an agent. See [Procedures](docs/procedures.md).
- **System and maintenance agents** — five built-in agents that operate the
  platform itself, plus a read-only health/permission auditor pattern. See
  [System agents](docs/system-agents.md).
- **Task dependencies and schedules** — `delegate`+`await_children` for
  real fan-out/fan-in, and recurring goal-driven runs with a cost budget.
  See [Task dependencies and schedules](docs/task-orchestration.md).
- **Evaluation-gated self-improvement** — every policy change gets a
  computed `improved`/`regressed` verdict from real task outcomes. See
  [Evaluation-gated self-improvement](docs/self-improvement.md).
- **Dashboard** — a single static HTML file (no build step) covering
  Overview, Agents, Chat, Projects, Run, Approvals, Memories, Audit, and
  Settings, all reachable through one generic `/api/v1/rpc` route, plus
  OAuth login/device-code connect and per-provider connectivity checks.
  See [Model configuration and chat](docs/chat-and-models.md).
- **Real accounts and an operator audit log** — username/password login,
  admin/user roles, per-user agent assignment, and an append-only audit
  trail for every consequential mutation. See [Operator audit
  log](docs/audit-log.md).
- **A real, tested extension upgrade path and backup/restore drill** — see
  [Source install](docs/deployment/source-install.md#upgrades) and [Backup
  and restore](docs/backup-and-restore.md).

Not yet built: Helm charts and general Kubernetes manifests beyond the CNPG
path above, and a native RPM package.

See [KNOWN_ISSUES.md](KNOWN_ISSUES.md) for the complete, itemized list of
gaps and what's still open.

## Runtime requirements

- PostgreSQL 16, 17, or 18 — all three are natively CI-verified on every
  push (`native-matrix`); the Docker image ships PostgreSQL 17
- `allgres` extension, `shared_preload_libraries = 'allgres'`
- `pgcrypto` (optional, for encrypted provider secrets)
- `pgvector` (optional, accelerates semantic search — everything works
  without it, just unindexed)

No Node, Python, Redis, RabbitMQ, pg_net, pg_cron, or external web server is
required at runtime.

## Documentation

Everything below is detail for when you need it — not required to get a
working instance running.

| Topic | What's there |
| --- | --- |
| [Architecture](docs/architecture.md) | The two background workers, `dashboard_rpc`, cluster monitoring, dashboard navigation |
| [Security model](docs/security.md) | Exposure, CORS, SSRF, secrets at rest, privileges, per-agent roles, self-modification |
| [The SQL sandbox](docs/sql-sandbox.md) | How an agent's `execute_sql` is analyzed and gated |
| [Memory and semantic search](docs/memory-and-search.md) | `remember`/`recall`, search history, semantic delegate search |
| [Procedures](docs/procedures.md) | Operator-curated reusable instructions and tool functions |
| [System agents](docs/system-agents.md) | `health_monitor`, `creator`, `fixer`, `self_improve`, and the rest |
| [Operator audit log](docs/audit-log.md) | Who did what, `operator_name` vs. a real verified account |
| [Model configuration and chat](docs/chat-and-models.md) | Providers, test connection, sessions, General/Messenger/Project chat modes |
| [Task dependencies and schedules](docs/task-orchestration.md) | `delegate`+`await_children`, recurring runs, cost budgets |
| [Evaluation-gated self-improvement](docs/self-improvement.md) | Measuring whether a policy change actually helped |
| [Configuration](docs/configuration.md) | Every environment variable the runtime worker reads |
| [Docker install, in detail](docs/deployment/docker.md) | The scripted `docker compose` flow, production hardening |
| [Source install](docs/deployment/source-install.md) | Bare-metal install, the no-restart path, upgrades |
| [CNPG (CloudNativePG)](docs/deployment/cnpg.md) | Kubernetes via Image Volume Extensions |
| [Backup and restore](docs/backup-and-restore.md) | Physical and logical strategies, the two-pass logical restore |
| [Tests](docs/testing.md) | `fn_selftest`, the fault-injection drill, what's deliberately not automated |

## Known limitations

Outstanding gaps are tracked in [KNOWN_ISSUES.md](KNOWN_ISSUES.md) — read it
before deploying. `allgres_public.fn_selftest()` exercises the
validate/queue/claim/complete state machine and runs as part of
`tests/smoke.sql`; see [Tests](docs/testing.md) for what it does and does
not cover.

## License

Apache-2.0. See [LICENSE](LICENSE).
