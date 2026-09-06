# Running agentgateway on Istio Ambient Mesh — lab

Companion manifests for the post **"Running agentgateway on Istio
Ambient Mesh"** (I3). Demonstrates agentgateway acting as an **Istio
Ambient Mesh waypoint proxy**, a feature Istio itself calls
experimental: agentgateway enforces an `HTTPRoute` on plain pod-to-pod
mesh traffic, with no sidecar and no agentgateway Helm chart at all.

## Layout

```
kind-config.yaml                        # kind node image pin (v1.34.0)
manifests/
  01-namespace-and-backend.yaml        # ambient-enabled namespace, httpbun backend, waypoint-targeting Service
  02-waypoint-gateway.yaml             # the Gateway that IS the waypoint (gatewayClassName: istio-agentgateway-waypoint)
  03-mesh-route.yaml                   # HTTPRoute attached to the waypoint, adds a header to mesh traffic
scripts/
  setup.sh                              # stands up the cluster, installs Istio ambient + agentgateway, applies the lab
  teardown.sh                           # kind delete cluster
```

## Quickstart

```sh
cd scripts
./setup.sh
```

Requires `istioctl` on `PATH`, or `setup.sh` downloads Istio 1.31.0 into
`scripts/istio-1.31.0/` itself. Then exec into a throwaway pod inside
the mesh and call the backend by its cluster-internal DNS name (this
lab has no external listener, only mesh-to-mesh traffic goes through
the waypoint):

```sh
kubectl run curltest --image=curlimages/curl:8.11.0 -n ambient-demo \
  --restart=Never --command -- sleep 3600
kubectl exec -n ambient-demo curltest -- \
  curl -s http://httpbun.ambient-demo.svc.cluster.local/get
```

Tear down with `./teardown.sh`.

## What's actually being demonstrated

Istio 1.31 added a second GatewayClass, `istio-agentgateway-waypoint`,
alongside the ingress-only `istio-agentgateway` GatewayClass that
shipped in 1.30. Labeling a Service `istio.io/use-waypoint: <name>`
routes its inbound mesh traffic through the named waypoint `Gateway`
for L7 policy, instead of letting `ztunnel` forward it directly. Here,
that waypoint is agentgateway itself, provisioned and reconciled
directly by Istio's own control plane (istiod), not by agentgateway's
usual Helm chart. Applying an `HTTPRoute` with a `RequestHeaderModifier`
filter against the waypoint `Gateway` adds a header to every request
that reaches `httpbun`, and the response's `origin` field shows the
waypoint pod's IP, not the caller's, both are checkable straight from
`curl` output with no extra tooling.

## What's validated and what isn't

See `PLAN.md` (private repo) for the exact commands and the full
decision log. Live-validated end to end, twice, from independent
clusters built from scratch: the ambient control plane comes up
healthy, the waypoint Gateway is provisioned automatically as an
agentgateway pod, and a real request from one pod to another is
proxied through it with the `HTTPRoute`'s header filter applied.

**Not independently tested here:** Istio's own docs state that
`VirtualService`/`DestinationRule`/`AuthorizationPolicy` are not
honored by an agentgateway waypoint, only Gateway API resources
configure it. That claim is doc-sourced, not verified against this
lab's own cluster.

## A note on the environment this was validated in

Same sandbox-only IPv6 quirk as the rest of this series (see A1's
README for the full explanation), but it shows up in two extra places
here that no other lab in this series hits, since Ambient Mesh has more
moving parts doing their own network setup:

- **Ambient's CNI redirection tries to add an IPv6 default route**
  during pod sandbox setup, which this sandbox's kernel rejects
  (`operation not supported`, no IPv6 support compiled in). Fixed
  reactively with `kubectl patch configmap/istio-cni-config -n
  istio-system --type merge -p '{"data":{"AMBIENT_IPV6":"false"}}'`
  followed by restarting the `istio-cni-node` DaemonSet pod, never
  baked into `setup.sh` or any manifest.
- **ztunnel and the agentgateway waypoint pod both crash on their
  readiness bind** for the same reason every other lab's
  `agentgateway-proxy` does (`Address family not supported by
  protocol`). Fixed reactively with `kubectl set env daemonset/ztunnel
  -n istio-system IPV6_ENABLED=false` and `kubectl set env
  deployment/<waypoint-name> -n <namespace> IPV6_ENABLED=false`.

Also needed: the `istio/pilot`, `istio/install-cni`, `istio/ztunnel`,
and `istio/agentgateway` images (the last one is Istio's own build of
agentgateway, distinct from `cr.agentgateway.dev/charts/agentgateway`
used by every other lab in this series) pre-loaded directly into the
kind node's containerd, since this sandbox's kind nodes can't reach the
registries directly. None of this is in `kind-config.yaml`, `setup.sh`,
or any manifest here; a real cluster with normal internet access and
IPv6 support needs none of it.
