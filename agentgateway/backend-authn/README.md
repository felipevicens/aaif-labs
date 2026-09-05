# Three Ways to Authenticate to Your Backend — lab

Companion manifests for the post **"Three Ways to Authenticate to Your
Backend"** (F3). Two live-validated backend-auth mechanisms
(`AgentgatewayPolicy.spec.backend.auth`): `jwtSign` (agentgateway mints
and signs a JWT itself) and `oauthTokenExchange` (agentgateway exchanges
an inbound token for a new one via a real Keycloak instance, RFC 8693).
A third mechanism, `crossAppAccess` (ID-JAG), is explained in the post but
not built here — see "What's validated and what isn't" below.

## Layout

```
kind-config.yaml                          # kind node image pin (v1.34.0)
manifests/
  00-cluster-and-install.md               # exact cluster + install commands, apply order, all scenarios
  01-gateway-and-httpbun.yaml              # Gateway + httpbun echo backend, two HTTPRoutes
  02-jwtsign-policy.yaml                   # Scenario 1: backend.auth.jwtSign
  03-keycloak.yaml                         # Keycloak (start-dev, --features=preview)
  04-keycloak-setup-job.yaml               # one-shot kcadm.sh Job: backend-oauth realm + 3 clients
  05-inbound-jwt-auth-policy.yaml          # client-facing JWT check on the /exchange route
  06-keycloak-token-endpoint-backend.yaml  # AgentgatewayBackend pointing at Keycloak's token endpoint
  07-token-exchange-policy.yaml            # Scenario 2: backend.auth.oauthTokenExchange
scripts/
  setup.sh                                 # stands up the cluster and applies everything
  teardown.sh                              # kind delete cluster
```

## Quickstart

```sh
cd scripts
./setup.sh
```

Then see `manifests/00-cluster-and-install.md` for the full scenario
commands. Tear down with `./teardown.sh`.

## What's actually being demonstrated

Backend auth is a different field from the client-auth policies used in
F1/F2 (`spec.traffic.jwtAuthentication`, `spec.traffic.extAuth`): it's
`spec.backend.auth`, and it decides what credential agentgateway itself
presents to the backend, independent of whether (or how) the client
authenticated to the gateway.

- **`jwtSign`** needs no external IdP: agentgateway signs a fresh JWT
  with a key you give it (a Kubernetes Secret here) and attaches it to
  every request on the route.
- **`oauthTokenExchange`** needs a real OAuth authorization server: this
  lab deploys Keycloak with the `--features=preview` flag Keycloak's own
  RFC 8693 "standard token exchange" support requires, then has
  agentgateway exchange the client's inbound token for a new one scoped
  to the backend, before forwarding the request.

## What's validated and what isn't

See `PLAN.md` (private repo) for the exact commands and the full decision
log. `jwtSign` and `oauthTokenExchange` are both live-validated end to
end, twice, from independent clusters built from scratch, using httpbun's
`/headers` endpoint to inspect the credential agentgateway actually
attached.

`crossAppAccess` (ID-JAG) is not built or run in this lab. Its underlying
spec, `draft-ietf-oauth-identity-assertion-authz-grant`, is still an
active IETF draft, and agentgateway's own documented local test setup for
it requires a non-stock, third-party Keycloak image
(`ceposta/keycloak:id-jag`) because "issuing and consuming an ID-JAG
requires the experimental `identity-assertion-jwt` Keycloak feature,
which is not in a stock Keycloak release" (agentgateway's own docs,
quoted in the post). The post explains the mechanism and links the real
spec and agentgateway's own worked example instead of fabricating a live
run against an unofficial image implementing an unfinished draft.

## A note on the environment this was validated in

Same sandbox-only quirks as the rest of this series (see A1's README for
the full explanation): the `IPV6_ENABLED=false` readiness-bind fix on the
proxy, and the image-preload workaround for `kind load docker-image` on
this session's containerd-snapshotter Docker, including the
proxy-inheritance variant of that issue first hit in F2 (a fresh kind
node's containerd inherits the host's `HTTPS_PROXY`, whose loopback
address is invalid inside the node's own network namespace). None of this
is in `kind-config.yaml`, `setup.sh`, or any manifest here; a real cluster
with normal internet access needs none of it.
