#!/usr/bin/env bash
# Clean-state local verification of the two-service graph with Docker Compose.
# Without a usable Docker daemon it starts a private podman API socket for the
# run (evo hosts have rootless podman and no podman-compose) and stops it at
# the end. Steps: fresh generated passwords in a 0600 file, a clean build, an
# empty volume, both services up, proof that the wizard ran on loopback before
# Jellyfin's network port opened, the initial smoke, a Jellyfin restart, a
# Jellyfin recreation and a gateway restart with the restart smoke after each,
# resource use, a secret scan of every log and environment, wrapper failure
# handling, clean stops, and teardown (containers, volume, network, image).
# Usage: ./scripts/local-check.sh   (prints no secret)
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${root}"
work="$(mktemp -d)"
project="jellyfin-check-$$"
volume="${project}-data"
service_pid=""
engine=docker
if ! docker info >/dev/null 2>&1; then
  engine=podman
  podman system service --time=0 "unix://${work}/podman.sock" >/dev/null 2>&1 &
  service_pid=$!
  export DOCKER_HOST="unix://${work}/podman.sock"
  for _ in $(seq 50); do docker version >/dev/null 2>&1 && break; sleep 0.2; done
fi
compose=(docker compose -p "${project}" --env-file "${work}/local.env" -f compose.yaml)
cleanup() {
  "${compose[@]}" down --timeout 20 >/dev/null 2>&1 || true
  for id in $("${engine}" ps -aq --filter "label=com.docker.compose.project=${project}" 2>/dev/null); do
    "${engine}" rm -f "${id}" >/dev/null 2>&1 || true
  done
  "${engine}" volume rm -f "${volume}" >/dev/null 2>&1 || true
  for net in $("${engine}" network ls -q --filter "label=com.docker.compose.project=${project}" 2>/dev/null); do
    "${engine}" network rm -f "${net}" >/dev/null 2>&1 || true
  done
  [[ -n "${KEEP_IMAGE:-}" ]] || "${engine}" rmi -f jellyfin-media-server:local >/dev/null 2>&1 || true
  if [[ -n "${service_pid}" ]]; then kill "${service_pid}" 2>/dev/null || true; wait "${service_pid}" 2>/dev/null || true; fi
  rm -rf "${work:?}"
}
trap cleanup EXIT
fail() { echo "local-check: $*" >&2; exit 1; }

gen() { python3 -I -c 'import secrets, string, sys; a = string.ascii_letters + string.digits; print("".join(secrets.choice(a) for _ in range(int(sys.argv[1]))))' "$1"; }
( umask 077
  { echo "GATEWAY_USERNAME=media-admin"
    echo "GATEWAY_PASSWORD=$(gen 32)"
    echo "JELLYFIN_ADMIN_USERNAME=admin"
    echo "JELLYFIN_ADMIN_PASSWORD=$(gen 32)"
    echo "JELLYFIN_LOCAL_PORT=${JELLYFIN_LOCAL_PORT:-13096}"
    echo "JELLYFIN_VOLUME=${volume}"; } > "${work}/local.env" )
set -a; . "${work}/local.env"; set +a
export BASE_URL="http://127.0.0.1:${JELLYFIN_LOCAL_PORT}"

container() { "${engine}" ps -aq --filter "label=com.docker.compose.project=${project}" --filter "label=com.docker.compose.service=$1"; }
log_of() { "${engine}" logs "$(container "$1")" 2>&1; }
count() { grep -c -- "$2" <<<"$(log_of "$1")" || true; }
wait_healthy() {
  for _ in $(seq 180); do
    [[ "$(curl -s --max-time 3 "${BASE_URL}/healthz" || true)" == Healthy ]] && return 0
    sleep 2
  done
  fail "the gateway health check never reported Jellyfin healthy"
}
smoke() { SMOKE_PHASE="$1" timeout 900 ./scripts/smoke.sh; }

"${compose[@]}" build --no-cache jellyfin >/dev/null 2>&1 || { "${compose[@]}" build jellyfin; exit 1; }
"${compose[@]}" up -d >/dev/null 2>&1 || { "${compose[@]}" up -d; exit 1; }
wait_healthy
jellyfin_id="$(container jellyfin)"; gateway_id="$(container gateway)"
[[ "$("${engine}" inspect "${jellyfin_id}" --format '{{json .HostConfig.PortBindings}}')" =~ ^(\{\}|null)$ ]] || fail "Jellyfin publishes a port"

# First boot ran the wizard on loopback only and Jellyfin's network port opened
# afterwards; the gateway waited for the completed wizard.
logs="$(log_of jellyfin)"
grep -q 'first boot; running the Jellyfin startup wizard on 127.0.0.1:18096' <<<"${logs}" || fail "no first-boot marker"
grep -q 'startup wizard completed for admin user admin' <<<"${logs}" || fail "no wizard-completed marker"
first_bind="$(grep -n 'Kestrel is listening on' <<<"${logs}" | head -1)"
[[ "${first_bind}" == *'listening on 127.0.0.1'* ]] || fail "the first Kestrel bind was not loopback: ${first_bind}"
done_line="$(grep -n 'startup wizard completed' <<<"${logs}" | cut -d: -f1)"
open_line="$(grep -n 'Kestrel is listening on' <<<"${logs}" | grep -v '127.0.0.1' | head -1 | cut -d: -f1)"
[[ -n "${open_line}" ]] && (( open_line > done_line )) || fail "Jellyfin opened a network listener before the wizard finished"
grep -q 'Waiting for Jellyfin to complete its startup wizard.' <<<"$(log_of gateway)" || fail "the gateway did not wait for the wizard"
echo "local-check: ok wizard completed on 127.0.0.1:18096 before Jellyfin listened on the network"

smoke initial

"${engine}" stop -t 30 "${jellyfin_id}" >/dev/null && "${engine}" start "${jellyfin_id}" >/dev/null
wait_healthy; smoke restart
[[ "$(count jellyfin 'first boot')" == 1 ]] || fail "the restart ran the bootstrap again"

"${compose[@]}" up -d --force-recreate --no-deps jellyfin >/dev/null 2>&1
wait_healthy; smoke restart
jellyfin_id="$(container jellyfin)"
[[ "$(count jellyfin 'first boot')" == 0 ]] || fail "the recreated container ran the bootstrap again"

"${engine}" stop -t 30 "${gateway_id}" >/dev/null && "${engine}" start "${gateway_id}" >/dev/null
wait_healthy; smoke restart

"${engine}" stats --no-stream --format '{{.Name}} {{.CPUPerc}} {{.MemUsage}}' "${jellyfin_id}" "${gateway_id}"

# No credential in any log, in the Jellyfin process environment, or in Caddy's.
for service in jellyfin gateway; do
  log_of "${service}" > "${work}/${service}.log"
  (( $(wc -l < "${work}/${service}.log") >= 3 )) || fail "the ${service} log is too short"
  for secret in "${GATEWAY_PASSWORD}" "${JELLYFIN_ADMIN_PASSWORD}"; do
    ! grep -qF -- "${secret}" "${work}/${service}.log" || fail "a password appears in the ${service} log"
  done
done
"${engine}" exec "${jellyfin_id}" sh -c 'grep -rlF -- "$1" /data/jellyfin/log /data/jellyfin/config 2>/dev/null; true' sh "${JELLYFIN_ADMIN_PASSWORD}" > "${work}/hits"
[[ ! -s "${work}/hits" ]] || fail "the admin password is stored in plain text under /data/jellyfin"
jf_pid="$("${engine}" exec "${jellyfin_id}" sh -c 'for p in /proc/[0-9]*; do [ "$(cat $p/comm 2>/dev/null)" = jellyfin ] && echo ${p#/proc/}; done; true' | head -1)"
[[ -n "${jf_pid}" ]] || fail "no jellyfin process"
names="$("${engine}" exec "${jellyfin_id}" sh -c "tr '\0' '\n' < /proc/${jf_pid}/environ | cut -d= -f1")"
! grep -qx 'JELLYFIN_ADMIN_PASSWORD' <<<"${names}" || fail "Jellyfin holds JELLYFIN_ADMIN_PASSWORD"
gnames="$("${engine}" exec --privileged "${gateway_id}" sh -c 'tr "\0" "\n" < /proc/1/environ | cut -d= -f1')"
[[ -n "${gnames}" ]] || fail "could not read the gateway environment"
! grep -qxE 'GATEWAY_PASSWORD|GATEWAY_CONFIG' <<<"${gnames}" || fail "Caddy holds GATEWAY_PASSWORD or GATEWAY_CONFIG"
echo "local-check: ok no password in logs, Jellyfin's stored config, or the Jellyfin and Caddy environments"

# Wrapper supervision: a dufs that exits makes the container exit nonzero.
"${engine}" exec "${jellyfin_id}" sh -c 'kill $(for p in /proc/[0-9]*; do [ "$(cat $p/comm 2>/dev/null)" = dufs ] && echo ${p#/proc/}; done; true)'
for _ in $(seq 30); do [[ "$("${engine}" inspect "${jellyfin_id}" --format '{{.State.Status}}')" == exited ]] && break; sleep 1; done
code="$("${engine}" inspect "${jellyfin_id}" --format '{{.State.Status}} {{.State.ExitCode}}')"
[[ "${code}" == "exited "[1-9]* ]] || fail "killing dufs left the container ${code}"
echo "local-check: ok killing dufs stops the container with a nonzero status (${code})"
"${engine}" start "${jellyfin_id}" >/dev/null; wait_healthy

for id in "${gateway_id}" "${jellyfin_id}"; do
  started=${SECONDS}
  "${engine}" stop -t 30 "${id}" >/dev/null
  (( SECONDS - started < 20 )) || fail "a stop took $((SECONDS - started))s"
  echo "local-check: ok stopped in $((SECONDS - started))s with $("${engine}" inspect "${id}" --format '{{.State.Status}} {{.State.ExitCode}}')"
done
echo "local-check: passed"
