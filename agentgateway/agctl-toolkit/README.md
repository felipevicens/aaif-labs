# The agctl Debugging Toolkit — lab

Companion manifests for the post **"The agctl Debugging Toolkit"** (I2).
Demonstrates `agctl proxy trace` (per-request tracing against a live
gateway) and `agctl proxy config` (runtime backend health and config
dump), both experimental `agctl` subcommands that talk to the proxy's own
admin endpoint directly.

## Layout

```
kind-config.yaml                       # kind node image pin (v1.34.0)
manifests/
  00-cluster-and-install.md            # exact cluster + install + walkthrough commands
  01-namespace-and-backend.yaml        # httpbun-as-OpenAI backend + Gateway + HTTPRoute (/chat)
  02-broken-route.yaml                 # a second route pointed at a Service with no matching pods
scripts/
  setup.sh                             # stands up the cluster, agentgateway, and a version-matched agctl
  teardown.sh                          # kind delete cluster
```

## Quickstart

```sh
cd scripts
./setup.sh
```

Then see `manifests/00-cluster-and-install.md` for the full walkthrough.
Tear down with `./teardown.sh`.

## What's actually being demonstrated

`agctl proxy trace gateway/<name> -n <ns> --raw --port <listener> -- <url>
[curl args...]` sends one request through the proxy and streams every
stage it passed through as JSONL: policy selection, route selection, the
backend call, and the response, each as a separate timestamped event. In
Kubernetes mode `agctl` resolves the proxy pod and opens its own
port-forward, no manual `kubectl port-forward` needed.

`agctl proxy config backends gateway/<name> -n <ns>` reports endpoint
health and traffic counters. By default it only lists backends that have
actually received a request; `--all` lists every `Service` agentgateway's
own service discovery knows about, cluster-wide.

## What's validated and what isn't

See `PLAN.md` (private repo) for the exact commands and the full decision
log. Both commands are live-validated end to end, twice, from independent
clusters built from scratch, plus a third run to capture the literal
output quoted in the post: a full chat-request trace, a broken-route
trace showing the "no healthy backends" short-circuit, and both the
default and `--all` views of `config backends`. Standalone (non-Kubernetes)
mode is doc-sourced only, not run in this lab.

## A note on the environment this was validated in

Same sandbox-only quirks as the rest of this series (see A1's README for
the full explanation): the `IPV6_ENABLED=false` readiness-bind fix on the
proxy (applied reactively via `kubectl set env`, never baked into
`setup.sh`), and importing images directly into the kind node's
containerd rather than relying on the sandbox's proxy-blocked image pulls.
None of this is in `kind-config.yaml`, `setup.sh`, or any manifest here; a
real cluster with normal internet access needs none of it.
