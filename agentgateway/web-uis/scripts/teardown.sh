#!/usr/bin/env bash
set -euo pipefail
helm uninstall kagent -n kagent >/dev/null 2>&1 || true
helm uninstall kagent-crds -n kagent >/dev/null 2>&1 || true
kind delete cluster --name agentgateway-web-uis
