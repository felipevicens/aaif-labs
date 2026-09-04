# Cluster + install commands

Exact commands used to stand up the environment this post's manifests are
tested against. Ephemeral `kind` cluster, torn down after testing. This post
is self-contained: it does not assume A1-A4's clusters are still around.

```sh
kind create cluster --name agentgateway-models-serve --config ../kind-config.yaml

export GWAPI_VERSION=1.6.0
kubectl apply --server-side -f \
  https://github.com/kubernetes-sigs/gateway-api/releases/download/v$GWAPI_VERSION/experimental-install.yaml

helm upgrade -i --create-namespace --namespace agentgateway-system \
  --version v1.5.0 agentgateway-crds oci://cr.agentgateway.dev/charts/agentgateway-crds

helm upgrade -i -n agentgateway-system agentgateway oci://cr.agentgateway.dev/charts/agentgateway \
  --version v1.5.0 --set agentgatewayModels.enabled=true

kubectl get gatewayclass   # expect agentgateway / ACCEPTED=True
```

Same `agentgatewayModels.enabled=true` flag A3 used: every scenario here
routes through `AgentgatewayModel`, still an experimental preview per
agentgateway's own docs, still needing the experimental Gateway API channel
like A1-A3 (A4 was the one post in this series that didn't need either).

No provider credentials needed anywhere in this lab: Ollama's own API key
is required by the OpenAI client library but ignored server-side, and
`AgentgatewayModel` doesn't add an `Authorization` header unless
`policies.auth` is configured. Keyless start to finish, same as every other
post in this series, just with a real model answering instead of a mock.

Apply order for the manifests in this folder:

1. `01-gateway-and-ollama.yaml` — the `Gateway`, and a real `ollama`
   `Deployment`/`Service`. The container pulls two tiny CPU-only models
   (`smollm2:135m`, `qwen2.5:0.5b`) at startup, so this step is slower than
   every other backend in this series: expect a few minutes, not seconds.

   ```sh
   kubectl wait --for=condition=available --timeout=300s deployment/ollama
   kubectl wait --for=condition=Programmed --timeout=120s gateway/agentgateway-proxy -n agentgateway-system

   # leave running in its own terminal
   kubectl port-forward -n agentgateway-system svc/agentgateway-proxy 8080:8080
   ```
2. `02-alias-real-provider-name.yaml` — Scenario A. An `AgentgatewayModel`
   named `gpt-4` (exact match on `metadata.name`), pointed at Ollama with a
   transformation that rewrites the client's requested `model` field to
   `smollm2:135m` before the request reaches Ollama.

   ```sh
   curl -s -X POST http://localhost:8080/v1/chat/completions \
     -H 'Content-Type: application/json' \
     -d '{"model":"gpt-4","messages":[{"role":"user","content":"Say hello in exactly three words."}]}'
   ```

   The response's own `model` field reads `smollm2:135m`, not `gpt-4`,
   because Ollama echoes back whatever tag it actually ran. Real,
   non-mocked completion text, generated on CPU by a 135M-parameter model.

   Request a model that was never created, to confirm this behaves exactly
   like a real provider:

   ```sh
   curl -s -X POST http://localhost:8080/v1/chat/completions \
     -H 'Content-Type: application/json' \
     -d '{"model":"gpt-5","messages":[]}'
   # {"error":{"message":"Model not found","type":"invalid_request_error","code":"model_not_found"}}
   ```
3. `03-weighted-virtual-model.yaml` — Scenario B. Two `Internal` models
   (`internal-smollm2`, `internal-qwen`), each aliasing a different real
   local model, and a public virtual model, `gpt-4-turbo`, that splits
   traffic across them 70/30 with `virtualModel.weighted`.

   ```sh
   for i in $(seq 20); do
     curl -s -X POST http://localhost:8080/v1/chat/completions \
       -H 'Content-Type: application/json' \
       -d '{"model":"gpt-4-turbo","messages":[{"role":"user","content":"hi"}]}' \
       | grep -o '"model":"[^"]*"'
   done | sort | uniq -c
   ```

   Two real runs, twenty requests each: 16/4 and 17/3 between
   `smollm2:135m` and `qwen2.5:0.5b`. Both land closer to 80/20 than the
   configured 70/30, expected noise from a small sample, not a bug; the
   docs' own weighted example makes the same point, that the split
   converges toward the configured ratio only as the sample grows.

## Cleanup

```sh
kind delete cluster --name agentgateway-models-serve
```
