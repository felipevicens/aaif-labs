#!/usr/bin/env bash
# Scenario 2: give Claude Code the OpenSandbox tools over MCP.
#
# Registers the server in the current directory's local scope (it lands in
# ~/.claude.json, not in a file you'd commit). The API key goes in with -e,
# because the MCP server is a child process of Claude Code and that's the
# documented way to hand it an env var.
set -euo pipefail

: "${OPEN_SANDBOX_API_KEY:?export OPEN_SANDBOX_API_KEY first (setup.sh prints it)}"

claude mcp add opensandbox --transport stdio \
  -e OPEN_SANDBOX_API_KEY="$OPEN_SANDBOX_API_KEY" \
  -- opensandbox-mcp --domain localhost:8080 --protocol http

claude mcp list
