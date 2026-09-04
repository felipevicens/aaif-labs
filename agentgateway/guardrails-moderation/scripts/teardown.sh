#!/usr/bin/env bash
# Tears down everything setup.sh created. Deleting the kind cluster removes
# every namespace, Deployment, Secret and CRD it touched, including the
# openai-secret Secret, no need to kubectl delete things one by one first.
set -euo pipefail

CLUSTER_NAME="agentgateway-guardrails-moderation"

echo "==> Deleting kind cluster ($CLUSTER_NAME)"
kind delete cluster --name "$CLUSTER_NAME"
