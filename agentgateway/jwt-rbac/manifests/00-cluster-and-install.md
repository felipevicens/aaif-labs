# Cluster + install commands

Exact commands used to stand up the environment this post's manifests were
tested against. Ephemeral `kind` cluster, torn down after testing —
nothing here touched shared infrastructure.

```sh
kind create cluster --name agentgateway-jwt-rbac --config kind-config.yaml

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

Apply order:

```sh
kubectl apply -f manifests/01-gateway-and-mock-backends.yaml

# No IdP here: a throwaway RSA keypair is minted for this one run and its
# public half goes straight into the policy as jwks.inline. scripts/gen_keys.py
# writes the private key to .keys/private.pem and prints the JWK Set JSON.
mkdir -p .keys
export JWKS_INLINE="$(python3 scripts/gen_keys.py .keys)"

envsubst '${JWKS_INLINE}' < manifests/02-jwt-auth-policy-cheap.yaml | kubectl apply -f -
envsubst '${JWKS_INLINE}' < manifests/03-jwt-auth-policy-expensive.yaml | kubectl apply -f -
```

Reach the gateway with a port-forward:

```sh
kubectl port-forward -n agentgateway-system svc/agentgateway-proxy 8080:8080
```

Mint one token per role — `scripts/mint_token.py` signs with `.keys/private.pem`:

```sh
ENGINEER_TOKEN=$(python3 scripts/mint_token.py .keys/private.pem engineer)
ADMIN_TOKEN=$(python3 scripts/mint_token.py .keys/private.pem admin)
NO_ROLE_TOKEN=$(python3 scripts/mint_token.py .keys/private.pem "")
WRONG_AUD_TOKEN=$(python3 scripts/mint_token.py .keys/private.pem admin --wrong-aud)
```

```sh
# Scenario 1: engineer role can call the cheap model
curl -s -o /dev/null -w '%{http_code}\n' http://localhost:8080/models/cheap-model/v1/chat/completions \
  -H "Authorization: Bearer $ENGINEER_TOKEN" -H 'Content-Type: application/json' \
  -d '{"model":"cheap-model","messages":[{"role":"user","content":"hi"}]}'

# Scenario 2: engineer role is REJECTED on the expensive model (403, not 401 —
# the token itself is valid, the authorization rule just doesn't match)
curl -s -o /dev/null -w '%{http_code}\n' http://localhost:8080/models/expensive-model/v1/chat/completions \
  -H "Authorization: Bearer $ENGINEER_TOKEN" -H 'Content-Type: application/json' \
  -d '{"model":"expensive-model","messages":[{"role":"user","content":"hi"}]}'

# Scenario 3: admin role can call both
curl -s -o /dev/null -w '%{http_code}\n' http://localhost:8080/models/cheap-model/v1/chat/completions \
  -H "Authorization: Bearer $ADMIN_TOKEN" -H 'Content-Type: application/json' \
  -d '{"model":"cheap-model","messages":[{"role":"user","content":"hi"}]}'
curl -s -o /dev/null -w '%{http_code}\n' http://localhost:8080/models/expensive-model/v1/chat/completions \
  -H "Authorization: Bearer $ADMIN_TOKEN" -H 'Content-Type: application/json' \
  -d '{"model":"expensive-model","messages":[{"role":"user","content":"hi"}]}'

# Scenario 4: no token at all — 401, rejected by jwtAuthentication before
# the CEL authorization rule ever runs
curl -s -o /dev/null -w '%{http_code}\n' http://localhost:8080/models/cheap-model/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"cheap-model","messages":[{"role":"user","content":"hi"}]}'

# Scenario 5: valid token, no roles claim at all — 403 (has(jwt.roles) is false)
curl -s -o /dev/null -w '%{http_code}\n' http://localhost:8080/models/cheap-model/v1/chat/completions \
  -H "Authorization: Bearer $NO_ROLE_TOKEN" -H 'Content-Type: application/json' \
  -d '{"model":"cheap-model","messages":[{"role":"user","content":"hi"}]}'

# Scenario 6: correctly-signed token, wrong audience — 401, rejected by
# jwtAuthentication's own aud check
curl -s -o /dev/null -w '%{http_code}\n' http://localhost:8080/models/expensive-model/v1/chat/completions \
  -H "Authorization: Bearer $WRONG_AUD_TOKEN" -H 'Content-Type: application/json' \
  -d '{"model":"expensive-model","messages":[{"role":"user","content":"hi"}]}'
```

Cleanup:

```sh
kind delete cluster --name agentgateway-jwt-rbac
rm -rf .keys
```
