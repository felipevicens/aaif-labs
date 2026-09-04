#!/usr/bin/env bash
# End-to-end setup for the MCP auth lab (D5 "MCP Auth With Keycloak in 20
# Minutes"). Stands up the gateway, an ordinary unauthenticated MCP tool
# server, and Keycloak (configured via a one-shot Job), but does NOT apply
# 05-jwt-auth-policy.yaml — that goes on by hand, so the before/after is
# visible. See manifests/00-cluster-and-install.md.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
MANIFESTS_DIR="$LAB_DIR/manifests"

CLUSTER_NAME="agentgateway-mcp-auth-keycloak"
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

echo "==> Applying 01-gateway-and-backend.yaml"
kubectl apply -f "$MANIFESTS_DIR/01-gateway-and-backend.yaml"
kubectl wait --for=condition=Programmed gateway/agentgateway-proxy -n agentgateway-system --timeout=120s

echo "==> Applying 02-mcp-tool-server.yaml"
kubectl apply -f "$MANIFESTS_DIR/02-mcp-tool-server.yaml"
kubectl wait --for=condition=Available deployment/mcp-tool-server -n mcp-auth --timeout=180s

echo "==> Applying 03-keycloak.yaml"
kubectl apply -f "$MANIFESTS_DIR/03-keycloak.yaml"
kubectl wait --for=condition=Available deployment/keycloak -n mcp-auth --timeout=180s

echo "==> Applying 04-keycloak-setup-job.yaml (configures the realm via kcadm.sh)"
kubectl apply -f "$MANIFESTS_DIR/04-keycloak-setup-job.yaml"
kubectl wait --for=condition=Complete job/keycloak-setup -n mcp-auth --timeout=180s

cat <<'EOF'

==> Done. Reach the gateway and Keycloak with:
  kubectl port-forward -n agentgateway-system svc/agentgateway-proxy 8080:8080
  kubectl port-forward -n mcp-auth svc/keycloak 8081:8080

  # Unauthenticated, unprotected: works with no token
  python3 scripts/mcp_client.py call whoami

  # Apply the JWT auth policy, then the same call is rejected
  kubectl apply -f manifests/05-jwt-auth-policy.yaml
  python3 scripts/mcp_client.py call whoami

  # Get a real token and try again
  TOKEN=$(./scripts/get_token.sh user1 user1pass)
  python3 scripts/mcp_client.py call whoami --token "$TOKEN"

  # user2 has a valid token but no mcp-user role: authorization denies it
  TOKEN2=$(./scripts/get_token.sh user2 user2pass)
  python3 scripts/mcp_client.py call whoami --token "$TOKEN2"
EOF
