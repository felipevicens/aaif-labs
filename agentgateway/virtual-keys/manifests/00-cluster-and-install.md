# Cluster + install commands

Exact commands used to stand up the environment this post's manifests were
tested against. Ephemeral `kind` cluster, torn down after testing — nothing
here touched shared infrastructure.

```sh
kind create cluster --name agentgateway-virtual-keys

kubectl apply --server-side -f \
  https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.6.0/experimental-install.yaml

helm upgrade -i --create-namespace -n agentgateway-system \
  --version 1.4.0-alpha.1 agentgateway-crds \
  oci://cr.agentgateway.dev/charts/agentgateway-crds

helm upgrade -i -n agentgateway-system agentgateway \
  oci://cr.agentgateway.dev/charts/agentgateway \
  --version 1.4.0-alpha.1 \
  --set controller.image.pullPolicy=Always \
  --set controller.extraEnv.KGW_ENABLE_GATEWAY_API_EXPERIMENTAL_FEATURES=true

kubectl get gatewayclass   # expect agentgateway / ACCEPTED=True
```

Apply order for the manifests in this folder:

1. `01-gateway-backend-route.yaml` — Gateway, AgentgatewayBackend, HTTPRoute.
   Substitute your own backend `host`/`port` (or a hosted provider — see the
   [api-keys docs](https://agentgateway.dev/docs/kubernetes/main/llm/api-keys/)).
   The `agentgateway-proxy` Service is a `LoadBalancer`; on `kind` it stays
   `EXTERNAL-IP: <pending>` (no LB provider — expected). Reach it with a
   port-forward, which is what the `curl`s assume:

   ```sh
   # leave running in its own terminal
   kubectl port-forward -n agentgateway-system svc/agentgateway-proxy 8080:8080
   ```
2. `02-api-keys-secret.yaml` + `03-apikey-auth-policy.yaml` — Scenario 1
   (API key authentication).
3. `04-ratelimit-namespace.yaml` — Redis + `envoyproxy/ratelimit` + ConfigMap.
4. `05-apikey-auth-plus-budget-policy.yaml` — replaces `03-*`, adds
   per-user token budgets (Scenario 2).
5. Scenario 3 (JWT). `06-jwt-auth-policy.yaml` is a reference shape only (its
   inline JWKS is a placeholder). For a working, verifiable demo, generate a
   throwaway key and apply the matching policy with the helper, then mint a
   token from the same key:

   ```sh
   python3 jwt/mint-demo-jwt.py --policy | kubectl apply -f -   # trusts your demo key
   export JWT=$(python3 jwt/mint-demo-jwt.py)                   # token signed by it
   ```

   Apply it standalone or alongside `03-*`/`05-*` to see the AND-composition
   behavior described in the post. See `jwt/README.md`.

Cleanup:

```sh
kind delete cluster --name agentgateway-virtual-keys
```
