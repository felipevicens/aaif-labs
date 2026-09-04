# Four Layers Between Your Users and a Bad Answer — lab

Companion manifests for the post **"Four Layers Between Your Users and a Bad
Answer"** (B1), the first post in the guardrails series. Chains two guard
types in order on the request path (`regex`, then a custom `webhook`) and
masks a sensitive value on the response path, all against
`AgentgatewayPolicy.spec.backend.ai.promptGuard`.

## Layout

```
kind-config.yaml                     # kind node image pin (v1.34.0)
manifests/
  00-cluster-and-install.md         # exact cluster + install commands, apply order, cleanup
  01-gateway-and-backends.yaml       # Gateway + httpbun (Scenario A) + a mock completions server (Scenario B)
  02-guardrail-webhook.yaml          # a lab-owned webhook implementing the real Pass/Mask/Reject contract
  03-layered-policy.yaml             # the multi-layer guardrail: regex -> webhook (request), regex Mask (response)
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
  (agentgateway `1.5.0`, Gateway API `1.6.0` standard channel), **twice
  from scratch**.
  - **Scenario A** (ordering): a clean request passes both guard layers
    (`200`). A request containing a builtin PII pattern (SSN) is rejected
    by the regex layer, and the webhook's own pod logs stay empty for that
    call, proof it never got there. A request with no PII but the
    webhook-only forbidden term ("wire transfer") passes regex and gets
    rejected by the webhook instead, with the webhook's own error message.
  - **Scenario B** (response masking): a mocked completion containing a
    fake credit-card number comes back with the number replaced by
    `<CREDIT_CARD>`, not the literal digits.
  - **Gotcha, also live-tested**: scaling the webhook Deployment to zero
    and repeating the clean request from Scenario A. `failureMode`
    defaults to `FailClosed`, so a perfectly clean request gets blocked
    anyway, because the safety layer checking it is unreachable.
- **Not live-tested**: the third documented guard type, `openAIModeration`.
  Its schema has no `baseURL` override anywhere in the docs, so there's no
  keyless way to point it at a mock; it needs a real OpenAI API key. This
  lab documents its real YAML shape in the post but does not apply it.
  Full live validation of moderation is B3's job.

## A note on the environment this was validated in

Same sandbox-only quirks as A1-A5's labs (the `oom_score_adj` node-image
fix and the `IPV6_ENABLED=false` readiness-bind fix). See A1's README for
the full explanation. None of this is in `kind-config.yaml`, `setup.sh`, or
the manifests here; real clusters with normal internet access need none of
it.

See `PLAN.md` (private repo) for the full decision log and CRD facts this
lab was built from.
