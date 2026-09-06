#!/usr/bin/env bash
# End-to-end setup for the route-delegation lab (H1 "Splitting One Route
# Into Ten Teams' Routes"). Fully keyless: every scenario runs against
# httpbun, no provider credentials needed anywhere.
#
# Deliberately applies the parent route and both children BEFORE the
# ReferenceGrants so you can see agentgateway 1.5.0's cross-namespace
# delegation gotcha for yourself, then applies the grants to fix it. See
# manifests/00-cluster-and-install.md for the exact commands and captured
# output.
#
# Usage:
#   ./setup.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
MANIFESTS_DIR="$LAB_DIR/manifests"

CLUSTER_NAME="agentgateway-route-delegation"
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

echo "==> Applying 01-namespaces-and-backends.yaml"
kubectl apply -f "$MANIFESTS_DIR/01-namespaces-and-backends.yaml"
kubectl wait --for=condition=Available deployment/httpbun -n team1 --timeout=120s
kubectl wait --for=condition=Available deployment/httpbun -n team2 --timeout=120s
kubectl wait --for=condition=Programmed gateway/agentgateway-proxy -n agentgateway-system --timeout=120s

echo "==> Applying 04-child-team1.yaml, 05-child-team2.yaml, 06-grandchild.yaml"
kubectl apply -f "$MANIFESTS_DIR/04-child-team1.yaml"
kubectl apply -f "$MANIFESTS_DIR/05-child-team2.yaml"
kubectl apply -f "$MANIFESTS_DIR/06-grandchild.yaml"

echo "==> Applying 02-parent-route.yaml (no ReferenceGrants yet - delegation will be rejected)"
kubectl apply -f "$MANIFESTS_DIR/02-parent-route.yaml"

echo "==> Applying 03-referencegrants.yaml (fixes the cross-namespace delegation)"
kubectl apply -f "$MANIFESTS_DIR/03-referencegrants.yaml"

echo "==> Applying 07-header-policy.yaml (parent header injection + team2 override)"
kubectl apply -f "$MANIFESTS_DIR/07-header-policy.yaml"

cat <<'EOF'

==> Done. Reach the gateway with:
  kubectl port-forward -n agentgateway-system svc/agentgateway-proxy 8080:8080

  # team1: inherits the parent's 1s timeout and the parent's header value
  curl -s http://localhost:8080/team1/headers | grep -i x-routed-by
  curl -s -o /dev/null -w '%{http_code} %{time_total}s\n' http://localhost:8080/team1/delay/3

  # team2: overrides the timeout to 5s and overrides the header value
  curl -s -o /dev/null -w '%{http_code} %{time_total}s\n' http://localhost:8080/team2/delay/3

  # team2 delegated a second level to a grandchild: the override still cascades
  curl -s http://localhost:8080/team2/nested/headers | grep -i x-routed-by
EOF
