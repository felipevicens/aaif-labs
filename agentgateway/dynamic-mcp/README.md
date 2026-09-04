# Adding an MCP Server Without Restarting Anything — lab

Companion manifests for the post **"Adding an MCP Server Without
Restarting Anything"** (D2). Where D1 federated five MCP servers with
`static` targets, each one a fixed host/port baked into the
`AgentgatewayBackend`, this lab federates them with a label `selector`
instead, and adds a second server to a running cluster with no edit to
that resource at all.

## Layout

```
kind-config.yaml                     # kind node image pin (v1.34.0)
manifests/
  00-cluster-and-install.md         # exact cluster + install commands, apply order, cleanup
  01-gateway-and-backend.yaml        # Gateway + one AgentgatewayBackend with a selector-based MCP target + HTTPRoute
  02-mcp-server-a.yaml               # the one MCP server that exists at boot
  03-mcp-server-b.yaml               # NOT applied by setup.sh — applying this live is the point of the lab
scripts/
  setup.sh                  # stands up the gateway + server A only
  teardown.sh                # kind delete cluster
  mcp_client.py               # minimal Streamable HTTP MCP client (pip install mcp)
```

## Quickstart

```sh
cd scripts
./setup.sh   # no keys needed anywhere in this lab
```

Then, with the port-forward from `setup.sh`'s own printed instructions
running:

```sh
python3 scripts/mcp_client.py list          # one tool, from mcp-server-a
kubectl apply -f manifests/03-mcp-server-b.yaml
kubectl wait --for=condition=Available deployment/mcp-server-b -n mcp-dynamic --timeout=180s
python3 scripts/mcp_client.py list          # now reflects mcp-server-b too, no gateway change
```

Tear down with `./teardown.sh` (just `kind delete cluster`).

## Why a hand-rolled MCP server instead of a published image

D1's tool servers all used the same public, credential-free
`ghcr.io/peterj/mcp-website-fetcher:main` image. That image only speaks
SSE (confirmed live: `--help` on it says "Port to listen on for SSE", and
its `/mcp` path 404s). agentgateway's docs are explicit that
label-`selector` MCP targets only support Streamable HTTP, not SSE, so
D1's image can't demonstrate this feature at all. The published
`mcp/everything` reference image was checked too, and also doesn't ship a
Streamable HTTP entrypoint in its published build (only stdio and SSE).
Rather than depend on a third-party image with the right transport, this
lab uses the same pattern C1's cost-tracking lab already established for
"no suitable real image exists": a stock `python:3.12-slim` base image
running a small script, mounted via `ConfigMap`, built on the official
Python `mcp` SDK's own Streamable HTTP server support
(`mcp.server.mcpserver.MCPServer(...).run(transport="streamable-http")`).
See `PLAN.md` (private repo) for the full research trail.

## What's validated and what isn't

Validated live on a from-scratch `kind` cluster, twice, with identical
results both times:

- **A selector-based MCP target only discovers Services in the same
  namespace as the `AgentgatewayBackend` resource itself.** Not
  documented anywhere. Put `mcp-server-a`'s Service in a different
  namespace and every call fails with `mcp: no backends configured`,
  even though the gateway's own workload discovery clearly sees it. This
  is why every server in this lab lives in `agentgateway-system`, not a
  separate namespace, unlike D1's `static.host` targets which can point
  at any namespace.
- **The tool-naming question this lab exists to answer**: with two
  Services (`mcp-server-a`, `mcp-server-b`) both carrying
  `mcp-role: dynamic-fetcher`, `tools/list` returns
  `mcp-server-a-8000_whoami` and `mcp-server-b-8000_whoami`. Each
  matching Service becomes its own sub-target, named
  `<service-name>-<port>`, with the tool prefixed
  `<sub-target-name>_<tool-name>` — same pattern as D1's named `static`
  targets, just derived from the Service instead of hand-written.
- **The prefixing is dynamic, not fixed.** Delete `mcp-server-b` live and
  `tools/list` immediately reverts to a single unprefixed `whoami`, same
  `prefixMode: Conditional` default D1 found (prefix only appears when
  there's more than one candidate to disambiguate).
- No gateway restart and no `AgentgatewayBackend` edit at any point in
  either direction.

See `PLAN.md` (private repo) for the exact commands, error text, and the
full decision log behind the hand-rolled server choice.

## A note on the environment this was validated in

Same sandbox-only quirks as the rest of this series (the `oom_score_adj`
node-image fix and the `IPV6_ENABLED=false` readiness-bind fix). See A1's
README for the full explanation. None of this is in `kind-config.yaml`,
`setup.sh`, or the manifests here; real clusters with normal internet
access need none of it.
