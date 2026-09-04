#!/usr/bin/env bash
# Tears down everything setup.sh (and manifests/03-mcp-server-b.yaml, if
# applied) created. Deleting the kind cluster removes every namespace,
# Deployment and CRD it touched, no need to kubectl delete things one by
# one first.
set -euo pipefail

CLUSTER_NAME="agentgateway-dynamic-mcp"

echo "==> Deleting kind cluster ($CLUSTER_NAME)"
kind delete cluster --name "$CLUSTER_NAME"
