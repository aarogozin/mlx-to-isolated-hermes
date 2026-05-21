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

DOCKER_NAME="${DOCKER_NAME:-omlx-agent-docker}"

echo "==> Starting host oMLX"
"${SCRIPT_DIR}/model-start-omlx-bg.sh"

echo
echo "==> Building Docker sandbox image"
"${SCRIPT_DIR}/docker-build.sh"

echo
echo "==> Creating Docker sandbox"
"${SCRIPT_DIR}/docker-create.sh"

echo
echo "==> Starting Docker sandbox"
"${SCRIPT_DIR}/docker-control.sh" start

echo
echo "==> Docker model connectivity"
docker exec "${DOCKER_NAME}" /bin/bash -lc 'source /opt/data/.env; curl -fsS -H "Authorization: Bearer $OPENAI_API_KEY" "$OPENAI_BASE_URL/models" | jq .'

echo
echo "==> Docker chat completion smoke"
docker exec "${DOCKER_NAME}" /bin/bash -lc 'source /opt/data/.env; curl -fsS --max-time 180 -H "Authorization: Bearer $OPENAI_API_KEY" -H "Content-Type: application/json" "$OPENAI_BASE_URL/chat/completions" -d "{\"model\":\"$MODEL_NAME\",\"messages\":[{\"role\":\"user\",\"content\":\"Reply with exactly: ok\"}],\"max_tokens\":8}" | jq .'

echo
echo "==> Hermes status"
docker exec "${DOCKER_NAME}" /bin/bash -lc 'source /opt/data/.env; hermes_bin="$(command -v hermes || true)"; if [[ -z "$hermes_bin" && -x /opt/hermes/.venv/bin/hermes ]]; then hermes_bin=/opt/hermes/.venv/bin/hermes; fi; printf "hermes=%s\nmodel=%s\nbase=%s\n" "$hermes_bin" "$MODEL_NAME" "$OPENAI_BASE_URL"; "$hermes_bin" doctor | sed -n "1,120p"'

echo
echo "Docker preview ready. Open a shell with:"
echo "  make docker-shell"
