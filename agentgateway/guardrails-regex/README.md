# Redacting PII Before It Ever Reaches the Model — lab

Companion manifests for the post **"Redacting PII Before It Ever Reaches
the Model"** (B2), the second post in the guardrails series. Goes deeper
into the `regex` guard type B1 already used, this time custom `matches`
patterns and `scope: [ToolOutput]`, both against
`AgentgatewayPolicy.spec.backend.ai.promptGuard`.

## Layout

```
kind-config.yaml                     # kind node image pin (v1.34.0)
manifests/
  00-cluster-and-install.md         # exact cluster + install commands, apply order, cleanup
  01-gateway-and-backend.yaml        # Gateway + httpbun, two routes (one per scenario)
  02-custom-matches-policy.yaml      # Scenario A: custom regex matches, an AWS-key-shaped secret
  03-tool-output-scope-policy.yaml   # Scenario B: scope: [ToolOutput] on a builtin Ssn guard
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

- **Both manifests are live-validated** against a real `kind` cluster
  (agentgateway `1.5.0`, Gateway API `1.6.0` standard channel), **twice
  from scratch**.
  - **Scenario A** (custom `matches`): a clean request passes (`200`). A
    request containing an AWS-access-key-shaped string, a pattern none of
    the builtin PII names cover, is rejected with the explicit
    `statusCode: 422` and custom message this lab's policy sets.
  - **Scenario B** (`scope: [ToolOutput]`): the docs never state what
    counts as "tool output" at the wire level, so this lab tests it
    empirically, sending the identical SSN string in a `role: user`
    message and in a `role: tool` message against the same guard. See the
    post for which one actually got blocked.
- **Not applicable here**: the third guard type from B1,
  `openAIModeration`, isn't part of this post's scope at all; B3 is where
  that gets its own lab.

## A note on the environment this was validated in

Same sandbox-only quirks as A1-B1's labs (the `oom_score_adj` node-image
fix and the `IPV6_ENABLED=false` readiness-bind fix). See A1's README for
the full explanation. None of this is in `kind-config.yaml`, `setup.sh`, or
the manifests here; real clusters with normal internet access need none of
it.

See `PLAN.md` (private repo) for the full decision log and CRD facts this
lab was built from.
