# Logs That Actually Explain What the Model Said — lab

Companion manifests for the post **"Logs That Actually Explain What the
Model Said"** (G2). Demonstrates that agentgateway's access-log policy can
put the actual prompt and completion text into a structured log line, sent
to Loki over OTLP, not just cost and token counts.

## Layout

```
kind-config.yaml                       # kind node image pin (v1.34.0)
manifests/
  00-cluster-and-install.md            # exact cluster + install + walkthrough commands
  01-namespace-and-backend.yaml        # httpbun-as-OpenAI backend + Gateway + HTTPRoute (/chat)
  02-loki-values.yaml                  # Helm values: Loki, single-binary, filesystem storage
  03-otel-collector-values.yaml        # Helm values: OTel Collector relaying OTLP logs to Loki
  04-access-log-policy.yaml            # AgentgatewayPolicy: ships access logs to the collector
scripts/
  setup.sh                             # stands up the cluster, agentgateway, Loki, and the collector
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

`AgentgatewayPolicy.spec.frontend.accessLog` has three fields: `filter`,
`attributes`, and `otlp`. `attributes.add` accepts arbitrary CEL
expressions, including the `llm.*` variable group's `llm.prompt` and
`llm.completion` — the actual input and output text of the model call, not
just its cost or token counts. `otlp.backendRef` ships every access-log
line to an OTel Collector as OTLP, same resource family G1 and G3 already
used for `frontend.tracing`.

This lab proves the round trip end to end: send a request with a
deterministic mocked completion (via httpbun's `httpbun: {"content": ...}`
field), and confirm that exact text comes back out of a real Loki query.

## What's validated and what isn't

See `PLAN.md` (private repo) for the exact commands and the full decision
log. The full chain — live CRD schema check, mocked-completion round trip
through Loki, the fails-open failure path when the collector reference is
broken, and recovery after fixing it — is live-validated end to end, twice,
from independent clusters built from scratch.

## A note on the environment this was validated in

Same sandbox-only quirks as the rest of this series (see A1's README for
the full explanation): the `IPV6_ENABLED=false` readiness-bind fix on the
proxy (applied reactively via `kubectl set env`, never baked into
`setup.sh`), and importing images directly into the kind node's
containerd rather than relying on the sandbox's proxy-blocked image pulls.
None of this is in `kind-config.yaml`, `setup.sh`, or any manifest here; a
real cluster with normal internet access needs none of it.
