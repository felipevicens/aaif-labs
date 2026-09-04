# Serving Your Own Model Like a Real Provider — lab

Companion manifests for the post **"Serving Your Own Model Like a Real
Provider"** (A5), the fifth post in the multi-provider LLM gateway series,
depending on A4. The first lab in this series backed by a real model
instead of a mock: a local Ollama server, aliased under client-facing
names via `AgentgatewayModel`, both directly (Scenario A) and split across
two real models with a weighted virtual model (Scenario B).

## Layout

```
kind-config.yaml                            # kind node image pin (v1.34.0)
manifests/
  00-cluster-and-install.md                 # exact cluster + install commands, apply order, cleanup
  01-gateway-and-ollama.yaml                 # Gateway + a real Ollama Deployment/Service (two tiny models)
  02-alias-real-provider-name.yaml           # Scenario A: gpt-4 alias, exact-match AgentgatewayModel
  03-weighted-virtual-model.yaml             # Scenario B: gpt-4-turbo, virtualModel.weighted across two real models
scripts/
  setup.sh                  # stands the whole thing up
  teardown.sh                # kind delete cluster
```

## Quickstart

```sh
cd scripts
./setup.sh   # no keys needed anywhere in this lab
```

Or follow `manifests/00-cluster-and-install.md` by hand for the exact
commands and apply order. Either way, reach the gateway with a
port-forward (kind's `LoadBalancer` Service for `agentgateway-proxy` stays
`<pending>`, there's no LB provider on kind):

```sh
kubectl port-forward -n agentgateway-system svc/agentgateway-proxy 8080:8080
```

Tear down with `./teardown.sh` (just `kind delete cluster`).

## What's validated and what isn't

- **All three manifests are live-validated** against a real `kind` cluster
  (agentgateway `1.5.0` with `agentgatewayModels.enabled=true`, Gateway API
  `1.6.0` experimental channel, Ollama `0.33.3`, models `smollm2:135m` and
  `qwen2.5:0.5b`), **twice from scratch**, with real `curl` requests
  against a real, non-mocked model. No GPU anywhere: both models are
  sub-1B-parameter and run comfortably on CPU.
  - **Scenario A** (`gpt-4` alias): `POST /v1/chat/completions` with
    `"model": "gpt-4"` returns a real, generated completion. The response's
    own `model` field reads `smollm2:135m`, not `gpt-4`, because Ollama
    echoes back whatever tag it actually ran, proof the alias reached a
    real backend and not a passthrough. Requesting a model that was never
    created returns the same `model_not_found` error shape a real hosted
    provider would give.
  - **Scenario B** (`gpt-4-turbo`, weighted 70/30): twenty requests in a
    row, tallied by the `model` field each target rewrites. Two real runs:
    16/4 and 17/3 between `smollm2:135m` and `qwen2.5:0.5b`, both closer to
    80/20 than the configured 70/30, expected noise from a small sample.
- Startup is slower than every other lab in this series: the Ollama
  container pulls two real models before it reports ready, worth budgeting
  a few minutes for `01-gateway-and-ollama.yaml` to apply cleanly, not the
  seconds every mocked backend in A1-A4 took.

## A note on the environment this was validated in

Same sandbox-only quirks as A1-A4's labs (the `oom_score_adj` node-image
fix and the `IPV6_ENABLED=false` readiness-bind fix, plus A4's
`kind load docker-image` workaround for images the sandbox's own egress
proxy can't reach from inside a kind node). See A1's README for the full
explanation. One more, specific to this lab: `ollama pull` inside the pod
fails TLS verification for the same underlying reason (the pod can't reach
the sandbox's own egress proxy, so it can't trust its CA either). Worked
around by pulling both models on the host, where the proxy and its CA are
already configured, and injecting the resulting blobs into the running
pod with `kubectl cp` (which, unlike `docker cp` into the kind node
container, works fine in this sandbox). None of this is in
`kind-config.yaml`, `setup.sh`, or the manifests here; real clusters with
normal internet access need none of it.

See `PLAN.md` (private repo) for the full decision log and CRD facts this
lab was built from.
