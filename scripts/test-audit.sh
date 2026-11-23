#!/usr/bin/env bash
# Offline regression cases for audit-template.sh. A stub `railway` returns a
# fixture built from the checked-in contract; the correct fixture must pass and
# each mutation must fail. Needs no network and no Railway credentials.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "${work:?}"' EXIT
mkdir "${work}/bin"
cat > "${work}/bin/railway" <<'STUB'
#!/usr/bin/env bash
jq -c '{data:{template:{name:"Jellyfin media server", status:"PUBLISHED", serializedConfig:.}}}' "${AUDIT_FIXTURE:?}"
STUB
chmod +x "${work}/bin/railway"

graph="$("${root}/scripts/iac-graph.sh")"
jq -n --argjson graph "${graph}" \
  --slurpfile defaults "${root}/template-defaults.json" --slurpfile descriptions "${root}/template-descriptions.json" \
  --slurpfile volumes "${root}/template-volumes.json" --slurpfile networking "${root}/template-networking.json" '
  {services: ([$graph.graph.resources[] | select(.type == "service")] | to_entries | map({key: ("svc-" + (.key|tostring)), value: (.value as $d | {
    name: $d.name, icon: null,
    source: (if $d.source.image then {image: $d.source.image} else {repo: $d.source.repo, branch: $d.source.branch, rootDirectory: $d.source.rootDirectory} end),
    deploy: {startCommand: ($d.deploy.startCommand // null), healthcheckPath: $d.deploy.healthcheckPath, healthcheckTimeout: $d.deploy.healthcheckTimeout,
      numReplicas: 1, restartPolicyType: "ON_FAILURE", restartPolicyMaxRetries: 10},
    variables: ($defaults[0][$d.name] | with_entries(.value = {defaultValue: .value, isOptional: false, description: $descriptions[0][$d.name][.key]}) ),
    networking: {serviceDomains: (if $networking[0][$d.name] then {"<hasDomain>": {port: $networking[0][$d.name].publicPort}} else {} end), customDomains: {}, tcpProxies: {}}
  } + (if $d.build then {build: $d.build} else {} end)
    + (if $volumes[0][$d.name] then {volumeMounts: {"vol-1": $volumes[0][$d.name]}} else {} end))}) | from_entries)}' > "${work}/good.json"

run() { AUDIT_FIXTURE="$1" PATH="${work}/bin:${PATH}" "${root}/scripts/audit-template.sh" tmpl PUBLISHED >/dev/null 2>&1; }
run "${work}/good.json" || { echo "FAIL: the correct fixture does not pass the audit" >&2; exit 1; }

failures=0
mutate() {
  local label="$1" filter="$2"
  jq "${filter}" "${work}/good.json" > "${work}/case.json"
  if run "${work}/case.json"; then echo "FAIL: audit accepted ${label}" >&2; failures=$((failures + 1)); else echo "ok: rejects ${label}"; fi
}
J='(.services|to_entries[]|select(.value.name=="Jellyfin")|.key) as $j'
G='(.services|to_entries[]|select(.value.name=="Jellyfin Gateway")|.key) as $g'
mutate "a gateway image with a trailing newline" "${G} | .services[\$g].source.image += \"\\n\""
mutate "an image beside the repository source" "${J} | .services[\$j].source.image = \"jellyfin/jellyfin:latest\""
mutate "another branch" "${J} | .services[\$j].source.branch = \"main\""
mutate "another repository" "${J} | .services[\$j].source.repo = \"someone/fork\""
mutate "a changed build block" "${J} | .services[\$j].build.dockerfilePath = \"Dockerfile.dev\""
mutate "a Jellyfin public domain" "${J} | .services[\$j].networking.serviceDomains = {\"<hasDomain>\": {port: 5001}}"
mutate "a custom domain on the upload port" "${J} | .services[\$j].networking.customDomains = {\"files.example.com\": {port: 5001}}"
mutate "a TCP proxy" "${J} | .services[\$j].networking.tcpProxies = {\"8096\": {}}"
mutate "two Jellyfin replicas" "${J} | .services[\$j].deploy.numReplicas = 2"
mutate "a NEVER restart policy" "${J} | .services[\$j].deploy.restartPolicyType = \"NEVER\""
mutate "a Jellyfin start command" "${J} | .services[\$j].deploy.startCommand = \"/jellyfin/jellyfin\""
mutate "a pre-deploy command" "${J} | .services[\$j].deploy.preDeployCommand = \"true\""
mutate "a literal admin password" "${J} | .services[\$j].variables.JELLYFIN_ADMIN_PASSWORD.defaultValue = \"literal-password-1234\""
mutate "a stored value beside a generated default" "${J} | .services[\$j].variables.JELLYFIN_ADMIN_PASSWORD.value = \"x\""
mutate "an optional gateway password" "${G} | .services[\$g].variables.GATEWAY_PASSWORD.isOptional = true"
mutate "an extra variable" "${G} | .services[\$g].variables.EXTRA = {defaultValue: \"x\", isOptional: false, description: \"\"}"
mutate "a missing gateway policy" "${G} | del(.services[\$g].variables.GATEWAY_CONFIG)"
mutate "a changed gateway policy" "${G} | .services[\$g].variables.GATEWAY_CONFIG.defaultValue |= sub(\"basic_auth\"; \"# basic_auth\")"
mutate "a string volume size" "${J} | .services[\$j].volumeMounts[\"vol-1\"].sizeMB = \"5000\""
mutate "a moved mount path" "${J} | .services[\$j].volumeMounts[\"vol-1\"].mountPath = \"/config\""
mutate "a gateway sharing the Jellyfin volume" "${G} | .services[\$g].volumeMounts = {\"vol-1\": {mountPath: \"/data\", sizeMB: 5000}}"
mutate "a third service" '.services.extra = (.services|to_entries[0].value|.name="Extra")'
mutate "a duplicated service name" "${G} | .services[\$g].name = \"Jellyfin\""
mutate "a bucket" '.buckets = {"b": {}}'
# Restore round trip: a generated draft with a seed image on Jellyfin, a stray
# custom domain, two replicas, stripped defaults and a stored value is restored
# through stubbed APIs, and the restored config must pass the audit.
J0='(.services|to_entries[]|select(.value.name=="Jellyfin")|.key) as $j'
jq "${J0} | .services[\$j].source = {image: \"jellyfin/jellyfin:12.4\"} | del(.services[\$j].build)
  | .services[\$j].networking.customDomains = {\"x.example.com\": {port: 5001}} | .services[\$j].deploy.numReplicas = 2
  | .services[] |= (.variables |= with_entries(.value = {value: \"resolved\"}))" "${work}/good.json" > "${work}/draft.json"
cat > "${work}/bin/curl" <<'STUB'
#!/usr/bin/env bash
body="$(cat)"
if jq -e '.query|test("templateUpsertConfig")' <<<"${body}" >/dev/null; then
  jq -c '.variables.input.serializedConfig' <<<"${body}" > "${RESTORED:?}"
  echo '{"data":{"templateUpsertConfig":{"id":"tmpl","code":"x"}}}'
else
  jq -c '{data:{templateUpsertSettings:{id:"tmpl", name:.variables.input.name}}}' <<<"${body}"
fi
STUB
chmod +x "${work}/bin/curl"
AUDIT_FIXTURE="${work}/draft.json" RESTORED="${work}/restored.json" RAILWAY_API_TOKEN=offline PATH="${work}/bin:${PATH}" \
  "${root}/scripts/restore-template-draft.sh" tmpl workspace >/dev/null
if run "${work}/restored.json"; then echo "ok: a restored generated draft passes the audit"; else echo "FAIL: the restored draft fails the audit" >&2; failures=$((failures + 1)); fi
if run "${work}/draft.json"; then echo "FAIL: audit accepted the unrestored draft" >&2; failures=$((failures + 1)); fi

(( failures == 0 )) || exit 1
echo "audit regression cases passed"
