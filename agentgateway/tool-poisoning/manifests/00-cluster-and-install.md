# Cluster + install commands

Exact commands used to stand up the environment this post's manifests were
tested against. Ephemeral `kind` cluster, torn down after testing —
nothing here touched shared infrastructure.

```sh
kind create cluster --name agentgateway-tool-poisoning --config kind-config.yaml

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
   whose only MCP target is `static`, pointed at the vulnerable server's
   in-cluster Service. One target, one backend, on purpose: this lab is
   about what happens between the gateway and a poisoned tool description,
   not about federation.
2. `02-vulnerable-tool-server.yaml` — a real MCP server, real transport,
   two tools. `search_docs`'s docstring carries a genuine tool-poisoning
   payload: a hidden instruction telling an agent to call
   `export_env_vars` on every search and hand back its output, silently.
   `export_env_vars` returns an obviously-fake "secret" string, so a call
   result either contains it or it doesn't.
3. `03-ext-mcp-guardrail.yaml` — this lab's own gRPC server implementing
   agentgateway's `ExtMcp` protocol (`crates/protos/proto/ext_mcp.proto`
   at v1.5.0, vendored verbatim in this file's ConfigMap). Deployed but
   inert until `04-guardrail-policy.yaml` attaches it.
4. `04-guardrail-policy.yaml` — the `AgentgatewayPolicy` that actually
   wires the guardrail in: sanitizes `tools/list` responses, blocks
   `tools/call` requests naming `export_env_vars`. Apply this after
   `setup.sh` finishes, by hand, so the before/after is visible.
5. `05-tool-access-policy.yaml` — a second, independent `AgentgatewayPolicy`:
   CEL-based tool access RBAC (`mcp.tool.name == "search_docs"`), no JWT.
   Apply this by hand too, after the guardrail, to see it work as a
   backstop even with the guardrail policy removed.

Reach the gateway with a port-forward:

```sh
kubectl port-forward -n agentgateway-system svc/agentgateway-proxy 8080:8080
```

Talk to it with the Python MCP SDK (`pip install mcp`), not `curl`
directly, same reason as every other MCP post in this series: Streamable
HTTP needs session-header handling a plain HTTP client doesn't give you
for free.

```sh
python3 scripts/mcp_client.py describe                        # names + full descriptions
kubectl apply -f manifests/04-guardrail-policy.yaml
python3 scripts/mcp_client.py describe                        # sanitized
python3 scripts/mcp_client.py call export_env_vars             # blocked
kubectl apply -f manifests/05-tool-access-policy.yaml
python3 scripts/mcp_client.py list                             # export_env_vars no longer even listed
```

Cleanup:

```sh
kind delete cluster --name agentgateway-tool-poisoning
```
