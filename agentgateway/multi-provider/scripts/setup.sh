#!/usr/bin/env bash
# End-to-end setup for the multi-provider lab (A1 "One API, Every Provider").
#
# Always applies the keyless path (01-gateway-backend-route.yaml) so the lab
# finishes even with no provider credentials at hand (CLAUDE.md: "labs must
# degrade gracefully"). 02 (OpenAI) and 03 (multi-provider groups, which also
# needs Gemini) are applied only when their env vars are set — otherwise this
# prints a clear warning and skips them instead of failing the whole run.
#
# 04 (Anthropic) is reference-only and never applied here, see its header.
#
# Usage:
#   ./setup.sh                  # Scenario 1 always, 2/3 if their keys are set
#   OPENAI_API_KEY=sk-... GEMINI_API_KEY=... ./setup.sh
set -euo pipefail

# envsubst ships with gettext, which isn't guaranteed to be installed (it
# wasn't in the environment this lab was validated in). Fall back to sed for
# the two placeholders this lab actually uses, same as 00-cluster-and-install.md
# already tells a reader without envsubst to do by hand.
apply_with_env() {
  local file="$1"
  if command -v envsubst >/dev/null 2>&1; then
    envsubst < "$file" | kubectl apply -f -
  else
    sed -e "s|\${OPENAI_API_KEY}|${OPENAI_API_KEY:-}|g" \
        -e "s|\${GEMINI_API_KEY}|${GEMINI_API_KEY:-}|g" \
        "$file" | kubectl apply -f -
  fi
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
MANIFESTS_DIR="$LAB_DIR/manifests"

CLUSTER_NAME="agentgateway-multi-provider"
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
  --version "v${AGW_VERSION}"

echo "==> Waiting for the agentgateway GatewayClass to exist"
# `kubectl wait` errors out immediately with NotFound if the object doesn't
# exist yet rather than waiting for it to be created. The controller pod
# needs a moment to start and register it after `helm upgrade -i` returns,
# so poll for existence first (confirmed live: without this, the very next
# `kubectl wait` below can race a freshly created pod and fail the whole
# script before the GatewayClass object is even there).
for i in $(seq 1 60); do
  kubectl get gatewayclass/agentgateway >/dev/null 2>&1 && break
  sleep 2
done

echo "==> Waiting for the agentgateway GatewayClass to be accepted"
kubectl wait --for=jsonpath='{.status.conditions[?(@.type=="Accepted")].status}'=True \
  gatewayclass/agentgateway --timeout=120s

echo "==> Scenario 1 (keyless): applying 01-gateway-backend-route.yaml"
kubectl apply -f "$MANIFESTS_DIR/01-gateway-backend-route.yaml"
kubectl wait --for=condition=Available deployment/httpbun -n default --timeout=120s
kubectl wait --for=condition=Programmed gateway/agentgateway-proxy -n agentgateway-system --timeout=120s

if [ -n "${OPENAI_API_KEY:-}" ]; then
  echo "==> Scenario 2 (OpenAI): applying 02-openai-secret-and-backend.yaml"
  apply_with_env "$MANIFESTS_DIR/02-openai-secret-and-backend.yaml"
else
  echo "==> Skipping Scenario 2 (OpenAI): OPENAI_API_KEY is not set."
  echo "    export OPENAI_API_KEY=sk-... and re-run to include it."
fi

if [ -n "${OPENAI_API_KEY:-}" ] && [ -n "${GEMINI_API_KEY:-}" ]; then
  echo "==> Scenario 3 (multi-provider groups): applying 03-multiprovider-priority-groups.yaml"
  apply_with_env "$MANIFESTS_DIR/03-multiprovider-priority-groups.yaml"
else
  echo "==> Skipping Scenario 3 (multi-provider groups): needs both OPENAI_API_KEY and GEMINI_API_KEY."
fi

echo "==> 04-anthropic-config-unvalidated.yaml is never applied automatically; see its header."

cat <<'EOF'

==> Done. Reach the gateway with:
  kubectl port-forward -n agentgateway-system svc/agentgateway-proxy 8080:8080

  # keyless (always works):
  curl -X POST http://localhost:8080/llm/httpbun -H 'Content-Type: application/json' \
    -d '{"model":"gpt-4","messages":[{"role":"user","content":"hi"}]}'
EOF
