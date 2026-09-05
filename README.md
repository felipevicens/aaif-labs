# aaif-labs

Tested, reusable artifacts accompanying **AAIF (Agentic AI Foundation)**
publications — Kubernetes manifests, MCP code, and demos, organized by
`topic/post/`.

Each set is tested end to end against a real environment (for Kubernetes work,
usually an ephemeral `kind` cluster, twice from scratch) before the
accompanying post is published. Most of this series runs on **agentgateway
`1.5.0`**, Gateway API `v1.6.0` (experimental channel), and a **httpbun**
keyless mock backend, so every lab can be run without a real provider key.

## Contents

### Published

- **agentgateway/virtual-keys/manifests/** — give each teammate their own API
  key to a shared local LLM, with per-person token budgets, API-key-vs-JWT
  auth, and key lifecycle. Tested against agentgateway `v1.4.0-alpha.1`.
- **agentgateway/observability/manifests/** — who's burning your tokens: a
  cost-attribution dashboard from access logs and metrics. Tested against
  agentgateway `1.5.0`.

### Serie A — multi-provider LLM gateway

- **multi-provider/** — one OpenAI-compatible facade fanning a single request
  out across httpbun, OpenAI and Gemini.
- **failover/** — automatic failover across a provider priority chain when one
  goes down.
- **content-routing/** — routing prompts to different models based on what
  they actually say.
- **inference-routing/** — picking the least-loaded GPU automatically with the
  Gateway API Inference Extension.
- **models-serve/** — serving your own self-hosted model like a real provider,
  with virtual models and aliasing.

### Serie B — guardrails

- **guardrails-multi-layer/** — four layers between your users and a bad
  answer, composed as gateway policies.
- **guardrails-regex/** — redacting PII before it ever reaches the model.
- **guardrails-moderation/** — moderation as a gateway policy, not app code.
- **guardrails-webhook/** — writing your own guardrail webhook against the
  real request/response contract.

### Serie C — cost

- **cost-tracking/** — what a prompt actually costs, from a cost catalog to a
  dollar dashboard.
- **budget-limits/** — giving every team a budget, not just a key.
- **attribution/** — invoice-grade cost attribution per team and per model.

### Serie D — MCP gateway

- **tool-federation/** — one MCP endpoint fronting five tool servers.
- **dynamic-mcp/** — adding an MCP server without restarting anything.
- **openapi-mcp/** — turning a REST API into an MCP tool automatically.
- **tool-poisoning/** — stopping a tool-poisoning attack with MCP guardrails
  and tool-access control.
- **mcp-auth-keycloak/** — MCP auth with Keycloak in 20 minutes.
- **mcp-session-limits/** — sessions and rate limits that make MCP survive
  real traffic.

### Serie E — A2A and front-ends

- **a2a-handshake/** — two agents, one handshake: A2A in practice.
- **web-uis/** — Open WebUI, LibreChat and kagent against one gateway.

### Serie F — security

- **jwt-rbac/** — who can call which model: JWT auth plus CEL RBAC end to end.
- **extauth/** — bringing your own external auth service.
- **backend-authn/** — three ways to authenticate to your backend: jwtSign,
  OAuth token exchange, and ID-JAG.
- **backend-mtls/** — mTLS between your gateway and a GPU backend.

### Serie G — observability (traces)

- **request-tracing/** — following one request end to end: distributed
  tracing with Grafana Tempo, no OTel Collector required.
- **trace-export/** — exporting traces to Datadog, Honeycomb and Grafana
  Cloud: why some destinations need an OTel Collector in front and others
  don't.
- **alerting-signals/** — what to alert on and what to ignore, across
  Kubernetes-resource, control-plane (xDS), and dataplane failure layers.
