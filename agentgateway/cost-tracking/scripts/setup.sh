#!/usr/bin/env bash
# End-to-end setup for the cost-tracking lab (C1 "What Does This Prompt
# Actually Cost You?"). Fully keyless: the only backend is a lab-owned
# mock server, no provider credentials anywhere. See
# manifests/00-cluster-and-install.md for what each step actually proves.
#
# Usage:
#   ./setup.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
MANIFESTS_DIR="$LAB_DIR/manifests"

CLUSTER_NAME="agentgateway-cost-tracking"
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

echo "==> Applying 01-gateway-and-catalog.yaml"
kubectl apply -f "$MANIFESTS_DIR/01-gateway-and-catalog.yaml"
kubectl wait --for=condition=Available deployment/cost-mock-backend -n default --timeout=120s
kubectl wait --for=condition=Programmed gateway/agentgateway-proxy -n agentgateway-system --timeout=120s

echo "==> Applying 02-cost-access-log-policy.yaml"
kubectl apply -f "$MANIFESTS_DIR/02-cost-access-log-policy.yaml"

cat <<'EOF'

==> Done. Reach the gateway with:
  kubectl port-forward -n agentgateway-system svc/agentgateway-proxy 8080:8080

  # Scenario A: cheap model, 1000/500 tokens.
  curl -s -o /dev/null -X POST http://localhost:8080/llm/cheap-model \
    -H 'Content-Type: application/json' \
    -d '{"model":"gpt-4o-mini","messages":[{"role":"user","content":"hello"}]}'

  # Scenario B: pricey model, same 1000/500 tokens.
  curl -s -o /dev/null -X POST http://localhost:8080/llm/pricey-model \
    -H 'Content-Type: application/json' \
    -d '{"model":"gpt-4o","messages":[{"role":"user","content":"hello"}]}'

  # Gotcha: a model the catalog has never priced.
  curl -s -o /dev/null -X POST http://localhost:8080/llm/unpriced-model \
    -H 'Content-Type: application/json' \
    -d '{"model":"shadow-model-v1","messages":[{"role":"user","content":"hello"}]}'

  # Read what the access log actually recorded for each.
  kubectl logs -n agentgateway-system deployment/agentgateway-proxy --tail=50

  # The raw token-usage metric, no Prometheus install needed.
  kubectl port-forward -n agentgateway-system deployment/agentgateway-proxy 15020:15020 &
  curl -s http://localhost:15020/metrics | grep agentgateway_gen_ai_client_token_usage
EOF
