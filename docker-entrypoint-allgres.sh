#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == "postgres" ]]; then
  set -- "$@" -c "shared_preload_libraries=allgres"
  # Provider secrets are encrypted at rest only when this GUC is set and
  # pgcrypto is installed; otherwise they are stored in plaintext and the
  # dashboard says so.
  if [[ -n "${ALLGRES_SECRET_KEY:-}" ]]; then
    set -- "$@" -c "allgres.secret_key=${ALLGRES_SECRET_KEY}"
  fi
fi

exec /usr/local/bin/docker-entrypoint.sh "$@"
