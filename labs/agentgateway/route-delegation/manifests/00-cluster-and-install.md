# Cluster + install commands

Exact commands used to stand up the environment this post's manifests are
tested against. Ephemeral `kind` cluster, torn down after testing. This post
is self-contained: it does not assume any other lab's cluster is still
around.

```sh
kind create cluster --name agentgateway-route-delegation --config ../kind-config.yaml

export GWAPI_VERSION=1.6.0
kubectl apply --server-side -f \
  https://github.com/kubernetes-sigs/gateway-api/releases/download/v$GWAPI_VERSION/experimental-install.yaml

helm upgrade -i --create-namespace --namespace agentgateway-system \
  --version v1.5.0 agentgateway-crds oci://cr.agentgateway.dev/charts/agentgateway-crds

helm upgrade -i -n agentgateway-system agentgateway oci://cr.agentgateway.dev/charts/agentgateway \
  --version v1.5.0

kubectl get gatewayclass   # expect agentgateway / ACCEPTED=True
```

No provider credentials needed anywhere in this lab: every scenario runs
against `httpbun`, keyless start to finish.

Apply order for the manifests in this folder:

1. `01-namespaces-and-backends.yaml` — creates `team1` and `team2`, an
   httpbun `Deployment`/`Service` in each, and the shared `Gateway` in
   `agentgateway-system`.
2. `04-child-team1.yaml`, `05-child-team2.yaml`, `06-grandchild.yaml` — the
   three delegated `HTTPRoute`s. Apply before the parent route so the parent
   doesn't spend a few seconds at `ResolvedRefs: False` waiting on names
   that don't exist yet — Kubernetes resolves the references either way
   once every object exists, so the actual order between these and the
   parent route doesn't matter for correctness.
3. `02-parent-route.yaml` — the platform team's route, delegating `/team1`
   (1s timeout) to `child-team1` and `/team2` (no timeout) to `child-team2`.
   Confirmed live: this route accepts and resolves cleanly even with zero
   `ReferenceGrant`s in the cluster — see the post's Scenario 1 for the
   full before/after test against the `1.5.0` release notes' claim that a
   `ReferenceGrant` is required.
4. `03-referencegrants.yaml` — the `ReferenceGrant`s the release notes
   describe. Applying them after step 3 changes nothing observable in this
   build, but they're correct Gateway API hygiene to ship regardless.
5. `07-header-policy.yaml` — one `AgentgatewayPolicy` on the parent route
   injecting `x-routed-by: platform-parent`, and one on `child-team2`
   overriding it to `team2-child`.

```sh
# leave running in its own terminal
kubectl port-forward -n agentgateway-system svc/agentgateway-proxy 8080:8080
```

Scenario 1: delegation works with no `ReferenceGrant` present.

```sh
kubectl get referencegrant -A
# No resources found

curl -s -o /dev/null -w '%{http_code}\n' http://localhost:8080/team1/headers
curl -s -o /dev/null -w '%{http_code}\n' http://localhost:8080/team2/nested/headers
# 200
# 200
```

Scenario 2: timeout inheritance vs. override.

```sh
curl -s -o /dev/null -w '%{http_code} %{time_total}s\n' http://localhost:8080/team1/delay/3
# 504 1.006484s  (inherits the parent's 1s timeout)

curl -s -o /dev/null -w '%{http_code} %{time_total}s\n' http://localhost:8080/team2/delay/3
# 200 3.006099s  (child-team2's own 5s timeout overrides the parent's)
```

Scenario 3: header policy inheritance vs. override, cascading through a
second delegation hop.

```sh
curl -s http://localhost:8080/team1/headers | grep -i x-routed-by
# X-Routed-By: platform-parent  (team1 has no policy of its own, inherits)

curl -s http://localhost:8080/team2/nested/headers | grep -i x-routed-by
# X-Routed-By: team2-child  (team2's override cascades to the grandchild)
```

## Cleanup

```sh
kind delete cluster --name agentgateway-route-delegation
```
