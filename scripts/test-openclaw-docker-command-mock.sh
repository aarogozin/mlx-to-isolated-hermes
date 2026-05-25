#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"

cleanup() {
  rm -rf "${TMP_DIR}"
}
trap cleanup EXIT

BIN_DIR="${TMP_DIR}/bin"
LOG_FILE="${TMP_DIR}/docker.log"
mkdir -p "${BIN_DIR}" "${TMP_DIR}/shared"

cat > "${BIN_DIR}/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

printf 'docker' >> "${MOCK_DOCKER_LOG}"
for arg in "$@"; do
  printf ' %q' "$arg" >> "${MOCK_DOCKER_LOG}"
done
printf '\n' >> "${MOCK_DOCKER_LOG}"

case "${1:-}" in
  image)
    case "${2:-}" in
      inspect) exit 0 ;;
    esac
    ;;
  pull|volume|run|create|start|stop|rm)
    exit 0
    ;;
  container)
    case "${2:-}" in
      inspect) exit 1 ;;
    esac
    ;;
  inspect)
    exit 1
    ;;
esac

exit 0
EOF
chmod +x "${BIN_DIR}/docker"

run_case() {
  local expose="$1"
  : > "${LOG_FILE}"

  PATH="${BIN_DIR}:${PATH}" \
  MOCK_DOCKER_LOG="${LOG_FILE}" \
  OPENCLAW_IMAGE="ghcr.io/openclaw/openclaw:latest" \
  OPENCLAW_PULL_POLICY=never \
  OPENCLAW_DOCKER_NAME="omlx-ci-openclaw" \
  OPENCLAW_DOCKER_CONFIG_VOLUME="omlx-ci-openclaw-config" \
  OPENCLAW_DOCKER_WORKSPACE_VOLUME="omlx-ci-openclaw-workspace" \
  OPENCLAW_DOCKER_AUTH_VOLUME="omlx-ci-openclaw-auth" \
  OPENCLAW_GATEWAY_TOKEN="ci-token" \
  OPENCLAW_CONTROL_PORT=18789 \
  OPENCLAW_BRIDGE_PORT=18790 \
  OPENCLAW_EXPOSE_BRIDGE_PORT="${expose}" \
  OPENAI_API_KEY="ci-api-key" \
  MODEL_NAME="ci-model" \
  OBSIDIAN_SHARED_PATH="${TMP_DIR}/shared" \
  OBSIDIAN_GUEST_PATH="/mnt/obsidian" \
  TELEGRAM_BOT_TOKEN= \
  TELEGRAM_USER_ID= \
    "${PROJECT_ROOT}/scripts/openclaw-control.sh" start docker >/dev/null
}

run_case 0
grep -q -- '--add-host rag-host.internal:host-gateway' "${LOG_FILE}"
grep -q -- '/usr/local/bin/rag-search:ro' "${LOG_FILE}"
grep -q -- '127.0.0.1:18789:18789' "${LOG_FILE}"
if grep -q -- '127.0.0.1:18790:18790' "${LOG_FILE}"; then
  echo "OpenClaw Docker should not expose 18790 by default" >&2
  exit 1
fi

run_case 1
grep -q -- '127.0.0.1:18790:18790' "${LOG_FILE}"

echo "openclaw docker command mock passed"
