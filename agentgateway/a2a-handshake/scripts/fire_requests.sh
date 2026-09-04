#!/usr/bin/env bash
# Fires N independent SendMessage calls at agent-b through the gateway,
# classifying each response as OK or RATE_LIMITED. Unlike D6's MCP rate
# limit, whether a rate-limited A2A call comes back as a plain HTTP 429
# or an HTTP 200 wrapping a JSON-RPC error (agentgateway's MCP-specific
# leniency) is exactly what this lab's Scenario 4 validation run checks —
# this script looks at both the status code and the body, and prints
# which shape it actually saw.
set -euo pipefail

N="${1:-10}"
URL="http://localhost:8080/a2a/agent-b/"
BODY='{"jsonrpc":"2.0","id":1,"method":"SendMessage","params":{"message":{"role":"ROLE_USER","parts":[{"text":"hi there"}],"messageId":"msg-fire"}}}'

for i in $(seq 1 "$N"); do
  resp=$(curl -s -w '\n%{http_code}' -X POST "$URL" \
    -H "Content-Type: application/json" \
    -H "A2A-Version: 1.0" \
    -d "$BODY")
  code=$(echo "$resp" | tail -n1)
  body=$(echo "$resp" | sed '$d')
  if [ "$code" = "429" ]; then
    echo "RATE_LIMITED (http-429)"
  elif echo "$body" | grep -q '"error"'; then
    echo "RATE_LIMITED (jsonrpc-error): $body"
  else
    echo "OK (http-$code)"
  fi
done
