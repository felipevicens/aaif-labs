#!/usr/bin/env bash
# End-to-end setup for the alerting-signals lab (G4 "What to Alert On (and
# What to Ignore)"). Stands up a gateway with one known-good HTTPRoute,
# then leaves two broken resources out of the initial apply so each
# scenario can be triggered on demand: a broken HTTPRoute (Kubernetes-
# resource layer) and a broken out-of-band health policy with malformed
# CEL (xDS/NACK layer).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
MANIFESTS_DIR="$LAB_DIR/manifests"

CLUSTER_NAME="agentgateway-alerting-signals"
GWAPI_VERSION="1.6.0"
AGW_VERSION="1.5.0"

if [ "$#" -gt 0 ]; then
  echo "Unknown argument: $1" >&2
  echo "Usage: $0" >&2
  exit 1
fi

echo "==> Creating kind cluster ($CLUSTER_NAME, node v1.34.0 pinned in kind-config.yaml)"
kind create cluster --name "$CLUSTER_NAME" --config "$LAB_DIR/kind-config.yaml"

echo "==> Installing Gateway API $GWAPI_VERSION (experimental channel)"
kubectl apply --server-side -f \
  "https://github.com/kubernetes-sigs/gateway-api/releases/download/v${GWAPI_VERSION}/experimental-install.yaml"

echo "==> Installing agentgateway CRDs $AGW_VERSION"
helm upgrade -i --create-namespace --namespace agentgateway-system \
  --version "v${AGW_VERSION}" agentgateway-crds \
  oci://cr.agentgateway.dev/charts/agentgateway-crds

echo "==> Installing agentgateway control plane $AGW_VERSION"
helm upgrade -i -n agentgateway-system agentgateway oci://cr.agentgateway.dev/charts/agentgateway \
  --version "v${AGW_VERSION}" \
  --set controller.extraEnv.KGW_ENABLE_GATEWAY_API_EXPERIMENTAL_FEATURES=true

echo "==> Waiting for the agentgateway GatewayClass to be accepted"
for i in $(seq 1 60); do
  kubectl get gatewayclass/agentgateway >/dev/null 2>&1 && break
  sleep 2
done
kubectl wait --for=jsonpath='{.status.conditions[?(@.type=="Accepted")].status}'=True \
  gatewayclass/agentgateway --timeout=120s

echo "==> Applying 01-namespace-and-backend.yaml (baseline: httpbun + gateway + good-route)"
kubectl apply -f "$MANIFESTS_DIR/01-namespace-and-backend.yaml"
kubectl wait --for=condition=Programmed gateway/agentgateway-proxy -n agentgateway-system --timeout=120s
kubectl wait --for=condition=Available deployment/agentgateway-proxy -n agentgateway-system --timeout=180s
kubectl wait --for=condition=Available deployment/httpbun -n alerting-signals --timeout=180s

cat <<EOF

==> Done. Port-forward the gateway, the proxy's own stats port (Scenario
    3's request metrics), and the control plane (Scenario 2's xDS-reject
    counter) - three separate port-forwards, each in its own terminal:
  kubectl port-forward -n agentgateway-system svc/agentgateway-proxy 8080:8080
  kubectl port-forward -n agentgateway-system deployment/agentgateway-proxy 15020:15020
  kubectl port-forward -n agentgateway-system deployment/agentgateway 9092:9092

  # Baseline: should succeed (200)
  curl -s http://localhost:8080/good -H "Host: alerting.internal"

  # Scenario 1: Kubernetes-resource layer. Apply a route pointing at a
  # Service that doesn't exist - should show ResolvedRefs: False,
  # reason: BackendNotFound, immediately, no traffic needed.
  kubectl apply -f "$MANIFESTS_DIR/02-broken-route.yaml"
  kubectl get httproute broken-route -n alerting-signals -o yaml
  curl -sS -o /dev/null -w "%{http_code}\n" http://localhost:8080/broken -H "Host: alerting.internal"   # 500

  # Scenario 2: xDS/NACK layer. Apply an out-of-band health policy with a
  # syntactically broken CEL unhealthyCondition. The resource's own status
  # shows Accepted: "True" with reason: PartiallyValid (read the message,
  # not just the boolean) and the proxy logs a real Nack. Existing traffic
  # on /good keeps working the whole time - the broken policy just never
  # takes effect.
  kubectl apply -f "$MANIFESTS_DIR/03-broken-health-policy.yaml"
  kubectl get agentgatewaypolicy httpbun-broken-health -n alerting-signals -o yaml
  kubectl logs -n agentgateway-system deployment/agentgateway-proxy --tail=20 | grep Nack
  curl -s http://localhost:9092/metrics | grep agentgateway_xds_rejects_total   # control plane :9092, port-forward it separately

  # Scenario 3: dataplane / live-request layer, the noisy one. /flaky is a
  # perfectly valid route to a backend that always answers 500 - nothing
  # wrong with any gateway config here at all.
  curl -sS -o /dev/null -w "%{http_code}\n" http://localhost:8080/flaky -H "Host: alerting.internal"   # 500
  curl -s http://localhost:15020/metrics | grep agentgateway_requests_total

See manifests/00-cluster-and-install.md for the full walkthrough.
EOF
