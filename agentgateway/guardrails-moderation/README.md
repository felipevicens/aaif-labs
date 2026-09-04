# Moderation as a Gateway Policy, Not App Code — lab

Companion manifests for the post **"Moderation as a Gateway Policy, Not
App Code"** (B3), the third post in the guardrails series. Covers the
`openAIModeration` guard type B1 documented YAML-only and deferred here,
against `AgentgatewayPolicy.spec.backend.ai.promptGuard`.

**This is the one lab in this series that isn't fully keyless.** The
guard makes its own real call to OpenAI's moderation endpoint, which has
no `baseURL` override and no keyless substitute anywhere in agentgateway's
own docs. The route's own LLM backend still stays keyless, httpbun.

## Layout

```
kind-config.yaml                     # kind node image pin (v1.34.0)
manifests/
  00-cluster-and-install.md         # exact cluster + install commands, apply order, cleanup
  01-gateway-and-backend.yaml        # Gateway + httpbun (the route's own backend, keyless)
  02-moderation-secret.yaml          # the real credential, applied via envsubst, never committed
  03-moderation-policy.yaml          # the openAIModeration guard itself
scripts/
  setup.sh                  # stands the whole thing up (needs OPENAI_API_KEY set)
  teardown.sh                # kind delete cluster
```

## Quickstart

```sh
export OPENAI_API_KEY="sk-..."
cd scripts
./setup.sh
```

Or follow `manifests/00-cluster-and-install.md` by hand for the exact
commands and apply order. Either way, reach the gateway with a
port-forward (kind's `LoadBalancer` Service for `agentgateway-proxy` stays
`<pending>`, there's no LB provider on kind):

```sh
kubectl port-forward -n agentgateway-system svc/agentgateway-proxy 8080:8080
```

Tear down with `./teardown.sh` (just `kind delete cluster`, which also
destroys the `openai-secret` Secret). Rotate the key itself afterward
regardless.

## What's validated and what isn't

- **All three manifests are live-validated** against a real `kind`
  cluster (agentgateway `1.5.0`, Gateway API `1.6.0` standard channel),
  **twice from scratch**, using a real OpenAI API key with moderation
  access.
  - A clean request passes the guard and reaches httpbun (`200`).
  - A request with genuinely flaggable content gets scored by OpenAI's
    real moderation model and rejected (`403`, the guard's own
    `response.message`).
- The Secret's key convention (`stringData.Authorization`, a bare key
  with `Bearer ` stripped automatically) is inherited from the
  `multi-provider` lab's already-validated `BackendAuth.secretRef`
  pattern, since the moderation docs page itself doesn't spell it out.
  This lab's own live validation is what confirms it also works for
  `openAIModeration`'s nested `policies.auth.secretRef`.

## A note on the environment this was validated in

Same sandbox-only quirks as A1-B2's labs (the `oom_score_adj` node-image
fix and the `IPV6_ENABLED=false` readiness-bind fix). See A1's README for
the full explanation. None of this is in `kind-config.yaml`, `setup.sh`, or
the manifests here; real clusters with normal internet access need none of
it.

This lab needed one more, new to this post: the sandbox this was validated
in intercepts outbound HTTPS transparently, including from inside the
`kind` node, not just the host shell. The `agentgateway-proxy` pod's own
minimal image doesn't trust that interception's CA, so its real call to
`api.openai.com` failed certificate validation (`invalid peer certificate:
UnknownIssuer`) until a trusted CA bundle was mounted into the Deployment
by hand for testing. A real cluster with normal, non-intercepted internet
access needs none of this either.

See `PLAN.md` (private repo) for the full decision log and CRD facts this
lab was built from.
