#!/usr/bin/env bash
# End-to-end setup for the mock-testing lab (H4 "Testing Your AI App
# Without Burning a Single Token"). No backend of any kind exists in this
# lab; every response comes from a directResponse policy at the gateway.
#
# Usage:
#   ./setup.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
MANIFESTS_DIR="$LAB_DIR/manifests"

CLUSTER_NAME="agentgateway-mock-testing"
GWAPI_VERSION="1.6.0"
AGW_VERSION="1.5.0"

if [ "$#" -gt 0 ]; then
  echo "Unknown argument: $1" >&2
  echo "Usage: $0" >&2
  exit 1
fi

echo "==> Creating kind cluster ($CLUSTER_NAME, node v1.34.0 pinned in kind-config.yaml)"
kind create cluster --name "$CLUSTER_NAME" --config "$LAB_DIR/kind-config.yaml"

echo "==> Installing Gateway API $GWAPI_VERSION (experimental channel)"
kubectl apply --server-side -f \
  "https://github.com/kubernetes-sigs/gateway-api/releases/download/v${GWAPI_VERSION}/experimental-install.yaml"

echo "==> Installing agentgateway CRDs $AGW_VERSION"
helm upgrade -i --create-namespace --namespace agentgateway-system \
  --version "v${AGW_VERSION}" agentgateway-crds \
  oci://cr.agentgateway.dev/charts/agentgateway-crds

echo "==> Installing agentgateway control plane $AGW_VERSION"
helm upgrade -i -n agentgateway-system agentgateway oci://cr.agentgateway.dev/charts/agentgateway \
  --version "v${AGW_VERSION}"

echo "==> Waiting for the agentgateway GatewayClass to exist"
for i in $(seq 1 60); do
  kubectl get gatewayclass/agentgateway >/dev/null 2>&1 && break
  sleep 2
done

echo "==> Waiting for the agentgateway GatewayClass to be accepted"
kubectl wait --for=jsonpath='{.status.conditions[?(@.type=="Accepted")].status}'=True \
  gatewayclass/agentgateway --timeout=120s

echo "==> Applying 01-namespace-and-gateway.yaml"
kubectl apply -f "$MANIFESTS_DIR/01-namespace-and-gateway.yaml"
kubectl wait --for=condition=Programmed gateway/agentgateway-proxy -n agentgateway-system --timeout=120s

echo "==> Applying the mock route and its directResponse policy"
kubectl apply -f "$MANIFESTS_DIR/02-route.yaml"
kubectl apply -f "$MANIFESTS_DIR/03-mock-policy.yaml"

cat <<'EOF'

==> Done. Reach the gateway with:
  kubectl port-forward -n agentgateway-system svc/agentgateway-proxy 8080:8080

  # default: mocked 200 completion, no header needed
  curl -s http://localhost:8080/mock/chat/completions

  # simulate a rate limit, no real provider ever called
  curl -s -H 'X-Mock-Scenario: ratelimit' http://localhost:8080/mock/chat/completions

  # simulate a server error
  curl -s -H 'X-Mock-Scenario: error' http://localhost:8080/mock/chat/completions
EOF
