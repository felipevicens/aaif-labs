# aaif-labs

Tested, reusable artifacts that accompany my **AAIF (Agentic AI Foundation)**
posts on Medium: Kubernetes manifests, scripts and demos, organized by
`topic/post/`.

Every lab is run end to end against a real environment before its post is
published (for Kubernetes work, usually an ephemeral `kind` cluster), and the
post shows the real output of those runs.

## Contents

### agentgateway

- **[`agentgateway/virtual-keys/`](agentgateway/virtual-keys/manifests/)**:
  give each teammate their own API key to a shared local LLM, with per-person
  token budgets, API keys vs JWTs, and the key lifecycle (add and revoke).
  Tested against agentgateway `v1.4.0-alpha.1`.
  Post: [Give Your Team Their Own API Keys to a Shared Local AI Model](https://medium.com/@fjvicens/give-your-team-their-own-api-keys-to-a-shared-local-ai-model-with-agentgateway-dd1848fc3eec)
- **[`agentgateway/observability/`](agentgateway/observability/manifests/)**:
  token usage per model, team and user, with an OpenTelemetry Collector,
  Prometheus and two Grafana dashboards (operational and token usage), plus a
  traffic generator. Tested against agentgateway `1.5.0`.
  Post: [Who's Burning Your Tokens?](https://medium.com/@fjvicens/whos-burning-your-tokens-8e4284789b89)
- **[`agentgateway/multi-provider/`](agentgateway/multi-provider/)**: one route
  and one `AgentgatewayBackend` re-pointed from a keyless mock to OpenAI,
  Gemini and Anthropic, then to priority groups, while the client (`curl` or
  a small OpenAI SDK app) never changes. Manifests and runnable scripts.
  Tested against agentgateway `1.5.0`.
  Post: [One API, Any Provider: Switching LLMs Without Changing Your App](https://medium.com/@fjvicens/one-api-any-provider-switching-llms-without-changing-your-app-44528b1271ef)

### OpenSandbox

- **[`opensandbox/claude-code-quickstart/`](opensandbox/claude-code-quickstart/)**:
  OpenSandbox on Docker with Claude Code. A sandbox by hand with `osb`, Claude
  Code testing an untrusted repo through the OpenSandbox MCP server, and Claude
  Code in YOLO mode inside a sandbox with a deny-by-default network policy and
  Credential Vault. Tested with OpenSandbox `1.2.0`, Claude Code `2.1.316` and
  Docker Engine `29.9.2`.
  Post: [Let Claude Code Run Anything, Without Letting It Touch Your Machine](https://medium.com/@fjvicens/let-claude-code-run-anything-without-letting-it-touch-your-machine-02692bf491ac)
