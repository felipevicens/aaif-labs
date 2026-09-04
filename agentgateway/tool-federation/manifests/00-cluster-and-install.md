# Cluster + install commands

Exact commands used to stand up the environment this post's manifests were
tested against. Ephemeral `kind` cluster, torn down after testing —
nothing here touched shared infrastructure.

```sh
kind create cluster --name agentgateway-tool-federation --config kind-config.yaml

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

1. `01-teams.yaml` — five independent Deployments/Services, one per
   team, all running the same real MCP server
   (`ghcr.io/peterj/mcp-website-fetcher:main`, one tool: `fetch`) in a
   dedicated `mcp-teams` namespace.
2. `02-gateway-and-mcp-backend.yaml` — Gateway, one `AgentgatewayBackend`
   federating all five as `spec.mcp.targets[]`, and the HTTPRoute that
   exposes the federated endpoint at `/mcp`. The `agentgateway-proxy`
   Service is a `LoadBalancer`; on `kind` it stays `EXTERNAL-IP: <pending>`
   (no LB provider — expected). Reach it with a port-forward:

   ```sh
   # leave running in its own terminal
   kubectl port-forward -n agentgateway-system svc/agentgateway-proxy 8080:8080
   ```
3. Talk to the federated endpoint with the Python MCP SDK (`pip install
   mcp`), not `curl` directly: MCP's Streamable HTTP transport needs
   session-header handling a plain HTTP client doesn't give you for free.

   ```sh
   python3 scripts/mcp_client.py list
   python3 scripts/mcp_client.py call docs_fetch https://lipsum.com/
   ```

Cleanup:

```sh
kind delete cluster --name agentgateway-tool-federation
```
