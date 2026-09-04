#!/usr/bin/env bash
# End-to-end setup for the extauth lab (F2 "Bring Your Own External Auth
# Service"). Stands up the gateway, a mock backend, the Istio ext-authz
# test fixture, and the policy that wires them together. See
# manifests/00-cluster-and-install.md for the full scenario commands.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
MANIFESTS_DIR="$LAB_DIR/manifests"

CLUSTER_NAME="agentgateway-extauth"
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

echo "==> Applying 01-gateway-and-backend.yaml"
kubectl apply -f "$MANIFESTS_DIR/01-gateway-and-backend.yaml"
kubectl wait --for=condition=Programmed gateway/agentgateway-proxy -n agentgateway-system --timeout=120s
kubectl wait --for=condition=Available deployment/agentgateway-proxy -n agentgateway-system --timeout=180s
kubectl wait --for=condition=Available deployment/httpbun -n default --timeout=180s

echo "==> Applying 02-ext-authz-service.yaml"
kubectl apply -f "$MANIFESTS_DIR/02-ext-authz-service.yaml"
kubectl wait --for=condition=Available deployment/ext-authz -n agentgateway-system --timeout=180s

echo "==> Applying 03-extauth-policy.yaml"
kubectl apply -f "$MANIFESTS_DIR/03-extauth-policy.yaml"

cat <<EOF

==> Done.

Call the guarded route:
  kubectl port-forward -n agentgateway-system svc/agentgateway-proxy 8080:8080 &
  curl -s -o /dev/null -w '%{http_code}\n' http://localhost:8080/llm \\
    -H 'Content-Type: application/json' -H 'x-ext-authz: allow' \\
    -d '{"model":"gpt-4","messages":[{"role":"user","content":"hi"}]}'

See manifests/00-cluster-and-install.md for the full scenario commands,
including the denied paths.
EOF
