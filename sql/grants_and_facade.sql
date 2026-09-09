-- Allgres 0.1.0 control plane -- sections 12-14: grants, the allgres facade
-- + dashboard RPC, and the final ownership pass.
--
-- Split out of sql/control_plane.sql alongside sql/selftest.sql once that
-- single file grew large enough to trip a real rustc compile-time safety
-- lint on the pgrx macro that embeds it (KNOWN_ISSUES.md item 38). Loaded
-- last (src/lib.rs's extension_sql_file! declares `requires =
-- ["selftest"]`, transitively after sql/control_plane.sql too): section
-- 12's REVOKEs and its own ownership-fixing catalog scan need every
-- function from both earlier files to already exist, and section 14's
-- final ownership pass needs literally everything -- the entire reason it
-- runs last.
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
