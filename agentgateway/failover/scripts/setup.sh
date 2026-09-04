#!/usr/bin/env bash
# End-to-end setup for the failover lab (A2 "Your Model Just Went Down.
# Did Anyone Notice?"). Fully keyless: every scenario runs against httpbun,
# no provider credentials needed anywhere.
#
# Applies all five manifests in order: Scenario A/B build up on the stable
# AgentgatewayBackend + AgentgatewayPolicy API, Scenario C repeats the same
# failure with the experimental AgentgatewayModel API to show the gap
# between them. See manifests/00-cluster-and-install.md for what each step
# actually proves.
#
# Usage:
#   ./setup.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
MANIFESTS_DIR="$LAB_DIR/manifests"

CLUSTER_NAME="agentgateway-failover"
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
# See A1's setup.sh for why this polls instead of going straight to
# `kubectl wait`: the controller pod needs a moment after `helm upgrade -i`
# returns before the GatewayClass object exists at all.
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
kubectl wait --for=condition=Available deployment/httpbun-primary-bad -n default --timeout=120s
kubectl wait --for=condition=Programmed gateway/agentgateway-proxy -n agentgateway-system --timeout=120s

echo "==> Applying 02-resilient-llm-backend-route.yaml (Scenario A/B backend, no failover yet)"
kubectl apply -f "$MANIFESTS_DIR/02-resilient-llm-backend-route.yaml"

echo "==> Applying 03-health-eviction-policy.yaml (Scenario A: failover, not transparent)"
kubectl apply -f "$MANIFESTS_DIR/03-health-eviction-policy.yaml"

echo "==> Applying 04-retry-policy.yaml (Scenario B: transparent failover)"
kubectl apply -f "$MANIFESTS_DIR/04-retry-policy.yaml"

echo "==> Applying 05-virtualmodel-failover-experimental.yaml (Scenario C: the gotcha)"
kubectl apply -f "$MANIFESTS_DIR/05-virtualmodel-failover-experimental.yaml"

cat <<'EOF'

==> Done. Reach the gateway with:
  kubectl port-forward -n agentgateway-system svc/agentgateway-proxy 8080:8080

  # Scenario A/B (stable API, transparent failover once both policies are applied):
  curl -X POST http://localhost:8080/llm/resilient -H 'Content-Type: application/json' \
    -d '{"model":"gpt-4","messages":[{"role":"user","content":"hi"}]}'

  # Scenario C (experimental API, does not fail over):
  curl -X POST http://localhost:8080/v1/chat/completions -H 'Content-Type: application/json' \
    -d '{"model":"resilient-virtualmodel","messages":[{"role":"user","content":"hi"}]}'
EOF
