#!/usr/bin/env bash
# End-to-end setup for the canary-deploy lab (H5 "Canary-Deploying a New
# Model Version"). Fully keyless: both backends are httpbun, no provider
# credentials needed anywhere. Stands up the cluster and applies stage 1
# of the rollout (95/5); promoting further is a separate kubectl apply,
# printed at the end.
#
# Usage:
#   ./setup.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
MANIFESTS_DIR="$LAB_DIR/manifests"

CLUSTER_NAME="agentgateway-canary-deploy"
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
for i in $(seq 1 60); do
  kubectl get gatewayclass/agentgateway >/dev/null 2>&1 && break
  sleep 2
done

echo "==> Waiting for the agentgateway GatewayClass to be accepted"
kubectl wait --for=jsonpath='{.status.conditions[?(@.type=="Accepted")].status}'=True \
  gatewayclass/agentgateway --timeout=120s

echo "==> Applying 01-namespace-and-backends.yaml"
kubectl apply -f "$MANIFESTS_DIR/01-namespace-and-backends.yaml"
kubectl wait --for=condition=Available deployment/model-v1-stable -n canary --timeout=120s
kubectl wait --for=condition=Available deployment/model-v2-canary -n canary --timeout=120s
kubectl wait --for=condition=Programmed gateway/agentgateway-proxy -n agentgateway-system --timeout=120s

echo "==> Applying stage 1 of the rollout: 95/5 (02-route-canary-95-5.yaml)"
kubectl apply -f "$MANIFESTS_DIR/02-route-canary-95-5.yaml"

cat <<'EOF'

==> Done. Reach the gateway with:
  kubectl port-forward -n agentgateway-system svc/agentgateway-proxy 8080:8080

  # send a batch of requests, then tally each backend's own access log
  for i in $(seq 1 100); do curl -s -o /dev/null http://localhost:8080/v1/chat/completions; done
  kubectl logs deploy/model-v1-stable -n canary | grep -c ' GET '
  kubectl logs deploy/model-v2-canary -n canary | grep -c ' GET '

  # promote the canary (same HTTPRoute, new weights, no restart)
  kubectl apply -f ../manifests/03-route-canary-50-50.yaml

  # full cutover
  kubectl apply -f ../manifests/04-route-canary-0-100.yaml
EOF
