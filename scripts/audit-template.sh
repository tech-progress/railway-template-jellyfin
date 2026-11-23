#!/usr/bin/env bash
# Audits Railway's stored serializedConfig for the Jellyfin template against the
# checked-in IaC and template-*.json files. Names mismatched fields only and
# never prints a resolved value.
# Usage: ./scripts/audit-template.sh TEMPLATE_ID [EXPECTED_STATUS]
set -euo pipefail
template_id="${1:?Usage: ./scripts/audit-template.sh TEMPLATE_ID [EXPECTED_STATUS]}"
expected_status="${2:-}"
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
name="Jellyfin media server"
fail() { echo "audit: FAIL $*" >&2; exit 1; }

template="$(railway api 'query Audit($id:String!){template(id:$id){name status serializedConfig}}' --var "id=${template_id}" --compact)"
graph="$("${root}/scripts/iac-graph.sh")"

# Every comparison below is between JSON encodings (jq -c): `jq -r` inside
# $(...) drops trailing newlines, so "image\n" would equal "image".
[[ "$(jq -c '.data.template.name' <<<"${template}")" == "$(jq -cn --arg n "${name}" '$n')" ]] || fail "template name"
[[ -z "${expected_status}" || "$(jq -c '.data.template.status' <<<"${template}")" == "$(jq -cn --arg s "${expected_status}" '$s')" ]] || fail "status"
expected_services="$(jq -r '[.graph.resources[] | select(.type == "service") | .name] | sort | join("\n")' <<<"${graph}")"
expected_services_json="$(jq -c '[.graph.resources[] | select(.type == "service") | .name] | sort' <<<"${graph}")"
# Shape: an ID-keyed services object, no other resources, no buckets.
jq -e '.data.template.serializedConfig | type == "object" and (.services | type) == "object"
  and ((keys - ["buckets", "services"]) == []) and ((has("buckets") | not) or .buckets == {}) and all(.services | keys[]; length > 0)' <<<"${template}" >/dev/null \
  || fail "graph shape or unexpected top-level resources"
[[ "$(jq -c '.data.template.serializedConfig.services | map(.name) | sort' <<<"${template}")" == "${expected_services_json}" ]] || fail "service set"
[[ "${expected_services_json}" == '["Jellyfin","Jellyfin Gateway"]' ]] || fail "IaC service set"
# Volume mounts: every mount ID nonempty and used once across the graph, so
# two services cannot share one volume.
jq -e '[.data.template.serializedConfig.services[] | (.volumeMounts // {}) | if type == "object" then keys[] else error("mounts") end] as $ids
  | all($ids[]; length > 0) and ($ids | length) == ($ids | unique | length)' <<<"${template}" >/dev/null 2>&1 \
  || fail "volume mount IDs must be nonempty and unique"

while IFS= read -r service; do
  desired="$(jq -c --arg n "${service}" '.graph.resources[] | select(.type == "service" and .name == $n)' <<<"${graph}")"
  actual="$(jq -c --arg n "${service}" '[.data.template.serializedConfig.services[] | select(.name == $n)] | if length == 1 then .[0] else error("duplicate") end' <<<"${template}")" \
    || fail "${service} appears more than once"
  if [[ "$(jq -c '.source.image // null' <<<"${desired}")" != null ]]; then
    [[ "$(jq -c '.source.image' <<<"${actual}")" == "$(jq -c '.source.image' <<<"${desired}")" ]] || fail "${service} image"
    [[ "$(jq -c '.source | keys' <<<"${actual}")" == '["image"]' ]] || fail "${service} mixed source"
    [[ "$(jq -c 'has("build")' <<<"${actual}")" == false ]] || fail "${service} build settings"
  else
    # Exactly the public distribution repository, release branch and root,
    # with no image beside it, and exactly the checked-in build block.
    [[ "$(jq -cS '.source' <<<"${actual}")" == "$(jq -cS '.source | {repo, branch, rootDirectory}' <<<"${desired}")" ]] || fail "${service} repository source"
    [[ "$(jq -cS '.source.repo' <<<"${desired}")" == '"tech-progress/railway-template-jellyfin"' && "$(jq -cS '.source.branch' <<<"${desired}")" == '"release-v1"' ]] || fail "${service} IaC source"
    [[ "$(jq -cS '.build' <<<"${actual}")" == "$(jq -cS '.build' <<<"${desired}")" ]] || fail "${service} build block"
  fi
  jq -e '(keys - ["build", "deploy", "icon", "name", "networking", "source", "variables", "volumeMounts"]) == []' <<<"${actual}" >/dev/null \
    || fail "${service} unexpected service fields"

  # The deploy block must be exactly this; any other key fails.
  expected_deploy="$(jq -cS '{startCommand: (.deploy.startCommand // null), healthcheckPath: (.deploy.healthcheckPath // null),
    healthcheckTimeout: (.deploy.healthcheckTimeout // null), numReplicas: 1, restartPolicyType: "ON_FAILURE", restartPolicyMaxRetries: 10}' <<<"${desired}")"
  [[ "$(jq -cS '.deploy' <<<"${actual}")" == "${expected_deploy}" ]] \
    || fail "${service} deploy block differs in: $(jq -r --argjson e "${expected_deploy}" '(.deploy // {}) as $a | ([$a, $e] | map(keys) | add | unique) | map(select($a[.] != $e[.])) | join(", ")' <<<"${actual}")"

  volume="$(jq -c --arg n "${service}" '.[$n] // null' "${root}/template-volumes.json")"
  if [[ "${volume}" == null ]]; then
    # Absent, or an empty object; an array or any other value fails.
    jq -e 'if has("volumeMounts") then .volumeMounts == {} else true end' <<<"${actual}" >/dev/null || fail "${service} unexpected volume"
  else
    # Compared as JSON, so a string "5000" or a missing size cannot pass.
    # The whole mount object is compared, so extra fields or an array fail.
    [[ "$(jq -cS 'if (.volumeMounts | type) == "object" and (.volumeMounts | length) == 1 then .volumeMounts | to_entries[0].value else "bad shape" end' <<<"${actual}")" \
      == "$(jq -cS '{mountPath, sizeMB}' <<<"${volume}")" ]] || fail "${service} volume"
  fi

  # The whole networking object, so an array or a stray key fails as well.
  expected_domains="$(jq -cS --arg n "${service}" 'if .[$n].publicPort != null then {"<hasDomain>": {port: .[$n].publicPort}} else {} end' "${root}/template-networking.json")"
  [[ "$(jq -cS '.networking' <<<"${actual}")" == "$(jq -cS --argjson d "${expected_domains}" -n '{serviceDomains: $d, customDomains: {}, tcpProxies: {}}')" ]] \
    || fail "${service} networking (public domain, custom domain or TCP proxy)"

  [[ "$(jq -c '(.variables // {}) | keys | sort' <<<"${actual}")" == "$(jq -c --arg n "${service}" '.[$n] | keys | sort' "${root}/template-defaults.json")" ]] \
    || fail "${service} variable set"
  # Values are compared as JSON so a number cannot stand in for a string, and
  # isOptional must be present and exactly false.
  while IFS= read -r key; do
    [[ "$(jq -c --arg k "${key}" '.variables[$k].defaultValue' <<<"${actual}")" == "$(jq -c --arg n "${service}" --arg k "${key}" '.[$n][$k]' "${root}/template-defaults.json")" ]] \
      || fail "${service} ${key} default"
    [[ "$(jq -c --arg k "${key}" '.variables[$k].description' <<<"${actual}")" == "$(jq -c --arg n "${service}" --arg k "${key}" '.[$n][$k]' "${root}/template-descriptions.json")" ]] \
      || fail "${service} ${key} description"
    [[ "$(jq -c --arg k "${key}" '.variables[$k] | if has("isOptional") then .isOptional else "missing" end' <<<"${actual}")" == false ]] || fail "${service} ${key} optional"
    # Nothing beside the three restored fields: a stored literal value would
    # otherwise sit next to a generated default.
    [[ "$(jq -c --arg k "${key}" '.variables[$k] | keys' <<<"${actual}")" == '["defaultValue","description","isOptional"]' ]] || fail "${service} ${key} extra fields"
  done < <(jq -r --arg n "${service}" '.[$n] | keys[]' "${root}/template-defaults.json")
done <<<"${expected_services}"

echo "Template ${template_id} matches the complete ${name} contract."
