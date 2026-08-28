# Buildable MVP image: PostgreSQL 17 + one Allgres extension.
FROM postgres:17-bookworm AS builder

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates curl build-essential clang libclang-dev pkg-config git \
    postgresql-server-dev-17 && rm -rf /var/lib/apt/lists/*

RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal
ENV PATH=/root/.cargo/bin:$PATH
RUN cargo install --locked cargo-pgrx --version 0.19.2
RUN cargo pgrx init --pg17=/usr/lib/postgresql/17/bin/pg_config

WORKDIR /src/allgres
COPY . .
RUN cargo pgrx install --release --features pg17
# cargo-pgrx installs only the current version's script; extension upgrade
# scripts are ours to place.
RUN cp -f sql/allgres--*--*.sql /usr/share/postgresql/17/extension/ 2>/dev/null || true

FROM postgres:17-bookworm
COPY --from=builder /usr/lib/postgresql/17/lib/allgres.so /usr/lib/postgresql/17/lib/allgres.so
COPY --from=builder /usr/share/postgresql/17/extension/allgres* /usr/share/postgresql/17/extension/

RUN printf "shared_preload_libraries = 'allgres'\n" > /etc/postgresql-allgres.conf
COPY docker-entrypoint-allgres.sh /usr/local/bin/docker-entrypoint-allgres.sh
COPY 001-create-extension.sql /docker-entrypoint-initdb.d/001-create-extension.sql
COPY tests /opt/allgres/tests
RUN chmod +x /usr/local/bin/docker-entrypoint-allgres.sh
ENTRYPOINT ["docker-entrypoint-allgres.sh"]
CMD ["postgres"]
