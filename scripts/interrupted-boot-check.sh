#!/usr/bin/env bash
# Interrupted first boot: the wrapper had created its marker, Jellyfin had
# stored the administrator's password through the wizard, and the container
# was killed before the libraries, encoding settings and port switch. Jellyfin
# itself then marks the wizard complete on its next start. The wrapper must
# resume provisioning on loopback and finish it, not open port 8096 early.
#
# Usage: ENGINE=podman IMAGE=jellyfin-media-server:local ./scripts/interrupted-boot-check.sh
# Uses its own volume and containers (no published ports) and removes them.
set -euo pipefail
engine="${ENGINE:-podman}"
image="${IMAGE:-jellyfin-media-server:local}"
work="$(mktemp -d)"
name="jellyfin-interrupted-$$"
cleanup() {
  "${engine}" rm -f "${name}-seed" "${name}" >/dev/null 2>&1 || true
  "${engine}" volume rm -f "${name}" >/dev/null 2>&1 || true
  rm -rf "${work:?}"
}
trap cleanup EXIT
fail() { echo "interrupted-boot-check: $*" >&2; exit 1; }

gen() { python3 -I -c 'import secrets, string; a = string.ascii_letters + string.digits; print("".join(secrets.choice(a) for _ in range(32)))'; }
( umask 077; printf 'PORT=8096\nJELLYFIN_ADMIN_USERNAME=admin\nJELLYFIN_ADMIN_PASSWORD=%s\n' "$(gen)" > "${work}/env" )
in_container() { "${engine}" exec -i "$1" sh -ec "$2"; }
# Credentials travel on stdin, never in arguments.
auth_json() { grep '^JELLYFIN_ADMIN_PASSWORD=' "${work}/env" | cut -d= -f2- | jq -Rc '{Username:"admin", Pw:., Name:"admin", Password:.}'; }
hdr='Authorization: MediaBrowser Client="check", Device="check", DeviceId="interrupted-check", Version="1"'

"${engine}" volume create "${name}" >/dev/null
# Seed: plain Jellyfin (no wrapper) on the new volume, wizard steps up to the
# administrator's password, then SIGKILL. The marker is what the wrapper writes
# before its first wizard call.
"${engine}" run -d --name "${name}-seed" --memory 1g --cpus 1 -v "${name}:/data" --entrypoint /jellyfin/jellyfin "${image}" >/dev/null
for _ in $(seq 120); do
  in_container "${name}-seed" 'curl -fsS -m 3 http://127.0.0.1:8096/System/Info/Public 2>/dev/null | grep -q "\"StartupWizardCompleted\":false" && [ "$(curl -fsS -m 3 http://127.0.0.1:8096/health)" = Healthy ]' 2>/dev/null && break
  sleep 2
done
in_container "${name}-seed" "curl -fsS -o /dev/null -H '${hdr}' -H 'Content-Type: application/json' -d '{\"ServerName\":\"x\",\"UICulture\":\"en-US\",\"MetadataCountryCode\":\"US\",\"PreferredMetadataLanguage\":\"en\"}' http://127.0.0.1:8096/Startup/Configuration && curl -fsS -o /dev/null -H '${hdr}' http://127.0.0.1:8096/Startup/User"
auth_json | in_container "${name}-seed" "curl -fsS -o /dev/null -H '${hdr}' -H 'Content-Type: application/json' --data-binary @- http://127.0.0.1:8096/Startup/User"
in_container "${name}-seed" ': > /data/jellyfin/config/railway-bootstrap-network'
"${engine}" kill -s KILL "${name}-seed" >/dev/null
"${engine}" rm -f "${name}-seed" >/dev/null

"${engine}" run -d --name "${name}" --memory 1536m --cpus 2 -v "${name}:/data" --env-file "${work}/env" "${image}" >/dev/null
for _ in $(seq 150); do
  [[ "$(in_container "${name}" 'curl -s -m 3 http://127.0.0.1:8096/health' 2>/dev/null)" == Healthy ]] && break
  "${engine}" inspect "${name}" --format '{{.State.Running}}' | grep -q true || fail "the wrapper exited: $("${engine}" logs --tail 5 "${name}" 2>&1)"
  sleep 2
done
logs="$("${engine}" logs "${name}" 2>&1)"
grep -q 'an earlier first boot stopped before provisioning finished; resuming on 127.0.0.1:18096' <<<"${logs}" || fail "no resume marker in the log"
grep -q 'startup wizard completed for admin user admin' <<<"${logs}" || fail "provisioning did not finish"
first_bind="$(grep 'Kestrel is listening on' <<<"${logs}" | head -1)"
[[ "${first_bind}" == *'listening on 127.0.0.1'* ]] || fail "the resumed boot listened on the network first: ${first_bind}"

token="$(auth_json | in_container "${name}" "curl -fsS -H '${hdr}' -H 'Content-Type: application/json' --data-binary @- http://127.0.0.1:8096/Users/AuthenticateByName" | jq -r .AccessToken)"
[[ -n "${token}" && "${token}" != null ]] || fail "admin sign-in failed after the resumed provisioning"
# The token reaches curl as a config file on stdin, never as an argument.
with_token() { CHECK_TOKEN="${token}" CHECK_HDR="${hdr}" jq -rn '"header = \"" + ((env.CHECK_HDR + ", Token=\"" + env.CHECK_TOKEN + "\"")|gsub("\""; "\\\"")) + "\""' | "${engine}" exec -i "${name}" curl -fsS -K - "$@"; }
libraries="$(with_token http://127.0.0.1:8096/Library/VirtualFolders)"
encoding="$(with_token http://127.0.0.1:8096/System/Configuration/encoding)"
with_token -o /dev/null -X POST http://127.0.0.1:8096/Sessions/Logout
[[ "$(jq -c '[.[].Name]|sort' <<<"${libraries}")" == '["Movies","Music","Shows"]' ]] || fail "libraries after resume: $(jq -c '[.[].Name]' <<<"${libraries}")"
jq -e '.EnableThrottling==true and .EnableSegmentDeletion==true' <<<"${encoding}" >/dev/null || fail "encoding settings were not applied on resume"
in_container "${name}" '[ ! -e /data/jellyfin/config/railway-bootstrap-network ] && grep -q "<InternalHttpPort>8096<" /data/jellyfin/config/network.xml' || fail "the marker or the bootstrap port survived"
echo "interrupted-boot-check: ok an interrupted first boot resumed on loopback and finished libraries, encoding and the port switch"
