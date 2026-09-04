# Cluster + install commands

Exact commands used to stand up the environment this post's manifests were
tested against. Ephemeral `kind` cluster, torn down after testing —
nothing here touched shared infrastructure.

```sh
kind create cluster --name agentgateway-extauth --config kind-config.yaml

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
kubectl apply -f manifests/01-gateway-and-backend.yaml
kubectl apply -f manifests/02-ext-authz-service.yaml
kubectl apply -f manifests/03-extauth-policy.yaml
```

Reach the gateway with a port-forward:

```sh
kubectl port-forward -n agentgateway-system svc/agentgateway-proxy 8080:8080
```

```sh
# Scenario 1: no x-ext-authz header at all — denied
curl -s http://localhost:8080/llm \
  -H 'Content-Type: application/json' \
  -d '{"model":"gpt-4","messages":[{"role":"user","content":"hi"}]}'

# Scenario 2: x-ext-authz: allow — the request actually reaches httpbun
curl -s http://localhost:8080/llm \
  -H 'Content-Type: application/json' -H 'x-ext-authz: allow' \
  -d '{"model":"gpt-4","messages":[{"role":"user","content":"hi"}]}'

# Scenario 3: x-ext-authz set to anything other than "allow" — still denied
curl -s http://localhost:8080/llm \
  -H 'Content-Type: application/json' -H 'x-ext-authz: deny' \
  -d '{"model":"gpt-4","messages":[{"role":"user","content":"hi"}]}'
```

Cleanup:

```sh
kind delete cluster --name agentgateway-extauth
```
