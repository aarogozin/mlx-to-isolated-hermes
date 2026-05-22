#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENV_FILE="${PROJECT_ROOT}/.env"

if [[ -f "${ENV_FILE}" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "${ENV_FILE}"
  set +a
fi

ACTION="${1:-}"
VM_NAME="${VM_NAME:-omlx-agent-ubuntu}"
VM_SSH_USER="${VM_SSH_USER:-agent}"
VM_SSH_KEY="${VM_SSH_KEY:-${HOME}/.ssh/omlx_agent_vm_ed25519}"
VM_SNAPSHOT_NAME="${VM_SNAPSHOT_NAME:-clean-agent-base}"

usage() {
  cat <<EOF
Usage: $0 <start|stop|ip|ssh|snapshot|reset|destroy|list-snapshots|status>
EOF
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

require_multipass_vm() {
  command -v multipass >/dev/null 2>&1 || die "multipass missing. Run make bootstrap first."
  multipass info "${VM_NAME}" >/dev/null 2>&1 || die "Multipass instance missing: ${VM_NAME}. Run make vm-create first."
}

multipass_ip() {
  multipass info "${VM_NAME}" | awk '/IPv4/ { print $2; exit }'
}

case "${ACTION}" in
  start)
    require_multipass_vm
    multipass start "${VM_NAME}"
    ;;
  stop)
    require_multipass_vm
    multipass stop "${VM_NAME}"
    ;;
  ip)
    require_multipass_vm
    multipass_ip
    ;;
  ssh)
    require_multipass_vm
    ip="$(multipass_ip)"
    exec ssh -i "${VM_SSH_KEY}" -o StrictHostKeyChecking=accept-new "${VM_SSH_USER}@${ip}"
    ;;
  snapshot)
    require_multipass_vm
    multipass snapshot "${VM_NAME}" --name "${VM_SNAPSHOT_NAME}"
    ;;
  reset)
    require_multipass_vm
    multipass stop "${VM_NAME}" || true
    multipass restore "${VM_NAME}.${VM_SNAPSHOT_NAME}"
    multipass start "${VM_NAME}"
    ;;
  destroy)
    command -v multipass >/dev/null 2>&1 || {
      echo "multipass missing; no Multipass VM to destroy."
      exit 0
    }
    if multipass info "${VM_NAME}" >/dev/null 2>&1; then
      multipass umount "${VM_NAME}" >/dev/null 2>&1 || true
      multipass stop "${VM_NAME}" >/dev/null 2>&1 || true
      multipass delete "${VM_NAME}" >/dev/null 2>&1 || true
      multipass purge >/dev/null 2>&1 || true
      echo "Destroyed Multipass instance: ${VM_NAME}"
    else
      multipass purge >/dev/null 2>&1 || true
      echo "Multipass instance already absent: ${VM_NAME}"
    fi
    ;;
  list-snapshots)
    require_multipass_vm
    multipass info --snapshots "${VM_NAME}"
    ;;
  status)
    require_multipass_vm
    state="$(multipass info "${VM_NAME}" | awk '/State/ { print $2; exit }')"
    ip="$(multipass_ip)"
    printf 'engine=multipass\nvm=%s\nstate=%s\nip=%s\n' "${VM_NAME}" "${state}" "${ip:-unknown}"
    ;;
  *)
    usage
    exit 2
    ;;
esac
