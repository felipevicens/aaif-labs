# Turning Your REST API Into an MCP Tool — lab

Companion manifests for the post **"Turning Your REST API Into an MCP
Tool"** (D3). Exposes a real REST API (`swaggerapi/petstore3`) as a set of
MCP tools, one per OpenAPI operation, with zero hand-written tool code.

## Layout

```
kind-config.yaml                     # kind node image pin (v1.34.0)
manifests/
  00-cluster-and-install.md         # exact cluster + install commands, apply order, cleanup
  01-gateway-and-backend.yaml        # Gateway + AgentgatewayBackend with a `static` target -> the adapter + HTTPRoute
  02-petstore.yaml                   # the plain REST API this lab exposes as MCP tools
  03-openapi-adapter.yaml            # agentgateway itself, standalone, in OpenAPI-to-MCP mode (ConfigMap + Deployment + Service)
scripts/
  setup.sh                  # stands up the gateway, petstore, and the adapter
  teardown.sh                # kind delete cluster
  mcp_client.py               # minimal Streamable HTTP MCP client, supports call arguments (pip install mcp)
```

## Quickstart

```sh
cd scripts
./setup.sh   # no keys needed anywhere in this lab
```

Then, with the port-forward from `setup.sh`'s own printed instructions
running:

```sh
python3 scripts/mcp_client.py list
python3 scripts/mcp_client.py call getInventory
python3 scripts/mcp_client.py call getPetById '{"path": {"petId": 1}}'
```

Tear down with `./teardown.sh` (just `kind delete cluster`).

## Why this needs an adapter workload at all

The Kubernetes `AgentgatewayBackend` CRD has no `openapi` MCP target type.
Confirmed against the real CRD, not just docs prose: pulled the
`agentgateway-crds` Helm chart locally (`helm pull
oci://cr.agentgateway.dev/charts/agentgateway-crds --version 1.5.0
--untar`) and inspected the generated CRD YAML directly. `spec.mcp.targets[]`
items support exactly three properties: `name`, `selector`, `static`.
Nothing else. OpenAPI-to-MCP conversion is a standalone-agentgateway-only
feature in this release.

So this lab runs agentgateway itself as the adapter: same image already
used for the proxy (`cr.agentgateway.dev/agentgateway:v1.5.0`), invoked in
its standalone config-file mode (`agentgateway -f config.yaml`) instead of
being driven by the Kubernetes controller. That mode's `mcp.targets[].openapi`
target does exist, and it's what turns petstore's spec into real MCP
tools. The adapter then gets federated into the "real" gateway with an
ordinary `static` target, exactly D1's mechanism. See `PLAN.md` (private
repo) for the full research trail, including the exact CRD field dump.

## What's validated and what isn't

Confirmed live, first against two plain Docker containers on one network
(no cluster, fastest way to check the mechanism before committing to the
Kubernetes lab shape), then on a from-scratch `kind` cluster:

- **The adapter serves both Streamable HTTP (`/mcp`) and SSE (`/sse`)
  simultaneously.** Either is a valid `protocol` for the `static` target
  federating it (the CRD's own enum is exactly `[SSE, StreamableHTTP]`).
- **One MCP tool per OpenAPI operation, named after its `operationId`.**
  Petstore's real spec produced 19 real tools (`getPetById`, `addPet`,
  `getInventory`, `findPetsByStatus`, and so on), each with an
  `inputSchema` generated straight from that operation's parameters and
  request body.
- **Tool calls round-trip to the real REST API, not a mock.** `getInventory`
  returned petstore's real inventory counts; `getPetById` with
  `{"path": {"petId": 1}}` returned a full, real pet object.

See `PLAN.md` (private repo) for the exact commands, error text, and the
full decision log.

## A note on the environment this was validated in

Same sandbox-only quirks as the rest of this series (the `oom_score_adj`
node-image fix and the `IPV6_ENABLED=false` readiness-bind fix, needed
here for both the gateway proxy and the standalone adapter, since it's the
same binary hitting the same IPv6-readiness-bind issue). See A1's README
for the full explanation. None of this is in `kind-config.yaml`,
`setup.sh`, or the manifests here; real clusters with normal internet
access need none of it.
