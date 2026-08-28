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
