# Following One Request End to End: Tracing With Tempo — lab

Companion manifests for the post **"Following One Request End to End:
Tracing With Tempo"** (G1). Turns on distributed tracing for an
agentgateway Gateway with a single `AgentgatewayPolicy`, sends one plain
HTTP request and one LLM-shaped request through it, and follows both into
Grafana Tempo to see exactly which span attributes agentgateway attaches
to each.

## Layout

```
kind-config.yaml                    # kind node image pin (v1.34.0)
manifests/
  00-cluster-and-install.md         # exact cluster + install + trace-following commands
  01-namespace-and-backend.yaml     # httpbun + Gateway + HTTPRoute (/good)
  02-ai-backend-and-route.yaml      # AgentgatewayBackend + HTTPRoute (/chat, LLM-shaped)
  03-tracing-policy.yaml            # AgentgatewayPolicy turning tracing on for the Gateway
scripts/
  setup.sh                          # stands up the cluster, agentgateway, and Tempo
  teardown.sh                       # kind delete cluster
```

## Quickstart

```sh
cd scripts
./setup.sh
```

Then see `manifests/00-cluster-and-install.md` for the full request/trace
walkthrough. Tear down with `./teardown.sh`.

## What's actually being demonstrated

Tracing in agentgateway is configured entirely through one
`AgentgatewayPolicy` (`spec.frontend.tracing`), not a Helm value or a
Gateway-level field. Its `backendRef` just needs to be OTLP-compatible -
this lab points it straight at Tempo's own OTLP gRPC receiver, skipping
the separate OTel Collector the docs' full observability-stack walkthrough
installs (that full stack, with Loki and Prometheus too, is closer to what
G2 needs).

The same Gateway, same tracing policy, same backend pod, but two request
shapes: `/good` is a plain HTTP route, `/chat` goes through an
`AgentgatewayBackend` mocked as an OpenAI provider. Their traces in Tempo
differ: the LLM-shaped request's spans carry extra `gen_ai.*` attributes
(`gen_ai.request.model`, `gen_ai.usage.input_tokens`, and so on) that the
plain HTTP request's spans never get.

## What's validated and what isn't

See `PLAN.md` (private repo) for the exact commands and the full decision
log. All scenarios are live-validated end to end, twice, from independent
clusters built from scratch.

## A note on the environment this was validated in

Same sandbox-only quirks as the rest of this series (see A1's README for
the full explanation): the `IPV6_ENABLED=false` readiness-bind fix on the
proxy (applied reactively via `kubectl set env`, never baked into
`setup.sh`), and importing images directly into the kind node's
containerd rather than relying on the sandbox's proxy-blocked image pulls.
None of this is in `kind-config.yaml`, `setup.sh`, or any manifest here; a
real cluster with normal internet access needs none of it.
