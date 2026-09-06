# Testing Without Burning a Token — lab

Companion manifests for the post **"Testing Your AI App Without Burning
a Single Token"** (H4). Demonstrates mocking an entire AI backend at the
gateway with `directResponse`, so a test suite can hit the app's real
route and get back canned, instant, zero-cost responses without any
`AIBackend`, any real provider, or any backend at all existing anywhere
in the lab.

## Layout

```
kind-config.yaml                       # kind node image pin (v1.34.0)
manifests/
  01-namespace-and-gateway.yaml        # mock-testing namespace (no backend), shared Gateway
  02-route.yaml                        # HTTPRoute with zero backendRefs
  03-mock-policy.yaml                  # conditional directResponse: ratelimit / error / default
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

One `HTTPRoute` with no `backendRefs` at all, answered entirely by an
`AgentgatewayPolicy`'s `traffic.directResponse`. The `conditional` field
turns one policy into a first-match-wins list: an `X-Mock-Scenario`
request header picks between a simulated rate limit (`429`), a simulated
server error (`500`), and a fallback mocked chat-completion body (`200`)
when no header is sent. No `AIBackend`, no real provider, no network hop
past the gateway itself.

## What's validated and what isn't

See `PLAN.md` (private repo) for the exact commands and the full
decision log. Every scenario in the post is live-validated end to end,
twice, from independent clusters built from scratch, including a
genuinely useful finding: a `directResponse` reply carries no
`content-type` header at all, on any scenario, on either run. Nothing
here is doc-sourced only.

## A note on the environment this was validated in

Same sandbox-only quirks as the rest of this series (see A1's README
for the full explanation): the `IPV6_ENABLED=false` readiness-bind fix
on the proxy (applied reactively via `kubectl set env`, never baked
into `setup.sh`), and importing images directly into the kind node's
containerd rather than relying on the sandbox's proxy-blocked image
pulls. None of this is in `kind-config.yaml`, `setup.sh`, or any
manifest here; a real cluster with normal internet access needs none of
it.
