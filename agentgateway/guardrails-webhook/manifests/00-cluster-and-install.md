# Cluster + install commands

Exact commands used to stand up the environment this post's manifests are
tested against. Ephemeral `kind` cluster, torn down after testing. This
post is self-contained: it does not assume B1's cluster is still around.

```sh
kind create cluster --name agentgateway-guardrails-webhook --config ../kind-config.yaml

export GWAPI_VERSION=1.6.0
kubectl apply --server-side -f \
  https://github.com/kubernetes-sigs/gateway-api/releases/download/v$GWAPI_VERSION/standard-install.yaml

helm upgrade -i --create-namespace --namespace agentgateway-system \
  --version v1.5.0 agentgateway-crds oci://cr.agentgateway.dev/charts/agentgateway-crds

helm upgrade -i -n agentgateway-system agentgateway oci://cr.agentgateway.dev/charts/agentgateway \
  --version v1.5.0

kubectl get gatewayclass   # expect agentgateway / ACCEPTED=True
```

Same as B1-B3, `AgentgatewayPolicy.spec.backend.ai.promptGuard` is a
stable field on a stable CRD, so the standard Gateway API channel is
enough.

No provider credentials needed anywhere in this lab. Both backends are
lab-owned mock servers that echo or synthesize their own completions.

Apply order for the manifests in this folder:

1. `01-gateway-and-backends.yaml` — the `Gateway`, two mock backends
   (`echo-backend`, which echoes the last request message's content back
   verbatim; `mock-completions-response`, whose completion content
   depends on what the caller asked), and two routes, one per scenario.

   ```sh
   kubectl wait --for=condition=Available deployment/echo-backend -n default --timeout=120s
   kubectl wait --for=condition=Available deployment/mock-completions-response -n default --timeout=120s
   kubectl wait --for=condition=Programmed gateway/agentgateway-proxy -n agentgateway-system --timeout=120s

   # leave running in its own terminal
   kubectl port-forward -n agentgateway-system svc/agentgateway-proxy 8080:8080
   ```
2. `02-guardrail-webhook.yaml` — the lab's own webhook, a self-hosted
   Deployment implementing both `POST /request` and `POST /response`
   against the real discriminated-union contract B1 already reverse-
   engineered (`{"action": {...}}`, Pass/Mask/Reject told apart by which
   fields are present).

   ```sh
   kubectl wait --for=condition=Available deployment/guardrail-webhook -n agentgateway-system --timeout=120s
   ```
3. `03-webhook-policies.yaml` — two `AgentgatewayPolicy` objects, one
   targeting each route's guard direction, plus a third targeting the
   webhook's own `Service` for `requestTimeout`, same pattern B1 used.

   ```sh
   # Scenario A: request-side partial-redaction Mask
   curl -s -X POST http://localhost:8080/llm/guarded-webhook-request \
     -H 'Content-Type: application/json' \
     -d '{"model":"gpt-4","messages":[{"role":"user","content":"my key is internal_sk_a1b2c3d4e5f67890"}]}'

   # Scenario B: response-side Mask
   curl -s -X POST http://localhost:8080/llm/guarded-webhook-response \
     -H 'Content-Type: application/json' \
     -d '{"model":"gpt-4","messages":[{"role":"user","content":"how do I reach the internal service?"}]}'

   # Gotcha 1: response-side Reject, undocumented in the reference schema
   curl -s -i -X POST http://localhost:8080/llm/guarded-webhook-response \
     -H 'Content-Type: application/json' \
     -d '{"model":"gpt-4","messages":[{"role":"user","content":"escalate this now"}]}'

   # Gotcha 2: failureMode: FailOpen against a down webhook
   kubectl scale deployment/guardrail-webhook -n agentgateway-system --replicas=0
   curl -s -o /dev/null -w '%{http_code}\n' -X POST http://localhost:8080/llm/guarded-webhook-request \
     -H 'Content-Type: application/json' \
     -d '{"model":"gpt-4","messages":[{"role":"user","content":"a perfectly clean request"}]}'
   kubectl scale deployment/guardrail-webhook -n agentgateway-system --replicas=1
   ```

   See the post for the actual captured status codes and bodies: Gotcha
   1 in particular is an open question the reference OpenAPI spec doesn't
   answer, settled here by sending the request and reading the response,
   not by assuming either way.

## Cleanup

```sh
kind delete cluster --name agentgateway-guardrails-webhook
```
