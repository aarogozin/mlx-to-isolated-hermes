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

ACTION="${1:-}"
DOCKER_NAME="${DOCKER_NAME:-omlx-agent-docker}"
DOCKER_DATA_VOLUME="${DOCKER_DATA_VOLUME:-${DOCKER_NAME}-data}"
DOCKER_WORKSPACE_VOLUME="${DOCKER_WORKSPACE_VOLUME:-${DOCKER_NAME}-workspace}"

usage() {
  cat <<EOF
Usage: $0 <start|stop|shell|reset|status>
EOF
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

command -v docker >/dev/null 2>&1 || die "docker CLI missing. Run make bootstrap or install Docker Desktop."

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
    docker start "${DOCKER_NAME}" >/dev/null
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
  status)
    if container_exists; then
      docker ps -a --filter "name=^/${DOCKER_NAME}$"
    else
      echo "Docker sandbox does not exist: ${DOCKER_NAME}"
    fi
    ;;
  *)
    usage
    exit 2
    ;;
esac
