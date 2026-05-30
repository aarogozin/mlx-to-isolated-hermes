#!/usr/bin/env bash
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

ACTION="${1:-cloudflare-status}"
AGENT_RUNTIME="${AGENT_RUNTIME:-hermes}"
SANDBOX_BACKEND="${SANDBOX_BACKEND:-docker}"
CLOUDFLARE_TUNNEL_TOKEN="${CLOUDFLARE_TUNNEL_TOKEN:-}"
HERMES_DASHBOARD_PORT="${HERMES_DASHBOARD_PORT:-9119}"
DOCKER_DASHBOARD_PORT="${DOCKER_DASHBOARD_PORT:-9120}"
OPENCLAW_CONTROL_PORT="${OPENCLAW_CONTROL_PORT:-18789}"
OPENCLAW_GATEWAY_TOKEN="${OPENCLAW_GATEWAY_TOKEN:-}"

die() {
  echo "ERROR: $*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "$1 is missing."
}

local_dashboard_target() {
  case "${AGENT_RUNTIME}" in
    openclaw) printf 'http://127.0.0.1:%s\n' "${OPENCLAW_CONTROL_PORT}" ;;
    hermes) printf 'http://127.0.0.1:%s\n' "${DOCKER_DASHBOARD_PORT}" ;;
  esac
}


start_local_dashboard() {
  AGENT_RUNTIME="${AGENT_RUNTIME}" SANDBOX_BACKEND="${SANDBOX_BACKEND}" "${SCRIPT_DIR}/agent-control.sh" start
}

case "${ACTION}" in
  cloudflare-start)
    require_command docker
    [[ -n "${CLOUDFLARE_TUNNEL_TOKEN}" ]] || die "CLOUDFLARE_TUNNEL_TOKEN missing in .env."
    start_local_dashboard
    cd "${PROJECT_ROOT}"
    docker compose -f docker-compose.cloudflared.yml up -d
    ;;
  cloudflare-stop)
    require_command docker
    cd "${PROJECT_ROOT}"
    docker compose -f docker-compose.cloudflared.yml down
    ;;
  cloudflare-status)
    require_command docker
    cd "${PROJECT_ROOT}"
    docker compose -f docker-compose.cloudflared.yml ps
    ;;
  *)
    cat <<EOF
Usage: $0 <cloudflare-start|cloudflare-stop|cloudflare-status>
EOF
    exit 2
    ;;
esac
