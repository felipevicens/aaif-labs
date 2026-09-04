# MCP Auth With Keycloak in 20 Minutes — lab

Companion manifests for the post **"MCP Auth With Keycloak in 20
Minutes"** (D5). Runs an ordinary, unauthenticated MCP tool server behind
agentgateway, then gates it with a real `AgentgatewayPolicy` that
validates JWTs issued by a real Keycloak instance and applies CEL-based
authorization on top of the token's own claims.

## Layout

```
kind-config.yaml                       # kind node image pin (v1.34.0)
manifests/
  00-cluster-and-install.md            # exact cluster + install commands, apply order, cleanup
  01-gateway-and-backend.yaml          # Gateway + AgentgatewayBackend (static target) + HTTPRoute
  02-mcp-tool-server.yaml              # an ordinary MCP server, no auth code of its own
  03-keycloak.yaml                     # Keycloak (start-dev mode, no external DB)
  04-keycloak-setup-job.yaml           # one-shot Job: realm, client, role, two test users, via kcadm.sh
  05-jwt-auth-policy.yaml              # AgentgatewayPolicy: JWT auth + MCP OAuth surface + CEL authorization
scripts/
  setup.sh                             # stands up the gateway, the tool server, and Keycloak
  teardown.sh                          # kind delete cluster
  get_token.sh                         # password-grant helper: username/password -> a real JWT
  mcp_client.py                        # minimal Streamable HTTP client, supports --token (pip install mcp)
```

## Quickstart

```sh
cd scripts
./setup.sh   # no external identity provider, no real credentials
```

Then, with both port-forwards from `setup.sh`'s own printed instructions
running:

```sh
# Unauthenticated, unprotected: works with no token
python3 scripts/mcp_client.py call whoami

# Apply the JWT auth policy, then the same call is rejected
kubectl apply -f manifests/05-jwt-auth-policy.yaml
python3 scripts/mcp_client.py call whoami

# Get a real token and try again
TOKEN=$(./scripts/get_token.sh user1 user1pass)
python3 scripts/mcp_client.py call whoami --token "$TOKEN"

# user2 has a valid token but no mcp-user role: authorization denies it
TOKEN2=$(./scripts/get_token.sh user2 user2pass)
python3 scripts/mcp_client.py call whoami --token "$TOKEN2"
```

Tear down with `./teardown.sh` (just `kind delete cluster`).

## What's actually being demonstrated

`mcp-tool-server` is an ordinary MCP server with zero auth code — the
same shape any real internal tool server usually has. `05-jwt-auth-policy.yaml`
attaches JWT authentication to the `AgentgatewayBackend` at the gateway,
in front of it, using `spec.traffic.jwtAuthentication`, not the
deprecated `spec.backend.mcp.authentication` field (the CRD schema itself
says the deprecated field runs after other policies like rate limiting,
while this one runs first).

`mcp.provider: Keycloak` turns on the actual MCP-spec OAuth surface, not
just plain bearer-token validation: agentgateway serves
`/.well-known/oauth-protected-resource/mcp` and
`/.well-known/oauth-authorization-server`, and proxies Dynamic Client
Registration to Keycloak on a new client's behalf. Keycloak is a named
provider in the CRD's own enum (`Auth0, Authentik, Descope, Entra,
Keycloak, Okta`), not a generic stand-in, because most identity providers
don't comply with the MCP OAuth spec exactly and need small adaptations —
Keycloak's JWKS endpoint isn't at the standard location, for one.

`traffic.authorization` then applies a second, independent check on top
of a validated token: a CEL expression over `jwt.realm_access.roles`, the
same shape D4 used for tool-name RBAC, this time keyed on identity
instead of tool name. `user1` has the `mcp-user` realm role and gets
through; `user2` has a perfectly valid token from the same realm, issued
by the same client, and still gets denied, because authorization is a
separate check from authentication.

## What's validated and what isn't

See `PLAN.md` (private repo) for the exact commands, the CRD schema
findings, and the full decision log. In short: confirmed live on two
from-scratch `kind` clusters, byte-identical both times — the
unauthenticated call working before the policy is applied, the same call
being rejected with no token once it is, a real Keycloak-issued token for
`user1` succeeding, and the same policy denying `user2`'s equally valid
token on the authorization check alone.

## A note on the environment this was validated in

Same sandbox-only quirks as the rest of this series: the `IPV6_ENABLED=false`
readiness-bind fix on the proxy, and the image-preload workaround for
`kind load docker-image` on this session's containerd-snapshotter Docker.
See A1's README for the full explanation. None of this is in
`kind-config.yaml`, `setup.sh`, or any manifest here; a real cluster with
normal internet access needs none of it.
