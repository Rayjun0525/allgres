#!/usr/bin/env bash
# The one install flow README.md's "Install flow" section documents end to
# end: build/pull the image, bring the container up on its own named data
# volume, wait for it to actually be healthy, make sure a first admin
# account exists, then prove the install actually works by running one real
# agent task through to completion -- not just that the container started.
# That last step doubles as "Provider 연결 검증" (provider connection
# verification): a task can only reach 'completed' if the agent's
# configured provider genuinely answered, so a green run here is the same
# round trip a real (non-mock) provider would need to pass.
#
# Requires: docker compose (this is the container path -- scripts/backup_drill.sh
# and scripts/fault_injection_drill.sh are the bare-metal ones). If
# ALLGRES_BOOTSTRAP_ADMIN_USER/ALLGRES_BOOTSTRAP_ADMIN_PASSWORD are set,
# 002-bootstrap-admin.sh already created that admin on first boot and this
# script logs in as them; otherwise it creates its own throwaway admin
# directly (the same one-liner used throughout this project's own
# development, `psql -c "SELECT fn_create_user(...)"`) so the flow is
# provable with zero configuration. ALLGRES_ENABLE_MOCK=1 (docker-compose.yml's
# own default) is what makes the final task actually complete out of the
# box; point AGENT_NAME at a real, working agent to prove a real provider.
set -euo pipefail

cd "$(dirname "$0")/.."

BASE="http://127.0.0.1:8088"
TOKEN="${ALLGRES_DASHBOARD_TOKEN:-}"
HDR=(-H 'X-Allgres-Client: bootstrap' -H 'Content-Type: application/json')
[[ -n "$TOKEN" ]] && HDR+=(-H "Authorization: Bearer $TOKEN")
AGENT_NAME="${AGENT_NAME:-analyst}"

echo "==> Bringing the stack up on its own named volume"
docker compose up -d --build
trap 'docker compose logs --no-color allgres | tail -200' ERR

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
else
  ADMIN_USER="bootstrap_admin_$$"
  ADMIN_PASS="Bootstrap-$$-Check"
  echo "==> No ALLGRES_BOOTSTRAP_ADMIN_USER/PASSWORD set; creating a throwaway admin ($ADMIN_USER) to prove the flow"
  docker compose exec -T allgres psql -U postgres -d postgres -v ON_ERROR_STOP=1 -tAc \
    "SELECT allgres_public.fn_create_user('$ADMIN_USER', '$ADMIN_PASS', 'admin');" >/dev/null
fi

echo "==> Logging in"
login=$(curl -fsS "${HDR[@]}" "$BASE/api/v1/rpc" \
  -d "{\"action\":\"auth.login\",\"username\":\"$ADMIN_USER\",\"password\":\"$ADMIN_PASS\"}")
session_token=$(python3 -c "import json,sys; print(json.load(sys.stdin)['session_token'])" <<<"$login")
[[ -n "$session_token" && "$session_token" != "None" ]] || { echo "login failed: $login"; exit 1; }

echo "==> Verifying $AGENT_NAME exists and is active"
agent_id=$(curl -fsS "${HDR[@]}" "$BASE/api/v1/rpc" \
  -d "{\"action\":\"agents.list\",\"session_token\":\"$session_token\"}" \
  | python3 -c "import json,sys; d=json.load(sys.stdin); a=[x for x in d['agents'] if x['name']=='$AGENT_NAME' and x['is_active']]; print(a[0]['agent_id'] if a else '')")
[[ -n "$agent_id" ]] || { echo "no active agent named '$AGENT_NAME' -- configure one and set AGENT_NAME"; exit 1; }

echo "==> Running one real task against it (install completion criterion)"
run=$(curl -fsS "${HDR[@]}" "$BASE/api/v1/rpc" \
  -d "{\"action\":\"run\",\"agent_id\":\"$agent_id\",\"goal\":\"bootstrap install check\",\"session_token\":\"$session_token\"}")
session_id=$(python3 -c "import json,sys; print(json.load(sys.stdin)['session_id'])" <<<"$run")
[[ -n "$session_id" && "$session_id" != "None" ]] || { echo "run failed: $run"; exit 1; }

echo "==> Waiting for it to complete"
status="open"
for _ in $(seq 1 60); do
  get=$(curl -fsS "${HDR[@]}" "$BASE/api/v1/rpc" \
    -d "{\"action\":\"sessions.get\",\"session_id\":\"$session_id\",\"session_token\":\"$session_token\"}")
  status=$(python3 -c "import json,sys; print(json.load(sys.stdin)['session']['status'])" <<<"$get")
  [[ "$status" == "open" ]] || break
  sleep 1
done

if [[ -n "${ALLGRES_BOOTSTRAP_ADMIN_USER:-}" ]]; then :; else
  docker compose exec -T allgres psql -U postgres -d postgres -tAc \
    "DELETE FROM allgres_private.web_sessions WHERE user_id IN (SELECT user_id FROM allgres_private.users WHERE username = '$ADMIN_USER'); DELETE FROM allgres_private.users WHERE username = '$ADMIN_USER';" >/dev/null
fi

if [[ "$status" == "completed" ]]; then
  echo "PASS: install verified -- a real agent task ran through $AGENT_NAME's configured provider and completed."
else
  echo "FAIL: task ended in status '$status' instead of 'completed' -- see: $get"
  exit 1
fi
