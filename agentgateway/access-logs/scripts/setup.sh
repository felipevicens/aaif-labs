#!/usr/bin/env bash
# End-to-end setup for the access-logs lab (G2 "Logs That Actually Explain
# What the Model Said"). Stands up agentgateway, a single-binary Loki
# instance, and an OTel Collector relaying agentgateway's own access-log
# OTLP export to Loki's native log-ingestion endpoint.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
MANIFESTS_DIR="$LAB_DIR/manifests"

CLUSTER_NAME="agentgateway-access-logs"
GWAPI_VERSION="1.6.0"
AGW_VERSION="1.5.0"
LOKI_VERSION="6.54.0"
OTEL_COLLECTOR_VERSION="0.135.0"

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

echo "==> Installing Loki $LOKI_VERSION (single-binary, filesystem storage, OTLP ingestion on :3100)"
helm repo add grafana https://grafana.github.io/helm-charts >/dev/null 2>&1 || true
helm repo update grafana >/dev/null
helm upgrade -i --create-namespace --namespace access-logs \
  --version "$LOKI_VERSION" loki grafana/loki \
  -f "$MANIFESTS_DIR/02-loki-values.yaml"

echo "==> Installing OTel Collector $OTEL_COLLECTOR_VERSION (relay to Loki's OTLP log endpoint)"
helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts >/dev/null 2>&1 || true
helm repo update open-telemetry >/dev/null
helm upgrade -i --create-namespace --namespace tracing \
  --version "$OTEL_COLLECTOR_VERSION" opentelemetry-collector open-telemetry/opentelemetry-collector \
  -f "$MANIFESTS_DIR/03-otel-collector-values.yaml"

echo "==> Waiting for the agentgateway GatewayClass to be accepted"
for i in $(seq 1 60); do
  kubectl get gatewayclass/agentgateway >/dev/null 2>&1 && break
  sleep 2
done
kubectl wait --for=jsonpath='{.status.conditions[?(@.type=="Accepted")].status}'=True \
  gatewayclass/agentgateway --timeout=120s

echo "==> Waiting for Loki to be ready"
kubectl wait --for=condition=Ready pod -l app.kubernetes.io/name=loki -n access-logs --timeout=180s

echo "==> Waiting for the OTel Collector to be ready"
kubectl wait --for=condition=Available deployment/opentelemetry-collector -n tracing --timeout=180s

echo "==> Applying 01-namespace-and-backend.yaml (httpbun-as-OpenAI + gateway + /chat route)"
kubectl apply -f "$MANIFESTS_DIR/01-namespace-and-backend.yaml"
kubectl wait --for=condition=Programmed gateway/agentgateway-proxy -n agentgateway-system --timeout=120s
kubectl wait --for=condition=Available deployment/agentgateway-proxy -n agentgateway-system --timeout=180s
kubectl wait --for=condition=Available deployment/httpbun -n access-logs --timeout=180s

echo "==> Applying 04-access-log-policy.yaml (ships access logs to the collector)"
kubectl apply -f "$MANIFESTS_DIR/04-access-log-policy.yaml"

cat <<EOF

==> Done. Port-forward the gateway and Loki's query API, each in its own
    terminal:
  kubectl port-forward -n agentgateway-system svc/agentgateway-proxy 8080:8080
  kubectl port-forward -n access-logs svc/loki 3100:3100

  # Send a request with a distinctive mocked completion
  curl -s http://localhost:8080/chat -H "Host: access-logs.internal" \\
    -H "Content-Type: application/json" \\
    -d '{"model":"gpt-4","messages":[{"role":"user","content":"hi"}],"httpbun":{"content":"the walrus guards the gate at midnight"}}'

  # Pull it back out of Loki. llm_completion arrives as structured
  # metadata, not an indexed label, so select the stream first and filter
  # on the metadata field as a pipeline stage.
  curl -s 'http://localhost:3100/loki/api/v1/query_range' \\
    --data-urlencode 'query={service_name="agentgateway-proxy"} | llm_completion=~".+"' | jq .

See manifests/00-cluster-and-install.md for the full walkthrough.
EOF
