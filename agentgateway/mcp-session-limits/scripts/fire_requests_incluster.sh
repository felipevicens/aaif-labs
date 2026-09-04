#!/usr/bin/env bash
# Same as fire_requests.sh, but fires from a throwaway pod inside the
# cluster against the Service ClusterIP, instead of through
# `kubectl port-forward` on localhost.
#
# This matters specifically for the replica-scaling scenario: a single
# `kubectl port-forward` session holds one long-lived connection to one
# backend pod for its whole life, so it never exercises kube-proxy's
# per-connection load balancing across replicas — every request lands on
# whichever pod was picked when the tunnel opened. Firing from inside the
# cluster at the Service directly gets real load balancing, which is what
# any normal in-cluster client (or an Ingress/LoadBalancer in front of the
# Service) actually sees.
set -euo pipefail

N="${1:-20}"
NAMESPACE="agentgateway-system"
POD="fire-requests-incluster"
SCRIPT="/tmp/fire-requests-incluster.sh"

kubectl delete pod "$POD" -n "$NAMESPACE" --ignore-not-found >/dev/null 2>&1
kubectl run "$POD" -n "$NAMESPACE" --image=curlimages/curl:8.10.1 --restart=Never \
  --command -- sleep 300 >/dev/null
kubectl wait --for=condition=Ready "pod/$POD" -n "$NAMESPACE" --timeout=60s >/dev/null

cat <<INNER > /tmp/fire-requests-incluster.sh
URL="http://agentgateway-proxy.${NAMESPACE}.svc.cluster.local:8080/mcp"
BODY='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"fire","version":"1"}}}'
for i in \$(seq 1 $N); do
  resp=\$(curl -s -X POST "\$URL" \
    -H "Content-Type: application/json" \
    -H "Accept: application/json, text/event-stream" \
    -d "\$BODY")
  if echo "\$resp" | grep -q '"code":-32003'; then
    echo "RATE_LIMITED"
  else
    echo "OK"
  fi
done
INNER

kubectl cp /tmp/fire-requests-incluster.sh "${NAMESPACE}/${POD}:${SCRIPT}"
kubectl exec -n "$NAMESPACE" "$POD" -- sh "$SCRIPT"

kubectl delete pod "$POD" -n "$NAMESPACE" --ignore-not-found >/dev/null 2>&1
rm -f /tmp/fire-requests-incluster.sh
