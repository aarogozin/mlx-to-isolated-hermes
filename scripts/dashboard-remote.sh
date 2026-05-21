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
TAILSCALE_DASHBOARD_TARGET="${TAILSCALE_DASHBOARD_TARGET:-http://127.0.0.1:9119}"
CLOUDFLARE_TUNNEL_TOKEN="${CLOUDFLARE_TUNNEL_TOKEN:-}"

die() {
  echo "ERROR: $*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "$1 is missing."
}

start_local_dashboard() {
  "${SCRIPT_DIR}/dashboard-control.sh" start
}

case "${ACTION}" in
  tailscale-start)
    require_command tailscale
    start_local_dashboard
    tailscale serve --bg "${TAILSCALE_DASHBOARD_TARGET}"
    tailscale serve status
    ;;
  tailscale-stop)
    require_command tailscale
    tailscale serve reset
    ;;
  tailscale-status)
    require_command tailscale
    tailscale serve status
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
