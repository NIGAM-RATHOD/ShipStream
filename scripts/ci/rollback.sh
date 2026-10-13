#!/usr/bin/env bash
# Roll the orders-api release back to the revision recorded by helm-deploy.sh.
# If there was no earlier revision (the very first install failed), uninstall instead
# so the next run starts clean.
set -uo pipefail

HELM_RELEASE="${HELM_RELEASE:-orders-api}"
K8S_NAMESPACE="${K8S_NAMESPACE:-shipstream}"
previous="$(cat .helm-previous-revision 2>/dev/null || echo 0)"

echo "---- diagnostics before rollback ----"
helm history "${HELM_RELEASE}" -n "${K8S_NAMESPACE}" --max 5 || true
kubectl -n "${K8S_NAMESPACE}" get pods -l "app.kubernetes.io/instance=${HELM_RELEASE}" -o wide || true
kubectl -n "${K8S_NAMESPACE}" get events --sort-by=.lastTimestamp | tail -n 20 || true

if [ "${previous}" -gt 0 ] 2>/dev/null; then
  echo "Rolling back ${HELM_RELEASE} to revision ${previous}"
  helm rollback "${HELM_RELEASE}" "${previous}" -n "${K8S_NAMESPACE}" --wait --timeout 180s || exit 1
  kubectl -n "${K8S_NAMESPACE}" rollout status "deploy/${HELM_RELEASE}" --timeout=120s || exit 1
else
  echo "No previously deployed revision - uninstalling the failed first release"
  helm uninstall "${HELM_RELEASE}" -n "${K8S_NAMESPACE}" --wait || exit 1
fi
helm history "${HELM_RELEASE}" -n "${K8S_NAMESPACE}" --max 3 || true
