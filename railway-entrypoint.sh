#!/bin/bash
# Railway wrapper for the official Jellyfin image.
#
# Volume layout (one Railway volume mounted at /data):
#   /data/jellyfin  Jellyfin data, config, logs, metadata and plugins
#   /data/cache     image cache and transcode segments
#   /data/media     movies/, shows/ and music/ libraries, written by dufs
#
# First boot: Jellyfin starts bound to 127.0.0.1:18096 only, the wrapper
# completes the startup wizard with JELLYFIN_ADMIN_USERNAME and
# JELLYFIN_ADMIN_PASSWORD, creates the three libraries, and stops it. Only then
# does Jellyfin listen on 8096, the port the gateway and Railway's health check
# use, so the open wizard is never reachable from the network. A boot after an
# interrupted first boot resumes the same provisioning on loopback.
#
# Every boot: Jellyfin and the private dufs upload server run side by side. If
# either exits, the other is stopped and the container exits nonzero so
# Railway's ON_FAILURE restart policy brings the service back.
set -euo pipefail
# Bash as PID 1 ignores TERM and INT without a handler. Until a step installs
# its own, a stop request ends the wrapper; an unfinished provisioning resumes
# on the next boot because its marker is still on the volume.
trap 'exit 143' TERM INT

data=/data
jellyfin_data="${data}/jellyfin"
config_dir="${jellyfin_data}/config"
cache_dir="${data}/cache"
media_dir="${data}/media"
bootstrap_port=18096
jellyfin_port=8096
curl_pid=""
upload_port="${UPLOAD_PORT:-5001}"
bootstrap_marker="${config_dir}/railway-bootstrap-network"

fail() { echo "railway-entrypoint: $*" >&2; exit 64; }

[[ "${JELLYFIN_DATA_DIR:-}" == "${jellyfin_data}" && "${JELLYFIN_CONFIG_DIR:-}" == "${config_dir}" && "${JELLYFIN_CACHE_DIR:-}" == "${cache_dir}" ]] ||
  fail "JELLYFIN_DATA_DIR, JELLYFIN_CONFIG_DIR and JELLYFIN_CACHE_DIR must keep the image defaults under /data."
[[ "${PORT:-${jellyfin_port}}" == "${jellyfin_port}" ]] || fail "PORT must be ${jellyfin_port}; Jellyfin listens there."
[[ "${upload_port}" =~ ^[0-9]+$ && "${upload_port}" != "${jellyfin_port}" && "${upload_port}" != "${bootstrap_port}" ]] ||
  fail "UPLOAD_PORT must be a port number other than ${jellyfin_port} and ${bootstrap_port}."

# The volume root must be a real directory, and nothing the wrapper creates
# below it may be a symbolic link that leads off the volume.
[[ -d "${data}" && ! -L "${data}" ]] || fail "${data} must be the mounted volume, not a link."
for dir in "${jellyfin_data}" "${config_dir}" "${jellyfin_data}/log" "${cache_dir}" "${media_dir}" "${media_dir}/movies" "${media_dir}/shows" "${media_dir}/music"; do
  [[ ! -L "${dir}" ]] || fail "${dir} is a symbolic link; refusing to follow it off the volume."
  mkdir -p "${dir}"
done

wizard_completed() {
  grep -q '<IsStartupWizardCompleted>true</IsStartupWizardCompleted>' "${config_dir}/system.xml" 2>/dev/null
}

# network.xml is written only by the bootstrap. Once the wizard is complete the
# administrator owns it through the dashboard.
write_network_config() {
  local port="$1" bind="$2"
  {
    printf '%s\n' '<?xml version="1.0" encoding="utf-8"?>'
    printf '%s\n' '<NetworkConfiguration xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xmlns:xsd="http://www.w3.org/2001/XMLSchema">'
    printf '  <InternalHttpPort>%s</InternalHttpPort>\n  <PublicHttpPort>%s</PublicHttpPort>\n' "${port}" "${port}"
    # UDP discovery cannot reach a Railway service.
    printf '%s\n' '  <AutoDiscovery>false</AutoDiscovery>' '  <EnableIPv4>true</EnableIPv4>' '  <EnableIPv6>true</EnableIPv6>' '  <EnableRemoteAccess>true</EnableRemoteAccess>'
    if [[ "${bind}" == loopback ]]; then
      printf '%s\n' '  <LocalNetworkAddresses>' '    <string>127.0.0.1</string>' '  </LocalNetworkAddresses>'
    else
      printf '%s\n' '  <LocalNetworkAddresses />'
    fi
    # The gateway reaches Jellyfin from Railway's private network and replaces
    # X-Forwarded-For with the client address Railway's edge reports.
    printf '%s\n' '  <KnownProxies>' '    <string>10.0.0.0/8</string>' '    <string>100.64.0.0/10</string>' '    <string>172.16.0.0/12</string>' '    <string>fd00::/8</string>' '  </KnownProxies>'
    printf '%s\n' '</NetworkConfiguration>'
  } >"${config_dir}/network.xml.tmp"
  mv "${config_dir}/network.xml.tmp" "${config_dir}/network.xml"
}

finish_network_config() {
  write_network_config "${jellyfin_port}" all
  # Awaited with the wait builtin so a stop request is not held until sync
  # ends; an interrupted sync leaves the marker, and the next boot resumes.
  sync &
  wait "$!"
  rm -f "${bootstrap_marker:?}"
}

start_jellyfin() {
  # Proxy variables must not capture loopback calls, and the admin password
  # must not reach Jellyfin, plugins or ffmpeg.
  env -u JELLYFIN_ADMIN_PASSWORD -u JELLYFIN_ADMIN_USERNAME /jellyfin/jellyfin &
  jellyfin_pid=$!
}

child_alive() {
  # A child that exited but is not yet reaped is a zombie (state Z).
  [[ -r "/proc/$1/stat" ]] && [[ "$(sed 's/^.*) //' "/proc/$1/stat" 2>/dev/null | cut -d' ' -f1)" != Z ]]
}

# Stop children within a bounded time. Jellyfin ignores TERM in its first
# seconds, before its host has registered a handler, so TERM is repeated every
# second and anything still running after 20 seconds gets KILL.
stop_children() {
  local pid alive=0 deadline=$((SECONDS + 20))
  kill -TERM "$@" 2>/dev/null || true
  while (( SECONDS < deadline )); do
    alive=0
    for pid in "$@"; do child_alive "${pid}" && alive=1; done
    (( alive )) || break
    sleep 1
    kill -TERM "$@" 2>/dev/null || true
  done
  if (( alive )); then
    echo "railway-entrypoint: a child ignored TERM for 20 seconds; sending KILL." >&2
    kill -KILL "$@" 2>/dev/null || true
  fi
  for pid in "$@"; do wait "${pid}" 2>/dev/null || true; done
}

json_string() {
  # Escape a value for a JSON string literal. Control characters were refused.
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  printf '"%s"' "${value}"
}

# Provisioning is finished only when the marker is gone. It is created before
# the first wizard call and removed after the libraries, encoding settings and
# final network.xml are in place. Jellyfin itself marks the wizard complete on
# start once its first user has a password, so the wizard flag alone cannot
# tell an interrupted provisioning from a finished one.
needs_provisioning() {
  ! wizard_completed || [[ -e "${bootstrap_marker}" ]]
}

provision() {
  local username="${JELLYFIN_ADMIN_USERNAME:-}" password="${JELLYFIN_ADMIN_PASSWORD:-}"
  [[ "${username}" =~ ^[A-Za-z0-9._@-]{1,64}$ ]] || fail "JELLYFIN_ADMIN_USERNAME must be 1-64 letters, digits, dot, dash, underscore or @."
  (( ${#password} >= 16 )) || fail "JELLYFIN_ADMIN_PASSWORD must have at least 16 characters."
  [[ "${password}" != *[[:cntrl:]]* ]] || fail "JELLYFIN_ADMIN_PASSWORD must not contain control characters."

  local base="http://127.0.0.1:${bootstrap_port}" client='MediaBrowser Client="Railway bootstrap", Device="railway-entrypoint", DeviceId="railway-bootstrap", Version="1.0.0"'
  local token="" code body info
  # curl reads headers and bodies from descriptors, so neither the password
  # nor the session token appears in process arguments. Each request runs in
  # the background and is awaited with the `wait` builtin: bash defers a trap
  # until a foreground command or command substitution ends, but `wait`
  # returns at once when a signal arrives, so a stop is never held up by a
  # request.
  bg_curl() {
    local rc=0
    curl --noproxy '*' "$@" &
    curl_pid=$!
    wait "${curl_pid}" || rc=$?
    curl_pid=""
    return "${rc}"
  }
  call() {
    local method="$1" path="$2" body="${3:-}" header="${client}"
    [[ -z "${token}" ]] || header+=", Token=\"${token}\""
    local rc=0
    code=000
    bg_curl --silent --show-error --max-time 60 --output /tmp/bootstrap-response --write-out '%{http_code}' \
      --config <(printf 'header = "Authorization: %s"\n' "${header//\"/\\\"}") \
      -H 'Content-Type: application/json' -X "${method}" --data-binary @<(printf '%s' "${body}") "${base}${path}" >/tmp/bootstrap-code || rc=$?
    read -r code </tmp/bootstrap-code || true
    # A transfer curl reports as failed (for example a truncated body) never
    # counts, whatever HTTP status it recorded.
    (( rc == 0 )) || code="curl-exit-${rc}"
  }
  expect() { [[ "$1" == "$2" ]] || { echo "railway-entrypoint: provisioning $3 returned HTTP $1" >&2; rm -f /tmp/bootstrap-response; exit 1; }; }

  if [[ -e "${bootstrap_marker}" ]]; then
    echo "railway-entrypoint: an earlier first boot stopped before provisioning finished; resuming on 127.0.0.1:${bootstrap_port}."
  else
    echo "railway-entrypoint: first boot; running the Jellyfin startup wizard on 127.0.0.1:${bootstrap_port}."
    : >"${bootstrap_marker}"
  fi
  write_network_config "${bootstrap_port}" loopback
  start_jellyfin
  # Bash as PID 1 ignores TERM without a handler; stop Jellyfin cleanly if
  # Railway stops the container mid-provisioning. The marker makes the next
  # boot resume.
  trap '[[ -z "${curl_pid}" ]] || kill "${curl_pid}" 2>/dev/null || true; stop_children "${jellyfin_pid}"; exit 143' TERM INT
  # /health answers 200 "Degraded" while the migration server still runs and
  # the API returns 503, so wait for "Healthy" and the real public info.
  ready() {
    local health=""
    info=""
    bg_curl -fsS --max-time 3 -o /tmp/bootstrap-health "${base}/health" 2>/dev/null || return 1
    read -r health </tmp/bootstrap-health || true
    [[ "${health}" == Healthy ]] || return 1
    bg_curl -fsS --max-time 3 -o /tmp/bootstrap-health "${base}/System/Info/Public" 2>/dev/null || return 1
    read -r info </tmp/bootstrap-health || true
    [[ "${info}" == *'"StartupWizardCompleted":'* ]]
  }
  for _ in $(seq 300); do
    ready && break
    kill -0 "${jellyfin_pid}" 2>/dev/null || { echo "railway-entrypoint: Jellyfin exited during provisioning." >&2; exit 1; }
    sleep 2 &
    wait "$!" || true
  done
  ready || { echo "railway-entrypoint: Jellyfin did not become ready within 10 minutes." >&2; exit 1; }

  if [[ "${info}" == *'"StartupWizardCompleted":false'* ]]; then
    call POST /Startup/Configuration '{"ServerName":"Media Server","UICulture":"en-US","MetadataCountryCode":"US","PreferredMetadataLanguage":"en"}'
    expect "${code}" 204 "server configuration"
    # GET /Startup/User creates the initial user if none exists yet.
    call GET /Startup/User
    expect "${code}" 200 "initial user lookup"
    call POST /Startup/User "$(printf '{"Name":%s,"Password":%s}' "$(json_string "${username}")" "$(json_string "${password}")")"
    # 403 means an interrupted earlier boot already set the password; the
    # sign-in below proves it is this deployment's password before going on.
    [[ "${code}" == 204 || "${code}" == 403 ]] || expect "${code}" 204 "admin account"
  fi
  # On a resumed provisioning with the wizard already complete, everything
  # below needs this deployment's administrator; any other password stops here.
  call POST /Users/AuthenticateByName "$(printf '{"Username":%s,"Pw":%s}' "$(json_string "${username}")" "$(json_string "${password}")")"
  expect "${code}" 200 "admin sign-in"
  token="$(sed -n 's/.*"AccessToken":"\([0-9a-fA-F]*\)".*/\1/p' /tmp/bootstrap-response)"
  [[ -n "${token}" ]] || { echo "railway-entrypoint: admin sign-in returned no token." >&2; exit 1; }
  grep -q '"IsAdministrator":true' /tmp/bootstrap-response || { echo "railway-entrypoint: ${username} is not an administrator." >&2; exit 1; }

  call GET /Library/VirtualFolders
  expect "${code}" 200 "library list"
  body="$(cat /tmp/bootstrap-response)"
  local library name collection path
  for library in "Movies:movies:${media_dir}/movies" "Shows:tvshows:${media_dir}/shows" "Music:music:${media_dir}/music"; do
    IFS=: read -r name collection path <<<"${library}"
    grep -q "\"Name\":\"${name}\"" <<<"${body}" && continue
    call POST "/Library/VirtualFolders?name=${name}&collectionType=${collection}&refreshLibrary=false" \
      "$(printf '{"LibraryOptions":{"EnableRealtimeMonitor":true,"PathInfos":[{"Path":"%s"}]}}' "${path}")"
    expect "${code}" 204 "library ${name}"
  done

  # Software transcoding on shared CPUs: pause ffmpeg once the client has
  # enough buffer, and let Jellyfin delete played HLS segments.
  call GET /System/Configuration/encoding
  expect "${code}" 200 "encoding settings"
  body="$(sed -e 's/"EnableThrottling":false/"EnableThrottling":true/' -e 's/"EnableSegmentDeletion":false/"EnableSegmentDeletion":true/' /tmp/bootstrap-response)"
  call POST /System/Configuration/encoding "${body}"
  expect "${code}" 204 "encoding update"
  call GET /System/Configuration/encoding
  expect "${code}" 200 "encoding readback"
  grep -q '"EnableThrottling":true' /tmp/bootstrap-response && grep -q '"EnableSegmentDeletion":true' /tmp/bootstrap-response ||
    { echo "railway-entrypoint: the encoding settings did not persist." >&2; exit 1; }

  call POST /Startup/Complete
  expect "${code}" 204 "wizard completion"
  call POST /Sessions/Logout
  expect "${code}" 204 "provisioning sign-out"
  token=""
  rm -f /tmp/bootstrap-response /tmp/bootstrap-code /tmp/bootstrap-health

  stop_children "${jellyfin_pid}"
  trap 'exit 143' TERM INT
  wizard_completed || { echo "railway-entrypoint: Jellyfin did not record the completed wizard." >&2; exit 1; }
  finish_network_config
  echo "railway-entrypoint: startup wizard completed for admin user ${username}; libraries Movies, Shows and Music created."
}

# Railway delivers the generated password in this process's environment. Use
# it only for provisioning, then replace this shell with one whose environment
# (and /proc/1/environ) no longer holds it.
if [[ -n "${JELLYFIN_ADMIN_PASSWORD+x}" ]]; then
  if needs_provisioning; then
    provision
  fi
  exec env -u JELLYFIN_ADMIN_PASSWORD "$0" "$@"
fi
if needs_provisioning; then
  fail "provisioning is not finished and JELLYFIN_ADMIN_PASSWORD is not set."
fi

stopping=0
jellyfin_pid=""
dufs_pid=""
stop() {
  kill -TERM ${jellyfin_pid:+"${jellyfin_pid}"} ${dufs_pid:+"${dufs_pid}"} 2>/dev/null || true
}
# Installed before the children start, so a stop request is never ignored.
trap 'stopping=1; stop' TERM INT

dufs "${media_dir}" \
  --bind 0.0.0.0 --bind :: \
  --port "${upload_port}" \
  --path-prefix files \
  --allow-upload --allow-delete --allow-search --allow-archive \
  --hidden '.*' &
dufs_pid=$!

start_jellyfin
# A stop that arrived while the children were starting.
(( stopping == 0 )) || stop

# Poll instead of `wait -n`: a stop request that lands just before a blocking
# wait would otherwise wait for a child that is still ignoring TERM.
status=0
while (( stopping == 0 )); do
  if ! child_alive "${jellyfin_pid}"; then wait "${jellyfin_pid}" || status=$?; break; fi
  if ! child_alive "${dufs_pid}"; then wait "${dufs_pid}" || status=$?; break; fi
  sleep 1 &
  wait "$!" || true
done
stop_children "${jellyfin_pid}" "${dufs_pid}"
if (( stopping )); then
  exit 0
fi
echo "railway-entrypoint: a Jellyfin service process exited unexpectedly (status ${status}); stopping the container." >&2
exit $(( status == 0 ? 1 : status ))
