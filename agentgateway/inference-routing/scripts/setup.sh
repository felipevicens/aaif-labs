#!/usr/bin/env bash
# End-to-end setup for the inference-routing lab (A4 "Picking the
# Least-Loaded GPU Automatically"). Fully keyless: the llm-d-inference-sim
# simulator stands in for a real vLLM model server, no provider credentials
# needed anywhere.
#
# Deploys the simulator and Gateway, installs the Gateway API Inference
# Extension CRDs, installs agentgateway with inferenceExtension.enabled,
# installs the llm-d Router Gateway chart (InferencePool + EPP + HTTPRoute),
# tests the bare quickstart (Scenario A), then reconfigures the chart to
# stop owning the HTTPRoute and applies the hand-authored
# AgentgatewayBackend + AgentgatewayPolicy layering (Scenario B). See
# manifests/00-cluster-and-install.md for what each step actually proves.
#
# Usage:
#   ./setup.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
MANIFESTS_DIR="$LAB_DIR/manifests"

CLUSTER_NAME="agentgateway-inference-routing"
GWAPI_VERSION="1.6.0"
INF_EXT_VERSION="1.5.0"
AGW_VERSION="1.5.0"
ROUTER_CHART_VERSION="v0.9.0"

if [ "$#" -gt 0 ]; then
  echo "Unknown argument: $1" >&2
  echo "Usage: $0" >&2
  exit 1
fi

echo "==> Creating kind cluster ($CLUSTER_NAME, node v1.34.0 pinned in kind-config.yaml)"
kind create cluster --name "$CLUSTER_NAME" --config "$LAB_DIR/kind-config.yaml"

echo "==> Installing Gateway API $GWAPI_VERSION (standard channel)"
kubectl apply --server-side -f \
  "https://github.com/kubernetes-sigs/gateway-api/releases/download/v${GWAPI_VERSION}/standard-install.yaml"

echo "==> Installing Gateway API Inference Extension $INF_EXT_VERSION CRDs"
kubectl apply -f \
  "https://github.com/kubernetes-sigs/gateway-api-inference-extension/releases/download/v${INF_EXT_VERSION}/manifests.yaml"

echo "==> Installing agentgateway CRDs $AGW_VERSION"
helm upgrade -i --create-namespace --namespace agentgateway-system \
  --version "v${AGW_VERSION}" agentgateway-crds \
  oci://cr.agentgateway.dev/charts/agentgateway-crds

echo "==> Installing agentgateway control plane $AGW_VERSION (Inference Extension enabled)"
helm upgrade -i -n agentgateway-system agentgateway oci://cr.agentgateway.dev/charts/agentgateway \
  --version "v${AGW_VERSION}" --set inferenceExtension.enabled=true

echo "==> Waiting for the agentgateway GatewayClass to exist"
for i in $(seq 1 60); do
  kubectl get gatewayclass/agentgateway >/dev/null 2>&1 && break
  sleep 2
done

echo "==> Waiting for the agentgateway GatewayClass to be accepted"
kubectl wait --for=jsonpath='{.status.conditions[?(@.type=="Accepted")].status}'=True \
  gatewayclass/agentgateway --timeout=120s

echo "==> Applying 01-simulator-and-gateway.yaml"
kubectl apply -f "$MANIFESTS_DIR/01-simulator-and-gateway.yaml"
kubectl wait --for=condition=available --timeout=180s deployment/vllm-qwen3-32b
kubectl wait --for=condition=Programmed --timeout=120s gateway/agentgateway-proxy -n agentgateway-system

echo "==> Installing the llm-d Router Gateway chart (InferencePool + EPP + HTTPRoute)"
helm upgrade -i vllm-qwen3-32b \
  oci://ghcr.io/llm-d/charts/llm-d-router-gateway \
  --version "$ROUTER_CHART_VERSION" \
  --set router.modelServers.matchLabels.app=vllm-qwen3-32b \
  --set router.epp.resources.requests.cpu=100m \
  --set router.epp.resources.requests.memory=128Mi \
  --set router.epp.resources.limits.memory=512Mi \
  --set provider.name=none \
  --set httpRoute.create=true \
  --set httpRoute.inferenceGatewayName=agentgateway-proxy \
  --set httpRoute.inferenceGatewayNamespace=agentgateway-system

echo "==> Waiting for the llm-d Router EPP deployment"
kubectl wait --for=condition=available --timeout=180s deployment/vllm-qwen3-32b-epp

echo "==> Reconfiguring the router chart to stop owning the HTTPRoute (Scenario B uses its own)"
helm upgrade vllm-qwen3-32b \
  oci://ghcr.io/llm-d/charts/llm-d-router-gateway \
  --version "$ROUTER_CHART_VERSION" \
  --reuse-values \
  --set httpRoute.create=false
kubectl delete httproute vllm-qwen3-32b --ignore-not-found

echo "==> Applying 02-inferencepool-backend-policy.yaml (Scenario B)"
kubectl apply -f "$MANIFESTS_DIR/02-inferencepool-backend-policy.yaml"

cat <<'EOF'

==> Done. Reach the gateway with:
  kubectl port-forward -n agentgateway-system svc/agentgateway-proxy 8080:8080

  # Scenario B (AgentgatewayBackend -> InferencePool, with a 100 tokens/min budget).
  # Send it a few times in a row; the simulator's response length is random up to
  # max_tokens, so exactly which request gets a 429 varies, but one always does:
  for i in 1 2 3; do
    curl -s -D - -o /dev/null http://localhost:8080/v1/chat/completions -H 'Content-Type: application/json' \
      -d '{"model":"Qwen/Qwen3-32B","max_tokens":200,"messages":[{"role":"user","content":"hi"}]}' \
      | grep -iE '^HTTP|x-ratelimit'
  done
EOF
