#!/usr/bin/env bash
# End-to-end setup for the request-tracing lab (G1 "Following One Request
# End to End: Tracing With Tempo"). Stands up agentgateway, a single-binary
# Tempo instance receiving OTLP traces directly (no separate OTel
# Collector), a plain HTTP route, and an LLM-shaped route, then turns on
# tracing for the whole Gateway via one AgentgatewayPolicy.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
MANIFESTS_DIR="$LAB_DIR/manifests"

CLUSTER_NAME="agentgateway-request-tracing"
GWAPI_VERSION="1.6.0"
AGW_VERSION="1.5.0"
TEMPO_VERSION="1.16.0"

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
  --version "v${AGW_VERSION}" \
  --set controller.extraEnv.KGW_ENABLE_GATEWAY_API_EXPERIMENTAL_FEATURES=true

echo "==> Installing Tempo $TEMPO_VERSION (single-binary, OTLP receiver on :4317)"
helm upgrade -i --create-namespace --namespace telemetry \
  --version "$TEMPO_VERSION" tempo \
  --repo https://grafana.github.io/helm-charts tempo

echo "==> Waiting for the agentgateway GatewayClass to be accepted"
for i in $(seq 1 60); do
  kubectl get gatewayclass/agentgateway >/dev/null 2>&1 && break
  sleep 2
done
kubectl wait --for=jsonpath='{.status.conditions[?(@.type=="Accepted")].status}'=True \
  gatewayclass/agentgateway --timeout=120s

echo "==> Waiting for Tempo to be ready"
kubectl wait --for=condition=Ready pod -l app.kubernetes.io/name=tempo -n telemetry --timeout=180s

echo "==> Applying 01-namespace-and-backend.yaml (httpbun + gateway + /good route)"
kubectl apply -f "$MANIFESTS_DIR/01-namespace-and-backend.yaml"
kubectl wait --for=condition=Programmed gateway/agentgateway-proxy -n agentgateway-system --timeout=120s
kubectl wait --for=condition=Available deployment/agentgateway-proxy -n agentgateway-system --timeout=180s
kubectl wait --for=condition=Available deployment/httpbun -n request-tracing --timeout=180s

echo "==> Applying 02-ai-backend-and-route.yaml (LLM-shaped /chat route)"
kubectl apply -f "$MANIFESTS_DIR/02-ai-backend-and-route.yaml"

echo "==> Applying 03-tracing-policy.yaml (turns tracing on for the Gateway)"
kubectl apply -f "$MANIFESTS_DIR/03-tracing-policy.yaml"

cat <<EOF

==> Done. Port-forward the gateway and Tempo's query API, each in its own
    terminal:
  kubectl port-forward -n agentgateway-system svc/agentgateway-proxy 8080:8080
  kubectl port-forward -n telemetry svc/tempo 3100:3100

  # Baseline: plain HTTP route, only default span attributes
  curl -s http://localhost:8080/good -H "Host: tracing.internal"

  # LLM-shaped route, same gateway, extra gen_ai.* span attributes
  curl -s http://localhost:8080/chat -H "Host: tracing.internal" \\
    -H "Content-Type: application/json" \\
    -d '{"model":"gpt-4","messages":[{"role":"user","content":"hi"}]}'

  # Search Tempo for recent traces from the gateway service
  curl -s "http://localhost:3100/api/search?tags=&limit=20" | jq .

  # Pull back one trace by ID (from the search results above) and inspect
  # its spans/attributes
  curl -s "http://localhost:3100/api/traces/<traceID>" | jq .

See manifests/00-cluster-and-install.md for the full walkthrough.
EOF
