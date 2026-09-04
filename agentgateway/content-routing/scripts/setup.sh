#!/usr/bin/env bash
# End-to-end setup for the content-routing lab (A3 "Routing Prompts by What
# They Actually Say"). Fully keyless: every scenario runs against httpbun,
# no provider credentials needed anywhere.
#
# Applies all four manifests in order: Scenario A routes on request-body
# content with the stable AgentgatewayBackend + AgentgatewayPolicy API,
# Scenario B repeats the same decision with the experimental
# AgentgatewayModel.virtualModel.conditional API, Scenario C tests whether
# conditional routing skips an evicted target the way failover does. See
# manifests/00-cluster-and-install.md for what each step actually proves.
#
# Usage:
#   ./setup.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
MANIFESTS_DIR="$LAB_DIR/manifests"

CLUSTER_NAME="agentgateway-content-routing"
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

echo "==> Installing agentgateway control plane $AGW_VERSION (AgentgatewayModel enabled)"
helm upgrade -i -n agentgateway-system agentgateway oci://cr.agentgateway.dev/charts/agentgateway \
  --version "v${AGW_VERSION}" --set agentgatewayModels.enabled=true

echo "==> Waiting for the agentgateway GatewayClass to exist"
for i in $(seq 1 60); do
  kubectl get gatewayclass/agentgateway >/dev/null 2>&1 && break
  sleep 2
done

echo "==> Waiting for the agentgateway GatewayClass to be accepted"
kubectl wait --for=jsonpath='{.status.conditions[?(@.type=="Accepted")].status}'=True \
  gatewayclass/agentgateway --timeout=120s

echo "==> Applying 01-gateway-and-backends.yaml"
kubectl apply -f "$MANIFESTS_DIR/01-gateway-and-backends.yaml"
kubectl wait --for=condition=Available deployment/httpbun -n default --timeout=120s
kubectl wait --for=condition=Available deployment/httpbun-broken -n default --timeout=120s
kubectl wait --for=condition=Programmed gateway/agentgateway-proxy -n agentgateway-system --timeout=120s

echo "==> Applying 02-content-routing-stable.yaml (Scenario A)"
kubectl apply -f "$MANIFESTS_DIR/02-content-routing-stable.yaml"

echo "==> Applying 03-conditional-model-experimental.yaml (Scenario B)"
kubectl apply -f "$MANIFESTS_DIR/03-conditional-model-experimental.yaml"

echo "==> Applying 04-conditional-ignores-health-gotcha.yaml (Scenario C: the gotcha)"
kubectl apply -f "$MANIFESTS_DIR/04-conditional-ignores-health-gotcha.yaml"

cat <<'EOF'

==> Done. Reach the gateway with:
  kubectl port-forward -n agentgateway-system svc/agentgateway-proxy 8080:8080

  # Scenario A (stable API, routes by an x-tier header extracted from the body):
  curl -X POST http://localhost:8080/llm/routed -H 'Content-Type: application/json' \
    -d '{"tier":"premium","messages":[{"role":"user","content":"hi"}]}'

  # Scenario B (experimental API, reads the body directly in a CEL "when"):
  curl -X POST http://localhost:8080/v1/chat/completions -H 'Content-Type: application/json' \
    -d '{"model":"routed-tier","tier":"premium","messages":[{"role":"user","content":"hi"}]}'

  # Scenario C (the gotcha: does conditional skip an evicted target?):
  curl -X POST http://localhost:8080/v1/chat/completions -H 'Content-Type: application/json' \
    -d '{"model":"routed-broken","force_primary":true,"messages":[{"role":"user","content":"hi"}]}'
EOF
