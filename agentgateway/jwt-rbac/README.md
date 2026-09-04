# Who Can Call Which Model — lab

Companion manifests for the post **"Who Can Call Which Model: JWT + CEL
RBAC End to End"** (F1). Two named models behind one Gateway, one JWT
issuer (a throwaway local keypair, no IdP container), and a different CEL
authorization rule per route: an `engineer` token can call the cheap
model but gets a 403 on the expensive one; an `admin` token can call both.

## Layout

```
kind-config.yaml                          # kind node image pin (v1.34.0)
manifests/
  00-cluster-and-install.md               # exact cluster + install commands, apply order, all scenarios
  01-gateway-and-mock-backends.yaml       # namespace, Gateway, mock model server, two named-model
                                           #   AgentgatewayBackend + HTTPRoute pairs
  02-jwt-auth-policy-cheap.yaml           # JWT auth + CEL authz for the cheap-model route
  03-jwt-auth-policy-expensive.yaml       # same JWT auth, stricter CEL authz, for the expensive-model route
scripts/
  gen_keys.py                             # generates a throwaway RSA keypair, prints the public JWK Set
  mint_token.py                           # mints a JWT signed with that keypair for a given role list
  setup.sh                                # stands up the cluster, generates keys, applies everything
  teardown.sh                             # kind delete cluster + removes the generated keypair
```

## Quickstart

```sh
cd scripts
./setup.sh
```

Then see `manifests/00-cluster-and-install.md` for the full scenario
commands: minting one token per role, calling each model, and every
failure path (no token, wrong role, wrong audience).

Tear down with `./teardown.sh`.

## What's actually being demonstrated

`AgentgatewayPolicy.spec.traffic.jwtAuthentication` validates that a
request carries a JWT signed by a configured issuer — here, `jwks.inline`
holds the public half of a keypair generated fresh for this one lab run,
so there's no IdP container to stand up at all. Once a request has a
valid, signed-and-not-expired token, `spec.traffic.authorization` runs a
CEL expression against that token's own claims (`jwt.roles` here) to
decide whether *this* request, on *this* route, is actually allowed
through. The two are separate checks: a wrong role on a valid token is a
`403` from the authorization rule, not a `401` from JWT validation.

Both models here are served by the same mock backend under different
names — the point isn't that the models are actually different, it's that
the same JWT, validated once, can be authorized differently per route,
which is exactly what "who can call which model" needs in a gateway
fronting several real, differently-priced or differently-permissioned
models.

## What's validated and what isn't

See `PLAN.md` (private repo) for the exact commands and the full decision
log. This lab validates through direct curl calls against each route with
freshly minted tokens per role, covering the success paths for both roles
against both models plus four failure paths (no token, wrong role, no
roles claim, wrong audience) — not a full client SDK integration, since
none is needed to prove the authentication/authorization mechanism itself.
Whether the from-scratch, twice-from-zero cluster pass this series
requires before publication has completed is tracked in `PLAN.md`.

## A note on the environment this was validated in

Same sandbox-only quirks as the rest of this series (see A1's README for
the full explanation): the `IPV6_ENABLED=false` readiness-bind fix on the
proxy, and the image-preload workaround for `kind load docker-image` on
this session's containerd-snapshotter Docker. `mock-llm`'s `pip install`
at pod start also needed a CA bundle mounted in and `SSL_CERT_FILE` /
`REQUESTS_CA_BUNDLE` / `PIP_CERT` pointed at it, because this sandbox's
egress proxy intercepts TLS and a bare `pip install` fails cert
verification against it (same pattern as every earlier lab in this series
that installs Python packages at pod start). None of this is in
`kind-config.yaml`, `setup.sh`, or any manifest here; a real cluster with
normal internet access needs none of it.

One caveat worth keeping even off-sandbox: `envsubst` (the `gettext-base`
package) isn't preinstalled everywhere. It's used here to splice the
generated `jwks.inline` JSON into the policy YAML before applying it, and
minimal base images commonly don't ship it — `apt-get install -y
gettext-base` if `envsubst: command not found`.
