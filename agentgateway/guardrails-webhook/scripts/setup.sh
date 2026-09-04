#!/usr/bin/env bash
# End-to-end setup for the guardrails-webhook lab (B4 "Writing Your Own
# Guardrail Webhook"). Fully keyless: both backends are lab-owned mock
# servers, no provider credentials anywhere. See
# manifests/00-cluster-and-install.md for what each step actually proves.
#
# Usage:
#   ./setup.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
MANIFESTS_DIR="$LAB_DIR/manifests"

CLUSTER_NAME="agentgateway-guardrails-webhook"
GWAPI_VERSION="1.6.0"
AGW_VERSION="1.5.0"

if [ "$#" -gt 0 ]; then
  echo "Unknown argument: $1" >&2
  echo "Usage: $0" >&2
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

echo "==> Applying 01-gateway-and-backends.yaml"
kubectl apply -f "$MANIFESTS_DIR/01-gateway-and-backends.yaml"
kubectl wait --for=condition=Available deployment/echo-backend -n default --timeout=120s
kubectl wait --for=condition=Available deployment/mock-completions-response -n default --timeout=120s
kubectl wait --for=condition=Programmed gateway/agentgateway-proxy -n agentgateway-system --timeout=120s

echo "==> Applying 02-guardrail-webhook.yaml"
kubectl apply -f "$MANIFESTS_DIR/02-guardrail-webhook.yaml"
kubectl wait --for=condition=Available deployment/guardrail-webhook -n agentgateway-system --timeout=120s

echo "==> Applying 03-webhook-policies.yaml"
kubectl apply -f "$MANIFESTS_DIR/03-webhook-policies.yaml"

cat <<'EOF'

==> Done. Reach the gateway with:
  kubectl port-forward -n agentgateway-system svc/agentgateway-proxy 8080:8080

  # Scenario A: request-side partial-redaction Mask.
  curl -s -X POST http://localhost:8080/llm/guarded-webhook-request \
    -H 'Content-Type: application/json' \
    -d '{"model":"gpt-4","messages":[{"role":"user","content":"my key is internal_sk_a1b2c3d4e5f67890"}]}'

  # Scenario B: response-side Mask, redacting a fabricated internal hostname.
  curl -s -X POST http://localhost:8080/llm/guarded-webhook-response \
    -H 'Content-Type: application/json' \
    -d '{"model":"gpt-4","messages":[{"role":"user","content":"how do I reach the internal service?"}]}'

  # Gotcha 1: does a response-side Reject actually work?
  curl -s -i -X POST http://localhost:8080/llm/guarded-webhook-response \
    -H 'Content-Type: application/json' \
    -d '{"model":"gpt-4","messages":[{"role":"user","content":"escalate this now"}]}'

  # Gotcha 2: scale the webhook to zero, then repeat a clean request-side
  # call. failureMode: FailOpen means it should still succeed.
  kubectl scale deployment/guardrail-webhook -n agentgateway-system --replicas=0
  curl -s -o /dev/null -w '%{http_code}\n' -X POST http://localhost:8080/llm/guarded-webhook-request \
    -H 'Content-Type: application/json' \
    -d '{"model":"gpt-4","messages":[{"role":"user","content":"a perfectly clean request"}]}'
  kubectl scale deployment/guardrail-webhook -n agentgateway-system --replicas=1
EOF
