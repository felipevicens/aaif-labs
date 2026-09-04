#!/usr/bin/env bash
# End-to-end setup for the guardrails-moderation lab (B3 "Moderation as a
# Gateway Policy, Not App Code"). The one lab in this series that isn't
# fully keyless: openAIModeration has no baseURL override anywhere, so it
# needs a real OpenAI API key with moderation access. Everything else
# (the route's own LLM backend) stays keyless, httpbun.
#
# Usage:
#   export OPENAI_API_KEY="sk-..."
#   ./setup.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
MANIFESTS_DIR="$LAB_DIR/manifests"

CLUSTER_NAME="agentgateway-guardrails-moderation"
GWAPI_VERSION="1.6.0"
AGW_VERSION="1.5.0"

if [ -z "${OPENAI_API_KEY:-}" ]; then
  echo "Set OPENAI_API_KEY first: export OPENAI_API_KEY=\"sk-...\"" >&2
  exit 1
fi

echo "==> Creating kind cluster ($CLUSTER_NAME, node v1.34.0 pinned in kind-config.yaml)"
kind create cluster --name "$CLUSTER_NAME" --config "$LAB_DIR/kind-config.yaml"

echo "==> Installing Gateway API $GWAPI_VERSION (standard channel, nothing here needs experimental)"
kubectl apply --server-side -f \
  "https://github.com/kubernetes-sigs/gateway-api/releases/download/v${GWAPI_VERSION}/standard-install.yaml"

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

echo "==> Applying 01-gateway-and-backend.yaml"
kubectl apply -f "$MANIFESTS_DIR/01-gateway-and-backend.yaml"
kubectl wait --for=condition=Available deployment/httpbun -n default --timeout=120s
kubectl wait --for=condition=Programmed gateway/agentgateway-proxy -n agentgateway-system --timeout=120s

echo "==> Applying 02-moderation-secret.yaml (envsubst, real key never written to disk)"
envsubst < "$MANIFESTS_DIR/02-moderation-secret.yaml" | kubectl apply -f -

echo "==> Applying 03-moderation-policy.yaml"
kubectl apply -f "$MANIFESTS_DIR/03-moderation-policy.yaml"

cat <<'EOF'

==> Done. Reach the gateway with:
  kubectl port-forward -n agentgateway-system svc/agentgateway-proxy 8080:8080

  # Clean request, passes.
  curl -s -o /dev/null -w '%{http_code}\n' -X POST http://localhost:8080/llm/guarded-moderation \
    -H 'Content-Type: application/json' \
    -d '{"model":"gpt-4","messages":[{"role":"user","content":"What is a load balancer?"}]}'

  # Flagged by real moderation scoring.
  curl -s -X POST http://localhost:8080/llm/guarded-moderation \
    -H 'Content-Type: application/json' \
    -d '{"model":"gpt-4","messages":[{"role":"user","content":"I want to harm myself"}]}'
EOF
