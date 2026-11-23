#!/usr/bin/env bash
# Static verification: files, version, pins, IaC graph, Compose/Railway parity,
# marketplace copy, and the offline audit regression cases.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }

for file in .dockerignore .env.example .gitignore .railway/railway.ts CHANGELOG.md Dockerfile LICENSE_REVIEW.md MARKETPLACE.md PUBLISHING.md README.md SUPPORT.md UPGRADE.md VERSION bun.lock compose.yaml package.json railway-entrypoint.sh template-defaults.json template-descriptions.json template-networking.json template-volumes.json scripts/audit-template.sh scripts/check-standalone.sh scripts/iac-graph.sh scripts/local-check.sh scripts/restore-template-draft.sh scripts/smoke.sh scripts/test-audit.sh; do
  [[ -f "${root}/${file}" ]] || fail "missing ${file}"
done

version="$(<"${root}/VERSION")"
[[ "${version}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "VERSION is not SemVer"
grep -Eq "^## ${version//./\\.} - [0-9]{4}-[0-9]{2}-[0-9]{2}$" "${root}/CHANGELOG.md" || fail "CHANGELOG has no entry for ${version}"
for file in README.md PUBLISHING.md; do grep -Fq "current template release is \`v${version}\`" "${root}/${file}" || fail "${file} does not name v${version}"; done

for file in "${root}"/template-*.json; do jq empty "${file}"; done
for file in "${root}"/scripts/*.sh "${root}/railway-entrypoint.sh"; do bash -n "${file}"; done

jellyfin_pin='FROM jellyfin/jellyfin:12.4@sha256:fea863d0cd9ec445985d9c75fc6ed64e38a1d2766cf0c250a33d553f4fc1b771'
dufs_pin='FROM sigoden/dufs:v0.47.0@sha256:e5152c04e41d5a9d785546278b632bf035c8a08c52d7e8d35f4b59681f5ff35a AS dufs'
caddy_pin='caddy:2.11.9-alpine@sha256:0bbb055bda6793c999bde78b1b5ce3e89f829fb031af2cf50056ea1246559fee'
grep -Fxq "${jellyfin_pin}" "${root}/Dockerfile" || fail "Jellyfin pin"
grep -Fxq "${dufs_pin}" "${root}/Dockerfile" || fail "dufs pin"
! grep -Eq '^VOLUME' "${root}/Dockerfile" || fail "Railway rejects Dockerfile VOLUME"
grep -Eq 'DOTNET_gcServer=0' "${root}/Dockerfile" || fail "workstation GC keeps a single .NET instance small on Railway"
grep -Fq "image: ${caddy_pin}" "${root}/compose.yaml" || fail "Compose Caddy pin"

graph="$("${root}/scripts/iac-graph.sh")"
jq -e '.ok==true' <<<"${graph}" >/dev/null || fail "IaC graph did not compile"
jq -e '([.graph.resources[]|select(.type=="service")|.name]|sort)==["Jellyfin","Jellyfin Gateway"] and ([.graph.resources[]|select(.type=="volume")]|length)==1' <<<"${graph}" >/dev/null || fail "IaC service or volume set"
jq -e '.graph.resources[]|select(.name=="Jellyfin")|.source.repo=="tech-progress/railway-template-jellyfin" and .source.branch=="release-v1" and .source.rootDirectory=="/" and .build.builder=="DOCKERFILE" and .deploy.healthcheckPath=="/health" and .deploy.startCommand==null' <<<"${graph}" >/dev/null || fail "Jellyfin source, health check or start command"
jq -e --arg img "${caddy_pin}" '.graph.resources[]|select(.name=="Jellyfin Gateway")|.source.image==$img and .deploy.healthcheckPath=="/healthz"' <<<"${graph}" >/dev/null || fail "gateway image or health check"
jq -e '[.graph.resources[]|select(.type=="volume")|.config.sizeMB]==[5000]' <<<"${graph}" >/dev/null || fail "IaC volume size"
jq -e '[.graph.resources[]|select(.name=="Jellyfin Gateway")|.variables.GATEWAY_PASSWORD.value]==[""] and [.graph.resources[]|select(.name=="Jellyfin")|.variables.JELLYFIN_ADMIN_PASSWORD.value]==[""]' <<<"${graph}" >/dev/null ||
  fail "IaC must not derive a password without JELLYFIN_SOURCE_* values"
jq -e '."Jellyfin Gateway".GATEWAY_PASSWORD=="${{secret(32)}}" and .Jellyfin.JELLYFIN_ADMIN_PASSWORD=="${{secret(32)}}"' "${root}/template-defaults.json" >/dev/null || fail "marketplace passwords must be generated"
jq -en --slurpfile d "${root}/template-defaults.json" --slurpfile e "${root}/template-descriptions.json" '($d[0]|map_values(keys))==($e[0]|map_values(keys))' >/dev/null || fail "every default needs exactly one description"
[[ "$(jq -cS . "${root}/template-volumes.json")" == '{"Jellyfin":{"mountPath":"/data","sizeMB":5000}}' ]] || fail "volume contract"
[[ "$(jq -cS . "${root}/template-networking.json")" == '{"Jellyfin Gateway":{"publicPort":8080}}' ]] || fail "networking contract"

# Compose and Railway run the same gateway script and policy, and the same
# Jellyfin variables.
compose_json="$(GATEWAY_PASSWORD=verify-only-password JELLYFIN_ADMIN_PASSWORD=verify-only-password docker compose -f "${root}/compose.yaml" config --format json)"
[[ "$(jq -r '.services.gateway.command[0]' <<<"${compose_json}" | sed 's/\$\$/$/g')" == "$(jq -r '.graph.resources[]|select(.name=="Jellyfin Gateway").deploy.startCommand|ltrimstr("/bin/sh -ec '"'"'")|rtrimstr("'"'"'")' <<<"${graph}")" ]] || fail "Compose and Railway gateway start commands differ"
[[ "$(jq -r '.services.gateway.environment.GATEWAY_CONFIG|rtrimstr("\n")' <<<"${compose_json}")" == "$(jq -r '."Jellyfin Gateway".GATEWAY_CONFIG' "${root}/template-defaults.json")" ]] || fail "Compose and Railway gateway policies differ"
for key in PORT UPLOAD_PORT JELLYFIN_ADMIN_USERNAME; do
  [[ "$(jq -r --arg k "${key}" '.services.jellyfin.environment[$k]' <<<"${compose_json}")" == "$(jq -r --arg k "${key}" '.Jellyfin[$k]' "${root}/template-defaults.json")" ]] || fail "Compose Jellyfin ${key} differs"
done
[[ "$(jq -r '.services.gateway.environment.GATEWAY_USERNAME' <<<"${compose_json}")" == "$(jq -r '."Jellyfin Gateway".GATEWAY_USERNAME' "${root}/template-defaults.json")" ]] || fail "Compose gateway username differs"

# The gateway policy: Basic Auth on /files* only, the anonymous health route
# answers from Jellyfin's /health, and forwarded headers come from the edge.
policy="$(jq -r '."Jellyfin Gateway".GATEWAY_CONFIG' "${root}/template-defaults.json")"
grep -Fq 'handle /files* {' <<<"${policy}" || fail "policy lacks the /files handler"
[[ "$(grep -c 'basic_auth' <<<"${policy}")" == 1 ]] || fail "policy must have exactly one basic_auth block"
! grep -Eq '^\s*route\b' <<<"${policy}" || fail "use handle blocks only; Caddy sorts handle before route"
grep -Fq 'header_up X-Forwarded-For {http.request.header.X-Real-IP}' <<<"${policy}" || fail "policy must forward Railway's client address"
grep -Fq 'header_up -Authorization' <<<"${policy}" || fail "policy must strip the Basic credential before dufs"

for heading in '# Deploy and Host' '## About Hosting' '## Why Deploy' '## Common Use Cases' '## Dependencies for' '### Deployment Dependencies'; do
  grep -q "^${heading}" "${root}/MARKETPLACE.md" || fail "MARKETPLACE.md lacks ${heading}"
done
description="$(sed -n 's/^  --description "\(.*\)" \\$/\1/p' "${root}/PUBLISHING.md")"
(( ${#description} >= 45 && ${#description} <= 75 )) || fail "marketplace description must be 45-75 characters"
for link in https://github.com/jellyfin/jellyfin https://jellyfin.org https://github.com/sigoden/dufs; do
  grep -Fq "${link}" "${root}/README.md" || fail "README lacks ${link}"
done

"${root}/scripts/test-audit.sh" >/dev/null || fail "offline audit regression cases"
echo "Jellyfin template structure, pins, gateway parity, IaC graph, marketplace copy and audit cases are valid."
