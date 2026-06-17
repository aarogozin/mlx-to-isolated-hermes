#!/usr/bin/env bash
# scripts/openclaw-control.sh — Start/stop/status OpenClaw in Docker.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
OMLX_HOME="${OMLX_HOME:-${PROJECT_ROOT}}"
ENV_FILE="${OMLX_HOME}/.env"

OVERRIDE_OPENCLAW_DOCKER_NAME="${OPENCLAW_DOCKER_NAME:-}"
OVERRIDE_OPENCLAW_DOCKER_CONFIG_VOLUME="${OPENCLAW_DOCKER_CONFIG_VOLUME:-}"
OVERRIDE_OPENCLAW_DOCKER_WORKSPACE_VOLUME="${OPENCLAW_DOCKER_WORKSPACE_VOLUME:-}"
OVERRIDE_OPENCLAW_DOCKER_AUTH_VOLUME="${OPENCLAW_DOCKER_AUTH_VOLUME:-}"
OVERRIDE_OBSIDIAN_SHARED_PATH_SET="${OBSIDIAN_SHARED_PATH+x}"
OVERRIDE_OBSIDIAN_SHARED_PATH="${OBSIDIAN_SHARED_PATH:-}"
OVERRIDE_SANDBOX_BACKEND="${SANDBOX_BACKEND:-}"

if [[ -f "${ENV_FILE}" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "${ENV_FILE}"
  set +a
fi

ACTION="${1:-status}"
TARGET="docker"

OPENCLAW_IMAGE="${OPENCLAW_IMAGE:-ghcr.io/openclaw/openclaw:latest}"
OPENCLAW_DOCKER_NAME="${OVERRIDE_OPENCLAW_DOCKER_NAME:-${OPENCLAW_DOCKER_NAME:-omlx-agent-openclaw-docker}}"
OPENCLAW_DOCKER_CONFIG_VOLUME="${OVERRIDE_OPENCLAW_DOCKER_CONFIG_VOLUME:-${OPENCLAW_DOCKER_CONFIG_VOLUME:-${OPENCLAW_DOCKER_NAME}-config}}"
OPENCLAW_DOCKER_WORKSPACE_VOLUME="${OVERRIDE_OPENCLAW_DOCKER_WORKSPACE_VOLUME:-${OPENCLAW_DOCKER_WORKSPACE_VOLUME:-${OPENCLAW_DOCKER_NAME}-workspace}}"
OPENCLAW_DOCKER_AUTH_VOLUME="${OVERRIDE_OPENCLAW_DOCKER_AUTH_VOLUME:-${OPENCLAW_DOCKER_AUTH_VOLUME:-${OPENCLAW_DOCKER_NAME}-auth}}"

OPENCLAW_CONTROL_PORT="${OPENCLAW_CONTROL_PORT:-18789}"
OPENCLAW_BRIDGE_PORT="${OPENCLAW_BRIDGE_PORT:-18790}"
OPENCLAW_EXPOSE_BRIDGE_PORT="${OPENCLAW_EXPOSE_BRIDGE_PORT:-0}"
OPENCLAW_GATEWAY_TOKEN="${OPENCLAW_GATEWAY_TOKEN:-}"
OPENCLAW_GATEWAY_BIND="${OPENCLAW_GATEWAY_BIND:-lan}"
if [[ "${OPENCLAW_GATEWAY_BIND}" == "0.0.0.0" ]]; then
  OPENCLAW_GATEWAY_BIND="lan"
elif [[ "${OPENCLAW_GATEWAY_BIND}" == "127.0.0.1" ]]; then
  OPENCLAW_GATEWAY_BIND="loopback"
fi
OPENCLAW_CONTROL_ALLOWED_ORIGINS="${OPENCLAW_CONTROL_ALLOWED_ORIGINS:-}"

OPENCLAW_OPENAI_BASE_URL_DOCKER="${OPENCLAW_OPENAI_BASE_URL_DOCKER:-${OPENAI_BASE_URL_DOCKER:-http://host.docker.internal:8000/v1}}"
RAG_BASE_URL_DOCKER="${RAG_BASE_URL_DOCKER:-http://rag-host.internal:8765}"

OPENAI_API_KEY="${OPENAI_API_KEY:-}"
TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
TELEGRAM_USER_ID="${TELEGRAM_USER_ID:-}"
TELEGRAM_ALLOWED_USERS="${TELEGRAM_ALLOWED_USERS:-}"
OBSIDIAN_GUEST_PATH="${OBSIDIAN_GUEST_PATH:-/mnt/obsidian}"

if [[ -n "${TELEGRAM_USER_ID}" ]]; then
  TELEGRAM_ALLOWED_USERS="${TELEGRAM_ALLOWED_USERS:-${TELEGRAM_USER_ID}}"
fi

if [[ -n "${OVERRIDE_OBSIDIAN_SHARED_PATH_SET}" ]]; then
  OBSIDIAN_SHARED_PATH="${OVERRIDE_OBSIDIAN_SHARED_PATH}"
else
  OBSIDIAN_SHARED_PATH="${OBSIDIAN_SHARED_PATH:-}"
fi

usage() {
  cat <<EOF
Usage: $0 <start|stop|restart|status|logs|shell|open-dashboard|destroy>
EOF
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

normalize_path() {
  local path="$1"
  [[ -n "${path}" ]] || return 0
  if [[ "${path}" == "~/"* ]]; then
    path="${HOME}/${path#~/}"
  fi
  printf '%s\n' "${path%/}"
}

ensure_gateway_token() {
  if [[ -n "${OPENCLAW_GATEWAY_TOKEN}" ]]; then
    return 0
  fi
  OPENCLAW_GATEWAY_TOKEN="$(openssl rand -hex 24 2>/dev/null || LC_ALL=C tr -dc 'a-f0-9' </dev/urandom | head -c 48; printf '\n')"
  "${SCRIPT_DIR}/env-set.sh" "${ENV_FILE}" OPENCLAW_GATEWAY_TOKEN "${OPENCLAW_GATEWAY_TOKEN}"
}

openclaw_dashboard_base_url() {
  printf 'http://127.0.0.1:%s' "${OPENCLAW_CONTROL_PORT}"
}

openclaw_dashboard_auth_url() {
  ensure_gateway_token
  printf '%s/#token=%s' "$(openclaw_dashboard_base_url)" "${OPENCLAW_GATEWAY_TOKEN}"
}

print_dashboard_access() {
  ensure_gateway_token
  cat <<EOF
Control UI: $(openclaw_dashboard_base_url)
Control UI auth URL: $(openclaw_dashboard_auth_url)
OPENCLAW_GATEWAY_TOKEN=${OPENCLAW_GATEWAY_TOKEN}
EOF
}

detect_model() {
  if [[ -n "${MODEL_NAME:-}" && "${MODEL_NAME}" != "local-model" ]]; then
    return 0
  fi
  local detected
  detected="$(curl -fsS --max-time 3 -H "Authorization: Bearer ${OPENAI_API_KEY}" "${OPENAI_BASE_URL:-http://localhost:8000/v1}/models" 2>/dev/null \
    | jq -r '.data[0].id // empty' 2>/dev/null || true)"
  [[ -n "${detected}" ]] && MODEL_NAME="${detected}"
}

openclaw_env_args() {
  local base_url="$1"
  local rag_url="$2"
  printf '%s\0' \
    -e "HOME=/home/node" \
    -e "OPENCLAW_HOME=/home/node" \
    -e "OPENCLAW_STATE_DIR=/home/node/.openclaw" \
    -e "OPENCLAW_CONFIG_PATH=/home/node/.openclaw/openclaw.json" \
    -e "OPENCLAW_CONFIG_DIR=/home/node/.openclaw" \
    -e "OPENCLAW_WORKSPACE_DIR=/home/node/.openclaw/workspace" \
    -e "OPENCLAW_AUTH_PROFILE_SECRET_DIR=/home/node/.config/openclaw" \
    -e "OPENCLAW_GATEWAY_TOKEN=${OPENCLAW_GATEWAY_TOKEN}" \
    -e "OPENCLAW_ALLOW_INSECURE_PRIVATE_WS=1" \
    -e "OPENCLAW_DISABLE_BONJOUR=1" \
    -e "CUSTOM_API_KEY=${OPENAI_API_KEY}" \
    -e "OPENAI_API_KEY=${OPENAI_API_KEY}" \
    -e "OPENAI_BASE_URL=${base_url}" \
    -e "MODEL_NAME=${MODEL_NAME:-local-model}" \
    -e "RAG_BASE_URL=${rag_url}" \
    -e "TELEGRAM_BOT_TOKEN=${TELEGRAM_BOT_TOKEN}" \
    -e "TELEGRAM_USER_ID=${TELEGRAM_USER_ID}" \
    -e "TELEGRAM_ALLOWED_USERS=${TELEGRAM_ALLOWED_USERS}"
}

docker_container_exists() {
  docker container inspect "${OPENCLAW_DOCKER_NAME}" >/dev/null 2>&1
}

docker_container_running() {
  [[ "$(docker inspect -f '{{.State.Running}}' "${OPENCLAW_DOCKER_NAME}" 2>/dev/null || true)" == "true" ]]
}

docker_run_cli() {
  local -a env_args=()
  while IFS= read -r -d '' arg; do
    env_args+=("${arg}")
  done < <(openclaw_env_args "${OPENCLAW_OPENAI_BASE_URL_DOCKER}" "${RAG_BASE_URL_DOCKER}")

  docker run --rm \
    --platform linux/arm64 \
    --user root \
    -e HOME=/home/node \
    --add-host host.docker.internal:host-gateway \
    --add-host model-host.internal:host-gateway \
    --add-host rag-host.internal:host-gateway \
    --entrypoint node \
    "${env_args[@]}" \
    -v "${OPENCLAW_DOCKER_CONFIG_VOLUME}:/home/node/.openclaw" \
    -v "${OPENCLAW_DOCKER_WORKSPACE_VOLUME}:/home/node/.openclaw/workspace" \
    -v "${OPENCLAW_DOCKER_AUTH_VOLUME}:/home/node/.config/openclaw" \
    -v "${SCRIPT_DIR}/rag-search-bridge.sh:/usr/local/bin/rag-search:ro" \
    "${OPENCLAW_IMAGE}" \
    openclaw.mjs "$@"
}

docker_prepare_volumes() {
  docker run --rm \
    --platform linux/arm64 \
    --user root \
    --entrypoint sh \
    -v "${OPENCLAW_DOCKER_CONFIG_VOLUME}:/home/node/.openclaw" \
    -v "${OPENCLAW_DOCKER_WORKSPACE_VOLUME}:/home/node/.openclaw/workspace" \
    -v "${OPENCLAW_DOCKER_AUTH_VOLUME}:/home/node/.config/openclaw" \
    -v "${SCRIPT_DIR}/rag-search-bridge.sh:/tmp/rag-search:ro" \
    "${OPENCLAW_IMAGE}" \
    -lc 'mkdir -p /home/node/.openclaw/workspace /home/node/.openclaw/skills/local-rag /home/node/.config/openclaw && cp /tmp/rag-search /home/node/.openclaw/rag-search && chmod 0755 /home/node/.openclaw/rag-search && cat > /home/node/.openclaw/skills/local-rag/SKILL.md <<'"'"'EOF'"'"'
# Local RAG

Use the rag-search command before answering questions that may depend on local notes, Obsidian vault content, project knowledge, or personal documents. Prefer a focused search query, cite the returned note path when useful, and do not claim the local knowledge base has no answer until rag-search returns no relevant results.
EOF
chown -R 1000:1000 /home/node/.openclaw /home/node/.config/openclaw'
}

openclaw_config_json() {
  jq -cn \
    --arg bind "${OPENCLAW_GATEWAY_BIND}" \
    --arg origin1 "http://localhost:${OPENCLAW_CONTROL_PORT}" \
    --arg origin2 "http://127.0.0.1:${OPENCLAW_CONTROL_PORT}" \
    --arg extra_origins "${OPENCLAW_CONTROL_ALLOWED_ORIGINS}" \
    --arg tg_token "${TELEGRAM_BOT_TOKEN}" \
    --arg tg_users "${TELEGRAM_ALLOWED_USERS}" '
    def split_origins:
      split(",") | map(gsub("^\\s+|\\s+$";"")) | map(select(. != ""));
    def origins:
      ([$origin1, $origin2]
        + (if $extra_origins != "" then ($extra_origins | split_origins) else [] end))
      | unique;
    [
      {path:"gateway.mode", value:"local"},
      {path:"gateway.bind", value:$bind},
      {path:"gateway.controlUi.allowedOrigins", value:origins}
    ]
    + (if $tg_token != "" then [
      {path:"channels.telegram.enabled", value:true},
      {path:"channels.telegram.dmPolicy", value:(if $tg_users != "" then "allowlist" else "pairing" end)},
      {path:"channels.telegram.groups", value:{"*": {requireMention: true}}}
    ] else [] end)
    + (if $tg_users != "" then [
      {path:"channels.telegram.allowFrom", value:($tg_users | split(",") | map(gsub("^\\s+|\\s+$";"")) | map(select(. != "")))}
    ] else [] end)
  '
}

docker_configure() {
  ensure_gateway_token
  detect_model
  [[ -n "${OPENAI_API_KEY}" ]] || die "OPENAI_API_KEY missing. Run make bootstrap or set it in .env."
  command -v docker >/dev/null 2>&1 || die "docker CLI missing. Run make bootstrap or install Docker Desktop."

  if [[ "${OPENCLAW_PULL_POLICY}" == "always" || ( "${OPENCLAW_PULL_POLICY}" == "latest" && "${OPENCLAW_IMAGE}" == *":latest" ) ]] \
    || ! docker image inspect "${OPENCLAW_IMAGE}" >/dev/null 2>&1; then
    docker pull --platform linux/arm64 "${OPENCLAW_IMAGE}"
  fi

  docker volume create "${OPENCLAW_DOCKER_CONFIG_VOLUME}" >/dev/null
  docker volume create "${OPENCLAW_DOCKER_WORKSPACE_VOLUME}" >/dev/null
  docker volume create "${OPENCLAW_DOCKER_AUTH_VOLUME}" >/dev/null
  docker_prepare_volumes

  docker_run_cli onboard \
    --non-interactive \
    --accept-risk \
    --mode local \
    --auth-choice custom-api-key \
    --custom-base-url "${OPENCLAW_OPENAI_BASE_URL_DOCKER}" \
    --custom-model-id "${MODEL_NAME}" \
    --custom-api-key "${OPENAI_API_KEY}" \
    --secret-input-mode plaintext \
    --custom-compatibility openai \
    --custom-text-input \
    --gateway-auth token \
    --gateway-bind "${OPENCLAW_GATEWAY_BIND}" \
    --gateway-port 18789 \
    --gateway-token-ref-env OPENCLAW_GATEWAY_TOKEN \
    --no-install-daemon \
    --skip-daemon \
    --skip-ui \
    --skip-health >/dev/null

  docker_run_cli config set --batch-json "$(openclaw_config_json)" >/dev/null
}

docker_create() {
  docker_configure

  local -a env_args=()
  while IFS= read -r -d '' arg; do
    env_args+=("${arg}")
  done < <(openclaw_env_args "${OPENCLAW_OPENAI_BASE_URL_DOCKER}" "${RAG_BASE_URL_DOCKER}")

  local -a mount_args=(
    -v "${OPENCLAW_DOCKER_CONFIG_VOLUME}:/home/node/.openclaw"
    -v "${OPENCLAW_DOCKER_WORKSPACE_VOLUME}:/home/node/.openclaw/workspace"
    -v "${OPENCLAW_DOCKER_AUTH_VOLUME}:/home/node/.config/openclaw"
    -v "${SCRIPT_DIR}/rag-search-bridge.sh:/usr/local/bin/rag-search:ro"
  )
  local -a port_args=(
    -p "127.0.0.1:${OPENCLAW_CONTROL_PORT}:18789"
  )
  if [[ "${OPENCLAW_EXPOSE_BRIDGE_PORT}" == "1" || "${OPENCLAW_EXPOSE_BRIDGE_PORT}" == "true" ]]; then
    port_args+=(-p "127.0.0.1:${OPENCLAW_BRIDGE_PORT}:18790")
  fi
  if [[ -n "${OBSIDIAN_SHARED_PATH}" ]]; then
    local host_path
    host_path="$(normalize_path "${OBSIDIAN_SHARED_PATH}")"
    [[ -d "${host_path}" ]] || die "OBSIDIAN_SHARED_PATH does not exist: ${host_path}"
    mount_args+=(-v "${host_path}:${OBSIDIAN_GUEST_PATH}:rw")
  fi

  if docker_container_exists; then
    echo "Stopping and removing existing OpenClaw Docker container: ${OPENCLAW_DOCKER_NAME}"
    docker stop "${OPENCLAW_DOCKER_NAME}" >/dev/null 2>&1 || true
    docker rm "${OPENCLAW_DOCKER_NAME}" >/dev/null 2>&1 || true
  fi

  docker create \
    --name "${OPENCLAW_DOCKER_NAME}" \
    --platform linux/arm64 \
    --restart unless-stopped \
    --user root \
    -e HOME=/home/node \
    --cpus "${DOCKER_CPUS:-2}" \
    --memory "${DOCKER_MEMORY:-4g}" \
    --shm-size "${DOCKER_SHM_SIZE:-1g}" \
    "${port_args[@]}" \
    --add-host host.docker.internal:host-gateway \
    --add-host model-host.internal:host-gateway \
    --add-host rag-host.internal:host-gateway \
    "${env_args[@]}" \
    "${mount_args[@]}" \
    "${OPENCLAW_IMAGE}" \
    node openclaw.mjs gateway run \
      --bind "${OPENCLAW_GATEWAY_BIND}" \
      --port 18789 \
      --auth token \
      --token "${OPENCLAW_GATEWAY_TOKEN}" >/dev/null

  echo "Created OpenClaw Docker gateway: ${OPENCLAW_DOCKER_NAME}"
  print_dashboard_access
}

docker_start() {
  docker_create
  docker start "${OPENCLAW_DOCKER_NAME}" >/dev/null
  echo "OpenClaw Docker gateway running: ${OPENCLAW_DOCKER_NAME}"
  print_dashboard_access
}

docker_stop() {
  if docker_container_exists; then
    docker stop "${OPENCLAW_DOCKER_NAME}" >/dev/null 2>&1 || true
    echo "OpenClaw Docker gateway stopped: ${OPENCLAW_DOCKER_NAME}"
  else
    echo "OpenClaw Docker gateway does not exist: ${OPENCLAW_DOCKER_NAME}"
  fi
}

docker_destroy() {
  docker_stop
  if docker_container_exists; then
    docker rm "${OPENCLAW_DOCKER_NAME}" >/dev/null 2>&1 || true
  fi
  docker volume rm "${OPENCLAW_DOCKER_CONFIG_VOLUME}" "${OPENCLAW_DOCKER_WORKSPACE_VOLUME}" "${OPENCLAW_DOCKER_AUTH_VOLUME}" >/dev/null 2>&1 || true
  echo "Removed OpenClaw Docker volumes if present: ${OPENCLAW_DOCKER_CONFIG_VOLUME}, ${OPENCLAW_DOCKER_WORKSPACE_VOLUME}, ${OPENCLAW_DOCKER_AUTH_VOLUME}"
}

status_target() {
  if command -v docker >/dev/null 2>&1 && docker_container_exists; then
    if docker_container_running; then
      echo "openclaw_docker=running container=${OPENCLAW_DOCKER_NAME}"
    else
      echo "openclaw_docker=stopped container=${OPENCLAW_DOCKER_NAME}"
    fi
  else
    echo "openclaw_docker=missing container=${OPENCLAW_DOCKER_NAME}"
  fi
}

case "${ACTION}" in
  start) docker_start ;;
  stop) docker_stop ;;
  restart) docker_stop; docker_start ;;
  status) status_target ;;
  logs) docker logs --tail 200 "${OPENCLAW_DOCKER_NAME}" 2>&1 || true ;;
  shell)
    docker_create
    docker_container_running || docker start "${OPENCLAW_DOCKER_NAME}" >/dev/null
    tty_args=(-i)
    if [[ -t 0 && -t 1 ]]; then
      tty_args=(-it)
    fi
    exec docker exec "${tty_args[@]}" "${OPENCLAW_DOCKER_NAME}" /bin/bash
    ;;
  open-dashboard)
    print_dashboard_access
    if command -v open >/dev/null 2>&1; then
      open "$(openclaw_dashboard_auth_url)"
    else
      echo "OpenClaw Control UI: $(openclaw_dashboard_auth_url)"
    fi
    ;;
  destroy) docker_destroy ;;
  *)
    usage
    exit 2
    ;;
esac
