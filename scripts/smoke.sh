#!/usr/bin/env bash
# Application-level smoke test through the public gateway.
#
#   SMOKE_PHASE=initial  boundary checks (wizard closed, /files/ protected,
#                        private APIs need a Jellyfin login), admin sign-in with
#                        the generated password, a video upload through /files/,
#                        a library scan that finds it, direct play that returns
#                        the uploaded bytes, and an ffmpeg transcode.
#   SMOKE_PHASE=restart  after a Jellyfin restart: the same login, libraries,
#                        uploaded file, scanned item and playback still work.
#
# Needs curl, jq, ffmpeg and ffprobe. Credentials come from the environment and
# are never printed or placed in process arguments.
set -euo pipefail

base_url="${BASE_URL:-http://127.0.0.1:13096}"
base_url="${base_url%/}"
phase="${SMOKE_PHASE:-initial}"
gateway_username="${GATEWAY_USERNAME:-media-admin}"
gateway_password="${GATEWAY_PASSWORD:?Set GATEWAY_PASSWORD}"
admin_username="${JELLYFIN_ADMIN_USERNAME:-admin}"
admin_password="${JELLYFIN_ADMIN_PASSWORD:?Set JELLYFIN_ADMIN_PASSWORD}"
# Over HTTPS (Railway) Jellyfin must see the visitor's address, not the gateway's.
require_client_ip="${REQUIRE_CLIENT_IP:-$([[ "${base_url}" == https://* ]] && echo 1 || echo 0)}"
title="Railway Smoke Film"
folder="movies/${title} (2024)"
file_name="${title} (2024).mp4"
work_dir="$(mktemp -d)"
token=""
trap 'logout; rm -rf "${work_dir:?}"' EXIT

gateway_auth="${work_dir}/gateway.netrc"
host="$(sed -E 's#^[a-z]+://([^/:]+).*#\1#' <<<"${base_url}")"
printf 'machine %s login %s password %s\n' "${host}" "${gateway_username}" "${gateway_password}" >"${gateway_auth}"
chmod 600 "${gateway_auth}"

fail() { echo "FAIL: $*" >&2; exit 1; }
status() { curl --silent --output /dev/null --write-out '%{http_code}' --max-time 30 --path-as-is "$@"; }
gw() { curl --fail --silent --show-error --max-time 300 --netrc-file "${gateway_auth}" "$@"; }
urlpath() { jq -rn --arg value "$1" '$value|@uri'; }
client_header() {
  local header="MediaBrowser Client=\"Railway smoke\", Device=\"smoke\", DeviceId=\"railway-smoke-${phase}\", Version=\"1.0.0\""
  [[ -z "${token}" ]] || header+=", Token=\"${token}\""
  printf 'header = "Authorization: %s"\n' "${header//\"/\\\"}"
}
# The session token reaches curl through a config descriptor (printf is a builtin).
api() { curl --fail --silent --show-error --max-time 120 --config <(client_header) "$@"; }
logout() {
  [[ -n "${token}" ]] || return 0
  api -X POST "${base_url}/Sessions/Logout" >/dev/null 2>&1 || true
  token=""
}
credentials_json() {
  SMOKE_USERNAME="${admin_username}" SMOKE_PASSWORD="$1" jq -nc '{Username:env.SMOKE_USERNAME, Pw:env.SMOKE_PASSWORD}'
}

for _ in $(seq 1 150); do
  [[ "$(curl --silent --max-time 5 "${base_url}/healthz" || true)" == Healthy ]] && break
  sleep 2
done
[[ "$(curl --silent --max-time 5 "${base_url}/healthz" || true)" == Healthy ]] || fail "gateway /healthz did not report Jellyfin healthy within 300 seconds"

# The gateway only opens after the wrapper completed the wizard.
info="$(curl --fail --silent --show-error "${base_url}/System/Info/Public")"
jq -e '.StartupWizardCompleted==true' <<<"${info}" >/dev/null || fail "startup wizard is not complete"
echo "wizard: Jellyfin $(jq -r .Version <<<"${info}") reports the startup wizard complete"

# Public boundary. The wizard API and private APIs need an admin session, and
# the upload manager needs the gateway credential.
for request in "POST /Startup/User" "POST /startup/user" "POST /Startup/Complete" "GET /Startup/User" "GET /Startup/Configuration" "POST /Startup/RemoteAccess" "GET /Users" "GET /Library/VirtualFolders" "GET /System/Info" "POST /Library/Refresh" "GET /System/Configuration"; do
  method="${request%% *}" path="${request#* }"
  code="$(status -X "${method}" -H 'Content-Type: application/json' --data '{"Name":"probe","Password":"Probe-123456789012"}' "${base_url}${path}")"
  [[ "${code}" == 401 || "${code}" == 403 ]] || fail "anonymous ${request} returned ${code}, expected 401 or 403"
done
wrong_user="${gateway_username}:wrong-password-for-smoke"
for path in /files/ /files /FILES/ /%66iles/ "/files/?json" /files/movies/ //files/; do
  code="$(status "${base_url}${path}")"
  [[ "${code}" == 401 ]] || fail "anonymous GET ${path} returned ${code}, expected 401"
  code="$(status -u "${wrong_user}" "${base_url}${path}")"
  [[ "${code}" == 401 ]] || fail "wrong-password GET ${path} returned ${code}, expected 401"
done
for path in /files/movies/anonymous.txt /FILES/movies/anonymous.txt /%66iles/movies/anonymous.txt; do
  code="$(status -X PUT --data-binary 'x' "${base_url}${path}")"
  [[ "${code}" == 401 ]] || fail "anonymous upload ${path} returned ${code}, expected 401"
  code="$(status -u "${wrong_user}" -X PUT --data-binary 'x' "${base_url}${path}")"
  [[ "${code}" == 401 ]] || fail "wrong-password upload ${path} returned ${code}, expected 401"
done
code="$(credentials_json "wrong-password-for-smoke" | status -X POST -H 'Content-Type: application/json' --config <(client_header) --data-binary @- "${base_url}/Users/AuthenticateByName")"
[[ "${code}" == 401 ]] || fail "wrong admin password returned ${code}, expected 401"
echo "boundary: wizard and private APIs refuse anonymous calls; /files/ refuses anonymous and wrong credentials"

login="$(credentials_json "${admin_password}" | api -X POST -H 'Content-Type: application/json' --data-binary @- "${base_url}/Users/AuthenticateByName")"
token="$(jq -r '.AccessToken // empty' <<<"${login}")"
[[ -n "${token}" ]] || fail "admin sign-in returned no token"
jq -e --arg name "${admin_username}" '.User.Name==$name and .User.Policy.IsAdministrator==true' <<<"${login}" >/dev/null || fail "signed-in user is not the generated administrator"
echo "login: ${admin_username} is an administrator and signs in with the generated password"

libraries="$(api "${base_url}/Library/VirtualFolders")"
for spec in Movies:movies:/data/media/movies Shows:tvshows:/data/media/shows Music:music:/data/media/music; do
  IFS=: read -r name type path <<<"${spec}"
  jq -e --arg n "${name}" --arg t "${type}" --arg p "${path}" 'any(.[]; .Name==$n and .CollectionType==$t and (.Locations|index($p)!=null))' <<<"${libraries}" >/dev/null ||
    fail "library ${name} (${type}) at ${path} is missing"
done
echo "libraries: Movies, Shows and Music point at /data/media"

encoding="$(api "${base_url}/System/Configuration/encoding")"
jq -e '.EnableThrottling==true and .EnableSegmentDeletion==true' <<<"${encoding}" >/dev/null || fail "transcode throttling or segment deletion is off"

sessions="$(api "${base_url}/Sessions?deviceId=railway-smoke-${phase}")"
remote="$(jq -r '.[0].RemoteEndPoint // empty' <<<"${sessions}")"
if [[ "${require_client_ip}" == 1 ]]; then
  [[ -n "${remote}" ]] || fail "session has no remote address"
  if [[ "${remote}" =~ ^(10\.|100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.|127\.|::1|[fF][cdCD]) ]]; then
    fail "Jellyfin sees a private address for the visitor; forwarded headers are not trusted"
  fi
  echo "client address: Jellyfin sees the visitor's public address"
fi

movie_id() {
  # Match the uploaded path: the display name depends on metadata providers.
  api "${base_url}/Items?Recursive=true&IncludeItemTypes=Movie&Fields=Path" |
    jq -r --arg p "/data/media/${folder}/${file_name}" '[.Items[]|select(.Path==$p)][0].Id // empty'
}

if [[ "${phase}" == initial ]]; then
  ffmpeg -nostdin -loglevel error -f lavfi -i "testsrc2=size=640x360:rate=24:duration=4" -f lavfi -i "sine=frequency=440:duration=4" \
    -c:v libx264 -pix_fmt yuv420p -preset veryfast -c:a aac -shortest -movflags +faststart "${work_dir}/upload.mp4"
  [[ -z "$(movie_id)" ]] || fail "the smoke film already exists before upload; start from an empty volume"
  code="$(gw --write-out '%{http_code}' --output /dev/null -T "${work_dir}/upload.mp4" "${base_url}/files/$(urlpath "${folder}" | sed 's/%2F/\//g')/$(urlpath "${file_name}")")"
  [[ "${code}" == 201 ]] || fail "upload returned ${code}, expected 201"
  echo "upload: ${file_name} stored through /files/"
  api -X POST "${base_url}/Library/Refresh" >/dev/null
  id=""
  for attempt in $(seq 1 90); do
    id="$(movie_id)"
    [[ -n "${id}" ]] && break
    (( attempt % 15 == 0 )) && api -X POST "${base_url}/Library/Refresh" >/dev/null
    sleep 2
  done
  [[ -n "${id}" ]] || fail "library scan did not find ${title}"
  echo "scan: the uploaded film appears as a Movie after a library scan"
else
  id="$(movie_id)"
  [[ -n "${id}" ]] || fail "${title} did not survive restart"
  echo "restart: the scanned item survived"
fi

item="$(api "${base_url}/Items/${id}?Fields=Path,MediaSources")"
[[ "$(jq -r .Path <<<"${item}")" == "/data/media/${folder}/${file_name}" ]] || fail "item path is not the uploaded file"
gw -o "${work_dir}/stored.mp4" "${base_url}/files/$(urlpath "${folder}" | sed 's/%2F/\//g')/$(urlpath "${file_name}")"
api -o "${work_dir}/direct.mp4" "${base_url}/Videos/${id}/stream?static=true&mediaSourceId=${id}"
[[ -s "${work_dir}/stored.mp4" ]] || fail "stored file is empty"
cmp -s "${work_dir}/stored.mp4" "${work_dir}/direct.mp4" || fail "direct play did not return the uploaded bytes"
if [[ -f "${work_dir}/upload.mp4" ]]; then
  cmp -s "${work_dir}/upload.mp4" "${work_dir}/stored.mp4" || fail "stored file differs from the upload"
fi
echo "playback: direct play returns the uploaded file byte for byte"

# Transcode to a small H.264 stream; ffmpeg runs inside the Jellyfin container.
api -o "${work_dir}/transcoded.ts" \
  "${base_url}/Videos/${id}/stream.ts?static=false&mediaSourceId=${id}&container=ts&videoCodec=h264&audioCodec=aac&maxWidth=320&videoBitRate=300000&audioBitRate=64000&playSessionId=railway-smoke-${phase}"
width="$(ffprobe -v error -select_streams v:0 -show_entries stream=width,codec_name -of json "${work_dir}/transcoded.ts" | jq -r '.streams[0]|"\(.codec_name),\(.width)"' || true)"
[[ "${width}" == "h264,320" ]] || fail "transcode returned '${width}', expected h264 at width 320"
duration="$(ffprobe -v error -show_entries format=duration -of csv=p=0 "${work_dir}/transcoded.ts" | cut -d. -f1)"
(( duration >= 3 )) || fail "transcode is ${duration}s long, expected the full 4-second clip"
echo "transcode: ffmpeg produced a 320-pixel H.264 stream of the whole clip"

if [[ "${phase}" == restart ]]; then
  listing="$(gw "${base_url}/files/movies/?json")"
  jq -e --arg name "${title} (2024)" '.paths|any(.name==$name)' <<<"${listing}" >/dev/null || fail "upload folder did not survive restart"
fi

echo "PASS: Jellyfin ${phase} smoke through ${base_url}"
