# Cluster + install commands

Exact commands used to stand up the environment this post's manifests were
tested against. Ephemeral `kind` cluster, torn down after testing.

```sh
kind create cluster --name agentgateway-budget-limits --config kind-config.yaml

export GWAPI_VERSION=1.6.0
kubectl apply --server-side -f \
  https://github.com/kubernetes-sigs/gateway-api/releases/download/v${GWAPI_VERSION}/experimental-install.yaml

helm upgrade -i --create-namespace --namespace agentgateway-system \
  --version v1.5.0 agentgateway-crds oci://cr.agentgateway.dev/charts/agentgateway-crds

helm upgrade -i -n agentgateway-system agentgateway oci://cr.agentgateway.dev/charts/agentgateway \
  --version v1.5.0 \
  --set controller.extraEnv.KGW_ENABLE_GATEWAY_API_EXPERIMENTAL_FEATURES=true

kubectl get gatewayclass   # expect agentgateway / ACCEPTED=True
```

The experimental Gateway API install and the `KGW_ENABLE_GATEWAY_API_
EXPERIMENTAL_FEATURES=true` flag are carried over from the virtual-keys lab,
which found (on `v1.4.0-alpha.1`) that global rate limiting silently no-ops
without them. Re-confirmed live on `v1.5.0` for this lab too — see the
README's validation notes if that changed.

Apply order:

1. `01-gateway-and-backend.yaml` — Gateway, mock backend, HTTPRoute.
2. `02-api-keys-secret.yaml` — three keys: alice + carol on team `platform`,
   bob alone on team `research`.
3. `03-ratelimit-namespace.yaml` — Redis + `envoyproxy/ratelimit`, config
   with nested team/user descriptors.
4. `04-apikey-auth-plus-team-budget-policy.yaml` — the policy tying it all
   together: API key auth plus the two-descriptor rate limit.

```sh
kubectl apply -f 01-gateway-and-backend.yaml
kubectl wait --for=condition=Available deployment/budget-mock-backend -n agentgateway-system --timeout=120s
kubectl wait --for=condition=Programmed gateway/agentgateway-proxy -n agentgateway-system --timeout=120s

kubectl apply -f 02-api-keys-secret.yaml
kubectl apply -f 03-ratelimit-namespace.yaml
kubectl wait --for=condition=Available deployment/ratelimit -n ratelimit --timeout=120s

kubectl apply -f 04-apikey-auth-plus-team-budget-policy.yaml

# leave this running in its own terminal
kubectl port-forward -n agentgateway-system svc/agentgateway-proxy 8080:8080
```

Cleanup:

```sh
kind delete cluster --name agentgateway-budget-limits
```
