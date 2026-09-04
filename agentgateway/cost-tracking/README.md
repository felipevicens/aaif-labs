# What Does This Prompt Actually Cost You? — lab

Companion manifests for the post **"What Does This Prompt Actually Cost
You?"** (C1), the first post in the cost series. It loads a real model
cost catalog (published OpenAI list prices for `gpt-4o-mini` and
`gpt-4o`) into agentgateway via `AgentgatewayParameters`, and proves the
realized-cost fields it adds to every access-log line, against a
deliberately unpriced third model too.

## Layout

```
kind-config.yaml                     # kind node image pin (v1.34.0)
manifests/
  00-cluster-and-install.md         # exact cluster + install commands, apply order, cleanup
  01-gateway-and-catalog.yaml        # Gateway + AgentgatewayParameters + catalog ConfigMap + mock backend + 3 routes
  02-cost-access-log-policy.yaml     # AgentgatewayPolicy adding llm.cost.* / llm.costRates.* to the access log
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
port-forward (kind's `LoadBalancer` Service for `agentgateway-proxy`
stays `<pending>`, there's no LB provider on kind):

```sh
kubectl port-forward -n agentgateway-system svc/agentgateway-proxy 8080:8080
```

Tear down with `./teardown.sh` (just `kind delete cluster`).

## What's validated and what isn't

- **Both manifests are live-validated** against a real `kind` cluster
  (agentgateway `1.5.0`, Gateway API `1.6.0` standard channel), **twice
  from scratch**, byte-identical results both runs.
  - **Scenario A** (`gpt-4o-mini`, 1000/500 tokens): access log reports
    `agw.ai.usage.cost.total=0.00045`, matching `(1000/1e6×0.15) +
    (500/1e6×0.60)` exactly.
  - **Scenario B** (`gpt-4o`, same 1000/500 tokens): access log reports
    `agw.ai.usage.cost.total=0.0075`, matching `(1000/1e6×2.50) +
    (500/1e6×10.00)` exactly. Same tokens, 16.7x the dollar cost.
  - **Finding**: `agw.ai.usage.cost.total` appears in the access log by
    default the moment a catalog is loaded, with zero
    `AgentgatewayPolicy` applied. The custom `attributes.add` fields in
    `02-cost-access-log-policy.yaml` add a full input/output/rate
    breakdown on top of that, not the cost data itself.
  - **Gotcha**: a model absent from the catalog (`shadow-model-v1`)
    returns `200` normally, but its access-log line carries no cost
    field at all, default or custom. Not `0`, not an error, just absent.
    Reproduced identically both runs.
  - **Also confirmed**: the proxy's own `:15020/metrics` endpoint exposes
    `agentgateway_gen_ai_client_token_usage` (raw token counts, no
    catalog needed) for every route, including the unpriced one.
- **Not tested here, noted honestly**: multiple `modelCatalog.sources`
  entries and whether later ones override earlier ones on Kubernetes
  (only a single `configMap` source used); the `tiers` field for
  context-length-based pricing; what a `GatewayClass`-level
  `modelCatalog` actually does operationally (docs say it's ignored).

## A note on the environment this was validated in

Same sandbox-only quirks as A1-B4's labs (the `oom_score_adj` node-image
fix and the `IPV6_ENABLED=false` readiness-bind fix). See A1's README for
the full explanation. None of this is in `kind-config.yaml`, `setup.sh`, or
the manifests here; real clusters with normal internet access need none of
it.

See `PLAN.md` (private repo) for the full decision log and CRD facts this
lab was built from.
