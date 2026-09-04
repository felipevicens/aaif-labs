#!/usr/bin/env bash
# End-to-end setup for the jwt-rbac lab (F1 "Who Can Call Which Model:
# JWT + CEL RBAC End to End"). Stands up the gateway, two named model
# routes, mints a throwaway RSA keypair for this run, and applies both
# per-route JWT-authentication + CEL-authorization policies with that
# keypair's public half inlined. See manifests/00-cluster-and-install.md
# for the full scenario commands (minting tokens per role, calling each
# model, the failure paths).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
MANIFESTS_DIR="$LAB_DIR/manifests"
KEYS_DIR="$LAB_DIR/.keys"

CLUSTER_NAME="agentgateway-jwt-rbac"
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

echo "==> Applying 01-gateway-and-mock-backends.yaml"
kubectl apply -f "$MANIFESTS_DIR/01-gateway-and-mock-backends.yaml"
kubectl wait --for=condition=Programmed gateway/agentgateway-proxy -n agentgateway-system --timeout=120s
kubectl wait --for=condition=Available deployment/agentgateway-proxy -n agentgateway-system --timeout=180s
kubectl wait --for=condition=Available deployment/mock-llm -n jwt-rbac --timeout=180s

echo "==> Generating a throwaway RSA keypair for this run"
mkdir -p "$KEYS_DIR"
JWKS_INLINE="$(python3 "$SCRIPT_DIR/gen_keys.py" "$KEYS_DIR")"
export JWKS_INLINE

echo "==> Applying 02-jwt-auth-policy-cheap.yaml and 03-jwt-auth-policy-expensive.yaml"
envsubst '${JWKS_INLINE}' < "$MANIFESTS_DIR/02-jwt-auth-policy-cheap.yaml" | kubectl apply -f -
envsubst '${JWKS_INLINE}' < "$MANIFESTS_DIR/03-jwt-auth-policy-expensive.yaml" | kubectl apply -f -

cat <<EOF

==> Done. Private key for minting tokens: $KEYS_DIR/private.pem

Mint a token and call a model:
  kubectl port-forward -n agentgateway-system svc/agentgateway-proxy 8080:8080 &
  TOKEN=\$(python3 "$SCRIPT_DIR/mint_token.py" "$KEYS_DIR/private.pem" engineer)
  curl -s http://localhost:8080/models/cheap-model/v1/chat/completions \\
    -H "Authorization: Bearer \$TOKEN" -H 'Content-Type: application/json' \\
    -d '{"model":"cheap-model","messages":[{"role":"user","content":"hi"}]}'

See manifests/00-cluster-and-install.md for the full scenario commands,
including every role/failure-path combination.
EOF
