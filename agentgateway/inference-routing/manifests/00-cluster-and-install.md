# Cluster + install commands

Exact commands used to stand up the environment this post's manifests are
tested against. Ephemeral `kind` cluster, torn down after testing. This post
is self-contained: it does not assume A1's, A2's, or A3's clusters are still
around.

```sh
kind create cluster --name agentgateway-inference-routing --config ../kind-config.yaml
```

Gateway API standard channel is enough here. Nothing in this lab uses an
experimental API (no `AgentgatewayModel`), unlike A1-A3, which needed the
experimental channel for that reason.

```sh
export GWAPI_VERSION=1.6.0
kubectl apply --server-side -f \
  https://github.com/kubernetes-sigs/gateway-api/releases/download/v$GWAPI_VERSION/standard-install.yaml
```

The Gateway API Inference Extension CRDs are a separate release train from
Gateway API itself. Its `v1.5.0` here is that project's own version number,
unrelated to agentgateway's `1.5.0` below, they just happen to match.

```sh
export INF_EXT_VERSION=1.5.0
kubectl apply -f \
  https://github.com/kubernetes-sigs/gateway-api-inference-extension/releases/download/v$INF_EXT_VERSION/manifests.yaml
```

agentgateway, same `1.5.0` used throughout this series, with the Inference
Extension controller support turned on:

```sh
helm upgrade -i --create-namespace --namespace agentgateway-system \
  --version v1.5.0 agentgateway-crds oci://cr.agentgateway.dev/charts/agentgateway-crds

helm upgrade -i -n agentgateway-system agentgateway oci://cr.agentgateway.dev/charts/agentgateway \
  --version v1.5.0 --set inferenceExtension.enabled=true

kubectl get gatewayclass   # expect agentgateway / ACCEPTED=True
```

No provider credentials needed anywhere in this lab: the simulator stands in
for a real model server, keyless start to finish, same role httpbun plays
elsewhere in this series.

Apply order for the manifests in this folder:

1. `01-simulator-and-gateway.yaml` — the `vllm-qwen3-32b` Deployment (the
   `llm-d-inference-sim` simulator, 3 replicas), and the `Gateway`
   (`agentgateway-proxy`, port 8080, same name/port as every other lab in
   this repo).

   ```sh
   kubectl wait --for=condition=available --timeout=120s deployment/vllm-qwen3-32b
   kubectl wait --for=condition=Programmed --timeout=120s gateway/agentgateway-proxy -n agentgateway-system
   ```
2. Install the llm-d Router Gateway chart. This is a separate, external
   project's Helm chart, not a manifest in this folder: it creates the
   `InferencePool`, the llm-d Router EPP Deployment/Service, and an
   `HTTPRoute` that attaches to the Gateway.

   ```sh
   export ROUTER_CHART_VERSION=v0.9.0
   helm upgrade -i vllm-qwen3-32b \
     oci://ghcr.io/llm-d/charts/llm-d-router-gateway \
     --version $ROUTER_CHART_VERSION \
     --set router.modelServers.matchLabels.app=vllm-qwen3-32b \
     --set router.epp.resources.requests.cpu=100m \
     --set router.epp.resources.requests.memory=128Mi \
     --set router.epp.resources.limits.memory=512Mi \
     --set provider.name=none \
     --set httpRoute.create=true \
     --set httpRoute.inferenceGatewayName=agentgateway-proxy \
     --set httpRoute.inferenceGatewayNamespace=agentgateway-system

   kubectl get inferencepool vllm-qwen3-32b
   kubectl get deployment vllm-qwen3-32b-epp \
     -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
   kubectl get httproute vllm-qwen3-32b
   ```

   **Gotcha caught here during validation**: `httpRoute.inferenceGatewayNamespace`
   defaults to `""`, which Gateway API resolves as "the HTTPRoute's own
   namespace" (`default`, where this chart's release lives), not the
   namespace the Gateway actually happens to be in. This series always puts
   its `Gateway` in `agentgateway-system` (see `01-simulator-and-gateway.yaml`),
   so leaving `httpRoute.inferenceGatewayNamespace` unset silently creates an
   `HTTPRoute` whose `parentRefs` points at a `Gateway` named
   `agentgateway-proxy` in `default`, which doesn't exist. Nothing errors:
   `kubectl get httproute` still shows the object, but its
   `status.parents` stays empty and every request gets a flat
   `404 route not found`, with no other clue why. Set the namespace
   explicitly whenever the Gateway isn't in the chart's own release
   namespace.

   The `Gateway`'s listener also needs `allowedRoutes.namespaces.from: All`
   (already set in `01-simulator-and-gateway.yaml`) for the same reason:
   the default is same-namespace-only, and this `HTTPRoute` lives in
   `default` while the `Gateway` lives in `agentgateway-system`. Without
   it, the same silent "route not found" happens even with the namespace
   fix above.

   **Scenario A** (bare quickstart, InferencePool selection only):

   ```sh
   kubectl port-forward -n agentgateway-system svc/agentgateway-proxy 8080:8080 &

   curl -s -o /dev/null -w '%{http_code}\n' http://localhost:8080/v1/completions \
     -H 'Content-Type: application/json' \
     -d '{"model":"Qwen/Qwen3-32B","prompt":"What is the warmest city in the USA?","max_tokens":100,"temperature":0.5}'
   # 200
   ```

   **Failure path**: scale the simulator to zero and send the same request.

   ```sh
   kubectl scale deployment/vllm-qwen3-32b --replicas=0
   curl -s http://localhost:8080/v1/completions \
     -H 'Content-Type: application/json' \
     -d '{"model":"Qwen/Qwen3-32B","prompt":"hi","max_tokens":10}'
   # HTTP 503
   # inference error: ServiceUnavailable - failed to find endpoint candidates for serving the request

   kubectl scale deployment/vllm-qwen3-32b --replicas=3
   kubectl wait --for=condition=available --timeout=90s deployment/vllm-qwen3-32b
   ```

   Confirms the `InferencePool`'s `endpointPickerRef.failureMode: FailOpen`
   (the default the router chart sets) doesn't mean "route anywhere when the
   EPP has nothing to pick." It means the EPP itself fails open if *it*
   errors; with zero backend pods there's genuinely nothing to route to, so
   agentgateway returns a clean `503`, not a silent black hole.
3. Reconfigure the router chart to stop creating its own `HTTPRoute`, so
   Scenario B's hand-authored one (below) doesn't collide with it (both
   would otherwise be named `vllm-qwen3-32b` in `default`):

   ```sh
   helm upgrade vllm-qwen3-32b \
     oci://ghcr.io/llm-d/charts/llm-d-router-gateway \
     --version $ROUTER_CHART_VERSION \
     --reuse-values \
     --set httpRoute.create=false

   kubectl delete httproute vllm-qwen3-32b --ignore-not-found
   ```
4. `02-inferencepool-backend-policy.yaml` — Scenario B. An
   `AgentgatewayBackend` with a `custom` provider pointing at the same
   `InferencePool`, a new `HTTPRoute` (same name, now hand-authored) routing
   to that backend, and an `AgentgatewayPolicy` capping token usage at
   100 tokens/minute.

   ```sh
   kubectl apply -f "$MANIFESTS_DIR/02-inferencepool-backend-policy.yaml"

   for i in 1 2 3; do
     curl -s -D - -o /dev/null http://localhost:8080/v1/chat/completions \
       -H 'Content-Type: application/json' \
       -d '{"model":"Qwen/Qwen3-32B","max_tokens":200,"messages":[{"role":"user","content":"hi"}]}' \
       | grep -iE '^HTTP|x-ratelimit'
   done
   ```

   The simulator's completion length isn't fixed at `max_tokens`, it picks a
   random length up to that cap, so exactly which request trips the budget
   varies. One real run: request 1 used 32 tokens (`200 OK`,
   `x-ratelimit-remaining: 68`), request 2 used 121 more (`200 OK`,
   `x-ratelimit-remaining: 0`, cumulative 153 already over the 100/minute
   budget), request 3 got `429 Too Many Requests`. Every request after that
   stays `429` until `x-ratelimit-reset` (the response's own reset-seconds
   value) elapses. Token counts are only known once a response completes
   (the field's own doc comment says this explicitly), so the request that
   pushes the total over the limit is never itself rejected. It's always
   the *next* one that pays for it.

## Cleanup

```sh
kind delete cluster --name agentgateway-inference-routing
```
