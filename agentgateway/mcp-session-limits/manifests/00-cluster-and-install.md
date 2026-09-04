# Cluster + install commands

Exact commands used to stand up the environment this post's manifests were
tested against. Ephemeral `kind` cluster, torn down after testing —
nothing here touched shared infrastructure.

```sh
kind create cluster --name agentgateway-mcp-session-limits --config kind-config.yaml

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

Apply order for the manifests in this folder:

1. `01-gateway-and-backend.yaml` — Gateway (scoped to a Gateway-level
   `AgentgatewayParameters` carrying a `deployment.spec.replicas: 1`
   overlay, so it can be scaled later without a new manifest) plus one
   `AgentgatewayBackend` whose `spec.mcp.sessionRouting` is spelled out as
   `Stateful` (the default), with a single `static` MCP target.
2. `02-mcp-tool-server.yaml` — a real, ordinary MCP server with one tool
   (`ping`) that increments a counter and reports its own PID. Neither
   session handling nor rate limiting is implemented here; both happen
   entirely at the gateway.
3. `03-rate-limit-policy.yaml` — the `AgentgatewayPolicy` with
   `traffic.rateLimit.local`, two entries at two different time scales
   (a `Seconds`-scale burst allowance and a tight `Minutes`-scale
   ceiling). Apply this after `setup.sh` finishes, by hand, so the
   before/after is visible.

Reach the gateway with one port-forward:

```sh
kubectl port-forward -n agentgateway-system svc/agentgateway-proxy 8080:8080
```

Talk to the gateway with the Python MCP SDK (`pip install mcp`) for the
higher-level scenarios, same reason as every other MCP post in this
series: Streamable HTTP needs session-header handling a plain HTTP client
doesn't give you for free. For the rate-limit scenarios, raw `curl` in a
loop is simpler and faster, since each `initialize` call is a
self-contained new request that doesn't need any prior session state.

```sh
python3 scripts/mcp_client.py call ping             # basic session mechanic

kubectl apply -f manifests/03-rate-limit-policy.yaml
./scripts/fire_requests.sh 15                        # local rate limit, 1 replica

kubectl patch agentgatewayparameters gateway-scaling -n agentgateway-system \
  --type merge -p '{"spec":{"deployment":{"spec":{"replicas":2}}}}'
./scripts/fire_requests_incluster.sh 20              # same limit, 2 replicas
```

The last command matters: it fires from a throwaway pod inside the
cluster against the Service ClusterIP, not through the `kubectl
port-forward` above. A port-forward to a Service sticks to whichever pod
it picked when the tunnel opened for the whole life of that process, so
running the scaling test through it never reaches the new replica at
all — every request keeps landing on the same, already-exhausted pod,
which looks exactly like "scaling did nothing." Firing from inside the
cluster gets real per-connection load balancing across both replicas.

Cleanup:

```sh
kind delete cluster --name agentgateway-mcp-session-limits
```
