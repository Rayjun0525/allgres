#!/usr/bin/env bash
# The one install flow README.md's "Install flow" section documents end to
# end: build/pull the image, bring the container up on its own named data
# volume, wait for it to actually be healthy, make sure a first admin
# account exists, then prove the install actually works by running a real
# agent task through to completion -- not just that the container started.
#
# Two checks, deliberately kept separate (an outside review of an earlier
# version of this script flagged the opposite -- one check standing in for
# both, on a real production agent, permanently repointed at a mock model
# with no restore):
#
#   1. A mock smoke check, always run, against a disposable agent this
#      script creates and tears down itself. Proves the install mechanics
#      work end to end -- login, run, agents.update (a real config change
#      and model swap), a task completing afterward -- with zero operator
#      configuration required, the same way `docker compose up` alone is
#      supposed to work with ALLGRES_ENABLE_MOCK=1. Never touches any
#      agent the operator created.
#   2. An optional real-provider check, only run when AGENT_NAME is set to
#      a real, already-configured agent. Runs exactly one task through it
#      to completion and never modifies its config in any way -- this is
#      the actual "does our real provider work" signal, kept apart from
#      the mock regression check above precisely so pointing it at a real
#      agent can never leave that agent mock-configured afterward.
#
# Requires: docker compose (this is the container path -- scripts/backup_drill.sh
# and scripts/fault_injection_drill.sh are the bare-metal ones). If
# ALLGRES_BOOTSTRAP_ADMIN_USER/ALLGRES_BOOTSTRAP_ADMIN_PASSWORD are set,
# 002-bootstrap-admin.sh already created that admin on first boot and this
# script logs in as them; otherwise it creates its own throwaway admin
# directly (the same one-liner used throughout this project's own
# development, `psql -c "SELECT fn_create_user(...)"`) so the flow is
# provable with zero configuration.
set -euo pipefail

cd "$(dirname "$0")/.."

BASE="http://127.0.0.1:8088"
TOKEN="${ALLGRES_DASHBOARD_TOKEN:-}"
HDR=(-H 'X-Allgres-Client: bootstrap' -H 'Content-Type: application/json')
[[ -n "$TOKEN" ]] && HDR+=(-H "Authorization: Bearer $TOKEN")
# Unset by default -- the real-provider check only runs when an operator
# explicitly names an agent they've already configured with a working,
# non-mock provider.
AGENT_NAME="${AGENT_NAME:-}"

psql_exec() {
  docker compose exec -T allgres psql -U postgres -d postgres -v ON_ERROR_STOP=1 "$@"
}

echo "==> Bringing the stack up on its own named volume"
docker compose up -d --build
trap 'docker compose logs --no-color allgres | tail -200' ERR

echo "==> Waiting for the container's own init scripts to settle (see scripts/smoke.sh for why this has to come before pg_isready)"
for _ in $(seq 1 60); do
  docker compose logs allgres 2>&1 | grep -qE "PostgreSQL init process complete|Skipping initialization" && break
  sleep 1
done

echo "==> Waiting for PostgreSQL"
for _ in $(seq 1 60); do
  docker compose exec -T allgres pg_isready -U postgres >/dev/null 2>&1 && break
  sleep 1
done

echo "==> Waiting for the dashboard"
for _ in $(seq 1 60); do
  curl -fsS "$BASE/healthz" >/dev/null 2>&1 && break
  sleep 1
done

if [[ -n "${ALLGRES_BOOTSTRAP_ADMIN_USER:-}" && -n "${ALLGRES_BOOTSTRAP_ADMIN_PASSWORD:-}" ]]; then
  echo "==> Using the admin created at first boot: $ALLGRES_BOOTSTRAP_ADMIN_USER"
  ADMIN_USER="$ALLGRES_BOOTSTRAP_ADMIN_USER"
  ADMIN_PASS="$ALLGRES_BOOTSTRAP_ADMIN_PASSWORD"
  ADMIN_IS_OURS=0
else
  ADMIN_USER="bootstrap_admin_$$"
  ADMIN_PASS="Bootstrap-$$-Check"
  ADMIN_IS_OURS=1
  echo "==> No ALLGRES_BOOTSTRAP_ADMIN_USER/PASSWORD set; creating a throwaway admin ($ADMIN_USER) to prove the flow"
  psql_exec -tAc "SELECT allgres_public.fn_create_user('$ADMIN_USER', '$ADMIN_PASS', 'admin');" >/dev/null
fi

echo "==> Logging in"
login=$(curl -fsS "${HDR[@]}" "$BASE/api/v1/rpc" \
  -d "{\"action\":\"auth.login\",\"username\":\"$ADMIN_USER\",\"password\":\"$ADMIN_PASS\"}")
session_token=$(python3 -c "import json,sys; print(json.load(sys.stdin)['session_token'])" <<<"$login")
[[ -n "$session_token" && "$session_token" != "None" ]] || { echo "login failed: $login"; exit 1; }

# Runs one real task and blocks until it leaves 'open'; echoes the final
# session status.
run_to_completion() {
  local goal="$1" agent="$2" run="" status="open" get="" session_id=""
  run=$(curl -fsS "${HDR[@]}" "$BASE/api/v1/rpc" \
    -d "{\"action\":\"run\",\"agent_id\":\"$agent\",\"goal\":\"$goal\",\"session_token\":\"$session_token\"}")
  session_id=$(python3 -c "import json,sys; print(json.load(sys.stdin)['session_id'])" <<<"$run")
  [[ -n "$session_id" && "$session_id" != "None" ]] || { echo "run failed: $run" >&2; echo "error"; return; }
  for _ in $(seq 1 60); do
    get=$(curl -fsS "${HDR[@]}" "$BASE/api/v1/rpc" \
      -d "{\"action\":\"sessions.get\",\"session_id\":\"$session_id\",\"session_token\":\"$session_token\"}")
    status=$(python3 -c "import json,sys; print(json.load(sys.stdin)['session']['status'])" <<<"$get")
    [[ "$status" == "open" ]] || break
    sleep 1
  done
  echo "$status"
}

echo "==> Seeding the built-in mock provider (idempotent, only ever touches the allgres_mock row) and a disposable check agent"
psql_exec -tAc "
  INSERT INTO allgres_private.llm_providers (name, kind, base_url, is_enabled, allow_private_network)
  VALUES ('allgres_mock', 'openai_compat', 'http://127.0.0.1:8088/mock', true, true)
  ON CONFLICT (name) DO UPDATE
  SET base_url = EXCLUDED.base_url, kind = EXCLUDED.kind, is_enabled = true, allow_private_network = true;
" >/dev/null
check_agent_name="bootstrap_check_$$"
check_agent_id=$(psql_exec -tAc "SELECT allgres_public.fn_create_agent('$check_agent_name')->>'agent_id';")
psql_exec -tAc "
  SELECT allgres_public.fn_set_policy(
    '$check_agent_id'::uuid, NULL, NULL, NULL,
    jsonb_build_object('provider', 'allgres_mock', 'model', 'allgres-mock', 'temperature', 0, 'max_tokens', 128)
  );
" >/dev/null

echo "==> Running one real task through it (install completion criterion: proves login -> run -> a real LLM round trip -> completion works out of the box)"
status1=$(run_to_completion "bootstrap install check" "$check_agent_id")

echo "==> Config change + model swap on the same disposable agent (roadmap item 9's 설정 변경/모델 교체 scenario)"
curl -fsS "${HDR[@]}" "$BASE/api/v1/rpc" \
  -d "{\"action\":\"agents.update\",\"agent_id\":\"$check_agent_id\",\"session_token\":\"$session_token\",\"max_steps\":9,\"llm_config\":{\"provider\":\"allgres_mock\",\"model\":\"allgres-mock-bootstrap-check\",\"temperature\":0,\"max_tokens\":128}}" \
  >/dev/null
after_update=$(curl -fsS "${HDR[@]}" "$BASE/api/v1/rpc" \
  -d "{\"action\":\"agents.list\",\"session_token\":\"$session_token\"}" \
  | python3 -c "import json,sys; d=json.load(sys.stdin); a=[x for x in d['agents'] if x['agent_id']=='$check_agent_id'][0]; print(a['max_steps'], a['llm_config'].get('model'))")
read -r new_max_steps new_model <<<"$after_update"
[[ "$new_max_steps" == "9" && "$new_model" == "allgres-mock-bootstrap-check" ]] \
  || { echo "FAIL: config change / model swap did not persist (got: $after_update)"; exit 1; }
status2=$(run_to_completion "bootstrap config-change check" "$check_agent_id")

echo "==> Cleaning up the disposable check agent"
psql_exec -tAc "UPDATE allgres_private.agents SET is_active = false WHERE agent_id = '$check_agent_id';" >/dev/null

status3="skipped"
if [[ -n "$AGENT_NAME" ]]; then
  echo "==> AGENT_NAME=$AGENT_NAME set -- also verifying its own real provider (this agent's config is never modified)"
  agent_id=$(curl -fsS "${HDR[@]}" "$BASE/api/v1/rpc" \
    -d "{\"action\":\"agents.list\",\"session_token\":\"$session_token\"}" \
    | python3 -c "import json,sys; d=json.load(sys.stdin); a=[x for x in d['agents'] if x['name']=='$AGENT_NAME' and x['is_active']]; print(a[0]['agent_id'] if a else '')")
  [[ -n "$agent_id" ]] || { echo "no active agent named '$AGENT_NAME'"; exit 1; }
  status3=$(run_to_completion "bootstrap real-provider check" "$agent_id")
fi

if [[ "$ADMIN_IS_OURS" == "1" ]]; then
  psql_exec -tAc "
    DELETE FROM allgres_private.web_sessions WHERE user_id IN (SELECT user_id FROM allgres_private.users WHERE username = '$ADMIN_USER');
    DELETE FROM allgres_private.users WHERE username = '$ADMIN_USER';
  " >/dev/null
fi

ok=1
[[ "$status1" == "completed" ]] || ok=0
[[ "$status2" == "completed" ]] || ok=0
[[ "$status3" == "completed" || "$status3" == "skipped" ]] || ok=0

if [[ "$ok" == "1" ]]; then
  echo "PASS: install verified -- the disposable check agent ran a real task to completion, a real config change and model swap over HTTP persisted and a task still completed afterward"
  if [[ "$status3" == "completed" ]]; then
    echo "PASS: AGENT_NAME=$AGENT_NAME's own real provider also completed a task, unmodified"
  fi
else
  echo "FAIL: install check ended in '$status1', config-change check ended in '$status2', real-provider check ended in '$status3'"
  exit 1
fi
