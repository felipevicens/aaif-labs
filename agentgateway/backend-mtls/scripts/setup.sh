#!/usr/bin/env bash
# End-to-end setup for the backend-mtls lab (F4 "mTLS Between Your
# Gateway and a GPU Backend"). Stands up the gateway, httpbun as the
# echo backend, and an nginx TLS frontend in front of it that requires a
# client certificate. Generates a throwaway self-signed CA plus a
# server cert (for nginx) and a client cert (for agentgateway) fresh on
# every run — nothing here is a committed, reusable credential.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
MANIFESTS_DIR="$LAB_DIR/manifests"
CERTS_DIR="$LAB_DIR/.certs"

CLUSTER_NAME="agentgateway-backend-mtls"
GWAPI_VERSION="1.6.0"
AGW_VERSION="1.5.0"

if [ "$#" -gt 0 ]; then
  echo "Unknown argument: $1" >&2
  echo "Usage: $0" >&2
  exit 1
fi

echo "==> Creating kind cluster ($CLUSTER_NAME, node v1.34.0 pinned in kind-config.yaml)"
kind create cluster --name "$CLUSTER_NAME" --config "$LAB_DIR/kind-config.yaml"

echo "==> Installing Gateway API $GWAPI_VERSION (experimental channel, needed for BackendTLSPolicy)"
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

echo "==> Generating a throwaway CA, server cert (nginx), and client cert (agentgateway)"
mkdir -p "$CERTS_DIR"
CN="mtls-backend.internal"

openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -keyout "$CERTS_DIR/ca.key" -out "$CERTS_DIR/ca.crt" \
  -subj "/CN=backend-mtls-ca"

openssl req -newkey rsa:2048 -nodes \
  -keyout "$CERTS_DIR/server.key" -out "$CERTS_DIR/server.csr" \
  -subj "/CN=$CN"
openssl x509 -req -in "$CERTS_DIR/server.csr" \
  -CA "$CERTS_DIR/ca.crt" -CAkey "$CERTS_DIR/ca.key" -CAcreateserial \
  -out "$CERTS_DIR/server.crt" -days 825 \
  -extfile <(printf "subjectAltName=DNS:%s" "$CN")

openssl req -newkey rsa:2048 -nodes \
  -keyout "$CERTS_DIR/client.key" -out "$CERTS_DIR/client.csr" \
  -subj "/CN=agentgateway-client"
# Without -extfile, `openssl x509 -req` emits a bare X.509v1 certificate
# (no extensions at all). agentgateway's rustls-based TLS stack rejects
# a v1 peer certificate outright — the policy gets silently NACKed with
# "invalid peer certificate: UnsupportedCertVersion" and every request
# to the backend then 400s with no hint the client cert was the problem.
# Any extension bumps the cert to v3; these are also the correct ones
# for a TLS client identity.
openssl x509 -req -in "$CERTS_DIR/client.csr" \
  -CA "$CERTS_DIR/ca.crt" -CAkey "$CERTS_DIR/ca.key" -CAcreateserial \
  -out "$CERTS_DIR/client.crt" -days 825 \
  -extfile <(printf "basicConstraints=CA:FALSE\nkeyUsage=digitalSignature,keyEncipherment\nextendedKeyUsage=clientAuth")

kubectl create namespace backend-mtls --dry-run=client -o yaml | kubectl apply -f -

kubectl create configmap backend-ca -n backend-mtls \
  --from-file=ca.crt="$CERTS_DIR/ca.crt" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret tls tls-backend-server-tls -n backend-mtls \
  --cert="$CERTS_DIR/server.crt" --key="$CERTS_DIR/server.key" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret tls gateway-client-tls -n backend-mtls \
  --cert="$CERTS_DIR/client.crt" --key="$CERTS_DIR/client.key" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "==> Applying 01-namespace-and-backends.yaml, 02-backend-tls-policy.yaml, 03-mtls-policy.yaml"
kubectl apply -f "$MANIFESTS_DIR/01-namespace-and-backends.yaml"
kubectl wait --for=condition=Programmed gateway/agentgateway-proxy -n agentgateway-system --timeout=120s
kubectl wait --for=condition=Available deployment/agentgateway-proxy -n agentgateway-system --timeout=180s
kubectl wait --for=condition=Available deployment/httpbun -n backend-mtls --timeout=180s
kubectl wait --for=condition=Available deployment/tls-backend -n backend-mtls --timeout=180s
kubectl apply -f "$MANIFESTS_DIR/02-backend-tls-policy.yaml"
kubectl apply -f "$MANIFESTS_DIR/03-mtls-policy.yaml"

cat <<EOF

==> Done. Port-forward the gateway:
  kubectl port-forward -n agentgateway-system svc/agentgateway-proxy 8080:8080

  # Scenario 1: full mTLS, should succeed (200) with X-Ssl-Client-Verify: SUCCESS
  curl -s http://localhost:8080/mtls -H "Host: mtls-backend.internal"

  # Scenario 2: remove the client cert policy, should now fail (400 —
  # nginx completes the TLS handshake either way with ssl_verify_client
  # on, then rejects at the HTTP layer once it sees no client cert)
  kubectl delete agentgatewaypolicy tls-backend-mtls -n backend-mtls
  curl -sS -o /dev/null -w "%{http_code}\n" http://localhost:8080/mtls -H "Host: mtls-backend.internal"
  kubectl apply -f "$MANIFESTS_DIR/03-mtls-policy.yaml"   # restore for scenario 3

  # Scenario 3: point the CA ConfigMap at the wrong CA, should now fail
  # (503 — agentgateway itself can't validate nginx's server certificate,
  # a connection-level failure rather than an HTTP-level one)
  openssl req -x509 -newkey rsa:2048 -nodes -days 1 -keyout /tmp/wrong-ca.key -out /tmp/wrong-ca.crt -subj "/CN=wrong-ca"
  kubectl create configmap backend-ca -n backend-mtls --from-file=ca.crt=/tmp/wrong-ca.crt --dry-run=client -o yaml | kubectl apply -f -
  curl -sS -o /dev/null -w "%{http_code}\n" http://localhost:8080/mtls -H "Host: mtls-backend.internal"
  kubectl create configmap backend-ca -n backend-mtls --from-file=ca.crt="$CERTS_DIR/ca.crt" --dry-run=client -o yaml | kubectl apply -f -   # restore

See manifests/00-cluster-and-install.md for the full walkthrough.
EOF
