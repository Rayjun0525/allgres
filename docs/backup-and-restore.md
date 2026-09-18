# Backup and restore

Part of the [documentation index](../README.md). See also: [Per-agent
roles](security.md#per-agent-roles).

`scripts/backup_drill.sh` is a runnable, re-runnable drill against a real
local PostgreSQL 16 install (bare-metal, not `docker-compose` — that path is
`scripts/smoke.sh`) that proves both backup strategies below actually work
with Allgres installed, not just that the commands exist. It is what first
caught the two bugs described in KNOWN_ISSUES.md, item 18; run it again if
either regresses.

**Physical (`pg_basebackup` + WAL archiving + PITR).** Covers everything,
including per-agent PostgreSQL roles (`agents.pg_role`) automatically, since
it copies the actual data files. Standard PostgreSQL procedure — take a
base backup, archive WAL, restore with a `recovery_target_time` — nothing
Allgres-specific to it.

**Logical (`pg_dump` + `pg_dumpall --globals-only`).** Needs two things this
extension does that a generic `pg_dump` would otherwise miss silently:

- **Roles are cluster-global.** `agents.pg_role` values (real `NOLOGIN`
  PostgreSQL roles, see [Per-agent roles](security.md#per-agent-roles)) are not part of
  any database dump — restoring onto a fresh cluster needs
  `pg_dumpall --globals-only` applied first, or every agent's row-level
  isolation is gone even though the row data itself restored fine.
- **Restore in two passes, not one.** `sql/control_plane.sql` and
  `sql/seed_data.sql` register
  every table holding real operator/agent state via
  `pg_extension_config_dump()` (agents, sessions, tasks, policies and their
  history, permissions, projects, execution logs, human approvals, change
  proposals, provider secrets, agent memories, and the outbound/SQL/OAuth
  call queues), so a plain
  `pg_dump` now actually includes this extension's data — it silently did
  not, before KNOWN_ISSUES.md item 18. Restoring it needs
  `pg_restore --schema-only` first (creates the extension and its own seed
  data), then `pg_restore --data-only --disable-triggers` (loads everything
  else with triggers off — `agents_ensure_policy`, see [Per-agent
  roles](security.md#per-agent-roles), would otherwise create a default policy row for
  each restored agent that collides with that agent's real one arriving
  right behind it in the same dump). A single-pass `pg_restore dump.file`
  will fail on that collision; `--disable-triggers` alone does not fix it
  either, since `pg_restore --help` documents that the flag only takes
  effect during a `--data-only` restore.
- One accepted, permanent limitation of the exclusion-filter approach: an
  operator's own edit to a *built-in* provider row (base_url, is_enabled,
  allow_private_network, a stored secret) does not survive a
  `pg_dump`-based restore — only a wholly new provider row would. Physical
  backup has no such gap.

**Schedule and retention.** Neither strategy is scheduled or pruned by
anything in this repo — that part is standard PostgreSQL operations, not
Allgres-specific, so it isn't automated here. A starting point for a
single-operator install, to adjust to your own RPO/RTO rather than treat
as a mandate: continuous WAL archiving plus a daily `pg_basebackup`,
keeping enough of both to restore to any point in the last 7-14 days
(a base backup is only as useful as the WAL segments after it are kept
alongside it), and a daily logical `pg_dump` kept for the same window as a
second, independent copy that doesn't depend on WAL continuity. Whatever
you pick, restore it somewhere non-production on a schedule too — a
backup nobody has restored is a hope, not a plan.

**Restore checklist (logical, the two-pass restore above):**

```bash
pg_dumpall --globals-only -f globals.sql          # 1. roles first
psql -f globals.sql                               #    onto the fresh cluster
pg_restore --schema-only -d <db> backup.dump       # 2. extension + seed data
pg_restore --data-only --disable-triggers -d <db> backup.dump  # 3. everything else
```

Then run `SELECT allgres_public.fn_selftest();` once against the restored
database — it's a live diagnostic safe to run against real data (see
[Tests](testing.md)), and a clean pass is a real signal the restore actually
landed in a working state, not just that the commands returned success.
