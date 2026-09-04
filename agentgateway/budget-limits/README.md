# Give Every Team a Budget, Not Just a Key — lab

Companion manifests for the post **"Give Every Team a Budget, Not Just a
Key"** (C2), the second post in the cost series. It builds on the
`virtual-keys` lab's per-person token budget (a flat rate limit keyed on
one user) by adding a **shared team-wide pool** on top, using the same
`envoyproxy/ratelimit` + Redis service already validated there, extended
with hierarchical descriptors.

## Layout

```
kind-config.yaml                     # kind node image pin (v1.34.0)
manifests/
  00-cluster-and-install.md         # exact cluster + install commands, apply order, cleanup
  01-gateway-and-backend.yaml        # Gateway + a plain 200-OK mock backend + HTTPRoute
  02-api-keys-secret.yaml            # 3 keys: alice+carol on team platform, bob alone on research
  03-ratelimit-namespace.yaml        # Redis + envoyproxy/ratelimit, nested team/user descriptors
  04-apikey-auth-plus-team-budget-policy.yaml  # AgentgatewayPolicy: auth + two-descriptor rate limit
scripts/
  setup.sh                  # stands the whole thing up, runs the demo curls
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

- **All four manifests are live-validated** against a real `kind` cluster
  (agentgateway `1.5.0`, Gateway API `1.6.0` **experimental** channel,
  `KGW_ENABLE_GATEWAY_API_EXPERIMENTAL_FEATURES=true` — required, same as
  `virtual-keys` found on `v1.4.0-alpha.1`; global rate limiting silently
  doesn't apply without both), **twice from scratch**, byte-identical
  results both runs, down to the raw Redis counter values.
- **Scenario A** (two teams, separate pools): bob (team `research`, pool
  2/min, personal cap 2/min) gets `200, 200, 429`. Alice, a different team
  entirely, gets `200` right after — completely unaffected.
- **Scenario B, part 1** (personal cap fires with team room to spare):
  alice (team `platform`, personal cap 2/min, team pool 4/min) gets
  `200, 200, 429` — her own cap, with the team pool only half full (2/4)
  when she's blocked.
- **Scenario B, part 2** (team pool fires with personal room to spare):
  carol (same team, personal cap 5/min) gets `200, 429, 429`. Her **second**
  call is already blocked, not her third, because of the finding below.
- **Finding, confirmed by reading the raw Redis keys directly**: every
  descriptor a policy checks (team-level, personal-level) gets its counter
  incremented on **every** request, whether or not that specific descriptor
  is the one that rejected it. Alice's rejected third call (blocked by her
  own personal cap) still spent one of the team's four pool slots. That's
  why carol's team-pool rejection lands one call earlier than a naive
  "4 = 2 (alice) + 2 (carol)" count would predict. Verified: the final
  Redis counters both runs were `team_id_platform=6` (alice's 3 + carol's
  3, allowed or not), `team_id_platform_user_id_alice=3`,
  `..._carol=3`, `team_id_research=3`, `..._user_id_bob=3`.
- **Not tested here, noted honestly**: whether the "every checked
  descriptor increments regardless of outcome" behavior is specific to
  `envoyproxy/ratelimit` (likely, agentgateway just forwards descriptors to
  whatever gRPC service is configured) versus something agentgateway
  controls directly; `unit: Tokens` combined with this team/user nesting
  (this lab uses `unit: Requests` throughout — the point here is the
  hierarchical-descriptor mechanism, not LLM-token-awareness, which
  `virtual-keys` already covers).

## A note on the environment this was validated in

Same sandbox-only quirks as the rest of this series (the `oom_score_adj`
node-image fix and the `IPV6_ENABLED=false` readiness-bind fix). See A1's
README for the full explanation. None of this is in `kind-config.yaml`,
`setup.sh`, or the manifests here; real clusters with normal internet
access need none of it.

See `PLAN.md` (private repo) for the full decision log, including why this
post exists as a distinct thing from `virtual-keys`' own budget scenario.
