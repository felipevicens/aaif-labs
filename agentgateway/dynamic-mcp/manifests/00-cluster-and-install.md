# Cluster + install commands

Exact commands used to stand up the environment this post's manifests were
tested against. Ephemeral `kind` cluster, torn down after testing —
nothing here touched shared infrastructure.

```sh
kind create cluster --name agentgateway-dynamic-mcp --config kind-config.yaml

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

1. `01-gateway-and-backend.yaml` — Gateway plus one `AgentgatewayBackend`
   whose only MCP target is a label `selector`
   (`services.matchLabels: {mcp-role: dynamic-fetcher}`), not a `static`
   host/port. The HTTPRoute exposes it at `/mcp`. Label-selector targets
   only support Streamable HTTP, per agentgateway's docs, which is why
   every server in this lab uses that transport, not SSE.
2. `02-mcp-server-a.yaml` — the one MCP server that exists when the
   cluster first comes up: a stock `python:3.12-slim` container running a
   small script (mounted via `ConfigMap`) built on the official Python
   `mcp` SDK, exposing one tool, `whoami`, that returns its own pod name.
   Its Service carries the `mcp-role: dynamic-fetcher` label the selector
   above is watching for, and lives in `agentgateway-system`, the same
   namespace as the `AgentgatewayBackend` — confirmed live, a
   selector-based target only discovers Services in its own namespace,
   not documented anywhere. See the file's header comment.
3. `03-mcp-server-b.yaml` — **not applied by `setup.sh`.** A second,
   independent MCP server, same tool name, same label, same namespace.
   Applying this file live, after the cluster is already up and already
   serving traffic, with zero change to `01-gateway-and-backend.yaml`, is
   Scenario B in the post.

Reach the federated endpoint with a port-forward:

```sh
kubectl port-forward -n agentgateway-system svc/agentgateway-proxy 8080:8080
```

Talk to it with the Python MCP SDK (`pip install mcp`), not `curl`
directly, same reason as every other MCP post in this series: Streamable
HTTP needs session-header handling a plain HTTP client doesn't give you
for free.

```sh
python3 scripts/mcp_client.py list
python3 scripts/mcp_client.py call whoami
```

Cleanup:

```sh
kind delete cluster --name agentgateway-dynamic-mcp
```
