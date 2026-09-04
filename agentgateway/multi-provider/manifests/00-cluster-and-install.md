# Cluster + install commands

Exact commands used to stand up the environment this post's manifests are
tested against. Ephemeral `kind` cluster, torn down after testing, same
pattern as post 1 and post 2 (`virtual-keys`, `observability`) — nothing here
touches shared infrastructure. This post is self-contained: it does not
assume either earlier cluster is still around.

```sh
kind create cluster --name agentgateway-multi-provider --config ../kind-config.yaml

export GWAPI_VERSION=1.6.0
kubectl apply --server-side -f \
  https://github.com/kubernetes-sigs/gateway-api/releases/download/v$GWAPI_VERSION/experimental-install.yaml

helm upgrade -i --create-namespace --namespace agentgateway-system \
  --version v1.5.0 agentgateway-crds oci://cr.agentgateway.dev/charts/agentgateway-crds

helm upgrade -i -n agentgateway-system agentgateway oci://cr.agentgateway.dev/charts/agentgateway \
  --version v1.5.0

kubectl get gatewayclass   # expect agentgateway / ACCEPTED=True
```

**Note on the experimental Gateway API flag.** Posts 1 and 2 (chart
`1.4.0-alpha.1`) passed `--set
controller.extraEnv.KGW_ENABLE_GATEWAY_API_EXPERIMENTAL_FEATURES=true`
explicitly. On chart `1.5.0` that flag was renamed to
`AGW_ENABLE_EXPERIMENTAL_GATEWAY_API_FEATURES` (prefix *and* word order
changed) and it now defaults to enabled, so the command above does not pass it
at all. If you are upgrading a `virtual-keys`/`observability` cluster in
place instead of starting fresh, drop the old `KGW_...` flag: the newer
controller silently ignores it rather than erroring, which just means it
looks set but does nothing.

Apply order for the manifests in this folder:

1. `01-gateway-backend-route.yaml` — Scenario 1. `Gateway`, the `httpbun`
   `Deployment`/`Service` (keyless OpenAI-compatible mock), an
   `AgentgatewayBackend` pointed at it, and its `HTTPRoute`. Nothing here
   needs a provider credential, so it is the path any reader can complete.
   The `agentgateway-proxy` Service is a `LoadBalancer`; on `kind` it stays
   `EXTERNAL-IP: <pending>` (no LB provider — expected). Reach it with a
   port-forward, which every `curl` below assumes:

   ```sh
   # leave running in its own terminal
   kubectl port-forward -n agentgateway-system svc/agentgateway-proxy 8080:8080
   ```
2. `02-openai-secret-and-backend.yaml` — Scenario 2 (real OpenAI, single
   provider). Needs `OPENAI_API_KEY`:

   ```sh
   export OPENAI_API_KEY="sk-..."
   envsubst < 02-openai-secret-and-backend.yaml | kubectl apply -f -
   ```

   No `envsubst`? Pipe the same YAML through a `cat <<EOF | kubectl apply -f -`
   heredoc instead; the shell expands `$OPENAI_API_KEY` with no extra tools.
3. `03-multiprovider-priority-groups.yaml` — Scenario 3, the core of the post.
   One `AgentgatewayBackend` combining httpbun, OpenAI and Gemini as
   `spec.ai.groups` (priority groups). Reuses the `openai-credentials` Secret
   from step 2 and adds a new one for Gemini. Needs both keys:

   ```sh
   export OPENAI_API_KEY="sk-..." GEMINI_API_KEY="..."
   envsubst < 03-multiprovider-priority-groups.yaml | kubectl apply -f -
   ```
4. `04-anthropic-config-unvalidated.yaml` is **not applied** by
   `scripts/setup.sh` and was not run against a live cluster. It is a
   reference config only — see its header comment before using it for real.

This post stays on the stable `AgentgatewayBackend` + `HTTPRoute` API
throughout. The experimental `AgentgatewayModel` API (`virtualModel.failover`
/ `.conditional`) is out of scope here; A2 and A3 build it out next.

## Cleanup

```sh
kind delete cluster --name agentgateway-multi-provider
```
