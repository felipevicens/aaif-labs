# Cluster + install commands

Exact commands used to stand up the environment this post's manifests were
tested against. Ephemeral `kind` cluster, torn down after testing —
nothing here touched shared infrastructure.

```sh
kind create cluster --name agentgateway-web-uis --config kind-config.yaml

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

kagent, for Scenario 3 (installed separately from agentgateway — it isn't
Gateway-API-shaped, so it doesn't fit this series' usual flat-YAML apply
order):

```sh
helm install kagent-crds oci://ghcr.io/kagent-dev/kagent/helm/kagent-crds \
  --namespace kagent --create-namespace

helm install kagent oci://ghcr.io/kagent-dev/kagent/helm/kagent \
  --namespace kagent \
  --set providers.default=openAI \
  --set providers.openAI.apiKey=placeholder
```

Apply order for the manifests in this folder:

1. `01-gateway-and-mock-backend.yaml` — the `web-uis` namespace, Gateway,
   the mock OpenAI-compatible model server, and the one
   `AgentgatewayBackend`/`HTTPRoute` pair every front-end below shares.
2. `03-open-webui.yaml` — Open WebUI, `OPENAI_API_BASE_URL` pointed at the
   gateway.
3. `04-librechat.yaml` — MongoDB + LibreChat, `librechat.yaml` custom
   endpoint pointed at the same gateway URL.
4. `05-kagent-model-and-agent.yaml` — after kagent itself is installed
   (above): a `ModelConfig` using kagent's "BYO OpenAI-compatible model"
   path, and a minimal `Agent` that uses it.
5. `02-guardrail-policy.yaml` — apply this **after** `setup.sh` finishes,
   by hand, so the before/after is visible: the same request from all
   three front-ends succeeds, then gets rejected identically once this one
   policy lands on the shared route.

Reach the gateway and each app with port-forwards:

```sh
kubectl port-forward -n agentgateway-system svc/agentgateway-proxy 8080:8080
kubectl port-forward -n web-uis svc/open-webui 3000:8080
kubectl port-forward -n web-uis svc/librechat 3080:3080
kubectl port-forward -n kagent svc/kagent-controller 8083:8083
```

This lab validates through direct API/CLI calls rather than a full
interactive browser session in each app — see the post's "what's
validated and what isn't" note. Each curl below uses the exact request
shape that app's own backend sends when a user submits a chat.

```sh
# Scenario 1: the shared backend directly (sanity check before adding any UI)
curl -s http://localhost:8080/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"agentgateway-demo-model","messages":[{"role":"user","content":"hi there"}]}'

# NOTE: GET /v1/models does NOT work here — a bodyless GET against this
# host/port/path-overridden `openai` backend fails inside agentgateway
# itself (400, "EOF while parsing a value"), before it ever reaches the
# mock. See the post's Gotchas. None of the three front-ends below
# actually depend on it (LibreChat's config sets fetch: false; Open
# WebUI tolerates a non-200 probe at startup).

# Scenario 2: same call, as Open WebUI's backend would send it (non-streaming)
curl -s http://localhost:8080/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"agentgateway-demo-model","messages":[{"role":"user","content":"hello from open webui"}],"stream":false}'

# Same call, as LibreChat's backend would send it
curl -s http://localhost:8080/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"agentgateway-demo-model","messages":[{"role":"user","content":"hello from librechat"}],"stream":false}'

# kagent: scriptable, non-interactive, app-native
kagent invoke --agent demo-agent --task "hello from kagent" --namespace kagent
# NOTE: kagent CLI v0.10.0 has a client-side response-decode bug that
# fails EVERY call, including ones that succeed server-side ("failed to
# decode response: ... error.data of type []*errordetails.Typed"). See
# the post's Gotchas. To see the actual result, call the same A2A method
# the CLI uses directly against the controller's REST port:
curl -s -X POST http://localhost:8083/api/a2a/kagent/demo-agent/ \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":"1","method":"message/send","params":{"message":{"role":"user","parts":[{"kind":"text","text":"hello from kagent"}],"messageId":"11111111-1111-1111-1111-111111111111"}}}'

# Scenario 3: apply the shared policy, then repeat all three calls above
kubectl apply -f manifests/02-guardrail-policy.yaml

curl -s -o /dev/null -w '%{http_code}\n' http://localhost:8080/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"agentgateway-demo-model","messages":[{"role":"user","content":"can you send me an email"}]}'

# kagent, same trigger word, via the direct A2A call (see note above) —
# the task comes back with status.state "failed" and the gateway's 403
# text in its message body, proving the shared policy governs kagent too
curl -s -X POST http://localhost:8083/api/a2a/kagent/demo-agent/ \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":"2","method":"message/send","params":{"message":{"role":"user","parts":[{"kind":"text","text":"can you send me an email"}],"messageId":"22222222-2222-2222-2222-222222222222"}}}'

# control: a request without the trigger word still succeeds after the policy is live
curl -s http://localhost:8080/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"agentgateway-demo-model","messages":[{"role":"user","content":"still fine"}]}'
```

Cleanup:

```sh
helm uninstall kagent -n kagent
helm uninstall kagent-crds -n kagent
kind delete cluster --name agentgateway-web-uis
```
