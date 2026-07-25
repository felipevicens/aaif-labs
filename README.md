# aaif-labs

Tested, reusable artifacts accompanying **AAIF (Agentic AI Foundation)**
publications — Kubernetes manifests, MCP code, and demos, organized by
`topic/post/`.

Each set is tested end to end against a real environment (for Kubernetes work,
usually an ephemeral `kind` cluster) before the accompanying post is published.

## Contents

- **agentgateway/virtual-keys/manifests/** — give each teammate their own API
  key to a shared local LLM, with per-person token budgets, API-key-vs-JWT
  auth, and key lifecycle. Tested against AgentGateway `v1.4.0-alpha.1`.
