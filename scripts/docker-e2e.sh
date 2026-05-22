#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENV_FILE="${PROJECT_ROOT}/.env"

OVERRIDE_DOCKER_E2E_NAME="${DOCKER_E2E_NAME:-}"

if [[ -f "${ENV_FILE}" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "${ENV_FILE}"
  set +a
fi

DOCKER_NAME="${OVERRIDE_DOCKER_E2E_NAME:-omlx-agent-docker-e2e}"
export DOCKER_NAME
export DOCKER_DATA_VOLUME="${DOCKER_NAME}-data"
export DOCKER_WORKSPACE_VOLUME="${DOCKER_NAME}-workspace"
export TELEGRAM_BOT_TOKEN=""
export TELEGRAM_USER_ID=""
export TELEGRAM_ALLOWED_USERS=""
export GATEWAY_ALLOWED_USERS=""

echo "==> Starting host oMLX"
"${SCRIPT_DIR}/model-start-omlx-bg.sh"

echo
echo "==> Creating Docker sandbox"
"${SCRIPT_DIR}/docker-create.sh"

echo
echo "==> Starting Docker sandbox"
"${SCRIPT_DIR}/docker-control.sh" start

echo
echo "==> Docker model connectivity"
docker exec "${DOCKER_NAME}" /bin/bash -lc 'source /opt/data/.env; curl -fsS -H "Authorization: Bearer $OPENAI_API_KEY" "$OPENAI_BASE_URL/models"' | jq .

echo
echo "==> Docker chat completion smoke"
docker exec "${DOCKER_NAME}" /bin/bash -lc 'source /opt/data/.env; curl -fsS --max-time 180 -H "Authorization: Bearer $OPENAI_API_KEY" -H "Content-Type: application/json" "$OPENAI_BASE_URL/chat/completions" -d "{\"model\":\"$MODEL_NAME\",\"messages\":[{\"role\":\"user\",\"content\":\"Reply with exactly: ok\"}],\"max_tokens\":8}"' | jq .

echo
echo "==> Hermes status"
docker exec "${DOCKER_NAME}" /bin/bash -lc 'source /opt/data/.env; hermes_bin="$(command -v hermes || true)"; if [[ -z "$hermes_bin" && -x /opt/hermes/.venv/bin/hermes ]]; then hermes_bin=/opt/hermes/.venv/bin/hermes; fi; printf "hermes=%s\nmodel=%s\nbase=%s\n" "$hermes_bin" "$MODEL_NAME" "$OPENAI_BASE_URL"; "$hermes_bin" doctor | sed -n "1,120p"'

if [[ -n "${OBSIDIAN_SHARED_PATH:-}" ]]; then
  echo
  echo "==> Docker shared folder smoke"
  "${SCRIPT_DIR}/shared-mounts-check.sh" docker
fi

echo
if [[ "${KEEP_DOCKER_E2E:-0}" == "1" ]]; then
  echo "Docker e2e container left running. Open a shell with:"
  echo "  DOCKER_NAME=${DOCKER_NAME} ./scripts/docker-control.sh shell"
else
  docker stop "${DOCKER_NAME}" >/dev/null 2>&1 || true
  docker rm "${DOCKER_NAME}" >/dev/null 2>&1 || true
  docker volume rm "${DOCKER_DATA_VOLUME}" "${DOCKER_WORKSPACE_VOLUME}" >/dev/null 2>&1 || true
  echo "Docker e2e complete; removed ${DOCKER_NAME} and its test volumes. Set KEEP_DOCKER_E2E=1 to keep it running."
fi
