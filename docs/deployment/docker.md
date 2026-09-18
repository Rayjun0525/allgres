# Docker install, in detail

Part of the [documentation index](../../README.md). If you just want the
fastest path to a running instance, see the main
[README's Quick start](../../README.md#quick-start) — this page is the
scripted, fully-verified `docker compose` flow behind it, for anyone who
wants to run the steps by hand, understand what `scripts/bootstrap.sh`
actually does, or set up a production-hardened deployment.

It builds the image locally from this repo's own `Dockerfile`, starts it
on its own named data volume, and the defaults below
(`docker-compose.yml`) are chosen so this works with zero configuration for
a first run and local evaluation — `ALLGRES_ENABLE_MOCK` on,
`ALLGRES_ALLOW_INSECURE_HTTP` set, no `ALLGRES_SECRET_KEY` — **none of that
is a production posture**; see [Exposure](../security.md#exposure) and
[Secrets at rest](../security.md#secrets-at-rest) for what to change before
this ever serves real traffic or real provider keys.

```bash
git clone https://github.com/Rayjun0525/allgres.git
cd allgres
docker compose up -d --build       # allgres_pgdata is a named volume (docker-compose.yml),
                                    # not an anonymous one -- `docker volume ls` finds it,
                                    # and `docker compose down` (without -v) keeps it.
./scripts/bootstrap.sh             # waits for healthy, makes sure a first admin exists,
                                    # then runs one real agent task through to completion
```

A pre-built image is also published to GHCR (GitHub Container Registry) for
every tagged release, so a local build isn't required to try it:

```bash
docker pull ghcr.io/rayjun0525/allgres:latest   # or a specific tag, e.g. :v0.1.0-alpha.1
```

It's the same image `docker-compose.yml`'s `build: .` produces — swap
`build: .` for `image: ghcr.io/rayjun0525/allgres:latest` in a compose file
to use it directly, or `docker run` it against your own PostgreSQL setup
(see the main [README's Quick start](../../README.md#quick-start) for the
plain single-container `docker run` form of this same image). Published by
`.github/workflows/publish-image.yml` on every `v*` tag push (and available
on demand via that workflow's manual dispatch); `:latest` tracks the most
recent tag, not `main`.

Both published ports (`5432`, `8088`) are bound to host loopback only; see
[Exposure](../security.md#exposure) before changing that.

Anything meant to serve real traffic should layer `docker-compose.prod.yml`
on top instead of hand-editing `docker-compose.yml`'s own defaults:

```bash
ALLGRES_DASHBOARD_TOKEN=... ALLGRES_SECRET_KEY=... POSTGRES_PASSWORD=... \
  docker compose -f docker-compose.yml -f docker-compose.prod.yml up -d --build
```

It refuses to boot at all (`docker compose config`/`up` fails outright) if
any of those three are left unset, turns `ALLGRES_ENABLE_MOCK` off
unconditionally, unsets the base file's `ALLGRES_ALLOW_INSECURE_HTTP=1` (a
real token makes it unnecessary -- see [Exposure](../security.md#exposure)),
and stops publishing PostgreSQL's own port to the host at all
(`docker compose exec` is the intended access path for `psql`/backups).
The dashboard port stays loopback-only, same as the base file; put a
TLS-terminating reverse proxy on the same Docker network in front of it
before changing that.

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
   agent) deliberately ships with no provider configured — see [Model
   configuration](../chat-and-models.md) — so nothing would actually
   complete out of the box otherwise. The script seeds the built-in
   `allgres_mock` provider row (idempotent — it only ever touches that
   one, reserved-name row) and creates its own disposable agent to run
   against: login, `run`, a real LLM round trip, `completed`; then a real
   `agents.update` config change (`max_steps`) and model swap, confirmed
   persisted, and a second task proving the change didn't break execution
   — roadmap item 9's "설정 변경, 모델 교체" scenarios, exercised over
   real HTTP with a real session token. The disposable agent is
   deactivated afterward and no operator-created agent is ever touched by
   this check.
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

See [Source install](source-install.md) for a bare-metal (non-Docker)
install and version upgrades, and [Backup and restore](../backup-and-restore.md)
for both backup strategies — both apply identically whichever way the
extension got installed.
