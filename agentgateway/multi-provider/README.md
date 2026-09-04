# One API, Every Provider — lab

Companion manifests for the post **"One API, Every Provider"** (A1), the
first long post in the multi-provider LLM gateway series. Builds a single
agentgateway `AgentgatewayBackend` that fans a client's OpenAI-compatible
request out across httpbun (keyless mock), OpenAI (real, cheapest tier) and
Gemini (real, free tier). This post's own Gotchas section ends on an open
question: priority order alone doesn't fail over. A2 (the week's first short
post) answers that with `policies.health.eviction` and a retry policy, then
tests the newer, experimental `AgentgatewayModel.virtualModel.failover` API
against the same failure and finds it doesn't deliver the same thing, live.
A3 goes deep on the experimental `AgentgatewayModel` API's other half,
content-based routing (`virtualModel.conditional`), next.

## Layout

```
kind-config.yaml            # kind node image pin (v1.34.0)
manifests/
  00-cluster-and-install.md # exact cluster + install commands, apply order, cleanup
  01-gateway-backend-route.yaml         # Scenario 1: keyless (httpbun)
  02-openai-secret-and-backend.yaml     # Scenario 2: single real provider (OpenAI)
  03-multiprovider-priority-groups.yaml # Scenario 3: multi-provider groups (the core)
  04-anthropic-config-unvalidated.yaml  # reference only, NOT applied by setup.sh
scripts/
  setup.sh                  # stands the whole thing up
  teardown.sh                # kind delete cluster
```

## Quickstart

```sh
cd scripts
./setup.sh                                          # Scenario 1 only, no keys needed
OPENAI_API_KEY=sk-... GEMINI_API_KEY=... ./setup.sh  # Scenarios 1-3
```

Or follow `manifests/00-cluster-and-install.md` by hand for the exact
commands and apply order. Either way, reach the gateway with a port-forward
(kind's `LoadBalancer` Service for `agentgateway-proxy` stays `<pending>`,
there's no LB provider on kind):

```sh
kubectl port-forward -n agentgateway-system svc/agentgateway-proxy 8080:8080
```

Tear down with `./teardown.sh` (just `kind delete cluster`).

## What's validated and what isn't

- **Scenarios 1-3 (`01-*`, `02-*`, `03-*`) are live-validated.** Applied via
  `setup.sh` itself against a real `kind` cluster (agentgateway `1.5.0`,
  Gateway API `1.6.0`), twice from scratch, with real `curl` requests against
  httpbun, OpenAI (`gpt-4o-mini`), and the three-provider `groups` backend.
  All three returned `HTTP 200` with real response bodies. Scenario 1 needs no
  credentials; 2 and 3 are skipped gracefully if `OPENAI_API_KEY` /
  `GEMINI_API_KEY` aren't set. The failure paths were tested too: an invalid
  key, a missing `Secret`, and a nonexistent model name, see the post's
  Gotchas section for what each one actually returns.
- Three real structural bugs were found and fixed during validation, all
  caught by the API server itself rejecting the manifest, not by manual
  review: `spec.ai.policies` is not a field (`policies` is a sibling of `ai`),
  `NamedLLMProvider` entries in `groups` are flat and don't nest under a
  `provider:` key, and `gemini-1.5-flash` / `gemini-2.5-flash-lite` are both
  retired, current model is `gemini-3.5-flash-lite`.
- `04-anthropic-config-unvalidated.yaml` is reference-only: the author has no
  Anthropic key to validate it against a live cluster, so its header spells
  out exactly which fields are best-effort guesses. Not applied by
  `setup.sh`. Its `spec.ai` / `spec.policies` structure IS confirmed, since
  it's identical to Scenario 2's now-fixed, live-tested shape.
- The experimental `AgentgatewayModel` API (`virtualModel.failover` /
  `.conditional`) is **not** part of this lab. A2 and A3 build it out fully;
  A1 stays on the stable `AgentgatewayBackend` + `HTTPRoute` API throughout.

## A note on the environment this was validated in

The Claude Code sandbox used to validate this lab has three quirks unrelated
to the manifests themselves, unlikely to affect a normal Docker install:

- `kind create cluster` needs a node image with a `runc` wrapper that strips
  `oomScoreAdj` from the pod sandbox spec (the sandbox's kernel refuses to
  lower it, which otherwise kills every static control-plane pod).
- The sandbox's kernel has no IPv6 support at all, so `agentgateway-proxy`
  needs `IPV6_ENABLED=false` set on its Deployment to bind its readiness
  server on IPv4 instead of the default `[::]` wildcard.
- Pods inside the `kind` node cannot reach the sandbox's own egress proxy
  (`127.0.0.1:<port>`, meaningless inside a separate network namespace), so
  images had to be pre-pulled on the host and loaded into the node directly,
  and outbound TLS to real providers needed the sandbox's CA bundle mounted
  into the proxy pod and pointed to via `SSL_CERT_FILE`.

None of this is in `kind-config.yaml` or the manifests. If a normal `kind` +
Docker setup somehow hits the same class of failure (a locked-down CI
runner, for instance), these are the three things to check.

See `PLAN.md` (private repo) for the full decision log and CRD facts this lab
was built from.
