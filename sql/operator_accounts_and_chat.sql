-- Allgres 0.1.0 control plane -- section 9c: the operator API's approval,
-- SQL-sandbox-allowlist, memory, account/auth, and chat/messenger surface.
--
-- Split out alongside sql/operator_agents_and_policies.sql (see that
-- file's own header for why, and KNOWN_ISSUES.md item 38). Loaded after
-- sql/operator_runtime_and_integrations.sql (`requires = ["operator_
-- runtime_and_integrations"]`). Loaded before sql/seed_data.sql.

-- p_reply is what makes this a conversation instead of a bare gate: it is
-- appended to execution_logs as an 'operator' message (a role the log CHECK
-- constraint has allowed since day one, previously never written to), so the
-- resumed agent sees what the human actually said, not just that it may
-- continue. Before this, fn_decide_approval only recorded approved/rejected;
-- the reason text a human gave was never fed back into the conversation the
-- agent replays on its next turn.
CREATE OR REPLACE FUNCTION allgres_public.fn_decide_approval(
  p_approval_id uuid,
  p_accept boolean,
  p_reply text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = allgres_private, pg_temp
AS $fn$
DECLARE
  v allgres_private.human_approvals%ROWTYPE;
  t allgres_private.tasks%ROWTYPE;
  v_reply text;
BEGIN
  SELECT * INTO v FROM allgres_private.human_approvals WHERE approval_id = p_approval_id FOR UPDATE;
  IF NOT FOUND OR v.status <> 'pending' THEN
    RAISE EXCEPTION 'approval not pending' USING ERRCODE = 'P0001';
  END IF;

  UPDATE allgres_private.human_approvals
  SET status = CASE WHEN p_accept THEN 'approved' ELSE 'rejected' END,
      reply_text = p_reply,
      decided_at = now()
  WHERE approval_id = p_approval_id;

  SELECT * INTO t FROM allgres_private.tasks WHERE task_id = v.task_id FOR UPDATE;
  IF NOT FOUND OR t.status <> 'waiting_human' THEN
    -- The task moved on without this decision (e.g. fn_watchdog already
    -- expired it).  The approval row itself is still recorded above; there
    -- is nothing left to resume or log against.
    PERFORM allgres_private.audit('approvals.decide', jsonb_build_object('approval_id', p_approval_id, 'accept', p_accept, 'task_updated', false));
    RETURN jsonb_build_object('ok', true, 'task_updated', false);
  END IF;

  v_reply := COALESCE(NULLIF(btrim(p_reply), ''), CASE WHEN p_accept THEN 'Approved.' ELSE 'Rejected.' END);
  PERFORM allgres_private.append_log(t.task_id, t.step_count + 1, 'operator', to_jsonb(v_reply));

  IF p_accept THEN
    UPDATE allgres_private.tasks
    SET status = 'queued', step_count = step_count + 1, updated_at = now()
    WHERE task_id = t.task_id;
  ELSE
    UPDATE allgres_private.tasks
    SET status = 'failed', error = 'human_rejected', step_count = step_count + 1, updated_at = now()
    WHERE task_id = t.task_id;
    PERFORM allgres_private.maybe_complete_session(t.session_id);
  END IF;
  PERFORM allgres_private.audit('approvals.decide', jsonb_build_object('approval_id', p_approval_id, 'accept', p_accept, 'task_updated', true));
  RETURN jsonb_build_object('ok', true, 'task_updated', true);
END;
$fn$;

-- The one control that was missing entirely: nothing could stop a runaway
-- agent.  Cancels every open task in the session (queued/running/
-- waiting_human/waiting_children), rejects any pending approval so it
-- doesn't linger, logs an
-- operator message on each cancelled task so the thread shows why it stopped,
-- and closes the session as 'cancelled' -- distinct from maybe_complete_session's
-- 'completed'/'failed', which this deliberately bypasses: that function has
-- no notion of an operator-initiated stop.
CREATE OR REPLACE FUNCTION allgres_public.fn_cancel_session(p_session_id uuid, p_reason text DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = allgres_private, pg_temp
AS $fn$
DECLARE
  r record;
  v_reason text := COALESCE(NULLIF(btrim(p_reason), ''), 'Cancelled by operator.');
  v_n int := 0;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM allgres_private.sessions WHERE session_id = p_session_id) THEN
    RAISE EXCEPTION 'session not found' USING ERRCODE = 'P0001';
  END IF;

  FOR r IN
    SELECT task_id, step_count
    FROM allgres_private.tasks
    WHERE session_id = p_session_id AND status IN ('queued', 'running', 'waiting_human', 'waiting_children')
    FOR UPDATE
  LOOP
    PERFORM allgres_private.append_log(r.task_id, r.step_count + 1, 'operator', to_jsonb(v_reason));
    UPDATE allgres_private.tasks
    SET status = 'cancelled', error = 'operator_cancelled', step_count = step_count + 1, updated_at = now()
    WHERE task_id = r.task_id;
    v_n := v_n + 1;
  END LOOP;

  -- A 'queued' outbound/SQL call has not been claimed yet, so marking the
  -- task cancelled above does not stop fn_claim_outbound/fn_claim_sql from
  -- picking it up next pump (see the task-status guard added there) -- but
  -- that guard only helps once the row is still 'queued' when it runs.
  -- Cancel it here too, before that race window opens, so a cancelled
  -- session cannot still fire an HTTP request or sandboxed query. An
  -- 'in_flight' row is already claimed and cannot be un-sent; marking it
  -- 'lost' here just means its eventual fn_complete_outbound/fn_complete_sql
  -- call finds the task no longer 'running' and discards the result, the
  -- same as any other post-cancel completion.
  UPDATE allgres_private.outbound_calls o
  SET status = 'lost', error = 'session_cancelled', updated_at = now()
  FROM allgres_private.tasks t
  WHERE o.task_id = t.task_id AND t.session_id = p_session_id
    AND o.status IN ('queued', 'in_flight');

  UPDATE allgres_private.sql_calls sc
  SET status = 'lost', updated_at = now()
  FROM allgres_private.tasks t
  WHERE sc.task_id = t.task_id AND t.session_id = p_session_id
    AND sc.status IN ('queued', 'in_flight');

  UPDATE allgres_private.human_approvals h
  SET status = 'rejected', reply_text = 'session_cancelled', decided_at = now()
  FROM allgres_private.tasks t
  WHERE h.task_id = t.task_id AND t.session_id = p_session_id AND h.status = 'pending';

  UPDATE allgres_private.sessions
  SET status = 'cancelled', completed_at = now()
  WHERE session_id = p_session_id AND status = 'open';

  PERFORM allgres_private.audit('sessions.cancel', jsonb_build_object('session_id', p_session_id, 'reason', v_reason, 'tasks_cancelled', v_n));
  RETURN jsonb_build_object('ok', true, 'tasks_cancelled', v_n);
END;
$fn$;

CREATE OR REPLACE FUNCTION allgres_public.fn_allowlist_add(p_ref text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = allgres_private, pg_temp
AS $fn$
BEGIN
  INSERT INTO allgres_private.sql_sandbox_allowlist (resource_ref)
  VALUES (p_ref)
  ON CONFLICT DO NOTHING;
  PERFORM allgres_private.audit('allowlist.add', jsonb_build_object('resource_ref', p_ref));
  RETURN jsonb_build_object('ok', true, 'resource_ref', p_ref);
END;
$fn$;

CREATE OR REPLACE FUNCTION allgres_public.fn_allowlist_del(p_ref text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = allgres_private, pg_temp
AS $fn$
BEGIN
  DELETE FROM allgres_private.sql_sandbox_allowlist WHERE resource_ref = p_ref;
  PERFORM allgres_private.audit('allowlist.remove', jsonb_build_object('resource_ref', p_ref));
  RETURN jsonb_build_object('ok', true);
END;
$fn$;

-- Operator-authored counterpart to the agent's own `remember` action
-- (fn_submit_result) -- same validation and eviction, via write_memory,
-- just with no session/task to attribute it to. Lets an operator seed an
-- agent's memory directly (a standing preference, a correction to
-- something the agent got wrong) rather than only ever waiting for the
-- agent to write it itself.
CREATE OR REPLACE FUNCTION allgres_public.fn_remember(
  p_agent_id uuid,
  p_content text,
  p_memory_type text DEFAULT 'semantic',
  p_importance text DEFAULT NULL,
  p_subject_id text DEFAULT NULL,
  p_expires_in_days text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = allgres_private, pg_temp
AS $fn$
DECLARE
  v_result jsonb;
BEGIN
  v_result := allgres_private.write_memory(
    p_agent_id, p_content, p_memory_type, p_importance, p_subject_id, p_expires_in_days
  );
  PERFORM allgres_private.audit('memories.create', jsonb_build_object(
    'agent_id', p_agent_id, 'memory_type', p_memory_type, 'content_preview', left(p_content, 120)
  ));
  RETURN v_result;
END;
$fn$;

CREATE OR REPLACE FUNCTION allgres_public.fn_forget(p_memory_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = allgres_private, pg_temp
AS $fn$
BEGIN
  DELETE FROM allgres_private.agent_memories WHERE memory_id = p_memory_id;
  PERFORM allgres_private.audit('memories.remove', jsonb_build_object('memory_id', p_memory_id));
  RETURN jsonb_build_object('ok', true, 'memory_id', p_memory_id);
END;
$fn$;

CREATE OR REPLACE FUNCTION allgres_private.selftest_cleanup()
RETURNS void
LANGUAGE plpgsql
AS $fn$
BEGIN
  -- A real DELETE of these rows was tried and reverted: execution_logs'
  -- append-only trigger (forbid_log_mutation) rejects DELETE the same as
  -- UPDATE, for anyone, including this function's own owner -- by design,
  -- see that trigger's comment. Deleting sql_calls/tasks/sessions instead
  -- and leaving orphaned execution_logs behind would either violate the
  -- tasks/sessions FK (nothing here cascades) or leave logs with no task to
  -- belong to. So selftest fixtures are never deleted; instead this only
  -- terminates anything left non-terminal by an interrupted run, and the
  -- operator-facing views/listings filter out goal LIKE 'selftest%' (see
  -- their own comments) so they never actually show up in the dashboard.
  UPDATE allgres_private.tasks t
  SET status = 'failed', error = 'selftest', updated_at = now()
  FROM allgres_private.sessions s
  WHERE t.session_id = s.session_id
    AND s.goal LIKE 'selftest%'
    AND t.status IN ('queued', 'running', 'waiting_human', 'waiting_children');
  UPDATE allgres_private.sessions
  SET status = 'cancelled', completed_at = now()
  WHERE goal LIKE 'selftest%' AND status = 'open';
END;
$fn$;

-- ---------------------------------------------------------------------------
-- 9b. Accounts, roles, and the chat/messenger surface built on them.
--     Real login (username/password, pgcrypto bcrypt hashes), distinct from
--     the dashboard's one shared bearer token -- see the users/web_sessions
--     table comments above for why this exists alongside, not instead of,
--     the lighter audit log item 28 already built.
-- ---------------------------------------------------------------------------

-- Every password operation here requires pgcrypto -- unlike provider secret
-- encryption (allgres_private.encrypt_secret), which degrades to plaintext
-- with a loud warning when pgcrypto is missing, a password hash has no safe
-- degraded mode: fail closed instead, the same way encrypt_secret already
-- fails closed when a secret *key* is configured but pgcrypto is not.
CREATE OR REPLACE FUNCTION allgres_public.fn_create_user(
  p_username text,
  p_password text,
  p_role text DEFAULT 'user'
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = allgres_private, pg_temp
AS $fn$
DECLARE
  v_ns text := allgres_private.pgcrypto_schema();
  v_hash text;
  v_id uuid;
  v_username text := btrim(COALESCE(p_username, ''));
BEGIN
  IF v_ns IS NULL THEN
    RAISE EXCEPTION 'pgcrypto is required for the accounts system but is not installed'
      USING ERRCODE = 'P0001';
  END IF;
  IF v_username = '' THEN
    RAISE EXCEPTION 'username required' USING ERRCODE = 'P0001';
  END IF;
  IF p_role NOT IN ('admin', 'user') THEN
    RAISE EXCEPTION 'invalid role: %', p_role USING ERRCODE = 'P0001';
  END IF;
  IF length(COALESCE(p_password, '')) < 8 THEN
    RAISE EXCEPTION 'password must be at least 8 characters' USING ERRCODE = 'P0001';
  END IF;

  EXECUTE format('SELECT %I.crypt($1, %I.gen_salt(''bf''))', v_ns, v_ns)
    INTO v_hash USING p_password;

  INSERT INTO allgres_private.users (username, password_hash, role)
  VALUES (v_username, v_hash, p_role)
  RETURNING user_id INTO v_id;

  -- Never log p_password/v_hash: audit_log.details is not a secrets store.
  PERFORM allgres_private.audit('users.create', jsonb_build_object('user_id', v_id, 'username', v_username, 'role', p_role));

  RETURN jsonb_build_object('ok', true, 'user_id', v_id, 'username', v_username, 'role', p_role);
END;
$fn$;

-- A failed login (unknown username or wrong password) is indistinguishable
-- from the caller's side -- same error message, and a fixed pg_sleep so a
-- valid-username-wrong-password attempt does not visibly resolve faster
-- than an unknown-username one.
CREATE OR REPLACE FUNCTION allgres_public.fn_login(p_username text, p_password text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = allgres_private, pg_temp
AS $fn$
DECLARE
  v_ns text := allgres_private.pgcrypto_schema();
  u allgres_private.users%ROWTYPE;
  v_ok boolean;
  v_token text;
BEGIN
  IF v_ns IS NULL THEN
    RAISE EXCEPTION 'pgcrypto is required for login but is not installed' USING ERRCODE = 'P0001';
  END IF;

  SELECT * INTO u FROM allgres_private.users
  WHERE username = btrim(COALESCE(p_username, '')) AND is_active;

  IF NOT FOUND THEN
    PERFORM pg_sleep(0.2);
    RAISE EXCEPTION 'invalid username or password' USING ERRCODE = 'P0001';
  END IF;

  EXECUTE format('SELECT %I.crypt($1, $2) = $2', v_ns)
    INTO v_ok USING COALESCE(p_password, ''), u.password_hash;

  IF NOT v_ok THEN
    RAISE EXCEPTION 'invalid username or password' USING ERRCODE = 'P0001';
  END IF;

  EXECUTE format('SELECT encode(%I.gen_random_bytes(32), ''hex'')', v_ns) INTO v_token;

  INSERT INTO allgres_private.web_sessions (session_token, user_id, expires_at)
  VALUES (v_token, u.user_id, now() + interval '7 days');

  RETURN jsonb_build_object(
    'ok', true, 'session_token', v_token,
    'user_id', u.user_id, 'username', u.username, 'role', u.role
  );
END;
$fn$;

-- Idempotent: logging out a token that is already gone (expired, or logged
-- out from another tab) is not an error.
CREATE OR REPLACE FUNCTION allgres_public.fn_logout(p_session_token text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = allgres_private, pg_temp
AS $fn$
BEGIN
  DELETE FROM allgres_private.web_sessions WHERE session_token = p_session_token;
  RETURN jsonb_build_object('ok', true);
END;
$fn$;

-- These four used to be the only mutations in the whole file with no SQL
-- entry point of their own -- their real INSERT/UPDATE/DELETE lived only
-- inline inside dashboard_rpc's users.set_active/set_role/assignments.set/
-- assignments.toggle branches, reachable only through the jsonb RPC
-- envelope. Every other mutation dashboard_rpc exposes already has a plain
-- function like this one behind it (fn_create_user just above,
-- fn_grant_permission, fn_set_policy, ...) that an operator with direct
-- database access can call the same way `psql -c "SELECT
-- fn_create_user(...)"` already works, with no jsonb, no dashboard, no
-- HTTP -- the whole point of a PostgreSQL-native control plane (see
-- README's opening line). dashboard_rpc's own require_admin gate is
-- unchanged; these carry no permission check themselves, exactly like
-- fn_grant_permission/fn_revoke_permission just above -- gating the web/API
-- surface is dashboard_rpc's job, not something every SQL-native function
-- underneath it should also have to reimplement for a caller already
-- trusted with direct database access.
CREATE OR REPLACE FUNCTION allgres_public.fn_set_user_active(p_user_id uuid, p_is_active boolean)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = allgres_private, pg_temp
AS $fn$
BEGIN
  UPDATE allgres_private.users SET is_active = p_is_active WHERE user_id = p_user_id;
  PERFORM allgres_private.audit('users.set_active', jsonb_build_object('user_id', p_user_id, 'is_active', p_is_active));
  RETURN jsonb_build_object('ok', true);
END;
$fn$;

CREATE OR REPLACE FUNCTION allgres_public.fn_set_user_role(p_user_id uuid, p_role text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = allgres_private, pg_temp
AS $fn$
BEGIN
  IF p_role NOT IN ('admin', 'user') THEN
    RAISE EXCEPTION 'invalid role: %', p_role USING ERRCODE = 'P0001';
  END IF;
  UPDATE allgres_private.users SET role = p_role WHERE user_id = p_user_id;
  PERFORM allgres_private.audit('users.set_role', jsonb_build_object('user_id', p_user_id, 'role', p_role));
  RETURN jsonb_build_object('ok', true);
END;
$fn$;

-- Replaces the full assignment set for one user with the given agent_ids --
-- simpler and less error-prone from the UI than incremental add/remove
-- calls for what is always edited as one list there; see
-- fn_set_user_assignment below for the single add/remove instead.
CREATE OR REPLACE FUNCTION allgres_public.fn_set_user_assignments(p_user_id uuid, p_agent_ids uuid[])
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = allgres_private, pg_temp
AS $fn$
BEGIN
  DELETE FROM allgres_private.user_agent_assignments WHERE user_id = p_user_id;
  INSERT INTO allgres_private.user_agent_assignments (user_id, agent_id)
  SELECT p_user_id, a FROM unnest(COALESCE(p_agent_ids, ARRAY[]::uuid[])) a;
  PERFORM allgres_private.audit('users.set_assignments', jsonb_build_object('user_id', p_user_id, 'agent_ids', to_jsonb(p_agent_ids)));
  RETURN jsonb_build_object('ok', true);
END;
$fn$;

CREATE OR REPLACE FUNCTION allgres_public.fn_set_user_assignment(p_user_id uuid, p_agent_id uuid, p_assigned boolean)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = allgres_private, pg_temp
AS $fn$
BEGIN
  IF p_assigned THEN
    INSERT INTO allgres_private.user_agent_assignments (user_id, agent_id)
    VALUES (p_user_id, p_agent_id)
    ON CONFLICT DO NOTHING;
  ELSE
    DELETE FROM allgres_private.user_agent_assignments
    WHERE user_id = p_user_id AND agent_id = p_agent_id;
  END IF;
  PERFORM allgres_private.audit('users.set_assignment', jsonb_build_object('user_id', p_user_id, 'agent_id', p_agent_id, 'assigned', p_assigned));
  RETURN jsonb_build_object('ok', true);
END;
$fn$;

-- Resolves a bearer token to the user it belongs to, or a NULL row if the
-- token is missing, unknown, expired, or the account was deactivated since
-- the token was issued. Touches last_seen_at only on a hit, so a wall of
-- invalid tokens can never generate write traffic.
CREATE OR REPLACE FUNCTION allgres_private.session_user(p_token text)
RETURNS allgres_private.users
LANGUAGE plpgsql
AS $fn$
DECLARE
  u allgres_private.users%ROWTYPE;
BEGIN
  IF p_token IS NULL OR p_token = '' THEN
    RETURN NULL;
  END IF;
  SELECT us.* INTO u
  FROM allgres_private.web_sessions ws
  JOIN allgres_private.users us ON us.user_id = ws.user_id
  WHERE ws.session_token = p_token AND ws.expires_at > now() AND us.is_active;
  IF FOUND THEN
    UPDATE allgres_private.web_sessions SET last_seen_at = now() WHERE session_token = p_token;
    RETURN u;
  END IF;
  RETURN NULL;
END;
$fn$;

CREATE OR REPLACE FUNCTION allgres_private.require_admin(p_token text)
RETURNS allgres_private.users
LANGUAGE plpgsql
AS $fn$
DECLARE
  u allgres_private.users%ROWTYPE;
BEGIN
  u := allgres_private.session_user(p_token);
  IF u.user_id IS NULL THEN
    RAISE EXCEPTION 'not logged in' USING ERRCODE = 'P0001';
  END IF;
  IF u.role <> 'admin' THEN
    RAISE EXCEPTION 'admin role required' USING ERRCODE = 'P0001';
  END IF;
  RETURN u;
END;
$fn$;

-- The guard on every agent-config action that can reach a system agent
-- (agents.update, policy.rollback, permissions.grant/revoke): a regular
-- agent needs no session_token at all today (the shared dashboard bearer
-- token alone has always been enough, see the module comment on
-- allgres_private.users), so this only starts requiring a logged-in admin
-- once the *target* is a system agent -- an ordinary agent's config is
-- unaffected, exactly the "borrow the idea, don't touch what already
-- works" shape the rest of this file follows. NULL p_agent_id (a request
-- with no/invalid agent_id) is left to the caller's own validation to
-- reject -- this function only ever tightens an is_system=true target.
CREATE OR REPLACE FUNCTION allgres_private.require_admin_for_system_agent(p_token text, p_agent_id uuid)
RETURNS void
LANGUAGE plpgsql
AS $fn$
BEGIN
  IF p_agent_id IS NOT NULL AND EXISTS (
    SELECT 1 FROM allgres_private.agents WHERE agent_id = p_agent_id AND is_system
  ) THEN
    PERFORM allgres_private.require_admin(p_token);
  END IF;
END;
$fn$;

-- The gate the rest of the platform-configuration surface was missing --
-- agents.create, agents.update/permissions.grant/permissions.revoke/
-- policy.rollback for an *ordinary* (non-system) agent, provider.create/
-- provider.update, allowlist.add/remove, and agents.set_autonomy all either
-- had no session check at all or (agents.update and friends) one that only
-- ever fired for a system-agent target, leaving every one of these
-- reachable by anyone holding the shared dashboard bearer token alone, with
-- no relationship to whether that caller is logged in, or as what role --
-- a real gap between the accounts system (item 28) and the admin-only
-- surface that predates it, not a deliberate two-tier design.
--
-- The fix cannot be a bare require_admin the way require_admin_for_system_
-- agent already is for a system-agent target: that would break the
-- deployment mode this whole accounts system was always additive to (see
-- the "Accounts, roles, ..." section comment on dashboard_rpc) -- a
-- single-operator install that has never created a user account at all,
-- where the shared bearer token alone has always been the entire security
-- model and still needs to be enough. So this only starts requiring a
-- logged-in admin once an operator has actually created at least one
-- account -- at that point every action gated by this function requires
-- one, uniformly, regardless of whether its specific target happens to be
-- a system agent. Before that point (zero rows in allgres_private.users --
-- checked fresh on every call, not cached, so the very next request after
-- the first account is created is already covered) this is a no-op, the
-- same as before this function existed.
CREATE OR REPLACE FUNCTION allgres_private.require_admin_if_accounts_exist(p_token text)
RETURNS void
LANGUAGE plpgsql
AS $fn$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM allgres_private.users) THEN
    RETURN;
  END IF;
  PERFORM allgres_private.require_admin(p_token);
END;
$fn$;

-- What approvals.list/proposals.list/fixes.list and their .decide
-- counterparts scope by (item 41, "opening the approval inbox to regular
-- users too"): NULL means unrestricted -- either nobody is logged in (the
-- original shared-bearer-token caller, unaffected by any of this) or the
-- caller is an admin, who could always see everything here before item 28
-- added accounts at all. A non-NULL, possibly empty, array is a regular
-- user's own assigned agents -- exactly user_agent_assignments, the same
-- explicit allow-list require_agent_access already enforces for chat.
CREATE OR REPLACE FUNCTION allgres_private.visible_agent_ids(p_token text)
RETURNS uuid[]
LANGUAGE plpgsql
AS $fn$
DECLARE
  u allgres_private.users%ROWTYPE;
  v_ids uuid[];
BEGIN
  u := allgres_private.session_user(p_token);
  IF u.user_id IS NULL OR u.role = 'admin' THEN
    RETURN NULL;
  END IF;
  SELECT COALESCE(array_agg(agent_id), ARRAY[]::uuid[]) INTO v_ids
  FROM allgres_private.user_agent_assignments WHERE user_id = u.user_id;
  RETURN v_ids;
END;
$fn$;

-- The one check every chat/messenger/model-config action for a specific
-- agent goes through: an admin may reach any active agent; a regular user
-- only one explicitly assigned via user_agent_assignments (item 29's
-- "explicit allowed set", not "everything visible by default").
CREATE OR REPLACE FUNCTION allgres_private.require_agent_access(p_token text, p_agent_id uuid)
RETURNS allgres_private.users
LANGUAGE plpgsql
AS $fn$
DECLARE
  u allgres_private.users%ROWTYPE;
BEGIN
  u := allgres_private.session_user(p_token);
  IF u.user_id IS NULL THEN
    RAISE EXCEPTION 'not logged in' USING ERRCODE = 'P0001';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM allgres_private.agents WHERE agent_id = p_agent_id AND is_active) THEN
    RAISE EXCEPTION 'agent inactive or missing' USING ERRCODE = 'P0001';
  END IF;
  IF u.role <> 'admin' AND NOT EXISTS (
    SELECT 1 FROM allgres_private.user_agent_assignments
    WHERE user_id = u.user_id AND agent_id = p_agent_id
  ) THEN
    RAISE EXCEPTION 'agent not assigned to this user' USING ERRCODE = 'P0001';
  END IF;
  RETURN u;
END;
$fn$;

-- The graceful counterpart require_admin_if_accounts_exist already is to
-- require_admin, for the same reason: require_agent_access above has no
-- bootstrap fallback (correct for chat/messenger/my_agents, which have
-- required a real login since the day accounts existed at all), but
-- applying it unconditionally to run/sessions.cancel/sessions.continue --
-- older actions than the login system itself, part of the admin-facing
-- Run/Sessions surface -- would break the single-operator, token-only
-- deployment mode those have always worked in. This is a no-op while
-- allgres_private.users is empty (checked fresh, not cached, same as
-- require_admin_if_accounts_exist); once any account exists, it requires
-- a real logged-in session AND (unless that session is an admin) that the
-- session belongs to a user actually assigned to p_agent_id -- the two
-- separate checks item 1 of the roadmap named: can this *user* reach this
-- *agent* at all, kept apart from whether the *agent* may reach a given
-- resource (agent_may_read/agent_has_permission, unrelated and untouched
-- here). Before this fix, run/sessions.cancel/sessions.continue had no
-- check whatsoever, at any account state -- any caller holding the shared
-- dashboard token could run, cancel, or continue a session against any
-- agent_id/session_id in the whole database, logged in or not, assigned
-- or not.
CREATE OR REPLACE FUNCTION allgres_private.require_agent_access_if_accounts_exist(p_token text, p_agent_id uuid)
RETURNS void
LANGUAGE plpgsql
AS $fn$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM allgres_private.users) THEN
    RETURN;
  END IF;
  PERFORM allgres_private.require_agent_access(p_token, p_agent_id);
END;
$fn$;

-- Project mode's own access check (item 42): a project is a valid chat
-- target only once bound to an agent and active, and reaching it still
-- goes through require_agent_access for that agent -- a regular user needs
-- the same assignment a Project's bound agent would require in General
-- mode, there is no separate project-level allow-list.
CREATE OR REPLACE FUNCTION allgres_private.require_project_access(p_token text, p_project_id uuid)
RETURNS TABLE(u allgres_private.users, agent_id uuid)
LANGUAGE plpgsql
AS $fn$
DECLARE
  v_project allgres_private.projects%ROWTYPE;
  v_user allgres_private.users%ROWTYPE;
BEGIN
  SELECT * INTO v_project FROM allgres_private.projects WHERE project_id = p_project_id AND is_active;
  IF v_project IS NULL THEN
    RAISE EXCEPTION 'project inactive or missing' USING ERRCODE = 'P0001';
  END IF;
  IF v_project.agent_id IS NULL THEN
    RAISE EXCEPTION 'project has no agent configured for chat' USING ERRCODE = 'P0001';
  END IF;
  v_user := allgres_private.require_agent_access(p_token, v_project.agent_id);
  RETURN QUERY SELECT v_user, v_project.agent_id;
END;
$fn$;

-- The simple 1:1 chat surface: one continuing session per (user, agent)
-- pair (user_agent_chat_sessions), created on first message and continued
-- (fn_continue_session) on every one after -- never a fresh, contextless
-- session per message.
CREATE OR REPLACE FUNCTION allgres_public.fn_chat_send(
  p_session_token text,
  p_agent_id uuid,
  p_message text
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = allgres_private, allgres_public, pg_temp
AS $fn$
DECLARE
  u allgres_private.users%ROWTYPE;
  v_sid uuid;
  v_created jsonb;
BEGIN
  u := allgres_private.require_agent_access(p_session_token, p_agent_id);
  IF btrim(COALESCE(p_message, '')) = '' THEN
    RAISE EXCEPTION 'message required' USING ERRCODE = 'P0001';
  END IF;

  SELECT session_id INTO v_sid
  FROM allgres_private.user_agent_chat_sessions
  WHERE user_id = u.user_id AND agent_id = p_agent_id;

  IF v_sid IS NULL THEN
    v_created := allgres_public.fn_create_session(p_agent_id, btrim(p_message));
    v_sid := (v_created->>'session_id')::uuid;
    INSERT INTO allgres_private.user_agent_chat_sessions (user_id, agent_id, session_id)
    VALUES (u.user_id, p_agent_id, v_sid);
    RETURN jsonb_build_object('ok', true, 'session_id', v_sid, 'task_id', v_created->>'task_id');
  END IF;

  v_created := allgres_public.fn_continue_session(v_sid, btrim(p_message));
  UPDATE allgres_private.user_agent_chat_sessions SET updated_at = now()
  WHERE user_id = u.user_id AND agent_id = p_agent_id;
  RETURN v_created;
END;
$fn$;

-- The full thread for a user's ongoing chat with one agent -- same
-- session-wide, root-tasks-only stitching fn_next_step itself now uses,
-- read back for display rather than to build a prompt.
CREATE OR REPLACE FUNCTION allgres_public.fn_chat_history(p_session_token text, p_agent_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = allgres_private, pg_temp
AS $fn$
DECLARE
  u allgres_private.users%ROWTYPE;
  v_sid uuid;
BEGIN
  u := allgres_private.require_agent_access(p_session_token, p_agent_id);

  SELECT session_id INTO v_sid
  FROM allgres_private.user_agent_chat_sessions
  WHERE user_id = u.user_id AND agent_id = p_agent_id;

  IF v_sid IS NULL THEN
    RETURN jsonb_build_object('ok', true, 'session_id', NULL, 'status', NULL, 'messages', '[]'::jsonb);
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'session_id', v_sid,
    'status', (SELECT status FROM allgres_private.sessions WHERE session_id = v_sid),
    'messages', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
        'role', l.role, 'content', allgres_private.log_content_text(l.content), 'created_at', l.created_at
      ) ORDER BY l.created_at)
      FROM allgres_private.execution_logs l
      JOIN allgres_private.tasks t USING (task_id)
      WHERE t.session_id = v_sid AND t.parent_task_id IS NULL
        AND l.role IN ('user', 'assistant', 'operator')
    ), '[]'::jsonb)
  );
END;
$fn$;

-- Project mode's fn_chat_send: identical shape (one continuing session,
-- created on first message, resumed after), keyed by project instead of
-- agent -- see user_project_chat_sessions's comment for why this is its
-- own table/session rather than reusing an agent's General-mode one. The
-- session itself still belongs to the project's bound agent
-- (fn_create_session's p_agent_id); fn_next_step is what makes the
-- resulting conversation actually see the project's preset_prompt, by
-- reading sessions.project_id back off the session it creates here.
CREATE OR REPLACE FUNCTION allgres_public.fn_project_chat_send(
  p_session_token text,
  p_project_id uuid,
  p_message text
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = allgres_private, allgres_public, pg_temp
AS $fn$
DECLARE
  v_access record;
  v_sid uuid;
  v_created jsonb;
BEGIN
  SELECT * INTO v_access FROM allgres_private.require_project_access(p_session_token, p_project_id);
  IF btrim(COALESCE(p_message, '')) = '' THEN
    RAISE EXCEPTION 'message required' USING ERRCODE = 'P0001';
  END IF;

  SELECT session_id INTO v_sid
  FROM allgres_private.user_project_chat_sessions
  WHERE user_id = (v_access.u).user_id AND project_id = p_project_id;

  IF v_sid IS NULL THEN
    v_created := allgres_public.fn_create_session(v_access.agent_id, btrim(p_message), p_project_id);
    v_sid := (v_created->>'session_id')::uuid;
    INSERT INTO allgres_private.user_project_chat_sessions (user_id, project_id, session_id)
    VALUES ((v_access.u).user_id, p_project_id, v_sid);
    RETURN jsonb_build_object('ok', true, 'session_id', v_sid, 'task_id', v_created->>'task_id');
  END IF;

  v_created := allgres_public.fn_continue_session(v_sid, btrim(p_message));
  UPDATE allgres_private.user_project_chat_sessions SET updated_at = now()
  WHERE user_id = (v_access.u).user_id AND project_id = p_project_id;
  RETURN v_created;
END;
$fn$;

CREATE OR REPLACE FUNCTION allgres_public.fn_project_chat_history(p_session_token text, p_project_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = allgres_private, pg_temp
AS $fn$
DECLARE
  v_access record;
  v_sid uuid;
BEGIN
  SELECT * INTO v_access FROM allgres_private.require_project_access(p_session_token, p_project_id);

  SELECT session_id INTO v_sid
  FROM allgres_private.user_project_chat_sessions
  WHERE user_id = (v_access.u).user_id AND project_id = p_project_id;

  IF v_sid IS NULL THEN
    RETURN jsonb_build_object('ok', true, 'session_id', NULL, 'status', NULL, 'messages', '[]'::jsonb);
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'session_id', v_sid,
    'status', (SELECT status FROM allgres_private.sessions WHERE session_id = v_sid),
    'messages', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
        'role', l.role, 'content', allgres_private.log_content_text(l.content), 'created_at', l.created_at
      ) ORDER BY l.created_at)
      FROM allgres_private.execution_logs l
      JOIN allgres_private.tasks t USING (task_id)
      WHERE t.session_id = v_sid AND t.parent_task_id IS NULL
        AND l.role IN ('user', 'assistant', 'operator')
    ), '[]'::jsonb)
  );
END;
$fn$;

-- The Slack-style messenger: a plain post is just stored; a post containing
-- "@agent_name" additionally resolves that agent (subject to the same
-- require_agent_access an unaddressed regular user could not bypass) and
-- routes the *same* message through fn_chat_send, so mentioning an agent in
-- the channel and messaging it in the 1:1 chat page share one conversation
-- per (user, agent) -- not two divergent histories.
CREATE OR REPLACE FUNCTION allgres_public.fn_messenger_post(p_session_token text, p_text text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = allgres_private, allgres_public, pg_temp
AS $fn$
DECLARE
  u allgres_private.users%ROWTYPE;
  v_text text := btrim(COALESCE(p_text, ''));
  v_names text[];
  v_name text;
  v_agent_id uuid;
  v_agent_ids uuid[] := ARRAY[]::uuid[];
  v_sid uuid;
  v_sids uuid[] := ARRAY[]::uuid[];
  v_mid uuid;
  v_orchestrator uuid;
  v_orchestrator_config jsonb;
BEGIN
  u := allgres_private.session_user(p_session_token);
  IF u.user_id IS NULL THEN
    RAISE EXCEPTION 'not logged in' USING ERRCODE = 'P0001';
  END IF;
  IF v_text = '' THEN
    RAISE EXCEPTION 'message required' USING ERRCODE = 'P0001';
  END IF;

  -- Every distinct @mention, in the order it first appears in the text --
  -- that order is what actually decides delivery order today (see
  -- orchestrator's comment below for what it decides instead).
  SELECT array_agg(name ORDER BY first_pos) INTO v_names FROM (
    SELECT (m)[1] AS name, min(ord) AS first_pos
    FROM regexp_matches(v_text, '@([A-Za-z0-9_-]+)', 'g') WITH ORDINALITY AS t(m, ord)
    GROUP BY (m)[1]
  ) q;

  IF v_names IS NOT NULL THEN
    FOREACH v_name IN ARRAY v_names LOOP
      SELECT agent_id INTO v_agent_id FROM allgres_private.agents WHERE name = v_name;
      IF v_agent_id IS NULL THEN
        RAISE EXCEPTION 'no such agent: %', v_name USING ERRCODE = 'P0001';
      END IF;
      -- Validates access the same way chat.send would, for every mention --
      -- a plain post (no mention) skips this entirely.
      PERFORM allgres_private.require_agent_access(p_session_token, v_agent_id);
      v_agent_ids := v_agent_ids || v_agent_id;
      v_sids := v_sids || (allgres_public.fn_chat_send(p_session_token, v_agent_id, v_text)->>'session_id')::uuid;
    END LOOP;
    v_agent_id := v_agent_ids[1];
    v_sid := v_sids[1];
  END IF;

  INSERT INTO allgres_private.channel_messages
    (author_user_id, content, mentioned_agent_id, session_id, mentioned_agent_ids)
  VALUES (u.user_id, v_text, v_agent_id, v_sid, NULLIF(v_agent_ids, ARRAY[]::uuid[]))
  RETURNING message_id INTO v_mid;

  -- orchestrator (item 40): advisory only in this pass -- it reads the same
  -- multi-mention message and the mentioned agents' own prompts and records
  -- its opinion on response order via its own final_answer, but delivery
  -- above already happened in text order regardless. A real reordering-
  -- before-delivery pass is future work; this at least exercises the seeded
  -- agent against a real message rather than leaving it permanently idle.
  -- How many mentions actually engage it (default 2, i.e. "more than
  -- one") is admin-tunable via orchestrator's own agent_config
  -- (min_mentions_to_route, set through agents.update) -- the same
  -- pattern session_compactor's thresholds use.
  SELECT agent_id, agent_config INTO v_orchestrator, v_orchestrator_config
  FROM allgres_private.agents WHERE name = 'orchestrator' AND is_active;
  IF v_orchestrator IS NOT NULL
     AND array_length(v_agent_ids, 1) >= COALESCE((v_orchestrator_config->>'min_mentions_to_route')::int, 2) THEN
    PERFORM allgres_private.queue_orchestrator_opinion(v_orchestrator, v_mid, v_text, v_agent_ids);
  END IF;

  RETURN jsonb_build_object(
    'ok', true, 'message_id', v_mid, 'mentioned_agent_id', v_agent_id, 'session_id', v_sid,
    'mentioned_agent_ids', to_jsonb(v_agent_ids)
  );
END;
$fn$;

-- Regular users can only reach this narrow slice of an agent's policy --
-- llm_config, through fn_set_policy the same way the operator-facing agent
-- editor already does -- never max_steps/permissions/prompt, which stay
-- admin-only via the existing agents.update surface.
CREATE OR REPLACE FUNCTION allgres_public.fn_set_my_model(
  p_session_token text,
  p_agent_id uuid,
  p_provider text,
  p_model text
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = allgres_private, allgres_public, pg_temp
AS $fn$
BEGIN
  PERFORM allgres_private.require_agent_access(p_session_token, p_agent_id);
  RETURN allgres_public.fn_set_policy(
    p_agent_id, NULL, NULL, NULL,
    jsonb_build_object('provider', p_provider, 'model', p_model)
  );
END;
$fn$;
