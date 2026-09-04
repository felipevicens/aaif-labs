#!/usr/bin/env bash
# End-to-end setup for the budget-limits lab (C2 "Give Every Team a
# Budget, Not Just a Key"). Fully keyless: no provider credentials
# anywhere. See manifests/00-cluster-and-install.md for what each step
# proves.
#
# Usage:
#   ./setup.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
MANIFESTS_DIR="$LAB_DIR/manifests"

CLUSTER_NAME="agentgateway-budget-limits"
GWAPI_VERSION="1.6.0"
AGW_VERSION="1.5.0"

if [ "$#" -gt 0 ]; then
  echo "Unknown argument: $1" >&2
  echo "Usage: $0" >&2
  exit 1
fi

echo "==> Creating kind cluster ($CLUSTER_NAME, node v1.34.0 pinned in kind-config.yaml)"
kind create cluster --name "$CLUSTER_NAME" --config "$LAB_DIR/kind-config.yaml"

echo "==> Installing Gateway API $GWAPI_VERSION (experimental channel: global rate limiting needs it)"
kubectl apply --server-side -f \
  "https://github.com/kubernetes-sigs/gateway-api/releases/download/v${GWAPI_VERSION}/experimental-install.yaml"

echo "==> Installing agentgateway CRDs $AGW_VERSION"
helm upgrade -i --create-namespace --namespace agentgateway-system \
  --version "v${AGW_VERSION}" agentgateway-crds \
  oci://cr.agentgateway.dev/charts/agentgateway-crds

echo "==> Installing agentgateway control plane $AGW_VERSION (experimental Gateway API features on)"
helm upgrade -i -n agentgateway-system agentgateway oci://cr.agentgateway.dev/charts/agentgateway \
  --version "v${AGW_VERSION}" \
  --set controller.extraEnv.KGW_ENABLE_GATEWAY_API_EXPERIMENTAL_FEATURES=true

echo "==> Waiting for the agentgateway GatewayClass to exist"
for i in $(seq 1 60); do
  kubectl get gatewayclass/agentgateway >/dev/null 2>&1 && break
  sleep 2
done

echo "==> Waiting for the agentgateway GatewayClass to be accepted"
kubectl wait --for=jsonpath='{.status.conditions[?(@.type=="Accepted")].status}'=True \
  gatewayclass/agentgateway --timeout=120s

echo "==> Applying 01-gateway-and-backend.yaml"
kubectl apply -f "$MANIFESTS_DIR/01-gateway-and-backend.yaml"
kubectl wait --for=condition=Available deployment/budget-mock-backend -n agentgateway-system --timeout=120s
kubectl wait --for=condition=Programmed gateway/agentgateway-proxy -n agentgateway-system --timeout=120s

echo "==> Applying 02-api-keys-secret.yaml"
kubectl apply -f "$MANIFESTS_DIR/02-api-keys-secret.yaml"

echo "==> Applying 03-ratelimit-namespace.yaml"
kubectl apply -f "$MANIFESTS_DIR/03-ratelimit-namespace.yaml"
kubectl wait --for=condition=Available deployment/redis -n ratelimit --timeout=120s
kubectl wait --for=condition=Available deployment/ratelimit -n ratelimit --timeout=120s

echo "==> Applying 04-apikey-auth-plus-team-budget-policy.yaml"
kubectl apply -f "$MANIFESTS_DIR/04-apikey-auth-plus-team-budget-policy.yaml"

cat <<'EOF'

==> Done. Reach the gateway with:
  kubectl port-forward -n agentgateway-system svc/agentgateway-proxy 8080:8080

  # Scenario A: two teams, separate pools. Expect 200, 200, 429 for bob,
  # then 200 for alice (a different team) right after -- unaffected.
  for i in 1 2 3; do
    curl -s -o /dev/null -w "bob call $i -> HTTP %{http_code}\n" \
      -X POST http://localhost:8080/work -H 'Content-Type: application/json' \
      -H 'Authorization: Bearer sk-bob-team-research' -d '{}'
  done
  curl -s -o /dev/null -w "alice call 1 -> HTTP %{http_code}\n" \
    -X POST http://localhost:8080/work -H 'Content-Type: application/json' \
    -H 'Authorization: Bearer sk-alice-team-platform' -d '{}'

  # Scenario B, part 1: alice's own tight cap (2/min) fires on her 3rd
  # call, with the platform team pool (4/min) only half full at that
  # point. Expect 200, 429 (this is her calls 2 and 3; call 1 was above).
  for i in 2 3; do
    curl -s -o /dev/null -w "alice call $i -> HTTP %{http_code}\n" \
      -X POST http://localhost:8080/work -H 'Content-Type: application/json' \
      -H 'Authorization: Bearer sk-alice-team-platform' -d '{}'
  done

  # Scenario B, part 2: carol's own cap (5/min) is nowhere close, but the
  # platform team pool is now exhausted -- including by alice's *rejected*
  # 3rd call above, which still spent a team-pool slot. Expect 200, 429,
  # 429: carol's 2nd call already finds the pool empty, not her 3rd.
  for i in 1 2 3; do
    curl -s -o /dev/null -w "carol call $i -> HTTP %{http_code}\n" \
      -X POST http://localhost:8080/work -H 'Content-Type: application/json' \
      -H 'Authorization: Bearer sk-carol-team-platform' -d '{}'
  done
EOF
