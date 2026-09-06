# Splitting One Route Into Ten Teams' Routes — lab

Companion manifests for the post **"Splitting One Route Into Ten Teams'
Routes"** (H1). Demonstrates multi-level Gateway API `HTTPRoute`
delegation: a platform team's parent route delegating to two application
teams' child routes, one of which delegates a second level to a
grandchild, plus native timeout inheritance/override and
`AgentgatewayPolicy` inheritance/override across the whole chain.

## Layout

```
kind-config.yaml                       # kind node image pin (v1.34.0)
manifests/
  00-cluster-and-install.md            # exact cluster + install + walkthrough commands
  01-namespaces-and-backends.yaml      # team1/team2 namespaces, httpbun backends, shared Gateway
  02-parent-route.yaml                 # platform team's route, delegates /team1 and /team2
  03-referencegrants.yaml              # ReferenceGrants the 1.5.0 release notes call for
  04-child-team1.yaml                  # leaf route, inherits the parent's timeout and header
  05-child-team2.yaml                  # own timeout override + delegates /team2/nested further
  06-grandchild.yaml                   # second-level leaf route under child-team2
  07-header-policy.yaml                # AgentgatewayPolicy: parent injects a header, team2 overrides it
scripts/
  setup.sh                             # stands up the cluster and applies every manifest in order
  teardown.sh                          # kind delete cluster
```

## Quickstart

```sh
cd scripts
./setup.sh
```

Then see `manifests/00-cluster-and-install.md` for the full walkthrough.
Tear down with `./teardown.sh`.

## What's actually being demonstrated

A parent `HTTPRoute` delegates to a child by using it as a `backendRef`
(`group: gateway.networking.k8s.io, kind: HTTPRoute`) instead of a real
`Service`. The child can delegate again to a grandchild the same way. Two
independent inheritance mechanisms ride on top of that delegation chain:
native Gateway API fields like `timeouts.request` (a parent's value
applies to a child that sets none of its own), and `AgentgatewayPolicy`
objects attached via `targetRefs` (a parent's policy is inherited by
children and grandchildren that don't define the same policy type, and a
child's own policy overrides it for that subtree).

## What's validated and what isn't

See `PLAN.md` (private repo) for the exact commands and the full decision
log. Every scenario in the post is live-validated end to end, twice, from
independent clusters built from scratch: delegation working with zero
`ReferenceGrant`s present (contradicting the `1.5.0` release notes'
stated requirement), timeout inheritance vs. override, and
`AgentgatewayPolicy` header inheritance vs. override cascading through a
second delegation hop. Nothing here is doc-sourced only.

## A note on the environment this was validated in

Same sandbox-only quirks as the rest of this series (see A1's README for
the full explanation): the `IPV6_ENABLED=false` readiness-bind fix on the
proxy (applied reactively via `kubectl set env`, never baked into
`setup.sh`), and importing images directly into the kind node's
containerd rather than relying on the sandbox's proxy-blocked image pulls.
None of this is in `kind-config.yaml`, `setup.sh`, or any manifest here; a
real cluster with normal internet access needs none of it.
