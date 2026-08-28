\set ON_ERROR_STOP on

-- Use the web background worker itself as an OpenAI-compatible mock model.
-- allow_private_network is required: the outbound guard rejects loopback
-- endpoints unless the provider opts in, which is what stops a dashboard user
-- from aiming the LLM path at an internal address.
INSERT INTO argo_private.llm_providers (name, kind, base_url, is_enabled, allow_private_network)
VALUES ('allgres_mock', 'openai_compat', 'http://127.0.0.1:8088/mock', true, true)
ON CONFLICT (name) DO UPDATE
SET base_url = EXCLUDED.base_url,
    kind = EXCLUDED.kind,
    is_enabled = true,
    allow_private_network = true;

UPDATE argo_private.policies
SET llm_config = jsonb_build_object(
      'provider', 'allgres_mock',
      'model', 'allgres-mock',
      'temperature', 0,
      'max_tokens', 128
    ),
    updated_at = now()
WHERE agent_id = (SELECT agent_id FROM argo_private.agents WHERE name = 'analyst');

CREATE TEMP TABLE _allgres_test_session(session_id uuid);
INSERT INTO _allgres_test_session
SELECT (argo_public.fn_create_session(
  (SELECT agent_id FROM argo_private.agents WHERE name = 'analyst'),
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
    FROM argo_private.sessions s
    JOIN _allgres_test_session t USING (session_id);
    EXIT WHEN v_status IN ('completed', 'failed');
    PERFORM pg_sleep(0.1);
  END LOOP;
END $$;

SELECT s.session_id, s.status, s.final_answer
FROM argo_private.sessions s
JOIN _allgres_test_session t USING (session_id);

DO $$
DECLARE
  v_status text;
  v_answer text;
BEGIN
  SELECT s.status, s.final_answer INTO v_status, v_answer
  FROM argo_private.sessions s
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
  SELECT agent_id INTO v_agent FROM argo_private.agents WHERE name = 'analyst';
  FOR i IN 1..12 LOOP
    PERFORM argo_public.fn_create_session(v_agent, 'load ' || i);
  END LOOP;
END $$;

SELECT count(*) AS queued_load
FROM argo_private.tasks WHERE status IN ('queued', 'running');

SELECT 'e2e ok' AS result;
