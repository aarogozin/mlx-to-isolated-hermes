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

ACTION="${1:-tailscale-status}"
AGENT_RUNTIME="${AGENT_RUNTIME:-hermes}"
SANDBOX_BACKEND="${SANDBOX_BACKEND:-multipass}"
TAILSCALE_ENABLED="${TAILSCALE_ENABLED:-0}"
TAILSCALE_SERVE_MODE="${TAILSCALE_SERVE_MODE:-serve}"
TAILSCALE_DASHBOARD_TARGET="${TAILSCALE_DASHBOARD_TARGET:-}"
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
  if [[ -n "${TAILSCALE_DASHBOARD_TARGET}" ]]; then
    printf '%s\n' "${TAILSCALE_DASHBOARD_TARGET}"
    return
  fi

  case "${AGENT_RUNTIME}:${SANDBOX_BACKEND}" in
    openclaw:*) printf 'http://127.0.0.1:%s\n' "${OPENCLAW_CONTROL_PORT}" ;;
    hermes:docker) printf 'http://127.0.0.1:%s\n' "${DOCKER_DASHBOARD_PORT}" ;;
    *) printf 'http://127.0.0.1:%s\n' "${HERMES_DASHBOARD_PORT}" ;;
  esac
}

print_access_hint() {
  local target="$1"
  echo "Local dashboard origin: ${target}"
  if [[ "${AGENT_RUNTIME}" == "openclaw" ]]; then
    if [[ -n "${OPENCLAW_GATEWAY_TOKEN}" ]]; then
      echo "OpenClaw local auth URL: ${target%/}/#token=${OPENCLAW_GATEWAY_TOKEN}"
      echo "OPENCLAW_GATEWAY_TOKEN=${OPENCLAW_GATEWAY_TOKEN}"
    else
      echo "OpenClaw token missing; run make bootstrap or make agent-start to generate OPENCLAW_GATEWAY_TOKEN."
    fi
  fi
}

start_local_dashboard() {
  AGENT_RUNTIME="${AGENT_RUNTIME}" SANDBOX_BACKEND="${SANDBOX_BACKEND}" "${SCRIPT_DIR}/agent-control.sh" start
}

case "${ACTION}" in
  tailscale-start)
    require_command tailscale
    start_local_dashboard
    target="$(local_dashboard_target)"
    case "${TAILSCALE_SERVE_MODE}" in
      serve) tailscale serve --bg "${target}" ;;
      funnel) tailscale funnel --bg "${target}" ;;
      *) die "unsupported TAILSCALE_SERVE_MODE=${TAILSCALE_SERVE_MODE}; use serve or funnel" ;;
    esac
    print_access_hint "${target}"
    tailscale serve status
    ;;
  tailscale-stop)
    require_command tailscale
    case "${TAILSCALE_SERVE_MODE}" in
      funnel) tailscale funnel reset ;;
      *) tailscale serve reset ;;
    esac
    ;;
  tailscale-status)
    require_command tailscale
    case "${TAILSCALE_SERVE_MODE}" in
      funnel) tailscale funnel status ;;
      *) tailscale serve status ;;
    esac
    ;;
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
Usage: $0 <tailscale-start|tailscale-stop|tailscale-status|cloudflare-start|cloudflare-stop|cloudflare-status>
EOF
    exit 2
    ;;
esac
