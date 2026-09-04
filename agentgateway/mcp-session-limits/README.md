# Sessions and Limits: Making MCP Survive Real Traffic — lab

Companion manifests for the post **"Sessions and Limits: Making MCP
Survive Real Traffic"** (D6). Runs an ordinary MCP tool server behind
agentgateway with `sessionRouting: Stateful` spelled out explicitly (the
default), then gates it with a real `AgentgatewayPolicy` local rate limit
and scales the gateway itself to show what "local" actually means.

## Layout

```
kind-config.yaml                       # kind node image pin (v1.34.0)
manifests/
  00-cluster-and-install.md            # exact cluster + install commands, apply order, cleanup
  01-gateway-and-backend.yaml          # Gateway + AgentgatewayParameters (replicas) + AgentgatewayBackend + HTTPRoute
  02-mcp-tool-server.yaml              # an ordinary MCP server, one `ping` tool, no session/rate-limit code of its own
  03-rate-limit-policy.yaml            # AgentgatewayPolicy: traffic.rateLimit.local, two entries
scripts/
  setup.sh                             # stands up the gateway and the tool server
  teardown.sh                          # kind delete cluster
  mcp_client.py                        # minimal Streamable HTTP client (pip install mcp)
  fire_requests.sh                     # fires N requests through the local port-forward, prints OK/RATE_LIMITED per line
  fire_requests_incluster.sh           # same, but from inside the cluster against the Service ClusterIP — use this one for the replica-scaling scenario
```

## Quickstart

```sh
cd scripts
./setup.sh
```

Then, with the port-forward from `setup.sh`'s own printed instructions
running:

```sh
# Basic session mechanic
python3 scripts/mcp_client.py call ping

# Apply the rate-limit policy, then hammer the endpoint
kubectl apply -f manifests/03-rate-limit-policy.yaml
./scripts/fire_requests.sh 15

# Scale the proxy to 2 replicas, fire again — from *inside* the cluster,
# not through the port-forward (see the gotcha below for why)
kubectl patch agentgatewayparameters gateway-scaling -n agentgateway-system \
  --type merge -p '{"spec":{"deployment":{"spec":{"replicas":2}}}}'
./scripts/fire_requests_incluster.sh 20
```

Tear down with `./teardown.sh` (just `kind delete cluster`).

## What's actually being demonstrated

`mcp-tool-server` has no session-handling or rate-limiting code of its
own — the same shape any real internal tool server usually has. Both
features live entirely at the gateway: session routing is
`AgentgatewayBackend.spec.mcp.sessionRouting` (a sibling of `targets`,
not a `traffic`/`AgentgatewayPolicy` concern at all), while rate limiting
is `AgentgatewayPolicy.spec.traffic.rateLimit`, the same policy family
D4/D5 already used for guardrails, tool-access RBAC, and JWT auth.

`traffic.rateLimit.local` is a single in-process token bucket **per proxy
process**, not a global counter — with both replicas starting from a
clean bucket, scaling `agentgateway-proxy` from 1 to 2 replicas doubles
the effective limit before a client sees a blocked call, since each
replica enforces its own bucket independently. Scaling under live
exhaustion is less clean: a newly-created replica starts with a full
bucket, but an already-running replica's bucket doesn't reset just
because you added a sibling, so the *immediate* effect of scaling
depends on how exhausted the existing replica already was. The two-entry
policy (a loose `Seconds`-scale burst allowance plus a tight
`Minutes`-scale ceiling) exists specifically to prove both entries are
enforced, not just the first — agentgateway 1.4 and earlier only honored
the first entry in the list.

A rate-limited MCP call is an HTTP **200**, not a `429` — agentgateway
returns the error as a JSON-RPC object (`code: -32003`) in the response
body. `fire_requests.sh` and `fire_requests_incluster.sh` both check the
body, not just the status code, for exactly that reason.

## What's validated and what isn't

See `PLAN.md` (private repo) for the exact commands, the CRD schema
findings, and the full decision log. In short: confirmed live on two
from-scratch `kind` clusters, byte-identical both times — the basic
session handshake, the local rate limit tripping on a single replica,
both policy entries being enforced independently, and the effective
limit doubling at 2 replicas when both are freshly rolled out.

One real methodology trap found along the way: testing the
replica-scaling scenario through the same `kubectl port-forward` tunnel
used for the earlier scenarios silently hides the effect entirely — a
port-forward to a Service sticks to one pod for the life of the tunnel,
so every request keeps landing on the same already-exhausted replica no
matter how many more you add. `fire_requests_incluster.sh` fires from
inside the cluster against the Service ClusterIP instead, which gets
real per-connection load balancing across replicas.

Deliberately **not** built or live-tested here, named as real risks in
the post's Gotchas section instead: global (Redis-backed) rate limiting,
JWT-claim-scoped CEL rate-limit descriptors and their silent-bypass
failure mode on unauthenticated traffic, and the static-vs-selector
backend-target session-affinity failure mode (which needs a
multi-replica backend to even observe, not just a multi-replica proxy).

## A note on the environment this was validated in

Same sandbox-only quirks as the rest of this series: the
`IPV6_ENABLED=false` readiness-bind fix on the proxy, and the
image-preload workaround for `kind load docker-image` on this session's
containerd-snapshotter Docker. See A1's README for the full explanation.
None of this is in `kind-config.yaml`, `setup.sh`, or any manifest here;
a real cluster with normal internet access needs none of it.
