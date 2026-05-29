#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENV_FILE="${PROJECT_ROOT}/.env"

OVERRIDE_TELEGRAM_BOT_TOKEN_SET="${TELEGRAM_BOT_TOKEN+x}"
OVERRIDE_TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
OVERRIDE_DOCKER_NAME="${DOCKER_NAME:-}"
OVERRIDE_AGENT_DATA_DIR="${AGENT_DATA_DIR:-}"
OVERRIDE_DOCKER_DATA_VOLUME="${DOCKER_DATA_VOLUME:-}"
OVERRIDE_DOCKER_WORKSPACE_VOLUME="${DOCKER_WORKSPACE_VOLUME:-}"

if [[ -f "${ENV_FILE}" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "${ENV_FILE}"
  set +a
fi

ACTION="${1:-}"
DOCKER_NAME="${OVERRIDE_DOCKER_NAME:-${DOCKER_NAME:-omlx-agent-docker}}"
AGENT_DATA_DIR="${OVERRIDE_AGENT_DATA_DIR:-${AGENT_DATA_DIR:-}}"
DOCKER_DATA_VOLUME="${OVERRIDE_DOCKER_DATA_VOLUME:-${DOCKER_DATA_VOLUME:-${DOCKER_NAME}-data}}"
DOCKER_WORKSPACE_VOLUME="${OVERRIDE_DOCKER_WORKSPACE_VOLUME:-${DOCKER_WORKSPACE_VOLUME:-${DOCKER_NAME}-workspace}}"
if [[ -n "${OVERRIDE_TELEGRAM_BOT_TOKEN_SET}" ]]; then
  TELEGRAM_BOT_TOKEN="${OVERRIDE_TELEGRAM_BOT_TOKEN}"
else
  TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
fi

usage() {
  cat <<EOF
Usage: $0 <start|stop|shell|update|reset|destroy|status|data-path>
EOF
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

if ! command -v docker >/dev/null 2>&1; then
  case "${ACTION}" in
    destroy|reset|stop|status)
      echo "docker CLI missing; no Docker sandbox to manage."
      exit 0
      ;;
    *)
      die "docker CLI missing. Run make bootstrap or install Docker Desktop."
      ;;
  esac
fi

container_exists() {
  docker container inspect "${DOCKER_NAME}" >/dev/null 2>&1
}

container_running() {
  [[ "$(docker inspect -f '{{.State.Running}}' "${DOCKER_NAME}" 2>/dev/null || true)" == "true" ]]
}

ensure_container() {
  if ! container_exists; then
    "${SCRIPT_DIR}/docker-create.sh"
  fi
}

case "${ACTION}" in
  start)
    ensure_container
    if [[ -n "${TELEGRAM_BOT_TOKEN}" ]]; then
      # Stop any VM gateway that might conflict with Docker's Telegram polling.
      # The status check can be unreliable, so also do a direct process kill in the VM.
      TELEGRAM_TARGET=vm "${SCRIPT_DIR}/telegram-control.sh" stop 2>/dev/null || true
      if command -v multipass >/dev/null 2>&1; then
        multipass exec "${VM_NAME:-omlx-agent-ubuntu}" -- bash -c \
          'pkill -f "gateway run" 2>/dev/null; rm -f "$HOME/.hermes/gateway.pid"' 2>/dev/null || true
      fi
      TELEGRAM_TARGET=docker "${SCRIPT_DIR}/telegram-control.sh" start
      exit 0
    fi
    docker start "${DOCKER_NAME}" >/dev/null
    # Apply WebSocket loopback gate patch and restart dashboard service:
    docker exec -u root "${DOCKER_NAME}" python3 -c 'p="/opt/hermes/hermes_cli/web_server.py"; c=open(p).read(); open(p,"w").write(c.replace("return client_host in _LOOPBACK_HOSTS", "return True"))' >/dev/null 2>&1 || true
    docker exec -u root "${DOCKER_NAME}" /command/s6-svc -r /run/service/dashboard >/dev/null 2>&1 || true
    echo "Docker sandbox running: ${DOCKER_NAME}"
    ;;
  stop)
    if container_exists; then
      docker stop "${DOCKER_NAME}" >/dev/null || true
      echo "Docker sandbox stopped: ${DOCKER_NAME}"
    else
      echo "Docker sandbox does not exist: ${DOCKER_NAME}"
    fi
    ;;
  shell)
    ensure_container
    if ! container_running; then
      docker start "${DOCKER_NAME}" >/dev/null
    fi
    tty_args=(-i)
    if [[ -t 0 && -t 1 ]]; then
      tty_args=(-it)
    fi
    exec docker exec "${tty_args[@]}" "${DOCKER_NAME}" /bin/bash
    ;;
  reset)
    if container_exists; then
      docker stop "${DOCKER_NAME}" >/dev/null || true
      docker rm "${DOCKER_NAME}" >/dev/null
      echo "Removed Docker sandbox container: ${DOCKER_NAME}"
    fi
    if [[ "${DOCKER_RESET_DATA:-0}" == "1" ]]; then
      docker volume rm "${DOCKER_DATA_VOLUME}" "${DOCKER_WORKSPACE_VOLUME}" >/dev/null 2>&1 || true
      echo "Removed Docker sandbox volumes."
    else
      echo "Preserved Docker volumes. Set DOCKER_RESET_DATA=1 to remove Hermes data and workspace."
    fi
    ;;
  destroy)
    if container_exists; then
      docker stop "${DOCKER_NAME}" >/dev/null 2>&1 || true
      docker rm "${DOCKER_NAME}" >/dev/null 2>&1 || true
      echo "Removed Docker sandbox container: ${DOCKER_NAME}"
    else
      echo "Docker sandbox container already absent: ${DOCKER_NAME}"
    fi
    docker volume rm "${DOCKER_DATA_VOLUME}" "${DOCKER_WORKSPACE_VOLUME}" >/dev/null 2>&1 || true
    echo "Removed Docker sandbox volumes if present: ${DOCKER_DATA_VOLUME}, ${DOCKER_WORKSPACE_VOLUME}"
    ;;
  status)
    if container_exists; then
      docker ps -a --filter "name=^/${DOCKER_NAME}$"
    else
      echo "Docker sandbox does not exist: ${DOCKER_NAME}"
    fi
    ;;
esac

# ── update ────────────────────────────────────────────────────────────────────
do_update() {
  local current_image
  current_image="$(docker inspect -f '{{.Config.Image}}' "${DOCKER_NAME}" 2>/dev/null || true)"

  if [[ -z "${current_image}" ]]; then
    # Container doesn't exist yet; use the image from env
    current_image="${HERMES_IMAGE:-nousresearch/hermes-agent:latest}"
  fi

  echo "Pulling latest image: ${current_image}..."
  if docker pull "${current_image}"; then
    echo "Image updated: ${current_image}"
  else
    echo "WARNING: docker pull failed, will restart with existing local image" >&2
  fi

  if container_exists; then
    echo "Stopping ${DOCKER_NAME}..."
    docker stop "${DOCKER_NAME}" > /dev/null 2>&1 || true
    docker rm   "${DOCKER_NAME}" > /dev/null 2>&1 || true
  fi

  "${SCRIPT_DIR}/docker-create.sh"
  docker start "${DOCKER_NAME}" > /dev/null
  echo "Updated and restarted: ${DOCKER_NAME}"
}

# ── data-path ─────────────────────────────────────────────────────────────────
do_data_path() {
  local data_path
  if [[ -n "${AGENT_DATA_DIR}" ]]; then
    data_path="${AGENT_DATA_DIR}"
    case "${data_path}" in
      /*) ;;
      *) data_path="${SCRIPT_DIR}/../${data_path}" ;;
    esac
  else
    data_path="${SCRIPT_DIR}/../.runtime/agent"
  fi
  data_path="$(cd "${data_path}" 2>/dev/null && pwd || echo "${data_path} (not created yet)")"
  echo "agent_data_dir=${data_path}"
  if [[ -d "${data_path}" ]]; then
    echo "contents:"
    ls -la "${data_path}" 2>/dev/null | sed 's/^/  /'
  fi
}

case "${ACTION}" in
  update)    do_update ;;
  data-path) do_data_path ;;
  *)
    usage
    exit 2
    ;;
esac
