#!/usr/bin/env bash
# Bring up the local ShipStream platform (idempotent - safe to re-run):
#   1. a local Docker registry on localhost:5001
#   2. a kind cluster (1 control-plane + 2 workers) that can pull from it
#   3. ingress-nginx
#   4. a kubeconfig for Jenkins that works from inside the "kind" Docker network
#
# Usage: ./scripts/local-up.sh
set -euo pipefail

# Git Bash on Windows rewrites arguments like /etc/containerd into C:/Program Files/Git/etc/...
# before they reach docker. Turn that off for this script.
export MSYS_NO_PATHCONV=1

CLUSTER_NAME="${CLUSTER_NAME:-shipstream}"
REG_NAME="${REG_NAME:-kind-registry}"
REG_PORT="${REG_PORT:-5001}"
INGRESS_NGINX_VERSION="${INGRESS_NGINX_VERSION:-controller-v1.12.1}"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SECRETS_DIR="${ROOT_DIR}/jenkins/secrets"

log() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }

for bin in docker kind kubectl; do
  command -v "$bin" >/dev/null || { echo "missing required tool: $bin" >&2; exit 1; }
done

log "1/6 Local registry ${REG_NAME} on localhost:${REG_PORT}"
if [ "$(docker inspect -f '{{.State.Running}}' "${REG_NAME}" 2>/dev/null || true)" != "true" ]; then
  docker rm -f "${REG_NAME}" >/dev/null 2>&1 || true
  docker run -d --restart=always -p "127.0.0.1:${REG_PORT}:5000" --network bridge \
    --name "${REG_NAME}" registry:2
else
  echo "already running"
fi

log "2/6 kind cluster '${CLUSTER_NAME}'"
if kind get clusters | grep -qx "${CLUSTER_NAME}"; then
  echo "already exists"
else
  kind create cluster --config "${ROOT_DIR}/kind/kind-config.yaml" --name "${CLUSTER_NAME}"
fi

log "3/6 Point every node's containerd at the registry (localhost:${REG_PORT} -> ${REG_NAME}:5000)"
REGISTRY_DIR="/etc/containerd/certs.d/localhost:${REG_PORT}"
for node in $(kind get nodes --name "${CLUSTER_NAME}"); do
  docker exec "${node}" mkdir -p "${REGISTRY_DIR}"
  printf '[host."http://%s:5000"]\n' "${REG_NAME}" \
    | docker exec -i "${node}" cp /dev/stdin "${REGISTRY_DIR}/hosts.toml"
  echo "configured ${node}"
done

# Put the registry on the kind network so nodes can resolve "kind-registry".
if [ "$(docker inspect -f '{{json .NetworkSettings.Networks.kind}}' "${REG_NAME}")" = "null" ]; then
  docker network connect kind "${REG_NAME}"
fi

# Advertise the registry to tools that look for it (KEP-1755).
kubectl apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: local-registry-hosting
  namespace: kube-public
data:
  localRegistryHosting.v1: |
    host: "localhost:${REG_PORT}"
    help: "https://kind.sigs.k8s.io/docs/user/local-registry/"
EOF

log "4/6 ingress-nginx (${INGRESS_NGINX_VERSION})"
kubectl apply -f "https://raw.githubusercontent.com/kubernetes/ingress-nginx/${INGRESS_NGINX_VERSION}/deploy/static/provider/kind/deploy.yaml"
kubectl wait --namespace ingress-nginx --for=condition=ready pod \
  --selector=app.kubernetes.io/component=controller --timeout=180s
# The admission webhook can lag the controller pod by a few seconds; creating an
# Ingress before it answers fails with "failed calling webhook". Wait for its endpoint.
for _ in $(seq 1 30); do
  if kubectl -n ingress-nginx get endpoints ingress-nginx-controller-admission \
      -o jsonpath='{.subsets[0].addresses[0].ip}' 2>/dev/null | grep -q .; then
    break
  fi
  sleep 2
done

log "5/6 Kubeconfig for Jenkins (uses the in-network API address, not 127.0.0.1)"
mkdir -p "${SECRETS_DIR}"
# Left world-readable on purpose: the jenkins user (uid 1000) inside the container must
# read it through the bind mount. It only grants access to a throwaway local cluster,
# and jenkins/secrets/ is git-ignored.
kind get kubeconfig --internal --name "${CLUSTER_NAME}" > "${SECRETS_DIR}/kubeconfig"
echo "wrote ${SECRETS_DIR}/kubeconfig"

log "6/6 Done"
kubectl get nodes -o wide
cat <<EOF

Next steps:
  docker compose -f jenkins/docker-compose.yml up -d --build   # start Jenkins on http://localhost:8080
  curl -H "Host: orders.local" http://localhost/health        # once orders-api is deployed
EOF
