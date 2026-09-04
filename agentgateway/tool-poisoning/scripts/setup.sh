#!/usr/bin/env bash
# End-to-end setup for the tool-poisoning lab (D4 "Stopping a
# Tool-Poisoning Attack Before It Starts"). Stands up the gateway, a
# deliberately vulnerable MCP tool server, and the ext-mcp guardrail
# server, but does NOT apply the two AgentgatewayPolicy files
# (04-guardrail-policy.yaml, 05-tool-access-policy.yaml) — those go on
# one at a time, by hand, so each defense's before/after is visible. See
# manifests/00-cluster-and-install.md.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
MANIFESTS_DIR="$LAB_DIR/manifests"

CLUSTER_NAME="agentgateway-tool-poisoning"
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

echo "==> Applying 02-vulnerable-tool-server.yaml (the deliberately poisoned MCP server)"
kubectl apply -f "$MANIFESTS_DIR/02-vulnerable-tool-server.yaml"
kubectl wait --for=condition=Available deployment/vulnerable-tool-server -n tool-poisoning --timeout=180s

echo "==> Applying 03-ext-mcp-guardrail.yaml (this lab's own gRPC guardrail server)"
kubectl apply -f "$MANIFESTS_DIR/03-ext-mcp-guardrail.yaml"
kubectl wait --for=condition=Available deployment/ext-mcp-guardrail -n agentgateway-system --timeout=180s

cat <<'EOF'

==> Done. Reach the gateway with:
  kubectl port-forward -n agentgateway-system svc/agentgateway-proxy 8080:8080

  # See the poisoned description, unprotected
  python3 scripts/mcp_client.py describe

  # Apply the guardrail, then look again
  kubectl apply -f manifests/04-guardrail-policy.yaml
  python3 scripts/mcp_client.py describe

  # Apply tool access RBAC as a second, independent layer
  kubectl apply -f manifests/05-tool-access-policy.yaml
  python3 scripts/mcp_client.py call export_env_vars
EOF
