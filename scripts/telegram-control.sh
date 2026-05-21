#!/usr/bin/env bash
# scripts/telegram-control.sh — Manage the Hermes Telegram gateway.
#
# Supports TELEGRAM_TARGET=vm (default) and TELEGRAM_TARGET=docker.
# VM paths work with VM_ENGINE=multipass and VM_ENGINE=vmware/fusion.

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

# shellcheck source=vm-common.sh
source "${SCRIPT_DIR}/vm-common.sh"

ACTION="${1:-status}"
TARGET="${TELEGRAM_TARGET:-vm}"
VM_NAME="${VM_NAME:-omlx-agent-ubuntu}"
VM_SSH_USER="${VM_SSH_USER:-agent}"
DOCKER_NAME="${DOCKER_NAME:-omlx-agent-docker}"
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

usage() {
  cat <<EOF
Usage: TELEGRAM_TARGET=<vm|docker> $0 <start|stop|restart|status|logs|pairing|doctor>
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
  make telegram-stop-host
EOF
  fi
}

stop_host_gateway() {
  local pids
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
       TELEGRAM_TARGET=${TARGET} make telegram-pairing
  3. Approve the code:
       TELEGRAM_TARGET=${TARGET} make telegram-approve CODE=<pairing-code>

For fully automatic access, set TELEGRAM_USER_ID or TELEGRAM_ALLOWED_USERS to your numeric Telegram user ID.
EOF
  fi
}

# ── VM target — shared across Multipass and VMware ────────────────────────────

sync_vm_env() {
  require_vm_ready
  vm_exec_root_env \
    AGENT_USER="${VM_SSH_USER}" \
    TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN}" \
    TELEGRAM_USER_ID="${TELEGRAM_USER_ID}" \
    TELEGRAM_ALLOWED_USERS="${TELEGRAM_ALLOWED_USERS}" \
    TELEGRAM_GROUP_ALLOWED_USERS="${TELEGRAM_GROUP_ALLOWED_USERS}" \
    TELEGRAM_GROUP_ALLOWED_CHATS="${TELEGRAM_GROUP_ALLOWED_CHATS}" \
    GATEWAY_ALLOWED_USERS="${GATEWAY_ALLOWED_USERS}" \
    GATEWAY_ALLOW_ALL_USERS="${GATEWAY_ALLOW_ALL_USERS}" \
    -- "python3 -" <<'PY'
import os
import pwd
import grp
from pathlib import Path

agent_user = os.environ["AGENT_USER"]
env_path = Path(f"/home/{agent_user}/.hermes/.env")
env_path.parent.mkdir(parents=True, exist_ok=True)

keys = [
    "TELEGRAM_BOT_TOKEN",
    "TELEGRAM_USER_ID",
    "TELEGRAM_ALLOWED_USERS",
    "TELEGRAM_GROUP_ALLOWED_USERS",
    "TELEGRAM_GROUP_ALLOWED_CHATS",
    "GATEWAY_ALLOWED_USERS",
    "GATEWAY_ALLOW_ALL_USERS",
]

lines = []
if env_path.exists():
    for line in env_path.read_text().splitlines():
        if not any(line.startswith(f"{key}=") for key in keys):
            lines.append(line)

for key in keys:
    value = os.environ.get(key, "")
    if value:
        lines.append(f"{key}={value}")

env_path.write_text("\n".join(lines).rstrip() + "\n")
uid = pwd.getpwnam(agent_user).pw_uid
gid = grp.getgrnam(agent_user).gr_gid
os.chown(env_path, uid, gid)
PY
}

ensure_vm_telegram_dependency() {
  vm_exec 'cd "$HOME"
    python_bin="$HOME/.hermes/hermes-agent/venv/bin/python"
    if [[ ! -x "$python_bin" ]]; then
      echo "Hermes Python venv missing; run make agents-install first." >&2
      exit 1
    fi
    if ! "$python_bin" -c "import telegram" >/dev/null 2>&1; then
      echo "Installing python-telegram-bot in Hermes venv..."
      if command -v uv >/dev/null 2>&1; then
        uv pip install --python "$python_bin" "python-telegram-bot>=21,<23"
      else
        "$python_bin" -m ensurepip --upgrade >/dev/null 2>&1 || true
        "$python_bin" -m pip install --upgrade "python-telegram-bot>=21,<23"
      fi
    fi'
}

start_vm() {
  require_token
  warn_host_gateway_conflict
  sync_vm_env
  ensure_vm_telegram_dependency
  vm_exec 'export PATH="$HOME/.local/bin:$PATH"
    source "$HOME/.hermes/.env"
    mkdir -p "$HOME/.hermes/logs"
    pid_file="$HOME/.hermes/gateway.pid"
    find_gateway_pid() {
      ps -u "$(id -u)" -o pid=,args= \
        | awk -v me="$$" -v p1="/venv/bin/hermes" -v p2="gateway run" \
          "$1 != me && index($0,p1) && index($0,p2) { print $1; exit }"
    }
    gateway_pid="$(find_gateway_pid)"
    if [[ -n "$gateway_pid" ]]; then
      echo "$gateway_pid" > "$pid_file"
      echo "Hermes gateway already running: PID $gateway_pid"
    else
      nohup hermes gateway run --accept-hooks > "$HOME/.hermes/logs/gateway.log" 2>&1 </dev/null &
      echo "$!" > "$pid_file"
      echo "Started Hermes gateway: PID $(cat "$pid_file")"
    fi
    sleep 2
    gateway_pid="$(find_gateway_pid)"
    if [[ -n "$gateway_pid" ]]; then
      echo "$gateway_pid" > "$pid_file"
      echo "gateway=running pid=$gateway_pid"
    else
      echo "gateway=stopped"
    fi
    tail -40 "$HOME/.hermes/logs/gateway.log" 2>/dev/null || true'
}

stop_vm() {
  sync_vm_env
  vm_exec 'pid_file="$HOME/.hermes/gateway.pid"
    gateway_pids="$(ps -u "$(id -u)" -o pid=,args= \
      | awk -v me="$$" -v p1="/venv/bin/hermes" -v p2="gateway run" \
        "$1 != me && index($0,p1) && index($0,p2) { print $1 }")"
    if [[ -n "$gateway_pids" ]]; then
      printf "%s\n" $gateway_pids | xargs kill 2>/dev/null || true
      rm -f "$pid_file"
      echo "Hermes gateway stopped."
    else
      rm -f "$pid_file"
      echo "Hermes gateway was not running."
    fi'
}

status_vm() {
  sync_vm_env
  vm_exec 'export PATH="$HOME/.local/bin:$PATH"
    source "$HOME/.hermes/.env" 2>/dev/null || true
    echo "token=$([ -n "${TELEGRAM_BOT_TOKEN:-}" ] && echo configured || echo missing)"
    pid_file="$HOME/.hermes/gateway.pid"
    gateway_pid="$(ps -u "$(id -u)" -o pid=,args= \
      | awk -v me="$$" -v p1="/venv/bin/hermes" -v p2="gateway run" \
        "$1 != me && index($0,p1) && index($0,p2) { print $1; exit }")"
    if [[ -n "$gateway_pid" ]]; then
      echo "$gateway_pid" > "$pid_file"
      echo "gateway=running pid=$gateway_pid"
    else
      echo "gateway=stopped"
    fi
    hermes pairing list 2>/dev/null || true'
}

logs_vm() {
  vm_exec 'tail -120 "$HOME/.hermes/logs/gateway.log" 2>/dev/null || echo "No gateway log yet."'
}

pairing_vm() {
  sync_vm_env
  vm_exec 'export PATH="$HOME/.local/bin:$PATH"; source "$HOME/.hermes/.env" 2>/dev/null || true; hermes pairing list'
}

approve_vm() {
  [[ -n "${CODE:-}" ]] || die "Set CODE=<pairing-code>."
  sync_vm_env
  vm_exec "export PATH=\"\$HOME/.local/bin:\$PATH\"; source \"\$HOME/.hermes/.env\" 2>/dev/null || true; hermes pairing approve $(printf '%q' "${CODE}")"
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

ensure_docker_telegram_dependency() {
  docker_exec 'if ! /opt/hermes/.venv/bin/python -c "import telegram" >/dev/null 2>&1; then
    echo "Installing python-telegram-bot in Hermes venv..."
    uv pip install --python /opt/hermes/.venv/bin/python "python-telegram-bot>=21,<23"
  fi'
}

start_docker() {
  require_token
  warn_host_gateway_conflict
  docker_ensure
  ensure_docker_telegram_dependency
  docker_exec 'source /opt/data/.env
    mkdir -p /opt/data/logs
    pid_file="/opt/data/gateway.pid"
    find_gateway_pid() {
      ps -eo pid=,args= \
        | awk -v me="$$" -v p1=".venv/bin/hermes" -v p2="gateway run" \
          "$1 != me && index($0,p1) && index($0,p2) { print $1; exit }"
    }
    gateway_pid="$(find_gateway_pid)"
    if [[ -n "$gateway_pid" ]]; then
      echo "$gateway_pid" > "$pid_file"
      echo "Hermes gateway already running: PID $gateway_pid"
    else
      nohup hermes gateway run --accept-hooks > /opt/data/logs/gateway.log 2>&1 </dev/null &
      echo "$!" > "$pid_file"
      echo "Started Hermes gateway: PID $(cat "$pid_file")"
    fi
    sleep 2
    gateway_pid="$(find_gateway_pid)"
    if [[ -n "$gateway_pid" ]]; then
      echo "$gateway_pid" > "$pid_file"
      echo "gateway=running pid=$gateway_pid"
    else
      echo "gateway=stopped"
    fi
    tail -40 /opt/data/logs/gateway.log 2>/dev/null || true'
}

stop_docker() {
  docker_ensure
  docker_exec 'pid_file="/opt/data/gateway.pid"
    gateway_pids="$(ps -eo pid=,args= \
      | awk -v me="$$" -v p1=".venv/bin/hermes" -v p2="gateway run" \
        "$1 != me && index($0,p1) && index($0,p2) { print $1 }")"
    if [[ -n "$gateway_pids" ]]; then
      printf "%s\n" $gateway_pids | xargs kill 2>/dev/null || true
      rm -f "$pid_file"
      echo "Hermes gateway stopped."
    else
      rm -f "$pid_file"
      echo "Hermes gateway was not running."
    fi'
}

status_docker() {
  docker_ensure
  docker_exec 'source /opt/data/.env 2>/dev/null || true
    echo "token=$([ -n "${TELEGRAM_BOT_TOKEN:-}" ] && echo configured || echo missing)"
    pid_file="/opt/data/gateway.pid"
    gateway_pid="$(ps -eo pid=,args= \
      | awk -v me="$$" -v p1=".venv/bin/hermes" -v p2="gateway run" \
        "$1 != me && index($0,p1) && index($0,p2) { print $1; exit }")"
    if [[ -n "$gateway_pid" ]]; then
      echo "$gateway_pid" > "$pid_file"
      echo "gateway=running pid=$gateway_pid"
    else
      echo "gateway=stopped"
    fi
    hermes pairing list 2>/dev/null || true'
}

logs_docker() {
  docker_ensure
  docker_exec 'tail -120 /opt/data/logs/gateway.log 2>/dev/null || echo "No gateway log yet."'
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
  echo "==> Host gateway"
  pids="$(host_gateway_pids || true)"
  if [[ -n "${pids}" ]]; then
    echo "host=running pids=${pids//$'\n'/, }"
  else
    echo "host=stopped"
  fi

  echo
  echo "==> VM gateway (${VM_ENGINE:-multipass})"
  if require_vm_ready 2>/dev/null; then
    status_vm
  else
    echo "vm=missing"
  fi

  echo
  echo "==> Docker gateway"
  if command -v docker >/dev/null 2>&1 && docker container inspect "${DOCKER_NAME}" >/dev/null 2>&1; then
    status_docker
  else
    echo "docker=missing"
  fi

  echo
  warn_host_gateway_conflict
}

# ── Dispatch ──────────────────────────────────────────────────────────────────

case "${ACTION}" in
  start|restart)
    [[ "${ACTION}" == "restart" ]] && "${BASH_SOURCE[0]}" stop
    case "${TARGET}" in
      vm)     start_vm ;;
      docker) start_docker ;;
      *) die "unsupported TELEGRAM_TARGET=${TARGET}; use vm or docker" ;;
    esac
    print_access_hint
    ;;
  stop)
    case "${TARGET}" in
      vm)     stop_vm ;;
      docker) stop_docker ;;
      *) die "unsupported TELEGRAM_TARGET=${TARGET}; use vm or docker" ;;
    esac
    ;;
  status)
    case "${TARGET}" in
      vm)     status_vm ;;
      docker) status_docker ;;
      *) die "unsupported TELEGRAM_TARGET=${TARGET}; use vm or docker" ;;
    esac
    print_access_hint
    ;;
  stop-host)
    stop_host_gateway
    ;;
  doctor)
    doctor_all
    ;;
  logs)
    case "${TARGET}" in
      vm)     logs_vm ;;
      docker) logs_docker ;;
      *) die "unsupported TELEGRAM_TARGET=${TARGET}; use vm or docker" ;;
    esac
    ;;
  pairing)
    case "${TARGET}" in
      vm)     pairing_vm ;;
      docker) pairing_docker ;;
      *) die "unsupported TELEGRAM_TARGET=${TARGET}; use vm or docker" ;;
    esac
    ;;
  approve)
    case "${TARGET}" in
      vm)     approve_vm ;;
      docker) approve_docker ;;
      *) die "unsupported TELEGRAM_TARGET=${TARGET}; use vm or docker" ;;
    esac
    ;;
  *)
    usage
    exit 2
    ;;
esac
