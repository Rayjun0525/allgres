\set ON_ERROR_STOP on

CREATE EXTENSION IF NOT EXISTS allgres;

SELECT allgres.native_version();
SELECT (allgres.native_status()->>'name') = 'Allgres' AS branded;

-- The full invariant suite, including the SQL sandbox and the outbound guard.
SELECT argo_public.fn_selftest();

DO $$
DECLARE r jsonb;
BEGIN
  r := argo_public.fn_selftest();
  IF (r->>'failed')::int > 0 THEN
    RAISE EXCEPTION 'selftest failures: %',
      (SELECT string_agg(e->>'name', ', ') FROM jsonb_array_elements(r->'cases') e
       WHERE NOT (e->>'ok')::boolean);
  END IF;
END $$;

SELECT (allgres.dashboard_rpc('{"action":"overview"}'::jsonb)->>'ok')::boolean AS dashboard_overview_ok;
SELECT jsonb_array_length(allgres.dashboard_rpc('{"action":"agents.list"}'::jsonb)->'agents') >= 1 AS dashboard_agents_ok;

-- The dashboard RPC must never hand back a provider secret.
DO $$
DECLARE r jsonb;
BEGIN
  PERFORM argo_public.fn_set_provider_secret(
    (SELECT provider_id FROM argo_private.llm_providers WHERE name = 'openai'), 'sk-smoke-test-key');
  r := allgres.dashboard_rpc('{"action":"settings.get"}'::jsonb);
  IF r::text LIKE '%sk-smoke-test-key%' THEN
    RAISE EXCEPTION 'settings.get leaked a provider secret';
  END IF;
  IF NOT (r->'providers' @> '[{"name":"openai","has_secret":true}]'::jsonb) THEN
    RAISE EXCEPTION 'settings.get did not report the stored secret';
  END IF;
END $$;

-- What settings.get reports about secret storage must match what is on disk.
-- Reporting "encrypted" while storing plaintext is worse than reporting
-- plaintext, so this asserts the stored bytes, not the claim.
DO $$
DECLARE
  v_mode text := argo_private.secret_storage_mode();
  v_raw  text;
BEGIN
  SELECT s.api_key INTO v_raw
  FROM argo_private.llm_secrets s
  JOIN argo_private.llm_providers p USING (provider_id)
  WHERE p.name = 'openai';

  IF v_mode = 'encrypted' THEN
    IF left(v_raw, 7) <> 'enc:v1:' THEN
      RAISE EXCEPTION 'secret_storage_mode reports encrypted but the stored key is plaintext';
    END IF;
    IF v_raw LIKE '%sk-smoke-test-key%' THEN
      RAISE EXCEPTION 'ciphertext still contains the plaintext key';
    END IF;
    IF argo_private.provider_secret(
         (SELECT provider_id FROM argo_private.llm_providers WHERE name = 'openai')
       ) <> 'sk-smoke-test-key' THEN
      RAISE EXCEPTION 'encrypted secret did not round-trip';
    END IF;
  ELSIF v_mode NOT IN ('plaintext_no_key', 'plaintext_no_pgcrypto') THEN
    RAISE EXCEPTION 'unexpected secret storage mode: %', v_mode;
  END IF;
END $$;

-- The sandbox role is actually assumed for agent SQL, not just documented as
-- the intent.  fn_execute_sql used to validate *and* run the query as its own
-- SECURITY DEFINER owner, because PostgreSQL refuses SET ROLE inside one; that
-- is why this has to happen here, top level, exactly as the runtime worker
-- does it (src/lib.rs's run_sandboxed_sql), not inside fn_selftest (also
-- SECURITY DEFINER, so it could not prove this either).
DO $$
DECLARE
  v_agent uuid;
  v_sql   text;
  v_result jsonb;
BEGIN
  SELECT agent_id INTO v_agent FROM argo_private.agents WHERE name = 'analyst' LIMIT 1;
  v_sql := argo_private.fn_validate_sql(v_agent, 'SELECT region FROM argo_public.v_sales');

  SET LOCAL ROLE sandbox;
  SET LOCAL search_path = pg_temp;
  SET LOCAL transaction_read_only = on;
  SET LOCAL statement_timeout = '5s';
  PERFORM set_config('argo.agent_id', v_agent::text, true);

  IF current_user <> 'sandbox' THEN
    RAISE EXCEPTION 'sandbox role was not assumed: current_user = %', current_user;
  END IF;

  v_result := argo_public.fn_run_sandboxed_sql(v_sql);
  IF NOT COALESCE((v_result->>'ok')::boolean, false) THEN
    RAISE EXCEPTION 'sandboxed execution failed: %', v_result->>'error';
  END IF;
  IF COALESCE(jsonb_array_length(v_result->'rows'), 0) = 0 THEN
    RAISE EXCEPTION 'sandboxed execution returned no rows';
  END IF;

  RESET ROLE;
END $$;

-- Per-agent PostgreSQL roles (fn_provision_agent_role): a persistent agent
-- created through fn_create_agent gets its own NOLOGIN role, and
-- fn_run_sandboxed_sql can run it as that role instead of the one shared
-- `sandbox` role every agent used to run as indistinguishably. Same
-- SECURITY DEFINER limitation as the block above keeps this out of
-- fn_selftest -- SET ROLE has to happen top level.
DO $$
DECLARE
  v_agent_a  uuid;
  v_role_a   text;
  v_agent_b  uuid;
  v_role_b   text;
  v_sql      text;
  v_result   jsonb;
BEGIN
  -- Reuse by name rather than creating fresh agents unconditionally: this
  -- script can run more than once against the same live database (not just
  -- once per fresh install), and agents.name is unique.
  SELECT agent_id INTO v_agent_a FROM argo_private.agents WHERE name = 'smoke_role_agent_a';
  IF NOT FOUND THEN
    v_agent_a := (argo_public.fn_create_agent('smoke_role_agent_a')->>'agent_id')::uuid;
  END IF;
  SELECT agent_id INTO v_agent_b FROM argo_private.agents WHERE name = 'smoke_role_agent_b';
  IF NOT FOUND THEN
    v_agent_b := (argo_public.fn_create_agent('smoke_role_agent_b')->>'agent_id')::uuid;
  END IF;
  SELECT pg_role INTO v_role_a FROM argo_private.agents WHERE agent_id = v_agent_a;
  SELECT pg_role INTO v_role_b FROM argo_private.agents WHERE agent_id = v_agent_b;
  IF v_role_a IS NULL THEN
    v_role_a := argo_private.fn_provision_agent_role(v_agent_a);
  END IF;
  IF v_role_b IS NULL THEN
    v_role_b := argo_private.fn_provision_agent_role(v_agent_b);
  END IF;
  IF v_role_a IS NULL OR v_role_b IS NULL OR v_role_a = v_role_b THEN
    RAISE EXCEPTION 'agents did not get distinct pg_role values: % / %', v_role_a, v_role_b;
  END IF;

  -- Give agent A exactly one task of its own (fn_create_session scopes the
  -- resulting task to whichever agent_id it is given), and none to agent B
  -- -- but grant BOTH the view permission, so the only thing standing
  -- between agent B and agent A's row is v_my_tasks's own
  -- `agent_id IS NOT DISTINCT FROM current_agent_id()` filter, not the
  -- separate permission-table check (already covered by
  -- views_enforce_permission in fn_selftest). This isolates exactly what
  -- changed in this pass: whether row visibility actually follows
  -- PostgreSQL role identity.
  IF NOT EXISTS (
    SELECT 1 FROM argo_private.tasks t JOIN argo_private.sessions s USING (session_id)
    WHERE s.goal = 'smoke role isolation probe' AND t.agent_id = v_agent_a
  ) THEN
    PERFORM argo_public.fn_create_session(v_agent_a, 'smoke role isolation probe');
  END IF;
  PERFORM argo_public.fn_grant_permission(v_agent_a, 'view', 'argo_public.v_my_tasks');
  PERFORM argo_public.fn_grant_permission(v_agent_b, 'view', 'argo_public.v_my_tasks');
  v_sql := argo_private.fn_validate_sql(v_agent_a, 'SELECT task_id FROM argo_public.v_my_tasks');

  EXECUTE format('SET LOCAL ROLE %I', v_role_a);
  IF current_user <> v_role_a THEN
    RAISE EXCEPTION 'agent role was not assumed: current_user = %, expected %', current_user, v_role_a;
  END IF;
  -- No argo.agent_id GUC set here on purpose: this proves role identity
  -- alone, not a GUC the worker would normally also set, resolves the right
  -- agent -- v_my_tasks's own definition calls
  -- argo_private.agent_may_read(), which needs current_agent_id(); neither
  -- is called directly here, the same as the real runtime worker never
  -- calls them directly either, only through the view.
  v_result := argo_public.fn_run_sandboxed_sql(v_sql);
  IF NOT COALESCE((v_result->>'ok')::boolean, false)
     OR COALESCE(jsonb_array_length(v_result->'rows'), 0) = 0 THEN
    RAISE EXCEPTION 'agent A could not see its own task: %', v_result;
  END IF;
  RESET ROLE;

  -- Same validated statement text, run as agent B's own role. Agent B has
  -- the same view permission as A but no task of its own, so
  -- v_my_tasks's row filter (re-evaluated at execution time against
  -- whoever current_agent_id() resolves to right now, not carried over
  -- from validating it as A) must return zero rows -- proving row
  -- visibility actually follows PostgreSQL role identity, not the query
  -- text or which agent it was granted to.
  EXECUTE format('SET LOCAL ROLE %I', v_role_b);
  IF current_user <> v_role_b THEN
    RAISE EXCEPTION 'agent role was not assumed: current_user = %, expected %', current_user, v_role_b;
  END IF;
  v_result := argo_public.fn_run_sandboxed_sql(v_sql);
  IF COALESCE(jsonb_array_length(v_result->'rows'), 0) <> 0 THEN
    RAISE EXCEPTION 'agent B saw agent A''s task, isolated only by role: %', v_result;
  END IF;
  RESET ROLE;
END $$;

-- transaction_read_only still blocks a write even when this execution
-- primitive is reached directly, bypassing fn_validate_sql -- defence in
-- depth, since fn_run_sandboxed_sql trusts its input completely.
DO $$
DECLARE v_result jsonb;
BEGIN
  SET LOCAL ROLE sandbox;
  SET LOCAL transaction_read_only = on;
  v_result := argo_public.fn_run_sandboxed_sql('INSERT INTO argo_private.sessions DEFAULT VALUES');
  IF COALESCE((v_result->>'ok')::boolean, false) THEN
    RAISE EXCEPTION 'sandbox role executed a write';
  END IF;
  RESET ROLE;
END $$;

-- A provider endpoint may not be pointed at a link-local or loopback address
-- unless the operator opts that provider in explicitly.
DO $$
DECLARE v_id uuid;
BEGIN
  SELECT provider_id INTO v_id FROM argo_private.llm_providers WHERE name = 'openai';
  BEGIN
    PERFORM argo_public.fn_set_provider(v_id, 'http://169.254.169.254/latest', NULL, NULL);
    RAISE EXCEPTION 'metadata endpoint was accepted';
  EXCEPTION WHEN sqlstate 'P0001' THEN
    NULL;
  END;
END $$;

SELECT 'smoke ok' AS result;
