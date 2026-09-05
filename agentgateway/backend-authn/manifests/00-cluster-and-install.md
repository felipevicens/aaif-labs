# Cluster + install commands

Exact commands used to stand up the environment this post's manifests were
tested against. Ephemeral `kind` cluster, torn down after testing —
nothing here touched shared infrastructure.

```sh
kind create cluster --name agentgateway-backend-authn --config kind-config.yaml

kubectl apply --server-side -f \
  https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.6.0/experimental-install.yaml

helm upgrade -i --create-namespace -n agentgateway-system \
  --version 1.5.0 agentgateway-crds \
  oci://cr.agentgateway.dev/charts/agentgateway-crds

helm upgrade -i -n agentgateway-system agentgateway \
  oci://cr.agentgateway.dev/charts/agentgateway \
  --version 1.5.0 \
  --set controller.extraEnv.KGW_ENABLE_GATEWAY_API_EXPERIMENTAL_FEATURES=true

kubectl get gatewayclass   # expect agentgateway / ACCEPTED=True
```

Apply order:

```sh
kubectl apply -f manifests/01-gateway-and-httpbun.yaml

# Scenario 1 (jwtSign): a throwaway EC (P-256) signing key, never committed.
# jwtSign requires PKCS8 — the SEC1/traditional format `ecparam` emits on
# its own fails with "failed to load EC signing key".
openssl ecparam -genkey -name prime256v1 -noout -out .keys/jwt-sign-private-sec1.pem
openssl pkcs8 -topk8 -nocrypt \
  -in .keys/jwt-sign-private-sec1.pem -out .keys/jwt-sign-private.pem
kubectl create secret generic jwt-signing-key -n backend-authn \
  --from-file=signingKey=.keys/jwt-sign-private.pem
kubectl apply -f manifests/02-jwtsign-policy.yaml

# Scenario 2 (oauthTokenExchange): Keycloak plus three throwaway client secrets
kubectl apply -f manifests/03-keycloak.yaml
kubectl create secret generic target-client-secret -n backend-authn --from-literal=secret="$(openssl rand -hex 24)"
kubectl create secret generic oauth-client-secret -n backend-authn --from-literal=secret="$(openssl rand -hex 24)"
kubectl create secret generic inbound-client-secret -n backend-authn --from-literal=secret="$(openssl rand -hex 24)"
kubectl apply -f manifests/04-keycloak-setup-job.yaml   # configures backend-oauth realm via kcadm.sh
kubectl apply -f manifests/05-inbound-jwt-auth-policy.yaml
kubectl apply -f manifests/06-keycloak-token-endpoint-backend.yaml
kubectl apply -f manifests/07-token-exchange-policy.yaml
```

Reach the gateway and Keycloak with two port-forwards:

```sh
kubectl port-forward -n agentgateway-system svc/agentgateway-proxy 8080:8080
kubectl port-forward -n backend-authn svc/keycloak 8081:8080
```

```sh
# Scenario 1: jwtSign. No token from the client at all: agentgateway
# mints and attaches one itself before forwarding to httpbun.
curl -s http://localhost:8080/jwtsign
```

```sh
# Scenario 2: oauthTokenExchange. First get an inbound token from
# Keycloak as inbound-client, then call the gateway with it.
INBOUND_SECRET=$(cat .keys/inbound-client-secret.txt)
INBOUND_TOKEN=$(curl -s http://localhost:8081/realms/backend-oauth/protocol/openid-connect/token \
  -u inbound-client:"$INBOUND_SECRET" \
  -d grant_type=password -d username=testuser -d password=testpass \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["access_token"])')

curl -s http://localhost:8080/exchange -H "Authorization: Bearer $INBOUND_TOKEN"
```

```sh
# Scenario 3: same route as Scenario 2, no token at all. Rejected by the
# jwtAuthentication policy before oauthTokenExchange ever runs.
curl -s -o /dev/null -w '%{http_code}\n' http://localhost:8080/exchange
```

Cleanup:

```sh
kind delete cluster --name agentgateway-backend-authn
rm -rf .keys
```
