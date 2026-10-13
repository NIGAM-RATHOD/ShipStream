#!/usr/bin/env bash
# Black-box checks against the deployed service, through the ingress.
#
# Required env: BASE_URL         e.g. http://shipstream-control-plane  or  http://<nlb-dns>
# Optional env: HOST_HEADER      e.g. orders.local (omit when the ingress has no host rule)
#               EXPECTED_VERSION if set, /health must report exactly this version
#               RETRIES          attempts while waiting for the ingress (default 30, 5s apart)
#
# Note: orders live in each pod's memory and there are 3 pods, so a GET-by-id right after
# a POST may land on a different pod and 404. The test therefore never reads back by id.
set -euo pipefail

: "${BASE_URL:?BASE_URL is required}"
HOST_HEADER="${HOST_HEADER:-}"
EXPECTED_VERSION="${EXPECTED_VERSION:-}"
RETRIES="${RETRIES:-30}"

curl_args=(-sS --max-time 5)
order_file="$(mktemp)"
trap 'rm -f "${order_file}"' EXIT
[ -n "${HOST_HEADER}" ] && curl_args+=(-H "Host: ${HOST_HEADER}")

fail() { echo "SMOKE FAIL: $*" >&2; exit 1; }

echo "Waiting for ${BASE_URL}/health ..."
for i in $(seq 1 "${RETRIES}"); do
  if body="$(curl "${curl_args[@]}" -f "${BASE_URL}/health" 2>/dev/null)"; then break; fi
  [ "$i" -eq "${RETRIES}" ] && fail "/health not reachable after ${RETRIES} attempts"
  sleep 5
done
echo "/health -> ${body}"
[ "$(echo "${body}" | jq -r .status)" = "ok" ] || fail "/health status is not ok"

if [ -n "${EXPECTED_VERSION}" ]; then
  # Hit /health a few times so we sample more than one pod behind the ingress.
  for _ in 1 2 3 4 5 6; do
    v="$(curl "${curl_args[@]}" -f "${BASE_URL}/health" | jq -r .version)"
    [ "$v" = "${EXPECTED_VERSION}" ] || fail "expected version ${EXPECTED_VERSION}, got ${v}"
  done
  echo "version ${EXPECTED_VERSION} confirmed"
fi

code="$(curl "${curl_args[@]}" -o "${order_file}" -w '%{http_code}' \
  -H 'Content-Type: application/json' \
  -d '{"customer":"smoke-test","item":"canary","quantity":1,"unit_price":0}' \
  "${BASE_URL}/orders")"
[ "${code}" = "201" ] || fail "POST /orders returned ${code}: $(cat "${order_file}")"
jq -e '.id | length > 0' "${order_file}" >/dev/null || fail "POST /orders returned no id"
echo "POST /orders -> 201 ($(jq -r .id "${order_file}"))"

code="$(curl "${curl_args[@]}" -o /dev/null -w '%{http_code}' "${BASE_URL}/orders")"
[ "${code}" = "200" ] || fail "GET /orders returned ${code}"
echo "GET /orders -> 200"

# Capture first: "curl | grep -q" can die of SIGPIPE under pipefail when grep exits early.
metrics="$(curl "${curl_args[@]}" -f "${BASE_URL}/metrics")" || fail "GET /metrics failed"
grep -q '^orders_api_http_requests_total' <<<"${metrics}" \
  || fail "/metrics does not expose orders_api_http_requests_total"
echo "/metrics -> ok"

echo "SMOKE PASS"
