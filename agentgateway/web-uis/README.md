# Open WebUI, LibreChat and kagent Against One Gateway — lab

Companion manifests for the post **"Open WebUI, LibreChat and kagent
Against One Gateway"** (E2). Deploys three unrelated AI front-ends — two
chat UIs and one Kubernetes-native agent framework — configured
identically to point at one `AgentgatewayBackend`/`HTTPRoute` pair, then
stacks one `AgentgatewayPolicy` on that shared route to show it governs
all three the same way, with zero per-app policy config.

## Layout

```
kind-config.yaml                          # kind node image pin (v1.34.0)
manifests/
  00-cluster-and-install.md               # exact cluster + install commands, apply order, cleanup
  01-gateway-and-mock-backend.yaml        # namespace, Gateway, mock OpenAI-compatible model server,
                                           #   the one shared AgentgatewayBackend + HTTPRoute
  02-guardrail-policy.yaml                # AgentgatewayPolicy: regex promptGuard, shared route only
  03-open-webui.yaml                      # Open WebUI Deployment + Service
  04-librechat.yaml                       # MongoDB + LibreChat Deployment + Service
  05-kagent-model-and-agent.yaml          # kagent ModelConfig (BYO OpenAI-compatible) + minimal Agent
scripts/
  setup.sh                                # stands up gateway, mock backend, all three front-ends, kagent
  teardown.sh                             # helm uninstall kagent + kind delete cluster
```

## Quickstart

```sh
cd scripts
./setup.sh
```

Then see `manifests/00-cluster-and-install.md` for the full port-forward
and scenario commands: the shared backend directly, each front-end's own
request shape, kagent's `invoke` CLI, and applying the shared guardrail
policy to see it reject the same trigger word identically across all
three.

Tear down with `./teardown.sh`.

## What's actually being demonstrated

Open WebUI, LibreChat, and kagent are three architecturally different
kinds of AI consumer — two browser-first chat UIs and one Kubernetes
agent framework with its own CRDs and CLI — but all three turn out to
speak the exact same OpenAI-compatible wire protocol when configured
correctly. kagent's own docs default to a native Ollama `ModelConfig`,
which would have needed a second mock protocol; its separate "BYO
OpenAI-compatible model" path (`provider: OpenAI` + `openAI.baseUrl`)
avoids that entirely. That's what lets all three share one
`AgentgatewayBackend` here with no protocol translation anywhere.

A bodyless `GET /v1/models` does **not** work against this host/port/path
-overridden `openai` backend — agentgateway's own LLM-request pipeline
rejects it before it ever reaches the mock (`400`, `EOF while parsing a
value`). None of the three apps need it here (LibreChat's config sets
`fetch: false`; Open WebUI tolerates a non-200 probe at startup), but it's
worth knowing before you assume agentgateway synthesizes that endpoint for
you. See `PLAN.md` and the post's Gotchas for the live-confirmed detail.

The mock model server (`01-gateway-and-mock-backend.yaml`) exists because
this lab's three consumers actually parse the response body, unlike A1's
httpbun echo scenario: it returns real `choices[].message.content` JSON
(and a matching SSE-chunk shape when `stream: true`), and ignores
`tools`/`tool_choice` fields rather than erroring on them, since kagent
sends `tool_choice: auto` on every request regardless of whether the
agent declares tools.

## What's validated and what isn't

See `PLAN.md` (private repo) for the exact commands and the full decision
log. This lab validates through direct API/CLI calls using each app's own
request shape (confirmed against each app's actual documented
configuration), plus kagent's scriptable `invoke` CLI, rather than a full
interactive browser session inside Open WebUI or LibreChat — consistent
with how every post in this series validates, and called out explicitly
here so it isn't overclaimed as "clicked through in three browsers."
Whether the from-scratch, twice-from-zero cluster pass this series
requires before publication has completed is tracked in `PLAN.md`.

## A note on the environment this was validated in

Same sandbox-only quirks as the rest of this series: the
`IPV6_ENABLED=false` readiness-bind fix on the proxy, and the
image-preload workaround for `kind load docker-image` on this session's
containerd-snapshotter Docker (needed here for more images than usual —
agentgateway, the mock server, Open WebUI, MongoDB, LibreChat, and
kagent's own chart). See A1's README for the full explanation. None of
this is in `kind-config.yaml`, `setup.sh`, or any manifest here; a real
cluster with normal internet access needs none of it.

Two extras specific to this lab's disk footprint, also sandbox-only: (1)
a `:latest`-tagged image already imported into the node still triggers a
real pull attempt on pod start (Kubernetes defaults `imagePullPolicy` to
`Always` for `latest`), fixed live with `kubectl patch ... imagePullPolicy:
IfNotPresent` rather than baked into the manifest; (2) this session's
accumulated disk usage from earlier, unrelated labs meant the three
front-ends had to be validated one at a time (deploy, validate, tear down,
next) instead of all at once as `setup.sh` does — a normal environment
doesn't need this. Also worth knowing: `kagent invoke` (CLI v0.10.0) has a
client-side response-decode bug that fails on every call, including ones
that succeed server-side — not sandbox-specific, a real CLI bug. The
lab's scenario commands show the direct A2A curl call as the way to see
the actual result; see `PLAN.md` for the full finding.
