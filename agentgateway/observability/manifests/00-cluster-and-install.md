# Cluster + install commands (Part 2)

Exact commands used to stand up the environment this post's manifests were
tested against. Ephemeral `kind` cluster, torn down after testing, same as
post 1 — nothing here touched shared infrastructure. This post is
self-contained: it doesn't assume post 1's cluster is still around, since
post 1 ends with `kind delete cluster`.

**Version note:** post 1 ran AgentGateway `v1.4.0-alpha.1`. This post bumps to
**`v1.5.0`** (the current stable release, re-verified end to end against a
live cluster — the manifests below originally shipped against `v1.4.1`, and
nothing here needed to change). If you're still on an older version from
post 1, upgrade the Helm release first. One `v1.5.0` breaking change worth
knowing about (doesn't affect this post's numbers, but might affect yours):
LLM token metrics now normalize prompt-cache tokens into `llm.inputTokens` —
see the "Gotchas" section in the post for what that means for
Anthropic/Bedrock backends.

```sh
kind create cluster --name agentgateway-observability

kubectl apply --server-side -f \
  https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.6.0/experimental-install.yaml

helm upgrade -i --create-namespace -n agentgateway-system \
  --version 1.5.0 agentgateway-crds \
  oci://cr.agentgateway.dev/charts/agentgateway-crds

helm upgrade -i -n agentgateway-system agentgateway \
  oci://cr.agentgateway.dev/charts/agentgateway \
  --version 1.5.0 \
  --set controller.image.pullPolicy=Always \
  --set controller.extraEnv.KGW_ENABLE_GATEWAY_API_EXPERIMENTAL_FEATURES=true

kubectl get gatewayclass   # expect agentgateway / ACCEPTED=True
```

## Recap: backend + virtual keys (post 1)

Same `Gateway` / `AgentgatewayBackend` / `HTTPRoute` trio as post 1's
`01-gateway-backend-route.yaml`, substituting your own vLLM (or hosted
provider) `host`/`port`. Port-forward to reach it:

```sh
kubectl port-forward -n agentgateway-system svc/agentgateway-proxy 8080:8080
```

Then apply `01-api-keys-secret-with-team.yaml` (this post's version of post 1's
`02-api-keys-secret.yaml`, with a `team` field added to each person) and post
1's `03-apikey-auth-policy.yaml` unchanged. If you followed post 1, this is
the same Secret shape you already know — just one more field per person.

## Apply order for this post's new manifests

1. `01-api-keys-secret-with-team.yaml` + post 1's `03-apikey-auth-policy.yaml`
   — the recap above.
2. `04-kube-prometheus-stack-values.yaml` — install with:
   ```sh
   helm upgrade -i kube-prometheus-stack prometheus-community/kube-prometheus-stack \
     --version 88.0.1 --namespace telemetry --create-namespace \
     -f 04-kube-prometheus-stack-values.yaml --wait --timeout 5m
   ```
3. `03-otel-collector-metrics-values.yaml` — install with:
   ```sh
   helm upgrade -i otel-collector-metrics open-telemetry/opentelemetry-collector \
     --version 0.165.0 --namespace telemetry \
     -f 03-otel-collector-metrics-values.yaml --wait --timeout 3m
   ```
4. `02-per-user-team-metrics-policy.yaml` — Scenario 3 (per-user/team labels).
5. `05-agentgateway-operational-dashboard.json` + `06-token-usage-dashboard.json`
   — Scenario 4. Two separate dashboards: the gateway's operational view (stock
   upstream, for SREs) and the team token-usage view (redesigned, for FinOps/leads).
   Import both in one labeled ConfigMap so kube-prometheus-stack's Grafana sidecar
   auto-loads them:
   ```sh
   kubectl create configmap agentgateway-dashboards -n telemetry \
     --from-file=agentgateway-operational.json=05-agentgateway-operational-dashboard.json \
     --from-file=token-usage.json=06-token-usage-dashboard.json \
     --dry-run=client -o yaml | kubectl label -f - --local -o yaml grafana_dashboard=1 \
     | kubectl apply -f -
   ```

Grafana port-forward:

```sh
kubectl port-forward -n telemetry svc/kube-prometheus-stack-grafana 3000:80
# http://localhost:3000, user admin / password from values (admin, this demo only)
```

## Cleanup

```sh
kind delete cluster --name agentgateway-observability
```
