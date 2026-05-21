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
DOCKER_IMAGE="${DOCKER_IMAGE:-omlx-agent-hermes:0.1.0}"
DOCKER_DATA_VOLUME="${DOCKER_DATA_VOLUME:-${DOCKER_NAME}-data}"
DOCKER_WORKSPACE_VOLUME="${DOCKER_WORKSPACE_VOLUME:-${DOCKER_NAME}-workspace}"
DOCKER_CPUS="${DOCKER_CPUS:-2}"
DOCKER_MEMORY="${DOCKER_MEMORY:-4g}"
DOCKER_SHM_SIZE="${DOCKER_SHM_SIZE:-1g}"
HERMES_DASHBOARD_PORT="${HERMES_DASHBOARD_PORT:-9119}"
OPENAI_BASE_URL_DOCKER="${OPENAI_BASE_URL_DOCKER:-http://host.docker.internal:8000/v1}"
ANTHROPIC_BASE_URL_DOCKER="${ANTHROPIC_BASE_URL_DOCKER:-http://host.docker.internal:8000}"
OPENAI_API_KEY="${OPENAI_API_KEY:-}"
ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY:-${OPENAI_API_KEY}}"
MODEL_NAME="${MODEL_NAME:-local-model}"
OBSIDIAN_SHARED_PATH="${OBSIDIAN_SHARED_PATH:-}"
TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
TELEGRAM_USER_ID="${TELEGRAM_USER_ID:-}"
TELEGRAM_ALLOWED_USERS="${TELEGRAM_ALLOWED_USERS:-}"
TELEGRAM_GROUP_ALLOWED_USERS="${TELEGRAM_GROUP_ALLOWED_USERS:-}"
TELEGRAM_GROUP_ALLOWED_CHATS="${TELEGRAM_GROUP_ALLOWED_CHATS:-}"
GATEWAY_ALLOWED_USERS="${GATEWAY_ALLOWED_USERS:-}"
GATEWAY_ALLOW_ALL_USERS="${GATEWAY_ALLOW_ALL_USERS:-false}"

if [[ -n "${TELEGRAM_USER_ID}" ]]; then
  TELEGRAM_ALLOWED_USERS="${TELEGRAM_ALLOWED_USERS:-${TELEGRAM_USER_ID}}"
  GATEWAY_ALLOWED_USERS="${GATEWAY_ALLOWED_USERS:-${TELEGRAM_USER_ID}}"
fi

die() {
  echo "ERROR: $*" >&2
  exit 1
}

command -v docker >/dev/null 2>&1 || die "docker CLI missing. Run make bootstrap or install Docker Desktop."
[[ -n "${OPENAI_API_KEY}" ]] || die "OPENAI_API_KEY missing. Run make bootstrap or set it in .env."

if ! docker image inspect "${DOCKER_IMAGE}" >/dev/null 2>&1; then
  "${SCRIPT_DIR}/docker-build.sh"
fi

if [[ "${MODEL_NAME}" == "local-model" || -z "${MODEL_NAME}" ]]; then
  detected_model="$(curl -fsS --max-time 3 -H "Authorization: Bearer ${OPENAI_API_KEY}" "${OPENAI_BASE_URL:-http://localhost:8000/v1}/models" 2>/dev/null | jq -r '.data[0].id // empty' 2>/dev/null || true)"
  if [[ -n "${detected_model}" ]]; then
    MODEL_NAME="${detected_model}"
  else
    MODEL_NAME="local-model"
  fi
fi

docker volume create "${DOCKER_DATA_VOLUME}" >/dev/null
docker volume create "${DOCKER_WORKSPACE_VOLUME}" >/dev/null

docker run --rm \
  --user root \
  -e OPENAI_BASE_URL="${OPENAI_BASE_URL_DOCKER}" \
  -e ANTHROPIC_BASE_URL="${ANTHROPIC_BASE_URL_DOCKER}" \
  -e OPENAI_API_KEY="${OPENAI_API_KEY}" \
  -e ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY}" \
  -e MODEL_NAME="${MODEL_NAME}" \
  -e TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN}" \
  -e TELEGRAM_USER_ID="${TELEGRAM_USER_ID}" \
  -e TELEGRAM_ALLOWED_USERS="${TELEGRAM_ALLOWED_USERS}" \
  -e TELEGRAM_GROUP_ALLOWED_USERS="${TELEGRAM_GROUP_ALLOWED_USERS}" \
  -e TELEGRAM_GROUP_ALLOWED_CHATS="${TELEGRAM_GROUP_ALLOWED_CHATS}" \
  -e GATEWAY_ALLOWED_USERS="${GATEWAY_ALLOWED_USERS}" \
  -e GATEWAY_ALLOW_ALL_USERS="${GATEWAY_ALLOW_ALL_USERS}" \
  -v "${DOCKER_DATA_VOLUME}:/opt/data" \
  -v "${DOCKER_WORKSPACE_VOLUME}:/home/agent/workspace" \
  --entrypoint /bin/sh \
  "${DOCKER_IMAGE}" \
  -lc 'set -eu
mkdir -p /opt/data /home/agent/workspace
mkdir -p /opt/data/.local/bin
ln -sfn /opt/hermes/.venv/bin/hermes /opt/data/.local/bin/hermes
cat > /opt/data/.env <<EOF
OPENAI_BASE_URL=${OPENAI_BASE_URL}
ANTHROPIC_BASE_URL=${ANTHROPIC_BASE_URL}
OPENAI_API_KEY=${OPENAI_API_KEY}
ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY}
MODEL_NAME=${MODEL_NAME}
EOF
append_env_if_set() {
  key="$1"
  value="$2"
  if [ -n "$value" ]; then
    printf "%s=%s\n" "$key" "$value" >> /opt/data/.env
  fi
}
append_env_if_set TELEGRAM_BOT_TOKEN "${TELEGRAM_BOT_TOKEN}"
append_env_if_set TELEGRAM_USER_ID "${TELEGRAM_USER_ID}"
append_env_if_set TELEGRAM_ALLOWED_USERS "${TELEGRAM_ALLOWED_USERS}"
append_env_if_set TELEGRAM_GROUP_ALLOWED_USERS "${TELEGRAM_GROUP_ALLOWED_USERS}"
append_env_if_set TELEGRAM_GROUP_ALLOWED_CHATS "${TELEGRAM_GROUP_ALLOWED_CHATS}"
append_env_if_set GATEWAY_ALLOWED_USERS "${GATEWAY_ALLOWED_USERS}"
append_env_if_set GATEWAY_ALLOW_ALL_USERS "${GATEWAY_ALLOW_ALL_USERS}"
cat > /opt/data/config.yaml <<EOF
model:
  provider: custom
  default: "${MODEL_NAME}"
  model: "${MODEL_NAME}"
  base_url: "${OPENAI_BASE_URL}"
  api_key: "${OPENAI_API_KEY}"
terminal:
  backend: local
  cwd: "/home/agent/workspace"
EOF
chown -R 10000:10000 /opt/data /home/agent/workspace'

if docker container inspect "${DOCKER_NAME}" >/dev/null 2>&1; then
  current_image_id="$(docker inspect -f '{{.Image}}' "${DOCKER_NAME}")"
  desired_image_id="$(docker image inspect -f '{{.Id}}' "${DOCKER_IMAGE}")"
  current_dashboard_port="$(docker inspect -f '{{range $port, $bindings := .NetworkSettings.Ports}}{{if eq $port "9119/tcp"}}{{range $bindings}}{{.HostIp}}:{{.HostPort}}{{end}}{{end}}{{end}}' "${DOCKER_NAME}")"
  desired_dashboard_port="127.0.0.1:${HERMES_DASHBOARD_PORT}"
  if [[ "${current_image_id}" == "${desired_image_id}" && "${current_dashboard_port}" == "${desired_dashboard_port}" ]]; then
    echo "Docker container already exists: ${DOCKER_NAME}"
    exit 0
  fi

  echo "Recreating Docker container ${DOCKER_NAME} because image or dashboard port changed."
  docker stop "${DOCKER_NAME}" >/dev/null 2>&1 || true
  docker rm "${DOCKER_NAME}" >/dev/null
fi

mount_args=(
  -v "${DOCKER_DATA_VOLUME}:/opt/data"
  -v "${DOCKER_WORKSPACE_VOLUME}:/home/agent/workspace"
)

if [[ -n "${OBSIDIAN_SHARED_PATH}" ]]; then
  [[ -d "${OBSIDIAN_SHARED_PATH}" ]] || die "OBSIDIAN_SHARED_PATH does not exist: ${OBSIDIAN_SHARED_PATH}"
  mount_args+=(-v "${OBSIDIAN_SHARED_PATH}:/mnt/obsidian:rw")
fi

docker create \
  --name "${DOCKER_NAME}" \
  --platform linux/arm64 \
  --restart unless-stopped \
  --cpus "${DOCKER_CPUS}" \
  --memory "${DOCKER_MEMORY}" \
  --shm-size "${DOCKER_SHM_SIZE}" \
  -p "127.0.0.1:${HERMES_DASHBOARD_PORT}:9119" \
  --add-host model-host.internal:host-gateway \
  -e OPENAI_BASE_URL="${OPENAI_BASE_URL_DOCKER}" \
  -e ANTHROPIC_BASE_URL="${ANTHROPIC_BASE_URL_DOCKER}" \
  -e OPENAI_API_KEY="${OPENAI_API_KEY}" \
  -e ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY}" \
  -e MODEL_NAME="${MODEL_NAME}" \
  -e TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN}" \
  -e TELEGRAM_USER_ID="${TELEGRAM_USER_ID}" \
  -e TELEGRAM_ALLOWED_USERS="${TELEGRAM_ALLOWED_USERS}" \
  -e TELEGRAM_GROUP_ALLOWED_USERS="${TELEGRAM_GROUP_ALLOWED_USERS}" \
  -e TELEGRAM_GROUP_ALLOWED_CHATS="${TELEGRAM_GROUP_ALLOWED_CHATS}" \
  -e GATEWAY_ALLOWED_USERS="${GATEWAY_ALLOWED_USERS}" \
  -e GATEWAY_ALLOW_ALL_USERS="${GATEWAY_ALLOW_ALL_USERS}" \
  "${mount_args[@]}" \
  "${DOCKER_IMAGE}" \
  sleep infinity >/dev/null

echo "Created Docker sandbox: ${DOCKER_NAME}"
echo "Image: ${DOCKER_IMAGE}"
echo "Model API: ${OPENAI_BASE_URL_DOCKER}"
echo "Model: ${MODEL_NAME}"
