-- Allgres 0.1.0 control plane -- section 9b: the operator API's session,
-- schedule, provider, connection, OAuth, and embedding-queue surface.
--
-- Split out alongside sql/operator_agents_and_policies.sql (see that
-- file's own header for why, and KNOWN_ISSUES.md item 38). Loaded after
-- it (`requires = ["operator_agents_and_policies"]`) -- same forward-
-- reference tolerance applies (LANGUAGE plpgsql throughout); chained
-- sequentially here purely to mirror this content's original position in
-- one file, not because anything in this file actually calls into the
-- previous one at CREATE time. Loaded before sql/operator_accounts_and_
-- chat.sql.
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

CREATE OR REPLACE FUNCTION allgres_public.fn_create_procedure_tool(
  p_name text, p_description text, p_handler text, p_args_template jsonb
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = allgres_private, pg_temp
AS $fn$
DECLARE
  v_name text := lower(trim(COALESCE(p_name, '')));
  v_url text;
  v_reason text;
  v_id uuid;
BEGIN
  IF v_name !~ '^[a-z][a-z0-9_]{0,62}$' THEN
    RAISE EXCEPTION 'tool name must use lowercase letters, digits, and underscores' USING ERRCODE = 'P0001';
  END IF;
  IF NULLIF(trim(p_description), '') IS NULL THEN
    RAISE EXCEPTION 'tool description is required' USING ERRCODE = 'P0001';
  END IF;
  IF p_handler <> 'http_get' THEN
    RAISE EXCEPTION 'only the http_get tool handler is supported' USING ERRCODE = 'P0001';
  END IF;
  IF p_args_template IS NULL
    OR jsonb_typeof(p_args_template) <> 'object'
    OR p_args_template ?| ARRAY(SELECT key FROM jsonb_object_keys(p_args_template) key WHERE key <> 'url') THEN
    RAISE EXCEPTION 'http_get tool arguments must contain only url' USING ERRCODE = 'P0001';
  END IF;
  v_url := NULLIF(trim(p_args_template->>'url'), '');
  v_reason := allgres_private.check_outbound_url(v_url, false);
  IF v_reason IS NOT NULL THEN
    RAISE EXCEPTION 'invalid tool URL: %', v_reason USING ERRCODE = 'P0001';
  END IF;
  INSERT INTO allgres_private.procedure_tools (name, description, handler, args_template)
  VALUES (v_name, trim(p_description), p_handler, jsonb_build_object('url', v_url))
  RETURNING tool_id INTO v_id;
  PERFORM allgres_private.audit('procedure_tools.create', jsonb_build_object('tool_id', v_id, 'name', v_name));
  RETURN jsonb_build_object('ok', true, 'tool_id', v_id);
END;
$fn$;

CREATE OR REPLACE FUNCTION allgres_public.fn_bind_procedure_tool(p_procedure_id uuid, p_tool_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = allgres_private, pg_temp
AS $fn$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM allgres_private.procedures WHERE procedure_id = p_procedure_id) THEN
    RAISE EXCEPTION 'procedure not found' USING ERRCODE = 'P0001';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM allgres_private.procedure_tools WHERE tool_id = p_tool_id) THEN
    RAISE EXCEPTION 'tool not found' USING ERRCODE = 'P0001';
  END IF;
  INSERT INTO allgres_private.procedure_tool_bindings (procedure_id, tool_id)
  VALUES (p_procedure_id, p_tool_id) ON CONFLICT DO NOTHING;
  PERFORM allgres_private.audit('procedure_tools.bind', jsonb_build_object('procedure_id', p_procedure_id, 'tool_id', p_tool_id));
  RETURN jsonb_build_object('ok', true);
END;
$fn$;

-- Starts an RFC 8628 device authorization request.  The worker performs the
-- HTTP call; this function only creates durable state and queues it.
CREATE OR REPLACE FUNCTION allgres_public.fn_oauth_device_start(p_provider_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = allgres_private, pg_temp
AS $fn$
DECLARE
  v allgres_private.llm_providers%ROWTYPE;
  v_session uuid;
  v_call uuid;
  v_reason text;
BEGIN
  SELECT * INTO v FROM allgres_private.llm_providers WHERE provider_id = p_provider_id;
  IF v.provider_id IS NULL OR v.kind <> 'oauth' OR v.oauth_flow <> 'device_code' THEN
    RAISE EXCEPTION 'provider is not device-code oauth' USING ERRCODE = 'P0001';
  END IF;
  IF v.oauth_device_url IS NULL OR v.oauth_token_url IS NULL OR v.oauth_client_id IS NULL THEN
    RAISE EXCEPTION 'device url / token url / client id missing' USING ERRCODE = 'P0001';
  END IF;
  v_reason := allgres_private.check_outbound_url(v.oauth_device_url, v.allow_private_network);
  IF v_reason IS NOT NULL THEN
    RAISE EXCEPTION 'oauth device url rejected: %', v_reason USING ERRCODE = 'P0001';
  END IF;

  -- Serialize starts per provider so two dashboard clicks cannot leave two
  -- live device codes racing to replace the same provider token.
  PERFORM pg_advisory_xact_lock(hashtextextended(p_provider_id::text, 0));

  -- Supersede unfinished attempts for the same provider.  Their device codes
  -- are single-purpose and expire quickly; keeping them active would create
  -- ambiguous status in the dashboard.
  UPDATE allgres_private.oauth_calls
  SET status='harvested', error='superseded by a newer login', updated_at=now()
  WHERE device_session_id IN (
    SELECT session_id FROM allgres_private.oauth_device_sessions
    WHERE provider_id=p_provider_id AND status IN ('starting','awaiting_user')
  ) AND status IN ('queued','in_flight');

  UPDATE allgres_private.oauth_device_sessions
  SET status = 'expired', error = 'superseded by a newer login', updated_at = now()
  WHERE provider_id = p_provider_id AND status IN ('starting','awaiting_user');

  INSERT INTO allgres_private.oauth_device_sessions(provider_id)
  VALUES (p_provider_id) RETURNING session_id INTO v_session;

  INSERT INTO allgres_private.oauth_calls
    (provider_id, state, url, request_headers, request_body, allow_private,
     status, operation, device_session_id)
  VALUES (
    p_provider_id, v_session::text, v.oauth_device_url,
    jsonb_build_object('accept','application/json'),
    jsonb_strip_nulls(jsonb_build_object('client_id',v.oauth_client_id,'scope',v.oauth_scope)),
    v.allow_private_network, 'queued', 'device_authorization', v_session
  ) RETURNING call_id INTO v_call;

  PERFORM allgres_private.audit('providers.oauth_device_start', jsonb_build_object('provider_id', p_provider_id, 'session_id', v_session));
  RETURN jsonb_build_object('ok',true,'session_id',v_session,'call_id',v_call,'status','starting');
END;
$fn$;

CREATE OR REPLACE FUNCTION allgres_public.fn_oauth_device_status(p_session_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = allgres_private, pg_temp
AS $fn$
DECLARE
  s allgres_private.oauth_device_sessions%ROWTYPE;
BEGIN
  SELECT * INTO s FROM allgres_private.oauth_device_sessions WHERE session_id = p_session_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'oauth device session not found' USING ERRCODE = 'P0001';
  END IF;
  RETURN jsonb_strip_nulls(jsonb_build_object(
    'ok', true, 'session_id', s.session_id, 'provider_id', s.provider_id,
    'status', s.status, 'user_code', s.user_code,
    'verification_uri', s.verification_uri,
    'verification_uri_complete', s.verification_uri_complete,
    'expires_at', s.expires_at, 'error', s.error
  ));
END;
$fn$;

-- Called from fn_claim_oauth.  It turns due device polls and expiring access
-- tokens into ordinary durable oauth_calls, with sensitive device/refresh
-- credentials added only later at claim time.
CREATE OR REPLACE FUNCTION allgres_private.queue_oauth_maintenance()
RETURNS int
LANGUAGE plpgsql
SET search_path = allgres_private, pg_temp
AS $fn$
DECLARE
  n int := 0;
  m int := 0;
BEGIN
  UPDATE allgres_private.oauth_device_sessions
  SET status='expired', error='device authorization expired', updated_at=now()
  WHERE status='awaiting_user' AND expires_at <= now();

  INSERT INTO allgres_private.oauth_calls
    (provider_id,state,url,request_headers,request_body,allow_private,status,operation,device_session_id)
  SELECT d.provider_id, d.session_id::text, p.oauth_token_url,
         jsonb_build_object('accept','application/json'),
         jsonb_build_object(
           'grant_type','urn:ietf:params:oauth:grant-type:device_code',
           'client_id',p.oauth_client_id
         ),
         p.allow_private_network,'queued','device_poll',d.session_id
  FROM allgres_private.oauth_device_sessions d
  JOIN allgres_private.llm_providers p USING(provider_id)
  WHERE d.status='awaiting_user' AND d.expires_at > now()
    AND COALESCE(d.next_poll_at,now()) <= now()
    AND NOT EXISTS (
      SELECT 1 FROM allgres_private.oauth_calls c
      WHERE c.device_session_id=d.session_id AND c.operation='device_poll'
        AND c.status IN ('queued','in_flight')
    );
  GET DIAGNOSTICS n = ROW_COUNT;

  UPDATE allgres_private.oauth_device_sessions d
  SET next_poll_at = now() + make_interval(secs=>d.interval_seconds), updated_at=now()
  WHERE d.status='awaiting_user' AND d.expires_at > now()
    AND COALESCE(d.next_poll_at,now()) <= now();

  INSERT INTO allgres_private.oauth_calls
    (provider_id,state,url,request_headers,request_body,allow_private,status,operation)
  SELECT p.provider_id, replace(gen_random_uuid()::text,'-',''), p.oauth_token_url,
         jsonb_build_object('accept','application/json'),
         jsonb_build_object('grant_type','refresh_token','client_id',p.oauth_client_id),
         p.allow_private_network,'queued','refresh'
  FROM allgres_private.llm_providers p
  JOIN allgres_private.llm_secrets s USING(provider_id)
  WHERE p.kind='oauth' AND p.is_enabled
    AND s.refresh_token IS NOT NULL
    AND s.expires_at IS NOT NULL AND s.expires_at <= now()+interval '2 minutes'
    AND NOT EXISTS (
      SELECT 1 FROM allgres_private.oauth_calls c
      WHERE c.provider_id=p.provider_id AND c.operation='refresh'
        AND (c.status IN ('queued','in_flight')
             OR c.created_at > now()-interval '30 seconds')
    );
  GET DIAGNOSTICS m = ROW_COUNT;
  n := n + m;
  RETURN n;
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
  IF v.oauth_flow = 'device_code' THEN
    RAISE EXCEPTION 'provider uses device-code oauth' USING ERRCODE = 'P0001';
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
  v_sensitive text;
  v_body jsonb;
BEGIN
  PERFORM set_config('statement_timeout', '2000', true);
  PERFORM allgres_private.queue_oauth_maintenance();
  FOR r IN
    SELECT call_id, provider_id, url, request_headers, request_body, allow_private,
           operation, device_session_id
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
    v_body := r.request_body;
    IF NULLIF(v_secret,'') IS NOT NULL THEN
      v_body := v_body || jsonb_build_object('client_secret',v_secret);
    END IF;
    IF r.operation = 'device_poll' THEN
      SELECT allgres_private.decrypt_secret(device_code) INTO v_sensitive
      FROM allgres_private.oauth_device_sessions WHERE session_id=r.device_session_id;
      v_body := v_body || jsonb_build_object('device_code',COALESCE(v_sensitive,''));
    ELSIF r.operation = 'refresh' THEN
      SELECT allgres_private.decrypt_secret(refresh_token) INTO v_sensitive
      FROM allgres_private.llm_secrets WHERE provider_id=r.provider_id;
      v_body := v_body || jsonb_build_object('refresh_token',COALESCE(v_sensitive,''));
    END IF;
    v_out := v_out || jsonb_build_array(jsonb_build_object(
      'call_id', r.call_id,
      'operation', r.operation,
      'device_session_id', r.device_session_id,
      'url', r.url,
      'headers', r.request_headers,
      'body', v_body,
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

  BEGIN
    v_parsed := p_body::jsonb;
  EXCEPTION WHEN others THEN
    v_parsed := NULL;
  END;

  -- The first device-flow response contains instructions, not tokens.
  IF c.operation = 'device_authorization' AND p_status BETWEEN 200 AND 299 THEN
    IF NULLIF(v_parsed->>'device_code','') IS NULL
       OR NULLIF(v_parsed->>'user_code','') IS NULL
       OR NULLIF(v_parsed->>'verification_uri','') IS NULL THEN
      UPDATE allgres_private.oauth_device_sessions
      SET status='error', error='invalid device authorization response', updated_at=now()
      WHERE session_id=c.device_session_id;
    ELSE
      UPDATE allgres_private.oauth_device_sessions
      SET device_code=allgres_private.encrypt_secret(v_parsed->>'device_code'),
          user_code=v_parsed->>'user_code',
          verification_uri=v_parsed->>'verification_uri',
          verification_uri_complete=NULLIF(v_parsed->>'verification_uri_complete',''),
          interval_seconds=LEAST(GREATEST(CASE WHEN v_parsed->>'interval' ~ '^[0-9]{1,9}$'
                                              THEN (v_parsed->>'interval')::int ELSE 5 END,1),60),
          expires_at=now()+make_interval(secs=>CASE WHEN v_parsed->>'expires_in' ~ '^[0-9]{1,9}$'
                                                    THEN (v_parsed->>'expires_in')::int ELSE 900 END),
          next_poll_at=now()+make_interval(secs=>LEAST(GREATEST(
            CASE WHEN v_parsed->>'interval' ~ '^[0-9]{1,9}$'
                 THEN (v_parsed->>'interval')::int ELSE 5 END,1),60)),
          status='awaiting_user', error=NULL, updated_at=now()
      WHERE session_id=c.device_session_id;
    END IF;
    UPDATE allgres_private.oauth_calls
    SET status='harvested', response_status=p_status, updated_at=now()
    WHERE call_id=p_call_id;
    RETURN jsonb_build_object('action','device_authorization_ready','session_id',c.device_session_id);
  END IF;

  -- RFC 8628 returns authorization_pending/slow_down as ordinary HTTP 400
  -- responses.  They are progress states, not failed logins.
  IF c.operation = 'device_poll' AND p_status >= 400 THEN
    IF v_parsed->>'error' IN ('authorization_pending','slow_down') THEN
      UPDATE allgres_private.oauth_device_sessions
      SET interval_seconds=CASE WHEN v_parsed->>'error'='slow_down'
                                THEN LEAST(interval_seconds+5,60) ELSE interval_seconds END,
          next_poll_at=now()+make_interval(secs=>CASE WHEN v_parsed->>'error'='slow_down'
                                THEN LEAST(interval_seconds+5,60) ELSE interval_seconds END),
          updated_at=now()
      WHERE session_id=c.device_session_id AND status='awaiting_user';
      UPDATE allgres_private.oauth_calls
      SET status='harvested', response_status=p_status, updated_at=now()
      WHERE call_id=p_call_id;
      RETURN jsonb_build_object('action','pending','reason',v_parsed->>'error');
    END IF;
    UPDATE allgres_private.oauth_device_sessions
    SET status=CASE WHEN v_parsed->>'error'='access_denied' THEN 'denied'
                    WHEN v_parsed->>'error'='expired_token' THEN 'expired' ELSE 'error' END,
        error=left(COALESCE(v_parsed->>'error_description',v_parsed->>'error',p_body,''),500),
        updated_at=now()
    WHERE session_id=c.device_session_id;
  END IF;

  IF p_status IS NULL OR p_status < 200 OR p_status >= 300 THEN
    IF c.operation = 'device_authorization' THEN
      UPDATE allgres_private.oauth_device_sessions
      SET status='error', error=left(COALESCE(v_parsed->>'error_description',v_parsed->>'error',p_body,''),500),
          updated_at=now()
      WHERE session_id=c.device_session_id;
    END IF;
    UPDATE allgres_private.oauth_calls
    SET status = 'harvested', response_status = p_status,
        error = left(COALESCE(p_body, ''), 2000), updated_at = now()
    WHERE call_id = p_call_id;
    RETURN jsonb_build_object('action', 'error', 'status', p_status);
  END IF;

  v_access := NULLIF(v_parsed->>'access_token', '');
  v_refresh := NULLIF(v_parsed->>'refresh_token', '');
  v_expires_in := CASE WHEN v_parsed->>'expires_in' ~ '^[0-9]{1,9}$'
                       THEN (v_parsed->>'expires_in')::int END;

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

  IF c.operation = 'device_poll' THEN
    UPDATE allgres_private.oauth_device_sessions
    SET status='connected', error=NULL, updated_at=now()
    WHERE session_id=c.device_session_id;
  END IF;

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
