#!/usr/bin/env bash
# End-to-end setup for the models-serve lab (A5 "Serving Your Own Model
# Like a Real Provider"). The first lab in this series backed by a real
# model instead of a mock: Ollama serves two tiny CPU-only models, and
# AgentgatewayModel aliases them under client-facing names, both a direct
# provider-style alias (Scenario A) and a weighted virtual model splitting
# traffic across both real models (Scenario B). See
# manifests/00-cluster-and-install.md for what each step actually proves.
#
# Usage:
#   ./setup.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
MANIFESTS_DIR="$LAB_DIR/manifests"

CLUSTER_NAME="agentgateway-models-serve"
GWAPI_VERSION="1.6.0"
AGW_VERSION="1.5.0"

if [ "$#" -gt 0 ]; then
  echo "Unknown argument: $1" >&2
  echo "Usage: $0" >&2
  exit 1
fi

echo "==> Creating kind cluster ($CLUSTER_NAME, node v1.34.0 pinned in kind-config.yaml)"
kind create cluster --name "$CLUSTER_NAME" --config "$LAB_DIR/kind-config.yaml"

echo "==> Installing Gateway API $GWAPI_VERSION (experimental channel, needed for AgentgatewayModel)"
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

echo "==> Applying 01-gateway-and-ollama.yaml (this pulls two models, can take a few minutes)"
kubectl apply -f "$MANIFESTS_DIR/01-gateway-and-ollama.yaml"
kubectl wait --for=condition=available --timeout=300s deployment/ollama
kubectl wait --for=condition=Programmed --timeout=120s gateway/agentgateway-proxy -n agentgateway-system

echo "==> Applying 02-alias-real-provider-name.yaml (Scenario A)"
kubectl apply -f "$MANIFESTS_DIR/02-alias-real-provider-name.yaml"

echo "==> Applying 03-weighted-virtual-model.yaml (Scenario B)"
kubectl apply -f "$MANIFESTS_DIR/03-weighted-virtual-model.yaml"

cat <<'EOF'

==> Done. Reach the gateway with:
  kubectl port-forward -n agentgateway-system svc/agentgateway-proxy 8080:8080

  # Scenario A: a real completion from a local model, aliased as gpt-4.
  curl -s -X POST http://localhost:8080/v1/chat/completions \
    -H 'Content-Type: application/json' \
    -d '{"model":"gpt-4","messages":[{"role":"user","content":"Say hello in exactly three words."}]}'

  # Scenario B: 20 requests split across two real local models, 70/30.
  for i in $(seq 20); do
    curl -s -X POST http://localhost:8080/v1/chat/completions \
      -H 'Content-Type: application/json' \
      -d '{"model":"gpt-4-turbo","messages":[{"role":"user","content":"hi"}]}' \
      | grep -o '"model":"[^"]*"'
  done | sort | uniq -c
EOF
