#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TMP_DIR="$(mktemp -d)"

cleanup() {
  rm -rf "${TMP_DIR}"
}
trap cleanup EXIT

BIN_DIR="${TMP_DIR}/bin"
HOST_SHARED="${TMP_DIR}/host shared"
LOG_FILE="${TMP_DIR}/calls.log"
mkdir -p "${BIN_DIR}" "${HOST_SHARED}"

cat > "${BIN_DIR}/multipass" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
cmd="${1:-}"
printf 'multipass %q' "${cmd}" >> "${MOCK_MULTIPASS_LOG}"
shift || true
for arg in "$@"; do
  printf ' %q' "$arg" >> "${MOCK_MULTIPASS_LOG}"
done
printf '\n' >> "${MOCK_MULTIPASS_LOG}"

case "${cmd}" in
  info)
    cat <<INFO
Name:           omlx-agent-ubuntu
State:          Running
IPv4:           192.0.2.10
Mounts:         --
INFO
    ;;
  exec)
    exit 0
    ;;
  transfer)
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
EOF
chmod +x "${BIN_DIR}/multipass"

PATH="${BIN_DIR}:${PATH}" \
MOCK_MULTIPASS_LOG="${LOG_FILE}" \
OBSIDIAN_SHARED_PATH="${HOST_SHARED}" \
OBSIDIAN_GUEST_PATH="/mnt/obsidian" \
VM_NAME="omlx-agent-ubuntu" \
VM_SSH_USER="agent" \
MULTIPASS_SHARED_MODE="transfer" \
  "${PROJECT_ROOT}/scripts/shared-mounts.sh" sync multipass > "${TMP_DIR}/sync.out"

grep -q 'shared=transferred' "${TMP_DIR}/sync.out"
grep -q 'multipass transfer --recursive' "${LOG_FILE}"
grep -q 'omlx-agent-ubuntu:/tmp/omlx-shared-transfer' "${LOG_FILE}"

PATH="${BIN_DIR}:${PATH}" \
MOCK_MULTIPASS_LOG="${LOG_FILE}" \
OBSIDIAN_SHARED_PATH="${HOST_SHARED}" \
OBSIDIAN_GUEST_PATH="/mnt/obsidian" \
VM_NAME="omlx-agent-ubuntu" \
MULTIPASS_SHARED_MODE="transfer" \
  "${PROJECT_ROOT}/scripts/shared-mounts.sh" status multipass > "${TMP_DIR}/status.out"

grep -q 'shared=transferred' "${TMP_DIR}/status.out"

if PATH="${BIN_DIR}:${PATH}" \
  OBSIDIAN_SHARED_PATH="${TMP_DIR}/missing" \
  "${PROJECT_ROOT}/scripts/shared-mounts.sh" sync multipass >"${TMP_DIR}/missing.out" 2>&1; then
  echo "expected missing host path to fail" >&2
  exit 1
fi
grep -q 'OBSIDIAN_SHARED_PATH does not exist' "${TMP_DIR}/missing.out"

echo "shared-mounts mock tests passed"
