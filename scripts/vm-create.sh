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

VM_ENGINE="${VM_ENGINE:-multipass}"

case "${VM_ENGINE}" in
  multipass)
    exec "${SCRIPT_DIR}/vm-create-multipass.sh"
    ;;
  vmware|fusion)
    exec "${SCRIPT_DIR}/vm-create-ubuntu.sh"
    ;;
  *)
    printf 'ERROR: unsupported VM_ENGINE=%s. Use multipass or vmware.\n' "${VM_ENGINE}" >&2
    exit 2
    ;;
esac

