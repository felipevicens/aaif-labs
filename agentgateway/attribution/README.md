# Invoice-Grade Attribution — lab

Companion manifests for the post **"Invoice-Grade Attribution"** (C3), the
third post in the cost series. It tests the generic `finalTransformations`
CEL-merge mechanism that agentgateway's own docs describe for stamping
identity onto every outbound LLM call, against a plain
`ai.provider.openai`-shaped `AgentgatewayBackend` and a mock backend that
echoes back whatever it received.

## Layout

```
kind-config.yaml                     # kind node image pin (v1.34.0)
manifests/
  00-cluster-and-install.md         # exact cluster + install commands, apply order, cleanup
  01-gateway-and-backend.yaml        # Gateway + echo mock backend + AgentgatewayBackend (finalTransformations) + HTTPRoute
  02-jwt-auth-policy.yaml            # reference-shape JWT auth policy (placeholder JWKS)
  jwt/
    mint-demo-jwt.py                 # mints a throwaway-signed demo JWT, or a working policy
    README.md
scripts/
  setup.sh                  # stands the whole thing up, prints the demo curl
  teardown.sh                # kind delete cluster
```

## Quickstart

```sh
cd scripts
./setup.sh   # no keys needed anywhere in this lab
```

Or follow `manifests/00-cluster-and-install.md` by hand. Either way, reach
the gateway with a port-forward:

```sh
kubectl port-forward -n agentgateway-system svc/agentgateway-proxy 8080:8080
```

Tear down with `./teardown.sh` (just `kind delete cluster`).

## What's validated and what isn't

- The generic `finalTransformations` merge mechanism against a plain
  OpenAI-shaped backend is **live-validated** against a real `kind`
  cluster, twice from scratch. See `PLAN.md` (private repo) for the exact
  schema location this confirmed and any correction made to the original
  doc-sourced guess.
- The AWS Bedrock path (`assumeRole` + real STS `AssumeRole` calls +
  IAM-principal cost attribution in AWS's Cost and Usage Report) is
  **doc-sourced only, not live-tested here**. It needs a real paid AWS
  account (violates this series' keyless rule) and CUR reporting has its
  own latency that makes same-day proof impractical even with credentials.
  See `PLAN.md` for the full scope decision.

## A note on the environment this was validated in

Same sandbox-only quirks as the rest of this series (the `oom_score_adj`
node-image fix and the `IPV6_ENABLED=false` readiness-bind fix). See A1's
README for the full explanation. None of this is in `kind-config.yaml`,
`setup.sh`, or the manifests here; real clusters with normal internet
access need none of it.

See `PLAN.md` (private repo) for the full decision log.
