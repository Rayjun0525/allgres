-- Allgres 0.1.0 control plane -- section 11, selftest.
--
-- Split out of sql/control_plane.sql once that single file grew large
-- enough to trip a real rustc compile-time safety lint on the pgrx macro
-- that embeds it as a compile-time constant (KNOWN_ISSUES.md item 38) --
-- fn_selftest alone was about a quarter of the file's total size. Loaded
-- after sql/control_plane.sql (src/lib.rs's extension_sql_file! declares
-- `requires = ["control_plane"]`), which is all fn_selftest's own body
-- actually needs: it is LANGUAGE plpgsql, so nothing inside it is checked
-- against the catalog until it is actually called, long after every file
-- here has finished loading -- the same forward-reference tolerance this
-- codebase already relies on for functions defined earlier in one file
-- calling ones defined later in it. Loaded before sql/grants_and_facade.sql
-- (section 12's REVOKE below still has to run, and its own ownership-
-- fixing catalog scan still has to find this function, both of which
-- require fn_selftest to already exist).
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

REVOKE ALL ON FUNCTION allgres_public.fn_selftest() FROM PUBLIC;
