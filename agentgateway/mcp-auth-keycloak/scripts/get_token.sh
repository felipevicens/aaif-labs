#!/usr/bin/env bash
# Gets a real Keycloak-issued access token via the Resource Owner
# Password Credentials grant, using the public `agentgateway` client
# 04-keycloak-setup-job.yaml creates. This is a shortcut around a full
# interactive authorization-code flow, standing in for "the client
# already completed browser login" so the rest of the lab can be
# scripted end to end.
#
# Usage: ./get_token.sh <username> <password>
set -euo pipefail

if [ "$#" -ne 2 ]; then
  echo "Usage: $0 <username> <password>" >&2
  exit 1
fi

curl -s -X POST \
  http://localhost:8081/realms/master/protocol/openid-connect/token \
  -d grant_type=password \
  -d client_id=agentgateway \
  -d username="$1" \
  -d password="$2" \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["access_token"])'
