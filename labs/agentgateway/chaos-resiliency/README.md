# Chaos on Purpose — lab

Companion manifests for the post **"Chaos on Purpose: Fault Injection,
Retries and Timeouts"** (H3). Demonstrates three resiliency mechanisms
against a single, fully deterministic httpbun backend: gateway-injected
fault delay, native Gateway API retry on a failing status code, and a
per-try timeout paired with retries against a slow backend.

## Layout

```
kind-config.yaml                       # kind node image pin (v1.34.0)
manifests/
  01-namespace-and-backend.yaml        # resiliency namespace, httpbun backend, shared Gateway
  02-route-fault.yaml                  # 1s request timeout, no retry
  03-fault-injection-policy.yaml       # injects a fixed 2s delay
  04-route-retry.yaml                  # retry on 500, 3 attempts, against /status/500
  05-route-pertry.yaml                 # retry on 504, 3 attempts, against /delay/5
  06-pertry-timeout-policy.yaml        # 1s per-try timeout on chaos-pertry
scripts/
  setup.sh                             # stands up the cluster and applies every manifest in order
  teardown.sh                          # kind delete cluster
```

## Quickstart

```sh
cd scripts
./setup.sh
```

Then port-forward the gateway and run the three curls printed at the end
of `setup.sh`'s output. Tear down with `./teardown.sh`.

## What's actually being demonstrated

Three independent scenarios, each on its own `HTTPRoute`, all against
the same httpbun backend using its fixed-behavior endpoints
(`/get`, `/status/500`, `/delay/5`) so every result is deterministic:
no real flaky backend needed to test any of this.

1. **Fault injection**: an `AgentgatewayPolicy`'s `traffic.delay`
   injects artificial latency at the gateway, independent of how fast
   the real backend answers.
2. **Retry**: the native `HTTPRoute.spec.rules[].retry` field resends a
   failing request against a configured list of status codes.
3. **Per-try timeout**: an `AgentgatewayPolicy`'s
   `traffic.timeouts.request`, paired with a route that already has a
   retry policy, bounds each individual attempt rather than the whole
   request.

## What's validated and what isn't

See `PLAN.md` (private repo) for the exact commands and the full
decision log. Every scenario in the post is live-validated end to end,
twice, from independent clusters built from scratch, including a
genuinely surprising result: a per-try timeout paired with a
`codes`-based retry policy does not trigger a retry when the timeout
itself is what fails the request. Nothing here is doc-sourced only.

## A note on the environment this was validated in

Same sandbox-only quirks as the rest of this series (see A1's README
for the full explanation): the `IPV6_ENABLED=false` readiness-bind fix
on the proxy (applied reactively via `kubectl set env`, never baked
into `setup.sh`), and importing images directly into the kind node's
containerd rather than relying on the sandbox's proxy-blocked image
pulls. None of this is in `kind-config.yaml`, `setup.sh`, or any
manifest here; a real cluster with normal internet access needs none of
it.
