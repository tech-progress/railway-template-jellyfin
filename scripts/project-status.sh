#!/usr/bin/env bash
# Prints one line per service instance in every environment of a project:
# environment, service, latest deployment status, running and crashed
# replica counts from the current instance state, and public domains.
# Usage: ./scripts/project-status.sh PROJECT_ID
set -euo pipefail
project_id="${1:?Usage: project-status.sh PROJECT_ID}"
railway api 'query($id:String!){project(id:$id){environments{edges{node{name serviceInstances{edges{node{serviceName
  domains{serviceDomains{domain targetPort}} latestDeployment{id status instances{status}}}}}}}}}}' --var "id=${project_id}" --compact \
  | jq -r '.data.project.environments.edges[].node as $e | $e.serviceInstances.edges[].node
    | [$e.name, .serviceName, (.latestDeployment.status // "NONE"),
       "running=\([.latestDeployment.instances[]? | select(.status == "RUNNING")] | length)",
       "crashed=\([.latestDeployment.instances[]? | select(.status == "CRASHED")] | length)",
       ([.domains.serviceDomains[]? | "\(.domain):\(.targetPort)"] | join(","))] | @tsv'
