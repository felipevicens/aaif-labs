# Exporting Traces to Datadog, Honeycomb and Grafana Cloud — lab

Companion manifests for the post **"Exporting Traces to Datadog,
Honeycomb and Grafana Cloud"** (G3). Demonstrates the one structural rule
behind all three vendor guides: whether a tracing backend needs an OTel
Collector in front of agentgateway depends entirely on whether that
backend requires an HTTP header agentgateway's own tracing policy can't
send.

## Layout

```
kind-config.yaml                       # kind node image pin (v1.34.0)
manifests/
  00-cluster-and-install.md            # exact cluster + install + walkthrough commands
  01-namespace-and-backend.yaml        # httpbun + Gateway + HTTPRoute (/good)
  02-fake-vendor.yaml                  # header-checking stand-in for a SaaS trace backend
  03-tracing-policy-direct.yaml        # Scenario 1: AgentgatewayPolicy straight to Tempo
  04-otel-collector-values.yaml        # Helm values: OTel Collector with a header-injecting exporter
  05-tracing-policy-collector.yaml     # Scenario 2: AgentgatewayPolicy through the collector
scripts/
  setup.sh                             # stands up the cluster, agentgateway, Tempo, and the collector
  teardown.sh                          # kind delete cluster
```

## Quickstart

```sh
cd scripts
./setup.sh
```

Then see `manifests/00-cluster-and-install.md` for the full walkthrough.
Tear down with `./teardown.sh`.

## What's actually being demonstrated

`AgentgatewayPolicy.spec.frontend.tracing` has no field for custom HTTP
headers. That's fine for a destination that accepts anonymous OTLP on
its own network, structurally the same as this lab's Scenario 1
(straight to Tempo) and the same shape the real Datadog Agent guide
uses, since the Agent handles auth once at install time via a
`Secret`-backed API key, not per request.

It's a hard blocker for Honeycomb and Grafana Cloud, which both require
a header on every OTLP call (`x-honeycomb-team`, `Authorization`). Their
real docs both route through an OTel Collector that injects the header
before forwarding. Scenario 2 reproduces that exact mechanism without
needing a real vendor account: a real OTel Collector injects a fake
header, and a small Python HTTP server (`fake-vendor`) proves whether it
actually arrived.

## What's validated and what isn't

See `PLAN.md` (private repo) for the exact commands and the full decision
log. All scenarios are live-validated end to end, twice, from independent
clusters built from scratch. The real Datadog/Honeycomb/Grafana Cloud
endpoints themselves are not tested here, since that would need a real
paid account of each; what's tested is the mechanism their own docs
describe, using a lab-owned backend as the stand-in.

## A note on the environment this was validated in

Same sandbox-only quirks as the rest of this series (see A1's README for
the full explanation): the `IPV6_ENABLED=false` readiness-bind fix on the
proxy (applied reactively via `kubectl set env`, never baked into
`setup.sh`), and importing images directly into the kind node's
containerd rather than relying on the sandbox's proxy-blocked image pulls.
None of this is in `kind-config.yaml`, `setup.sh`, or any manifest here; a
real cluster with normal internet access needs none of it.
