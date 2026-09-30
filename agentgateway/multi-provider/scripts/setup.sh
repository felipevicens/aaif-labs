#!/usr/bin/env bash
# End-to-end setup for the multi-provider lab (A1).
#
# The keyless scenarios (01 httpbun, 03 see-the-translation, 08 groups without
# eviction) are always applied, so the lab finishes with no provider keys at
# all. 02 (OpenAI), 04 (Gemini), 05 (Anthropic) and 06 (OpenAI + Gemini) are
# applied only when their env vars are set. They all re-apply the same backend
# `llm`, so the final state is the last one your keys allow.
#
# Secrets are created from the environment with `kubectl create secret`. No
# manifest carries a key or a ${PLACEHOLDER}, so nothing here needs envsubst.
#
# Usage:
#   ./setup.sh
#   OPENAI_API_KEY=sk-... GEMINI_API_KEY=... ANTHROPIC_API_KEY=sk-ant-... ./setup.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
M="$LAB_DIR/manifests"

CLUSTER_NAME="agentgateway-multi-provider"
GWAPI_VERSION="1.6.0"
AGW_VERSION="1.5.0"
NS="agentgateway-system"

echo "==> Creating kind cluster ($CLUSTER_NAME, node image pinned in kind-config.yaml)"
kind create cluster --name "$CLUSTER_NAME" --config "$LAB_DIR/kind-config.yaml"

echo "==> Installing Gateway API $GWAPI_VERSION (experimental channel)"
kubectl apply --server-side -f \
  "https://github.com/kubernetes-sigs/gateway-api/releases/download/v${GWAPI_VERSION}/experimental-install.yaml"

echo "==> Installing agentgateway $AGW_VERSION (CRDs, then control plane)"
helm upgrade -i --create-namespace -n "$NS" --version "v${AGW_VERSION}" \
  agentgateway-crds oci://cr.agentgateway.dev/charts/agentgateway-crds
helm upgrade -i -n "$NS" --version "v${AGW_VERSION}" \
  agentgateway oci://cr.agentgateway.dev/charts/agentgateway

echo "==> Waiting for the agentgateway GatewayClass"
# kubectl wait fails at once with NotFound if the object does not exist yet,
# so poll for it first: the controller needs a moment to register it.
for _ in $(seq 1 60); do
  kubectl get gatewayclass/agentgateway >/dev/null 2>&1 && break
  sleep 2
done
kubectl wait --for=jsonpath='{.status.conditions[?(@.type=="Accepted")].status}'=True \
  gatewayclass/agentgateway --timeout=120s

echo "==> Scenario 1 (keyless): gateway, httpbun, backend llm, route /v1/chat/completions"
kubectl apply -f "$M/01-gateway-httpbun-route.yaml"
kubectl wait --for=condition=Available deployment/httpbun -n default --timeout=180s
kubectl wait --for=condition=Programmed gateway/agentgateway-proxy -n "$NS" --timeout=180s

echo "==> Scenario 3 (keyless): echo server + wire-gemini / wire-anthropic"
kubectl apply -f "$M/03-see-the-translation.yaml"
kubectl wait --for=condition=Available deployment/echo -n default --timeout=180s

echo "==> Gotcha demo (keyless): groups without eviction on /demo/groups"
kubectl apply -f "$M/08-groups-without-eviction.yaml"

if [ -n "${OPENAI_API_KEY:-}" ]; then
  echo "==> Scenario 2 (OpenAI)"
  kubectl create secret generic openai-credentials -n "$NS" \
    --from-literal=Authorization="$OPENAI_API_KEY" --dry-run=client -o yaml | kubectl apply -f -
  kubectl apply -f "$M/02-openai-backend.yaml"
else
  echo "==> Skipping Scenario 2: OPENAI_API_KEY is not set"
fi

if [ -n "${GEMINI_API_KEY:-}" ]; then
  echo "==> Scenario 4 (Gemini)"
  kubectl create secret generic gemini-credentials -n "$NS" \
    --from-literal=Authorization="$GEMINI_API_KEY" --dry-run=client -o yaml | kubectl apply -f -
  kubectl apply -f "$M/04-gemini-backend.yaml"
else
  echo "==> Skipping Scenario 4: GEMINI_API_KEY is not set"
fi

if [ -n "${ANTHROPIC_API_KEY:-}" ]; then
  echo "==> Scenario 5 (Anthropic)"
  kubectl create secret generic anthropic-credentials -n "$NS" \
    --from-literal=Authorization="$ANTHROPIC_API_KEY" --dry-run=client -o yaml | kubectl apply -f -
  kubectl apply -f "$M/05-anthropic-backend.yaml"
else
  echo "==> Skipping Scenario 5: ANTHROPIC_API_KEY is not set"
fi

if [ -n "${OPENAI_API_KEY:-}" ] && [ -n "${GEMINI_API_KEY:-}" ]; then
  echo "==> Scenario 6 (OpenAI + Gemini in one backend, OpenAI first)"
  kubectl apply -f "$M/06-provider-groups-openai-first.yaml"
else
  echo "==> Skipping Scenario 6: needs both OPENAI_API_KEY and GEMINI_API_KEY"
fi

cat <<'EOF'

==> Done. In another terminal:
  kubectl port-forward -n agentgateway-system svc/agentgateway-proxy 8080:8080

Then:
  curl -s http://localhost:8080/v1/chat/completions -H 'Content-Type: application/json' \
    -d '{"model":"gpt-4o-mini","messages":[{"role":"user","content":"Say OK"}]}'
EOF
