#!/usr/bin/env bash
# Deploys the template's stored serializedConfig, unchanged, with the public
# templateDeployV2 mutation (the marketplace deployment path) into a new
# project, or into a fresh environment of an existing project.
# Prints the project and workflow IDs only.
# Usage: ./scripts/deploy-stored-template.sh TEMPLATE_ID WORKSPACE_ID [PROJECT_ID ENVIRONMENT_ID]
set -euo pipefail
template_id="${1:?Usage: deploy-stored-template.sh TEMPLATE_ID WORKSPACE_ID [PROJECT_ID ENVIRONMENT_ID]}"
workspace_id="${2:?Usage: deploy-stored-template.sh TEMPLATE_ID WORKSPACE_ID [PROJECT_ID ENVIRONMENT_ID]}"
project_id="${3:-}"; environment_id="${4:-}"
token="${RAILWAY_API_TOKEN:-$(jq -r '.user.accessToken' "${RAILWAY_CONFIG_PATH:-${HOME}/.railway/config.json}")}"
public() {
  curl --compressed --fail --silent --show-error https://backboard.railway.com/graphql/v2 \
    --config <(printf 'header = "Authorization: Bearer %s"\n' "${token}") -H 'Content-Type: application/json' --data-binary @-
}
config="$(jq -nc --arg id "${template_id}" '{query: "query($id:String!){template(id:$id){serializedConfig}}", variables: {id: $id}}' | public)"
jq -c --arg t "${template_id}" --arg w "${workspace_id}" --arg p "${project_id}" --arg e "${environment_id}" '
  {query: "mutation($input:TemplateDeployV2Input!){templateDeployV2(input:$input){projectId workflowId}}",
   variables: {input: ({templateId: $t, workspaceId: $w, serializedConfig: .data.template.serializedConfig}
     + (if $p != "" then {projectId: $p, environmentId: $e} else {} end))}}' <<<"${config}" \
  | public | jq -e -c 'if (.errors // []) | length > 0 then error("templateDeployV2 failed: \(.errors | map(.message) | join("; "))") else .data.templateDeployV2 end'
