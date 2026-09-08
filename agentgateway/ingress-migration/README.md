# Migrating From Ingress NGINX in an Afternoon — lab

Companion manifests for the post **"Migrating From Ingress NGINX in an
Afternoon"** (I1). Demonstrates the real `ingress2gateway` CLI (the
`kgateway-dev` fork's `agentgateway` emitter) converting two ingress-nginx
`Ingress` objects — one with CORS annotations, one with basic auth — into
Gateway API `HTTPRoute`s plus `AgentgatewayPolicy` resources, and proves
the converted config behaves the same way the original annotations did.

## Layout

```
kind-config.yaml                          # kind node image pin (v1.34.0)
manifests/
  01-namespace-and-backend.yaml         # namespace, httpbun backend, shared Gateway with two listeners
  02-before-ingress-cors.yaml           # "before": ingress-nginx Ingress with CORS annotations (reference only, not applied)
  03-before-ingress-basic-auth.yaml     # "before": ingress-nginx Ingress with basic-auth annotations (reference only, not applied)
  04-cors-migrated.yaml                 # "after": real ingress2gateway output for the CORS Ingress
  05-basic-auth-migrated.yaml           # "after": real ingress2gateway output for the basic-auth Ingress, plus the Secret it references
scripts/
  setup.sh                               # stands up the cluster, installs Gateway API + agentgateway + ingress2gateway, applies the lab
  teardown.sh                            # kind delete cluster
```

## Quickstart

```sh
cd scripts
./setup.sh
```

`setup.sh` installs the real `ingress2gateway` binary (`kgateway-dev`
fork, `v0.5.0`) and re-runs the exact conversion `manifests/04` and
`manifests/05` were generated from, so you see the tool's own INFO/WARN
output before the already-converted manifests get applied. Tear down with
`./teardown.sh`.

## What's actually being demonstrated

`ingress2gateway print --providers=ingress-nginx --emitter=agentgateway`
reads a real ingress-nginx `Ingress` and prints Gateway API resources for
it. Two scenarios:

- **CORS** (`manifests/02` → `manifests/04`): the tool emits CORS
  configuration **twice** — once as a native Gateway API `HTTPRoute`
  `CORS` filter (plus a `ResponseHeaderModifier` stripping any
  `Access-Control-*` headers a backend might set on its own), and again
  as a functionally redundant `AgentgatewayPolicy.spec.traffic.cors`
  saying the same thing. Both come straight from the tool, not something
  edited in afterward.
- **Basic auth** (`manifests/03` → `manifests/05`): `auth-type: basic` +
  `auth-secret` + `auth-secret-type: auth-file` become
  `AgentgatewayPolicy.spec.traffic.basicAuthentication.secretRef`. The
  tool's own INFO output warns that agentgateway expects the htpasswd
  content under Secret key `.htaccess`, while ingress-nginx expects key
  `auth` — the two are not interchangeable, and the Secret in
  `manifests/05` uses the `.htaccess` key agentgateway actually needs.
  The same three annotations also get flagged WARN "Unsupported
  annotation" by the tool's generic ingress-nginx provider pass, even
  though the `agentgateway` emitter pass handles them correctly — noisy
  but harmless, confirmed by the successful conversion output itself.

Both migrated `HTTPRoute`s were edited from the tool's raw output in
exactly two mechanical ways any reader would also make: the `Gateway`
block the tool prints is dropped (`manifests/01` already defines one
shared `Gateway` with a listener per hostname), and the `HTTPRoute`'s
`parentRefs` points at it instead.

## What's validated and what isn't

See `PLAN.md` (private repo) for the exact commands and the full decision
log. Live-validated end to end, twice, from independent clusters built
from scratch:

- CORS preflight (`OPTIONS`) from the allowed origin
  (`https://app.allowed.example`) gets back the full set of
  `Access-Control-*` headers; the same preflight from a different origin
  (`https://evil.example`) gets none. A normal `GET` from the allowed
  origin carries the gateway's own `Access-Control-Allow-Origin` and
  `Access-Control-Allow-Credentials` response headers (not httpbun's,
  since the backend never sets any).
- Basic auth: no credentials returns `401` with
  `WWW-Authenticate: Basic realm="Restricted"`; the correct
  username/password (`aaif` / `letmein123`, hashed with
  `openssl passwd -apr1` into the Secret's `.htaccess` key) returns
  `200`; a wrong password returns `401`.

**Not covered by this lab** (see `PLAN.md` for the scope decision): SSL
redirect (`ssl-redirect`/`force-ssl-redirect` annotations — real TLS/SNI
setup is disproportionate for a `kind` cluster) and canary/traffic-split
annotations (already covered by H5's native weighted `backendRefs`
canary). The tool also does not emit anything for ingress-nginx's session
affinity or regex path-matching annotations against this target — both
explicitly unsupported by the `agentgateway` emitter, not a gap in this
lab.

## A note on the environment this was validated in

Same sandbox-only network restriction as the rest of this series: this
sandbox's kind nodes can't reach `cr.agentgateway.dev` or GitHub releases
directly, so the Gateway API CRDs, the agentgateway CRDs/control-plane
images, and httpbun were all pulled once on the host and re-imported into
each fresh kind node's containerd. This time the images involved were
multi-arch manifest lists, and `kind load docker-image` itself failed on
them (`ctr: content digest ... not found`, from its own
`--all-platforms` import flag expecting platform blobs the host's
single-arch pull never fetched); the fix was `docker save` on the host,
`docker cp` the tarball into the node, then `docker exec ... ctr
--namespace=k8s.io images import` **without** `--all-platforms` inside
the node directly. Also hit the same sandbox-only IPv6 quirk as the rest
of this series (see A1's README): `agentgateway-proxy`'s readiness bind
crashes with `Address family not supported by protocol` until `kubectl
set env deployment/agentgateway-proxy -n agentgateway-system
IPV6_ENABLED=false`. None of this is in `kind-config.yaml`, `setup.sh`,
or any manifest here; a real cluster with normal internet access and IPv6
support needs none of it.
