#!/usr/bin/env bash
# End-to-end setup for the openapi-mcp lab (D3 "Turning Your REST API Into
# an MCP Tool"). Applies the gateway, the petstore REST API, and the
# OpenAPI-to-MCP adapter in front of it. See manifests/00-cluster-and-install.md.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
MANIFESTS_DIR="$LAB_DIR/manifests"

CLUSTER_NAME="agentgateway-openapi-mcp"
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
  --version "v${AGW_VERSION}" \
  --set controller.extraEnv.KGW_ENABLE_GATEWAY_API_EXPERIMENTAL_FEATURES=true

echo "==> Waiting for the agentgateway GatewayClass to exist"
for i in $(seq 1 60); do
  kubectl get gatewayclass/agentgateway >/dev/null 2>&1 && break
  sleep 2
done

echo "==> Waiting for the agentgateway GatewayClass to be accepted"
kubectl wait --for=jsonpath='{.status.conditions[?(@.type=="Accepted")].status}'=True \
  gatewayclass/agentgateway --timeout=120s

echo "==> Applying 01-gateway-and-backend.yaml (static target -> the OpenAPI adapter)"
kubectl apply -f "$MANIFESTS_DIR/01-gateway-and-backend.yaml"
kubectl wait --for=condition=Programmed gateway/agentgateway-proxy -n agentgateway-system --timeout=120s

echo "==> Applying 02-petstore.yaml (the REST API this lab exposes as MCP tools)"
kubectl apply -f "$MANIFESTS_DIR/02-petstore.yaml"
kubectl wait --for=condition=Available deployment/petstore -n openapi-mcp --timeout=180s

echo "==> Applying 03-openapi-adapter.yaml (agentgateway itself, in OpenAPI-to-MCP mode)"
kubectl apply -f "$MANIFESTS_DIR/03-openapi-adapter.yaml"
kubectl wait --for=condition=Available deployment/openapi-adapter -n openapi-mcp --timeout=180s

cat <<'EOF'

==> Done. Reach the gateway with:
  kubectl port-forward -n agentgateway-system svc/agentgateway-proxy 8080:8080

  # List every tool generated from petstore's OpenAPI spec
  python3 scripts/mcp_client.py list

  # Call one with no arguments
  python3 scripts/mcp_client.py call getInventory

  # Call one with arguments
  python3 scripts/mcp_client.py call getPetById '{"path": {"petId": 1}}'
EOF
