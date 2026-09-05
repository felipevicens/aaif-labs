# Cluster, install, and following the header from gateway to vendor

Everything below is what `scripts/setup.sh` runs, spelled out so you can
run it by hand or adapt it to a real cluster, with real output from live
validation, run twice from independent clusters built from scratch.

## 1. Cluster, control plane, Tempo, and the OTel Collector

```sh
kind create cluster --name agentgateway-trace-export --config kind-config.yaml

kubectl apply --server-side -f \
  https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.6.0/experimental-install.yaml

helm upgrade -i --create-namespace --namespace agentgateway-system \
  --version v1.5.0 agentgateway-crds oci://cr.agentgateway.dev/charts/agentgateway-crds

helm upgrade -i -n agentgateway-system agentgateway oci://cr.agentgateway.dev/charts/agentgateway \
  --version v1.5.0 \
  --set controller.extraEnv.KGW_ENABLE_GATEWAY_API_EXPERIMENTAL_FEATURES=true

helm upgrade -i --create-namespace --namespace telemetry \
  --version 1.16.0 tempo --repo https://grafana.github.io/helm-charts tempo

helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts
helm upgrade -i --create-namespace --namespace tracing \
  --version 0.135.0 opentelemetry-collector open-telemetry/opentelemetry-collector \
  -f 04-otel-collector-values.yaml
```

Confirmed live: chart `0.135.0` maps to `otelcol-contrib` app version
`0.136.0`. `04-otel-collector-values.yaml` sets `mode: deployment` and
adds a second exporter, `otlphttp/fake_vendor`, next to the stock `debug`
one: a `traces_endpoint` pointed straight at `fake-vendor`'s `/ingest`
path (bypassing the exporter's default `/v1/traces` suffix) and a
`headers.x-fake-vendor-key` value it injects into every outbound OTLP
call. That header is the entire point of this lab: it's the piece an
`AgentgatewayPolicy` alone cannot add.

## 2. The route and the fake vendor

```sh
kubectl apply -f 01-namespace-and-backend.yaml
kubectl apply -f 02-fake-vendor.yaml
```

`01-namespace-and-backend.yaml` deploys httpbun, the Gateway, and a
`/good` route (rewritten to httpbun's own `/get`) - same pattern as every
other lab in this series. `02-fake-vendor.yaml` deploys a small Python
`http.server` that answers any `POST` with `200 {"accepted":true}` and
prints, per request, whether an `x-fake-vendor-key` header showed up.
It's a stand-in for a SaaS trace backend's own auth check, without
needing a real one.

## 3. Confirm the schema has no header field

```sh
kubectl get crd agentgatewaypolicies.agentgateway.dev -o json \
  | jq '.spec.versions[0].schema.openAPIV3Schema.properties.spec.properties.frontend.properties.tracing.properties | keys'
```

Confirmed live, against the installed CRD itself (not just the docs):

```json
["attributes","backendRef","clientSampling","filter","path","protocol","randomSampling","resources","url"]
```

No `headers` field anywhere under `frontend.tracing`. That's the
structural fact this whole post is built on.

## 4. Scenario 1: straight to Tempo (the Datadog Agent / Jaeger shape)

```sh
kubectl apply -f 03-tracing-policy-direct.yaml

kubectl port-forward -n agentgateway-system svc/agentgateway-proxy 8080:8080 &
kubectl port-forward -n telemetry svc/tempo 3100:3100 &

curl -s http://localhost:8080/good -H "Host: tracing.internal"
curl -s "http://localhost:3100/api/search?tags=&limit=20" | jq .
```

Confirmed live response shape:

```json
{
  "traces": [
    {"traceID":"23ef75b4...","rootServiceName":"agentgateway-proxy","rootTraceName":"GET /good/*","startTimeUnixNano":"...","durationMs":1}
  ],
  "metrics": {"inspectedTraces":1,"inspectedBytes":"17550","completedJobs":1,"totalJobs":1}
}
```

No header, no collector, no problem - because Tempo (like a Datadog Agent
or Jaeger) accepts anonymous OTLP on its own network. Reproduced
identically on a second cluster, built from scratch.

## 5. Scenario 2: through the OTel Collector (the Honeycomb / Grafana Cloud shape)

```sh
kubectl apply -f manifests/05-tracing-policy-collector.yaml

curl -s http://localhost:8080/good -H "Host: tracing.internal"

kubectl logs -n trace-export deploy/fake-vendor --tail=5
```

Only the `backendRef` changes, from `tempo.telemetry` to
`opentelemetry-collector.tracing`. Confirmed live, `fake-vendor`'s own
stdout after the request:

```
/ingest headers=Accept-Encoding,Content-Encoding,Content-Length,Content-Type,Host,User-Agent,X-Fake-Vendor-Key x-fake-vendor-key-present=True
```

`X-Fake-Vendor-Key` is in the header list, and `x-fake-vendor-key-present`
reads `True`. agentgateway itself never saw or sent that header - the
Collector added it on the hop between agentgateway and `fake-vendor`,
from the static value in its own Helm values, not from anything in the
request. That's the exact mechanism Honeycomb's `x-honeycomb-team` and
Grafana Cloud's `Authorization: Basic <base64>` both need in real life.
Reproduced identically on a second cluster, built from scratch.

## 6. What happens when the destination is unreachable

```sh
kubectl patch agentgatewaypolicy tracing -n agentgateway-system --type merge \
  -p '{"spec":{"frontend":{"tracing":{"backendRef":{"name":"opentelemetry-collector","namespace":"tracing","port":9999},"protocol":"GRPC","randomSampling":"true"}}}}'

curl -sS -o /dev/null -w '%{http_code}\n' http://localhost:8080/good -H "Host: tracing.internal"
```

Confirmed live: the request still returns `200`. Same fails-open behavior
as G1's direct-to-Tempo policy - a broken tracing `backendRef` costs
visibility, never traffic, whether the destination is Tempo directly or
an OTel Collector in front of it. Point it back at port 4317 (re-apply
`05-tracing-policy-collector.yaml`) and the next request traces again,
no restart needed.

## 7. Tear down

```sh
kind delete cluster --name agentgateway-trace-export
```
