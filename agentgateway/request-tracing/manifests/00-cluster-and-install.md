# Cluster, install, and following one request end to end

Everything below is what `scripts/setup.sh` runs, spelled out so you can
run it by hand or adapt it to a real cluster, with real output from live
validation.

## 1. Cluster, control plane, and Tempo

```sh
kind create cluster --name agentgateway-request-tracing --config kind-config.yaml

kubectl apply --server-side -f \
  https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.6.0/experimental-install.yaml

helm upgrade -i --create-namespace --namespace agentgateway-system \
  --version v1.5.0 agentgateway-crds oci://cr.agentgateway.dev/charts/agentgateway-crds

helm upgrade -i -n agentgateway-system agentgateway oci://cr.agentgateway.dev/charts/agentgateway \
  --version v1.5.0 \
  --set controller.extraEnv.KGW_ENABLE_GATEWAY_API_EXPERIMENTAL_FEATURES=true

helm upgrade -i --create-namespace --namespace telemetry \
  --version 1.16.0 tempo --repo https://grafana.github.io/helm-charts tempo
```

Tempo's default single-binary install (confirmed live on chart `1.16.0`,
app version `2.6.1`) brings up an OTLP gRPC receiver on port 4317 and its
own HTTP query API on port 3100, both with no extra config needed - the
tracing policy below points straight at 4317, no separate OTel Collector
in front.

## 2. The routes: one plain, one LLM-shaped

```sh
kubectl apply -f 01-namespace-and-backend.yaml
kubectl apply -f 02-ai-backend-and-route.yaml
```

`01-namespace-and-backend.yaml` deploys httpbun, the Gateway, and a
`/good` route (rewritten to httpbun's own `/get`). `02-ai-backend-and-route.yaml`
adds an `AgentgatewayBackend` pointing at the same httpbun pod mocked as
an OpenAI provider, and a `/chat` route in front of it. Same backend pod,
two different request shapes through the gateway.

## 3. Turn tracing on

```sh
kubectl apply -f 03-tracing-policy.yaml
```

One `AgentgatewayPolicy` targeting the Gateway, `frontend.tracing`
pointing at `tempo.telemetry.svc.cluster.local:4317` over gRPC, with
`randomSampling: "true"` so every request from this lab's plain `curl`
calls gets traced (no incoming `traceparent` header for `clientSampling`
to pick up).

## 4. Send one of each request

```sh
kubectl port-forward -n agentgateway-system svc/agentgateway-proxy 8080:8080 &

curl -s http://localhost:8080/good -H "Host: tracing.internal"

curl -s http://localhost:8080/chat -H "Host: tracing.internal" \
  -H "Content-Type: application/json" \
  -d '{"model":"gpt-4","messages":[{"role":"user","content":"hi"}]}'
```

## 5. Follow the request into Tempo

```sh
kubectl port-forward -n telemetry svc/tempo 3100:3100 &

curl -s "http://localhost:3100/api/search?tags=&limit=20" | jq .
```

Confirmed live response shape:

```json
{
  "traces": [
    {"traceID":"daf0e8ab...","rootServiceName":"agentgateway-proxy","rootTraceName":"POST /chat/*","startTimeUnixNano":"...","durationMs":3},
    {"traceID":"a5e39d37...","rootServiceName":"agentgateway-proxy","rootTraceName":"GET /good/*","startTimeUnixNano":"...","durationMs":2}
  ],
  "metrics": {"inspectedTraces":2,"inspectedBytes":"18096","completedJobs":1,"totalJobs":1}
}
```

New traces took roughly 8 to 15 seconds to show up after the request -
that's the batch span exporter's flush interval, not a broken pipeline.
Pull one trace by ID:

```sh
curl -s "http://localhost:3100/api/traces/<traceID>" | jq .
```

Each trace has two spans: a root span for the gateway's own handling of
the inbound request, and a child span for the outbound call it made to
the backend. Confirmed live, the `/good` root span (`GET /good/*`)
carries only the default HTTP set: `gateway`, `listener`, `route`,
`endpoint`, `src.addr`, `http.host`, `http.path`, `http.status`,
`http.version`, `http.method`, `trace.id`, `span.id`, `protocol=http`,
`duration`, `url.scheme`, `network.protocol.version`. Its child span
(`GET httpbun.request-tracing.svc.cluster.local:3090`) carries
`agentgateway.outbound.kind=Primary`, `agentgateway.outbound.subtype=Http`,
plus the same `http.*` set for the actual backend call.

The `/chat` root span (`POST /chat/*`) carries the same set
(`protocol=llm` instead) plus the OTel GenAI semantic-convention
attributes: `gen_ai.operation.name=chat`, `gen_ai.provider.name=openai`,
`gen_ai.request.model=gpt-4`, `gen_ai.response.model=gpt-4`,
`gen_ai.usage.input_tokens=3`, `gen_ai.usage.output_tokens=29`. Its child
span carries `agentgateway.outbound.subtype=Llm` instead of `Http`.

## 6. What happens when Tempo is unreachable

```sh
kubectl patch agentgatewaypolicy tracing -n agentgateway-system --type merge \
  -p '{"spec":{"frontend":{"tracing":{"backendRef":{"name":"tempo","namespace":"telemetry","port":9999},"protocol":"GRPC","randomSampling":"true"}}}}'

curl -sS -o /dev/null -w '%{http_code}\n' http://localhost:8080/good -H "Host: tracing.internal"
```

Confirmed live: the request still returns `200`. The proxy logs one error
per failed export batch:

```
error opentelemetry_sdk name="BatchSpanProcessor.ExportError" error="Operation failed: no healthy backends"
```

No new trace shows up in Tempo while the `backendRef` is broken. Point it
back at port 4317 (re-apply `03-tracing-policy.yaml`) and the very next
request produces a trace again within the same flush window - no restart
needed. Tracing fails open: a bad OTLP destination costs you visibility,
never traffic.

## 7. Tear down

```sh
kind delete cluster --name agentgateway-request-tracing
```
