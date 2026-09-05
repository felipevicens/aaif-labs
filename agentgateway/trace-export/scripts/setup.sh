#!/usr/bin/env bash
# End-to-end setup for the trace-export lab (G3 "Exporting Traces to
# Datadog, Honeycomb and Grafana Cloud"). Stands up agentgateway, a
# single-binary Tempo instance (stand-in for a destination that accepts
# anonymous OTLP, same shape as a Datadog Agent or Jaeger), an OTel
# Collector configured to inject a header (stand-in for the Honeycomb/
# Grafana Cloud pattern), and a fake-vendor HTTP server that proves
# whether that header actually arrived.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
MANIFESTS_DIR="$LAB_DIR/manifests"

CLUSTER_NAME="agentgateway-trace-export"
GWAPI_VERSION="1.6.0"
AGW_VERSION="1.5.0"
TEMPO_VERSION="1.16.0"
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

echo "==> Installing Tempo $TEMPO_VERSION (single-binary, OTLP receiver on :4317)"
helm upgrade -i --create-namespace --namespace telemetry \
  --version "$TEMPO_VERSION" tempo \
  --repo https://grafana.github.io/helm-charts tempo

echo "==> Installing OTel Collector $OTEL_COLLECTOR_VERSION (header-injecting hop to fake-vendor)"
helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts >/dev/null 2>&1 || true
helm repo update open-telemetry >/dev/null
helm upgrade -i --create-namespace --namespace tracing \
  --version "$OTEL_COLLECTOR_VERSION" opentelemetry-collector open-telemetry/opentelemetry-collector \
  -f "$MANIFESTS_DIR/04-otel-collector-values.yaml"

echo "==> Waiting for the agentgateway GatewayClass to be accepted"
for i in $(seq 1 60); do
  kubectl get gatewayclass/agentgateway >/dev/null 2>&1 && break
  sleep 2
done
kubectl wait --for=jsonpath='{.status.conditions[?(@.type=="Accepted")].status}'=True \
  gatewayclass/agentgateway --timeout=120s

echo "==> Waiting for Tempo to be ready"
kubectl wait --for=condition=Ready pod -l app.kubernetes.io/name=tempo -n telemetry --timeout=180s

echo "==> Waiting for the OTel Collector to be ready"
kubectl wait --for=condition=Available deployment/opentelemetry-collector -n tracing --timeout=180s

echo "==> Applying 01-namespace-and-backend.yaml (httpbun + gateway + /good route)"
kubectl apply -f "$MANIFESTS_DIR/01-namespace-and-backend.yaml"
kubectl wait --for=condition=Programmed gateway/agentgateway-proxy -n agentgateway-system --timeout=120s
kubectl wait --for=condition=Available deployment/agentgateway-proxy -n agentgateway-system --timeout=180s
kubectl wait --for=condition=Available deployment/httpbun -n trace-export --timeout=180s

echo "==> Applying 02-fake-vendor.yaml (header-checking stand-in for a SaaS backend)"
kubectl apply -f "$MANIFESTS_DIR/02-fake-vendor.yaml"
kubectl wait --for=condition=Available deployment/fake-vendor -n trace-export --timeout=180s

echo "==> Applying 03-tracing-policy-direct.yaml (Scenario 1: straight to Tempo)"
kubectl apply -f "$MANIFESTS_DIR/03-tracing-policy-direct.yaml"

cat <<EOF

==> Done. Port-forward the gateway, Tempo's query API, and the OTel
    Collector, each in its own terminal:
  kubectl port-forward -n agentgateway-system svc/agentgateway-proxy 8080:8080
  kubectl port-forward -n telemetry svc/tempo 3100:3100

  # Scenario 1: direct to Tempo, same shape as a Datadog Agent or Jaeger
  curl -s http://localhost:8080/good -H "Host: tracing.internal"
  curl -s "http://localhost:3100/api/search?tags=&limit=20" | jq .

  # Scenario 2: switch to the OTel Collector (Honeycomb/Grafana Cloud shape)
  kubectl apply -f manifests/05-tracing-policy-collector.yaml
  curl -s http://localhost:8080/good -H "Host: tracing.internal"
  kubectl logs -n trace-export deploy/fake-vendor | tail -5

See manifests/00-cluster-and-install.md for the full walkthrough.
EOF
