# Writing Your Own Guardrail Webhook — lab

Companion manifests for the post **"Writing Your Own Guardrail Webhook"**
(B4), the fourth post in the guardrails series. B1 built a thin webhook
just to prove ordering; this lab writes a real one, exercising `Mask`
returned from the webhook itself, the `POST /response` endpoint B1 never
touched, and `failureMode: FailOpen`, against
`AgentgatewayPolicy.spec.backend.ai.promptGuard`.

## Layout

```
kind-config.yaml                     # kind node image pin (v1.34.0)
manifests/
  00-cluster-and-install.md         # exact cluster + install commands, apply order, cleanup
  01-gateway-and-backends.yaml       # Gateway + two mock backends (echo, and prompt-dependent completions)
  02-guardrail-webhook.yaml          # the lab's own webhook, both /request and /response
  03-webhook-policies.yaml           # request-side (FailOpen) + response-side guards, + timeout policy
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

- **All three manifests are live-validated** against a real `kind`
  cluster (agentgateway `1.5.0`, Gateway API `1.6.0` standard channel),
  **twice from scratch**.
  - **Scenario A** (request-side `Mask`): a message containing an
    internal API-key-shaped string comes back with only part of it
    masked, keeping a prefix visible, something a `regex` guard's
    all-or-nothing builtin replacement can't do.
  - **Scenario B** (response-side `Mask`, `POST /response`): a completion
    containing a fabricated internal hostname comes back with that
    hostname redacted, proving the response-side webhook endpoint really
    gets called with the completion's own shape and can rewrite it.
  - **Gotcha 1**: whether a response-side webhook can actually `Reject`,
    despite the reference OpenAPI spec never defining that action for
    `POST /response`. Tested empirically, not assumed. See the post for
    what agentgateway `1.5.0` actually did.
  - **Gotcha 2**: `failureMode: FailOpen`, tested against a
    scaled-to-zero webhook. Contrasted directly with B1's live-tested
    `FailClosed` default, where the same down-webhook condition returned
    `503` on every request.
- **Also checked, not a scenario of its own**: the webhook pod's own
  received headers, to confirm directly whether agentgateway sends any
  authentication or signature header when calling it. See the post.

## A note on the environment this was validated in

Same sandbox-only quirks as A1-B3's labs (the `oom_score_adj` node-image
fix and the `IPV6_ENABLED=false` readiness-bind fix). See A1's README for
the full explanation. None of this is in `kind-config.yaml`, `setup.sh`, or
the manifests here; real clusters with normal internet access need none of
it.

See `PLAN.md` (private repo) for the full decision log and CRD facts this
lab was built from.
