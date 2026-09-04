# Cluster + install commands

Exact commands used to stand up the environment this post's manifests are
tested against. Ephemeral `kind` cluster, torn down after testing. This post
is self-contained: it does not assume A1's or A2's clusters are still around.

```sh
kind create cluster --name agentgateway-content-routing --config ../kind-config.yaml

export GWAPI_VERSION=1.6.0
kubectl apply --server-side -f \
  https://github.com/kubernetes-sigs/gateway-api/releases/download/v$GWAPI_VERSION/experimental-install.yaml

helm upgrade -i --create-namespace --namespace agentgateway-system \
  --version v1.5.0 agentgateway-crds oci://cr.agentgateway.dev/charts/agentgateway-crds

helm upgrade -i -n agentgateway-system agentgateway oci://cr.agentgateway.dev/charts/agentgateway \
  --version v1.5.0 --set agentgatewayModels.enabled=true

kubectl get gatewayclass   # expect agentgateway / ACCEPTED=True
```

**`agentgatewayModels.enabled=true`** turns on support for the
`AgentgatewayModel` CRD, used in Scenarios B and C. Scenario A uses only the
stable `AgentgatewayBackend` + `HTTPRoute` API and doesn't need it, but
there's no reason to install twice.

No provider credentials needed anywhere in this lab: every scenario runs
against `httpbun`, keyless start to finish.

Apply order for the manifests in this folder:

1. `01-gateway-and-backends.yaml` — the `Gateway`, a shared `httpbun`
   `Deployment`/`Service` used by Scenarios A and B, and a second, separate
   one (`httpbun-broken`) used only by Scenario C, whose only job is
   answering `/status/500`. Two separate backends for the same reason as
   A2: agentgateway tracks eviction health per (Service, endpoint), so
   sharing a Service between a broken path and a healthy one evicts both.
   The `agentgateway-proxy` Service is a `LoadBalancer`; on `kind` it stays
   `EXTERNAL-IP: <pending>` (no LB provider — expected). Reach it with a
   port-forward, which every `curl` below assumes:

   ```sh
   # leave running in its own terminal
   kubectl port-forward -n agentgateway-system svc/agentgateway-proxy 8080:8080
   ```
2. `02-content-routing-stable.yaml` — Scenario A. Two `AgentgatewayBackend`s
   (`fast-tier`, `premium-tier`), an `HTTPRoute` at `/llm/routed` with two
   rules matching on an `x-tier` header, and an `AgentgatewayPolicy` that
   extracts a `tier` field from the JSON request body into that header in
   the `PreRouting` phase.

   ```sh
   curl -s -X POST http://localhost:8080/llm/routed \
     -H 'Content-Type: application/json' \
     -d '{"messages":[{"role":"user","content":"hi"}]}' | jq -r '.model'
   # fast-v1 (no tier field: falls through to the catch-all rule)

   curl -s -X POST http://localhost:8080/llm/routed \
     -H 'Content-Type: application/json' \
     -d '{"tier":"premium","messages":[{"role":"user","content":"hi"}]}' | jq -r '.model'
   # premium-v1
   ```
3. `03-conditional-model-experimental.yaml` — Scenario B, the same routing
   decision with the experimental `AgentgatewayModel.virtualModel.conditional`
   API. Send requests to model `routed-tier`:

   ```sh
   curl -s -X POST http://localhost:8080/v1/chat/completions \
     -H 'Content-Type: application/json' \
     -d '{"model":"routed-tier","messages":[{"role":"user","content":"hi"}]}' | jq -r '.model'
   # resolved-fast

   curl -s -X POST http://localhost:8080/v1/chat/completions \
     -H 'Content-Type: application/json' \
     -d '{"model":"routed-tier","tier":"premium","messages":[{"role":"user","content":"hi"}]}' | jq -r '.model'
   # resolved-premium
   ```
4. `04-conditional-ignores-health-gotcha.yaml` — Scenario C, the gotcha.
   Model `routed-broken` always selects the deliberately broken target.
   Send several requests in a row and see whether eviction ever kicks in.

   ```sh
   for i in 1 2 3 4 5; do
     curl -s -o /dev/null -w '%{http_code}\n' -X POST http://localhost:8080/v1/chat/completions \
       -H 'Content-Type: application/json' \
       -d '{"model":"routed-broken","force_primary":true,"messages":[{"role":"user","content":"hi"}]}'
   done
   ```

## Cleanup

```sh
kind delete cluster --name agentgateway-content-routing
```
