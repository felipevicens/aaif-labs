#!/usr/bin/env bash
# End-to-end setup for the ingress-migration lab (I1 "Migrating From
# Ingress NGINX in an Afternoon"). httpbun mocks the backend, no provider
# credentials needed. Installs the real ingress2gateway binary
# (kgateway-dev fork, agentgateway emitter) and re-runs the exact
# conversion this lab's manifests/04 and manifests/05 were generated from,
# so you can see the tool's own INFO/WARN output for yourself before
# applying the already-converted manifests.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
MANIFESTS_DIR="$LAB_DIR/manifests"

CLUSTER_NAME="agentgateway-ingress-migration"
GWAPI_VERSION="1.6.0"
AGW_VERSION="1.5.0"
I2GW_VERSION="0.5.0"
I2GW_BIN="$LAB_DIR/ingress2gateway"

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

echo "==> Installing ingress2gateway $I2GW_VERSION (kgateway-dev fork, agentgateway emitter)"
GOBIN="$LAB_DIR" go install "github.com/kgateway-dev/ingress2gateway@v${I2GW_VERSION}"
mv "$LAB_DIR/ingress2gateway" "$I2GW_BIN" 2>/dev/null || true
"$I2GW_BIN" version

echo "==> Waiting for the agentgateway GatewayClass to be accepted"
for i in $(seq 1 60); do
  kubectl get gatewayclass/agentgateway >/dev/null 2>&1 && break
  sleep 2
done
kubectl wait --for=jsonpath='{.status.conditions[?(@.type=="Accepted")].status}'=True \
  gatewayclass/agentgateway --timeout=120s

echo "==> Applying 01-namespace-and-backend.yaml"
kubectl apply -f "$MANIFESTS_DIR/01-namespace-and-backend.yaml"
kubectl wait --for=condition=Programmed gateway/agentgateway-proxy -n agentgateway-system --timeout=120s
kubectl wait --for=condition=Available deployment/agentgateway-proxy -n agentgateway-system --timeout=180s
kubectl wait --for=condition=Available deployment/httpbun -n ingress-migration --timeout=180s

echo "==> Re-running the real conversion (informational only, output already committed in manifests/04 and 05)"
"$I2GW_BIN" print --providers=ingress-nginx --emitter=agentgateway \
  --input-file "$MANIFESTS_DIR/02-before-ingress-cors.yaml" >/dev/null
"$I2GW_BIN" print --providers=ingress-nginx --emitter=agentgateway \
  --input-file "$MANIFESTS_DIR/03-before-ingress-basic-auth.yaml" >/dev/null

echo "==> Applying 04-cors-migrated.yaml and 05-basic-auth-migrated.yaml"
kubectl apply -f "$MANIFESTS_DIR/04-cors-migrated.yaml"
kubectl apply -f "$MANIFESTS_DIR/05-basic-auth-migrated.yaml"

cat <<'EOF'

==> Done.

  kubectl port-forward -n agentgateway-system svc/agentgateway-proxy 8080:8080

  # Scenario 1: CORS preflight from the allowed origin
  curl -s -D - -o /dev/null -X OPTIONS http://localhost:8080/get \
    -H 'Host: cors.migrate.local' \
    -H 'Origin: https://app.allowed.example' \
    -H 'Access-Control-Request-Method: GET'

  # Scenario 1: CORS preflight from a different origin
  curl -s -D - -o /dev/null -X OPTIONS http://localhost:8080/get \
    -H 'Host: cors.migrate.local' \
    -H 'Origin: https://evil.example' \
    -H 'Access-Control-Request-Method: GET'

  # Scenario 2: basic auth, no credentials
  curl -s -o /dev/null -w '%{http_code}\n' http://localhost:8080/get \
    -H 'Host: secure.migrate.local'

  # Scenario 2: basic auth, correct credentials (aaif:letmein123)
  curl -s -o /dev/null -w '%{http_code}\n' http://localhost:8080/get \
    -H 'Host: secure.migrate.local' -u aaif:letmein123

  # Scenario 2: basic auth, wrong password
  curl -s -o /dev/null -w '%{http_code}\n' http://localhost:8080/get \
    -H 'Host: secure.migrate.local' -u aaif:wrongpassword
EOF
