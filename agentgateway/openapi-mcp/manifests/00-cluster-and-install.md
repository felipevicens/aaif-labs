# Cluster + install commands

Exact commands used to stand up the environment this post's manifests were
tested against. Ephemeral `kind` cluster, torn down after testing —
nothing here touched shared infrastructure.

```sh
kind create cluster --name agentgateway-openapi-mcp --config kind-config.yaml

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
   whose only MCP target is `static`, pointed at the OpenAPI adapter's
   in-cluster Service (`openapi-adapter.openapi-mcp.svc.cluster.local:3000`,
   `protocol: StreamableHTTP`). This is the same `static.host` mechanism
   the tool-federation post (D1) used, confirmed here to work identically
   whether the target is a hand-written MCP server or a generated one. The
   HTTPRoute exposes it at `/mcp`.
2. `02-petstore.yaml` — the plain REST API this whole post exposes as MCP
   tools: `swaggerapi/petstore3:unstable`, the same image agentgateway's
   own official tutorial uses. Nothing MCP-aware about it; it's an
   ordinary OpenAPI 3.0 service.
3. `03-openapi-adapter.yaml` — agentgateway itself, run standalone
   (`agentgateway -f /config/config.yaml`, the same image already used for
   the proxy, just invoked differently) with `mcp.targets[].openapi`
   pointed at petstore's real spec (baked into the ConfigMap, fetched
   verbatim from petstore's own `/api/v3/openapi.json`). This is the
   adapter: the Kubernetes `AgentgatewayBackend` CRD has no native
   `openapi` MCP target (confirmed against the real CRD schema, `spec.mcp.targets[]`
   supports exactly `name`, `selector`, `static` — see the file's header
   comment), so this workload is what stands in for it.

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
python3 scripts/mcp_client.py call getInventory
python3 scripts/mcp_client.py call getPetById '{"path": {"petId": 1}}'
```

Cleanup:

```sh
kind delete cluster --name agentgateway-openapi-mcp
```
