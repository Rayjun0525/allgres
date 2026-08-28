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
