# Cluster + install walkthrough (G2 — access logs to Loki)

Everything below ran against a real `kind` cluster, twice, from two
independent clusters built from scratch. Commands and output are copied
verbatim from the second run; the first run produced the same result.

## 1. Stand up the cluster and install everything

```sh
cd scripts
./setup.sh
```

This creates the `kind` cluster, installs the Gateway API experimental
CRDs, agentgateway `1.5.0`, a single-binary Loki `3.6.7` (chart
`grafana/loki` `6.54.0`, filesystem storage, `auth_enabled: false`), and
an OTel Collector `0.136.0` (chart `open-telemetry/opentelemetry-collector`
`0.135.0`) whose only exporter relays OTLP logs to Loki's native
`/otlp/v1/logs` endpoint. It then applies the httpbun-as-OpenAI backend,
the `/chat` route, and the access-log `AgentgatewayPolicy`.

## 2. Confirm the live CRD schema before trusting the docs

Same bar as G3: read the installed CRD instead of taking the docs' word
for the shape of `frontend.accessLog`.

```sh
kubectl get crd agentgatewaypolicies.agentgateway.dev -o json | \
  jq -r '.spec.versions[0].schema.openAPIV3Schema.properties.spec.properties.frontend.properties.accessLog.properties | keys'
```

```json
[
  "attributes",
  "filter",
  "otlp"
]
```

Confirms the doc-sourced shape from `PLAN.md`'s research note:
`otlp.backendRef` really does sit next to `attributes` and `filter` under
`accessLog`, the same family of resource G1 and G3 already used for
`frontend.tracing`.

## 3. Send a request with a distinctive mocked completion

httpbun's OpenAI-compatible mock accepts an `httpbun` field in the request
body that sets the response's `choices[0].message.content` verbatim. That
makes the completion text fully controlled and easy to search for later.

```sh
kubectl port-forward -n agentgateway-system svc/agentgateway-proxy 8080:8080 &
kubectl port-forward -n access-logs svc/loki 3100:3100 &

curl -s http://localhost:8080/chat -H "Host: access-logs.internal" \
  -H "Content-Type: application/json" \
  -d '{"model":"gpt-4","messages":[{"role":"user","content":"hi"}],"httpbun":{"content":"the walrus guards the gate at midnight"}}'
```

```json
{"model":"gpt-4","usage":{"prompt_tokens":3,"completion_tokens":10,"total_tokens":13},"choices":[{"message":{"content":"the walrus guards the gate at midnight","role":"assistant"},"finish_reason":"stop","index":0}],"created":1788607279,"id":"chatcmpl-07d369335cd71d940f4d1f22","object":"chat.completion"}
```

## 4. Pull it back out of Loki

The `attributes.add` CEL fields (`llm_model`, `llm_prompt`,
`llm_completion`) arrive in Loki as structured metadata, not indexed
labels — `curl http://localhost:3100/loki/api/v1/label` only ever lists
the OTLP resource attributes (`k8s_namespace_name`, `service_name`, and
so on). A label matcher like `{llm_completion=~".+"}` matches nothing.
Select the stream by its real label first, then filter on the metadata
field as a LogQL pipeline stage:

```sh
curl -s 'http://localhost:3100/loki/api/v1/query_range' \
  --data-urlencode 'query={service_name="agentgateway-proxy"} | llm_completion=~".+"' | jq '.data.result[0].stream'
```

```json
{
  "detected_level": "INFO",
  "gen_ai_operation_name": "chat",
  "gen_ai_provider_name": "openai",
  "gen_ai_request_model": "gpt-4",
  "gen_ai_response_model": "gpt-4",
  "http_method": "POST",
  "http_path": "/chat",
  "http_status": "200",
  "llm_completion": "[\"the walrus guards the gate at midnight\"]",
  "llm_model": "gpt-4",
  "llm_prompt": "[{\"role\": \"user\", \"content\": \"hi\"}]",
  "route": "access-logs/chat-route",
  "service_name": "agentgateway-proxy"
}
```

The exact sentence sent to httpbun comes back out of Loki, unchanged,
inside `llm_completion`.

## 5. Failure path: break the collector reference

```sh
kubectl patch agentgatewaypolicy access-log-otlp -n agentgateway-system \
  --type='json' -p='[{"op":"replace","path":"/spec/frontend/accessLog/otlp/backendRef/name","value":"nonexistent-collector"}]'

curl -s -w "\nHTTP_STATUS:%{http_code}\n" http://localhost:8080/chat -H "Host: access-logs.internal" \
  -H "Content-Type: application/json" \
  -d '{"model":"gpt-4","messages":[{"role":"user","content":"hi"}],"httpbun":{"content":"failure path proof sentence"}}'
```

Result: `HTTP_STATUS:200`. The chat response still comes back correctly;
access-log export failing does not fail the request. Querying Loki for
that sentence afterward returns zero results, since the collector was
never reachable to relay it. Restoring the policy's original
`backendRef` and sending a new request immediately resumes delivery — no
restart needed anywhere in the chain.

## 6. Tear down

```sh
cd scripts
./teardown.sh
```

## What's validated and what isn't

Both runs (independent clusters, from scratch) reproduced identical
results: the live CRD schema check, the mocked-completion round trip
through Loki, the fails-open failure path, and immediate recovery after
fixing the policy. See `PLAN.md` (private repo) for the full decision log.
