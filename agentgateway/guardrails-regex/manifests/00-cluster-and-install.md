# Cluster + install commands

Exact commands used to stand up the environment this post's manifests are
tested against. Ephemeral `kind` cluster, torn down after testing. This
post is self-contained: it does not assume B1's cluster is still around.

```sh
kind create cluster --name agentgateway-guardrails-regex --config ../kind-config.yaml

export GWAPI_VERSION=1.6.0
kubectl apply --server-side -f \
  https://github.com/kubernetes-sigs/gateway-api/releases/download/v$GWAPI_VERSION/standard-install.yaml

helm upgrade -i --create-namespace --namespace agentgateway-system \
  --version v1.5.0 agentgateway-crds oci://cr.agentgateway.dev/charts/agentgateway-crds

helm upgrade -i -n agentgateway-system agentgateway oci://cr.agentgateway.dev/charts/agentgateway \
  --version v1.5.0

kubectl get gatewayclass   # expect agentgateway / ACCEPTED=True
```

Same as B1, `AgentgatewayPolicy.spec.backend.ai.promptGuard` is a stable
field on a stable CRD, so the standard Gateway API channel is enough.

No provider credentials needed anywhere in this lab. Both scenarios are
request-side regex guards against httpbun, fully keyless.

Apply order for the manifests in this folder:

1. `01-gateway-and-backend.yaml` — the `Gateway`, httpbun (the only
   backend this lab needs, since both scenarios only inspect the request,
   never the completion), and two routes, one per scenario.

   ```sh
   kubectl wait --for=condition=Available deployment/httpbun -n default --timeout=120s
   kubectl wait --for=condition=Programmed gateway/agentgateway-proxy -n agentgateway-system --timeout=120s

   # leave running in its own terminal
   kubectl port-forward -n agentgateway-system svc/agentgateway-proxy 8080:8080
   ```
2. `02-custom-matches-policy.yaml` — Scenario A: a custom regex pattern
   catching an AWS-access-key-shaped string, rejected with an explicit
   `statusCode: 422`.

   ```sh
   curl -s -o /dev/null -w '%{http_code}\n' -X POST http://localhost:8080/llm/guarded-secret \
     -H 'Content-Type: application/json' \
     -d '{"model":"gpt-4","messages":[{"role":"user","content":"What is a load balancer?"}]}'
   # 200

   curl -s -o /dev/null -w '%{http_code}\n' -X POST http://localhost:8080/llm/guarded-secret \
     -H 'Content-Type: application/json' \
     -d '{"model":"gpt-4","messages":[{"role":"user","content":"my key is AKIAABCDEFGHIJKLMNOP"}]}'
   # 422
   ```
3. `03-tool-output-scope-policy.yaml` — Scenario B: `scope: [ToolOutput]`
   on a builtin `Ssn` guard, tested against the identical SSN string in a
   `role: user` message and a `role: tool` message.

   ```sh
   curl -s -o /dev/null -w '%{http_code}\n' -X POST http://localhost:8080/llm/guarded-tool \
     -H 'Content-Type: application/json' \
     -d '{"model":"gpt-4","messages":[{"role":"user","content":"My SSN is 123-45-6789"}]}'

   curl -s -o /dev/null -w '%{http_code}\n' -X POST http://localhost:8080/llm/guarded-tool \
     -H 'Content-Type: application/json' \
     -d '{"model":"gpt-4","messages":[{"role":"tool","tool_call_id":"call_1","content":"My SSN is 123-45-6789"}]}'
   ```

   See the post for which of these actually returned `200` vs `422` on a
   live cluster: this scenario's whole point is that the doc page never
   states what counts as "tool output" at the wire level, so this lab's
   own live validation is what settles it.

## Cleanup

```sh
kind delete cluster --name agentgateway-guardrails-regex
```
