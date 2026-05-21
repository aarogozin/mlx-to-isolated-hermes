#!/usr/bin/env bash
# scripts/e2e-ready.sh — Full end-to-end provisioning smoke-test.
#
# Syncs models, starts oMLX, installs Hermes in the VM, and verifies
# that the guest can reach the model API. Supports VM_ENGINE=multipass
# and VM_ENGINE=vmware/fusion via vm-common.sh.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENV_FILE="${PROJECT_ROOT}/.env"

# shellcheck source=vm-common.sh
source "${SCRIPT_DIR}/vm-common.sh"

echo "==> Downloaded LM Studio models"
"${SCRIPT_DIR}/models-list-human.sh"

echo
echo "==> Syncing LM Studio MLX models for oMLX"
"${SCRIPT_DIR}/models-sync-omlx.sh"

echo
echo "==> Starting host oMLX"
"${SCRIPT_DIR}/model-start-omlx-bg.sh"

echo
echo "==> Provisioning Hermes in VM"
"${SCRIPT_DIR}/agents-install.sh"

echo
echo "==> Syncing Hermes model catalog"
"${SCRIPT_DIR}/hermes-sync-models.sh"

set -a
# shellcheck disable=SC1090
source "${ENV_FILE}"
set +a

echo
echo "==> Guest model connectivity"
vm_exec 'source ~/.hermes/.env; curl -fsS -H "Authorization: Bearer $OPENAI_API_KEY" "$OPENAI_BASE_URL/models" | jq .'

echo
echo "==> Hermes status"
vm_exec 'export PATH="$HOME/.local/bin:$PATH"; source ~/.hermes/.env; printf "hermes=%s\nmodel=%s\nbase=%s\n" "$(command -v hermes)" "$MODEL_NAME" "$OPENAI_BASE_URL"; hermes doctor | sed -n "1,120p"'

echo
echo "Ready. Start Hermes with:"
echo "  make vm-ssh"
echo "  hermes"
