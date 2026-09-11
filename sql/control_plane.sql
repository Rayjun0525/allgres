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
-- This file is the single canonical definition of the control plane's core
-- (sections 1-8 below). Every object is defined exactly once, in
-- dependency order; there are no superseded copies left behind by earlier
-- migrations. The file is idempotent, so it can be replayed as an `ALTER
-- EXTENSION ... UPDATE` script (see scripts/gen-upgrade.sh).
--
-- Sections 9-14 (the operator API, seed data, selftest, grants, the
-- allgres facade + dashboard RPC, and the final ownership pass) live in
-- six other files instead -- split out once this file alone grew large
-- enough to trip a real rustc compile-time safety lint on the pgrx macro
-- that embeds it (see KNOWN_ISSUES.md item 38). All seven files are loaded
-- in this exact order (src/lib.rs's extension_sql_file! calls, chained
-- with `requires` so pgrx enforces it regardless of declaration order) --
-- together they behave as exactly one file always has: any of them can
-- forward-reference anything in an earlier one (a PL/pgSQL function body
-- is never validated against the catalog until it is actually called,
-- long after every file has finished loading), and the ownership-fixing
-- pass/REVOKEs in the last file correctly find every function every
-- earlier file defines because each one is required to load before it.
--
-- Layout:
--   1. roles                                              (this file)
--   2. schemas, tables, indexes, triggers                 (this file)
--   3. generic helpers                                    (this file)
--   4. outbound URL / host guards                         (this file)
--   5. provider secret storage                             (this file)
--   6. SQL sandbox                                         (this file)
--   7. agent state machine                                 (this file)
--   8. pump                                                 (this file)
--   9a. operator API: agents, projects, policies,
--       procedures, permissions, fixes    (sql/operator_agents_and_policies.sql)
--   9b. operator API: sessions, schedules, providers,
--       connections, OAuth, embeddings    (sql/operator_runtime_and_integrations.sql)
--   9c. operator API: approvals, allowlist, memories,
--       accounts/auth, chat/messenger     (sql/operator_accounts_and_chat.sql)
--  10. seed data                          (sql/seed_data.sql)
--  10b. extension configuration tables    (sql/seed_data.sql)
--  11. selftest                           (sql/selftest.sql)
--  12. grants                             (sql/grants_and_facade.sql)
--  13. allgres facade + dashboard RPC     (sql/grants_and_facade.sql)
--  14. final ownership pass               (sql/grants_and_facade.sql)

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

-- A Tool Function is a named, reusable execution contract.  Version one is
-- deliberately narrow: it can only invoke the existing asynchronous
-- http_get runtime with a fixed operator-reviewed URL.  This makes a
-- procedure grant meaningful without giving an agent arbitrary SQL/function
-- execution or an unrestricted network capability.
CREATE TABLE IF NOT EXISTS allgres_private.procedure_tools (
  tool_id       uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name          text NOT NULL UNIQUE CHECK (name ~ '^[a-z][a-z0-9_]{0,62}$'),
  description   text NOT NULL,
  handler       text NOT NULL CHECK (handler IN ('http_get')),
  args_template jsonb NOT NULL DEFAULT '{}'::jsonb,
  is_active     boolean NOT NULL DEFAULT true,
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS allgres_private.procedure_tool_bindings (
  procedure_id uuid NOT NULL REFERENCES allgres_private.procedures(procedure_id) ON DELETE CASCADE,
  tool_id      uuid NOT NULL REFERENCES allgres_private.procedure_tools(tool_id) ON DELETE CASCADE,
  PRIMARY KEY (procedure_id, tool_id)
);

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

-- OAuth providers can use the original authorization-code redirect flow or
-- an RFC 8628 device-code flow.  Device-code is what xAI exposes for a
-- browser login that works from a headless/containerized Allgres worker.
ALTER TABLE allgres_private.llm_providers
  ADD COLUMN IF NOT EXISTS oauth_flow text NOT NULL DEFAULT 'authorization_code'
    CHECK (oauth_flow IN ('authorization_code', 'device_code')),
  ADD COLUMN IF NOT EXISTS oauth_device_url text;

CREATE TABLE IF NOT EXISTS allgres_private.oauth_states (
  state        text PRIMARY KEY,
  provider_id  uuid NOT NULL REFERENCES allgres_private.llm_providers(provider_id) ON DELETE CASCADE,
  created_at   timestamptz NOT NULL DEFAULT now()
);

-- The device_code is a short-lived bearer credential, so it receives the
-- same encrypted-at-rest treatment as access/refresh tokens.  user_code and
-- verification URLs are intentionally returned to the dashboard: they are
-- the public instructions the operator must see to approve the login.
CREATE TABLE IF NOT EXISTS allgres_private.oauth_device_sessions (
  session_id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  provider_id               uuid NOT NULL REFERENCES allgres_private.llm_providers(provider_id) ON DELETE CASCADE,
  device_code               text,
  user_code                 text,
  verification_uri          text,
  verification_uri_complete text,
  status                    text NOT NULL DEFAULT 'starting'
                              CHECK (status IN ('starting','awaiting_user','connected','denied','expired','error')),
  interval_seconds          int NOT NULL DEFAULT 5 CHECK (interval_seconds BETWEEN 1 AND 60),
  expires_at                timestamptz,
  next_poll_at              timestamptz,
  error                     text,
  created_at                timestamptz NOT NULL DEFAULT now(),
  updated_at                timestamptz NOT NULL DEFAULT now()
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

ALTER TABLE allgres_private.oauth_calls
  ADD COLUMN IF NOT EXISTS operation text NOT NULL DEFAULT 'token_exchange'
    CHECK (operation IN ('token_exchange','device_authorization','device_poll','refresh')),
  ADD COLUMN IF NOT EXISTS device_session_id uuid
    REFERENCES allgres_private.oauth_device_sessions(session_id) ON DELETE CASCADE;

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
  -- OAuth exchanges store an access_token rather than an api_key.  Keeping
  -- the choice in this private claim-time helper means neither credential is
  -- ever copied into outbound_calls or returned to the dashboard.
  SELECT allgres_private.decrypt_secret(COALESCE(api_key, access_token))
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
  v_procedure_tools jsonb;
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

  -- A procedure grant also exposes its reviewed Tool Functions.  Keep these
  -- structured rather than merely appending their names: the model receives
  -- the exact fixed arguments and cannot substitute a host or URL.
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'name', pt.name, 'description', pt.description, 'handler', pt.handler,
    'args', pt.args_template, 'procedure', pr.name
  ) ORDER BY pt.name), '[]'::jsonb)
  INTO v_procedure_tools
  FROM allgres_private.procedure_tools pt
  JOIN allgres_private.procedure_tool_bindings pb USING (tool_id)
  JOIN allgres_private.procedures pr USING (procedure_id)
  WHERE pt.is_active AND pr.is_active
    AND pr.name = ANY(allgres_private.agent_permission_refs(t.agent_id, 'procedure'));
  v_tools := v_tools || v_procedure_tools;

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
  v_procedure_tool allgres_private.procedure_tools%ROWTYPE;
  v_procedure_bound boolean := false;
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
    -- Some OpenAI-compatible models follow the action correctly but name
    -- the payload `content` (or repeat the action name as `final_answer`).
    -- Treat those common shapes as aliases instead of silently completing a
    -- task with an empty answer.  A genuinely missing/empty payload remains
    -- invalid and gets another model step.
    v_answer := COALESCE(
      NULLIF(v_parsed->>'answer', ''),
      NULLIF(v_parsed->>'content', ''),
      NULLIF(v_parsed->>'final_answer', '')
    );
    IF v_answer IS NULL THEN
      PERFORM allgres_private.append_log(
        p_task_id, t.step_count + 1, 'error',
        jsonb_build_object('reason', 'final_answer_missing_answer', 'parsed', v_parsed)
      );
      UPDATE allgres_private.tasks
      SET step_count = step_count + 1, updated_at = now()
      WHERE task_id = p_task_id;
      RETURN jsonb_build_object('action', 'continue', 'reason', 'final_answer_missing_answer');
    END IF;
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
      SELECT pt.* INTO v_procedure_tool
      FROM allgres_private.procedure_tools pt
      JOIN allgres_private.procedure_tool_bindings pb USING (tool_id)
      JOIN allgres_private.procedures pr USING (procedure_id)
      WHERE lower(pt.name) = lower(COALESCE(v_tool, ''))
        AND pt.is_active AND pr.is_active
        AND pr.name = ANY(allgres_private.agent_permission_refs(t.agent_id, 'procedure'))
      LIMIT 1;
      IF FOUND THEN
        v_procedure_bound := true;
        v_tool := v_procedure_tool.handler;
        v_args := v_procedure_tool.args_template;
        v_allowed := true;
      ELSE
        PERFORM allgres_private.append_log(
          p_task_id, t.step_count + 1, 'error',
          jsonb_build_object('reason', 'tool_not_permitted', 'tool', v_tool)
        );
        UPDATE allgres_private.tasks
        SET step_count = step_count + 1, updated_at = now()
        WHERE task_id = p_task_id;
        RETURN jsonb_build_object('action', 'continue');
      END IF;
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
    v_allowed := v_procedure_bound
      OR allgres_private.agent_has_permission(t.agent_id, 'http_host', v_host);
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
      -- Do not send an expired OAuth token. fn_claim_oauth runs on the same
      -- worker loop and queues/claims its refresh; this LLM row remains
      -- durable and becomes claimable as soon as the rotated token lands.
      AND (p.kind IS DISTINCT FROM 'oauth' OR EXISTS (
        SELECT 1 FROM allgres_private.llm_secrets s
        WHERE s.provider_id=o.provider_id AND s.access_token IS NOT NULL
          AND (s.expires_at IS NULL OR s.expires_at > now()+interval '30 seconds')
      ))
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

