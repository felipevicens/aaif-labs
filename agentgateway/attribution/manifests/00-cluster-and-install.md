# Cluster + install commands

Exact commands used to stand up the environment this post's manifests were
tested against. Ephemeral `kind` cluster, torn down after testing —
nothing here touched shared infrastructure.

```sh
kind create cluster --name agentgateway-attribution --config kind-config.yaml

kubectl apply --server-side -f \
  https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.6.0/experimental-install.yaml

helm upgrade -i --create-namespace -n agentgateway-system \
  --version 1.5.0 agentgateway-crds \
  oci://cr.agentgateway.dev/charts/agentgateway-crds

helm upgrade -i -n agentgateway-system agentgateway \
  oci://cr.agentgateway.dev/charts/agentgateway \
  --version 1.5.0 \
  --set controller.extraEnv.KGW_ENABLE_GATEWAY_API_EXPERIMENTAL_FEATURES=true

kubectl get gatewayclass   # expect agentgateway / ACCEPTED=True
```

Apply order for the manifests in this folder:

1. `01-gateway-and-backend.yaml` — Gateway, mock backend (echoes back
   whatever JSON body it receives, so a `finalTransformations` merge is
   visible directly in the response), `AgentgatewayBackend` with the
   `finalTransformations` field under `spec.ai`, and the HTTPRoute. The
   `agentgateway-proxy` Service is a `LoadBalancer`; on `kind` it stays
   `EXTERNAL-IP: <pending>` (no LB provider — expected). Reach it with a
   port-forward, which is what the `curl`s assume:

   ```sh
   # leave running in its own terminal
   kubectl port-forward -n agentgateway-system svc/agentgateway-proxy 8080:8080
   ```
2. `02-jwt-auth-policy.yaml` is a reference shape only (its inline JWKS is
   a placeholder). For a working, verifiable demo, generate a throwaway
   key and apply the matching policy with the helper, then mint a token
   from the same key:

   ```sh
   python3 jwt/mint-demo-jwt.py --policy | kubectl apply -f -   # trusts your demo key
   export JWT=$(python3 jwt/mint-demo-jwt.py)                   # token signed by it
   ```

   See `jwt/README.md`.
3. Send a request carrying both the JWT and a plain `x-team` header, and
   check what the mock backend received:

   ```sh
   curl -s -X POST http://localhost:8080/llm -H 'Content-Type: application/json' \
     -H "Authorization: Bearer $JWT" -H 'x-team: growth' \
     -d '{"model":"demo-model","messages":[{"role":"user","content":"hi"}]}' | jq .received.metadata
   ```

   `jwt.sub` (`alice`, from the validated token) and the `x-team` header
   value should both show up merged into `metadata` on the *outbound*
   request body, i.e. inside `received.metadata` on the mock's echoed
   response.

Cleanup:

```sh
kind delete cluster --name agentgateway-attribution
```
