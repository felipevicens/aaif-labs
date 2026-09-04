#!/usr/bin/env bash
# End-to-end setup for the attribution lab (C3 "Invoice-Grade
# Attribution"). Fully keyless: no cloud credentials anywhere, JWT auth
# uses a throwaway self-signed key. See manifests/00-cluster-and-install.md
# for what each step proves.
#
# Usage:
#   ./setup.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
MANIFESTS_DIR="$LAB_DIR/manifests"

CLUSTER_NAME="agentgateway-attribution"
GWAPI_VERSION="1.6.0"
AGW_VERSION="1.5.0"

if [ "$#" -gt 0 ]; then
  echo "Unknown argument: $1" >&2
  echo "Usage: $0" >&2
  exit 1
fi

echo "==> Creating kind cluster ($CLUSTER_NAME, node v1.34.0 pinned in kind-config.yaml)"
kind create cluster --name "$CLUSTER_NAME" --config "$LAB_DIR/kind-config.yaml"

echo "==> Installing Gateway API $GWAPI_VERSION (experimental channel: JWT auth needs it)"
kubectl apply --server-side -f \
  "https://github.com/kubernetes-sigs/gateway-api/releases/download/v${GWAPI_VERSION}/experimental-install.yaml"

echo "==> Installing agentgateway CRDs $AGW_VERSION"
helm upgrade -i --create-namespace --namespace agentgateway-system \
  --version "v${AGW_VERSION}" agentgateway-crds \
  oci://cr.agentgateway.dev/charts/agentgateway-crds

echo "==> Installing agentgateway control plane $AGW_VERSION (experimental Gateway API features on)"
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

echo "==> Applying 01-gateway-and-backend.yaml"
kubectl apply -f "$MANIFESTS_DIR/01-gateway-and-backend.yaml"
kubectl wait --for=condition=Available deployment/attribution-mock-backend -n agentgateway-system --timeout=120s
kubectl wait --for=condition=Programmed gateway/agentgateway-proxy -n agentgateway-system --timeout=120s

echo "==> Applying jwt-auth policy (throwaway demo key, generated on first run)"
python3 "$MANIFESTS_DIR/jwt/mint-demo-jwt.py" --policy | kubectl apply -f -

cat <<'EOF'

==> Done. Reach the gateway with:
  kubectl port-forward -n agentgateway-system svc/agentgateway-proxy 8080:8080

  # Mint a token signed by the same throwaway key the policy just trusted
  export JWT=$(python3 manifests/jwt/mint-demo-jwt.py)

  # Send a request carrying both the JWT and a plain x-team header, then
  # check what agentgateway actually put on the outbound request body.
  curl -s -X POST http://localhost:8080/llm -H 'Content-Type: application/json' \
    -H "Authorization: Bearer $JWT" -H 'x-team: growth' \
    -d '{"model":"demo-model","messages":[{"role":"user","content":"hi"}]}' \
    | jq .received.metadata
  # Expect: {"user": "alice", "team": "growth"} -- jwt.sub and the x-team
  # header, merged server-side into the request body agentgateway forwards,
  # not anything the client sent itself.
EOF
