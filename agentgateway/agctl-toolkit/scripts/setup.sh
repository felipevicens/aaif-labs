#!/usr/bin/env bash
# End-to-end setup for the agctl-toolkit lab (I2 "The agctl Debugging
# Toolkit"). Stands up agentgateway, an httpbun-backed /chat route, a
# second /broken route with no live backend, and installs an agctl binary
# version-matched to the agentgateway control plane. No separate
# observability stack: agctl proxy trace/config talk to the proxy's own
# admin endpoint directly.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
MANIFESTS_DIR="$LAB_DIR/manifests"

CLUSTER_NAME="agentgateway-agctl-toolkit"
GWAPI_VERSION="1.6.0"
AGW_VERSION="1.5.0"
AGCTL_BIN="$LAB_DIR/agctl"

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

echo "==> Installing agctl $AGW_VERSION (version-matched to the control plane)"
curl -sL "https://github.com/agentgateway/agentgateway/releases/download/v${AGW_VERSION}/agctl-linux-amd64" \
  -o "$AGCTL_BIN"
chmod +x "$AGCTL_BIN"
"$AGCTL_BIN" version

echo "==> Waiting for the agentgateway GatewayClass to be accepted"
for i in $(seq 1 60); do
  kubectl get gatewayclass/agentgateway >/dev/null 2>&1 && break
  sleep 2
done
kubectl wait --for=jsonpath='{.status.conditions[?(@.type=="Accepted")].status}'=True \
  gatewayclass/agentgateway --timeout=120s

echo "==> Applying 01-namespace-and-backend.yaml (httpbun + gateway + /chat route)"
kubectl apply -f "$MANIFESTS_DIR/01-namespace-and-backend.yaml"
kubectl wait --for=condition=Programmed gateway/agentgateway-proxy -n agentgateway-system --timeout=120s
kubectl wait --for=condition=Available deployment/agentgateway-proxy -n agentgateway-system --timeout=180s
kubectl wait --for=condition=Available deployment/httpbun -n agctl-toolkit --timeout=180s

echo "==> Applying 02-broken-route.yaml (/broken, no live backend behind it)"
kubectl apply -f "$MANIFESTS_DIR/02-broken-route.yaml"

cat <<EOF

==> Done. agctl is at $AGCTL_BIN. In one terminal, watch for the next
    request and trace it:

  $AGCTL_BIN proxy trace gateway/agentgateway-proxy -n agentgateway-system --raw

  In another terminal, send the request that gets traced:

  curl -s http://localhost:8080/chat -H "Host: agctl-toolkit.internal" \\
    -H "Content-Type: application/json" \\
    -d '{"model":"gpt-4","messages":[{"role":"user","content":"hi"}]}'

  (Needs its own port-forward first: kubectl port-forward -n
  agentgateway-system svc/agentgateway-proxy 8080:8080 &)

  Or let agctl send the request itself (inject mode, no second terminal):

  $AGCTL_BIN proxy trace gateway/agentgateway-proxy -n agentgateway-system \\
    --raw --port 8080 -- http://agctl-toolkit.internal/chat \\
    -X POST -H "Content-Type: application/json" \\
    -d '{"model":"gpt-4","messages":[{"role":"user","content":"hi"}]}'

  # Same, against the broken route, to see a failed backend call in the trace
  $AGCTL_BIN proxy trace gateway/agentgateway-proxy -n agentgateway-system \\
    --raw --port 8080 -- http://agctl-toolkit.internal/broken

  # Runtime config and backend health, no port-forward needed
  $AGCTL_BIN proxy config all gateway/agentgateway-proxy -n agentgateway-system -o yaml
  $AGCTL_BIN proxy config backends gateway/agentgateway-proxy -n agentgateway-system
  $AGCTL_BIN proxy config backends gateway/agentgateway-proxy -n agentgateway-system --all

See manifests/00-cluster-and-install.md for the full walkthrough.
EOF
