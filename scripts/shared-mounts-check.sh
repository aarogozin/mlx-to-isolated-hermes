#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENV_FILE="${PROJECT_ROOT}/.env"

OVERRIDE_SANDBOX_BACKEND="${SANDBOX_BACKEND:-}"
OVERRIDE_VM_NAME="${VM_NAME:-}"
OVERRIDE_OBSIDIAN_SHARED_PATH="${OBSIDIAN_SHARED_PATH:-}"
OVERRIDE_OBSIDIAN_GUEST_PATH="${OBSIDIAN_GUEST_PATH:-}"
OVERRIDE_DOCKER_NAME="${DOCKER_NAME:-}"
OVERRIDE_OPENCLAW_DOCKER_NAME="${OPENCLAW_DOCKER_NAME:-}"
OVERRIDE_AGENT_RUNTIME="${AGENT_RUNTIME:-}"

if [[ -f "${ENV_FILE}" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "${ENV_FILE}"
  set +a
fi

TARGET="${1:-${OVERRIDE_SANDBOX_BACKEND:-${SANDBOX_BACKEND:-multipass}}}"
AGENT_RUNTIME="${OVERRIDE_AGENT_RUNTIME:-${AGENT_RUNTIME:-hermes}}"
HERMES_VM_NAME="${HERMES_VM_NAME:-${VM_NAME:-omlx-agent-ubuntu}}"
OPENCLAW_VM_NAME="${OPENCLAW_VM_NAME:-omlx-openclaw-ubuntu}"
case "${AGENT_RUNTIME}" in
  hermes) DEFAULT_VM_NAME="${HERMES_VM_NAME}" ;;
  openclaw) DEFAULT_VM_NAME="${OPENCLAW_VM_NAME}" ;;
  *) DEFAULT_VM_NAME="${VM_NAME:-omlx-agent-ubuntu}" ;;
esac
VM_NAME="${OVERRIDE_VM_NAME:-${DEFAULT_VM_NAME}}"
OBSIDIAN_SHARED_PATH="${OVERRIDE_OBSIDIAN_SHARED_PATH:-${OBSIDIAN_SHARED_PATH:-}}"
OBSIDIAN_GUEST_PATH="${OVERRIDE_OBSIDIAN_GUEST_PATH:-${OBSIDIAN_GUEST_PATH:-/mnt/obsidian}}"
DOCKER_NAME="${OVERRIDE_DOCKER_NAME:-${DOCKER_NAME:-omlx-agent-docker}}"
OPENCLAW_DOCKER_NAME="${OVERRIDE_OPENCLAW_DOCKER_NAME:-${OPENCLAW_DOCKER_NAME:-omlx-agent-openclaw-docker}}"
if [[ "${AGENT_RUNTIME}" == "openclaw" && -z "${OVERRIDE_DOCKER_NAME}" ]]; then
  DOCKER_NAME="${OPENCLAW_DOCKER_NAME}"
fi
TIMEOUT_BIN="$(command -v timeout || command -v gtimeout || true)"
CHECK_HOST_FILE=""
CHECK_GUEST_FILE=""
CHECK_HOST_DOCKER_FILE=""

die() {
  echo "ERROR: $*" >&2
  exit 1
}

normalize_path() {
  local path="$1"
  [[ -n "${path}" ]] || return 0
  if [[ "${path}" == "~/"* ]]; then
    path="${HOME}/${path#~/}"
  fi
  printf '%s\n' "${path%/}"
}

run_host_timeout() {
  local seconds="$1"
  shift
  if [[ -n "${TIMEOUT_BIN}" ]]; then
    "${TIMEOUT_BIN}" "${seconds}s" "$@"
  else
    "$@"
  fi
}

host_path="$(normalize_path "${OBSIDIAN_SHARED_PATH}")"
if [[ -z "${host_path}" ]]; then
  echo "shared-check=skipped reason=OBSIDIAN_SHARED_PATH unset"
  exit 0
fi
[[ -d "${host_path}" ]] || die "OBSIDIAN_SHARED_PATH does not exist: ${host_path}"

check_multipass() {
  command -v multipass >/dev/null 2>&1 || die "multipass CLI missing"
  multipass info "${VM_NAME}" >/dev/null 2>&1 || die "Multipass VM missing: ${VM_NAME}"

  local marker
  local host_file
  local guest_file
  marker="omlx-shared-check-$(date +%s)-$$.txt"
  host_file="${host_path}/${marker}"
  guest_file="${OBSIDIAN_GUEST_PATH}/${marker}"

  cleanup() {
    rm -f "${CHECK_HOST_FILE}"
    run_host_timeout 10 multipass exec "${VM_NAME}" -- sudo rm -f "${CHECK_GUEST_FILE}" >/dev/null 2>&1 || true
  }
  trap cleanup EXIT

  printf 'omlx shared check %s\n' "${marker}" > "${host_file}"
  CHECK_HOST_FILE="${host_file}"
  CHECK_GUEST_FILE="${guest_file}"
  "${SCRIPT_DIR}/shared-mounts.sh" sync multipass >/dev/null

  guest_content="$(run_host_timeout 20 multipass exec "${VM_NAME}" -- sudo cat "${guest_file}")"
  host_content="$(cat "${host_file}")"
  [[ "${guest_content}" == "${host_content}" ]] \
    || die "shared folder content mismatch between host and VM"

  echo "shared-check=ok target=multipass mode=${MULTIPASS_SHARED_MODE:-transfer} file=${marker}"
  cleanup
  trap - EXIT
}

check_docker() {
  command -v docker >/dev/null 2>&1 || die "docker CLI missing"
  docker container inspect "${DOCKER_NAME}" >/dev/null 2>&1 || die "Docker container missing: ${DOCKER_NAME}"
  [[ "$(docker inspect -f '{{.State.Running}}' "${DOCKER_NAME}")" == "true" ]] \
    || die "Docker container is not running: ${DOCKER_NAME}"

  local marker
  local host_file
  local guest_file
  marker="omlx-shared-check-$(date +%s)-$$.txt"
  host_file="${host_path}/${marker}"
  guest_file="${OBSIDIAN_GUEST_PATH}/${marker}"

  cleanup() {
    rm -f "${CHECK_HOST_FILE}" "${CHECK_HOST_DOCKER_FILE}"
    docker exec "${DOCKER_NAME}" rm -f "${CHECK_GUEST_FILE}" "${CHECK_GUEST_FILE}.from-container" >/dev/null 2>&1 || true
  }
  trap cleanup EXIT

  printf 'omlx shared docker host %s\n' "${marker}" > "${host_file}"
  CHECK_HOST_FILE="${host_file}"
  CHECK_HOST_DOCKER_FILE="${host_file}.from-container"
  CHECK_GUEST_FILE="${guest_file}"
  guest_content="$(docker exec "${DOCKER_NAME}" cat "${guest_file}")"
  host_content="$(cat "${host_file}")"
  [[ "${guest_content}" == "${host_content}" ]] \
    || die "shared folder content mismatch between host and Docker"

  docker exec "${DOCKER_NAME}" /bin/bash -lc "printf '%s\n' 'omlx shared docker guest ${marker}' > '${guest_file}.from-container'"
  [[ -f "${host_file}.from-container" ]] || die "Docker shared folder write-back did not reach host"

  echo "shared-check=ok target=docker file=${marker}"
  cleanup
  trap - EXIT
}

case "${TARGET}" in
  multipass|vm)
    check_multipass
    ;;
  docker)
    check_docker
    ;;
  *)
    die "unsupported shared check target: ${TARGET}. Use multipass or docker."
    ;;
esac
