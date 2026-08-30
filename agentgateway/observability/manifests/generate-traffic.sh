#!/usr/bin/env bash
# Traffic generator for the AgentGateway observability lab/post.
#
# Drives requests through the gateway as alice, bob, and carol so the
# Grafana dashboards (Scenario 4) have real, non-empty, distinguishable
# data to screenshot instead of a single flat spike. Default ratio
# (alice:bob:carol = 2:1:1) matches the numbers already quoted in the post.
#
# Requests are streamed (stream: true): Time To First Token and Tokens Per
# Second on the operational dashboard are only emitted for streaming calls
# (see "Gotchas worth remembering" in the post), so non-streaming traffic
# leaves those two panels empty.
#
# Requires: the gateway port-forwarded to localhost:8080 (Setup section),
# and alice/bob/carol's keys + team labels already applied (Scenario 3).
#
# Usage:
#   ./generate-traffic.sh                    # one pass: 4 alice, 2 bob, 2 carol
#   ROUNDS=6 SLEEP=15 ./generate-traffic.sh  # 6 passes, 15s apart, so the
#                                            # trend panels show several
#                                            # buckets instead of one burst
set -euo pipefail

GATEWAY_URL="${GATEWAY_URL:-http://localhost:8080/llm}"
LLM_MODEL="${LLM_MODEL:-gpt-oss-120b}"
ALICE_KEY="${ALICE_KEY:-sk-alice-abc123def456}"
BOB_KEY="${BOB_KEY:-sk-bob-xyz789uvw012}"
CAROL_KEY="${CAROL_KEY:-sk-carol-newkey999}"
ALICE_CALLS="${ALICE_CALLS:-4}"
BOB_CALLS="${BOB_CALLS:-2}"
CAROL_CALLS="${CAROL_CALLS:-2}"
ROUNDS="${ROUNDS:-1}"
SLEEP="${SLEEP:-5}"

BODY="{\"model\":\"$LLM_MODEL\",\"max_tokens\":20,\"stream\":true,\"messages\":[{\"role\":\"user\",\"content\":\"Say OK\"}]}"

call() {
  local name="$1" key="$2"
  local code
  code=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$GATEWAY_URL" \
    -H 'Content-Type: application/json' -H "Authorization: Bearer $key" -d "$BODY")
  echo "  $name -> HTTP $code"
}

for round in $(seq 1 "$ROUNDS"); do
  echo "Round $round/$ROUNDS"
  for _ in $(seq 1 "$ALICE_CALLS"); do call alice "$ALICE_KEY"; done
  for _ in $(seq 1 "$BOB_CALLS"); do call bob "$BOB_KEY"; done
  for _ in $(seq 1 "$CAROL_CALLS"); do call carol "$CAROL_KEY"; done
  if [ "$round" -lt "$ROUNDS" ]; then
    echo "  sleeping ${SLEEP}s..."
    sleep "$SLEEP"
  fi
done

echo "Done: $((ALICE_CALLS * ROUNDS)) alice, $((BOB_CALLS * ROUNDS)) bob, $((CAROL_CALLS * ROUNDS)) carol calls sent to $GATEWAY_URL"
