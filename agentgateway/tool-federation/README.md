# One MCP Endpoint, Five Tool Servers — lab

Companion manifests for the post **"One MCP Endpoint, Five Tool Servers"**
(D1), the first post in the MCP gateway series. It federates five
independent MCP servers behind one agentgateway endpoint and inspects how
tool aggregation, name prefixing, and partial-failure behavior actually
work.

## Layout

```
kind-config.yaml                     # kind node image pin (v1.34.0)
manifests/
  00-cluster-and-install.md         # exact cluster + install commands, apply order, cleanup
  01-teams.yaml                      # 5 Deployments/Services, one per team, same real MCP server
  02-gateway-and-mcp-backend.yaml     # Gateway + one AgentgatewayBackend federating all 5 as mcp.targets[] + HTTPRoute
scripts/
  setup.sh                  # stands the whole thing up
  teardown.sh                # kind delete cluster
  mcp_client.py               # minimal Streamable HTTP MCP client (pip install mcp)
```

## Quickstart

```sh
cd scripts
./setup.sh   # no keys needed anywhere in this lab
```

Or follow `manifests/00-cluster-and-install.md` by hand. Either way, reach
the gateway with a port-forward:

```sh
kubectl port-forward -n agentgateway-system svc/agentgateway-proxy 8080:8080
```

Tear down with `./teardown.sh` (just `kind delete cluster`).

## Why the same image five times

Rather than chase five different pieces of third-party MCP server
software, this lab deploys the same real, public, credential-free
`ghcr.io/peterj/mcp-website-fetcher:main` image five times, once per team
(`docs`, `growth`, `platform`, `data`, `search`). That is a deliberate
choice, not a shortcut: it is a realistic shape (five teams each running
their own instance of an internal utility, pointed at their own allowlisted
domains) and it is a better test of tool-name prefixing than five
different tool names would be, since all five targets register the
identical tool `fetch` and only the `<team>_fetch` prefix disambiguates
them. See `PLAN.md` (private repo) for the full reasoning, including why
an `npx`-based reference MCP server was tried and rejected for this lab.

## What's validated and what isn't

Validated twice from scratch on `kind`, both runs byte-identical:

- The federated endpoint (`python3 scripts/mcp_client.py list`) returns
  exactly five prefixed tools: `docs_fetch`, `growth_fetch`,
  `platform_fetch`, `data_fetch`, `search_fetch`.
- A tool call (`call docs_fetch <url>`) round-trips through the federated
  endpoint to the right backend and returns real content.
- `spec.mcp.failureMode` (default `FailClosed`) fails the *entire* session,
  not just the down target's tools, when one team's backend is unreachable.
  `FailOpen` (what this lab ships) degrades gracefully to the remaining
  tools and self-heals once the target recovers, no gateway restart needed.

See `PLAN.md` (private repo) for the full decision log, the exact
`kubectl explain` output that resolved the `failureMode` schema location,
and the sandbox-only egress quirk hit during validation (a `kind` pod in
this particular sandbox can't reach real internet HTTPS without extra CA
trust — not something a real cluster needs, and not part of these
manifests).

## A note on the environment this was validated in

Same sandbox-only quirks as the rest of this series (the `oom_score_adj`
node-image fix and the `IPV6_ENABLED=false` readiness-bind fix). See A1's
README for the full explanation. None of this is in `kind-config.yaml`,
`setup.sh`, or the manifests here; real clusters with normal internet
access need none of it.
