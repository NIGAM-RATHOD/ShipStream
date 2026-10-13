#!/usr/bin/env bash
# Tear down everything local-up.sh and docker compose created.
# Pass --keep-jenkins to keep the Jenkins container and its jenkins_home volume.
set -euo pipefail
export MSYS_NO_PATHCONV=1

CLUSTER_NAME="${CLUSTER_NAME:-shipstream}"
REG_NAME="${REG_NAME:-kind-registry}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [ "${1:-}" != "--keep-jenkins" ]; then
  docker compose -f "${ROOT_DIR}/jenkins/docker-compose.yml" down -v || true
fi
kind delete cluster --name "${CLUSTER_NAME}" || true
docker rm -f "${REG_NAME}" >/dev/null 2>&1 || true
rm -f "${ROOT_DIR}/jenkins/secrets/kubeconfig"
echo "local environment removed"
