# Wraps cargo-pgrx so building allgres from source is the same two
# commands as any other native Postgres extension: `make` then `make
# install` (`sudo` prepended if the extension directories need it -- see
# the `install` target below). Nothing here replaces
# `cargo pgrx <subcommand>` directly -- it only detects the one locally
# installed PostgreSQL version and the cargo-pgrx version this crate is
# pinned to, so neither has to be typed by hand every time.
#
# `make quickstart` goes one step further and actually runs the thing --
# against the `postgres` database, using the no-restart install path
# (docs/deployment/source-install.md, "Installing without a restart")
# rather than editing postgresql.conf. Kept separate from `install` on
# purpose: `install` only ever touches this machine's Postgres
# *installation* (files under
# pg_config's own lib/share dirs, same as any extension's own `make
# install`); `quickstart` is the one target that touches a live database,
# so it stays a deliberate, separate step rather than a side effect of
# building the extension.

PG_CONFIG ?= pg_config
QUICKSTART_DB ?= postgres

CARGO_PGRX_VERSION := $(shell grep -E '^pgrx = ' Cargo.toml | sed -E 's/.*version = "=?([0-9.]+)".*/\1/')
PG_MAJOR := $(shell $(PG_CONFIG) --version 2>/dev/null | sed -E 's/PostgreSQL ([0-9]+).*/\1/')

.PHONY: build install quickstart clean check

check:
ifeq ($(PG_MAJOR),)
	$(error pg_config not found on PATH -- install this PostgreSQL version's \
	  -dev/-server-dev package (e.g. `apt install postgresql-server-dev-17`, \
	  matching whatever major version you're targeting) first, or set \
	  PG_CONFIG=/path/to/pg_config if it's already installed somewhere \
	  not on PATH)
endif
ifeq ($(filter $(PG_MAJOR),16 17 18),)
	$(error PostgreSQL $(PG_MAJOR) (from $(PG_CONFIG)) is not supported -- \
	  Allgres targets 16, 17, and 18)
endif
ifeq ($(shell command -v cc 2>/dev/null || command -v gcc 2>/dev/null),)
	$(error no C compiler found on PATH -- cargo-pgrx itself needs one to \
	  build (via bindgen, for Postgres FFI generation), before it ever \
	  touches this extension's own source. Install a C toolchain first \
	  (Debian/Ubuntu: `apt install build-essential clang libclang-dev \
	  pkg-config` -- the same packages the repo-root Dockerfile and \
	  cnpg/Dockerfile already install before their own cargo-pgrx build). \
	  Without this, `cargo install cargo-pgrx` below fails with a bare \
	  "error: failed to compile `cargo-pgrx`" and no further explanation)
endif
ifeq ($(shell command -v clang 2>/dev/null),)
	$(error clang not found on PATH -- bindgen (a cargo-pgrx dependency) \
	  needs libclang specifically, not just a generic C compiler. Install \
	  it first (Debian/Ubuntu: `apt install clang libclang-dev`))
endif
ifeq ($(shell command -v pkg-config 2>/dev/null),)
	$(error pkg-config not found on PATH -- several of cargo-pgrx's own \
	  dependencies (openssl-sys among them) need it to locate system \
	  libraries. Install it first (Debian/Ubuntu: `apt install \
	  pkg-config`))
endif
ifeq ($(shell pkg-config --exists openssl 2>/dev/null && echo yes),)
	$(error OpenSSL development files not found via pkg-config -- \
	  cargo-pgrx's own openssl-sys dependency needs them to build, \
	  regardless of PostgreSQL's own OpenSSL support. Confirmed live: not \
	  every base image that already has a C toolchain and clang also has \
	  this. Install them first (Debian/Ubuntu: `apt install libssl-dev`; \
	  Fedora/RHEL: `dnf install openssl-devel`), or set PKG_CONFIG_PATH \
	  to wherever `openssl.pc` actually lives if it's already installed \
	  somewhere pkg-config isn't searching)
endif
	@echo "Targeting PostgreSQL $(PG_MAJOR) via $(PG_CONFIG)"

# rustup's own official install method -- the same one-liner Dockerfile
# already uses -- only runs when `cargo` isn't already on PATH, so this is
# a no-op on any machine that already has Rust.
build: check
	@command -v cargo >/dev/null 2>&1 || { \
	  echo "Rust not found -- installing via rustup"; \
	  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal; \
	  echo "Add \$$HOME/.cargo/bin to PATH (or open a new shell) and re-run make."; \
	  exit 1; \
	}
	@command -v cargo-pgrx >/dev/null 2>&1 || cargo install --locked cargo-pgrx --version $(CARGO_PGRX_VERSION)
	@cargo pgrx init --pg$(PG_MAJOR)=$(PG_CONFIG)
	cargo pgrx package --pg-config $(PG_CONFIG) --no-default-features --features pg$(PG_MAJOR)

# `-s`/`--sudo` only when not already root -- the extension directories
# pg_config points at (lib/share under the PostgreSQL install itself) are
# root- or postgres-owned on most systems; skipping the flag when already
# root avoids a `sudo: command not found` failure in a container that has
# no sudo binary at all, which is exactly the environment this project's
# own Dockerfile builds in.
install: build
	cargo pgrx install $(if $(filter 0,$(shell id -u)),,--sudo) \
	  --pg-config $(PG_CONFIG) --release --no-default-features --features pg$(PG_MAJOR)
	@echo ""
	@echo "allgres is installed. Two ways to actually run it -- pick one:"
	@echo ""
	@echo "  1) No restart needed: 'make quickstart' (against the '$(QUICKSTART_DB)'"
	@echo "     database), or by hand: SET allgres.reloadable = 'on'; then"
	@echo "     CREATE EXTENSION allgres; then"
	@echo "     SELECT allgres_public.fn_start_dynamic_workers();"
	@echo ""
	@echo "  2) shared_preload_libraries = 'allgres' in postgresql.conf, restart"
	@echo "     Postgres, then CREATE EXTENSION allgres;"
	@echo ""
	@echo "See docs/deployment/source-install.md for the full picture."

quickstart:
	psql -v ON_ERROR_STOP=1 -d $(QUICKSTART_DB) -c "SET allgres.reloadable = 'on'; \
	  CREATE EXTENSION IF NOT EXISTS pgcrypto; \
	  CREATE EXTENSION IF NOT EXISTS allgres; \
	  SELECT allgres_public.fn_start_dynamic_workers();"
	@echo ""
	@echo "\"ok\": true above -- allgres just started with no restart; open http://127.0.0.1:8088"
	@echo "\"ok\": false, already in shared_preload_libraries -- also fine, the static"
	@echo "  (postmaster-managed) workers already cover it; open http://127.0.0.1:8088 the same way"
	@echo "any other \"ok\": false -- dynamic start didn't happen; see"
	@echo "  docs/deployment/source-install.md, 'Installing without a restart'"

clean:
	cargo clean
