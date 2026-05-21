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
VM_ENGINE="${VM_ENGINE:-multipass}"
VM_NAME="${VM_NAME:-omlx-agent-ubuntu}"
VMX_PATH="${VMX_PATH:-${HOME}/Virtual Machines.localized/${VM_NAME}.vmwarevm/${VM_NAME}.vmx}"
VM_SSH_USER="${VM_SSH_USER:-agent}"
VM_SSH_KEY="${VM_SSH_KEY:-${HOME}/.ssh/omlx_agent_vm_ed25519}"
VM_SNAPSHOT_NAME="${VM_SNAPSHOT_NAME:-clean-agent-base}"
VMRUN="${VMRUN_PATH:-/Applications/VMware Fusion.app/Contents/Public/vmrun}"

usage() {
  cat <<EOF
Usage: $0 <start|stop|ip|ssh|snapshot|reset|list-snapshots|status>
EOF
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

require_vm() {
  [[ -x "${VMRUN}" ]] || die "vmrun missing: ${VMRUN}"
  [[ -f "${VMX_PATH}" ]] || die "VMX missing: ${VMX_PATH}. Run make vm-create first."
}

guest_ip() {
  "${VMRUN}" -T fusion getGuestIPAddress "${VMX_PATH}" -wait
}

multipass_ip() {
  multipass info "${VM_NAME}" | awk '/IPv4/ { print $2; exit }'
}

require_multipass_vm() {
  command -v multipass >/dev/null 2>&1 || die "multipass missing. Run make bootstrap first."
  multipass info "${VM_NAME}" >/dev/null 2>&1 || die "Multipass instance missing: ${VM_NAME}. Run make vm-create first."
}

run_multipass() {
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
    list-snapshots)
      require_multipass_vm
      multipass info --snapshots "${VM_NAME}"
      ;;
    status)
      require_multipass_vm
      state="$(multipass info "${VM_NAME}" | awk '/State/ { print $2; exit }')"
      ip="$(multipass_ip)"
      printf 'engine=multipass\nvm=%s\nstate=%s\nip=%s\n' \
        "${VM_NAME}" "${state}" "${ip:-unknown}"
      ;;
    *)
      usage
      exit 2
      ;;
  esac
}

run_vmware() {
  case "${ACTION}" in
    start)
      require_vm
      "${VMRUN}" -T fusion start "${VMX_PATH}" nogui
      ;;
    stop)
      require_vm
      "${VMRUN}" -T fusion stop "${VMX_PATH}" soft || "${VMRUN}" -T fusion stop "${VMX_PATH}" hard
      ;;
    ip)
      require_vm
      guest_ip
      ;;
    ssh)
      require_vm
      ip="$(guest_ip)"
      exec ssh -i "${VM_SSH_KEY}" -o StrictHostKeyChecking=accept-new "${VM_SSH_USER}@${ip}"
      ;;
    snapshot)
      require_vm
      "${VMRUN}" -T fusion snapshot "${VMX_PATH}" "${VM_SNAPSHOT_NAME}"
      ;;
    reset)
      require_vm
      "${VMRUN}" -T fusion revertToSnapshot "${VMX_PATH}" "${VM_SNAPSHOT_NAME}"
      "${VMRUN}" -T fusion start "${VMX_PATH}" nogui
      ;;
    list-snapshots)
      require_vm
      "${VMRUN}" -T fusion listSnapshots "${VMX_PATH}" showTree
      ;;
    status)
      require_vm
      state="$("${VMRUN}" -T fusion list 2>/dev/null | grep "${VMX_PATH}" | awk '{ print $1; exit }' || echo unknown)"
      ip="$(guest_ip)"
      printf 'engine=vmware\nvmx=%s\nstate=%s\nip=%s\n' \
        "${VMX_PATH}" "${state}" "${ip:-unknown}"
      ;;
    *)
      usage
      exit 2
      ;;
  esac
}

case "${VM_ENGINE}" in
  multipass)
    run_multipass
    ;;
  vmware|fusion)
    run_vmware
    ;;
  *)
    die "unsupported VM_ENGINE=${VM_ENGINE}. Use multipass or vmware."
    ;;
esac
