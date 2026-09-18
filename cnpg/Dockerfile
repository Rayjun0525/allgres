# Extension-only image for CNPG's Image Volume Extensions mechanism
# (https://cloudnative-pg.io -- docs/src/imagevolume_extensions.md), NOT a
# full Postgres image: CNPG mounts this at /extensions/allgres inside its
# own official operand image (ghcr.io/cloudnative-pg/postgresql:18-...)
# rather than allgres shipping (and having to keep in sync) a whole custom
# postgres image the way the repo-root Dockerfile does for plain Docker/
# docker-compose. Requires PostgreSQL 18+ (the extension_control_path GUC
# this mechanism relies on is PG18+) and Kubernetes 1.33+ with the
# ImageVolume feature gate (default-on from 1.35). See cnpg/cluster-
# example.yaml for how a Cluster actually references this image, and
# README.md, "CNPG (CloudNativePG)", for the full picture.
#
# Modeled directly on cloudnative-pg/postgres-extensions-containers'
# pgvector/Dockerfile -- same base image default, same FROM-scratch final
# layout -- swapping its "apt-get install a prebuilt .deb" builder stage
# for a from-source cargo-pgrx build, since no prebuilt allgres package
# exists anywhere to install instead.
ARG BASE=ghcr.io/cloudnative-pg/postgresql:18-minimal-trixie
FROM $BASE AS builder
ARG PG_MAJOR=18
USER 0

# Building against this exact operand image (not a generic postgres:18
# image) is deliberate: the compiled .so links against this image's own
# libpq/postgres internals, and CNPG runs the extension inside this same
# image at runtime -- building anywhere else risks an ABI mismatch that
# only shows up as a mysterious dlopen failure in a real cluster, not a
# build error here.
#
# UNVERIFIED (no Docker daemon in the environment this Dockerfile was
# written in -- see docs/deployment/cnpg.md): this assumes the
# PGDG apt repo that gives this base image its own postgresql-${PG_MAJOR}
# packages also has postgresql-server-dev-${PG_MAJOR} available from the
# same source. If this RUN fails on "Unable to locate package", that
# assumption is the first thing to check.
#
# libssl-dev: cargo-pgrx's own openssl-sys dependency needs it directly,
# not just PostgreSQL's own SSL support -- postgresql-server-dev-${PG_MAJOR}
# pulls it in transitively via libpq-dev on Debian, but that chain is not
# something to rely on silently (confirmed live: a source install on a
# machine without it hit exactly this, see KNOWN_ISSUES.md item 52).
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates curl build-essential clang libclang-dev pkg-config \
    libssl-dev git "postgresql-server-dev-${PG_MAJOR}" \
    && rm -rf /var/lib/apt/lists/*

RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal
ENV PATH=/root/.cargo/bin:$PATH
RUN cargo install --locked cargo-pgrx --version 0.19.2
RUN cargo pgrx init --pg${PG_MAJOR}=$(command -v pg_config)

WORKDIR /src/allgres
COPY . .
# `COPY . .` only ever sees the build *context*, not this Dockerfile's own
# directory -- confirmed live: building with `cnpg/` itself as the context
# (e.g. running `docker build` from inside `cnpg/`, or `-f cnpg/Dockerfile
# cnpg/`) copies just this directory's two files and fails here with
# "could not find `Cargo.toml`", since Cargo.toml/Cargo.lock/src/sql never
# arrive at all. The context must be the repo root: `docker build -f
# cnpg/Dockerfile .` run from the repo root, exactly as README.md's own
# "CNPG (CloudNativePG)" section shows it. This check exists so that
# mistake fails here, with this message, instead of inside cargo-pgrx with
# a much less obvious one.
RUN test -f Cargo.toml || { \
      echo >&2 "ERROR: Cargo.toml not found at the build context root."; \
      echo >&2 "Build this from the repo root with the repo root as the"; \
      echo >&2 "context, e.g.: docker build -f cnpg/Dockerfile . -- not"; \
      echo >&2 "from inside cnpg/ itself."; \
      exit 1; \
    }
RUN cargo pgrx package --pg-config $(command -v pg_config) --no-default-features --features pg${PG_MAJOR}

# `FROM scratch`, not the CNPG base again: this image is never itself run
# as a container -- CNPG mounts its filesystem read-only via Kubernetes'
# ImageVolume, so nothing in it beyond these two directories (lib/,
# share/extension/) is ever actually used. USER 65532:65532 matches
# postgres-extensions-containers' own convention for these mount-only
# images (distinct from the operand image's own UID 26).
FROM scratch
ARG PG_MAJOR=18
COPY --from=builder /src/allgres/target/release/allgres-pg${PG_MAJOR}/usr/lib/postgresql/${PG_MAJOR}/lib/allgres.so /lib/
COPY --from=builder /src/allgres/target/release/allgres-pg${PG_MAJOR}/usr/share/postgresql/${PG_MAJOR}/extension/allgres* /share/extension/
USER 65532:65532
