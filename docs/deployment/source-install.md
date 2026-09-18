# Source install (bare metal)

Part of the [documentation index](../../README.md). See also the main
[README's Quick start](../../README.md#quick-start) for the condensed version
of the first part of this page.

No Docker: install straight onto an existing PostgreSQL 16, 17, or 18
server. The guiding principle is the same as Docker's `./scripts/
bootstrap.sh` — a working instance in a handful of commands, not a
multi-page install guide to work through by hand. You need three things on
`PATH` before the first command below:

- That PostgreSQL version's own `-dev`/`-server-dev`/`-devel` package,
  which provides both `pg_config` and the C header files (`include/
  server`) `cargo-pgrx` compiles against — e.g. `apt install
  postgresql-server-dev-17` on Debian/Ubuntu, or `dnf install
  postgresql17-devel` on RHEL/Rocky/Alma/Fedora via the PGDG yum/dnf
  repo, matching whichever major version you're targeting. **`pg_config`
  being on `PATH` is not proof this is actually installed** — confirmed
  live on a PGDG RPM install where `pg_config` resolved and reported a
  valid version, but its own `--includedir-server` pointed at
  `/usr/pgsql-18/include/server`, which didn't exist, because only
  `postgresql18-server` (runtime) was installed, not the separate
  `postgresql18-devel` package headers actually live under; `make check`
  now runs `pg_config --includedir-server` itself and fails fast if that
  directory is missing, instead of `cargo-pgrx`'s own bindgen step dying
  deep inside `cargo install cargo-pgrx` with "cannot find ...
  include/server for C header files".
  On RHEL/Rocky/Alma **9** specifically, installing `postgresqlNN-devel`
  can itself fail first, on `perl(IPC::Run)`/`perl-IPC-Run` — one of
  `postgresqlNN-devel`'s own dependencies (used by PostgreSQL's TAP test
  tooling, not by allgres), which lives in the CRB (CodeReady Builder)
  repo, not enabled by default on a fresh RHEL9-family install. Confirmed
  live: enabling CRB for just that one install is enough on its own — no
  EPEL needed —
  ```bash
  sudo dnf -y --enablerepo=crb install postgresql17-devel
  ```
  or, to enable CRB for good instead of per-command:
  ```bash
  sudo dnf config-manager --set-enabled crb   # Rocky/Alma 9; on real RHEL 9 use:
  # sudo subscription-manager repos --enable codeready-builder-for-rhel-9-$(arch)-rpms
  sudo dnf install -y postgresql17-devel      # retry, now resolvable
  ```
- A C toolchain: `cc`/`gcc` and `clang`/`libclang-dev` specifically —
  `cargo-pgrx` itself (the tool, before it ever touches this extension's
  own source) needs one to build, via `bindgen`'s use of libclang for
  Postgres FFI generation. On Debian/Ubuntu: `apt install build-essential
  clang libclang-dev pkg-config`.
- OpenSSL's development files: `cargo-pgrx` also pulls in `openssl-sys`,
  which needs `pkg-config` to find `openssl.pc` and the headers/library
  it points at. On Debian/Ubuntu: `apt install libssl-dev`; on
  Fedora/RHEL: `dnf install openssl-devel`. **Not every environment that
  already has a C toolchain and `clang` also has this** — confirmed live
  on an aarch64 machine that had everything else and still hit `error:
  failed to compile cargo-pgrx` from a bare `openssl-sys` build-script
  failure, distinct from (and only reachable after fixing) the missing-
  compiler case below.

All three package lists above are the exact ones the repo-root
`Dockerfile` and `cnpg/Dockerfile` already install before their own
`cargo-pgrx` build. Missing any of them surfaces as `error: failed to
compile cargo-pgrx v0.19.2`, with the real reason only visible scrolled
up in Cargo's own build output; `make check` (run automatically by
`make`/`make install`) now fails fast with a clear message naming
whichever piece is actually missing instead, before ever reaching that
`cargo install` line.

Rust and `cargo-pgrx` are handled for you if they aren't already there:

```bash
git clone https://github.com/Rayjun0525/allgres.git
cd allgres
make install     # needs root? see the note just below, not a bare `sudo`
make quickstart  # CREATE EXTENSION + start, no restart -- see below
```

**If `lib`/`share` aren't writable by your own account** (the common
case running as the `postgres` service account itself, which usually has
no usable login password): run the whole thing as root from the start,
`sudo env "PATH=$PATH" make install`, rather than a plain `make install`.
Without the `sudo` prefix, `install`'s own recipe still tries to recover
by adding `cargo pgrx install`'s `--sudo` flag whenever it detects it
isn't already root — but that makes `cargo-pgrx` shell out to a real
interactive `sudo cp` *per file*, prompting for a password that a
service account frequently can't supply at all. Running the entire
command as root from the outset avoids that nested prompt entirely
(`env "PATH=$PATH"` just carries over wherever `cargo`/`cargo-pgrx`/
`pg_config` were installed under the non-root account's own `$HOME`, so
root's shell still finds them).

Four commands, and the last two are only two because `install` and
*running* it are kept deliberately separate (`install` only ever touches
this machine's PostgreSQL installation, the same as any extension's own
`make install`; `quickstart` is the one step that touches a live database,
so it stays opt-in rather than a side effect of building). `make` alone
(no target) stages a build under `target/release/allgres-pgNN/` without
touching the system at all, if you just want to compile first and decide
later. `make install` explains its own next steps when it finishes, in
case you'd rather run them by hand or against a different database than
`quickstart`'s default of `postgres`.

What the Makefile is actually doing, for anyone who wants to run the
underlying commands directly instead, or already has `cargo-pgrx`
installed and configured: it installs `cargo-pgrx` if missing (`cargo
install --locked cargo-pgrx --version 0.19.2`, pinned to whatever this
crate's own `Cargo.toml` requires), runs `cargo pgrx init` for the one
PostgreSQL version `pg_config` resolves to, then `cargo pgrx install
--release --features pgNN`, which compiles the extension and copies the
`.so`/`.control`/`.sql` files into that installation's own extension
directory — no manual file copying either way.

Open the address `ALLGRES_HTTP_ADDR` defaults to
(`http://127.0.0.1:8088`) the same as the Docker path. See
[Configuration](../configuration.md) for every environment variable the
runtime worker reads.

That default is loopback-only on purpose — see [Security model,
"Exposure"](../security.md#exposure) for why — which matters more on a
source install than the Docker path's own `-p 127.0.0.1:8088:8088` might
suggest: `ALLGRES_HTTP_ADDR` is a plain process environment variable (not
a GUC), read once when the web worker starts, so it has to be exported
into the shell `postgres` itself is started from, then applied with a
real restart (`pg_ctl restart`, not `SET`/reload — a background worker
only re-reads its own process environment at the next fork). To reach
the dashboard from outside the machine `postgres` runs on (including from
outside a container you're source-installing into, where Docker's own
port-forwarding targets the container's real network interface and can
never reach something bound to the container's own loopback):

```bash
export ALLGRES_HTTP_ADDR=0.0.0.0:8088
export ALLGRES_ALLOW_INSECURE_HTTP=1   # required for a non-loopback bind with no token set
pg_ctl restart -D /path/to/your/data/dir
```

`ALLGRES_ALLOW_INSECURE_HTTP=1` is exactly as permissive as it sounds —
anyone who can reach the port can create agents, rewrite prompts, and
register provider keys with no token at all — so treat it the same way
the Docker path's own compose file does: fine behind a network boundary
you already trust, never a substitute for `ALLGRES_DASHBOARD_TOKEN` or a
TLS-terminating reverse proxy on anything actually reachable by others.

`make quickstart` uses the no-restart path (`allgres.reloadable`) covered
in detail just below, in [Installing without a
restart](#installing-without-a-restart) — worth reading once for what it
actually trades off. The classic path still works exactly as it always
has, and is what a from-scratch production install should default to:

```conf
shared_preload_libraries = 'allgres'
```

restart PostgreSQL (a plain reload is not enough — this registers a
background worker, which only happens at postmaster start), then

```sql
CREATE EXTENSION IF NOT EXISTS pgcrypto;   -- optional, encrypts secrets at rest
CREATE EXTENSION allgres;
```

## Installing without a restart

The `shared_preload_libraries` restart above is a real PostgreSQL
constraint, not an Allgres choice: both background workers (`allgres
runtime`, `allgres web`) are registered from `_PG_init`, which only runs
during preload processing, and only a postmaster restart re-runs that.
For an operator who cannot restart the server they're installing onto — a
managed instance where changing `shared_preload_libraries` means a
maintenance window, or simply one they'd rather not schedule for a first
try — there's a second path that needs no restart at all:

```conf
allgres.reloadable = on
```

`allgres.reloadable` is a placeholder GUC, exactly like `allgres.secret_key`
(see [Secrets at rest](../security.md#secrets-at-rest)) — settable in
`postgresql.conf` or via `SET` for one session, no preload required to read
it. With it `on`, skip the `shared_preload_libraries` line and the restart
entirely:

```sql
CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE EXTENSION allgres;
SELECT allgres_public.fn_start_dynamic_workers();
```

(exactly what `make quickstart` runs, against the `postgres` database, if
`allgres` is already installed).

That last call registers both workers with PostgreSQL's own
`RegisterDynamicBackgroundWorker`, the same mechanism `pg_cron` and similar
extensions use for on-demand workers, instead of the static path
`shared_preload_libraries` takes. It is safe to call more than once — a
second call finds both already running and is a no-op — and it is a no-op,
not an error, when `allgres` actually is preloaded (the postmaster already
owns the workers there).

The tradeoff is real and worth stating plainly: a crash of either worker
self-heals exactly the way it does under `shared_preload_libraries` (the
postmaster honors the same restart timer regardless of how a worker was
registered), but nothing persists a dynamic registration anywhere, so a
full PostgreSQL restart — for any reason, planned or not — drops both
workers and does not bring them back on its own. There is no watchdog that
notices and calls `fn_start_dynamic_workers()` again automatically; that
call is the operator's own to make, after `CREATE EXTENSION` and again
after every subsequent restart. For a deployment where PostgreSQL itself
restarts often (or where "came back up quiet" needs to mean the dashboard
actually came back too), `shared_preload_libraries` remains the better
default — this path exists for the specific case where the one restart it
saves is the one that matters.

## Upgrades

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
