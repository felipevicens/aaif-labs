# Picking the Least-Loaded GPU Automatically — lab

Companion manifests for the post **"Picking the Least-Loaded GPU
Automatically"** (A4), the third long post in the multi-provider LLM
gateway series, depending on A1. Routes to a simulated GPU model server pool
through the Kubernetes Gateway API Inference Extension: agentgateway
implements the gateway side of the protocol, the llm-d Router does the
actual endpoint selection. Two scenarios: the bare quickstart
(`HTTPRoute` straight to an `InferencePool`), and the same pool reached
through an `AgentgatewayBackend` so a token-budget `AgentgatewayPolicy` can
sit on top of it.

## Layout

```
kind-config.yaml                            # kind node image pin (v1.34.0)
manifests/
  00-cluster-and-install.md                 # exact cluster + install commands, apply order, cleanup
  01-simulator-and-gateway.yaml             # llm-d-inference-sim Deployment + Gateway
  02-inferencepool-backend-policy.yaml      # Scenario B: AgentgatewayBackend + HTTPRoute + token-budget AgentgatewayPolicy
scripts/
  setup.sh                  # stands the whole thing up
  teardown.sh                # kind delete cluster
```

The `InferencePool`, the llm-d Router EPP, and Scenario A's `HTTPRoute` are
not manifests in this repo: they come from the external
`llm-d-router-gateway` Helm chart, installed by `setup.sh` /
`00-cluster-and-install.md`.

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

- **Both manifests are live-validated** against a real `kind` cluster
  (agentgateway `1.5.0`, Gateway API `1.6.0` standard channel, Gateway API
  Inference Extension `1.5.0`, llm-d Router chart `v0.9.0`,
  `llm-d-inference-sim` `v0.8.2`), **twice from scratch**, with real `curl`
  requests. No real GPU anywhere: the simulator stands in for a vLLM model
  server the same way httpbun stands in for a real LLM provider elsewhere
  in this series.
  - **Scenario A** (bare quickstart): `POST /v1/completions` against the
    `InferencePool` returns `200 OK`, and the response carries
    `X-Inference-Pod`/`X-Inference-Port` headers naming the exact pod the
    EPP picked, real, literal proof that endpoint selection happened.
  - **Failure path**: scaling the simulator `Deployment` to zero replicas
    and repeating the same request returns a clean `503` (`inference
    error: ServiceUnavailable - failed to find endpoint candidates for
    serving the request`), not a silent hang or a 200 with garbage.
  - **Scenario B** (`AgentgatewayBackend` + `AgentgatewayPolicy` layered on
    the same `InferencePool`): a 100 tokens/minute budget. The simulator's
    completion length is random up to `max_tokens`, so the exact request
    that trips the limit varies between runs, but every run against a
    fresh cluster produces a `429 Too Many Requests` within a handful of
    requests, and recovers to `200` once `x-ratelimit-reset` elapses.
- Two real bugs were caught by this validation, not by review, both now
  documented as header comments / inline notes in the manifests and
  `00-cluster-and-install.md`:
  - The `Gateway`'s listener needs `allowedRoutes.namespaces.from: All`.
    Without it, an `HTTPRoute` in a different namespace than the `Gateway`
    (the router chart's release lives in `default`; this series always
    puts its `Gateway` in `agentgateway-system`) never attaches, and every
    request gets a flat `404 route not found` with no other clue why.
  - The `llm-d-router-gateway` chart's `httpRoute.inferenceGatewayNamespace`
    defaults to `""`, which Gateway API resolves as "the `HTTPRoute`'s own
    namespace," not the `Gateway`'s actual namespace. Same silent
    `404 route not found` symptom until it's set explicitly.

## A note on the environment this was validated in

Same sandbox-only quirks as A1/A2/A3's labs (the `oom_score_adj` node-image
fix and the `IPV6_ENABLED=false` readiness-bind fix), plus one specific to
this lab: pods on the sandbox's `kind` node can't reach the sandbox's own
egress proxy, so every image this lab pulls (`cr.agentgateway.dev/*`,
`ghcr.io/llm-d/*`) had to be pre-pulled on the host and imported into the
node's `containerd` directly, working around a `kind load docker-image`
failure specific to this sandbox (`ctr: content digest ... not found` on a
multi-platform image manifest). See A1's README for the full explanation of
the shared quirks. None of this is in `kind-config.yaml`, `setup.sh`, or the
manifests here.

See `PLAN.md` (private repo) for the full decision log and CRD facts this
lab was built from.
