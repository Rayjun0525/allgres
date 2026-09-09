-- Allgres 0.1.0 control plane -- section 9a: the operator API's agent,
-- project, policy, procedure, permission, and fix surface.
--
-- Split out of sql/control_plane.sql alongside the other operator-API
-- files once that single file grew large enough to trip a real rustc
-- compile-time safety lint (KNOWN_ISSUES.md item 38). Loaded after
-- sql/control_plane.sql (src/lib.rs's extension_sql_file! declares
-- `requires = ["control_plane"]`) -- every function here is LANGUAGE
-- plpgsql, so nothing inside a body is checked against the catalog until
-- it is actually called, long after every file has finished loading; this
-- file's own DDL (the CREATE FUNCTION statements themselves) only needs
-- the tables/types sections 1-8 define. Loaded before sql/operator_
-- runtime_and_integrations.sql.
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

