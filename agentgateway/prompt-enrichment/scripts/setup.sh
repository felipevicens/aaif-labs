#!/usr/bin/env bash
# End-to-end setup for the prompt-enrichment lab (H2 "Injecting System
# Prompts Without Touching Any App"). httpbun mocks the backend, no
# provider credentials needed. agctl is installed version-matched to the
# control plane, since Scenario 1 uses agctl proxy trace to show the exact
# messages array agentgateway sends upstream, after enrichment.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
MANIFESTS_DIR="$LAB_DIR/manifests"

CLUSTER_NAME="agentgateway-prompt-enrichment"
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

echo "==> Installing Gateway API $GWAPI_VERSION (standard channel, nothing here needs experimental)"
kubectl apply --server-side -f \
  "https://github.com/kubernetes-sigs/gateway-api/releases/download/v${GWAPI_VERSION}/standard-install.yaml"

echo "==> Installing agentgateway CRDs $AGW_VERSION"
helm upgrade -i --create-namespace --namespace agentgateway-system \
  --version "v${AGW_VERSION}" agentgateway-crds \
  oci://cr.agentgateway.dev/charts/agentgateway-crds

echo "==> Installing agentgateway control plane $AGW_VERSION"
helm upgrade -i -n agentgateway-system agentgateway oci://cr.agentgateway.dev/charts/agentgateway \
  --version "v${AGW_VERSION}"

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

echo "==> Applying 01-namespace-and-backend.yaml (baseline, no enrichment yet)"
kubectl apply -f "$MANIFESTS_DIR/01-namespace-and-backend.yaml"
kubectl wait --for=condition=Programmed gateway/agentgateway-proxy -n agentgateway-system --timeout=120s
kubectl wait --for=condition=Available deployment/agentgateway-proxy -n agentgateway-system --timeout=180s
kubectl wait --for=condition=Available deployment/httpbun -n prompt-enrichment --timeout=180s

echo "==> Applying 02-prompt-enrichment-policy.yaml"
kubectl apply -f "$MANIFESTS_DIR/02-prompt-enrichment-policy.yaml"

cat <<EOF

==> Done. agctl is at $AGCTL_BIN.

  # Trace a request end to end, see the enriched messages array
  # agentgateway actually sends upstream:
  $AGCTL_BIN proxy trace gateway/agentgateway-proxy -n agentgateway-system \\
    --raw --port 8080 -- http://prompt-enrichment.internal/chat \\
    -X POST -H "Content-Type: application/json" \\
    -d '{"model":"gpt-4","messages":[{"role":"user","content":"What is your return policy?"}]}'

  # Same, but the client already sends its own system message: confirm
  # whether prepend adds a second one or replaces it.
  $AGCTL_BIN proxy trace gateway/agentgateway-proxy -n agentgateway-system \\
    --raw --port 8080 -- http://prompt-enrichment.internal/chat \\
    -X POST -H "Content-Type: application/json" \\
    -d '{"model":"gpt-4","messages":[{"role":"system","content":"You are a pirate."},{"role":"user","content":"What is your return policy?"}]}'

See manifests/02-prompt-enrichment-policy.yaml for the exact prepend/append
configured, and PLAN.md (private repo) for the full decision log.
EOF
