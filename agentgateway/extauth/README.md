# Bring Your Own External Auth Service — lab

Companion manifests for the post **"Bring Your Own External Auth
Service"** (F2). One `AgentgatewayPolicy` delegates the allow/deny
decision for every request to an external gRPC service, instead of
agentgateway checking a JWT or a CEL rule itself.

## Layout

```
kind-config.yaml                    # kind node image pin (v1.34.0)
manifests/
  00-cluster-and-install.md         # exact cluster + install commands, apply order, all scenarios
  01-gateway-and-backend.yaml       # namespace-less Gateway + httpbun mock backend
  02-ext-authz-service.yaml         # Istio's own ext-authz test fixture (gRPC, port 9000)
  03-extauth-policy.yaml            # AgentgatewayPolicy wiring traffic.extAuth at the ext-authz Service
scripts/
  setup.sh                          # stands up the cluster and applies everything
  teardown.sh                       # kind delete cluster
```

## Quickstart

```sh
cd scripts
./setup.sh
```

Then see `manifests/00-cluster-and-install.md` for the full scenario
commands: no header (denied), `x-ext-authz: allow` (allowed), and any
other value (still denied).

Tear down with `./teardown.sh`.

## What's actually being demonstrated

`AgentgatewayPolicy.spec.traffic.extAuth` hands the entire allow/deny
decision to an external service that speaks the Envoy external-
authorization gRPC proto. agentgateway doesn't interpret the request
itself here, unlike the JWT + CEL lab (F1): it forwards a check request
(headers, path, method) to `backendRef`, waits for an ALLOW or DENY, and
only then decides whether the real request continues.

The ext-authz service used here isn't a stub built for this post. It's
the Istio project's own test fixture
(`gcr.io/istio-testing/ext-authz:1.25-dev`), the same image the
agentgateway docs' own worked example uses: it allows any request
carrying `x-ext-authz: allow` and denies everything else, including a
request with the header present but set to some other value.

## What's validated and what isn't

See `PLAN.md` (private repo) for the exact commands and the full decision
log. This lab validates through direct curl calls against the guarded
route: no header, the allow value, and a non-allow value. It does not
build or test a custom ext-authz server; the whole point of "bring your
own" is that agentgateway doesn't care what's behind `backendRef`, as
long as it speaks the proto, and Istio's own fixture already proves that
end to end.

## A note on the environment this was validated in

Same sandbox-only quirks as the rest of this series (see A1's README for
the full explanation): the `IPV6_ENABLED=false` readiness-bind fix on the
proxy, and the image-preload workaround for `kind load docker-image` on
this session's containerd-snapshotter Docker. None of this is in
`kind-config.yaml`, `setup.sh`, or any manifest here; a real cluster with
normal internet access needs none of it.
