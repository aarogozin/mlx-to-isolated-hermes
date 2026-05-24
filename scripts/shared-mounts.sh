#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENV_FILE="${PROJECT_ROOT}/.env"

OVERRIDE_VM_NAME="${VM_NAME:-}"
OVERRIDE_VM_SSH_USER="${VM_SSH_USER:-}"
OVERRIDE_OBSIDIAN_SHARED_PATH="${OBSIDIAN_SHARED_PATH:-}"
OVERRIDE_OBSIDIAN_GUEST_PATH="${OBSIDIAN_GUEST_PATH:-}"
OVERRIDE_DOCKER_NAME="${DOCKER_NAME:-}"
OVERRIDE_OPENCLAW_DOCKER_NAME="${OPENCLAW_DOCKER_NAME:-}"
OVERRIDE_AGENT_RUNTIME="${AGENT_RUNTIME:-}"
OVERRIDE_MULTIPASS_SHARED_MODE="${MULTIPASS_SHARED_MODE:-}"

if [[ -f "${ENV_FILE}" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "${ENV_FILE}"
  set +a
fi

ACTION="${1:-sync}"
TARGET="${2:-${SANDBOX_BACKEND:-multipass}}"
AGENT_RUNTIME="${OVERRIDE_AGENT_RUNTIME:-${AGENT_RUNTIME:-hermes}}"
HERMES_VM_NAME="${HERMES_VM_NAME:-${VM_NAME:-omlx-agent-ubuntu}}"
OPENCLAW_VM_NAME="${OPENCLAW_VM_NAME:-omlx-openclaw-ubuntu}"
case "${AGENT_RUNTIME}" in
  hermes) DEFAULT_VM_NAME="${HERMES_VM_NAME}" ;;
  openclaw) DEFAULT_VM_NAME="${OPENCLAW_VM_NAME}" ;;
  *) DEFAULT_VM_NAME="${VM_NAME:-omlx-agent-ubuntu}" ;;
esac
VM_NAME="${OVERRIDE_VM_NAME:-${DEFAULT_VM_NAME}}"
VM_SSH_USER="${OVERRIDE_VM_SSH_USER:-${VM_SSH_USER:-agent}}"
OBSIDIAN_SHARED_PATH="${OVERRIDE_OBSIDIAN_SHARED_PATH:-${OBSIDIAN_SHARED_PATH:-}}"
OBSIDIAN_GUEST_PATH="${OVERRIDE_OBSIDIAN_GUEST_PATH:-${OBSIDIAN_GUEST_PATH:-/mnt/obsidian}}"
DOCKER_NAME="${OVERRIDE_DOCKER_NAME:-${DOCKER_NAME:-omlx-agent-docker}}"
OPENCLAW_DOCKER_NAME="${OVERRIDE_OPENCLAW_DOCKER_NAME:-${OPENCLAW_DOCKER_NAME:-omlx-agent-openclaw-docker}}"
if [[ "${AGENT_RUNTIME}" == "openclaw" && -z "${OVERRIDE_DOCKER_NAME}" ]]; then
  DOCKER_NAME="${OPENCLAW_DOCKER_NAME}"
fi
MULTIPASS_SHARED_MODE="${OVERRIDE_MULTIPASS_SHARED_MODE:-${MULTIPASS_SHARED_MODE:-transfer}}"
SNAP_INSTALL_TIMEOUT_SECONDS="${SNAP_INSTALL_TIMEOUT_SECONDS:-180}"
SNAP_INSTALL_RETRIES="${SNAP_INSTALL_RETRIES:-3}"
MULTIPASS_MOUNT_TIMEOUT_SECONDS="${MULTIPASS_MOUNT_TIMEOUT_SECONDS:-30}"

die() {
  echo "ERROR: $*" >&2
  exit 1
}

usage() {
  cat <<EOF
Usage: $0 <sync|status> [multipass|vm|docker]
EOF
}

normalize_path() {
  local path="$1"
  [[ -n "${path}" ]] || return 0
  if [[ "${path}" == "~/"* ]]; then
    path="${HOME}/${path#~/}"
  fi
  path="${path%/}"
  printf '%s\n' "${path}"
}

host_path="$(normalize_path "${OBSIDIAN_SHARED_PATH}")"
TIMEOUT_BIN="$(command -v timeout || command -v gtimeout || true)"

run_host_timeout() {
  local seconds="$1"
  shift
  if [[ -n "${TIMEOUT_BIN}" ]]; then
    "${TIMEOUT_BIN}" "${seconds}s" "$@"
  else
    "$@"
  fi
}

install_multipass_sshfs() {
  if multipass exec "${VM_NAME}" -- bash -lc 'snap list multipass-sshfs >/dev/null 2>&1'; then
    return 0
  fi

  echo "Installing multipass-sshfs inside ${VM_NAME}..."
  multipass exec "${VM_NAME}" -- sudo env \
    SNAP_INSTALL_TIMEOUT_SECONDS="${SNAP_INSTALL_TIMEOUT_SECONDS}" \
    SNAP_INSTALL_RETRIES="${SNAP_INSTALL_RETRIES}" \
    bash -lc '
    set -euo pipefail
    if ! command -v snap >/dev/null 2>&1; then
      apt-get update
      DEBIAN_FRONTEND=noninteractive apt-get install -y snapd
    fi

    for attempt in $(seq 1 "${SNAP_INSTALL_RETRIES}"); do
      if timeout "${SNAP_INSTALL_TIMEOUT_SECONDS}s" snap install multipass-sshfs; then
        exit 0
      fi

      change_id="$(snap changes 2>/dev/null | awk '"'"'/Install "multipass-sshfs" snap/ { id=$1 } END { print id }'"'"')"
      if [[ -n "${change_id}" ]]; then
        snap abort "${change_id}" >/dev/null 2>&1 || true
      fi
      if [[ "${attempt}" -lt "${SNAP_INSTALL_RETRIES}" ]]; then
        echo "multipass-sshfs install failed on attempt ${attempt}/${SNAP_INSTALL_RETRIES}; retrying in 10s..." >&2
        sleep 10
      fi
    done

    change_id="$(snap changes 2>/dev/null | awk '"'"'/Install "multipass-sshfs" snap/ { id=$1 } END { print id }'"'"')"
    if [[ -n "${change_id}" ]]; then
      snap abort "${change_id}" >/dev/null 2>&1 || true
    fi
      echo "Failed to install multipass-sshfs inside the VM." >&2
      echo "This is usually a temporary Snapcraft/network issue. Recent snap changes:" >&2
      snap changes >&2 || true
      if [[ -n "${change_id}" ]]; then
        snap change "${change_id}" >&2 || true
      fi
      exit 1
  '
}

current_multipass_mounts() {
  multipass info "${VM_NAME}" 2>/dev/null | sed -n '/^Mounts:/,$p'
}

mount_points_to_guest_path() {
  current_multipass_mounts | grep -Fq "${OBSIDIAN_GUEST_PATH}"
}

mount_points_to_host_path() {
  current_multipass_mounts | grep -Fq "${host_path}"
}

mount_multipass_path() {
  local output

  if output="$(run_host_timeout "${MULTIPASS_MOUNT_TIMEOUT_SECONDS}" multipass mount "${host_path}" "${VM_NAME}:${OBSIDIAN_GUEST_PATH}" 2>&1)"; then
    return 0
  fi

  if grep -Fq 'multipass-sshfs' <<<"${output}"; then
    install_multipass_sshfs || return 1
    run_host_timeout "${MULTIPASS_MOUNT_TIMEOUT_SECONDS}" multipass mount "${host_path}" "${VM_NAME}:${OBSIDIAN_GUEST_PATH}"
    return 0
  fi

  printf '%s\n' "${output}" >&2
  return 1
}

transfer_multipass_path() {
  local source_name
  local tmp_guest

  source_name="$(basename "${host_path}")"
  tmp_guest="/tmp/omlx-shared-transfer-$RANDOM-$$"

  echo "shared=transfer source=${host_path} target=${VM_NAME}:${OBSIDIAN_GUEST_PATH}"
  multipass exec "${VM_NAME}" -- rm -rf "${tmp_guest}"
  multipass exec "${VM_NAME}" -- mkdir -p "${tmp_guest}"
  multipass transfer --recursive "${host_path}" "${VM_NAME}:${tmp_guest}"
  multipass exec "${VM_NAME}" -- sudo env \
    OBSIDIAN_GUEST_PATH="${OBSIDIAN_GUEST_PATH}" \
    TMP_GUEST="${tmp_guest}" \
    SOURCE_NAME="${source_name}" \
    VM_SSH_USER="${VM_SSH_USER}" \
    bash -c '
      set -euo pipefail
      source_dir="${TMP_GUEST}/${SOURCE_NAME}"
      [[ -d "${source_dir}" ]] || {
        echo "Transferred source directory missing: ${source_dir}" >&2
        exit 1
      }
      mkdir -p "${OBSIDIAN_GUEST_PATH}"
      find "${OBSIDIAN_GUEST_PATH}" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
      cp -a "${source_dir}/." "${OBSIDIAN_GUEST_PATH}/"
      chown -R "${VM_SSH_USER}:${VM_SSH_USER}" "${OBSIDIAN_GUEST_PATH}" || true
      rm -rf "${TMP_GUEST}"
    '
  echo "shared=transferred source=${host_path} target=${VM_NAME}:${OBSIDIAN_GUEST_PATH}"
}

sync_multipass() {
  [[ -n "${host_path}" ]] || { echo "shared=disabled"; return 0; }
  [[ -d "${host_path}" ]] || die "OBSIDIAN_SHARED_PATH does not exist: ${host_path}"
  command -v multipass >/dev/null 2>&1 || die "multipass CLI missing"
  multipass info "${VM_NAME}" >/dev/null 2>&1 || die "Multipass VM missing: ${VM_NAME}"

  case "${MULTIPASS_SHARED_MODE}" in
    disabled|off|none)
      echo "shared=disabled mode=${MULTIPASS_SHARED_MODE}"
      return 0
      ;;
    transfer|copy|snapshot)
      transfer_multipass_path
      return 0
      ;;
    mount|sshfs)
      ;;
    *)
      die "unsupported MULTIPASS_SHARED_MODE=${MULTIPASS_SHARED_MODE}. Use transfer, mount, or disabled."
      ;;
  esac

  multipass exec "${VM_NAME}" -- sudo mkdir -p "${OBSIDIAN_GUEST_PATH}"

  if mount_points_to_guest_path; then
    if mount_points_to_host_path; then
      echo "shared=mounted source=${host_path} target=${VM_NAME}:${OBSIDIAN_GUEST_PATH}"
      return 0
    fi
    echo "Shared mount target exists with a different host path; remounting ${VM_NAME}:${OBSIDIAN_GUEST_PATH}..."
    multipass umount "${VM_NAME}:${OBSIDIAN_GUEST_PATH}" >/dev/null 2>&1 || true
  fi

  if mount_multipass_path; then
    echo "shared=mounted source=${host_path} target=${VM_NAME}:${OBSIDIAN_GUEST_PATH}"
    return 0
  fi

  die "failed to mount ${host_path} into ${VM_NAME}:${OBSIDIAN_GUEST_PATH}"
}

status_multipass() {
  if ! command -v multipass >/dev/null 2>&1 || ! multipass info "${VM_NAME}" >/dev/null 2>&1; then
    echo "shared=unknown vm=missing"
    return 0
  fi
  if [[ "${MULTIPASS_SHARED_MODE}" == "transfer" || "${MULTIPASS_SHARED_MODE}" == "copy" || "${MULTIPASS_SHARED_MODE}" == "snapshot" ]]; then
    if multipass exec "${VM_NAME}" -- test -d "${OBSIDIAN_GUEST_PATH}" >/dev/null 2>&1; then
      local item_count
      item_count="$(multipass exec "${VM_NAME}" -- find "${OBSIDIAN_GUEST_PATH}" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l | tr -d ' ')"
      echo "shared=transferred source=${host_path:-unset} target=${VM_NAME}:${OBSIDIAN_GUEST_PATH} items=${item_count}"
      return 0
    fi
    echo "shared=missing mode=${MULTIPASS_SHARED_MODE} target=${VM_NAME}:${OBSIDIAN_GUEST_PATH}"
    return 0
  fi
  multipass info "${VM_NAME}" | sed -n '/^Mounts:/,$p'
}

status_docker() {
  if ! command -v docker >/dev/null 2>&1 || ! docker container inspect "${DOCKER_NAME}" >/dev/null 2>&1; then
    echo "shared=unknown docker=missing"
    return 0
  fi
  docker inspect -f '{{range .Mounts}}{{println .Source "->" .Destination}}{{end}}' "${DOCKER_NAME}"
}

case "${ACTION}:${TARGET}" in
  sync:multipass|sync:vm)
    sync_multipass
    ;;
  sync:docker)
    [[ -n "${host_path}" ]] || { echo "shared=disabled"; exit 0; }
    [[ -d "${host_path}" ]] || die "OBSIDIAN_SHARED_PATH does not exist: ${host_path}"
    echo "shared=configured source=${host_path} target=/mnt/obsidian"
    ;;
  status:multipass|status:vm)
    status_multipass
    ;;
  status:docker)
    status_docker
    ;;
  *)
    usage
    exit 2
    ;;
esac
