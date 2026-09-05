# What to Alert On (and What to Ignore) — lab

Companion manifests for the post **"What to Alert On (and What to
Ignore)"** (G4). Live-validated: three genuinely distinct failure layers
in agentgateway — a Kubernetes-resource-status failure, a real xDS-layer
policy rejection (a NACK), and an ordinary noisy backend failure — each
with a different real signal, and a different answer to whether it's
worth paging on.

## Layout

```
kind-config.yaml                    # kind node image pin (v1.34.0)
manifests/
  00-cluster-and-install.md         # exact cluster + install + scenario commands
  01-namespace-and-backend.yaml     # httpbun + Gateway + HTTPRoute (/good and /flaky)
  02-broken-route.yaml              # HTTPRoute pointing at a nonexistent Service
  03-broken-health-policy.yaml      # AgentgatewayPolicy with a syntactically broken CEL expression
scripts/
  setup.sh                          # stands up the baseline cluster
  teardown.sh                       # kind delete cluster
```

## Quickstart

```sh
cd scripts
./setup.sh
```

Then see `manifests/00-cluster-and-install.md` for the full scenario
commands. Tear down with `./teardown.sh`.

## What's actually being demonstrated

A resource that "looks fine" in `kubectl` is not the same thing as a
resource the dataplane actually applied, and a request that returns a
500 is not automatically a gateway problem:

- **Kubernetes-resource layer** (`02-broken-route.yaml`): a route pointing
  at a Service that doesn't exist. Surfaces immediately as
  `ResolvedRefs: False, reason: BackendNotFound` on the route's own
  status — no traffic, no metrics endpoint, no proxy logs needed.
- **xDS/NACK layer** (`03-broken-health-policy.yaml`): a policy that
  passes Kubernetes admission and controller reconciliation cleanly (it's
  just a CEL string), but that agentgateway itself rejects when it tries
  to compile the expression. The resource status still says
  `Accepted: "True"` — the real signal is the `reason: PartiallyValid`
  and the message next to it, plus a genuine `agentgateway_xds_rejects_total`
  Prometheus counter and a `Nack` line in the proxy's own logs.
- **Dataplane / live-request layer** (the `/flaky` route in
  `01-namespace-and-backend.yaml`): a perfectly valid route to a backend
  that always answers 500. Nothing about the gateway configuration is
  wrong here at all — this is the noisy layer, and `agentgateway_requests_total`'s
  `reason` label (`Upstream` vs `NotFound`) is what actually distinguishes
  it from the first layer at the metrics level.

## What's validated and what isn't

See `PLAN.md` (private repo) for the exact commands and the full decision
log, including the doc-research dead ends before the real metric names and
status shapes were confirmed live. All three scenarios are live-validated
end to end, twice, from independent clusters built from scratch.

## A note on the environment this was validated in

Same sandbox-only quirks as the rest of this series (see A1's README for
the full explanation): the `IPV6_ENABLED=false` readiness-bind fix on the
proxy (applied reactively via `kubectl set env`, never baked into
`setup.sh`), and importing images directly into the kind node's
containerd rather than relying on the sandbox's proxy-blocked image pulls.
None of this is in `kind-config.yaml`, `setup.sh`, or any manifest here; a
real cluster with normal internet access needs none of it.
