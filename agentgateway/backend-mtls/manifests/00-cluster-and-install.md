# Cluster, install, and all three scenarios

Everything below is what `scripts/setup.sh` runs, spelled out so you can
run it by hand or adapt it to a real cluster.

## 1. Cluster and control plane

```sh
kind create cluster --name agentgateway-backend-mtls --config kind-config.yaml

kubectl apply --server-side -f \
  https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.6.0/experimental-install.yaml

helm upgrade -i --create-namespace --namespace agentgateway-system \
  --version v1.5.0 agentgateway-crds oci://cr.agentgateway.dev/charts/agentgateway-crds

helm upgrade -i -n agentgateway-system agentgateway oci://cr.agentgateway.dev/charts/agentgateway \
  --version v1.5.0 \
  --set controller.extraEnv.KGW_ENABLE_GATEWAY_API_EXPERIMENTAL_FEATURES=true
```

The Gateway API's experimental channel is what ships `BackendTLSPolicy` —
it's not in the standard channel.

## 2. A throwaway CA, server cert, and client cert

```sh
CN="mtls-backend.internal"

openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -keyout ca.key -out ca.crt -subj "/CN=backend-mtls-ca"

openssl req -newkey rsa:2048 -nodes -keyout server.key -out server.csr -subj "/CN=$CN"
openssl x509 -req -in server.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
  -out server.crt -days 825 -extfile <(printf "subjectAltName=DNS:%s" "$CN")

openssl req -newkey rsa:2048 -nodes -keyout client.key -out client.csr -subj "/CN=agentgateway-client"
openssl x509 -req -in client.csr -CA ca.crt -CAkey ca.key -CAcreateserial -out client.crt -days 825 \
  -extfile <(printf "basicConstraints=CA:FALSE\nkeyUsage=digitalSignature,keyEncipherment\nextendedKeyUsage=clientAuth")
```

The server cert is what nginx presents; its SAN has to match the
`hostname` on the `BackendTLSPolicy` below. The client cert is what
agentgateway presents back to nginx — that's the mutual half. The
`-extfile` on the client cert isn't optional: without it, `openssl x509
-req` emits a bare X.509v1 certificate, and agentgateway's rustls-based
TLS stack rejects a v1 peer certificate with a silent policy NACK
(`invalid peer certificate: UnsupportedCertVersion`) — see the Gotchas
section in the post.

```sh
kubectl create namespace backend-mtls

kubectl create configmap backend-ca -n backend-mtls --from-file=ca.crt=ca.crt

kubectl create secret tls tls-backend-server-tls -n backend-mtls \
  --cert=server.crt --key=server.key

kubectl create secret tls gateway-client-tls -n backend-mtls \
  --cert=client.crt --key=client.key
```

## 3. The backends and the policies

```sh
kubectl apply -f 01-namespace-and-backends.yaml
kubectl apply -f 02-backend-tls-policy.yaml
kubectl apply -f 03-mtls-policy.yaml
```

`01-namespace-and-backends.yaml` deploys httpbun as a plain-HTTP echo
backend, and an nginx Deployment in front of it that terminates HTTPS on
`:443` and requires a client certificate (`ssl_verify_client on`). The
`tls-backend` Service is what agentgateway actually connects to; nginx
proxies onward to httpbun and forwards nginx's own TLS verdict
(`$ssl_client_verify`, `$ssl_client_s_dn`) as headers, so httpbun's
`/headers` response tells you exactly what happened on the wire.

`02-backend-tls-policy.yaml` is the standard Gateway API
`BackendTLSPolicy` — verifies nginx's server certificate against the CA
ConfigMap and the expected hostname. One-way only.

`03-mtls-policy.yaml` is `AgentgatewayPolicy.spec.backend.tls` —
`mtlsCertificateRef` supplies the client cert agentgateway presents
during the handshake, `sni` pins the SNI value. This is the field that
actually makes the connection mutual. It also repeats `caCertificateRefs`
even though `02-backend-tls-policy.yaml` already sets one: confirmed live
that once an `AgentgatewayPolicy` carrying `backend.tls` targets the same
object, it replaces the `BackendTLSPolicy`'s server-cert verification for
that target rather than layering on top of it — omit it here and
agentgateway falls back to the system trust store and rejects nginx's
self-signed cert as `UnknownIssuer`.

## 4. Scenario 1 — full mTLS (happy path)

```sh
kubectl port-forward -n agentgateway-system svc/agentgateway-proxy 8080:8080 &

curl -s http://localhost:8080/mtls -H "Host: mtls-backend.internal"
```

Expect a 200 with `"X-Ssl-Client-Verify": "SUCCESS"` and an
`"X-Ssl-Client-Dn": "CN=agentgateway-client"` header in the echoed JSON —
proof nginx actually validated a client certificate, not just that the
request went through.

## 5. Scenario 2 — missing client cert (failure path)

```sh
kubectl delete agentgatewaypolicy tls-backend-mtls -n backend-mtls

curl -sS -o /dev/null -w "%{http_code}\n" http://localhost:8080/mtls -H "Host: mtls-backend.internal"
```

`BackendTLSPolicy` alone still gets agentgateway an encrypted,
server-verified connection — but with no `mtlsCertificateRef`,
agentgateway presents no client certificate. Confirmed live: nginx's
`ssl_verify_client on` does *not* fail the TLS handshake itself over
this — it completes the handshake, then rejects at the HTTP layer with
a 400 ("No required SSL certificate was sent") once it sees no client
cert came through. So the client-visible symptom is a plain 400, not a
connection-level error. Restore with:

```sh
kubectl apply -f 03-mtls-policy.yaml
```

## 6. Scenario 3 — wrong CA (failure path)

```sh
openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
  -keyout wrong-ca.key -out wrong-ca.crt -subj "/CN=wrong-ca"

kubectl create configmap backend-ca -n backend-mtls \
  --from-file=ca.crt=wrong-ca.crt --dry-run=client -o yaml | kubectl apply -f -

curl -sS -o /dev/null -w "%{http_code}\n" http://localhost:8080/mtls -H "Host: mtls-backend.internal"
```

Now agentgateway can't validate nginx's server certificate at all
(`caCertificateRefs` points at a CA that never issued it) — confirmed
live as a 503 with `error="upstream call failed: Connect: invalid peer
certificate: UnknownIssuer"` in agentgateway's own logs. Unlike Scenario
2, this failure never reaches nginx at all: the TLS handshake fails on
agentgateway's own side before any HTTP request is sent, so the symptom
is a connection-level 503, not an HTTP-level 400. Restore with:

```sh
kubectl create configmap backend-ca -n backend-mtls \
  --from-file=ca.crt=ca.crt --dry-run=client -o yaml | kubectl apply -f -
```

## 7. Tear down

```sh
kind delete cluster --name agentgateway-backend-mtls
```
