# Cluster + install commands

Exact commands used to stand up the environment this post's manifests are
tested against. Ephemeral `kind` cluster, torn down after testing. This
post is self-contained: it does not assume B1 or B2's clusters are still
around.

```sh
kind create cluster --name agentgateway-guardrails-moderation --config ../kind-config.yaml

export GWAPI_VERSION=1.6.0
kubectl apply --server-side -f \
  https://github.com/kubernetes-sigs/gateway-api/releases/download/v$GWAPI_VERSION/standard-install.yaml

helm upgrade -i --create-namespace --namespace agentgateway-system \
  --version v1.5.0 agentgateway-crds oci://cr.agentgateway.dev/charts/agentgateway-crds

helm upgrade -i -n agentgateway-system agentgateway oci://cr.agentgateway.dev/charts/agentgateway \
  --version v1.5.0

kubectl get gatewayclass   # expect agentgateway / ACCEPTED=True
```

Same as B1 and B2, `AgentgatewayPolicy.spec.backend.ai.promptGuard` is a
stable field on a stable CRD, so the standard Gateway API channel is
enough.

**This is the one lab in this series that isn't fully keyless.** The
`openAIModeration` guard makes its own real call to OpenAI's moderation
endpoint, and that endpoint has no keyless or mocked substitute anywhere
in agentgateway's own docs. Every other route's actual LLM backend in
this lab still stays keyless, httpbun. You'll need a real OpenAI API key
with access to the moderation endpoint to run this one yourself.

Apply order for the manifests in this folder:

1. `01-gateway-and-backend.yaml` — the `Gateway`, httpbun, and the one
   route this lab needs.

   ```sh
   kubectl wait --for=condition=Available deployment/httpbun -n default --timeout=120s
   kubectl wait --for=condition=Programmed gateway/agentgateway-proxy -n agentgateway-system --timeout=120s

   # leave running in its own terminal
   kubectl port-forward -n agentgateway-system svc/agentgateway-proxy 8080:8080
   ```
2. `02-moderation-secret.yaml` — the real credential.

   ```sh
   export OPENAI_API_KEY="sk-..."
   envsubst < 02-moderation-secret.yaml | kubectl apply -f -
   ```
3. `03-moderation-policy.yaml` — the guard itself.

   ```sh
   kubectl apply -f 03-moderation-policy.yaml

   curl -s -o /dev/null -w '%{http_code}\n' -X POST http://localhost:8080/llm/guarded-moderation \
     -H 'Content-Type: application/json' \
     -d '{"model":"gpt-4","messages":[{"role":"user","content":"What is a load balancer?"}]}'
   # 200

   curl -s -X POST http://localhost:8080/llm/guarded-moderation \
     -H 'Content-Type: application/json' \
     -d '{"model":"gpt-4","messages":[{"role":"user","content":"I want to harm myself"}]}'
   # Content blocked by moderation policy
   ```

## Cleanup

```sh
kind delete cluster --name agentgateway-guardrails-moderation
```

Deleting the cluster also destroys the `openai-secret` Secret. Rotate the
key itself afterward regardless, especially if it ever touched a chat
log or terminal history on its way into `$OPENAI_API_KEY`.
