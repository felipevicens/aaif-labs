# Cluster + install commands

Exact commands used to stand up the environment this post's manifests are
tested against. Ephemeral `kind` cluster, torn down after testing. This
post is self-contained: it does not assume any earlier lab's cluster is
still around.

```sh
kind create cluster --name agentgateway-cost-tracking --config ../kind-config.yaml

export GWAPI_VERSION=1.6.0
kubectl apply --server-side -f \
  https://github.com/kubernetes-sigs/gateway-api/releases/download/v$GWAPI_VERSION/standard-install.yaml

helm upgrade -i --create-namespace --namespace agentgateway-system \
  --version v1.5.0 agentgateway-crds oci://cr.agentgateway.dev/charts/agentgateway-crds

helm upgrade -i -n agentgateway-system agentgateway oci://cr.agentgateway.dev/charts/agentgateway \
  --version v1.5.0

kubectl get gatewayclass   # expect agentgateway / ACCEPTED=True
```

`AgentgatewayParameters` and its `modelCatalog` field are on
`agentgateway.dev/v1alpha1`, the same alpha channel the CRD chart already
installs — no extra CRDs beyond what every other lab in this series
already applies.

No provider credentials needed anywhere in this lab. The only backend is a
lab-owned mock server that echoes back whatever model name it was asked
for, with a fixed, known token count.

Apply order for the manifests in this folder:

1. `01-gateway-and-catalog.yaml` — the `Gateway` (wired to a Gateway-level
   `AgentgatewayParameters` via `infrastructure.parametersRef`), the
   `AgentgatewayParameters` itself, the `ConfigMap` carrying the model cost
   catalog (real OpenAI list prices for `gpt-4o-mini` and `gpt-4o`), the
   mock backend, and three `AgentgatewayBackend`/`HTTPRoute` pairs: one
   priced cheap, one priced expensive, one for a model the catalog has
   never heard of.

   ```sh
   kubectl wait --for=condition=Available deployment/cost-mock-backend -n default --timeout=120s
   kubectl wait --for=condition=Programmed gateway/agentgateway-proxy -n agentgateway-system --timeout=120s

   # leave running in its own terminal
   kubectl port-forward -n agentgateway-system svc/agentgateway-proxy 8080:8080
   ```
2. `02-cost-access-log-policy.yaml` — an `AgentgatewayPolicy` targeting the
   `Gateway`, adding `llm.cost.*` and `llm.costRates.*` as CEL-derived
   fields on every access-log line.

   ```sh
   # Scenario A: cheap model, 1000/500 tokens
   curl -s -o /dev/null -X POST http://localhost:8080/llm/cheap-model \
     -H 'Content-Type: application/json' \
     -d '{"model":"gpt-4o-mini","messages":[{"role":"user","content":"hello"}]}'

   # Scenario B: pricey model, same 1000/500 tokens
   curl -s -o /dev/null -X POST http://localhost:8080/llm/pricey-model \
     -H 'Content-Type: application/json' \
     -d '{"model":"gpt-4o","messages":[{"role":"user","content":"hello"}]}'

   # Gotcha: a model the catalog has never priced
   curl -s -o /dev/null -X POST http://localhost:8080/llm/unpriced-model \
     -H 'Content-Type: application/json' \
     -d '{"model":"shadow-model-v1","messages":[{"role":"user","content":"hello"}]}'

   # read what the access log actually recorded for each
   kubectl logs -n agentgateway-system deployment/agentgateway-proxy --tail=50
   ```

   Also scrapes the proxy's own `/metrics` endpoint directly, no
   Prometheus install needed for this lab:

   ```sh
   kubectl port-forward -n agentgateway-system deployment/agentgateway-proxy 15020:15020 &
   curl -s http://localhost:15020/metrics | grep agentgateway_gen_ai_client_token_usage
   ```

   See the post for the actual captured access-log lines, dollar figures,
   and what happened to `llm.cost` for the unpriced model.

## Cleanup

```sh
kind delete cluster --name agentgateway-cost-tracking
```
