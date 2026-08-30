\set ON_ERROR_STOP on

-- Use the web background worker itself as an OpenAI-compatible mock model.
-- allow_private_network is required: the outbound guard rejects loopback
-- endpoints unless the provider opts in, which is what stops a dashboard user
-- from aiming the LLM path at an internal address.
INSERT INTO allgres_private.llm_providers (name, kind, base_url, is_enabled, allow_private_network)
VALUES ('allgres_mock', 'openai_compat', 'http://127.0.0.1:8088/mock', true, true)
ON CONFLICT (name) DO UPDATE
SET base_url = EXCLUDED.base_url,
    kind = EXCLUDED.kind,
    is_enabled = true,
    allow_private_network = true;

UPDATE allgres_private.policies
SET llm_config = jsonb_build_object(
      'provider', 'allgres_mock',
      'model', 'allgres-mock',
      'temperature', 0,
      'max_tokens', 128
    ),
    updated_at = now()
WHERE agent_id = (SELECT agent_id FROM allgres_private.agents WHERE name = 'analyst');

CREATE TEMP TABLE _allgres_test_session(session_id uuid);
INSERT INTO _allgres_test_session
SELECT (allgres_public.fn_create_session(
  (SELECT agent_id FROM allgres_private.agents WHERE name = 'analyst'),
  'Return the Allgres MVP mock answer.'
)->>'session_id')::uuid;

-- The native runtime worker is asynchronous.  Wait up to ~20 seconds.
DO $$
DECLARE
  v_status text;
  i int;
BEGIN
  FOR i IN 1..200 LOOP
    SELECT s.status INTO v_status
    FROM allgres_private.sessions s
    JOIN _allgres_test_session t USING (session_id);
    EXIT WHEN v_status IN ('completed', 'failed');
    PERFORM pg_sleep(0.1);
  END LOOP;
END $$;

SELECT s.session_id, s.status, s.final_answer
FROM allgres_private.sessions s
JOIN _allgres_test_session t USING (session_id);

DO $$
DECLARE
  v_status text;
  v_answer text;
BEGIN
  SELECT s.status, s.final_answer INTO v_status, v_answer
  FROM allgres_private.sessions s
  JOIN _allgres_test_session t USING (session_id);

  IF v_status <> 'completed' THEN
    RAISE EXCEPTION 'Allgres E2E mock did not complete (status=%)', v_status;
  END IF;
  IF v_answer <> 'Allgres mock runtime OK' THEN
    RAISE EXCEPTION 'Unexpected Allgres E2E answer: %', v_answer;
  END IF;
END $$;

-- Queue enough work to keep outbound calls in flight.  scripts/smoke.sh then
-- measures dashboard latency over HTTP, which is the path that actually goes
-- web worker -> unix socket -> runtime SPI thread.  Calling dashboard_rpc from
-- psql would not exercise that thread at all.
DO $$
DECLARE
  v_agent uuid;
  i int;
BEGIN
  SELECT agent_id INTO v_agent FROM allgres_private.agents WHERE name = 'analyst';
  FOR i IN 1..12 LOOP
    PERFORM allgres_public.fn_create_session(v_agent, 'load ' || i);
  END LOOP;
END $$;

SELECT count(*) AS queued_load
FROM allgres_private.tasks WHERE status IN ('queued', 'running');

-- OAuth token exchange, driven through the real background worker's HTTP
-- pool (fn_claim_oauth -> perform_http's send_form branch -> mock token
-- endpoint -> fn_complete_oauth), not just fn_selftest's direct calls --
-- the same distinction the LLM mock round trip above draws, and the one
-- item 12/13/18 kept finding real bugs by insisting on.
INSERT INTO allgres_private.llm_providers
  (name, kind, base_url, is_enabled, allow_private_network, oauth_auth_url, oauth_token_url, oauth_client_id)
VALUES ('allgres_mock_oauth', 'oauth', 'http://127.0.0.1:8088/mock/oauth/authorize', true, true,
        'http://127.0.0.1:8088/mock/oauth/authorize', 'http://127.0.0.1:8088/mock/oauth/token', 'e2e-client-id')
ON CONFLICT (name) DO UPDATE
SET oauth_auth_url = EXCLUDED.oauth_auth_url,
    oauth_token_url = EXCLUDED.oauth_token_url,
    oauth_client_id = EXCLUDED.oauth_client_id,
    allow_private_network = true;

SELECT allgres_public.fn_set_provider(
  (SELECT provider_id FROM allgres_private.llm_providers WHERE name = 'allgres_mock_oauth'),
  NULL, NULL, NULL, NULL, NULL, NULL, 'allgres-mock-oauth-secret'
);

CREATE TEMP TABLE _allgres_oauth_call(call_id uuid, provider_id uuid);
INSERT INTO _allgres_oauth_call
SELECT
  (allgres_public.fn_oauth_token_request(
    (allgres_public.fn_oauth_start(
      (SELECT provider_id FROM allgres_private.llm_providers WHERE name = 'allgres_mock_oauth'),
      'http://127.0.0.1:8088/callback'
    )->>'state'),
    'e2e-mock-auth-code',
    'http://127.0.0.1:8088/callback'
  )->>'call_id')::uuid,
  (SELECT provider_id FROM allgres_private.llm_providers WHERE name = 'allgres_mock_oauth');

DO $$
DECLARE
  v_status text;
  i int;
BEGIN
  FOR i IN 1..200 LOOP
    SELECT status INTO v_status
    FROM allgres_private.oauth_calls o
    JOIN _allgres_oauth_call c ON c.call_id = o.call_id;
    EXIT WHEN v_status = 'harvested';
    PERFORM pg_sleep(0.1);
  END LOOP;
END $$;

DO $$
DECLARE
  v_status text;
  v_access text;
  v_refresh text;
  v_body text;
BEGIN
  SELECT o.status INTO v_status
  FROM allgres_private.oauth_calls o JOIN _allgres_oauth_call c ON c.call_id = o.call_id;
  IF v_status <> 'harvested' THEN
    RAISE EXCEPTION 'Allgres E2E oauth exchange did not complete (status=%)', v_status;
  END IF;

  SELECT allgres_private.decrypt_secret(s.access_token), allgres_private.decrypt_secret(s.refresh_token)
  INTO v_access, v_refresh
  FROM allgres_private.llm_secrets s JOIN _allgres_oauth_call c ON c.provider_id = s.provider_id;

  -- The mock token endpoint echoes the code it received back into the
  -- access token and refuses the exchange unless the exact client_secret
  -- arrived -- so a token landing here proves the real code, and the real
  -- claim-time-injected secret, both actually made it over the wire.
  IF v_access <> 'allgres-mock-access-e2e-mock-auth-code' THEN
    RAISE EXCEPTION 'Unexpected Allgres E2E oauth access token: %', v_access;
  END IF;
  IF v_refresh <> 'allgres-mock-refresh' THEN
    RAISE EXCEPTION 'Unexpected Allgres E2E oauth refresh token: %', v_refresh;
  END IF;

  -- The same proof item 13's own verification used: the client secret and
  -- the issued tokens exist only in llm_secrets, encrypted -- never in the
  -- queue row or the execution log of any task (oauth_calls has no task_id
  -- at all, but the columns it does have are checked anyway).
  SELECT string_agg(request_body::text || COALESCE(error, ''), ' ') INTO v_body
  FROM allgres_private.oauth_calls c2
  WHERE c2.provider_id = (SELECT provider_id FROM _allgres_oauth_call);
  IF v_body LIKE '%allgres-mock-oauth-secret%' THEN
    RAISE EXCEPTION 'OAuth client secret leaked into oauth_calls';
  END IF;
  IF v_body LIKE '%allgres-mock-access-%' OR v_body LIKE '%allgres-mock-refresh%' THEN
    RAISE EXCEPTION 'OAuth tokens leaked into oauth_calls';
  END IF;
END $$;

SELECT 'e2e ok' AS result;
