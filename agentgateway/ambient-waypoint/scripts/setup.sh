#!/usr/bin/env bash
# End-to-end setup for the ambient-waypoint lab (I3 "Running agentgateway
# on Istio Ambient Mesh"). Fully keyless: httpbun stands in for the
# backend, no provider credentials needed anywhere.
#
# Unlike every other lab in this series, agentgateway is NOT installed
# via its own Helm chart here. Istio's own control plane (istiod)
# provisions it directly as an Ambient Mesh waypoint proxy, a feature
# Istio marks explicitly experimental as of 1.31.
#
# Requires istioctl on PATH, or downloads it into ./istio-<version> if
# missing.
#
# Usage:
#   ./setup.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
MANIFESTS_DIR="$LAB_DIR/manifests"

CLUSTER_NAME="agentgateway-ambient-waypoint"
GWAPI_VERSION="1.6.0"
ISTIO_VERSION="1.31.0"

if [ "$#" -gt 0 ]; then
  echo "Unknown argument: $1" >&2
  echo "Usage: $0" >&2
  exit 1
fi

ISTIOCTL="istioctl"
if ! command -v istioctl >/dev/null 2>&1; then
  if [ ! -x "$SCRIPT_DIR/istio-${ISTIO_VERSION}/bin/istioctl" ]; then
    echo "==> Downloading istioctl $ISTIO_VERSION"
    curl -sSL "https://github.com/istio/istio/releases/download/${ISTIO_VERSION}/istioctl-${ISTIO_VERSION}-linux-amd64.tar.gz" \
      | tar xz -C "$SCRIPT_DIR"
    mkdir -p "$SCRIPT_DIR/istio-${ISTIO_VERSION}/bin"
    mv "$SCRIPT_DIR/istioctl" "$SCRIPT_DIR/istio-${ISTIO_VERSION}/bin/istioctl"
  fi
  ISTIOCTL="$SCRIPT_DIR/istio-${ISTIO_VERSION}/bin/istioctl"
fi

echo "==> Creating kind cluster ($CLUSTER_NAME, node v1.34.0 pinned in kind-config.yaml)"
kind create cluster --name "$CLUSTER_NAME" --config "$LAB_DIR/kind-config.yaml"

echo "==> Installing Gateway API $GWAPI_VERSION (experimental channel)"
kubectl apply --server-side -f \
  "https://github.com/kubernetes-sigs/gateway-api/releases/download/v${GWAPI_VERSION}/experimental-install.yaml"

echo "==> Installing Istio $ISTIO_VERSION, ambient profile, agentgateway enabled"
"$ISTIOCTL" install --set profile=ambient \
  --set values.pilot.env.PILOT_ENABLE_AGENTGATEWAY=true \
  -y

echo "==> Waiting for the istio-agentgateway-waypoint GatewayClass to be accepted"
kubectl wait --for=jsonpath='{.status.conditions[?(@.type=="Accepted")].status}'=True \
  gatewayclass/istio-agentgateway-waypoint --timeout=120s

echo "==> Applying 01-namespace-and-backend.yaml"
kubectl apply -f "$MANIFESTS_DIR/01-namespace-and-backend.yaml"
kubectl wait --for=condition=Available deployment/httpbun -n ambient-demo --timeout=120s

echo "==> Applying 02-waypoint-gateway.yaml"
kubectl apply -f "$MANIFESTS_DIR/02-waypoint-gateway.yaml"
kubectl wait --for=condition=Programmed gateway/httpbun-waypoint -n ambient-demo --timeout=120s

echo "==> Applying 03-mesh-route.yaml"
kubectl apply -f "$MANIFESTS_DIR/03-mesh-route.yaml"

cat <<'EOF'

==> Done. Test from inside the mesh (ambient has no external listener
    for this lab, the waypoint only sees pod-to-pod traffic):

  kubectl run curltest --image=curlimages/curl:8.11.0 -n ambient-demo \
    --restart=Never --command -- sleep 3600
  kubectl exec -n ambient-demo curltest -- \
    curl -s http://httpbun.ambient-demo.svc.cluster.local/get

  # the response's "origin" field is the waypoint pod's IP, not the
  # caller's, and it carries an X-Via-Waypoint header the HTTPRoute
  # added, both are added by agentgateway acting as the waypoint

  kubectl delete pod curltest -n ambient-demo
EOF
