#!/usr/bin/env bash
# End-to-end setup for the backend-authn lab (F3 "Three Ways to
# Authenticate to Your Backend"). Stands up the gateway, httpbun as a
# shared echo backend, and two live scenarios: jwtSign (Scenario 1, no
# external IdP) and oauthTokenExchange (Scenario 2, backed by a Keycloak
# instance configured via a one-shot Job). See manifests/00-cluster-and-install.md
# for the full scenario commands. A third mechanism, crossAppAccess
# (ID-JAG), is discussed in the post but not built here — see PLAN.md's
# F3 research section for why.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
MANIFESTS_DIR="$LAB_DIR/manifests"
KEYS_DIR="$LAB_DIR/.keys"

CLUSTER_NAME="agentgateway-backend-authn"
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

echo "==> Applying 01-gateway-and-httpbun.yaml"
kubectl apply -f "$MANIFESTS_DIR/01-gateway-and-httpbun.yaml"
kubectl wait --for=condition=Programmed gateway/agentgateway-proxy -n agentgateway-system --timeout=120s
kubectl wait --for=condition=Available deployment/agentgateway-proxy -n agentgateway-system --timeout=180s
kubectl wait --for=condition=Available deployment/httpbun -n backend-authn --timeout=180s

echo "==> Generating a throwaway EC (P-256) signing key for jwtSign"
mkdir -p "$KEYS_DIR"
# jwtSign requires PKCS8, not the SEC1/traditional format `ecparam` emits
# on its own; without the pkcs8 step agentgateway rejects the Secret with
# "failed to load EC signing key".
openssl ecparam -genkey -name prime256v1 -noout -out "$KEYS_DIR/jwt-sign-private-sec1.pem"
openssl pkcs8 -topk8 -nocrypt \
  -in "$KEYS_DIR/jwt-sign-private-sec1.pem" -out "$KEYS_DIR/jwt-sign-private.pem"
kubectl create secret generic jwt-signing-key -n backend-authn \
  --from-file=signingKey="$KEYS_DIR/jwt-sign-private.pem" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "==> Applying 02-jwtsign-policy.yaml"
kubectl apply -f "$MANIFESTS_DIR/02-jwtsign-policy.yaml"

echo "==> Applying 03-keycloak.yaml"
kubectl apply -f "$MANIFESTS_DIR/03-keycloak.yaml"
kubectl wait --for=condition=Available deployment/keycloak -n backend-authn --timeout=180s

echo "==> Creating throwaway Keycloak client secrets for this run"
TARGET_CLIENT_SECRET="$(openssl rand -hex 24)"
REQUESTER_CLIENT_SECRET="$(openssl rand -hex 24)"
INBOUND_CLIENT_SECRET="$(openssl rand -hex 24)"
kubectl create secret generic target-client-secret -n backend-authn \
  --from-literal=secret="$TARGET_CLIENT_SECRET" --dry-run=client -o yaml | kubectl apply -f -
kubectl create secret generic oauth-client-secret -n backend-authn \
  --from-literal=secret="$REQUESTER_CLIENT_SECRET" --dry-run=client -o yaml | kubectl apply -f -
kubectl create secret generic inbound-client-secret -n backend-authn \
  --from-literal=secret="$INBOUND_CLIENT_SECRET" --dry-run=client -o yaml | kubectl apply -f -
echo "$INBOUND_CLIENT_SECRET" > "$KEYS_DIR/inbound-client-secret.txt"

echo "==> Applying 04-keycloak-setup-job.yaml (configures backend-oauth realm via kcadm.sh)"
kubectl delete job keycloak-setup -n backend-authn --ignore-not-found
kubectl apply -f "$MANIFESTS_DIR/04-keycloak-setup-job.yaml"
kubectl wait --for=condition=Complete job/keycloak-setup -n backend-authn --timeout=180s

echo "==> Applying 05-inbound-jwt-auth-policy.yaml, 06-keycloak-token-endpoint-backend.yaml, 07-token-exchange-policy.yaml"
kubectl apply -f "$MANIFESTS_DIR/05-inbound-jwt-auth-policy.yaml"
kubectl apply -f "$MANIFESTS_DIR/06-keycloak-token-endpoint-backend.yaml"
kubectl apply -f "$MANIFESTS_DIR/07-token-exchange-policy.yaml"

cat <<EOF

==> Done. Port-forward the gateway and Keycloak:
  kubectl port-forward -n agentgateway-system svc/agentgateway-proxy 8080:8080
  kubectl port-forward -n backend-authn svc/keycloak 8081:8080

  # Scenario 1: jwtSign, no token needed from the client at all
  curl -s http://localhost:8080/jwtsign

  # Scenario 2: oauthTokenExchange, needs an inbound token first
  INBOUND_TOKEN=\$(curl -s http://localhost:8081/realms/backend-oauth/protocol/openid-connect/token \\
    -u inbound-client:\$(cat "$KEYS_DIR/inbound-client-secret.txt") \\
    -d grant_type=password -d username=testuser -d password=testpass | python3 -c 'import json,sys;print(json.load(sys.stdin)["access_token"])')
  curl -s http://localhost:8080/exchange -H "Authorization: Bearer \$INBOUND_TOKEN"

See manifests/00-cluster-and-install.md for the full scenario commands.
EOF
