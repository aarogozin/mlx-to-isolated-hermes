#!/usr/bin/env bash
# scripts/dashboard-control.sh — Start/stop/status the Hermes Dashboard.
#
# Supports DASHBOARD_TARGET=vm (default) and DASHBOARD_TARGET=docker.
# VM paths work with VM_ENGINE=multipass and VM_ENGINE=vmware/fusion.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENV_FILE="${PROJECT_ROOT}/.env"
RUNTIME_DIR="${PROJECT_ROOT}/.runtime"

if [[ -f "${ENV_FILE}" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "${ENV_FILE}"
  set +a
fi

# shellcheck source=vm-common.sh
source "${SCRIPT_DIR}/vm-common.sh"

ACTION="${1:-status}"
TARGET="${DASHBOARD_TARGET:-vm}"
VM_NAME="${VM_NAME:-omlx-agent-ubuntu}"
VM_SSH_USER="${VM_SSH_USER:-agent}"
VM_SSH_KEY="${VM_SSH_KEY:-${HOME}/.ssh/omlx_agent_vm_ed25519}"
DOCKER_NAME="${DOCKER_NAME:-omlx-agent-docker}"
HERMES_DASHBOARD_PORT="${HERMES_DASHBOARD_PORT:-9119}"
HERMES_DASHBOARD_TUI="${HERMES_DASHBOARD_TUI:-1}"
LOCAL_DASHBOARD_HOST="${LOCAL_DASHBOARD_HOST:-127.0.0.1}"
TUNNEL_PID_FILE="${RUNTIME_DIR}/dashboard-${VM_NAME}-${HERMES_DASHBOARD_PORT}.pid"
TUNNEL_LOG_FILE="${RUNTIME_DIR}/dashboard-${VM_NAME}-${HERMES_DASHBOARD_PORT}.log"
TUNNEL_CONTROL_SOCKET="${RUNTIME_DIR}/dashboard-${VM_NAME}-${HERMES_DASHBOARD_PORT}.sock"
KNOWN_HOSTS_FILE="${RUNTIME_DIR}/known_hosts"

usage() {
  cat <<EOF
Usage: DASHBOARD_TARGET=<vm|docker> $0 <start|stop|restart|status|logs|open>
EOF
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

dashboard_url() {
  printf 'http://%s:%s\n' "${LOCAL_DASHBOARD_HOST}" "${HERMES_DASHBOARD_PORT}"
}

dashboard_flags() {
  local flags=(--host "$1" --port "$2" --no-open)
  if [[ "${HERMES_DASHBOARD_TUI}" == "1" || "${HERMES_DASHBOARD_TUI}" == "true" ]]; then
    flags+=(--tui)
  fi
  printf '%q ' "${flags[@]}"
}

port_listening() {
  lsof -nP -iTCP:"${HERMES_DASHBOARD_PORT}" -sTCP:LISTEN >/dev/null 2>&1
}

# ── SSH tunnel helpers (engine-agnostic: uses get_vm_ip from vm-common.sh) ───

_ssh_opts_array() {
  printf '%s\0' \
    -i "${VM_SSH_KEY}" \
    -o BatchMode=yes \
    -o ExitOnForwardFailure=yes \
    -o StrictHostKeyChecking=accept-new \
    -o UserKnownHostsFile="${KNOWN_HOSTS_FILE}"
}

tunnel_check() {
  local ip="$1"
  [[ -S "${TUNNEL_CONTROL_SOCKET}" ]] || return 1
  ssh -S "${TUNNEL_CONTROL_SOCKET}" -O check \
    -i "${VM_SSH_KEY}" \
    -o BatchMode=yes \
    -o StrictHostKeyChecking=accept-new \
    -o UserKnownHostsFile="${KNOWN_HOSTS_FILE}" \
    "${VM_SSH_USER}@${ip}" >/dev/null 2>&1
}

# ── VM target ─────────────────────────────────────────────────────────────────

ensure_vm_dashboard_dependencies() {
  vm_exec_root 'set -euo pipefail
    apt-get update >/dev/null
    DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates curl gnupg >/dev/null
    node_major="$(node -p "Number(process.versions.node.split(\".\")[0])" 2>/dev/null || echo 0)"
    if [[ "${node_major}" -lt 20 ]]; then
      curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
      DEBIAN_FRONTEND=noninteractive apt-get install -y nodejs
    fi
    npm install -g pnpm@10 >/dev/null 2>&1 || true'

  vm_exec 'set -euo pipefail
    web_dir="$HOME/.hermes/hermes-agent/web"
    [[ -d "$web_dir" ]] || exit 0
    node_version="$(node -v)"
    stamp="$HOME/.hermes/.dashboard-webdeps-${node_version}"
    if [[ ! -f "$stamp" ]]; then
      cd "$web_dir"
      npm install
      touch "$stamp"
    fi'
}

start_vm_dashboard() {
  require_vm_ready

  case "${VM_ENGINE:-multipass}" in
    multipass) multipass start "${VM_NAME}" >/dev/null 2>&1 || true ;;
  esac

  ensure_vm_dashboard_dependencies

  local flags
  flags="$(dashboard_flags 127.0.0.1 "${HERMES_DASHBOARD_PORT}")"

  vm_exec "export PATH=\"\$HOME/.local/bin:\$PATH\"
    source \"\$HOME/.hermes/.env\" 2>/dev/null || true
    mkdir -p \"\$HOME/.hermes/logs\"
    dashboard_pid=\"\$(ps -u \"\$(id -u)\" -o pid=,args= \
      | awk -v p1=\"/venv/bin/hermes\" -v p2=\" dashboard\" \
        'index(\$0,p1) && index(\$0,p2) && !index(\$0,\"--status\") && !index(\$0,\"--stop\") { print \$1; exit }')\"
    if [[ -n \"\$dashboard_pid\" ]]; then
      echo \"\$dashboard_pid\" > \"\$HOME/.hermes/dashboard.pid\"
      echo \"Hermes dashboard already running in VM: PID \$dashboard_pid\"
    else
      nohup hermes dashboard ${flags}> \"\$HOME/.hermes/logs/dashboard.log\" 2>&1 </dev/null &
      echo \"\$!\" > \"\$HOME/.hermes/dashboard.pid\"
      echo \"Started Hermes dashboard in VM: PID \$(cat \"\$HOME/.hermes/dashboard.pid\")\"
    fi"
}

start_vm_tunnel() {
  mkdir -p "${RUNTIME_DIR}"
  [[ -f "${VM_SSH_KEY}" ]] || die "VM SSH key missing: ${VM_SSH_KEY}. Run make vm-create first."

  local ip
  ip="$(get_vm_ip)"
  [[ -n "${ip}" ]] || die "could not detect VM IP for ${VM_NAME}"

  if tunnel_check "${ip}"; then
    echo "Dashboard SSH tunnel already running."
    return
  fi

  if port_listening; then
    echo "Local dashboard port ${HERMES_DASHBOARD_PORT} is already listening; leaving existing listener in place."
    return
  fi

  rm -f "${TUNNEL_CONTROL_SOCKET}" "${TUNNEL_PID_FILE}"
  ssh \
    -f \
    -N \
    -M \
    -S "${TUNNEL_CONTROL_SOCKET}" \
    -L "${LOCAL_DASHBOARD_HOST}:${HERMES_DASHBOARD_PORT}:127.0.0.1:${HERMES_DASHBOARD_PORT}" \
    -i "${VM_SSH_KEY}" \
    -o BatchMode=yes \
    -o ExitOnForwardFailure=yes \
    -o StrictHostKeyChecking=accept-new \
    -o UserKnownHostsFile="${KNOWN_HOSTS_FILE}" \
    "${VM_SSH_USER}@${ip}" >"${TUNNEL_LOG_FILE}" 2>&1
  sleep 1

  if ! tunnel_check "${ip}"; then
    cat "${TUNNEL_LOG_FILE}" >&2 || true
    rm -f "${TUNNEL_PID_FILE}" "${TUNNEL_CONTROL_SOCKET}"
    die "failed to start dashboard SSH tunnel"
  fi

  pgrep -f "ssh .*${TUNNEL_CONTROL_SOCKET}" | head -1 > "${TUNNEL_PID_FILE}" 2>/dev/null || true
  if [[ -s "${TUNNEL_PID_FILE}" ]]; then
    echo "Dashboard SSH tunnel: PID $(cat "${TUNNEL_PID_FILE}")"
  else
    echo "Dashboard SSH tunnel: running"
  fi
}

start_vm() {
  start_vm_dashboard
  start_vm_tunnel
  echo "Hermes dashboard: $(dashboard_url)"
}

stop_vm_tunnel() {
  local ip
  ip="$(get_vm_ip)"
  if tunnel_check "${ip}"; then
    ssh -S "${TUNNEL_CONTROL_SOCKET}" -O exit \
      -i "${VM_SSH_KEY}" \
      -o BatchMode=yes \
      -o StrictHostKeyChecking=accept-new \
      -o UserKnownHostsFile="${KNOWN_HOSTS_FILE}" \
      "${VM_SSH_USER}@${ip}" >/dev/null 2>&1 || true
    echo "Dashboard SSH tunnel stopped."
  elif [[ -f "${TUNNEL_PID_FILE}" ]] && kill -0 "$(cat "${TUNNEL_PID_FILE}")" >/dev/null 2>&1; then
    kill "$(cat "${TUNNEL_PID_FILE}")" >/dev/null 2>&1 || true
    echo "Stale dashboard SSH tunnel PID stopped."
  fi
  rm -f "${TUNNEL_PID_FILE}" "${TUNNEL_CONTROL_SOCKET}"
}

stop_vm() {
  require_vm_ready
  vm_exec 'dashboard_pids="$(ps -u "$(id -u)" -o pid=,args= \
    | awk -v p1="/venv/bin/hermes" -v p2=" dashboard" \
      '"'"'index($0,p1) && index($0,p2) && !index($0,"--status") && !index($0,"--stop") { print $1 }'"'"')"
    if [[ -n "$dashboard_pids" ]]; then
      printf "%s\n" $dashboard_pids | xargs kill 2>/dev/null || true
      echo "Hermes dashboard stopped in VM."
    else
      echo "Hermes dashboard was not running in VM."
    fi
    rm -f "$HOME/.hermes/dashboard.pid"'
  stop_vm_tunnel
}

status_vm() {
  require_vm_ready
  vm_exec 'dashboard_pid="$(ps -u "$(id -u)" -o pid=,args= \
    | awk -v p1="/venv/bin/hermes" -v p2=" dashboard" \
      '"'"'index($0,p1) && index($0,p2) && !index($0,"--status") && !index($0,"--stop") { print $1; exit }'"'"')"
    if [[ -n "$dashboard_pid" ]]; then
      echo "dashboard=running pid=$dashboard_pid"
    else
      echo "dashboard=stopped"
    fi'

  local ip
  ip="$(get_vm_ip)"
  if tunnel_check "${ip}"; then
    if [[ -s "${TUNNEL_PID_FILE}" ]]; then
      echo "tunnel=running pid=$(cat "${TUNNEL_PID_FILE}")"
    else
      echo "tunnel=running"
    fi
  else
    echo "tunnel=stopped"
  fi
  if curl -fsS --max-time 2 "$(dashboard_url)" >/dev/null 2>&1; then
    echo "web=ready url=$(dashboard_url)"
  else
    echo "web=not-ready url=$(dashboard_url)"
  fi
}

logs_vm() {
  require_vm_ready
  vm_exec 'tail -160 "$HOME/.hermes/logs/dashboard.log" 2>/dev/null || echo "No dashboard log yet."'
  if [[ -f "${TUNNEL_LOG_FILE}" ]]; then
    echo
    echo "==> SSH tunnel log"
    tail -80 "${TUNNEL_LOG_FILE}" || true
  fi
}

# ── Docker target ─────────────────────────────────────────────────────────────

docker_ensure() {
  command -v docker >/dev/null 2>&1 || die "docker CLI missing."
  "${SCRIPT_DIR}/docker-create.sh" >/dev/null
  docker start "${DOCKER_NAME}" >/dev/null
}

docker_exec() {
  docker exec "${DOCKER_NAME}" /bin/bash -lc "$1"
}

start_docker() {
  docker_ensure
  local flags
  flags="$(dashboard_flags 0.0.0.0 9119)"
  docker_exec "source /opt/data/.env 2>/dev/null || true
    mkdir -p /opt/data/logs
    dashboard_pid=\"\$(ps -eo pid=,args= \
      | awk -v p1=\"/venv/bin/hermes\" -v p2=\" dashboard\" \
        'index(\$0,p1) && index(\$0,p2) && !index(\$0,\"--status\") && !index(\$0,\"--stop\") { print \$1; exit }')\"
    if [[ -n \"\$dashboard_pid\" ]]; then
      echo \"\$dashboard_pid\" > /opt/data/dashboard.pid
      echo \"Hermes dashboard already running in Docker: PID \$dashboard_pid\"
    else
      nohup hermes dashboard ${flags}--insecure > /opt/data/logs/dashboard.log 2>&1 </dev/null &
      echo \"\$!\" > /opt/data/dashboard.pid
      echo \"Started Hermes dashboard in Docker: PID \$(cat /opt/data/dashboard.pid)\"
    fi"
  echo "Hermes dashboard: $(dashboard_url)"
}

stop_docker() {
  docker_ensure
  docker_exec 'dashboard_pids="$(ps -eo pid=,args= \
    | awk -v p1="/venv/bin/hermes" -v p2=" dashboard" \
      '"'"'index($0,p1) && index($0,p2) && !index($0,"--status") && !index($0,"--stop") { print $1 }'"'"')"
    if [[ -n "$dashboard_pids" ]]; then
      printf "%s\n" $dashboard_pids | xargs kill 2>/dev/null || true
      echo "Hermes dashboard stopped in Docker."
    else
      echo "Hermes dashboard was not running in Docker."
    fi
    rm -f /opt/data/dashboard.pid'
}

status_docker() {
  docker_ensure
  docker_exec 'dashboard_pid="$(ps -eo pid=,args= \
    | awk -v p1="/venv/bin/hermes" -v p2=" dashboard" \
      '"'"'index($0,p1) && index($0,p2) && !index($0,"--status") && !index($0,"--stop") { print $1; exit }'"'"')"
    if [[ -n "$dashboard_pid" ]]; then
      echo "dashboard=running pid=$dashboard_pid"
    else
      echo "dashboard=stopped"
    fi'
  if curl -fsS --max-time 2 "$(dashboard_url)" >/dev/null 2>&1; then
    echo "web=ready url=$(dashboard_url)"
  else
    echo "web=not-ready url=$(dashboard_url)"
  fi
}

logs_docker() {
  docker_ensure
  docker_exec 'tail -160 /opt/data/logs/dashboard.log 2>/dev/null || echo "No dashboard log yet."'
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
    case "${TARGET}" in
      vm)     start_vm ;;
      docker) start_docker ;;
      *) die "unsupported DASHBOARD_TARGET=${TARGET}; use vm or docker" ;;
    esac
    ;;
  stop)
    case "${TARGET}" in
      vm)     stop_vm ;;
      docker) stop_docker ;;
      *) die "unsupported DASHBOARD_TARGET=${TARGET}; use vm or docker" ;;
    esac
    ;;
  status)
    case "${TARGET}" in
      vm)     status_vm ;;
      docker) status_docker ;;
      *) die "unsupported DASHBOARD_TARGET=${TARGET}; use vm or docker" ;;
    esac
    ;;
  logs)
    case "${TARGET}" in
      vm)     logs_vm ;;
      docker) logs_docker ;;
      *) die "unsupported DASHBOARD_TARGET=${TARGET}; use vm or docker" ;;
    esac
    ;;
  open)
    open_dashboard
    ;;
  *)
    usage
    exit 2
    ;;
esac
