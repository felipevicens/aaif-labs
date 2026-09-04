# Routing Prompts by What They Actually Say — lab

Companion manifests for the post **"Routing Prompts by What They Actually
Say"** (A3), the second short post in the multi-provider LLM gateway
series, depending on A1. Builds the same content-based routing decision two
ways: the stable `AgentgatewayBackend` + `AgentgatewayPolicy` (`PreRouting`
extraction) combination, and the experimental `AgentgatewayModel.
virtualModel.conditional` API. A third scenario shows a real gap in the
experimental path: it never checks the health of the target it picks.

## Layout

```
kind-config.yaml                          # kind node image pin (v1.34.0)
manifests/
  00-cluster-and-install.md               # exact cluster + install commands, apply order, cleanup
  01-gateway-and-backends.yaml            # Gateway + shared httpbun + broken httpbun-broken
  02-content-routing-stable.yaml          # Scenario A: PreRouting extraction + HTTPRoute
  03-conditional-model-experimental.yaml  # Scenario B: virtualModel.conditional
  04-conditional-ignores-health-gotcha.yaml  # Scenario C: the gotcha
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

- **All four manifests are live-validated** against a real `kind` cluster
  (agentgateway `1.5.0`, Gateway API `1.6.0`), **twice from scratch**, with
  real `curl` requests. Every scenario's exact, literal output is what the
  post quotes:
  - **Scenario A** (`02-*`): no `tier` field routes to `fast-tier`
    (`model: fast-v1` in the response); `{"tier":"premium"}` routes to
    `premium-tier` (`model: premium-v1`).
  - **Scenario B** (`03-*`): the same two outcomes, `resolved-fast` /
    `resolved-premium`, produced by `virtualModel.conditional`'s own `when`
    reading the body directly, no extraction policy involved.
  - **Scenario C** (`04-*`, the gotcha): five sequential requests to a
    `conditional` model whose only target carries a `consecutiveFailures: 1`
    eviction policy and always returns `HTTP 500`. All five return `500`.
    The proxy's own `/config_dump` shows why: the Service-level endpoint
    tracker correctly logs all five failures and ejects once
    (`consecutiveFailures: 5, timesEjected: 1`), but the separate,
    model-policy-level tracker tied to the actual `eviction` config on that
    target never moves (`health: 1.0, consecutiveFailures: 0, timesEjected:
    0`) — two health trackers on the same backend, only one of them wired
    to anything `conditional` looks at, and `conditional` doesn't look at
    either one before picking a target.
- Two real manifest bugs were caught by this validation, not by review:
  `AgentgatewayBackend.spec.ai`'s `host`/`port`/`path` fields nest under
  `provider.openai`, not directly under `ai` (`unknown field "spec.ai.
  host"` otherwise); and `AgentgatewayPolicy.spec.targetRefs` has no
  `namespace` field at all, so a policy can only target an object already
  in its own namespace (`unknown field "spec.targetRefs[0].namespace"`
  otherwise).

## A note on the environment this was validated in

Same three sandbox-only quirks as A1's and A2's labs, see those READMEs for
the full explanation. None of them are in `kind-config.yaml` or the
manifests here.

See `PLAN.md` (private repo) for the full decision log and CRD facts this
lab was built from.
