# Cluster + install commands

Exact commands used to stand up the environment this post's manifests are
tested against. Ephemeral `kind` cluster, torn down after testing. This post
is self-contained: it does not assume A1-A5's clusters are still around.

```sh
kind create cluster --name agentgateway-guardrails-multi-layer --config ../kind-config.yaml

export GWAPI_VERSION=1.6.0
kubectl apply --server-side -f \
  https://github.com/kubernetes-sigs/gateway-api/releases/download/v$GWAPI_VERSION/standard-install.yaml

helm upgrade -i --create-namespace --namespace agentgateway-system \
  --version v1.5.0 agentgateway-crds oci://cr.agentgateway.dev/charts/agentgateway-crds

helm upgrade -i -n agentgateway-system agentgateway oci://cr.agentgateway.dev/charts/agentgateway \
  --version v1.5.0

kubectl get gatewayclass   # expect agentgateway / ACCEPTED=True
```

Nothing here is experimental: `AgentgatewayPolicy.spec.backend.ai.promptGuard`
is a stable field on a stable CRD, so the standard Gateway API channel is
enough, unlike A1, A3 and A5's `AgentgatewayModel`.

No provider credentials needed for the two guard types this lab live-tests
(`regex`, `webhook`). The third documented guard type, `openAIModeration`,
needs a real OpenAI API key with no keyless substitute (its schema has no
`baseURL` override anywhere in the docs), so it ships here as YAML only,
not applied by `setup.sh`. B3 is where that guard gets its own live
validation.

Apply order for the manifests in this folder:

1. `01-gateway-and-backends.yaml` — the `Gateway`, httpbun (Scenario A's
   backend, a fixed mock completion, same role it plays in A1-A3), and a
   tiny lab-owned mock completions server (Scenario B's backend, since its
   response needs to actually contain a credit-card-shaped string, which
   httpbun's fixed mock can't provide).

   ```sh
   kubectl wait --for=condition=Available deployment/httpbun -n default --timeout=120s
   kubectl wait --for=condition=Available deployment/mock-completions -n default --timeout=120s
   kubectl wait --for=condition=Programmed gateway/agentgateway-proxy -n agentgateway-system --timeout=120s

   # leave running in its own terminal
   kubectl port-forward -n agentgateway-system svc/agentgateway-proxy 8080:8080
   ```
2. `02-guardrail-webhook.yaml` — a tiny lab-owned webhook implementing the
   real Guardrail Webhook API contract (`POST /request`, `POST /response`,
   a discriminated `Pass`/`Mask`/`Reject` JSON response). Rejects any
   request mentioning "wire transfer", a domain-specific term no regex
   builtin covers.

   ```sh
   kubectl wait --for=condition=Available deployment/guardrail-webhook -n agentgateway-system --timeout=120s
   ```
3. `03-layered-policy.yaml` — the multi-layer guardrail itself. One
   `AgentgatewayPolicy` with two request guards in order (`regex`, then
   `webhook`) and one response guard (`regex` with `action: Mask`), plus a
   second, small policy setting a request timeout on the webhook's own
   `Service`.

   ```sh
   curl -s -o /dev/null -w '%{http_code}\n' -X POST http://localhost:8080/llm/guarded \
     -H 'Content-Type: application/json' \
     -d '{"model":"gpt-4","messages":[{"role":"user","content":"What is a load balancer?"}]}'
   # 200

   curl -s -X POST http://localhost:8080/llm/guarded \
     -H 'Content-Type: application/json' \
     -d '{"model":"gpt-4","messages":[{"role":"user","content":"My SSN is 123-45-6789"}]}'
   # {"error":{"message":"Request blocked: contains personally identifiable information.", ...}}

   kubectl logs -n agentgateway-system deployment/guardrail-webhook
   # no /request line for that call: the regex guard rejected it first

   curl -s -X POST http://localhost:8080/llm/guarded \
     -H 'Content-Type: application/json' \
     -d '{"model":"gpt-4","messages":[{"role":"user","content":"Please process a wire transfer for me"}]}'
   # {"error":{"message":"Blocked by guardrail webhook: wire transfer requests need human review", ...}}

   curl -s -X POST http://localhost:8080/llm/guarded-cc \
     -H 'Content-Type: application/json' \
     -d '{"model":"gpt-4","messages":[{"role":"user","content":"Give me a test card number"}]}'
   # the completion's card number reads <CREDIT_CARD>, not the real digits
   ```

## Cleanup

```sh
kind delete cluster --name agentgateway-guardrails-multi-layer
```
