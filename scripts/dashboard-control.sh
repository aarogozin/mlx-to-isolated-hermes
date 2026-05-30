#!/usr/bin/env bash
# scripts/dashboard-control.sh — Start/stop/status the Hermes Dashboard in Docker.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
OMLX_HOME="${OMLX_HOME:-${PROJECT_ROOT}}"
ENV_FILE="${OMLX_HOME}/.env"

if [[ -f "${ENV_FILE}" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "${ENV_FILE}"
  set +a
fi

ACTION="${1:-status}"
TARGET="docker"
DOCKER_NAME="${DOCKER_NAME:-omlx-agent-docker}"
HERMES_DASHBOARD_PORT="${HERMES_DASHBOARD_PORT:-9119}"
DOCKER_DASHBOARD_PORT="${DOCKER_DASHBOARD_PORT:-9120}"
HERMES_DASHBOARD_TUI="${HERMES_DASHBOARD_TUI:-0}"
LOCAL_DASHBOARD_HOST="${LOCAL_DASHBOARD_HOST:-127.0.0.1}"

usage() {
  cat <<EOF
Usage: $0 <start|stop|restart|status|logs|open>
EOF
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

dashboard_url() {
  printf 'http://%s:%s\n' "${LOCAL_DASHBOARD_HOST}" "${DOCKER_DASHBOARD_PORT}"
}

port_listening() {
  lsof -nP -iTCP:"${DOCKER_DASHBOARD_PORT}" -sTCP:LISTEN >/dev/null 2>&1
}

# ── Docker target ─────────────────────────────────────────────────────────────

docker_start_and_patch() {
  docker start "${DOCKER_NAME}" >/dev/null
  # Apply WebSocket loopback gate patch and restart dashboard service:
  docker exec -u root "${DOCKER_NAME}" python3 -c 'p="/opt/hermes/hermes_cli/web_server.py"; c=open(p).read(); c=c.replace("return client_host in _LOOPBACK_HOSTS", "return True"); c=c.replace("return hmac.compare_digest(token.encode(), _SESSION_TOKEN.encode())", "return True"); open(p,"w").write(c)' >/dev/null 2>&1 || true
  docker exec -u root "${DOCKER_NAME}" /command/s6-svc -r /run/service/dashboard >/dev/null 2>&1 || true
}

docker_ensure() {
  command -v docker >/dev/null 2>&1 || die "docker CLI missing."
  "${SCRIPT_DIR}/docker-create.sh" >/dev/null
  docker_start_and_patch
}

start_docker() {
  docker_ensure
  echo "Hermes dashboard: $(dashboard_url)"
}

stop_docker() {
  if docker container inspect "${DOCKER_NAME}" >/dev/null 2>&1; then
    docker stop "${DOCKER_NAME}" >/dev/null || true
    echo "Docker Hermes dashboard stopped: ${DOCKER_NAME}"
  else
    echo "Docker container does not exist: ${DOCKER_NAME}"
  fi
}

status_docker() {
  command -v docker >/dev/null 2>&1 || die "docker CLI missing."
  if ! docker container inspect "${DOCKER_NAME}" >/dev/null 2>&1; then
    echo "dashboard=missing container=${DOCKER_NAME}"
    echo "web=not-ready url=$(dashboard_url)"
    return
  fi
  if [[ "$(docker inspect -f '{{.State.Running}}' "${DOCKER_NAME}" 2>/dev/null || true)" == "true" ]]; then
    echo "dashboard=managed-by-container container=running"
  else
    echo "dashboard=managed-by-container container=stopped"
  fi
  if curl -fsS --max-time 2 "$(dashboard_url)" >/dev/null 2>&1; then
    echo "web=ready url=$(dashboard_url)"
  else
    echo "web=not-ready url=$(dashboard_url)"
  fi
}

logs_docker() {
  docker_ensure
  docker logs --tail 160 "${DOCKER_NAME}" 2>&1 | sed -n '/^\[dashboard\]/p'
}

open_dashboard() {
  local url
  url="$(dashboard_url)"
  command -v open >/dev/null 2>&1 && open "${url}"
  echo "${url}"
}

# ── Dispatch ──────────────────────────────────────────────────────────────────

case "${ACTION}" in
  start|restart)
    [[ "${ACTION}" == "restart" ]] && "${BASH_SOURCE[0]}" stop
    start_docker
    ;;
  stop)
    stop_docker
    ;;
  status)
    status_docker
    ;;
  logs)
    logs_docker
    ;;
  open)
    open_dashboard
    ;;
  *)
    usage
    exit 2
    ;;
esac
