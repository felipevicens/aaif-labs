# Two Agents, One Handshake: A2A in Practice — lab

Companion manifests for the post **"Two Agents, One Handshake: A2A in
Practice"** (E1). Runs two real `a2a-sdk` agent servers behind
agentgateway, each as its own `AgentgatewayBackend{a2a}` + `HTTPRoute`
pair, and stacks a generic traffic policy on one of them to show that
agentgateway's A2A support is routing and telemetry, not an A2A-aware
policy engine.

## Layout

```
kind-config.yaml                       # kind node image pin (v1.34.0)
manifests/
  00-cluster-and-install.md            # exact cluster + install commands, apply order, cleanup
  01-gateway-and-backends.yaml         # Gateway + two AgentgatewayBackend{a2a} + two HTTPRoutes (URLRewrite)
  02-agent-a.yaml                      # namespace + "Hello World Agent" (real a2a-sdk==1.1.2 server)
  03-agent-b.yaml                      # "Loud Agent" (uppercased output, same shape)
  04-rate-limit-policy.yaml            # AgentgatewayPolicy: traffic.rateLimit.local, agent-b only
scripts/
  setup.sh                             # stands up the gateway and both agents
  teardown.sh                          # kind delete cluster
  a2a_client.py                        # minimal stdlib-only A2A v1.0 JSON-RPC client
  fire_requests.sh                     # fires N SendMessage calls at agent-b, classifies OK/RATE_LIMITED
```

## Quickstart

```sh
cd scripts
./setup.sh
```

Then, with the port-forward from `setup.sh`'s own printed instructions
running, see `manifests/00-cluster-and-install.md` for the full command
sequence covering all four scenarios (routing + card rewrite, a
non-streaming task call, a streaming task call, and the stacked
rate-limit policy).

Tear down with `./teardown.sh` (just `kind delete cluster`).

## What's actually being demonstrated

`AgentgatewayBackend.spec.a2a` is a single `{host, port}` pair, not a
`targets` list like `mcp` — one backend per agent, which is why this lab
runs two of everything instead of one backend fronting two upstreams.
Unlike `ai`/`mcp`, the CRD has no admission rule requiring a matching
`AgentgatewayPolicy` type; an `a2a` backend works standalone.

Two things agentgateway actually does with A2A traffic: it rewrites the
agent card served at `/.well-known/agent-card.json` (replacing
`supportedInterfaces[].url`, the v1.0 field, with a gateway-reachable
URL instead of the agent's own in-cluster DNS name), and it inspects the
JSON-RPC method and response shape for telemetry only
(`a2a.method`, `a2a.response.outcome`, `a2a.task.state`,
`a2a.context.id`). Task execution, SSE streaming, and any auth handshake
pass straight through untouched.

There is no A2A-specific authorization or rate-limiting: a generic
`traffic.rateLimit` (the same policy family D6 used for MCP) applies to
an `a2a` backend as a plain route-level policy, with no visibility into
A2A method names or task state. Scenario 4 stacks it on agent-b's
`HTTPRoute` only, leaving agent-a as a live control to prove the block
is the policy and not the gateway or the agent itself.

## Real a2a-sdk mechanics, confirmed by running the actual package

Found by running the real published `a2a-sdk==1.1.2` against the
official `helloworld` sample, not by reading its docs:

- **`sse_starlette` is a real dependency that `pip install a2a-sdk` does
  not pull in automatically.** The sample code's SSE response path
  imports it directly; omit it and the server fails at import time.
- **The JSON-RPC method name is `SendMessage` / `SendStreamingMessage`**
  (proto-derived CamelCase), not `message/send`-style naming — that
  belongs to A2A's separate REST binding, a different HTTP surface
  entirely.
- **The message payload's text goes in `parts: [{"text": "..."}]`, not
  `content`.**
- **The `A2A-Version` HTTP header selects the protocol version
  per-request, not the payload shape.** Miss the header and this SDK
  version silently assumes `0.3`, then rejects the call with a confusing
  `-32009 VERSION_NOT_SUPPORTED` error that has nothing to do with
  whether the request body itself was correct — this SDK's handler only
  implements v1.0.

`scripts/a2a_client.py` gets all four right on purpose, so the post's
`curl`/Python examples aren't guessed from documentation.

## What's validated and what isn't

See `PLAN.md` (private repo) for the exact commands, the CRD schema
findings, and the full decision log. The local (non-cluster) mechanics
above were confirmed by running the real `a2a-sdk` package directly
against a hand-run `helloworld` agent before any manifest was written.
Cluster-level behavior (the agent-card rewrite, telemetry fields, the
rate-limit interaction) needs its own from-scratch validation pass, twice,
per this series' standing methodology — see `PLAN.md` for whether that
pass has completed yet.

Deliberately **not** built or live-tested here, named as real risks in
the post's Gotchas section instead: the `aws` A2A backend type, an
authenticated extended agent card, and multi-cluster agent federation —
no such feature exists in the source as of agentgateway 1.5.0.

## A note on the environment this was validated in

Same sandbox-only quirks as the rest of this series: the
`IPV6_ENABLED=false` readiness-bind fix on the proxy, and the
image-preload workaround for `kind load docker-image` on this session's
containerd-snapshotter Docker. See A1's README for the full explanation.
None of this is in `kind-config.yaml`, `setup.sh`, or any manifest here;
a real cluster with normal internet access needs none of it.
