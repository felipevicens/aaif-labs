#!/usr/bin/env bash
# End-to-end setup for the web-uis lab (E2 "Open WebUI, LibreChat and
# kagent Against One Gateway"). Stands up the gateway, the shared mock
# backend, all three front-ends, and kagent itself, but does NOT apply
# 02-guardrail-policy.yaml — that goes on by hand, so the before/after
# across all three front-ends is visible. See manifests/00-cluster-and-install.md.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
MANIFESTS_DIR="$LAB_DIR/manifests"

CLUSTER_NAME="agentgateway-web-uis"
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
  --version "v${AGW_VERSION}" \
  --set controller.extraEnv.KGW_ENABLE_GATEWAY_API_EXPERIMENTAL_FEATURES=true

echo "==> Waiting for the agentgateway GatewayClass to be accepted"
for i in $(seq 1 60); do
  kubectl get gatewayclass/agentgateway >/dev/null 2>&1 && break
  sleep 2
done
kubectl wait --for=jsonpath='{.status.conditions[?(@.type=="Accepted")].status}'=True \
  gatewayclass/agentgateway --timeout=120s

echo "==> Applying 01-gateway-and-mock-backend.yaml"
kubectl apply -f "$MANIFESTS_DIR/01-gateway-and-mock-backend.yaml"
kubectl wait --for=condition=Programmed gateway/agentgateway-proxy -n agentgateway-system --timeout=120s
kubectl wait --for=condition=Available deployment/agentgateway-proxy -n agentgateway-system --timeout=180s
kubectl wait --for=condition=Available deployment/mock-llm -n web-uis --timeout=180s

echo "==> Applying 03-open-webui.yaml"
kubectl apply -f "$MANIFESTS_DIR/03-open-webui.yaml"

echo "==> Applying 04-librechat.yaml"
kubectl apply -f "$MANIFESTS_DIR/04-librechat.yaml"

echo "==> Waiting for Open WebUI, MongoDB, and LibreChat to be Available"
kubectl wait --for=condition=Available deployment/open-webui -n web-uis --timeout=300s
kubectl wait --for=condition=Available deployment/mongodb -n web-uis --timeout=180s
kubectl wait --for=condition=Available deployment/librechat -n web-uis --timeout=300s

echo "==> Installing kagent (kagent-crds + kagent charts)"
helm upgrade -i kagent-crds oci://ghcr.io/kagent-dev/kagent/helm/kagent-crds \
  --namespace kagent --create-namespace
helm upgrade -i kagent oci://ghcr.io/kagent-dev/kagent/helm/kagent \
  --namespace kagent \
  --set providers.default=openAI \
  --set providers.openAI.apiKey=placeholder

echo "==> Waiting for the kagent controller to be Available"
kubectl wait --for=condition=Available deployment/kagent-controller -n kagent --timeout=300s

echo "==> Applying 05-kagent-model-and-agent.yaml"
kubectl apply -f "$MANIFESTS_DIR/05-kagent-model-and-agent.yaml"

cat <<'EOF'

==> Done. Reach everything with port-forwards:
  kubectl port-forward -n agentgateway-system svc/agentgateway-proxy 8080:8080
  kubectl port-forward -n web-uis svc/open-webui 3000:8080
  kubectl port-forward -n web-uis svc/librechat 3080:3080
  kubectl port-forward -n kagent svc/kagent-controller 8083:8083

See manifests/00-cluster-and-install.md for the full scenario commands,
including applying manifests/02-guardrail-policy.yaml by hand for the
before/after.
EOF
