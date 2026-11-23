#!/usr/bin/env bash
# Restores the Jellyfin draft to the checked-in contract through the Template
# Composer operation (templateUpsertConfig): the repository source and build of
# Jellyfin, the gateway image, whole deploy blocks, variable defaults (generated
# secrets and references), descriptions, the volume size, and the gateway-only
# public domain. Prints no secret.
# Usage: ./scripts/restore-template-draft.sh TEMPLATE_ID WORKSPACE_ID
set -euo pipefail
template_id="${1:?Usage: ./scripts/restore-template-draft.sh TEMPLATE_ID WORKSPACE_ID}"
workspace_id="${2:?Usage: ./scripts/restore-template-draft.sh TEMPLATE_ID WORKSPACE_ID}"
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
name="Jellyfin media server"
token="${RAILWAY_API_TOKEN:-$(jq -r '.user.accessToken' "${RAILWAY_CONFIG_PATH:-${HOME}/.railway/config.json}")}"

desired="$("${root}/scripts/iac-graph.sh" | jq -c '[.graph.resources[] | select(.type == "service") | {key: .name, value: {source, build, deploy}}] | from_entries')"
draft="$(railway api 'query Draft($id:String!){template(id:$id){serializedConfig}}' --var "id=${template_id}" --compact)"

# The draft travels on stdin: it may carry resolved values.
variables="$(jq -c --argjson desired "${desired}" \
  --slurpfile defaults "${root}/template-defaults.json" \
  --slurpfile descriptions "${root}/template-descriptions.json" \
  --slurpfile volumes "${root}/template-volumes.json" \
  --slurpfile networking "${root}/template-networking.json" \
  --arg id "${template_id}" --arg workspaceId "${workspace_id}" --arg name "${name}" '
  .data.template.serializedConfig as $config
  | if ($config | type) != "object" or ($config.services | type) != "object" then error("Draft services must be an object keyed by ID")
    elif (($config | keys) - ["buckets", "services"]) != [] then error("Draft has unexpected top-level resources")
    elif ($config | has("buckets")) and $config.buckets != {} then error("Draft has buckets")
    elif any($config.services | keys[]; length == 0) then error("Draft has an empty service ID")
    elif (($config.services | map(.name) | sort) != ($desired | keys | sort)) then error("Draft service set mismatch")
    elif ([$config.services[] | (.volumeMounts // {}) | if type == "object" then keys[] else "" end] as $ids
          | any($ids[]; length == 0) or ($ids | length) != ($ids | unique | length)) then error("Draft volume mount IDs must be nonempty and unique")
    else reduce ($config.services | to_entries[]) as $s ({buckets: {}, services: $config.services};
      $desired[$s.value.name] as $want
      | if $want.source.image != null then
          .services[$s.key].source = {image: $want.source.image}
          | del(.services[$s.key].build)
        else
          .services[$s.key].source = {repo: $want.source.repo, branch: $want.source.branch, rootDirectory: $want.source.rootDirectory}
          | .services[$s.key].build = $want.build
        end
      # Replace the whole deploy block so inherited settings (pre-deploy
      # commands, cron schedules, replica counts, regions) cannot survive.
      # Jellyfin keeps SQLite on one volume: exactly one replica.
      | .services[$s.key].deploy = {
          startCommand: ($want.deploy.startCommand // null),
          healthcheckPath: ($want.deploy.healthcheckPath // null),
          healthcheckTimeout: ($want.deploy.healthcheckTimeout // null),
          numReplicas: 1, restartPolicyType: "ON_FAILURE", restartPolicyMaxRetries: 10}
      | .services[$s.key] |= with_entries(select(.key | IN("build", "deploy", "icon", "name", "networking", "source", "variables", "volumeMounts")))
      | .services[$s.key].variables = reduce (($defaults[0][$s.value.name] // {}) | to_entries[]) as $v ({};
          .[$v.key] = {defaultValue: $v.value, isOptional: false,
            description: ($descriptions[0][$s.value.name][$v.key] // "")})
      | if $volumes[0][$s.value.name] != null then
          if ((.services[$s.key].volumeMounts // {}) | type) != "object" or ((.services[$s.key].volumeMounts // {}) | length) != 1
          then error("Draft volume mount missing for " + $s.value.name)
          else .services[$s.key].volumeMounts |= with_entries(
            .value = {mountPath: $volumes[0][$s.value.name].mountPath, sizeMB: $volumes[0][$s.value.name].sizeMB}) end
        else del(.services[$s.key].volumeMounts) end
      # Replace the whole networking object so no custom domain or TCP proxy survives.
      | if $networking[0][$s.value.name].publicPort != null
        then .services[$s.key].networking = {serviceDomains: {"<hasDomain>": {port: $networking[0][$s.value.name].publicPort}}, customDomains: {}, tcpProxies: {}}
        else .services[$s.key].networking = {serviceDomains: {}, customDomains: {}, tcpProxies: {}} end)
      | {id: $id, input: {name: $name, workspaceId: $workspaceId, serializedConfig: .}}
    end' <<<"${draft}")"

internal() {
  curl --compressed --fail --silent --show-error https://backboard.railway.com/graphql/internal \
    --config <(printf 'header = "Authorization: Bearer %s"\n' "${token}") -H 'Content-Type: application/json' --data-binary @- <<<"$1"
}
request="$(jq -c --arg query 'mutation Update($id:String!,$input:TemplateUpsertConfigInput!){templateUpsertConfig(id:$id,input:$input){id code}}' '{query:$query,variables:.}' <<<"${variables}")"
response="$(internal "${request}")"
jq -e '.data.templateUpsertConfig.id != null and ((.errors // []) | length == 0)' <<<"${response}" >/dev/null ||
  { echo "templateUpsertConfig failed: $(jq -r '[.errors[]?.message] | join("; ")' <<<"${response}")" >&2; exit 1; }
settings="$(jq -nc --arg id "${template_id}" --arg workspaceId "${workspace_id}" --arg name "${name}" --arg query 'mutation Settings($id:String!,$input:TemplateUpsertSettingsInput!){templateUpsertSettings(id:$id,input:$input){id name}}' '{query:$query,variables:{id:$id,input:{name:$name,workspaceId:$workspaceId}}}')"
response="$(internal "${settings}")"
jq -e --arg name "${name}" '.data.templateUpsertSettings.name == $name and ((.errors // []) | length == 0)' <<<"${response}" >/dev/null ||
  { echo "templateUpsertSettings failed: $(jq -r '[.errors[]?.message] | join("; ")' <<<"${response}")" >&2; exit 1; }
echo "Restored ${name} draft ${template_id}."
