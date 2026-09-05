# Cluster, install, and all three scenarios

Everything below is what `scripts/setup.sh` runs, spelled out so you can
run it by hand or adapt it to a real cluster.

## 1. Cluster and control plane

```sh
kind create cluster --name agentgateway-alerting-signals --config kind-config.yaml

kubectl apply --server-side -f \
  https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.6.0/experimental-install.yaml

helm upgrade -i --create-namespace --namespace agentgateway-system \
  --version v1.5.0 agentgateway-crds oci://cr.agentgateway.dev/charts/agentgateway-crds

helm upgrade -i -n agentgateway-system agentgateway oci://cr.agentgateway.dev/charts/agentgateway \
  --version v1.5.0 \
  --set controller.extraEnv.KGW_ENABLE_GATEWAY_API_EXPERIMENTAL_FEATURES=true
```

## 2. The baseline: a working route and a genuinely flaky one

```sh
kubectl apply -f 01-namespace-and-backend.yaml
```

This deploys httpbun, the Gateway, and one HTTPRoute with two rules:
`/good` (rewritten to httpbun's `/get`, a normal 200) and `/flaky`
(rewritten to httpbun's `/status/500`, which always answers 500). Nothing
about `/flaky` is a gateway misconfiguration — the route is perfectly
valid, the backend just always fails. That distinction matters: this is
the layer you should alert on conservatively, not the same way as the
other two.

```sh
kubectl port-forward -n agentgateway-system svc/agentgateway-proxy 8080:8080 &

curl -s http://localhost:8080/good -H "Host: alerting.internal"        # 200
curl -sS -o /dev/null -w "%{http_code}\n" http://localhost:8080/flaky -H "Host: alerting.internal"   # 500
```

## 3. Scenario 1 — a broken HTTPRoute (Kubernetes-resource layer)

```sh
kubectl apply -f 02-broken-route.yaml

kubectl get httproute broken-route -n alerting-signals -o yaml
```

`broken-route` points its `backendRef` at `httpbun-does-not-exist`, a
Service that was never created. Confirmed live: the route's own status
shows this immediately, no traffic required:

```yaml
- type: ResolvedRefs
  status: "False"
  reason: BackendNotFound
  message: 'backend(httpbun-does-not-exist.alerting-signals.svc.cluster.local) not found'
```

`Accepted` still reads `"True"` — the route's syntax is fine, only the
backend reference is broken. A live request to `/broken` gets a 500, and
`agentgateway_requests_total` records it with
`reason="NotFound",backend="unknown"` — a different `reason` label than a
real backend failure, confirmed below. No Kubernetes Warning Event gets
created for this on either the `HTTPRoute` or the `Gateway` — the status
condition is the only signal, so an alert on this layer has to watch
`ResolvedRefs`/`Accepted` conditions directly (via `kubectl` or a status
exporter), not wait for an Event.

## 4. Scenario 2 — a broken out-of-band policy (xDS/NACK layer)

```sh
kubectl apply -f 03-broken-health-policy.yaml

kubectl get agentgatewaypolicy httpbun-broken-health -n alerting-signals -o yaml
```

`httpbun-broken-health` targets the httpbun `Service` directly (not a
route) and sets `spec.backend.health.unhealthyCondition` to
`"response.code =="` — syntactically broken CEL. It passes Kubernetes
admission cleanly (it's just a string field) and the controller
reconciles it without error. Confirmed live, the policy's own status is
still informative, but easy to misread:

```yaml
status:
  ancestors:
    - conditions:
        - type: Accepted
          status: "True"
          reason: PartiallyValid
          message: 'backend health unhealthyCondition is not a valid CEL expression: response.code =='
```

`Accepted: "True"` — read only the boolean and this looks fine.
`reason: PartiallyValid` and the message are where the actual problem
lives. The proxy's own logs confirm this is a genuine xDS-layer rejection,
not just a cosmetic warning:

```
type=Nack error="[{\"key\":\"policy/alerting-signals/httpbun-broken-health:health:...\",
  \"warn\":\"invalid CEL expression for backend.health.unhealthyCondition: parse: ERROR: ...
  replacing \\\"response.code ==\\\" with an expression that always fails\"}]"
```

agentgateway degrades gracefully rather than dropping the whole
config: it substitutes an expression that always evaluates false, so the
custom eviction condition silently never fires. `/good` keeps returning
200 the entire time — nothing about this breaks existing traffic, it just
means the policy you applied does nothing.

This is also the one place a real Prometheus counter exists for it.
Port-forward the control plane and check:

```sh
kubectl port-forward -n agentgateway-system deployment/agentgateway 9092:9092 &

curl -s http://localhost:9092/metrics | grep agentgateway_xds_rejects_total
# agentgateway_xds_rejects_total 1
```

Confirmed live on agentgateway v1.5.0 (the plain OSS
`cr.agentgateway.dev` charts, not Solo's Gloo Gateway distribution): the
real metric name is `agentgateway_xds_rejects_total`, a single unlabeled
counter. It is absent from `/metrics` entirely until the first rejection
happens, then stays at its cumulative count from then on — it does not
reset when the broken policy is deleted. Also confirmed:
`agentgateway_controller_reconciliations_total` stays at
`result="success"` throughout this whole scenario — reconciliation
succeeding and xDS accepting the result are genuinely two different
things, and only one of them has a counter with "reject" in the name.

## 5. Scenario 3 — a genuinely flaky backend (dataplane layer, noisy)

Already deployed in step 2. Check the proxy's own request metrics:

```sh
kubectl port-forward -n agentgateway-system deployment/agentgateway-proxy 15020:15020 &

curl -s http://localhost:15020/metrics | grep agentgateway_requests_total
```

Confirmed live label set:

```
agentgateway_requests_total{backend="httpbun...",status="200",reason="Upstream",route="alerting-signals/good-route",...} 5
agentgateway_requests_total{backend="httpbun...",status="500",reason="Upstream",route="alerting-signals/good-route",...} 1
agentgateway_requests_total{backend="unknown",status="500",reason="NotFound",route="alerting-signals/broken-route",...} 1
```

Same HTTP status (500) as Scenario 1's broken route, but a different
`reason` label: `Upstream` (a real backend answered, and it was a 500)
versus `NotFound` (the route never resolved a backend at all). That
label is the actual answer to "what to alert on and what to ignore" — a
sustained rate of `reason="Upstream"` 5xx is a backend problem, worth
watching but not necessarily paging your on-call for the gateway itself;
any `reason="NotFound"` or `reason="NoRoute"` traffic means a route is
broken and Scenario 1's status-condition check already caught it before
a single request needed to fail.

## 6. Tear down

```sh
kind delete cluster --name agentgateway-alerting-signals
```
