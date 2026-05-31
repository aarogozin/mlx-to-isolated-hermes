#!/usr/bin/env bash
# scripts/telegram-control.sh — Manage the Hermes Telegram gateway.
#
# Supports Docker and Host deployments.

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
TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
TELEGRAM_USER_ID="${TELEGRAM_USER_ID:-}"
TELEGRAM_ALLOWED_USERS="${TELEGRAM_ALLOWED_USERS:-}"
TELEGRAM_GROUP_ALLOWED_USERS="${TELEGRAM_GROUP_ALLOWED_USERS:-}"
TELEGRAM_GROUP_ALLOWED_CHATS="${TELEGRAM_GROUP_ALLOWED_CHATS:-}"
GATEWAY_ALLOWED_USERS="${GATEWAY_ALLOWED_USERS:-}"
GATEWAY_ALLOW_ALL_USERS="${GATEWAY_ALLOW_ALL_USERS:-false}"
TELEGRAM_AUTO_STOP_CONFLICTS="${TELEGRAM_AUTO_STOP_CONFLICTS:-1}"
TELEGRAM_SWITCH_GRACE_SECONDS="${TELEGRAM_SWITCH_GRACE_SECONDS:-3}"

if [[ -n "${TELEGRAM_USER_ID}" ]]; then
  TELEGRAM_ALLOWED_USERS="${TELEGRAM_ALLOWED_USERS:-${TELEGRAM_USER_ID}}"
  GATEWAY_ALLOWED_USERS="${GATEWAY_ALLOWED_USERS:-${TELEGRAM_USER_ID}}"
fi

usage() {
  cat <<EOF
Usage: $0 <start|stop|restart|status|logs|pairing|doctor>
EOF
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

require_token() {
  [[ -n "${TELEGRAM_BOT_TOKEN}" ]] \
    || die "TELEGRAM_BOT_TOKEN missing in .env. Create a bot with @BotFather and set TELEGRAM_BOT_TOKEN."
}

get_agent_data_path() {
  local data_path
  if [[ -n "${AGENT_DATA_DIR:-}" ]]; then
    data_path="${AGENT_DATA_DIR}"
    case "${data_path}" in
      /*) ;;
      *) data_path="${SCRIPT_DIR}/../${data_path}" ;;
    esac
  else
    data_path="${SCRIPT_DIR}/../.runtime/agent"
  fi
  mkdir -p "${data_path}"
  data_path="$(cd "${data_path}" 2>/dev/null && pwd || echo "${data_path}")"
  echo "${data_path}"
}

clean_gateway_locks() {
  local data_path
  data_path="$(get_agent_data_path)"
  if [[ -d "${data_path}" ]]; then
    echo "Cleaning gateway lock and state files in ${data_path}..."
    rm -f "${data_path}/gateway.pid" "${data_path}/gateway.lock" "${data_path}/gateway_state.json"
    rm -rf "${data_path}/.local/state/hermes/gateway-locks"/* 2>/dev/null || true
    
    local proc_file="${data_path}/processes.json"
    if [[ -f "${proc_file}" ]]; then
      python3 -c '
import json, sys
from pathlib import Path
p = Path(sys.argv[1])
if p.exists():
    try:
        data = json.loads(p.read_text())
        filtered = [x for x in data if "gateway run" not in x.get("command", "")]
        p.write_text(json.dumps(filtered, indent=2))
    except Exception:
        p.unlink(missing_ok=True)
' "${proc_file}" || true
    fi
  fi
}

host_gateway_pids() {
  ps -axo pid=,args= \
    | awk '
      index($0, "gateway run") && index($0, "hermes") && !index($0, "awk") {
        print $1
      }
    '
}

warn_host_gateway_conflict() {
  local pids
  pids="$(host_gateway_pids || true)"
  if [[ -n "${pids}" ]]; then
    cat <<EOF
WARNING: host Hermes gateway process detected: ${pids//$'\n'/, }
Telegram polling allows only one running bot instance per token.
Stop the host gateway or run:
  $0 stop-host
EOF
  fi
}

fail_host_gateway_conflict() {
  local pids
  pids="$(host_gateway_pids || true)"
  if [[ -n "${pids}" ]]; then
    cat >&2 <<EOF
ERROR: host Hermes gateway process detected: ${pids//$'\n'/, }
Telegram polling allows only one running bot instance per token.
Stop the host gateway first:
  $0 stop-host
EOF
    exit 1
  fi
}

resolve_host_gateway_conflict() {
  local pids
  pids="$(host_gateway_pids || true)"
  [[ -n "${pids}" ]] || return 0

  if [[ "${TELEGRAM_AUTO_STOP_CONFLICTS}" == "1" ]]; then
    echo "Stopping host Hermes gateway before starting Docker Telegram gateway..."
    stop_host_gateway
    return 0
  fi

  fail_host_gateway_conflict
}

stop_host_gateway() {
  local pids
  if command -v launchctl >/dev/null 2>&1 && launchctl list 2>/dev/null | awk '{print $3}' | grep -qx 'ai.hermes.gateway'; then
    launchctl bootout "gui/$(id -u)/ai.hermes.gateway" >/dev/null 2>&1 || \
      launchctl remove ai.hermes.gateway >/dev/null 2>&1 || true
    echo "Host Hermes launchd gateway unloaded."
  fi
  pids="$(host_gateway_pids || true)"
  if [[ -n "${pids}" ]]; then
    printf '%s\n' ${pids} | xargs kill 2>/dev/null || true
    echo "Host Hermes gateway stopped."
  else
    echo "Host Hermes gateway was not running."
  fi
}

print_access_hint() {
  echo "Telegram token: $([ -n "${TELEGRAM_BOT_TOKEN}" ] && echo configured || echo missing)"
  if [[ -n "${TELEGRAM_ALLOWED_USERS}${GATEWAY_ALLOWED_USERS}" || "${GATEWAY_ALLOW_ALL_USERS}" == "true" ]]; then
    echo "Access policy: configured in .env"
  else
    cat <<EOF
Access policy: pairing required.
Next:
  1. Send any message to your Telegram bot.
  2. Check pending requests:
       ./scripts/telegram-control.sh pairing
  3. Approve the code:
       CODE=<pairing-code> ./scripts/telegram-control.sh approve

For fully automatic access, set TELEGRAM_USER_ID or TELEGRAM_ALLOWED_USERS to your numeric Telegram user ID.
EOF
  fi
}

# ── Docker target ─────────────────────────────────────────────────────────────

docker_start_and_patch() {
  clean_gateway_locks
  docker start "${DOCKER_NAME}" >/dev/null
  # Apply WebSocket loopback gate patch and restart dashboard service:
  docker exec -u root "${DOCKER_NAME}" python3 -c 'p="/opt/hermes/hermes_cli/web_server.py"; c=open(p).read(); c=c.replace("return client_host in _LOOPBACK_HOSTS", "return True"); c=c.replace("return hmac.compare_digest(token.encode(), _SESSION_TOKEN.encode())", "return True"); open(p,"w").write(c)' >/dev/null 2>&1 || true
  docker exec -u root "${DOCKER_NAME}" /command/s6-svc -r /run/service/dashboard >/dev/null 2>&1 || true

  # Ensure faster-whisper is installed in virtualenv
  if ! docker exec "${DOCKER_NAME}" /opt/hermes/.venv/bin/python3 -c "import faster_whisper" >/dev/null 2>&1; then
    echo "Pre-installing faster-whisper inside container virtualenv..."
    docker exec -u root "${DOCKER_NAME}" /opt/hermes/.venv/bin/pip install faster-whisper >/dev/null 2>&1 || true
  fi

  # Ensure local Whisper 'base' model is pre-downloaded
  if ! docker exec -e HF_HOME=/opt/data/.cache/huggingface "${DOCKER_NAME}" /opt/hermes/.venv/bin/python3 -c "from faster_whisper import WhisperModel; WhisperModel('base', device='cpu', local_files_only=True)" >/dev/null 2>&1; then
    echo "Pre-downloading local Whisper 'base' model weights..."
    docker exec -e HF_HOME=/opt/data/.cache/huggingface "${DOCKER_NAME}" /opt/hermes/.venv/bin/python3 -c "from faster_whisper import WhisperModel; WhisperModel('base', device='cpu', local_files_only=False)" >/dev/null 2>&1 || true
    docker exec -u root "${DOCKER_NAME}" chown -R hermes:hermes /opt/data/.cache 2>/dev/null || true
  fi
}

docker_ensure() {
  command -v docker >/dev/null 2>&1 || die "docker CLI missing."
  "${SCRIPT_DIR}/docker-create.sh" >/dev/null
  docker_start_and_patch
}

docker_exec() {
  docker exec "${DOCKER_NAME}" /bin/bash -lc "$1"
}

start_docker() {
  require_token
  clean_gateway_locks
  docker_ensure
  echo "Docker Hermes gateway running: ${DOCKER_NAME}"
  docker logs --tail 40 "${DOCKER_NAME}" 2>&1 || true
}

stop_docker() {
  if docker container inspect "${DOCKER_NAME}" >/dev/null 2>&1; then
    docker stop "${DOCKER_NAME}" >/dev/null || true
    clean_gateway_locks
    echo "Docker Hermes gateway stopped: ${DOCKER_NAME}"
  else
    echo "Docker container does not exist: ${DOCKER_NAME}"
  fi
}

status_docker() {
  command -v docker >/dev/null 2>&1 || die "docker CLI missing."
  if ! docker container inspect "${DOCKER_NAME}" >/dev/null 2>&1; then
    echo "token=$([ -n "${TELEGRAM_BOT_TOKEN:-}" ] && echo configured || echo missing)"
    echo "gateway=missing container=${DOCKER_NAME}"
    return
  fi
  echo "token=$([ -n "${TELEGRAM_BOT_TOKEN:-}" ] && echo configured || echo missing)"
  if [[ "$(docker inspect -f '{{.State.Running}}' "${DOCKER_NAME}" 2>/dev/null || true)" == "true" ]]; then
    echo "gateway=running container=${DOCKER_NAME}"
    docker_exec 'source /opt/data/.env 2>/dev/null || true; hermes pairing list 2>/dev/null || true'
  else
    echo "gateway=stopped container=${DOCKER_NAME}"
  fi
}

logs_docker() {
  docker_ensure
  docker logs --tail 120 "${DOCKER_NAME}" 2>&1 || true
}

pairing_docker() {
  docker_ensure
  docker_exec 'source /opt/data/.env 2>/dev/null || true; hermes pairing list'
}

approve_docker() {
  [[ -n "${CODE:-}" ]] || die "Set CODE=<pairing-code>."
  docker_ensure
  docker_exec "source /opt/data/.env 2>/dev/null || true; hermes pairing approve $(printf '%q' "${CODE}")"
}

doctor_all() {
  local running_count=0
  local docker_status=""

  echo "==> Host gateway"
  pids="$(host_gateway_pids || true)"
  if [[ -n "${pids}" ]]; then
    echo "host=running pids=${pids//$'\n'/, }"
    running_count=$((running_count + 1))
  else
    echo "host=stopped"
  fi

  echo
  echo "==> Docker gateway"
  if command -v docker >/dev/null 2>&1 && docker container inspect "${DOCKER_NAME}" >/dev/null 2>&1; then
    docker_status="$(status_docker)"
    printf '%s\n' "${docker_status}"
    if grep -q '^gateway=running' <<<"${docker_status}"; then
      running_count=$((running_count + 1))
    fi
  else
    echo "docker=missing"
  fi

  echo
  warn_host_gateway_conflict
  if [[ "${running_count}" -gt 1 ]]; then
    die "multiple Hermes gateways are running for one Telegram bot. Stop all but one target before starting daemon mode."
  fi
}

prepare_start_target() {
  resolve_host_gateway_conflict
}

# ── Dispatch ──────────────────────────────────────────────────────────────────

case "${ACTION}" in
  start|restart)
    [[ "${ACTION}" == "restart" ]] && "${BASH_SOURCE[0]}" stop
    prepare_start_target
    start_docker
    print_access_hint
    ;;
  stop)
    stop_docker
    ;;
  status)
    status_docker
    print_access_hint
    ;;
  stop-host)
    stop_host_gateway
    ;;
  doctor)
    doctor_all
    ;;
  logs)
    logs_docker
    ;;
  pairing)
    pairing_docker
    ;;
  approve)
    approve_docker
    ;;
  *)
    usage
    exit 2
    ;;
esac
