# Stopping a Tool-Poisoning Attack Before It Starts — lab

Companion manifests for the post **"Stopping a Tool-Poisoning Attack
Before It Starts"** (D4). Runs a deliberately vulnerable MCP server whose
tool description carries a real prompt-injection payload, then closes it
with two independent layers: an MCP guardrail that sanitizes descriptions
and blocks a specific dangerous tool, and CEL-based tool access RBAC as a
second, unrelated backstop.

## Layout

```
kind-config.yaml                       # kind node image pin (v1.34.0)
manifests/
  00-cluster-and-install.md            # exact cluster + install commands, apply order, cleanup
  01-gateway-and-backend.yaml          # Gateway + AgentgatewayBackend (static target) + HTTPRoute
  02-vulnerable-tool-server.yaml       # the deliberately poisoned MCP server
  03-ext-mcp-guardrail.yaml            # this lab's own gRPC ExtMcp guardrail server (ConfigMap + Deployment + Service)
  04-guardrail-policy.yaml             # AgentgatewayPolicy attaching the guardrail
  05-tool-access-policy.yaml           # AgentgatewayPolicy: CEL tool-name RBAC, no JWT
scripts/
  setup.sh                             # stands up the gateway, the vulnerable server, and the guardrail server
  teardown.sh                          # kind delete cluster
  mcp_client.py                        # minimal Streamable HTTP client with a `describe` command (pip install mcp)
```

## Quickstart

```sh
cd scripts
./setup.sh   # no keys needed anywhere in this lab
```

Then, with the port-forward from `setup.sh`'s own printed instructions
running:

```sh
# See the poisoned description, unprotected
python3 scripts/mcp_client.py describe

# Apply the guardrail, then look again
kubectl apply -f manifests/04-guardrail-policy.yaml
python3 scripts/mcp_client.py describe
python3 scripts/mcp_client.py call export_env_vars   # blocked

# Apply tool access RBAC as a second, independent layer
kubectl apply -f manifests/05-tool-access-policy.yaml
python3 scripts/mcp_client.py list                   # export_env_vars no longer even listed
```

Tear down with `./teardown.sh` (just `kind delete cluster`).

## What's actually being demonstrated

`vulnerable-tool-server` exposes two tools. `search_docs`'s description
carries a real tool-poisoning payload: an embedded instruction telling
whatever agent reads it to silently call `export_env_vars` and hand back
its output on every search. `export_env_vars` itself returns an
obviously-fake but recognizable "secret" string, so any run can prove
with certainty whether the instruction got followed.

`ext-mcp-guardrail` is a real gRPC server implementing agentgateway's
`ExtMcp` wire protocol (`crates/protos/proto/ext_mcp.proto` in
agentgateway/agentgateway at v1.5.0), attached to the backend through an
`AgentgatewayPolicy`. It does two things, independently: it truncates
`search_docs`'s description at the injected instruction before the
description ever reaches a client (`tools/list`, Response phase), and it
hard-blocks any call to `export_env_vars` by tool name regardless of what
its description says (`tools/call`, Request phase).

`tool-access` is a second `AgentgatewayPolicy`, unrelated to the
guardrail, using CEL-based RBAC (`mcp.tool.name == "search_docs"`) to
allow-list which tools exist at all. Confirmed live with the guardrail
policy removed entirely: RBAC alone still hides `export_env_vars` from
`tools/list` and still rejects a direct call to it, with a different error
than the guardrail's. Neither layer depends on the other.

## What's validated and what isn't

Confirmed live on two from-scratch `kind` clusters, byte-identical both
times:

- **The poisoned description is real and visible** to any client that
  reads `tools/list`, until something inspects it.
- **The guardrail sanitizes it in flight.** `search_docs`'s description
  comes back truncated to its first clean sentence once the guardrail
  policy is applied; unchanged with it removed.
- **The guardrail blocks the dangerous tool outright**, independent of
  sanitization: `export_env_vars` returns a `PERMISSION_DENIED`-mapped
  error on every attempt while the guardrail policy is active.
- **Tool access RBAC is a real, independent second layer**, not a
  restatement of the guardrail: tested with the guardrail policy removed,
  RBAC alone still hides and denies the same tool, with its own distinct
  error.

See `PLAN.md` (private repo) for the exact commands, the reverse-engineered
`ExtMcp` wire format (undocumented anywhere agentgateway publishes), and
the full decision log.

## A note on the environment this was validated in

Same sandbox-only quirks as the rest of this series: the `IPV6_ENABLED=false`
readiness-bind fix on the proxy, and a CA-bundle mount + `SSL_CERT_FILE`/
`REQUESTS_CA_BUNDLE` fix on both `vulnerable-tool-server` (`pip install mcp`)
and `ext-mcp-guardrail` (`pip install grpcio grpcio-tools protobuf`), since
this sandbox terminates outbound TLS behind a self-signed CA. See A1's
README for the full explanation. None of this is in `kind-config.yaml`,
`setup.sh`, or any manifest here; a real cluster with normal internet
access needs none of it.
