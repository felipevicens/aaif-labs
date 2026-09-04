#!/usr/bin/env bash
# End-to-end setup for the guardrails-regex lab (B2 "Redacting PII Before
# It Ever Reaches the Model"). Fully keyless: httpbun is the only backend,
# since both scenarios are request-side regex guards that never need the
# completion's own content. See manifests/00-cluster-and-install.md for
# what each step actually proves.
#
# Usage:
#   ./setup.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
MANIFESTS_DIR="$LAB_DIR/manifests"

CLUSTER_NAME="agentgateway-guardrails-regex"
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

echo "==> Applying 01-gateway-and-backend.yaml"
kubectl apply -f "$MANIFESTS_DIR/01-gateway-and-backend.yaml"
kubectl wait --for=condition=Available deployment/httpbun -n default --timeout=120s
kubectl wait --for=condition=Programmed gateway/agentgateway-proxy -n agentgateway-system --timeout=120s

echo "==> Applying 02-custom-matches-policy.yaml"
kubectl apply -f "$MANIFESTS_DIR/02-custom-matches-policy.yaml"

echo "==> Applying 03-tool-output-scope-policy.yaml"
kubectl apply -f "$MANIFESTS_DIR/03-tool-output-scope-policy.yaml"

cat <<'EOF'

==> Done. Reach the gateway with:
  kubectl port-forward -n agentgateway-system svc/agentgateway-proxy 8080:8080

  # Scenario A, step 1: clean request, passes.
  curl -s -o /dev/null -w '%{http_code}\n' -X POST http://localhost:8080/llm/guarded-secret \
    -H 'Content-Type: application/json' \
    -d '{"model":"gpt-4","messages":[{"role":"user","content":"What is a load balancer?"}]}'

  # Scenario A, step 2: an AWS-key-shaped string, caught by the custom
  # regex, no builtin covers this.
  curl -s -X POST http://localhost:8080/llm/guarded-secret \
    -H 'Content-Type: application/json' \
    -d '{"model":"gpt-4","messages":[{"role":"user","content":"my key is AKIAABCDEFGHIJKLMNOP"}]}'

  # Scenario B, step 1: the same SSN string in an ordinary user message.
  curl -s -o /dev/null -w '%{http_code}\n' -X POST http://localhost:8080/llm/guarded-tool \
    -H 'Content-Type: application/json' \
    -d '{"model":"gpt-4","messages":[{"role":"user","content":"My SSN is 123-45-6789"}]}'

  # Scenario B, step 2: the same SSN string in a role: tool message.
  curl -s -o /dev/null -w '%{http_code}\n' -X POST http://localhost:8080/llm/guarded-tool \
    -H 'Content-Type: application/json' \
    -d '{"model":"gpt-4","messages":[{"role":"tool","tool_call_id":"call_1","content":"My SSN is 123-45-6789"}]}'
EOF
