# Maintenance and system agents

Part of the [documentation index](../README.md). See also: [Security
model](security.md) for `is_system`/admin gating.

## Maintenance agents

An agent can be a system-facing operator instead of a user-facing one: read
`allgres_public.v_system_health` (worker presence, queue backlogs, pending
approvals, failures in the last 24h, expired-but-unswept memories) and
`allgres_public.v_permission_audit` (every agent's permission grants), form
an opinion, and report it — the same `execute_sql`/`final_answer`/`remember`
actions any other agent has, no special agent "kind" or new action type
needed. Both views are system-wide, not per-agent data, so there is nothing
to row-scope: `agent_may_read` alone decides whether an agent sees them at
all — zero rows without the grant, the full picture with it.

A seeded example, `health_monitor`, ships with both views granted and
nothing else — no `execute_sql` access to any business-data view, no
`delegate`, no functions, and deliberately no `propose_change` in its prompt
either: this first slice is read-and-report only, more conservative than a
maintenance agent strictly needs to be, on purpose. It compares against
what it `remember`ed on its last run (already sitting in its own context,
the same recall every other agent gets) and gives a short human-readable
summary as its `final_answer` — visible in the Sessions thread view like
any other run.

There is no scheduler: nothing runs `health_monitor` automatically. An
operator triggers it from the Run page, or an external `cron` job hits
`POST /api/v1/run` the same way any other automation would. Deliberately
not built: an internal recurring-task primitive (a `pg_cron` dependency or
a new scheduling loop in the runtime worker); a way for a maintenance agent
to *act* on what it finds — even `propose_change` isn't wired into its
seeded prompt, so a real finding still requires an operator to read the
session and decide, the same review-before-apply shape self-modification
already uses; and any auditor beyond the two views above (a memory curator,
a performance advisor) — the review that proposed this pattern named
several; this ships the two with the clearest, most immediately useful
read surface already in place.

## System agents

Beyond the two demo/maintenance agents above, four built-in agents operate
the platform itself, seeded under one shared parent (`system_root`) so a
grant or a framing sentence added to the root reaches all four without
being restated per agent: `session_compactor` (summarizes a session's
older turns once its log passes a threshold — `allgres_private.
maybe_trigger_compaction`, called on every `fn_next_step`), `creator`,
`fixer`, and `self_improve`. `agent_id`/`name`/`system_prompt` inheritance
is real — `allgres_private.agent_has_permission`/`agent_effective_prompt`
walk `parent_agent_id` so a child sees its own grants plus everything the
root was granted, and its own prompt appended after the root's shared
framing. Every one of the four is `is_system = true`: editing its policy or
permissions from the Agents page always requires an admin session
(`require_admin_for_system_agent`), unconditionally. An ordinary,
non-system agent used to be unaffected by this specific check — but see
[Security model](security.md): once any account has ever been
created, the platform-configuration surface as a whole (agent creation
and edits, providers, the allowlist, OAuth connect) requires an admin
session too, system agent or not.

(A fifth system agent, `orchestrator`, used to record an advisory-only
opinion on response order whenever a Messenger post `@mentions` more than
one agent — delivery itself was always text order regardless, so this
never actually reordered or gated anything. Removed in the v2 redesign;
see KNOWN_ISSUES.md.)

Any behavior constant a specific agent kind needs — `session_compactor`'s
trigger threshold and how many recent logs it leaves uncompacted — lives
in a generic `agent_config jsonb` column on every agent rather than
being compiled in, so a future parameter never needs a schema migration.
`fn_set_agent_config` merges into it (a key sent as `null` clears back to
the coded default), through the same admin gate as every other
system-agent field. The Agents page's edit modal exposes each known key
as a labeled number field for the agent it belongs to, plus a raw-JSON
`agent_config` textarea on every agent as the fallback for anything not
given a named field yet (see KNOWN_ISSUES item 34).

`creator`, `fixer`, and `self_improve` can each take one real,
consequential action, gated by a per-agent `autonomy_level` an admin sets
from the Agents page (`agents.set_autonomy`): `admin_approval` (default)
queues it for a human to accept or reject; `auto`/`self_approve` apply it
immediately.

- **creator** proposes a brand-new agent (`create_agent`); approval calls
  the same `fn_create_agent` the Agents page itself uses.
- **fixer** reads the same two read-only views `health_monitor` does
  (`v_system_health`, `v_permission_audit`) and, instead of only
  reporting, proposes a concrete remediation (`propose_fix`: revoke a
  permission, or deactivate an agent) into a new Fixes queue.
- **self_improve** is the one agent allowed to `propose_change` against an
  *other* agent's policy (every other agent's `propose_change` stays
  self-only) — aimed at cost/efficiency, not behavior. See
  [Evaluation-gated self-improvement](self-improvement.md) for how a change
  it proposes gets measured after the fact.

Approvals, Proposals, and the new Fixes queue are no longer admin-only
inboxes: a regular user sees and may decide the ones whose target is one
of their own assigned agents (`allgres_private.visible_agent_ids`); an
admin still sees everything. Both inboxes also filter out
`fn_selftest`'s own fixtures, the same as Sessions/Tasks already did.

An admin can also grant/revoke a user's access to one agent directly from
the Agents page's own edit modal (`assignments.toggle`/`.for_agent`), not
only from Settings' Users section — the reverse direction of the same
`user_agent_assignments` table, one pair at a time rather than replacing a
user's whole list.
