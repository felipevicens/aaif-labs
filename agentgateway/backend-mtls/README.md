# mTLS Between Your Gateway and a GPU Backend — lab

Companion manifests for the post **"mTLS Between Your Gateway and a GPU
Backend"** (F4). Live-validated: a standard Gateway API `BackendTLSPolicy`
(one-way TLS, verifies the backend's server certificate) layered with
agentgateway's own `AgentgatewayPolicy.spec.backend.tls.mtlsCertificateRef`
(the client certificate agentgateway presents, making the connection
actually mutual).

## Layout

```
kind-config.yaml                    # kind node image pin (v1.34.0)
manifests/
  00-cluster-and-install.md         # exact cluster + install + cert + scenario commands
  01-namespace-and-backends.yaml    # httpbun + nginx TLS frontend (requires client certs) + Gateway/HTTPRoute
  02-backend-tls-policy.yaml        # BackendTLSPolicy: verify the backend's server cert (one-way)
  03-mtls-policy.yaml               # AgentgatewayPolicy.spec.backend.tls: the client cert (mutual)
scripts/
  setup.sh                          # generates a throwaway CA/server/client cert set and applies everything
  teardown.sh                       # kind delete cluster
```

## Quickstart

```sh
cd scripts
./setup.sh
```

Then see `manifests/00-cluster-and-install.md` for the full scenario
commands. Tear down with `./teardown.sh`.

## What's actually being demonstrated

Encrypting the hop from your gateway to a backend and actually
authenticating to it as a specific client are two different resources:

- **`BackendTLSPolicy`** is a standard Gateway API resource. It verifies
  the backend's server certificate against a CA and an expected hostname.
  On its own, this is one-way TLS — the backend never learns who's
  calling.
- **`AgentgatewayPolicy.spec.backend.tls.mtlsCertificateRef`** is
  agentgateway-specific. It supplies the client certificate agentgateway
  presents during the handshake, which is what makes the connection
  mutual. It can carry its own CA reference too, but this lab pairs it
  with `BackendTLSPolicy` to show both resources working together.

nginx stands in for the backend (a real GPU-serving stack has no bearing
on the TLS mechanics), configured with `ssl_verify_client on` so it
actually rejects a connection with no client certificate — that's the
failure path this lab validates, not just the happy path.

## What's validated and what isn't

See `PLAN.md` (private repo) for the exact commands and the full decision
log. All three scenarios (full mTLS success, missing-client-cert failure,
wrong-CA failure) are live-validated end to end, twice, from independent
clusters built from scratch. The CA, server cert, and client cert are all
generated fresh by `setup.sh` on every run — nothing here is a reusable,
committed credential.

## A note on the environment this was validated in

Same sandbox-only quirks as the rest of this series (see A1's README for
the full explanation): the `IPV6_ENABLED=false` readiness-bind fix on the
proxy (applied reactively via `kubectl set env`, never baked into
`setup.sh`), and the image-preload workaround for `kind load docker-image`
on this session's containerd-snapshotter Docker. None of this is in
`kind-config.yaml`, `setup.sh`, or any manifest here; a real cluster with
normal internet access needs none of it.
