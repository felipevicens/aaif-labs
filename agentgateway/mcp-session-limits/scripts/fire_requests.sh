#!/usr/bin/env bash
# Fires N independent `initialize` requests at the gateway's /mcp endpoint,
# one per line. Each request is a self-contained new session attempt, so
# this needs no prior session state, which keeps it fast and simple for
# hammering the rate limiter.
#
# A rate-limited MCP call is NOT an HTTP 429: agentgateway answers with a
# normal HTTP 200 carrying a JSON-RPC error object, code -32003, in the
# body. This script checks the body, not just the HTTP status, for
# exactly that reason.
set -euo pipefail

N="${1:-15}"
URL="http://localhost:8080/mcp"
BODY='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"fire","version":"1"}}}'

for i in $(seq 1 "$N"); do
  resp=$(curl -s -X POST "$URL" \
    -H "Content-Type: application/json" \
    -H "Accept: application/json, text/event-stream" \
    -d "$BODY")
  if echo "$resp" | grep -q '"code":-32003'; then
    echo "RATE_LIMITED"
  else
    echo "OK"
  fi
done
