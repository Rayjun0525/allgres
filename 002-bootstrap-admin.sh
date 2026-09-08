#!/usr/bin/env bash
# Optional first-admin bootstrap, the last step of "one install flow" (see
# README, "Install flow"): 001-create-extension.sql already ran by the time
# any docker-entrypoint-initdb.d/*.sh script runs, so allgres_public.fn_create_user
# is callable here. This only fires when both ALLGRES_BOOTSTRAP_ADMIN_USER and
# ALLGRES_BOOTSTRAP_ADMIN_PASSWORD are set -- an operator who wants to keep
# creating the first admin by hand (`psql -c "SELECT fn_create_user(...)"`,
# the same one-liner used throughout this project's own development) sees no
# behavior change at all.
#
# Like every other file here, this only ever runs once: postgres's own
# entrypoint invokes docker-entrypoint-initdb.d/* exactly when it is
# initializing a brand new $PGDATA, never again on a restart against an
# existing (named-volume) one -- so this is genuinely a first-boot bootstrap,
# not something that runs on every container start.
set -euo pipefail

if [[ -z "${ALLGRES_BOOTSTRAP_ADMIN_USER:-}" || -z "${ALLGRES_BOOTSTRAP_ADMIN_PASSWORD:-}" ]]; then
  exit 0
fi

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL
  SELECT allgres_public.fn_create_user(
    '$(printf '%s' "$ALLGRES_BOOTSTRAP_ADMIN_USER" | sed "s/'/''/g")',
    '$(printf '%s' "$ALLGRES_BOOTSTRAP_ADMIN_PASSWORD" | sed "s/'/''/g")',
    'admin'
  );
EOSQL
