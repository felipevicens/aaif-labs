# Canary-Deploying a New Model Version — lab

Companion manifests for the post **"Canary-Deploying a New Model
Version"** (H5). Demonstrates a full canary rollout using nothing but
the native Gateway API `weight` field on `HTTPRoute` `backendRefs`: no
AI-specific policy, no `AgentgatewayPolicy` at all, just Kubernetes
traffic splitting applied to two "model server" versions.

## Layout

```
kind-config.yaml                        # kind node image pin (v1.34.0)
manifests/
  01-namespace-and-backends.yaml        # canary namespace, two identical httpbun backends, shared Gateway
  02-route-canary-95-5.yaml             # stage 1: 95% stable, 5% canary
  03-route-canary-50-50.yaml            # stage 2: promoted to an even split
  04-route-canary-0-100.yaml            # stage 3: full cutover to the new version
scripts/
  setup.sh                              # stands up the cluster and applies stage 1
  teardown.sh                           # kind delete cluster
```

## Quickstart

```sh
cd scripts
./setup.sh
```

Then port-forward the gateway, send a batch of requests, and tally each
backend's own access log (commands printed at the end of `setup.sh`'s
output). Promote the canary by applying `03-route-canary-50-50.yaml`,
then cut over fully with `04-route-canary-0-100.yaml`. Tear down with
`./teardown.sh`.

## What's actually being demonstrated

Two identical httpbun Deployments stand in for "model server v1
(stable)" and "model server v2 (canary)". One `HTTPRoute` splits traffic
between them by `weight`, and every stage of the rollout is just a
`kubectl apply` of the same route object with new numbers, no restart of
either backend. The route's `URLRewrite` filter is rule-level, so both
backends return an identical response regardless of which one actually
answered: a well-behaved canary is invisible to the client, and the
split is verified from the backend side (`kubectl logs`), not by
inspecting response bodies.

## What's validated and what isn't

See `PLAN.md` (private repo) for the exact commands and the full
decision log. Every stage in the post is live-validated end to end,
twice, from independent clusters built from scratch: real request
batches, tallied against each backend's own request log, confirming the
split converges toward the configured ratio as the sample grows.

## A note on the environment this was validated in

Same sandbox-only quirks as the rest of this series (see A1's README
for the full explanation): the `IPV6_ENABLED=false` readiness-bind fix
on the proxy (applied reactively via `kubectl set env`, never baked
into `setup.sh`), and importing images directly into the kind node's
containerd rather than relying on the sandbox's proxy-blocked image
pulls. None of this is in `kind-config.yaml`, `setup.sh`, or any
manifest here; a real cluster with normal internet access needs none of
it.
