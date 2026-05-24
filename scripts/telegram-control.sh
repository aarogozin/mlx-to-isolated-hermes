#!/usr/bin/env bash
# scripts/telegram-control.sh — Manage the Hermes Telegram gateway.
#
# Supports TELEGRAM_TARGET=vm (default) and TELEGRAM_TARGET=docker.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENV_FILE="${PROJECT_ROOT}/.env"

OVERRIDE_TELEGRAM_TARGET="${TELEGRAM_TARGET:-}"
OVERRIDE_VM_NAME="${VM_NAME:-}"

if [[ -f "${ENV_FILE}" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "${ENV_FILE}"
  set +a
fi

# shellcheck source=vm-common.sh
source "${SCRIPT_DIR}/vm-common.sh"

ACTION="${1:-status}"
TARGET="${OVERRIDE_TELEGRAM_TARGET:-${TELEGRAM_TARGET:-vm}}"
VM_NAME="${OVERRIDE_VM_NAME:-${HERMES_VM_NAME:-${VM_NAME:-omlx-agent-ubuntu}}}"
VM_SSH_USER="${VM_SSH_USER:-agent}"
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
  ./scripts/telegram-control.sh stop-host
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
  ./scripts/telegram-control.sh stop-host
EOF
    exit 1
  fi
}

resolve_host_gateway_conflict() {
  local pids
  pids="$(host_gateway_pids || true)"
  [[ -n "${pids}" ]] || return 0

  if [[ "${TELEGRAM_AUTO_STOP_CONFLICTS}" == "1" ]]; then
    echo "Stopping host Hermes gateway before starting ${TARGET} Telegram gateway..."
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
       TELEGRAM_TARGET=${TARGET} ./scripts/telegram-control.sh pairing
  3. Approve the code:
       TELEGRAM_TARGET=${TARGET} CODE=<pairing-code> ./scripts/telegram-control.sh approve

For fully automatic access, set TELEGRAM_USER_ID or TELEGRAM_ALLOWED_USERS to your numeric Telegram user ID.
EOF
  fi
}

# ── VM target ─────────────────────────────────────────────────────────────────

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
      echo "Hermes Python venv missing; run ./scripts/agents-install.sh first." >&2
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
  sync_vm_env
  ensure_vm_telegram_dependency
  vm_exec 'export PATH="$HOME/.local/bin:$PATH"
    source "$HOME/.hermes/.env"
    mkdir -p "$HOME/.hermes/logs"
    pid_file="$HOME/.hermes/gateway.pid"
    find_gateway_pids() {
      python3 - <<'"'"'PY'"'"'
import os

uid = os.getuid()
for name in os.listdir("/proc"):
    if not name.isdigit():
        continue
    proc = f"/proc/{name}"
    try:
        if os.stat(proc).st_uid != uid:
            continue
        parts = [p.decode("utf-8", "ignore") for p in open(f"{proc}/cmdline", "rb").read().split(b"\0") if p]
    except OSError:
        continue
    has_hermes = any(p == "hermes" or p.endswith("/venv/bin/hermes") for p in parts)
    if has_hermes and "gateway" in parts and "run" in parts:
        print(name)
PY
    }
    gateway_pid="$(find_gateway_pids | head -1)"
    if [[ -n "$gateway_pid" ]]; then
      echo "$gateway_pid" > "$pid_file"
      echo "Hermes gateway already running: PID $gateway_pid"
    else
      nohup hermes gateway run --accept-hooks > "$HOME/.hermes/logs/gateway.log" 2>&1 </dev/null &
      echo "$!" > "$pid_file"
      echo "Started Hermes gateway: PID $(cat "$pid_file")"
    fi
    sleep 2
    gateway_pid="$(find_gateway_pids | head -1)"
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
    gateway_pids="$(python3 - <<'"'"'PY'"'"'
import os

uid = os.getuid()
for name in os.listdir("/proc"):
    if not name.isdigit():
        continue
    proc = f"/proc/{name}"
    try:
        if os.stat(proc).st_uid != uid:
            continue
        parts = [p.decode("utf-8", "ignore") for p in open(f"{proc}/cmdline", "rb").read().split(b"\0") if p]
    except OSError:
        continue
    has_hermes = any(p == "hermes" or p.endswith("/venv/bin/hermes") for p in parts)
    if has_hermes and "gateway" in parts and "run" in parts:
        print(name)
PY
)"
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
    gateway_pid="$(python3 - <<'"'"'PY'"'"'
import os

uid = os.getuid()
for name in os.listdir("/proc"):
    if not name.isdigit():
        continue
    proc = f"/proc/{name}"
    try:
        if os.stat(proc).st_uid != uid:
            continue
        parts = [p.decode("utf-8", "ignore") for p in open(f"{proc}/cmdline", "rb").read().split(b"\0") if p]
    except OSError:
        continue
    has_hermes = any(p == "hermes" or p.endswith("/venv/bin/hermes") for p in parts)
    if has_hermes and "gateway" in parts and "run" in parts:
        print(name)
        break
PY
)"
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
  :
}

start_docker() {
  require_token
  docker_ensure
  ensure_docker_telegram_dependency
  docker start "${DOCKER_NAME}" >/dev/null
  echo "Docker Hermes gateway running: ${DOCKER_NAME}"
  docker logs --tail 40 "${DOCKER_NAME}" 2>&1 || true
}

stop_docker() {
  if docker container inspect "${DOCKER_NAME}" >/dev/null 2>&1; then
    docker stop "${DOCKER_NAME}" >/dev/null || true
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
  local vm_status=""
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
  echo "==> VM gateway (multipass)"
  if require_vm_ready 2>/dev/null; then
    vm_status="$(status_vm)"
    printf '%s\n' "${vm_status}"
    if grep -q '^gateway=running' <<<"${vm_status}"; then
      running_count=$((running_count + 1))
    fi
  else
    echo "vm=missing"
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
  local status_output=""
  local switched=0

  resolve_host_gateway_conflict

  case "${TARGET}" in
    vm)
      if command -v docker >/dev/null 2>&1 && docker container inspect "${DOCKER_NAME}" >/dev/null 2>&1; then
        status_output="$(status_docker 2>/dev/null || true)"
        if grep -q '^gateway=running' <<<"${status_output}"; then
          echo "Stopping Docker Telegram gateway before starting VM..."
          stop_docker || true
          switched=1
        fi
      fi
      ;;
    docker)
      if require_vm_ready 2>/dev/null; then
        status_output="$(status_vm 2>/dev/null || true)"
        if grep -q '^gateway=running' <<<"${status_output}"; then
          echo "Stopping VM Telegram gateway before starting Docker..."
          stop_vm || true
          switched=1
        fi
      fi
      ;;
  esac

  if [[ "${switched}" == "1" && "${TELEGRAM_SWITCH_GRACE_SECONDS}" != "0" ]]; then
    echo "Waiting ${TELEGRAM_SWITCH_GRACE_SECONDS}s for Telegram polling handoff..."
    sleep "${TELEGRAM_SWITCH_GRACE_SECONDS}"
  fi
}

# ── Dispatch ──────────────────────────────────────────────────────────────────

case "${ACTION}" in
  start|restart)
    [[ "${ACTION}" == "restart" ]] && "${BASH_SOURCE[0]}" stop
    prepare_start_target
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
