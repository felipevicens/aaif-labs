# Cluster + install commands

Exact commands used to stand up the environment this post's manifests were
tested against. Ephemeral `kind` cluster, deleted after testing. This post is
self-contained: it does not assume any earlier cluster is still around.

```sh
kind create cluster --name agentgateway-multi-provider --config ../kind-config.yaml

kubectl apply --server-side -f \
  https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.6.0/experimental-install.yaml

helm upgrade -i --create-namespace -n agentgateway-system --version v1.5.0 \
  agentgateway-crds oci://cr.agentgateway.dev/charts/agentgateway-crds

helm upgrade -i -n agentgateway-system --version v1.5.0 \
  agentgateway oci://cr.agentgateway.dev/charts/agentgateway

kubectl get gatewayclass   # expect agentgateway / ACCEPTED=True
```

No Helm flag is needed for anything in this lab. The first posts of the
series (chart `1.4.0-alpha.1`) passed
`controller.extraEnv.KGW_ENABLE_GATEWAY_API_EXPERIMENTAL_FEATURES=true`; this
one passes nothing.

## Apply order

1. `01-gateway-httpbun-route.yaml`: Scenario 1, no keys. The `Gateway`,
   httpbun, the backend `llm` pointing at httpbun, and the `HTTPRoute` on
   `/v1/chat/completions`. After this, start the port-forward and leave it
   running in its own terminal:

   ```sh
   kubectl wait --for=condition=Programmed gateway/agentgateway-proxy \
     -n agentgateway-system --timeout=180s
   kubectl port-forward -n agentgateway-system svc/agentgateway-proxy 8080:8080
   ```

2. `02-openai-backend.yaml`: Scenario 2. Create the Secret first:

   ```sh
   kubectl create secret generic openai-credentials -n agentgateway-system \
     --from-literal=Authorization="$OPENAI_API_KEY"
   kubectl apply -f 02-openai-backend.yaml
   ```

3. `03-see-the-translation.yaml`: Scenario 3, no keys. Echo server plus
   `wire-gemini` / `wire-anthropic` backends on `/wire/gemini` and
   `/wire/anthropic`. Read what they received with
   `kubectl logs deploy/echo -n default`.

4. `04-gemini-backend.yaml`: Scenario 4. Create the Secret with the bare key:

   ```sh
   kubectl create secret generic gemini-credentials -n agentgateway-system \
     --from-literal=Authorization="$GEMINI_API_KEY"
   kubectl apply -f 04-gemini-backend.yaml
   ```

5. `05-anthropic-backend.yaml`: Scenario 5. Create the Secret with the bare
   key. No `location` block is needed, the gateway moves it to `x-api-key`:

   ```sh
   kubectl create secret generic anthropic-credentials -n agentgateway-system \
     --from-literal=Authorization="$ANTHROPIC_API_KEY"
   kubectl apply -f 05-anthropic-backend.yaml
   ```

6. `06-provider-groups-openai-first.yaml`, then
   `07-provider-groups-gemini-first.yaml`: Scenario 6. Needs the OpenAI and
   Gemini Secrets.

7. `08-groups-without-eviction.yaml`: the Gotcha demo, no keys, on
   `/demo/groups`.

Files 02, 04, 05, 06 and 07 all re-apply the same backend `llm`, so each one
replaces the previous one. The route and the client never change.

## Cleanup

```sh
kind delete cluster --name agentgateway-multi-provider
```
