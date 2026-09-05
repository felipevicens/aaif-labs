#!/usr/bin/env bash
set -euo pipefail
kind delete cluster --name agentgateway-backend-mtls
rm -rf "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/.certs"
