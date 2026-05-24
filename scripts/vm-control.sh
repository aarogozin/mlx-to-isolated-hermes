#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENV_FILE="${PROJECT_ROOT}/.env"

OVERRIDE_AGENT_RUNTIME="${AGENT_RUNTIME:-}"
OVERRIDE_VM_NAME="${VM_NAME:-}"

if [[ -f "${ENV_FILE}" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "${ENV_FILE}"
  set +a
fi

ACTION="${1:-}"
AGENT_RUNTIME="${OVERRIDE_AGENT_RUNTIME:-${AGENT_RUNTIME:-hermes}}"
HERMES_VM_NAME="${HERMES_VM_NAME:-${VM_NAME:-omlx-agent-ubuntu}}"
OPENCLAW_VM_NAME="${OPENCLAW_VM_NAME:-omlx-openclaw-ubuntu}"
case "${AGENT_RUNTIME}" in
  hermes) DEFAULT_VM_NAME="${HERMES_VM_NAME}" ;;
  openclaw) DEFAULT_VM_NAME="${OPENCLAW_VM_NAME}" ;;
  *) DEFAULT_VM_NAME="${VM_NAME:-omlx-agent-ubuntu}" ;;
esac
VM_NAME="${OVERRIDE_VM_NAME:-${DEFAULT_VM_NAME}}"
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

ensure_model_host_alias() {
  multipass exec "${VM_NAME}" -- sudo bash -lc '
    if [[ -f /usr/local/sbin/update-model-host-alias ]]; then
      chmod 0755 /usr/local/sbin/update-model-host-alias
      systemctl daemon-reload
      systemctl enable --now model-host-alias.service >/dev/null 2>&1 || /usr/local/sbin/update-model-host-alias || true
    else
      gateway="$(ip route | awk "/default/ {print \$3; exit}")"
      if [[ -n "${gateway}" ]]; then
        grep -v "[[:space:]]model-host\\.internal$" /etc/hosts > /etc/hosts.tmp
        printf "%s model-host.internal\n" "${gateway}" >> /etc/hosts.tmp
        mv /etc/hosts.tmp /etc/hosts
      fi
    fi
  ' >/dev/null 2>&1 || true
}

case "${ACTION}" in
  start)
    require_multipass_vm
    multipass start "${VM_NAME}"
    ensure_model_host_alias
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
    ensure_model_host_alias
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
