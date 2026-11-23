#!/usr/bin/env bash
# Wait until a Railway deployment leaves its in-progress states, then print the final status.
# Usage: wait-deployment.sh DEPLOYMENT_ID [TIMEOUT_SECONDS]
set -euo pipefail
deployment_id="${1:?Usage: wait-deployment.sh DEPLOYMENT_ID [TIMEOUT_SECONDS]}"; timeout_seconds="${2:-600}"
deadline=$((SECONDS + timeout_seconds))
while (( SECONDS < deadline )); do
  status="$(railway api 'query($id:String!){deployment(id:$id){status}}' --var "id=${deployment_id}" --compact | jq -r '.data.deployment.status')"
  case "${status}" in
    SUCCESS|FAILED|CRASHED|CANCELED|REMOVED|SKIPPED) echo "${status}"; [[ "${status}" == SUCCESS ]]; exit ;;
  esac
  sleep 5
done
echo "TIMEOUT"; exit 1
