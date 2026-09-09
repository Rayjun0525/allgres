-- Allgres 0.1.0 control plane.
--
-- Internal state lives in the allgres_private/allgres_public schemas and the
-- allgres_owner role; user-facing native functions are exposed under schema
-- allgres. Earlier development used the project's original name, Argo, for
-- these three identifiers (argo_private/argo_public/argo_owner) -- fully
-- retired now, project-wide. An install from before the rename (0.2.0 or
-- earlier; see sql/allgres--0.2.0.sql, kept frozen with the old names as a
-- true historical snapshot) is migrated in place the first time this file
-- runs against it -- see the ALTER ROLE/SCHEMA ... RENAME block in "1.
-- Roles" below -- not recreated under the new names with the old ones left
-- behind holding orphaned data.
--
-- This file is the single canonical definition of the control plane.  Every
-- object is defined exactly once, in dependency order; there are no superseded
-- copies left behind by earlier migrations.  The file is idempotent, so it can
-- be replayed as an `ALTER EXTENSION ... UPDATE` script (see scripts/gen-upgrade.sh).
--
-- Layout:
--   1. roles
--   2. schemas, tables, indexes, triggers
--   3. generic helpers
--   4. outbound URL / host guards      (shared by the LLM and tool paths)
--   5. provider secret storage
--   6. SQL sandbox                     (fn_validate_sql, fn_run_sandboxed_sql, and the parser)
--   7. agent state machine             (fn_next_step / fn_submit_result)
--   8. pump                            (dispatch / claim / complete / watchdog)
--   9. operator API
--  10. seed data
--  10b. extension configuration tables (pg_dump data inclusion)
--  11. selftest
--  12. grants
--  13. allgres facade + dashboard RPC

-- ---------------------------------------------------------------------------
-- 1. Roles.  Invariant 7: three runtime roles.  allgres_owner is deploy-only.
-- ---------------------------------------------------------------------------

-- Rename-in-place, not recreate-and-abandon: an install from before Argo was
-- fully retired (0.2.0 or earlier -- see sql/allgres--0.2.0.sql, frozen with
-- the old names) has real data sitting under argo_owner/argo_private/
-- argo_public. ALTER ROLE/SCHEMA ... RENAME keeps every object and every
-- row exactly where it is, just under the new name; recreating
-- allgres_owner/allgres_private/allgres_public fresh and leaving the old
-- ones behind would silently orphan that data, the same way a logical
-- backup silently dropped it all before pg_extension_config_dump was
-- registered (see KNOWN_ISSUES.md, "the backup/PITR drill"). This has to
-- run before the CREATE ROLE/CREATE SCHEMA IF NOT EXISTS block right below
-- it -- otherwise that block, finding no allgres_owner yet, creates an
-- empty one before this rename ever gets a chance to run, and the rename's
-- own "must not already exist" guard then blocks it, orphaning the old
-- role/schema instead of renaming it. A fresh install has neither old
-- name, so every guard here is a no-op.
--
-- Three safety properties an external review (correctly) pointed out the
-- first version of this block lacked; the first two were fixed in the
-- previous round, the third fixed here:
--   - fail loud, not silent, on an ambiguous state (old and new both
--     present) -- proceeding either would either error confusingly deep
--     into the rest of this file or silently leave data stranded under
--     the old name;
--   - "a schema literally named argo_private/argo_public exists" is not by
--     itself proof it is *this* extension's schema -- "Argo" is not an
--     exotic enough name to rule out an unrelated coincidence on the same
--     cluster. The previous round's answer was to also check for one
--     object only Allgres would have put there (argo_private.agents,
--     argo_public.fn_selftest) -- better than nothing, but a second review
--     round pointed out it is still just a name-shaped guess: an unrelated
--     schema that happens to be named argo_private and happens to have an
--     "agents" table would still pass;
--   - the actually reliable signal was sitting in pg_depend the whole
--     time: CREATE EXTENSION (and ALTER EXTENSION UPDATE, which keeps the
--     same pg_extension row across a version bump) automatically records
--     every object it creates as a member of that extension as it creates
--     it. A schema this file itself created, in any prior version, is
--     therefore *always* a pg_depend member of the 'allgres' extension
--     specifically -- something no coincidentally-named unrelated schema
--     could ever be, regardless of what tables happen to live in it. That
--     is now the primary check; the object-existence check from the
--     previous round stays as a secondary sanity assertion (a genuine but
--     somehow-corrupted old install should still fail loud with a clearer
--     message than a bare "not an extension member" would give).
--   argo_owner has no object of its own to check this way (ownership was
--   never actually transferred to it in any 0.2.0-era install either --
--   see the ownership-transfer block later in this file, itself new; and
--   roles are cluster-global, not owned by any one database's extension,
--   so pg_depend extension-membership does not apply to it the way it
--   does to a schema); its only real link to Allgres is having been
--   created alongside the two schemas, so it is only renamed once at
--   least one of them was independently confirmed genuine.
DO $$
DECLARE
  v_had_argo_private boolean := false;
  v_had_argo_public boolean := false;
BEGIN
  IF EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = 'argo_private') THEN
    IF NOT EXISTS (
      SELECT 1 FROM pg_depend d
      JOIN pg_extension e ON e.oid = d.refobjid AND e.extname = 'allgres'
      WHERE d.classid = 'pg_namespace'::regclass
        AND d.objid = (SELECT oid FROM pg_namespace WHERE nspname = 'argo_private')
        AND d.deptype = 'e'
    ) THEN
      RAISE EXCEPTION 'schema "argo_private" exists but is not a member of the "allgres" extension (a genuine prior Allgres install would be, per pg_depend) -- this does not look like an Allgres install; refusing to rename it automatically. Resolve the name collision manually before installing/upgrading Allgres.' USING ERRCODE = 'P0001';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_tables WHERE schemaname = 'argo_private' AND tablename = 'agents') THEN
      RAISE EXCEPTION 'schema "argo_private" is an "allgres" extension member but has no "agents" table -- this looks like a corrupted or partial Allgres install; refusing to rename it automatically. Resolve manually before installing/upgrading Allgres.' USING ERRCODE = 'P0001';
    END IF;
    IF EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = 'allgres_private') THEN
      RAISE EXCEPTION 'both "argo_private" and "allgres_private" already exist -- ambiguous, refusing to guess which is current. Resolve manually before installing/upgrading Allgres.' USING ERRCODE = 'P0001';
    END IF;
    ALTER SCHEMA argo_private RENAME TO allgres_private;
    v_had_argo_private := true;
  END IF;

  IF EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = 'argo_public') THEN
    IF NOT EXISTS (
      SELECT 1 FROM pg_depend d
      JOIN pg_extension e ON e.oid = d.refobjid AND e.extname = 'allgres'
      WHERE d.classid = 'pg_namespace'::regclass
        AND d.objid = (SELECT oid FROM pg_namespace WHERE nspname = 'argo_public')
        AND d.deptype = 'e'
    ) THEN
      RAISE EXCEPTION 'schema "argo_public" exists but is not a member of the "allgres" extension (a genuine prior Allgres install would be, per pg_depend) -- this does not look like an Allgres install; refusing to rename it automatically. Resolve the name collision manually before installing/upgrading Allgres.' USING ERRCODE = 'P0001';
    END IF;
    IF NOT EXISTS (
      SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
      WHERE n.nspname = 'argo_public' AND p.proname = 'fn_selftest'
    ) THEN
      RAISE EXCEPTION 'schema "argo_public" is an "allgres" extension member but has no "fn_selftest" function -- this looks like a corrupted or partial Allgres install; refusing to rename it automatically. Resolve manually before installing/upgrading Allgres.' USING ERRCODE = 'P0001';
    END IF;
    IF EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = 'allgres_public') THEN
      RAISE EXCEPTION 'both "argo_public" and "allgres_public" already exist -- ambiguous, refusing to guess which is current. Resolve manually before installing/upgrading Allgres.' USING ERRCODE = 'P0001';
    END IF;
    ALTER SCHEMA argo_public RENAME TO allgres_public;
    v_had_argo_public := true;
  END IF;

  IF (v_had_argo_private OR v_had_argo_public) AND EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'argo_owner') THEN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'allgres_owner') THEN
      RAISE EXCEPTION 'both "argo_owner" and "allgres_owner" already exist -- ambiguous, refusing to guess which is current. Resolve manually before installing/upgrading Allgres.' USING ERRCODE = 'P0001';
    END IF;
    ALTER ROLE argo_owner RENAME TO allgres_owner;
  END IF;
END
$$;

-- allgres_owner is a pure object-owner role -- NOLOGIN (nobody connects as
-- it directly; the installer connects as a superuser or an equivalent
-- deploy identity, and everything this file creates ends up owned by
-- allgres_owner via the ownership-transfer block in "12. Grants") and
-- NOINHERIT (it grants nothing to anyone by virtue of membership; every
-- grant below is explicit). allgres_role_admin is deliberately a *separate*
-- role, not folded into allgres_owner, and owns exactly one function
-- (fn_provision_agent_role, the only thing in this file that runs a
-- dynamic CREATE ROLE): giving allgres_owner CREATEROLE so that one
-- function could dynamically provision agent roles would hand every other
-- SECURITY DEFINER function in this file that same power too, since they
-- would all share the same owner -- a bug or an unreviewed future change
-- in any one of them would have it. Scoping CREATEROLE to the one role
-- that owns exactly the one function that needs it keeps that blast radius
-- to that one function.
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'allgres_owner') THEN
    CREATE ROLE allgres_owner NOLOGIN NOINHERIT;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'allgres_role_admin') THEN
    CREATE ROLE allgres_role_admin NOLOGIN NOINHERIT CREATEROLE;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'operator') THEN
    CREATE ROLE operator LOGIN;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'worker') THEN
    CREATE ROLE worker LOGIN;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'sandbox') THEN
    CREATE ROLE sandbox NOLOGIN;
  END IF;
END
$$;

-- ALTER ROLE ... RENAME (above) changes only the name, never the role's
-- other attributes -- a renamed argo_owner (LOGIN, from every 0.2.0-era
-- install) stays LOGIN after becoming allgres_owner, and the CREATE ROLE
-- IF NOT EXISTS block just above never touches it either, since by then it
-- already exists under the new name. Normalizing both roles' attributes
-- unconditionally, every replay, is what actually makes them NOLOGIN
-- (nobody connects as either directly, see the comment above) regardless
-- of whether this run created them fresh or found them renamed; confirmed
-- live that a real 0.2.0-upgraded allgres_owner stayed LOGIN without this.
ALTER ROLE allgres_owner NOLOGIN NOINHERIT;
ALTER ROLE allgres_role_admin NOLOGIN NOINHERIT CREATEROLE;

-- The sandbox never resolves an unqualified relation name: the runtime worker
-- narrows search_path to pg_temp before running model-generated SQL, and this
-- default keeps that true for any other session that assumes the role.
ALTER ROLE sandbox  SET search_path = pg_temp;
ALTER ROLE worker   SET search_path = allgres_public, pg_temp;
ALTER ROLE operator SET search_path = allgres_private, allgres_public, pg_temp;

-- The runtime worker drops to `worker` per transaction, then drops further to
-- `sandbox` to run agent SQL (fn_run_sandboxed_sql); that second hop needs
-- role membership.
GRANT sandbox TO worker;

-- ---------------------------------------------------------------------------
-- Drop objects whose signature or return type changed since 0.1.0.
-- CREATE OR REPLACE cannot do either, so upgrades need an explicit drop.
-- ---------------------------------------------------------------------------

DROP FUNCTION IF EXISTS allgres_public.fn_set_provider(uuid, text, boolean, text, text, text, text);
DROP FUNCTION IF EXISTS allgres.create_session(uuid, text);

-- fn_execute_sql validated *and* ran agent SQL as its own (SECURITY DEFINER)
-- owner, which is what made SET ROLE sandbox illegal in the first place (see
-- "6. SQL sandbox" below).  It is replaced by fn_validate_sql (validation
-- only, returns text) plus fn_run_sandboxed_sql (execution, run by the
-- runtime worker as the sandbox role) -- a name and a return-type change, so
-- CREATE OR REPLACE cannot land it.
DROP FUNCTION IF EXISTS allgres_private.fn_execute_sql(uuid, text);

-- fn_create_session gains an optional project_id; fn_decide_approval gains an
-- optional human reply.  CREATE OR REPLACE cannot append a new parameter to
-- an existing signature -- it creates a second overload instead of replacing
-- (verified: PostgreSQL treats a longer parameter list as a distinct
-- function, which then makes the shorter call ambiguous) -- so both need an
-- explicit drop first.
DROP FUNCTION IF EXISTS allgres_public.fn_create_session(uuid, text);
DROP FUNCTION IF EXISTS allgres_public.fn_decide_approval(uuid, boolean);
DROP FUNCTION IF EXISTS allgres_public.fn_set_policy(uuid, text, int, int, jsonb);
-- fn_set_policy gains max_delegation_depth/max_session_tasks (see "1.
-- Roles" -- no, "2. Schemas" -- the policies table comment near
-- max_concurrent_tasks/max_turn_seconds) -- same signature-growth rule as
-- above: the 0.2.0-era 8-arg version needs its own explicit drop, not just
-- the 5-arg one three lines up, or an upgrade leaves both overloads
-- installed side by side.
DROP FUNCTION IF EXISTS allgres_public.fn_set_policy(uuid, text, int, int, jsonb, int, int, boolean);

-- fn_create_project gains optional agent_id/preset_prompt (item 42, Chat's
-- Project mode) -- same signature-growth rule as above: without this drop,
-- an upgrade leaves the 0.2.0-era 2-arg overload installed side by side,
-- and any single-argument call (fn_selftest's own project fixture, the
-- Run page's "no description" case) becomes ambiguous between the two.
DROP FUNCTION IF EXISTS allgres_public.fn_create_project(text, text);

-- The SQL sandbox no longer inspects statement text with regexes; it reads the
-- tree produced by PostgreSQL's own parser (allgres.analyze_sql).  These are
-- the hand-rolled lexer that replaced.
DROP FUNCTION IF EXISTS allgres_private.sql_table_refs(text);
DROP FUNCTION IF EXISTS allgres_private.sql_relation_refs(text);
DROP FUNCTION IF EXISTS allgres_private.sql_cte_names(text);
DROP FUNCTION IF EXISTS allgres_private.sql_normalize(text);
DROP FUNCTION IF EXISTS allgres_private.strip_sql_noise(text);

-- The provider API key used to be decrypted and baked into the Authorization/
-- x-api-key header inside build_llm_http, which fn_dispatch_tasks then wrote
-- straight into outbound_calls.request_headers -- a real table row, so the
-- plaintext key sat there for the row's whole life, in WAL, in any physical
-- backup or PITR archive, on any replica, and readable by a plain SELECT.
-- Credential resolution moves to fn_claim_outbound, at claim time, injected
-- only into the response handed to the worker over the RPC socket -- never
-- written back to a table. build_llm_http drops p_fallback_key (it no longer
-- touches a key at all); fn_dispatch_tasks drops it for the same reason;
-- fn_claim_outbound gains it, since resolving the fallback key is now its
-- job. All three signatures changed, so all three need an explicit drop.
DROP FUNCTION IF EXISTS allgres_private.build_llm_http(jsonb, text);
DROP FUNCTION IF EXISTS allgres_public.fn_dispatch_tasks(text);
DROP FUNCTION IF EXISTS allgres_public.fn_claim_outbound(int);

-- agent_may_read now takes the agent_id as a parameter instead of resolving
-- it itself -- see its own comment for why (current_user is not what it
-- looks like from inside a SECURITY DEFINER function's own body).
DROP FUNCTION IF EXISTS allgres_private.agent_may_read(text);

-- OAuth token exchange used to be built and handed straight back to its
-- caller (fn_oauth_token_request), with a separate fn_oauth_store_tokens an
-- operator called afterward with whatever access/refresh token their own
-- browser-side code obtained -- which is exactly how a decrypted client
-- secret reached `operator` in the first place (see KNOWN_ISSUES, "a
-- second-round external review of items 18 and 19"). Both functions are
-- replaced by a queued exchange the runtime worker performs itself
-- (fn_claim_oauth/fn_complete_oauth, see "9. Operator API"): fn_oauth_token_request
-- keeps its name and signature but now only queues, and fn_oauth_store_tokens
-- has no replacement at all -- its storage logic moved inside
-- fn_complete_oauth, and nothing outside the worker needs to call it anymore.
DROP FUNCTION IF EXISTS allgres_public.fn_oauth_store_tokens(text, text, text, int);

-- ---------------------------------------------------------------------------
-- 2. Schemas, tables, indexes, triggers.
-- ---------------------------------------------------------------------------

CREATE SCHEMA IF NOT EXISTS allgres_private;
CREATE SCHEMA IF NOT EXISTS allgres_public;

CREATE TABLE IF NOT EXISTS allgres_private.agents (
  agent_id    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name        text NOT NULL UNIQUE,
  is_active   boolean NOT NULL DEFAULT true,
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now()
);

-- NULL until fn_provision_agent_role runs (fn_create_agent does this for
-- every new agent; an agent that existed before this column was added stays
-- NULL, and its sandboxed SQL falls back to the shared `sandbox` role, the
-- same as before -- opt-in, not a breaking migration). Once set, this is the
-- agent's actual PostgreSQL security identity for sandboxed execution: a
-- NOLOGIN role, a member of `sandbox` (so it inherits exactly the grants
-- `sandbox` already has, nothing duplicated per agent), that
-- fn_run_sandboxed_sql runs as via `SET LOCAL ROLE` instead of the one
-- shared `sandbox` role every agent used to run as indistinguishably. See
-- fn_provision_agent_role and "6. SQL sandbox" below.
ALTER TABLE allgres_private.agents
  ADD COLUMN IF NOT EXISTS pg_role text UNIQUE;

-- System agents (item 32, "system agent hierarchy"): a small, fixed set of
-- built-in agents that operate the platform itself rather than a user's
-- workload -- session compaction, cross-agent orchestration in Messenger,
-- helping create new agents/skills/tools, proposing fixes for what
-- health_monitor finds, and tuning other agents for lower token/time cost.
-- is_system marks a row as one of these: dashboard_rpc's agents.update/
-- agents.create/policy.rollback/permissions.* branches require an admin
-- session (require_admin) whenever the target is_system, where a regular
-- user's own agents (created for them, or by them if ever allowed) need no
-- such check today -- see the require_admin call added to those branches
-- below. parent_agent_id is the inheritance edge: fn_effective_permissions
-- and fn_effective_prompt (below) walk it to fold every ancestor's grants
-- and system_prompt preamble into a child's own, so editing the one root
-- system agent's permissions changes what every system agent may do without
-- editing five rows by hand. A non-system agent's parent_agent_id is always
-- NULL -- inheritance is a system-agent-only concept, not a general agent
-- feature.
ALTER TABLE allgres_private.agents
  ADD COLUMN IF NOT EXISTS is_system boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS parent_agent_id uuid REFERENCES allgres_private.agents(agent_id);

CREATE INDEX IF NOT EXISTS agents_parent_idx ON allgres_private.agents (parent_agent_id)
  WHERE parent_agent_id IS NOT NULL;

-- autonomy_level: how much a system agent's own consequential actions
-- (create_agent/create_skill/create_tool for `creator`, a remediation for
-- `fixer`, a cross-agent propose_change for `self_improve`) may run without
-- a human in the loop, set per-agent by an admin from the Agents page --
-- not hardcoded per agent kind, so an operator can loosen or tighten any one
-- of them independently as trust in it grows or drops.
--   'admin_approval' (default, most cautious): every such action is queued
--     for an admin to accept or reject before it takes effect -- the
--     existing change_proposals/human_approvals inbox, unchanged.
--   'self_approve': the action takes effect immediately, but the agent may
--     still choose await_human/propose_change itself when its own
--     confidence is low or the change looks unusually large -- an escalation
--     the agent decides to make, not one the platform forces on every call.
--   'auto': always takes effect immediately, no escalation path used.
-- Meaningless for an ordinary (non-system) agent today -- nothing reads it
-- for anything but the three system-agent action kinds above -- so it is a
-- plain column with a safe default rather than a system-agent-only table,
-- to keep this simple and leave room for a future agent kind to use it too.
ALTER TABLE allgres_private.agents
  ADD COLUMN IF NOT EXISTS autonomy_level text NOT NULL DEFAULT 'admin_approval'
    CHECK (autonomy_level IN ('auto', 'self_approve', 'admin_approval'));

-- Generic per-agent settings that are neither "operational policy"
-- (system_prompt/llm_config/max_steps and friends, on allgres_private.
-- policies, versioned with policy_history/generation) nor a general agent
-- feature (autonomy_level, permissions) -- a specific system agent's own
-- tunable behavior instead: session_compactor's compaction_threshold/
-- compaction_keep_recent, orchestrator's min_mentions_to_route (see
-- fn_set_agent_config and each reader's own comment). Unversioned and
-- unstructured on purpose -- unlike a policy edit, changing one of these
-- is not a decision anyone needs an approval trail or a rollback for, and
-- a plain jsonb bag means a new tunable never needs a new migration: the
-- reader that cares about a key applies its own default when the key is
-- absent, the same COALESCE-a-default shape this file already uses
-- throughout. Meaningless for an ordinary agent today (nothing reads it
-- for anything but the two system-agent kinds above), the same "a plain
-- column with a safe default, not a system-agent-only table" reasoning
-- autonomy_level's own comment gives.
ALTER TABLE allgres_private.agents
  ADD COLUMN IF NOT EXISTS agent_config jsonb NOT NULL DEFAULT '{}'::jsonb;

-- Semantic identity for delegation discovery (fn_search_agents): a vector
-- embedding of this agent's own name + system_prompt, so another agent can
-- find it by describing a task instead of already knowing its exact name.
-- See the llm_providers.purpose comment above for why this is a plain
-- double precision[], not pgvector's `vector` type. embedding_model records
-- "<provider name>:<model>" at the time it was generated so a later switch
-- of the configured embedding provider/model can be detected as staleness
-- (the dashboard's job, not this column's) rather than silently mixing
-- embeddings from two different models in one ranking -- fn_search_agents
-- already refuses to compare mismatched dimensions (cosine_similarity
-- returns NULL for those), but two different 1536-dimension models are not
-- comparable either even though nothing about their shape would catch it.
ALTER TABLE allgres_private.agents
  ADD COLUMN IF NOT EXISTS embedding double precision[],
  ADD COLUMN IF NOT EXISTS embedding_model text,
  ADD COLUMN IF NOT EXISTS embedding_updated_at timestamptz;

CREATE TABLE IF NOT EXISTS allgres_private.policies (
  agent_id        uuid PRIMARY KEY REFERENCES allgres_private.agents(agent_id) ON DELETE CASCADE,
  system_prompt   text NOT NULL,
  max_steps       int NOT NULL DEFAULT 20 CHECK (max_steps > 0),
  max_retries     int NOT NULL DEFAULT 2 CHECK (max_retries >= 0),
  llm_config      jsonb NOT NULL DEFAULT '{}'::jsonb,
  updated_at      timestamptz NOT NULL DEFAULT now()
);

-- generation + max_concurrent_tasks/max_turn_seconds: a real version count
-- (fn_set_policy snapshots the pre-change row into policy_history and bumps
-- this, but only when something actually changed -- a no-op update, e.g.
-- agents.update only flipping is_active, must not create a phantom version),
-- and two caps max_steps/max_retries didn't cover: max_steps bounds a
-- runaway *loop* (how many turns), not how many tasks this agent runs at
-- once (max_concurrent_tasks, enforced in fn_dispatch_tasks) or how long one
-- task may run start to finish regardless of step count (max_turn_seconds, a
-- wall-clock ceiling from the task's created_at, enforced in fn_watchdog;
-- NULL means uncapped).
ALTER TABLE allgres_private.policies
  ADD COLUMN IF NOT EXISTS generation int NOT NULL DEFAULT 1,
  ADD COLUMN IF NOT EXISTS max_concurrent_tasks int NOT NULL DEFAULT 4 CHECK (max_concurrent_tasks > 0),
  ADD COLUMN IF NOT EXISTS max_turn_seconds int CHECK (max_turn_seconds IS NULL OR max_turn_seconds > 0);

-- max_delegation_depth/max_session_tasks: delegate (see fn_submit_result) had no
-- resource bound of its own at all before this -- an external review pointed
-- out that with mutual delegate permissions granted (A may delegate to B, B
-- to A), nothing stopped an unbounded A -> B -> A -> B -> ... chain, since
-- each child task gets its own fresh max_steps/max_retries/max_turn_seconds
-- budget under max_concurrent_tasks alone. Two independent bounds, not one:
-- max_delegation_depth caps how many delegate hops deep one chain may go
-- (checked against tasks.delegation_depth, below), which alone does not
-- catch a long non-repeating chain (A -> B -> C -> D -> ...) that never
-- revisits an agent -- max_session_tasks caps the total number of tasks one
-- session may ever spawn, regardless of shape. Both operator-configurable,
-- same envelope-field pattern as max_concurrent_tasks/max_turn_seconds: an
-- agent's own propose_change can never touch either (see fn_submit_result).
ALTER TABLE allgres_private.policies
  ADD COLUMN IF NOT EXISTS max_delegation_depth int NOT NULL DEFAULT 5 CHECK (max_delegation_depth >= 0),
  ADD COLUMN IF NOT EXISTS max_session_tasks int NOT NULL DEFAULT 100 CHECK (max_session_tasks > 0);

-- Append-only: one row per version that was ever live, populated by
-- fn_set_policy just before it overwrites allgres_private.policies.  There is no
-- row for the current version -- that's what allgres_private.policies itself is.
CREATE TABLE IF NOT EXISTS allgres_private.policy_history (
  version_id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  agent_id             uuid NOT NULL REFERENCES allgres_private.agents(agent_id) ON DELETE CASCADE,
  generation           int NOT NULL,
  system_prompt        text NOT NULL,
  max_steps            int NOT NULL,
  max_retries          int NOT NULL,
  llm_config           jsonb NOT NULL,
  max_concurrent_tasks int NOT NULL,
  max_turn_seconds     int,
  changed_at           timestamptz NOT NULL DEFAULT now(),
  UNIQUE (agent_id, generation)
);

ALTER TABLE allgres_private.policy_history
  ADD COLUMN IF NOT EXISTS max_delegation_depth int NOT NULL DEFAULT 5,
  ADD COLUMN IF NOT EXISTS max_session_tasks int NOT NULL DEFAULT 100;

-- Roadmap item 7: evaluation-gated self-improvement. Every archived version
-- is stamped with how the agent was actually doing under exactly that
-- version (see allgres_private.agent_success_rate_for_generation) right
-- before it was replaced -- populated by fn_set_policy at the exact
-- moment a version is overwritten, alongside the row's other now-historical
-- fields. NULL means no evaluable data existed yet (a brand-new agent's
-- very first change), not zero -- never treated as "0% success" by
-- fn_evaluate_last_change below. This is what turns "self_improve proposed
-- a change" into something a later turn (or an operator) can actually
-- check the outcome of, instead of trusting a proposal was good on its own
-- say-so.
ALTER TABLE allgres_private.policy_history
  ADD COLUMN IF NOT EXISTS success_rate_at_change numeric;

CREATE INDEX IF NOT EXISTS policy_history_agent_idx
  ON allgres_private.policy_history (agent_id, generation DESC);

CREATE TABLE IF NOT EXISTS allgres_private.permissions (
  permission_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  agent_id      uuid NOT NULL REFERENCES allgres_private.agents(agent_id) ON DELETE CASCADE,
  resource_type text NOT NULL CHECK (resource_type IN ('view', 'tool', 'agent', 'http_host')),
  resource_ref  text NOT NULL,
  granted_at    timestamptz NOT NULL DEFAULT now(),
  UNIQUE (agent_id, resource_type, resource_ref)
);

-- 'procedure' (roadmap item 4, see allgres_private.procedures below): an
-- existing install's CREATE TABLE IF NOT EXISTS above never re-runs once
-- the table exists, so its original CHECK has to be widened here instead --
-- same upgrade shape outbound_calls_kind_check already used for 'embedding'.
ALTER TABLE allgres_private.permissions DROP CONSTRAINT IF EXISTS permissions_resource_type_check;
ALTER TABLE allgres_private.permissions ADD CONSTRAINT permissions_resource_type_check
  CHECK (resource_type IN ('view', 'tool', 'agent', 'http_host', 'procedure'));

-- Roadmap item 4: a named, versioned, reusable procedure an operator (or,
-- in a later slice, an approved agent proposal) curates once and any
-- granted agent can draw on every turn -- distinct from agent_memories,
-- which is private to one agent, unversioned (overwritten by eviction, not
-- history), and never explicitly shared. content is free text: whatever
-- shape of "how to do X" the operator finds useful (a checklist, a SQL
-- template, a delegation plan) -- nothing here parses or executes it.
-- generation/is_active live on the row itself, snapshotted into
-- procedure_history only on an actual content change -- the exact same
-- shape allgres_private.policies/policy_history already uses for an
-- agent's own policy (see fn_set_policy's own comment on why: "only ever a
-- new version that happens to match an old one," never a rewrite of what
-- was already recorded).
CREATE TABLE IF NOT EXISTS allgres_private.procedures (
  procedure_id  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name          text NOT NULL UNIQUE,
  content       text NOT NULL,
  generation    int NOT NULL DEFAULT 1,
  is_active     boolean NOT NULL DEFAULT true,
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS allgres_private.procedure_history (
  version_id    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  procedure_id  uuid NOT NULL REFERENCES allgres_private.procedures(procedure_id) ON DELETE CASCADE,
  generation    int NOT NULL,
  content       text NOT NULL,
  changed_at    timestamptz NOT NULL DEFAULT now(),
  UNIQUE (procedure_id, generation)
);
CREATE INDEX IF NOT EXISTS procedure_history_procedure_idx
  ON allgres_private.procedure_history (procedure_id, generation DESC);

-- Every permission check in this file (call_tool's tool/http_host grants,
-- delegate's target-agent grant, execute_sql's view grant via
-- agent_may_read/fn_validate_sql below) goes through this one function
-- rather than querying allgres_private.permissions directly, so a system
-- agent's inheritance (item 32/33: "borrow the parent's permissions,
-- don't restate them") only has to be taught once. For an ordinary agent
-- (parent_agent_id NULL) the recursive term never fires and this is
-- exactly the direct-grant EXISTS check it replaces -- no behavior change
-- for anything that isn't a system agent. Comparison is case-insensitive
-- on both sides for every resource_type, matching the one caller
-- (call_tool's http_host check) that already normalized this way; view/
-- tool/agent refs are stored consistently-cased already, so this is a
-- no-op widening for them, not a new match.
CREATE OR REPLACE FUNCTION allgres_private.agent_has_permission(
  p_agent_id uuid, p_resource_type text, p_resource_ref text
) RETURNS boolean
LANGUAGE sql
STABLE
AS $fn$
  WITH RECURSIVE chain AS (
    SELECT agent_id, parent_agent_id FROM allgres_private.agents WHERE agent_id = p_agent_id
    UNION ALL
    SELECT a.agent_id, a.parent_agent_id
    FROM allgres_private.agents a
    JOIN chain c ON a.agent_id = c.parent_agent_id
  )
  SELECT EXISTS (
    SELECT 1
    FROM allgres_private.permissions p
    JOIN chain c ON c.agent_id = p.agent_id
    WHERE p.resource_type = p_resource_type
      AND lower(p.resource_ref) = lower(p_resource_ref)
  )
$fn$;

-- The listing form of agent_has_permission: every resource_ref of one
-- resource_type an agent may use, own grants and inherited ones merged and
-- de-duplicated -- what fn_next_step shows the LLM as its "bounds" (a
-- system agent's displayed views/tools must match what it can actually
-- call, the same reasoning as agent_has_permission's comment above).
CREATE OR REPLACE FUNCTION allgres_private.agent_permission_refs(
  p_agent_id uuid, p_resource_type text
) RETURNS text[]
LANGUAGE sql
STABLE
AS $fn$
  WITH RECURSIVE chain AS (
    SELECT agent_id, parent_agent_id FROM allgres_private.agents WHERE agent_id = p_agent_id
    UNION ALL
    SELECT a.agent_id, a.parent_agent_id
    FROM allgres_private.agents a
    JOIN chain c ON a.agent_id = c.parent_agent_id
  )
  SELECT COALESCE(array_agg(DISTINCT p.resource_ref ORDER BY p.resource_ref), ARRAY[]::text[])
  FROM allgres_private.permissions p
  JOIN chain c ON c.agent_id = p.agent_id
  WHERE p.resource_type = p_resource_type
$fn$;

-- A system agent's own system_prompt is only its specific instructions
-- ("you compact long sessions"); the shared "you are one of Allgres's own
-- system agents, operate under the autonomy_level set for you" framing
-- lives once on the root and is inherited, the same idea as
-- agent_has_permission above but for prompt text instead of grants.
-- Ordered root-first so the most specific (this agent's own) instructions
-- land last in the text, closest to where the LLM actually acts on them.
-- For a non-system agent (no parent) this returns exactly its own
-- system_prompt, unchanged from before this function existed.
CREATE OR REPLACE FUNCTION allgres_private.agent_effective_prompt(p_agent_id uuid)
RETURNS text
LANGUAGE sql
STABLE
AS $fn$
  WITH RECURSIVE chain AS (
    SELECT a.agent_id, a.parent_agent_id, 0 AS depth
    FROM allgres_private.agents a WHERE a.agent_id = p_agent_id
    UNION ALL
    SELECT a.agent_id, a.parent_agent_id, c.depth + 1
    FROM allgres_private.agents a
    JOIN chain c ON a.agent_id = c.parent_agent_id
  )
  SELECT string_agg(p.system_prompt, E'\n\n---\n\n' ORDER BY c.depth DESC)
  FROM chain c
  JOIN allgres_private.policies p ON p.agent_id = c.agent_id
$fn$;

-- item 39: once a session's own not-yet-summarized root-level log grows
-- past a threshold, queue a one-time background task for session_compactor
-- to fold everything but the most recent handful of turns -- plus the
-- previous summary, if any, so a second compaction never drops what the
-- first one already captured -- into one updated summary. A no-op call in
-- every ordinary case (below threshold, a compaction already in flight, or
-- session_compactor missing/inactive) -- fn_next_step calls this on every
-- root-level step, so it has to be cheap and safe to call repeatedly.
-- Deliberately never sets sessions.compacted_before itself: that only
-- happens once session_compactor's own remember actually lands
-- (fn_submit_result), so a turn can never see neither the raw logs nor a
-- finished summary -- worst case, a session sees a few turns' worth of
-- extra history while its compaction is still in flight. The threshold is
-- measured against logs *after* the current compacted_before (or all of
-- them, the first time) -- counting every row ever written, compacted or
-- not, would stay past threshold forever, since raw logs are append-only
-- and never deleted, and would queue a new compaction on every single step.
-- The threshold (60) and how many recent logs stay uncompacted (10) are
-- both admin-tunable via session_compactor's own agent_config
-- (compaction_threshold/compaction_keep_recent, set through agents.update
-- from the Agents page) -- these numbers are its defaults, applied only
-- when an admin has never touched the setting.
CREATE OR REPLACE FUNCTION allgres_private.maybe_trigger_compaction(p_session_id uuid, p_task_ids uuid[])
RETURNS void
LANGUAGE plpgsql
AS $fn$
DECLARE
  c_threshold int;
  c_keep_recent int;
  v_current_cutoff timestamptz;
  v_count int;
  v_cutoff timestamptz;
  v_compactor uuid;
  v_compactor_active boolean;
  v_compactor_config jsonb;
  v_prev_summary text;
  v_old_logs jsonb;
  v_comp_session uuid;
  v_comp_task uuid;
BEGIN
  -- Read before the threshold check itself, since the threshold is one of
  -- the values being read (item: agent metadata config) -- session_compactor's
  -- own agent_config, not the target session's agent: the compactor is the
  -- one actually doing the compacting, so its settings are what apply,
  -- regardless of which agent owns the session. Defaults (60/10) match
  -- this function's behavior before agent_config existed -- an admin who
  -- never touches these settings sees no change at all.
  SELECT agent_id, is_active, agent_config INTO v_compactor, v_compactor_active, v_compactor_config
  FROM allgres_private.agents WHERE name = 'session_compactor';
  IF v_compactor IS NULL OR NOT v_compactor_active THEN
    RETURN;
  END IF;
  c_threshold := COALESCE((v_compactor_config->>'compaction_threshold')::int, 60);
  c_keep_recent := COALESCE((v_compactor_config->>'compaction_keep_recent')::int, 10);

  SELECT compacted_before INTO v_current_cutoff
  FROM allgres_private.sessions WHERE session_id = p_session_id;

  SELECT count(*) INTO v_count
  FROM allgres_private.execution_logs
  WHERE task_id = ANY(p_task_ids)
    AND (v_current_cutoff IS NULL OR created_at >= v_current_cutoff);
  IF v_count <= c_threshold THEN
    RETURN;
  END IF;

  IF EXISTS (
    SELECT 1 FROM allgres_private.sessions
    WHERE goal = 'session_compact:' || p_session_id::text AND status = 'open'
  ) THEN
    RETURN;
  END IF;

  -- compaction_keep_recent = 0 (a valid, allowed value -- see its own
  -- CHECK range, 0 to 1000000) means "keep nothing, compact everything up
  -- to now" -- there is no "the Nth-newest log" boundary to find when N is
  -- 0, so this can't reuse the OFFSET below at all: `OFFSET c_keep_recent
  -- - 1` with c_keep_recent = 0 sends PostgreSQL a literal OFFSET -1,
  -- which is a hard error ("OFFSET must not be negative"), not a graceful
  -- "keep the newest one anyway" -- confirmed live, this used to abort the
  -- whole compaction check outright the moment an operator set
  -- keep_recent to 0.
  IF c_keep_recent <= 0 THEN
    v_cutoff := clock_timestamp();
  ELSE
    SELECT created_at INTO v_cutoff FROM (
      SELECT created_at FROM allgres_private.execution_logs
      WHERE task_id = ANY(p_task_ids)
        AND (v_current_cutoff IS NULL OR created_at >= v_current_cutoff)
      ORDER BY created_at DESC
      OFFSET c_keep_recent - 1 LIMIT 1
    ) q;
  END IF;
  IF v_cutoff IS NULL THEN
    RETURN;
  END IF;

  IF v_current_cutoff IS NOT NULL THEN
    SELECT am.content INTO v_prev_summary
    FROM allgres_private.agent_memories am
    WHERE am.agent_id = v_compactor AND am.subject_id = p_session_id::text
    ORDER BY am.created_at DESC LIMIT 1;
  END IF;

  SELECT COALESCE(jsonb_agg(jsonb_build_object('role', role, 'content', content) ORDER BY created_at), '[]'::jsonb)
  INTO v_old_logs
  FROM allgres_private.execution_logs
  WHERE task_id = ANY(p_task_ids)
    AND (v_current_cutoff IS NULL OR created_at >= v_current_cutoff)
    AND created_at < v_cutoff;

  v_comp_session := (allgres_public.fn_create_session(
    v_compactor, 'session_compact:' || p_session_id::text
  )->>'session_id')::uuid;
  SELECT task_id INTO v_comp_task FROM allgres_private.tasks WHERE session_id = v_comp_session LIMIT 1;

  UPDATE allgres_private.tasks
  SET input = jsonb_build_object('target_session_id', p_session_id, 'compact_cutoff', v_cutoff)
  WHERE task_id = v_comp_task;

  INSERT INTO allgres_private.execution_logs (task_id, step_number, role, content)
  VALUES (v_comp_task, 1, 'user', jsonb_build_object(
    'target_session_id', p_session_id,
    'previous_summary', v_prev_summary,
    'turns', v_old_logs
  ));
END;
$fn$;

-- item 40: fires a one-shot advisory task for orchestrator whenever a
-- Messenger post @mentions more than one agent -- see fn_messenger_post's
-- own comment for what "advisory" means today (it records an opinion,
-- delivery order is still text order). Kept as its own function, not
-- inlined into fn_messenger_post, the same reasoning as
-- maybe_trigger_compaction: a clearly-named, independently testable unit.
CREATE OR REPLACE FUNCTION allgres_private.queue_orchestrator_opinion(
  p_orchestrator uuid, p_message_id uuid, p_text text, p_agent_ids uuid[]
) RETURNS void
LANGUAGE plpgsql
AS $fn$
DECLARE
  v_sid uuid;
  v_tid uuid;
  v_candidates jsonb;
BEGIN
  SELECT COALESCE(jsonb_agg(jsonb_build_object('name', a.name, 'system_prompt', p.system_prompt)), '[]'::jsonb)
  INTO v_candidates
  FROM allgres_private.agents a
  JOIN allgres_private.policies p USING (agent_id)
  WHERE a.agent_id = ANY(p_agent_ids);

  v_sid := (allgres_public.fn_create_session(
    p_orchestrator, 'messenger_route:' || p_message_id::text
  )->>'session_id')::uuid;
  SELECT task_id INTO v_tid FROM allgres_private.tasks WHERE session_id = v_sid LIMIT 1;

  INSERT INTO allgres_private.execution_logs (task_id, step_number, role, content)
  VALUES (v_tid, 1, 'user', jsonb_build_object('message', p_text, 'candidates', v_candidates));
END;
$fn$;

CREATE TABLE IF NOT EXISTS allgres_private.sql_sandbox_allowlist (
  resource_ref text PRIMARY KEY
);

-- Positive allowlist for functions callable from sandboxed SQL, on top of
-- every other gate fn_validate_sql already applies (pg_catalog only,
-- non-volatile, non-security-definer, not in c_denied_fns). A denylist can
-- only ever name what is already known to be dangerous, and pg_catalog has
-- hundreds of functions: pg_show_all_settings() is STABLE, not VOLATILE, not
-- SECURITY DEFINER, lives in pg_catalog, and is on no reasonable denylist
-- that only thinks to name current_setting/set_config/version/etc by
-- name -- confirmed live, it validated as ordinary safe SQL and would have
-- returned every GUC on the server, allgres.secret_key included, the same
-- class of bug the denylist was added to close. An allowlist fails in the
-- opposite, safe direction: a legitimate function an analyst needs might not
-- be seeded here yet, which is a false rejection, not a leak.
CREATE TABLE IF NOT EXISTS allgres_private.sql_function_allowlist (
  function_name text PRIMARY KEY
);

INSERT INTO allgres_private.sql_function_allowlist (function_name) VALUES
  -- aggregates
  ('count'), ('sum'), ('avg'), ('min'), ('max'),
  ('array_agg'), ('string_agg'), ('jsonb_agg'), ('jsonb_object_agg'),
  ('json_agg'), ('json_object_agg'), ('bool_and'), ('bool_or'), ('every'),
  ('stddev'), ('stddev_pop'), ('stddev_samp'),
  ('variance'), ('var_pop'), ('var_samp'),
  ('percentile_cont'), ('percentile_disc'), ('mode'),
  -- string
  ('length'), ('char_length'), ('character_length'), ('bit_length'), ('octet_length'),
  ('upper'), ('lower'), ('initcap'),
  ('substring'), ('substr'), ('trim'), ('btrim'), ('ltrim'), ('rtrim'),
  ('concat'), ('concat_ws'), ('replace'), ('split_part'), ('strpos'), ('position'),
  ('left'), ('right'), ('lpad'), ('rpad'), ('repeat'), ('reverse'), ('format'),
  ('regexp_replace'), ('regexp_match'), ('regexp_matches'),
  ('regexp_split_to_array'), ('regexp_split_to_table'), ('regexp_count'),
  ('to_char'), ('quote_literal'), ('quote_ident'),
  -- numeric / math
  ('abs'), ('round'), ('ceil'), ('ceiling'), ('floor'), ('trunc'),
  ('power'), ('sqrt'), ('cbrt'), ('exp'), ('ln'), ('log'), ('mod'),
  ('sign'), ('div'), ('gcd'), ('lcm'), ('width_bucket'), ('greatest'), ('least'),
  -- date/time
  ('now'), ('extract'), ('date_part'), ('date_trunc'), ('age'), ('isfinite'),
  ('to_date'), ('to_timestamp'), ('make_date'), ('make_time'),
  ('make_timestamp'), ('make_timestamptz'), ('make_interval'),
  ('justify_days'), ('justify_hours'), ('justify_interval'),
  -- json/jsonb
  ('jsonb_build_object'), ('jsonb_build_array'), ('jsonb_array_elements'),
  ('jsonb_array_elements_text'), ('jsonb_array_length'),
  ('jsonb_extract_path'), ('jsonb_extract_path_text'), ('jsonb_object_keys'),
  ('jsonb_typeof'), ('jsonb_pretty'), ('jsonb_strip_nulls'),
  ('jsonb_each'), ('jsonb_each_text'), ('jsonb_path_query'), ('jsonb_path_exists'),
  ('json_build_object'), ('json_build_array'), ('json_array_elements'),
  ('json_array_elements_text'), ('json_extract_path'), ('json_extract_path_text'),
  ('json_object_keys'), ('json_typeof'),
  ('row_to_json'), ('to_json'), ('to_jsonb'),
  -- set-returning helpers commonly used with a value list
  ('generate_series'), ('unnest'),
  -- null / conditional -- these are grammar keywords in most positions, but
  -- harmless to allow in case the parser ever surfaces one as a plain call
  ('coalesce'), ('nullif'),
  ('pg_typeof')
ON CONFLICT DO NOTHING;

-- Groups sessions the way a Slack workspace groups channels.  Deliberately
-- does not scope agents: an agent is reused across projects (the same way one
-- bot can sit in several channels), so only sessions -- the actual
-- conversation threads -- belong to a project.
CREATE TABLE IF NOT EXISTS allgres_private.projects (
  project_id   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name         text NOT NULL UNIQUE,
  description  text,
  is_active    boolean NOT NULL DEFAULT true,
  created_at   timestamptz NOT NULL DEFAULT now(),
  updated_at   timestamptz NOT NULL DEFAULT now()
);

-- The Chat page's "Project" mode (item 42): a project used to be only a
-- label sessions could optionally carry (still true when agent_id is
-- NULL -- existing projects, and the Run page's own project picker, are
-- unaffected). One bound to an agent is also a chat target in its own
-- right, with preset_prompt appended after that agent's own effective
-- prompt (see fn_next_step) -- a project narrows a general-purpose agent
-- to one particular job/context without touching the agent's own policy.
ALTER TABLE allgres_private.projects
  ADD COLUMN IF NOT EXISTS agent_id uuid REFERENCES allgres_private.agents(agent_id),
  ADD COLUMN IF NOT EXISTS preset_prompt text;

CREATE TABLE IF NOT EXISTS allgres_private.sessions (
  session_id    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  agent_id      uuid NOT NULL REFERENCES allgres_private.agents(agent_id),
  goal          text NOT NULL,
  status        text NOT NULL CHECK (status IN ('open', 'completed', 'failed', 'cancelled')),
  final_answer  text,
  started_at    timestamptz NOT NULL DEFAULT now(),
  completed_at  timestamptz
);

-- Nullable: a one-off session (the dashboard's "Run" page, or a smoke test)
-- doesn't have to belong to a project.
ALTER TABLE allgres_private.sessions
  ADD COLUMN IF NOT EXISTS project_id uuid REFERENCES allgres_private.projects(project_id);

-- Set once session_compactor's own remember for this session actually
-- lands (fn_submit_result's remember branch), never by the trigger side
-- itself (allgres_private.maybe_trigger_compaction) -- see that function's
-- comment for why. NULL means "never compacted, include every root-level
-- log," the behavior every session had before item 39.
ALTER TABLE allgres_private.sessions
  ADD COLUMN IF NOT EXISTS compacted_before timestamptz;

CREATE INDEX IF NOT EXISTS sessions_project_idx
  ON allgres_private.sessions (project_id, started_at DESC)
  WHERE project_id IS NOT NULL;

-- Roadmap item 6: schedule/event-driven execution tied to long-term goal
-- tracking. A schedule *is* the durable goal-tracking record, not a
-- separate concept bolted alongside one: its name and goal text describe
-- what is being pursued, and run_count/last_run_at/last_session_id are the
-- actual history of checking on it over time -- "how many times has this
-- run, most recently when, against which session" -- queryable in
-- PostgreSQL like everything else here, not held anywhere in worker memory.
-- Firing is a plain now() >= next_run_at poll (fn_run_schedules, called
-- from fn_pump alongside fn_watchdog/fn_dispatch_tasks), not pg_cron or any
-- external scheduler -- one less extension dependency, and the same
-- restart-survives-for-free property every other queue in this file
-- already has: state is a row, not a timer running somewhere.
--
-- Two independent stop conditions, both optional: max_runs (a run budget)
-- and ends_at (a wall-clock deadline) -- fn_run_schedules auto-deactivates
-- a schedule that has hit either, so "still is_active" itself means
-- "still eligible to fire," not just "was never turned off." A real
-- *cost*-based stop condition (a dollar or token budget) is deliberately
-- not here: nothing in this codebase parses token usage out of an LLM
-- response or prices a provider/model today, so a cost cap here would only
-- ever compare against a number nothing ever populates. That is real
-- follow-up work, not something to fake with an unenforced column.
CREATE TABLE IF NOT EXISTS allgres_private.schedules (
  schedule_id      uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name             text NOT NULL UNIQUE,
  agent_id         uuid NOT NULL REFERENCES allgres_private.agents(agent_id) ON DELETE CASCADE,
  goal             text NOT NULL,
  interval_seconds int NOT NULL CHECK (interval_seconds > 0),
  next_run_at      timestamptz NOT NULL,
  is_active        boolean NOT NULL DEFAULT true,
  max_runs         int CHECK (max_runs IS NULL OR max_runs > 0),
  run_count        int NOT NULL DEFAULT 0,
  ends_at          timestamptz,
  last_run_at      timestamptz,
  last_session_id  uuid REFERENCES allgres_private.sessions(session_id),
  created_at       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS schedules_due_idx
  ON allgres_private.schedules (next_run_at)
  WHERE is_active;

CREATE TABLE IF NOT EXISTS allgres_private.tasks (
  task_id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  session_id      uuid NOT NULL REFERENCES allgres_private.sessions(session_id),
  agent_id        uuid NOT NULL REFERENCES allgres_private.agents(agent_id),
  parent_task_id  uuid REFERENCES allgres_private.tasks(task_id),
  status          text NOT NULL CHECK (status IN
                    ('queued', 'running', 'completed', 'failed', 'waiting_human')),
  step_count      int NOT NULL DEFAULT 0,
  input           jsonb NOT NULL DEFAULT '{}'::jsonb,
  output          jsonb,
  error           text,
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now()
);

-- Set once, in fn_next_step, the first time a task leaves 'queued' -- distinct
-- from created_at because a task can sit 'queued' for a while waiting for a
-- max_concurrent_tasks slot before it ever runs a turn. max_turn_seconds (see
-- fn_watchdog) measures from here, not from created_at: the queue wait is not
-- part of the agent's own turn budget, and counting it would let a busy
-- agent's own concurrency cap starve tasks that are still waiting for their
-- first turn.
ALTER TABLE allgres_private.tasks
  ADD COLUMN IF NOT EXISTS started_at timestamptz;

-- 0 for a root task (no parent); a delegate child is always
-- parent.delegation_depth + 1 -- see fn_submit_result's delegate branch, which
-- enforces max_delegation_depth against this before ever inserting a
-- child row.
ALTER TABLE allgres_private.tasks
  ADD COLUMN IF NOT EXISTS delegation_depth int NOT NULL DEFAULT 0;

-- Which policy generation (allgres_private.policies.generation) was live
-- when this root task was created -- stamped once, at INSERT time, by
-- fn_create_session/fn_continue_session (the only two places that create
-- a root-level task) and never touched again even if the policy changes
-- again while the task is still running. This is what
-- allgres_private.agent_success_rate_for_generation and
-- fn_evaluate_last_change use to compare "how this agent did under policy
-- N" against "how it's doing under policy N+1" -- an outside review
-- pointed out that comparing whichever tasks happen to be most recent,
-- with no regard for which policy they actually ran under, could smear a
-- change's before/after outcomes together (a task queued right before a
-- change and one queued right after, both in the same "recent 20" window)
-- and call a regression an improvement, or vice versa, by accident. NULL
-- for a task inserted before this column existed, or a delegated child
-- (only root tasks are ever stamped -- a delegated child's outcome
-- reflects whoever it was delegated *to*, never the delegating agent's
-- own policy, the same reason agent_recent_success_rate already excludes
-- them).
ALTER TABLE allgres_private.tasks
  ADD COLUMN IF NOT EXISTS policy_generation int;

CREATE INDEX IF NOT EXISTS tasks_agent_policy_generation_idx
  ON allgres_private.tasks (agent_id, policy_generation, created_at DESC)
  WHERE parent_task_id IS NULL;

-- 'cancelled' is distinct from 'failed': an operator stopping a task is a
-- different signal than the agent's own logic giving up.  Unnamed CHECK
-- constraints get Postgres's default <table>_<column>_check name, so this is
-- the idempotent way to widen one -- CREATE TABLE IF NOT EXISTS won't touch
-- an existing table, and there is no ALTER TABLE ... ADD VALUE for a plain
-- CHECK the way there is for an enum type.
-- 'waiting_children' (roadmap item 5): a task paused on await_children,
-- exactly the same shape as 'waiting_human' -- excluded from
-- fn_dispatch_tasks' own claim query (status IN ('queued','running') only),
-- so it sits untouched until fn_watchdog's own sweep (see that function)
-- finds every one of its children terminal and requeues it. Nothing here
-- lives in worker memory: the dependency this represents (this task
-- depends on its children finishing) is entirely a row in this table, so a
-- worker or database restart loses none of it -- the next watchdog tick
-- just finds the same row again.
ALTER TABLE allgres_private.tasks DROP CONSTRAINT IF EXISTS tasks_status_check;
ALTER TABLE allgres_private.tasks ADD CONSTRAINT tasks_status_check CHECK (status IN
  ('queued', 'running', 'completed', 'failed', 'waiting_human', 'cancelled', 'waiting_children'));

CREATE INDEX IF NOT EXISTS tasks_ready_idx
  ON allgres_private.tasks (created_at)
  WHERE status IN ('queued', 'running');
CREATE INDEX IF NOT EXISTS tasks_session_idx
  ON allgres_private.tasks (session_id, created_at);
CREATE INDEX IF NOT EXISTS tasks_agent_status_idx
  ON allgres_private.tasks (agent_id, status);
CREATE INDEX IF NOT EXISTS tasks_updated_idx
  ON allgres_private.tasks (updated_at DESC);

-- An agent's own proposal to change its behavior -- never its resource
-- envelope or permissions, see fn_submit_result's propose_change handling
-- for the exact allowed-field list -- pending an operator's decision.
-- base_generation is the policy generation this was proposed against: if
-- the live policy has moved on by the time it's decided (an operator edit,
-- or another proposal already applied), fn_decide_proposal marks it
-- 'stale' instead of blindly applying it over whatever changed it.
CREATE TABLE IF NOT EXISTS allgres_private.change_proposals (
  proposal_id      uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  agent_id         uuid NOT NULL REFERENCES allgres_private.agents(agent_id) ON DELETE CASCADE,
  task_id          uuid REFERENCES allgres_private.tasks(task_id),
  proposed_changes jsonb NOT NULL,
  reason           text,
  base_generation  int NOT NULL,
  status           text NOT NULL DEFAULT 'pending'
                     CHECK (status IN ('pending', 'approved', 'rejected', 'stale')),
  created_at       timestamptz NOT NULL DEFAULT now(),
  decided_at       timestamptz,
  decided_reply    text
);

CREATE INDEX IF NOT EXISTS change_proposals_pending_idx
  ON allgres_private.change_proposals (created_at)
  WHERE status = 'pending';
CREATE INDEX IF NOT EXISTS change_proposals_agent_idx
  ON allgres_private.change_proposals (agent_id, created_at DESC);

-- kind/target_agent_id (item 36/38, the creator and self_improve system
-- agents): 'policy_change' is every proposal this table has ever held --
-- agent_id proposes a change to its own policy, target_agent_id stays NULL,
-- and fn_decide_proposal reads COALESCE(target_agent_id, agent_id) for
-- backward compatibility with every existing row. 'create_agent' is new:
-- agent_id (always 'creator') proposes a brand-new agent, proposed_changes
-- holds {name, system_prompt} instead of {system_prompt, llm_config},
-- target_agent_id and base_generation are both meaningless (there is no
-- existing target, so base_generation is stored as 0 and never compared).
-- target_agent_id lets self_improve (and only self_improve, enforced in
-- fn_submit_result) propose a change to an agent other than itself --
-- something no other agent may do, since propose_change's normal shape
-- assumes agent_id names both the proposer and the target.
ALTER TABLE allgres_private.change_proposals
  ADD COLUMN IF NOT EXISTS kind text NOT NULL DEFAULT 'policy_change'
    CHECK (kind IN ('policy_change', 'create_agent')),
  ADD COLUMN IF NOT EXISTS target_agent_id uuid REFERENCES allgres_private.agents(agent_id);

-- fixer's remediation queue (item 37): shaped like change_proposals but for
-- an action on permissions/agents.is_active rather than on policy fields --
-- deliberately a separate table rather than another change_proposals kind,
-- since a fix's payload (fix_kind + target_agent_id + detail) shares no
-- columns with proposed_changes's {system_prompt, llm_config} shape.
CREATE TABLE IF NOT EXISTS allgres_private.fix_proposals (
  fix_id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  agent_id        uuid NOT NULL REFERENCES allgres_private.agents(agent_id) ON DELETE CASCADE,
  task_id         uuid REFERENCES allgres_private.tasks(task_id),
  fix_kind        text NOT NULL CHECK (fix_kind IN ('revoke_permission', 'deactivate_agent')),
  target_agent_id uuid NOT NULL REFERENCES allgres_private.agents(agent_id),
  detail          jsonb NOT NULL DEFAULT '{}'::jsonb,
  reason          text,
  status          text NOT NULL DEFAULT 'pending'
                    CHECK (status IN ('pending', 'approved', 'rejected')),
  created_at      timestamptz NOT NULL DEFAULT now(),
  decided_at      timestamptz,
  decided_reply   text
);

CREATE INDEX IF NOT EXISTS fix_proposals_pending_idx
  ON allgres_private.fix_proposals (created_at)
  WHERE status = 'pending';

CREATE TABLE IF NOT EXISTS allgres_private.execution_logs (
  log_id      uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  task_id     uuid NOT NULL REFERENCES allgres_private.tasks(task_id),
  step_number int NOT NULL,
  role        text NOT NULL CHECK (role IN
                ('system', 'user', 'assistant', 'tool', 'error', 'operator')),
  content     jsonb NOT NULL,
  created_at  timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS execution_logs_task_idx
  ON allgres_private.execution_logs (task_id, step_number, created_at);
CREATE INDEX IF NOT EXISTS execution_logs_created_idx
  ON allgres_private.execution_logs (created_at DESC);

-- Long-term agent memory, slice one: structured storage plus recency/
-- importance retrieval, deliberately no embedding column or vector search
-- in this pass -- narrow, the same shape item 15 used for per-agent roles
-- ("does the core mechanism work at all, end to end, verified live, before
-- any of the rest is built on top of it"). execution_logs is the verbatim,
-- append-only transcript of one task; this is the opposite: a bounded,
-- curated, cross-session store an agent writes to on purpose (the
-- `remember` action) and that fn_next_step reads back into every future
-- turn's context, for that agent only -- see "7. Agent state machine".
-- subject_id is free text (there is no user-accounts system to key it to
-- yet, see KNOWN_ISSUES item 10), for an agent to tag who or what a memory
-- is about if it chooses to; nothing enforces its shape or reads it as
-- identity today.
CREATE TABLE IF NOT EXISTS allgres_private.agent_memories (
  memory_id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  agent_id          uuid NOT NULL REFERENCES allgres_private.agents(agent_id) ON DELETE CASCADE,
  subject_id        text,
  memory_type       text NOT NULL CHECK (memory_type IN
                      ('semantic', 'episodic', 'preference', 'instruction', 'relationship', 'working')),
  content           text NOT NULL,
  importance        real NOT NULL DEFAULT 0.5 CHECK (importance BETWEEN 0 AND 1),
  confidence        real NOT NULL DEFAULT 1.0 CHECK (confidence BETWEEN 0 AND 1),
  source_session_id uuid REFERENCES allgres_private.sessions(session_id) ON DELETE SET NULL,
  source_task_id    uuid REFERENCES allgres_private.tasks(task_id) ON DELETE SET NULL,
  created_at        timestamptz NOT NULL DEFAULT now(),
  last_accessed_at  timestamptz,
  expires_at        timestamptz,
  metadata          jsonb NOT NULL DEFAULT '{}'::jsonb
);

-- What fn_next_step's retrieval query actually uses: one agent's own rows,
-- ranked by importance then recency, live rows only.
CREATE INDEX IF NOT EXISTS agent_memories_recall_idx
  ON allgres_private.agent_memories (agent_id, importance DESC, created_at DESC);
CREATE INDEX IF NOT EXISTS agent_memories_expiry_idx
  ON allgres_private.agent_memories (expires_at)
  WHERE expires_at IS NOT NULL;

-- Slice two, deliberately deferred by slice one's own comment above:
-- semantic recall, same shape as agents.embedding (see that column's own
-- comment for why a plain double precision[] rather than pgvector's
-- `vector` type) -- a vector embedding of this one memory's own content,
-- so the new 'recall' agent action (fn_next_step) can rank an agent's own
-- memories by relevance to a query instead of only importance/recency,
-- which stays exactly as it was for the automatic every-turn injection.
-- embedding_model records "<provider name>:<model>" the same staleness-
-- detection reason agents.embedding_model gives.
ALTER TABLE allgres_private.agent_memories
  ADD COLUMN IF NOT EXISTS embedding double precision[],
  ADD COLUMN IF NOT EXISTS embedding_model text,
  ADD COLUMN IF NOT EXISTS embedding_updated_at timestamptz;

-- A lightweight audit trail (README, "Operator audit log"), deliberately
-- not a real accounts system: the dashboard has one shared bearer token
-- (see "Exposure" in the README's Security model), not per-operator
-- credentials, so there is no authenticated identity to attach here.
-- operator_name is self-reported -- text the browser sends alongside every
-- request, the same way the dashboard token itself is (sessionStorage, per
-- browser tab) -- and dashboard_rpc writes one row per consequential
-- action in the same transaction as the mutation itself, so a row only
-- ever exists for something that actually committed. This answers "who
-- claimed responsibility for this," not "who was authenticated to do it" --
-- anyone holding the one shared token can type any name, or none. See
-- KNOWN_ISSUES.md, item 10, for what a real accounts system would need
-- instead, and item 28 for why this lighter version was built first.
CREATE TABLE IF NOT EXISTS allgres_private.audit_log (
  audit_id      uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  operator_name text,
  action        text NOT NULL,
  details       jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at    timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS audit_log_created_idx
  ON allgres_private.audit_log (created_at DESC);

-- Every consequential mutation used to be logged only from inside
-- dashboard_rpc's own dispatch -- an outside review pointed out that this
-- project's other stated goal, every mutation also being a plain SQL
-- function an operator can call directly (see "Everything the dashboard
-- does, psql can do too" in the README), meant a direct SQL call left no
-- audit trail at all. origin/db_role fix that: origin records whether the
-- call arrived through dashboard_rpc ('web') or not ('sql', the default --
-- see allgres_private.audit's own comment for why that has to be the
-- fail-safe direction); db_role is the actual authenticated Postgres role
-- for the call, always populated regardless of origin -- unlike
-- operator_name, which stays exactly what it always was: self-reported,
-- present only for a 'web' row where the browser sent one.
ALTER TABLE allgres_private.audit_log
  ADD COLUMN IF NOT EXISTS origin text NOT NULL DEFAULT 'sql' CHECK (origin IN ('web', 'sql')),
  ADD COLUMN IF NOT EXISTS db_role text NOT NULL DEFAULT session_user;

-- dashboard_rpc calls allgres_private.set_audit_context once, before its
-- CASE dispatch, so every mutating function it goes on to call can write
-- its own audit_log row (via allgres_private.audit below) already knowing
-- this transaction arrived through the web/API surface with this self-
-- reported operator name. A plain `SET LOCAL`-equivalent GUC
-- (`is_local = true`) carries the actual value for just the current
-- transaction -- but PostgreSQL has a sharp edge for a *never-before-
-- referenced* custom GUC specifically: the very first is_local=true SET on
-- it, in any given session, does not roll back to NULL the way SET LOCAL
-- normally would -- it silently becomes that session's permanent baseline,
-- because there was no prior session-level value to revert to. Left alone,
-- that means the first dashboard_rpc call on a freshly-opened, since-
-- reused connection (fn_selftest calling itself twice in one psql session
-- is exactly this) would permanently mislabel every later direct-SQL call
-- on that same connection as 'web' too, for the rest of the session --
-- exactly the bug this whole feature exists to avoid. The fix: also issue
-- a plain (non-local) SET of the sentinel '__sql__' every time, right
-- before the real is_local value -- this reliably makes '__sql__' the
-- value this transaction's is_local override reverts to the instant it
-- commits or rolls back (verified against live PostgreSQL, not just
-- documented SET LOCAL semantics), regardless of whether this is the
-- first-ever reference to the GUC in this session. A function called
-- directly via SQL, in a transaction that never called this, reads back
-- either that same '__sql__' baseline or a genuine NULL (a connection
-- that has never touched this GUC at all) -- both mean 'sql' in
-- allgres_private.audit below.
CREATE OR REPLACE FUNCTION allgres_private.set_audit_context(p_operator_name text)
RETURNS void
LANGUAGE sql
AS $fn$
  SELECT set_config('allgres.audit_operator', '__sql__', false);
  SELECT set_config('allgres.audit_operator', COALESCE(NULLIF(btrim(p_operator_name), ''), ''), true);
$fn$;

-- The one place every consequential mutating function writes its own
-- audit_log row from now on, regardless of whether it was reached through
-- dashboard_rpc or called directly via SQL -- see the table's own comment
-- for why that parity is the whole point. p_details is whatever fields
-- that specific function judges safe and useful to record (never a raw
-- secret -- see each call site), not a generic echo of its arguments.
CREATE OR REPLACE FUNCTION allgres_private.audit(p_action text, p_details jsonb DEFAULT '{}'::jsonb)
RETURNS void
LANGUAGE sql
AS $fn$
  INSERT INTO allgres_private.audit_log (operator_name, action, details, origin, db_role)
  VALUES (
    NULLIF(NULLIF(current_setting('allgres.audit_operator', true), '__sql__'), ''),
    p_action,
    COALESCE(p_details, '{}'::jsonb),
    CASE WHEN COALESCE(current_setting('allgres.audit_operator', true), '__sql__') = '__sql__'
         THEN 'sql' ELSE 'web' END,
    session_user
  );
$fn$;

-- Real per-operator accounts (KNOWN_ISSUES.md, item 10 -- what item 28's
-- lighter audit log kept deferring): a username/password login, distinct
-- from the dashboard's one shared bearer token, so the conversational
-- (chat/messenger) surface can tell an admin apart from a regular user and
-- scope what each one can reach. password_hash is a pgcrypto bcrypt hash
-- (see fn_create_user/fn_login) -- never handled or compared in plaintext
-- past the one call that sets or checks it.
CREATE TABLE IF NOT EXISTS allgres_private.users (
  user_id       uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  username      text NOT NULL UNIQUE,
  password_hash text NOT NULL,
  role          text NOT NULL CHECK (role IN ('admin', 'user')),
  is_active     boolean NOT NULL DEFAULT true,
  created_at    timestamptz NOT NULL DEFAULT now()
);

-- A bearer token distinct from the dashboard's own shared one: this one
-- identifies a single logged-in user, carried by the browser the same way
-- (sessionStorage, sent back on every chat/messenger/account call) but
-- resolved server-side to a real row instead of trusted at face value.
CREATE TABLE IF NOT EXISTS allgres_private.web_sessions (
  session_token text PRIMARY KEY,
  user_id       uuid NOT NULL REFERENCES allgres_private.users(user_id) ON DELETE CASCADE,
  created_at    timestamptz NOT NULL DEFAULT now(),
  expires_at    timestamptz NOT NULL,
  last_seen_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS web_sessions_user_idx ON allgres_private.web_sessions (user_id);
CREATE INDEX IF NOT EXISTS web_sessions_expiry_idx ON allgres_private.web_sessions (expires_at);

-- Which agents a regular user may see or talk to at all -- an admin needs
-- no row here (see require_agent_access); this table only ever narrows a
-- regular user's reach, never widens an admin's.
CREATE TABLE IF NOT EXISTS allgres_private.user_agent_assignments (
  user_id    uuid NOT NULL REFERENCES allgres_private.users(user_id) ON DELETE CASCADE,
  agent_id   uuid NOT NULL REFERENCES allgres_private.agents(agent_id) ON DELETE CASCADE,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, agent_id)
);

-- One continuing session per (user, agent) pair for the simple 1:1 chat
-- page, and the same pair's session for a messenger @mention (see
-- messenger.post): "chat with this agent" is one ongoing conversation per
-- user, not a new session every message. Deliberately separate from
-- fn_create_session's ordinary sessions table -- this is only the pointer
-- to which session a user's chat with an agent currently lives in.
CREATE TABLE IF NOT EXISTS allgres_private.user_agent_chat_sessions (
  user_id    uuid NOT NULL REFERENCES allgres_private.users(user_id) ON DELETE CASCADE,
  agent_id   uuid NOT NULL REFERENCES allgres_private.agents(agent_id) ON DELETE CASCADE,
  session_id uuid NOT NULL REFERENCES allgres_private.sessions(session_id),
  updated_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, agent_id)
);

-- Project mode's own continuing-session map (item 42), the same one
-- session per pair shape as user_agent_chat_sessions above, kept as its
-- own table rather than folding project_id into that one's key: a user
-- chatting with the same agent both in General mode and through a Project
-- bound to it are deliberately two separate conversations (the project's
-- preset_prompt context shouldn't leak into the plain General chat, or the
-- other way around).
CREATE TABLE IF NOT EXISTS allgres_private.user_project_chat_sessions (
  user_id    uuid NOT NULL REFERENCES allgres_private.users(user_id) ON DELETE CASCADE,
  project_id uuid NOT NULL REFERENCES allgres_private.projects(project_id) ON DELETE CASCADE,
  session_id uuid NOT NULL REFERENCES allgres_private.sessions(session_id),
  updated_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, project_id)
);

-- The Slack-style messenger channel: every plain post, and every message
-- that addressed an agent with "@agent_name". mentioned_agent_id/session_id
-- are set only for the latter; messenger.list joins session_id back to
-- allgres_private.sessions to show the agent's reply once that session
-- completes, rather than duplicating the answer into this table itself.
CREATE TABLE IF NOT EXISTS allgres_private.channel_messages (
  message_id        uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  author_user_id    uuid NOT NULL REFERENCES allgres_private.users(user_id) ON DELETE CASCADE,
  content            text NOT NULL,
  mentioned_agent_id uuid REFERENCES allgres_private.agents(agent_id),
  session_id         uuid REFERENCES allgres_private.sessions(session_id),
  created_at         timestamptz NOT NULL DEFAULT now()
);

-- item 40: a message that @mentions more than one agent reaches all of
-- them, not just the first -- mentioned_agent_id/session_id above stay
-- populated with the *first* one (text order) so every existing reader of
-- those two columns keeps working unchanged; this is the full ordered list
-- for a multi-mention post, NULL for a plain post or a single mention.
ALTER TABLE allgres_private.channel_messages
  ADD COLUMN IF NOT EXISTS mentioned_agent_ids uuid[];
CREATE INDEX IF NOT EXISTS channel_messages_created_idx
  ON allgres_private.channel_messages (created_at DESC);

CREATE TABLE IF NOT EXISTS allgres_private.human_approvals (
  approval_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  task_id     uuid NOT NULL REFERENCES allgres_private.tasks(task_id),
  status      text NOT NULL CHECK (status IN ('pending', 'approved', 'rejected')),
  payload     jsonb NOT NULL,
  decided_at  timestamptz
);

-- created_at was missing entirely (no way to sort/age pending approvals);
-- reply_text carries what the human actually said, so the agent isn't just
-- unblocked but told why -- see fn_decide_approval; expires_at is what lets
-- fn_watchdog reclaim an approval nobody ever answers, the same "durable
-- queue, self-healing" shape it already uses for stuck outbound_calls and
-- sql_calls, just on human timescales instead of machine ones.
ALTER TABLE allgres_private.human_approvals
  ADD COLUMN IF NOT EXISTS created_at timestamptz NOT NULL DEFAULT now(),
  ADD COLUMN IF NOT EXISTS reply_text text,
  ADD COLUMN IF NOT EXISTS expires_at timestamptz;

CREATE INDEX IF NOT EXISTS human_approvals_pending_idx
  ON allgres_private.human_approvals (created_at)
  WHERE status = 'pending';
CREATE INDEX IF NOT EXISTS human_approvals_expiry_idx
  ON allgres_private.human_approvals (expires_at)
  WHERE status = 'pending' AND expires_at IS NOT NULL;

CREATE TABLE IF NOT EXISTS allgres_private.llm_providers (
  provider_id     uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name            text NOT NULL UNIQUE,
  kind            text NOT NULL CHECK (kind IN ('openai_compat', 'anthropic', 'oauth')),
  base_url        text NOT NULL,
  oauth_auth_url  text,
  oauth_token_url text,
  oauth_scope     text,
  oauth_client_id text,
  is_enabled      boolean NOT NULL DEFAULT true,
  -- Opt-in escape hatch for loopback / RFC1918 endpoints (Ollama, LM Studio,
  -- an in-cluster gateway).  Without it the outbound guard rejects them, which
  -- is what stops a dashboard user from turning the LLM path into an SSRF.
  allow_private_network boolean NOT NULL DEFAULT false,
  created_at      timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE allgres_private.llm_providers
  ADD COLUMN IF NOT EXISTS allow_private_network boolean NOT NULL DEFAULT false;

-- What a provider is *for*: a 'chat' provider serves an agent's own turns
-- (llm_config.provider on a policy) the same as before this column existed;
-- an 'embedding' provider exists only to turn text into a vector for
-- semantic search (agent-identity search, and later memory recall -- see
-- fn_queue_agent_embedding). Restricted to kind='openai_compat' because
-- POST <base_url>/embeddings with {"model","input"} and a
-- {"data":[{"embedding":[...]}]} response is the one shape every embedding
-- API (OpenAI, Voyage AI's OpenAI-compat mode, a local Ollama/LM Studio
-- server) actually agrees on; 'anthropic' has no embeddings endpoint at
-- all, and 'oauth' is a token-exchange shape, not a completions one.
ALTER TABLE allgres_private.llm_providers
  ADD COLUMN IF NOT EXISTS purpose text NOT NULL DEFAULT 'chat'
    CHECK (purpose IN ('chat', 'embedding'));

ALTER TABLE allgres_private.llm_providers
  DROP CONSTRAINT IF EXISTS llm_providers_embedding_purpose_kind_check;
ALTER TABLE allgres_private.llm_providers
  ADD CONSTRAINT llm_providers_embedding_purpose_kind_check
    CHECK (purpose <> 'embedding' OR kind = 'openai_compat');

-- Which model an 'embedding' provider actually calls -- meaningless for a
-- 'chat' provider, which already gets its model per-agent from
-- llm_config.model instead, since a chat provider genuinely serves many
-- models at once while an embedding provider row exists to call exactly
-- one (mixing embedding models in the same vector space is meaningless, see
-- agents.embedding_model). Required, not defaulted, the same way base_url
-- has no default: fn_create_provider/fn_set_provider reject an
-- embedding-purpose row without one rather than silently guessing a model
-- name that might not exist on that provider.
ALTER TABLE allgres_private.llm_providers
  ADD COLUMN IF NOT EXISTS embedding_model text;
ALTER TABLE allgres_private.llm_providers
  DROP CONSTRAINT IF EXISTS llm_providers_embedding_needs_model_check;
ALTER TABLE allgres_private.llm_providers
  ADD CONSTRAINT llm_providers_embedding_needs_model_check
    CHECK (purpose <> 'embedding' OR NULLIF(trim(embedding_model), '') IS NOT NULL);

-- Whether this provider's OpenAI-compat /chat/completions call may include
-- `response_format: {"type":"json_object"}` -- real OpenAI (and most hosted
-- openai_compat services) accept it and it measurably improves this file's
-- own "reply with one JSON object only" contract; a number of locally-run
-- openai_compat servers do not (confirmed live against LM Studio: HTTP 400,
-- "'response_format.type' must be 'json_schema' or 'text'"). This used to
-- be a single hardcoded `v_prov.name <> 'ollama'` check inside
-- build_llm_http -- true for every provider except the one literally
-- *named* 'ollama', including any other operator-added local server (LM
-- Studio, llama.cpp's own server, vLLM, ...) that shares the exact same
-- restriction under a different name. A real per-provider column instead,
-- defaulting to true (unchanged behavior for every existing provider except
-- the seeded 'ollama' row, retroactively flipped below), settable from the
-- provider create/edit form.
ALTER TABLE allgres_private.llm_providers
  ADD COLUMN IF NOT EXISTS response_format_json_object boolean NOT NULL DEFAULT true;
-- The retroactive UPDATE for the seeded 'ollama' row lives just after that
-- row's own INSERT further down this file, not here -- on a fresh install
-- this ALTER runs before that INSERT ever creates the row, so an UPDATE
-- here would silently match zero rows and the seed would keep the column's
-- 'true' default instead (confirmed live: exactly this ordering bug, caught
-- by fn_selftest's own seeded_ollama_provider_still_omits_response_format
-- case failing on a fresh install).

-- Everything below (agent-identity embeddings, semantic delegate search, and
-- later memory recall) is an optional feature layered on top of a plain
-- PostgreSQL install, never a hard dependency the way pgcrypto effectively
-- is for gen_random_uuid() on pre-13 servers. Embeddings are therefore
-- stored as an ordinary double precision[] -- a type every PostgreSQL has --
-- not pgvector's own `vector` type, which would make every table and
-- function that touches this column fail to even install on a server
-- without the `vector` extension. Ranking is done with plain SQL cosine
-- similarity (allgres_private.cosine_similarity below) everywhere, always
-- correct, just an unindexed sequential scan.
--
-- When the operator *has* installed pgvector (CREATE EXTENSION vector,
-- entirely their own opt-in step -- allgres never runs it itself, the same
-- way it never runs CREATE EXTENSION pgcrypto itself), every place that
-- reads or ranks embeddings checks allgres_private.vector_available() and
-- switches to a dynamic-SQL query built with EXECUTE (see fn_search_agents)
-- so it can use vector(N)'s <=> operator and an HNSW index -- speed, not
-- correctness, is the only thing pgvector changes here. Because a plain
-- CREATE FUNCTION body naming the `vector` type would fail to compile on a
-- server that has never installed the extension, every reference to it is
-- inside a string literal passed to EXECUTE, never written as literal SQL.
CREATE OR REPLACE FUNCTION allgres_private.vector_available()
RETURNS boolean
LANGUAGE sql STABLE
AS $fn$
  SELECT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'vector');
$fn$;

-- Every dynamic-SQL string that names the `vector` type or its operator
-- classes schema-qualifies them with this, rather than relying on
-- search_path: this function's own SECURITY DEFINER search_path (allgres_
-- private/allgres_public/pg_temp, never `public`) is still in effect for
-- an EXECUTE run from inside another SECURITY DEFINER function -- PL/pgSQL
-- does not restore the caller's search_path for a nested EXECUTE the way
-- it might look like it should -- so an unqualified `vector(N)` reference
-- would fail with "type vector does not exist" even on a server that has
-- it installed, the moment it is only visible via a search_path this
-- function does not share. Defaults to 'public' (CREATE EXTENSION vector's
-- own default target) only when pgvector is not installed at all, so a
-- caller that forgot to check vector_available() first still gets a
-- sensible "not found" error naming the schema it looked in, not a NULL
-- silently formatted into invalid SQL.
CREATE OR REPLACE FUNCTION allgres_private.vector_schema()
RETURNS text
LANGUAGE sql STABLE
AS $fn$
  SELECT COALESCE(
    (SELECT n.nspname FROM pg_extension e JOIN pg_namespace n ON n.oid = e.extnamespace WHERE e.extname = 'vector'),
    'public'
  );
$fn$;

-- Idempotent, safe to call on every embedding write: if pgvector is
-- installed and the accelerating index either does not exist yet or was
-- built for a dimension count that no longer matches what is actually
-- being written (an operator switched the configured embedding provider
-- or model -- see agents.embedding_model), drop and rebuild it for the
-- dimension count actually in use now. If pgvector is not installed, this
-- is a no-op -- there is deliberately no separate "enable vector support"
-- admin step; the index simply appears the first time an embedding is
-- written after the operator installs pgvector, which is what "it's an
-- add-on, not a dependency" means in practice. A plain expression index on
-- the array cast to vector(N), not a second synced column -- one less
-- thing that can drift out of sync with the real data. Its WHERE clause
-- restricts it to rows of that exact dimension, matching
-- fn_search_agents/rank_agents_by_embedding's own dimension filtering, so
-- an old-dimension row left behind by a provider switch is simply invisible
-- to this index rather than corrupting a distance comparison.
CREATE OR REPLACE FUNCTION allgres_private.ensure_vector_index()
RETURNS void
LANGUAGE plpgsql
AS $fn$
DECLARE
  v_dims int;
  v_idx_oid oid;
  v_indexed_dims int;
BEGIN
  IF NOT allgres_private.vector_available() THEN
    RETURN;
  END IF;

  SELECT array_length(embedding, 1) INTO v_dims
  FROM allgres_private.agents
  WHERE embedding IS NOT NULL
  ORDER BY embedding_updated_at DESC NULLS LAST
  LIMIT 1;
  IF v_dims IS NULL THEN
    RETURN;
  END IF;

  v_idx_oid := to_regclass('allgres_private.agents_embedding_hnsw_idx')::oid;
  IF v_idx_oid IS NOT NULL THEN
    SELECT (regexp_match(pg_get_indexdef(v_idx_oid), 'vector\((\d+)\)'))[1]::int INTO v_indexed_dims;
    IF v_indexed_dims = v_dims THEN
      RETURN;
    END IF;
    EXECUTE 'DROP INDEX allgres_private.agents_embedding_hnsw_idx';
  END IF;

  EXECUTE format(
    'CREATE INDEX agents_embedding_hnsw_idx ON allgres_private.agents '
    || 'USING hnsw ((embedding::%2$I.vector(%1$s)) %2$I.vector_cosine_ops) '
    || 'WHERE embedding IS NOT NULL AND array_length(embedding, 1) = %1$s',
    v_dims, allgres_private.vector_schema()
  );
END;
$fn$;

-- Same idempotent accelerating-index maintenance as ensure_vector_index
-- above, for allgres_private.agent_memories.embedding instead of
-- agents.embedding -- semantic recall's own table, kept as a second
-- function rather than a parameterized one so a plain `vector(N)`
-- reference never has to be built generically across two different
-- target tables inside one EXECUTE string.
CREATE OR REPLACE FUNCTION allgres_private.ensure_memory_vector_index()
RETURNS void
LANGUAGE plpgsql
AS $fn$
DECLARE
  v_dims int;
  v_idx_oid oid;
  v_indexed_dims int;
BEGIN
  IF NOT allgres_private.vector_available() THEN
    RETURN;
  END IF;

  SELECT array_length(embedding, 1) INTO v_dims
  FROM allgres_private.agent_memories
  WHERE embedding IS NOT NULL
  ORDER BY embedding_updated_at DESC NULLS LAST
  LIMIT 1;
  IF v_dims IS NULL THEN
    RETURN;
  END IF;

  v_idx_oid := to_regclass('allgres_private.agent_memories_embedding_hnsw_idx')::oid;
  IF v_idx_oid IS NOT NULL THEN
    SELECT (regexp_match(pg_get_indexdef(v_idx_oid), 'vector\((\d+)\)'))[1]::int INTO v_indexed_dims;
    IF v_indexed_dims = v_dims THEN
      RETURN;
    END IF;
    EXECUTE 'DROP INDEX allgres_private.agent_memories_embedding_hnsw_idx';
  END IF;

  EXECUTE format(
    'CREATE INDEX agent_memories_embedding_hnsw_idx ON allgres_private.agent_memories '
    || 'USING hnsw ((embedding::%2$I.vector(%1$s)) %2$I.vector_cosine_ops) '
    || 'WHERE embedding IS NOT NULL AND array_length(embedding, 1) = %1$s',
    v_dims, allgres_private.vector_schema()
  );
END;
$fn$;

-- Brute-force cosine similarity over two plain float arrays -- 1 = identical
-- direction, 0 = orthogonal, -1 = opposite; NULL if either side is empty or
-- their dimensions do not match (an agent embedded under a since-changed
-- embedding model, most likely -- see agents.embedding_model), since a
-- distance between vectors of different length is not meaningful. Used
-- directly when pgvector is not installed, and doubles as the correctness
-- reference the pgvector-accelerated path is checked against in
-- fn_selftest.
CREATE OR REPLACE FUNCTION allgres_private.cosine_similarity(
  a double precision[], b double precision[]
) RETURNS double precision
LANGUAGE sql IMMUTABLE
AS $fn$
  SELECT CASE
    WHEN a IS NULL OR b IS NULL OR array_length(a, 1) IS NULL OR array_length(a, 1) <> array_length(b, 1) THEN NULL
    ELSE (
      -- NULLIF, not a CASE: a zero-magnitude vector (degenerate, but not
      -- something to trust an embedding API never returns) must come back
      -- NULL, not raise "division by zero" and take fn_search_agents' whole
      -- ranking query down with it.
      SELECT sum(x * y) / NULLIF(sqrt(sum(x * x)) * sqrt(sum(y * y)), 0)
      FROM unnest(a, b) AS t(x, y)
    )
  END;
$fn$;

-- The actual ranking behind the 'search_agents' agent action (see
-- fn_next_step and fn_complete_outbound's 'embedding' branch): every other
-- active, embedded agent the requester actually holds an 'agent' permission
-- grant for (allgres_private.agent_has_permission -- the exact same check
-- 'delegate' itself enforces, so a search can never surface a name the
-- caller could not actually delegate to), ranked by cosine similarity to
-- the caller's query embedding, nearest first. Uses the pgvector-
-- accelerated <=> operator via dynamic SQL when
-- allgres_private.vector_available(), a brute-force
-- allgres_private.cosine_similarity() scan otherwise -- see the
-- llm_providers.purpose comment for why both paths have to exist. Excludes
-- the requester itself (searching for a delegate target, not a mirror), any
-- agent whose embedding has a different dimension than the query's
-- (cosine_similarity already returns NULL for that mismatch in the
-- brute-force path; the accelerated path filters it explicitly since
-- casting a mismatched-length array to vector(N) would error, not just rank
-- oddly), and -- p_expected_model, the "<provider name>:<model>" the query
-- embedding was itself just generated with (see fn_complete_outbound) --
-- any agent embedded under a *different* model. Two different embedding
-- models can produce vectors of the identical dimension while meaning
-- something completely different per axis; matching dimension alone would
-- silently rank across two incomparable vector spaces the moment an
-- operator switches embedding providers/models without an accident this
-- obvious ever surfacing as an error.
CREATE OR REPLACE FUNCTION allgres_private.rank_agents_by_embedding(
  p_query_embedding double precision[],
  p_requester_agent_id uuid,
  p_expected_model text,
  p_limit int DEFAULT 5
) RETURNS jsonb
LANGUAGE plpgsql
AS $fn$
DECLARE
  v_out jsonb;
  v_dims int;
  v_n int := GREATEST(1, LEAST(COALESCE(p_limit, 5), 20));
BEGIN
  v_dims := array_length(p_query_embedding, 1);
  IF v_dims IS NULL THEN
    RETURN '[]'::jsonb;
  END IF;

  IF allgres_private.vector_available() THEN
    EXECUTE format(
      'SELECT COALESCE(jsonb_agg(jsonb_build_object(''agent_id'', agent_id, ''name'', name, ''similarity'', similarity) ORDER BY similarity DESC), ''[]''::jsonb) '
      || 'FROM (SELECT agent_id, name, 1 - (embedding::%2$I.vector(%1$s) OPERATOR(%2$I.<=>) $1::%2$I.vector(%1$s)) AS similarity '
      || 'FROM allgres_private.agents '
      || 'WHERE embedding IS NOT NULL AND is_active AND agent_id <> $2 AND array_length(embedding, 1) = %1$s '
      || 'AND embedding_model = $4 '
      || 'AND allgres_private.agent_has_permission($2, ''agent'', name) '
      || 'ORDER BY embedding::%2$I.vector(%1$s) OPERATOR(%2$I.<=>) $1::%2$I.vector(%1$s) LIMIT $3) s',
      v_dims, allgres_private.vector_schema()
    ) INTO v_out USING p_query_embedding, p_requester_agent_id, v_n, p_expected_model;
  ELSE
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'agent_id', agent_id, 'name', name, 'similarity', similarity
    ) ORDER BY similarity DESC), '[]'::jsonb)
    INTO v_out
    FROM (
      SELECT agent_id, name, allgres_private.cosine_similarity(embedding, p_query_embedding) AS similarity
      FROM allgres_private.agents
      WHERE embedding IS NOT NULL AND is_active
        AND agent_id <> p_requester_agent_id
        AND array_length(embedding, 1) = v_dims
        AND embedding_model = p_expected_model
        AND allgres_private.agent_has_permission(p_requester_agent_id, 'agent', name)
      ORDER BY allgres_private.cosine_similarity(embedding, p_query_embedding) DESC NULLS LAST
      LIMIT v_n
    ) s;
  END IF;

  RETURN v_out;
END;
$fn$;

-- The 'recall' agent action's own ranking (fn_next_step queues the query
-- embedding, fn_complete_outbound's 'recall' branch calls this once it
-- comes back): an agent's own live memories only (WHERE agent_id =, not
-- <>, unlike rank_agents_by_embedding above -- this is semantic search
-- over the caller's own store, not a cross-agent discovery), ranked by
-- cosine similarity to the query, nearest first. No separate permission
-- check: an agent's own agent_memories rows are already its own private
-- store with no cross-agent read path at all (see agent_memories' own
-- comment), the identical trust boundary fn_next_step's automatic
-- importance/recency recall already uses -- this only changes the
-- ordering, not who can see what. Same dimension/model guards as
-- rank_agents_by_embedding, for the same reason (a since-changed
-- embedding provider must never silently rank across two incomparable
-- vector spaces).
CREATE OR REPLACE FUNCTION allgres_private.rank_memories_by_embedding(
  p_query_embedding double precision[],
  p_agent_id uuid,
  p_expected_model text,
  p_limit int DEFAULT 5
) RETURNS jsonb
LANGUAGE plpgsql
AS $fn$
DECLARE
  v_out jsonb;
  v_dims int;
  v_n int := GREATEST(1, LEAST(COALESCE(p_limit, 5), 20));
BEGIN
  v_dims := array_length(p_query_embedding, 1);
  IF v_dims IS NULL THEN
    RETURN '[]'::jsonb;
  END IF;

  IF allgres_private.vector_available() THEN
    EXECUTE format(
      'SELECT COALESCE(jsonb_agg(jsonb_build_object('
      || '''memory_id'', memory_id, ''memory_type'', memory_type, ''content'', content, ''similarity'', similarity'
      || ') ORDER BY similarity DESC), ''[]''::jsonb) '
      || 'FROM (SELECT memory_id, memory_type, left(content, 500) AS content, '
      || '1 - (embedding::%2$I.vector(%1$s) OPERATOR(%2$I.<=>) $1::%2$I.vector(%1$s)) AS similarity '
      || 'FROM allgres_private.agent_memories '
      || 'WHERE embedding IS NOT NULL AND agent_id = $2 AND array_length(embedding, 1) = %1$s '
      || 'AND embedding_model = $4 AND (expires_at IS NULL OR expires_at > now()) '
      || 'ORDER BY embedding::%2$I.vector(%1$s) OPERATOR(%2$I.<=>) $1::%2$I.vector(%1$s) LIMIT $3) s',
      v_dims, allgres_private.vector_schema()
    ) INTO v_out USING p_query_embedding, p_agent_id, v_n, p_expected_model;
  ELSE
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'memory_id', memory_id, 'memory_type', memory_type, 'content', content, 'similarity', similarity
    ) ORDER BY similarity DESC), '[]'::jsonb)
    INTO v_out
    FROM (
      SELECT memory_id, memory_type, left(content, 500) AS content,
             allgres_private.cosine_similarity(embedding, p_query_embedding) AS similarity
      FROM allgres_private.agent_memories
      WHERE embedding IS NOT NULL AND agent_id = p_agent_id
        AND array_length(embedding, 1) = v_dims
        AND embedding_model = p_expected_model
        AND (expires_at IS NULL OR expires_at > now())
      ORDER BY allgres_private.cosine_similarity(embedding, p_query_embedding) DESC NULLS LAST
      LIMIT v_n
    ) s;
  END IF;

  RETURN v_out;
END;
$fn$;

-- Never returned by list functions.  Operator writes via fn_set_provider_secret.
CREATE TABLE IF NOT EXISTS allgres_private.llm_secrets (
  provider_id         uuid PRIMARY KEY REFERENCES allgres_private.llm_providers(provider_id) ON DELETE CASCADE,
  api_key             text,
  oauth_client_secret text,
  access_token        text,
  refresh_token       text,
  expires_at          timestamptz
);

CREATE TABLE IF NOT EXISTS allgres_private.oauth_states (
  state        text PRIMARY KEY,
  provider_id  uuid NOT NULL REFERENCES allgres_private.llm_providers(provider_id) ON DELETE CASCADE,
  created_at   timestamptz NOT NULL DEFAULT now()
);

-- Roadmap item 2: a named external HTTP endpoint an operator configures once
-- (base_url + how to authenticate), so the 'http_request' tool can send an
-- authenticated call without an agent ever seeing, choosing, or supplying a
-- credential itself. base_url is fixed at configuration time and is the only
-- host a stored credential may ever be sent to -- an agent using a
-- connection supplies a relative path, never a full URL (enforced in
-- fn_next_step's call_tool handling, not here); this is the same
-- no-per-caller-redirect shape llm_providers.base_url already enforces for
-- an agent's own llm_config (see sanitize_llm_config).
CREATE TABLE IF NOT EXISTS allgres_private.api_connections (
  connection_id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name                  text NOT NULL UNIQUE,
  base_url              text NOT NULL,
  auth_kind             text NOT NULL DEFAULT 'none'
                          CHECK (auth_kind IN ('none', 'authorization', 'x-api-key')),
  allow_private_network boolean NOT NULL DEFAULT false,
  is_enabled            boolean NOT NULL DEFAULT true,
  created_at            timestamptz NOT NULL DEFAULT now(),
  updated_at            timestamptz NOT NULL DEFAULT now()
);

-- Never returned by list functions, same as llm_secrets -- operator writes
-- via fn_set_connection_secret only.
CREATE TABLE IF NOT EXISTS allgres_private.api_connection_secrets (
  connection_id  uuid PRIMARY KEY REFERENCES allgres_private.api_connections(connection_id) ON DELETE CASCADE,
  api_key        text
);

CREATE TABLE IF NOT EXISTS allgres_private.outbound_calls (
  call_id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  task_id          uuid NOT NULL REFERENCES allgres_private.tasks(task_id),
  kind             text NOT NULL CHECK (kind IN ('llm', 'tool')),
  tool             text,
  url              text NOT NULL,
  request_headers  jsonb NOT NULL DEFAULT '{}'::jsonb,
  request_body     jsonb NOT NULL DEFAULT '{}'::jsonb,
  net_request_id   bigint,
  status           text NOT NULL CHECK (status IN ('queued', 'in_flight', 'harvested', 'lost')),
  response_status  int,
  response_body    text,
  error            text,
  created_at       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now()
);

-- 'embedding': fn_search_agents' own query text, queued and claimed exactly
-- like 'llm' (same provider/auth_kind resolution in fn_claim_outbound, same
-- JSON-POST shape in perform_http) -- task-bound because a search happens
-- mid-turn, unlike an agent's own identity embedding (embedding_calls
-- above, which has no task to belong to). See fn_complete_outbound's
-- 'embedding' branch for what happens to the response.
ALTER TABLE allgres_private.outbound_calls DROP CONSTRAINT IF EXISTS outbound_calls_kind_check;
ALTER TABLE allgres_private.outbound_calls ADD CONSTRAINT outbound_calls_kind_check
  CHECK (kind IN ('llm', 'tool', 'embedding', 'recall'));

-- 'recall': the new 'recall' agent action's own query text (semantic
-- memory search, fn_next_step) -- queued and claimed exactly like
-- 'embedding' above (same provider/auth_kind resolution, same JSON-POST
-- shape), kept as its own kind rather than reusing 'embedding' only
-- because fn_complete_outbound needs to know which ranking function to
-- call once the vector comes back: allgres_private.rank_agents_by_embedding
-- for 'embedding' (search_agents), allgres_private.rank_memories_by_embedding
-- for this one.

-- Set (as the 'idempotency-key' request header, mirrored here for
-- visibility) on every mutating 'http_request' call queued by
-- fn_next_step's call_tool handling -- see that INSERT's own comment for
-- how the value is derived and why. NULL for a GET/http_get call (nothing
-- to make idempotent) and for anything queued before this column existed.
-- An outside review pointed out that a crash between an external side
-- effect actually landing (the worker's HTTP call succeeded) and this
-- extension recording that it did (fn_complete_outbound never ran, or
-- fn_watchdog reclaimed a call that was in fact already delivered) could
-- leave an agent's later retry as a genuine duplicate POST/PATCH/DELETE
-- against a real external system -- this is the mitigation: a
-- de-facto-standard header (the same one Stripe/GitHub/PayPal/Square
-- already accept) that lets an idempotency-aware destination recognize a
-- retried request and return its original result instead of repeating the
-- effect. It is a mitigation, not a guarantee -- see this column's own
-- section in README, "External call idempotency", for exactly which
-- outcomes it does and does not cover.
ALTER TABLE allgres_private.outbound_calls
  ADD COLUMN IF NOT EXISTS idempotency_key text;

-- The URL's host string is checked against allgres_private.is_blocked_host at
-- queue time (see check_outbound_url), but the worker connects by hostname
-- later, on its own HTTP thread, with its own DNS resolution -- a hostname
-- that resolves to a public IP right now can resolve to 127.0.0.1 or an
-- RFC1918 address by the time the request actually goes out (DNS
-- rebinding), and the string check has nothing left to say about that. The
-- worker re-checks every IP the host actually resolves to immediately
-- before connecting; this column is the one piece of context it cannot
-- derive from the URL alone -- whether *this* call's provider opted into
-- loopback/private endpoints -- so it knows whether that recheck should
-- reject a private address or accept it. http_get never sets it: the tool
-- path passes p_allow_private = false into check_outbound_url unconditionally,
-- so it stays at its default here too.
ALTER TABLE allgres_private.outbound_calls
  ADD COLUMN IF NOT EXISTS allow_private boolean NOT NULL DEFAULT false;

-- Which provider (if any) this call needs a credential for, and which header
-- to put it in -- not the credential itself. request_headers never holds the
-- decrypted key; fn_claim_outbound resolves it from provider_id at claim
-- time and merges it only into the JSON handed to the worker. Both are NULL
-- for a 'tool' call (http_get carries no credential at all).
ALTER TABLE allgres_private.outbound_calls
  ADD COLUMN IF NOT EXISTS provider_id uuid REFERENCES allgres_private.llm_providers(provider_id),
  ADD COLUMN IF NOT EXISTS auth_kind text CHECK (auth_kind IS NULL OR auth_kind IN ('authorization', 'x-api-key'));

-- The HTTP method the worker actually sends. Always 'GET' before this column
-- existed (the only shape 'llm'/'oauth' calls ever needed a verb for, and
-- 'tool' meant http_get); the 'http_request' tool is what first needed
-- anything else. Same credential-at-claim-time boundary as provider_id
-- above, for a stored allgres_private.api_connections credential instead of
-- an llm_providers one -- request_headers never holds the decrypted key,
-- fn_claim_outbound resolves it from connection_id at claim time. Both are
-- NULL unless the tool call named a connection.
ALTER TABLE allgres_private.outbound_calls
  ADD COLUMN IF NOT EXISTS method text NOT NULL DEFAULT 'GET'
    CHECK (method IN ('GET', 'POST', 'PUT', 'PATCH', 'DELETE'));
ALTER TABLE allgres_private.outbound_calls
  ADD COLUMN IF NOT EXISTS connection_id uuid REFERENCES allgres_private.api_connections(connection_id);

CREATE INDEX IF NOT EXISTS outbound_ready_idx
  ON allgres_private.outbound_calls (created_at)
  WHERE status = 'queued';
CREATE INDEX IF NOT EXISTS outbound_task_idx
  ON allgres_private.outbound_calls (task_id, status);
CREATE INDEX IF NOT EXISTS outbound_inflight_idx
  ON allgres_private.outbound_calls (updated_at)
  WHERE status = 'in_flight';

-- OAuth token exchange, queued the same way as outbound_calls/sql_calls:
-- queued -> in_flight -> harvested/lost, claimed by the runtime worker and
-- run on the same HTTP thread pool. Unlike outbound_calls this has no
-- task_id -- the exchange is an operator-initiated dashboard action, not an
-- agent turn -- so fn_complete_oauth stores the resulting tokens directly
-- instead of routing through fn_submit_result. request_body never holds the
-- client_secret: fn_oauth_token_request queues everything else, and
-- fn_claim_oauth resolves and merges the decrypted secret in at claim time,
-- the same credential-at-claim-time shape fn_claim_outbound already uses for
-- an LLM provider's api_key (see KNOWN_ISSUES, "provider credentials in
-- plaintext").
CREATE TABLE IF NOT EXISTS allgres_private.oauth_calls (
  call_id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  provider_id      uuid NOT NULL REFERENCES allgres_private.llm_providers(provider_id) ON DELETE CASCADE,
  state            text NOT NULL,
  url              text NOT NULL,
  request_headers  jsonb NOT NULL DEFAULT '{}'::jsonb,
  request_body     jsonb NOT NULL DEFAULT '{}'::jsonb,
  allow_private    boolean NOT NULL DEFAULT false,
  status           text NOT NULL CHECK (status IN ('queued', 'in_flight', 'harvested', 'lost')),
  response_status  int,
  error            text,
  created_at       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS oauth_calls_ready_idx
  ON allgres_private.oauth_calls (created_at)
  WHERE status = 'queued';
CREATE INDEX IF NOT EXISTS oauth_calls_inflight_idx
  ON allgres_private.oauth_calls (updated_at)
  WHERE status = 'in_flight';

-- Regenerating an agent's identity embedding (fn_queue_agent_embedding,
-- called whenever fn_create_agent/agents.update touches name or
-- system_prompt) is, like an OAuth token exchange, not an agent turn --
-- there is no task_id to hang it off. Same queued -> in_flight ->
-- harvested/lost shape as oauth_calls, claimed by the same runtime worker
-- HTTP pool; fn_complete_agent_embedding writes the result straight into
-- allgres_private.agents.embedding instead of routing through
-- fn_submit_result. A task-bound embedding (fn_search_agents' own query
-- text) goes through outbound_calls instead, alongside 'llm'/'tool' -- see
-- that table's kind check and fn_complete_outbound's 'embedding' branch.
CREATE TABLE IF NOT EXISTS allgres_private.embedding_calls (
  call_id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  agent_id         uuid NOT NULL REFERENCES allgres_private.agents(agent_id) ON DELETE CASCADE,
  provider_id      uuid NOT NULL REFERENCES allgres_private.llm_providers(provider_id) ON DELETE CASCADE,
  model            text NOT NULL,
  url              text NOT NULL,
  request_headers  jsonb NOT NULL DEFAULT '{}'::jsonb,
  request_body     jsonb NOT NULL DEFAULT '{}'::jsonb,
  allow_private    boolean NOT NULL DEFAULT false,
  status           text NOT NULL CHECK (status IN ('queued', 'in_flight', 'harvested', 'lost')),
  response_status  int,
  error            text,
  created_at       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS embedding_calls_ready_idx
  ON allgres_private.embedding_calls (created_at)
  WHERE status = 'queued';
CREATE INDEX IF NOT EXISTS embedding_calls_inflight_idx
  ON allgres_private.embedding_calls (updated_at)
  WHERE status = 'in_flight';

-- Semantic memory recall (allgres_private.queue_memory_embedding /
-- fn_complete_agent_embedding's 'memory' branch): the exact same
-- queued -> in_flight -> harvested/lost pipeline above, generalized to a
-- second kind of target instead of a second table, since fn_claim_agent_
-- embedding's own claim query never referenced agent_id at all -- only
-- fn_complete_agent_embedding's final write needs to know which row this
-- was for. agent_id is now nullable and memory_id is the alternative
-- target; the CHECK below is the same "exactly one of two possible
-- targets" shape outbound_calls' own kind-specific columns already use
-- informally (a 'tool' row's connection_id, an 'llm' row's provider_id),
-- just enforced here since there really are only two rows to distinguish.
ALTER TABLE allgres_private.embedding_calls
  ALTER COLUMN agent_id DROP NOT NULL,
  ADD COLUMN IF NOT EXISTS memory_id uuid REFERENCES allgres_private.agent_memories(memory_id) ON DELETE CASCADE;

ALTER TABLE allgres_private.embedding_calls DROP CONSTRAINT IF EXISTS embedding_calls_target_check;
ALTER TABLE allgres_private.embedding_calls ADD CONSTRAINT embedding_calls_target_check
  CHECK ((agent_id IS NOT NULL) <> (memory_id IS NOT NULL));

-- Agent SQL is validated here (fn_validate_sql) but executed by the runtime
-- worker as a top-level statement under the `sandbox` role -- PostgreSQL
-- forbids `SET ROLE` inside a SECURITY DEFINER function, so it cannot run
-- inline in the same call that validates it.  This table is the handoff,
-- shaped exactly like outbound_calls: queued -> in_flight -> harvested/lost.
CREATE TABLE IF NOT EXISTS allgres_private.sql_calls (
  call_id     uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  task_id     uuid NOT NULL REFERENCES allgres_private.tasks(task_id),
  agent_id    uuid NOT NULL REFERENCES allgres_private.agents(agent_id),
  sql         text NOT NULL,
  status      text NOT NULL CHECK (status IN ('queued', 'in_flight', 'harvested', 'lost')),
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS sql_calls_ready_idx
  ON allgres_private.sql_calls (created_at)
  WHERE status = 'queued';
CREATE INDEX IF NOT EXISTS sql_calls_task_idx
  ON allgres_private.sql_calls (task_id, status);
CREATE INDEX IF NOT EXISTS sql_calls_inflight_idx
  ON allgres_private.sql_calls (updated_at)
  WHERE status = 'in_flight';

CREATE TABLE IF NOT EXISTS allgres_private.demo_sales (
  sale_id   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  agent_id  uuid REFERENCES allgres_private.agents(agent_id) ON DELETE CASCADE,
  region    text NOT NULL,
  sku       text NOT NULL,
  amount    numeric NOT NULL,
  sold_on   date NOT NULL
);

-- Prefers the caller's actual PostgreSQL role identity over the
-- allgres.agent_id GUC: an agent provisioned with its own role (see
-- fn_provision_agent_role) is running sandboxed SQL as that role, and
-- current_user is PostgreSQL's own session state, not a value this or any
-- other function has to trust a GUC for.
--
-- Deliberately SECURITY INVOKER and table-free (the agent_id is parsed
-- straight back out of the role name -- fn_provision_agent_role only ever
-- names one 'allgres_agent_' || <uuid with dashes stripped>, so this is
-- exactly reversible) rather than looking it up in allgres_private.agents.
-- The reason is not the schema grant (that could be solved with
-- SECURITY DEFINER, same as everywhere else in this file) but something
-- SECURITY DEFINER cannot solve here: it changes current_user for the
-- rest of that function's execution, to the function's *owner*, not the
-- original caller -- and that change is in effect for anything called
-- from inside it too, security definer or not. agent_may_read is already
-- SECURITY DEFINER (it has to be, to read allgres_private.permissions and
-- sql_sandbox_allowlist); calling this function from inside agent_may_read
-- would see current_user as agent_may_read's owner on every single call,
-- never the querying agent's own role -- confirmed live: that was this
-- function's first version, and every agent's own grants resolved as
-- "no permission" against its own view. So this stays SECURITY INVOKER,
-- and every caller (see v_sales / v_my_tasks below) calls it directly,
-- before crossing into agent_may_read's SECURITY DEFINER boundary, not
-- from inside it -- current_user is only ever the real caller up to the
-- point something SECURITY DEFINER runs, never past it.
--
-- The GUC path stays as a fallback for an agent that predates per-agent
-- roles and still runs sandboxed SQL as the one shared `sandbox` role --
-- see fn_run_sandboxed_sql's caller in src/lib.rs for how that GUC gets
-- set. GUCs do not have the SECURITY DEFINER problem above: a value set
-- with set_config(..., true) survives a role or security-context change
-- for the rest of the transaction, which is exactly why the original
-- design used one instead of current_user in the first place.
CREATE OR REPLACE FUNCTION allgres_private.current_agent_id()
RETURNS uuid
LANGUAGE sql
STABLE
AS $fn$
  SELECT COALESCE(
    (
      SELECT (
        substr(hex, 1, 8) || '-' || substr(hex, 9, 4) || '-' || substr(hex, 13, 4) || '-' ||
        substr(hex, 17, 4) || '-' || substr(hex, 21, 12)
      )::uuid
      FROM (SELECT substr(current_user, length('allgres_agent_') + 1) AS hex) s
      -- Not just a length check: an unrelated role that happens to start
      -- with this prefix must fall through to the GUC, not blow up the
      -- ::uuid cast below with an "invalid input syntax" error.
      WHERE hex ~ '^[0-9a-f]{32}$'
    ),
    nullif(current_setting('allgres.agent_id', true), '')::uuid
  )
$fn$;

CREATE OR REPLACE FUNCTION allgres_private.touch_updated_at()
RETURNS trigger
LANGUAGE plpgsql
AS $fn$
BEGIN
  NEW.updated_at := now();
  RETURN NEW;
END;
$fn$;

DROP TRIGGER IF EXISTS agents_touch ON allgres_private.agents;
CREATE TRIGGER agents_touch
  BEFORE UPDATE ON allgres_private.agents
  FOR EACH ROW EXECUTE FUNCTION allgres_private.touch_updated_at();

DROP TRIGGER IF EXISTS tasks_touch ON allgres_private.tasks;
CREATE TRIGGER tasks_touch
  BEFORE UPDATE ON allgres_private.tasks
  FOR EACH ROW EXECUTE FUNCTION allgres_private.touch_updated_at();

DROP TRIGGER IF EXISTS projects_touch ON allgres_private.projects;
CREATE TRIGGER projects_touch
  BEFORE UPDATE ON allgres_private.projects
  FOR EACH ROW EXECUTE FUNCTION allgres_private.touch_updated_at();

CREATE OR REPLACE FUNCTION allgres_private.forbid_log_mutation()
RETURNS trigger
LANGUAGE plpgsql
AS $fn$
BEGIN
  RAISE EXCEPTION 'execution_logs are append-only'
    USING ERRCODE = 'P0001';
END;
$fn$;

DROP TRIGGER IF EXISTS execution_logs_no_update ON allgres_private.execution_logs;
CREATE TRIGGER execution_logs_no_update
  BEFORE UPDATE OR DELETE ON allgres_private.execution_logs
  FOR EACH ROW EXECUTE FUNCTION allgres_private.forbid_log_mutation();

-- An audit trail that can be edited or deleted isn't one -- append-only,
-- the same enforcement (trigger + REVOKE, not just convention) execution_logs
-- already has, for the same reason.
CREATE OR REPLACE FUNCTION allgres_private.forbid_audit_mutation()
RETURNS trigger
LANGUAGE plpgsql
AS $fn$
BEGIN
  RAISE EXCEPTION 'audit_log is append-only'
    USING ERRCODE = 'P0001';
END;
$fn$;

DROP TRIGGER IF EXISTS audit_log_no_update ON allgres_private.audit_log;
CREATE TRIGGER audit_log_no_update
  BEFORE UPDATE OR DELETE ON allgres_private.audit_log
  FOR EACH ROW EXECUTE FUNCTION allgres_private.forbid_audit_mutation();

CREATE OR REPLACE FUNCTION allgres_private.ensure_policy()
RETURNS trigger
LANGUAGE plpgsql
AS $fn$
BEGIN
  INSERT INTO allgres_private.policies (agent_id, system_prompt, llm_config)
  VALUES (
    NEW.agent_id,
    $prompt$You are an agent whose next action is decided only as JSON.
Reply with a single JSON object, no markdown, no extra keys:
{"action":"final_answer","answer":"..."}
{"action":"execute_sql","sql":"SELECT ..."}
{"action":"call_tool","tool":"...","args":{}}
{"action":"delegate","agent_name":"...","input":{},"wait":false}
{"action":"await_children"}
{"action":"await_human","reason":"..."}
SQL must be a single SELECT or WITH against schema-qualified views you were given.
delegate's "wait" defaults to false (hand off and your turn ends); set it true to keep going instead of
finishing, so you can delegate to more agents or later call await_children to pause until every agent you
delegated to has finished, with what each one did visible on your next turn.
$prompt$,
    -- Deliberately empty: a new agent has no provider/model until an
    -- operator configures one. Defaulting this to any real provider would
    -- make every fresh agent look already set up when it never was.
    '{}'::jsonb
  )
  ON CONFLICT (agent_id) DO NOTHING;
  RETURN NEW;
END;
$fn$;

DROP TRIGGER IF EXISTS agents_ensure_policy ON allgres_private.agents;
CREATE TRIGGER agents_ensure_policy
  AFTER INSERT ON allgres_private.agents
  FOR EACH ROW EXECUTE FUNCTION allgres_private.ensure_policy();

-- ---------------------------------------------------------------------------
-- 3. Generic helpers.
-- ---------------------------------------------------------------------------

-- base_url is deliberately NOT accepted here.  Per-agent llm_config used to be
-- able to override the endpoint, which let anyone with dashboard access point
-- the worker (carrying the provider API key) at an arbitrary address.  The
-- endpoint now comes only from allgres_private.llm_providers, which is
-- operator-managed and validated by the outbound guard.
CREATE OR REPLACE FUNCTION allgres_private.sanitize_llm_config(p jsonb)
RETURNS jsonb
LANGUAGE sql
IMMUTABLE
AS $fn$
  SELECT jsonb_strip_nulls(jsonb_build_object(
    'model',       NULLIF(p->>'model', ''),
    'temperature', p->'temperature',
    'max_tokens',  p->'max_tokens',
    'provider',    NULLIF(p->>'provider', '')
  ))
$fn$;

CREATE OR REPLACE FUNCTION allgres_private.extract_first_json(p_text text)
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE
AS $fn$
DECLARE
  i int;
  start_pos int := 0;
  depth int := 0;
  in_str boolean := false;
  esc boolean := false;
  ch text;
  chunk text;
BEGIN
  IF p_text IS NULL OR btrim(p_text) = '' THEN
    RETURN NULL;
  END IF;
  -- Fast path: the whole string is JSON
  BEGIN
    IF left(btrim(p_text), 1) = '{' THEN
      RETURN btrim(p_text)::jsonb;
    END IF;
  EXCEPTION WHEN others THEN
    NULL;
  END;
  FOR i IN 1..length(p_text) LOOP
    ch := substr(p_text, i, 1);
    IF start_pos = 0 THEN
      IF ch = '{' THEN
        start_pos := i;
        depth := 1;
        in_str := false;
        esc := false;
      END IF;
    ELSE
      IF in_str THEN
        IF esc THEN
          esc := false;
        ELSIF ch = E'\\' THEN
          esc := true;
        ELSIF ch = '"' THEN
          in_str := false;
        END IF;
      ELSE
        IF ch = '"' THEN
          in_str := true;
        ELSIF ch = '{' THEN
          depth := depth + 1;
        ELSIF ch = '}' THEN
          depth := depth - 1;
          IF depth = 0 THEN
            chunk := substr(p_text, start_pos, i - start_pos + 1);
            BEGIN
              RETURN chunk::jsonb;
            EXCEPTION WHEN others THEN
              start_pos := 0;
            END;
          END IF;
        END IF;
      END IF;
    END IF;
  END LOOP;
  RETURN NULL;
END;
$fn$;

CREATE OR REPLACE FUNCTION allgres_private.log_content_text(p jsonb)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $fn$
  SELECT CASE
    WHEN p IS NULL THEN ''
    WHEN jsonb_typeof(p) = 'string' THEN p #>> '{}'
    ELSE p::text
  END
$fn$;

CREATE OR REPLACE FUNCTION allgres_private.append_log(
  p_task_id uuid,
  p_step int,
  p_role text,
  p_content jsonb
) RETURNS void
LANGUAGE sql
AS $fn$
  INSERT INTO allgres_private.execution_logs (task_id, step_number, role, content)
  VALUES (p_task_id, p_step, p_role, p_content)
$fn$;

CREATE OR REPLACE FUNCTION allgres_private.maybe_complete_session(p_session_id uuid)
RETURNS void
LANGUAGE plpgsql
AS $fn$
DECLARE
  v_open int;
  v_failed int;
  v_answer text;
BEGIN
  SELECT
    count(*) FILTER (WHERE status IN ('queued', 'running', 'waiting_human', 'waiting_children')),
    count(*) FILTER (WHERE status = 'failed')
  INTO v_open, v_failed
  FROM allgres_private.tasks
  WHERE session_id = p_session_id;

  IF v_open > 0 THEN
    RETURN;
  END IF;

  SELECT t.output->>'answer'
  INTO v_answer
  FROM allgres_private.tasks t
  WHERE t.session_id = p_session_id
    AND t.status = 'completed'
    AND t.parent_task_id IS NULL
  ORDER BY t.updated_at DESC
  LIMIT 1;

  IF v_failed > 0 AND v_answer IS NULL THEN
    UPDATE allgres_private.sessions
    SET status = 'failed', completed_at = now()
    WHERE session_id = p_session_id AND status = 'open';
  ELSE
    UPDATE allgres_private.sessions
    SET status = 'completed',
        final_answer = COALESCE(v_answer, final_answer),
        completed_at = now()
    WHERE session_id = p_session_id AND status = 'open';
  END IF;
END;
$fn$;

-- Roadmap item 7: the one evaluation signal this slice computes -- an
-- agent's own recent completed-vs-failed ratio, over its last p_limit
-- root-level tasks (parent_task_id IS NULL: a delegated child reflects
-- whatever agent it was delegated *to*, not this one, and counting it here
-- would blur the two; the same root-level distinction fn_next_step's own
-- message assembly already draws). Deliberately not a lifetime average --
-- an agent that was bad for its first 500 tasks and has been solid for its
-- last 20 should read as solid, not dragged down by history a since-fixed
-- problem no longer reflects. selftest's own fixture sessions are excluded
-- the same way every operator-facing count already excludes them
-- (goal LIKE 'selftest%'). NULL (not zero) when there is no evaluable data
-- yet -- a brand-new agent, or one whose only tasks are still open -- so a
-- caller can tell "nothing to judge yet" from "judged and found wanting."
CREATE OR REPLACE FUNCTION allgres_private.agent_recent_success_rate(p_agent_id uuid, p_limit int DEFAULT 20)
RETURNS numeric
LANGUAGE sql
STABLE
AS $fn$
  SELECT CASE WHEN count(*) FILTER (WHERE q.status IN ('completed', 'failed')) = 0 THEN NULL
    ELSE round(
      count(*) FILTER (WHERE q.status = 'completed')::numeric
        / count(*) FILTER (WHERE q.status IN ('completed', 'failed')),
      3
    )
  END
  FROM (
    SELECT t.status
    FROM allgres_private.tasks t
    JOIN allgres_private.sessions s ON s.session_id = t.session_id
    WHERE t.agent_id = p_agent_id
      AND t.parent_task_id IS NULL
      AND s.goal NOT LIKE 'selftest%'
    ORDER BY t.created_at DESC
    LIMIT GREATEST(1, COALESCE(p_limit, 20))
  ) q
$fn$;

-- Same completed/failed ratio as agent_recent_success_rate above, scoped
-- to exactly the root tasks that ran under one specific policy generation
-- (tasks.policy_generation -- see that column's own comment) instead of
-- "whichever N tasks happen to be most recent regardless of which policy
-- produced them." fn_evaluate_last_change uses this for both sides of its
-- before/after comparison so a change's real outcome is never smeared
-- together with the policy it replaced (or the one that replaced it).
-- Returns a NULL rate with sample_size = 0 for a generation with no
-- evaluable root tasks yet -- never a manufactured 0%, same convention as
-- agent_recent_success_rate.
CREATE OR REPLACE FUNCTION allgres_private.agent_success_rate_for_generation(
  p_agent_id uuid, p_generation int, p_limit int DEFAULT 20
) RETURNS TABLE(rate numeric, sample_size int)
LANGUAGE sql
STABLE
AS $fn$
  SELECT
    CASE WHEN count(*) FILTER (WHERE q.status IN ('completed', 'failed')) = 0 THEN NULL
      ELSE round(
        count(*) FILTER (WHERE q.status = 'completed')::numeric
          / count(*) FILTER (WHERE q.status IN ('completed', 'failed')),
        3
      )
    END,
    count(*) FILTER (WHERE q.status IN ('completed', 'failed'))::int
  FROM (
    SELECT t.status
    FROM allgres_private.tasks t
    JOIN allgres_private.sessions s ON s.session_id = t.session_id
    WHERE t.agent_id = p_agent_id
      AND t.parent_task_id IS NULL
      AND t.policy_generation = p_generation
      AND s.goal NOT LIKE 'selftest%'
    ORDER BY t.created_at DESC
    LIMIT GREATEST(1, COALESCE(p_limit, 20))
  ) q
$fn$;

-- Authorisation for agent-visible views lives in the views, so it holds even if
-- the statement analysis in fn_validate_sql misses a reference.  An agent that
-- reaches a view it has no permission for sees no rows rather than a leak.
-- Takes the agent_id as a parameter rather than calling
-- current_agent_id() itself: this function has to be SECURITY DEFINER (it
-- reads allgres_private.permissions and sql_sandbox_allowlist, which
-- `sandbox` and per-agent roles have no direct grant on), and SECURITY
-- DEFINER changes current_user -- to this function's *owner* -- for
-- everything it calls internally too. current_agent_id() has to run
-- before that boundary, in the caller's own context, to see the real
-- querying role at all; see its own comment for the live-confirmed
-- failure this caused when it was called from in here instead. Every
-- caller (v_my_tasks / v_sales below) calls current_agent_id() itself and
-- passes the result in.
CREATE OR REPLACE FUNCTION allgres_private.agent_may_read(p_ref text, p_agent_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = allgres_private, pg_temp
AS $fn$
  SELECT p_agent_id IS NOT NULL
     AND EXISTS (
       SELECT 1 FROM allgres_private.sql_sandbox_allowlist a
       WHERE a.resource_ref = p_ref
     )
     AND allgres_private.agent_has_permission(p_agent_id, 'view', p_ref)
$fn$;

CREATE OR REPLACE VIEW allgres_public.v_my_tasks
  WITH (security_barrier = true)
AS
  SELECT
    task_id,
    session_id,
    status,
    step_count,
    created_at,
    updated_at
  FROM allgres_private.tasks
  WHERE agent_id IS NOT DISTINCT FROM allgres_private.current_agent_id()
    AND allgres_private.agent_may_read('allgres_public.v_my_tasks', allgres_private.current_agent_id());

CREATE OR REPLACE VIEW allgres_public.v_sales
  WITH (security_barrier = true)
AS
  SELECT sale_id, region, sku, amount, sold_on
  FROM allgres_private.demo_sales
  WHERE agent_id IS NOT DISTINCT FROM allgres_private.current_agent_id()
    AND allgres_private.agent_may_read('allgres_public.v_sales', allgres_private.current_agent_id());

-- Read-only diagnostic views for a maintenance/auditor agent (README,
-- "Maintenance agents"). Same permission-gated shape as v_sales/
-- v_my_tasks, but with no agent_id ownership column to filter rows by --
-- these describe the system as a whole, not any one agent's own data, so
-- agent_may_read alone decides visibility: an agent without the grant sees
-- zero rows (a bare SELECT with no FROM clause and a false WHERE returns
-- none, the same as any other filtered query), an agent with it sees the
-- same picture every other agent holding the grant would -- there is
-- nothing per-agent to scope further.
CREATE OR REPLACE VIEW allgres_public.v_system_health
  WITH (security_barrier = true)
AS
  SELECT
    -- Same caveat as the dashboard's own Workers panel (KNOWN_ISSUES.md,
    -- item 5): `allgres web` deliberately has no database connection, so a
    -- background worker without one never appears in pg_stat_activity at
    -- all -- this reads as "1 worker online" even when both are healthy,
    -- not a sign the web worker is down.
    (SELECT count(*) FROM pg_stat_activity WHERE backend_type IN ('allgres runtime', 'allgres web')) AS workers_online,
    (SELECT count(*) FROM allgres_private.outbound_calls WHERE status = 'queued') AS outbound_queued,
    (SELECT count(*) FROM allgres_private.outbound_calls WHERE status = 'in_flight') AS outbound_in_flight,
    (SELECT count(*) FROM allgres_private.sql_calls WHERE status = 'queued') AS sql_queued,
    (SELECT count(*) FROM allgres_private.sql_calls WHERE status = 'in_flight') AS sql_in_flight,
    (SELECT count(*) FROM allgres_private.oauth_calls WHERE status = 'queued') AS oauth_queued,
    (SELECT count(*) FROM allgres_private.tasks WHERE status IN ('queued', 'running', 'waiting_human', 'waiting_children')) AS running_tasks,
    (SELECT count(*) FROM allgres_private.tasks WHERE status = 'failed' AND updated_at > now() - interval '24 hours') AS failed_tasks_24h,
    (SELECT count(*) FROM allgres_private.human_approvals WHERE status = 'pending') AS pending_approvals,
    (SELECT count(*) FROM allgres_private.agent_memories WHERE expires_at IS NOT NULL AND expires_at < now()) AS expired_memories_pending
  WHERE allgres_private.agent_may_read('allgres_public.v_system_health', allgres_private.current_agent_id());

-- Roadmap item 7: per-agent evaluation data (allgres_private.
-- agent_recent_success_rate's own comment explains the metric itself).
-- Same permission-gated shape as v_system_health -- an agent without the
-- grant sees zero rows -- but per-row rather than a single aggregate, since
-- this describes each agent individually, the comparison self_improve (or
-- an operator) actually needs before proposing or judging a change.
CREATE OR REPLACE VIEW allgres_public.v_agent_health
  WITH (security_barrier = true)
AS
  SELECT
    a.agent_id,
    a.name,
    p.generation,
    allgres_private.agent_recent_success_rate(a.agent_id, 20) AS recent_success_rate,
    (
      SELECT h.success_rate_at_change
      FROM allgres_private.policy_history h
      WHERE h.agent_id = a.agent_id
      ORDER BY h.generation DESC
      LIMIT 1
    ) AS success_rate_before_last_change
  FROM allgres_private.agents a
  JOIN allgres_private.policies p USING (agent_id)
  WHERE a.is_active
    AND allgres_private.agent_may_read('allgres_public.v_agent_health', allgres_private.current_agent_id());

-- One row per (agent, resource) grant -- the full permission matrix a
-- security-auditor agent needs to spot an anomaly (an inactive agent still
-- holding grants, an unusually broad http_host, a permission nobody has
-- used).  Nothing here is secret: names, resource types and refs, and
-- when a grant was made -- never a credential.
CREATE OR REPLACE VIEW allgres_public.v_permission_audit
  WITH (security_barrier = true)
AS
  SELECT
    a.agent_id,
    a.name AS agent_name,
    a.is_active AS agent_is_active,
    p.resource_type,
    p.resource_ref,
    p.granted_at
  FROM allgres_private.permissions p
  JOIN allgres_private.agents a USING (agent_id)
  WHERE allgres_private.agent_may_read('allgres_public.v_permission_audit', allgres_private.current_agent_id());

-- ---------------------------------------------------------------------------
-- 4. Outbound URL / host guards.
--
-- One implementation, used by every outbound path: the LLM endpoint, the
-- http_get tool, and the OAuth token exchange.  Previously only http_get was
-- guarded, so an operator-set (or dashboard-set) provider base_url could reach
-- link-local metadata services with the provider credentials attached.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION allgres_private.url_host(p_url text)
RETURNS text
LANGUAGE plpgsql
IMMUTABLE
AS $fn$
DECLARE
  v_auth text;
  v_host text;
BEGIN
  IF p_url IS NULL THEN
    RETURN NULL;
  END IF;
  -- Whitespace or control characters mean the URL was built by string
  -- concatenation somewhere; refuse to guess what a client would parse.
  IF p_url ~ '[[:space:][:cntrl:]]' THEN
    RETURN NULL;
  END IF;

  v_auth := (regexp_match(p_url, '^[a-zA-Z][a-zA-Z0-9+.-]*://([^/?#]*)'))[1];
  IF v_auth IS NULL OR v_auth = '' THEN
    RETURN NULL;
  END IF;

  -- userinfo@host is the classic host-confusion trick; different parsers pick
  -- different hosts.  Refuse the whole URL rather than pick one.
  IF position('@' IN v_auth) > 0 THEN
    RETURN NULL;
  END IF;

  IF left(v_auth, 1) = '[' THEN
    v_host := split_part(substring(v_auth from 2), ']', 1);
  ELSE
    v_host := v_auth;
    -- A single colon is host:port.  More than one means a bare IPv6 literal.
    IF length(v_host) - length(replace(v_host, ':', '')) = 1 THEN
      v_host := split_part(v_host, ':', 1);
    END IF;
  END IF;

  v_host := lower(regexp_replace(btrim(v_host), '\.$', ''));
  RETURN nullif(v_host, '');
END;
$fn$;

CREATE OR REPLACE FUNCTION allgres_private.is_blocked_host(p_host text)
RETURNS boolean
LANGUAGE plpgsql
IMMUTABLE
AS $fn$
DECLARE
  h  text := lower(coalesce(p_host, ''));
  v4 text;
BEGIN
  IF h = '' THEN
    RETURN true;
  END IF;

  -- IPv4-mapped / -compatible IPv6 (::ffff:127.0.0.1) reduces to its IPv4 part.
  v4 := (regexp_match(h, '^::(ffff:)?([0-9]{1,3}(\.[0-9]{1,3}){3})$'))[2];
  IF v4 IS NOT NULL THEN
    RETURN allgres_private.is_blocked_host(v4);
  END IF;

  -- Non dotted-quad spellings of an IPv4 address (2130706433, 0x7f000001,
  -- 0177.0.0.1) all resolve to the same place but dodge dotted-quad regexes.
  IF h ~ '^[0-9]+$' OR h ~ '^0x[0-9a-f]+$' OR h ~ '^0[0-7]*(\.|$)' THEN
    RETURN true;
  END IF;

  IF h IN ('localhost', 'localhost.localdomain', 'ip6-localhost', 'ip6-loopback') THEN
    RETURN true;
  END IF;
  IF h ~ '(^|\.)(local|localhost|internal|intranet|corp|home|lan)$' THEN
    RETURN true;
  END IF;

  -- IPv6
  IF h IN ('::', '::1') THEN
    RETURN true;
  END IF;
  IF h ~ '^f[cd][0-9a-f]{2}:' THEN          -- fc00::/7  unique local
    RETURN true;
  END IF;
  IF h ~ '^fe[89ab][0-9a-f]:' THEN          -- fe80::/10 link local
    RETURN true;
  END IF;

  -- IPv4 literals
  IF h ~ '^[0-9]{1,3}(\.[0-9]{1,3}){3}$' THEN
    RETURN h ~ '^(0|10|127)\.'
        OR h ~ '^169\.254\.'
        OR h ~ '^172\.(1[6-9]|2[0-9]|3[01])\.'
        OR h ~ '^192\.168\.'
        OR h ~ '^192\.0\.[02]\.'
        OR h ~ '^198\.1[89]\.'
        OR h ~ '^100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.'   -- CGNAT 100.64/10
        OR h ~ '^(22[4-9]|2[3-5][0-9])\.'                          -- multicast + reserved
        OR h = '255.255.255.255';
  END IF;

  RETURN false;
END;
$fn$;

-- Returns NULL when the URL may be fetched, otherwise a short machine-readable
-- reason.  p_allow_private is the per-provider opt-in for loopback/RFC1918.
CREATE OR REPLACE FUNCTION allgres_private.check_outbound_url(
  p_url text,
  p_allow_private boolean DEFAULT false
) RETURNS text
LANGUAGE plpgsql
IMMUTABLE
AS $fn$
DECLARE
  v_scheme text;
  v_host   text;
BEGIN
  IF p_url IS NULL OR btrim(p_url) = '' THEN
    RETURN 'missing_url';
  END IF;
  IF p_url ~ '[[:space:][:cntrl:]]' THEN
    RETURN 'url_has_control_characters';
  END IF;

  v_scheme := lower(coalesce((regexp_match(p_url, '^([a-zA-Z][a-zA-Z0-9+.-]*)://'))[1], ''));
  IF v_scheme = '' THEN
    RETURN 'url_missing_scheme';
  END IF;
  IF v_scheme NOT IN ('http', 'https') THEN
    RETURN 'scheme_not_allowed';
  END IF;
  IF v_scheme = 'http' AND NOT coalesce(p_allow_private, false) THEN
    RETURN 'plaintext_http_not_allowed';
  END IF;

  v_host := allgres_private.url_host(p_url);
  IF v_host IS NULL THEN
    RETURN 'url_host_unparseable';
  END IF;
  IF allgres_private.is_blocked_host(v_host) AND NOT coalesce(p_allow_private, false) THEN
    RETURN 'host_blocked';
  END IF;

  RETURN NULL;
END;
$fn$;

-- ---------------------------------------------------------------------------
-- 5. Provider secret storage.
--
-- Secrets are encrypted at rest with pgcrypto when both pgcrypto is installed
-- and `allgres.secret_key` is set in postgresql.conf.  Without a key they fall
-- back to plaintext, and settings.get reports which mode is in effect so the
-- dashboard can say so out loud instead of implying protection that is not
-- there.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION allgres_private.secret_key()
RETURNS text
LANGUAGE sql
STABLE
AS $fn$
  SELECT nullif(current_setting('allgres.secret_key', true), '')
$fn$;

-- pgcrypto can be installed into any schema, and the callers here run with a
-- restricted search_path, so its schema is resolved rather than assumed.  An
-- earlier version called `pgp_sym_encrypt` unqualified, failed to resolve it,
-- and silently fell back to storing the secret in plaintext while still
-- reporting "encrypted".
CREATE OR REPLACE FUNCTION allgres_private.pgcrypto_schema()
RETURNS text
LANGUAGE sql
STABLE
AS $fn$
  SELECT n.nspname
  FROM pg_catalog.pg_proc p
  JOIN pg_catalog.pg_namespace n ON n.oid = p.pronamespace
  WHERE p.proname = 'pgp_sym_encrypt'
  LIMIT 1
$fn$;

CREATE OR REPLACE FUNCTION allgres_private.encrypt_secret(p_plain text)
RETURNS text
LANGUAGE plpgsql
AS $fn$
DECLARE
  v_key text := allgres_private.secret_key();
  v_ns  text := allgres_private.pgcrypto_schema();
  v_out text;
BEGIN
  IF p_plain IS NULL OR p_plain = '' THEN
    RETURN NULL;
  END IF;

  -- No key configured is a deliberate choice, and the dashboard reports it.
  IF v_key IS NULL THEN
    RETURN p_plain;
  END IF;

  -- A key configured but no pgcrypto is a misconfiguration.  Fail loudly:
  -- storing a secret in plaintext when the operator asked for encryption is
  -- worse than refusing to store it.
  IF v_ns IS NULL THEN
    RAISE EXCEPTION 'allgres.secret_key is set but pgcrypto is not installed'
      USING ERRCODE = 'P0001';
  END IF;

  EXECUTE format('SELECT %I.armor(%I.pgp_sym_encrypt($1, $2))', v_ns, v_ns)
    INTO v_out USING p_plain, v_key;
  RETURN 'enc:v1:' || v_out;
END;
$fn$;

CREATE OR REPLACE FUNCTION allgres_private.decrypt_secret(p_stored text)
RETURNS text
LANGUAGE plpgsql
AS $fn$
DECLARE
  v_key text := allgres_private.secret_key();
  v_ns  text := allgres_private.pgcrypto_schema();
  v_out text;
BEGIN
  IF p_stored IS NULL THEN
    RETURN NULL;
  END IF;
  IF left(p_stored, 7) <> 'enc:v1:' THEN
    RETURN p_stored;
  END IF;
  IF v_key IS NULL OR v_ns IS NULL THEN
    RETURN NULL;
  END IF;
  BEGIN
    EXECUTE format('SELECT %I.pgp_sym_decrypt(%I.dearmor($1), $2)', v_ns, v_ns)
      INTO v_out USING substr(p_stored, 8), v_key;
    RETURN v_out;
  EXCEPTION WHEN others THEN
    -- Wrong key, or ciphertext from a previous key.
    RETURN NULL;
  END;
END;
$fn$;

-- Reports what the next write would actually do, by doing it.  Checking only
-- that pgp_sym_encrypt exists somewhere is how the previous version came to
-- report "encrypted" while storing plaintext.
CREATE OR REPLACE FUNCTION allgres_private.secret_storage_mode()
RETURNS text
LANGUAGE plpgsql
STABLE
AS $fn$
DECLARE
  v_probe text;
BEGIN
  IF allgres_private.secret_key() IS NULL THEN
    RETURN 'plaintext_no_key';
  END IF;
  IF allgres_private.pgcrypto_schema() IS NULL THEN
    RETURN 'plaintext_no_pgcrypto';
  END IF;
  BEGIN
    v_probe := allgres_private.encrypt_secret('allgres-probe');
  EXCEPTION WHEN others THEN
    RETURN 'plaintext_encrypt_failed';
  END;
  IF v_probe IS NULL OR left(v_probe, 7) <> 'enc:v1:' THEN
    RETURN 'plaintext_encrypt_failed';
  END IF;
  IF allgres_private.decrypt_secret(v_probe) IS DISTINCT FROM 'allgres-probe' THEN
    RETURN 'encrypted_but_not_readable';
  END IF;
  RETURN 'encrypted';
END;
$fn$;

CREATE OR REPLACE FUNCTION allgres_private.provider_secret(p_provider_id uuid)
RETURNS text
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = allgres_private, pg_temp
AS $fn$
  SELECT allgres_private.decrypt_secret(api_key)
  FROM allgres_private.llm_secrets
  WHERE provider_id = p_provider_id
$fn$;

-- Same shape as provider_secret, for the OAuth client secret instead of the
-- api_key column. Used only by fn_claim_oauth, at claim time -- never at
-- queue time (fn_oauth_token_request), which is what keeps it out of
-- oauth_calls.request_body.
CREATE OR REPLACE FUNCTION allgres_private.oauth_client_secret(p_provider_id uuid)
RETURNS text
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = allgres_private, pg_temp
AS $fn$
  SELECT allgres_private.decrypt_secret(oauth_client_secret)
  FROM allgres_private.llm_secrets
  WHERE provider_id = p_provider_id
$fn$;

-- Same shape as provider_secret, for allgres_private.api_connections. Used
-- only by fn_claim_outbound, at claim time -- never at queue time, which is
-- what keeps it out of outbound_calls.request_headers.
CREATE OR REPLACE FUNCTION allgres_private.connection_secret(p_connection_id uuid)
RETURNS text
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = allgres_private, pg_temp
AS $fn$
  SELECT allgres_private.decrypt_secret(api_key)
  FROM allgres_private.api_connection_secrets
  WHERE connection_id = p_connection_id
$fn$;

-- ---------------------------------------------------------------------------
-- 6. SQL sandbox.
--
-- What an agent statement is allowed to touch is decided from PostgreSQL's own
-- parse tree (allgres.analyze_sql -> raw_parser), not from pattern matching the
-- statement text.  The previous regex layer had to re-implement lexing, and
-- comment injection, quoted identifiers, comma joins and `extract(x FROM y)`
-- were all ways for it to be wrong in one direction or the other.
--
-- A note on the `sandbox` role, because the obvious design does not work:
-- PostgreSQL refuses `SET ROLE` inside a security-definer function ("cannot set
-- parameter \"role\" within security-definer function", SQLSTATE 42501), and the
-- restriction covers the whole call stack below one.  This function is
-- SECURITY DEFINER (it needs to read allgres_private.permissions and pg_proc
-- regardless of who is asking), so it cannot itself drop to an unprivileged
-- role.  Earlier versions of this file tried anyway and turned the failure
-- into "sandbox role unavailable", which meant execute_sql never worked at
-- all.
--
-- The fix is the split below: this function only validates and returns the
-- normalized statement text; it executes nothing.  The runtime worker queues
-- that text in allgres_private.sql_calls (fn_claim_sql / fn_complete_sql, the
-- same claim/complete shape the outbound HTTP pump uses for LLM and tool
-- calls), then runs it as a *top-level* SPI statement -- issued directly by
-- the worker, not nested inside any SECURITY DEFINER function -- where
-- `SET LOCAL ROLE sandbox` is legal.  See allgres_public.fn_run_sandboxed_sql
-- below and src/lib.rs's `run_sandboxed_sql`.
--
-- Layering, strongest first:
--   a. the statement only ever executes as `sandbox`, never as this
--      function's owner;
--   b. search_path = pg_temp, so an unqualified relation name cannot resolve
--      to anything at all;
--   c. the views themselves return no rows unless the current agent holds the
--      matching permission (allgres_private.agent_may_read), so authorisation
--      does not depend on the analysis below being complete;
--   d. transaction_read_only + statement_timeout, both real now that
--      execution is a top-level statement instead of nested inside one;
--   e. only non-volatile functions, checked against pg_proc — volatility is
--      what separates a read from a side effect;
--   f. the parse tree must be exactly one non-writing SELECT;
--   g. every relation it names must be schema-qualified, outside the reserved
--      schemas, and in allowlist n per-agent permission.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION allgres_private.fn_validate_sql(p_agent_id uuid, p_sql text)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = allgres_private, allgres_public, pg_temp
AS $fn$
DECLARE
  c_reserved constant text[] := ARRAY[
    'allgres_private', 'allgres', 'pg_catalog', 'pg_toast', 'information_schema'
  ];

  -- Volatility alone is not a security boundary: STABLE means "cannot change
  -- within one statement", not "safe to expose to an agent". current_setting
  -- is STABLE, and current_setting('allgres.secret_key', true) hands the key
  -- that encrypts every provider secret in the system straight back as a SQL
  -- result -- confirmed by actually running it under the sandbox role. This
  -- denylist blocks the pg_catalog functions that disclose configuration,
  -- session, or process state despite being non-volatile; the namespace and
  -- prosecdef checks below close the same gap for anything not built in.
  c_denied_fns constant text[] := ARRAY[
    'current_setting', 'set_config',
    'current_database', 'current_catalog', 'current_schema', 'current_schemas',
    'current_user', 'session_user',
    'inet_client_addr', 'inet_client_port', 'inet_server_addr', 'inet_server_port',
    'pg_backend_pid', 'pg_postmaster_start_time', 'pg_conf_load_time',
    'pg_trigger_depth', 'pg_is_in_recovery',
    'version',
    'txid_current', 'txid_current_snapshot', 'txid_status',
    'txid_snapshot_xmin', 'txid_snapshot_xmax', 'txid_snapshot_xip',
    'pg_current_xact_id', 'pg_current_xact_id_if_assigned', 'pg_current_snapshot',
    'pg_last_wal_receive_lsn', 'pg_last_wal_replay_lsn', 'pg_last_xact_replay_timestamp'
  ];

  v_sql      text;
  v_tree     jsonb;
  v_ctes     text[];
  v_rel      jsonb;
  v_fn       jsonb;
  v_safe_fns int;
  v_all_fns  int;
  v_schema   text;
  v_ref      text;
  v_ok       boolean;
  v_plan     json;
  v_cost     numeric;
BEGIN
  PERFORM set_config('statement_timeout', '5000', true);

  v_sql := btrim(coalesce(p_sql, ''));
  -- The statement is wrapped in a subquery below, so a trailing terminator has
  -- to go even though the parser itself tolerates it.
  v_sql := regexp_replace(v_sql, ';+\s*$', '');
  IF v_sql = '' THEN
    RAISE EXCEPTION 'fn_validate_sql: empty sql' USING ERRCODE = 'P0001';
  END IF;
  IF length(v_sql) > 8000 THEN
    RAISE EXCEPTION 'fn_validate_sql: statement too long' USING ERRCODE = 'P0001';
  END IF;

  -- Parse only: no planning, no rewriting, no execution.  A syntax error
  -- surfaces here as an ordinary exception.
  BEGIN
    v_tree := allgres.analyze_sql(v_sql);
  EXCEPTION WHEN others THEN
    RAISE EXCEPTION 'fn_validate_sql: not parseable as SQL: %', SQLERRM
      USING ERRCODE = 'P0001';
  END;

  IF NOT COALESCE((v_tree->>'ok')::boolean, false) THEN
    RAISE EXCEPTION 'fn_validate_sql: statement could not be analysed'
      USING ERRCODE = 'P0001';
  END IF;

  IF (v_tree->>'statements')::int <> 1 THEN
    RAISE EXCEPTION 'fn_validate_sql: expected one statement, found %',
      v_tree->>'statements' USING ERRCODE = 'P0001';
  END IF;

  IF v_tree->>'kind' <> 'select' THEN
    RAISE EXCEPTION 'fn_validate_sql: only SELECT / WITH ... SELECT is allowed'
      USING ERRCODE = 'P0001';
  END IF;

  -- Covers SELECT ... INTO and data-modifying CTEs, both of which parse as a
  -- SelectStmt and both of which write.
  IF COALESCE((v_tree->>'writes')::boolean, false) THEN
    RAISE EXCEPTION 'fn_validate_sql: statement writes; only reads are allowed'
      USING ERRCODE = 'P0001';
  END IF;

  SELECT coalesce(array_agg(value #>> '{}'), '{}')
  INTO v_ctes
  FROM jsonb_array_elements(COALESCE(v_tree->'ctes', '[]'::jsonb));

  FOR v_rel IN SELECT jsonb_array_elements(COALESCE(v_tree->'relations', '[]'::jsonb)) LOOP
    v_schema := v_rel->>'schema';

    IF v_schema IS NULL THEN
      -- The parser cannot tell a CTE reference from a table reference; the CTE
      -- list it returns is what disambiguates them.
      CONTINUE WHEN (v_rel->>'name') = ANY (v_ctes);
      RAISE EXCEPTION 'fn_validate_sql: unqualified name "%" rejected', v_rel->>'name'
        USING ERRCODE = 'P0001';
    END IF;

    IF lower(v_schema) = ANY (c_reserved) OR lower(v_schema) LIKE 'pg\_%' THEN
      RAISE EXCEPTION 'fn_validate_sql: schema "%" is not readable by agents', v_schema
        USING ERRCODE = 'P0001';
    END IF;

    v_ref := v_schema || '.' || (v_rel->>'name');
    SELECT EXISTS (
      SELECT 1 FROM allgres_private.sql_sandbox_allowlist a
      WHERE a.resource_ref = v_ref
    ) AND allgres_private.agent_has_permission(p_agent_id, 'view', v_ref)
    INTO v_ok;
    IF NOT v_ok THEN
      RAISE EXCEPTION 'fn_validate_sql: "%" not in allowlist', v_ref
        USING ERRCODE = 'P0001';
    END IF;
  END LOOP;

  -- A function must be on the sql_function_allowlist AND pass every other
  -- gate: pg_catalog only -- an agent can never call a user-defined
  -- function, which rules out every SECURITY DEFINER function Allgres
  -- itself ships (they run as this validator's owner, not as `sandbox`, and
  -- were never meant to be agent-callable) and every extension function
  -- such as pgcrypto's or dblink's; non-volatile, which is what actually
  -- separates a read from a side effect (pg_read_file, pg_ls_dir,
  -- lo_import, dblink, nextval and pg_sleep are all volatile); NOT
  -- prosecdef, as defense in depth in case a future pg_catalog entry is
  -- ever security-definer; and not on the explicit denylist, as one more
  -- backstop in case the allowlist is ever seeded with a mistake. The
  -- allowlist is the one that actually matters, though: a denylist can only
  -- ever name what is already known to be dangerous, and pg_catalog has
  -- hundreds of functions that are STABLE, non-security-definer, and
  -- unnamed by any reasonable denylist -- pg_show_all_settings() among
  -- them, which returns every GUC on the server. Default-deny throughout:
  -- an unknown name, or one that fails any gate, is rejected rather than
  -- assumed safe.
  FOR v_fn IN SELECT jsonb_array_elements(COALESCE(v_tree->'functions', '[]'::jsonb)) LOOP
    IF lower(v_fn->>'name') = ANY (c_denied_fns) THEN
      RAISE EXCEPTION 'fn_validate_sql: function "%" is not allowed', v_fn->>'name'
        USING ERRCODE = 'P0001';
    END IF;
    IF NOT EXISTS (
      SELECT 1 FROM allgres_private.sql_function_allowlist
      WHERE function_name = lower(v_fn->>'name')
    ) THEN
      RAISE EXCEPTION 'fn_validate_sql: function "%" is not in the sandbox allowlist', v_fn->>'name'
        USING ERRCODE = 'P0001';
    END IF;

    -- An unqualified call in this check's own denominator must only ever
    -- be counted against pg_catalog, never every namespace in the
    -- database: `sandbox` (the role every agent SQL statement actually
    -- runs as) has search_path = pg_temp, so pg_catalog -- always searched
    -- implicitly regardless of search_path -- is the *only* place a bare
    -- name can resolve at execution time. Before this, an unqualified
    -- name was checked against every schema's same-named overload
    -- (v_fn->>'schema' IS NULL matched all of them), which made a
    -- genuinely safe, pg_catalog-only call like plain `sum(amount)` fail
    -- this check the moment any *other* extension defined its own
    -- same-named overload in its own schema -- pgvector's own sum(vector)/
    -- avg(vector) aggregates are exactly this, and could never actually be
    -- reached by a sandboxed query in the first place, since `public` is
    -- not in sandbox's search_path either.
    SELECT count(*) FILTER (WHERE p.provolatile <> 'v' AND NOT p.prosecdef),
           count(*)
    INTO v_safe_fns, v_all_fns
    FROM pg_catalog.pg_proc p
    JOIN pg_catalog.pg_namespace n ON n.oid = p.pronamespace
    WHERE p.proname = (v_fn->>'name')
      AND n.nspname = COALESCE(v_fn->>'schema', 'pg_catalog');

    IF v_all_fns = 0 THEN
      RAISE EXCEPTION 'fn_validate_sql: unknown function "%"', v_fn->>'name'
        USING ERRCODE = 'P0001';
    END IF;
    IF v_safe_fns <> v_all_fns THEN
      RAISE EXCEPTION 'fn_validate_sql: function "%" is volatile, security-definer, or not a pg_catalog builtin, and not allowed', v_fn->>'name'
        USING ERRCODE = 'P0001';
    END IF;
  END LOOP;

  -- Cost estimation only: no rows are fetched here, so this can safely run as
  -- this function's owner rather than needing the `sandbox` role.
  BEGIN
    EXECUTE 'EXPLAIN (FORMAT JSON) ' || v_sql INTO v_plan;
  EXCEPTION WHEN others THEN
    RAISE EXCEPTION 'fn_validate_sql: engine rejected query: %', SQLERRM
      USING ERRCODE = 'P0001';
  END;

  v_cost := (v_plan->0->'Plan'->>'Total Cost')::numeric;
  IF v_cost > 20000000 THEN
    RAISE EXCEPTION 'fn_validate_sql: estimated cost % is too high', round(v_cost)
      USING ERRCODE = 'P0001';
  END IF;

  -- Normalized, parser-confirmed text: exactly one complete non-writing
  -- SELECT, safe for the caller to queue and later wrap in a subquery.
  RETURN v_sql;
END;
$fn$;

-- Executes one already-validated statement as the `sandbox` role and shapes
-- its result.  Deliberately not SECURITY DEFINER: it must run as whatever
-- role the caller currently is, which is only ever `sandbox` because nothing
-- but the runtime worker's top-level `SET LOCAL ROLE sandbox` (see
-- src/lib.rs's `run_sandboxed_sql`) is granted EXECUTE on it -- see the grants
-- section.  p_sql is trusted here precisely because it can only have reached
-- this function by way of fn_validate_sql's return value.
CREATE OR REPLACE FUNCTION allgres_public.fn_run_sandboxed_sql(p_sql text)
RETURNS jsonb
LANGUAGE plpgsql
AS $fn$
DECLARE
  v_rows      jsonb;
  v_n         int;
  v_truncated boolean := false;
BEGIN
  -- Safe to wrap in a subquery: fn_validate_sql already confirmed p_sql is
  -- one complete SELECT, so it cannot terminate the enclosing expression.
  BEGIN
    EXECUTE 'SELECT coalesce(jsonb_agg(q.row), ''[]''::jsonb) FROM (SELECT to_jsonb(s) AS row FROM ('
      || p_sql
      || ') s LIMIT 201) q'
      INTO v_rows;
  EXCEPTION WHEN others THEN
    RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
  END;

  v_n := coalesce(jsonb_array_length(v_rows), 0);
  IF v_n > 200 THEN
    v_rows := (SELECT jsonb_agg(x) FROM jsonb_array_elements(v_rows) WITH ORDINALITY e(x, n) WHERE n <= 200);
    v_truncated := true;
    v_n := 200;
  END IF;
  IF octet_length(v_rows::text) > 65536 THEN
    WHILE octet_length(v_rows::text) > 65536 AND jsonb_array_length(v_rows) > 1 LOOP
      v_rows := v_rows - (jsonb_array_length(v_rows) - 1);
      v_truncated := true;
    END LOOP;
    v_n := jsonb_array_length(v_rows);
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'row_count', v_n,
    'truncated', v_truncated,
    'rows', v_rows
  );
END;
$fn$;

-- ---------------------------------------------------------------------------
-- 7. Agent state machine.  Short transactions only; never waits on HTTP.
-- ---------------------------------------------------------------------------

-- Shared by the agent's own `remember` action (fn_submit_result) and the
-- operator-authored path (fn_remember / dashboard_rpc's memories.create):
-- same validation, same fixed 500-per-agent eviction, same insert. Returns
-- {ok:false, error:...} rather than raising, since the two callers handle a
-- rejected write differently (one logs an 'error' turn and continues the
-- task; the other just reports failure to the dashboard) -- this function
-- only decides whether the write is well-formed, not what happens next.
-- p_importance/p_expires_in_days are text, not real/int: casting either at
-- a call site (`(p_request->>'importance')::real`) throws immediately on a
-- malformed value, before this function's own defensive handling ever runs
-- -- an agent-controlled string has to be parsed *inside* the guarded block
-- that decides what to do when it doesn't parse, not before it.
CREATE OR REPLACE FUNCTION allgres_private.write_memory(
  p_agent_id uuid,
  p_content text,
  p_memory_type text,
  p_importance text,
  p_subject_id text,
  p_expires_in_days text,
  p_source_session_id uuid DEFAULT NULL,
  p_source_task_id uuid DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = allgres_private, pg_temp
AS $fn$
DECLARE
  v_content text;
  v_type text;
  v_importance real;
  v_expires timestamptz;
  v_memory uuid;
BEGIN
  v_content := btrim(COALESCE(p_content, ''));
  IF v_content = '' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'empty_content');
  END IF;

  v_type := COALESCE(NULLIF(p_memory_type, ''), 'semantic');
  IF v_type NOT IN ('semantic', 'episodic', 'preference', 'instruction', 'relationship', 'working') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_memory_type', 'memory_type', v_type);
  END IF;

  -- Malformed importance falls back to the default rather than rejecting
  -- the whole write -- it is a ranking hint, not a correctness constraint.
  BEGIN
    v_importance := LEAST(1.0, GREATEST(0.0, COALESCE(NULLIF(p_importance, '')::real, 0.5)));
  EXCEPTION WHEN others THEN
    v_importance := 0.5;
  END;

  v_expires := NULL;
  IF NULLIF(p_expires_in_days, '') IS NOT NULL THEN
    BEGIN
      v_expires := now() + make_interval(days => GREATEST(0, p_expires_in_days::int));
    EXCEPTION WHEN others THEN
      v_expires := NULL;
    END;
  END IF;

  INSERT INTO allgres_private.agent_memories (
    agent_id, subject_id, memory_type, content, importance,
    source_session_id, source_task_id, expires_at
  ) VALUES (
    p_agent_id, NULLIF(btrim(COALESCE(p_subject_id, '')), ''), v_type,
    left(v_content, 4000), v_importance, p_source_session_id, p_source_task_id, v_expires
  ) RETURNING memory_id INTO v_memory;

  PERFORM allgres_private.queue_memory_embedding(v_memory);

  -- Bounded working set: keeps the 500 most important (then most recent)
  -- rows and evicts the rest, rather than let the table (and every future
  -- prompt's memory block) grow without limit. Ordering DESC and OFFSET-ing
  -- past the keepers is deliberate: ORDER BY ... ASC OFFSET 500 would skip
  -- the 500 *least* important rows and delete everything after them --
  -- i.e. the important ones -- which is exactly backwards. 500 is a fixed
  -- constant for this slice, not an operator-configurable policy field --
  -- see item 25's own README note for the same kind of deliberate
  -- simplification.
  DELETE FROM allgres_private.agent_memories
  WHERE memory_id IN (
    SELECT memory_id FROM allgres_private.agent_memories
    WHERE agent_id = p_agent_id
    ORDER BY importance DESC, created_at DESC
    OFFSET 500
  );

  RETURN jsonb_build_object('ok', true, 'memory_id', v_memory, 'memory_type', v_type);
END;
$fn$;

CREATE OR REPLACE FUNCTION allgres_public.fn_next_step(p_task_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = allgres_private, allgres_public, pg_temp
AS $fn$
DECLARE
  t allgres_private.tasks%ROWTYPE;
  a allgres_private.agents%ROWTYPE;
  p allgres_private.policies%ROWTYPE;
  v_messages jsonb := '[]'::jsonb;
  v_log record;
  v_has_input boolean;
  v_views jsonb;
  v_tools jsonb;
  v_input_text text;
  v_cfg jsonb;
  v_memories jsonb;
  v_memory_ids uuid[];
  v_procedures jsonb;
  v_task_ids uuid[];
  v_compacted_before timestamptz;
  v_summary_text text;
  v_project_preset text;
BEGIN
  PERFORM set_config('statement_timeout', '2000', true);

  SELECT * INTO t
  FROM allgres_private.tasks
  WHERE task_id = p_task_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'fn_next_step: task not found' USING ERRCODE = 'P0001';
  END IF;

  IF t.status NOT IN ('queued', 'running') THEN
    RAISE EXCEPTION 'fn_next_step: status % not runnable', t.status
      USING ERRCODE = 'P0001';
  END IF;

  IF t.status = 'queued' THEN
    -- COALESCE, not a bare now(): a task revisits 'queued' every time it
    -- resumes from waiting_human (fn_decide_approval sets it back to
    -- 'queued'), and possibly other paths later. A bare assignment here
    -- would reset started_at on every resume, so max_turn_seconds would
    -- measure "time since most recently resumed" instead of "time since
    -- this task first started running" -- silently defeating the wall-clock
    -- ceiling for any task that ever waits on a human.
    UPDATE allgres_private.tasks
    SET status = 'running', started_at = COALESCE(started_at, now()), updated_at = now()
    WHERE task_id = p_task_id;
    t.status := 'running';
  END IF;

  SELECT * INTO a FROM allgres_private.agents WHERE agent_id = t.agent_id;
  SELECT * INTO p FROM allgres_private.policies WHERE agent_id = t.agent_id;

  IF a IS NULL OR NOT a.is_active THEN
    UPDATE allgres_private.tasks
    SET status = 'failed', error = 'agent_inactive', updated_at = now()
    WHERE task_id = p_task_id;
    PERFORM allgres_private.append_log(
      p_task_id, t.step_count, 'error',
      jsonb_build_object('reason', 'agent_inactive')
    );
    PERFORM allgres_private.maybe_complete_session(t.session_id);
    RETURN jsonb_build_object('action', 'done', 'reason', 'agent_inactive');
  END IF;

  IF p IS NULL THEN
    RAISE EXCEPTION 'fn_next_step: policy missing' USING ERRCODE = 'P0001';
  END IF;

  IF t.step_count >= p.max_steps THEN
    UPDATE allgres_private.tasks
    SET status = 'failed', error = 'max_steps', updated_at = now()
    WHERE task_id = p_task_id;
    PERFORM allgres_private.append_log(
      p_task_id, t.step_count, 'error',
      jsonb_build_object('reason', 'max_steps', 'max_steps', p.max_steps)
    );
    PERFORM allgres_private.maybe_complete_session(t.session_id);
    RETURN jsonb_build_object('action', 'done', 'reason', 'max_steps');
  END IF;

  -- Own grants plus (for a system agent) whatever its parent chain grants --
  -- see agent_permission_refs's comment; this is what the LLM is actually
  -- bound by (agent_has_permission), so the bounds text it reads must show
  -- the same set, not just this agent's own direct grants.
  SELECT to_jsonb(allgres_private.agent_permission_refs(t.agent_id, 'view')) INTO v_views;
  SELECT to_jsonb(allgres_private.agent_permission_refs(t.agent_id, 'tool')) INTO v_tools;

  -- Recalled every turn, the same way system_prompt and the view/tool bounds
  -- are: an agent's own memories, live ones only, ranked by importance then
  -- recency, capped at 15 rows and 500 chars each so one prompt can never be
  -- dominated by this block. Scoped strictly to this agent_id -- there is no
  -- cross-agent read here, unlike delegate, which is explicit and audited.
  -- last_accessed_at is touched for exactly the rows recalled, not on
  -- write, so it reflects "last time this actually reached a prompt," not
  -- "last time it was mentioned."
  WITH recalled AS (
    SELECT memory_id, memory_type, content, importance
    FROM allgres_private.agent_memories
    WHERE agent_id = t.agent_id
      AND (expires_at IS NULL OR expires_at > now())
    ORDER BY importance DESC, created_at DESC
    LIMIT 15
  )
  SELECT
    COALESCE(jsonb_agg(jsonb_build_object(
      'type', memory_type, 'content', left(content, 500)
    ) ORDER BY importance DESC), '[]'::jsonb),
    COALESCE(array_agg(memory_id), ARRAY[]::uuid[])
  INTO v_memories, v_memory_ids
  FROM recalled;

  IF array_length(v_memory_ids, 1) > 0 THEN
    UPDATE allgres_private.agent_memories
    SET last_accessed_at = now()
    WHERE memory_id = ANY(v_memory_ids);
  END IF;

  -- Roadmap item 4: reusable procedures (allgres_private.procedures), the
  -- same inheritance-aware permission check every other resource_type
  -- already goes through (agent_permission_refs) -- an operator curates and
  -- versions these once, any agent explicitly granted one (or inheriting it
  -- via its parent chain, same as a system agent's tool/view grants) sees
  -- its current content every turn. Unlike memory this is not ranked or
  -- capped: a deliberately small, shared, curated set, not per-agent noise
  -- that grows on its own.
  SELECT COALESCE(jsonb_agg(jsonb_build_object('name', pr.name, 'content', pr.content) ORDER BY pr.name), '[]'::jsonb)
  INTO v_procedures
  FROM allgres_private.procedures pr
  WHERE pr.is_active
    AND pr.name = ANY(allgres_private.agent_permission_refs(t.agent_id, 'procedure'));

  -- Bounds come from the database, not from worker code, so revoking a
  -- Project mode (item 42): this session's project, if any, may narrow the
  -- agent with a preset -- appended after the agent's own effective prompt,
  -- so a project focuses a general-purpose agent for one particular job
  -- without editing that agent's own policy.
  SELECT pr.preset_prompt INTO v_project_preset
  FROM allgres_private.sessions se
  JOIN allgres_private.projects pr ON pr.project_id = se.project_id
  WHERE se.session_id = t.session_id;

  -- permission takes effect on the very next step.
  v_messages := v_messages || jsonb_build_array(
    jsonb_build_object(
      'role', 'system',
      'content',
      allgres_private.agent_effective_prompt(t.agent_id)
      || CASE WHEN v_project_preset IS NOT NULL THEN E'\n\n# project preset\n' || v_project_preset ELSE '' END
      || E'\n\n# bounds (authoritative, from the database)\nviews: '
      || v_views::text
      || E'\ntools: '
      || v_tools::text
      || E'\nPick action from final_answer | execute_sql | call_tool | delegate | await_children | await_human | propose_change | remember.'
      || E'\nFor numeric questions, execute_sql first. Do not invent keys.'
      || E'\nawait_children: {"action":"await_children"} -- pauses this task until every task you have delegated'
      || E' (however many, across however many turns) has finished; your next turn then sees what each one did.'
      || E' Rejected if you have nothing pending to wait on.'
      || E'\npropose_change: {"action":"propose_change","changes":{"system_prompt":"..."},"reason":"..."}'
      || E' -- only system_prompt and llm_config.model/temperature/max_tokens may be proposed;'
      || E' an operator decides it later, it does not change your policy right now.'
      || E'\nremember: {"action":"remember","content":"...","memory_type":"semantic|episodic|preference|instruction|relationship|working","importance":0.0-1.0,"subject_id":"...","expires_in_days":N}'
      || E' -- saves something worth recalling in a future session; memory_type and importance default to'
      || E' semantic/0.5 if omitted, expires_in_days is optional and unset means it never expires on its own.'
      || E' Use it when you learn a durable fact, preference, or instruction, not for routine intermediate results.'
      || CASE WHEN v_memories = '[]'::jsonb THEN ''
              ELSE E'\n\n# memory (your own past recollections, most important first)\n' || v_memories::text
         END
      || CASE WHEN v_procedures = '[]'::jsonb THEN ''
              ELSE E'\n\n# procedures (reusable, curated by an operator -- follow these when they apply)\n' || v_procedures::text
         END
    )
  );

  -- A root-level task (parent_task_id IS NULL -- the dashboard's Run page,
  -- or a chat turn from fn_continue_session) sees every root-level task's
  -- log in this session, not just its own: fn_continue_session starts a
  -- fresh task per turn (its own step_count/max_steps budget), so without
  -- this the model would forget everything said in an earlier turn the
  -- moment a new one started. A delegated task (parent_task_id IS NOT
  -- NULL) stays scoped to only its own log, unchanged from before -- a
  -- sub-agent's turn must not see the parent conversation, or another
  -- sibling delegate's, just because they happen to share a session_id.
  IF t.parent_task_id IS NULL THEN
    SELECT array_agg(task_id) INTO v_task_ids
    FROM allgres_private.tasks
    WHERE session_id = t.session_id AND parent_task_id IS NULL;

    -- session_compactor auto-trigger (item 39): a no-op unless this
    -- session's own root-level log has actually grown past the threshold.
    PERFORM allgres_private.maybe_trigger_compaction(t.session_id, v_task_ids);
  ELSE
    v_task_ids := ARRAY[p_task_id];
  END IF;

  SELECT compacted_before INTO v_compacted_before
  FROM allgres_private.sessions WHERE session_id = t.session_id;

  IF v_compacted_before IS NOT NULL THEN
    SELECT am.content INTO v_summary_text
    FROM allgres_private.agent_memories am
    JOIN allgres_private.agents sc ON sc.agent_id = am.agent_id AND sc.name = 'session_compactor'
    WHERE am.subject_id = t.session_id::text
    ORDER BY am.created_at DESC
    LIMIT 1;
    IF v_summary_text IS NOT NULL THEN
      v_messages := v_messages || jsonb_build_array(
        jsonb_build_object('role', 'system', 'content', E'# earlier in this conversation, summarized\n' || v_summary_text)
      );
    END IF;
  END IF;

  FOR v_log IN
    SELECT role, content
    FROM allgres_private.execution_logs
    WHERE task_id = ANY(v_task_ids)
      AND (v_compacted_before IS NULL OR created_at >= v_compacted_before)
    ORDER BY created_at, step_number
  LOOP
    -- 'operator' carries a human's reply to an await_human approval (see
    -- fn_decide_approval); it has to reach the model as a 'user' turn just
    -- like a tool result does, or the human's answer is visible on the
    -- dashboard but the agent it was meant for never sees it.
    IF v_log.role IN ('system', 'user', 'assistant', 'tool', 'operator') THEN
      v_messages := v_messages || jsonb_build_array(
        jsonb_build_object(
          'role', CASE WHEN v_log.role IN ('tool', 'operator') THEN 'user' ELSE v_log.role END,
          'content', allgres_private.log_content_text(v_log.content)
        )
      );
    ELSIF v_log.role = 'error' THEN
      v_messages := v_messages || jsonb_build_array(
        jsonb_build_object(
          'role', 'user',
          'content', 'Previous step error: ' || allgres_private.log_content_text(v_log.content)
          || '. Reply with a valid action JSON.'
        )
      );
    END IF;
  END LOOP;

  v_input_text := COALESCE(t.input->>'goal', t.input->>'text', t.input::text);
  SELECT EXISTS (
    SELECT 1 FROM allgres_private.execution_logs
    WHERE task_id = p_task_id AND role = 'user'
  ) INTO v_has_input;
  IF NOT v_has_input AND v_input_text IS NOT NULL AND v_input_text NOT IN ('', '{}') THEN
    v_messages := v_messages || jsonb_build_array(
      jsonb_build_object('role', 'user', 'content', v_input_text)
    );
  END IF;

  v_cfg := allgres_private.sanitize_llm_config(p.llm_config);

  RETURN jsonb_build_object(
    'action', 'call_llm',
    'task_id', t.task_id,
    'agent_id', t.agent_id,
    'session_id', t.session_id,
    'step', t.step_count + 1,
    'messages', v_messages,
    'llm_config', v_cfg,
    'bounds', jsonb_build_object(
      'views', v_views,
      'tools', v_tools,
      'max_steps', p.max_steps
    )
  );
END;
$fn$;

CREATE OR REPLACE FUNCTION allgres_public.fn_submit_result(p_task_id uuid, p_payload jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = allgres_private, allgres_public, pg_temp
AS $fn$
DECLARE
  t allgres_private.tasks%ROWTYPE;
  a allgres_private.agents%ROWTYPE;
  p allgres_private.policies%ROWTYPE;
  v_type text;
  v_parsed jsonb;
  v_action text;
  v_tool text;
  v_args jsonb;
  v_target uuid;
  v_child uuid;
  v_err_n int;
  v_allowed boolean;
  v_cycle boolean;
  v_session_task_count int;
  v_url text;
  v_host text;
  v_reason text;
  v_call uuid;
  v_answer text;
  v_valid_sql text;
  v_changes jsonb;
  v_ok boolean;
  v_proposal uuid;
  v_mem_result jsonb;
  v_created jsonb;
  v_provider allgres_private.llm_providers%ROWTYPE;
  v_method text;
  v_conn_name text;
  v_conn allgres_private.api_connections%ROWTYPE;
  v_conn_auth text;
  v_path text;
  v_req_headers jsonb;
  v_req_body jsonb;
BEGIN
  PERFORM set_config('statement_timeout', '2000', true);

  SELECT * INTO t
  FROM allgres_private.tasks
  WHERE task_id = p_task_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'fn_submit_result: task not found' USING ERRCODE = 'P0001';
  END IF;
  IF t.status <> 'running' THEN
    RAISE EXCEPTION 'fn_submit_result: status % is not running', t.status
      USING ERRCODE = 'P0001';
  END IF;

  SELECT * INTO a FROM allgres_private.agents WHERE agent_id = t.agent_id;
  SELECT * INTO p FROM allgres_private.policies WHERE agent_id = t.agent_id;

  IF a IS NULL OR NOT a.is_active THEN
    UPDATE allgres_private.tasks
    SET status = 'failed', error = 'agent_inactive', updated_at = now()
    WHERE task_id = p_task_id;
    PERFORM allgres_private.append_log(
      p_task_id, t.step_count, 'error',
      jsonb_build_object('reason', 'agent_inactive', 'discarded', true)
    );
    PERFORM allgres_private.maybe_complete_session(t.session_id);
    RETURN jsonb_build_object('action', 'done', 'reason', 'agent_inactive');
  END IF;

  v_type := p_payload->>'type';
  IF v_type IS NULL OR v_type NOT IN ('llm_response', 'tool_result', 'error') THEN
    PERFORM allgres_private.append_log(
      p_task_id, t.step_count, 'error',
      jsonb_build_object('reason', 'payload_rejected', 'payload', p_payload)
    );
    UPDATE allgres_private.tasks
    SET step_count = step_count + 1, updated_at = now()
    WHERE task_id = p_task_id;
    RETURN jsonb_build_object('action', 'continue', 'reason', 'payload_rejected');
  END IF;

  IF v_type = 'error' THEN
    PERFORM allgres_private.append_log(
      p_task_id, t.step_count + 1, 'error',
      jsonb_build_object('message', COALESCE(p_payload->>'message', 'error'))
    );
    SELECT count(*) INTO v_err_n
    FROM allgres_private.execution_logs
    WHERE task_id = p_task_id AND role = 'error';
    UPDATE allgres_private.tasks
    SET step_count = step_count + 1, updated_at = now()
    WHERE task_id = p_task_id;
    IF v_err_n > p.max_retries THEN
      UPDATE allgres_private.tasks
      SET status = 'failed', error = COALESCE(p_payload->>'message', 'error'), updated_at = now()
      WHERE task_id = p_task_id;
      PERFORM allgres_private.maybe_complete_session(t.session_id);
      RETURN jsonb_build_object('action', 'done', 'reason', 'retries_exceeded');
    END IF;
    RETURN jsonb_build_object('action', 'continue');
  END IF;

  IF v_type = 'tool_result' THEN
    PERFORM allgres_private.append_log(
      p_task_id, t.step_count + 1, 'tool',
      COALESCE(p_payload->'content', '{}'::jsonb)
    );
    UPDATE allgres_private.tasks
    SET step_count = step_count + 1, updated_at = now()
    WHERE task_id = p_task_id;
    RETURN jsonb_build_object('action', 'continue');
  END IF;

  -- llm_response
  PERFORM allgres_private.append_log(
    p_task_id, t.step_count + 1, 'assistant',
    to_jsonb(COALESCE(p_payload->>'content', ''))
  );

  v_parsed := p_payload->'parsed';
  IF v_parsed IS NULL OR jsonb_typeof(v_parsed) <> 'object' THEN
    v_parsed := allgres_private.extract_first_json(p_payload->>'content');
  END IF;

  v_action := v_parsed->>'action';
  IF v_action IS NULL OR v_action NOT IN (
    'final_answer', 'execute_sql', 'call_tool', 'delegate', 'search_agents', 'recall', 'await_human', 'propose_change',
    'remember', 'create_agent', 'propose_fix', 'await_children'
  ) THEN
    PERFORM allgres_private.append_log(
      p_task_id, t.step_count + 1, 'error',
      jsonb_build_object('reason', 'unknown_action', 'parsed', v_parsed)
    );
    UPDATE allgres_private.tasks
    SET step_count = step_count + 1, updated_at = now()
    WHERE task_id = p_task_id;
    RETURN jsonb_build_object('action', 'continue', 'reason', 'unknown_action');
  END IF;

  IF v_action = 'final_answer' THEN
    v_answer := COALESCE(v_parsed->>'answer', '');
    UPDATE allgres_private.tasks
    SET status = 'completed',
        output = jsonb_build_object('answer', v_answer),
        step_count = step_count + 1,
        updated_at = now()
    WHERE task_id = p_task_id;
    UPDATE allgres_private.sessions
    SET final_answer = v_answer
    WHERE session_id = t.session_id;
    PERFORM allgres_private.maybe_complete_session(t.session_id);
    RETURN jsonb_build_object('action', 'done');
  END IF;

  -- Validation happens here, synchronously, as this function's owner (it only
  -- reads allgres_private.permissions and pg_proc; see fn_validate_sql).
  -- Execution does not: it is queued for the runtime worker, which runs it as
  -- a top-level statement under the `sandbox` role and reports back through
  -- fn_complete_sql, the same claim/complete shape used for outbound HTTP
  -- calls.  See "6. SQL sandbox" above for why this cannot happen inline.
  IF v_action = 'execute_sql' THEN
    BEGIN
      v_valid_sql := allgres_private.fn_validate_sql(t.agent_id, v_parsed->>'sql');
    EXCEPTION WHEN others THEN
      PERFORM allgres_private.append_log(
        p_task_id, t.step_count + 1, 'error',
        jsonb_build_object('sql', v_parsed->>'sql', 'message', SQLERRM)
      );
      UPDATE allgres_private.tasks
      SET step_count = step_count + 1, updated_at = now()
      WHERE task_id = p_task_id;
      RETURN jsonb_build_object('action', 'continue');
    END;

    INSERT INTO allgres_private.sql_calls (task_id, agent_id, sql, status)
    VALUES (p_task_id, t.agent_id, v_valid_sql, 'queued')
    RETURNING call_id INTO v_call;

    UPDATE allgres_private.tasks
    SET step_count = step_count + 1, updated_at = now()
    WHERE task_id = p_task_id;
    RETURN jsonb_build_object('action', 'execute_sql', 'sql', v_valid_sql, 'call_id', v_call);
  END IF;

  IF v_action = 'call_tool' THEN
    v_tool := v_parsed->>'tool';
    v_args := COALESCE(v_parsed->'args', '{}'::jsonb);
    v_allowed := allgres_private.agent_has_permission(t.agent_id, 'tool', v_tool);
    IF NOT v_allowed THEN
      PERFORM allgres_private.append_log(
        p_task_id, t.step_count + 1, 'error',
        jsonb_build_object('reason', 'tool_not_permitted', 'tool', v_tool)
      );
      UPDATE allgres_private.tasks
      SET step_count = step_count + 1, updated_at = now()
      WHERE task_id = p_task_id;
      RETURN jsonb_build_object('action', 'continue');
    END IF;

    IF v_tool NOT IN ('http_get', 'http_request') THEN
      PERFORM allgres_private.append_log(
        p_task_id, t.step_count + 1, 'error',
        jsonb_build_object('reason', 'unknown_tool', 'tool', v_tool)
      );
      UPDATE allgres_private.tasks
      SET step_count = step_count + 1, updated_at = now()
      WHERE task_id = p_task_id;
      RETURN jsonb_build_object('action', 'continue');
    END IF;

    v_conn := NULL;
    v_conn_auth := NULL;
    v_req_body := '{}'::jsonb;

    IF v_tool = 'http_get' THEN
      v_method := 'GET';
      v_url := v_args->>'url';
      v_req_headers := jsonb_build_object('accept', 'application/json, text/plain, */*');
    ELSE
      -- 'http_request': method/headers/body, and an optional named
      -- allgres_private.api_connections credential -- see that table's own
      -- comment for why a connection's own base_url is the only host its
      -- credential may ever reach.
      v_method := upper(COALESCE(NULLIF(trim(v_args->>'method'), ''), 'GET'));
      IF v_method NOT IN ('GET', 'POST', 'PUT', 'PATCH', 'DELETE') THEN
        PERFORM allgres_private.append_log(
          p_task_id, t.step_count + 1, 'error',
          jsonb_build_object('reason', 'unsupported_http_method', 'method', v_args->>'method')
        );
        UPDATE allgres_private.tasks
        SET step_count = step_count + 1, updated_at = now()
        WHERE task_id = p_task_id;
        RETURN jsonb_build_object('action', 'continue');
      END IF;

      v_conn_name := NULLIF(trim(v_args->>'connection'), '');
      IF v_conn_name IS NOT NULL THEN
        SELECT * INTO v_conn FROM allgres_private.api_connections
        WHERE name = v_conn_name AND is_enabled;
        IF NOT FOUND THEN
          PERFORM allgres_private.append_log(
            p_task_id, t.step_count + 1, 'error',
            jsonb_build_object('reason', 'unknown_connection', 'connection', v_conn_name)
          );
          UPDATE allgres_private.tasks
          SET step_count = step_count + 1, updated_at = now()
          WHERE task_id = p_task_id;
          RETURN jsonb_build_object('action', 'continue');
        END IF;

        -- Never a full URL here: a stored connection's credential may only
        -- ever be sent to its own fixed base_url, so the agent supplies a
        -- path relative to it, never a host of its own choosing.
        v_path := COALESCE(v_args->>'path', '');
        IF v_path ~* '^[a-zA-Z][a-zA-Z0-9+.-]*://' THEN
          PERFORM allgres_private.append_log(
            p_task_id, t.step_count + 1, 'error',
            jsonb_build_object('reason', 'connection_path_must_be_relative', 'path', v_path)
          );
          UPDATE allgres_private.tasks
          SET step_count = step_count + 1, updated_at = now()
          WHERE task_id = p_task_id;
          RETURN jsonb_build_object('action', 'continue');
        END IF;
        v_url := rtrim(v_conn.base_url, '/') || '/' || ltrim(v_path, '/');
        v_conn_auth := NULLIF(v_conn.auth_kind, 'none');
      ELSE
        v_url := v_args->>'url';
      END IF;

      -- Headers an agent may set itself: string values only, and never the
      -- header a connection's credential is injected into at claim time
      -- (fn_claim_outbound) -- letting an agent set Authorization/x-api-key
      -- here would either be silently overwritten by the real credential or,
      -- with no connection at all, be exactly the plaintext-secret-in-a-row
      -- shape this design keeps out of outbound_calls to begin with.
      SELECT COALESCE(jsonb_object_agg(lower(kv.key), kv.value), '{}'::jsonb)
      INTO v_req_headers
      FROM jsonb_each_text(
        CASE WHEN jsonb_typeof(v_args->'headers') = 'object' THEN v_args->'headers' ELSE '{}'::jsonb END
      ) AS kv(key, value)
      WHERE lower(kv.key) NOT IN ('authorization', 'x-api-key', 'host', 'content-length');
      v_req_headers := v_req_headers || jsonb_build_object('accept', 'application/json, text/plain, */*');

      IF v_method IN ('POST', 'PUT', 'PATCH') THEN
        v_req_body := CASE WHEN jsonb_typeof(v_args->'body') IS NOT NULL THEN v_args->'body' ELSE '{}'::jsonb END;
      END IF;

      -- External call idempotency (see outbound_calls.idempotency_key's own
      -- comment for the crash scenario this mitigates): every mutating
      -- method gets a deterministic 'idempotency-key' header, unless the
      -- agent already set one itself (respected as-is -- an agent that
      -- knows a destination's own idempotency contract gets to drive it).
      -- Derived from this task plus the exact method/url/body, not from
      -- call_id (which is different on every queued row, including a
      -- genuine retry): an agent retrying the identical request after
      -- seeing an error or a 'lost' outcome produces the identical key, so
      -- an idempotency-aware destination can recognize the retry and
      -- return its original result instead of repeating the effect. A
      -- deliberately different request (a changed body, a different task)
      -- produces a different key, same as it should.
      IF v_method IN ('POST', 'PUT', 'PATCH', 'DELETE') AND NOT (v_req_headers ? 'idempotency-key') THEN
        v_req_headers := v_req_headers || jsonb_build_object(
          'idempotency-key',
          md5(p_task_id::text || '|' || v_method || '|' || v_url || '|' || v_req_body::text)
        );
      END IF;
    END IF;

    v_reason := allgres_private.check_outbound_url(v_url, COALESCE(v_conn.allow_private_network, false));
    IF v_reason IS NOT NULL THEN
      PERFORM allgres_private.append_log(
        p_task_id, t.step_count + 1, 'error',
        jsonb_build_object('reason', v_reason, 'url', v_url)
      );
      UPDATE allgres_private.tasks
      SET step_count = step_count + 1, updated_at = now()
      WHERE task_id = p_task_id;
      RETURN jsonb_build_object('action', 'continue');
    END IF;

    v_host := allgres_private.url_host(v_url);
    v_allowed := allgres_private.agent_has_permission(t.agent_id, 'http_host', v_host);
    IF NOT v_allowed THEN
      PERFORM allgres_private.append_log(
        p_task_id, t.step_count + 1, 'error',
        jsonb_build_object('reason', 'http_host_not_permitted', 'host', v_host)
      );
      UPDATE allgres_private.tasks
      SET step_count = step_count + 1, updated_at = now()
      WHERE task_id = p_task_id;
      RETURN jsonb_build_object('action', 'continue');
    END IF;

    INSERT INTO allgres_private.outbound_calls (
      task_id, kind, tool, url, method, request_headers, request_body, status,
      allow_private, connection_id, auth_kind, idempotency_key
    ) VALUES (
      p_task_id, 'tool', v_tool, v_url, v_method, v_req_headers, v_req_body, 'queued',
      COALESCE(v_conn.allow_private_network, false), v_conn.connection_id, v_conn_auth,
      v_req_headers->>'idempotency-key'
    ) RETURNING call_id INTO v_call;

    UPDATE allgres_private.tasks
    SET step_count = step_count + 1, updated_at = now()
    WHERE task_id = p_task_id;
    RETURN jsonb_build_object('action', 'call_tool', 'tool', v_tool, 'args', v_args, 'call_id', v_call);
  END IF;

  -- Semantic delegate-target discovery ("tool/skill search" -- an agent IS
  -- the unit of capability in this platform, so searching for one to
  -- delegate to is what "finding a tool" means here; see the agent_config
  -- KNOWN_ISSUES item this follows). A query embedding is itself an
  -- outbound HTTP call, so this only queues one (kind='embedding' on
  -- outbound_calls, alongside 'llm'/'tool') and returns -- the ranked
  -- candidate list comes back as a plain 'tool_result' on a later step,
  -- from fn_complete_outbound's own 'embedding' branch, exactly the way
  -- call_tool's result always has. Never returns a name the caller could
  -- not actually delegate() to: allgres_private.rank_agents_by_embedding
  -- applies the identical agent_has_permission check delegate enforces.
  IF v_action = 'search_agents' THEN
    IF NULLIF(trim(v_parsed->>'query'), '') IS NULL THEN
      PERFORM allgres_private.append_log(
        p_task_id, t.step_count + 1, 'error',
        jsonb_build_object('reason', 'search_agents_needs_query')
      );
      UPDATE allgres_private.tasks
      SET step_count = step_count + 1, updated_at = now()
      WHERE task_id = p_task_id;
      RETURN jsonb_build_object('action', 'continue');
    END IF;

    SELECT * INTO v_provider FROM allgres_private.llm_providers
    WHERE purpose = 'embedding' AND is_enabled
    ORDER BY created_at LIMIT 1;
    IF NOT FOUND THEN
      PERFORM allgres_private.append_log(
        p_task_id, t.step_count + 1, 'error',
        jsonb_build_object('reason', 'no_embedding_provider_configured')
      );
      UPDATE allgres_private.tasks
      SET step_count = step_count + 1, updated_at = now()
      WHERE task_id = p_task_id;
      RETURN jsonb_build_object('action', 'continue');
    END IF;

    v_url := v_provider.base_url || '/embeddings';
    v_reason := allgres_private.check_outbound_url(v_url, v_provider.allow_private_network);
    IF v_reason IS NOT NULL THEN
      PERFORM allgres_private.append_log(
        p_task_id, t.step_count + 1, 'error',
        jsonb_build_object('reason', v_reason, 'url', v_url)
      );
      UPDATE allgres_private.tasks
      SET step_count = step_count + 1, updated_at = now()
      WHERE task_id = p_task_id;
      RETURN jsonb_build_object('action', 'continue');
    END IF;

    INSERT INTO allgres_private.outbound_calls (
      task_id, kind, url, request_headers, request_body, status, allow_private, provider_id, auth_kind
    ) VALUES (
      p_task_id, 'embedding', v_url,
      jsonb_build_object('content-type', 'application/json'),
      jsonb_build_object('model', v_provider.embedding_model, 'input', left(v_parsed->>'query', 8000)),
      'queued', v_provider.allow_private_network, v_provider.provider_id, 'authorization'
    ) RETURNING call_id INTO v_call;

    UPDATE allgres_private.tasks
    SET step_count = step_count + 1, updated_at = now()
    WHERE task_id = p_task_id;
    RETURN jsonb_build_object('action', 'search_agents', 'query', v_parsed->>'query', 'call_id', v_call);
  END IF;

  -- Semantic memory recall (roadmap backlog item: the same embedding
  -- infra search_agents already uses, applied to an agent's own
  -- agent_memories instead of cross-agent discovery). The automatic
  -- every-turn injection above stays importance/recency ranked -- that
  -- has to run synchronously while this prompt is being assembled, and a
  -- query embedding is itself an outbound HTTP call, so it cannot -- this
  -- is the explicit alternative for "recall something specific," the same
  -- one-queue-then-continue shape search_agents uses (kind='recall' on
  -- outbound_calls, since fn_complete_outbound needs to know to rank
  -- memories, not agents, once the vector comes back). Never a name/id the
  -- caller could not already see: allgres_private.rank_memories_by_embedding
  -- only ever reads WHERE agent_id = this task's own agent, the identical
  -- scope the automatic recall above already uses.
  IF v_action = 'recall' THEN
    IF NULLIF(trim(v_parsed->>'query'), '') IS NULL THEN
      PERFORM allgres_private.append_log(
        p_task_id, t.step_count + 1, 'error',
        jsonb_build_object('reason', 'recall_needs_query')
      );
      UPDATE allgres_private.tasks
      SET step_count = step_count + 1, updated_at = now()
      WHERE task_id = p_task_id;
      RETURN jsonb_build_object('action', 'continue');
    END IF;

    SELECT * INTO v_provider FROM allgres_private.llm_providers
    WHERE purpose = 'embedding' AND is_enabled
    ORDER BY created_at LIMIT 1;
    IF NOT FOUND THEN
      PERFORM allgres_private.append_log(
        p_task_id, t.step_count + 1, 'error',
        jsonb_build_object('reason', 'no_embedding_provider_configured')
      );
      UPDATE allgres_private.tasks
      SET step_count = step_count + 1, updated_at = now()
      WHERE task_id = p_task_id;
      RETURN jsonb_build_object('action', 'continue');
    END IF;

    v_url := v_provider.base_url || '/embeddings';
    v_reason := allgres_private.check_outbound_url(v_url, v_provider.allow_private_network);
    IF v_reason IS NOT NULL THEN
      PERFORM allgres_private.append_log(
        p_task_id, t.step_count + 1, 'error',
        jsonb_build_object('reason', v_reason, 'url', v_url)
      );
      UPDATE allgres_private.tasks
      SET step_count = step_count + 1, updated_at = now()
      WHERE task_id = p_task_id;
      RETURN jsonb_build_object('action', 'continue');
    END IF;

    INSERT INTO allgres_private.outbound_calls (
      task_id, kind, url, request_headers, request_body, status, allow_private, provider_id, auth_kind
    ) VALUES (
      p_task_id, 'recall', v_url,
      jsonb_build_object('content-type', 'application/json'),
      jsonb_build_object('model', v_provider.embedding_model, 'input', left(v_parsed->>'query', 8000)),
      'queued', v_provider.allow_private_network, v_provider.provider_id, 'authorization'
    ) RETURNING call_id INTO v_call;

    UPDATE allgres_private.tasks
    SET step_count = step_count + 1, updated_at = now()
    WHERE task_id = p_task_id;
    RETURN jsonb_build_object('action', 'recall', 'query', v_parsed->>'query', 'call_id', v_call);
  END IF;

  IF v_action = 'delegate' THEN
    SELECT agent_id INTO v_target
    FROM allgres_private.agents
    WHERE name = v_parsed->>'agent_name' AND is_active;
    IF v_target IS NULL THEN
      PERFORM allgres_private.append_log(
        p_task_id, t.step_count + 1, 'error',
        jsonb_build_object('reason', 'delegate_unknown', 'agent_name', v_parsed->>'agent_name')
      );
      UPDATE allgres_private.tasks
      SET step_count = step_count + 1, updated_at = now()
      WHERE task_id = p_task_id;
      RETURN jsonb_build_object('action', 'continue');
    END IF;
    v_allowed := allgres_private.agent_has_permission(t.agent_id, 'agent', v_parsed->>'agent_name');
    IF NOT v_allowed THEN
      PERFORM allgres_private.append_log(
        p_task_id, t.step_count + 1, 'error',
        jsonb_build_object('reason', 'delegate_not_permitted', 'agent_name', v_parsed->>'agent_name')
      );
      UPDATE allgres_private.tasks
      SET step_count = step_count + 1, updated_at = now()
      WHERE task_id = p_task_id;
      RETURN jsonb_build_object('action', 'continue');
    END IF;

    -- Three independent bounds on delegation, none of which existed before
    -- an external review pointed out the gap: with mutual delegate
    -- permissions (A may delegate to B, B to A -- a legitimate,
    -- operator-granted setup, not a misconfiguration), nothing stopped an
    -- unbounded A -> B -> A -> B -> ... chain, since each child task got
    -- its own fresh max_steps/max_retries/max_turn_seconds budget under
    -- max_concurrent_tasks alone -- none of which bound the chain as a
    -- whole.
    --
    -- 1. max_delegation_depth: how many hops deep one chain may go.
    IF t.delegation_depth + 1 > p.max_delegation_depth THEN
      PERFORM allgres_private.append_log(
        p_task_id, t.step_count + 1, 'error',
        jsonb_build_object('reason', 'delegate_depth_exceeded', 'agent_name', v_parsed->>'agent_name',
                            'depth', t.delegation_depth, 'max_delegation_depth', p.max_delegation_depth)
      );
      UPDATE allgres_private.tasks
      SET step_count = step_count + 1, updated_at = now()
      WHERE task_id = p_task_id;
      RETURN jsonb_build_object('action', 'continue');
    END IF;

    -- 2. Ancestor-cycle check: depth alone does not catch a chain that
    -- revisits an agent well within its depth budget (A -> B -> A with a
    -- generous max_delegation_depth) -- walk this task's own ancestor
    -- chain (parent_task_id, including this task itself as the base case)
    -- and refuse if the target agent already appears in it.
    WITH RECURSIVE ancestors AS (
      SELECT task_id, agent_id, parent_task_id FROM allgres_private.tasks WHERE task_id = p_task_id
      UNION ALL
      SELECT tk.task_id, tk.agent_id, tk.parent_task_id
      FROM allgres_private.tasks tk
      JOIN ancestors an ON tk.task_id = an.parent_task_id
    )
    SELECT EXISTS (SELECT 1 FROM ancestors WHERE agent_id = v_target) INTO v_cycle;
    IF v_cycle THEN
      PERFORM allgres_private.append_log(
        p_task_id, t.step_count + 1, 'error',
        jsonb_build_object('reason', 'delegate_cycle', 'agent_name', v_parsed->>'agent_name')
      );
      UPDATE allgres_private.tasks
      SET step_count = step_count + 1, updated_at = now()
      WHERE task_id = p_task_id;
      RETURN jsonb_build_object('action', 'continue');
    END IF;

    -- 3. max_session_tasks: a long, never-repeating chain (A -> B -> C ->
    -- D -> ...) defeats both checks above without ever revisiting an
    -- agent or exceeding a generous depth cap -- this bounds the total
    -- task count of the session as a whole, regardless of shape.
    SELECT count(*) INTO v_session_task_count
    FROM allgres_private.tasks WHERE session_id = t.session_id;
    IF v_session_task_count >= p.max_session_tasks THEN
      PERFORM allgres_private.append_log(
        p_task_id, t.step_count + 1, 'error',
        jsonb_build_object('reason', 'delegate_session_task_limit', 'agent_name', v_parsed->>'agent_name',
                            'session_tasks', v_session_task_count, 'max_session_tasks', p.max_session_tasks)
      );
      UPDATE allgres_private.tasks
      SET step_count = step_count + 1, updated_at = now()
      WHERE task_id = p_task_id;
      RETURN jsonb_build_object('action', 'continue');
    END IF;

    INSERT INTO allgres_private.tasks (
      session_id, agent_id, parent_task_id, status, input, delegation_depth
    ) VALUES (
      t.session_id, v_target, p_task_id, 'queued',
      COALESCE(v_parsed->'input', '{}'::jsonb), t.delegation_depth + 1
    ) RETURNING task_id INTO v_child;

    -- Default (no "wait"): completely unchanged from before roadmap item 5
    -- -- delegate is a one-shot hand-off, the parent's job ends the moment
    -- the child is queued, and no caller of delegate written before this
    -- (orchestrator's multi-mention routing, self_improve's cross-agent
    -- proposals) is affected. "wait": true is the opt-in real dependency
    -- edge: the parent stays 'running' instead of completing, so its next
    -- turn can delegate again (fanning out to more children over further
    -- turns, exactly like this one) or call the new await_children action
    -- to actually pause until every child it has spawned so far is done --
    -- see that action's own comment.
    IF COALESCE((v_parsed->>'wait')::boolean, false) THEN
      UPDATE allgres_private.tasks
      SET step_count = step_count + 1, updated_at = now()
      WHERE task_id = p_task_id;
    ELSE
      UPDATE allgres_private.tasks
      SET status = 'completed',
          output = jsonb_build_object('child_task_id', v_child),
          step_count = step_count + 1,
          updated_at = now()
      WHERE task_id = p_task_id;
    END IF;
    RETURN jsonb_build_object('action', 'continue', 'child_task_id', v_child);
  END IF;

  -- An agent may propose a change to its own behavior -- system_prompt, and
  -- the generation-tuning parts of llm_config -- but never to its own
  -- resource envelope (max_steps, max_retries, max_concurrent_tasks,
  -- max_turn_seconds, all operator-only via agents.update, unchanged by
  -- this action), its own permissions, or where its provider endpoint
  -- points (llm_config.provider/base_url -- already locked to the
  -- operator-managed provider row, see sanitize_llm_config). Any other key,
  -- anywhere in the proposal, is rejected outright rather than silently
  -- dropped: an agent can improve its own knowledge and behavior spec, not
  -- expand its own trust boundary. This never touches the live policy by
  -- itself -- it only ever queues a row for fn_decide_proposal, an
  -- operator-only function, to accept or reject. Not blocking, unlike
  -- await_human: proposing an improvement for future turns has nothing to
  -- do with whether the current task can finish.
  IF v_action = 'propose_change' THEN
    v_changes := v_parsed->'changes';
    IF v_changes IS NULL OR jsonb_typeof(v_changes) <> 'object' OR v_changes = '{}'::jsonb THEN
      PERFORM allgres_private.append_log(
        p_task_id, t.step_count + 1, 'error',
        jsonb_build_object('reason', 'propose_change_empty', 'changes', v_changes)
      );
      UPDATE allgres_private.tasks SET step_count = step_count + 1, updated_at = now() WHERE task_id = p_task_id;
      RETURN jsonb_build_object('action', 'continue');
    END IF;

    SELECT bool_and(k IN ('system_prompt', 'llm_config')) INTO v_ok
    FROM jsonb_object_keys(v_changes) k;
    IF v_ok IS DISTINCT FROM true THEN
      PERFORM allgres_private.append_log(
        p_task_id, t.step_count + 1, 'error',
        jsonb_build_object('reason', 'propose_change_field_not_allowed', 'changes', v_changes)
      );
      UPDATE allgres_private.tasks SET step_count = step_count + 1, updated_at = now() WHERE task_id = p_task_id;
      RETURN jsonb_build_object('action', 'continue');
    END IF;
    IF v_changes ? 'llm_config' THEN
      IF jsonb_typeof(v_changes->'llm_config') <> 'object' THEN
        v_ok := false;
      ELSE
        SELECT bool_and(k IN ('model', 'temperature', 'max_tokens')) INTO v_ok
        FROM jsonb_object_keys(v_changes->'llm_config') k;
      END IF;
      IF v_ok IS DISTINCT FROM true THEN
        PERFORM allgres_private.append_log(
          p_task_id, t.step_count + 1, 'error',
          jsonb_build_object('reason', 'propose_change_field_not_allowed', 'changes', v_changes)
        );
        UPDATE allgres_private.tasks SET step_count = step_count + 1, updated_at = now() WHERE task_id = p_task_id;
        RETURN jsonb_build_object('action', 'continue');
      END IF;
    END IF;

    -- Only self_improve may target an agent other than itself (item 38) --
    -- every other agent's propose_change stays exactly what it always was,
    -- a proposal against its own policy.
    v_target := NULL;
    IF v_parsed ? 'target_agent_id' THEN
      IF a.name <> 'self_improve' THEN
        PERFORM allgres_private.append_log(
          p_task_id, t.step_count + 1, 'error',
          jsonb_build_object('reason', 'propose_change_cross_agent_not_permitted', 'changes', v_changes)
        );
        UPDATE allgres_private.tasks SET step_count = step_count + 1, updated_at = now() WHERE task_id = p_task_id;
        RETURN jsonb_build_object('action', 'continue');
      END IF;
      v_target := NULLIF(v_parsed->>'target_agent_id', '')::uuid;
      IF v_target IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM allgres_private.agents WHERE agent_id = v_target AND is_active
      ) THEN
        PERFORM allgres_private.append_log(
          p_task_id, t.step_count + 1, 'error',
          jsonb_build_object('reason', 'propose_change_target_not_found', 'target_agent_id', v_target)
        );
        UPDATE allgres_private.tasks SET step_count = step_count + 1, updated_at = now() WHERE task_id = p_task_id;
        RETURN jsonb_build_object('action', 'continue');
      END IF;
    END IF;
    v_target := COALESCE(v_target, t.agent_id);

    -- A system agent whose autonomy_level opts out of admin_approval takes
    -- effect immediately instead of queueing (item 33's autonomy_level;
    -- creator/propose_fix below follow the same shape). Every non-system
    -- agent keeps autonomy_level='admin_approval' by default and is
    -- unaffected -- this branch is unreachable for them in practice, since
    -- only self_improve/creator/fixer ever set a different level.
    IF a.is_system AND a.autonomy_level <> 'admin_approval' THEN
      PERFORM allgres_public.fn_set_policy(
        v_target, v_changes->>'system_prompt', NULL, NULL, v_changes->'llm_config',
        NULL, NULL, false
      );
      PERFORM allgres_private.append_log(
        p_task_id, t.step_count + 1, 'assistant',
        jsonb_build_object('applied_change', v_changes, 'target_agent_id', v_target, 'autonomy_level', a.autonomy_level)
      );
      UPDATE allgres_private.tasks SET step_count = step_count + 1, updated_at = now() WHERE task_id = p_task_id;
      RETURN jsonb_build_object('action', 'continue', 'applied', true, 'target_agent_id', v_target);
    END IF;

    INSERT INTO allgres_private.change_proposals
      (agent_id, task_id, proposed_changes, reason, base_generation, target_agent_id)
    SELECT t.agent_id, p_task_id, v_changes, NULLIF(btrim(COALESCE(v_parsed->>'reason', '')), ''),
           tp.generation, NULLIF(v_target, t.agent_id)
    FROM allgres_private.policies tp WHERE tp.agent_id = v_target
    RETURNING proposal_id INTO v_proposal;

    PERFORM allgres_private.append_log(
      p_task_id, t.step_count + 1, 'assistant',
      jsonb_build_object('proposed_change', v_changes, 'proposal_id', v_proposal, 'target_agent_id', v_target)
    );
    UPDATE allgres_private.tasks SET step_count = step_count + 1, updated_at = now() WHERE task_id = p_task_id;
    RETURN jsonb_build_object('action', 'continue', 'proposal_id', v_proposal);
  END IF;

  IF v_action = 'create_agent' THEN
    IF a.name <> 'creator' THEN
      PERFORM allgres_private.append_log(
        p_task_id, t.step_count + 1, 'error',
        jsonb_build_object('reason', 'create_agent_not_permitted')
      );
      UPDATE allgres_private.tasks SET step_count = step_count + 1, updated_at = now() WHERE task_id = p_task_id;
      RETURN jsonb_build_object('action', 'continue');
    END IF;
    IF NULLIF(btrim(COALESCE(v_parsed->>'name', '')), '') IS NULL
       OR NULLIF(btrim(COALESCE(v_parsed->>'system_prompt', '')), '') IS NULL THEN
      PERFORM allgres_private.append_log(
        p_task_id, t.step_count + 1, 'error',
        jsonb_build_object('reason', 'create_agent_incomplete', 'parsed', v_parsed)
      );
      UPDATE allgres_private.tasks SET step_count = step_count + 1, updated_at = now() WHERE task_id = p_task_id;
      RETURN jsonb_build_object('action', 'continue');
    END IF;

    IF a.autonomy_level <> 'admin_approval' THEN
      v_created := allgres_public.fn_create_agent(v_parsed->>'name', v_parsed->>'system_prompt');
      PERFORM allgres_private.append_log(
        p_task_id, t.step_count + 1, 'assistant',
        jsonb_build_object('created_agent', v_created, 'autonomy_level', a.autonomy_level)
      );
      UPDATE allgres_private.tasks SET step_count = step_count + 1, updated_at = now() WHERE task_id = p_task_id;
      RETURN jsonb_build_object('action', 'continue', 'applied', true, 'created_agent', v_created);
    END IF;

    INSERT INTO allgres_private.change_proposals (agent_id, task_id, kind, proposed_changes, reason, base_generation)
    VALUES (
      t.agent_id, p_task_id, 'create_agent',
      jsonb_build_object('name', v_parsed->>'name', 'system_prompt', v_parsed->>'system_prompt'),
      NULLIF(btrim(COALESCE(v_parsed->>'reason', '')), ''), 0
    )
    RETURNING proposal_id INTO v_proposal;

    PERFORM allgres_private.append_log(
      p_task_id, t.step_count + 1, 'assistant',
      jsonb_build_object('proposed_agent', v_parsed, 'proposal_id', v_proposal)
    );
    UPDATE allgres_private.tasks SET step_count = step_count + 1, updated_at = now() WHERE task_id = p_task_id;
    RETURN jsonb_build_object('action', 'continue', 'proposal_id', v_proposal);
  END IF;

  IF v_action = 'propose_fix' THEN
    IF a.name <> 'fixer' THEN
      PERFORM allgres_private.append_log(
        p_task_id, t.step_count + 1, 'error',
        jsonb_build_object('reason', 'propose_fix_not_permitted')
      );
      UPDATE allgres_private.tasks SET step_count = step_count + 1, updated_at = now() WHERE task_id = p_task_id;
      RETURN jsonb_build_object('action', 'continue');
    END IF;
    IF v_parsed->>'fix_kind' IS NULL OR v_parsed->>'fix_kind' NOT IN ('revoke_permission', 'deactivate_agent') THEN
      PERFORM allgres_private.append_log(
        p_task_id, t.step_count + 1, 'error',
        jsonb_build_object('reason', 'propose_fix_unknown_kind', 'parsed', v_parsed)
      );
      UPDATE allgres_private.tasks SET step_count = step_count + 1, updated_at = now() WHERE task_id = p_task_id;
      RETURN jsonb_build_object('action', 'continue');
    END IF;
    v_target := NULLIF(v_parsed->>'target_agent_id', '')::uuid;
    IF v_target IS NULL OR NOT EXISTS (SELECT 1 FROM allgres_private.agents WHERE agent_id = v_target) THEN
      PERFORM allgres_private.append_log(
        p_task_id, t.step_count + 1, 'error',
        jsonb_build_object('reason', 'propose_fix_target_not_found', 'target_agent_id', v_target)
      );
      UPDATE allgres_private.tasks SET step_count = step_count + 1, updated_at = now() WHERE task_id = p_task_id;
      RETURN jsonb_build_object('action', 'continue');
    END IF;

    IF a.autonomy_level <> 'admin_approval' THEN
      v_created := allgres_private.apply_fix(v_parsed->>'fix_kind', v_target, COALESCE(v_parsed->'detail', '{}'::jsonb));
      PERFORM allgres_private.append_log(
        p_task_id, t.step_count + 1, 'assistant',
        jsonb_build_object('applied_fix', v_parsed, 'result', v_created, 'autonomy_level', a.autonomy_level)
      );
      UPDATE allgres_private.tasks SET step_count = step_count + 1, updated_at = now() WHERE task_id = p_task_id;
      RETURN jsonb_build_object('action', 'continue', 'applied', true, 'result', v_created);
    END IF;

    INSERT INTO allgres_private.fix_proposals (agent_id, task_id, fix_kind, target_agent_id, detail, reason)
    VALUES (
      t.agent_id, p_task_id, v_parsed->>'fix_kind', v_target,
      COALESCE(v_parsed->'detail', '{}'::jsonb),
      NULLIF(btrim(COALESCE(v_parsed->>'reason', '')), '')
    )
    RETURNING fix_id INTO v_proposal;

    PERFORM allgres_private.append_log(
      p_task_id, t.step_count + 1, 'assistant',
      jsonb_build_object('proposed_fix', v_parsed, 'fix_id', v_proposal)
    );
    UPDATE allgres_private.tasks SET step_count = step_count + 1, updated_at = now() WHERE task_id = p_task_id;
    RETURN jsonb_build_object('action', 'continue', 'fix_id', v_proposal);
  END IF;

  -- No queue, no claim/complete: unlike execute_sql/call_tool this never
  -- leaves PostgreSQL, so it can be a plain synchronous write, the same
  -- shape as propose_change's INSERT. It also needs no resource-permission
  -- check the way execute_sql (a view) or delegate (a target agent) do --
  -- an agent can only ever write to its own memory, which cannot expand its
  -- privileges or touch anything another agent owns.
  IF v_action = 'remember' THEN
    v_mem_result := allgres_private.write_memory(
      t.agent_id,
      v_parsed->>'content',
      v_parsed->>'memory_type',
      v_parsed->>'importance',
      v_parsed->>'subject_id',
      v_parsed->>'expires_in_days',
      t.session_id, p_task_id
    );
    IF NOT COALESCE((v_mem_result->>'ok')::boolean, false) THEN
      PERFORM allgres_private.append_log(
        p_task_id, t.step_count + 1, 'error',
        jsonb_build_object('reason', 'remember_' || (v_mem_result->>'error'), 'payload', v_parsed)
      );
      UPDATE allgres_private.tasks SET step_count = step_count + 1, updated_at = now() WHERE task_id = p_task_id;
      RETURN jsonb_build_object('action', 'continue');
    END IF;

    PERFORM allgres_private.append_log(
      p_task_id, t.step_count + 1, 'assistant',
      jsonb_build_object('remembered', v_mem_result->>'memory_id', 'memory_type', v_mem_result->>'memory_type')
    );
    UPDATE allgres_private.tasks SET step_count = step_count + 1, updated_at = now() WHERE task_id = p_task_id;

    -- session_compactor's own remember is what actually takes the older
    -- logs out of future context (see maybe_trigger_compaction): only once
    -- the summary memory exists does fn_next_step start excluding what it
    -- summarizes -- never the other way around, which would risk a turn
    -- seeing neither the raw logs nor a finished summary.
    IF a.name = 'session_compactor' AND t.input ? 'target_session_id' AND t.input ? 'compact_cutoff' THEN
      UPDATE allgres_private.sessions
      SET compacted_before = (t.input->>'compact_cutoff')::timestamptz
      WHERE session_id = (t.input->>'target_session_id')::uuid;
    END IF;

    RETURN jsonb_build_object('action', 'continue', 'memory_id', v_mem_result->>'memory_id');
  END IF;

  IF v_action = 'await_human' THEN
    UPDATE allgres_private.tasks
    SET status = 'waiting_human',
        step_count = step_count + 1,
        updated_at = now()
    WHERE task_id = p_task_id;
    -- 24h default: long enough for an actual human to see and answer it,
    -- short enough that a forgotten approval doesn't hold a task open
    -- forever.  fn_watchdog reclaims it past this point.
    INSERT INTO allgres_private.human_approvals (task_id, status, payload, expires_at)
    VALUES (
      p_task_id, 'pending',
      jsonb_build_object('reason', COALESCE(v_parsed->>'reason', '')),
      now() + interval '24 hours'
    );
    RETURN jsonb_build_object('action', 'wait');
  END IF;

  -- Roadmap item 5: a real multi-agent task dependency edge. delegate
  -- itself stays fire-and-forget (an agent may fan out to several
  -- sub-agents across several turns, exactly as orchestrator already does
  -- for parallel routing); await_children is the explicit synchronization
  -- point -- pause until every one of this task's own children (however
  -- many were delegated, across however many turns) reaches a terminal
  -- state, then resume with what each one actually did. Rejected outright
  -- when there is nothing to wait on, the same "don't let an agent block
  -- itself on a mistake" reasoning search_agents_needs_query already
  -- applies to a missing query.
  IF v_action = 'await_children' THEN
    IF NOT EXISTS (
      SELECT 1 FROM allgres_private.tasks
      WHERE parent_task_id = p_task_id AND status NOT IN ('completed', 'failed', 'cancelled')
    ) THEN
      PERFORM allgres_private.append_log(
        p_task_id, t.step_count + 1, 'error',
        jsonb_build_object('reason', 'no_pending_children_to_await')
      );
      UPDATE allgres_private.tasks
      SET step_count = step_count + 1, updated_at = now()
      WHERE task_id = p_task_id;
      RETURN jsonb_build_object('action', 'continue');
    END IF;

    UPDATE allgres_private.tasks
    SET status = 'waiting_children', step_count = step_count + 1, updated_at = now()
    WHERE task_id = p_task_id;
    RETURN jsonb_build_object('action', 'wait');
  END IF;

  RETURN jsonb_build_object('action', 'continue');
END;
$fn$;

-- ---------------------------------------------------------------------------
-- 8. Pump.  Builds requests; HTTP and sandboxed SQL both happen after these
--    functions commit -- the former on the runtime worker's HTTP pool
--    threads, the latter back on its SPI thread as the `sandbox` role.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION allgres_private.build_llm_http(
  p_spec jsonb
) RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = allgres_private, allgres_public, pg_temp
AS $fn$
DECLARE
  v_cfg jsonb := COALESCE(p_spec->'llm_config', '{}'::jsonb);
  v_name text := v_cfg->>'provider';
  v_prov allgres_private.llm_providers%ROWTYPE;
  v_url text;
  v_reason text;
  v_headers jsonb;
  v_body jsonb;
  v_model text;
  v_msgs jsonb := COALESCE(p_spec->'messages', '[]'::jsonb);
  v_system text := '';
  v_rest jsonb := '[]'::jsonb;
  v_el jsonb;
BEGIN
  -- Fail closed on the requested provider, never silently substitute a
  -- different one. This used to fall back to whichever enabled provider
  -- sorted first by name when v_name didn't resolve -- not a convenience,
  -- a real privacy/security bug: an agent (or operator) configured for one
  -- provider specifically, who then disables it or mistypes its name,
  -- could have every subsequent prompt silently routed to a completely
  -- different provider with no error, no log entry distinguishing "sent
  -- where configured" from "sent wherever was first alphabetically" --
  -- confirmed by inspection, an external review caught it. There is no
  -- fallback_provider_id or similar explicit opt-in for cross-provider
  -- fallback in this file; if that is ever wanted, it needs to be a real,
  -- named policy an operator turns on, not the default.
  --
  -- An agent with no provider configured at all must fail the same way, not
  -- quietly resolve to whichever provider happens to be seeded: an agent
  -- that was never set up should never actually reach a real LLM endpoint.
  IF v_name IS NULL THEN
    RAISE EXCEPTION 'agent has no llm_config.provider configured -- set a provider and model before running this agent'
      USING ERRCODE = 'P0001';
  END IF;

  SELECT * INTO v_prov
  FROM allgres_private.llm_providers
  WHERE name = v_name AND is_enabled
  LIMIT 1;

  IF v_prov.provider_id IS NULL THEN
    RAISE EXCEPTION 'llm provider "%" is not configured or not enabled -- refusing to silently substitute a different provider', v_name
      USING ERRCODE = 'P0001';
  END IF;

  -- No secret is fetched or handled here on purpose. This function's result
  -- is what fn_dispatch_tasks persists into outbound_calls -- a real table
  -- row, subject to WAL, physical backup, PITR, and replication -- so a
  -- credential built into it here would sit there in plaintext for the
  -- row's whole lifetime. fn_claim_outbound resolves and injects the actual
  -- Authorization/x-api-key header itself, at claim time, into the response
  -- it hands the worker over the RPC socket; that value is never written
  -- back to any table. See "provider_id"/"auth_kind" in the RETURN below --
  -- that is the only credential-shaped thing this function ever produces:
  -- which provider and which header name, not the secret itself.

  v_model := v_cfg->>'model';
  IF v_model IS NULL THEN
    RAISE EXCEPTION 'agent has no llm_config.model configured -- set a provider and model before running this agent'
      USING ERRCODE = 'P0001';
  END IF;

  -- The endpoint comes only from the provider row.  Per-agent llm_config can no
  -- longer redirect it (see sanitize_llm_config).
  v_url := rtrim(v_prov.base_url, '/');
  v_reason := allgres_private.check_outbound_url(v_url, v_prov.allow_private_network);
  IF v_reason IS NOT NULL THEN
    RAISE EXCEPTION 'llm provider "%" endpoint rejected: %', v_prov.name, v_reason
      USING ERRCODE = 'P0001';
  END IF;

  IF v_prov.kind = 'anthropic' THEN
    FOR v_el IN SELECT jsonb_array_elements(v_msgs) LOOP
      IF v_el->>'role' = 'system' THEN
        v_system := v_system || CASE WHEN v_system = '' THEN '' ELSE E'\n' END || (v_el->>'content');
      ELSE
        v_rest := v_rest || jsonb_build_array(
          jsonb_build_object(
            'role', CASE WHEN v_el->>'role' IN ('assistant', 'user') THEN v_el->>'role' ELSE 'user' END,
            'content', v_el->>'content'
          )
        );
      END IF;
    END LOOP;
    v_url := v_url || '/v1/messages';
    v_headers := jsonb_build_object(
      'content-type', 'application/json',
      'anthropic-version', '2023-06-01'
    );
    v_body := jsonb_build_object(
      'model', v_model,
      'max_tokens', COALESCE((v_cfg->>'max_tokens')::int, 1024),
      'system', v_system,
      'messages', v_rest
    );
  ELSE
    v_url := v_url || '/chat/completions';
    v_headers := jsonb_build_object(
      'content-type', 'application/json'
    );
    v_body := jsonb_build_object(
      'model', v_model,
      'messages', v_msgs,
      'temperature', COALESCE((v_cfg->>'temperature')::float, 0.2),
      'max_tokens', COALESCE((v_cfg->>'max_tokens')::int, 1024)
    );
    -- Per-provider, not a name check -- see response_format_json_object's
    -- own comment on allgres_private.llm_providers.
    IF v_prov.response_format_json_object THEN
      v_body := v_body || jsonb_build_object(
        'response_format', jsonb_build_object('type', 'json_object')
      );
    END IF;
  END IF;

  RETURN jsonb_build_object(
    'provider', v_prov.name,
    'kind', v_prov.kind,
    'url', v_url,
    'headers', v_headers,
    'body', v_body,
    'allow_private', v_prov.allow_private_network,
    'provider_id', v_prov.provider_id,
    'auth_kind', CASE WHEN v_prov.kind = 'anthropic' THEN 'x-api-key' ELSE 'authorization' END
  );
END;
$fn$;

CREATE OR REPLACE FUNCTION allgres_public.fn_dispatch_tasks()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = allgres_private, allgres_public, pg_temp
AS $fn$
DECLARE
  t record;
  spec jsonb;
  http jsonb;
  v_id uuid;
  v_n int := 0;
  v_out jsonb := '[]'::jsonb;
BEGIN
  PERFORM set_config('statement_timeout', '2000', true);

  FOR t IN
    SELECT task_id, agent_id
    FROM allgres_private.tasks
    WHERE status IN ('queued', 'running')
      AND NOT EXISTS (
        SELECT 1 FROM allgres_private.outbound_calls o
        WHERE o.task_id = tasks.task_id
          AND o.status IN ('queued', 'in_flight')
      )
      -- A task that just emitted execute_sql stays 'running' with no
      -- outbound_calls row at all -- the SQL result hasn't come back yet, it
      -- queued into sql_calls instead. Without this guard the next pump
      -- would call fn_next_step on it again before that result exists,
      -- rebuild the same dangling execute_sql request from execution_logs,
      -- and fire a second LLM call racing the pending SQL result.
      AND NOT EXISTS (
        SELECT 1 FROM allgres_private.sql_calls sc
        WHERE sc.task_id = tasks.task_id
          AND sc.status IN ('queued', 'in_flight')
      )
    ORDER BY created_at
    FOR UPDATE SKIP LOCKED
  LOOP
    -- max_concurrent_tasks caps how many of this agent's tasks may be
    -- actively in a turn (running, waiting_human, or waiting_children) at
    -- once; a 'queued' task that hasn't started yet doesn't occupy a slot,
    -- it just waits longer. Excluding t.task_id itself matters for a
    -- 'running' task continuing its next turn: that's not a new slot, it
    -- already holds the one it's in.
    IF (
      SELECT count(*) FROM allgres_private.tasks x
      WHERE x.agent_id = t.agent_id AND x.task_id <> t.task_id
        AND x.status IN ('running', 'waiting_human', 'waiting_children')
    ) >= (SELECT max_concurrent_tasks FROM allgres_private.policies WHERE agent_id = t.agent_id) THEN
      CONTINUE;
    END IF;

    BEGIN
      spec := allgres_public.fn_next_step(t.task_id);
    EXCEPTION WHEN others THEN
      -- Silently retrying forever is the failure mode this guards against:
      -- without the warning, a persistent (not transient) fn_next_step bug
      -- for one task would just get skipped every single dispatch tick,
      -- with zero trace anywhere that anything was ever wrong. The warning
      -- always fires; pushing the error into the task's own retry
      -- accounting is best-effort on top of that (fn_next_step may have
      -- thrown before the task even reached 'running', in which case
      -- fn_submit_result can't accept it either -- the warning is what
      -- still captures that case).
      RAISE WARNING 'fn_dispatch_tasks: fn_next_step failed for task %: %', t.task_id, SQLERRM;
      BEGIN
        PERFORM allgres_public.fn_submit_result(
          t.task_id, jsonb_build_object('type', 'error', 'message', SQLERRM)
        );
      EXCEPTION WHEN others THEN
        NULL;
      END;
      CONTINUE;
    END;
    IF spec->>'action' <> 'call_llm' THEN
      CONTINUE;
    END IF;
    BEGIN
      http := allgres_private.build_llm_http(spec);
    EXCEPTION WHEN others THEN
      PERFORM allgres_public.fn_submit_result(
        t.task_id,
        jsonb_build_object('type', 'error', 'message', SQLERRM)
      );
      CONTINUE;
    END;
    -- request_headers holds only what build_llm_http returned -- no
    -- credential; provider_id/auth_kind are what fn_claim_outbound needs to
    -- inject one later, at claim time, without ever writing it here.
    INSERT INTO allgres_private.outbound_calls (
      task_id, kind, url, request_headers, request_body, status, allow_private,
      provider_id, auth_kind
    ) VALUES (
      t.task_id, 'llm', http->>'url', http->'headers', http->'body', 'queued',
      COALESCE((http->>'allow_private')::boolean, false),
      (http->>'provider_id')::uuid, http->>'auth_kind'
    ) RETURNING call_id INTO v_id;
    v_out := v_out || jsonb_build_array(jsonb_build_object('call_id', v_id, 'task_id', t.task_id));
    v_n := v_n + 1;
    EXIT WHEN v_n >= 4;
  END LOOP;

  RETURN jsonb_build_object('dispatched', v_n, 'calls', v_out);
END;
$fn$;

CREATE OR REPLACE FUNCTION allgres_public.fn_claim_outbound(p_limit int DEFAULT 4, p_fallback_key text DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = allgres_private, allgres_public, pg_temp
AS $fn$
DECLARE
  r record;
  v_out jsonb := '[]'::jsonb;
  v_n int := 0;
  v_headers jsonb;
  v_key text;
BEGIN
  PERFORM set_config('statement_timeout', '2000', true);
  -- The task-status join is defense in depth against fn_cancel_session (or a
  -- watchdog terminal transition) racing a row from 'queued' to claimable
  -- between when it was inserted and when this runs: a call whose task is no
  -- longer 'running' must never be claimed and actually sent, cancelled or
  -- not -- fn_complete_outbound already discards its result in that case,
  -- but by then the request has left the process.
  FOR r IN
    SELECT o.call_id, o.task_id, o.kind, o.tool, o.url, o.method, o.request_headers, o.request_body,
           o.allow_private, o.provider_id, o.connection_id, o.auth_kind, p.name AS provider_name
    FROM allgres_private.outbound_calls o
    JOIN allgres_private.tasks t ON t.task_id = o.task_id
    LEFT JOIN allgres_private.llm_providers p ON p.provider_id = o.provider_id
    WHERE o.status = 'queued' AND t.status = 'running'
    ORDER BY o.created_at
    FOR UPDATE OF o SKIP LOCKED
    LIMIT GREATEST(1, LEAST(COALESCE(p_limit, 4), 16))
  LOOP
    UPDATE allgres_private.outbound_calls
    SET status = 'in_flight', updated_at = now()
    WHERE call_id = r.call_id;

    -- The credential is resolved and injected right here, into the response
    -- this function hands the worker over the RPC socket -- never written
    -- back to outbound_calls.request_headers, which is why that column was
    -- never given one in the first place (see fn_dispatch_tasks /
    -- build_llm_http). It exists only in this return value and then in the
    -- worker's memory for the one HTTP request it is used for.
    v_headers := r.request_headers;
    IF r.auth_kind IS NOT NULL AND r.provider_id IS NOT NULL THEN
      v_key := allgres_private.provider_secret(r.provider_id);
      IF (v_key IS NULL OR v_key = '') AND r.provider_name IN ('xai', 'grok') THEN
        v_key := NULLIF(p_fallback_key, '');
      END IF;
      v_key := COALESCE(v_key, NULLIF(p_fallback_key, ''), '');
      v_headers := v_headers || jsonb_build_object(
        r.auth_kind,
        CASE WHEN r.auth_kind = 'x-api-key' THEN v_key ELSE 'Bearer ' || v_key END
      );
    -- Same injection, for an 'http_request' tool call routed through a
    -- stored allgres_private.api_connections credential instead of an LLM
    -- provider's. No xai/grok-shaped fallback here -- that quirk belongs to
    -- the LLM path alone (see its own comment above).
    ELSIF r.auth_kind IS NOT NULL AND r.connection_id IS NOT NULL THEN
      v_key := COALESCE(allgres_private.connection_secret(r.connection_id), '');
      v_headers := v_headers || jsonb_build_object(
        r.auth_kind,
        CASE WHEN r.auth_kind = 'x-api-key' THEN v_key ELSE 'Bearer ' || v_key END
      );
    END IF;

    v_out := v_out || jsonb_build_array(jsonb_build_object(
      'call_id', r.call_id,
      'task_id', r.task_id,
      'kind', r.kind,
      'tool', r.tool,
      'url', r.url,
      'method', r.method,
      'headers', v_headers,
      'body', r.request_body,
      'allow_private', r.allow_private
    ));
    v_n := v_n + 1;
  END LOOP;
  RETURN jsonb_build_object('count', v_n, 'calls', v_out);
END;
$fn$;

-- Same claim shape as fn_claim_outbound, for allgres_private.sql_calls instead.
-- The runtime worker executes each claimed call itself, as the `sandbox`
-- role, via a top-level SPI statement (see fn_run_sandboxed_sql above and
-- src/lib.rs's `run_sandboxed_sql`) -- there is no HTTP round trip here.
CREATE OR REPLACE FUNCTION allgres_public.fn_claim_sql(p_limit int DEFAULT 4)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = allgres_private, allgres_public, pg_temp
AS $fn$
DECLARE
  r record;
  v_out jsonb := '[]'::jsonb;
  v_n int := 0;
BEGIN
  PERFORM set_config('statement_timeout', '2000', true);
  -- Same task-status join as fn_claim_outbound, and for the same reason: a
  -- cancelled or otherwise-terminal task's queued SQL must never actually
  -- execute under the sandbox role, even if it was queued before the task
  -- left 'running'.
  FOR r IN
    SELECT sc.call_id, sc.task_id, sc.agent_id, sc.sql, a.pg_role
    FROM allgres_private.sql_calls sc
    JOIN allgres_private.tasks t ON t.task_id = sc.task_id
    JOIN allgres_private.agents a ON a.agent_id = sc.agent_id
    WHERE sc.status = 'queued' AND t.status = 'running'
    ORDER BY sc.created_at
    FOR UPDATE OF sc SKIP LOCKED
    LIMIT GREATEST(1, LEAST(COALESCE(p_limit, 4), 16))
  LOOP
    UPDATE allgres_private.sql_calls
    SET status = 'in_flight', updated_at = now()
    WHERE call_id = r.call_id;
    -- pg_role is NULL for an agent that predates per-agent roles; the
    -- worker falls back to the shared `sandbox` role for those (see
    -- run_sandboxed_sql in src/lib.rs).
    v_out := v_out || jsonb_build_array(jsonb_build_object(
      'call_id', r.call_id,
      'task_id', r.task_id,
      'agent_id', r.agent_id,
      'sql', r.sql,
      'pg_role', r.pg_role
    ));
    v_n := v_n + 1;
  END LOOP;
  RETURN jsonb_build_object('count', v_n, 'calls', v_out);
END;
$fn$;

CREATE OR REPLACE FUNCTION allgres_private.llm_text_from_http(p_body text)
RETURNS text
LANGUAGE plpgsql
IMMUTABLE
AS $fn$
DECLARE
  j jsonb;
  t text;
BEGIN
  BEGIN
    j := p_body::jsonb;
  EXCEPTION WHEN others THEN
    RETURN p_body;
  END;
  t := j #>> '{choices,0,message,content}';
  IF t IS NOT NULL THEN
    RETURN t;
  END IF;
  t := j #>> '{content,0,text}';
  IF t IS NOT NULL THEN
    RETURN t;
  END IF;
  RETURN p_body;
END;
$fn$;

CREATE OR REPLACE FUNCTION allgres_public.fn_complete_outbound(
  p_call_id uuid,
  p_status int,
  p_body text
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = allgres_private, allgres_public, pg_temp
AS $fn$
DECLARE
  c allgres_private.outbound_calls%ROWTYPE;
  v_text text;
  v_parsed jsonb;
  v_payload jsonb;
  v_result jsonb;
  v_running boolean;
  v_query_vec double precision[];
  v_requester uuid;
  v_expected_model text;
BEGIN
  PERFORM set_config('statement_timeout', '2000', true);

  SELECT * INTO c
  FROM allgres_private.outbound_calls
  WHERE call_id = p_call_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'fn_complete_outbound: not found' USING ERRCODE = 'P0001';
  END IF;

  -- Fencing: a call only ever completes from 'in_flight'. If it isn't
  -- anymore -- fn_watchdog already reclaimed it as 'lost' after a timeout,
  -- most likely -- this is a zombie worker's belated result for a call
  -- that has already been retried or failed as a *different* attempt.
  -- Accepting it here would inject a stale response into whatever the task
  -- is doing now, possibly an entirely different turn. The row already
  -- reflects what actually happened to this call; recording nothing and
  -- returning is correct, not a gap -- the task has already moved on.
  IF c.status <> 'in_flight' THEN
    RETURN jsonb_build_object(
      'submit', jsonb_build_object('action', 'stale', 'reason', 'call_not_in_flight', 'status', c.status),
      'call_id', p_call_id
    );
  END IF;

  UPDATE allgres_private.outbound_calls
  SET status = 'harvested',
      response_status = p_status,
      response_body = left(COALESCE(p_body, ''), 200000),
      updated_at = now()
  WHERE call_id = p_call_id;

  IF c.kind = 'tool' THEN
    v_payload := jsonb_build_object(
      'type', 'tool_result',
      'content', jsonb_build_object(
        'status', p_status,
        'body', left(COALESCE(p_body, ''), 16000)
      )
    );
  -- fn_search_agents' own query embedding (item: semantic delegate
  -- discovery). Same {"data":[{"embedding":[...]}]} response shape as
  -- fn_complete_agent_embedding parses, but the result here is a ranked
  -- candidate list handed back as a 'tool_result' -- exactly what
  -- 'execute_sql'/'call_tool' already look like to the agent on its next
  -- step -- rather than written into a stored column.
  ELSIF c.kind = 'embedding' THEN
    IF p_status IS NULL OR p_status < 200 OR p_status >= 300 THEN
      v_payload := jsonb_build_object(
        'type', 'error',
        'message', 'embedding http ' || COALESCE(p_status::text, '0') || ': ' || left(COALESCE(p_body, ''), 2000)
      );
    ELSE
      BEGIN
        v_parsed := p_body::jsonb;
      EXCEPTION WHEN others THEN
        v_parsed := NULL;
      END;
      SELECT array_agg((x)::double precision) INTO v_query_vec
      FROM jsonb_array_elements_text(v_parsed->'data'->0->'embedding') AS x;
      IF v_query_vec IS NULL OR array_length(v_query_vec, 1) IS NULL THEN
        v_payload := jsonb_build_object(
          'type', 'error', 'message', 'embedding response had no usable data[0].embedding'
        );
      ELSE
        SELECT agent_id INTO v_requester FROM allgres_private.tasks WHERE task_id = c.task_id;
        -- The same "<provider name>:<model>" string fn_complete_agent_embedding
        -- stamps onto agents.embedding_model, built from what this very call
        -- was actually queued with (c.request_body->>'model', the provider it
        -- was actually sent to) rather than re-deriving "the" current
        -- embedding provider -- which could have changed between queue time
        -- and this completion.
        SELECT p.name || ':' || (c.request_body->>'model') INTO v_expected_model
        FROM allgres_private.llm_providers p WHERE p.provider_id = c.provider_id;
        v_payload := jsonb_build_object(
          'type', 'tool_result',
          'content', jsonb_build_object(
            'status', p_status,
            'body', COALESCE(
              allgres_private.rank_agents_by_embedding(v_query_vec, v_requester, v_expected_model, 5),
              '[]'::jsonb
            )::text
          )
        );
      END IF;
    END IF;
  -- The 'recall' agent action's own query embedding (semantic memory
  -- recall). Identical shape to the 'embedding' branch just above --
  -- same response parsing, same "<provider name>:<model>" staleness
  -- guard -- ranking an agent's own agent_memories instead of other
  -- agents' identities is the only difference (rank_memories_by_embedding
  -- vs rank_agents_by_embedding).
  ELSIF c.kind = 'recall' THEN
    IF p_status IS NULL OR p_status < 200 OR p_status >= 300 THEN
      v_payload := jsonb_build_object(
        'type', 'error',
        'message', 'embedding http ' || COALESCE(p_status::text, '0') || ': ' || left(COALESCE(p_body, ''), 2000)
      );
    ELSE
      BEGIN
        v_parsed := p_body::jsonb;
      EXCEPTION WHEN others THEN
        v_parsed := NULL;
      END;
      SELECT array_agg((x)::double precision) INTO v_query_vec
      FROM jsonb_array_elements_text(v_parsed->'data'->0->'embedding') AS x;
      IF v_query_vec IS NULL OR array_length(v_query_vec, 1) IS NULL THEN
        v_payload := jsonb_build_object(
          'type', 'error', 'message', 'embedding response had no usable data[0].embedding'
        );
      ELSE
        SELECT agent_id INTO v_requester FROM allgres_private.tasks WHERE task_id = c.task_id;
        SELECT p.name || ':' || (c.request_body->>'model') INTO v_expected_model
        FROM allgres_private.llm_providers p WHERE p.provider_id = c.provider_id;
        v_payload := jsonb_build_object(
          'type', 'tool_result',
          'content', jsonb_build_object(
            'status', p_status,
            'body', COALESCE(
              allgres_private.rank_memories_by_embedding(v_query_vec, v_requester, v_expected_model, 5),
              '[]'::jsonb
            )::text
          )
        );
      END IF;
    END IF;
  ELSIF p_status IS NULL OR p_status >= 400 OR p_status < 200 THEN
    -- Auto-detect a provider that rejects response_format outright (a real
    -- local-server incompatibility, not a hypothetical -- confirmed live
    -- against LM Studio) instead of leaving an operator to notice the same
    -- HTTP 400 and flip response_format_json_object's own checkbox by
    -- hand. This flips it here, at the moment the error is first seen, on
    -- the row's real provider_id; the task's own next retry (already
    -- happening on its own via the normal max_retries path -- nothing
    -- extra queued or requeued from here) calls build_llm_http fresh, the
    -- same as any other retry, which reads this column live and simply
    -- stops sending the field. A narrow signature match on p_status and
    -- the exact phrase this specific rejection uses, not "any 400 means
    -- turn it off" -- an unrelated 400 (a bad API key, a context-length
    -- error, ...) must never touch this column.
    IF p_status = 400 AND p_body ILIKE '%response_format.type%' THEN
      UPDATE allgres_private.llm_providers
      SET response_format_json_object = false
      WHERE provider_id = c.provider_id AND response_format_json_object;
    END IF;
    v_payload := jsonb_build_object(
      'type', 'error',
      'message', 'llm http ' || COALESCE(p_status::text, '0') || ': ' || left(COALESCE(p_body, ''), 2000)
    );
  ELSE
    v_text := allgres_private.llm_text_from_http(p_body);
    v_parsed := allgres_private.extract_first_json(v_text);
    v_payload := jsonb_build_object(
      'type', 'llm_response',
      'content', v_text,
      'parsed', v_parsed
    );
  END IF;

  -- The task may have been failed by the watchdog or by max_steps while this
  -- call was in flight.  Harvesting must still commit, so never let
  -- fn_submit_result abort the transaction that records the response.
  SELECT EXISTS (
    SELECT 1 FROM allgres_private.tasks WHERE task_id = c.task_id AND status = 'running'
  ) INTO v_running;

  IF v_running THEN
    BEGIN
      v_result := allgres_public.fn_submit_result(c.task_id, v_payload);
    EXCEPTION WHEN others THEN
      v_result := jsonb_build_object('action', 'error', 'message', SQLERRM);
    END;
  ELSE
    v_result := jsonb_build_object('action', 'skipped', 'reason', 'task_not_running');
  END IF;

  RETURN jsonb_build_object('submit', v_result, 'call_id', p_call_id);
END;
$fn$;

-- Same completion shape as fn_complete_outbound, for a sandboxed SQL
-- execution.  p_ok/p_rows/p_row_count/p_truncated/p_error are exactly what
-- fn_run_sandboxed_sql returned (or a worker-side failure, e.g. the sandbox
-- role itself being unavailable); this function only records the outcome and
-- continues the task, reusing fn_submit_result's tool_result/error handling
-- (including its retry-count logic) rather than duplicating it.
CREATE OR REPLACE FUNCTION allgres_public.fn_complete_sql(
  p_call_id uuid,
  p_ok boolean,
  p_rows jsonb,
  p_row_count int,
  p_truncated boolean,
  p_error text
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = allgres_private, allgres_public, pg_temp
AS $fn$
DECLARE
  c allgres_private.sql_calls%ROWTYPE;
  v_payload jsonb;
  v_result jsonb;
  v_running boolean;
BEGIN
  PERFORM set_config('statement_timeout', '2000', true);

  SELECT * INTO c
  FROM allgres_private.sql_calls
  WHERE call_id = p_call_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'fn_complete_sql: not found' USING ERRCODE = 'P0001';
  END IF;

  -- Fencing: same reasoning as fn_complete_outbound. A sandboxed-SQL
  -- execution only ever completes from 'in_flight'; if fn_watchdog already
  -- reclaimed it as 'lost', this is a stale result from an attempt the task
  -- has already moved past.
  IF c.status <> 'in_flight' THEN
    RETURN jsonb_build_object(
      'submit', jsonb_build_object('action', 'stale', 'reason', 'call_not_in_flight', 'status', c.status),
      'call_id', p_call_id
    );
  END IF;

  UPDATE allgres_private.sql_calls
  SET status = 'harvested', updated_at = now()
  WHERE call_id = p_call_id;

  IF COALESCE(p_ok, false) THEN
    v_payload := jsonb_build_object(
      'type', 'tool_result',
      'content', jsonb_build_object(
        'sql', c.sql,
        'result', jsonb_build_object(
          'ok', true,
          'row_count', COALESCE(p_row_count, 0),
          'truncated', COALESCE(p_truncated, false),
          'rows', COALESCE(p_rows, '[]'::jsonb)
        )
      )
    );
  ELSE
    v_payload := jsonb_build_object(
      'type', 'error',
      'message', 'sql: ' || left(c.sql, 200) || ' -- ' || COALESCE(p_error, 'execution failed')
    );
  END IF;

  -- The task may have been failed by the watchdog or by max_steps while this
  -- call was in flight.  Harvesting must still commit, so never let
  -- fn_submit_result abort the transaction that records the response.
  SELECT EXISTS (
    SELECT 1 FROM allgres_private.tasks WHERE task_id = c.task_id AND status = 'running'
  ) INTO v_running;

  IF v_running THEN
    BEGIN
      v_result := allgres_public.fn_submit_result(c.task_id, v_payload);
    EXCEPTION WHEN others THEN
      v_result := jsonb_build_object('action', 'error', 'message', SQLERRM);
    END;
  ELSE
    v_result := jsonb_build_object('action', 'skipped', 'reason', 'task_not_running');
  END IF;

  RETURN jsonb_build_object('submit', v_result, 'call_id', p_call_id);
END;
$fn$;

CREATE OR REPLACE FUNCTION allgres_public.fn_watchdog(p_timeout_seconds int DEFAULT 90)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = allgres_private, allgres_public, pg_temp
AS $fn$
DECLARE
  r record;
  n int := 0;
  v_step int;
  v_session uuid;
  v_mem_gc int;
BEGIN
  PERFORM set_config('statement_timeout', '2000', true);
  FOR r IN
    SELECT call_id, task_id
    FROM allgres_private.outbound_calls
    WHERE status = 'in_flight'
      AND updated_at < now() - make_interval(secs => GREATEST(15, COALESCE(p_timeout_seconds, 90)))
    FOR UPDATE SKIP LOCKED
  LOOP
    UPDATE allgres_private.outbound_calls
    SET status = 'lost', error = 'timeout', updated_at = now()
    WHERE call_id = r.call_id;
    IF EXISTS (SELECT 1 FROM allgres_private.tasks WHERE task_id = r.task_id AND status = 'running') THEN
      BEGIN
        PERFORM allgres_public.fn_submit_result(
          r.task_id,
          jsonb_build_object('type', 'error', 'message', 'outbound timeout')
        );
      EXCEPTION WHEN others THEN
        RAISE WARNING 'fn_watchdog: fn_submit_result failed for task % after outbound timeout: %', r.task_id, SQLERRM;
      END;
    END IF;
    n := n + 1;
  END LOOP;

  -- Same reclaim, for a sandboxed SQL execution the worker never came back
  -- from (a worker crash between fn_claim_sql and fn_complete_sql).  Ordinary
  -- execution is bounded by fn_run_sandboxed_sql's own statement_timeout, so
  -- this only ever fires on that kind of crash, not on a slow query.
  FOR r IN
    SELECT call_id, task_id
    FROM allgres_private.sql_calls
    WHERE status = 'in_flight'
      AND updated_at < now() - make_interval(secs => GREATEST(15, COALESCE(p_timeout_seconds, 90)))
    FOR UPDATE SKIP LOCKED
  LOOP
    UPDATE allgres_private.sql_calls
    SET status = 'lost', updated_at = now()
    WHERE call_id = r.call_id;
    IF EXISTS (SELECT 1 FROM allgres_private.tasks WHERE task_id = r.task_id AND status = 'running') THEN
      BEGIN
        PERFORM allgres_public.fn_submit_result(
          r.task_id,
          jsonb_build_object('type', 'error', 'message', 'sql execution timeout')
        );
      EXCEPTION WHEN others THEN
        RAISE WARNING 'fn_watchdog: fn_submit_result failed for task % after sql timeout: %', r.task_id, SQLERRM;
      END;
    END IF;
    n := n + 1;
  END LOOP;

  -- Same reclaim, for an OAuth token exchange the worker never came back
  -- from (a crash between fn_claim_oauth and fn_complete_oauth). No task to
  -- notify -- oauth_calls has no task_id -- so this only marks the row
  -- 'lost'; the operator sees the failure next time they look at the
  -- provider (has_secret stays false) and has to restart the flow, since the
  -- authorization code fn_oauth_token_request already consumed cannot be
  -- redeemed a second time regardless of what this reclaim does.
  FOR r IN
    SELECT call_id
    FROM allgres_private.oauth_calls
    WHERE status = 'in_flight'
      AND updated_at < now() - make_interval(secs => GREATEST(15, COALESCE(p_timeout_seconds, 90)))
    FOR UPDATE SKIP LOCKED
  LOOP
    UPDATE allgres_private.oauth_calls
    SET status = 'lost', error = 'timeout', updated_at = now()
    WHERE call_id = r.call_id;
    n := n + 1;
  END LOOP;

  -- Same reclaim, for an agent-identity embedding call the worker never came
  -- back from. Also no task to notify; unlike an OAuth exchange this is
  -- fully retriable, since queue_agent_embedding is called again on the
  -- agent's next edit -- there is deliberately no automatic retry here, the
  -- embedding just stays whatever it was (possibly still NULL) until then.
  FOR r IN
    SELECT call_id
    FROM allgres_private.embedding_calls
    WHERE status = 'in_flight'
      AND updated_at < now() - make_interval(secs => GREATEST(15, COALESCE(p_timeout_seconds, 90)))
    FOR UPDATE SKIP LOCKED
  LOOP
    UPDATE allgres_private.embedding_calls
    SET status = 'lost', error = 'timeout', updated_at = now()
    WHERE call_id = r.call_id;
    n := n + 1;
  END LOOP;

  -- Same self-healing shape again, on human timescales: an await_human that
  -- nobody ever answers before its expires_at (set by fn_submit_result, 24h
  -- default) gets auto-rejected instead of holding the task open forever.
  -- Unlike the two loops above this has its own per-row deadline rather than
  -- p_timeout_seconds, since a human's response time has nothing to do with
  -- an HTTP call's or a sandboxed query's.
  FOR r IN
    SELECT approval_id, task_id
    FROM allgres_private.human_approvals
    WHERE status = 'pending'
      AND expires_at IS NOT NULL AND expires_at < now()
    FOR UPDATE SKIP LOCKED
  LOOP
    UPDATE allgres_private.human_approvals
    SET status = 'rejected', reply_text = 'approval_timeout', decided_at = now()
    WHERE approval_id = r.approval_id;

    SELECT step_count, session_id INTO v_step, v_session
    FROM allgres_private.tasks
    WHERE task_id = r.task_id AND status = 'waiting_human'
    FOR UPDATE;

    IF FOUND THEN
      PERFORM allgres_private.append_log(
        r.task_id, v_step + 1, 'operator',
        to_jsonb('No response before the approval expired.'::text)
      );
      UPDATE allgres_private.tasks
      SET status = 'failed', error = 'approval_timeout', step_count = step_count + 1, updated_at = now()
      WHERE task_id = r.task_id;
      PERFORM allgres_private.maybe_complete_session(v_session);
    END IF;
    n := n + 1;
  END LOOP;

  -- max_turn_seconds: a wall-clock ceiling on a task's whole lifetime once it
  -- has actually started, not tied to any particular in-flight call -- a
  -- task can blow this budget by taking many fast steps just as easily as
  -- one slow one, so it is checked against started_at rather than any single
  -- call's updated_at. Measured from started_at, not created_at: a 'queued'
  -- task waiting on a max_concurrent_tasks slot has never run a turn, so
  -- started_at is still NULL for it and this loop leaves it alone entirely
  -- -- otherwise a busy agent's own concurrency cap would starve a task long
  -- enough to have this kill it before its first turn. Terminal, like
  -- max_steps: no retry, straight to failed.
  FOR r IN
    SELECT t.task_id, t.session_id, t.step_count
    FROM allgres_private.tasks t
    JOIN allgres_private.policies p USING (agent_id)
    WHERE t.status IN ('running', 'waiting_human', 'waiting_children')
      AND p.max_turn_seconds IS NOT NULL
      AND t.started_at IS NOT NULL
      AND t.started_at < now() - make_interval(secs => p.max_turn_seconds)
    FOR UPDATE SKIP LOCKED
  LOOP
    PERFORM allgres_private.append_log(
      r.task_id, r.step_count + 1, 'error', jsonb_build_object('reason', 'turn_timeout')
    );
    UPDATE allgres_private.tasks
    SET status = 'failed', error = 'turn_timeout', step_count = step_count + 1, updated_at = now()
    WHERE task_id = r.task_id;
    -- Same reasoning as fn_cancel_session: whatever this task had queued or
    -- in flight when its wall clock ran out must not still fire after it is
    -- failed.
    UPDATE allgres_private.outbound_calls
    SET status = 'lost', error = 'turn_timeout', updated_at = now()
    WHERE task_id = r.task_id AND status IN ('queued', 'in_flight');
    UPDATE allgres_private.sql_calls
    SET status = 'lost', updated_at = now()
    WHERE task_id = r.task_id AND status IN ('queued', 'in_flight');
    PERFORM allgres_private.maybe_complete_session(r.session_id);
    n := n + 1;
  END LOOP;

  -- Roadmap item 5: the wake side of await_children. A task sitting in
  -- 'waiting_children' resumes the moment every one of its own children
  -- (parent_task_id = this task) has reached a terminal status -- checked
  -- fresh on every tick, entirely from what is already in this table, so a
  -- worker or database restart mid-wait loses nothing: the next tick just
  -- finds the same row again. No timeout of its own here (unlike
  -- human_approvals' expires_at above) -- a stuck child is caught by the
  -- max_turn_seconds sweep just above, which applies to 'waiting_children'
  -- exactly as it does to 'running'.
  FOR r IN
    SELECT t.task_id, t.step_count
    FROM allgres_private.tasks t
    WHERE t.status = 'waiting_children'
      AND NOT EXISTS (
        SELECT 1 FROM allgres_private.tasks c
        WHERE c.parent_task_id = t.task_id
          AND c.status NOT IN ('completed', 'failed', 'cancelled')
      )
    FOR UPDATE SKIP LOCKED
  LOOP
    PERFORM allgres_private.append_log(
      r.task_id, r.step_count + 1, 'tool',
      jsonb_build_object('delegate_results', COALESCE((
        SELECT jsonb_agg(jsonb_build_object(
          'agent', ca.name, 'status', c.status, 'output', c.output, 'error', c.error
        ) ORDER BY c.created_at)
        FROM allgres_private.tasks c
        JOIN allgres_private.agents ca ON ca.agent_id = c.agent_id
        WHERE c.parent_task_id = r.task_id
      ), '[]'::jsonb))
    );
    UPDATE allgres_private.tasks
    SET status = 'queued', step_count = step_count + 1, updated_at = now()
    WHERE task_id = r.task_id;
    n := n + 1;
  END LOOP;

  -- Garbage collection, not reclaim: an expired memory is already filtered
  -- out of fn_next_step's own recall query (WHERE expires_at IS NULL OR
  -- expires_at > now()), so nothing is broken by leaving a stale row sitting
  -- there -- this just keeps the table (and the 500-per-agent cap in
  -- fn_submit_result's `remember` handler) from accumulating dead weight
  -- indefinitely.
  DELETE FROM allgres_private.agent_memories WHERE expires_at IS NOT NULL AND expires_at < now();
  GET DIAGNOSTICS v_mem_gc = ROW_COUNT;

  RETURN jsonb_build_object('lost', n, 'memories_expired', v_mem_gc);
END;
$fn$;

CREATE OR REPLACE FUNCTION allgres_public.fn_pump(p_fallback_key text DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = allgres_private, allgres_public, pg_temp
AS $fn$
DECLARE
  d jsonb;
  c jsonb;
  w jsonb;
  s jsonb;
  o jsonb;
  sc jsonb;
BEGIN
  -- Does not perform HTTP or run sandboxed SQL.  Caller claims queued rows
  -- AFTER this commits.
  w := allgres_public.fn_watchdog();
  -- Roadmap item 6: due schedules fire before dispatch, so a session (and
  -- its first queued task) a schedule creates this very tick is picked up
  -- by the same fn_dispatch_tasks call right below, not left waiting a
  -- full extra tick.
  sc := allgres_public.fn_run_schedules();
  d := allgres_public.fn_dispatch_tasks();
  c := allgres_public.fn_claim_outbound(4, p_fallback_key);
  s := allgres_public.fn_claim_sql(4);
  o := allgres_public.fn_claim_oauth(4);
  RETURN jsonb_build_object(
    'watchdog', w, 'schedules', sc, 'dispatch', d, 'claim', c, 'claim_sql', s, 'claim_oauth', o
  );
END;
$fn$;

-- ---------------------------------------------------------------------------
-- 9. Operator API.  The console never SELECTs llm_secrets.
-- ---------------------------------------------------------------------------

-- Gives an agent its own PostgreSQL security identity: a NOLOGIN role,
-- named only from the agent's own uuid (never from operator- or
-- agent-supplied text, so the dynamic CREATE ROLE below has no injection
-- surface), a member of `sandbox` and of `worker` (the latter so the
-- runtime worker -- which only ever holds `worker` membership, never
-- `sandbox` directly beyond what GRANT sandbox TO worker already covers --
-- can SET LOCAL ROLE to it; SET ROLE requires membership in the target).
-- Idempotent: re-running it for an already-provisioned agent just returns
-- the existing role name.
--
-- This needs the ability to CREATE ROLE, which is not a new privilege
-- boundary: whatever installs the extension already creates allgres_owner,
-- operator, worker, and sandbox in the roles bootstrap above, so it already
-- has that power (typically as a superuser, or an installer role granted
-- CREATEROLE for exactly this). This function, like every other
-- SECURITY DEFINER function in this file, is owned by that same installer;
-- it does not need or request any privilege the installer did not already
-- have.
CREATE OR REPLACE FUNCTION allgres_private.fn_provision_agent_role(p_agent_id uuid)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = allgres_private, pg_temp
AS $fn$
DECLARE
  v_role text;
BEGIN
  SELECT pg_role INTO v_role FROM allgres_private.agents WHERE agent_id = p_agent_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'fn_provision_agent_role: agent not found' USING ERRCODE = 'P0001';
  END IF;
  IF v_role IS NOT NULL THEN
    RETURN v_role;
  END IF;

  v_role := 'allgres_agent_' || replace(p_agent_id::text, '-', '');

  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = v_role) THEN
    EXECUTE format(
      'CREATE ROLE %I NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS INHERIT',
      v_role
    );
    EXECUTE format('GRANT sandbox TO %I', v_role);
    EXECUTE format('GRANT %I TO worker', v_role);
    EXECUTE format('ALTER ROLE %I SET search_path = pg_temp', v_role);
  END IF;

  UPDATE allgres_private.agents SET pg_role = v_role WHERE agent_id = p_agent_id;
  RETURN v_role;
END;
$fn$;

CREATE OR REPLACE FUNCTION allgres_public.fn_create_agent(p_name text, p_prompt text DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = allgres_private, allgres_public, pg_temp
AS $fn$
DECLARE
  v_id uuid;
  v_role text;
BEGIN
  IF btrim(COALESCE(p_name, '')) = '' THEN
    RAISE EXCEPTION 'agent name required' USING ERRCODE = 'P0001';
  END IF;
  INSERT INTO allgres_private.agents (name)
  VALUES (btrim(p_name))
  RETURNING agent_id INTO v_id;
  IF p_prompt IS NOT NULL AND btrim(p_prompt) <> '' THEN
    UPDATE allgres_private.policies
    SET system_prompt = p_prompt, updated_at = now()
    WHERE agent_id = v_id;
  END IF;
  v_role := allgres_private.fn_provision_agent_role(v_id);
  PERFORM allgres_private.queue_agent_embedding(v_id);
  PERFORM allgres_private.audit('agents.create', jsonb_build_object('agent_id', v_id, 'name', btrim(p_name)));
  RETURN jsonb_build_object('ok', true, 'agent_id', v_id, 'pg_role', v_role);
END;
$fn$;

CREATE OR REPLACE FUNCTION allgres_public.fn_set_agent_active(p_agent_id uuid, p_active boolean)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = allgres_private, pg_temp
AS $fn$
BEGIN
  UPDATE allgres_private.agents
  SET is_active = p_active, updated_at = now()
  WHERE agent_id = p_agent_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'agent not found' USING ERRCODE = 'P0001';
  END IF;
  PERFORM allgres_private.audit('agents.update', jsonb_build_object('agent_id', p_agent_id, 'is_active', p_active));
  RETURN jsonb_build_object('ok', true, 'is_active', p_active);
END;
$fn$;

-- autonomy_level's own setter, separate from fn_set_policy: it is a
-- request-per-agent behavioral toggle (how much of creator/fixer/
-- self_improve's own consequential actions run unattended), not a policy
-- field an agent could ever propose_change for itself, and the CHECK
-- constraint on allgres_private.agents does the real validation -- this
-- just gives it a friendly error instead of a raw constraint-violation.
CREATE OR REPLACE FUNCTION allgres_public.fn_set_agent_autonomy(p_agent_id uuid, p_level text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = allgres_private, pg_temp
AS $fn$
BEGIN
  IF p_level IS NULL OR p_level NOT IN ('auto', 'self_approve', 'admin_approval') THEN
    RAISE EXCEPTION 'invalid autonomy_level: %', p_level USING ERRCODE = 'P0001';
  END IF;
  UPDATE allgres_private.agents
  SET autonomy_level = p_level, updated_at = now()
  WHERE agent_id = p_agent_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'agent not found' USING ERRCODE = 'P0001';
  END IF;
  PERFORM allgres_private.audit('agents.set_autonomy', jsonb_build_object('agent_id', p_agent_id, 'autonomy_level', p_level));
  RETURN jsonb_build_object('ok', true, 'autonomy_level', p_level);
END;
$fn$;

-- agent_config stays a fully open jsonb bag for any key a future tunable
-- needs -- see its own column comment, "a new tunable never needs a new
-- migration" -- but every key a *current* reader actually casts (the three
-- below, all via (value->>'key')::int) is checked here at set time instead
-- of only failing later, mid-turn, the moment maybe_trigger_compaction or
-- fn_messenger_post finally reads a bad one back. An unknown key -- the
-- whole reason this column is a jsonb bag and not one column per tunable --
-- is left alone entirely; only names this file's own readers already
-- depend on get a fail-fast check, and it never blocks the key from being
-- set to jsonb null (the documented "clear it back to default" signal,
-- checked before this loop ever sees it as a would-be integer).
CREATE OR REPLACE FUNCTION allgres_private.validate_agent_config(p_config jsonb)
RETURNS void
LANGUAGE plpgsql
AS $fn$
DECLARE
  r record;
  v_val jsonb;
  v_num numeric;
BEGIN
  FOR r IN
    SELECT * FROM (VALUES
      ('compaction_threshold', 1, 1000000),
      ('compaction_keep_recent', 0, 1000000),
      ('min_mentions_to_route', 1, 1000)
    ) AS t(key, min_val, max_val)
  LOOP
    IF NOT (p_config ? r.key) THEN
      CONTINUE;
    END IF;
    v_val := p_config -> r.key;
    IF jsonb_typeof(v_val) = 'null' THEN
      CONTINUE;
    END IF;
    IF jsonb_typeof(v_val) <> 'number' THEN
      RAISE EXCEPTION 'agent_config.% must be a number, got %', r.key, jsonb_typeof(v_val)
        USING ERRCODE = 'P0001';
    END IF;
    v_num := v_val::text::numeric;
    IF v_num <> trunc(v_num) THEN
      RAISE EXCEPTION 'agent_config.% must be a whole number, got %', r.key, v_num
        USING ERRCODE = 'P0001';
    END IF;
    IF v_num < r.min_val OR v_num > r.max_val THEN
      RAISE EXCEPTION 'agent_config.% must be between % and %, got %', r.key, r.min_val, r.max_val, v_num
        USING ERRCODE = 'P0001';
    END IF;
  END LOOP;
END;
$fn$;

-- agent_config's own setter: a shallow merge (||), the same "only touch
-- the keys you send" shape fn_set_project_config uses for preset_prompt --
-- clearing one tunable back to its coded default means sending it as
-- JSON null (jsonb_strip_nulls drops it, so the reader's own COALESCE
-- applies again), not omitting the key, which would leave whatever was
-- there before untouched.
CREATE OR REPLACE FUNCTION allgres_public.fn_set_agent_config(p_agent_id uuid, p_config jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = allgres_private, pg_temp
AS $fn$
DECLARE
  v_config jsonb;
BEGIN
  IF p_config IS NULL OR jsonb_typeof(p_config) <> 'object' THEN
    RAISE EXCEPTION 'agent_config must be a JSON object' USING ERRCODE = 'P0001';
  END IF;
  PERFORM allgres_private.validate_agent_config(p_config);
  UPDATE allgres_private.agents
  SET agent_config = jsonb_strip_nulls(agent_config || p_config), updated_at = now()
  WHERE agent_id = p_agent_id
  RETURNING agent_config INTO v_config;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'agent not found' USING ERRCODE = 'P0001';
  END IF;
  PERFORM allgres_private.audit('agents.update', jsonb_build_object('agent_id', p_agent_id, 'agent_config', p_config));
  RETURN jsonb_build_object('ok', true, 'agent_config', v_config);
END;
$fn$;

CREATE OR REPLACE FUNCTION allgres_public.fn_create_project(
  p_name text,
  p_description text DEFAULT NULL,
  p_agent_id uuid DEFAULT NULL,
  p_preset_prompt text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = allgres_private, pg_temp
AS $fn$
DECLARE
  v_id uuid;
BEGIN
  IF btrim(COALESCE(p_name, '')) = '' THEN
    RAISE EXCEPTION 'project name required' USING ERRCODE = 'P0001';
  END IF;
  IF p_agent_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM allgres_private.agents WHERE agent_id = p_agent_id AND is_active
  ) THEN
    RAISE EXCEPTION 'agent inactive or missing' USING ERRCODE = 'P0001';
  END IF;
  INSERT INTO allgres_private.projects (name, description, agent_id, preset_prompt)
  VALUES (
    btrim(p_name), NULLIF(btrim(COALESCE(p_description, '')), ''),
    p_agent_id, NULLIF(btrim(COALESCE(p_preset_prompt, '')), '')
  )
  RETURNING project_id INTO v_id;
  PERFORM allgres_private.audit('projects.create', jsonb_build_object('project_id', v_id, 'name', btrim(p_name)));
  RETURN jsonb_build_object('ok', true, 'project_id', v_id);
END;
$fn$;

CREATE OR REPLACE FUNCTION allgres_public.fn_set_project_active(p_project_id uuid, p_active boolean)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = allgres_private, pg_temp
AS $fn$
BEGIN
  UPDATE allgres_private.projects
  SET is_active = p_active, updated_at = now()
  WHERE project_id = p_project_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'project not found' USING ERRCODE = 'P0001';
  END IF;
  PERFORM allgres_private.audit('projects.update', jsonb_build_object('project_id', p_project_id, 'is_active', p_active));
  RETURN jsonb_build_object('ok', true, 'is_active', p_active);
END;
$fn$;

-- Project mode's chat config (item 42), separate from fn_set_project_active
-- the same way fn_set_agent_autonomy is separate from fn_set_agent_active:
-- a project already usable as a plain session label needs neither field
-- touched, so this is opt-in per call (NULL means "leave unchanged" for
-- agent_id, and preset_prompt is only cleared by passing an empty string).
CREATE OR REPLACE FUNCTION allgres_public.fn_set_project_config(
  p_project_id uuid, p_agent_id uuid DEFAULT NULL, p_preset_prompt text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = allgres_private, pg_temp
AS $fn$
BEGIN
  IF p_agent_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM allgres_private.agents WHERE agent_id = p_agent_id AND is_active
  ) THEN
    RAISE EXCEPTION 'agent inactive or missing' USING ERRCODE = 'P0001';
  END IF;
  UPDATE allgres_private.projects
  SET agent_id = COALESCE(p_agent_id, agent_id),
      preset_prompt = COALESCE(p_preset_prompt, preset_prompt),
      updated_at = now()
  WHERE project_id = p_project_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'project not found' USING ERRCODE = 'P0001';
  END IF;
  PERFORM allgres_private.audit('projects.update', jsonb_build_object('project_id', p_project_id, 'agent_id', p_agent_id, 'preset_prompt', p_preset_prompt));
  RETURN jsonb_build_object('ok', true);
END;
$fn$;

-- Versions only on a real change: agents.update calls this on every save
-- (e.g. just flipping is_active), and if that always snapshotted history and
-- bumped generation, "version 47" would mean nothing -- most of the chain
-- would be identical no-op copies of the row next to it.  IS DISTINCT FROM
-- against the row as it stood at the top of this call is what tells the two
-- apart.
CREATE OR REPLACE FUNCTION allgres_public.fn_set_policy(
  p_agent_id uuid,
  p_prompt text DEFAULT NULL,
  p_max_steps int DEFAULT NULL,
  p_max_retries int DEFAULT NULL,
  p_llm_config jsonb DEFAULT NULL,
  p_max_concurrent_tasks int DEFAULT NULL,
  p_max_turn_seconds int DEFAULT NULL,
  p_clear_max_turn_seconds boolean DEFAULT false,
  p_max_delegation_depth int DEFAULT NULL,
  p_max_session_tasks int DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = allgres_private, pg_temp
AS $fn$
DECLARE
  p_row allgres_private.policies%ROWTYPE;
  v_prompt text;
  v_steps int;
  v_retries int;
  v_cfg jsonb;
  v_concurrent int;
  v_turn_secs int;
  v_deleg_depth int;
  v_session_tasks int;
  v_changed boolean;
BEGIN
  SELECT * INTO p_row FROM allgres_private.policies WHERE agent_id = p_agent_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'policy not found' USING ERRCODE = 'P0001';
  END IF;

  v_prompt     := COALESCE(NULLIF(p_prompt, ''), p_row.system_prompt);
  v_steps      := COALESCE(p_max_steps, p_row.max_steps);
  v_retries    := COALESCE(p_max_retries, p_row.max_retries);
  v_cfg        := CASE WHEN p_llm_config IS NULL THEN p_row.llm_config
                       ELSE allgres_private.sanitize_llm_config(p_row.llm_config || p_llm_config) END;
  v_concurrent := COALESCE(p_max_concurrent_tasks, p_row.max_concurrent_tasks);
  -- max_turn_seconds is the one field whose desired value can legitimately be
  -- NULL ("no cap"), so unlike the others a NULL argument can't just mean
  -- "leave it alone" -- p_clear_max_turn_seconds is the explicit way to ask
  -- for that, distinct from simply not passing the parameter.
  v_turn_secs  := CASE WHEN p_clear_max_turn_seconds THEN NULL
                       ELSE COALESCE(p_max_turn_seconds, p_row.max_turn_seconds) END;
  v_deleg_depth   := COALESCE(p_max_delegation_depth, p_row.max_delegation_depth);
  v_session_tasks := COALESCE(p_max_session_tasks, p_row.max_session_tasks);

  v_changed := v_prompt IS DISTINCT FROM p_row.system_prompt
    OR v_steps IS DISTINCT FROM p_row.max_steps
    OR v_retries IS DISTINCT FROM p_row.max_retries
    OR v_cfg IS DISTINCT FROM p_row.llm_config
    OR v_concurrent IS DISTINCT FROM p_row.max_concurrent_tasks
    OR v_turn_secs IS DISTINCT FROM p_row.max_turn_seconds
    OR v_deleg_depth IS DISTINCT FROM p_row.max_delegation_depth
    OR v_session_tasks IS DISTINCT FROM p_row.max_session_tasks;

  IF v_changed THEN
    INSERT INTO allgres_private.policy_history (
      agent_id, generation, system_prompt, max_steps, max_retries, llm_config,
      max_concurrent_tasks, max_turn_seconds, max_delegation_depth, max_session_tasks,
      success_rate_at_change
    ) VALUES (
      p_row.agent_id, p_row.generation, p_row.system_prompt, p_row.max_steps,
      p_row.max_retries, p_row.llm_config, p_row.max_concurrent_tasks, p_row.max_turn_seconds,
      p_row.max_delegation_depth, p_row.max_session_tasks,
      (SELECT rate FROM allgres_private.agent_success_rate_for_generation(p_row.agent_id, p_row.generation, 20))
    );
  END IF;

  UPDATE allgres_private.policies
  SET system_prompt = v_prompt,
      max_steps = v_steps,
      max_retries = v_retries,
      llm_config = v_cfg,
      max_concurrent_tasks = v_concurrent,
      max_turn_seconds = v_turn_secs,
      max_delegation_depth = v_deleg_depth,
      max_session_tasks = v_session_tasks,
      generation = generation + (CASE WHEN v_changed THEN 1 ELSE 0 END),
      updated_at = now()
  WHERE agent_id = p_agent_id;

  IF v_changed THEN
    PERFORM allgres_private.audit('agents.update', jsonb_build_object(
      'agent_id', p_agent_id, 'field', 'policy',
      'generation', p_row.generation + 1,
      'llm_config', v_cfg, 'max_steps', v_steps, 'max_retries', v_retries,
      'max_concurrent_tasks', v_concurrent, 'max_turn_seconds', v_turn_secs,
      'max_delegation_depth', v_deleg_depth, 'max_session_tasks', v_session_tasks
    ));
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'generation', p_row.generation + (CASE WHEN v_changed THEN 1 ELSE 0 END),
    'changed', v_changed
  );
END;
$fn$;

-- Bulk-set every active agent's provider/model in one call, reusing
-- fn_set_policy's own merge (a per-agent system_prompt/max_steps/etc. is
-- left untouched -- only llm_config.provider/model change) rather than a
-- silent global fallback an agent with nothing configured would ever
-- reach on its own: README has said from early on that "there is no
-- fallback provider or model name baked in anywhere" and that stays true
-- here too -- this is one explicit, admin-initiated write touching every
-- row at once, the same as if an operator had opened each agent's editor
-- and typed the same two fields in, not a standing default new agents
-- inherit later. System agents are included -- they run turns the same
-- way any other agent does and would otherwise be the one thing this
-- can't reach in one pass.
CREATE OR REPLACE FUNCTION allgres_public.fn_bulk_set_model(
  p_provider text,
  p_model text
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = allgres_private, allgres_public, pg_temp
AS $fn$
DECLARE
  v_agent record;
  v_count int := 0;
BEGIN
  IF NULLIF(trim(p_provider), '') IS NULL OR NULLIF(trim(p_model), '') IS NULL THEN
    RAISE EXCEPTION 'provider and model are both required' USING ERRCODE = 'P0001';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM allgres_private.llm_providers WHERE name = p_provider AND is_enabled
  ) THEN
    RAISE EXCEPTION 'llm provider "%" is not configured or not enabled', p_provider
      USING ERRCODE = 'P0001';
  END IF;

  FOR v_agent IN SELECT agent_id FROM allgres_private.agents WHERE is_active LOOP
    PERFORM allgres_public.fn_set_policy(
      v_agent.agent_id, NULL, NULL, NULL,
      jsonb_build_object('provider', p_provider, 'model', p_model)
    );
    v_count := v_count + 1;
  END LOOP;

  PERFORM allgres_private.audit('agents.bulk_set_model', jsonb_build_object('provider', p_provider, 'model', p_model, 'updated_count', v_count));
  RETURN jsonb_build_object('ok', true, 'updated_count', v_count);
END;
$fn$;

-- Operator-only: an agent's own propose_change action (fn_submit_result)
-- only ever reaches this table, never the live policy directly. Approving
-- applies the change through fn_set_policy -- the same versioning path any
-- other policy edit goes through, so a promoted proposal shows up in
-- policy_history exactly like an operator's own edit would.
CREATE OR REPLACE FUNCTION allgres_public.fn_decide_proposal(
  p_proposal_id uuid, p_approve boolean, p_reply text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = allgres_private, allgres_public, pg_temp
AS $fn$
DECLARE
  r allgres_private.change_proposals%ROWTYPE;
  v_cur_gen int;
  v_policy jsonb;
  v_target uuid;
  v_created jsonb;
BEGIN
  SELECT * INTO r FROM allgres_private.change_proposals WHERE proposal_id = p_proposal_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'fn_decide_proposal: not found' USING ERRCODE = 'P0001';
  END IF;
  IF r.status <> 'pending' THEN
    RAISE EXCEPTION 'fn_decide_proposal: already decided (%)', r.status USING ERRCODE = 'P0001';
  END IF;

  IF NOT p_approve THEN
    UPDATE allgres_private.change_proposals
    SET status = 'rejected', decided_at = now(), decided_reply = p_reply
    WHERE proposal_id = p_proposal_id;
    PERFORM allgres_private.audit('proposals.decide', jsonb_build_object('proposal_id', p_proposal_id, 'status', 'rejected'));
    RETURN jsonb_build_object('ok', true, 'status', 'rejected');
  END IF;

  -- 'create_agent' (the creator system agent): there is no existing policy
  -- to go stale, so the generation check below does not apply -- it simply
  -- creates the agent proposed_changes described.
  IF r.kind = 'create_agent' THEN
    v_created := allgres_public.fn_create_agent(
      r.proposed_changes->>'name', r.proposed_changes->>'system_prompt'
    );
    UPDATE allgres_private.change_proposals
    SET status = 'approved', decided_at = now(), decided_reply = p_reply
    WHERE proposal_id = p_proposal_id;
    PERFORM allgres_private.audit('proposals.decide', jsonb_build_object('proposal_id', p_proposal_id, 'status', 'approved', 'kind', 'create_agent'));
    RETURN jsonb_build_object('ok', true, 'status', 'approved', 'created_agent', v_created);
  END IF;

  -- 'policy_change': target_agent_id is who this actually changes -- the
  -- proposer itself (agent_id) for every ordinary propose_change, or a
  -- different agent for self_improve's cross-agent proposals (see
  -- fn_submit_result). The live policy may have moved on since this was
  -- proposed -- an operator edit, or another proposal already applied.
  -- Approving blindly here would silently clobber whatever changed it with
  -- a decision made against a policy that no longer exists; mark it stale
  -- instead and let the operator re-propose or handle it directly.
  v_target := COALESCE(r.target_agent_id, r.agent_id);
  SELECT generation INTO v_cur_gen FROM allgres_private.policies WHERE agent_id = v_target;
  IF v_cur_gen IS DISTINCT FROM r.base_generation THEN
    UPDATE allgres_private.change_proposals
    SET status = 'stale', decided_at = now(),
        decided_reply = COALESCE(p_reply, 'base policy changed since this was proposed')
    WHERE proposal_id = p_proposal_id;
    PERFORM allgres_private.audit('proposals.decide', jsonb_build_object('proposal_id', p_proposal_id, 'status', 'stale'));
    RETURN jsonb_build_object('ok', false, 'status', 'stale');
  END IF;

  v_policy := allgres_public.fn_set_policy(
    v_target,
    r.proposed_changes->>'system_prompt',
    NULL, NULL,
    r.proposed_changes->'llm_config',
    NULL, NULL, false
  );

  UPDATE allgres_private.change_proposals
  SET status = 'approved', decided_at = now(), decided_reply = p_reply
  WHERE proposal_id = p_proposal_id;

  PERFORM allgres_private.audit('proposals.decide', jsonb_build_object('proposal_id', p_proposal_id, 'status', 'approved', 'kind', 'policy_change', 'target_agent_id', v_target));
  RETURN jsonb_build_object('ok', true, 'status', 'approved', 'policy', v_policy);
END;
$fn$;

-- Restores a prior policy version through the same fn_set_policy path any
-- other change takes: rolling back is never a mutation of policy_history,
-- only ever a new version that happens to match an old one -- the current
-- live row still gets snapshotted into history before being overwritten,
-- same as always.
CREATE OR REPLACE FUNCTION allgres_public.fn_rollback_policy(p_agent_id uuid, p_generation int)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = allgres_private, allgres_public, pg_temp
AS $fn$
DECLARE
  h allgres_private.policy_history%ROWTYPE;
BEGIN
  SELECT * INTO h FROM allgres_private.policy_history
  WHERE agent_id = p_agent_id AND generation = p_generation;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'fn_rollback_policy: no history for that agent at generation %', p_generation
      USING ERRCODE = 'P0001';
  END IF;

  PERFORM allgres_private.audit('policy.rollback', jsonb_build_object('agent_id', p_agent_id, 'restored_generation', p_generation));
  RETURN allgres_public.fn_set_policy(
    p_agent_id, h.system_prompt, h.max_steps, h.max_retries, h.llm_config,
    h.max_concurrent_tasks, h.max_turn_seconds, h.max_turn_seconds IS NULL,
    h.max_delegation_depth, h.max_session_tasks
  );
END;
$fn$;

-- Roadmap item 7: "did the last change to this agent actually help" as a
-- real, computed verdict, not something an operator (or self_improve) has
-- to eyeball two numbers to answer. Compares the agent's success rate
-- under its CURRENT policy generation against its rate under the
-- immediately preceding one -- both computed live, right now, by
-- allgres_private.agent_success_rate_for_generation, rather than the
-- current generation's live rate against a frozen success_rate_at_change
-- snapshot from whatever the "recent tasks" window happened to contain at
-- change time. An outside review pointed out that "recent" is not the
-- same question as "under this policy": a handful of tasks queued right
-- before a change and a handful queued right after both landing in one
-- undifferentiated window could call a regression an improvement (or vice
-- versa) purely from which side of the boundary they happened to fall on.
-- Isolating both sides by tasks.policy_generation closes that gap.
--
-- p_min_samples (default 5, floored at 1) is the second half of that same
-- review finding: "completed" is a proxy for task throughput, not for
-- correctness, and even that proxy is noisy on a handful of tasks. Either
-- side short of this floor withholds a verdict ('insufficient_data')
-- rather than call a real trend from what could just as easily be luck --
-- this is a completion-rate signal, not a semantic judge of whether the
-- agent's actual output was correct; see README, "Evaluation-gated
-- self-improvement" for what a real per-task correctness judge would
-- still need that this does not attempt.
CREATE OR REPLACE FUNCTION allgres_public.fn_evaluate_last_change(p_agent_id uuid, p_min_samples int DEFAULT 5)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = allgres_private, pg_temp
AS $fn$
DECLARE
  v_gen int;
  v_changed_at timestamptz;
  v_current_rate numeric;
  v_current_n int;
  v_before_rate numeric;
  v_before_n int;
  v_min int := GREATEST(1, COALESCE(p_min_samples, 5));
  v_verdict text;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM allgres_private.agents WHERE agent_id = p_agent_id) THEN
    RAISE EXCEPTION 'agent not found' USING ERRCODE = 'P0001';
  END IF;

  SELECT generation INTO v_gen FROM allgres_private.policies WHERE agent_id = p_agent_id;

  SELECT changed_at INTO v_changed_at
  FROM allgres_private.policy_history
  WHERE agent_id = p_agent_id AND generation = v_gen - 1;

  IF NOT FOUND THEN
    v_verdict := 'no_change_recorded_yet';
  ELSE
    SELECT rate, sample_size INTO v_current_rate, v_current_n
    FROM allgres_private.agent_success_rate_for_generation(p_agent_id, v_gen, 20);
    SELECT rate, sample_size INTO v_before_rate, v_before_n
    FROM allgres_private.agent_success_rate_for_generation(p_agent_id, v_gen - 1, 20);

    IF COALESCE(v_current_n, 0) < v_min OR COALESCE(v_before_n, 0) < v_min THEN
      v_verdict := 'insufficient_data';
    ELSIF v_current_rate > v_before_rate THEN
      v_verdict := 'improved';
    ELSIF v_current_rate < v_before_rate THEN
      v_verdict := 'regressed';
    ELSE
      v_verdict := 'unchanged';
    END IF;
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'verdict', v_verdict,
    'current_success_rate', v_current_rate,
    'current_sample_size', COALESCE(v_current_n, 0),
    'success_rate_before_last_change', v_before_rate,
    'before_sample_size', COALESCE(v_before_n, 0),
    'min_samples_required', v_min,
    'compared_to_generation', v_gen - 1,
    'last_changed_at', v_changed_at
  );
END;
$fn$;

-- ---------------------------------------------------------------------------
-- Roadmap item 4: procedures -- see allgres_private.procedures' own comment.
-- Same create/set/rollback shape as fn_create_provider/fn_set_policy/
-- fn_rollback_policy on purpose: this is the same "named row, versioned,
-- only actually snapshotted on a real change" problem with a different
-- consumer (a grantable, agent-recallable text blob instead of a provider
-- endpoint or an agent's own policy).
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION allgres_public.fn_create_procedure(p_name text, p_content text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = allgres_private, pg_temp
AS $fn$
DECLARE
  v_id uuid;
BEGIN
  IF NULLIF(trim(p_name), '') IS NULL THEN
    RAISE EXCEPTION 'procedure name is required' USING ERRCODE = 'P0001';
  END IF;
  IF NULLIF(trim(p_content), '') IS NULL THEN
    RAISE EXCEPTION 'procedure content is required' USING ERRCODE = 'P0001';
  END IF;
  INSERT INTO allgres_private.procedures (name, content)
  VALUES (trim(p_name), p_content)
  RETURNING procedure_id INTO v_id;
  PERFORM allgres_private.audit('procedures.create', jsonb_build_object('procedure_id', v_id, 'name', trim(p_name)));
  RETURN jsonb_build_object('ok', true, 'procedure_id', v_id);
END;
$fn$;

CREATE OR REPLACE FUNCTION allgres_public.fn_set_procedure(
  p_procedure_id uuid,
  p_content text DEFAULT NULL,
  p_enabled boolean DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = allgres_private, pg_temp
AS $fn$
DECLARE
  p_row allgres_private.procedures%ROWTYPE;
  v_content text;
  v_changed boolean;
BEGIN
  SELECT * INTO p_row FROM allgres_private.procedures WHERE procedure_id = p_procedure_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'procedure not found' USING ERRCODE = 'P0001';
  END IF;

  v_content := COALESCE(NULLIF(p_content, ''), p_row.content);
  v_changed := v_content IS DISTINCT FROM p_row.content;

  IF v_changed THEN
    INSERT INTO allgres_private.procedure_history (procedure_id, generation, content)
    VALUES (p_row.procedure_id, p_row.generation, p_row.content);
  END IF;

  UPDATE allgres_private.procedures
  SET content = v_content,
      is_active = COALESCE(p_enabled, is_active),
      generation = generation + (CASE WHEN v_changed THEN 1 ELSE 0 END),
      updated_at = now()
  WHERE procedure_id = p_procedure_id;

  PERFORM allgres_private.audit('procedures.update', jsonb_build_object(
    'procedure_id', p_procedure_id, 'changed', v_changed, 'enabled', p_enabled,
    'generation', p_row.generation + (CASE WHEN v_changed THEN 1 ELSE 0 END)
  ));
  RETURN jsonb_build_object(
    'ok', true,
    'generation', p_row.generation + (CASE WHEN v_changed THEN 1 ELSE 0 END),
    'changed', v_changed
  );
END;
$fn$;

-- Same shape as fn_rollback_policy: never a mutation of procedure_history,
-- only ever a new version (via fn_set_procedure) that happens to match an
-- old one.
CREATE OR REPLACE FUNCTION allgres_public.fn_rollback_procedure(p_procedure_id uuid, p_generation int)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = allgres_private, allgres_public, pg_temp
AS $fn$
DECLARE
  h allgres_private.procedure_history%ROWTYPE;
BEGIN
  SELECT * INTO h FROM allgres_private.procedure_history
  WHERE procedure_id = p_procedure_id AND generation = p_generation;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'fn_rollback_procedure: no history for that procedure at generation %', p_generation
      USING ERRCODE = 'P0001';
  END IF;
  PERFORM allgres_private.audit('procedures.rollback', jsonb_build_object('procedure_id', p_procedure_id, 'restored_generation', p_generation));
  RETURN allgres_public.fn_set_procedure(p_procedure_id, h.content, NULL);
END;
$fn$;

CREATE OR REPLACE FUNCTION allgres_public.fn_grant_permission(
  p_agent_id uuid, p_type text, p_ref text
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = allgres_private, pg_temp
AS $fn$
BEGIN
  INSERT INTO allgres_private.permissions (agent_id, resource_type, resource_ref)
  VALUES (p_agent_id, p_type, p_ref)
  ON CONFLICT (agent_id, resource_type, resource_ref) DO NOTHING;
  PERFORM allgres_private.audit('permissions.grant', jsonb_build_object('agent_id', p_agent_id, 'type', p_type, 'ref', p_ref));
  RETURN jsonb_build_object('ok', true);
END;
$fn$;

CREATE OR REPLACE FUNCTION allgres_public.fn_revoke_permission(
  p_agent_id uuid, p_type text, p_ref text
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = allgres_private, pg_temp
AS $fn$
BEGIN
  DELETE FROM allgres_private.permissions
  WHERE agent_id = p_agent_id AND resource_type = p_type AND resource_ref = p_ref;
  PERFORM allgres_private.audit('permissions.revoke', jsonb_build_object('agent_id', p_agent_id, 'type', p_type, 'ref', p_ref));
  RETURN jsonb_build_object('ok', true);
END;
$fn$;

-- What a fixer proposal actually does once let through -- shared by
-- fn_decide_fix (admin_approval level) and fn_submit_result's immediate
-- path (auto/self_approve level), so there is exactly one place that knows
-- how to turn a fix_kind into a real change.
CREATE OR REPLACE FUNCTION allgres_private.apply_fix(
  p_fix_kind text, p_target_agent_id uuid, p_detail jsonb
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = allgres_private, allgres_public, pg_temp
AS $fn$
BEGIN
  IF p_fix_kind = 'revoke_permission' THEN
    RETURN allgres_public.fn_revoke_permission(
      p_target_agent_id, p_detail->>'resource_type', p_detail->>'resource_ref'
    );
  ELSIF p_fix_kind = 'deactivate_agent' THEN
    RETURN allgres_public.fn_set_agent_active(p_target_agent_id, false);
  END IF;
  RAISE EXCEPTION 'apply_fix: unknown fix_kind %', p_fix_kind USING ERRCODE = 'P0001';
END;
$fn$;

CREATE OR REPLACE FUNCTION allgres_public.fn_decide_fix(
  p_fix_id uuid, p_approve boolean, p_reply text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = allgres_private, allgres_public, pg_temp
AS $fn$
DECLARE
  r allgres_private.fix_proposals%ROWTYPE;
  v_result jsonb;
BEGIN
  SELECT * INTO r FROM allgres_private.fix_proposals WHERE fix_id = p_fix_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'fn_decide_fix: not found' USING ERRCODE = 'P0001';
  END IF;
  IF r.status <> 'pending' THEN
    RAISE EXCEPTION 'fn_decide_fix: already decided (%)', r.status USING ERRCODE = 'P0001';
  END IF;

  IF NOT p_approve THEN
    UPDATE allgres_private.fix_proposals
    SET status = 'rejected', decided_at = now(), decided_reply = p_reply
    WHERE fix_id = p_fix_id;
    PERFORM allgres_private.audit('fixes.decide', jsonb_build_object('fix_id', p_fix_id, 'status', 'rejected'));
    RETURN jsonb_build_object('ok', true, 'status', 'rejected');
  END IF;

  v_result := allgres_private.apply_fix(r.fix_kind, r.target_agent_id, r.detail);

  UPDATE allgres_private.fix_proposals
  SET status = 'approved', decided_at = now(), decided_reply = p_reply
  WHERE fix_id = p_fix_id;

  PERFORM allgres_private.audit('fixes.decide', jsonb_build_object('fix_id', p_fix_id, 'status', 'approved'));
  RETURN jsonb_build_object('ok', true, 'status', 'approved', 'result', v_result);
END;
$fn$;

CREATE OR REPLACE FUNCTION allgres_public.fn_create_session(
  p_agent_id uuid,
  p_goal text,
  p_project_id uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = allgres_private, pg_temp
AS $fn$
DECLARE
  v_sid uuid;
  v_tid uuid;
BEGIN
  IF btrim(COALESCE(p_goal, '')) = '' THEN
    RAISE EXCEPTION 'goal required' USING ERRCODE = 'P0001';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM allgres_private.agents WHERE agent_id = p_agent_id AND is_active) THEN
    RAISE EXCEPTION 'agent inactive or missing' USING ERRCODE = 'P0001';
  END IF;
  IF p_project_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM allgres_private.projects WHERE project_id = p_project_id AND is_active
  ) THEN
    RAISE EXCEPTION 'project inactive or missing' USING ERRCODE = 'P0001';
  END IF;
  INSERT INTO allgres_private.sessions (agent_id, project_id, goal, status)
  VALUES (p_agent_id, p_project_id, btrim(p_goal), 'open')
  RETURNING session_id INTO v_sid;
  INSERT INTO allgres_private.tasks (session_id, agent_id, status, input, policy_generation)
  VALUES (v_sid, p_agent_id, 'queued', jsonb_build_object('goal', btrim(p_goal)),
          (SELECT generation FROM allgres_private.policies WHERE agent_id = p_agent_id))
  RETURNING task_id INTO v_tid;
  INSERT INTO allgres_private.execution_logs (task_id, step_number, role, content)
  VALUES (v_tid, 0, 'user', to_jsonb(btrim(p_goal)));
  RETURN jsonb_build_object('ok', true, 'session_id', v_sid, 'task_id', v_tid);
END;
$fn$;

-- Before this, a session was a one-shot exchange: fn_create_session, one
-- task, done -- there was no way to send a follow-up in the same
-- conversation, only start a brand new session that remembered nothing.
-- This creates a new root-level task in the *same* session; fn_next_step's
-- message assembly now stitches every root-level task in a session back
-- together (see its own comment), so the agent sees the prior turns too,
-- not just this one message.
CREATE OR REPLACE FUNCTION allgres_public.fn_continue_session(
  p_session_id uuid,
  p_message text
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = allgres_private, pg_temp
AS $fn$
DECLARE
  s allgres_private.sessions%ROWTYPE;
  v_tid uuid;
BEGIN
  IF btrim(COALESCE(p_message, '')) = '' THEN
    RAISE EXCEPTION 'message required' USING ERRCODE = 'P0001';
  END IF;

  SELECT * INTO s FROM allgres_private.sessions WHERE session_id = p_session_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'session not found' USING ERRCODE = 'P0001';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM allgres_private.agents WHERE agent_id = s.agent_id AND is_active) THEN
    RAISE EXCEPTION 'agent inactive or missing' USING ERRCODE = 'P0001';
  END IF;

  -- One turn at a time: a second message while the agent is still working
  -- the last one would race fn_next_step's own read of this session's
  -- root-level tasks rather than cleanly queue behind it.
  IF EXISTS (
    SELECT 1 FROM allgres_private.tasks
    WHERE session_id = p_session_id AND parent_task_id IS NULL
      AND status IN ('queued', 'running', 'waiting_human', 'waiting_children')
  ) THEN
    RAISE EXCEPTION 'this session has a turn still in progress -- wait for it to finish before sending another message'
      USING ERRCODE = 'P0001';
  END IF;

  -- A session that already finished (or was cancelled) is reopened by a new
  -- message the same way a chat thread resumes when someone replies to it.
  UPDATE allgres_private.sessions
  SET status = 'open', completed_at = NULL
  WHERE session_id = p_session_id;

  INSERT INTO allgres_private.tasks (session_id, agent_id, status, input, policy_generation)
  VALUES (p_session_id, s.agent_id, 'queued', jsonb_build_object('goal', btrim(p_message)),
          (SELECT generation FROM allgres_private.policies WHERE agent_id = s.agent_id))
  RETURNING task_id INTO v_tid;
  INSERT INTO allgres_private.execution_logs (task_id, step_number, role, content)
  VALUES (v_tid, 0, 'user', to_jsonb(btrim(p_message)));

  RETURN jsonb_build_object('ok', true, 'session_id', p_session_id, 'task_id', v_tid);
END;
$fn$;

-- ---------------------------------------------------------------------------
-- Roadmap item 6: schedules -- see allgres_private.schedules' own comment.
-- Same create/set/delete shape as fn_create_connection/fn_set_connection on
-- purpose: a named, operator-managed row with its own lifecycle.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION allgres_public.fn_create_schedule(
  p_name text,
  p_agent_id uuid,
  p_goal text,
  p_interval_seconds int,
  p_max_runs int DEFAULT NULL,
  p_ends_at timestamptz DEFAULT NULL,
  p_start_at timestamptz DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = allgres_private, pg_temp
AS $fn$
DECLARE
  v_id uuid;
BEGIN
  IF NULLIF(trim(p_name), '') IS NULL THEN
    RAISE EXCEPTION 'schedule name is required' USING ERRCODE = 'P0001';
  END IF;
  IF NULLIF(trim(p_goal), '') IS NULL THEN
    RAISE EXCEPTION 'schedule goal is required' USING ERRCODE = 'P0001';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM allgres_private.agents WHERE agent_id = p_agent_id AND is_active) THEN
    RAISE EXCEPTION 'agent inactive or missing' USING ERRCODE = 'P0001';
  END IF;
  IF COALESCE(p_interval_seconds, 0) <= 0 THEN
    RAISE EXCEPTION 'interval_seconds must be a positive number of seconds' USING ERRCODE = 'P0001';
  END IF;
  IF p_max_runs IS NOT NULL AND p_max_runs <= 0 THEN
    RAISE EXCEPTION 'max_runs must be a positive number' USING ERRCODE = 'P0001';
  END IF;

  INSERT INTO allgres_private.schedules (name, agent_id, goal, interval_seconds, next_run_at, max_runs, ends_at)
  VALUES (trim(p_name), p_agent_id, trim(p_goal), p_interval_seconds, COALESCE(p_start_at, now()), p_max_runs, p_ends_at)
  RETURNING schedule_id INTO v_id;
  PERFORM allgres_private.audit('schedules.create', jsonb_build_object(
    'schedule_id', v_id, 'name', trim(p_name), 'agent_id', p_agent_id, 'interval_seconds', p_interval_seconds
  ));
  RETURN jsonb_build_object('ok', true, 'schedule_id', v_id);
END;
$fn$;

CREATE OR REPLACE FUNCTION allgres_public.fn_set_schedule(
  p_schedule_id uuid,
  p_goal text DEFAULT NULL,
  p_interval_seconds int DEFAULT NULL,
  p_is_active boolean DEFAULT NULL,
  p_max_runs int DEFAULT NULL,
  p_clear_max_runs boolean DEFAULT false,
  p_ends_at timestamptz DEFAULT NULL,
  p_clear_ends_at boolean DEFAULT false
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = allgres_private, pg_temp
AS $fn$
DECLARE
  s allgres_private.schedules%ROWTYPE;
BEGIN
  SELECT * INTO s FROM allgres_private.schedules WHERE schedule_id = p_schedule_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'schedule not found' USING ERRCODE = 'P0001';
  END IF;
  IF p_interval_seconds IS NOT NULL AND p_interval_seconds <= 0 THEN
    RAISE EXCEPTION 'interval_seconds must be a positive number of seconds' USING ERRCODE = 'P0001';
  END IF;

  UPDATE allgres_private.schedules
  SET goal = COALESCE(NULLIF(p_goal, ''), goal),
      interval_seconds = COALESCE(p_interval_seconds, interval_seconds),
      is_active = COALESCE(p_is_active, is_active),
      max_runs = CASE WHEN p_clear_max_runs THEN NULL ELSE COALESCE(p_max_runs, max_runs) END,
      ends_at = CASE WHEN p_clear_ends_at THEN NULL ELSE COALESCE(p_ends_at, ends_at) END,
      updated_at = now()
  WHERE schedule_id = p_schedule_id;
  PERFORM allgres_private.audit('schedules.update', jsonb_build_object('schedule_id', p_schedule_id, 'is_active', p_is_active));
  RETURN jsonb_build_object('ok', true);
END;
$fn$;

-- No FK cascade onto a schedule from anything that must survive it (a past
-- run's own session stands on its own once created -- see last_session_id's
-- ON DELETE default, no action, matching how a delegated task outlives a
-- deleted parent nowhere in this file either). Deleting a schedule only
-- ever removes the row that decides whether it fires again; every session
-- it already created stays exactly as it was.
CREATE OR REPLACE FUNCTION allgres_public.fn_delete_schedule(p_schedule_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = allgres_private, pg_temp
AS $fn$
BEGIN
  DELETE FROM allgres_private.schedules WHERE schedule_id = p_schedule_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'schedule not found' USING ERRCODE = 'P0001';
  END IF;
  PERFORM allgres_private.audit('schedules.delete', jsonb_build_object('schedule_id', p_schedule_id));
  RETURN jsonb_build_object('ok', true);
END;
$fn$;

-- The firing sweep, called from fn_pump every tick alongside fn_watchdog/
-- fn_dispatch_tasks -- entirely a poll against next_run_at, no external
-- scheduler and nothing held in worker memory, so a restart between ticks
-- loses nothing: the next tick just finds the same due row again. Always
-- reschedules from *now*, never by walking next_run_at forward in
-- interval_seconds steps -- a schedule that missed several intervals while
-- the extension was down (or simply never got a tick) fires once to catch
-- up, not N times in a burst.
CREATE OR REPLACE FUNCTION allgres_public.fn_run_schedules()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = allgres_private, allgres_public, pg_temp
AS $fn$
DECLARE
  r record;
  v_created jsonb;
  n int := 0;
BEGIN
  PERFORM set_config('statement_timeout', '2000', true);
  FOR r IN
    SELECT schedule_id, agent_id, goal, interval_seconds, max_runs, run_count, ends_at
    FROM allgres_private.schedules
    WHERE is_active AND next_run_at <= now()
    FOR UPDATE SKIP LOCKED
  LOOP
    -- A stop condition reached between ticks (an operator lowering max_runs,
    -- or ends_at simply arriving) is honoured here too, not only at create/
    -- set time -- deactivate and skip firing rather than run one more time
    -- past the limit.
    IF (r.max_runs IS NOT NULL AND r.run_count >= r.max_runs)
       OR (r.ends_at IS NOT NULL AND r.ends_at <= now()) THEN
      UPDATE allgres_private.schedules SET is_active = false, updated_at = now()
      WHERE schedule_id = r.schedule_id;
      CONTINUE;
    END IF;

    BEGIN
      v_created := allgres_public.fn_create_session(r.agent_id, r.goal);
    EXCEPTION WHEN others THEN
      -- The agent went inactive, or some other transient failure -- push
      -- next_run_at forward anyway so a permanently-broken schedule cannot
      -- spin every tick forever; the operator sees run_count stay behind
      -- what elapsed time would predict and can investigate.
      RAISE WARNING 'fn_run_schedules: fn_create_session failed for schedule %: %', r.schedule_id, SQLERRM;
      UPDATE allgres_private.schedules
      SET next_run_at = now() + make_interval(secs => r.interval_seconds),
          updated_at = now()
      WHERE schedule_id = r.schedule_id;
      CONTINUE;
    END;

    UPDATE allgres_private.schedules
    SET run_count = run_count + 1,
        last_run_at = now(),
        last_session_id = (v_created->>'session_id')::uuid,
        next_run_at = now() + make_interval(secs => interval_seconds),
        is_active = NOT (
          (max_runs IS NOT NULL AND run_count + 1 >= max_runs)
          OR (ends_at IS NOT NULL AND ends_at <= now())
        ),
        updated_at = now()
    WHERE schedule_id = r.schedule_id;
    n := n + 1;
  END LOOP;
  RETURN jsonb_build_object('fired', n);
END;
$fn$;

-- Fires one schedule immediately -- an operator's "run it now" button, or
-- an external system's own event hitting this through dashboard_rpc
-- ('schedules.run_now'), the closest this slice comes to genuinely
-- event-driven execution (see README, "Task dependencies" -- the same
-- deferred-scope note applies here: a real condition/webhook-triggered
-- schedule is future work, not this). Bypasses next_run_at, but never a
-- stop condition: a schedule that has already hit max_runs/ends_at (or is
-- simply paused) cannot be forced past that by this either.
CREATE OR REPLACE FUNCTION allgres_public.fn_run_schedule_now(p_schedule_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = allgres_private, allgres_public, pg_temp
AS $fn$
DECLARE
  s allgres_private.schedules%ROWTYPE;
  v_created jsonb;
BEGIN
  SELECT * INTO s FROM allgres_private.schedules WHERE schedule_id = p_schedule_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'schedule not found' USING ERRCODE = 'P0001';
  END IF;
  IF NOT s.is_active THEN
    RAISE EXCEPTION 'schedule is not active' USING ERRCODE = 'P0001';
  END IF;
  IF (s.max_runs IS NOT NULL AND s.run_count >= s.max_runs) OR (s.ends_at IS NOT NULL AND s.ends_at <= now()) THEN
    RAISE EXCEPTION 'schedule has already reached a stop condition' USING ERRCODE = 'P0001';
  END IF;

  v_created := allgres_public.fn_create_session(s.agent_id, s.goal);

  UPDATE allgres_private.schedules
  SET run_count = run_count + 1,
      last_run_at = now(),
      last_session_id = (v_created->>'session_id')::uuid,
      is_active = NOT (
        (max_runs IS NOT NULL AND run_count + 1 >= max_runs)
        OR (ends_at IS NOT NULL AND ends_at <= now())
      ),
      updated_at = now()
  WHERE schedule_id = p_schedule_id;
  PERFORM allgres_private.audit('schedules.run_now', jsonb_build_object('schedule_id', p_schedule_id, 'session_id', v_created->>'session_id'));
  RETURN v_created;
END;
$fn$;

CREATE OR REPLACE FUNCTION allgres_public.fn_set_provider_secret(p_provider_id uuid, p_api_key text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = allgres_private, pg_temp
AS $fn$
BEGIN
  INSERT INTO allgres_private.llm_secrets (provider_id, api_key)
  VALUES (p_provider_id, allgres_private.encrypt_secret(NULLIF(p_api_key, '')))
  ON CONFLICT (provider_id) DO UPDATE
    SET api_key = COALESCE(
          allgres_private.encrypt_secret(NULLIF(p_api_key, '')),
          allgres_private.llm_secrets.api_key
        );
  -- Never log p_api_key itself -- only that a secret was (re)written.
  PERFORM allgres_private.audit('provider.set_secret', jsonb_build_object('provider_id', p_provider_id, 'api_key_set', true));
  RETURN jsonb_build_object(
    'ok', true,
    'has_secret', true,
    'storage', allgres_private.secret_storage_mode()
  );
END;
$fn$;

-- fn_set_provider only ever UPDATEs a row that already exists -- there was
-- no way for an operator to add a provider beyond the fixed seed list
-- (xai/openai/anthropic/ollama/openai_compat) without editing the database
-- by hand. This is the create counterpart: name/kind/base_url up front,
-- api_key and allow_private_network optional at creation time (both can
-- still be changed later via fn_set_provider / fn_set_provider_secret).
CREATE OR REPLACE FUNCTION allgres_public.fn_create_provider(
  p_name text,
  p_kind text,
  p_base_url text,
  p_api_key text DEFAULT NULL,
  p_allow_private_network boolean DEFAULT false,
  p_purpose text DEFAULT 'chat',
  p_embedding_model text DEFAULT NULL,
  p_response_format_json_object boolean DEFAULT true
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = allgres_private, pg_temp
AS $fn$
DECLARE
  v_id uuid;
  v_url text;
  v_reason text;
  v_purpose text := COALESCE(NULLIF(trim(p_purpose), ''), 'chat');
BEGIN
  IF NULLIF(trim(p_name), '') IS NULL THEN
    RAISE EXCEPTION 'provider name is required' USING ERRCODE = 'P0001';
  END IF;
  IF p_kind NOT IN ('openai_compat', 'anthropic', 'oauth') THEN
    RAISE EXCEPTION 'invalid provider kind: %', p_kind USING ERRCODE = 'P0001';
  END IF;
  IF v_purpose NOT IN ('chat', 'embedding') THEN
    RAISE EXCEPTION 'invalid provider purpose: %', v_purpose USING ERRCODE = 'P0001';
  END IF;
  IF v_purpose = 'embedding' THEN
    IF p_kind <> 'openai_compat' THEN
      RAISE EXCEPTION 'embedding providers must be kind=openai_compat' USING ERRCODE = 'P0001';
    END IF;
    IF NULLIF(trim(p_embedding_model), '') IS NULL THEN
      RAISE EXCEPTION 'embedding_model is required for an embedding provider' USING ERRCODE = 'P0001';
    END IF;
  END IF;

  v_url := rtrim(NULLIF(trim(p_base_url), ''), '/');
  IF v_url IS NULL THEN
    RAISE EXCEPTION 'provider base_url is required' USING ERRCODE = 'P0001';
  END IF;

  -- Same endpoint validation fn_set_provider applies to an edit, applied at
  -- creation time too, so a bad or SSRF-shaped URL is rejected up front
  -- rather than only failing later when an agent first tries to use it.
  v_reason := allgres_private.check_outbound_url(v_url, COALESCE(p_allow_private_network, false));
  IF v_reason IS NOT NULL THEN
    RAISE EXCEPTION 'provider endpoint rejected: % (%)', v_reason, v_url
      USING ERRCODE = 'P0001';
  END IF;

  INSERT INTO allgres_private.llm_providers
    (name, kind, base_url, is_enabled, allow_private_network, purpose, embedding_model,
     response_format_json_object)
  VALUES (trim(p_name), p_kind, v_url, true, COALESCE(p_allow_private_network, false),
          v_purpose, NULLIF(trim(p_embedding_model), ''), COALESCE(p_response_format_json_object, true))
  RETURNING provider_id INTO v_id;

  IF NULLIF(p_api_key, '') IS NOT NULL THEN
    PERFORM allgres_public.fn_set_provider_secret(v_id, p_api_key);
  END IF;

  PERFORM allgres_private.audit('provider.create', jsonb_build_object(
    'provider_id', v_id, 'name', trim(p_name), 'kind', p_kind, 'base_url', v_url,
    'purpose', v_purpose, 'allow_private_network', COALESCE(p_allow_private_network, false),
    'api_key_set', NULLIF(p_api_key, '') IS NOT NULL
  ));
  RETURN jsonb_build_object('ok', true, 'provider_id', v_id);
END;
$fn$;

CREATE OR REPLACE FUNCTION allgres_public.fn_set_provider(
  p_provider_id uuid,
  p_base_url text DEFAULT NULL,
  p_enabled boolean DEFAULT NULL,
  p_allow_private_network boolean DEFAULT NULL,
  p_oauth_auth_url text DEFAULT NULL,
  p_oauth_token_url text DEFAULT NULL,
  p_oauth_client_id text DEFAULT NULL,
  p_oauth_client_secret text DEFAULT NULL,
  p_embedding_model text DEFAULT NULL,
  p_response_format_json_object boolean DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = allgres_private, pg_temp
AS $fn$
DECLARE
  v_allow  boolean;
  v_url    text;
  v_reason text;
BEGIN
  SELECT COALESCE(p_allow_private_network, allow_private_network),
         rtrim(COALESCE(NULLIF(p_base_url, ''), base_url), '/')
  INTO v_allow, v_url
  FROM allgres_private.llm_providers
  WHERE provider_id = p_provider_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'provider not found' USING ERRCODE = 'P0001';
  END IF;

  -- Validate here as well as at request build time, so a bad endpoint is
  -- rejected while the operator is looking at the error.
  v_reason := allgres_private.check_outbound_url(v_url, v_allow);
  IF v_reason IS NOT NULL THEN
    RAISE EXCEPTION 'provider endpoint rejected: % (%)', v_reason, v_url
      USING ERRCODE = 'P0001';
  END IF;

  IF p_oauth_auth_url IS NOT NULL AND p_oauth_auth_url <> '' THEN
    v_reason := allgres_private.check_outbound_url(p_oauth_auth_url, v_allow);
    IF v_reason IS NOT NULL THEN
      RAISE EXCEPTION 'oauth auth url rejected: %', v_reason USING ERRCODE = 'P0001';
    END IF;
  END IF;
  IF p_oauth_token_url IS NOT NULL AND p_oauth_token_url <> '' THEN
    v_reason := allgres_private.check_outbound_url(p_oauth_token_url, v_allow);
    IF v_reason IS NOT NULL THEN
      RAISE EXCEPTION 'oauth token url rejected: %', v_reason USING ERRCODE = 'P0001';
    END IF;
  END IF;

  UPDATE allgres_private.llm_providers
  SET
    base_url = v_url,
    is_enabled = COALESCE(p_enabled, is_enabled),
    allow_private_network = v_allow,
    oauth_auth_url = COALESCE(p_oauth_auth_url, oauth_auth_url),
    oauth_token_url = COALESCE(p_oauth_token_url, oauth_token_url),
    oauth_client_id = COALESCE(p_oauth_client_id, oauth_client_id),
    embedding_model = COALESCE(NULLIF(trim(p_embedding_model), ''), embedding_model),
    response_format_json_object = COALESCE(p_response_format_json_object, response_format_json_object)
  WHERE provider_id = p_provider_id;

  IF p_oauth_client_secret IS NOT NULL AND p_oauth_client_secret <> '' THEN
    INSERT INTO allgres_private.llm_secrets (provider_id, oauth_client_secret)
    VALUES (p_provider_id, allgres_private.encrypt_secret(p_oauth_client_secret))
    ON CONFLICT (provider_id) DO UPDATE
      SET oauth_client_secret = EXCLUDED.oauth_client_secret;
  END IF;

  PERFORM allgres_private.audit('provider.update', jsonb_build_object(
    'provider_id', p_provider_id, 'base_url', v_url, 'enabled', p_enabled,
    'allow_private_network', v_allow, 'oauth_client_secret_set', (p_oauth_client_secret IS NOT NULL AND p_oauth_client_secret <> '')
  ));
  RETURN jsonb_build_object('ok', true);
END;
$fn$;

-- ---------------------------------------------------------------------------
-- Roadmap item 2: generic authenticated HTTP connections, for the
-- 'http_request' tool (see fn_next_step's call_tool handling and
-- fn_claim_outbound below). Same create/set/set_secret shape as
-- fn_create_provider/fn_set_provider/fn_set_provider_secret, deliberately --
-- this is the same credential-storage problem (a named endpoint plus an
-- optional bearer/api-key secret, never returned by any list action) with a
-- different consumer.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION allgres_public.fn_create_connection(
  p_name text,
  p_base_url text,
  p_auth_kind text DEFAULT 'none',
  p_api_key text DEFAULT NULL,
  p_allow_private_network boolean DEFAULT false
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = allgres_private, pg_temp
AS $fn$
DECLARE
  v_id uuid;
  v_url text;
  v_reason text;
  v_auth text := COALESCE(NULLIF(trim(p_auth_kind), ''), 'none');
BEGIN
  IF NULLIF(trim(p_name), '') IS NULL THEN
    RAISE EXCEPTION 'connection name is required' USING ERRCODE = 'P0001';
  END IF;
  IF v_auth NOT IN ('none', 'authorization', 'x-api-key') THEN
    RAISE EXCEPTION 'invalid connection auth_kind: %', v_auth USING ERRCODE = 'P0001';
  END IF;

  v_url := rtrim(NULLIF(trim(p_base_url), ''), '/');
  IF v_url IS NULL THEN
    RAISE EXCEPTION 'connection base_url is required' USING ERRCODE = 'P0001';
  END IF;

  v_reason := allgres_private.check_outbound_url(v_url, COALESCE(p_allow_private_network, false));
  IF v_reason IS NOT NULL THEN
    RAISE EXCEPTION 'connection endpoint rejected: % (%)', v_reason, v_url
      USING ERRCODE = 'P0001';
  END IF;

  INSERT INTO allgres_private.api_connections
    (name, base_url, auth_kind, is_enabled, allow_private_network)
  VALUES (trim(p_name), v_url, v_auth, true, COALESCE(p_allow_private_network, false))
  RETURNING connection_id INTO v_id;

  IF NULLIF(p_api_key, '') IS NOT NULL THEN
    PERFORM allgres_public.fn_set_connection_secret(v_id, p_api_key);
  END IF;

  PERFORM allgres_private.audit('connections.create', jsonb_build_object(
    'connection_id', v_id, 'name', trim(p_name), 'base_url', v_url, 'auth_kind', v_auth,
    'allow_private_network', COALESCE(p_allow_private_network, false),
    'api_key_set', NULLIF(p_api_key, '') IS NOT NULL
  ));
  RETURN jsonb_build_object('ok', true, 'connection_id', v_id);
END;
$fn$;

CREATE OR REPLACE FUNCTION allgres_public.fn_set_connection(
  p_connection_id uuid,
  p_base_url text DEFAULT NULL,
  p_auth_kind text DEFAULT NULL,
  p_enabled boolean DEFAULT NULL,
  p_allow_private_network boolean DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = allgres_private, pg_temp
AS $fn$
DECLARE
  v_allow boolean;
  v_url   text;
  v_auth  text;
  v_reason text;
BEGIN
  SELECT COALESCE(p_allow_private_network, allow_private_network),
         rtrim(COALESCE(NULLIF(p_base_url, ''), base_url), '/'),
         COALESCE(NULLIF(p_auth_kind, ''), auth_kind)
  INTO v_allow, v_url, v_auth
  FROM allgres_private.api_connections
  WHERE connection_id = p_connection_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'connection not found' USING ERRCODE = 'P0001';
  END IF;
  IF v_auth NOT IN ('none', 'authorization', 'x-api-key') THEN
    RAISE EXCEPTION 'invalid connection auth_kind: %', v_auth USING ERRCODE = 'P0001';
  END IF;

  v_reason := allgres_private.check_outbound_url(v_url, v_allow);
  IF v_reason IS NOT NULL THEN
    RAISE EXCEPTION 'connection endpoint rejected: % (%)', v_reason, v_url
      USING ERRCODE = 'P0001';
  END IF;

  UPDATE allgres_private.api_connections
  SET base_url = v_url,
      auth_kind = v_auth,
      is_enabled = COALESCE(p_enabled, is_enabled),
      allow_private_network = v_allow,
      updated_at = now()
  WHERE connection_id = p_connection_id;

  PERFORM allgres_private.audit('connections.update', jsonb_build_object(
    'connection_id', p_connection_id, 'base_url', v_url, 'auth_kind', v_auth,
    'enabled', p_enabled, 'allow_private_network', v_allow
  ));
  RETURN jsonb_build_object('ok', true);
END;
$fn$;

CREATE OR REPLACE FUNCTION allgres_public.fn_set_connection_secret(p_connection_id uuid, p_api_key text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = allgres_private, pg_temp
AS $fn$
BEGIN
  INSERT INTO allgres_private.api_connection_secrets (connection_id, api_key)
  VALUES (p_connection_id, allgres_private.encrypt_secret(NULLIF(p_api_key, '')))
  ON CONFLICT (connection_id) DO UPDATE
    SET api_key = COALESCE(
          allgres_private.encrypt_secret(NULLIF(p_api_key, '')),
          allgres_private.api_connection_secrets.api_key
        );
  RETURN jsonb_build_object(
    'ok', true,
    'has_secret', true,
    'storage', allgres_private.secret_storage_mode()
  );
END;
$fn$;

-- No FK cascades onto anything an agent turn depends on for its own history
-- (outbound_calls.connection_id has no ON DELETE behaviour, so a real call
-- row referencing this connection blocks the delete -- same shape as an
-- agent with real sessions/tasks). An operator retiring a connection that
-- was actually used keeps it around disabled (fn_set_connection, is_enabled
-- = false) instead.
CREATE OR REPLACE FUNCTION allgres_public.fn_delete_connection(p_connection_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = allgres_private, pg_temp
AS $fn$
BEGIN
  DELETE FROM allgres_private.api_connections WHERE connection_id = p_connection_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'connection not found' USING ERRCODE = 'P0001';
  END IF;
  PERFORM allgres_private.audit('connections.delete', jsonb_build_object('connection_id', p_connection_id));
  RETURN jsonb_build_object('ok', true);
END;
$fn$;

CREATE OR REPLACE FUNCTION allgres_public.fn_oauth_start(p_provider_id uuid, p_redirect text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = allgres_private, pg_temp
AS $fn$
DECLARE
  v allgres_private.llm_providers%ROWTYPE;
  v_state text := replace(gen_random_uuid()::text, '-', '');
  v_url text;
BEGIN
  SELECT * INTO v FROM allgres_private.llm_providers WHERE provider_id = p_provider_id;
  IF v.provider_id IS NULL OR v.kind <> 'oauth' THEN
    RAISE EXCEPTION 'provider is not oauth' USING ERRCODE = 'P0001';
  END IF;
  IF v.oauth_auth_url IS NULL OR v.oauth_client_id IS NULL THEN
    RAISE EXCEPTION 'oauth urls / client id missing' USING ERRCODE = 'P0001';
  END IF;
  INSERT INTO allgres_private.oauth_states (state, provider_id) VALUES (v_state, p_provider_id);
  v_url := v.oauth_auth_url
    || CASE WHEN v.oauth_auth_url LIKE '%?' THEN '&' ELSE '?' END
    || 'response_type=code'
    || '&client_id=' || replace(v.oauth_client_id, ' ', '%20')
    || '&state=' || v_state
    || '&redirect_uri=' || replace(p_redirect, ' ', '%20')
    || CASE WHEN v.oauth_scope IS NOT NULL THEN '&scope=' || replace(v.oauth_scope, ' ', '%20') ELSE '' END;
  RETURN jsonb_build_object('ok', true, 'redirect_url', v_url, 'state', v_state);
END;
$fn$;

-- OAuth token exchange is queued the same way an agent's LLM call is: this
-- function only builds the request and inserts a queued oauth_calls row --
-- it never touches the client secret, so it has nothing to hand back to its
-- caller that fn_oauth_token_request's old version used to leak (see
-- KNOWN_ISSUES, "a second-round external review of items 18 and 19":
-- `operator`'s existing blanket grant on allgres_public reached this
-- function, breaking the same "the dashboard never returns a secret" rule
-- provider_secret() being revoked from `operator` exists to enforce). The
-- runtime worker's HTTP pool claims the row (fn_claim_oauth), performs the
-- exchange, and fn_complete_oauth stores whatever comes back -- the same
-- claim/complete shape as fn_claim_outbound/fn_complete_outbound, just
-- without a task_id, since this is an operator dashboard action rather than
-- an agent turn.
CREATE OR REPLACE FUNCTION allgres_public.fn_oauth_token_request(
  p_state text,
  p_code text,
  p_redirect text
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = allgres_private, pg_temp
AS $fn$
DECLARE
  v_pid uuid;
  v allgres_private.llm_providers%ROWTYPE;
  v_reason text;
  v_call uuid;
BEGIN
  SELECT provider_id INTO v_pid FROM allgres_private.oauth_states WHERE state = p_state;
  IF v_pid IS NULL THEN
    RAISE EXCEPTION 'unknown oauth state' USING ERRCODE = 'P0001';
  END IF;
  SELECT * INTO v FROM allgres_private.llm_providers WHERE provider_id = v_pid;
  IF v.oauth_token_url IS NULL OR v.oauth_client_id IS NULL THEN
    RAISE EXCEPTION 'oauth token url / client id missing' USING ERRCODE = 'P0001';
  END IF;

  v_reason := allgres_private.check_outbound_url(v.oauth_token_url, v.allow_private_network);
  IF v_reason IS NOT NULL THEN
    RAISE EXCEPTION 'oauth token url rejected: %', v_reason USING ERRCODE = 'P0001';
  END IF;

  -- A state is single-use from here: whether the exchange below succeeds or
  -- fails, the authorization code has been (or is about to be) presented to
  -- the provider, and a provider-issued code cannot be redeemed twice.
  -- Deleting it now, rather than at completion, also means a duplicate
  -- fn_oauth_token_request call for the same state (a doubled dashboard
  -- click, say) queues at most one exchange, not two.
  DELETE FROM allgres_private.oauth_states WHERE state = p_state;

  INSERT INTO allgres_private.oauth_calls (
    provider_id, state, url, request_headers, request_body, allow_private, status
  ) VALUES (
    v_pid, p_state, v.oauth_token_url,
    jsonb_build_object('content-type', 'application/x-www-form-urlencoded',
                        'accept', 'application/json'),
    jsonb_build_object(
      'grant_type', 'authorization_code',
      'code', p_code,
      'redirect_uri', p_redirect,
      'client_id', v.oauth_client_id
    ),
    v.allow_private_network,
    'queued'
  )
  RETURNING call_id INTO v_call;

  -- Never log p_code/p_redirect: an authorization code is a bearer secret
  -- until it's redeemed, and the call row above is where it already lives
  -- (transiently) for the worker to pick up.
  PERFORM allgres_private.audit('oauth.token_request', jsonb_build_object('provider_id', v_pid, 'call_id', v_call));

  RETURN jsonb_build_object('ok', true, 'queued', true, 'call_id', v_call, 'provider_id', v_pid);
END;
$fn$;

-- Claims queued OAuth token-exchange rows for the runtime worker's HTTP pool.
-- Same claim shape as fn_claim_outbound: the client secret is resolved and
-- merged into the response's body right here, never written back to
-- oauth_calls.request_body, and exists after this only in the return value
-- and then in the worker's memory for the one HTTP request it is used for.
CREATE OR REPLACE FUNCTION allgres_public.fn_claim_oauth(p_limit int DEFAULT 4)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = allgres_private, allgres_public, pg_temp
AS $fn$
DECLARE
  r record;
  v_out jsonb := '[]'::jsonb;
  v_n int := 0;
  v_secret text;
BEGIN
  PERFORM set_config('statement_timeout', '2000', true);
  FOR r IN
    SELECT call_id, provider_id, url, request_headers, request_body, allow_private
    FROM allgres_private.oauth_calls
    WHERE status = 'queued'
    ORDER BY created_at
    FOR UPDATE SKIP LOCKED
    LIMIT GREATEST(1, LEAST(COALESCE(p_limit, 4), 16))
  LOOP
    UPDATE allgres_private.oauth_calls
    SET status = 'in_flight', updated_at = now()
    WHERE call_id = r.call_id;

    v_secret := allgres_private.oauth_client_secret(r.provider_id);
    v_out := v_out || jsonb_build_array(jsonb_build_object(
      'call_id', r.call_id,
      'url', r.url,
      'headers', r.request_headers,
      'body', r.request_body || jsonb_build_object('client_secret', COALESCE(v_secret, '')),
      'allow_private', r.allow_private
    ));
    v_n := v_n + 1;
  END LOOP;
  RETURN jsonb_build_object('count', v_n, 'calls', v_out);
END;
$fn$;

-- Fencing identical to fn_complete_outbound/fn_complete_sql: a row only ever
-- completes from 'in_flight'.  On success, stores the access/refresh token
-- the same way the old public fn_oauth_store_tokens used to -- that function
-- is gone; nothing needs to call it directly anymore, which closes the
-- surface entirely rather than leaving it revoked-but-present.
CREATE OR REPLACE FUNCTION allgres_public.fn_complete_oauth(
  p_call_id uuid,
  p_status int,
  p_body text
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = allgres_private, allgres_public, pg_temp
AS $fn$
DECLARE
  c allgres_private.oauth_calls%ROWTYPE;
  v_parsed jsonb;
  v_access text;
  v_refresh text;
  v_expires_in int;
BEGIN
  PERFORM set_config('statement_timeout', '2000', true);

  SELECT * INTO c
  FROM allgres_private.oauth_calls
  WHERE call_id = p_call_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'fn_complete_oauth: not found' USING ERRCODE = 'P0001';
  END IF;

  IF c.status <> 'in_flight' THEN
    RETURN jsonb_build_object('action', 'stale', 'reason', 'call_not_in_flight', 'status', c.status);
  END IF;

  IF p_status IS NULL OR p_status < 200 OR p_status >= 300 THEN
    UPDATE allgres_private.oauth_calls
    SET status = 'harvested', response_status = p_status,
        error = left(COALESCE(p_body, ''), 2000), updated_at = now()
    WHERE call_id = p_call_id;
    RETURN jsonb_build_object('action', 'error', 'status', p_status);
  END IF;

  BEGIN
    v_parsed := p_body::jsonb;
  EXCEPTION WHEN others THEN
    v_parsed := NULL;
  END;

  v_access := NULLIF(v_parsed->>'access_token', '');
  v_refresh := NULLIF(v_parsed->>'refresh_token', '');
  v_expires_in := NULLIF(v_parsed->>'expires_in', '')::int;

  IF v_access IS NULL THEN
    UPDATE allgres_private.oauth_calls
    SET status = 'harvested', response_status = p_status,
        error = 'token endpoint response had no access_token', updated_at = now()
    WHERE call_id = p_call_id;
    RETURN jsonb_build_object('action', 'error', 'reason', 'no_access_token');
  END IF;

  INSERT INTO allgres_private.llm_secrets (provider_id, access_token, refresh_token, expires_at)
  VALUES (
    c.provider_id,
    allgres_private.encrypt_secret(v_access),
    allgres_private.encrypt_secret(v_refresh),
    CASE WHEN v_expires_in IS NULL THEN NULL ELSE now() + make_interval(secs => v_expires_in) END
  )
  ON CONFLICT (provider_id) DO UPDATE SET
    access_token = EXCLUDED.access_token,
    refresh_token = COALESCE(EXCLUDED.refresh_token, allgres_private.llm_secrets.refresh_token),
    expires_at = EXCLUDED.expires_at;

  UPDATE allgres_private.oauth_calls
  SET status = 'harvested', response_status = p_status, updated_at = now()
  WHERE call_id = p_call_id;

  RETURN jsonb_build_object('action', 'stored', 'provider_id', c.provider_id);
END;
$fn$;

-- Queues (or re-queues) regenerating one agent's identity embedding --
-- called from fn_create_agent and agents.update whenever name/system_prompt
-- changes. Silent no-op, never an exception, whenever embeddings are not
-- actually usable right now: no purpose='embedding' provider registered, or
-- its endpoint fails the same SSRF check every other outbound URL goes
-- through -- an agent create/update must never fail, or even warn, over a
-- missing optional feature. Any still-'queued' row for this agent is
-- deleted first so rapid edits (a few Save clicks in the dashboard modal)
-- do not pile up redundant calls; an 'in_flight' one is left alone and
-- simply gets overwritten by whichever call completes last -- last-write-
-- wins, not ordered, the same tolerance fn_complete_agent_embedding's own
-- comment explains.
CREATE OR REPLACE FUNCTION allgres_private.queue_agent_embedding(p_agent_id uuid)
RETURNS void
LANGUAGE plpgsql
AS $fn$
DECLARE
  v_provider allgres_private.llm_providers%ROWTYPE;
  v_name text;
  v_prompt text;
  v_url text;
  v_reason text;
BEGIN
  SELECT * INTO v_provider FROM allgres_private.llm_providers
  WHERE purpose = 'embedding' AND is_enabled
  ORDER BY created_at LIMIT 1;
  IF NOT FOUND THEN
    RETURN;
  END IF;

  SELECT a.name, COALESCE(pol.system_prompt, '') INTO v_name, v_prompt
  FROM allgres_private.agents a
  LEFT JOIN allgres_private.policies pol ON pol.agent_id = a.agent_id
  WHERE a.agent_id = p_agent_id;
  IF v_name IS NULL THEN
    RETURN;
  END IF;

  v_url := v_provider.base_url || '/embeddings';
  v_reason := allgres_private.check_outbound_url(v_url, v_provider.allow_private_network);
  IF v_reason IS NOT NULL THEN
    RETURN;
  END IF;

  DELETE FROM allgres_private.embedding_calls WHERE agent_id = p_agent_id AND status = 'queued';

  INSERT INTO allgres_private.embedding_calls
    (agent_id, provider_id, model, url, request_headers, request_body, allow_private, status)
  VALUES (
    p_agent_id, v_provider.provider_id, v_provider.embedding_model, v_url,
    jsonb_build_object('content-type', 'application/json'),
    jsonb_build_object('model', v_provider.embedding_model, 'input', left(v_name || ': ' || v_prompt, 8000)),
    v_provider.allow_private_network,
    'queued'
  );
END;
$fn$;

-- Same shape as queue_agent_embedding above, for one memory instead of one
-- agent's identity -- called from write_memory right after every insert
-- (both the agent's own `remember` action and the operator-authored
-- fn_remember path share that one insertion point, so this covers both
-- with no separate wiring). A no-op, exactly like queue_agent_embedding,
-- when no purpose='embedding' provider is configured -- the memory is
-- still written and still recalled by importance/recency, it just never
-- becomes eligible for semantic 'recall' ranking until one exists.
CREATE OR REPLACE FUNCTION allgres_private.queue_memory_embedding(p_memory_id uuid)
RETURNS void
LANGUAGE plpgsql
AS $fn$
DECLARE
  v_provider allgres_private.llm_providers%ROWTYPE;
  v_type text;
  v_content text;
  v_url text;
  v_reason text;
BEGIN
  SELECT * INTO v_provider FROM allgres_private.llm_providers
  WHERE purpose = 'embedding' AND is_enabled
  ORDER BY created_at LIMIT 1;
  IF NOT FOUND THEN
    RETURN;
  END IF;

  SELECT memory_type, content INTO v_type, v_content
  FROM allgres_private.agent_memories WHERE memory_id = p_memory_id;
  IF v_content IS NULL THEN
    RETURN;
  END IF;

  v_url := v_provider.base_url || '/embeddings';
  v_reason := allgres_private.check_outbound_url(v_url, v_provider.allow_private_network);
  IF v_reason IS NOT NULL THEN
    RETURN;
  END IF;

  DELETE FROM allgres_private.embedding_calls WHERE memory_id = p_memory_id AND status = 'queued';

  INSERT INTO allgres_private.embedding_calls
    (memory_id, provider_id, model, url, request_headers, request_body, allow_private, status)
  VALUES (
    p_memory_id, v_provider.provider_id, v_provider.embedding_model, v_url,
    jsonb_build_object('content-type', 'application/json'),
    jsonb_build_object('model', v_provider.embedding_model, 'input', left(v_type || ': ' || v_content, 8000)),
    v_provider.allow_private_network,
    'queued'
  );
END;
$fn$;

-- Claims queued agent-identity embedding calls for the runtime worker's HTTP
-- pool -- same claim shape as fn_claim_oauth, credential resolved and
-- merged into the response right here, never written back to
-- embedding_calls.request_headers.
CREATE OR REPLACE FUNCTION allgres_public.fn_claim_agent_embedding(p_limit int DEFAULT 4)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = allgres_private, allgres_public, pg_temp
AS $fn$
DECLARE
  r record;
  v_out jsonb := '[]'::jsonb;
  v_n int := 0;
  v_key text;
BEGIN
  PERFORM set_config('statement_timeout', '2000', true);
  FOR r IN
    SELECT call_id, provider_id, url, request_headers, request_body, allow_private
    FROM allgres_private.embedding_calls
    WHERE status = 'queued'
    ORDER BY created_at
    FOR UPDATE SKIP LOCKED
    LIMIT GREATEST(1, LEAST(COALESCE(p_limit, 4), 16))
  LOOP
    UPDATE allgres_private.embedding_calls
    SET status = 'in_flight', updated_at = now()
    WHERE call_id = r.call_id;

    v_key := allgres_private.provider_secret(r.provider_id);
    v_out := v_out || jsonb_build_array(jsonb_build_object(
      'call_id', r.call_id,
      'url', r.url,
      'headers', r.request_headers || jsonb_build_object('authorization', 'Bearer ' || COALESCE(v_key, '')),
      'body', r.request_body,
      'allow_private', r.allow_private
    ));
    v_n := v_n + 1;
  END LOOP;
  RETURN jsonb_build_object('count', v_n, 'calls', v_out);
END;
$fn$;

-- Parses {"data":[{"embedding":[...]}]} (OpenAI's embeddings response
-- shape, which Voyage AI's OpenAI-compat mode and most local servers also
-- return) and writes straight into allgres_private.agents.embedding --
-- there is no task_id to route this through fn_submit_result the way a
-- task-bound outbound call does. Fenced identically to
-- fn_complete_outbound/fn_complete_oauth: only ever completes from
-- 'in_flight', so a belated response for a call fn_watchdog already
-- reclaimed as 'lost' cannot overwrite a newer embedding.
-- allgres_private.ensure_vector_index() runs on every successful write --
-- cheap (one catalog lookup) once the index already exists, and is what
-- makes the pgvector-accelerated path "just appear" the first time an
-- embedding is written after the operator installs pgvector, with no
-- separate admin step.
CREATE OR REPLACE FUNCTION allgres_public.fn_complete_agent_embedding(
  p_call_id uuid,
  p_status int,
  p_body text
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = allgres_private, allgres_public, pg_temp
AS $fn$
DECLARE
  c allgres_private.embedding_calls%ROWTYPE;
  v_parsed jsonb;
  v_vec double precision[];
BEGIN
  PERFORM set_config('statement_timeout', '2000', true);

  SELECT * INTO c FROM allgres_private.embedding_calls WHERE call_id = p_call_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'fn_complete_agent_embedding: not found' USING ERRCODE = 'P0001';
  END IF;

  IF c.status <> 'in_flight' THEN
    RETURN jsonb_build_object('action', 'stale', 'reason', 'call_not_in_flight', 'status', c.status);
  END IF;

  IF p_status IS NULL OR p_status < 200 OR p_status >= 300 THEN
    UPDATE allgres_private.embedding_calls
    SET status = 'harvested', response_status = p_status,
        error = left(COALESCE(p_body, ''), 2000), updated_at = now()
    WHERE call_id = p_call_id;
    RETURN jsonb_build_object('action', 'error', 'status', p_status);
  END IF;

  BEGIN
    v_parsed := p_body::jsonb;
    SELECT array_agg((x)::double precision)
    INTO v_vec
    FROM jsonb_array_elements_text(v_parsed->'data'->0->'embedding') AS x;
  EXCEPTION WHEN others THEN
    v_vec := NULL;
  END;

  IF v_vec IS NULL OR array_length(v_vec, 1) IS NULL THEN
    UPDATE allgres_private.embedding_calls
    SET status = 'harvested', response_status = p_status,
        error = 'embedding response had no usable data[0].embedding', updated_at = now()
    WHERE call_id = p_call_id;
    RETURN jsonb_build_object('action', 'error', 'reason', 'no_embedding_in_response');
  END IF;

  -- Exactly one of agent_id/memory_id is set (embedding_calls_target_check)
  -- -- an agent's own identity embedding writes to allgres_private.agents,
  -- a memory's semantic-recall embedding (queue_memory_embedding) writes
  -- to allgres_private.agent_memories instead. Same "<provider name>:
  -- <model>" staleness-detection string either way.
  IF c.agent_id IS NOT NULL THEN
    UPDATE allgres_private.agents
    SET embedding = v_vec,
        embedding_model = (SELECT name FROM allgres_private.llm_providers WHERE provider_id = c.provider_id) || ':' || c.model,
        embedding_updated_at = now(),
        updated_at = now()
    WHERE agent_id = c.agent_id;
  ELSE
    UPDATE allgres_private.agent_memories
    SET embedding = v_vec,
        embedding_model = (SELECT name FROM allgres_private.llm_providers WHERE provider_id = c.provider_id) || ':' || c.model,
        embedding_updated_at = now()
    WHERE memory_id = c.memory_id;
  END IF;

  UPDATE allgres_private.embedding_calls
  SET status = 'harvested', response_status = p_status, updated_at = now()
  WHERE call_id = p_call_id;

  IF c.agent_id IS NOT NULL THEN
    PERFORM allgres_private.ensure_vector_index();
    RETURN jsonb_build_object('action', 'stored', 'agent_id', c.agent_id, 'dims', array_length(v_vec, 1));
  ELSE
    PERFORM allgres_private.ensure_memory_vector_index();
    RETURN jsonb_build_object('action', 'stored', 'memory_id', c.memory_id, 'dims', array_length(v_vec, 1));
  END IF;
END;
$fn$;

-- p_reply is what makes this a conversation instead of a bare gate: it is
-- appended to execution_logs as an 'operator' message (a role the log CHECK
-- constraint has allowed since day one, previously never written to), so the
-- resumed agent sees what the human actually said, not just that it may
-- continue. Before this, fn_decide_approval only recorded approved/rejected;
-- the reason text a human gave was never fed back into the conversation the
-- agent replays on its next turn.
CREATE OR REPLACE FUNCTION allgres_public.fn_decide_approval(
  p_approval_id uuid,
  p_accept boolean,
  p_reply text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = allgres_private, pg_temp
AS $fn$
DECLARE
  v allgres_private.human_approvals%ROWTYPE;
  t allgres_private.tasks%ROWTYPE;
  v_reply text;
BEGIN
  SELECT * INTO v FROM allgres_private.human_approvals WHERE approval_id = p_approval_id FOR UPDATE;
  IF NOT FOUND OR v.status <> 'pending' THEN
    RAISE EXCEPTION 'approval not pending' USING ERRCODE = 'P0001';
  END IF;

  UPDATE allgres_private.human_approvals
  SET status = CASE WHEN p_accept THEN 'approved' ELSE 'rejected' END,
      reply_text = p_reply,
      decided_at = now()
  WHERE approval_id = p_approval_id;

  SELECT * INTO t FROM allgres_private.tasks WHERE task_id = v.task_id FOR UPDATE;
  IF NOT FOUND OR t.status <> 'waiting_human' THEN
    -- The task moved on without this decision (e.g. fn_watchdog already
    -- expired it).  The approval row itself is still recorded above; there
    -- is nothing left to resume or log against.
    PERFORM allgres_private.audit('approvals.decide', jsonb_build_object('approval_id', p_approval_id, 'accept', p_accept, 'task_updated', false));
    RETURN jsonb_build_object('ok', true, 'task_updated', false);
  END IF;

  v_reply := COALESCE(NULLIF(btrim(p_reply), ''), CASE WHEN p_accept THEN 'Approved.' ELSE 'Rejected.' END);
  PERFORM allgres_private.append_log(t.task_id, t.step_count + 1, 'operator', to_jsonb(v_reply));

  IF p_accept THEN
    UPDATE allgres_private.tasks
    SET status = 'queued', step_count = step_count + 1, updated_at = now()
    WHERE task_id = t.task_id;
  ELSE
    UPDATE allgres_private.tasks
    SET status = 'failed', error = 'human_rejected', step_count = step_count + 1, updated_at = now()
    WHERE task_id = t.task_id;
    PERFORM allgres_private.maybe_complete_session(t.session_id);
  END IF;
  PERFORM allgres_private.audit('approvals.decide', jsonb_build_object('approval_id', p_approval_id, 'accept', p_accept, 'task_updated', true));
  RETURN jsonb_build_object('ok', true, 'task_updated', true);
END;
$fn$;

-- The one control that was missing entirely: nothing could stop a runaway
-- agent.  Cancels every open task in the session (queued/running/
-- waiting_human/waiting_children), rejects any pending approval so it
-- doesn't linger, logs an
-- operator message on each cancelled task so the thread shows why it stopped,
-- and closes the session as 'cancelled' -- distinct from maybe_complete_session's
-- 'completed'/'failed', which this deliberately bypasses: that function has
-- no notion of an operator-initiated stop.
CREATE OR REPLACE FUNCTION allgres_public.fn_cancel_session(p_session_id uuid, p_reason text DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = allgres_private, pg_temp
AS $fn$
DECLARE
  r record;
  v_reason text := COALESCE(NULLIF(btrim(p_reason), ''), 'Cancelled by operator.');
  v_n int := 0;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM allgres_private.sessions WHERE session_id = p_session_id) THEN
    RAISE EXCEPTION 'session not found' USING ERRCODE = 'P0001';
  END IF;

  FOR r IN
    SELECT task_id, step_count
    FROM allgres_private.tasks
    WHERE session_id = p_session_id AND status IN ('queued', 'running', 'waiting_human', 'waiting_children')
    FOR UPDATE
  LOOP
    PERFORM allgres_private.append_log(r.task_id, r.step_count + 1, 'operator', to_jsonb(v_reason));
    UPDATE allgres_private.tasks
    SET status = 'cancelled', error = 'operator_cancelled', step_count = step_count + 1, updated_at = now()
    WHERE task_id = r.task_id;
    v_n := v_n + 1;
  END LOOP;

  -- A 'queued' outbound/SQL call has not been claimed yet, so marking the
  -- task cancelled above does not stop fn_claim_outbound/fn_claim_sql from
  -- picking it up next pump (see the task-status guard added there) -- but
  -- that guard only helps once the row is still 'queued' when it runs.
  -- Cancel it here too, before that race window opens, so a cancelled
  -- session cannot still fire an HTTP request or sandboxed query. An
  -- 'in_flight' row is already claimed and cannot be un-sent; marking it
  -- 'lost' here just means its eventual fn_complete_outbound/fn_complete_sql
  -- call finds the task no longer 'running' and discards the result, the
  -- same as any other post-cancel completion.
  UPDATE allgres_private.outbound_calls o
  SET status = 'lost', error = 'session_cancelled', updated_at = now()
  FROM allgres_private.tasks t
  WHERE o.task_id = t.task_id AND t.session_id = p_session_id
    AND o.status IN ('queued', 'in_flight');

  UPDATE allgres_private.sql_calls sc
  SET status = 'lost', updated_at = now()
  FROM allgres_private.tasks t
  WHERE sc.task_id = t.task_id AND t.session_id = p_session_id
    AND sc.status IN ('queued', 'in_flight');

  UPDATE allgres_private.human_approvals h
  SET status = 'rejected', reply_text = 'session_cancelled', decided_at = now()
  FROM allgres_private.tasks t
  WHERE h.task_id = t.task_id AND t.session_id = p_session_id AND h.status = 'pending';

  UPDATE allgres_private.sessions
  SET status = 'cancelled', completed_at = now()
  WHERE session_id = p_session_id AND status = 'open';

  PERFORM allgres_private.audit('sessions.cancel', jsonb_build_object('session_id', p_session_id, 'reason', v_reason, 'tasks_cancelled', v_n));
  RETURN jsonb_build_object('ok', true, 'tasks_cancelled', v_n);
END;
$fn$;

CREATE OR REPLACE FUNCTION allgres_public.fn_allowlist_add(p_ref text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = allgres_private, pg_temp
AS $fn$
BEGIN
  INSERT INTO allgres_private.sql_sandbox_allowlist (resource_ref)
  VALUES (p_ref)
  ON CONFLICT DO NOTHING;
  PERFORM allgres_private.audit('allowlist.add', jsonb_build_object('resource_ref', p_ref));
  RETURN jsonb_build_object('ok', true, 'resource_ref', p_ref);
END;
$fn$;

CREATE OR REPLACE FUNCTION allgres_public.fn_allowlist_del(p_ref text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = allgres_private, pg_temp
AS $fn$
BEGIN
  DELETE FROM allgres_private.sql_sandbox_allowlist WHERE resource_ref = p_ref;
  PERFORM allgres_private.audit('allowlist.remove', jsonb_build_object('resource_ref', p_ref));
  RETURN jsonb_build_object('ok', true);
END;
$fn$;

-- Operator-authored counterpart to the agent's own `remember` action
-- (fn_submit_result) -- same validation and eviction, via write_memory,
-- just with no session/task to attribute it to. Lets an operator seed an
-- agent's memory directly (a standing preference, a correction to
-- something the agent got wrong) rather than only ever waiting for the
-- agent to write it itself.
CREATE OR REPLACE FUNCTION allgres_public.fn_remember(
  p_agent_id uuid,
  p_content text,
  p_memory_type text DEFAULT 'semantic',
  p_importance text DEFAULT NULL,
  p_subject_id text DEFAULT NULL,
  p_expires_in_days text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = allgres_private, pg_temp
AS $fn$
DECLARE
  v_result jsonb;
BEGIN
  v_result := allgres_private.write_memory(
    p_agent_id, p_content, p_memory_type, p_importance, p_subject_id, p_expires_in_days
  );
  PERFORM allgres_private.audit('memories.create', jsonb_build_object(
    'agent_id', p_agent_id, 'memory_type', p_memory_type, 'content_preview', left(p_content, 120)
  ));
  RETURN v_result;
END;
$fn$;

CREATE OR REPLACE FUNCTION allgres_public.fn_forget(p_memory_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = allgres_private, pg_temp
AS $fn$
BEGIN
  DELETE FROM allgres_private.agent_memories WHERE memory_id = p_memory_id;
  PERFORM allgres_private.audit('memories.remove', jsonb_build_object('memory_id', p_memory_id));
  RETURN jsonb_build_object('ok', true, 'memory_id', p_memory_id);
END;
$fn$;

CREATE OR REPLACE FUNCTION allgres_private.selftest_cleanup()
RETURNS void
LANGUAGE plpgsql
AS $fn$
BEGIN
  -- A real DELETE of these rows was tried and reverted: execution_logs'
  -- append-only trigger (forbid_log_mutation) rejects DELETE the same as
  -- UPDATE, for anyone, including this function's own owner -- by design,
  -- see that trigger's comment. Deleting sql_calls/tasks/sessions instead
  -- and leaving orphaned execution_logs behind would either violate the
  -- tasks/sessions FK (nothing here cascades) or leave logs with no task to
  -- belong to. So selftest fixtures are never deleted; instead this only
  -- terminates anything left non-terminal by an interrupted run, and the
  -- operator-facing views/listings filter out goal LIKE 'selftest%' (see
  -- their own comments) so they never actually show up in the dashboard.
  UPDATE allgres_private.tasks t
  SET status = 'failed', error = 'selftest', updated_at = now()
  FROM allgres_private.sessions s
  WHERE t.session_id = s.session_id
    AND s.goal LIKE 'selftest%'
    AND t.status IN ('queued', 'running', 'waiting_human', 'waiting_children');
  UPDATE allgres_private.sessions
  SET status = 'cancelled', completed_at = now()
  WHERE goal LIKE 'selftest%' AND status = 'open';
END;
$fn$;

-- ---------------------------------------------------------------------------
-- 9b. Accounts, roles, and the chat/messenger surface built on them.
--     Real login (username/password, pgcrypto bcrypt hashes), distinct from
--     the dashboard's one shared bearer token -- see the users/web_sessions
--     table comments above for why this exists alongside, not instead of,
--     the lighter audit log item 28 already built.
-- ---------------------------------------------------------------------------

-- Every password operation here requires pgcrypto -- unlike provider secret
-- encryption (allgres_private.encrypt_secret), which degrades to plaintext
-- with a loud warning when pgcrypto is missing, a password hash has no safe
-- degraded mode: fail closed instead, the same way encrypt_secret already
-- fails closed when a secret *key* is configured but pgcrypto is not.
CREATE OR REPLACE FUNCTION allgres_public.fn_create_user(
  p_username text,
  p_password text,
  p_role text DEFAULT 'user'
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = allgres_private, pg_temp
AS $fn$
DECLARE
  v_ns text := allgres_private.pgcrypto_schema();
  v_hash text;
  v_id uuid;
  v_username text := btrim(COALESCE(p_username, ''));
BEGIN
  IF v_ns IS NULL THEN
    RAISE EXCEPTION 'pgcrypto is required for the accounts system but is not installed'
      USING ERRCODE = 'P0001';
  END IF;
  IF v_username = '' THEN
    RAISE EXCEPTION 'username required' USING ERRCODE = 'P0001';
  END IF;
  IF p_role NOT IN ('admin', 'user') THEN
    RAISE EXCEPTION 'invalid role: %', p_role USING ERRCODE = 'P0001';
  END IF;
  IF length(COALESCE(p_password, '')) < 8 THEN
    RAISE EXCEPTION 'password must be at least 8 characters' USING ERRCODE = 'P0001';
  END IF;

  EXECUTE format('SELECT %I.crypt($1, %I.gen_salt(''bf''))', v_ns, v_ns)
    INTO v_hash USING p_password;

  INSERT INTO allgres_private.users (username, password_hash, role)
  VALUES (v_username, v_hash, p_role)
  RETURNING user_id INTO v_id;

  -- Never log p_password/v_hash: audit_log.details is not a secrets store.
  PERFORM allgres_private.audit('users.create', jsonb_build_object('user_id', v_id, 'username', v_username, 'role', p_role));

  RETURN jsonb_build_object('ok', true, 'user_id', v_id, 'username', v_username, 'role', p_role);
END;
$fn$;

-- A failed login (unknown username or wrong password) is indistinguishable
-- from the caller's side -- same error message, and a fixed pg_sleep so a
-- valid-username-wrong-password attempt does not visibly resolve faster
-- than an unknown-username one.
CREATE OR REPLACE FUNCTION allgres_public.fn_login(p_username text, p_password text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = allgres_private, pg_temp
AS $fn$
DECLARE
  v_ns text := allgres_private.pgcrypto_schema();
  u allgres_private.users%ROWTYPE;
  v_ok boolean;
  v_token text;
BEGIN
  IF v_ns IS NULL THEN
    RAISE EXCEPTION 'pgcrypto is required for login but is not installed' USING ERRCODE = 'P0001';
  END IF;

  SELECT * INTO u FROM allgres_private.users
  WHERE username = btrim(COALESCE(p_username, '')) AND is_active;

  IF NOT FOUND THEN
    PERFORM pg_sleep(0.2);
    RAISE EXCEPTION 'invalid username or password' USING ERRCODE = 'P0001';
  END IF;

  EXECUTE format('SELECT %I.crypt($1, $2) = $2', v_ns)
    INTO v_ok USING COALESCE(p_password, ''), u.password_hash;

  IF NOT v_ok THEN
    RAISE EXCEPTION 'invalid username or password' USING ERRCODE = 'P0001';
  END IF;

  EXECUTE format('SELECT encode(%I.gen_random_bytes(32), ''hex'')', v_ns) INTO v_token;

  INSERT INTO allgres_private.web_sessions (session_token, user_id, expires_at)
  VALUES (v_token, u.user_id, now() + interval '7 days');

  RETURN jsonb_build_object(
    'ok', true, 'session_token', v_token,
    'user_id', u.user_id, 'username', u.username, 'role', u.role
  );
END;
$fn$;

-- Idempotent: logging out a token that is already gone (expired, or logged
-- out from another tab) is not an error.
CREATE OR REPLACE FUNCTION allgres_public.fn_logout(p_session_token text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = allgres_private, pg_temp
AS $fn$
BEGIN
  DELETE FROM allgres_private.web_sessions WHERE session_token = p_session_token;
  RETURN jsonb_build_object('ok', true);
END;
$fn$;

-- These four used to be the only mutations in the whole file with no SQL
-- entry point of their own -- their real INSERT/UPDATE/DELETE lived only
-- inline inside dashboard_rpc's users.set_active/set_role/assignments.set/
-- assignments.toggle branches, reachable only through the jsonb RPC
-- envelope. Every other mutation dashboard_rpc exposes already has a plain
-- function like this one behind it (fn_create_user just above,
-- fn_grant_permission, fn_set_policy, ...) that an operator with direct
-- database access can call the same way `psql -c "SELECT
-- fn_create_user(...)"` already works, with no jsonb, no dashboard, no
-- HTTP -- the whole point of a PostgreSQL-native control plane (see
-- README's opening line). dashboard_rpc's own require_admin gate is
-- unchanged; these carry no permission check themselves, exactly like
-- fn_grant_permission/fn_revoke_permission just above -- gating the web/API
-- surface is dashboard_rpc's job, not something every SQL-native function
-- underneath it should also have to reimplement for a caller already
-- trusted with direct database access.
CREATE OR REPLACE FUNCTION allgres_public.fn_set_user_active(p_user_id uuid, p_is_active boolean)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = allgres_private, pg_temp
AS $fn$
BEGIN
  UPDATE allgres_private.users SET is_active = p_is_active WHERE user_id = p_user_id;
  PERFORM allgres_private.audit('users.set_active', jsonb_build_object('user_id', p_user_id, 'is_active', p_is_active));
  RETURN jsonb_build_object('ok', true);
END;
$fn$;

CREATE OR REPLACE FUNCTION allgres_public.fn_set_user_role(p_user_id uuid, p_role text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = allgres_private, pg_temp
AS $fn$
BEGIN
  IF p_role NOT IN ('admin', 'user') THEN
    RAISE EXCEPTION 'invalid role: %', p_role USING ERRCODE = 'P0001';
  END IF;
  UPDATE allgres_private.users SET role = p_role WHERE user_id = p_user_id;
  PERFORM allgres_private.audit('users.set_role', jsonb_build_object('user_id', p_user_id, 'role', p_role));
  RETURN jsonb_build_object('ok', true);
END;
$fn$;

-- Replaces the full assignment set for one user with the given agent_ids --
-- simpler and less error-prone from the UI than incremental add/remove
-- calls for what is always edited as one list there; see
-- fn_set_user_assignment below for the single add/remove instead.
CREATE OR REPLACE FUNCTION allgres_public.fn_set_user_assignments(p_user_id uuid, p_agent_ids uuid[])
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = allgres_private, pg_temp
AS $fn$
BEGIN
  DELETE FROM allgres_private.user_agent_assignments WHERE user_id = p_user_id;
  INSERT INTO allgres_private.user_agent_assignments (user_id, agent_id)
  SELECT p_user_id, a FROM unnest(COALESCE(p_agent_ids, ARRAY[]::uuid[])) a;
  PERFORM allgres_private.audit('users.set_assignments', jsonb_build_object('user_id', p_user_id, 'agent_ids', to_jsonb(p_agent_ids)));
  RETURN jsonb_build_object('ok', true);
END;
$fn$;

CREATE OR REPLACE FUNCTION allgres_public.fn_set_user_assignment(p_user_id uuid, p_agent_id uuid, p_assigned boolean)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = allgres_private, pg_temp
AS $fn$
BEGIN
  IF p_assigned THEN
    INSERT INTO allgres_private.user_agent_assignments (user_id, agent_id)
    VALUES (p_user_id, p_agent_id)
    ON CONFLICT DO NOTHING;
  ELSE
    DELETE FROM allgres_private.user_agent_assignments
    WHERE user_id = p_user_id AND agent_id = p_agent_id;
  END IF;
  PERFORM allgres_private.audit('users.set_assignment', jsonb_build_object('user_id', p_user_id, 'agent_id', p_agent_id, 'assigned', p_assigned));
  RETURN jsonb_build_object('ok', true);
END;
$fn$;

-- Resolves a bearer token to the user it belongs to, or a NULL row if the
-- token is missing, unknown, expired, or the account was deactivated since
-- the token was issued. Touches last_seen_at only on a hit, so a wall of
-- invalid tokens can never generate write traffic.
CREATE OR REPLACE FUNCTION allgres_private.session_user(p_token text)
RETURNS allgres_private.users
LANGUAGE plpgsql
AS $fn$
DECLARE
  u allgres_private.users%ROWTYPE;
BEGIN
  IF p_token IS NULL OR p_token = '' THEN
    RETURN NULL;
  END IF;
  SELECT us.* INTO u
  FROM allgres_private.web_sessions ws
  JOIN allgres_private.users us ON us.user_id = ws.user_id
  WHERE ws.session_token = p_token AND ws.expires_at > now() AND us.is_active;
  IF FOUND THEN
    UPDATE allgres_private.web_sessions SET last_seen_at = now() WHERE session_token = p_token;
    RETURN u;
  END IF;
  RETURN NULL;
END;
$fn$;

CREATE OR REPLACE FUNCTION allgres_private.require_admin(p_token text)
RETURNS allgres_private.users
LANGUAGE plpgsql
AS $fn$
DECLARE
  u allgres_private.users%ROWTYPE;
BEGIN
  u := allgres_private.session_user(p_token);
  IF u.user_id IS NULL THEN
    RAISE EXCEPTION 'not logged in' USING ERRCODE = 'P0001';
  END IF;
  IF u.role <> 'admin' THEN
    RAISE EXCEPTION 'admin role required' USING ERRCODE = 'P0001';
  END IF;
  RETURN u;
END;
$fn$;

-- The guard on every agent-config action that can reach a system agent
-- (agents.update, policy.rollback, permissions.grant/revoke): a regular
-- agent needs no session_token at all today (the shared dashboard bearer
-- token alone has always been enough, see the module comment on
-- allgres_private.users), so this only starts requiring a logged-in admin
-- once the *target* is a system agent -- an ordinary agent's config is
-- unaffected, exactly the "borrow the idea, don't touch what already
-- works" shape the rest of this file follows. NULL p_agent_id (a request
-- with no/invalid agent_id) is left to the caller's own validation to
-- reject -- this function only ever tightens an is_system=true target.
CREATE OR REPLACE FUNCTION allgres_private.require_admin_for_system_agent(p_token text, p_agent_id uuid)
RETURNS void
LANGUAGE plpgsql
AS $fn$
BEGIN
  IF p_agent_id IS NOT NULL AND EXISTS (
    SELECT 1 FROM allgres_private.agents WHERE agent_id = p_agent_id AND is_system
  ) THEN
    PERFORM allgres_private.require_admin(p_token);
  END IF;
END;
$fn$;

-- The gate the rest of the platform-configuration surface was missing --
-- agents.create, agents.update/permissions.grant/permissions.revoke/
-- policy.rollback for an *ordinary* (non-system) agent, provider.create/
-- provider.update, allowlist.add/remove, and agents.set_autonomy all either
-- had no session check at all or (agents.update and friends) one that only
-- ever fired for a system-agent target, leaving every one of these
-- reachable by anyone holding the shared dashboard bearer token alone, with
-- no relationship to whether that caller is logged in, or as what role --
-- a real gap between the accounts system (item 28) and the admin-only
-- surface that predates it, not a deliberate two-tier design.
--
-- The fix cannot be a bare require_admin the way require_admin_for_system_
-- agent already is for a system-agent target: that would break the
-- deployment mode this whole accounts system was always additive to (see
-- the "Accounts, roles, ..." section comment on dashboard_rpc) -- a
-- single-operator install that has never created a user account at all,
-- where the shared bearer token alone has always been the entire security
-- model and still needs to be enough. So this only starts requiring a
-- logged-in admin once an operator has actually created at least one
-- account -- at that point every action gated by this function requires
-- one, uniformly, regardless of whether its specific target happens to be
-- a system agent. Before that point (zero rows in allgres_private.users --
-- checked fresh on every call, not cached, so the very next request after
-- the first account is created is already covered) this is a no-op, the
-- same as before this function existed.
CREATE OR REPLACE FUNCTION allgres_private.require_admin_if_accounts_exist(p_token text)
RETURNS void
LANGUAGE plpgsql
AS $fn$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM allgres_private.users) THEN
    RETURN;
  END IF;
  PERFORM allgres_private.require_admin(p_token);
END;
$fn$;

-- What approvals.list/proposals.list/fixes.list and their .decide
-- counterparts scope by (item 41, "opening the approval inbox to regular
-- users too"): NULL means unrestricted -- either nobody is logged in (the
-- original shared-bearer-token caller, unaffected by any of this) or the
-- caller is an admin, who could always see everything here before item 28
-- added accounts at all. A non-NULL, possibly empty, array is a regular
-- user's own assigned agents -- exactly user_agent_assignments, the same
-- explicit allow-list require_agent_access already enforces for chat.
CREATE OR REPLACE FUNCTION allgres_private.visible_agent_ids(p_token text)
RETURNS uuid[]
LANGUAGE plpgsql
AS $fn$
DECLARE
  u allgres_private.users%ROWTYPE;
  v_ids uuid[];
BEGIN
  u := allgres_private.session_user(p_token);
  IF u.user_id IS NULL OR u.role = 'admin' THEN
    RETURN NULL;
  END IF;
  SELECT COALESCE(array_agg(agent_id), ARRAY[]::uuid[]) INTO v_ids
  FROM allgres_private.user_agent_assignments WHERE user_id = u.user_id;
  RETURN v_ids;
END;
$fn$;

-- The one check every chat/messenger/model-config action for a specific
-- agent goes through: an admin may reach any active agent; a regular user
-- only one explicitly assigned via user_agent_assignments (item 29's
-- "explicit allowed set", not "everything visible by default").
CREATE OR REPLACE FUNCTION allgres_private.require_agent_access(p_token text, p_agent_id uuid)
RETURNS allgres_private.users
LANGUAGE plpgsql
AS $fn$
DECLARE
  u allgres_private.users%ROWTYPE;
BEGIN
  u := allgres_private.session_user(p_token);
  IF u.user_id IS NULL THEN
    RAISE EXCEPTION 'not logged in' USING ERRCODE = 'P0001';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM allgres_private.agents WHERE agent_id = p_agent_id AND is_active) THEN
    RAISE EXCEPTION 'agent inactive or missing' USING ERRCODE = 'P0001';
  END IF;
  IF u.role <> 'admin' AND NOT EXISTS (
    SELECT 1 FROM allgres_private.user_agent_assignments
    WHERE user_id = u.user_id AND agent_id = p_agent_id
  ) THEN
    RAISE EXCEPTION 'agent not assigned to this user' USING ERRCODE = 'P0001';
  END IF;
  RETURN u;
END;
$fn$;

-- The graceful counterpart require_admin_if_accounts_exist already is to
-- require_admin, for the same reason: require_agent_access above has no
-- bootstrap fallback (correct for chat/messenger/my_agents, which have
-- required a real login since the day accounts existed at all), but
-- applying it unconditionally to run/sessions.cancel/sessions.continue --
-- older actions than the login system itself, part of the admin-facing
-- Run/Sessions surface -- would break the single-operator, token-only
-- deployment mode those have always worked in. This is a no-op while
-- allgres_private.users is empty (checked fresh, not cached, same as
-- require_admin_if_accounts_exist); once any account exists, it requires
-- a real logged-in session AND (unless that session is an admin) that the
-- session belongs to a user actually assigned to p_agent_id -- the two
-- separate checks item 1 of the roadmap named: can this *user* reach this
-- *agent* at all, kept apart from whether the *agent* may reach a given
-- resource (agent_may_read/agent_has_permission, unrelated and untouched
-- here). Before this fix, run/sessions.cancel/sessions.continue had no
-- check whatsoever, at any account state -- any caller holding the shared
-- dashboard token could run, cancel, or continue a session against any
-- agent_id/session_id in the whole database, logged in or not, assigned
-- or not.
CREATE OR REPLACE FUNCTION allgres_private.require_agent_access_if_accounts_exist(p_token text, p_agent_id uuid)
RETURNS void
LANGUAGE plpgsql
AS $fn$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM allgres_private.users) THEN
    RETURN;
  END IF;
  PERFORM allgres_private.require_agent_access(p_token, p_agent_id);
END;
$fn$;

-- Project mode's own access check (item 42): a project is a valid chat
-- target only once bound to an agent and active, and reaching it still
-- goes through require_agent_access for that agent -- a regular user needs
-- the same assignment a Project's bound agent would require in General
-- mode, there is no separate project-level allow-list.
CREATE OR REPLACE FUNCTION allgres_private.require_project_access(p_token text, p_project_id uuid)
RETURNS TABLE(u allgres_private.users, agent_id uuid)
LANGUAGE plpgsql
AS $fn$
DECLARE
  v_project allgres_private.projects%ROWTYPE;
  v_user allgres_private.users%ROWTYPE;
BEGIN
  SELECT * INTO v_project FROM allgres_private.projects WHERE project_id = p_project_id AND is_active;
  IF v_project IS NULL THEN
    RAISE EXCEPTION 'project inactive or missing' USING ERRCODE = 'P0001';
  END IF;
  IF v_project.agent_id IS NULL THEN
    RAISE EXCEPTION 'project has no agent configured for chat' USING ERRCODE = 'P0001';
  END IF;
  v_user := allgres_private.require_agent_access(p_token, v_project.agent_id);
  RETURN QUERY SELECT v_user, v_project.agent_id;
END;
$fn$;

-- The simple 1:1 chat surface: one continuing session per (user, agent)
-- pair (user_agent_chat_sessions), created on first message and continued
-- (fn_continue_session) on every one after -- never a fresh, contextless
-- session per message.
CREATE OR REPLACE FUNCTION allgres_public.fn_chat_send(
  p_session_token text,
  p_agent_id uuid,
  p_message text
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = allgres_private, allgres_public, pg_temp
AS $fn$
DECLARE
  u allgres_private.users%ROWTYPE;
  v_sid uuid;
  v_created jsonb;
BEGIN
  u := allgres_private.require_agent_access(p_session_token, p_agent_id);
  IF btrim(COALESCE(p_message, '')) = '' THEN
    RAISE EXCEPTION 'message required' USING ERRCODE = 'P0001';
  END IF;

  SELECT session_id INTO v_sid
  FROM allgres_private.user_agent_chat_sessions
  WHERE user_id = u.user_id AND agent_id = p_agent_id;

  IF v_sid IS NULL THEN
    v_created := allgres_public.fn_create_session(p_agent_id, btrim(p_message));
    v_sid := (v_created->>'session_id')::uuid;
    INSERT INTO allgres_private.user_agent_chat_sessions (user_id, agent_id, session_id)
    VALUES (u.user_id, p_agent_id, v_sid);
    RETURN jsonb_build_object('ok', true, 'session_id', v_sid, 'task_id', v_created->>'task_id');
  END IF;

  v_created := allgres_public.fn_continue_session(v_sid, btrim(p_message));
  UPDATE allgres_private.user_agent_chat_sessions SET updated_at = now()
  WHERE user_id = u.user_id AND agent_id = p_agent_id;
  RETURN v_created;
END;
$fn$;

-- The full thread for a user's ongoing chat with one agent -- same
-- session-wide, root-tasks-only stitching fn_next_step itself now uses,
-- read back for display rather than to build a prompt.
CREATE OR REPLACE FUNCTION allgres_public.fn_chat_history(p_session_token text, p_agent_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = allgres_private, pg_temp
AS $fn$
DECLARE
  u allgres_private.users%ROWTYPE;
  v_sid uuid;
BEGIN
  u := allgres_private.require_agent_access(p_session_token, p_agent_id);

  SELECT session_id INTO v_sid
  FROM allgres_private.user_agent_chat_sessions
  WHERE user_id = u.user_id AND agent_id = p_agent_id;

  IF v_sid IS NULL THEN
    RETURN jsonb_build_object('ok', true, 'session_id', NULL, 'status', NULL, 'messages', '[]'::jsonb);
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'session_id', v_sid,
    'status', (SELECT status FROM allgres_private.sessions WHERE session_id = v_sid),
    'messages', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
        'role', l.role, 'content', allgres_private.log_content_text(l.content), 'created_at', l.created_at
      ) ORDER BY l.created_at)
      FROM allgres_private.execution_logs l
      JOIN allgres_private.tasks t USING (task_id)
      WHERE t.session_id = v_sid AND t.parent_task_id IS NULL
        AND l.role IN ('user', 'assistant', 'operator')
    ), '[]'::jsonb)
  );
END;
$fn$;

-- Project mode's fn_chat_send: identical shape (one continuing session,
-- created on first message, resumed after), keyed by project instead of
-- agent -- see user_project_chat_sessions's comment for why this is its
-- own table/session rather than reusing an agent's General-mode one. The
-- session itself still belongs to the project's bound agent
-- (fn_create_session's p_agent_id); fn_next_step is what makes the
-- resulting conversation actually see the project's preset_prompt, by
-- reading sessions.project_id back off the session it creates here.
CREATE OR REPLACE FUNCTION allgres_public.fn_project_chat_send(
  p_session_token text,
  p_project_id uuid,
  p_message text
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = allgres_private, allgres_public, pg_temp
AS $fn$
DECLARE
  v_access record;
  v_sid uuid;
  v_created jsonb;
BEGIN
  SELECT * INTO v_access FROM allgres_private.require_project_access(p_session_token, p_project_id);
  IF btrim(COALESCE(p_message, '')) = '' THEN
    RAISE EXCEPTION 'message required' USING ERRCODE = 'P0001';
  END IF;

  SELECT session_id INTO v_sid
  FROM allgres_private.user_project_chat_sessions
  WHERE user_id = (v_access.u).user_id AND project_id = p_project_id;

  IF v_sid IS NULL THEN
    v_created := allgres_public.fn_create_session(v_access.agent_id, btrim(p_message), p_project_id);
    v_sid := (v_created->>'session_id')::uuid;
    INSERT INTO allgres_private.user_project_chat_sessions (user_id, project_id, session_id)
    VALUES ((v_access.u).user_id, p_project_id, v_sid);
    RETURN jsonb_build_object('ok', true, 'session_id', v_sid, 'task_id', v_created->>'task_id');
  END IF;

  v_created := allgres_public.fn_continue_session(v_sid, btrim(p_message));
  UPDATE allgres_private.user_project_chat_sessions SET updated_at = now()
  WHERE user_id = (v_access.u).user_id AND project_id = p_project_id;
  RETURN v_created;
END;
$fn$;

CREATE OR REPLACE FUNCTION allgres_public.fn_project_chat_history(p_session_token text, p_project_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = allgres_private, pg_temp
AS $fn$
DECLARE
  v_access record;
  v_sid uuid;
BEGIN
  SELECT * INTO v_access FROM allgres_private.require_project_access(p_session_token, p_project_id);

  SELECT session_id INTO v_sid
  FROM allgres_private.user_project_chat_sessions
  WHERE user_id = (v_access.u).user_id AND project_id = p_project_id;

  IF v_sid IS NULL THEN
    RETURN jsonb_build_object('ok', true, 'session_id', NULL, 'status', NULL, 'messages', '[]'::jsonb);
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'session_id', v_sid,
    'status', (SELECT status FROM allgres_private.sessions WHERE session_id = v_sid),
    'messages', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
        'role', l.role, 'content', allgres_private.log_content_text(l.content), 'created_at', l.created_at
      ) ORDER BY l.created_at)
      FROM allgres_private.execution_logs l
      JOIN allgres_private.tasks t USING (task_id)
      WHERE t.session_id = v_sid AND t.parent_task_id IS NULL
        AND l.role IN ('user', 'assistant', 'operator')
    ), '[]'::jsonb)
  );
END;
$fn$;

-- The Slack-style messenger: a plain post is just stored; a post containing
-- "@agent_name" additionally resolves that agent (subject to the same
-- require_agent_access an unaddressed regular user could not bypass) and
-- routes the *same* message through fn_chat_send, so mentioning an agent in
-- the channel and messaging it in the 1:1 chat page share one conversation
-- per (user, agent) -- not two divergent histories.
CREATE OR REPLACE FUNCTION allgres_public.fn_messenger_post(p_session_token text, p_text text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = allgres_private, allgres_public, pg_temp
AS $fn$
DECLARE
  u allgres_private.users%ROWTYPE;
  v_text text := btrim(COALESCE(p_text, ''));
  v_names text[];
  v_name text;
  v_agent_id uuid;
  v_agent_ids uuid[] := ARRAY[]::uuid[];
  v_sid uuid;
  v_sids uuid[] := ARRAY[]::uuid[];
  v_mid uuid;
  v_orchestrator uuid;
  v_orchestrator_config jsonb;
BEGIN
  u := allgres_private.session_user(p_session_token);
  IF u.user_id IS NULL THEN
    RAISE EXCEPTION 'not logged in' USING ERRCODE = 'P0001';
  END IF;
  IF v_text = '' THEN
    RAISE EXCEPTION 'message required' USING ERRCODE = 'P0001';
  END IF;

  -- Every distinct @mention, in the order it first appears in the text --
  -- that order is what actually decides delivery order today (see
  -- orchestrator's comment below for what it decides instead).
  SELECT array_agg(name ORDER BY first_pos) INTO v_names FROM (
    SELECT (m)[1] AS name, min(ord) AS first_pos
    FROM regexp_matches(v_text, '@([A-Za-z0-9_-]+)', 'g') WITH ORDINALITY AS t(m, ord)
    GROUP BY (m)[1]
  ) q;

  IF v_names IS NOT NULL THEN
    FOREACH v_name IN ARRAY v_names LOOP
      SELECT agent_id INTO v_agent_id FROM allgres_private.agents WHERE name = v_name;
      IF v_agent_id IS NULL THEN
        RAISE EXCEPTION 'no such agent: %', v_name USING ERRCODE = 'P0001';
      END IF;
      -- Validates access the same way chat.send would, for every mention --
      -- a plain post (no mention) skips this entirely.
      PERFORM allgres_private.require_agent_access(p_session_token, v_agent_id);
      v_agent_ids := v_agent_ids || v_agent_id;
      v_sids := v_sids || (allgres_public.fn_chat_send(p_session_token, v_agent_id, v_text)->>'session_id')::uuid;
    END LOOP;
    v_agent_id := v_agent_ids[1];
    v_sid := v_sids[1];
  END IF;

  INSERT INTO allgres_private.channel_messages
    (author_user_id, content, mentioned_agent_id, session_id, mentioned_agent_ids)
  VALUES (u.user_id, v_text, v_agent_id, v_sid, NULLIF(v_agent_ids, ARRAY[]::uuid[]))
  RETURNING message_id INTO v_mid;

  -- orchestrator (item 40): advisory only in this pass -- it reads the same
  -- multi-mention message and the mentioned agents' own prompts and records
  -- its opinion on response order via its own final_answer, but delivery
  -- above already happened in text order regardless. A real reordering-
  -- before-delivery pass is future work; this at least exercises the seeded
  -- agent against a real message rather than leaving it permanently idle.
  -- How many mentions actually engage it (default 2, i.e. "more than
  -- one") is admin-tunable via orchestrator's own agent_config
  -- (min_mentions_to_route, set through agents.update) -- the same
  -- pattern session_compactor's thresholds use.
  SELECT agent_id, agent_config INTO v_orchestrator, v_orchestrator_config
  FROM allgres_private.agents WHERE name = 'orchestrator' AND is_active;
  IF v_orchestrator IS NOT NULL
     AND array_length(v_agent_ids, 1) >= COALESCE((v_orchestrator_config->>'min_mentions_to_route')::int, 2) THEN
    PERFORM allgres_private.queue_orchestrator_opinion(v_orchestrator, v_mid, v_text, v_agent_ids);
  END IF;

  RETURN jsonb_build_object(
    'ok', true, 'message_id', v_mid, 'mentioned_agent_id', v_agent_id, 'session_id', v_sid,
    'mentioned_agent_ids', to_jsonb(v_agent_ids)
  );
END;
$fn$;

-- Regular users can only reach this narrow slice of an agent's policy --
-- llm_config, through fn_set_policy the same way the operator-facing agent
-- editor already does -- never max_steps/permissions/prompt, which stay
-- admin-only via the existing agents.update surface.
CREATE OR REPLACE FUNCTION allgres_public.fn_set_my_model(
  p_session_token text,
  p_agent_id uuid,
  p_provider text,
  p_model text
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = allgres_private, allgres_public, pg_temp
AS $fn$
BEGIN
  PERFORM allgres_private.require_agent_access(p_session_token, p_agent_id);
  RETURN allgres_public.fn_set_policy(
    p_agent_id, NULL, NULL, NULL,
    jsonb_build_object('provider', p_provider, 'model', p_model)
  );
END;
$fn$;

-- ---------------------------------------------------------------------------
-- 10. Seed data.  Create-only: replaying this file must not clobber an
--     operator's edited prompt, provider list, or policy.
-- ---------------------------------------------------------------------------

-- Fixed provider_id values, not the column's gen_random_uuid() default: a
-- random id here would differ between any two installs of this same seed
-- (a fresh install vs. a restore target, most concretely), breaking every
-- FK that points at a built-in provider (llm_secrets, outbound_calls) the
-- moment that data crosses installs -- see KNOWN_ISSUES.md, "backup/PITR
-- drill". ON CONFLICT (name) DO NOTHING means this is forward-only: an
-- install that already seeded these rows before this fix keeps whatever
-- random id it already has, since the row already exists by name; only a
-- fresh install (or a restore onto one) gets the fixed id from here on.
INSERT INTO allgres_private.llm_providers (provider_id, name, kind, base_url, is_enabled, allow_private_network)
VALUES
  ('157b9a61-537b-4faf-a88a-c673ab3fad8e', 'xai',           'openai_compat', 'https://api.x.ai/v1',        true,  false),
  ('f87649ff-8541-4404-a505-5508d59812e2', 'openai',        'openai_compat', 'https://api.openai.com/v1',  true,  false),
  ('b73bdab2-66a7-4eb8-9906-6f0ee2b9f32c', 'anthropic',     'anthropic',     'https://api.anthropic.com',  true,  false),
  ('21b55be9-aef4-4709-8a65-b3dc10e008ac', 'ollama',        'openai_compat', 'http://127.0.0.1:11434/v1',  true,  true),
  ('93ad5476-8d3a-4443-8b98-f50b6d1d4fbc', 'openai_compat', 'openai_compat', 'https://api.openai.com/v1',  true,  false)
ON CONFLICT (name) DO NOTHING;

-- response_format_json_object's own retroactive fix (its column comment
-- above explains why): must run after the INSERT above, whether that
-- INSERT just created the row (fresh install) or found it already there
-- and did nothing (ON CONFLICT DO NOTHING, an existing install) -- either
-- way the row exists by the time this runs, unlike the ALTER TABLE far
-- above it. Unconditional on every re-run of this file, not gated by
-- whether the row was just inserted, so an install that already had the
-- pre-fix default overwritten some other way is also corrected the next
-- time control_plane.sql is applied.
UPDATE allgres_private.llm_providers SET response_format_json_object = false WHERE name = 'ollama';

INSERT INTO allgres_private.sql_sandbox_allowlist (resource_ref)
VALUES ('allgres_public.v_sales'), ('allgres_public.v_my_tasks'),
       ('allgres_public.v_system_health'), ('allgres_public.v_permission_audit'),
       ('allgres_public.v_agent_health')
ON CONFLICT DO NOTHING;

DO $seed$
DECLARE
  v_agent uuid;
BEGIN
  SELECT agent_id INTO v_agent FROM allgres_private.agents WHERE name = 'analyst';

  IF v_agent IS NULL THEN
    INSERT INTO allgres_private.agents (name) VALUES ('analyst') RETURNING agent_id INTO v_agent;

    -- Only on first creation, so an upgrade never overwrites a tuned policy.
    UPDATE allgres_private.policies
    SET system_prompt = $prompt$You are the Allgres analyst. Reply with one JSON object only. No markdown, no prose.

Allowed:
{"action":"final_answer","answer":"..."}
{"action":"execute_sql","sql":"SELECT ..."}
{"action":"call_tool","tool":"http_get","args":{"url":"https://..."}}
{"action":"await_human","reason":"..."}

For numbers use execute_sql against allgres_public.v_sales (region, sku, amount, sold_on).
Example: {"action":"execute_sql","sql":"SELECT region, sum(amount) AS total FROM allgres_public.v_sales GROUP BY region"}
When you have the result, emit final_answer in one short sentence.
$prompt$,
        max_steps = 8,
        max_retries = 2,
        -- Deliberately no llm_config here (see ensure_policy): a fresh
        -- install must not look like a provider was already picked and
        -- authenticated when nothing has actually been configured yet.
        updated_at = now()
    WHERE agent_id = v_agent;
  END IF;

  INSERT INTO allgres_private.permissions (agent_id, resource_type, resource_ref)
  SELECT v_agent, x.resource_type, x.resource_ref
  FROM (VALUES
    ('view', 'allgres_public.v_sales'),
    ('view', 'allgres_public.v_my_tasks'),
    ('tool', 'http_get')
  ) AS x(resource_type, resource_ref)
  ON CONFLICT (agent_id, resource_type, resource_ref) DO NOTHING;

  IF NOT EXISTS (SELECT 1 FROM allgres_private.demo_sales WHERE agent_id = v_agent) THEN
    INSERT INTO allgres_private.demo_sales (agent_id, region, sku, amount, sold_on)
    SELECT v_agent, s.region, s.sku, s.amount, s.sold_on
    FROM (VALUES
      ('seoul',   'ARB-1', 1200.00, DATE '2026-08-01'),
      ('seoul',   'ARB-2',  840.50, DATE '2026-08-03'),
      ('busan',   'ARB-1',  410.00, DATE '2026-08-04'),
      ('incheon', 'ARB-3', 1920.00, DATE '2026-08-07'),
      ('busan',   'ARB-2',  275.25, DATE '2026-08-12')
    ) AS s(region, sku, amount, sold_on);
  END IF;
END
$seed$;

-- A second, deliberately plain demo agent for the Chat page's own "General"
-- tab: item 39's own follow-up to that tab always needing an agent picked
-- from a dropdown first, reported live as friction an operator (or a
-- regular user with exactly one thing they want to talk to) shouldn't have
-- to deal with just to say hello. Unlike 'analyst' it holds no view/tool
-- permissions and no demo data -- a plain conversational partner, not a
-- data-query one -- so its own prompt only ever offers final_answer/
-- await_human, never execute_sql/call_tool.
DO $seed$
DECLARE
  v_agent uuid;
BEGIN
  SELECT agent_id INTO v_agent FROM allgres_private.agents WHERE name = 'general';

  IF v_agent IS NULL THEN
    INSERT INTO allgres_private.agents (name) VALUES ('general') RETURNING agent_id INTO v_agent;

    UPDATE allgres_private.policies
    SET system_prompt = $prompt$You are a helpful, general-purpose conversational assistant. Reply with one JSON object only. No markdown, no prose.

Allowed:
{"action":"final_answer","answer":"..."}
{"action":"await_human","reason":"..."}

Have a normal, friendly conversation. When you have a reply, emit final_answer with your answer as plain text.
$prompt$,
        -- Deliberately no llm_config here, same reason as 'analyst' above.
        updated_at = now()
    WHERE agent_id = v_agent;
  END IF;
END
$seed$;

-- A first, deliberately narrow maintenance/auditor agent (README,
-- "Maintenance agents"): read-only, no mutation surface at all in this
-- slice -- not even propose_change is part of its seeded prompt. It reads
-- v_system_health/v_permission_audit, reports what it finds as its own
-- final_answer (visible in the Sessions thread view like any other run),
-- and remembers anything worth comparing against next time so trends are
-- visible across runs, not just a single snapshot -- the same `remember`
-- action any other agent has, no special case needed. There is no
-- scheduler that runs this automatically; an operator (or an external cron
-- hitting POST /api/v1/run) triggers it, the same as any other agent.
DO $seed$
DECLARE
  v_agent uuid;
BEGIN
  SELECT agent_id INTO v_agent FROM allgres_private.agents WHERE name = 'health_monitor';

  IF v_agent IS NULL THEN
    INSERT INTO allgres_private.agents (name) VALUES ('health_monitor') RETURNING agent_id INTO v_agent;

    UPDATE allgres_private.policies
    SET system_prompt = $prompt$You are Allgres's own health and security monitor. Reply with one JSON object only. No markdown, no prose.

Allowed:
{"action":"final_answer","answer":"..."}
{"action":"execute_sql","sql":"SELECT ..."}
{"action":"remember","content":"...","memory_type":"episodic","importance":0.0-1.0,"subject_id":"system_health"}

You can read exactly two views: allgres_public.v_system_health (worker
counts, queue backlogs, pending approvals, recent failures) and
allgres_public.v_permission_audit (every agent's permission grants). You
cannot change anything -- no propose_change, no delegate, no tools. Your
job is to look, compare against what you remembered last time (it is
already in your own context below, if you have run before), and report:
what changed, anything that looks wrong (a queue backlog that never drains,
an inactive agent that still holds grants, a spike in failed tasks), and
whether it is worth an operator's attention. Remember anything worth
comparing against next run, then give your final_answer as a short summary
a human would actually want to read.
$prompt$,
        max_steps = 6,
        max_retries = 2,
        updated_at = now()
    WHERE agent_id = v_agent;
  END IF;

  INSERT INTO allgres_private.permissions (agent_id, resource_type, resource_ref)
  SELECT v_agent, x.resource_type, x.resource_ref
  FROM (VALUES
    ('view', 'allgres_public.v_system_health'),
    ('view', 'allgres_public.v_permission_audit')
  ) AS x(resource_type, resource_ref)
  ON CONFLICT (agent_id, resource_type, resource_ref) DO NOTHING;
END
$seed$;

-- ---------------------------------------------------------------------------
-- 10a-2. The system agent family (item 32/33): one root plus five children,
-- all is_system=true. The root carries no operational job of its own -- it
-- exists so the five children have one place to inherit shared framing and
-- shared grants from (allgres_private.agent_effective_prompt/
-- agent_has_permission walk parent_agent_id up to it); editing the root
-- changes what every child says and may do without editing five rows.
-- Every child's is_system=true means only an admin session may edit its
-- policy/permissions/autonomy from here on (require_admin_for_system_agent,
-- fn_set_agent_autonomy) -- a regular user can see one it is assigned to
-- (My Agents) but never change it. None of these five ships with an
-- llm_config, same as analyst/health_monitor above and for the same reason
-- (ensure_policy's comment): a fresh install must not look like a provider
-- was already picked before an operator actually chose one.
DO $seed$
DECLARE
  v_root uuid;
BEGIN
  SELECT agent_id INTO v_root FROM allgres_private.agents WHERE name = 'system_root';
  IF v_root IS NULL THEN
    INSERT INTO allgres_private.agents (name, is_system)
    VALUES ('system_root', true) RETURNING agent_id INTO v_root;

    UPDATE allgres_private.policies
    SET system_prompt = $prompt$You are part of Allgres's own system agent family -- built-in agents that
operate the platform itself (this database, its other agents, its own
configuration) rather than a user's workload. You never act alone: every
child agent below adds its own specific job on top of this shared framing.

Reply with one JSON object only. No markdown, no prose. Whatever your
autonomy_level is (visible in your own agent record), never claim an action
took effect before it actually has -- an admin_approval-level action is only
a proposal until decided; a self_approve-level action still means you chose
to act, not that no one is watching; only auto means no human step exists
in the path at all.
$prompt$,
        max_steps = 4,
        updated_at = now()
    WHERE agent_id = v_root;
  END IF;

  -- session_compactor: summarizes a session's older turns once it grows
  -- long, so a long-running Chat/Messenger conversation stays within a
  -- reasonable prompt size without losing what was actually said -- see
  -- fn_maybe_compact_session, the real mechanism this agent's prompt
  -- describes; autonomy_level is 'auto' because its output is additive (a
  -- summary memory placed alongside the untouched, append-only logs, never
  -- a deletion) -- there is nothing here for a human to approve.
  IF NOT EXISTS (SELECT 1 FROM allgres_private.agents WHERE name = 'session_compactor') THEN
    DECLARE v_agent uuid;
    BEGIN
      INSERT INTO allgres_private.agents (name, is_system, parent_agent_id, autonomy_level)
      VALUES ('session_compactor', true, v_root, 'auto') RETURNING agent_id INTO v_agent;
      UPDATE allgres_private.policies
      SET system_prompt = $prompt$Your job is session compaction. Your task input carries: target_session_id
(what this belongs to), turns (the oldest turns of a long conversation that
no longer fit in a normal context window), and previous_summary (a prior
summary of everything before these turns, or null if this is the first
compaction of this session). On your first step, reply with one JSON
object only: {"action":"remember","content":"<summary>","memory_type":"episodic","importance":0.6,"subject_id":"<target_session_id from your input>"}
where <summary> folds previous_summary (when present) together with turns
into one updated, faithful, dense summary (decisions made, facts
established, open questions) -- short enough to replace all of it in future
context, complete enough that nothing important from either is lost. Never
invent anything not actually in previous_summary or turns. Once remember
succeeds, your next step should give final_answer with a one-line
confirmation -- this task is otherwise done.
$prompt$,
          max_steps = 4,
          updated_at = now()
      WHERE agent_id = v_agent;
    END;
  END IF;

  -- orchestrator: Messenger's routing brain for a message that @mentions
  -- more than one agent at once -- decides the order they respond in (and,
  -- through delegate, whether one should hand off to another) instead of
  -- firing every mentioned agent independently and interleaving their
  -- replies at random. See fn_messenger_post's multi-mention branch, the
  -- real call site.
  IF NOT EXISTS (SELECT 1 FROM allgres_private.agents WHERE name = 'orchestrator') THEN
    DECLARE v_agent uuid;
    BEGIN
      INSERT INTO allgres_private.agents (name, is_system, parent_agent_id, autonomy_level)
      VALUES ('orchestrator', true, v_root, 'auto') RETURNING agent_id INTO v_agent;
      UPDATE allgres_private.policies
      SET system_prompt = $prompt$Your job is multi-agent routing in a shared Messenger channel. You are given
one message that @mentions more than one agent, and the name/system_prompt
summary of each. Reply with one JSON object only:
{"action":"final_answer","answer":"<json array of agent names, in the order they should respond>"}
Order by who most directly owns the request first; an agent whose answer
would depend on another's should come after it. You do not answer the
message yourself.
$prompt$,
          max_steps = 4,
          updated_at = now()
      WHERE agent_id = v_agent;
    END;
  END IF;

  -- creator: the only agent that may call create_agent (see fn_submit_result's
  -- create_agent branch) -- proposing a brand-new agent (name + prompt) for
  -- a human or its own admin_approval/self_approve setting to let through.
  IF NOT EXISTS (SELECT 1 FROM allgres_private.agents WHERE name = 'creator') THEN
    DECLARE v_agent uuid;
    BEGIN
      INSERT INTO allgres_private.agents (name, is_system, parent_agent_id, autonomy_level)
      VALUES ('creator', true, v_root, 'admin_approval') RETURNING agent_id INTO v_agent;
      UPDATE allgres_private.policies
      SET system_prompt = $prompt$Your job is helping build new agents for this platform: turn a plain-language
request ("I want something that watches X and tells me Y") into a concrete
new agent. Reply with one JSON object only:
{"action":"create_agent","name":"...","system_prompt":"...","reason":"..."}
name must be short, lowercase, underscore_separated, and not already in
use. system_prompt must fully specify the new agent's job the same way
every other agent's does: what it reads, what it decides, what its
final_answer should look like -- it will run with zero other permissions
until an admin grants some, so say so in the prompt rather than assuming
access it does not have. Depending on your own autonomy_level this either
takes effect immediately or is queued for an admin to accept or reject --
either way, your job ends at proposing it well.
$prompt$,
          max_steps = 6,
          updated_at = now()
      WHERE agent_id = v_agent;
    END;
  END IF;

  -- fixer: reads what health_monitor already found (same two diagnostic
  -- views) and, instead of only reporting, proposes an actual remediation
  -- for a human (or, at higher autonomy, itself) to let through -- see
  -- fn_submit_result's propose_fix branch and fn_decide_fix.
  IF NOT EXISTS (SELECT 1 FROM allgres_private.agents WHERE name = 'fixer') THEN
    DECLARE v_agent uuid;
    BEGIN
      INSERT INTO allgres_private.agents (name, is_system, parent_agent_id, autonomy_level)
      VALUES ('fixer', true, v_root, 'admin_approval') RETURNING agent_id INTO v_agent;
      UPDATE allgres_private.policies
      SET system_prompt = $prompt$Your job is remediation. You can read allgres_public.v_system_health and
allgres_public.v_permission_audit, the same two views health_monitor
watches. When you see something actually wrong (an inactive agent still
holding grants, a queue backlog that never drains, a spike in failed
tasks), propose a concrete, narrow fix. Reply with one JSON object only:
{"action":"propose_fix","fix_kind":"revoke_permission|deactivate_agent","target_agent_id":"...","detail":{...},"reason":"..."}
Never propose anything you cannot fully explain the effect of. If nothing
is actually wrong, use final_answer to say so -- do not manufacture a fix
to have something to propose.
$prompt$,
          max_steps = 6,
          updated_at = now()
      WHERE agent_id = v_agent;
      INSERT INTO allgres_private.permissions (agent_id, resource_type, resource_ref)
      SELECT v_agent, x.resource_type, x.resource_ref
      FROM (VALUES
        ('view', 'allgres_public.v_system_health'),
        ('view', 'allgres_public.v_permission_audit')
      ) AS x(resource_type, resource_ref)
      ON CONFLICT (agent_id, resource_type, resource_ref) DO NOTHING;
    END;
  END IF;

  -- self_improve: the one agent allowed to propose_change against an agent
  -- other than itself (see fn_submit_result's cross-agent propose_change
  -- extension) -- aimed specifically at cost/efficiency (a shorter prompt,
  -- a cheaper model, a lower max_tokens) backed by this agent's own
  -- execution_logs cost stats, never at what the target agent does.
  -- Roadmap item 7 (evaluation-gated self-improvement): also reads
  -- allgres_public.v_agent_health -- a real completed/failed ratio, not
  -- just cost -- so a change is judged by whether the target got cheaper
  -- *without* the agent actually doing worse afterward, and this agent can
  -- check fn_evaluate_last_change on its own past target before proposing
  -- again, instead of assuming its last proposal already helped.
  IF NOT EXISTS (SELECT 1 FROM allgres_private.agents WHERE name = 'self_improve') THEN
    DECLARE v_agent uuid;
    BEGIN
      INSERT INTO allgres_private.agents (name, is_system, parent_agent_id, autonomy_level)
      VALUES ('self_improve', true, v_root, 'admin_approval') RETURNING agent_id INTO v_agent;
      UPDATE allgres_private.policies
      SET system_prompt = $prompt$Your job is cost efficiency, not behavior. You are given one agent's recent
execution_logs cost stats (steps per task, tokens per step, wall-clock time)
and its current system_prompt/llm_config. Look for waste: a prompt padded
with content that never changes the outcome, a model/max_tokens larger than
the task needs, a step pattern that could be shorter. Before proposing,
execute_sql against allgres_public.v_agent_health for the target agent's
recent_success_rate -- a change that makes it cheaper but noticeably less
successful is not an improvement, do not propose it. If you previously
changed this same agent, you can also check whether that change actually
helped: call the same evaluation this platform already tracks for it
(success_rate_before_last_change on that view, or ask an operator to run
fn_evaluate_last_change) before proposing another change on top of it.
Reply with one JSON object only:
{"action":"propose_change","target_agent_id":"...","changes":{"system_prompt":"...","llm_config":{...}},"reason":"..."}
Never change what the target agent is supposed to accomplish -- only how
cheaply it gets there. If you find nothing worth changing, use final_answer
to say so.
$prompt$,
          max_steps = 6,
          updated_at = now()
      WHERE agent_id = v_agent;
      INSERT INTO allgres_private.permissions (agent_id, resource_type, resource_ref)
      VALUES (v_agent, 'view', 'allgres_public.v_agent_health')
      ON CONFLICT (agent_id, resource_type, resource_ref) DO NOTHING;
    END;
  END IF;

  -- health_monitor already reads v_system_health for the cluster as a
  -- whole; v_agent_health is the same idea per-agent, so it belongs to the
  -- same diagnostic surface -- granted here rather than only at creation
  -- time above, so an existing install picks it up on its next apply too.
  INSERT INTO allgres_private.permissions (agent_id, resource_type, resource_ref)
  SELECT agent_id, 'view', 'allgres_public.v_agent_health'
  FROM allgres_private.agents WHERE name = 'health_monitor'
  ON CONFLICT (agent_id, resource_type, resource_ref) DO NOTHING;
END
$seed$;

-- ---------------------------------------------------------------------------
-- 10b. Extension configuration tables -- which of this extension's own
--      tables `pg_dump` includes data for, and on what terms.
--
-- By default `pg_dump` excludes ALL data belonging to an extension's own
-- objects: schema only, regenerated fresh by `CREATE EXTENSION` on restore.
-- Every table below holds real operator/agent state that `CREATE EXTENSION`
-- does not regenerate, so without this a logical backup (`pg_dump`) of this
-- database would restore to a working, EMPTY install -- every agent,
-- session, task, policy, log, and secret silently gone, with no error
-- anywhere to say so. Confirmed live before this was added: a real agent,
-- session, and task, dumped with `pg_dump -Fc` and restored into a fresh
-- cluster, came back with none of it -- only the seed data below. See
-- KNOWN_ISSUES.md, "backup/PITR drill", for the full account and the fix
-- verified afterward. Physical backup (`pg_basebackup` / PITR) has no such
-- gap -- it copies the actual data files -- this is specific to logical
-- (`pg_dump`) backup.
--
-- Tables with no seed rows at all dump unconditionally. The tables section
-- 10 above seeds (llm_providers, sql_sandbox_allowlist, and
-- agents/policies/permissions for the built-in 'analyst', 'general', and
-- 'health_monitor' agents plus the six is_system=true system agents from
-- 10a-2, plus demo_sales for 'analyst' alone)
-- exclude exactly those seeded rows: the extension script recreates them
-- fresh on every install, and dumping them too would try to INSERT a
-- second copy on top and fail on the same UNIQUE constraint that makes
-- them idempotent to begin with. The one real cost of that exclusion: an
-- operator's own edit to a *built-in* provider row (base_url, is_enabled,
-- allow_private_network, a stored secret) does not survive a
-- `pg_dump`-based restore -- only a wholly new provider row would; a
-- physical backup has no such limit. `sql_function_allowlist` and
-- `oauth_states` are deliberately not registered here: every row in the
-- former is exactly what the extension script itself inserts (see
-- KNOWN_ISSUES, "SQL sandbox function check" -- nothing beyond the seed
-- can exist there today), and the latter holds only short-lived
-- in-progress OAuth flow state that is stale within minutes regardless of
-- backup. `oauth_calls` *is* registered, unconditionally, the same as
-- outbound_calls/sql_calls: unlike oauth_states it is an audit trail of
-- exchange attempts an operator may want to keep, and unlike llm_secrets it
-- never holds a plaintext secret or token to begin with (fn_claim_oauth
-- injects the client secret only into its in-memory response to the
-- worker; fn_complete_oauth never writes a response body back into this
-- table -- there is no response_body column on it at all, only a status
-- code and, on failure, the provider's error text).
-- ---------------------------------------------------------------------------

SELECT pg_catalog.pg_extension_config_dump('allgres_private.agents',
  $cfgdump$WHERE NOT (name IN ('analyst', 'health_monitor', 'general') OR is_system)$cfgdump$);
SELECT pg_catalog.pg_extension_config_dump('allgres_private.policies',
  $cfgdump$WHERE agent_id NOT IN (SELECT agent_id FROM allgres_private.agents WHERE name IN ('analyst', 'health_monitor', 'general') OR is_system)$cfgdump$);
SELECT pg_catalog.pg_extension_config_dump('allgres_private.permissions',
  $cfgdump$WHERE agent_id NOT IN (SELECT agent_id FROM allgres_private.agents WHERE name IN ('analyst', 'health_monitor', 'general') OR is_system)$cfgdump$);
SELECT pg_catalog.pg_extension_config_dump('allgres_private.demo_sales',
  $cfgdump$WHERE agent_id <> (SELECT agent_id FROM allgres_private.agents WHERE name = 'analyst')$cfgdump$);
SELECT pg_catalog.pg_extension_config_dump('allgres_private.llm_providers',
  $cfgdump$WHERE name NOT IN ('xai', 'openai', 'anthropic', 'ollama', 'openai_compat')$cfgdump$);
SELECT pg_catalog.pg_extension_config_dump('allgres_private.sql_sandbox_allowlist',
  $cfgdump$WHERE resource_ref NOT IN ('allgres_public.v_sales', 'allgres_public.v_my_tasks', 'allgres_public.v_system_health', 'allgres_public.v_permission_audit')$cfgdump$);

SELECT pg_catalog.pg_extension_config_dump('allgres_private.policy_history', '');
SELECT pg_catalog.pg_extension_config_dump('allgres_private.projects', '');
SELECT pg_catalog.pg_extension_config_dump('allgres_private.sessions', '');
SELECT pg_catalog.pg_extension_config_dump('allgres_private.tasks', '');
SELECT pg_catalog.pg_extension_config_dump('allgres_private.execution_logs', '');
SELECT pg_catalog.pg_extension_config_dump('allgres_private.human_approvals', '');
SELECT pg_catalog.pg_extension_config_dump('allgres_private.change_proposals', '');
SELECT pg_catalog.pg_extension_config_dump('allgres_private.llm_secrets', '');
SELECT pg_catalog.pg_extension_config_dump('allgres_private.outbound_calls', '');
SELECT pg_catalog.pg_extension_config_dump('allgres_private.sql_calls', '');
SELECT pg_catalog.pg_extension_config_dump('allgres_private.oauth_calls', '');
SELECT pg_catalog.pg_extension_config_dump('allgres_private.agent_memories', '');
SELECT pg_catalog.pg_extension_config_dump('allgres_private.audit_log', '');
SELECT pg_catalog.pg_extension_config_dump('allgres_private.api_connections', '');
SELECT pg_catalog.pg_extension_config_dump('allgres_private.api_connection_secrets', '');
SELECT pg_catalog.pg_extension_config_dump('allgres_private.procedures', '');
SELECT pg_catalog.pg_extension_config_dump('allgres_private.procedure_history', '');
SELECT pg_catalog.pg_extension_config_dump('allgres_private.schedules', '');

-- ---------------------------------------------------------------------------
-- 11. Selftest.  Spec section 10 invariants, runnable from the console.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION allgres_public.fn_selftest()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = allgres_private, allgres_public, pg_temp
AS $fn$
DECLARE
  v jsonb := '[]'::jsonb;
  v_agent uuid;
  v_sid uuid;
  v_tid uuid;
  v_saved_prompt text;
  spec jsonb;
  sub jsonb;
  r jsonb;
  n_logs int;
  ok boolean;
  detail text;
  v_call uuid;
  claim jsonb;
  comp jsonb;
  v_project uuid;
  v_approval uuid;
  v_expires timestamptz;
  v_started timestamptz;
  v_tid2 uuid;
  v_gen int;
  v_prov_agent uuid;
  v_role1 text;
  v_role2 text;
  v_proposal uuid;
  v_prompt_before text;
  v_deleg_a uuid;
  v_deleg_b uuid;
  v_provider uuid;
  v_state text;
  v_call2 uuid;
  detail_bool boolean;
  v_mem_result jsonb;
  v_mem_count int;
  v_low_mem uuid;
  v_high_mem uuid;
  v_mem_gc int;
  v_new_agent uuid;
  v_conn uuid;
  v_rate numeric;
  v_eval_child_name text;
  v_sid2 uuid;
  v_direct_sql_user uuid;
  v_root_id uuid;
  v_creator_id uuid;
  v_fixer_id uuid;
  v_self_id uuid;
  v_sys_target uuid;
  v_fix_id uuid;
  v_i int;
  v_comp_sid uuid;
  v_comp_tid uuid;
  v_comp_base timestamptz;
  v_orchestrator_id uuid;
  v_msg_id uuid;
  v_mentioned_ids uuid[];
  v_mention_target uuid;
  v_admin_tok text;
  v_user_tok text;
  v_audit_tok text;
  v_acct_agent uuid;
BEGIN
  -- Clear out any leftover fixtures from an interrupted prior run before
  -- creating new ones, so a crash mid-selftest can't leave stale rows
  -- behind indefinitely.
  PERFORM allgres_private.selftest_cleanup();

  -- 0. origin/db_role provenance, sql half (see section 29a below for the
  -- web half, which uses dashboard_rpc's own calls further down instead):
  -- allgres.audit_operator is a transaction-local GUC (set_config(...,
  -- is_local=true)), so this has to run before dashboard_rpc's own
  -- set_audit_context executes even once anywhere in this function's one
  -- transaction -- once it has, the GUC stays visibly set (not NULL) for
  -- the rest of this call, same as it would for any other single
  -- transaction that mixes a dashboard_rpc call with a later direct one.
  -- fn_allowlist_add/fn_allowlist_del called here, with no dashboard_rpc
  -- anywhere above this line, must record origin='sql', db_role = the
  -- real authenticated role, and no operator_name (nothing here ever
  -- claimed one) -- the exact direct-SQL audit trail the outside review
  -- pointed out was missing entirely before allgres_private.audit existed.
  PERFORM allgres_public.fn_allowlist_add('selftest_audit_origin_marker');
  SELECT origin = 'sql' AND operator_name IS NULL AND db_role = session_user::text
  INTO detail_bool
  FROM allgres_private.audit_log
  WHERE action = 'allowlist.add' AND details->>'resource_ref' = 'selftest_audit_origin_marker'
  ORDER BY created_at DESC LIMIT 1;
  ok := COALESCE(detail_bool, false);
  PERFORM allgres_public.fn_allowlist_del('selftest_audit_origin_marker');
  v := v || jsonb_build_array(jsonb_build_object('name', 'audit_log_direct_sql_call_records_origin_sql', 'ok', ok));

  SELECT agent_id INTO v_agent FROM allgres_private.agents WHERE name = 'analyst' LIMIT 1;
  SELECT system_prompt INTO v_saved_prompt FROM allgres_private.policies WHERE agent_id = v_agent;

  -- 1. next_step messages[0] is the current prompt
  UPDATE allgres_private.policies
  SET system_prompt = 'PROMPT_A_' || extract(epoch from now())::text
  WHERE agent_id = v_agent;
  v_sid := (allgres_public.fn_create_session(v_agent, 'selftest policy')->>'session_id')::uuid;
  SELECT task_id INTO v_tid FROM allgres_private.tasks WHERE session_id = v_sid LIMIT 1;
  spec := allgres_public.fn_next_step(v_tid);
  ok := (spec->'messages'->0->>'content') LIKE 'PROMPT_A_%';
  v := v || jsonb_build_array(jsonb_build_object('name', 'policy_propagates_to_next_step', 'ok', ok));

  -- 2. inactive agent -> done/failed, no side effect
  UPDATE allgres_private.agents SET is_active = false WHERE agent_id = v_agent;
  spec := allgres_public.fn_next_step(v_tid);
  ok := spec->>'action' = 'done' AND spec->>'reason' = 'agent_inactive';
  SELECT status INTO detail FROM allgres_private.tasks WHERE task_id = v_tid;
  ok := ok AND detail = 'failed';
  v := v || jsonb_build_array(jsonb_build_object('name', 'inactive_agent_fails_task', 'ok', ok));
  UPDATE allgres_private.agents SET is_active = true WHERE agent_id = v_agent;

  -- 3. unknown action -> continue, still running
  v_sid := (allgres_public.fn_create_session(v_agent, 'selftest unknown')->>'session_id')::uuid;
  SELECT task_id INTO v_tid FROM allgres_private.tasks WHERE session_id = v_sid LIMIT 1;
  PERFORM allgres_public.fn_next_step(v_tid);
  sub := allgres_public.fn_submit_result(v_tid, jsonb_build_object(
    'type', 'llm_response',
    'content', '{"action":"hack_the_planet"}',
    'parsed', jsonb_build_object('action', 'hack_the_planet')
  ));
  SELECT status INTO detail FROM allgres_private.tasks WHERE task_id = v_tid;
  ok := sub->>'action' = 'continue' AND detail = 'running';
  v := v || jsonb_build_array(jsonb_build_object('name', 'unknown_action_continue', 'ok', ok));

  -- 4. execute_sql INSERT rejected
  PERFORM allgres_public.fn_next_step(v_tid);
  sub := allgres_public.fn_submit_result(v_tid, jsonb_build_object(
    'type', 'llm_response',
    'content', '{"action":"execute_sql"}',
    'parsed', jsonb_build_object('action', 'execute_sql', 'sql', 'INSERT INTO allgres_private.sessions DEFAULT VALUES')
  ));
  SELECT count(*) INTO n_logs
  FROM allgres_private.execution_logs
  WHERE task_id = v_tid AND role = 'error';
  SELECT status INTO detail FROM allgres_private.tasks WHERE task_id = v_tid;
  ok := n_logs >= 1 AND detail = 'running';
  v := v || jsonb_build_array(jsonb_build_object('name', 'insert_rejected_stays_running', 'ok', ok));

  -- 5. sandbox rejects everything outside the allowlist
  FOREACH detail IN ARRAY ARRAY[
    'SELECT * FROM allgres_private.sessions',
    'select * from ARGO_PRIVATE.SESSIONS',
    'SELECT * FROM allgres_private.sessions; SELECT 1',
    E'SELECT * FROM allgres_private./*x*/sessions',
    E'SELECT * FROM allgres_private.\nsessions',
    'SELECT * FROM sessions',
    'SELECT * FROM "allgres_private"."sessions"',
    'WITH x AS (SELECT 1) SELECT * FROM allgres_private.sessions',
    -- comma joins used to slip past the parser entirely
    'SELECT * FROM allgres_public.v_sales a, allgres_private.sessions b',
    'SELECT * FROM allgres_public.v_sales, allgres_private.demo_sales',
    -- catalogue access in a subquery, not in the top-level FROM
    'SELECT (SELECT count(*) FROM pg_catalog.pg_authid) FROM allgres_public.v_sales',
    'SELECT * FROM allgres_public.v_sales UNION ALL SELECT * FROM allgres_private.demo_sales',
    -- a comment splicing a second relation into the FROM list: the grammar sees
    -- through this, a text scanner has to be taught to
    E'SELECT * FROM allgres_public.v_sales --x\n, allgres_private.sessions',
    -- SELECT ... INTO and data-modifying CTEs both parse as a SelectStmt
    'SELECT * INTO allgres_private.stolen FROM allgres_public.v_sales',
    'WITH w AS (DELETE FROM allgres_private.sessions RETURNING 1) SELECT * FROM w',
    -- volatile functions: without the sandbox role fix these would run as
    -- this function's own owner, so the volatility check exists to stop them
    -- even though execution is now sandboxed too (belt and suspenders)
    'SELECT * FROM pg_ls_dir(''.'')',
    'SELECT pg_read_file(''/etc/passwd'') FROM allgres_public.v_sales',
    'SELECT pg_sleep(30) FROM allgres_public.v_sales',
    'SELECT lo_import(''/etc/passwd'')',
    'SELECT random() FROM allgres_public.v_sales',
    'SELECT no_such_function_xyz(1) FROM allgres_public.v_sales',
    -- STABLE, not VOLATILE -- the volatility check alone let this through,
    -- and it hands back the key that encrypts every provider secret.
    'SELECT current_setting(''allgres.secret_key'', true) AS leak',
    'SELECT current_setting(''allgres.secret_key'', true) AS leak FROM allgres_public.v_sales',
    'SELECT version()',
    'SELECT inet_server_addr()',
    -- a user-defined SECURITY DEFINER function, even one Allgres ships
    -- itself, must never be callable from inside the sandbox
    'SELECT allgres_private.secret_key() AS leak',
    -- STABLE, non-security-definer, pg_catalog -- passes every gate a
    -- denylist-only check has, and isn't the kind of name a hand-written
    -- denylist thinks to include. Confirmed live before the allowlist
    -- existed: this validated as ordinary safe SQL and would have returned
    -- every GUC on the server, allgres.secret_key included.
    'SELECT setting FROM pg_catalog.pg_show_all_settings() WHERE name = ''allgres.secret_key''',
    -- an ordinary pg_catalog, non-volatile, non-secdef function that is
    -- simply not on the allowlist -- proves default-deny holds for
    -- anything unseeded, not just the specific names already known to leak
    'SELECT pg_get_userbyid(10) AS whoever'
  ] LOOP
    BEGIN
      PERFORM allgres_private.fn_validate_sql(v_agent, detail);
      ok := false;
    EXCEPTION WHEN others THEN
      ok := true;
    END;
    v := v || jsonb_build_array(jsonb_build_object(
      'name', 'sandbox_reject:' || left(detail, 48),
      'ok', ok
    ));
  END LOOP;

  -- 6. allowed shapes still validate (the parser must not be uselessly
  --    strict); fn_validate_sql only normalizes and returns text now, it does
  --    not execute -- that is covered separately below (item 13)
  FOREACH detail IN ARRAY ARRAY[
    'SELECT region, amount FROM allgres_public.v_sales',
    'SELECT region, sum(amount) AS total FROM allgres_public.v_sales GROUP BY region ORDER BY total DESC',
    'WITH x AS (SELECT region, amount FROM allgres_public.v_sales) SELECT region FROM x',
    'SELECT n FROM generate_series(1, 3) AS g(n)',
    'SELECT s.region, t.status FROM allgres_public.v_sales s, allgres_public.v_my_tasks t',
    -- `FROM` as an operator inside extract(); a text scanner reads this as a
    -- relation reference unless it is special-cased
    'SELECT extract(year FROM sold_on) AS y FROM allgres_public.v_sales',
    -- a schema name inside a string literal is data, not a reference
    'SELECT ''allgres_private.sessions'' AS note FROM allgres_public.v_sales',
    'SELECT region FROM allgres_public.v_sales WHERE sku = ''ARB-1'' /* join allgres_private.x */'
  ] LOOP
    BEGIN
      ok := allgres_private.fn_validate_sql(v_agent, detail) IS NOT NULL;
    EXCEPTION WHEN others THEN
      ok := false;
    END;
    v := v || jsonb_build_array(jsonb_build_object(
      'name', 'sandbox_allow:' || left(detail, 48),
      'ok', ok
    ));
  END LOOP;

  -- 7. logs append-only
  BEGIN
    UPDATE allgres_private.execution_logs SET role = 'user' WHERE task_id = v_tid;
    ok := false;
  EXCEPTION WHEN others THEN
    ok := true;
  END;
  v := v || jsonb_build_array(jsonb_build_object('name', 'logs_append_only', 'ok', ok));

  -- 8. final_answer completes
  v_sid := (allgres_public.fn_create_session(v_agent, 'selftest done')->>'session_id')::uuid;
  SELECT task_id INTO v_tid FROM allgres_private.tasks WHERE session_id = v_sid LIMIT 1;
  PERFORM allgres_public.fn_next_step(v_tid);
  sub := allgres_public.fn_submit_result(v_tid, jsonb_build_object(
    'type', 'llm_response',
    'content', '{"action":"final_answer","answer":"ok"}',
    'parsed', jsonb_build_object('action', 'final_answer', 'answer', 'ok')
  ));
  SELECT status INTO detail FROM allgres_private.tasks WHERE task_id = v_tid;
  ok := sub->>'action' = 'done' AND detail = 'completed';
  v := v || jsonb_build_array(jsonb_build_object('name', 'final_answer_completes', 'ok', ok));

  -- 9. outbound guard blocks the SSRF shapes on every path, not just http_get
  ok := allgres_private.is_blocked_host('169.254.169.254')
    AND allgres_private.is_blocked_host('127.0.0.1')
    AND allgres_private.is_blocked_host('::1')
    AND allgres_private.is_blocked_host('::ffff:127.0.0.1')
    AND allgres_private.is_blocked_host('fd00::1')
    AND allgres_private.is_blocked_host('fe80::1')
    AND allgres_private.is_blocked_host('2130706433')
    AND allgres_private.is_blocked_host('0x7f000001')
    AND allgres_private.is_blocked_host('metadata.internal')
    AND allgres_private.is_blocked_host('10.1.2.3')
    AND allgres_private.is_blocked_host('172.16.0.1')
    AND allgres_private.is_blocked_host('100.64.0.1')
    AND NOT allgres_private.is_blocked_host('api.openai.com')
    AND NOT allgres_private.is_blocked_host('api.x.ai');
  v := v || jsonb_build_array(jsonb_build_object('name', 'blocked_host_matrix', 'ok', ok));

  ok := allgres_private.check_outbound_url('https://169.254.169.254/latest/meta-data/') IS NOT NULL
    AND allgres_private.check_outbound_url('http://api.openai.com/v1') IS NOT NULL
    AND allgres_private.check_outbound_url('file:///etc/passwd') IS NOT NULL
    AND allgres_private.check_outbound_url('https://evil.example.com@127.0.0.1/') IS NOT NULL
    AND allgres_private.check_outbound_url('https://api.openai.com/v1') IS NULL
    AND allgres_private.check_outbound_url('http://127.0.0.1:11434/v1', true) IS NULL;
  v := v || jsonb_build_array(jsonb_build_object('name', 'outbound_url_guard', 'ok', ok));

  -- 10. per-agent llm_config can no longer redirect the provider endpoint
  ok := NOT (allgres_private.sanitize_llm_config(
          '{"model":"m","base_url":"http://169.254.169.254"}'::jsonb) ? 'base_url');
  v := v || jsonb_build_array(jsonb_build_object('name', 'llm_config_cannot_set_base_url', 'ok', ok));

  -- 11. the views enforce permission on their own, so authorisation does not
  --     depend on fn_validate_sql having spotted every reference
  PERFORM set_config('allgres.agent_id', gen_random_uuid()::text, true);
  SELECT count(*) INTO n_logs FROM allgres_public.v_sales;
  ok := (n_logs = 0);
  PERFORM set_config('allgres.agent_id', v_agent::text, true);
  SELECT count(*) INTO n_logs FROM allgres_public.v_sales;
  ok := ok AND (n_logs > 0);
  PERFORM set_config('allgres.agent_id', '', true);
  SELECT count(*) INTO n_logs FROM allgres_public.v_sales;
  ok := ok AND (n_logs = 0);
  v := v || jsonb_build_array(jsonb_build_object('name', 'views_enforce_permission', 'ok', ok));

  -- 12. the analyser reads the real parse tree, not the statement text
  ok := (allgres.analyze_sql('SELECT 1')->>'kind') = 'select'
    AND (allgres.analyze_sql('SELECT 1; SELECT 2')->>'statements')::int = 2
    AND (allgres.analyze_sql('UPDATE allgres_private.agents SET name = ''x''')->>'kind') = 'other'
    AND (allgres.analyze_sql('SELECT * INTO t FROM allgres_public.v_sales')->>'writes')::boolean
    AND (allgres.analyze_sql(
           E'SELECT * FROM allgres_public.v_sales --x\n, allgres_private.sessions'
         )->'relations') @> '[{"schema":"allgres_private","name":"sessions"}]'::jsonb
    AND NOT ((allgres.analyze_sql('SELECT ''allgres_private.sessions'' FROM allgres_public.v_sales')->'relations')
             @> '[{"schema":"allgres_private"}]'::jsonb);
  v := v || jsonb_build_array(jsonb_build_object('name', 'native_parser_analysis', 'ok', ok));

  -- 13. execute_sql queues a call instead of running inline; the runtime
  --     worker claims it, runs it as the sandbox role (fn_run_sandboxed_sql,
  --     exercised directly against a live `sandbox` session in
  --     tests/smoke.sql -- this function is SECURITY DEFINER and so cannot
  --     itself do the SET ROLE), and posts the result back through
  --     fn_claim_sql/fn_complete_sql, the same claim/complete shape the
  --     outbound HTTP pump uses.
  v_sid := (allgres_public.fn_create_session(v_agent, 'selftest execute_sql_queue')->>'session_id')::uuid;
  SELECT task_id INTO v_tid FROM allgres_private.tasks WHERE session_id = v_sid LIMIT 1;
  PERFORM allgres_public.fn_next_step(v_tid);
  sub := allgres_public.fn_submit_result(v_tid, jsonb_build_object(
    'type', 'llm_response',
    'content', '{"action":"execute_sql"}',
    'parsed', jsonb_build_object('action', 'execute_sql', 'sql', 'SELECT region FROM allgres_public.v_sales')
  ));
  v_call := (sub->>'call_id')::uuid;
  SELECT status INTO detail FROM allgres_private.tasks WHERE task_id = v_tid;
  ok := sub->>'action' = 'execute_sql' AND v_call IS NOT NULL AND detail = 'running';
  SELECT status INTO detail FROM allgres_private.sql_calls WHERE call_id = v_call;
  ok := ok AND detail = 'queued';
  v := v || jsonb_build_array(jsonb_build_object('name', 'execute_sql_queues_a_call', 'ok', ok));

  -- 13b. The task is still 'running' with no outbound_calls row -- the model
  --      just asked for execute_sql and the SQL result has not come back yet
  --      -- so before the sql_calls guard existed, fn_dispatch_tasks would
  --      call fn_next_step on it again right here, rebuild the same dangling
  --      execute_sql request from execution_logs (no tool result exists for
  --      it yet), and fire a second, racing LLM call before the pending SQL
  --      result was ever seen. It must dispatch nothing while that sql_calls
  --      row is still queued.
  PERFORM allgres_public.fn_dispatch_tasks();
  ok := NOT EXISTS (
    SELECT 1 FROM allgres_private.outbound_calls WHERE task_id = v_tid
  );
  v := v || jsonb_build_array(jsonb_build_object('name', 'dispatch_holds_back_pending_sql_task', 'ok', ok));

  claim := allgres_public.fn_claim_sql(10);
  ok := (claim->>'count')::int >= 1
    AND EXISTS (
      SELECT 1 FROM jsonb_array_elements(claim->'calls') c
      WHERE (c->>'call_id')::uuid = v_call AND c->>'sql' = 'SELECT region FROM allgres_public.v_sales'
    );
  SELECT status INTO detail FROM allgres_private.sql_calls WHERE call_id = v_call;
  ok := ok AND detail = 'in_flight';
  v := v || jsonb_build_array(jsonb_build_object('name', 'claim_sql_marks_in_flight', 'ok', ok));

  comp := allgres_public.fn_complete_sql(v_call, true, '[{"region":"west"}]'::jsonb, 1, false, NULL);
  SELECT count(*) INTO n_logs
  FROM allgres_private.execution_logs
  WHERE task_id = v_tid AND role = 'tool' AND content->>'sql' = 'SELECT region FROM allgres_public.v_sales';
  SELECT status INTO detail FROM allgres_private.sql_calls WHERE call_id = v_call;
  ok := (comp->'submit'->>'action') = 'continue' AND n_logs = 1 AND detail = 'harvested';
  v := v || jsonb_build_array(jsonb_build_object('name', 'complete_sql_appends_tool_log', 'ok', ok));

  -- a worker-side execution failure (sandbox unavailable, statement timeout,
  -- ...) is logged as an error and retried, not treated as validation having
  -- missed something
  v_sid := (allgres_public.fn_create_session(v_agent, 'selftest execute_sql_failure')->>'session_id')::uuid;
  SELECT task_id INTO v_tid FROM allgres_private.tasks WHERE session_id = v_sid LIMIT 1;
  PERFORM allgres_public.fn_next_step(v_tid);
  sub := allgres_public.fn_submit_result(v_tid, jsonb_build_object(
    'type', 'llm_response',
    'content', '{"action":"execute_sql"}',
    'parsed', jsonb_build_object('action', 'execute_sql', 'sql', 'SELECT region FROM allgres_public.v_sales')
  ));
  v_call := (sub->>'call_id')::uuid;
  PERFORM allgres_public.fn_claim_sql(10);
  comp := allgres_public.fn_complete_sql(v_call, false, NULL, NULL, false, 'statement timeout');
  SELECT count(*) INTO n_logs
  FROM allgres_private.execution_logs
  WHERE task_id = v_tid AND role = 'error';
  SELECT status INTO detail FROM allgres_private.tasks WHERE task_id = v_tid;
  ok := n_logs >= 1 AND detail = 'running';
  v := v || jsonb_build_array(jsonb_build_object('name', 'complete_sql_failure_logs_error', 'ok', ok));

  -- 13b. Fencing: a belated completion for a call fn_watchdog already
  --      reclaimed as 'lost' (a zombie worker's result for an attempt the
  --      task has already moved past) must be discarded, not recorded --
  --      accepting it would inject a stale response into whatever the task
  --      is doing now, which could by now be a completely different turn.
  v_sid := (allgres_public.fn_create_session(v_agent, 'selftest sql_fencing')->>'session_id')::uuid;
  SELECT task_id INTO v_tid FROM allgres_private.tasks WHERE session_id = v_sid LIMIT 1;
  PERFORM allgres_public.fn_next_step(v_tid);
  sub := allgres_public.fn_submit_result(v_tid, jsonb_build_object(
    'type', 'llm_response',
    'content', '{"action":"execute_sql"}',
    'parsed', jsonb_build_object('action', 'execute_sql', 'sql', 'SELECT region FROM allgres_public.v_sales')
  ));
  v_call := (sub->>'call_id')::uuid;
  PERFORM allgres_public.fn_claim_sql(10);
  -- Simulate what fn_watchdog does to a stuck in_flight call.
  UPDATE allgres_private.sql_calls SET status = 'lost', updated_at = now() WHERE call_id = v_call;
  SELECT count(*) INTO n_logs FROM allgres_private.execution_logs WHERE task_id = v_tid;
  comp := allgres_public.fn_complete_sql(v_call, true, '[{"region":"west"}]'::jsonb, 1, false, NULL);
  ok := comp->'submit'->>'action' = 'stale';
  SELECT status INTO detail FROM allgres_private.sql_calls WHERE call_id = v_call;
  ok := ok AND detail = 'lost';
  SELECT count(*) INTO v_gen FROM allgres_private.execution_logs WHERE task_id = v_tid;
  ok := ok AND v_gen = n_logs;
  v := v || jsonb_build_array(jsonb_build_object('name', 'complete_sql_fences_stale_result', 'ok', ok));

  -- Same fencing, for fn_complete_outbound. A synthetic row stands in for
  -- one fn_dispatch_tasks would have queued; exercising the fence does not
  -- need the provider machinery that inserts it normally.
  v_sid := (allgres_public.fn_create_session(v_agent, 'selftest outbound_fencing')->>'session_id')::uuid;
  SELECT task_id INTO v_tid FROM allgres_private.tasks WHERE session_id = v_sid LIMIT 1;
  INSERT INTO allgres_private.outbound_calls (task_id, kind, url, status)
  VALUES (v_tid, 'llm', 'https://api.x.ai/v1/chat/completions', 'in_flight')
  RETURNING call_id INTO v_call;
  UPDATE allgres_private.outbound_calls SET status = 'lost', updated_at = now() WHERE call_id = v_call;
  SELECT count(*) INTO n_logs FROM allgres_private.execution_logs WHERE task_id = v_tid;
  comp := allgres_public.fn_complete_outbound(v_call, 200, '{"choices":[{"message":{"content":"{\"action\":\"final_answer\",\"answer\":\"stale\"}"}}]}');
  ok := comp->'submit'->>'action' = 'stale';
  SELECT status INTO detail FROM allgres_private.outbound_calls WHERE call_id = v_call;
  ok := ok AND detail = 'lost';
  SELECT count(*) INTO v_gen FROM allgres_private.execution_logs WHERE task_id = v_tid;
  ok := ok AND v_gen = n_logs;
  v := v || jsonb_build_array(jsonb_build_object('name', 'complete_outbound_fences_stale_result', 'ok', ok));

  -- 14. sessions can be scoped to a project; fn_create_session rejects an
  --     inactive or missing project the same way it already rejects an
  --     inactive or missing agent.  Project name carries a timestamp so
  --     repeat selftest runs don't collide on the UNIQUE constraint.
  v_project := (allgres_public.fn_create_project(
    'selftest project ' || extract(epoch from clock_timestamp())::text
  )->>'project_id')::uuid;
  v_sid := (allgres_public.fn_create_session(v_agent, 'selftest project_scoped', v_project)->>'session_id')::uuid;
  SELECT (project_id = v_project) INTO ok FROM allgres_private.sessions WHERE session_id = v_sid;
  v := v || jsonb_build_array(jsonb_build_object('name', 'session_scoped_to_project', 'ok', ok));

  PERFORM allgres_public.fn_set_project_active(v_project, false);
  BEGIN
    PERFORM allgres_public.fn_create_session(v_agent, 'selftest inactive_project', v_project);
    ok := false;
  EXCEPTION WHEN others THEN
    ok := true;
  END;
  v := v || jsonb_build_array(jsonb_build_object('name', 'inactive_project_rejected', 'ok', ok));

  -- 15. await_human sets an expiry, and once decided the human's actual
  --     reply is fed back into the conversation as an 'operator' log entry
  --     -- not just an approve/reject bit fn_next_step can't see.
  v_sid := (allgres_public.fn_create_session(v_agent, 'selftest approval_reply')->>'session_id')::uuid;
  SELECT task_id INTO v_tid FROM allgres_private.tasks WHERE session_id = v_sid LIMIT 1;
  PERFORM allgres_public.fn_next_step(v_tid);
  SELECT started_at INTO v_started FROM allgres_private.tasks WHERE task_id = v_tid;
  sub := allgres_public.fn_submit_result(v_tid, jsonb_build_object(
    'type', 'llm_response',
    'content', '{"action":"await_human"}',
    'parsed', jsonb_build_object('action', 'await_human', 'reason', 'Which quarter definition?')
  ));
  SELECT status INTO detail FROM allgres_private.tasks WHERE task_id = v_tid;
  ok := sub->>'action' = 'wait' AND detail = 'waiting_human';
  SELECT approval_id, expires_at INTO v_approval, v_expires
  FROM allgres_private.human_approvals WHERE task_id = v_tid AND status = 'pending';
  ok := ok AND v_approval IS NOT NULL
    AND v_expires > now() AND v_expires <= now() + interval '24 hours 1 minute';
  v := v || jsonb_build_array(jsonb_build_object('name', 'await_human_creates_pending_approval', 'ok', ok));

  comp := allgres_public.fn_decide_approval(v_approval, true, 'Use the fiscal-year quarter.');
  SELECT count(*) INTO n_logs
  FROM allgres_private.execution_logs
  WHERE task_id = v_tid AND role = 'operator'
    AND content = to_jsonb('Use the fiscal-year quarter.'::text);
  SELECT status INTO detail FROM allgres_private.tasks WHERE task_id = v_tid;
  ok := COALESCE((comp->>'task_updated')::boolean, false) AND n_logs = 1 AND detail = 'queued';
  v := v || jsonb_build_array(jsonb_build_object('name', 'approval_reply_feeds_back_into_log', 'ok', ok));

  -- 15b. The log row above is necessary but not sufficient: fn_next_step
  --      builds the actual LLM request from execution_logs, and used to skip
  --      role='operator' entirely (only system/user/assistant/tool made it
  --      into the message list), so the dashboard showed the human's reply
  --      but the agent's next call_llm never carried it. It has to arrive as
  --      a 'user' turn, the same way a tool result does.
  spec := allgres_public.fn_next_step(v_tid);
  ok := spec->>'action' = 'call_llm'
    AND EXISTS (
      SELECT 1 FROM jsonb_array_elements(spec->'messages') m
      WHERE m->>'role' = 'user' AND m->>'content' = 'Use the fiscal-year quarter.'
    );
  v := v || jsonb_build_array(jsonb_build_object('name', 'operator_reply_reaches_llm_messages', 'ok', ok));

  -- 15c. fn_next_step just drove the task through 'waiting_human' -> 'queued'
  --      -> 'running' again (fn_decide_approval put it back to 'queued'; the
  --      call above resumed it). started_at must survive that: a bare
  --      `started_at = now()` on every queued->running transition would
  --      reset it on every human resume, silently turning max_turn_seconds
  --      into "time since last resume" instead of "time since this task
  --      first ran" for any task that ever waits on a human.
  SELECT started_at INTO v_expires FROM allgres_private.tasks WHERE task_id = v_tid;
  ok := v_started IS NOT NULL AND v_expires = v_started;
  v := v || jsonb_build_array(jsonb_build_object('name', 'started_at_survives_human_resume', 'ok', ok));

  -- 16. fn_watchdog reclaims an approval nobody ever answers -- the same
  --     self-healing shape it already applies to stuck outbound/sql calls,
  --     just on a per-row deadline instead of p_timeout_seconds.
  v_sid := (allgres_public.fn_create_session(v_agent, 'selftest approval_expiry')->>'session_id')::uuid;
  SELECT task_id INTO v_tid FROM allgres_private.tasks WHERE session_id = v_sid LIMIT 1;
  PERFORM allgres_public.fn_next_step(v_tid);
  PERFORM allgres_public.fn_submit_result(v_tid, jsonb_build_object(
    'type', 'llm_response',
    'content', '{"action":"await_human"}',
    'parsed', jsonb_build_object('action', 'await_human', 'reason', 'will never be answered')
  ));
  UPDATE allgres_private.human_approvals
  SET expires_at = now() - interval '1 minute'
  WHERE task_id = v_tid AND status = 'pending';
  PERFORM allgres_public.fn_watchdog();
  SELECT status INTO detail FROM allgres_private.human_approvals WHERE task_id = v_tid;
  ok := detail = 'rejected';
  SELECT status INTO detail FROM allgres_private.tasks WHERE task_id = v_tid;
  ok := ok AND detail = 'failed';
  SELECT count(*) INTO n_logs
  FROM allgres_private.execution_logs
  WHERE task_id = v_tid AND role = 'operator'
    AND content = to_jsonb('No response before the approval expired.'::text);
  ok := ok AND n_logs = 1;
  v := v || jsonb_build_array(jsonb_build_object('name', 'watchdog_expires_stale_approval', 'ok', ok));

  -- 17. fn_cancel_session stops every open task in the session, rejects any
  --     pending approval so it doesn't linger, and closes the session --
  --     the control that was simply missing before this pass.
  v_sid := (allgres_public.fn_create_session(v_agent, 'selftest cancel_session')->>'session_id')::uuid;
  SELECT task_id INTO v_tid FROM allgres_private.tasks WHERE session_id = v_sid LIMIT 1;
  PERFORM allgres_public.fn_next_step(v_tid);
  PERFORM allgres_public.fn_submit_result(v_tid, jsonb_build_object(
    'type', 'llm_response',
    'content', '{"action":"await_human"}',
    'parsed', jsonb_build_object('action', 'await_human', 'reason', 'irrelevant, session gets cancelled')
  ));
  comp := allgres_public.fn_cancel_session(v_sid, 'selftest stop');
  SELECT status INTO detail FROM allgres_private.tasks WHERE task_id = v_tid;
  ok := (comp->>'tasks_cancelled')::int = 1 AND detail = 'cancelled';
  SELECT status INTO detail FROM allgres_private.sessions WHERE session_id = v_sid;
  ok := ok AND detail = 'cancelled';
  ok := ok AND NOT EXISTS (
    SELECT 1 FROM allgres_private.human_approvals WHERE task_id = v_tid AND status = 'pending'
  );
  SELECT count(*) INTO n_logs
  FROM allgres_private.execution_logs
  WHERE task_id = v_tid AND role = 'operator' AND content = to_jsonb('selftest stop'::text);
  ok := ok AND n_logs = 1;
  v := v || jsonb_build_array(jsonb_build_object('name', 'cancel_session_stops_open_task', 'ok', ok));

  -- 17b. Marking the task 'cancelled' above is not enough on its own: a
  --      'queued' outbound_calls or sql_calls row for it would otherwise
  --      still be claimable and would still actually fire (HTTP request or
  --      sandboxed query) after the operator cancelled the session --
  --      fn_cancel_session must also mark those rows 'lost' itself, and
  --      fn_claim_outbound/fn_claim_sql's own task-status join is the second
  --      layer in case anything is queued in the race window before that.
  v_sid := (allgres_public.fn_create_session(v_agent, 'selftest cancel_pending_calls')->>'session_id')::uuid;
  SELECT task_id INTO v_tid FROM allgres_private.tasks WHERE session_id = v_sid LIMIT 1;
  PERFORM allgres_public.fn_next_step(v_tid);
  sub := allgres_public.fn_submit_result(v_tid, jsonb_build_object(
    'type', 'llm_response',
    'content', '{"action":"execute_sql"}',
    'parsed', jsonb_build_object('action', 'execute_sql', 'sql', 'SELECT region FROM allgres_public.v_sales')
  ));
  v_call := (sub->>'call_id')::uuid;
  -- A synthetic queued outbound row on the same task, standing in for one
  -- fn_dispatch_tasks would have queued for a real LLM turn -- exercising the
  -- cleanup does not require the provider machinery that inserts it normally.
  INSERT INTO allgres_private.outbound_calls (task_id, kind, url, status)
  VALUES (v_tid, 'llm', 'https://api.x.ai/v1/chat/completions', 'queued')
  RETURNING call_id INTO v_tid2;
  comp := allgres_public.fn_cancel_session(v_sid, 'selftest stop pending calls');
  SELECT status INTO detail FROM allgres_private.sql_calls WHERE call_id = v_call;
  ok := (comp->>'tasks_cancelled')::int = 1 AND detail = 'lost';
  SELECT status INTO detail FROM allgres_private.outbound_calls WHERE call_id = v_tid2;
  ok := ok AND detail = 'lost';
  claim := allgres_public.fn_claim_sql(10);
  ok := ok AND NOT EXISTS (
    SELECT 1 FROM jsonb_array_elements(claim->'calls') c WHERE (c->>'call_id')::uuid = v_call
  );
  claim := allgres_public.fn_claim_outbound(10);
  ok := ok AND NOT EXISTS (
    SELECT 1 FROM jsonb_array_elements(claim->'calls') c WHERE (c->>'call_id')::uuid = v_tid2
  );
  v := v || jsonb_build_array(jsonb_build_object('name', 'cancel_session_voids_pending_calls', 'ok', ok));

  -- 18. fn_grant_permission / fn_revoke_permission -- the RPC surface
  --     (permissions.grant/revoke) is a thin passthrough to these, so
  --     exercising them here covers both.  Uses a scratch http_host ref
  --     rather than a real view grant, so it can't disturb the seeded
  --     permissions the sandbox_allow/reject cases above depend on.
  PERFORM allgres_public.fn_grant_permission(v_agent, 'http_host', 'selftest.invalid');
  ok := EXISTS (
    SELECT 1 FROM allgres_private.permissions
    WHERE agent_id = v_agent AND resource_type = 'http_host' AND resource_ref = 'selftest.invalid'
  );
  v := v || jsonb_build_array(jsonb_build_object('name', 'grant_permission_creates_row', 'ok', ok));

  PERFORM allgres_public.fn_revoke_permission(v_agent, 'http_host', 'selftest.invalid');
  ok := NOT EXISTS (
    SELECT 1 FROM allgres_private.permissions
    WHERE agent_id = v_agent AND resource_type = 'http_host' AND resource_ref = 'selftest.invalid'
  );
  v := v || jsonb_build_array(jsonb_build_object('name', 'revoke_permission_removes_row', 'ok', ok));

  -- Roadmap item 4: allgres_private.procedures -- a named, versioned,
  -- reusable "how to do X" any agent granted a matching 'procedure'
  -- permission sees in its own prompt every turn. Same versioning shape as
  -- fn_set_policy (only an actual content change snapshots history and
  -- bumps generation), same rollback shape as fn_rollback_policy (a new
  -- version, never a rewrite).
  DELETE FROM allgres_private.procedure_history WHERE procedure_id IN (
    SELECT procedure_id FROM allgres_private.procedures WHERE name = 'selftest_procedure'
  );
  DELETE FROM allgres_private.procedures WHERE name = 'selftest_procedure';
  r := allgres_public.fn_create_procedure('selftest_procedure', 'selftest v1: do the thing carefully');
  ok := (r->>'ok')::boolean;
  v_call := (r->>'procedure_id')::uuid;
  ok := ok AND (SELECT generation FROM allgres_private.procedures WHERE procedure_id = v_call) = 1;
  v := v || jsonb_build_array(jsonb_build_object('name', 'fn_create_procedure_starts_at_generation_one', 'ok', ok));

  sub := allgres_public.fn_set_procedure(v_call, NULL, NULL);
  ok := (sub->>'changed')::boolean IS FALSE
    AND (SELECT generation FROM allgres_private.procedures WHERE procedure_id = v_call) = 1
    AND NOT EXISTS (SELECT 1 FROM allgres_private.procedure_history WHERE procedure_id = v_call);
  v := v || jsonb_build_array(jsonb_build_object('name', 'fn_set_procedure_noop_does_not_version', 'ok', ok));

  sub := allgres_public.fn_set_procedure(v_call, 'selftest v2: do the thing carefully, then verify', NULL);
  ok := (sub->>'changed')::boolean IS TRUE
    AND (sub->>'generation')::int = 2
    AND (SELECT content FROM allgres_private.procedures WHERE procedure_id = v_call) LIKE '%then verify%'
    AND (SELECT content FROM allgres_private.procedure_history WHERE procedure_id = v_call AND generation = 1)
        = 'selftest v1: do the thing carefully';
  v := v || jsonb_build_array(jsonb_build_object('name', 'fn_set_procedure_versions_on_real_change', 'ok', ok));

  sub := allgres_public.fn_rollback_procedure(v_call, 1);
  ok := (sub->>'generation')::int = 3
    AND (SELECT content FROM allgres_private.procedures WHERE procedure_id = v_call)
        = 'selftest v1: do the thing carefully'
    AND (SELECT count(*) FROM allgres_private.procedure_history WHERE procedure_id = v_call) = 2;
  v := v || jsonb_build_array(jsonb_build_object('name', 'fn_rollback_procedure_restores_via_a_new_version', 'ok', ok));

  BEGIN
    PERFORM allgres_public.fn_rollback_procedure(v_call, 99);
    ok := false;
  EXCEPTION WHEN others THEN
    ok := true;
  END;
  v := v || jsonb_build_array(jsonb_build_object('name', 'fn_rollback_procedure_rejects_unknown_generation', 'ok', ok));

  -- Recall: gated by the same agent_permission_refs check as a view/tool
  -- grant, and inherited through a parent chain the same way (not
  -- re-tested here -- system_agent_inherits_root_permission already proves
  -- the underlying mechanism for a different resource_type).
  v_sid := (allgres_public.fn_create_session(v_agent, 'selftest procedure recall')->>'session_id')::uuid;
  SELECT task_id INTO v_tid FROM allgres_private.tasks WHERE session_id = v_sid LIMIT 1;
  spec := allgres_public.fn_next_step(v_tid);
  ok := (spec->'messages'->0->>'content') NOT LIKE '%# procedures%';
  v := v || jsonb_build_array(jsonb_build_object('name', 'procedure_hidden_from_prompt_without_permission', 'ok', ok));

  PERFORM allgres_public.fn_grant_permission(v_agent, 'procedure', 'selftest_procedure');
  UPDATE allgres_private.tasks SET status = 'running' WHERE task_id = v_tid;
  spec := allgres_public.fn_next_step(v_tid);
  ok := (spec->'messages'->0->>'content') LIKE '%# procedures%'
    AND (spec->'messages'->0->>'content') LIKE '%selftest v1: do the thing carefully%';
  v := v || jsonb_build_array(jsonb_build_object('name', 'procedure_shown_in_prompt_once_granted', 'ok', ok));
  PERFORM allgres_public.fn_revoke_permission(v_agent, 'procedure', 'selftest_procedure');

  -- Disabled (is_active = false) never shows even with a grant -- the same
  -- "operator can pull a bad one without deleting its history" property
  -- is_enabled already gives an llm_provider.
  PERFORM allgres_public.fn_grant_permission(v_agent, 'procedure', 'selftest_procedure');
  PERFORM allgres_public.fn_set_procedure(v_call, NULL, false);
  UPDATE allgres_private.tasks SET status = 'running' WHERE task_id = v_tid;
  spec := allgres_public.fn_next_step(v_tid);
  ok := (spec->'messages'->0->>'content') NOT LIKE '%# procedures%';
  v := v || jsonb_build_array(jsonb_build_object('name', 'disabled_procedure_hidden_even_with_permission', 'ok', ok));
  PERFORM allgres_public.fn_revoke_permission(v_agent, 'procedure', 'selftest_procedure');
  DELETE FROM allgres_private.procedure_history WHERE procedure_id = v_call;
  DELETE FROM allgres_private.procedures WHERE procedure_id = v_call;

  -- 19. fn_set_policy only versions on a real change.  A no-op call (every
  --     param NULL/false) must not bump generation or write history --
  --     agents.update calls this on every save, e.g. just flipping
  --     is_active, and that must not manufacture a version.  A call that
  --     actually changes something must do both, and the pre-change values
  --     must land in policy_history under the *old* generation number.
  SELECT generation INTO v_gen FROM allgres_private.policies WHERE agent_id = v_agent;
  PERFORM allgres_public.fn_set_policy(v_agent);
  ok := (SELECT generation FROM allgres_private.policies WHERE agent_id = v_agent) = v_gen;
  ok := ok AND NOT EXISTS (
    SELECT 1 FROM allgres_private.policy_history WHERE agent_id = v_agent AND generation = v_gen
  );
  v := v || jsonb_build_array(jsonb_build_object('name', 'noop_policy_update_does_not_version', 'ok', ok));

  comp := allgres_public.fn_set_policy(v_agent, NULL, NULL, NULL, NULL, 7);
  ok := COALESCE((comp->>'changed')::boolean, false) AND (comp->>'generation')::int = v_gen + 1;
  ok := ok AND (SELECT max_concurrent_tasks FROM allgres_private.policies WHERE agent_id = v_agent) = 7;
  ok := ok AND EXISTS (
    SELECT 1 FROM allgres_private.policy_history
    WHERE agent_id = v_agent AND generation = v_gen AND max_concurrent_tasks = 4
  );
  v := v || jsonb_build_array(jsonb_build_object('name', 'real_policy_update_versions_the_old_row', 'ok', ok));
  PERFORM allgres_public.fn_set_policy(v_agent, NULL, NULL, NULL, NULL, 4);

  -- 19b. propose_change: an agent's own request to change its behavior
  --      never touches the live policy directly -- it only ever queues a
  --      row for an operator to decide. Not blocking, unlike await_human:
  --      the task keeps running.
  v_sid := (allgres_public.fn_create_session(v_agent, 'selftest propose_change')->>'session_id')::uuid;
  SELECT task_id INTO v_tid FROM allgres_private.tasks WHERE session_id = v_sid LIMIT 1;
  SELECT system_prompt, generation INTO v_prompt_before, v_gen FROM allgres_private.policies WHERE agent_id = v_agent;
  PERFORM allgres_public.fn_next_step(v_tid);
  sub := allgres_public.fn_submit_result(v_tid, jsonb_build_object(
    'type', 'llm_response',
    'content', '{"action":"propose_change"}',
    'parsed', jsonb_build_object(
      'action', 'propose_change',
      'changes', jsonb_build_object('system_prompt', 'Be terser.'),
      'reason', 'selftest'
    )
  ));
  v_proposal := (sub->>'proposal_id')::uuid;
  SELECT status INTO detail FROM allgres_private.tasks WHERE task_id = v_tid;
  ok := sub->>'action' = 'continue' AND v_proposal IS NOT NULL AND detail = 'running';
  ok := ok AND EXISTS (
    SELECT 1 FROM allgres_private.change_proposals
    WHERE proposal_id = v_proposal AND agent_id = v_agent AND status = 'pending'
      AND proposed_changes = jsonb_build_object('system_prompt', 'Be terser.')
      AND base_generation = v_gen
  );
  ok := ok AND (SELECT system_prompt FROM allgres_private.policies WHERE agent_id = v_agent) = v_prompt_before;
  v := v || jsonb_build_array(jsonb_build_object('name', 'propose_change_queues_a_proposal', 'ok', ok));

  -- 19c. Only system_prompt and llm_config.{model,temperature,max_tokens}
  --      may be proposed -- an agent can improve its own behavior, never
  --      expand its own resource envelope or redirect its own provider
  --      endpoint. Both rejections must be logged, not silently dropped,
  --      and must not create a proposal row.
  PERFORM allgres_public.fn_submit_result(v_tid, jsonb_build_object(
    'type', 'llm_response',
    'content', '{"action":"propose_change"}',
    'parsed', jsonb_build_object('action', 'propose_change', 'changes', jsonb_build_object('max_steps', 999))
  ));
  PERFORM allgres_public.fn_submit_result(v_tid, jsonb_build_object(
    'type', 'llm_response',
    'content', '{"action":"propose_change"}',
    'parsed', jsonb_build_object(
      'action', 'propose_change',
      'changes', jsonb_build_object('llm_config', jsonb_build_object('provider', 'evil'))
    )
  ));
  SELECT count(*) INTO n_logs FROM allgres_private.execution_logs
  WHERE task_id = v_tid AND role = 'error' AND content->>'reason' = 'propose_change_field_not_allowed';
  ok := n_logs = 2 AND NOT EXISTS (
    SELECT 1 FROM allgres_private.change_proposals
    WHERE task_id = v_tid AND (proposed_changes ? 'max_steps' OR proposed_changes->'llm_config' ? 'provider')
  );
  v := v || jsonb_build_array(jsonb_build_object('name', 'propose_change_rejects_disallowed_fields', 'ok', ok));

  -- 19d. fn_decide_proposal: reject leaves the policy untouched.
  comp := allgres_public.fn_decide_proposal(v_proposal, false, 'not now');
  ok := comp->>'status' = 'rejected';
  ok := ok AND (SELECT status FROM allgres_private.change_proposals WHERE proposal_id = v_proposal) = 'rejected';
  ok := ok AND (SELECT system_prompt FROM allgres_private.policies WHERE agent_id = v_agent) = v_prompt_before;
  v := v || jsonb_build_array(jsonb_build_object('name', 'decide_proposal_reject_leaves_policy_untouched', 'ok', ok));

  -- 19e. Approve applies the change through fn_set_policy -- the same
  --      versioning path an operator's own edit takes, so a promoted
  --      proposal shows up in policy_history exactly like one would.
  v_sid := (allgres_public.fn_create_session(v_agent, 'selftest propose_change_approve')->>'session_id')::uuid;
  SELECT task_id INTO v_tid2 FROM allgres_private.tasks WHERE session_id = v_sid LIMIT 1;
  PERFORM allgres_public.fn_next_step(v_tid2);
  sub := allgres_public.fn_submit_result(v_tid2, jsonb_build_object(
    'type', 'llm_response',
    'content', '{"action":"propose_change"}',
    'parsed', jsonb_build_object('action', 'propose_change', 'changes', jsonb_build_object('system_prompt', 'Be terser.'))
  ));
  v_proposal := (sub->>'proposal_id')::uuid;
  comp := allgres_public.fn_decide_proposal(v_proposal, true, 'looks fine');
  ok := comp->>'status' = 'approved';
  ok := ok AND (SELECT system_prompt FROM allgres_private.policies WHERE agent_id = v_agent) = 'Be terser.';
  ok := ok AND (SELECT generation FROM allgres_private.policies WHERE agent_id = v_agent) = v_gen + 1;
  ok := ok AND EXISTS (
    SELECT 1 FROM allgres_private.policy_history
    WHERE agent_id = v_agent AND generation = v_gen AND system_prompt = v_prompt_before
  );
  ok := ok AND (SELECT status FROM allgres_private.change_proposals WHERE proposal_id = v_proposal) = 'approved';
  v := v || jsonb_build_array(jsonb_build_object('name', 'decide_proposal_approve_versions_and_applies', 'ok', ok));

  -- 19f. Staleness: the live policy moved on since this proposal was made
  --      (an operator edit, simulated here) -- approving must not blindly
  --      clobber whatever changed it.
  v_sid := (allgres_public.fn_create_session(v_agent, 'selftest propose_change_stale')->>'session_id')::uuid;
  SELECT task_id INTO v_tid2 FROM allgres_private.tasks WHERE session_id = v_sid LIMIT 1;
  PERFORM allgres_public.fn_next_step(v_tid2);
  sub := allgres_public.fn_submit_result(v_tid2, jsonb_build_object(
    'type', 'llm_response',
    'content', '{"action":"propose_change"}',
    'parsed', jsonb_build_object('action', 'propose_change', 'changes', jsonb_build_object('system_prompt', 'stale attempt'))
  ));
  v_proposal := (sub->>'proposal_id')::uuid;
  PERFORM allgres_public.fn_set_policy(v_agent, 'operator changed it meanwhile');
  comp := allgres_public.fn_decide_proposal(v_proposal, true);
  ok := comp->>'status' = 'stale';
  ok := ok AND (SELECT status FROM allgres_private.change_proposals WHERE proposal_id = v_proposal) = 'stale';
  ok := ok AND (SELECT system_prompt FROM allgres_private.policies WHERE agent_id = v_agent) = 'operator changed it meanwhile';
  v := v || jsonb_build_array(jsonb_build_object('name', 'decide_proposal_detects_stale_base', 'ok', ok));

  -- 19g. fn_rollback_policy restores a prior version through the same
  --      fn_set_policy path -- itself versioned, never a mutation of
  --      policy_history.
  SELECT generation INTO v_gen FROM allgres_private.policies WHERE agent_id = v_agent;
  comp := allgres_public.fn_rollback_policy(v_agent, v_gen - 2);
  ok := COALESCE((comp->>'changed')::boolean, false);
  ok := ok AND (SELECT system_prompt FROM allgres_private.policies WHERE agent_id = v_agent) = v_prompt_before;
  ok := ok AND (SELECT generation FROM allgres_private.policies WHERE agent_id = v_agent) = v_gen + 1;
  v := v || jsonb_build_array(jsonb_build_object('name', 'rollback_policy_restores_prior_version', 'ok', ok));

  -- 20. max_concurrent_tasks holds a task back from fn_dispatch_tasks once
  --     the agent's cap is already occupied by another running task, rather
  --     than dispatching it anyway.
  UPDATE allgres_private.policies SET max_concurrent_tasks = 1 WHERE agent_id = v_agent;
  v_sid := (allgres_public.fn_create_session(v_agent, 'selftest concurrency_a')->>'session_id')::uuid;
  SELECT task_id INTO v_tid FROM allgres_private.tasks WHERE session_id = v_sid LIMIT 1;
  UPDATE allgres_private.tasks SET status = 'running', updated_at = now() WHERE task_id = v_tid;
  v_sid := (allgres_public.fn_create_session(v_agent, 'selftest concurrency_b')->>'session_id')::uuid;
  SELECT task_id INTO v_tid2 FROM allgres_private.tasks WHERE session_id = v_sid LIMIT 1;
  PERFORM allgres_public.fn_dispatch_tasks();
  SELECT status INTO detail FROM allgres_private.tasks WHERE task_id = v_tid2;
  ok := detail = 'queued';
  v := v || jsonb_build_array(jsonb_build_object('name', 'max_concurrent_tasks_holds_back_dispatch', 'ok', ok));
  UPDATE allgres_private.policies SET max_concurrent_tasks = 4 WHERE agent_id = v_agent;
  UPDATE allgres_private.tasks SET status = 'cancelled' WHERE task_id IN (v_tid, v_tid2);

  -- 21. max_turn_seconds is a wall-clock ceiling on a task's whole lifetime
  --     once it has actually started; fn_watchdog reclaims one that has been
  --     running longer than its agent's cap, straight to failed, no retry --
  --     the same terminal shape as max_steps. fn_next_step (called here to
  --     simulate a real turn) is what sets started_at, so this backdates
  --     that instead of created_at.
  UPDATE allgres_private.policies SET max_turn_seconds = 60 WHERE agent_id = v_agent;
  v_sid := (allgres_public.fn_create_session(v_agent, 'selftest turn_timeout')->>'session_id')::uuid;
  SELECT task_id INTO v_tid FROM allgres_private.tasks WHERE session_id = v_sid LIMIT 1;
  PERFORM allgres_public.fn_next_step(v_tid);
  UPDATE allgres_private.tasks SET started_at = now() - interval '2 minutes' WHERE task_id = v_tid;
  PERFORM allgres_public.fn_watchdog();
  SELECT status INTO detail FROM allgres_private.tasks WHERE task_id = v_tid;
  ok := detail = 'failed';
  SELECT count(*) INTO n_logs
  FROM allgres_private.execution_logs
  WHERE task_id = v_tid AND role = 'error' AND content->>'reason' = 'turn_timeout';
  ok := ok AND n_logs = 1;
  v := v || jsonb_build_array(jsonb_build_object('name', 'max_turn_seconds_expires_stale_task', 'ok', ok));

  -- Roadmap item 5: max_turn_seconds reaches a task genuinely stuck in
  -- 'waiting_children' the same way it reaches 'running'/'waiting_human' --
  -- without this, a child that never finishes would let its parent wait
  -- forever with no wall-clock bound at all.
  v_sid := (allgres_public.fn_create_session(v_agent, 'selftest waiting_children_turn_timeout')->>'session_id')::uuid;
  SELECT task_id INTO v_tid FROM allgres_private.tasks WHERE session_id = v_sid LIMIT 1;
  PERFORM allgres_public.fn_next_step(v_tid);
  UPDATE allgres_private.tasks
  SET status = 'waiting_children', started_at = now() - interval '2 minutes'
  WHERE task_id = v_tid;
  PERFORM allgres_public.fn_watchdog();
  ok := (SELECT status FROM allgres_private.tasks WHERE task_id = v_tid) = 'failed';
  v := v || jsonb_build_array(jsonb_build_object('name', 'max_turn_seconds_reaches_a_task_waiting_on_children', 'ok', ok));

  -- 22. A task still 'queued' -- e.g. held back by max_concurrent_tasks --
  --     has never run a turn, so started_at is still NULL for it and
  --     max_turn_seconds must leave it alone no matter how old created_at
  --     is. Without this a busy agent's own concurrency cap could starve a
  --     task long enough for max_turn_seconds to kill it before its first
  --     turn -- exactly the bug this loop's started_at rewrite closes.
  v_sid := (allgres_public.fn_create_session(v_agent, 'selftest turn_timeout_queued')->>'session_id')::uuid;
  SELECT task_id INTO v_tid FROM allgres_private.tasks WHERE session_id = v_sid LIMIT 1;
  UPDATE allgres_private.tasks SET created_at = now() - interval '2 minutes' WHERE task_id = v_tid;
  PERFORM allgres_public.fn_watchdog();
  SELECT status, started_at INTO detail, v_expires FROM allgres_private.tasks WHERE task_id = v_tid;
  ok := detail = 'queued' AND v_expires IS NULL;
  v := v || jsonb_build_array(jsonb_build_object('name', 'max_turn_seconds_spares_queued_task', 'ok', ok));
  PERFORM allgres_public.fn_set_policy(v_agent, NULL, NULL, NULL, NULL, NULL, NULL, true);

  -- 23. fn_provision_agent_role is idempotent (a second call for an
  --     already-provisioned agent returns the same role, no duplicate
  --     CREATE ROLE) and rejects an unknown agent. Reuses one fixed test
  --     agent across repeated fn_selftest calls, rather than creating a
  --     fresh one every time: fn_selftest is meant to be callable
  --     repeatedly (a health check), and a per-agent PostgreSQL role is a
  --     real cluster-wide object this should not quietly accumulate one of
  --     forever. Actually assuming the role and proving cross-agent
  --     isolation live is in tests/smoke.sql, not here, for the same
  --     reason the sandbox-role check is: fn_selftest is itself
  --     SECURITY DEFINER and cannot SET ROLE.
  SELECT agent_id INTO v_prov_agent
  FROM allgres_private.agents WHERE name = 'selftest_provision_agent';
  IF NOT FOUND THEN
    v_prov_agent := (allgres_public.fn_create_agent('selftest_provision_agent')->>'agent_id')::uuid;
  END IF;
  SELECT pg_role INTO v_role1 FROM allgres_private.agents WHERE agent_id = v_prov_agent;
  v_role2 := allgres_private.fn_provision_agent_role(v_prov_agent);
  ok := v_role1 IS NOT NULL AND v_role1 = v_role2 AND v_role1 LIKE 'allgres\_agent\_%';
  v := v || jsonb_build_array(jsonb_build_object('name', 'provision_agent_role_is_idempotent', 'ok', ok));

  BEGIN
    PERFORM allgres_private.fn_provision_agent_role(gen_random_uuid());
    ok := false;
  EXCEPTION WHEN others THEN
    ok := true;
  END;
  v := v || jsonb_build_array(jsonb_build_object('name', 'provision_agent_role_rejects_unknown_agent', 'ok', ok));

  -- 24. delegate's three independent resource bounds -- an external review
  --     pointed out delegate had none of its own before this: with mutual
  --     delegate permissions granted (a legitimate, operator-granted
  --     setup), nothing stopped an unbounded A -> B -> A -> B -> ... chain,
  --     since each child task got a fresh max_steps/max_retries/
  --     max_turn_seconds budget under max_concurrent_tasks alone -- none of
  --     which bounded the chain as a whole. Two fixed, reused test agents
  --     (same repeatable-fn_selftest reasoning as selftest_provision_agent
  --     above), granted delegate permission to each other so the guards
  --     under test are the only thing stopping a cycle, not a missing
  --     permission. 24a/24c build their ancestor chain directly via
  --     UPDATE/INSERT rather than by driving delegate hop by hop, since
  --     only the enforcement at the final hop is under test.
  SELECT agent_id INTO v_deleg_a FROM allgres_private.agents WHERE name = 'selftest_delegate_a';
  IF NOT FOUND THEN
    v_deleg_a := (allgres_public.fn_create_agent('selftest_delegate_a')->>'agent_id')::uuid;
  END IF;
  SELECT agent_id INTO v_deleg_b FROM allgres_private.agents WHERE name = 'selftest_delegate_b';
  IF NOT FOUND THEN
    v_deleg_b := (allgres_public.fn_create_agent('selftest_delegate_b')->>'agent_id')::uuid;
  END IF;
  PERFORM allgres_public.fn_grant_permission(v_deleg_a, 'agent', 'selftest_delegate_b');
  PERFORM allgres_public.fn_grant_permission(v_deleg_b, 'agent', 'selftest_delegate_a');

  -- 24a. a chain already at max_delegation_depth may not delegate one hop
  --      further, even with a permitted target and room in every other budget.
  UPDATE allgres_private.policies SET max_delegation_depth = 2 WHERE agent_id = v_deleg_a;
  v_sid := (allgres_public.fn_create_session(v_deleg_a, 'selftest delegate_depth')->>'session_id')::uuid;
  SELECT task_id INTO v_tid FROM allgres_private.tasks WHERE session_id = v_sid LIMIT 1;
  UPDATE allgres_private.tasks SET delegation_depth = 2 WHERE task_id = v_tid;
  PERFORM allgres_public.fn_next_step(v_tid);
  sub := allgres_public.fn_submit_result(v_tid, jsonb_build_object(
    'type', 'llm_response', 'content', '{"action":"delegate"}',
    'parsed', jsonb_build_object('action', 'delegate', 'agent_name', 'selftest_delegate_b')
  ));
  SELECT count(*) INTO n_logs FROM allgres_private.execution_logs
    WHERE task_id = v_tid AND role = 'error' AND content->>'reason' = 'delegate_depth_exceeded';
  ok := n_logs = 1;
  v := v || jsonb_build_array(jsonb_build_object('name', 'delegate_depth_exceeded_rejected', 'ok', ok));
  UPDATE allgres_private.policies SET max_delegation_depth = 5 WHERE agent_id = v_deleg_a;

  -- 24b. delegating back to an agent already in this task's own ancestor
  --      chain is rejected regardless of depth headroom -- a long chain
  --      that keeps revisiting the same two agents would otherwise pass
  --      24a's check forever.
  v_sid := (allgres_public.fn_create_session(v_deleg_a, 'selftest delegate_cycle')->>'session_id')::uuid;
  SELECT task_id INTO v_tid FROM allgres_private.tasks WHERE session_id = v_sid LIMIT 1;
  INSERT INTO allgres_private.tasks (session_id, agent_id, parent_task_id, status, delegation_depth)
  VALUES (v_sid, v_deleg_b, v_tid, 'running', 1)
  RETURNING task_id INTO v_tid2;
  PERFORM allgres_public.fn_next_step(v_tid2);
  sub := allgres_public.fn_submit_result(v_tid2, jsonb_build_object(
    'type', 'llm_response', 'content', '{"action":"delegate"}',
    'parsed', jsonb_build_object('action', 'delegate', 'agent_name', 'selftest_delegate_a')
  ));
  SELECT count(*) INTO n_logs FROM allgres_private.execution_logs
    WHERE task_id = v_tid2 AND role = 'error' AND content->>'reason' = 'delegate_cycle';
  ok := n_logs = 1;
  v := v || jsonb_build_array(jsonb_build_object('name', 'delegate_cycle_rejected', 'ok', ok));

  -- 24c. independent of depth or cycle shape, max_session_tasks bounds a
  --      session's total task count outright -- the guard a long,
  --      never-repeating chain (A -> B -> C -> D -> ...) cannot evade.
  UPDATE allgres_private.policies SET max_session_tasks = 1 WHERE agent_id = v_deleg_a;
  v_sid := (allgres_public.fn_create_session(v_deleg_a, 'selftest delegate_session_cap')->>'session_id')::uuid;
  SELECT task_id INTO v_tid FROM allgres_private.tasks WHERE session_id = v_sid LIMIT 1;
  PERFORM allgres_public.fn_next_step(v_tid);
  sub := allgres_public.fn_submit_result(v_tid, jsonb_build_object(
    'type', 'llm_response', 'content', '{"action":"delegate"}',
    'parsed', jsonb_build_object('action', 'delegate', 'agent_name', 'selftest_delegate_b')
  ));
  SELECT count(*) INTO n_logs FROM allgres_private.execution_logs
    WHERE task_id = v_tid AND role = 'error' AND content->>'reason' = 'delegate_session_task_limit';
  ok := n_logs = 1;
  v := v || jsonb_build_array(jsonb_build_object('name', 'delegate_session_task_limit_rejected', 'ok', ok));
  UPDATE allgres_private.policies SET max_session_tasks = 100 WHERE agent_id = v_deleg_a;

  -- 24d. none of the above are so tight a legitimate delegate within every
  --      budget cannot go through, and the child's delegation_depth is set
  --      correctly (parent + 1) so a later hop's own depth check has the
  --      right number to compare against.
  v_sid := (allgres_public.fn_create_session(v_deleg_a, 'selftest delegate_ok')->>'session_id')::uuid;
  SELECT task_id INTO v_tid FROM allgres_private.tasks WHERE session_id = v_sid LIMIT 1;
  PERFORM allgres_public.fn_next_step(v_tid);
  sub := allgres_public.fn_submit_result(v_tid, jsonb_build_object(
    'type', 'llm_response', 'content', '{"action":"delegate"}',
    'parsed', jsonb_build_object('action', 'delegate', 'agent_name', 'selftest_delegate_b')
  ));
  v_tid2 := NULLIF(sub->>'child_task_id', '')::uuid;
  ok := v_tid2 IS NOT NULL;
  ok := ok AND (SELECT agent_id FROM allgres_private.tasks WHERE task_id = v_tid2) = v_deleg_b;
  ok := ok AND (SELECT delegation_depth FROM allgres_private.tasks WHERE task_id = v_tid2) = 1;
  v := v || jsonb_build_array(jsonb_build_object('name', 'delegate_succeeds_within_budget', 'ok', ok));

  -- Roadmap item 5: delegate's "wait" opt-in and await_children -- a real,
  -- Postgres-resident multi-agent task dependency edge. Default delegate
  -- (tested just above) is completely unchanged; this is the new path.
  v_sid := (allgres_public.fn_create_session(v_deleg_a, 'selftest await_children_reject')->>'session_id')::uuid;
  SELECT task_id INTO v_tid FROM allgres_private.tasks WHERE session_id = v_sid LIMIT 1;
  PERFORM allgres_public.fn_next_step(v_tid);
  sub := allgres_public.fn_submit_result(v_tid, jsonb_build_object(
    'type', 'llm_response', 'content', '{}',
    'parsed', jsonb_build_object('action', 'await_children')
  ));
  ok := (sub->>'action') = 'continue'
    AND (SELECT status FROM allgres_private.tasks WHERE task_id = v_tid) = 'running';
  SELECT content INTO r FROM allgres_private.execution_logs WHERE task_id = v_tid AND role = 'error' ORDER BY step_number DESC LIMIT 1;
  ok := ok AND (r->>'reason') = 'no_pending_children_to_await';
  v := v || jsonb_build_array(jsonb_build_object('name', 'await_children_rejects_with_no_pending_children', 'ok', ok));

  v_sid := (allgres_public.fn_create_session(v_deleg_a, 'selftest delegate_wait_fan_out')->>'session_id')::uuid;
  SELECT task_id INTO v_tid FROM allgres_private.tasks WHERE session_id = v_sid LIMIT 1;
  PERFORM allgres_public.fn_next_step(v_tid);
  sub := allgres_public.fn_submit_result(v_tid, jsonb_build_object(
    'type', 'llm_response', 'content', '{}',
    'parsed', jsonb_build_object('action', 'delegate', 'agent_name', 'selftest_delegate_b', 'wait', true)
  ));
  v_tid2 := NULLIF(sub->>'child_task_id', '')::uuid;
  ok := v_tid2 IS NOT NULL
    AND (SELECT status FROM allgres_private.tasks WHERE task_id = v_tid) = 'running';
  v := v || jsonb_build_array(jsonb_build_object('name', 'delegate_wait_true_keeps_parent_running_not_completed', 'ok', ok));

  UPDATE allgres_private.tasks SET status = 'running' WHERE task_id = v_tid;
  sub := allgres_public.fn_submit_result(v_tid, jsonb_build_object(
    'type', 'llm_response', 'content', '{}',
    'parsed', jsonb_build_object('action', 'await_children')
  ));
  ok := (sub->>'action') = 'wait'
    AND (SELECT status FROM allgres_private.tasks WHERE task_id = v_tid) = 'waiting_children';
  v := v || jsonb_build_array(jsonb_build_object('name', 'await_children_pauses_the_task', 'ok', ok));

  -- A session must not look "done" while one of its tasks is genuinely
  -- still waiting on its own children -- maybe_complete_session's own
  -- open-task check.
  ok := (SELECT status FROM allgres_private.sessions WHERE session_id = v_sid) = 'open';
  v := v || jsonb_build_array(jsonb_build_object('name', 'session_stays_open_while_a_task_awaits_children', 'ok', ok));

  PERFORM allgres_public.fn_watchdog();
  ok := (SELECT status FROM allgres_private.tasks WHERE task_id = v_tid) = 'waiting_children';
  v := v || jsonb_build_array(jsonb_build_object('name', 'watchdog_does_not_wake_while_child_still_open', 'ok', ok));

  PERFORM allgres_public.fn_next_step(v_tid2);
  PERFORM allgres_public.fn_submit_result(v_tid2, jsonb_build_object(
    'type', 'llm_response', 'content', '{}',
    'parsed', jsonb_build_object('action', 'final_answer', 'answer', 'selftest child result marker')
  ));
  PERFORM allgres_public.fn_watchdog();
  ok := (SELECT status FROM allgres_private.tasks WHERE task_id = v_tid) = 'queued';
  SELECT content INTO r FROM allgres_private.execution_logs WHERE task_id = v_tid ORDER BY step_number DESC LIMIT 1;
  ok := ok AND (r->'delegate_results')::text LIKE '%selftest child result marker%'
    AND (r->'delegate_results'->0->>'agent') = 'selftest_delegate_b'
    AND (r->'delegate_results'->0->>'status') = 'completed';
  v := v || jsonb_build_array(jsonb_build_object('name', 'watchdog_wakes_parent_once_child_completes_with_results', 'ok', ok));

  -- fn_cancel_session must reach a task genuinely stuck in
  -- 'waiting_children' too, not just queued/running/waiting_human.
  v_sid := (allgres_public.fn_create_session(v_deleg_a, 'selftest cancel_while_awaiting_children')->>'session_id')::uuid;
  SELECT task_id INTO v_tid FROM allgres_private.tasks WHERE session_id = v_sid LIMIT 1;
  PERFORM allgres_public.fn_next_step(v_tid);
  PERFORM allgres_public.fn_submit_result(v_tid, jsonb_build_object(
    'type', 'llm_response', 'content', '{}',
    'parsed', jsonb_build_object('action', 'delegate', 'agent_name', 'selftest_delegate_b', 'wait', true)
  ));
  UPDATE allgres_private.tasks SET status = 'running' WHERE task_id = v_tid;
  PERFORM allgres_public.fn_submit_result(v_tid, jsonb_build_object(
    'type', 'llm_response', 'content', '{}',
    'parsed', jsonb_build_object('action', 'await_children')
  ));
  ok := (SELECT status FROM allgres_private.tasks WHERE task_id = v_tid) = 'waiting_children';
  PERFORM allgres_public.fn_cancel_session(v_sid, 'selftest cancel test');
  ok := ok AND (SELECT status FROM allgres_private.tasks WHERE task_id = v_tid) = 'cancelled';
  v := v || jsonb_build_array(jsonb_build_object('name', 'cancel_session_cancels_a_task_waiting_on_children', 'ok', ok));

  -- Roadmap item 6: schedules -- see allgres_private.schedules' own
  -- comment. Exercises the exact function fn_pump calls (fn_run_schedules),
  -- not a substitute.
  DELETE FROM allgres_private.schedules WHERE name = 'selftest_schedule';
  r := allgres_public.fn_create_schedule(
    'selftest_schedule', v_agent, 'selftest schedule goal', 3600, NULL, NULL, now() - interval '1 minute'
  );
  ok := (r->>'ok')::boolean;
  v_call := (r->>'schedule_id')::uuid;
  v := v || jsonb_build_array(jsonb_build_object('name', 'fn_create_schedule_starts_due', 'ok', ok));

  sub := allgres_public.fn_run_schedules();
  ok := COALESCE((sub->>'fired')::int, 0) >= 1
    AND (SELECT run_count FROM allgres_private.schedules WHERE schedule_id = v_call) = 1
    AND (SELECT last_session_id FROM allgres_private.schedules WHERE schedule_id = v_call) IS NOT NULL
    AND (SELECT next_run_at FROM allgres_private.schedules WHERE schedule_id = v_call) > now();
  ok := ok AND EXISTS (
    SELECT 1 FROM allgres_private.sessions
    WHERE session_id = (SELECT last_session_id FROM allgres_private.schedules WHERE schedule_id = v_call)
      AND goal = 'selftest schedule goal'
  );
  v := v || jsonb_build_array(jsonb_build_object('name', 'fn_run_schedules_fires_a_due_schedule_and_creates_a_session', 'ok', ok));

  PERFORM allgres_public.fn_run_schedules();
  ok := (SELECT run_count FROM allgres_private.schedules WHERE schedule_id = v_call) = 1;
  v := v || jsonb_build_array(jsonb_build_object('name', 'fn_run_schedules_does_not_fire_before_next_run_at', 'ok', ok));

  r := allgres_public.fn_run_schedule_now(v_call);
  ok := (r->>'ok')::boolean
    AND (SELECT run_count FROM allgres_private.schedules WHERE schedule_id = v_call) = 2;
  v := v || jsonb_build_array(jsonb_build_object('name', 'fn_run_schedule_now_bypasses_next_run_at', 'ok', ok));

  -- max_runs reached mid-flight (an operator lowering it, or simply
  -- accumulating runs) is honoured the next time the schedule would
  -- actually fire, not only at create/set time -- deactivated, not fired
  -- one run past the budget.
  UPDATE allgres_private.schedules SET max_runs = 2, next_run_at = now() - interval '1 minute' WHERE schedule_id = v_call;
  sub := allgres_public.fn_run_schedules();
  ok := COALESCE((sub->>'fired')::int, 0) = 0
    AND (SELECT run_count FROM allgres_private.schedules WHERE schedule_id = v_call) = 2
    AND (SELECT is_active FROM allgres_private.schedules WHERE schedule_id = v_call) IS FALSE;
  v := v || jsonb_build_array(jsonb_build_object('name', 'schedule_deactivates_on_reaching_max_runs', 'ok', ok));

  BEGIN
    PERFORM allgres_public.fn_run_schedule_now(v_call);
    ok := false;
  EXCEPTION WHEN others THEN
    ok := true;
  END;
  v := v || jsonb_build_array(jsonb_build_object('name', 'fn_run_schedule_now_rejects_an_inactive_schedule', 'ok', ok));

  -- ends_at is an independent stop condition, same auto-deactivate.
  UPDATE allgres_private.schedules
  SET is_active = true, max_runs = NULL, ends_at = now() - interval '1 minute',
      next_run_at = now() - interval '1 minute'
  WHERE schedule_id = v_call;
  sub := allgres_public.fn_run_schedules();
  ok := COALESCE((sub->>'fired')::int, 0) = 0
    AND (SELECT is_active FROM allgres_private.schedules WHERE schedule_id = v_call) IS FALSE;
  v := v || jsonb_build_array(jsonb_build_object('name', 'schedule_deactivates_on_reaching_ends_at', 'ok', ok));

  -- A paused (is_active=false) schedule never fires, no matter how overdue.
  UPDATE allgres_private.schedules
  SET is_active = false, ends_at = NULL, next_run_at = now() - interval '1 minute'
  WHERE schedule_id = v_call;
  sub := allgres_public.fn_run_schedules();
  ok := COALESCE((sub->>'fired')::int, 0) = 0
    AND (SELECT run_count FROM allgres_private.schedules WHERE schedule_id = v_call) = 2;
  v := v || jsonb_build_array(jsonb_build_object('name', 'inactive_schedule_never_fires', 'ok', ok));

  DELETE FROM allgres_private.schedules WHERE schedule_id = v_call;

  -- 25. build_llm_http fails closed on an unconfigured/disabled provider
  --     instead of silently substituting whichever other enabled provider
  --     sorted first by name -- an external review caught the old
  --     fallback: a real privacy/security bug, since it could quietly
  --     reroute a prompt to a completely different provider than the one
  --     actually configured, with no error and no log entry distinguishing
  --     the two.
  BEGIN
    PERFORM allgres_private.build_llm_http(jsonb_build_object(
      'llm_config', jsonb_build_object('provider', 'selftest_nonexistent_provider')
    ));
    ok := false;
  EXCEPTION WHEN others THEN
    ok := SQLERRM LIKE '%selftest_nonexistent_provider%is not configured or not enabled%';
  END;
  v := v || jsonb_build_array(jsonb_build_object('name', 'llm_provider_fails_closed_not_substituted', 'ok', ok));

  -- 25b. An agent with no llm_config at all (a fresh agent, before any
  --      operator has configured a model) must fail the same way -- this
  --      used to silently resolve to the seeded xai/grok-4.5 provider/model,
  --      which made every unconfigured agent look already set up.
  BEGIN
    PERFORM allgres_private.build_llm_http(jsonb_build_object('llm_config', '{}'::jsonb));
    ok := false;
  EXCEPTION WHEN others THEN
    ok := SQLERRM LIKE '%no llm_config.provider configured%';
  END;
  v := v || jsonb_build_array(jsonb_build_object('name', 'llm_provider_required_not_defaulted', 'ok', ok));

  -- 25c. New agents must start with an empty llm_config, not a hardcoded
  --      provider/model -- ensure_policy used to default every new agent's
  --      policy to xai/grok-4.5 regardless of what the operator asked for.
  INSERT INTO allgres_private.agents (name) VALUES ('selftest_new_agent_' || extract(epoch from clock_timestamp())::text)
  RETURNING agent_id INTO v_new_agent;
  ok := (SELECT llm_config FROM allgres_private.policies WHERE agent_id = v_new_agent) = '{}'::jsonb;
  DELETE FROM allgres_private.agents WHERE agent_id = v_new_agent;
  v := v || jsonb_build_array(jsonb_build_object('name', 'new_agent_llm_config_starts_empty', 'ok', ok));

  -- 25d. fn_create_provider: an operator can add a brand new provider (not
  --      just edit one of the fixed seeded ones), with a working api_key set
  --      in the same call, and it fails closed on a bad kind/URL just like
  --      fn_set_provider does on edit.
  DELETE FROM allgres_private.llm_providers WHERE name = 'selftest_new_provider';
  r := allgres_public.fn_create_provider('selftest_new_provider', 'openai_compat',
    'https://selftest.invalid/v1', 'selftest-new-provider-key', false);
  ok := (r->>'ok')::boolean AND (r->>'provider_id') IS NOT NULL;
  ok := ok AND EXISTS (
    SELECT 1 FROM allgres_private.llm_providers WHERE name = 'selftest_new_provider' AND is_enabled
  );
  ok := ok AND allgres_private.provider_secret((r->>'provider_id')::uuid) = 'selftest-new-provider-key';
  v := v || jsonb_build_array(jsonb_build_object('name', 'fn_create_provider_adds_working_provider', 'ok', ok));

  BEGIN
    PERFORM allgres_public.fn_create_provider('selftest_bad_kind', 'not_a_real_kind', 'https://selftest.invalid/v1');
    ok := false;
  EXCEPTION WHEN others THEN
    ok := true;
  END;
  v := v || jsonb_build_array(jsonb_build_object('name', 'fn_create_provider_rejects_bad_kind', 'ok', ok));

  BEGIN
    PERFORM allgres_public.fn_create_provider('selftest_ssrf_provider', 'openai_compat', 'http://169.254.169.254/latest');
    ok := false;
  EXCEPTION WHEN others THEN
    ok := true;
  END;
  v := v || jsonb_build_array(jsonb_build_object('name', 'fn_create_provider_rejects_ssrf_url', 'ok', ok));

  -- 25e. response_format_json_object (item 37's own fix): a per-provider
  -- flag replacing what used to be a single `v_prov.name <> 'ollama'` check
  -- inside build_llm_http -- confirmed live against a real LM Studio
  -- instance, which rejects response_format outright (HTTP 400) the same
  -- way Ollama's own openai_compat endpoint always has, under a name
  -- nothing in that old check ever recognized. Default true (unchanged
  -- behavior for selftest_new_provider above and every other existing
  -- provider); an operator can turn it off per provider, exercised here by
  -- checking build_llm_http's actual request body, not just the stored
  -- column.
  r := allgres_public.fn_create_provider('selftest_no_json_mode', 'openai_compat',
    'https://selftest.invalid/v1', NULL, false, 'chat', NULL, false);
  ok := (r->>'ok')::boolean;
  spec := allgres_private.build_llm_http(jsonb_build_object(
    'llm_config', jsonb_build_object('provider', 'selftest_no_json_mode', 'model', 'x'),
    'messages', '[]'::jsonb
  ));
  ok := ok AND NOT (spec->'body' ? 'response_format');
  v := v || jsonb_build_array(jsonb_build_object('name', 'response_format_json_object_false_omits_it', 'ok', ok));

  spec := allgres_private.build_llm_http(jsonb_build_object(
    'llm_config', jsonb_build_object('provider', 'selftest_new_provider', 'model', 'x'),
    'messages', '[]'::jsonb
  ));
  ok := (spec->'body'->'response_format'->>'type') = 'json_object';
  v := v || jsonb_build_array(jsonb_build_object('name', 'response_format_json_object_true_by_default', 'ok', ok));

  -- The migration's own retroactive fix, not just the new column's default:
  -- the seeded 'ollama' row must still come out false after this file's own
  -- ALTER TABLE/UPDATE runs, exactly matching what the old name check used
  -- to give it.
  ok := (SELECT response_format_json_object FROM allgres_private.llm_providers WHERE name = 'ollama') IS FALSE;
  v := v || jsonb_build_array(jsonb_build_object('name', 'seeded_ollama_provider_still_omits_response_format', 'ok', ok));

  -- 25f. fn_complete_outbound's own auto-detect for the same rejection,
  -- so an operator never has to notice the HTTP 400 and flip the checkbox
  -- by hand -- a synthetic outbound_calls row stands in for one
  -- fn_dispatch_tasks would have queued, same technique as
  -- complete_outbound_fences_stale_result above.
  r := allgres_public.fn_create_provider('selftest_autodetect_provider', 'openai_compat',
    'https://selftest.invalid/v1');
  v_provider := (r->>'provider_id')::uuid;
  v_sid := (allgres_public.fn_create_session(v_agent, 'selftest response_format autodetect')->>'session_id')::uuid;
  SELECT task_id INTO v_tid FROM allgres_private.tasks WHERE session_id = v_sid LIMIT 1;
  INSERT INTO allgres_private.outbound_calls (task_id, kind, url, status, provider_id)
  VALUES (v_tid, 'llm', 'https://selftest.invalid/v1/chat/completions', 'in_flight', v_provider)
  RETURNING call_id INTO v_call;
  PERFORM allgres_public.fn_complete_outbound(v_call, 400,
    '{"error":"''response_format.type'' must be ''json_schema'' or ''text''"}');
  ok := (SELECT response_format_json_object FROM allgres_private.llm_providers WHERE provider_id = v_provider) IS FALSE;
  v := v || jsonb_build_array(jsonb_build_object('name', 'response_format_rejection_autodetected_and_disabled', 'ok', ok));

  -- A narrow signature match, not "any 400 turns it off" -- an unrelated
  -- failure (bad key, context length, ...) must never touch the column.
  r := allgres_public.fn_create_provider('selftest_autodetect_unrelated', 'openai_compat',
    'https://selftest.invalid/v1');
  v_provider := (r->>'provider_id')::uuid;
  INSERT INTO allgres_private.outbound_calls (task_id, kind, url, status, provider_id)
  VALUES (v_tid, 'llm', 'https://selftest.invalid/v1/chat/completions', 'in_flight', v_provider)
  RETURNING call_id INTO v_call;
  PERFORM allgres_public.fn_complete_outbound(v_call, 400, '{"error":"context length exceeded"}');
  ok := (SELECT response_format_json_object FROM allgres_private.llm_providers WHERE provider_id = v_provider);
  v := v || jsonb_build_array(jsonb_build_object('name', 'unrelated_400_does_not_disable_response_format', 'ok', ok));

  DELETE FROM allgres_private.outbound_calls WHERE provider_id IN (
    SELECT provider_id FROM allgres_private.llm_providers
    WHERE name IN ('selftest_no_json_mode', 'selftest_autodetect_provider', 'selftest_autodetect_unrelated')
  );
  DELETE FROM allgres_private.llm_providers WHERE name IN
    ('selftest_no_json_mode', 'selftest_autodetect_provider', 'selftest_autodetect_unrelated');

  -- 25g0. The 'general' demo agent (item 39's own follow-up): seeded
  -- active, no llm_config picked for it yet (same reason as 'analyst'),
  -- and no view/tool permissions -- a plain conversational partner, unlike
  -- 'analyst', which is deliberately a data-query one. Checked here, before
  -- fn_bulk_set_model below runs against every active agent including this
  -- one -- that would otherwise give this its own llm_config and make the
  -- "still unconfigured" half of this assertion fail on nothing but test
  -- ordering.
  ok := EXISTS (
    SELECT 1 FROM allgres_private.agents a JOIN allgres_private.policies p USING (agent_id)
    WHERE a.name = 'general' AND a.is_active AND p.llm_config = '{}'::jsonb
  );
  ok := ok AND NOT EXISTS (
    SELECT 1 FROM allgres_private.permissions
    WHERE agent_id = (SELECT agent_id FROM allgres_private.agents WHERE name = 'general')
  );
  v := v || jsonb_build_array(jsonb_build_object('name', 'general_agent_seeded_plain_and_unconfigured', 'ok', ok));

  -- 25g. fn_bulk_set_model: one call sets llm_config.provider/model on
  -- every active agent, reusing fn_set_policy's own merge (nothing else on
  -- any of those policies changes) rather than a hand-rolled UPDATE that
  -- would bypass policy_history/generation the way every other agent
  -- mutation in this file goes through.
  -- fn_bulk_set_model is deliberately "every active agent", so exercising
  -- it for real -- not against some carved-out subset -- means every real
  -- seeded agent's llm_config changes too. Snapshotted here and restored
  -- below before this function returns, the same idempotence-on-rerun
  -- requirement every other fixture in this file already meets (a second
  -- fn_selftest call on the same database must see the same starting
  -- state, not one already bulk-set from the first run).
  CREATE TEMP TABLE IF NOT EXISTS _selftest_bulk_snapshot (agent_id uuid PRIMARY KEY, llm_config jsonb);
  DELETE FROM _selftest_bulk_snapshot;
  INSERT INTO _selftest_bulk_snapshot
  SELECT agent_id, llm_config FROM allgres_private.policies
  WHERE agent_id IN (SELECT agent_id FROM allgres_private.agents WHERE is_active);

  DELETE FROM allgres_private.agents WHERE name IN ('selftest_bulk_agent_a', 'selftest_bulk_agent_b');
  INSERT INTO allgres_private.agents (name) VALUES ('selftest_bulk_agent_a'), ('selftest_bulk_agent_b');
  r := allgres_public.fn_create_provider('selftest_bulk_provider', 'openai_compat', 'https://selftest.invalid/v1');
  comp := allgres_public.fn_bulk_set_model('selftest_bulk_provider', 'selftest-model-x');
  ok := COALESCE((comp->>'ok')::boolean, false) AND COALESCE((comp->>'updated_count')::int, 0) >= 2;
  ok := ok AND NOT EXISTS (
    SELECT 1 FROM allgres_private.agents a JOIN allgres_private.policies p USING (agent_id)
    WHERE a.name IN ('selftest_bulk_agent_a', 'selftest_bulk_agent_b')
      AND (p.llm_config->>'provider' <> 'selftest_bulk_provider' OR p.llm_config->>'model' <> 'selftest-model-x')
  );
  v := v || jsonb_build_array(jsonb_build_object('name', 'fn_bulk_set_model_updates_every_active_agent', 'ok', ok));

  BEGIN
    PERFORM allgres_public.fn_bulk_set_model('selftest_nonexistent_provider_xyz', 'x');
    ok := false;
  EXCEPTION WHEN others THEN
    ok := SQLERRM LIKE '%is not configured or not enabled%';
  END;
  v := v || jsonb_build_array(jsonb_build_object('name', 'fn_bulk_set_model_rejects_unknown_provider', 'ok', ok));

  UPDATE allgres_private.policies p SET llm_config = s.llm_config
  FROM _selftest_bulk_snapshot s WHERE p.agent_id = s.agent_id;
  DROP TABLE _selftest_bulk_snapshot;

  DELETE FROM allgres_private.agents WHERE name IN ('selftest_bulk_agent_a', 'selftest_bulk_agent_b');
  DELETE FROM allgres_private.llm_providers WHERE name = 'selftest_bulk_provider';

  DELETE FROM allgres_private.llm_secrets WHERE provider_id IN (
    SELECT provider_id FROM allgres_private.llm_providers WHERE name = 'selftest_new_provider'
  );
  DELETE FROM allgres_private.llm_providers WHERE name = 'selftest_new_provider';

  -- Roadmap item 2: allgres_private.api_connections + the 'http_request'
  -- tool -- a named external endpoint with a stored credential, so an agent
  -- can make an authenticated call (not just http_get's bare GET) without
  -- ever seeing the secret itself. Same claim-time injection shape already
  -- proven above (25f) for an LLM provider's api_key.
  DELETE FROM allgres_private.outbound_calls WHERE connection_id IN (
    SELECT connection_id FROM allgres_private.api_connections WHERE name = 'selftest_conn'
  );
  DELETE FROM allgres_private.api_connections WHERE name = 'selftest_conn';
  r := allgres_public.fn_create_connection('selftest_conn', 'https://selftest.invalid/api',
    'authorization', 'selftest-conn-key', false);
  ok := (r->>'ok')::boolean;
  v_conn := (r->>'connection_id')::uuid;
  ok := ok AND allgres_private.connection_secret(v_conn) = 'selftest-conn-key';
  v := v || jsonb_build_array(jsonb_build_object('name', 'fn_create_connection_stores_working_secret', 'ok', ok));

  sub := allgres.dashboard_rpc(jsonb_build_object('action', 'connections.list'));
  ok := (sub->'connections')::text NOT LIKE '%selftest-conn-key%'
    AND (sub->'connections')::text LIKE '%selftest_conn%';
  v := v || jsonb_build_array(jsonb_build_object('name', 'connections_list_never_exposes_secret', 'ok', ok));

  -- A dedicated fixture agent, reused across reruns (like several agents
  -- above): once it makes a real call_tool turn it has real execution_logs,
  -- which the append-only trigger forbids ever deleting -- so this can only
  -- ever be reactivated, never recreated, on a later run.
  SELECT agent_id INTO v_new_agent FROM allgres_private.agents WHERE name = 'selftest_httpreq_agent';
  IF v_new_agent IS NULL THEN
    v_new_agent := (allgres_public.fn_create_agent('selftest_httpreq_agent')->>'agent_id')::uuid;
  END IF;
  UPDATE allgres_private.agents SET is_active = true WHERE agent_id = v_new_agent;
  PERFORM allgres_public.fn_grant_permission(v_new_agent, 'tool', 'http_request');
  PERFORM allgres_public.fn_grant_permission(v_new_agent, 'http_host', 'selftest.invalid');

  v_sid := (allgres_public.fn_create_session(v_new_agent, 'selftest http_request via connection')->>'session_id')::uuid;
  SELECT task_id INTO v_tid FROM allgres_private.tasks WHERE session_id = v_sid LIMIT 1;
  UPDATE allgres_private.tasks SET status = 'running' WHERE task_id = v_tid;

  comp := allgres_public.fn_submit_result(v_tid, jsonb_build_object(
    'type', 'llm_response', 'content', '{}', 'parsed', jsonb_build_object(
      'action', 'call_tool', 'tool', 'http_request',
      'args', jsonb_build_object('method', 'post', 'connection', 'selftest_conn', 'path', 'widgets',
        'body', jsonb_build_object('x', 1))
    )
  ));
  -- Looked up by the call_id call_tool itself returned, not "the newest
  -- row" -- every fn_submit_result call in this whole test block runs in
  -- the same transaction, so created_at ties across them and an ORDER BY
  -- created_at is not a reliable tiebreaker once more than one row exists.
  v_call := (comp->>'call_id')::uuid;
  SELECT to_jsonb(o) INTO r FROM allgres_private.outbound_calls o WHERE o.call_id = v_call;
  ok := (r->>'url') = 'https://selftest.invalid/api/widgets'
    AND (r->>'method') = 'POST'
    AND (r->>'auth_kind') = 'authorization'
    AND (r->>'connection_id') = v_conn::text
    AND (r->'request_body') = jsonb_build_object('x', 1);
  v := v || jsonb_build_array(jsonb_build_object('name', 'http_request_via_connection_resolves_relative_path', 'ok', ok));

  -- External call idempotency (an outside review's finding: a crash
  -- between an external effect landing and this extension recording that
  -- it did could otherwise leave a later retry as a genuine duplicate
  -- POST/PATCH/DELETE). A mutating call gets a deterministic
  -- 'idempotency-key' header, mirrored onto outbound_calls.idempotency_key.
  ok := (r->>'idempotency_key') IS NOT NULL
    AND (r->'request_headers'->>'idempotency-key') = (r->>'idempotency_key');
  v := v || jsonb_build_array(jsonb_build_object('name', 'http_request_mutating_call_gets_idempotency_key', 'ok', ok));

  -- The same task retrying the exact same method/url/body (the ordinary
  -- shape of an agent retry after an error) reproduces the identical key --
  -- derived from the request's own content, not from call_id, which is
  -- different on every queued row including a genuine retry.
  UPDATE allgres_private.tasks SET status = 'running' WHERE task_id = v_tid;
  comp := allgres_public.fn_submit_result(v_tid, jsonb_build_object(
    'type', 'llm_response', 'content', '{}', 'parsed', jsonb_build_object(
      'action', 'call_tool', 'tool', 'http_request',
      'args', jsonb_build_object('method', 'post', 'connection', 'selftest_conn', 'path', 'widgets',
        'body', jsonb_build_object('x', 1))
    )
  ));
  v_call2 := (comp->>'call_id')::uuid;
  ok := v_call2 <> v_call
    AND (SELECT idempotency_key FROM allgres_private.outbound_calls WHERE call_id = v_call2)
      = (SELECT idempotency_key FROM allgres_private.outbound_calls WHERE call_id = v_call);
  v := v || jsonb_build_array(jsonb_build_object('name', 'http_request_retry_of_same_call_reuses_idempotency_key', 'ok', ok));

  -- A materially different request (a changed body) must not collide with
  -- it -- this is content-derived isolation, not just a random per-call id.
  UPDATE allgres_private.tasks SET status = 'running' WHERE task_id = v_tid;
  comp := allgres_public.fn_submit_result(v_tid, jsonb_build_object(
    'type', 'llm_response', 'content', '{}', 'parsed', jsonb_build_object(
      'action', 'call_tool', 'tool', 'http_request',
      'args', jsonb_build_object('method', 'post', 'connection', 'selftest_conn', 'path', 'widgets',
        'body', jsonb_build_object('x', 2))
    )
  ));
  ok := (SELECT idempotency_key FROM allgres_private.outbound_calls WHERE call_id = (comp->>'call_id')::uuid)
      <> (SELECT idempotency_key FROM allgres_private.outbound_calls WHERE call_id = v_call);
  v := v || jsonb_build_array(jsonb_build_object('name', 'http_request_different_body_gets_different_idempotency_key', 'ok', ok));

  -- An agent that already sets its own idempotency-key header (a
  -- destination with its own contract for the value's shape) is respected,
  -- never silently overwritten.
  UPDATE allgres_private.tasks SET status = 'running' WHERE task_id = v_tid;
  comp := allgres_public.fn_submit_result(v_tid, jsonb_build_object(
    'type', 'llm_response', 'content', '{}', 'parsed', jsonb_build_object(
      'action', 'call_tool', 'tool', 'http_request',
      'args', jsonb_build_object('method', 'post', 'connection', 'selftest_conn', 'path', 'widgets',
        'headers', jsonb_build_object('Idempotency-Key', 'selftest-custom-key'),
        'body', jsonb_build_object('x', 3))
    )
  ));
  ok := (SELECT idempotency_key FROM allgres_private.outbound_calls WHERE call_id = (comp->>'call_id')::uuid) = 'selftest-custom-key';
  v := v || jsonb_build_array(jsonb_build_object('name', 'http_request_respects_agent_supplied_idempotency_key', 'ok', ok));

  -- A GET has no side effect to protect -- it never gets one at all.
  UPDATE allgres_private.tasks SET status = 'running' WHERE task_id = v_tid;
  comp := allgres_public.fn_submit_result(v_tid, jsonb_build_object(
    'type', 'llm_response', 'content', '{}', 'parsed', jsonb_build_object(
      'action', 'call_tool', 'tool', 'http_request',
      'args', jsonb_build_object('method', 'get', 'connection', 'selftest_conn', 'path', 'widgets')
    )
  ));
  ok := (SELECT idempotency_key FROM allgres_private.outbound_calls WHERE call_id = (comp->>'call_id')::uuid) IS NULL;
  v := v || jsonb_build_array(jsonb_build_object('name', 'http_request_get_never_gets_an_idempotency_key', 'ok', ok));

  -- Never a full URL when a connection is named: the whole point of a
  -- stored credential is that it can only ever reach its own base_url.
  UPDATE allgres_private.tasks SET status = 'running' WHERE task_id = v_tid;
  comp := allgres_public.fn_submit_result(v_tid, jsonb_build_object(
    'type', 'llm_response', 'content', '{}', 'parsed', jsonb_build_object(
      'action', 'call_tool', 'tool', 'http_request',
      'args', jsonb_build_object('method', 'get', 'connection', 'selftest_conn', 'path', 'https://evil.invalid/steal')
    )
  ));
  SELECT content INTO r FROM allgres_private.execution_logs WHERE task_id = v_tid AND role = 'error' ORDER BY step_number DESC LIMIT 1;
  ok := (comp->>'action') = 'continue' AND (r->>'reason') = 'connection_path_must_be_relative';
  v := v || jsonb_build_array(jsonb_build_object('name', 'http_request_connection_rejects_absolute_path', 'ok', ok));

  UPDATE allgres_private.tasks SET status = 'running' WHERE task_id = v_tid;
  comp := allgres_public.fn_submit_result(v_tid, jsonb_build_object(
    'type', 'llm_response', 'content', '{}', 'parsed', jsonb_build_object(
      'action', 'call_tool', 'tool', 'http_request',
      'args', jsonb_build_object('method', 'TRACE', 'url', 'https://selftest.invalid/x')
    )
  ));
  SELECT content INTO r FROM allgres_private.execution_logs WHERE task_id = v_tid AND role = 'error' ORDER BY step_number DESC LIMIT 1;
  ok := (comp->>'action') = 'continue' AND (r->>'reason') = 'unsupported_http_method';
  v := v || jsonb_build_array(jsonb_build_object('name', 'http_request_rejects_unsupported_method', 'ok', ok));

  UPDATE allgres_private.tasks SET status = 'running' WHERE task_id = v_tid;
  comp := allgres_public.fn_submit_result(v_tid, jsonb_build_object(
    'type', 'llm_response', 'content', '{}', 'parsed', jsonb_build_object(
      'action', 'call_tool', 'tool', 'http_request',
      'args', jsonb_build_object('method', 'get', 'connection', 'selftest_conn_does_not_exist', 'path', 'x')
    )
  ));
  SELECT content INTO r FROM allgres_private.execution_logs WHERE task_id = v_tid AND role = 'error' ORDER BY step_number DESC LIMIT 1;
  ok := (comp->>'action') = 'continue' AND (r->>'reason') = 'unknown_connection';
  v := v || jsonb_build_array(jsonb_build_object('name', 'http_request_rejects_unknown_connection', 'ok', ok));

  -- An agent-supplied Authorization header on a direct (no-connection) call
  -- is stripped, not honoured -- it would otherwise be exactly the
  -- plaintext-secret-in-a-row shape this design keeps out of outbound_calls.
  UPDATE allgres_private.tasks SET status = 'running' WHERE task_id = v_tid;
  comp := allgres_public.fn_submit_result(v_tid, jsonb_build_object(
    'type', 'llm_response', 'content', '{}', 'parsed', jsonb_build_object(
      'action', 'call_tool', 'tool', 'http_request',
      'args', jsonb_build_object('method', 'get', 'url', 'https://selftest.invalid/y',
        'headers', jsonb_build_object('authorization', 'sneaky', 'x-custom', 'keep'))
    )
  ));
  v_call := (comp->>'call_id')::uuid;
  SELECT to_jsonb(o) INTO r FROM allgres_private.outbound_calls o WHERE o.call_id = v_call;
  ok := (r->'request_headers'->>'x-custom') = 'keep'
    AND NOT (r->'request_headers' ? 'authorization')
    AND (r->>'connection_id') IS NULL AND (r->>'auth_kind') IS NULL;
  v := v || jsonb_build_array(jsonb_build_object('name', 'http_request_direct_url_strips_agent_supplied_auth_header', 'ok', ok));

  -- 'tool' permission is per-tool-name, not a blanket "may call call_tool":
  -- holding http_get does not imply http_request, and vice versa.
  PERFORM allgres_public.fn_revoke_permission(v_new_agent, 'tool', 'http_request');
  UPDATE allgres_private.tasks SET status = 'running' WHERE task_id = v_tid;
  comp := allgres_public.fn_submit_result(v_tid, jsonb_build_object(
    'type', 'llm_response', 'content', '{}', 'parsed', jsonb_build_object(
      'action', 'call_tool', 'tool', 'http_request',
      'args', jsonb_build_object('method', 'get', 'url', 'https://selftest.invalid/z')
    )
  ));
  SELECT content INTO r FROM allgres_private.execution_logs WHERE task_id = v_tid AND role = 'error' ORDER BY step_number DESC LIMIT 1;
  ok := (comp->>'action') = 'continue' AND (r->>'reason') = 'tool_not_permitted';
  v := v || jsonb_build_array(jsonb_build_object('name', 'http_request_needs_tool_permission_distinct_from_http_get', 'ok', ok));
  PERFORM allgres_public.fn_grant_permission(v_new_agent, 'tool', 'http_request');

  -- http_get itself must come out exactly as before this tool was added:
  -- method GET, no connection, no body.
  PERFORM allgres_public.fn_grant_permission(v_new_agent, 'tool', 'http_get');
  UPDATE allgres_private.tasks SET status = 'running' WHERE task_id = v_tid;
  comp := allgres_public.fn_submit_result(v_tid, jsonb_build_object(
    'type', 'llm_response', 'content', '{}', 'parsed', jsonb_build_object(
      'action', 'call_tool', 'tool', 'http_get',
      'args', jsonb_build_object('url', 'https://selftest.invalid/legacy')
    )
  ));
  v_call := (comp->>'call_id')::uuid;
  SELECT to_jsonb(o) INTO r FROM allgres_private.outbound_calls o WHERE o.call_id = v_call;
  ok := (r->>'method') = 'GET' AND (r->>'connection_id') IS NULL AND (r->'request_body') = '{}'::jsonb;
  v := v || jsonb_build_array(jsonb_build_object('name', 'http_get_unchanged_by_http_request_addition', 'ok', ok));

  -- The credential itself: never in request_headers at queue time (already
  -- implied above by connection_id being the only thing recorded), and
  -- actually injected, decrypted, by fn_claim_outbound at claim time.
  UPDATE allgres_private.tasks SET status = 'running' WHERE task_id = v_tid;
  comp := allgres_public.fn_submit_result(v_tid, jsonb_build_object(
    'type', 'llm_response', 'content', '{}', 'parsed', jsonb_build_object(
      'action', 'call_tool', 'tool', 'http_request',
      'args', jsonb_build_object('method', 'get', 'connection', 'selftest_conn', 'path', 'ping')
    )
  ));
  v_call := (comp->>'call_id')::uuid;
  claim := allgres_public.fn_claim_outbound(10);
  SELECT x INTO r FROM jsonb_array_elements(claim->'calls') x WHERE x->>'call_id' = v_call::text;
  ok := (r->'headers'->>'authorization') = 'Bearer selftest-conn-key';
  PERFORM allgres_public.fn_complete_outbound(v_call, 200, '{}');
  v := v || jsonb_build_array(jsonb_build_object('name', 'fn_claim_outbound_injects_connection_secret', 'ok', ok));

  -- No FK cascade from outbound_calls.connection_id (see that column's own
  -- comment): a connection a real call still references cannot be deleted
  -- out from under it.
  BEGIN
    PERFORM allgres_public.fn_delete_connection(v_conn);
    ok := false;
  EXCEPTION WHEN foreign_key_violation THEN
    ok := true;
  END;
  v := v || jsonb_build_array(jsonb_build_object('name', 'connection_delete_blocked_while_outbound_calls_reference_it', 'ok', ok));

  DELETE FROM allgres_private.outbound_calls WHERE task_id = v_tid;
  PERFORM allgres_public.fn_delete_connection(v_conn);
  UPDATE allgres_private.agents SET is_active = false WHERE agent_id = v_new_agent;

  -- 26. OAuth token exchange, queued rather than handed back to the caller
  --     (see KNOWN_ISSUES.md, "a second-round external review of items 18
  --     and 19": fn_oauth_token_request used to decrypt the client secret
  --     and return the built request directly). A fixed provider name, like
  --     provision_agent_role_is_idempotent's fixed test agent, so repeated
  --     fn_selftest calls don't accumulate garbage rows.
  INSERT INTO allgres_private.llm_providers (name, kind, base_url, is_enabled, allow_private_network,
    oauth_auth_url, oauth_token_url, oauth_client_id)
  VALUES ('selftest_oauth', 'oauth', 'https://selftest.invalid/oauth', true, false,
    'https://selftest.invalid/oauth/authorize', 'https://selftest.invalid/oauth/token', 'selftest-client-id')
  ON CONFLICT (name) DO UPDATE SET
    oauth_auth_url = EXCLUDED.oauth_auth_url,
    oauth_token_url = EXCLUDED.oauth_token_url,
    oauth_client_id = EXCLUDED.oauth_client_id
  RETURNING provider_id INTO v_provider;
  PERFORM allgres_public.fn_set_provider(v_provider, NULL, NULL, NULL, NULL, NULL, NULL, 'selftest-secret-value');
  DELETE FROM allgres_private.oauth_calls WHERE provider_id = v_provider;
  DELETE FROM allgres_private.oauth_states WHERE provider_id = v_provider;

  -- 26a. fn_oauth_token_request queues instead of leaking: the client secret
  --      appears nowhere in its own return value, nor in the queued row's
  --      request_body -- only fn_claim_oauth (worker-only) ever sees it.
  v_state := (allgres_public.fn_oauth_start(v_provider, 'https://dashboard.local/callback')->>'state');
  sub := allgres_public.fn_oauth_token_request(v_state, 'selftest-code', 'https://dashboard.local/callback');
  v_call := (sub->>'call_id')::uuid;
  ok := (sub->>'queued')::boolean IS TRUE AND v_call IS NOT NULL
    AND NOT (sub::text LIKE '%selftest-secret-value%');
  SELECT NOT (request_body::text LIKE '%selftest-secret-value%') AND NOT (request_body ? 'client_secret')
    INTO detail_bool FROM allgres_private.oauth_calls WHERE call_id = v_call;
  ok := ok AND COALESCE(detail_bool, false);
  -- Single-use: the state is consumed at queue time, not at completion.
  ok := ok AND NOT EXISTS (SELECT 1 FROM allgres_private.oauth_states WHERE state = v_state);
  v := v || jsonb_build_array(jsonb_build_object('name', 'oauth_token_request_queues_without_leaking_secret', 'ok', ok));

  -- 26b. fn_claim_oauth injects the decrypted secret only into the response
  --      it hands the worker -- never back into oauth_calls.request_body,
  --      the same claim-time-only shape fn_claim_outbound already uses for
  --      an LLM provider's api_key (KNOWN_ISSUES.md, item 13).
  spec := allgres_public.fn_claim_oauth(10);
  SELECT elem INTO sub
  FROM jsonb_array_elements(spec->'calls') AS t(elem)
  WHERE (elem->>'call_id')::uuid = v_call;
  ok := sub IS NOT NULL AND sub->'body'->>'client_secret' = 'selftest-secret-value';
  SELECT NOT (request_body::text LIKE '%selftest-secret-value%') AND status = 'in_flight'
    INTO detail_bool FROM allgres_private.oauth_calls WHERE call_id = v_call;
  ok := ok AND COALESCE(detail_bool, false);
  v := v || jsonb_build_array(jsonb_build_object('name', 'claim_oauth_injects_secret_only_into_response', 'ok', ok));

  -- 26c. Fencing: identical reasoning to complete_sql_fences_stale_result --
  --      a belated result for a call fn_watchdog already reclaimed as 'lost'
  --      must be discarded, not stored, or a zombie worker's response could
  --      overwrite whatever a second, later attempt actually produced.
  UPDATE allgres_private.oauth_calls SET status = 'lost', updated_at = now() WHERE call_id = v_call;
  comp := allgres_public.fn_complete_oauth(v_call, 200,
    '{"access_token":"should-not-be-stored","refresh_token":"nope","expires_in":3600}');
  ok := comp->>'action' = 'stale';
  ok := ok AND NOT EXISTS (
    SELECT 1 FROM allgres_private.llm_secrets
    WHERE provider_id = v_provider AND access_token IS NOT NULL
      AND allgres_private.decrypt_secret(access_token) = 'should-not-be-stored'
  );
  v := v || jsonb_build_array(jsonb_build_object('name', 'complete_oauth_fences_stale_result', 'ok', ok));

  -- 26d. A second, real flow: fn_complete_oauth stores what comes back,
  --      encrypted, the same way the old public fn_oauth_store_tokens used
  --      to -- that function is gone; this is the only path left to it.
  v_state := (allgres_public.fn_oauth_start(v_provider, 'https://dashboard.local/callback')->>'state');
  sub := allgres_public.fn_oauth_token_request(v_state, 'selftest-code-2', 'https://dashboard.local/callback');
  v_call2 := (sub->>'call_id')::uuid;
  PERFORM allgres_public.fn_claim_oauth(10);
  comp := allgres_public.fn_complete_oauth(v_call2, 200,
    '{"access_token":"selftest-access-tok","refresh_token":"selftest-refresh-tok","expires_in":3600}');
  ok := comp->>'action' = 'stored';
  ok := ok AND (
    SELECT allgres_private.decrypt_secret(access_token) = 'selftest-access-tok'
       AND allgres_private.decrypt_secret(refresh_token) = 'selftest-refresh-tok'
       AND expires_at IS NOT NULL
    FROM allgres_private.llm_secrets WHERE provider_id = v_provider
  );
  v := v || jsonb_build_array(jsonb_build_object('name', 'complete_oauth_stores_tokens_on_success', 'ok', ok));

  -- 26e. A token endpoint response with no access_token is an error, not a
  --      silent no-op -- fn_complete_oauth must not leave the row 'in_flight'
  --      forever waiting for a result that already arrived and was unusable.
  v_state := (allgres_public.fn_oauth_start(v_provider, 'https://dashboard.local/callback')->>'state');
  sub := allgres_public.fn_oauth_token_request(v_state, 'selftest-code-3', 'https://dashboard.local/callback');
  v_call2 := (sub->>'call_id')::uuid;
  PERFORM allgres_public.fn_claim_oauth(10);
  comp := allgres_public.fn_complete_oauth(v_call2, 200, '{"error":"access_denied"}');
  ok := comp->>'action' = 'error' AND comp->>'reason' = 'no_access_token';
  SELECT status = 'harvested' INTO detail_bool FROM allgres_private.oauth_calls WHERE call_id = v_call2;
  ok := ok AND COALESCE(detail_bool, false);
  v := v || jsonb_build_array(jsonb_build_object('name', 'complete_oauth_requires_access_token', 'ok', ok));

  DELETE FROM allgres_private.oauth_calls WHERE provider_id = v_provider;
  DELETE FROM allgres_private.oauth_states WHERE provider_id = v_provider;

  -- 27. Long-term agent memory (item 25). Starts from a clean slate for the
  --     analyst agent so the recall test below can assert on content, not
  --     just presence.
  DELETE FROM allgres_private.agent_memories WHERE agent_id = v_agent;

  -- 27a. `remember` rejects malformed input without failing the task.
  v_sid := (allgres_public.fn_create_session(v_agent, 'selftest remember_reject')->>'session_id')::uuid;
  SELECT task_id INTO v_tid FROM allgres_private.tasks WHERE session_id = v_sid LIMIT 1;
  PERFORM allgres_public.fn_next_step(v_tid);
  sub := allgres_public.fn_submit_result(v_tid, jsonb_build_object(
    'type', 'llm_response', 'content', '{"action":"remember"}',
    'parsed', jsonb_build_object('action', 'remember', 'content', '')
  ));
  SELECT status INTO detail FROM allgres_private.tasks WHERE task_id = v_tid;
  ok := sub->>'action' = 'continue' AND detail = 'running' AND sub->>'memory_id' IS NULL;
  PERFORM allgres_public.fn_next_step(v_tid);
  sub := allgres_public.fn_submit_result(v_tid, jsonb_build_object(
    'type', 'llm_response', 'content', '{"action":"remember"}',
    'parsed', jsonb_build_object('action', 'remember', 'content', 'x', 'memory_type', 'not_a_real_type')
  ));
  ok := ok AND sub->>'action' = 'continue' AND sub->>'memory_id' IS NULL;
  SELECT count(*) INTO v_mem_count FROM allgres_private.agent_memories WHERE agent_id = v_agent;
  ok := ok AND v_mem_count = 0;
  v := v || jsonb_build_array(jsonb_build_object('name', 'remember_rejects_malformed_input', 'ok', ok));

  -- 27b. A well-formed `remember` writes a row and is recalled into a later
  --      task's own fn_next_step context -- the actual point of this
  --      feature, not just that a row got written (see item 12's own
  --      standing question: "does the test check the write, or the read?").
  PERFORM allgres_public.fn_next_step(v_tid);
  sub := allgres_public.fn_submit_result(v_tid, jsonb_build_object(
    'type', 'llm_response', 'content', '{"action":"remember"}',
    'parsed', jsonb_build_object(
      'action', 'remember', 'content', 'selftest marker: the sky is teal',
      'memory_type', 'semantic', 'importance', 0.9
    )
  ));
  ok := sub->>'action' = 'continue' AND sub->>'memory_id' IS NOT NULL;

  v_sid := (allgres_public.fn_create_session(v_agent, 'selftest remember_recall')->>'session_id')::uuid;
  SELECT task_id INTO v_tid2 FROM allgres_private.tasks WHERE session_id = v_sid LIMIT 1;
  spec := allgres_public.fn_next_step(v_tid2);
  ok := ok AND (spec->'messages'->0->>'content') LIKE '%selftest marker: the sky is teal%';
  ok := ok AND (spec->'messages'->0->>'content') LIKE '%remember%';
  SELECT last_accessed_at IS NOT NULL INTO detail_bool
  FROM allgres_private.agent_memories WHERE agent_id = v_agent AND content LIKE 'selftest marker%';
  ok := ok AND COALESCE(detail_bool, false);
  v := v || jsonb_build_array(jsonb_build_object('name', 'remember_writes_and_is_recalled', 'ok', ok));

  -- 27c. Recall is scoped to the querying agent only -- selftest_delegate_b's
  --      own fn_next_step must never see selftest_delegate_a's memory, the
  --      same isolation property provision_agent_role_is_idempotent already
  --      proved for the SQL sandbox (v_my_tasks), now for this instead.
  DELETE FROM allgres_private.agent_memories WHERE agent_id IN (v_deleg_a, v_deleg_b);
  v_mem_result := allgres_private.write_memory(
    v_deleg_a, 'selftest marker: agent A secret preference', 'preference', '1.0', NULL, NULL
  );
  v_sid := (allgres_public.fn_create_session(v_deleg_b, 'selftest recall_scoping')->>'session_id')::uuid;
  SELECT task_id INTO v_tid FROM allgres_private.tasks WHERE session_id = v_sid LIMIT 1;
  spec := allgres_public.fn_next_step(v_tid);
  ok := (spec->'messages'->0->>'content') NOT LIKE '%agent A secret preference%';
  v := v || jsonb_build_array(jsonb_build_object('name', 'memory_recall_scoped_to_agent', 'ok', ok));
  DELETE FROM allgres_private.agent_memories WHERE agent_id IN (v_deleg_a, v_deleg_b);

  -- 27d. The fixed 500-per-agent cap evicts the least important (then
  --      oldest) rows rather than growing without bound.
  DELETE FROM allgres_private.agent_memories WHERE agent_id = v_agent;
  v_mem_result := allgres_private.write_memory(v_agent, 'selftest low importance marker', 'working', '0.0', NULL, NULL);
  v_low_mem := (v_mem_result->>'memory_id')::uuid;
  FOR n_logs IN 1..499 LOOP
    PERFORM allgres_private.write_memory(v_agent, 'selftest filler ' || n_logs, 'working', '0.4', NULL, NULL);
  END LOOP;
  v_mem_result := allgres_private.write_memory(v_agent, 'selftest high importance marker', 'working', '1.0', NULL, NULL);
  v_high_mem := (v_mem_result->>'memory_id')::uuid;
  SELECT count(*) INTO v_mem_count FROM allgres_private.agent_memories WHERE agent_id = v_agent;
  ok := v_mem_count = 500;
  ok := ok AND NOT EXISTS (SELECT 1 FROM allgres_private.agent_memories WHERE memory_id = v_low_mem);
  ok := ok AND EXISTS (SELECT 1 FROM allgres_private.agent_memories WHERE memory_id = v_high_mem);
  v := v || jsonb_build_array(jsonb_build_object('name', 'memory_cap_evicts_least_important', 'ok', ok));
  DELETE FROM allgres_private.agent_memories WHERE agent_id = v_agent;

  -- 27e. fn_watchdog garbage-collects an expired memory -- filtered out of
  --      recall already (see fn_next_step), this just stops the row itself
  --      from sitting there forever.
  v_mem_result := allgres_private.write_memory(v_agent, 'selftest expired marker', 'working', '0.5', NULL, '1');
  UPDATE allgres_private.agent_memories SET expires_at = now() - interval '1 minute'
  WHERE memory_id = (v_mem_result->>'memory_id')::uuid;
  spec := allgres_public.fn_watchdog();
  ok := COALESCE((spec->>'memories_expired')::int, 0) >= 1;
  ok := ok AND NOT EXISTS (
    SELECT 1 FROM allgres_private.agent_memories WHERE memory_id = (v_mem_result->>'memory_id')::uuid
  );
  v := v || jsonb_build_array(jsonb_build_object('name', 'watchdog_expires_stale_memory', 'ok', ok));

  -- 27f. The operator path (fn_remember/fn_forget, dashboard_rpc's
  --      memories.create/.remove) is the same write_memory underneath, with
  --      no session/task to attribute it to.
  sub := allgres_public.fn_remember(v_agent, 'selftest operator-authored memory', 'instruction', '0.7', 'operator', NULL);
  ok := (sub->>'ok')::boolean IS TRUE AND sub->>'memory_id' IS NOT NULL;
  ok := ok AND EXISTS (
    SELECT 1 FROM allgres_private.agent_memories
    WHERE memory_id = (sub->>'memory_id')::uuid AND source_session_id IS NULL AND source_task_id IS NULL
  );
  comp := allgres_public.fn_forget((sub->>'memory_id')::uuid);
  ok := ok AND (comp->>'ok')::boolean IS TRUE;
  ok := ok AND NOT EXISTS (
    SELECT 1 FROM allgres_private.agent_memories WHERE memory_id = (sub->>'memory_id')::uuid
  );
  v := v || jsonb_build_array(jsonb_build_object('name', 'fn_remember_and_fn_forget_round_trip', 'ok', ok));

  DELETE FROM allgres_private.agent_memories WHERE agent_id = v_agent;

  -- 28. The seeded maintenance/auditor agent (README, "Maintenance
  --     agents") can read v_system_health/v_permission_audit; a plain
  --     agent with no grant for either sees zero rows from both -- the
  --     same enforcement views_enforce_permission already proved for
  --     v_sales, now for the system-wide views instead of a per-agent-
  --     owned one (no agent_id column to filter by; agent_may_read alone
  --     gates the whole row set).
  SELECT agent_id INTO v_prov_agent FROM allgres_private.agents WHERE name = 'health_monitor';
  ok := v_prov_agent IS NOT NULL;

  PERFORM set_config('allgres.agent_id', v_prov_agent::text, true);
  SELECT count(*) INTO n_logs FROM allgres_public.v_system_health;
  ok := ok AND n_logs = 1;
  SELECT count(*) INTO n_logs FROM allgres_public.v_permission_audit;
  ok := ok AND n_logs > 0;

  PERFORM set_config('allgres.agent_id', v_agent::text, true);
  SELECT count(*) INTO n_logs FROM allgres_public.v_system_health;
  ok := ok AND n_logs = 0;
  SELECT count(*) INTO n_logs FROM allgres_public.v_permission_audit;
  ok := ok AND n_logs = 0;
  PERFORM set_config('allgres.agent_id', '', true);
  v := v || jsonb_build_array(jsonb_build_object('name', 'maintenance_views_enforce_permission', 'ok', ok));

  -- Roadmap item 7 (evaluation-gated self-improvement): v_agent_health is
  -- the same permission-gated shape v_system_health/v_permission_audit
  -- just proved, per-agent instead of a single aggregate row -- reuses
  -- v_prov_agent (health_monitor, granted at seed time) and v_agent
  -- (ungranted) from the block just above.
  PERFORM set_config('allgres.agent_id', v_prov_agent::text, true);
  SELECT count(*) INTO n_logs FROM allgres_public.v_agent_health;
  ok := n_logs > 0;
  PERFORM set_config('allgres.agent_id', v_agent::text, true);
  SELECT count(*) INTO n_logs FROM allgres_public.v_agent_health;
  ok := ok AND n_logs = 0;
  PERFORM set_config('allgres.agent_id', '', true);
  v := v || jsonb_build_array(jsonb_build_object('name', 'v_agent_health_enforces_permission', 'ok', ok));

  ok := allgres_private.agent_has_permission(
    (SELECT agent_id FROM allgres_private.agents WHERE name = 'self_improve'),
    'view', 'allgres_public.v_agent_health'
  );
  v := v || jsonb_build_array(jsonb_build_object('name', 'self_improve_is_granted_v_agent_health', 'ok', ok));

  -- allgres_private.agent_recent_success_rate: NULL (not zero) with no
  -- evaluable tasks yet, a real ratio once some exist, scoped to root-level
  -- tasks only (a delegated child must never count toward the delegating
  -- agent's own rate -- it reflects whoever it was delegated *to*). The
  -- function also excludes goal LIKE 'selftest%' sessions (the same
  -- exclusion every operator-facing count in this file already applies to
  -- fn_selftest's own debris -- see its comment), so proving the *counted*
  -- case needs a fixture session/task that does NOT carry that prefix.
  -- Rather than drive that through fn_create_session (which unconditionally
  -- writes an execution_logs row, and that trigger's append-only rule would
  -- then block ever deleting it -- the reason every other fixture agent in
  -- this file is left deactivated forever instead of removed), the fixture
  -- tasks below are inserted directly and never touch execution_logs at
  -- all, so they can be hard-deleted afterward and leave nothing for an
  -- operator to ever see.
  INSERT INTO allgres_private.agents (name)
    VALUES ('selftest_eval_agent_' || substr(md5(random()::text), 1, 8))
    RETURNING agent_id INTO v_new_agent;
  v_eval_child_name := 'selftest_eval_child_' || substr(md5(random()::text), 1, 8);
  INSERT INTO allgres_private.agents (name)
    VALUES (v_eval_child_name)
    RETURNING agent_id INTO v_deleg_a;
  PERFORM allgres_public.fn_grant_permission(v_new_agent, 'agent', v_eval_child_name);

  ok := allgres_private.agent_recent_success_rate(v_new_agent, 20) IS NULL;
  v := v || jsonb_build_array(jsonb_build_object('name', 'agent_recent_success_rate_null_with_no_tasks', 'ok', ok));

  -- Generation 1: one completed root task, explicitly stamped with the
  -- agent's current (only) generation the same way fn_create_session
  -- would -- plus a delegated child under a different agent, parented to
  -- it, whose own failure must not move v_new_agent's rate at all.
  v_sid := gen_random_uuid();
  INSERT INTO allgres_private.sessions (session_id, agent_id, goal, status)
    VALUES (v_sid, v_new_agent, 'eval fixture (selftest): one completed root task', 'open');
  INSERT INTO allgres_private.tasks (session_id, agent_id, status, policy_generation)
    VALUES (v_sid, v_new_agent, 'completed', 1) RETURNING task_id INTO v_tid;
  INSERT INTO allgres_private.tasks (session_id, agent_id, parent_task_id, status)
    VALUES (v_sid, v_deleg_a, v_tid, 'failed') RETURNING task_id INTO v_deleg_b;
  v_rate := allgres_private.agent_recent_success_rate(v_new_agent, 20);
  ok := v_rate = 1.0;
  v := v || jsonb_build_array(jsonb_build_object('name', 'agent_recent_success_rate_ignores_delegated_children', 'ok', ok));

  ok := (SELECT (rate, sample_size) = (1.0, 1) FROM allgres_private.agent_success_rate_for_generation(v_new_agent, 1, 20));
  v := v || jsonb_build_array(jsonb_build_object('name', 'agent_success_rate_for_generation_scopes_to_that_generation', 'ok', ok));

  r := allgres_public.fn_evaluate_last_change(v_new_agent);
  ok := (r->>'verdict') = 'no_change_recorded_yet';
  v := v || jsonb_build_array(jsonb_build_object('name', 'fn_evaluate_last_change_reports_no_change_recorded_yet', 'ok', ok));

  -- policy_history.success_rate_at_change: a real snapshot of generation
  -- 1's own tasks (not some other window), taken at the moment it is
  -- replaced by generation 2.
  PERFORM allgres_public.fn_set_policy(v_new_agent, 'selftest eval prompt v2');
  ok := (SELECT success_rate_at_change FROM allgres_private.policy_history WHERE agent_id = v_new_agent AND generation = 1) = 1.0;
  v := v || jsonb_build_array(jsonb_build_object('name', 'policy_history_snapshots_success_rate_on_a_real_change', 'ok', ok));

  -- Right after the change, generation 2 has zero tasks of its own yet --
  -- an outside review's point exactly: this is not "unchanged", it is "no
  -- data yet for the new policy", and fn_evaluate_last_change must say so
  -- rather than compare an empty window to generation 1's rate.
  r := allgres_public.fn_evaluate_last_change(v_new_agent);
  ok := (r->>'verdict') = 'insufficient_data' AND (r->>'current_sample_size')::int = 0;
  v := v || jsonb_build_array(jsonb_build_object('name', 'fn_evaluate_last_change_reports_insufficient_data_before_any_new_generation_task', 'ok', ok));

  -- One failing root task lands under the NEW generation (2). With only
  -- one sample on each side, the default sample-size floor (5) must still
  -- withhold a verdict rather than call this "regressed" off one data
  -- point per side.
  v_sid2 := gen_random_uuid();
  INSERT INTO allgres_private.sessions (session_id, agent_id, goal, status)
    VALUES (v_sid2, v_new_agent, 'eval fixture (selftest): one failed root task', 'open');
  INSERT INTO allgres_private.tasks (session_id, agent_id, status, policy_generation)
    VALUES (v_sid2, v_new_agent, 'failed', 2);
  r := allgres_public.fn_evaluate_last_change(v_new_agent);
  ok := (r->>'verdict') = 'insufficient_data'
    AND (r->>'current_sample_size')::int = 1 AND (r->>'before_sample_size')::int = 1;
  v := v || jsonb_build_array(jsonb_build_object('name', 'fn_evaluate_last_change_withholds_verdict_below_min_samples', 'ok', ok));

  -- The same comparison with an explicit lower floor gets a real verdict:
  -- generation 2's one failure against generation 1's one success is a
  -- real regression, correctly isolated to just those two generations'
  -- own tasks -- proving the isolation itself, not just the sample-size
  -- gate: an ungated (mixed-window) comparison would have averaged both
  -- generations' tasks together into a flat 0.5 on both sides and missed
  -- the regression entirely.
  r := allgres_public.fn_evaluate_last_change(v_new_agent, 1);
  ok := (r->>'verdict') = 'regressed' AND (r->>'compared_to_generation')::int = 1;
  v := v || jsonb_build_array(jsonb_build_object('name', 'fn_evaluate_last_change_reports_regressed_isolated_by_generation', 'ok', ok));

  r := allgres_public.fn_evaluate_last_change(v_deleg_a);
  ok := (r->>'verdict') = 'no_change_recorded_yet';
  v := v || jsonb_build_array(jsonb_build_object('name', 'fn_evaluate_last_change_reports_no_change_recorded_yet_for_a_fresh_agent', 'ok', ok));

  -- None of this touched execution_logs, so unlike every other fixture
  -- agent in this file it can be removed outright instead of merely
  -- deactivated -- policies/policy_history/permissions cascade off the
  -- agents delete.
  DELETE FROM allgres_private.tasks WHERE session_id IN (v_sid, v_sid2);
  DELETE FROM allgres_private.sessions WHERE session_id IN (v_sid, v_sid2);
  DELETE FROM allgres_private.agents WHERE agent_id IN (v_new_agent, v_deleg_a);

  -- 29. Operator audit log (README, "Operator audit log"): a consequential
  --     dashboard_rpc action writes exactly one row, with the self-
  --     reported operator_name and (for an action carrying one) no
  --     credential anywhere in it; a read-only action writes none; the
  --     table refuses UPDATE/DELETE even from the function's own owner,
  --     not just from operator (see audit_log_no_update's own comment for
  --     why a REVOKE alone would not have been enough).
  --
  -- The allowlist.add/remove and provider.update calls below are admin-
  -- gated (require_admin_if_accounts_exist) -- this section used to lean
  -- on the ambient "no accounts exist yet" bootstrap no-op the same way a
  -- fresh install's own fn_selftest run happens to start in, which broke
  -- outright (every gated call here rejected) the moment fn_selftest ran
  -- against a database that already had one real account -- exactly what
  -- happens the first time an operator clicks Settings' own "Run
  -- selftest" button after creating their own admin account. A throwaway
  -- admin token minted right here, used explicitly on every gated call in
  -- this section, and torn down before it ends, makes this section's own
  -- coverage independent of whatever account state the surrounding
  -- database already happens to be in. Skipped when pgcrypto isn't
  -- installed (fn_create_user would fail closed anyway); without
  -- pgcrypto no real account can exist either, so the old bootstrap
  -- no-op still applies and v_audit_tok staying NULL reaches the same
  -- gate the same way an absent session_token always has.
  v_audit_tok := NULL;
  IF allgres_private.pgcrypto_schema() IS NOT NULL THEN
    DELETE FROM allgres_private.users WHERE username = 'selftest_audit_admin';
    PERFORM allgres_public.fn_create_user('selftest_audit_admin', 'selftest-audit-pw1', 'admin');
    v_audit_tok := allgres_public.fn_login('selftest_audit_admin', 'selftest-audit-pw1')->>'session_token';
  END IF;

  PERFORM allgres.dashboard_rpc(jsonb_build_object(
    'action', 'allowlist.remove', 'ref', 'selftest_audit_marker', 'session_token', v_audit_tok
  ));
  sub := allgres.dashboard_rpc(jsonb_build_object(
    'action', 'allowlist.add', 'ref', 'selftest_audit_marker', 'operator_name', 'selftest_operator',
    'session_token', v_audit_tok
  ));
  ok := (sub->>'ok')::boolean IS TRUE;
  SELECT operator_name = 'selftest_operator' AND details = jsonb_build_object('resource_ref', 'selftest_audit_marker')
  INTO detail_bool
  FROM allgres_private.audit_log
  WHERE action = 'allowlist.add' AND details->>'resource_ref' = 'selftest_audit_marker'
  ORDER BY created_at DESC LIMIT 1;
  ok := ok AND COALESCE(detail_bool, false);
  PERFORM allgres.dashboard_rpc(jsonb_build_object(
    'action', 'allowlist.remove', 'ref', 'selftest_audit_marker', 'session_token', v_audit_tok
  ));

  SELECT count(*) INTO n_logs FROM allgres_private.audit_log;
  PERFORM allgres.dashboard_rpc(jsonb_build_object('action', 'overview'));
  SELECT count(*) INTO v_gen FROM allgres_private.audit_log;
  ok := ok AND v_gen = n_logs;

  sub := allgres.dashboard_rpc(jsonb_build_object(
    'action', 'provider.update', 'provider_id', v_provider,
    'api_key', 'selftest-should-not-leak-into-audit-log', 'operator_name', 'selftest_operator',
    'session_token', v_audit_tok
  ));
  SELECT NOT (details::text LIKE '%selftest-should-not-leak%') INTO detail_bool
  FROM allgres_private.audit_log WHERE action = 'provider.update' ORDER BY created_at DESC LIMIT 1;
  ok := ok AND COALESCE(detail_bool, false);
  PERFORM allgres_public.fn_set_provider(v_provider, NULL, NULL, NULL, NULL, NULL, NULL, 'selftest-secret-value');

  BEGIN
    UPDATE allgres_private.audit_log SET operator_name = 'tampered'
    WHERE audit_id = (SELECT audit_id FROM allgres_private.audit_log ORDER BY created_at DESC LIMIT 1);
    ok := false;
  EXCEPTION WHEN others THEN
    ok := ok AND SQLERRM LIKE '%append-only%';
  END;

  v := v || jsonb_build_array(jsonb_build_object('name', 'audit_log_records_consequential_actions_only', 'ok', ok));

  -- 29a. origin/db_role provenance, web half (the sql half runs at the very
  -- top of this function, before dashboard_rpc's own set_audit_context has
  -- ever executed in this transaction -- see that section's comment for
  -- why it cannot also be checked here): the same allowlist.add action,
  -- reached through dashboard_rpc with an operator_name, must record
  -- origin='web' with that operator_name and the real db_role -- proving
  -- the fail-safe direction in allgres_private.audit's own comment holds.
  -- A distinct ref from the sql half's, not just a distinct assertion: the
  -- whole selftest run is one transaction, so now() -- and therefore
  -- audit_log.created_at -- is identical for every row it inserts; reusing
  -- the same ref would make "ORDER BY created_at DESC LIMIT 1" pick
  -- between two same-timestamp rows arbitrarily instead of the one this
  -- check actually means to look at.
  sub := allgres.dashboard_rpc(jsonb_build_object(
    'action', 'allowlist.add', 'ref', 'selftest_audit_origin_marker_web', 'operator_name', 'selftest_operator',
    'session_token', v_audit_tok
  ));
  SELECT origin = 'web' AND operator_name = 'selftest_operator' AND db_role = session_user::text
  INTO detail_bool
  FROM allgres_private.audit_log
  WHERE action = 'allowlist.add' AND details->>'resource_ref' = 'selftest_audit_origin_marker_web'
  ORDER BY created_at DESC LIMIT 1;
  ok := COALESCE(detail_bool, false);
  PERFORM allgres.dashboard_rpc(jsonb_build_object(
    'action', 'allowlist.remove', 'ref', 'selftest_audit_origin_marker_web', 'session_token', v_audit_tok
  ));
  v := v || jsonb_build_array(jsonb_build_object('name', 'audit_log_dashboard_rpc_call_records_origin_web', 'ok', ok));

  IF v_audit_tok IS NOT NULL THEN
    PERFORM allgres_public.fn_logout(v_audit_tok);
    DELETE FROM allgres_private.users WHERE username = 'selftest_audit_admin';
  END IF;

  -- item 36's own bootstrap guarantee: require_admin_if_accounts_exist must
  -- be a true no-op for a deployment that has never created a user account
  -- at all. Only actually checkable when allgres_private.users is empty --
  -- true on a fresh install/CI (section 31 below is the only place
  -- fn_selftest itself ever creates a row there, and always cleans up
  -- after itself), but NOT true when fn_selftest runs against a live
  -- deployment that already has a real admin account, e.g. via Settings'
  -- own "Run selftest" button. Reporting a failure in that case would be a
  -- false alarm about which state this particular run started in, not a
  -- real defect -- there is nothing this run can check either way, so it
  -- reports true ("nothing to verify here this run") rather than an
  -- unconditional false. Confirmed live: this used to fail outright the
  -- moment one real account existed anywhere in the database beforehand,
  -- permanently breaking "Run selftest" as an ongoing diagnostic the
  -- moment an operator used the accounts feature at all.
  IF NOT EXISTS (SELECT 1 FROM allgres_private.users) THEN
    sub := allgres.dashboard_rpc(jsonb_build_object(
      'action', 'agents.create',
      'name', 'selftest_bootstrap_probe_' || extract(epoch from clock_timestamp())::text
    ));
    ok := COALESCE((sub->>'ok')::boolean, false);
  ELSE
    ok := true;
  END IF;
  v := v || jsonb_build_array(jsonb_build_object('name', 'admin_gate_is_a_noop_before_any_account_exists', 'ok', ok));

  -- Same bootstrap guarantee, for require_agent_access_if_accounts_exist
  -- (roadmap item 1's run/sessions.* fix): `run` against any active agent
  -- must still work with no session_token at all before any account
  -- exists, the same single-operator token-only mode every other gate in
  -- this file preserves.
  IF NOT EXISTS (SELECT 1 FROM allgres_private.users) THEN
    sub := allgres.dashboard_rpc(jsonb_build_object(
      'action', 'run', 'agent_id', v_agent::text, 'goal', 'selftest bootstrap run probe'
    ));
    ok := COALESCE((sub->>'ok')::boolean, false);
  ELSE
    ok := true;
  END IF;
  v := v || jsonb_build_array(jsonb_build_object('name', 'run_gate_is_a_noop_before_any_account_exists', 'ok', ok));

  -- 30. fn_continue_session: a session can be resumed with a follow-up
  --     message instead of only ever starting a brand new, contextless one
  --     (dashboard, "no way to chat"). The new turn is a new task, but
  --     fn_next_step now sees every root-level task's log in the session
  --     (see its own comment), so the follow-up still includes the first
  --     turn's goal -- and a second message cannot be sent while the first
  --     turn is still in flight.
  v_sid := (allgres_public.fn_create_session(v_agent, 'selftest continue_session turn one')->>'session_id')::uuid;
  SELECT task_id INTO v_tid FROM allgres_private.tasks WHERE session_id = v_sid AND parent_task_id IS NULL;

  BEGIN
    PERFORM allgres_public.fn_continue_session(v_sid, 'should be rejected -- turn one still running');
    ok := false;
  EXCEPTION WHEN others THEN
    ok := SQLERRM LIKE '%turn still in progress%';
  END;
  v := v || jsonb_build_array(jsonb_build_object('name', 'fn_continue_session_rejects_while_turn_in_progress', 'ok', ok));

  UPDATE allgres_private.tasks SET status = 'completed', output = jsonb_build_object('answer', 'first answer')
  WHERE task_id = v_tid;
  PERFORM allgres_private.maybe_complete_session(v_sid);
  ok := (SELECT status FROM allgres_private.sessions WHERE session_id = v_sid) = 'completed';

  r := allgres_public.fn_continue_session(v_sid, 'selftest continue_session turn two');
  v_tid2 := (r->>'task_id')::uuid;
  ok := ok AND v_tid2 IS NOT NULL AND v_tid2 <> v_tid;
  ok := ok AND (SELECT status FROM allgres_private.sessions WHERE session_id = v_sid) = 'open';

  spec := allgres_public.fn_next_step(v_tid2);
  ok := ok AND (spec->'messages')::text LIKE '%turn one%'
    AND (spec->'messages')::text LIKE '%turn two%';
  v := v || jsonb_build_array(jsonb_build_object('name', 'fn_continue_session_reopens_and_keeps_context', 'ok', ok));

  UPDATE allgres_private.tasks SET status = 'completed', output = jsonb_build_object('answer', 'second answer')
  WHERE task_id = v_tid2;
  PERFORM allgres_private.maybe_complete_session(v_sid);

  -- 31. Real accounts (item 29's follow-up to item 28's lighter audit log):
  --     pgcrypto-backed login, role gating (require_admin/
  --     require_agent_access), and the chat/messenger surface built on
  --     them. A fresh agent of its own, never the real 'analyst' fixture --
  --     fn_set_my_model below actually mutates llm_config, and fn_selftest
  --     must never leave a real seeded agent's policy different from how
  --     it found it.
  DELETE FROM allgres_private.web_sessions WHERE user_id IN (
    SELECT user_id FROM allgres_private.users WHERE username IN ('selftest_admin', 'selftest_user')
  );
  DELETE FROM allgres_private.users WHERE username IN ('selftest_admin', 'selftest_user');
  SELECT agent_id INTO v_acct_agent FROM allgres_private.agents WHERE name = 'selftest_accounts_agent';
  IF v_acct_agent IS NULL THEN
    v_acct_agent := (allgres_public.fn_create_agent('selftest_accounts_agent')->>'agent_id')::uuid;
  END IF;

  IF allgres_private.pgcrypto_schema() IS NULL THEN
    -- Accounts have no degraded mode, unlike secret encryption: fail
    -- closed and loudly instead of ever hashing or comparing a password
    -- in plaintext.
    BEGIN
      PERFORM allgres_public.fn_create_user('selftest_no_pgcrypto', 'irrelevant123', 'admin');
      ok := false;
    EXCEPTION WHEN others THEN
      ok := SQLERRM LIKE '%pgcrypto is required%';
    END;
    v := v || jsonb_build_array(jsonb_build_object('name', 'accounts_fail_closed_without_pgcrypto', 'ok', ok));
  ELSE
    PERFORM allgres_public.fn_create_user('selftest_admin', 'selftest-admin-pw1', 'admin');
    PERFORM allgres_public.fn_create_user('selftest_user', 'selftest-user-pw1', 'user');

    BEGIN
      PERFORM allgres_public.fn_login('selftest_admin', 'wrong-password');
      ok := false;
    EXCEPTION WHEN others THEN
      ok := SQLERRM LIKE '%invalid username or password%';
    END;
    v := v || jsonb_build_array(jsonb_build_object('name', 'fn_login_rejects_wrong_password', 'ok', ok));

    comp := allgres_public.fn_login('selftest_admin', 'selftest-admin-pw1');
    v_admin_tok := comp->>'session_token';
    ok := (comp->>'ok')::boolean AND v_admin_tok IS NOT NULL AND (comp->>'role') = 'admin';
    v := v || jsonb_build_array(jsonb_build_object('name', 'fn_login_succeeds_with_correct_password', 'ok', ok));

    comp := allgres_public.fn_login('selftest_user', 'selftest-user-pw1');
    v_user_tok := comp->>'session_token';

    -- An admin reaches any active agent with no assignment row at all; a
    -- regular user is rejected from the same agent until explicitly
    -- assigned, then allowed.
    BEGIN
      PERFORM allgres_private.require_agent_access(v_user_tok, v_acct_agent);
      ok := false;
    EXCEPTION WHEN others THEN
      ok := SQLERRM LIKE '%not assigned%';
    END;
    ok := ok AND (allgres_private.require_agent_access(v_admin_tok, v_acct_agent)).user_id IS NOT NULL;
    v := v || jsonb_build_array(jsonb_build_object('name', 'require_agent_access_admin_bypasses_assignment', 'ok', ok));

    INSERT INTO allgres_private.user_agent_assignments (user_id, agent_id)
    VALUES ((SELECT user_id FROM allgres_private.users WHERE username = 'selftest_user'), v_acct_agent);
    ok := (allgres_private.require_agent_access(v_user_tok, v_acct_agent)).user_id IS NOT NULL;
    v := v || jsonb_build_array(jsonb_build_object('name', 'require_agent_access_allows_assigned_user', 'ok', ok));

    -- fn_messenger_post: a plain post carries no mentioned_agent_id/
    -- session_id; an @mention of an agent the user cannot reach is
    -- rejected the same way chat.send would reject it directly.
    comp := allgres_public.fn_messenger_post(v_user_tok, 'just a plain selftest channel message');
    ok := (comp->>'mentioned_agent_id') IS NULL AND (comp->>'session_id') IS NULL;
    v := v || jsonb_build_array(jsonb_build_object('name', 'messenger_plain_post_has_no_mention', 'ok', ok));

    BEGIN
      PERFORM allgres_public.fn_messenger_post(v_user_tok, '@health_monitor selftest not assigned');
      ok := false;
    EXCEPTION WHEN others THEN
      ok := SQLERRM LIKE '%not assigned%';
    END;
    v := v || jsonb_build_array(jsonb_build_object('name', 'messenger_mention_of_unassigned_agent_rejected', 'ok', ok));

    -- fn_set_my_model: the one thing a regular user may change on their
    -- assigned agent's policy -- never max_steps/permissions/prompt, which
    -- stay behind the operator-only agents.update surface.
    comp := allgres_public.fn_set_my_model(v_user_tok, v_acct_agent, 'selftest_placeholder_provider', 'some-model');
    ok := (comp->>'ok')::boolean
      AND (SELECT llm_config FROM allgres_private.policies WHERE agent_id = v_acct_agent)
        = jsonb_build_object('provider', 'selftest_placeholder_provider', 'model', 'some-model');
    v := v || jsonb_build_array(jsonb_build_object('name', 'fn_set_my_model_updates_assigned_agent', 'ok', ok));

    BEGIN
      PERFORM allgres_public.fn_set_my_model(
        v_user_tok, (SELECT agent_id FROM allgres_private.agents WHERE name = 'health_monitor'), 'x', 'y'
      );
      ok := false;
    EXCEPTION WHEN others THEN
      ok := SQLERRM LIKE '%not assigned%';
    END;
    v := v || jsonb_build_array(jsonb_build_object('name', 'fn_set_my_model_rejects_unassigned_agent', 'ok', ok));

    -- 32. The system agent family (item 32/33): hierarchy, inheritance,
    --     autonomy_level, and the three new consequential actions --
    --     create_agent (creator), propose_fix (fixer), cross-agent
    --     propose_change (self_improve). Uses the real seeded agents (their
    --     names are what fn_submit_result's own-action gates check), never
    --     a scratch stand-in, but every mutation below is either reversed
    --     (autonomy_level reset to admin_approval) or lands on a disposable
    --     scratch target agent created just for this section.
    SELECT agent_id INTO v_root_id FROM allgres_private.agents WHERE name = 'system_root';
    SELECT agent_id INTO v_creator_id FROM allgres_private.agents WHERE name = 'creator';
    SELECT agent_id INTO v_fixer_id FROM allgres_private.agents WHERE name = 'fixer';
    SELECT agent_id INTO v_self_id FROM allgres_private.agents WHERE name = 'self_improve';

    ok := v_root_id IS NOT NULL AND v_creator_id IS NOT NULL AND v_fixer_id IS NOT NULL AND v_self_id IS NOT NULL
      AND (SELECT parent_agent_id FROM allgres_private.agents WHERE agent_id = v_creator_id) = v_root_id
      AND (SELECT parent_agent_id FROM allgres_private.agents WHERE agent_id = v_fixer_id) = v_root_id
      AND (SELECT parent_agent_id FROM allgres_private.agents WHERE agent_id = v_self_id) = v_root_id;
    v := v || jsonb_build_array(jsonb_build_object('name', 'system_agents_seeded_under_one_root', 'ok', ok));

    -- Inheritance: a grant on the root reaches every child through
    -- agent_has_permission/agent_permission_refs, and reaches no unrelated
    -- agent; agent_effective_prompt folds the root's framing text in ahead
    -- of the child's own (root-first, self last).
    PERFORM allgres_public.fn_grant_permission(v_root_id, 'tool', 'selftest_inherited_tool');
    ok := allgres_private.agent_has_permission(v_creator_id, 'tool', 'selftest_inherited_tool')
      AND allgres_private.agent_has_permission(v_fixer_id, 'tool', 'selftest_inherited_tool')
      AND 'selftest_inherited_tool' = ANY(allgres_private.agent_permission_refs(v_self_id, 'tool'))
      AND NOT allgres_private.agent_has_permission(v_acct_agent, 'tool', 'selftest_inherited_tool');
    v := v || jsonb_build_array(jsonb_build_object('name', 'system_agent_inherits_root_permission', 'ok', ok));
    PERFORM allgres_public.fn_revoke_permission(v_root_id, 'tool', 'selftest_inherited_tool');

    ok := allgres_private.agent_effective_prompt(v_creator_id) LIKE '%system agent family%'
      AND allgres_private.agent_effective_prompt(v_creator_id) LIKE '%create_agent%'
      AND allgres_private.agent_effective_prompt(v_acct_agent) NOT LIKE '%system agent family%';
    v := v || jsonb_build_array(jsonb_build_object('name', 'system_agent_prompt_inherits_root_framing', 'ok', ok));

    -- is_system agents may only be edited from an admin session; an
    -- ordinary agent (v_acct_agent) is unaffected and needs no token at
    -- all, exactly as before item 32.
    BEGIN
      PERFORM allgres_private.require_admin_for_system_agent(NULL, v_creator_id);
      ok := false;
    EXCEPTION WHEN others THEN
      ok := SQLERRM LIKE '%not logged in%';
    END;
    BEGIN
      PERFORM allgres_private.require_admin_for_system_agent(v_admin_tok, v_creator_id);
    EXCEPTION WHEN others THEN
      ok := false;
    END;
    BEGIN
      -- No session_token at all, but the target isn't a system agent --
      -- must be a silent no-op, not a "not logged in" rejection.
      PERFORM allgres_private.require_admin_for_system_agent(NULL, v_acct_agent);
    EXCEPTION WHEN others THEN
      ok := false;
    END;
    v := v || jsonb_build_array(jsonb_build_object('name', 'system_agent_edits_require_admin_session', 'ok', ok));

    -- fn_set_agent_autonomy: a friendly rejection for a bad level, and it
    -- actually changes the column.
    BEGIN
      PERFORM allgres_public.fn_set_agent_autonomy(v_creator_id, 'not_a_real_level');
      ok := false;
    EXCEPTION WHEN others THEN
      ok := SQLERRM LIKE '%invalid autonomy_level%';
    END;
    v := v || jsonb_build_array(jsonb_build_object('name', 'set_agent_autonomy_rejects_bad_level', 'ok', ok));

    -- create_agent (creator only): admin_approval queues a create_agent
    -- proposal that fn_decide_proposal turns into a real agent; a
    -- non-creator agent may never call it.
    v_sid := (allgres_public.fn_create_session(v_creator_id, 'selftest creator create_agent')->>'session_id')::uuid;
    SELECT task_id INTO v_tid FROM allgres_private.tasks WHERE session_id = v_sid LIMIT 1;
    PERFORM allgres_public.fn_next_step(v_tid);
    sub := allgres_public.fn_submit_result(v_tid, jsonb_build_object(
      'type', 'llm_response', 'content', '{"action":"create_agent"}',
      'parsed', jsonb_build_object(
        'action', 'create_agent',
        'name', 'selftest_created_by_creator_' || extract(epoch from clock_timestamp())::text,
        'system_prompt', 'selftest-created agent, safe to ignore.',
        'reason', 'selftest'
      )
    ));
    v_proposal := (sub->>'proposal_id')::uuid;
    ok := v_proposal IS NOT NULL AND EXISTS (
      SELECT 1 FROM allgres_private.change_proposals
      WHERE proposal_id = v_proposal AND kind = 'create_agent' AND status = 'pending'
    );
    v := v || jsonb_build_array(jsonb_build_object('name', 'create_agent_queues_a_proposal', 'ok', ok));

    comp := allgres_public.fn_decide_proposal(v_proposal, true);
    ok := comp->>'status' = 'approved'
      AND EXISTS (SELECT 1 FROM allgres_private.agents WHERE agent_id = (comp->'created_agent'->>'agent_id')::uuid);
    v := v || jsonb_build_array(jsonb_build_object('name', 'decide_proposal_creates_the_agent', 'ok', ok));

    v_sid := (allgres_public.fn_create_session(v_agent, 'selftest create_agent not permitted')->>'session_id')::uuid;
    SELECT task_id INTO v_tid FROM allgres_private.tasks WHERE session_id = v_sid LIMIT 1;
    PERFORM allgres_public.fn_next_step(v_tid);
    PERFORM allgres_public.fn_submit_result(v_tid, jsonb_build_object(
      'type', 'llm_response', 'content', '{"action":"create_agent"}',
      'parsed', jsonb_build_object('action', 'create_agent', 'name', 'should_not_exist', 'system_prompt', 'x')
    ));
    ok := EXISTS (
      SELECT 1 FROM allgres_private.execution_logs
      WHERE task_id = v_tid AND role = 'error' AND content->>'reason' = 'create_agent_not_permitted'
    ) AND NOT EXISTS (SELECT 1 FROM allgres_private.agents WHERE name = 'should_not_exist');
    v := v || jsonb_build_array(jsonb_build_object('name', 'create_agent_rejected_from_non_creator', 'ok', ok));

    -- autonomy_level='auto' skips the proposal queue entirely.
    PERFORM allgres_public.fn_set_agent_autonomy(v_creator_id, 'auto');
    v_sid := (allgres_public.fn_create_session(v_creator_id, 'selftest creator auto create_agent')->>'session_id')::uuid;
    SELECT task_id INTO v_tid FROM allgres_private.tasks WHERE session_id = v_sid LIMIT 1;
    PERFORM allgres_public.fn_next_step(v_tid);
    sub := allgres_public.fn_submit_result(v_tid, jsonb_build_object(
      'type', 'llm_response', 'content', '{"action":"create_agent"}',
      'parsed', jsonb_build_object(
        'action', 'create_agent',
        'name', 'selftest_auto_created_' || extract(epoch from clock_timestamp())::text,
        'system_prompt', 'selftest-created agent, safe to ignore.'
      )
    ));
    ok := COALESCE((sub->>'applied')::boolean, false)
      AND EXISTS (SELECT 1 FROM allgres_private.agents WHERE agent_id = (sub->'created_agent'->>'agent_id')::uuid);
    v := v || jsonb_build_array(jsonb_build_object('name', 'autonomy_auto_creates_agent_immediately', 'ok', ok));
    PERFORM allgres_public.fn_set_agent_autonomy(v_creator_id, 'admin_approval');

    -- propose_fix (fixer only): admin_approval queues a fix that
    -- fn_decide_fix applies; only ever against a disposable scratch target,
    -- never a real seeded agent.
    SELECT agent_id INTO v_sys_target FROM allgres_private.agents WHERE name = 'selftest_fix_target';
    IF v_sys_target IS NULL THEN
      v_sys_target := (allgres_public.fn_create_agent('selftest_fix_target')->>'agent_id')::uuid;
    END IF;
    PERFORM allgres_public.fn_set_agent_active(v_sys_target, true);
    v_sid := (allgres_public.fn_create_session(v_fixer_id, 'selftest fixer propose_fix')->>'session_id')::uuid;
    SELECT task_id INTO v_tid FROM allgres_private.tasks WHERE session_id = v_sid LIMIT 1;
    PERFORM allgres_public.fn_next_step(v_tid);
    sub := allgres_public.fn_submit_result(v_tid, jsonb_build_object(
      'type', 'llm_response', 'content', '{"action":"propose_fix"}',
      'parsed', jsonb_build_object(
        'action', 'propose_fix', 'fix_kind', 'deactivate_agent',
        'target_agent_id', v_sys_target::text, 'reason', 'selftest'
      )
    ));
    v_fix_id := (sub->>'fix_id')::uuid;
    ok := v_fix_id IS NOT NULL AND EXISTS (
      SELECT 1 FROM allgres_private.fix_proposals WHERE fix_id = v_fix_id AND status = 'pending'
    ) AND (SELECT is_active FROM allgres_private.agents WHERE agent_id = v_sys_target);
    v := v || jsonb_build_array(jsonb_build_object('name', 'propose_fix_queues_a_fix', 'ok', ok));

    comp := allgres_public.fn_decide_fix(v_fix_id, true);
    ok := comp->>'status' = 'approved'
      AND NOT (SELECT is_active FROM allgres_private.agents WHERE agent_id = v_sys_target);
    v := v || jsonb_build_array(jsonb_build_object('name', 'decide_fix_applies_deactivation', 'ok', ok));

    -- self_improve cross-agent propose_change: only self_improve may set
    -- target_agent_id; the proposal's base_generation and eventual write
    -- land on the target, not on self_improve's own policy.
    PERFORM allgres_public.fn_set_agent_active(v_sys_target, true);
    SELECT generation INTO v_gen FROM allgres_private.policies WHERE agent_id = v_sys_target;
    v_sid := (allgres_public.fn_create_session(v_self_id, 'selftest self_improve cross-agent')->>'session_id')::uuid;
    SELECT task_id INTO v_tid FROM allgres_private.tasks WHERE session_id = v_sid LIMIT 1;
    PERFORM allgres_public.fn_next_step(v_tid);
    sub := allgres_public.fn_submit_result(v_tid, jsonb_build_object(
      'type', 'llm_response', 'content', '{"action":"propose_change"}',
      'parsed', jsonb_build_object(
        'action', 'propose_change', 'target_agent_id', v_sys_target::text,
        'changes', jsonb_build_object('system_prompt', 'selftest cheaper prompt'), 'reason', 'selftest cost'
      )
    ));
    v_proposal := (sub->>'proposal_id')::uuid;
    ok := v_proposal IS NOT NULL AND EXISTS (
      SELECT 1 FROM allgres_private.change_proposals
      WHERE proposal_id = v_proposal AND target_agent_id = v_sys_target AND base_generation = v_gen
    );
    v := v || jsonb_build_array(jsonb_build_object('name', 'self_improve_proposes_against_target_generation', 'ok', ok));

    comp := allgres_public.fn_decide_proposal(v_proposal, true);
    ok := comp->>'status' = 'approved'
      AND (SELECT system_prompt FROM allgres_private.policies WHERE agent_id = v_sys_target) = 'selftest cheaper prompt'
      AND (SELECT system_prompt FROM allgres_private.policies WHERE agent_id = v_self_id) <> 'selftest cheaper prompt';
    v := v || jsonb_build_array(jsonb_build_object('name', 'decide_proposal_writes_to_target_not_proposer', 'ok', ok));

    -- Only self_improve may name a target_agent_id at all.
    v_sid := (allgres_public.fn_create_session(v_agent, 'selftest cross-agent not permitted')->>'session_id')::uuid;
    SELECT task_id INTO v_tid FROM allgres_private.tasks WHERE session_id = v_sid LIMIT 1;
    PERFORM allgres_public.fn_next_step(v_tid);
    PERFORM allgres_public.fn_submit_result(v_tid, jsonb_build_object(
      'type', 'llm_response', 'content', '{"action":"propose_change"}',
      'parsed', jsonb_build_object(
        'action', 'propose_change', 'target_agent_id', v_sys_target::text,
        'changes', jsonb_build_object('system_prompt', 'should not apply')
      )
    ));
    ok := EXISTS (
      SELECT 1 FROM allgres_private.execution_logs
      WHERE task_id = v_tid AND role = 'error' AND content->>'reason' = 'propose_change_cross_agent_not_permitted'
    ) AND (SELECT system_prompt FROM allgres_private.policies WHERE agent_id = v_sys_target) <> 'should not apply';
    v := v || jsonb_build_array(jsonb_build_object('name', 'propose_change_cross_agent_rejected_from_others', 'ok', ok));

    -- Regular-user approval scoping (item 41): an admin sees/decides
    -- everything; a regular user only proposals/fixes whose target is one
    -- of their own assigned agents.
    PERFORM allgres_public.fn_set_agent_active(v_sys_target, false);
    v_fix_id := NULL;
    INSERT INTO allgres_private.fix_proposals (agent_id, task_id, fix_kind, target_agent_id, detail, reason)
    VALUES (v_fixer_id, v_tid, 'deactivate_agent', v_sys_target, '{}'::jsonb, 'selftest scoping')
    RETURNING fix_id INTO v_fix_id;

    ok := allgres_private.visible_agent_ids(v_admin_tok) IS NULL;
    ok := ok AND NOT (v_sys_target = ANY(COALESCE(allgres_private.visible_agent_ids(v_user_tok), ARRAY[]::uuid[])));
    v := v || jsonb_build_array(jsonb_build_object('name', 'visible_agent_ids_scopes_regular_users', 'ok', ok));

    INSERT INTO allgres_private.user_agent_assignments (user_id, agent_id)
    VALUES ((SELECT user_id FROM allgres_private.users WHERE username = 'selftest_user'), v_sys_target)
    ON CONFLICT DO NOTHING;
    ok := v_sys_target = ANY(allgres_private.visible_agent_ids(v_user_tok));
    v := v || jsonb_build_array(jsonb_build_object('name', 'visible_agent_ids_includes_assigned_target', 'ok', ok));

    UPDATE allgres_private.fix_proposals SET status = 'rejected' WHERE fix_id = v_fix_id;
    PERFORM allgres_public.fn_set_agent_active(v_sys_target, true);

    -- 33. session_compactor auto-trigger (item 39): once a session's own
    -- root-level log passes the threshold, fn_next_step queues a real
    -- compaction task; once that task's own remember lands, the original
    -- session's next turn excludes what got summarized and includes the
    -- summary instead. Explicit, distinct created_at values -- inserted
    -- this fast, real turns would never collide, but a tight loop in one
    -- transaction shares plpgsql's single now() otherwise, which would
    -- make every row indistinguishable by time and defeat the cutoff
    -- entirely (caught live while first writing this test).
    v_comp_base := now() - interval '1 hour';
    v_sid := (allgres_public.fn_create_session(v_agent, 'selftest compaction trigger')->>'session_id')::uuid;
    SELECT task_id INTO v_tid FROM allgres_private.tasks WHERE session_id = v_sid LIMIT 1;
    FOR v_i IN 1..70 LOOP
      INSERT INTO allgres_private.execution_logs (task_id, step_number, role, content, created_at)
      VALUES (v_tid, v_i, 'assistant', to_jsonb('selftest turn ' || v_i::text), v_comp_base + (v_i * interval '1 second'));
    END LOOP;
    PERFORM allgres_public.fn_next_step(v_tid);

    SELECT s.session_id INTO v_comp_sid FROM allgres_private.sessions s
    WHERE s.goal = 'session_compact:' || v_sid::text;
    ok := v_comp_sid IS NOT NULL;
    v := v || jsonb_build_array(jsonb_build_object('name', 'compaction_triggers_past_threshold', 'ok', ok));

    SELECT task_id INTO v_comp_tid FROM allgres_private.tasks WHERE session_id = v_comp_sid;
    PERFORM allgres_public.fn_next_step(v_comp_tid);
    PERFORM allgres_public.fn_submit_result(v_comp_tid, jsonb_build_object(
      'type', 'llm_response', 'content', '{}',
      'parsed', jsonb_build_object(
        'action', 'remember', 'content', 'SELFTEST COMPACTION SUMMARY',
        'memory_type', 'episodic', 'importance', 0.6, 'subject_id', v_sid::text
      )
    ));
    PERFORM allgres_public.fn_next_step(v_comp_tid);
    PERFORM allgres_public.fn_submit_result(v_comp_tid, jsonb_build_object(
      'type', 'llm_response', 'content', '{}',
      'parsed', jsonb_build_object('action', 'final_answer', 'answer', 'done')
    ));
    ok := (SELECT compacted_before FROM allgres_private.sessions WHERE session_id = v_sid) IS NOT NULL;
    ok := ok AND (SELECT status FROM allgres_private.sessions WHERE session_id = v_comp_sid) = 'completed';
    v := v || jsonb_build_array(jsonb_build_object('name', 'compaction_task_completes_and_sets_cutoff', 'ok', ok));

    INSERT INTO allgres_private.execution_logs (task_id, step_number, role, content, created_at)
    VALUES (v_tid, 71, 'assistant', to_jsonb('selftest turn 71'::text), v_comp_base + interval '71 seconds');
    spec := allgres_public.fn_next_step(v_tid);
    ok := (spec->'messages')::text LIKE '%SELFTEST COMPACTION SUMMARY%'
      AND (spec->'messages')::text NOT LIKE '%selftest turn 1"%'
      AND (spec->'messages')::text LIKE '%selftest turn 71%';
    v := v || jsonb_build_array(jsonb_build_object('name', 'compacted_session_excludes_old_includes_summary_and_new', 'ok', ok));

    -- 33b. agent_config (agent metadata settings, item: "make every such
    -- parameter configurable, not just compaction"): a generic per-agent
    -- jsonb bag, merged (not replaced) by fn_set_agent_config. agents.update
    -- as a whole is now admin-gated the moment any account exists at all
    -- (require_admin_if_accounts_exist, item 36's own fix for the gap an
    -- outside review found), for a system-agent target *and* an ordinary
    -- one alike -- accounts exist by this point in the run (the 31 section
    -- above created selftest_admin/selftest_user), so both branches here
    -- exercise the accounts-configured behavior, not the bootstrap no-op.
    sub := allgres.dashboard_rpc(jsonb_build_object(
      'action', 'agents.update', 'agent_id', v_sys_target::text,
      'agent_config', jsonb_build_object('probe', 1)
    ));
    ok := (sub->>'ok')::boolean IS DISTINCT FROM true;
    v := v || jsonb_build_array(jsonb_build_object('name', 'agent_config_on_ordinary_agent_now_needs_admin_once_accounts_exist', 'ok', ok));

    sub := allgres.dashboard_rpc(jsonb_build_object(
      'action', 'agents.update', 'agent_id', v_sys_target::text, 'session_token', v_admin_tok,
      'agent_config', jsonb_build_object('probe', 1)
    ));
    ok := COALESCE((sub->>'ok')::boolean, false);
    v := v || jsonb_build_array(jsonb_build_object('name', 'agent_config_on_ordinary_agent_succeeds_with_admin_session', 'ok', ok));

    -- dashboard_rpc never raises to its caller (its own outer EXCEPTION
    -- WHEN OTHERS turns everything into {ok:false,...}), so a rejection
    -- here shows up as ok is-distinct-from-true, not a thrown error.
    sub := allgres.dashboard_rpc(jsonb_build_object(
      'action', 'agents.update', 'agent_id', v_creator_id::text,
      'agent_config', jsonb_build_object('probe', 1)
    ));
    ok := (sub->>'ok')::boolean IS DISTINCT FROM true;
    v := v || jsonb_build_array(jsonb_build_object('name', 'agent_config_on_system_agent_needs_admin', 'ok', ok));

    comp := allgres.dashboard_rpc(jsonb_build_object(
      'action', 'agents.update', 'agent_id', v_creator_id::text, 'session_token', v_admin_tok,
      'agent_config', jsonb_build_object('probe', 2)
    ));
    ok := COALESCE((comp->>'ok')::boolean, false)
      AND (SELECT agent_config FROM allgres_private.agents WHERE agent_id = v_creator_id) = jsonb_build_object('probe', 2);
    v := v || jsonb_build_array(jsonb_build_object('name', 'agent_config_persists_merged_not_replaced', 'ok', ok));

    -- item 36's own fix, spot-checked on a representative few of the
    -- platform-configuration actions that used to have no session check at
    -- all -- the underlying gate (require_admin_if_accounts_exist) is the
    -- exact same one already proven above for agents.update, so this is
    -- deliberately not exhaustive over every action it was also added to
    -- (policy.rollback, permissions.revoke, provider.update, allowlist.
    -- remove, agents.set_autonomy, providers.oauth_start/oauth_callback).
    sub := allgres.dashboard_rpc(jsonb_build_object('action', 'agents.create', 'name', 'selftest_should_not_exist'));
    ok := (sub->>'ok')::boolean IS DISTINCT FROM true
      AND NOT EXISTS (SELECT 1 FROM allgres_private.agents WHERE name = 'selftest_should_not_exist');
    v := v || jsonb_build_array(jsonb_build_object('name', 'agents_create_needs_admin_once_accounts_exist', 'ok', ok));

    sub := allgres.dashboard_rpc(jsonb_build_object(
      'action', 'agents.create', 'session_token', v_admin_tok,
      'name', 'selftest_created_with_admin_' || extract(epoch from clock_timestamp())::text
    ));
    ok := COALESCE((sub->>'ok')::boolean, false);
    v := v || jsonb_build_array(jsonb_build_object('name', 'agents_create_succeeds_with_admin_session', 'ok', ok));

    sub := allgres.dashboard_rpc(jsonb_build_object(
      'action', 'provider.create', 'name', 'selftest_should_not_exist_provider',
      'kind', 'openai_compat', 'base_url', 'https://example.invalid'
    ));
    ok := (sub->>'ok')::boolean IS DISTINCT FROM true
      AND NOT EXISTS (SELECT 1 FROM allgres_private.llm_providers WHERE name = 'selftest_should_not_exist_provider');
    v := v || jsonb_build_array(jsonb_build_object('name', 'provider_create_needs_admin_once_accounts_exist', 'ok', ok));

    sub := allgres.dashboard_rpc(jsonb_build_object(
      'action', 'connections.create', 'name', 'selftest_should_not_exist_connection',
      'base_url', 'https://selftest.invalid'
    ));
    ok := (sub->>'ok')::boolean IS DISTINCT FROM true
      AND NOT EXISTS (SELECT 1 FROM allgres_private.api_connections WHERE name = 'selftest_should_not_exist_connection');
    v := v || jsonb_build_array(jsonb_build_object('name', 'connections_create_needs_admin_once_accounts_exist', 'ok', ok));

    sub := allgres.dashboard_rpc(jsonb_build_object(
      'action', 'procedures.create', 'name', 'selftest_should_not_exist_procedure', 'content', 'x'
    ));
    ok := (sub->>'ok')::boolean IS DISTINCT FROM true
      AND NOT EXISTS (SELECT 1 FROM allgres_private.procedures WHERE name = 'selftest_should_not_exist_procedure');
    v := v || jsonb_build_array(jsonb_build_object('name', 'procedures_create_needs_admin_once_accounts_exist', 'ok', ok));

    sub := allgres.dashboard_rpc(jsonb_build_object(
      'action', 'schedules.create', 'name', 'selftest_should_not_exist_schedule',
      'agent_id', v_agent::text, 'goal', 'x', 'interval_seconds', 3600
    ));
    ok := (sub->>'ok')::boolean IS DISTINCT FROM true
      AND NOT EXISTS (SELECT 1 FROM allgres_private.schedules WHERE name = 'selftest_should_not_exist_schedule');
    v := v || jsonb_build_array(jsonb_build_object('name', 'schedules_create_needs_admin_once_accounts_exist', 'ok', ok));

    sub := allgres.dashboard_rpc(jsonb_build_object(
      'action', 'allowlist.add', 'ref', 'allgres_public.v_should_not_be_added'
    ));
    ok := (sub->>'ok')::boolean IS DISTINCT FROM true
      AND NOT EXISTS (SELECT 1 FROM allgres_private.sql_sandbox_allowlist WHERE resource_ref = 'allgres_public.v_should_not_be_added');
    v := v || jsonb_build_array(jsonb_build_object('name', 'allowlist_add_needs_admin_once_accounts_exist', 'ok', ok));

    sub := allgres.dashboard_rpc(jsonb_build_object(
      'action', 'permissions.grant', 'agent_id', v_sys_target::text, 'type', 'tool', 'ref', 'http_get'
    ));
    -- Not also asserting NOT agent_has_permission(...) here: v_sys_target's
    -- permission state going into this point isn't otherwise pinned down by
    -- this test, so that clause would risk a false negative against a grant
    -- some earlier, unrelated case happened to leave in place. The rejection
    -- itself is what this case is for.
    ok := (sub->>'ok')::boolean IS DISTINCT FROM true;
    v := v || jsonb_build_array(jsonb_build_object('name', 'permissions_grant_needs_admin_once_accounts_exist', 'ok', ok));

    -- Same gate, for the new bulk provider/model action: touches every
    -- active agent at once, so it needs the admin session at least as much
    -- as any single-agent action above does.
    sub := allgres.dashboard_rpc(jsonb_build_object(
      'action', 'agents.bulk_set_model', 'provider', 'analyst', 'model', 'should-not-apply'
    ));
    ok := (sub->>'ok')::boolean IS DISTINCT FROM true;
    v := v || jsonb_build_array(jsonb_build_object('name', 'bulk_set_model_needs_admin_once_accounts_exist', 'ok', ok));

    -- run/sessions.cancel/sessions.continue/sessions.list/sessions.get
    -- (roadmap item 1's own named gap): before this fix these five had no
    -- session check whatsoever, at any account state -- any caller holding
    -- the shared dashboard token could run, cancel, or continue a session
    -- against, or simply list/read, any agent_id/session_id in the whole
    -- database. Spot-checked here the same way the rest of this block
    -- already is: not exhaustive, but exercising both halves item 1 asked
    -- for. A fresh, dedicated agent for the "not assigned" cases -- not
    -- v_sys_target, which visible_agent_ids_includes_assigned_target above
    -- deliberately assigns to selftest_user already, and not v_acct_agent,
    -- which selftest_user genuinely is assigned to.
    DELETE FROM allgres_private.agents WHERE name = 'selftest_unassigned_target';
    v_new_agent := (allgres_public.fn_create_agent('selftest_unassigned_target')->>'agent_id')::uuid;

    sub := allgres.dashboard_rpc(jsonb_build_object(
      'action', 'run', 'agent_id', v_new_agent::text, 'goal', 'selftest should not run'
    ));
    ok := (sub->>'ok')::boolean IS DISTINCT FROM true;
    v := v || jsonb_build_array(jsonb_build_object('name', 'run_rejects_no_session_token_once_accounts_exist', 'ok', ok));

    -- Logged in, but as a user with no assignment to this specific agent --
    -- the per-agent assignment check itself, not just "any session token
    -- at all".
    sub := allgres.dashboard_rpc(jsonb_build_object(
      'action', 'run', 'agent_id', v_new_agent::text, 'goal', 'selftest should not run',
      'session_token', v_user_tok
    ));
    ok := (sub->>'ok')::boolean IS DISTINCT FROM true;
    v := v || jsonb_build_array(jsonb_build_object('name', 'run_rejects_user_not_assigned_to_this_agent', 'ok', ok));
    DELETE FROM allgres_private.agents WHERE agent_id = v_new_agent;

    -- Exercised on the gate function directly for the two success cases,
    -- not through a real `run` -- v_acct_agent must stay deletable at this
    -- function's own final cleanup below (no ON DELETE CASCADE from
    -- sessions/tasks/execution_logs to agents, and execution_logs' own
    -- append-only trigger means a real session/task chain, once created,
    -- can never be removed again -- confirmed live: creating one here the
    -- first time broke that cleanup's own DELETE with a FK violation).
    -- v_sys_target has no such constraint (never deleted, sessions against
    -- it already accumulate forever elsewhere in this file), so the two
    -- rejection cases above still go through the real dashboard_rpc action.
    BEGIN
      PERFORM allgres_private.require_agent_access_if_accounts_exist(v_user_tok, v_acct_agent);
      ok := true;
    EXCEPTION WHEN others THEN
      ok := false;
    END;
    v := v || jsonb_build_array(jsonb_build_object('name', 'run_allows_assigned_user', 'ok', ok));

    BEGIN
      PERFORM allgres_private.require_agent_access_if_accounts_exist(v_admin_tok, v_sys_target);
      ok := true;
    EXCEPTION WHEN others THEN
      ok := false;
    END;
    v := v || jsonb_build_array(jsonb_build_object('name', 'run_allows_admin_on_any_agent', 'ok', ok));

    v_sid := (allgres_public.fn_create_session(v_sys_target, 'selftest session scoping target')->>'session_id')::uuid;
    sub := allgres.dashboard_rpc(jsonb_build_object(
      'action', 'sessions.continue', 'session_id', v_sid::text, 'message', 'should not be allowed',
      'session_token', v_user_tok
    ));
    ok := (sub->>'ok')::boolean IS DISTINCT FROM true;
    v := v || jsonb_build_array(jsonb_build_object('name', 'sessions_continue_rejects_unassigned_user', 'ok', ok));

    sub := allgres.dashboard_rpc(jsonb_build_object(
      'action', 'sessions.cancel', 'session_id', v_sid::text, 'reason', 'selftest cleanup',
      'session_token', v_admin_tok
    ));
    ok := COALESCE((sub->>'ok')::boolean, false);
    v := v || jsonb_build_array(jsonb_build_object('name', 'sessions_cancel_allows_admin', 'ok', ok));

    sub := allgres.dashboard_rpc(jsonb_build_object('action', 'sessions.list'));
    ok := (sub->>'ok')::boolean IS DISTINCT FROM true;
    v := v || jsonb_build_array(jsonb_build_object('name', 'sessions_list_needs_admin_once_accounts_exist', 'ok', ok));

    sub := allgres.dashboard_rpc(jsonb_build_object('action', 'sessions.get', 'session_id', v_sid::text));
    ok := (sub->>'ok')::boolean IS DISTINCT FROM true;
    v := v || jsonb_build_array(jsonb_build_object('name', 'sessions_get_needs_admin_once_accounts_exist', 'ok', ok));

    -- tasks.list/logs.list (same admin-only audience, reached through a
    -- Rust GET route whose session_token comes from a header instead of a
    -- request body -- api_route's own comment explains why not a query
    -- string). Exercised at the dashboard_rpc level, same as the pair
    -- above: the header-vs-body plumbing is Rust's own concern, already
    -- covered by that file's unit tests.
    sub := allgres.dashboard_rpc(jsonb_build_object('action', 'tasks.list'));
    ok := (sub->>'ok')::boolean IS DISTINCT FROM true;
    v := v || jsonb_build_array(jsonb_build_object('name', 'tasks_list_needs_admin_once_accounts_exist', 'ok', ok));

    sub := allgres.dashboard_rpc(jsonb_build_object('action', 'logs.list'));
    ok := (sub->>'ok')::boolean IS DISTINCT FROM true;
    v := v || jsonb_build_array(jsonb_build_object('name', 'logs_list_needs_admin_once_accounts_exist', 'ok', ok));

    -- Setting a key to JSON null clears it back to the reader's own coded
    -- default rather than leaving a stray {"probe":2} on a real seeded
    -- agent.
    PERFORM allgres.dashboard_rpc(jsonb_build_object(
      'action', 'agents.update', 'agent_id', v_creator_id::text, 'session_token', v_admin_tok,
      'agent_config', jsonb_build_object('probe', NULL)
    ));
    ok := (SELECT agent_config FROM allgres_private.agents WHERE agent_id = v_creator_id) = '{}'::jsonb;
    v := v || jsonb_build_array(jsonb_build_object('name', 'agent_config_null_value_clears_the_key', 'ok', ok));

    -- A known-integer key must fail fast at set time on a value fn_next_step
    -- would otherwise only choke on much later, mid-turn -- a non-numeric
    -- string, and a numeric value outside its sane range.
    BEGIN
      PERFORM allgres_public.fn_set_agent_config(
        v_creator_id, jsonb_build_object('compaction_threshold', 'not_a_number')
      );
      ok := false;
    EXCEPTION WHEN others THEN
      ok := SQLERRM LIKE '%must be a number%';
    END;
    v := v || jsonb_build_array(jsonb_build_object('name', 'agent_config_rejects_non_numeric_known_key', 'ok', ok));

    BEGIN
      PERFORM allgres_public.fn_set_agent_config(
        v_creator_id, jsonb_build_object('min_mentions_to_route', 0)
      );
      ok := false;
    EXCEPTION WHEN others THEN
      ok := SQLERRM LIKE '%must be between%';
    END;
    v := v || jsonb_build_array(jsonb_build_object('name', 'agent_config_rejects_out_of_range_known_key', 'ok', ok));

    -- Neither rejection above left a partial write behind, and an unknown
    -- key (not one of the file's own known-integer readers) still passes
    -- through untouched -- the whole point of this staying a generic bag.
    ok := (SELECT agent_config FROM allgres_private.agents WHERE agent_id = v_creator_id) = '{}'::jsonb;
    v := v || jsonb_build_array(jsonb_build_object('name', 'agent_config_rejected_value_not_persisted', 'ok', ok));

    PERFORM allgres_public.fn_set_agent_config(v_creator_id, jsonb_build_object('some_future_string_tunable', 'anything goes'));
    ok := (SELECT agent_config FROM allgres_private.agents WHERE agent_id = v_creator_id) = jsonb_build_object('some_future_string_tunable', 'anything goes');
    v := v || jsonb_build_array(jsonb_build_object('name', 'agent_config_unknown_key_stays_unvalidated', 'ok', ok));
    PERFORM allgres_public.fn_set_agent_config(v_creator_id, jsonb_build_object('some_future_string_tunable', NULL));

    -- 33c. session_compactor's threshold/keep_recent are read from its own
    -- agent_config, not hardcoded -- a lower threshold set here must
    -- actually change when compaction fires, and is reset back to the
    -- coded default afterward so real usage of this seeded agent is
    -- unaffected by having run fn_selftest.
    PERFORM allgres_public.fn_set_agent_config(
      (SELECT agent_id FROM allgres_private.agents WHERE name = 'session_compactor'),
      jsonb_build_object('compaction_threshold', 5, 'compaction_keep_recent', 2)
    );
    v_comp_base := now() - interval '1 hour';
    v_sid := (allgres_public.fn_create_session(v_agent, 'selftest configurable compaction threshold')->>'session_id')::uuid;
    SELECT task_id INTO v_tid FROM allgres_private.tasks WHERE session_id = v_sid LIMIT 1;
    FOR v_i IN 1..8 LOOP
      INSERT INTO allgres_private.execution_logs (task_id, step_number, role, content, created_at)
      VALUES (v_tid, v_i, 'assistant', to_jsonb('selftest low-threshold turn ' || v_i::text), v_comp_base + (v_i * interval '1 second'));
    END LOOP;
    PERFORM allgres_public.fn_next_step(v_tid);
    ok := EXISTS (
      SELECT 1 FROM allgres_private.sessions WHERE goal = 'session_compact:' || v_sid::text
    );
    v := v || jsonb_build_array(jsonb_build_object('name', 'configurable_compaction_threshold_fires_early', 'ok', ok));
    PERFORM allgres_public.fn_set_agent_config(
      (SELECT agent_id FROM allgres_private.agents WHERE name = 'session_compactor'),
      jsonb_build_object('compaction_threshold', NULL, 'compaction_keep_recent', NULL)
    );

    -- 33d. compaction_keep_recent = 0 ("keep nothing, compact everything")
    -- is a valid value within its own documented range (0 to 1000000) --
    -- an unclamped OFFSET (c_keep_recent - 1) used to send PostgreSQL a
    -- literal OFFSET -1 the moment it was set, a hard error that aborted
    -- the whole compaction check rather than compacting everything the
    -- way 0 actually means.
    PERFORM allgres_public.fn_set_agent_config(
      (SELECT agent_id FROM allgres_private.agents WHERE name = 'session_compactor'),
      jsonb_build_object('compaction_threshold', 5, 'compaction_keep_recent', 0)
    );
    v_comp_base := now() - interval '1 hour';
    v_sid := (allgres_public.fn_create_session(v_agent, 'selftest keep_recent zero')->>'session_id')::uuid;
    SELECT task_id INTO v_tid FROM allgres_private.tasks WHERE session_id = v_sid LIMIT 1;
    FOR v_i IN 1..8 LOOP
      INSERT INTO allgres_private.execution_logs (task_id, step_number, role, content, created_at)
      VALUES (v_tid, v_i, 'assistant', to_jsonb('selftest keep_recent zero turn ' || v_i::text), v_comp_base + (v_i * interval '1 second'));
    END LOOP;
    BEGIN
      PERFORM allgres_public.fn_next_step(v_tid);
      ok := true;
    EXCEPTION WHEN others THEN
      ok := false;
    END;
    ok := ok AND COALESCE((
      SELECT (t.input->>'compact_cutoff')::timestamptz > v_comp_base + interval '8 seconds'
      FROM allgres_private.tasks t
      JOIN allgres_private.sessions s ON s.session_id = t.session_id
      WHERE s.goal = 'session_compact:' || v_sid::text
    ), false);
    v := v || jsonb_build_array(jsonb_build_object('name', 'compaction_keep_recent_zero_compacts_everything_without_crashing', 'ok', ok));
    PERFORM allgres_public.fn_set_agent_config(
      (SELECT agent_id FROM allgres_private.agents WHERE name = 'session_compactor'),
      jsonb_build_object('compaction_threshold', NULL, 'compaction_keep_recent', NULL)
    );

    -- 34. orchestrator multi-mention (item 40): a message mentioning more
    -- than one agent is delivered to all of them, in text order, and
    -- queues a real (if advisory-only in this pass) opinion task for
    -- orchestrator. Never v_acct_agent, which fn_chat_send would leave a
    -- session referencing -- the same FK this whole section is careful to
    -- avoid for v_acct_agent everywhere else, so it stays deletable at the
    -- very end; v_sys_target and a second disposable target are used
    -- instead, both fine to accumulate sessions on forever.
    SELECT agent_id INTO v_mention_target FROM allgres_private.agents WHERE name = 'selftest_mention_target';
    IF v_mention_target IS NULL THEN
      v_mention_target := (allgres_public.fn_create_agent('selftest_mention_target')->>'agent_id')::uuid;
    END IF;
    INSERT INTO allgres_private.user_agent_assignments (user_id, agent_id)
    VALUES ((SELECT user_id FROM allgres_private.users WHERE username = 'selftest_user'), v_mention_target)
    ON CONFLICT DO NOTHING;

    r := allgres_public.fn_messenger_post(v_user_tok, '@selftest_fix_target @selftest_mention_target selftest multi-mention');
    v_mentioned_ids := ARRAY(SELECT jsonb_array_elements_text(r->'mentioned_agent_ids'))::uuid[];
    ok := array_length(v_mentioned_ids, 1) = 2
      AND v_mentioned_ids[1] = v_sys_target
      AND v_mentioned_ids[2] = v_mention_target;
    v := v || jsonb_build_array(jsonb_build_object('name', 'messenger_multi_mention_delivers_to_all_in_text_order', 'ok', ok));

    v_msg_id := (r->>'message_id')::uuid;
    SELECT agent_id INTO v_orchestrator_id FROM allgres_private.agents WHERE name = 'orchestrator';
    ok := EXISTS (
      SELECT 1 FROM allgres_private.sessions
      WHERE agent_id = v_orchestrator_id AND goal = 'messenger_route:' || v_msg_id::text
    );
    v := v || jsonb_build_array(jsonb_build_object('name', 'multi_mention_queues_orchestrator_opinion', 'ok', ok));

    -- 34b. orchestrator's min_mentions_to_route (agent metadata config,
    -- same as session_compactor's thresholds): raising it must actually
    -- suppress routing for a mention count that used to qualify, and
    -- clearing it back must restore the default (>= 2) behavior --
    -- confirms this reads live from agent_config on every post, not once
    -- at startup. Each re-mention below reuses the same two chat sessions
    -- the multi-mention test above just opened, and fn_continue_session
    -- refuses a second message while the last root task is still queued --
    -- so the loop clears whatever the previous post left in flight first.
    FOR v_tid IN
      SELECT t.task_id FROM allgres_private.tasks t
      JOIN allgres_private.user_agent_chat_sessions cs ON cs.session_id = t.session_id
      WHERE cs.user_id = (SELECT user_id FROM allgres_private.users WHERE username = 'selftest_user')
        AND cs.agent_id IN (v_sys_target, v_mention_target)
        AND t.status IN ('queued', 'running', 'waiting_human')
    LOOP
      PERFORM allgres_public.fn_next_step(v_tid);
      PERFORM allgres_public.fn_submit_result(v_tid, jsonb_build_object(
        'type', 'llm_response', 'content', '{"action":"final_answer","answer":"ok"}',
        'parsed', jsonb_build_object('action', 'final_answer', 'answer', 'ok')
      ));
    END LOOP;
    PERFORM allgres_public.fn_set_agent_config(v_orchestrator_id, jsonb_build_object('min_mentions_to_route', 3));
    r := allgres_public.fn_messenger_post(v_user_tok, '@selftest_fix_target @selftest_mention_target selftest raised min-mentions');
    ok := NOT EXISTS (
      SELECT 1 FROM allgres_private.sessions
      WHERE agent_id = v_orchestrator_id AND goal = 'messenger_route:' || (r->>'message_id')
    );
    v := v || jsonb_build_array(jsonb_build_object('name', 'raised_min_mentions_suppresses_routing', 'ok', ok));

    FOR v_tid IN
      SELECT t.task_id FROM allgres_private.tasks t
      JOIN allgres_private.user_agent_chat_sessions cs ON cs.session_id = t.session_id
      WHERE cs.user_id = (SELECT user_id FROM allgres_private.users WHERE username = 'selftest_user')
        AND cs.agent_id IN (v_sys_target, v_mention_target)
        AND t.status IN ('queued', 'running', 'waiting_human')
    LOOP
      PERFORM allgres_public.fn_next_step(v_tid);
      PERFORM allgres_public.fn_submit_result(v_tid, jsonb_build_object(
        'type', 'llm_response', 'content', '{"action":"final_answer","answer":"ok"}',
        'parsed', jsonb_build_object('action', 'final_answer', 'answer', 'ok')
      ));
    END LOOP;
    PERFORM allgres_public.fn_set_agent_config(v_orchestrator_id, jsonb_build_object('min_mentions_to_route', NULL));
    r := allgres_public.fn_messenger_post(v_user_tok, '@selftest_fix_target @selftest_mention_target selftest reset min-mentions');
    ok := EXISTS (
      SELECT 1 FROM allgres_private.sessions
      WHERE agent_id = v_orchestrator_id AND goal = 'messenger_route:' || (r->>'message_id')
    );
    v := v || jsonb_build_array(jsonb_build_object('name', 'clearing_min_mentions_restores_default_routing', 'ok', ok));

    -- 35. Project chat mode (item 42): a project bound to an agent, with a
    -- preset_prompt appended after that agent's own effective prompt.
    -- Bound to v_sys_target, never v_acct_agent -- fn_project_chat_send
    -- creates a real session against the project's agent, the same FK
    -- concern as every other use of v_acct_agent in this section.
    SELECT project_id INTO v_project FROM allgres_private.projects WHERE name = 'selftest_project';
    IF v_project IS NULL THEN
      v_project := (allgres_public.fn_create_project(
        'selftest_project', 'selftest', v_sys_target, 'Selftest preset: answer only in haiku.'
      )->>'project_id')::uuid;
    ELSE
      PERFORM allgres_public.fn_set_project_config(v_project, v_sys_target, 'Selftest preset: answer only in haiku.');
      PERFORM allgres_public.fn_set_project_active(v_project, true);
    END IF;

    r := allgres_public.fn_project_chat_send(v_user_tok, v_project, 'selftest project chat turn one');
    v_sid := (r->>'session_id')::uuid;
    ok := v_sid IS NOT NULL AND (SELECT project_id FROM allgres_private.sessions WHERE session_id = v_sid) = v_project;
    v := v || jsonb_build_array(jsonb_build_object('name', 'project_chat_send_creates_project_scoped_session', 'ok', ok));

    SELECT task_id INTO v_tid FROM allgres_private.tasks WHERE session_id = v_sid LIMIT 1;
    spec := allgres_public.fn_next_step(v_tid);
    ok := (spec->'messages'->0->>'content') LIKE '%Selftest preset: answer only in haiku%';
    v := v || jsonb_build_array(jsonb_build_object('name', 'project_preset_prompt_reaches_the_model', 'ok', ok));

    r := allgres_public.fn_project_chat_history(v_user_tok, v_project);
    ok := (r->>'session_id')::uuid = v_sid AND (r->'messages')::text LIKE '%selftest project chat turn one%';
    v := v || jsonb_build_array(jsonb_build_object('name', 'project_chat_history_reads_back_the_session', 'ok', ok));

    -- 35b. assignments.for_agent/assignments.toggle (item 32's own "grant
    -- access from the Agents page too, not only from Users"): the reverse
    -- direction of assignments.list/assignments.set, admin-only, one
    -- (user, agent) pair at a time rather than replacing a user's whole list.
    sub := allgres.dashboard_rpc(jsonb_build_object(
      'action', 'assignments.toggle', 'session_token', v_admin_tok,
      'user_id', (SELECT user_id FROM allgres_private.users WHERE username = 'selftest_user'),
      'agent_id', v_sys_target, 'assigned', true
    ));
    ok := COALESCE((sub->>'ok')::boolean, false);
    sub := allgres.dashboard_rpc(jsonb_build_object(
      'action', 'assignments.for_agent', 'session_token', v_admin_tok, 'agent_id', v_sys_target
    ));
    ok := ok AND (sub->'user_ids')::text LIKE '%'||(SELECT user_id FROM allgres_private.users WHERE username = 'selftest_user')::text||'%';
    v := v || jsonb_build_array(jsonb_build_object('name', 'assignments_toggle_and_for_agent_admin_only', 'ok', ok));

    sub := allgres.dashboard_rpc(jsonb_build_object(
      'action', 'assignments.toggle', 'session_token', v_user_tok,
      'user_id', (SELECT user_id FROM allgres_private.users WHERE username = 'selftest_user'),
      'agent_id', v_sys_target, 'assigned', false
    ));
    ok := (sub->>'ok')::boolean IS DISTINCT FROM true;
    v := v || jsonb_build_array(jsonb_build_object('name', 'assignments_toggle_rejects_non_admin', 'ok', ok));

    -- The rejected toggle above leaves the earlier assign(true) call's own
    -- effect in place (it was rejected before doing anything, not
    -- reverted) -- undo it via the admin session that can actually do so,
    -- so selftest_user's assignment to v_sys_target doesn't silently
    -- persist past this run into the next one. v_sys_target itself is
    -- never deleted between runs, so an unreverted assignment here used to
    -- accumulate forever, quietly invalidating any later test (in this run
    -- or the next) that assumes selftest_user is *not* assigned to it.
    PERFORM allgres.dashboard_rpc(jsonb_build_object(
      'action', 'assignments.toggle', 'session_token', v_admin_tok,
      'user_id', (SELECT user_id FROM allgres_private.users WHERE username = 'selftest_user'),
      'agent_id', v_sys_target, 'assigned', false
    ));

    -- fn_set_user_active/fn_set_user_role/fn_set_user_assignments/
    -- fn_set_user_assignment: these four used to be the only mutations
    -- dashboard_rpc exposed with no SQL entry point of their own (their real
    -- INSERT/UPDATE/DELETE lived only inline inside the users.set_active/
    -- set_role/assignments.set/assignments.toggle branches themselves,
    -- reachable only through the jsonb RPC envelope) -- called directly
    -- here, with no dashboard_rpc/jsonb involved at all, on a throwaway user
    -- of their own rather than selftest_user/selftest_admin (many tests
    -- below this point still depend on those two keeping their original
    -- active/role state).
    DELETE FROM allgres_private.users WHERE username = 'selftest_direct_sql_user';
    v_direct_sql_user := (allgres_public.fn_create_user('selftest_direct_sql_user', 'selftest-direct-pw1', 'user')->>'user_id')::uuid;

    PERFORM allgres_public.fn_set_user_active(v_direct_sql_user, false);
    ok := NOT (SELECT is_active FROM allgres_private.users WHERE user_id = v_direct_sql_user);
    v := v || jsonb_build_array(jsonb_build_object('name', 'fn_set_user_active_direct_sql_call', 'ok', ok));
    PERFORM allgres_public.fn_set_user_active(v_direct_sql_user, true);

    PERFORM allgres_public.fn_set_user_role(v_direct_sql_user, 'admin');
    ok := (SELECT role FROM allgres_private.users WHERE user_id = v_direct_sql_user) = 'admin';
    v := v || jsonb_build_array(jsonb_build_object('name', 'fn_set_user_role_direct_sql_call', 'ok', ok));
    PERFORM allgres_public.fn_set_user_role(v_direct_sql_user, 'user');

    BEGIN
      PERFORM allgres_public.fn_set_user_role(v_direct_sql_user, 'not_a_real_role');
      ok := false;
    EXCEPTION WHEN others THEN
      ok := true;
    END;
    v := v || jsonb_build_array(jsonb_build_object('name', 'fn_set_user_role_rejects_unknown_role', 'ok', ok));

    PERFORM allgres_public.fn_set_user_assignments(v_direct_sql_user, ARRAY[v_sys_target]);
    ok := (SELECT array_agg(agent_id) FROM allgres_private.user_agent_assignments WHERE user_id = v_direct_sql_user) = ARRAY[v_sys_target];
    v := v || jsonb_build_array(jsonb_build_object('name', 'fn_set_user_assignments_direct_sql_call', 'ok', ok));
    -- A real full-replace-with-empty, the same edge case an empty
    -- agent_ids array from the UI hits -- must clear, not leave stale rows.
    PERFORM allgres_public.fn_set_user_assignments(v_direct_sql_user, ARRAY[]::uuid[]);
    ok := NOT EXISTS (SELECT 1 FROM allgres_private.user_agent_assignments WHERE user_id = v_direct_sql_user);
    v := v || jsonb_build_array(jsonb_build_object('name', 'fn_set_user_assignments_empty_array_clears', 'ok', ok));

    PERFORM allgres_public.fn_set_user_assignment(v_direct_sql_user, v_sys_target, true);
    ok := EXISTS (SELECT 1 FROM allgres_private.user_agent_assignments WHERE user_id = v_direct_sql_user AND agent_id = v_sys_target);
    PERFORM allgres_public.fn_set_user_assignment(v_direct_sql_user, v_sys_target, false);
    ok := ok AND NOT EXISTS (SELECT 1 FROM allgres_private.user_agent_assignments WHERE user_id = v_direct_sql_user AND agent_id = v_sys_target);
    v := v || jsonb_build_array(jsonb_build_object('name', 'fn_set_user_assignment_direct_sql_call', 'ok', ok));

    DELETE FROM allgres_private.web_sessions WHERE user_id = v_direct_sql_user;
    DELETE FROM allgres_private.users WHERE user_id = v_direct_sql_user;

    -- Roadmap item 3: history.search unions three sources -- an agent's own
    -- explicit remember()s, a task's role='error' log entries (failures),
    -- and a completed session's final_answer (decisions) -- and links every
    -- result back to the session/task it came from. Scoped the same way
    -- proposals.list/fixes.list are, and the same fix now applied to
    -- memories.list below: it had no v_scope check at all before this, the
    -- one listing on this table that hadn't picked up that pattern.
    DELETE FROM allgres_private.agent_memories WHERE agent_id = v_sys_target;
    PERFORM allgres_private.write_memory(
      v_sys_target, 'selftest history marker mem 9f3a', 'semantic', '0.8', NULL, NULL
    );

    sub := allgres.dashboard_rpc(jsonb_build_object(
      'action', 'history.search', 'session_token', v_admin_tok, 'query', 'history marker mem 9f3a'
    ));
    ok := (sub->'results')::text LIKE '%history marker mem 9f3a%'
      AND (sub->'results')::text LIKE '%"source": "memory"%';
    v := v || jsonb_build_array(jsonb_build_object('name', 'history_search_finds_a_memory_as_admin', 'ok', ok));

    sub := allgres.dashboard_rpc(jsonb_build_object('action', 'history.search', 'session_token', v_admin_tok, 'query', ''));
    ok := (sub->>'ok')::boolean IS DISTINCT FROM true;
    v := v || jsonb_build_array(jsonb_build_object('name', 'history_search_requires_query', 'ok', ok));

    -- v_sys_target is unassigned again right above this point -- a regular
    -- user must see neither its memory nor it via memories.list.
    sub := allgres.dashboard_rpc(jsonb_build_object(
      'action', 'history.search', 'session_token', v_user_tok, 'query', 'history marker mem 9f3a'
    ));
    ok := COALESCE((sub->>'ok')::boolean, false) AND sub->'results' = '[]'::jsonb;
    r := allgres.dashboard_rpc(jsonb_build_object(
      'action', 'memories.list', 'session_token', v_user_tok, 'agent_id', v_sys_target::text
    ));
    ok := ok AND r->'memories' = '[]'::jsonb;
    v := v || jsonb_build_array(jsonb_build_object('name', 'history_and_memories_hide_unassigned_agent_from_regular_user', 'ok', ok));

    PERFORM allgres.dashboard_rpc(jsonb_build_object(
      'action', 'assignments.toggle', 'session_token', v_admin_tok,
      'user_id', (SELECT user_id FROM allgres_private.users WHERE username = 'selftest_user'),
      'agent_id', v_sys_target, 'assigned', true
    ));
    sub := allgres.dashboard_rpc(jsonb_build_object(
      'action', 'history.search', 'session_token', v_user_tok, 'query', 'history marker mem 9f3a'
    ));
    r := allgres.dashboard_rpc(jsonb_build_object(
      'action', 'memories.list', 'session_token', v_user_tok, 'agent_id', v_sys_target::text
    ));
    ok := (sub->'results')::text LIKE '%history marker mem 9f3a%'
      AND (r->'memories')::text LIKE '%history marker mem 9f3a%';
    v := v || jsonb_build_array(jsonb_build_object('name', 'history_and_memories_show_assigned_agent_to_regular_user', 'ok', ok));

    -- Restored to unassigned so a later run (or a later test in this same
    -- run) that assumes v_sys_target starts unassigned still holds.
    PERFORM allgres.dashboard_rpc(jsonb_build_object(
      'action', 'assignments.toggle', 'session_token', v_admin_tok,
      'user_id', (SELECT user_id FROM allgres_private.users WHERE username = 'selftest_user'),
      'agent_id', v_sys_target, 'assigned', false
    ));
    DELETE FROM allgres_private.agent_memories WHERE agent_id = v_sys_target;

    -- A failure/decision fixture with a goal that does NOT start with
    -- 'selftest' -- that prefix is what every operator-facing listing
    -- (history.search included) hides on purpose (selftest_fixtures_hidden_
    -- not_deleted, above), so a 'selftest ...' goal here would make its own
    -- matches invisible to the very search being tested. Reused by goal
    -- across reruns, the same way selftest_httpreq_agent is reused by name,
    -- since its real execution_logs can never be hard-deleted afterward.
    SELECT s.session_id, t.task_id INTO v_sid, v_tid
    FROM allgres_private.sessions s
    JOIN allgres_private.tasks t ON t.session_id = s.session_id
    WHERE s.agent_id = v_agent AND s.goal = 'history_search_test_fixture'
    LIMIT 1;
    IF v_sid IS NULL THEN
      v_sid := (allgres_public.fn_create_session(v_agent, 'history_search_test_fixture')->>'session_id')::uuid;
      SELECT task_id INTO v_tid FROM allgres_private.tasks WHERE session_id = v_sid LIMIT 1;
      PERFORM allgres_public.fn_next_step(v_tid);
      PERFORM allgres_public.fn_submit_result(v_tid, jsonb_build_object(
        'type', 'llm_response', 'content', '{}',
        'parsed', jsonb_build_object('action', 'final_answer', 'answer', 'selftest history marker decision 7c2e')
      ));
      PERFORM allgres_private.append_log(v_tid, 999, 'error', jsonb_build_object('message', 'selftest history marker failure 4b1d'));
    END IF;

    sub := allgres.dashboard_rpc(jsonb_build_object(
      'action', 'history.search', 'session_token', v_admin_tok, 'query', 'history marker decision 7c2e'
    ));
    ok := (sub->'results')::text LIKE '%"source": "decision"%'
      AND (sub->'results')::text LIKE '%history marker decision 7c2e%';
    v := v || jsonb_build_array(jsonb_build_object('name', 'history_search_finds_a_session_decision', 'ok', ok));

    sub := allgres.dashboard_rpc(jsonb_build_object(
      'action', 'history.search', 'session_token', v_admin_tok, 'query', 'history marker failure 4b1d'
    ));
    ok := (sub->'results')::text LIKE '%"source": "failure"%'
      AND (sub->'results')::text LIKE '%history marker failure 4b1d%';
    v := v || jsonb_build_array(jsonb_build_object('name', 'history_search_finds_a_task_failure', 'ok', ok));

    -- 36. Overview's cluster monitoring (item 44): PostgreSQL version and
    -- this cluster's own pg_stat_activity counts (SQL-visible) alongside
    -- native_host_stats (OS-level CPU load/memory, not SQL-visible at
    -- all). Values themselves are host-dependent -- this only checks the
    -- shape is present, not any particular number.
    r := allgres.dashboard_rpc(jsonb_build_object('action', 'overview'));
    ok := (r->>'pg_version') IS NOT NULL
      AND (r->'db_sessions'->>'total')::int >= 1
      AND (r->'host'->'cpu_count') IS NOT NULL;
    v := v || jsonb_build_array(jsonb_build_object('name', 'overview_reports_pg_version_db_sessions_and_host_stats', 'ok', ok));

    -- fn_logout is idempotent, and a logged-out token no longer resolves.
    PERFORM allgres_public.fn_logout(v_user_tok);
    ok := allgres_private.session_user(v_user_tok) IS NULL;
    PERFORM allgres_public.fn_logout(v_user_tok);
    v := v || jsonb_build_array(jsonb_build_object('name', 'fn_logout_invalidates_token_and_is_idempotent', 'ok', ok));

    PERFORM allgres_public.fn_logout(v_admin_tok);
  END IF;

  DELETE FROM allgres_private.web_sessions WHERE user_id IN (
    SELECT user_id FROM allgres_private.users WHERE username IN ('selftest_admin', 'selftest_user')
  );
  DELETE FROM allgres_private.user_agent_assignments WHERE agent_id = v_acct_agent;
  DELETE FROM allgres_private.users WHERE username IN ('selftest_admin', 'selftest_user');
  DELETE FROM allgres_private.policies WHERE agent_id = v_acct_agent;
  DELETE FROM allgres_private.agents WHERE agent_id = v_acct_agent;

  -- selftest_cleanup cannot delete these rows outright -- execution_logs'
  -- append-only trigger rejects DELETE the same as UPDATE, for anyone -- so
  -- an operator must never see them a different way: every operator-facing
  -- listing/count filters out goal LIKE 'selftest%' instead. A still-open
  -- task left behind (as if selftest crashed mid-run) is also terminated,
  -- not left to look "running" forever.
  v_sid := (allgres_public.fn_create_session(v_agent, 'selftest cleanup probe')->>'session_id')::uuid;
  SELECT task_id INTO v_tid FROM allgres_private.tasks WHERE session_id = v_sid LIMIT 1;
  PERFORM allgres_private.append_log(v_tid, 1, 'assistant', jsonb_build_object('note', 'selftest'));
  PERFORM allgres_private.selftest_cleanup();
  ok := EXISTS (SELECT 1 FROM allgres_private.sessions WHERE session_id = v_sid AND status = 'cancelled')
    AND EXISTS (SELECT 1 FROM allgres_private.tasks WHERE task_id = v_tid AND status = 'failed')
    AND EXISTS (SELECT 1 FROM allgres_private.execution_logs WHERE task_id = v_tid);
  ok := ok
    AND NOT ((allgres.dashboard_rpc('{"action":"sessions.list","limit":500}'::jsonb))::text LIKE '%'||v_sid::text||'%')
    AND NOT ((allgres.dashboard_rpc('{"action":"tasks.list","limit":500}'::jsonb))::text LIKE '%'||v_tid::text||'%')
    AND NOT ((allgres.dashboard_rpc('{"action":"events"}'::jsonb))::text LIKE '%'||v_tid::text||'%');
  v := v || jsonb_build_array(jsonb_build_object('name', 'selftest_fixtures_hidden_not_deleted', 'ok', ok));

  -- Agent-identity embeddings / semantic delegate search (item 34-follow-up:
  -- generic embeddings, an optional pgvector-accelerated feature). No real
  -- HTTP round trip here -- that is tests/e2e_mock.sql's job, driven through
  -- the actual runtime worker -- this is allgres_private.
  -- rank_agents_by_embedding's own ranking/permission/dimension logic in
  -- isolation, with embeddings set directly rather than generated.
  DECLARE
    v_req uuid;
    v_near uuid;
    v_far uuid;
    v_wrongdim uuid;
    v_nopermission uuid;
    v_ranked jsonb;
    v_wrongmodel uuid;
  BEGIN
    SELECT agent_id INTO v_req FROM allgres_private.agents WHERE name = 'selftest_embed_requester';
    IF v_req IS NULL THEN
      v_req := (allgres_public.fn_create_agent('selftest_embed_requester')->>'agent_id')::uuid;
    END IF;
    SELECT agent_id INTO v_near FROM allgres_private.agents WHERE name = 'selftest_embed_near';
    IF v_near IS NULL THEN
      v_near := (allgres_public.fn_create_agent('selftest_embed_near')->>'agent_id')::uuid;
    END IF;
    SELECT agent_id INTO v_far FROM allgres_private.agents WHERE name = 'selftest_embed_far';
    IF v_far IS NULL THEN
      v_far := (allgres_public.fn_create_agent('selftest_embed_far')->>'agent_id')::uuid;
    END IF;
    SELECT agent_id INTO v_wrongdim FROM allgres_private.agents WHERE name = 'selftest_embed_wrongdim';
    IF v_wrongdim IS NULL THEN
      v_wrongdim := (allgres_public.fn_create_agent('selftest_embed_wrongdim')->>'agent_id')::uuid;
    END IF;
    SELECT agent_id INTO v_nopermission FROM allgres_private.agents WHERE name = 'selftest_embed_nopermission';
    IF v_nopermission IS NULL THEN
      v_nopermission := (allgres_public.fn_create_agent('selftest_embed_nopermission')->>'agent_id')::uuid;
    END IF;
    -- Same dimension AND same direction as v_near -- would rank first on
    -- similarity alone -- but embedded under a different model, so must be
    -- excluded exactly like a dimension mismatch is: two models can agree
    -- on vector length while meaning something entirely different per axis.
    SELECT agent_id INTO v_wrongmodel FROM allgres_private.agents WHERE name = 'selftest_embed_wrongmodel';
    IF v_wrongmodel IS NULL THEN
      v_wrongmodel := (allgres_public.fn_create_agent('selftest_embed_wrongmodel')->>'agent_id')::uuid;
    END IF;

    UPDATE allgres_private.agents SET embedding = ARRAY[1,0,0,0]::double precision[], embedding_model = 'selftest_provider:model-a' WHERE agent_id = v_near;
    UPDATE allgres_private.agents SET embedding = ARRAY[0,1,0,0]::double precision[], embedding_model = 'selftest_provider:model-a' WHERE agent_id = v_far;
    UPDATE allgres_private.agents SET embedding = ARRAY[1,0,0]::double precision[], embedding_model = 'selftest_provider:model-a' WHERE agent_id = v_wrongdim;
    UPDATE allgres_private.agents SET embedding = ARRAY[1,0,0,0]::double precision[], embedding_model = 'selftest_provider:model-b' WHERE agent_id = v_wrongmodel;
    -- Closer to the query than v_near, but the requester is never granted
    -- 'agent' permission for it -- must still be excluded, the same check
    -- 'delegate' itself enforces.
    UPDATE allgres_private.agents SET embedding = ARRAY[1,0,0,0]::double precision[], embedding_model = 'selftest_provider:model-a' WHERE agent_id = v_nopermission;

    PERFORM allgres_public.fn_grant_permission(v_req, 'agent', 'selftest_embed_near');
    PERFORM allgres_public.fn_grant_permission(v_req, 'agent', 'selftest_embed_far');
    PERFORM allgres_public.fn_grant_permission(v_req, 'agent', 'selftest_embed_wrongdim');
    PERFORM allgres_public.fn_grant_permission(v_req, 'agent', 'selftest_embed_wrongmodel');

    v_ranked := allgres_private.rank_agents_by_embedding(
      ARRAY[1,0,0,0]::double precision[], v_req, 'selftest_provider:model-a', 5
    );
    ok := jsonb_array_length(v_ranked) = 2
      AND v_ranked->0->>'name' = 'selftest_embed_near'
      AND (v_ranked->0->>'similarity')::numeric = 1
      AND v_ranked->1->>'name' = 'selftest_embed_far';
    v := v || jsonb_build_array(jsonb_build_object('name', 'rank_agents_by_embedding_orders_filters_and_excludes_mismatched_dims_and_models', 'ok', ok));

    -- search_agents with no purpose='embedding' provider configured (the
    -- default state here) must be a friendly continue, not an exception --
    -- an optional feature's absence can never fail a task.
    v_sid := (allgres_public.fn_create_session(v_req, 'selftest search_agents no provider')->>'session_id')::uuid;
    SELECT task_id INTO v_tid FROM allgres_private.tasks WHERE session_id = v_sid LIMIT 1;
    PERFORM allgres_public.fn_next_step(v_tid);
    sub := allgres_public.fn_submit_result(v_tid, jsonb_build_object(
      'type', 'llm_response',
      'content', '{"action":"search_agents","query":"anything"}',
      'parsed', jsonb_build_object('action', 'search_agents', 'query', 'anything')
    ));
    ok := sub->>'action' = 'continue' AND EXISTS (
      SELECT 1 FROM allgres_private.execution_logs
      WHERE task_id = v_tid AND role = 'error' AND content->>'reason' = 'no_embedding_provider_configured'
    );
    v := v || jsonb_build_array(jsonb_build_object('name', 'search_agents_no_provider_is_a_friendly_continue', 'ok', ok));
  END;

  -- Semantic memory recall (roadmap backlog item: the same embedding infra
  -- as agent-identity embeddings/search_agents just above, applied to
  -- allgres_private.agent_memories instead). No real HTTP round trip here
  -- either -- that is tests/e2e_mock.sql's job -- this is allgres_private.
  -- rank_memories_by_embedding's own ranking/dimension/model/expiry logic
  -- in isolation, with embeddings set directly rather than generated, plus
  -- the 'recall' agent action's own no-provider fallback.
  DECLARE
    v_rec_agent uuid;
    v_mem_near uuid;
    v_mem_far uuid;
    v_mem_wrongdim uuid;
    v_mem_wrongmodel uuid;
    v_mem_expired uuid;
    v_ranked jsonb;
  BEGIN
    SELECT agent_id INTO v_rec_agent FROM allgres_private.agents WHERE name = 'selftest_recall_agent';
    IF v_rec_agent IS NULL THEN
      v_rec_agent := (allgres_public.fn_create_agent('selftest_recall_agent')->>'agent_id')::uuid;
    END IF;

    DELETE FROM allgres_private.agent_memories WHERE agent_id = v_rec_agent;

    v_mem_near := (allgres_public.fn_remember(v_rec_agent, 'selftest memory near', 'semantic', '0.5', NULL, NULL)->>'memory_id')::uuid;
    v_mem_far := (allgres_public.fn_remember(v_rec_agent, 'selftest memory far', 'semantic', '0.5', NULL, NULL)->>'memory_id')::uuid;
    v_mem_wrongdim := (allgres_public.fn_remember(v_rec_agent, 'selftest memory wrongdim', 'semantic', '0.5', NULL, NULL)->>'memory_id')::uuid;
    v_mem_wrongmodel := (allgres_public.fn_remember(v_rec_agent, 'selftest memory wrongmodel', 'semantic', '0.5', NULL, NULL)->>'memory_id')::uuid;
    -- Same dimension AND direction as v_mem_near -- would rank first on
    -- similarity alone -- but already expired, so must be excluded exactly
    -- like fn_next_step's own automatic recall already excludes it.
    v_mem_expired := (allgres_public.fn_remember(v_rec_agent, 'selftest memory expired', 'semantic', '0.5', NULL, '1')->>'memory_id')::uuid;

    UPDATE allgres_private.agent_memories SET embedding = ARRAY[1,0,0,0]::double precision[], embedding_model = 'selftest_provider:model-a' WHERE memory_id = v_mem_near;
    UPDATE allgres_private.agent_memories SET embedding = ARRAY[0,1,0,0]::double precision[], embedding_model = 'selftest_provider:model-a' WHERE memory_id = v_mem_far;
    UPDATE allgres_private.agent_memories SET embedding = ARRAY[1,0,0]::double precision[], embedding_model = 'selftest_provider:model-a' WHERE memory_id = v_mem_wrongdim;
    UPDATE allgres_private.agent_memories SET embedding = ARRAY[1,0,0,0]::double precision[], embedding_model = 'selftest_provider:model-b' WHERE memory_id = v_mem_wrongmodel;
    UPDATE allgres_private.agent_memories SET embedding = ARRAY[1,0,0,0]::double precision[], embedding_model = 'selftest_provider:model-a', expires_at = now() - interval '1 hour' WHERE memory_id = v_mem_expired;

    v_ranked := allgres_private.rank_memories_by_embedding(
      ARRAY[1,0,0,0]::double precision[], v_rec_agent, 'selftest_provider:model-a', 5
    );
    ok := jsonb_array_length(v_ranked) = 2
      AND v_ranked->0->>'memory_id' = v_mem_near::text
      AND (v_ranked->0->>'similarity')::numeric = 1
      AND v_ranked->1->>'memory_id' = v_mem_far::text;
    v := v || jsonb_build_array(jsonb_build_object('name', 'rank_memories_by_embedding_orders_filters_and_excludes_mismatched_dims_models_and_expired', 'ok', ok));

    DELETE FROM allgres_private.agent_memories WHERE agent_id = v_rec_agent;

    -- 'recall' with no purpose='embedding' provider configured (the
    -- default state here) must be a friendly continue, not an exception --
    -- an optional feature's absence can never fail a task.
    v_sid := (allgres_public.fn_create_session(v_rec_agent, 'selftest recall no provider')->>'session_id')::uuid;
    SELECT task_id INTO v_tid FROM allgres_private.tasks WHERE session_id = v_sid LIMIT 1;
    PERFORM allgres_public.fn_next_step(v_tid);
    sub := allgres_public.fn_submit_result(v_tid, jsonb_build_object(
      'type', 'llm_response',
      'content', '{"action":"recall","query":"anything"}',
      'parsed', jsonb_build_object('action', 'recall', 'query', 'anything')
    ));
    ok := sub->>'action' = 'continue' AND EXISTS (
      SELECT 1 FROM allgres_private.execution_logs
      WHERE task_id = v_tid AND role = 'error' AND content->>'reason' = 'no_embedding_provider_configured'
    );
    v := v || jsonb_build_array(jsonb_build_object('name', 'recall_no_provider_is_a_friendly_continue', 'ok', ok));

    -- Missing query text is rejected the same way search_agents' own
    -- missing-query case is, before any provider lookup even happens.
    UPDATE allgres_private.tasks SET status = 'running' WHERE task_id = v_tid;
    sub := allgres_public.fn_submit_result(v_tid, jsonb_build_object(
      'type', 'llm_response', 'content', '{}', 'parsed', jsonb_build_object('action', 'recall')
    ));
    ok := sub->>'action' = 'continue' AND EXISTS (
      SELECT 1 FROM allgres_private.execution_logs
      WHERE task_id = v_tid AND role = 'error' AND content->>'reason' = 'recall_needs_query'
    );
    v := v || jsonb_build_array(jsonb_build_object('name', 'recall_rejects_missing_query', 'ok', ok));
  END;

  PERFORM allgres_private.selftest_cleanup();

  -- Leave the agent as we found it.
  UPDATE allgres_private.policies SET system_prompt = v_saved_prompt WHERE agent_id = v_agent;

  RETURN jsonb_build_object(
    'passed', (SELECT count(*) FROM jsonb_array_elements(v) e WHERE (e->>'ok')::boolean),
    'failed', (SELECT count(*) FROM jsonb_array_elements(v) e WHERE NOT (e->>'ok')::boolean),
    'cases', v
  );
END;
$fn$;

-- ---------------------------------------------------------------------------
-- 12. Grants.
-- ---------------------------------------------------------------------------

-- Every schema, table, view, sequence, and SECURITY DEFINER function this
-- file creates is owned by allgres_owner (fn_provision_agent_role alone
-- excepted -- see "1. Roles" for why it is owned by allgres_role_admin
-- instead), not by whichever superuser happened to run CREATE EXTENSION.
-- Ownership was never actually reassigned before this -- confirmed live,
-- an external review caught it: every schema and every SECURITY DEFINER
-- function in a fresh install was owned by the installing superuser, which
-- means the "four fixed roles" README describes were three real
-- boundaries and one that did nothing (allgres_owner existed but owned
-- nothing, so SECURITY DEFINER meant "runs as whoever installed this," not
-- "runs as a role scoped to exactly what this file grants it"). Iterates
-- rather than naming every object by hand, so it stays correct as objects
-- are added; idempotent (ALTER ... OWNER TO is a no-op when already
-- correct), so replaying this on every install/upgrade is free. Must run
-- after every object above has been created, and before the grants below
-- (a GRANT does not depend on ownership, but keeping the two together
-- keeps this section legible as "how access to these schemas actually
-- works," start to finish).
-- Scoped to actual members of the 'allgres' extension (pg_depend, deptype
-- 'e') rather than "everything currently sitting in these three schema
-- namespaces" -- a second-round review pointed out the blanket version
-- would silently take ownership of any unrelated object a user happened to
-- create inside allgres_private/allgres_public/allgres, which has nothing
-- to do with this extension. CREATE EXTENSION (and ALTER EXTENSION UPDATE,
-- which keeps the same pg_extension row) automatically records every
-- object this file creates as an extension member as it creates it, so
-- this scoping needs no separate bookkeeping of its own.
DO $$
DECLARE r record;
BEGIN
  FOR r IN
    SELECT n.nspname, c.relname, c.relkind
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    JOIN pg_depend d ON d.classid = 'pg_class'::regclass AND d.objid = c.oid AND d.deptype = 'e'
    JOIN pg_extension e ON e.oid = d.refobjid AND e.extname = 'allgres'
    WHERE n.nspname IN ('allgres_private', 'allgres_public', 'allgres')
      AND c.relkind IN ('r', 'v', 'S')
      AND c.relowner <> 'allgres_owner'::regrole
  LOOP
    EXECUTE format(
      'ALTER %s %I.%I OWNER TO allgres_owner',
      CASE r.relkind WHEN 'r' THEN 'TABLE' WHEN 'v' THEN 'VIEW' WHEN 'S' THEN 'SEQUENCE' END,
      r.nspname, r.relname
    );
  END LOOP;

  FOR r IN
    SELECT p.oid::regprocedure AS sig, p.proname
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    JOIN pg_depend d ON d.classid = 'pg_proc'::regclass AND d.objid = p.oid AND d.deptype = 'e'
    JOIN pg_extension e ON e.oid = d.refobjid AND e.extname = 'allgres'
    WHERE n.nspname IN ('allgres_private', 'allgres_public', 'allgres')
      AND p.proowner <> 'allgres_owner'::regrole
      AND p.proname <> 'fn_provision_agent_role'
  LOOP
    EXECUTE format('ALTER FUNCTION %s OWNER TO allgres_owner', r.sig);
  END LOOP;

  IF EXISTS (
    SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'allgres_private' AND p.proname = 'fn_provision_agent_role'
      AND p.proowner <> 'allgres_role_admin'::regrole
  ) THEN
    ALTER FUNCTION allgres_private.fn_provision_agent_role(uuid) OWNER TO allgres_role_admin;
  END IF;

  IF (SELECT nspowner FROM pg_namespace WHERE nspname = 'allgres_private') <> 'allgres_owner'::regrole THEN
    ALTER SCHEMA allgres_private OWNER TO allgres_owner;
  END IF;
  IF (SELECT nspowner FROM pg_namespace WHERE nspname = 'allgres_public') <> 'allgres_owner'::regrole THEN
    ALTER SCHEMA allgres_public OWNER TO allgres_owner;
  END IF;
  -- The allgres schema (pgrx's native facade: analyze_sql, native_version,
  -- native_status, dashboard_rpc) is included here too, not left owned by
  -- the installing superuser: fn_selftest and other allgres_owner-owned
  -- PL/pgSQL functions call allgres.analyze_sql, and a SECURITY DEFINER
  -- function only gets what its *owner* was actually granted -- confirmed
  -- live, this was missed on the first pass and fn_selftest failed with
  -- "permission denied for schema allgres" the moment allgres_owner
  -- stopped being a superuser stand-in and became a real, limited role.
  -- On a fresh install this schema does not exist yet at this point in the
  -- file (it is only declared, redundantly, by "13." below -- pgrx's own
  -- native entity for this schema runs before section 1 and is what
  -- actually creates it that early) -- the IF's NULL <> ... short-circuits
  -- to skip rather than error either way, and the final pass after "13."
  -- covers this schema's ownership again regardless, so nothing here is
  -- required to succeed on every replay, only to be idempotent when it can.
  IF (SELECT nspowner FROM pg_namespace WHERE nspname = 'allgres') <> 'allgres_owner'::regrole THEN
    ALTER SCHEMA allgres OWNER TO allgres_owner;
  END IF;
END
$$;

-- fn_provision_agent_role's owner (allgres_role_admin) runs
-- GRANT sandbox TO <newrole> and GRANT <newrole> TO worker for every agent
-- it provisions. CREATEROLE alone covers creating and dropping the new
-- role; granting membership in sandbox/worker specifically -- roles
-- allgres_role_admin did not create -- needs ADMIN OPTION on each,
-- confirmed live (plain membership, tried first, still failed with
-- "permission denied to grant role \"sandbox\": only roles with the ADMIN
-- option ... may grant this role" -- CREATEROLE's PG16+ relaxation covers
-- managing a role's own attributes and dropping it, not granting
-- membership in an unrelated pre-existing role). ADMIN OPTION also lets
-- allgres_role_admin revoke sandbox/worker membership from anyone, not
-- only the roles it provisions -- a wider grant than ideal, but there is
-- no narrower standard primitive for "may grant this one role to others"
-- short of it.
GRANT sandbox TO allgres_role_admin WITH ADMIN OPTION;
GRANT worker TO allgres_role_admin WITH ADMIN OPTION;

-- fn_create_agent (owned by allgres_owner) calls fn_provision_agent_role
-- directly -- across the ownership split above, that is now a call to a
-- function owned by a *different* role, which needs its own EXECUTE grant
-- the same as any other cross-owner call would; two objects owned by the
-- same role never needed one, which is why this was missed on the first
-- pass (confirmed live: fn_create_agent failed with "permission denied for
-- function fn_provision_agent_role" the moment the two owners diverged).
GRANT EXECUTE ON FUNCTION allgres_private.fn_provision_agent_role(uuid) TO allgres_owner;

-- fn_provision_agent_role's own body reads and updates allgres_private.agents
-- directly -- also implicit before the ownership split (same reasoning as
-- the EXECUTE grant above), also confirmed live: "permission denied for
-- schema allgres_private" on the very next call after the EXECUTE grant
-- alone. USAGE on the schema plus exactly the two privileges the function
-- body actually uses, not a blanket grant on every table in the schema.
GRANT USAGE ON SCHEMA allgres_private TO allgres_role_admin;
GRANT SELECT, UPDATE ON allgres_private.agents TO allgres_role_admin;

REVOKE ALL ON SCHEMA allgres_private FROM PUBLIC;
REVOKE ALL ON SCHEMA allgres_public FROM PUBLIC;

-- PostgreSQL grants EXECUTE on a newly created function to PUBLIC by
-- default -- unlike tables, which default to no access at all. Only about
-- a dozen of this file's ~55 functions ever got an explicit REVOKE for it
-- (the ones the pump loop calls, added when that path was hardened).
-- Confirmed live, an external review's narrower report of one such gap
-- (fn_oauth_token_request, which hands back a decrypted OAuth client
-- secret) led to checking every function in these three schemas the same
-- way -- and found allgres_private.secret_key() on the same list: the
-- literal pgcrypto key that encrypts every provider API key in the
-- system, callable with zero Allgres role membership at all, by any role
-- that can merely connect to the database. `operator` having broad
-- EXECUTE by design (the dashboard's whole point) was never the real
-- problem; PUBLIC having it by nobody ever revoking the default was.
--
-- REVOKE EXECUTE ON ALL FUNCTIONS is a snapshot against what exists right
-- now, not a standing policy, so it has to run after every CREATE
-- FUNCTION above it, here, to actually cover all of them -- ALTER DEFAULT
-- PRIVILEGES below is the standing half, closing the same gap for
-- whatever gets added later in this file without anyone remembering to
-- name it. Neither breaks a legitimate caller: every SECURITY DEFINER
-- function in this file runs as its *owner* regardless of who calls it
-- (ownership always implies EXECUTE on what you own, with no grant
-- needed), and every cross-owner call this file actually makes already
-- has its own explicit GRANT (see fn_provision_agent_role above, the one
-- real instance) -- confirmed live: fn_selftest, tests/smoke.sql, and
-- tests/e2e_mock.sql (the last of which exercises the real background
-- worker end to end, not just SECURITY DEFINER calls that would mask a
-- gap the way testing as postgres/superuser always would) all still pass
-- after this revoke.
REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA allgres_private FROM PUBLIC;
REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA allgres_public FROM PUBLIC;
REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA allgres FROM PUBLIC;
ALTER DEFAULT PRIVILEGES IN SCHEMA allgres_private REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;
ALTER DEFAULT PRIVILEGES IN SCHEMA allgres_public REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;
ALTER DEFAULT PRIVILEGES IN SCHEMA allgres REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;

GRANT USAGE ON SCHEMA allgres_public TO worker, operator, sandbox;
GRANT USAGE ON SCHEMA allgres_private TO operator;

GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA allgres_private TO operator;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA allgres_private TO operator;
ALTER DEFAULT PRIVILEGES IN SCHEMA allgres_private
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO operator;

-- Logs are append-only even for operator (the trigger enforces it too).
REVOKE UPDATE, DELETE ON allgres_private.execution_logs FROM operator;
-- REVOKE from operator is real defense in depth here the same way it is
-- for execution_logs; a REVOKE against allgres_owner itself would not be
-- (a table owner's DML rights on their own table cannot be revoked by
-- ACL in PostgreSQL at all -- only the audit_log_no_update trigger above
-- actually stops that path, and it applies regardless of who issues the
-- UPDATE/DELETE, ownership included).
REVOKE UPDATE, DELETE ON allgres_private.audit_log FROM operator;

REVOKE ALL ON allgres_private.llm_secrets FROM PUBLIC;
REVOKE ALL ON allgres_private.llm_secrets FROM operator;
REVOKE ALL ON allgres_private.llm_secrets FROM worker;

-- The sandbox reaches allowlisted views only; allgres_public holds nothing else.
GRANT SELECT ON ALL TABLES IN SCHEMA allgres_public TO sandbox;
ALTER DEFAULT PRIVILEGES IN SCHEMA allgres_public GRANT SELECT ON TABLES TO sandbox;

REVOKE ALL ON FUNCTION allgres_public.fn_next_step(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION allgres_public.fn_submit_result(uuid, jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION allgres_public.fn_pump(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION allgres_public.fn_dispatch_tasks() FROM PUBLIC;
REVOKE ALL ON FUNCTION allgres_public.fn_claim_outbound(int, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION allgres_public.fn_complete_outbound(uuid, int, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION allgres_public.fn_claim_sql(int) FROM PUBLIC;
REVOKE ALL ON FUNCTION allgres_public.fn_complete_sql(uuid, boolean, jsonb, int, boolean, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION allgres_public.fn_claim_oauth(int) FROM PUBLIC;
REVOKE ALL ON FUNCTION allgres_public.fn_complete_oauth(uuid, int, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION allgres_public.fn_watchdog(int) FROM PUBLIC;
REVOKE ALL ON FUNCTION allgres_public.fn_run_schedules() FROM PUBLIC;
REVOKE ALL ON FUNCTION allgres_public.fn_selftest() FROM PUBLIC;

-- fn_run_sandboxed_sql is SECURITY INVOKER and does not itself validate what
-- it is given: it must only ever be reachable as the `sandbox` role, which
-- the runtime worker assumes with a top-level SET ROLE right before calling
-- it (see src/lib.rs's `run_sandboxed_sql`).  A default grant to PUBLIC would
-- defeat that, since sandbox already has USAGE on this schema.
REVOKE ALL ON FUNCTION allgres_public.fn_run_sandboxed_sql(text) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION allgres_public.fn_next_step(uuid) TO worker;
GRANT EXECUTE ON FUNCTION allgres_public.fn_submit_result(uuid, jsonb) TO worker;
GRANT EXECUTE ON FUNCTION allgres_public.fn_pump(text) TO worker;
GRANT EXECUTE ON FUNCTION allgres_public.fn_dispatch_tasks() TO worker;
GRANT EXECUTE ON FUNCTION allgres_public.fn_claim_outbound(int, text) TO worker;
GRANT EXECUTE ON FUNCTION allgres_public.fn_complete_outbound(uuid, int, text) TO worker;
GRANT EXECUTE ON FUNCTION allgres_public.fn_claim_sql(int) TO worker;
GRANT EXECUTE ON FUNCTION allgres_public.fn_complete_sql(uuid, boolean, jsonb, int, boolean, text) TO worker;
GRANT EXECUTE ON FUNCTION allgres_public.fn_claim_oauth(int) TO worker;
GRANT EXECUTE ON FUNCTION allgres_public.fn_complete_oauth(uuid, int, text) TO worker;
GRANT EXECUTE ON FUNCTION allgres_public.fn_claim_agent_embedding(int) TO worker;
GRANT EXECUTE ON FUNCTION allgres_public.fn_complete_agent_embedding(uuid, int, text) TO worker;
GRANT EXECUTE ON FUNCTION allgres_public.fn_watchdog(int) TO worker;
GRANT EXECUTE ON FUNCTION allgres_public.fn_run_schedules() TO worker;
GRANT EXECUTE ON FUNCTION allgres_public.fn_run_sandboxed_sql(text) TO sandbox;

-- current_agent_id() is deliberately SECURITY INVOKER, not DEFINER (see its
-- own comment above, "1. Roles" is the wrong section to relitigate why),
-- and v_sales/v_my_tasks call it directly from their own WHERE clause --
-- which means it runs as whoever is actually querying the view, not as
-- some owner, and needs its own EXECUTE grant precisely because it is not
-- SECURITY DEFINER. Every per-agent role inherits this via `sandbox`
-- membership, the same way it inherits everything else sandbox has, so
-- one grant here covers all of them. Confirmed live: tests/smoke.sql's
-- role-isolation check (a real `SET LOCAL ROLE sandbox` querying
-- v_my_tasks, not fn_selftest calling through a SECURITY DEFINER wrapper)
-- failed with "permission denied for function current_agent_id" the
-- moment PUBLIC stopped covering this by default -- this was one of
-- several such gaps found only by testing under the actual role, not
-- superuser or another SECURITY DEFINER function.
GRANT EXECUTE ON FUNCTION allgres_private.current_agent_id() TO sandbox;

-- SECURITY DEFINER changes what agent_may_read's own body runs as once
-- it's allowed to start -- it does not waive the EXECUTE check needed to
-- call it in the first place, and v_sales/v_my_tasks call it directly
-- from their own WHERE clause the same as current_agent_id() just above.
-- Confirmed live, the same way: the next function PUBLIC's default had
-- been quietly covering for the sandbox role.
GRANT EXECUTE ON FUNCTION allgres_private.agent_may_read(text, uuid) TO sandbox;

GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA allgres_public TO operator;

-- The dashboard never returns a secret, only whether one is set (see
-- README, "Secrets at rest") -- provider_secret() is revoked from operator
-- two lines below for exactly that reason. fn_oauth_token_request used to
-- break that rule outright: it decrypted the OAuth client_secret and handed
-- the built HTTP request straight back to its caller, which the blanket
-- grant above would have handed to `operator` the moment anything wired it
-- into dashboard_rpc (see KNOWN_ISSUES.md, "a second-round external review
-- of items 18 and 19", for the equivalent leak this review round actually
-- found and fixed). It is fixed now the same way item 13 already fixed the
-- identical class of leak for an LLM provider's api_key: the secret is
-- resolved and merged in only at claim time (fn_claim_oauth), inside the
-- runtime worker's own response, never returned by anything `operator` can
-- call. fn_oauth_start/fn_oauth_token_request stay under the blanket grant
-- above -- both now return only a redirect URL / a queued call_id, nothing
-- secret -- the same way fn_claim_outbound/fn_complete_outbound stay under
-- it despite resolving the LLM credential internally: ownership, not the
-- caller's own grants, is what runs their body (see the blanket-grant
-- comment above). fn_oauth_store_tokens is gone outright -- its storage
-- logic moved inside fn_complete_oauth, worker-only, with no public entry
-- point left to revoke from operator in the first place.

REVOKE EXECUTE ON FUNCTION allgres_private.fn_validate_sql(uuid, text) FROM worker;
REVOKE EXECUTE ON FUNCTION allgres_private.provider_secret(uuid) FROM operator;
REVOKE EXECUTE ON FUNCTION allgres_private.provider_secret(uuid) FROM worker;
REVOKE EXECUTE ON FUNCTION allgres_private.oauth_client_secret(uuid) FROM operator;
REVOKE EXECUTE ON FUNCTION allgres_private.oauth_client_secret(uuid) FROM worker;
REVOKE EXECUTE ON FUNCTION allgres_private.connection_secret(uuid) FROM operator;
REVOKE EXECUTE ON FUNCTION allgres_private.connection_secret(uuid) FROM worker;
REVOKE EXECUTE ON FUNCTION allgres_private.decrypt_secret(text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION allgres_private.encrypt_secret(text) FROM PUBLIC;

-- PostgreSQL grants EXECUTE to PUBLIC on a new function by default; relying
-- on that here would mean anything with USAGE on allgres_private (operator has
-- it) could trigger a CREATE ROLE through this SECURITY DEFINER function
-- without that being a deliberate choice. It is one -- operator is the
-- trusted admin/dashboard role and manually re-provisioning an agent's role
-- is a legitimate maintenance action -- but explicit beats ambient, the
-- same reasoning already applied to provider_secret above. worker never
-- needs this directly: fn_create_agent (allgres_public, same owner) calls it
-- internally, which needs no grant at all between two objects owned by the
-- same role.
REVOKE ALL ON FUNCTION allgres_private.fn_provision_agent_role(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION allgres_private.fn_provision_agent_role(uuid) TO operator;

-- ---------------------------------------------------------------------------
-- 13. allgres facade + dashboard RPC.
-- ---------------------------------------------------------------------------

CREATE SCHEMA IF NOT EXISTS allgres;
COMMENT ON SCHEMA allgres IS 'Allgres public facade. Postgres Is All You Need.';

CREATE OR REPLACE FUNCTION allgres.create_agent(p_name text)
RETURNS jsonb LANGUAGE sql SECURITY DEFINER
SET search_path = allgres_public, allgres_private, pg_temp
AS $$ SELECT allgres_public.fn_create_agent(p_name) $$;

-- Returns jsonb: fn_create_session returns an object, and the old `RETURNS uuid`
-- declaration made this function fail its return-type check at CREATE time.
CREATE OR REPLACE FUNCTION allgres.create_session(p_agent_id uuid, p_goal text)
RETURNS jsonb LANGUAGE sql SECURITY DEFINER
SET search_path = allgres_public, allgres_private, pg_temp
AS $$ SELECT allgres_public.fn_create_session(p_agent_id, p_goal) $$;

CREATE OR REPLACE FUNCTION allgres.pump()
RETURNS jsonb LANGUAGE sql SECURITY DEFINER
SET search_path = allgres_public, allgres_private, pg_temp
AS $$ SELECT allgres_public.fn_dispatch_tasks() $$;

-- Best-effort privilege drop for the runtime background worker.  It connects as
-- the bootstrap superuser (so a missing role can never crash-loop the worker at
-- startup) and calls this at the top of every transaction, so ordinary work runs
-- as `worker` instead.  Returns false when the role is not there yet.
CREATE OR REPLACE FUNCTION allgres.assume_worker_role()
RETURNS boolean
LANGUAGE plpgsql
AS $fn$
BEGIN
  EXECUTE 'SET LOCAL ROLE worker';
  RETURN true;
EXCEPTION WHEN others THEN
  RETURN false;
END;
$fn$;

CREATE OR REPLACE VIEW allgres.agents AS
SELECT a.agent_id, a.name, a.is_active, a.created_at, a.updated_at
FROM allgres_private.agents a;

CREATE OR REPLACE VIEW allgres.tasks AS
SELECT task_id, session_id, agent_id, parent_task_id, status, step_count,
       input, output, error, created_at, updated_at
FROM allgres_private.tasks;

CREATE OR REPLACE VIEW allgres.projects AS
SELECT project_id, name, description, is_active, created_at, updated_at
FROM allgres_private.projects;

REVOKE ALL ON SCHEMA allgres FROM PUBLIC;
GRANT USAGE ON SCHEMA allgres TO operator, worker;
GRANT SELECT ON allgres.agents, allgres.tasks, allgres.projects TO operator;

-- Same PUBLIC-EXECUTE-by-default gap the blanket revoke earlier in this
-- file closes for allgres_private/allgres_public -- these four are
-- defined here, in "13.", after that revoke already ran (a snapshot
-- against what existed at the time, not a standing rule), so they need
-- their own, same as dashboard_rpc and analyze_sql already had. Confirmed
-- live: these four were still PUBLIC-executable after the earlier revoke,
-- for exactly that reason.
REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA allgres FROM PUBLIC;

GRANT EXECUTE ON FUNCTION allgres.create_agent(text) TO operator;
GRANT EXECUTE ON FUNCTION allgres.create_session(uuid, text) TO operator;
GRANT EXECUTE ON FUNCTION allgres.pump() TO worker, operator;
GRANT EXECUTE ON FUNCTION allgres.assume_worker_role() TO worker, operator;

-- One PL/pgSQL RPC surface keeps HTTP routing and native code thin.
CREATE OR REPLACE FUNCTION allgres.dashboard_rpc(p_request jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = allgres_private, allgres_public, allgres, pg_catalog, pg_temp
AS $fn$
DECLARE
  v_action text := COALESCE(p_request->>'action', '');
  v_id uuid;
  v_user allgres_private.users%ROWTYPE;
  v_scope uuid[];
BEGIN
  -- Every consequential mutating function below now writes its own
  -- audit_log row itself (allgres_private.audit) the moment it actually
  -- runs -- not a centralized list here keyed on action name, which used
  -- to mean a direct SQL call to the exact same function left no audit
  -- trail at all (see the table's own comment and "Everything the
  -- dashboard does, psql can do too" in the README). This one call is all
  -- dashboard_rpc itself still does: it stamps the current transaction
  -- with this request's self-reported operator_name so every audit() call
  -- reached from here on is correctly recorded as 'web', not 'sql'.
  PERFORM allgres_private.set_audit_context(p_request->>'operator_name');

  CASE v_action
    -- Every count/listing here excludes goal LIKE 'selftest%' (see
    -- selftest_cleanup's comment: those rows can never be deleted outright,
    -- only hidden) -- a headline metric or "recent" list is exactly where an
    -- operator would otherwise see fn_selftest's own fixtures.
    WHEN 'overview' THEN
      RETURN jsonb_build_object(
        'ok', true,
        'server_time', now(),
        'version', allgres.native_version(),
        'agents', (SELECT count(*) FROM allgres_private.agents),
        'active_agents', (SELECT count(*) FROM allgres_private.agents WHERE is_active),
        'running_tasks', (
          SELECT count(*) FROM allgres_private.tasks t JOIN allgres_private.sessions s USING (session_id)
          WHERE t.status IN ('queued','running','waiting_human','waiting_children') AND s.goal NOT LIKE 'selftest%'
        ),
        'queued_outbound', (
          SELECT count(*) FROM allgres_private.outbound_calls o
          JOIN allgres_private.tasks t USING (task_id) JOIN allgres_private.sessions s USING (session_id)
          WHERE o.status = 'queued' AND s.goal NOT LIKE 'selftest%'
        ),
        'queued_sql', (
          SELECT count(*) FROM allgres_private.sql_calls c
          JOIN allgres_private.tasks t USING (task_id) JOIN allgres_private.sessions s USING (session_id)
          WHERE c.status = 'queued' AND s.goal NOT LIKE 'selftest%'
        ),
        'pending_approvals', (
          SELECT count(*) FROM allgres_private.human_approvals h
          JOIN allgres_private.tasks t USING (task_id) JOIN allgres_private.sessions s USING (session_id)
          WHERE h.status = 'pending' AND s.goal NOT LIKE 'selftest%'
        ),
        'failed_tasks', (
          SELECT count(*) FROM allgres_private.tasks t JOIN allgres_private.sessions s USING (session_id)
          WHERE t.status = 'failed' AND s.goal NOT LIKE 'selftest%'
        ),
        'sessions', (SELECT count(*) FROM allgres_private.sessions WHERE goal NOT LIKE 'selftest%'),
        'secret_storage', allgres_private.secret_storage_mode(),
        -- Overview's cluster monitoring (item 44): PostgreSQL version + this
        -- cluster's own session counts come straight from SQL; CPU load and
        -- memory come from the one place SQL cannot see them, native_host_stats.
        'pg_version', current_setting('server_version'),
        'db_sessions', (
          SELECT jsonb_build_object(
            'active', count(*) FILTER (WHERE state = 'active'),
            'idle', count(*) FILTER (WHERE state = 'idle'),
            'idle_in_transaction', count(*) FILTER (WHERE state = 'idle in transaction'),
            'total', count(*)
          )
          FROM pg_stat_activity
          WHERE datname = current_database()
        ),
        'host', allgres.native_host_stats(),
        'workers', COALESCE((
          SELECT jsonb_agg(jsonb_build_object('name', backend_type, 'pid', pid) ORDER BY backend_type)
          FROM pg_stat_activity
          WHERE backend_type IN ('allgres runtime','allgres web')
        ), '[]'::jsonb),
        'recent_tasks', COALESCE((
          SELECT jsonb_agg(to_jsonb(q) ORDER BY q.updated_at DESC)
          FROM (
            SELECT t.task_id, a.name AS agent, t.status, t.step_count,
                   s.goal, t.error, t.created_at, t.updated_at
            FROM allgres_private.tasks t
            JOIN allgres_private.agents a USING (agent_id)
            JOIN allgres_private.sessions s USING (session_id)
            WHERE s.goal NOT LIKE 'selftest%'
            ORDER BY t.updated_at DESC LIMIT 8
          ) q
        ), '[]'::jsonb)
      );

    WHEN 'agents.list' THEN
      RETURN jsonb_build_object('ok', true, 'agents', COALESCE((
        SELECT jsonb_agg(
          jsonb_build_object(
            'agent_id', a.agent_id,
            'name', a.name,
            'is_active', a.is_active,
            'is_system', a.is_system,
            'parent_agent_id', a.parent_agent_id,
            'parent_name', pa.name,
            'autonomy_level', a.autonomy_level,
            'agent_config', a.agent_config,
            'created_at', a.created_at,
            'updated_at', a.updated_at,
            'system_prompt', p.system_prompt,
            'max_steps', p.max_steps,
            'max_retries', p.max_retries,
            'llm_config', p.llm_config,
            'generation', p.generation,
            'max_concurrent_tasks', p.max_concurrent_tasks,
            'max_turn_seconds', p.max_turn_seconds,
            'max_delegation_depth', p.max_delegation_depth,
            'max_session_tasks', p.max_session_tasks,
            'permissions', COALESCE((
              SELECT jsonb_agg(jsonb_build_object('type', x.resource_type, 'ref', x.resource_ref)
                     ORDER BY x.resource_type, x.resource_ref)
              FROM allgres_private.permissions x WHERE x.agent_id = a.agent_id
            ), '[]'::jsonb)
          ) ORDER BY a.name
        )
        FROM allgres_private.agents a
        JOIN allgres_private.policies p USING (agent_id)
        LEFT JOIN allgres_private.agents pa ON pa.agent_id = a.parent_agent_id
        WHERE a.name NOT LIKE 'selftest%'
      ), '[]'::jsonb));

    WHEN 'agents.set_autonomy' THEN
      -- Relaxed from a bare require_admin: that alone made this the one
      -- action on the whole platform-configuration surface that could never
      -- be reached at all in a deployment that has never created a user
      -- account -- see require_admin_if_accounts_exist's own comment.
      PERFORM allgres_private.require_admin_if_accounts_exist(p_request->>'session_token');
      RETURN allgres_public.fn_set_agent_autonomy(
        (p_request->>'agent_id')::uuid, p_request->>'autonomy_level'
      );

    WHEN 'agents.bulk_set_model' THEN
      PERFORM allgres_private.require_admin_if_accounts_exist(p_request->>'session_token');
      RETURN allgres_public.fn_bulk_set_model(p_request->>'provider', p_request->>'model');

    WHEN 'agents.create' THEN
      PERFORM allgres_private.require_admin_if_accounts_exist(p_request->>'session_token');
      RETURN allgres_public.fn_create_agent(p_request->>'name', p_request->>'system_prompt');

    WHEN 'agents.update' THEN
      v_id := (p_request->>'agent_id')::uuid;
      -- Two gates, deliberately not one: require_admin_for_system_agent is
      -- unconditional the moment the target is a system agent (it always
      -- has been); require_admin_if_accounts_exist is what now also covers
      -- an *ordinary* agent, but only once accounts are actually in use.
      PERFORM allgres_private.require_admin_for_system_agent(p_request->>'session_token', v_id);
      PERFORM allgres_private.require_admin_if_accounts_exist(p_request->>'session_token');
      IF p_request ? 'is_active' THEN
        PERFORM allgres_public.fn_set_agent_active(v_id, (p_request->>'is_active')::boolean);
      END IF;
      IF p_request ? 'agent_config' THEN
        PERFORM allgres_public.fn_set_agent_config(v_id, p_request->'agent_config');
      END IF;
      PERFORM allgres_public.fn_set_policy(
        v_id,
        NULLIF(p_request->>'system_prompt',''),
        CASE WHEN p_request ? 'max_steps'   THEN (p_request->>'max_steps')::int    ELSE NULL END,
        CASE WHEN p_request ? 'max_retries' THEN (p_request->>'max_retries')::int  ELSE NULL END,
        CASE WHEN p_request ? 'llm_config'  THEN p_request->'llm_config'           ELSE NULL END,
        CASE WHEN p_request ? 'max_concurrent_tasks' THEN (p_request->>'max_concurrent_tasks')::int ELSE NULL END,
        CASE WHEN p_request ? 'max_turn_seconds' THEN (p_request->>'max_turn_seconds')::int ELSE NULL END,
        (p_request ? 'max_turn_seconds') AND (p_request->>'max_turn_seconds') IS NULL,
        CASE WHEN p_request ? 'max_delegation_depth' THEN (p_request->>'max_delegation_depth')::int ELSE NULL END,
        CASE WHEN p_request ? 'max_session_tasks' THEN (p_request->>'max_session_tasks')::int ELSE NULL END
      );
      -- A changed system_prompt is a changed identity for fn_search_agents'
      -- purposes -- name never changes after fn_create_agent, so that alone
      -- decides staleness. Queuing unconditionally on every non-empty
      -- system_prompt in the request (not a real before/after diff) is the
      -- same tolerance-for-a-harmless-extra-call the rest of this file
      -- already accepts elsewhere; the worst case is one wasted embedding
      -- call when an operator "changes" a prompt to its own current text.
      IF NULLIF(p_request->>'system_prompt', '') IS NOT NULL THEN
        PERFORM allgres_private.queue_agent_embedding(v_id);
      END IF;
      RETURN jsonb_build_object('ok', true, 'agent_id', v_id);

    WHEN 'policy.history' THEN
      RETURN jsonb_build_object('ok', true, 'history', COALESCE((
        SELECT jsonb_agg(to_jsonb(q) ORDER BY q.generation DESC)
        FROM (
          SELECT version_id, generation, system_prompt, max_steps, max_retries,
                 llm_config, max_concurrent_tasks, max_turn_seconds,
                 max_delegation_depth, max_session_tasks, success_rate_at_change, changed_at
          FROM allgres_private.policy_history
          WHERE agent_id = (p_request->>'agent_id')::uuid
        ) q
      ), '[]'::jsonb));

    WHEN 'policy.rollback' THEN
      PERFORM allgres_private.require_admin_for_system_agent(
        p_request->>'session_token', (p_request->>'agent_id')::uuid
      );
      PERFORM allgres_private.require_admin_if_accounts_exist(p_request->>'session_token');
      RETURN allgres_public.fn_rollback_policy(
        (p_request->>'agent_id')::uuid, (p_request->>'generation')::int
      );

    -- Roadmap item 7: "did the last change to this agent actually help" as
    -- a real computed verdict (allgres_public.fn_evaluate_last_change's own
    -- comment). Read-only, open the same way policy.history already is --
    -- an operator reviewing an agent's own history, not a mutation.
    WHEN 'agents.evaluate' THEN
      RETURN allgres_public.fn_evaluate_last_change((p_request->>'agent_id')::uuid);

    -- Optional filters: agent_id (one agent's proposals) and status (e.g.
    -- 'pending' for an inbox view); neither is required, so this also
    -- serves "every proposal, newest first".
    WHEN 'proposals.list' THEN
      v_scope := allgres_private.visible_agent_ids(p_request->>'session_token');
      RETURN jsonb_build_object('ok', true, 'proposals', COALESCE((
        SELECT jsonb_agg(jsonb_build_object(
          'proposal_id', cp.proposal_id, 'agent_id', cp.agent_id, 'agent', a.name,
          'kind', cp.kind, 'target_agent_id', cp.target_agent_id, 'target_agent', ta.name,
          'task_id', cp.task_id, 'proposed_changes', cp.proposed_changes,
          'reason', cp.reason, 'base_generation', cp.base_generation,
          'status', cp.status, 'created_at', cp.created_at,
          'decided_at', cp.decided_at, 'decided_reply', cp.decided_reply
        ) ORDER BY cp.created_at DESC)
        FROM allgres_private.change_proposals cp
        JOIN allgres_private.agents a ON a.agent_id = cp.agent_id
        LEFT JOIN allgres_private.agents ta ON ta.agent_id = cp.target_agent_id
        WHERE (NOT (p_request ? 'agent_id') OR cp.agent_id = (p_request->>'agent_id')::uuid)
          AND (NOT (p_request ? 'status') OR cp.status = p_request->>'status')
          AND COALESCE(cp.reason, '') NOT LIKE 'selftest%'
          -- create_agent has no existing target to scope by, so it stays
          -- admin-only in this inbox; a policy_change is visible to whoever
          -- may reach its actual target (COALESCE(target_agent_id, agent_id)).
          AND (v_scope IS NULL OR (cp.kind = 'policy_change' AND COALESCE(cp.target_agent_id, cp.agent_id) = ANY(v_scope)))
      ), '[]'::jsonb));

    WHEN 'proposals.decide' THEN
      v_scope := allgres_private.visible_agent_ids(p_request->>'session_token');
      IF v_scope IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM allgres_private.change_proposals cp
        WHERE cp.proposal_id = (p_request->>'proposal_id')::uuid
          AND cp.kind = 'policy_change'
          AND COALESCE(cp.target_agent_id, cp.agent_id) = ANY(v_scope)
      ) THEN
        RAISE EXCEPTION 'proposal not visible to this user' USING ERRCODE = 'P0001';
      END IF;
      RETURN allgres_public.fn_decide_proposal(
        (p_request->>'proposal_id')::uuid,
        (p_request->>'approve')::boolean,
        NULLIF(p_request->>'reply', '')
      );

    WHEN 'fixes.list' THEN
      v_scope := allgres_private.visible_agent_ids(p_request->>'session_token');
      RETURN jsonb_build_object('ok', true, 'fixes', COALESCE((
        SELECT jsonb_agg(jsonb_build_object(
          'fix_id', f.fix_id, 'agent_id', f.agent_id, 'agent', a.name,
          'fix_kind', f.fix_kind, 'target_agent_id', f.target_agent_id, 'target_agent', ta.name,
          'detail', f.detail, 'reason', f.reason, 'status', f.status,
          'created_at', f.created_at, 'decided_at', f.decided_at, 'decided_reply', f.decided_reply
        ) ORDER BY f.created_at DESC)
        FROM allgres_private.fix_proposals f
        JOIN allgres_private.agents a ON a.agent_id = f.agent_id
        JOIN allgres_private.agents ta ON ta.agent_id = f.target_agent_id
        WHERE (NOT (p_request ? 'status') OR f.status = p_request->>'status')
          AND COALESCE(f.reason, '') NOT LIKE 'selftest%'
          AND (v_scope IS NULL OR f.target_agent_id = ANY(v_scope))
      ), '[]'::jsonb));

    WHEN 'fixes.decide' THEN
      v_scope := allgres_private.visible_agent_ids(p_request->>'session_token');
      IF v_scope IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM allgres_private.fix_proposals f
        WHERE f.fix_id = (p_request->>'fix_id')::uuid AND f.target_agent_id = ANY(v_scope)
      ) THEN
        RAISE EXCEPTION 'fix not visible to this user' USING ERRCODE = 'P0001';
      END IF;
      RETURN allgres_public.fn_decide_fix(
        (p_request->>'fix_id')::uuid,
        (p_request->>'approve')::boolean,
        NULLIF(p_request->>'reply', '')
      );

    WHEN 'permissions.list' THEN
      RETURN jsonb_build_object('ok', true, 'permissions', COALESCE((
        SELECT jsonb_agg(jsonb_build_object(
          'permission_id', p.permission_id, 'type', p.resource_type,
          'ref', p.resource_ref, 'granted_at', p.granted_at
        ) ORDER BY p.resource_type, p.resource_ref)
        FROM allgres_private.permissions p
        WHERE p.agent_id = (p_request->>'agent_id')::uuid
      ), '[]'::jsonb));

    WHEN 'permissions.grant' THEN
      PERFORM allgres_private.require_admin_for_system_agent(
        p_request->>'session_token', (p_request->>'agent_id')::uuid
      );
      PERFORM allgres_private.require_admin_if_accounts_exist(p_request->>'session_token');
      RETURN allgres_public.fn_grant_permission(
        (p_request->>'agent_id')::uuid, p_request->>'type', p_request->>'ref'
      );

    WHEN 'permissions.revoke' THEN
      PERFORM allgres_private.require_admin_for_system_agent(
        p_request->>'session_token', (p_request->>'agent_id')::uuid
      );
      PERFORM allgres_private.require_admin_if_accounts_exist(p_request->>'session_token');
      RETURN allgres_public.fn_revoke_permission(
        (p_request->>'agent_id')::uuid, p_request->>'type', p_request->>'ref'
      );

    -- Fills the four grant-target pickers a permissions editor needs in one
    -- call: agent-visible views (queried live from pg_catalog, not hardcoded,
    -- so a newly created view shows up with no code change), the one real
    -- tool, other agents (delegate targets), and a note that http_host is
    -- free text -- there is no fixed list of allowed hosts to offer.
    WHEN 'permissions.options' THEN
      RETURN jsonb_build_object(
        'ok', true,
        'views', COALESCE((
          SELECT jsonb_agg(schemaname || '.' || viewname ORDER BY viewname)
          FROM pg_catalog.pg_views WHERE schemaname = 'allgres_public'
        ), '[]'::jsonb),
        'tools', '["http_get", "http_request"]'::jsonb,
        'agents', COALESCE((
          SELECT jsonb_agg(name ORDER BY name) FROM allgres_private.agents WHERE is_active
        ), '[]'::jsonb),
        'procedures', COALESCE((
          SELECT jsonb_agg(name ORDER BY name) FROM allgres_private.procedures WHERE is_active
        ), '[]'::jsonb),
        'http_hosts', 'free text -- any hostname the outbound guard allows'
      );

    WHEN 'allowlist.list' THEN
      RETURN jsonb_build_object('ok', true, 'allowlist', COALESCE((
        SELECT jsonb_agg(resource_ref ORDER BY resource_ref)
        FROM allgres_private.sql_sandbox_allowlist
      ), '[]'::jsonb));

    WHEN 'allowlist.add' THEN
      PERFORM allgres_private.require_admin_if_accounts_exist(p_request->>'session_token');
      RETURN allgres_public.fn_allowlist_add(p_request->>'ref');

    WHEN 'allowlist.remove' THEN
      PERFORM allgres_private.require_admin_if_accounts_exist(p_request->>'session_token');
      RETURN allgres_public.fn_allowlist_del(p_request->>'ref');

    WHEN 'projects.list' THEN
      RETURN jsonb_build_object('ok', true, 'projects', COALESCE((
        SELECT jsonb_agg(to_jsonb(pr) ORDER BY pr.name)
        FROM (
          SELECT p.project_id, p.name, p.description, p.is_active, p.created_at, p.updated_at,
                 p.agent_id, a.name AS agent, p.preset_prompt
          FROM allgres_private.projects p
          LEFT JOIN allgres_private.agents a ON a.agent_id = p.agent_id
        ) pr
      ), '[]'::jsonb));

    WHEN 'projects.create' THEN
      RETURN allgres_public.fn_create_project(
        p_request->>'name', p_request->>'description',
        NULLIF(p_request->>'agent_id', '')::uuid, p_request->>'preset_prompt'
      );

    WHEN 'projects.update' THEN
      v_id := (p_request->>'project_id')::uuid;
      IF p_request ? 'is_active' THEN
        PERFORM allgres_public.fn_set_project_active(v_id, (p_request->>'is_active')::boolean);
      END IF;
      IF p_request ? 'agent_id' OR p_request ? 'preset_prompt' THEN
        PERFORM allgres_public.fn_set_project_config(
          v_id, NULLIF(p_request->>'agent_id', '')::uuid, p_request->>'preset_prompt'
        );
      END IF;
      RETURN jsonb_build_object('ok', true, 'project_id', v_id);

    WHEN 'project_chat.send' THEN
      RETURN allgres_public.fn_project_chat_send(
        p_request->>'session_token', (p_request->>'project_id')::uuid, p_request->>'message'
      );

    WHEN 'project_chat.history' THEN
      RETURN allgres_public.fn_project_chat_history(
        p_request->>'session_token', (p_request->>'project_id')::uuid
      );

    WHEN 'run' THEN
      v_id := (p_request->>'agent_id')::uuid;
      PERFORM allgres_private.require_agent_access_if_accounts_exist(p_request->>'session_token', v_id);
      RETURN allgres_public.fn_create_session(
        v_id,
        p_request->>'goal',
        NULLIF(p_request->>'project_id', '')::uuid
      );

    WHEN 'sessions.cancel' THEN
      PERFORM allgres_private.require_agent_access_if_accounts_exist(
        p_request->>'session_token',
        (SELECT agent_id FROM allgres_private.sessions WHERE session_id = (p_request->>'session_id')::uuid)
      );
      RETURN allgres_public.fn_cancel_session(
        (p_request->>'session_id')::uuid,
        p_request->>'reason'
      );

    WHEN 'sessions.continue' THEN
      PERFORM allgres_private.require_agent_access_if_accounts_exist(
        p_request->>'session_token',
        (SELECT agent_id FROM allgres_private.sessions WHERE session_id = (p_request->>'session_id')::uuid)
      );
      RETURN allgres_public.fn_continue_session(
        (p_request->>'session_id')::uuid,
        p_request->>'message'
      );

    -- ---------------------------------------------------------------------
    -- Accounts, roles, and the chat/messenger surface (see the
    -- users/web_sessions table comments and require_admin/
    -- require_agent_access). None of these touch operator_name/the
    -- dashboard's own shared bearer token -- a session_token in the request
    -- body identifies the logged-in user instead, resolved server-side by
    -- allgres_private.session_user rather than trusted at face value.
    -- ---------------------------------------------------------------------

    WHEN 'auth.login' THEN
      RETURN allgres_public.fn_login(p_request->>'username', p_request->>'password');

    WHEN 'auth.logout' THEN
      RETURN allgres_public.fn_logout(p_request->>'session_token');

    WHEN 'auth.me' THEN
      v_user := allgres_private.session_user(p_request->>'session_token');
      IF v_user.user_id IS NULL THEN
        RETURN jsonb_build_object('ok', true, 'logged_in', false);
      END IF;
      RETURN jsonb_build_object(
        'ok', true, 'logged_in', true,
        'user_id', v_user.user_id, 'username', v_user.username, 'role', v_user.role
      );

    WHEN 'users.create' THEN
      PERFORM allgres_private.require_admin(p_request->>'session_token');
      RETURN allgres_public.fn_create_user(
        p_request->>'username', p_request->>'password',
        COALESCE(NULLIF(p_request->>'role', ''), 'user')
      );

    WHEN 'users.list' THEN
      PERFORM allgres_private.require_admin(p_request->>'session_token');
      RETURN jsonb_build_object('ok', true, 'users', COALESCE((
        SELECT jsonb_agg(jsonb_build_object(
          'user_id', user_id, 'username', username, 'role', role,
          'is_active', is_active, 'created_at', created_at
        ) ORDER BY created_at)
        FROM allgres_private.users
      ), '[]'::jsonb));

    WHEN 'users.set_active' THEN
      PERFORM allgres_private.require_admin(p_request->>'session_token');
      RETURN allgres_public.fn_set_user_active(
        (p_request->>'user_id')::uuid, (p_request->>'is_active')::boolean
      );

    WHEN 'users.set_role' THEN
      PERFORM allgres_private.require_admin(p_request->>'session_token');
      RETURN allgres_public.fn_set_user_role((p_request->>'user_id')::uuid, p_request->>'role');

    -- Replaces the full assignment set for one user with the given
    -- agent_ids array -- simpler and less error-prone from the UI than
    -- incremental add/remove calls for what is always edited as one list.
    WHEN 'assignments.set' THEN
      PERFORM allgres_private.require_admin(p_request->>'session_token');
      RETURN allgres_public.fn_set_user_assignments(
        (p_request->>'user_id')::uuid,
        ARRAY(SELECT (a)::uuid FROM jsonb_array_elements_text(COALESCE(p_request->'agent_ids', '[]'::jsonb)) a)
      );

    WHEN 'assignments.list' THEN
      PERFORM allgres_private.require_admin(p_request->>'session_token');
      RETURN jsonb_build_object('ok', true, 'agent_ids', COALESCE((
        SELECT jsonb_agg(agent_id) FROM allgres_private.user_agent_assignments
        WHERE user_id = (p_request->>'user_id')::uuid
      ), '[]'::jsonb));

    -- The reverse direction of assignments.list (item 32: "admin should be
    -- able to grant user access from the Agents page too, not only from
    -- Users") -- every user who may reach one agent, and a single add/
    -- remove that doesn't require replacing that user's whole assignment
    -- list the way assignments.set (built for the Users page's own
    -- per-user checkbox list) does.
    WHEN 'assignments.for_agent' THEN
      PERFORM allgres_private.require_admin(p_request->>'session_token');
      RETURN jsonb_build_object('ok', true, 'user_ids', COALESCE((
        SELECT jsonb_agg(user_id) FROM allgres_private.user_agent_assignments
        WHERE agent_id = (p_request->>'agent_id')::uuid
      ), '[]'::jsonb));

    WHEN 'assignments.toggle' THEN
      PERFORM allgres_private.require_admin(p_request->>'session_token');
      RETURN allgres_public.fn_set_user_assignment(
        (p_request->>'user_id')::uuid, (p_request->>'agent_id')::uuid, (p_request->>'assigned')::boolean
      );

    -- The agents a logged-in user may see at all: every active agent for an
    -- admin, only explicitly assigned ones for a regular user.
    WHEN 'agents.mine' THEN
      v_user := allgres_private.session_user(p_request->>'session_token');
      IF v_user.user_id IS NULL THEN
        RAISE EXCEPTION 'not logged in' USING ERRCODE = 'P0001';
      END IF;
      RETURN jsonb_build_object('ok', true, 'agents', COALESCE((
        SELECT jsonb_agg(jsonb_build_object(
          'agent_id', a.agent_id, 'name', a.name,
          'provider', p.llm_config->>'provider', 'model', p.llm_config->>'model'
        ) ORDER BY a.name)
        FROM allgres_private.agents a
        JOIN allgres_private.policies p USING (agent_id)
        WHERE a.is_active AND (
          v_user.role = 'admin'
          OR EXISTS (
            SELECT 1 FROM allgres_private.user_agent_assignments x
            WHERE x.user_id = v_user.user_id AND x.agent_id = a.agent_id
          )
        )
      ), '[]'::jsonb));

    WHEN 'agents.set_my_model' THEN
      RETURN allgres_public.fn_set_my_model(
        p_request->>'session_token', (p_request->>'agent_id')::uuid,
        NULLIF(p_request->>'provider', ''), NULLIF(p_request->>'model', '')
      );

    WHEN 'chat.send' THEN
      RETURN allgres_public.fn_chat_send(
        p_request->>'session_token', (p_request->>'agent_id')::uuid, p_request->>'message'
      );

    WHEN 'chat.history' THEN
      RETURN allgres_public.fn_chat_history(
        p_request->>'session_token', (p_request->>'agent_id')::uuid
      );

    WHEN 'messenger.post' THEN
      RETURN allgres_public.fn_messenger_post(p_request->>'session_token', p_request->>'text');

    WHEN 'messenger.list' THEN
      v_user := allgres_private.session_user(p_request->>'session_token');
      IF v_user.user_id IS NULL THEN
        RAISE EXCEPTION 'not logged in' USING ERRCODE = 'P0001';
      END IF;
      RETURN jsonb_build_object('ok', true, 'messages', COALESCE((
        SELECT jsonb_agg(to_jsonb(q) ORDER BY q.created_at)
        FROM (
          SELECT m.message_id, m.content, m.created_at,
                 au.username AS author, ag.name AS mentioned_agent,
                 s.status AS reply_status, s.final_answer AS reply,
                 -- Every mentioned agent's own reply, for a multi-mention
                 -- post (item 40) -- each agent keeps its own (user, agent)
                 -- session, so this is found the same way fn_chat_send
                 -- itself resolves one, not a column stored on this row.
                 (
                   SELECT jsonb_agg(jsonb_build_object(
                     'agent', a2.name, 'reply_status', s2.status, 'reply', s2.final_answer
                   ) ORDER BY x.ord)
                   FROM unnest(m.mentioned_agent_ids) WITH ORDINALITY AS x(agent_id, ord)
                   JOIN allgres_private.agents a2 ON a2.agent_id = x.agent_id
                   LEFT JOIN allgres_private.user_agent_chat_sessions ucs
                     ON ucs.user_id = m.author_user_id AND ucs.agent_id = x.agent_id
                   LEFT JOIN allgres_private.sessions s2 ON s2.session_id = ucs.session_id
                 ) AS mentioned_agents
          FROM allgres_private.channel_messages m
          JOIN allgres_private.users au ON au.user_id = m.author_user_id
          LEFT JOIN allgres_private.agents ag ON ag.agent_id = m.mentioned_agent_id
          LEFT JOIN allgres_private.sessions s ON s.session_id = m.session_id
          ORDER BY m.created_at DESC
          LIMIT LEAST(GREATEST(COALESCE((p_request->>'limit')::int, 200), 1), 1000)
        ) q
      ), '[]'::jsonb));

    WHEN 'sessions.list' THEN
      -- Admin-only monitoring surface (no "Sessions" page exists for a
      -- regular user -- README's own role list) with, until now, no check
      -- at all: every session across every agent and every user, visible
      -- to anyone holding the shared token regardless of login state.
      PERFORM allgres_private.require_admin_if_accounts_exist(p_request->>'session_token');
      RETURN jsonb_build_object('ok', true, 'sessions', COALESCE((
        SELECT jsonb_agg(to_jsonb(q) ORDER BY q.started_at DESC)
        FROM (
          SELECT s.session_id, s.agent_id, a.name AS agent, s.project_id,
                 s.goal, s.status, s.final_answer, s.started_at, s.completed_at
          FROM allgres_private.sessions s
          JOIN allgres_private.agents a USING (agent_id)
          WHERE s.goal NOT LIKE 'selftest%'
            AND (NOT (p_request ? 'project_id')
             OR s.project_id IS NOT DISTINCT FROM NULLIF(p_request->>'project_id', '')::uuid)
          ORDER BY s.started_at DESC
          LIMIT LEAST(GREATEST(COALESCE((p_request->>'limit')::int, 100), 1), 500)
        ) q
      ), '[]'::jsonb));

    WHEN 'sessions.get' THEN
      PERFORM allgres_private.require_admin_if_accounts_exist(p_request->>'session_token');
      v_id := (p_request->>'session_id')::uuid;
      IF NOT EXISTS (SELECT 1 FROM allgres_private.sessions WHERE session_id = v_id) THEN
        RETURN jsonb_build_object('ok', false, 'error', 'session_not_found');
      END IF;
      RETURN jsonb_build_object(
        'ok', true,
        'session', (
          SELECT jsonb_build_object(
            'session_id', s.session_id, 'agent_id', s.agent_id, 'agent', a.name,
            'project_id', s.project_id, 'goal', s.goal, 'status', s.status,
            'final_answer', s.final_answer, 'started_at', s.started_at, 'completed_at', s.completed_at
          )
          FROM allgres_private.sessions s JOIN allgres_private.agents a USING (agent_id)
          WHERE s.session_id = v_id
        ),
        'tasks', COALESCE((
          SELECT jsonb_agg(to_jsonb(q) ORDER BY q.created_at)
          FROM (
            SELECT task_id, parent_task_id, status, step_count, output, error, created_at, updated_at
            FROM allgres_private.tasks WHERE session_id = v_id
          ) q
        ), '[]'::jsonb),
        'logs', COALESCE((
          SELECT jsonb_agg(to_jsonb(q) ORDER BY q.created_at)
          FROM (
            SELECT l.log_id, l.task_id, l.step_number, l.role, l.content, l.created_at
            FROM allgres_private.execution_logs l
            JOIN allgres_private.tasks t USING (task_id)
            WHERE t.session_id = v_id
          ) q
        ), '[]'::jsonb)
      );

    -- goal NOT LIKE 'selftest%' excludes fn_selftest's own fixture sessions
    -- (see selftest_cleanup's comment: they can never be deleted outright,
    -- execution_logs' append-only trigger forbids it even for this
    -- function's owner, so they are hidden here instead).
    WHEN 'tasks.list' THEN
      -- Admin-only monitoring surface, same audience as sessions.list --
      -- reached via a Rust-side GET route with no request body, so its
      -- session_token comes from a header instead (see api_route's own
      -- comment on the Tasks/Logs routes for why not a query string).
      PERFORM allgres_private.require_admin_if_accounts_exist(p_request->>'session_token');
      RETURN jsonb_build_object('ok', true, 'tasks', COALESCE((
        SELECT jsonb_agg(to_jsonb(q) ORDER BY q.updated_at DESC)
        FROM (
          SELECT t.task_id, t.session_id, t.parent_task_id, a.agent_id, a.name AS agent,
                 t.status, t.step_count, s.goal, s.final_answer,
                 t.output, t.error, t.created_at, t.updated_at
          FROM allgres_private.tasks t
          JOIN allgres_private.agents a USING (agent_id)
          JOIN allgres_private.sessions s USING (session_id)
          WHERE s.goal NOT LIKE 'selftest%'
          ORDER BY t.updated_at DESC
          LIMIT LEAST(GREATEST(COALESCE((p_request->>'limit')::int, 100), 1), 500)
        ) q
      ), '[]'::jsonb));

    WHEN 'logs.list' THEN
      PERFORM allgres_private.require_admin_if_accounts_exist(p_request->>'session_token');
      RETURN jsonb_build_object('ok', true, 'logs', COALESCE((
        SELECT jsonb_agg(to_jsonb(q) ORDER BY q.created_at DESC)
        FROM (
          SELECT l.log_id, l.task_id, l.step_number, l.role, l.content, l.created_at,
                 a.name AS agent
          FROM allgres_private.execution_logs l
          JOIN allgres_private.tasks t USING (task_id)
          JOIN allgres_private.agents a USING (agent_id)
          JOIN allgres_private.sessions s USING (session_id)
          WHERE s.goal NOT LIKE 'selftest%'
          ORDER BY l.created_at DESC
          LIMIT LEAST(GREATEST(COALESCE((p_request->>'limit')::int, 150), 1), 1000)
        ) q
      ), '[]'::jsonb));

    -- Optional agent_id filter, the same shape tasks.list's own optional
    -- limit uses: present -> scoped, absent -> every agent's memories.
    WHEN 'memories.list' THEN
      -- Scoped the same way proposals.list/fixes.list are: NULL (admin) sees
      -- every agent's memories, a regular user only their assigned agents'
      -- -- this was reachable for any agent_id before, regardless of who was
      -- asking, the one listing on this table that hadn't picked up the
      -- v_scope pattern already applied elsewhere.
      v_scope := allgres_private.visible_agent_ids(p_request->>'session_token');
      RETURN jsonb_build_object('ok', true, 'memories', COALESCE((
        SELECT jsonb_agg(to_jsonb(q) ORDER BY q.importance DESC, q.created_at DESC)
        FROM (
          SELECT m.memory_id, m.agent_id, a.name AS agent, m.subject_id, m.memory_type,
                 m.content, m.importance, m.confidence, m.source_session_id,
                 m.created_at, m.last_accessed_at, m.expires_at
          FROM allgres_private.agent_memories m
          JOIN allgres_private.agents a USING (agent_id)
          WHERE (NULLIF(p_request->>'agent_id', '') IS NULL
             OR m.agent_id = (p_request->>'agent_id')::uuid)
            AND (v_scope IS NULL OR m.agent_id = ANY(v_scope))
          ORDER BY m.importance DESC, m.created_at DESC
          LIMIT LEAST(GREATEST(COALESCE((p_request->>'limit')::int, 200), 1), 1000)
        ) q
      ), '[]'::jsonb));

    WHEN 'memories.create' THEN
      RETURN allgres_public.fn_remember(
        (p_request->>'agent_id')::uuid,
        p_request->>'content',
        NULLIF(p_request->>'memory_type', ''),
        p_request->>'importance',
        p_request->>'subject_id',
        p_request->>'expires_in_days'
      );

    WHEN 'memories.remove' THEN
      RETURN allgres_public.fn_forget((p_request->>'memory_id')::uuid);

    -- Roadmap item 3: search past work/decisions/failures, instead of only
    -- ever seeing an agent's most-important-first memory list or paging
    -- through raw execution logs one session at a time. Three sources,
    -- unioned and ordered by recency, each linking back to the session/task
    -- it came from so the dashboard can jump straight to it:
    --   memory   -- an agent's own explicit `remember`s
    --   failure  -- a task's role='error' log entries
    --   decision -- a completed session's final_answer
    -- `simple` (not `english`) tsvector config: this content is as likely to
    -- be Korean as English, and `simple` only lowercases/tokenizes, it does
    -- not assume an English stemmer -- ORed with a plain ILIKE substring
    -- match so a short query or one stemming can't help still finds
    -- something. Scoped exactly like memories.list above; p_agent_id/
    -- p_project_id (a session's project) narrow further when given.
    WHEN 'history.search' THEN
      v_scope := allgres_private.visible_agent_ids(p_request->>'session_token');
      IF NULLIF(trim(p_request->>'query'), '') IS NULL THEN
        RETURN jsonb_build_object('ok', false, 'error', 'query_required');
      END IF;
      RETURN jsonb_build_object('ok', true, 'results', COALESCE((
        SELECT jsonb_agg(to_jsonb(q) ORDER BY q.created_at DESC)
        FROM (
          SELECT * FROM (
            SELECT 'memory' AS source, m.memory_id AS ref_id, m.agent_id, a.name AS agent,
                   m.source_session_id AS session_id, m.source_task_id AS task_id,
                   m.memory_type AS kind, left(m.content, 400) AS snippet, m.created_at
            FROM allgres_private.agent_memories m
            JOIN allgres_private.agents a USING (agent_id)
            LEFT JOIN allgres_private.sessions se ON se.session_id = m.source_session_id
            WHERE (to_tsvector('simple', m.content) @@ plainto_tsquery('simple', p_request->>'query')
                   OR m.content ILIKE '%' || (p_request->>'query') || '%')
              AND (v_scope IS NULL OR m.agent_id = ANY(v_scope))
              AND (NULLIF(p_request->>'agent_id', '') IS NULL OR m.agent_id = (p_request->>'agent_id')::uuid)
              AND (NULLIF(p_request->>'project_id', '') IS NULL OR se.project_id = (p_request->>'project_id')::uuid)
              AND COALESCE(se.goal, '') NOT LIKE 'selftest%'

            UNION ALL

            SELECT 'failure' AS source, l.log_id AS ref_id, t.agent_id, a.name AS agent,
                   t.session_id, l.task_id, 'error' AS kind,
                   left(l.content::text, 400) AS snippet, l.created_at
            FROM allgres_private.execution_logs l
            JOIN allgres_private.tasks t ON t.task_id = l.task_id
            JOIN allgres_private.agents a ON a.agent_id = t.agent_id
            JOIN allgres_private.sessions se ON se.session_id = t.session_id
            WHERE l.role = 'error'
              AND (to_tsvector('simple', l.content::text) @@ plainto_tsquery('simple', p_request->>'query')
                   OR l.content::text ILIKE '%' || (p_request->>'query') || '%')
              AND (v_scope IS NULL OR t.agent_id = ANY(v_scope))
              AND (NULLIF(p_request->>'agent_id', '') IS NULL OR t.agent_id = (p_request->>'agent_id')::uuid)
              AND (NULLIF(p_request->>'project_id', '') IS NULL OR se.project_id = (p_request->>'project_id')::uuid)
              AND se.goal NOT LIKE 'selftest%'

            UNION ALL

            SELECT 'decision' AS source, se.session_id AS ref_id, se.agent_id, a.name AS agent,
                   se.session_id, NULL::uuid AS task_id, se.status AS kind,
                   left(se.final_answer, 400) AS snippet,
                   COALESCE(se.completed_at, se.started_at) AS created_at
            FROM allgres_private.sessions se
            JOIN allgres_private.agents a ON a.agent_id = se.agent_id
            WHERE se.final_answer IS NOT NULL
              AND (to_tsvector('simple', se.final_answer) @@ plainto_tsquery('simple', p_request->>'query')
                   OR se.final_answer ILIKE '%' || (p_request->>'query') || '%')
              AND (v_scope IS NULL OR se.agent_id = ANY(v_scope))
              AND (NULLIF(p_request->>'agent_id', '') IS NULL OR se.agent_id = (p_request->>'agent_id')::uuid)
              AND (NULLIF(p_request->>'project_id', '') IS NULL OR se.project_id = (p_request->>'project_id')::uuid)
              AND se.goal NOT LIKE 'selftest%'
          ) u
          ORDER BY u.created_at DESC
          LIMIT LEAST(GREATEST(COALESCE((p_request->>'limit')::int, 30), 1), 200)
        ) q
      ), '[]'::jsonb));

    -- origin/db_role now that direct SQL calls also audit themselves
    -- (a fn_selftest fixture creating its own agents/users/procedures via
    -- direct SQL calls, exactly like this section does, now leaves an
    -- audit_log row too) -- filtered out here the same way every other
    -- operator-facing listing in this file already hides selftest's own
    -- fixture noise (goal LIKE 'selftest%'), matched here against the
    -- details this function's own audit() calls always include a name/
    -- username/ref/goal for.
    WHEN 'audit.list' THEN
      RETURN jsonb_build_object('ok', true, 'entries', COALESCE((
        SELECT jsonb_agg(to_jsonb(q) ORDER BY q.created_at DESC)
        FROM (
          SELECT audit_id, operator_name, action, details, origin, db_role, created_at
          FROM allgres_private.audit_log
          WHERE details::text NOT ILIKE '%selftest%'
          ORDER BY created_at DESC
          LIMIT LEAST(GREATEST(COALESCE((p_request->>'limit')::int, 200), 1), 1000)
        ) q
      ), '[]'::jsonb));

    WHEN 'settings.get' THEN
      RETURN jsonb_build_object(
        'ok', true,
        'secret_storage', allgres_private.secret_storage_mode(),
        'providers', COALESCE((
          SELECT jsonb_agg(jsonb_build_object(
            'provider_id', p.provider_id,
            'name', p.name,
            'kind', p.kind,
            'purpose', p.purpose,
            'embedding_model', p.embedding_model,
            'base_url', p.base_url,
            'is_enabled', p.is_enabled,
            'allow_private_network', p.allow_private_network,
            'response_format_json_object', p.response_format_json_object,
            'oauth_auth_url', p.oauth_auth_url,
            'oauth_token_url', p.oauth_token_url,
            'oauth_client_id', p.oauth_client_id,
            'oauth_scope', p.oauth_scope,
            'has_secret', EXISTS (
              SELECT 1 FROM allgres_private.llm_secrets s
              WHERE s.provider_id = p.provider_id AND (
                NULLIF(s.api_key,'') IS NOT NULL
                OR NULLIF(s.access_token,'') IS NOT NULL
                OR NULLIF(s.oauth_client_secret,'') IS NOT NULL
              )
            )
          ) ORDER BY p.name)
          FROM allgres_private.llm_providers p
        ), '[]'::jsonb)
      );

    WHEN 'provider.update' THEN
      PERFORM allgres_private.require_admin_if_accounts_exist(p_request->>'session_token');
      v_id := (p_request->>'provider_id')::uuid;
      PERFORM allgres_public.fn_set_provider(
        v_id,
        NULLIF(p_request->>'base_url',''),
        CASE WHEN p_request ? 'is_enabled' THEN (p_request->>'is_enabled')::boolean ELSE NULL END,
        CASE WHEN p_request ? 'allow_private_network'
             THEN (p_request->>'allow_private_network')::boolean ELSE NULL END,
        NULLIF(p_request->>'oauth_auth_url',''),
        NULLIF(p_request->>'oauth_token_url',''),
        NULLIF(p_request->>'oauth_client_id',''),
        NULLIF(p_request->>'oauth_client_secret',''),
        NULLIF(p_request->>'embedding_model',''),
        CASE WHEN p_request ? 'response_format_json_object'
             THEN (p_request->>'response_format_json_object')::boolean ELSE NULL END
      );
      IF NULLIF(p_request->>'api_key','') IS NOT NULL THEN
        PERFORM allgres_public.fn_set_provider_secret(v_id, p_request->>'api_key');
      END IF;
      RETURN jsonb_build_object('ok', true, 'provider_id', v_id);

    WHEN 'provider.create' THEN
      PERFORM allgres_private.require_admin_if_accounts_exist(p_request->>'session_token');
      RETURN allgres_public.fn_create_provider(
        p_request->>'name',
        p_request->>'kind',
        p_request->>'base_url',
        NULLIF(p_request->>'api_key',''),
        COALESCE((p_request->>'allow_private_network')::boolean, false),
        COALESCE(NULLIF(p_request->>'purpose',''), 'chat'),
        NULLIF(p_request->>'embedding_model',''),
        COALESCE((p_request->>'response_format_json_object')::boolean, true)
      );

    -- Roadmap item 2: named external HTTP endpoints the 'http_request' tool
    -- can call with a stored credential (see allgres_private.api_connections'
    -- own comment). Never returns api_key -- only has_secret, the same as
    -- settings.get for llm_providers.
    WHEN 'connections.list' THEN
      RETURN jsonb_build_object('ok', true, 'connections', COALESCE((
        SELECT jsonb_agg(jsonb_build_object(
          'connection_id', c.connection_id,
          'name', c.name,
          'base_url', c.base_url,
          'auth_kind', c.auth_kind,
          'is_enabled', c.is_enabled,
          'allow_private_network', c.allow_private_network,
          'has_secret', EXISTS (
            SELECT 1 FROM allgres_private.api_connection_secrets s
            WHERE s.connection_id = c.connection_id AND NULLIF(s.api_key, '') IS NOT NULL
          )
        ) ORDER BY c.name)
        FROM allgres_private.api_connections c
      ), '[]'::jsonb));

    WHEN 'connections.create' THEN
      PERFORM allgres_private.require_admin_if_accounts_exist(p_request->>'session_token');
      RETURN allgres_public.fn_create_connection(
        p_request->>'name',
        p_request->>'base_url',
        COALESCE(NULLIF(p_request->>'auth_kind',''), 'none'),
        NULLIF(p_request->>'api_key',''),
        COALESCE((p_request->>'allow_private_network')::boolean, false)
      );

    WHEN 'connections.update' THEN
      PERFORM allgres_private.require_admin_if_accounts_exist(p_request->>'session_token');
      v_id := (p_request->>'connection_id')::uuid;
      PERFORM allgres_public.fn_set_connection(
        v_id,
        NULLIF(p_request->>'base_url',''),
        NULLIF(p_request->>'auth_kind',''),
        CASE WHEN p_request ? 'is_enabled' THEN (p_request->>'is_enabled')::boolean ELSE NULL END,
        CASE WHEN p_request ? 'allow_private_network'
             THEN (p_request->>'allow_private_network')::boolean ELSE NULL END
      );
      IF NULLIF(p_request->>'api_key','') IS NOT NULL THEN
        PERFORM allgres_public.fn_set_connection_secret(v_id, p_request->>'api_key');
      END IF;
      RETURN jsonb_build_object('ok', true, 'connection_id', v_id);

    WHEN 'connections.delete' THEN
      PERFORM allgres_private.require_admin_if_accounts_exist(p_request->>'session_token');
      RETURN allgres_public.fn_delete_connection((p_request->>'connection_id')::uuid);

    -- Roadmap item 4: reusable procedures (see allgres_private.procedures'
    -- own comment). Listing is open the same way settings.get/allowlist.list
    -- are -- a shared, curated library, not per-agent data -- only
    -- create/update/rollback are admin-gated, matching provider.create/
    -- policy.rollback.
    WHEN 'procedures.list' THEN
      RETURN jsonb_build_object('ok', true, 'procedures', COALESCE((
        SELECT jsonb_agg(jsonb_build_object(
          'procedure_id', p.procedure_id, 'name', p.name, 'content', p.content,
          'generation', p.generation, 'is_active', p.is_active,
          'created_at', p.created_at, 'updated_at', p.updated_at
        ) ORDER BY p.name)
        FROM allgres_private.procedures p
      ), '[]'::jsonb));

    WHEN 'procedures.get' THEN
      v_id := (p_request->>'procedure_id')::uuid;
      RETURN jsonb_build_object(
        'ok', true,
        'procedure', (
          SELECT jsonb_build_object(
            'procedure_id', p.procedure_id, 'name', p.name, 'content', p.content,
            'generation', p.generation, 'is_active', p.is_active
          )
          FROM allgres_private.procedures p WHERE p.procedure_id = v_id
        ),
        'history', COALESCE((
          SELECT jsonb_agg(jsonb_build_object(
            'generation', h.generation, 'content', h.content, 'changed_at', h.changed_at
          ) ORDER BY h.generation DESC)
          FROM allgres_private.procedure_history h WHERE h.procedure_id = v_id
        ), '[]'::jsonb)
      );

    WHEN 'procedures.create' THEN
      PERFORM allgres_private.require_admin_if_accounts_exist(p_request->>'session_token');
      RETURN allgres_public.fn_create_procedure(p_request->>'name', p_request->>'content');

    WHEN 'procedures.update' THEN
      PERFORM allgres_private.require_admin_if_accounts_exist(p_request->>'session_token');
      RETURN allgres_public.fn_set_procedure(
        (p_request->>'procedure_id')::uuid,
        NULLIF(p_request->>'content', ''),
        CASE WHEN p_request ? 'is_active' THEN (p_request->>'is_active')::boolean ELSE NULL END
      );

    WHEN 'procedures.rollback' THEN
      PERFORM allgres_private.require_admin_if_accounts_exist(p_request->>'session_token');
      RETURN allgres_public.fn_rollback_procedure(
        (p_request->>'procedure_id')::uuid, (p_request->>'generation')::int
      );

    -- Roadmap item 6: schedule/event-driven execution (see
    -- allgres_private.schedules' own comment). Listing is open, same as
    -- procedures.list/connections.list -- a shared, operator-curated
    -- surface; every mutation (including run_now, which actually creates a
    -- session and so is consequential the same way sessions.cancel is) is
    -- admin-gated once any account exists.
    WHEN 'schedules.list' THEN
      RETURN jsonb_build_object('ok', true, 'schedules', COALESCE((
        SELECT jsonb_agg(jsonb_build_object(
          'schedule_id', sc.schedule_id, 'name', sc.name, 'agent_id', sc.agent_id, 'agent', a.name,
          'goal', sc.goal, 'interval_seconds', sc.interval_seconds, 'next_run_at', sc.next_run_at,
          'is_active', sc.is_active, 'max_runs', sc.max_runs, 'run_count', sc.run_count,
          'ends_at', sc.ends_at, 'last_run_at', sc.last_run_at, 'last_session_id', sc.last_session_id
        ) ORDER BY sc.name)
        FROM allgres_private.schedules sc
        JOIN allgres_private.agents a USING (agent_id)
      ), '[]'::jsonb));

    WHEN 'schedules.create' THEN
      PERFORM allgres_private.require_admin_if_accounts_exist(p_request->>'session_token');
      RETURN allgres_public.fn_create_schedule(
        p_request->>'name',
        (p_request->>'agent_id')::uuid,
        p_request->>'goal',
        (p_request->>'interval_seconds')::int,
        NULLIF(p_request->>'max_runs', '')::int,
        NULLIF(p_request->>'ends_at', '')::timestamptz,
        NULLIF(p_request->>'start_at', '')::timestamptz
      );

    WHEN 'schedules.update' THEN
      PERFORM allgres_private.require_admin_if_accounts_exist(p_request->>'session_token');
      RETURN allgres_public.fn_set_schedule(
        (p_request->>'schedule_id')::uuid,
        NULLIF(p_request->>'goal', ''),
        NULLIF(p_request->>'interval_seconds', '')::int,
        CASE WHEN p_request ? 'is_active' THEN (p_request->>'is_active')::boolean ELSE NULL END,
        NULLIF(p_request->>'max_runs', '')::int,
        COALESCE((p_request->>'clear_max_runs')::boolean, false),
        NULLIF(p_request->>'ends_at', '')::timestamptz,
        COALESCE((p_request->>'clear_ends_at')::boolean, false)
      );

    WHEN 'schedules.delete' THEN
      PERFORM allgres_private.require_admin_if_accounts_exist(p_request->>'session_token');
      RETURN allgres_public.fn_delete_schedule((p_request->>'schedule_id')::uuid);

    WHEN 'schedules.run_now' THEN
      PERFORM allgres_private.require_admin_if_accounts_exist(p_request->>'session_token');
      RETURN allgres_public.fn_run_schedule_now((p_request->>'schedule_id')::uuid);

    -- Starts an OAuth authorization-code flow for a kind='oauth' provider:
    -- fn_oauth_start only ever returns a redirect_url and a state, neither
    -- of which is secret, so this is safe for operator to call directly.
    WHEN 'providers.oauth_start' THEN
      PERFORM allgres_private.require_admin_if_accounts_exist(p_request->>'session_token');
      v_id := (p_request->>'provider_id')::uuid;
      RETURN allgres_public.fn_oauth_start(v_id, p_request->>'redirect');

    -- Completes the flow: queues the token exchange (fn_oauth_token_request)
    -- rather than performing it inline, so the operator-facing return value
    -- is only {ok, queued, call_id, provider_id} -- never a token or the
    -- client secret. The runtime worker's HTTP pool picks the row up and
    -- fn_complete_oauth stores whatever comes back; settings.get's
    -- has_secret is how the dashboard finds out it landed.
    WHEN 'providers.oauth_callback' THEN
      PERFORM allgres_private.require_admin_if_accounts_exist(p_request->>'session_token');
      RETURN allgres_public.fn_oauth_token_request(
        p_request->>'state', p_request->>'code', p_request->>'redirect'
      );

    WHEN 'events' THEN
      RETURN jsonb_build_object(
        'ok', true,
        'server_time', now(),
        'tasks', COALESCE((
          SELECT jsonb_agg(to_jsonb(q) ORDER BY q.updated_at DESC)
          FROM (
            SELECT t.task_id, a.name AS agent, t.status, t.step_count, t.updated_at,
                   left(COALESCE(t.error,''), 240) AS error
            FROM allgres_private.tasks t
            JOIN allgres_private.agents a USING (agent_id)
            JOIN allgres_private.sessions s USING (session_id)
            WHERE s.goal NOT LIKE 'selftest%'
            ORDER BY t.updated_at DESC LIMIT 12
          ) q
        ), '[]'::jsonb),
        'logs', COALESCE((
          SELECT jsonb_agg(to_jsonb(q) ORDER BY q.created_at DESC)
          FROM (
            SELECT l.log_id, l.task_id, l.step_number, l.role, l.content, l.created_at
            FROM allgres_private.execution_logs l
            JOIN allgres_private.tasks t USING (task_id)
            JOIN allgres_private.sessions s USING (session_id)
            WHERE s.goal NOT LIKE 'selftest%'
            ORDER BY l.created_at DESC LIMIT 15
          ) q
        ), '[]'::jsonb)
      );

    WHEN 'approvals.list' THEN
      v_scope := allgres_private.visible_agent_ids(p_request->>'session_token');
      RETURN jsonb_build_object('ok', true, 'approvals', COALESCE((
        SELECT jsonb_agg(to_jsonb(q) ORDER BY q.created_at)
        FROM (
          SELECT h.approval_id, h.task_id, t.session_id, a.name AS agent,
                 s.goal, h.payload->>'reason' AS reason,
                 h.created_at, h.expires_at
          FROM allgres_private.human_approvals h
          JOIN allgres_private.tasks t USING (task_id)
          JOIN allgres_private.agents a USING (agent_id)
          JOIN allgres_private.sessions s USING (session_id)
          WHERE h.status = 'pending'
            AND (v_scope IS NULL OR t.agent_id = ANY(v_scope))
          ORDER BY h.created_at
          LIMIT LEAST(GREATEST(COALESCE((p_request->>'limit')::int, 100), 1), 500)
        ) q
      ), '[]'::jsonb));

    WHEN 'approvals.decide' THEN
      v_scope := allgres_private.visible_agent_ids(p_request->>'session_token');
      IF v_scope IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM allgres_private.human_approvals h
        JOIN allgres_private.tasks t USING (task_id)
        WHERE h.approval_id = (p_request->>'approval_id')::uuid AND t.agent_id = ANY(v_scope)
      ) THEN
        RAISE EXCEPTION 'approval not visible to this user' USING ERRCODE = 'P0001';
      END IF;
      RETURN allgres_public.fn_decide_approval(
        (p_request->>'approval_id')::uuid,
        (p_request->>'accept')::boolean,
        NULLIF(p_request->>'reply', '')
      );

    WHEN 'selftest' THEN
      RETURN allgres_public.fn_selftest();

    ELSE
      RETURN jsonb_build_object('ok', false, 'error', 'unknown_action', 'action', v_action);
  END CASE;
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM, 'sqlstate', SQLSTATE);
END;
$fn$;

REVOKE ALL ON FUNCTION allgres.dashboard_rpc(jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION allgres.dashboard_rpc(jsonb) TO operator, worker;

-- analyze_sql only parses, but there is no reason for the sandbox to reach it.
REVOKE ALL ON FUNCTION allgres.analyze_sql(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION allgres.analyze_sql(text) TO operator, worker;

-- ---------------------------------------------------------------------------
-- 14. Final ownership pass.
-- ---------------------------------------------------------------------------

-- "12. Grants" runs its ownership-transfer pass before this section exists --
-- on a fresh install, allgres.create_agent/create_session/pump/
-- assume_worker_role/dashboard_rpc and the allgres.agents/tasks/projects
-- views are all created after that pass already ran, so they were never
-- caught by it and stayed owned by whichever superuser ran CREATE
-- EXTENSION -- confirmed live by a second-round review, then reproduced
-- here: a fresh install left exactly those objects, and no others, owned
-- by the installer instead of allgres_owner. An upgrade from a real 0.2.0
-- install did not show this, since those objects already existed (under
-- their old owner from that install's own history) before this file's
-- ownership pass ran at all -- fresh-install-only bugs like this are
-- exactly what testing only the upgrade path misses.
--
-- Same logic as "12. Grants", not duplicated by hand: literally the same
-- extension-membership-scoped, idempotent pass, run again now that every
-- object in the file (this section included) actually exists. A no-op for
-- anything the first pass already caught.
DO $$
DECLARE r record;
BEGIN
  FOR r IN
    SELECT n.nspname, c.relname, c.relkind
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    JOIN pg_depend d ON d.classid = 'pg_class'::regclass AND d.objid = c.oid AND d.deptype = 'e'
    JOIN pg_extension e ON e.oid = d.refobjid AND e.extname = 'allgres'
    WHERE n.nspname IN ('allgres_private', 'allgres_public', 'allgres')
      AND c.relkind IN ('r', 'v', 'S')
      AND c.relowner <> 'allgres_owner'::regrole
  LOOP
    EXECUTE format(
      'ALTER %s %I.%I OWNER TO allgres_owner',
      CASE r.relkind WHEN 'r' THEN 'TABLE' WHEN 'v' THEN 'VIEW' WHEN 'S' THEN 'SEQUENCE' END,
      r.nspname, r.relname
    );
  END LOOP;

  FOR r IN
    SELECT p.oid::regprocedure AS sig, p.proname
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    JOIN pg_depend d ON d.classid = 'pg_proc'::regclass AND d.objid = p.oid AND d.deptype = 'e'
    JOIN pg_extension e ON e.oid = d.refobjid AND e.extname = 'allgres'
    WHERE n.nspname IN ('allgres_private', 'allgres_public', 'allgres')
      AND p.proowner <> 'allgres_owner'::regrole
      AND p.proname <> 'fn_provision_agent_role'
  LOOP
    EXECUTE format('ALTER FUNCTION %s OWNER TO allgres_owner', r.sig);
  END LOOP;

  IF (SELECT nspowner FROM pg_namespace WHERE nspname = 'allgres') <> 'allgres_owner'::regrole THEN
    ALTER SCHEMA allgres OWNER TO allgres_owner;
  END IF;
END
$$;
