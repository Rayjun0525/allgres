#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

BASE="http://127.0.0.1:8088"
TOKEN="${ALLGRES_DASHBOARD_TOKEN:-}"
# Every /api/v1 call needs the client header; that requirement is what makes a
# cross-origin browser request fail.
HDR=(-H 'X-Allgres-Client: smoke')
[[ -n "$TOKEN" ]] && HDR+=(-H "Authorization: Bearer $TOKEN")

docker compose up -d --build
trap 'docker compose logs --no-color allgres | tail -200' ERR

for _ in $(seq 1 60); do
  docker compose exec -T allgres pg_isready -U postgres >/dev/null 2>&1 && break
  sleep 1
done

for _ in $(seq 1 60); do
  curl -fsS "$BASE/healthz" >/dev/null 2>&1 && break
  sleep 1
done

docker compose exec -T allgres psql -U postgres -d postgres -v ON_ERROR_STOP=1 -f /opt/allgres/tests/smoke.sql
docker compose exec -T allgres psql -U postgres -d postgres -v ON_ERROR_STOP=1 -f /opt/allgres/tests/e2e_mock.sql

curl -fsS "$BASE/healthz"; echo
curl -fsS "${HDR[@]}" "$BASE/api/v1/status"; echo
curl -fsS "${HDR[@]}" "$BASE/api/v1/agents"; echo
# `curl | grep -q` is a real race, not a style nit: -q makes grep exit the
# instant it finds a match, closing its end of the pipe while curl may still
# be mid-write -- curl then reports exit 23 ("failure writing output") for a
# broken pipe that was actually a successful match, and `pipefail` turns
# that into a script failure regardless of what grep found. Capturing into a
# variable first (command substitution waits for curl to finish, in full,
# before grep ever runs) removes the race instead of just tolerating it.
# The bigger the body -- and /api/v1/agents just above has grown a lot
# since this script was first written -- the more likely the race resolves
# the "wrong" way, so this is not something a fresh install would keep
# getting away with.
index_body=$(curl -fsS "$BASE/")
grep -q 'Allgres Control Plane' <<<"$index_body"

# e2e_mock.sql left a dozen tasks queued, so the runtime worker has outbound
# calls in flight right now.  The dashboard must still answer promptly: that is
# the whole point of moving blocking HTTP off the SPI thread.  Before, a claimed
# batch could hold that thread for minutes and every call here returned
# rpc_read_failed.
for _ in $(seq 1 10); do
  t=$(curl -fsS -o /dev/null -w '%{time_total}' "${HDR[@]}" "$BASE/api/v1/status")
  awk -v t="$t" 'BEGIN { if (t > 2.0) { print "dashboard latency " t "s while outbound calls were in flight"; exit 1 } }'
done
echo "dashboard stayed responsive under outbound load"

# The dashboard HTML must ship a per-response CSP nonce, not the placeholder.
# Same capture-then-grep fix as above -- these two used to pipe curl
# straight into grep -q/-qv as well.
csp_headers=$(curl -fsSD- -o /dev/null "$BASE/")
grep -qi "content-security-policy:.*nonce-" <<<"$csp_headers"
index_body=$(curl -fsS "$BASE/")
grep -qv '__CSP_NONCE__' <<<"$index_body"

# CSRF: an API call without the client header, or with a foreign Origin, fails.
[[ "$(curl -s -o /dev/null -w '%{http_code}' "$BASE/api/v1/agents")" == "403" ]]
[[ "$(curl -s -o /dev/null -w '%{http_code}' "${HDR[@]}" \
      -H 'Origin: http://evil.test' "$BASE/api/v1/agents")" == "403" ]]
# Preflight is never approved.
[[ "$(curl -s -o /dev/null -w '%{http_code}' -X OPTIONS "$BASE/api/v1/agents")" == "405" ]]

# The RPC socket must not be reachable by other local users.
docker compose exec -T allgres sh -lc '
  d=$(psql -U postgres -tAc "SELECT allgres.native_status()->>'"'"'rpc_socket'"'"'")
  test "$(stat -c %a "$(dirname "$d")")" = "700"
  test "$(stat -c %a "$d")" = "600"
'

curl -fsS -X POST "$BASE/mock/chat/completions" \
  -H 'content-type: application/json' \
  -d '{"model":"allgres-mock","messages":[]}' >/dev/null

echo "Allgres dashboard MVP smoke test passed."
