# Injecting System Prompts Without Touching Any App — lab

Companion manifests for the post **"Injecting System Prompts Without
Touching Any App"** (H2). Demonstrates agentgateway's **Prompt
Enrichment** policy: prepending and appending fixed messages to every
chat request that reaches a route, with zero changes to the calling
app's own code.

## Layout

```
kind-config.yaml                        # kind node image pin (v1.34.0)
manifests/
  01-namespace-and-backend.yaml        # namespace, httpbun backend, Gateway, /chat route (baseline, no enrichment)
  02-prompt-enrichment-policy.yaml     # AgentgatewayPolicy: backend.ai.prompt.prepend/append
scripts/
  setup.sh                              # stands up the cluster, installs agentgateway + agctl, applies the lab
  teardown.sh                           # kind delete cluster
```

## Quickstart

```sh
cd scripts
./setup.sh
```

`setup.sh` also downloads an `agctl` binary version-matched to the
control plane. Scenario 1 uses `agctl proxy trace` to show the exact
messages array agentgateway sends upstream, after enrichment, the same
tool this series validated in I2. Tear down with `./teardown.sh`.

## What's actually being demonstrated

`AgentgatewayPolicy.spec.backend.ai.prompt.{prepend,append}` is a
sibling field of `promptGuard` (used by B1-B4's guardrails) on the same
`spec.backend.ai` block, not a separate CRD. `prepend` messages are
inserted at the start of the request's `messages` array, `append`
messages at the end, before the request ever reaches the provider.
Here, a route targeted by this policy gets a system message forcing
short answers and a closing instruction against guessing, and the
calling app's own request body never has to include either.

## What's validated and what isn't

See `PLAN.md` (private repo) for the exact commands and the full
decision log. Live-validated end to end, twice, from independent
clusters built from scratch: a plain user-only request gets the
prepended and appended messages added before it reaches httpbun, and a
request that already carries its own system message still gets the
policy's system message prepended ahead of it, confirmed via
`agctl proxy trace`'s own body snapshot of the exact upstream request.

**Not independently tested here:** interaction between Prompt
Enrichment and A3's content-routing or A2's failover groups (does
enrichment apply once per attempt, or once total, when a request
retries across backends). That combination wasn't in scope for this
lab.

## A note on the environment this was validated in

Same sandbox-only network restriction as the rest of this series: this
sandbox's kind nodes can't reach `cr.agentgateway.dev` or GitHub
releases directly, so the agentgateway and Gateway API CRDs, the
agentgateway control plane image, httpbun, and the `agctl` binary were
all pulled once on the host and re-imported into each fresh kind node's
containerd. None of that is in `kind-config.yaml`, `setup.sh`, or any
manifest here; a real cluster with normal internet access needs none of
it.
