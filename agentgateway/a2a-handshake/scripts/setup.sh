#!/usr/bin/env bash
# End-to-end setup for the A2A lab (E1 "Two Agents, One Handshake: A2A in
# Practice"). Stands up the gateway and both A2A agents, but does NOT
# apply 04-rate-limit-policy.yaml — that goes on by hand, so the
# before/after on agent-b is visible while agent-a stays a control. See
# manifests/00-cluster-and-install.md.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
MANIFESTS_DIR="$LAB_DIR/manifests"

CLUSTER_NAME="agentgateway-a2a-handshake"
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

echo "==> Waiting for the agentgateway GatewayClass to exist"
for i in $(seq 1 60); do
  kubectl get gatewayclass/agentgateway >/dev/null 2>&1 && break
  sleep 2
done

echo "==> Waiting for the agentgateway GatewayClass to be accepted"
kubectl wait --for=jsonpath='{.status.conditions[?(@.type=="Accepted")].status}'=True \
  gatewayclass/agentgateway --timeout=120s

echo "==> Applying 02-agent-a.yaml (creates the a2a-handshake namespace)"
kubectl apply -f "$MANIFESTS_DIR/02-agent-a.yaml"

echo "==> Applying 03-agent-b.yaml"
kubectl apply -f "$MANIFESTS_DIR/03-agent-b.yaml"

echo "==> Waiting for both agents to be Available"
kubectl wait --for=condition=Available deployment/agent-a -n a2a-handshake --timeout=180s
kubectl wait --for=condition=Available deployment/agent-b -n a2a-handshake --timeout=180s

echo "==> Applying 01-gateway-and-backends.yaml"
kubectl apply -f "$MANIFESTS_DIR/01-gateway-and-backends.yaml"
kubectl wait --for=condition=Programmed gateway/agentgateway-proxy -n agentgateway-system --timeout=120s
kubectl wait --for=condition=Available deployment/agentgateway-proxy -n agentgateway-system --timeout=120s

cat <<'EOF'

==> Done. Reach the gateway with:
  kubectl port-forward -n agentgateway-system svc/agentgateway-proxy 8080:8080

  # Scenario 1: routing + agent-card rewrite
  python3 scripts/a2a_client.py card http://localhost:8080/a2a/agent-a
  python3 scripts/a2a_client.py card http://localhost:8080/a2a/agent-b

  # Scenario 2: task call, non-streaming
  python3 scripts/a2a_client.py send http://localhost:8080/a2a/agent-a "hi there"
  python3 scripts/a2a_client.py send http://localhost:8080/a2a/agent-b "hi there"

  # Scenario 3: task call, streaming (SSE)
  python3 scripts/a2a_client.py stream http://localhost:8080/a2a/agent-a "hi there"

  # Scenario 4: stack a generic traffic policy on agent-b only
  kubectl apply -f manifests/04-rate-limit-policy.yaml
  ./scripts/fire_requests.sh 10
EOF
