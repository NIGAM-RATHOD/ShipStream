#!/usr/bin/env bash
# Deploy (install or upgrade) the orders-api Helm release and wait for it to become ready.
#
# Required env: IMAGE_REPOSITORY, IMAGE_TAG
# Optional env: HELM_RELEASE, K8S_NAMESPACE, CHART_DIR, VALUES_FILE, CREATE_NAMESPACE, HELM_TIMEOUT
#
# Writes the revision that was live *before* this deploy to .helm-previous-revision
# (0 = first install) so rollback.sh knows where to go back to.
set -euo pipefail

: "${IMAGE_REPOSITORY:?IMAGE_REPOSITORY is required}"
: "${IMAGE_TAG:?IMAGE_TAG is required}"
HELM_RELEASE="${HELM_RELEASE:-orders-api}"
K8S_NAMESPACE="${K8S_NAMESPACE:-shipstream}"
CHART_DIR="${CHART_DIR:-helm/orders-api}"
VALUES_FILE="${VALUES_FILE:-}"
CREATE_NAMESPACE="${CREATE_NAMESPACE:-true}"
HELM_TIMEOUT="${HELM_TIMEOUT:-180s}"

previous="$(helm history "${HELM_RELEASE}" -n "${K8S_NAMESPACE}" --max 50 -o json 2>/dev/null \
  | jq -r '[.[] | select(.status == "deployed")] | last | .revision // 0' || echo 0)"
echo "${previous:-0}" > .helm-previous-revision
echo "Currently deployed revision: ${previous:-0}"

args=(upgrade --install "${HELM_RELEASE}" "${CHART_DIR}"
  --namespace "${K8S_NAMESPACE}"
  --set "image.repository=${IMAGE_REPOSITORY}"
  --set "image.tag=${IMAGE_TAG}"
  --wait --timeout "${HELM_TIMEOUT}"
  --history-max 10)
[ "${CREATE_NAMESPACE}" = "true" ] && args+=(--create-namespace)
[ -n "${VALUES_FILE}" ] && args+=(-f "${VALUES_FILE}")

set -x
helm "${args[@]}"
kubectl -n "${K8S_NAMESPACE}" rollout status "deploy/${HELM_RELEASE}" --timeout=60s
kubectl -n "${K8S_NAMESPACE}" get pods -l "app.kubernetes.io/instance=${HELM_RELEASE}" -o wide
