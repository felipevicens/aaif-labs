# Cluster + install commands

Exact commands used to stand up the environment this post's manifests were
tested against. Ephemeral `kind` cluster, torn down after testing —
nothing here touched shared infrastructure.

```sh
kind create cluster --name agentgateway-mcp-auth-keycloak --config kind-config.yaml

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

1. `01-gateway-and-backend.yaml` — Gateway plus one `AgentgatewayBackend`
   whose only MCP target is `static`, pointed at the tool server's
   in-cluster Service.
2. `02-mcp-tool-server.yaml` — a real, ordinary MCP server with one tool
   (`whoami`) and zero auth code of its own. It has no idea a JWT exists
   anywhere in this lab.
3. `03-keycloak.yaml` — Keycloak in `start-dev` mode, no external database.
4. `04-keycloak-setup-job.yaml` — a one-shot Job that configures the
   built-in `master` realm via `kcadm.sh`: an audience client-scope, a
   public OAuth client, an `mcp-user` realm role, and two test users (one
   with the role, one without).
5. `05-jwt-auth-policy.yaml` — the `AgentgatewayPolicy` that actually
   gates the MCP endpoint: JWT validation against Keycloak's JWKS
   (`mode: Strict`), the MCP-spec OAuth surface (`mcp.provider: Keycloak`),
   and CEL authorization on `jwt.realm_access.roles`. Apply this after
   `setup.sh` finishes, by hand, so the before/after is visible.

Reach the gateway and Keycloak with two port-forwards:

```sh
kubectl port-forward -n agentgateway-system svc/agentgateway-proxy 8080:8080
kubectl port-forward -n mcp-auth svc/keycloak 8081:8080
```

Talk to the gateway with the Python MCP SDK (`pip install mcp`), same
reason as every other MCP post in this series: Streamable HTTP needs
session-header handling a plain HTTP client doesn't give you for free.

```sh
python3 scripts/mcp_client.py call whoami                       # unauthenticated, works
kubectl apply -f manifests/05-jwt-auth-policy.yaml
python3 scripts/mcp_client.py call whoami                       # now rejected, no token

TOKEN=$(./scripts/get_token.sh user1 user1pass)
python3 scripts/mcp_client.py call whoami --token "$TOKEN"      # has mcp-user role: works

TOKEN2=$(./scripts/get_token.sh user2 user2pass)
python3 scripts/mcp_client.py call whoami --token "$TOKEN2"     # valid token, no role: denied
```

`get_token.sh` uses the Resource Owner Password Credentials grant against
the public `agentgateway` client `04-keycloak-setup-job.yaml` creates —
a scripted stand-in for "the user already completed browser login,"
since a full interactive authorization-code flow needs a real browser.

Cleanup:

```sh
kind delete cluster --name agentgateway-mcp-auth-keycloak
```
