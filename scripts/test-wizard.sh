#!/usr/bin/env bash
# scripts/test-wizard.sh — Test suite for the setup.sh wizard non-interactive behaviors
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

TEST_DIR="/tmp/test-omlx-wizard-$$"
mkdir -p "${TEST_DIR}"

cleanup() {
  rm -rf "${TEST_DIR}"
  echo "Cleaned up test directory."
}
trap cleanup EXIT

echo "=================================================="
echo "Running Setup Wizard Automation Tests"
echo "=================================================="

# Test Case 1: Fully configured .env runs non-interactively and passes
echo -e "\n--> Test Case 1: Full configuration bypasses prompts"
cat > "${TEST_DIR}/.env" <<EOF
AGENT_RUNTIME='hermes'
MODEL_NAME='mlx-community/Meta-Llama-3-8B-Instruct-4bit'
RAG_ENABLED='0'
SYNCTHING_ENABLED='0'
N8N_ENABLED='0'
EOF

# Ensure any dummy .env.example exists in the execution path
# setup.sh uses ENV_EXAMPLE="${PROJECT_ROOT}/.env.example"
# Let's run setup.sh with OMLX_HOME set to TEST_DIR
if OMLX_HOME="${TEST_DIR}" "${PROJECT_ROOT}/scripts/setup.sh" --dry-run < /dev/null; then
  echo "✓ Test Case 1 PASSED: Wizard completed successfully without prompting."
else
  echo "✗ Test Case 1 FAILED: Wizard requested prompts or failed."
  exit 1
fi

# Test Case 2: Incomplete configuration fails cleanly in non-interactive environment
echo -e "\n--> Test Case 2: Missing AGENT_RUNTIME fails in non-interactive shell"
cat > "${TEST_DIR}/.env" <<EOF
MODEL_NAME='mlx-community/Meta-Llama-3-8B-Instruct-4bit'
RAG_ENABLED='0'
SYNCTHING_ENABLED='0'
N8N_ENABLED='0'
EOF

if OMLX_HOME="${TEST_DIR}" "${PROJECT_ROOT}/scripts/setup.sh" --dry-run < /dev/null > "${TEST_DIR}/test-2-output.log" 2>&1; then
  echo "✗ Test Case 2 FAILED: Wizard succeeded when it should have failed due to missing AGENT_RUNTIME."
  cat "${TEST_DIR}/test-2-output.log"
  exit 1
else
  output_content="$(cat "${TEST_DIR}/test-2-output.log")"
  if printf '%s\n' "${output_content}" | grep -q "missing in .env"; then
    echo "✓ Test Case 2 PASSED: Wizard exited with error and printed: missing in .env"
  else
    echo "✗ Test Case 2 FAILED: Wizard exited with error but did not print expected message."
    echo "Output was:"
    echo "${output_content}"
    exit 1
  fi
fi

# Test Case 3: RAG enabled but missing paths fails cleanly in non-interactive environment
echo -e "\n--> Test Case 3: RAG enabled but missing RAG_SOURCE_PATH fails in non-interactive shell"
cat > "${TEST_DIR}/.env" <<EOF
AGENT_RUNTIME='hermes'
MODEL_NAME='mlx-community/Meta-Llama-3-8B-Instruct-4bit'
RAG_ENABLED='1'
SYNCTHING_ENABLED='0'
N8N_ENABLED='0'
EOF

if OMLX_HOME="${TEST_DIR}" "${PROJECT_ROOT}/scripts/setup.sh" --dry-run < /dev/null > "${TEST_DIR}/test-3-output.log" 2>&1; then
  echo "✗ Test Case 3 FAILED: Wizard succeeded when it should have failed due to missing RAG_SOURCE_PATH."
  cat "${TEST_DIR}/test-3-output.log"
  exit 1
else
  output_content="$(cat "${TEST_DIR}/test-3-output.log")"
  if printf '%s\n' "${output_content}" | grep -q "missing in .env"; then
    echo "✓ Test Case 3 PASSED: Wizard exited with error and printed: missing in .env"
  else
    echo "✗ Test Case 3 FAILED: Wizard exited with error but did not print expected message."
    echo "Output was:"
    echo "${output_content}"
    exit 1
  fi
fi

# Test Case 4: RAG enabled with paths present passes cleanly
echo -e "\n--> Test Case 4: RAG enabled with paths configured passes"
mkdir -p "${TEST_DIR}/mock_docs"
mkdir -p "${TEST_DIR}/mock_obsidian"
cat > "${TEST_DIR}/.env" <<EOF
AGENT_RUNTIME='hermes'
MODEL_NAME='mlx-community/Meta-Llama-3-8B-Instruct-4bit'
RAG_ENABLED='1'
RAG_SOURCE_PATH='${TEST_DIR}/mock_docs'
OBSIDIAN_SHARED_PATH='${TEST_DIR}/mock_obsidian'
SYNCTHING_ENABLED='0'
N8N_ENABLED='0'
EOF

if OMLX_HOME="${TEST_DIR}" "${PROJECT_ROOT}/scripts/setup.sh" --dry-run < /dev/null; then
  echo "✓ Test Case 4 PASSED: RAG configuration successfully verified."
else
  echo "✗ Test Case 4 FAILED: RAG configuration failed."
  exit 1
fi

echo -e "\n=================================================="
echo "All Setup Wizard Automation Tests Passed Successfully!"
echo "=================================================="
