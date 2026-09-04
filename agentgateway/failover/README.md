# Your Model Just Went Down. Did Anyone Notice? — lab

Companion manifests for the post **"Your Model Just Went Down. Did Anyone
Notice?"** (A2), the first short post in the multi-provider LLM gateway
series, depending on A1. Builds one broken LLM backend and one healthy one
behind agentgateway, then makes the broken one actually fail over,
transparently, using the stable `AgentgatewayBackend` + `AgentgatewayPolicy`
API. Scenario C repeats the exact same failure with the newer, experimental
`AgentgatewayModel.virtualModel.failover` API to show a real, live gap
between the two.

## Layout

```
kind-config.yaml            # kind node image pin (v1.34.0)
manifests/
  00-cluster-and-install.md            # exact cluster + install commands, apply order, cleanup
  01-gateway-and-backends.yaml         # Gateway + healthy httpbun + broken httpbun-primary-bad
  02-resilient-llm-backend-route.yaml  # AgentgatewayBackend priority groups + HTTPRoute, no failover yet
  03-health-eviction-policy.yaml       # Scenario A: failover, not transparent
  04-retry-policy.yaml                 # Scenario B: transparent failover
  05-virtualmodel-failover-experimental.yaml  # Scenario C: the experimental gap
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
commands and apply order. Either way, reach the gateway with a port-forward
(kind's `LoadBalancer` Service for `agentgateway-proxy` stays `<pending>`,
there's no LB provider on kind):

```sh
kubectl port-forward -n agentgateway-system svc/agentgateway-proxy 8080:8080
```

Tear down with `./teardown.sh` (just `kind delete cluster`).

## What's validated and what isn't

- **All five manifests are live-validated**, applied via `setup.sh` itself
  against a real `kind` cluster (agentgateway `1.5.0`, Gateway API `1.6.0`),
  **twice from scratch**, with real `curl` requests. Every scenario's exact,
  literal output is what the post quotes:
  - **Before any policy** (`02-*` alone): every request to `/llm/resilient`
    returns `HTTP 500`, httpbun's own error body, forever.
  - **Scenario A** (`03-*`, eviction alone): request 1 still returns the
    primary's real `500`. Every request after that returns `200` from the
    fallback, because `consecutiveFailures: 1` evicts the primary on its
    first failure.
  - **Scenario B** (`04-*`, eviction + retry): the very first request ever
    sent already returns `200`. The proxy's own access log confirms a real
    retry happened (`retry.attempt=1`, `duration=23ms` vs. a single try's
    near-`0ms`) — the client just never sees it.
  - **Scenario C** (`05-*`, the gotcha): the exact same failure, the exact
    same eviction policy, described with `AgentgatewayModel.virtualModel.
    failover` instead. Five separate sequential requests, all `HTTP 500`
    from the primary, priority 1 never reached once.
- A real manifest bug was caught by this validation, not by review: the
  `Gateway`'s listener needs `allowedRoutes.namespaces.from: All`, same as
  A1's, or any `HTTPRoute` in a different namespace (here, `default`) gets
  rejected with `NotAllowedByListeners` and every request 404s. Easy to
  miss because the error only shows up in `kubectl get httproute -o yaml`,
  not in anything `curl` returns.
- Scenario C's outcome is corroborated two more ways, not just this lab's
  own run: the official docs (`agentgateway.dev/docs/kubernetes/main/llm/
  failover`) call `virtualModel.failover` **experimental** outright, and
  the controller source (`controller/pkg/agentgateway/translator/
  model_collections.go`, `modelFailoverBackend`) shows it compiles to the
  *same* underlying structure as Scenario A/B's backend, health policy
  included — so the gap is a real behavior difference between the two
  attachment paths, not a dropped field in translation. The precise reason
  inside the Rust proxy's selection code was not pinned down further; see
  `PLAN.md` (private repo) for the full trace.

## A note on the environment this was validated in

Same three sandbox-only quirks as A1's lab, see that README for the full
explanation. None of them are in `kind-config.yaml` or the manifests here.

See `PLAN.md` (private repo) for the full decision log and CRD facts this lab
was built from.
