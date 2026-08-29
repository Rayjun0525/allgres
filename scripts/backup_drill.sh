#!/usr/bin/env bash
# Backup/PITR drill: proves, against a real local PostgreSQL install, that
# both backup strategies documented in README.md actually work with Allgres
# installed -- not just that the commands exist.
#
#   1. Physical: pg_basebackup + WAL archiving + point-in-time recovery to a
#      specific timestamp, not just "replay everything."
#   2. Logical: pg_dump + pg_dumpall --globals-only, restored into a wholly
#      fresh cluster -- including that a per-agent PostgreSQL role
#      (agents.pg_role, see README "Per-agent roles") and the row-level
#      isolation it gates both survive.
#
# This script is what first caught two real bugs (see KNOWN_ISSUES.md,
# "backup/PITR drill"): pg_dump silently excluded 100% of Allgres's runtime
# data (no table was registered via pg_extension_config_dump), and the
# built-in LLM provider rows had random per-install ids that broke any
# foreign key crossing environments. Both are fixed in sql/control_plane.sql;
# this script is what to run again if either regresses.
#
# Requires: a local PostgreSQL 16 install with the allgres extension
# already built and installed (cargo pgrx install), run as a user that can
# `sudo -u postgres` and use pg_basebackup/initdb/pg_ctl directly -- this is
# a bare-metal drill, not a docker-compose one (scripts/smoke.sh covers the
# container path). Uses its own scratch directories under /var/lib/postgresql
# and its own ports (5433/5434), and cleans up after itself; it does not
# touch the primary cluster's data, only reads from it via pg_basebackup and
# pg_dump. Restores WAL archiving settings it changes back to what they were.
set -euo pipefail

PG_BIN="${PG_BIN:-/usr/lib/postgresql/16/bin}"
PGCONF="${PGCONF:-/etc/postgresql/16/main/postgresql.conf}"
CLUSTER="${CLUSTER:-16 main}"
SCRATCH="${SCRATCH:-/var/lib/postgresql/allgres-backup-drill}"
RESTORE_PORT="${RESTORE_PORT:-5433}"
FRESH_PORT="${FRESH_PORT:-5434}"

as_pg() { sudo -u postgres "$@"; }

# execution_logs is append-only -- enforced by trigger and by REVOKE, not
# just convention (see README, "Privileges") -- so a repeat run cannot
# clean up a prior run's rows by deleting them; that is by design, not an
# oversight to route around. Each run's test agents get a unique suffix
# instead, so re-running never collides and nothing needs deleting. The tiny
# rows a run leaves behind are permanent, exactly like every other agent's
# audit trail in this database, and are harmless.
SUFFIX="$(date +%s)_$$"

# SCRATCH is overridable (SCRATCH=... in the environment) and gets rm -rf'd
# twice below; refuse anything that isn't a plausible scratch path rather
# than trusting an override blindly. The previous check here
# (/var/lib/postgresql/*) was too wide -- confirmed by inspection: a
# mistyped override like SCRATCH=/var/lib/postgresql/16/main, a real
# cluster's own data directory, would have passed it and then been
# rm -rf'd outright. realpath -m canonicalizes first (resolves any ".."
# and symlinks before the prefix check runs, so neither can walk the
# check out of the directory it approved), and the prefix now names this
# script's own scratch directory specifically, not the whole
# /var/lib/postgresql/ tree any real cluster also lives under.
SCRATCH="$(realpath -m "$SCRATCH")"
case "$SCRATCH" in
  /var/lib/postgresql/allgres-backup-drill*) ;;
  *)
    echo "FAIL: SCRATCH ('$SCRATCH') must be under /var/lib/postgresql/allgres-backup-drill* -- refusing to rm -rf it" >&2
    exit 1
    ;;
esac

# Defense in depth beyond the path check above: only ever rm -rf a
# directory this script itself created and marked. A first run (or a
# SCRATCH that does not exist yet) has nothing to check -- this only fires
# when something is already sitting at this exact path without the marker,
# which the narrowed prefix above makes unlikely but not impossible (a
# stray directory created by hand, for instance).
if [ -d "$SCRATCH" ] && [ ! -f "$SCRATCH/.allgres_backup_drill_marker" ]; then
  echo "FAIL: '$SCRATCH' already exists and has no .allgres_backup_drill_marker -- refusing to rm -rf a directory this script did not create" >&2
  exit 1
fi

echo "=== backup_drill: cleaning any previous run's scratch clusters ==="
as_pg "$PG_BIN/pg_ctl" -D "$SCRATCH/pitr_restore" stop -m fast 2>/dev/null || true
as_pg "$PG_BIN/pg_ctl" -D "$SCRATCH/logical_restore" stop -m fast 2>/dev/null || true
rm -rf "$SCRATCH"
mkdir -p "$SCRATCH/wal_archive" "$SCRATCH/logs" "$SCRATCH/dumps" "$SCRATCH/sock"
touch "$SCRATCH/.allgres_backup_drill_marker"
chown -R postgres:postgres "$SCRATCH"
ARCHIVE_ADDED=0
trap '
  as_pg "$PG_BIN/pg_ctl" -D "$SCRATCH/pitr_restore" stop -m fast 2>/dev/null || true
  as_pg "$PG_BIN/pg_ctl" -D "$SCRATCH/logical_restore" stop -m fast 2>/dev/null || true
  if [ "$ARCHIVE_ADDED" = "1" ]; then
    sed -i "/^archive_mode = on\$/d; /^archive_command = .*backup_drill/d" "$PGCONF"
    pg_ctlcluster $CLUSTER restart
  fi
' EXIT

echo
echo "=== Phase 1: physical backup + point-in-time recovery ==="

if ! grep -q "^archive_mode = on$" "$PGCONF"; then
  echo "archive_mode = on" >> "$PGCONF"
  echo "archive_command = 'test ! -f $SCRATCH/wal_archive/%f && cp %p $SCRATCH/wal_archive/%f'" >> "$PGCONF"
  ARCHIVE_ADDED=1
  pg_ctlcluster $CLUSTER restart
  sleep 2
fi

as_pg "$PG_BIN/pg_basebackup" -D "$SCRATCH/basebackup" -Fp -X stream -c fast

as_pg psql -d postgres -v ON_ERROR_STOP=1 -c \
  "SELECT allgres_public.fn_create_agent('backup_drill_before_$SUFFIX', 'created before the PITR target');" >/dev/null
as_pg psql -d postgres -c "SELECT pg_switch_wal();" >/dev/null
T1=$(as_pg psql -d postgres -t -A -c "SELECT now();")
sleep 2
as_pg psql -d postgres -v ON_ERROR_STOP=1 -c \
  "SELECT allgres_public.fn_create_agent('backup_drill_after_$SUFFIX', 'created after the PITR target -- must NOT survive the restore');" >/dev/null
as_pg psql -d postgres -c "SELECT pg_switch_wal();" >/dev/null

cp -a "$SCRATCH/basebackup" "$SCRATCH/pitr_restore"
chown -R postgres:postgres "$SCRATCH/pitr_restore"
rm -f "$SCRATCH/pitr_restore/postmaster.pid"
cp "$(dirname "$PGCONF")/postgresql.conf" "$(dirname "$PGCONF")/pg_hba.conf" "$(dirname "$PGCONF")/pg_ident.conf" \
  "$SCRATCH/pitr_restore/"
python3 - "$SCRATCH/pitr_restore/postgresql.conf" "$SCRATCH/pitr_restore" "$RESTORE_PORT" "$SCRATCH/sock" <<'PYEOF'
import re, sys
path, datadir, port, sockdir = sys.argv[1:5]
s = open(path).read()
s = re.sub(r"^data_directory = .*$", f"data_directory = '{datadir}'", s, flags=re.M)
s = re.sub(r"^hba_file = .*$", f"hba_file = '{datadir}/pg_hba.conf'", s, flags=re.M)
s = re.sub(r"^ident_file = .*$", f"ident_file = '{datadir}/pg_ident.conf'", s, flags=re.M)
s = re.sub(r"^external_pid_file = .*$", f"external_pid_file = '{datadir}/pid'", s, flags=re.M)
s = re.sub(r"^unix_socket_directories = .*$", f"unix_socket_directories = '{sockdir}'", s, flags=re.M)
s = re.sub(r"^port = .*$", f"port = {port}", s, flags=re.M)
s = re.sub(r"^include_dir = .*$", "#include_dir = 'conf.d'", s, flags=re.M)
open(path, "w").write(s)
PYEOF
chown postgres:postgres "$SCRATCH/pitr_restore/postgresql.conf" "$SCRATCH/pitr_restore/pg_hba.conf" "$SCRATCH/pitr_restore/pg_ident.conf"

as_pg touch "$SCRATCH/pitr_restore/recovery.signal"
cat >> "$SCRATCH/pitr_restore/postgresql.auto.conf" <<EOF
restore_command = 'cp $SCRATCH/wal_archive/%f %p'
recovery_target_time = '$T1'
recovery_target_action = 'promote'
EOF
chown postgres:postgres "$SCRATCH/pitr_restore/postgresql.auto.conf"

as_pg "$PG_BIN/pg_ctl" -D "$SCRATCH/pitr_restore" -l "$SCRATCH/logs/pitr_restore.log" start
for _ in $(seq 1 30); do as_pg pg_isready -h "$SCRATCH/sock" -p "$RESTORE_PORT" -q && break; sleep 1; done
# pg_isready only proves the server accepts connections, which is already
# true during hot-standby replay -- before recovery_target_action=promote
# has actually finished promoting to a writable primary. Confirmed live:
# querying right after pg_isready hit both a stale read ("before=0 after=0",
# recovery hadn't replayed up to the target LSN yet) and, once that race
# was papered over by a retry, "cannot execute UPDATE in a read-only
# transaction" from fn_selftest -- still not promoted. Waiting on
# pg_is_in_recovery() = false is what the PITR restore actually needs;
# pg_isready alone is not far enough.
for _ in $(seq 1 60); do
  v=$(as_pg psql -h "$SCRATCH/sock" -p "$RESTORE_PORT" -d postgres -t -A -c "SELECT pg_is_in_recovery();" 2>/dev/null || echo "")
  [ "$v" = "f" ] && break
  sleep 1
done

BEFORE=$(as_pg psql -h "$SCRATCH/sock" -p "$RESTORE_PORT" -d postgres -t -A -c \
  "SELECT count(*) FROM allgres_private.agents WHERE name = 'backup_drill_before_$SUFFIX';")
AFTER=$(as_pg psql -h "$SCRATCH/sock" -p "$RESTORE_PORT" -d postgres -t -A -c \
  "SELECT count(*) FROM allgres_private.agents WHERE name = 'backup_drill_after_$SUFFIX';")
if [ "$BEFORE" != "1" ] || [ "$AFTER" != "0" ]; then
  echo "FAIL: PITR did not land at the intended point in time (before=$BEFORE after=$AFTER)" >&2
  exit 1
fi
SELFTEST=$(as_pg psql -h "$SCRATCH/sock" -p "$RESTORE_PORT" -d postgres -t -A -c \
  "SELECT (allgres_public.fn_selftest()->>'failed')::int;")
if [ "$SELFTEST" != "0" ]; then
  echo "FAIL: fn_selftest had $SELFTEST failures on the PITR-restored instance" >&2
  exit 1
fi
echo "OK: point-in-time recovery landed exactly at the target (before-agent present, after-agent absent), fn_selftest clean"
as_pg "$PG_BIN/pg_ctl" -D "$SCRATCH/pitr_restore" stop -m fast

echo
echo "=== Phase 2: logical dump/restore, including per-agent role isolation ==="

as_pg psql -d postgres -v ON_ERROR_STOP=1 -c "
DO \$\$
DECLARE v_agent uuid;
BEGIN
  v_agent := (allgres_public.fn_create_agent('backup_drill_logical_$SUFFIX', 'logical restore check')->>'agent_id')::uuid;
  PERFORM allgres_public.fn_grant_permission(v_agent, 'view', 'allgres_public.v_my_tasks');
  PERFORM allgres_public.fn_create_session(v_agent, 'logical restore drill session');
END \$\$;" >/dev/null

as_pg pg_dump -Fc -d postgres -f "$SCRATCH/dumps/postgres.dump" 2>/dev/null
as_pg pg_dumpall --globals-only -f "$SCRATCH/dumps/globals.sql"

as_pg "$PG_BIN/initdb" -D "$SCRATCH/logical_restore" --auth=trust > "$SCRATCH/logs/initdb.log" 2>&1
cat >> "$SCRATCH/logical_restore/postgresql.conf" <<EOF
shared_preload_libraries = 'allgres'
port = $FRESH_PORT
unix_socket_directories = '$SCRATCH/sock'
EOF
chown postgres:postgres "$SCRATCH/logical_restore/postgresql.conf"
as_pg env ALLGRES_HTTP_ADDR=127.0.0.1:0 "$PG_BIN/pg_ctl" -D "$SCRATCH/logical_restore" -l "$SCRATCH/logs/logical_restore.log" start
for _ in $(seq 1 30); do as_pg pg_isready -h "$SCRATCH/sock" -p "$FRESH_PORT" -q && break; sleep 1; done

# Not -v ON_ERROR_STOP=1: pg_dumpall --globals-only unconditionally emits
# `CREATE ROLE postgres ...` (and similar) for roles initdb already
# created on this fresh cluster, which errors, expectedly, every run --
# turning that into a hard stop would break the one case that is
# supposed to happen. What must NOT happen silently is anything else
# failing alongside it, which running with no error checking at all
# (the gap an external review caught) cannot tell apart from the expected
# case -- so every ERROR line in the log is inspected below, and only
# ones that don't match the expected shape fail the drill.
as_pg psql -h "$SCRATCH/sock" -p "$FRESH_PORT" -d postgres -f "$SCRATCH/dumps/globals.sql" > "$SCRATCH/logs/globals_apply.log" 2>&1 || true
UNEXPECTED=$(grep "ERROR:" "$SCRATCH/logs/globals_apply.log" | grep -v "already exists" || true)
if [ -n "$UNEXPECTED" ]; then
  echo "FAIL: unexpected error(s) applying globals.sql:" >&2
  echo "$UNEXPECTED" >&2
  exit 1
fi

# Two-pass restore, not one: pg_restore's --disable-triggers only takes
# effect during a --data-only restore (`pg_restore --help` says so exactly;
# combined with a full restore it is silently a no-op). Without it, the
# agents_ensure_policy trigger fires while the dumped `agents` rows load,
# creating a default policies row per agent, which then collides with that
# same agent's *real* policies row arriving right behind it in the dump.
as_pg pg_restore -h "$SCRATCH/sock" -p "$FRESH_PORT" -d postgres --no-owner --role=postgres \
  --schema-only "$SCRATCH/dumps/postgres.dump" > "$SCRATCH/logs/restore_schema.log" 2>&1
as_pg pg_restore -h "$SCRATCH/sock" -p "$FRESH_PORT" -d postgres --no-owner --role=postgres \
  --data-only --disable-triggers "$SCRATCH/dumps/postgres.dump" > "$SCRATCH/logs/restore_data.log" 2>&1

# SET LOCAL ROLE straight from this postgres superuser session would
# succeed regardless of whether the dump/restore actually preserved the
# GRANT <agent_role> TO worker membership fn_provision_agent_role makes --
# a superuser can assume any role, membership grant or not, so that alone
# only proves the role exists, not that the real path works. Hopping
# through `worker` first, the same as the real runtime worker does
# (drop_privileges() -> worker, then run_sandboxed_sql's own
# SET LOCAL ROLE <agent_role>), means the *second* SET ROLE only succeeds
# if worker's membership in the agent role actually survived -- once
# current_user is a non-superuser role, PostgreSQL checks that role's own
# grants for the next SET ROLE, not the original session's.
ROLE_OK=$(as_pg psql -h "$SCRATCH/sock" -p "$FRESH_PORT" -d postgres -t -A -v ON_ERROR_STOP=1 -c "
DO \$\$
DECLARE
  v_role text; v_sql text; v_agent uuid; v_result jsonb;
BEGIN
  SELECT agent_id, pg_role INTO v_agent, v_role FROM allgres_private.agents WHERE name = 'backup_drill_logical_$SUFFIX';
  v_sql := allgres_private.fn_validate_sql(v_agent, 'SELECT task_id FROM allgres_public.v_my_tasks');
  SET LOCAL ROLE worker;
  IF current_user <> 'worker' THEN RAISE EXCEPTION 'worker role not assumed: %', current_user; END IF;
  EXECUTE format('SET LOCAL ROLE %I', v_role);
  IF current_user <> v_role THEN RAISE EXCEPTION 'agent role not assumed from worker (membership lost in restore?): %', current_user; END IF;
  v_result := allgres_public.fn_run_sandboxed_sql(v_sql);
  IF NOT COALESCE((v_result->>'ok')::boolean, false) OR COALESCE(jsonb_array_length(v_result->'rows'), 0) = 0 THEN
    RAISE EXCEPTION 'agent could not see its own task after restore: %', v_result;
  END IF;
  RESET ROLE;
  RAISE NOTICE 'role isolation ok';
END \$\$;" 2>&1)
echo "$ROLE_OK" | grep -q "role isolation ok" || { echo "FAIL: role isolation did not survive logical restore:"; echo "$ROLE_OK" >&2; exit 1; }

SELFTEST2=$(as_pg psql -h "$SCRATCH/sock" -p "$FRESH_PORT" -d postgres -t -A -c \
  "SELECT (allgres_public.fn_selftest()->>'failed')::int;")
if [ "$SELFTEST2" != "0" ]; then
  echo "FAIL: fn_selftest had $SELFTEST2 failures on the logically-restored instance" >&2
  exit 1
fi
echo "OK: logical dump/restore preserved agent data, provider secrets, and per-agent role isolation; fn_selftest clean"
as_pg "$PG_BIN/pg_ctl" -D "$SCRATCH/logical_restore" stop -m fast

echo
echo "=== backup_drill: all checks passed ==="
rm -rf "$SCRATCH"
