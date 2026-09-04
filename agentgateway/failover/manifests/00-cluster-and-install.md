# Cluster + install commands

Exact commands used to stand up the environment this post's manifests are
tested against. Ephemeral `kind` cluster, torn down after testing. This post
is self-contained: it does not assume A1's `agentgateway-multi-provider`
cluster is still around.

```sh
kind create cluster --name agentgateway-failover --config ../kind-config.yaml

export GWAPI_VERSION=1.6.0
kubectl apply --server-side -f \
  https://github.com/kubernetes-sigs/gateway-api/releases/download/v$GWAPI_VERSION/experimental-install.yaml

helm upgrade -i --create-namespace --namespace agentgateway-system \
  --version v1.5.0 agentgateway-crds oci://cr.agentgateway.dev/charts/agentgateway-crds

helm upgrade -i -n agentgateway-system agentgateway oci://cr.agentgateway.dev/charts/agentgateway \
  --version v1.5.0 --set agentgatewayModels.enabled=true

kubectl get gatewayclass   # expect agentgateway / ACCEPTED=True
```

**`agentgatewayModels.enabled=true`** is the one flag this lab needs that A1
didn't: it turns on support for the `AgentgatewayModel` CRD, used only in
Scenario C. Scenarios A and B use the same stable `AgentgatewayBackend` +
`HTTPRoute` API as A1 and don't need it, but there's no reason to install
twice, so it's on from the start.

No provider credentials needed anywhere in this lab: every scenario runs
against `httpbun`, keyless start to finish.

Apply order for the manifests in this folder:

1. `01-gateway-and-backends.yaml` — the `Gateway`, a healthy `httpbun`
   `Deployment`/`Service`, and a second, deliberately broken one
   (`httpbun-primary-bad`) whose only job is answering `/status/500`. Two
   separate backends on purpose, see the file's own header comment for why.
   The `agentgateway-proxy` Service is a `LoadBalancer`; on `kind` it stays
   `EXTERNAL-IP: <pending>` (no LB provider — expected). Reach it with a
   port-forward, which every `curl` below assumes:

   ```sh
   # leave running in its own terminal
   kubectl port-forward -n agentgateway-system svc/agentgateway-proxy 8080:8080
   ```
2. `02-resilient-llm-backend-route.yaml` — one `AgentgatewayBackend`
   (`spec.ai.groups`, priority by array order) spanning both backends, and
   its `HTTPRoute` at `/llm/resilient`. On its own, no failover yet: a 500
   from group 0 is just a 500 to the client.

   ```sh
   curl -s -o /dev/null -w '%{http_code}\n' -X POST http://localhost:8080/llm/resilient \
     -H 'Content-Type: application/json' \
     -d '{"model":"gpt-4","messages":[{"role":"user","content":"hi"}]}'
   # 500, every time, until step 3 is applied
   ```
3. `03-health-eviction-policy.yaml` — Scenario A. An `AgentgatewayPolicy`
   targeting the backend with `spec.backend.health.eviction`. Send several
   requests in a row: the first still returns the primary's real 500 (not
   evicted yet), every one after that returns 200 from the fallback.
4. `04-retry-policy.yaml` — Scenario B. A second `AgentgatewayPolicy`,
   targeting the `HTTPRoute` this time, with `spec.traffic.retry`. Layered
   on top of step 3: now even the very first request returns 200, no error
   ever reaches the client.
5. `05-virtualmodel-failover-experimental.yaml` — Scenario C, the gotcha.
   The same two backends, the same eviction policy, described instead with
   the experimental `AgentgatewayModel.virtualModel.failover` API. Send
   several requests to model `resilient-virtualmodel`: every one returns
   500 from the primary. See the file's header and the post's Gotchas
   section for what this does and doesn't prove.

## Cleanup

```sh
kind delete cluster --name agentgateway-failover
```
