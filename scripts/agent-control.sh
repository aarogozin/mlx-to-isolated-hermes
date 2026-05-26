#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENV_FILE="${PROJECT_ROOT}/.env"

OVERRIDE_AGENT_RUNTIME="${AGENT_RUNTIME:-}"
OVERRIDE_SANDBOX_BACKEND="${SANDBOX_BACKEND:-}"
OVERRIDE_VM_NAME="${VM_NAME:-}"
OVERRIDE_OBSIDIAN_SHARED_PATH_SET="${OBSIDIAN_SHARED_PATH+x}"
OVERRIDE_OBSIDIAN_SHARED_PATH="${OBSIDIAN_SHARED_PATH:-}"
OVERRIDE_TELEGRAM_BOT_TOKEN_SET="${TELEGRAM_BOT_TOKEN+x}"
OVERRIDE_TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"

if [[ -f "${ENV_FILE}" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "${ENV_FILE}"
  set +a
fi

ACTION="${1:-status}"
AGENT_RUNTIME="${OVERRIDE_AGENT_RUNTIME:-${AGENT_RUNTIME:-hermes}}"
SANDBOX_BACKEND="${OVERRIDE_SANDBOX_BACKEND:-${SANDBOX_BACKEND:-multipass}}"
if [[ -n "${OVERRIDE_OBSIDIAN_SHARED_PATH_SET}" ]]; then
  OBSIDIAN_SHARED_PATH="${OVERRIDE_OBSIDIAN_SHARED_PATH}"
else
  OBSIDIAN_SHARED_PATH="${OBSIDIAN_SHARED_PATH:-}"
fi
if [[ -n "${OVERRIDE_TELEGRAM_BOT_TOKEN_SET}" ]]; then
  TELEGRAM_BOT_TOKEN="${OVERRIDE_TELEGRAM_BOT_TOKEN}"
else
  TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
fi
TELEGRAM_SWITCH_GRACE_SECONDS="${TELEGRAM_SWITCH_GRACE_SECONDS:-3}"
AGENT_CONFLICT_POLICY="${AGENT_CONFLICT_POLICY:-fail}"
AGENT_PERSIST_SELECTION="${AGENT_PERSIST_SELECTION:-0}"
SHARED_MOUNTS_REQUIRED="${SHARED_MOUNTS_REQUIRED:-0}"
HERMES_VM_NAME="${HERMES_VM_NAME:-${VM_NAME:-omlx-agent-ubuntu}}"
OPENCLAW_VM_NAME="${OPENCLAW_VM_NAME:-omlx-openclaw-ubuntu}"
VM_SSH_USER="${VM_SSH_USER:-agent}"
VM_SSH_KEY="${VM_SSH_KEY:-${HOME}/.ssh/omlx_agent_vm_ed25519}"
DOCKER_NAME="${DOCKER_NAME:-omlx-agent-docker}"
OPENCLAW_DOCKER_NAME="${OPENCLAW_DOCKER_NAME:-omlx-agent-openclaw-docker}"
OPENCLAW_CONTROL_PORT="${OPENCLAW_CONTROL_PORT:-18789}"
TIMEOUT_BIN="$(command -v timeout || command -v gtimeout || true)"

usage() {
  cat <<EOF
Usage: $0 <start|stop|restart|pause|status|active|pause-mode|logs|shell|open-dashboard>
EOF
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

runtime_target() {
  case "${SANDBOX_BACKEND}" in
    docker) echo "docker" ;;
    multipass|vm) echo "vm" ;;
    *) die "unsupported SANDBOX_BACKEND=${SANDBOX_BACKEND}. Use docker or multipass." ;;
  esac
}

[[ "${AGENT_RUNTIME}" == "hermes" || "${AGENT_RUNTIME}" == "openclaw" ]] \
  || die "unsupported AGENT_RUNTIME=${AGENT_RUNTIME}. Use hermes or openclaw."

target="$(runtime_target)"
requested_mode="${AGENT_RUNTIME}/${target}"

runtime_vm_name() {
  local runtime="$1"
  if [[ -n "${OVERRIDE_VM_NAME}" && "${runtime}" == "${AGENT_RUNTIME}" ]]; then
    printf '%s\n' "${OVERRIDE_VM_NAME}"
    return
  fi
  case "${runtime}" in
    hermes) printf '%s\n' "${HERMES_VM_NAME}" ;;
    openclaw) printf '%s\n' "${OPENCLAW_VM_NAME}" ;;
    *) printf '%s\n' "${HERMES_VM_NAME}" ;;
  esac
}

REQUESTED_VM_NAME="$(runtime_vm_name "${AGENT_RUNTIME}")"

docker_running() {
  local name="$1"
  command -v docker >/dev/null 2>&1 \
    && docker container inspect "${name}" >/dev/null 2>&1 \
    && [[ "$(docker inspect -f '{{.State.Running}}' "${name}" 2>/dev/null || true)" == "true" ]]
}

vm_exists() {
  local name="$1"
  command -v multipass >/dev/null 2>&1 && multipass info "${name}" >/dev/null 2>&1
}

vm_running_state() {
  local name="$1"
  vm_exists "${name}" && [[ "$(multipass info "${name}" | awk '/State/ { print $2; exit }')" == "Running" ]]
}

ensure_vm() {
  local name="${1:-${REQUESTED_VM_NAME}}"
  if vm_exists "${name}"; then
    VM_NAME="${name}" "${SCRIPT_DIR}/vm-control.sh" start
  else
    OBSIDIAN_SHARED_PATH="${OBSIDIAN_SHARED_PATH}" VM_NAME="${name}" "${SCRIPT_DIR}/vm-create.sh"
  fi
}

vm_process_running() {
  local name="$1"
  local pattern="$2"
  local ip
  vm_running_state "${name}" || return 1
  ip="$(multipass info "${name}" | awk '/IPv4/ { print $2; exit }')"
  [[ -n "${ip}" ]] || return 1
  if [[ -n "${TIMEOUT_BIN}" ]]; then
    "${TIMEOUT_BIN}" 5s ssh -i "${VM_SSH_KEY:-${HOME}/.ssh/omlx_agent_vm_ed25519}" \
      -o BatchMode=yes -o ConnectTimeout=3 -o StrictHostKeyChecking=accept-new \
      "${VM_SSH_USER}@${ip}" "pgrep -af $(printf '%q' "${pattern}")" >/dev/null 2>&1
  else
    ssh -i "${VM_SSH_KEY:-${HOME}/.ssh/omlx_agent_vm_ed25519}" \
      -o BatchMode=yes -o ConnectTimeout=3 -o StrictHostKeyChecking=accept-new \
      "${VM_SSH_USER}@${ip}" "pgrep -af $(printf '%q' "${pattern}")" >/dev/null 2>&1
  fi
}

active_records() {
  if docker_running "${DOCKER_NAME}"; then
    echo "hermes/docker|hermes|docker|${DOCKER_NAME}"
  fi
  if docker_running "${OPENCLAW_DOCKER_NAME}"; then
    echo "openclaw/docker|openclaw|docker|${OPENCLAW_DOCKER_NAME}"
  fi
  if vm_process_running "${HERMES_VM_NAME}" 'gateway run|hermes dashboard'; then
    echo "hermes/vm|hermes|vm|${HERMES_VM_NAME}"
  fi
  if vm_process_running "${OPENCLAW_VM_NAME}" '[o]penclaw($| )|[n]ode .*openclaw.mjs gateway|[n]ode .*dist/index.js gateway'; then
    echo "openclaw/vm|openclaw|vm|${OPENCLAW_VM_NAME}"
  fi
}

active_modes() {
  active_records | cut -d'|' -f1
}

pause_mode() {
  local mode="$1"
  local runtime="${mode%%/*}"
  local backend="${mode#*/}"
  local vm_name

  echo "Pausing active agent: ${mode}"
  case "${runtime}:${backend}" in
    hermes:docker)
      AGENT_RUNTIME=hermes SANDBOX_BACKEND=docker "${SCRIPT_DIR}/docker-control.sh" stop || true
      ;;
    openclaw:docker)
      AGENT_RUNTIME=openclaw SANDBOX_BACKEND=docker "${SCRIPT_DIR}/openclaw-control.sh" stop docker || true
      ;;
    hermes:vm)
      vm_name="$(runtime_vm_name hermes)"
      VM_NAME="${vm_name}" TELEGRAM_TARGET=vm "${SCRIPT_DIR}/telegram-control.sh" stop || true
      VM_NAME="${vm_name}" DASHBOARD_TARGET=vm "${SCRIPT_DIR}/dashboard-control.sh" stop || true
      VM_NAME="${vm_name}" "${SCRIPT_DIR}/vm-control.sh" stop || true
      ;;
    openclaw:vm)
      vm_name="$(runtime_vm_name openclaw)"
      VM_NAME="${vm_name}" "${SCRIPT_DIR}/openclaw-control.sh" stop multipass || true
      VM_NAME="${vm_name}" "${SCRIPT_DIR}/vm-control.sh" stop || true
      ;;
  esac
}

prompt_conflict_resolution() {
  local conflicts="$1"
  if [[ ! -t 0 ]]; then
    return 1
  fi
  cat >&2 <<EOF

Another agent stack is already running:
$(printf '%s\n' "${conflicts}" | sed 's/^/  - /')

Requested:
  - ${requested_mode} ($(if [[ "${target}" == "vm" ]]; then printf '%s' "${REQUESTED_VM_NAME}"; else printf 'sandbox'; fi))

Choose:
  1) Pause active stack(s) and continue
  2) Abort
  3) Full clean-all reset
EOF
  local answer
  while true; do
    printf "Select [1-3]: " >&2
    read -r answer </dev/tty
    case "${answer}" in
      1) echo pause; return 0 ;;
      2|"") echo fail; return 0 ;;
      3) echo clean; return 0 ;;
    esac
  done
}

guard_single_active_agent() {
  local modes
  modes="$(active_modes | sort -u)"
  [[ -n "${modes}" ]] || return 0

  local conflicts
  conflicts="$(printf '%s\n' "${modes}" | grep -vx "${requested_mode}" || true)"
  [[ -z "${conflicts}" ]] && return 0

  local policy="${AGENT_CONFLICT_POLICY}"
  if [[ "${policy}" == "prompt" ]]; then
    policy="$(prompt_conflict_resolution "${conflicts}" || echo fail)"
  fi

  case "${policy}" in
    pause|auto-pause)
      while IFS= read -r mode; do
        [[ -n "${mode}" ]] || continue
        pause_mode "${mode}"
      done <<<"${conflicts}"
      return 0
      ;;
    ignore|allow)
      echo "WARNING: ignoring active agent conflict by request." >&2
      printf '%s\n' "${conflicts}" | sed 's/^/  active: /' >&2
      return 0
      ;;
    clean|clean-all)
      FORCE=1 "${SCRIPT_DIR}/clean-all.sh"
      return 0
      ;;
    fail)
      ;;
    *)
      die "unsupported AGENT_CONFLICT_POLICY=${AGENT_CONFLICT_POLICY}. Use fail, prompt, pause, clean, or ignore."
      ;;
  esac

  {
    cat >&2 <<EOF
ERROR: another agent stack is already running.

Active:
$(printf '%s\n' "${conflicts}" | sed 's/^/  - /')

Requested:
  - ${requested_mode}

Stop the active stack first:
  AGENT_RUNTIME=<active-runtime> SANDBOX_BACKEND=<active-backend> make agent-stop

Or switch by pausing the active stack:
  AGENT_RUNTIME=${AGENT_RUNTIME} SANDBOX_BACKEND=${SANDBOX_BACKEND} make agent-switch

For a full sandbox reset:
  FORCE=1 make clean-all
EOF
    exit 1
  }
}

sync_shared_mounts() {
  case "${target}" in
    docker|vm)
      if ! AGENT_RUNTIME="${AGENT_RUNTIME}" OBSIDIAN_SHARED_PATH="${OBSIDIAN_SHARED_PATH}" VM_NAME="${REQUESTED_VM_NAME}" "${SCRIPT_DIR}/shared-mounts.sh" sync "${target}"; then
        if [[ "${SHARED_MOUNTS_REQUIRED}" == "1" ]]; then
          die "shared mount sync failed"
        fi
        echo "WARNING: shared mount sync failed; continuing because SHARED_MOUNTS_REQUIRED=0."
      fi
      ;;
  esac
}

switch_to_target_gateway_slot() {
  [[ -n "${TELEGRAM_BOT_TOKEN}" ]] || return 0

  "${SCRIPT_DIR}/telegram-control.sh" stop-host 2>/dev/null || true

  case "${target}" in
    docker)
      if vm_process_running "${HERMES_VM_NAME}" 'gateway run|hermes dashboard' \
        || vm_process_running "${OPENCLAW_VM_NAME}" '[o]penclaw($| )|[n]ode .*openclaw.mjs gateway|[n]ode .*dist/index.js gateway'; then
        echo "  ·  Refusing to auto-stop a VM agent; run make agent-stop for the active mode."
      fi
      ;;
    vm)
      if docker_running "${DOCKER_NAME}" || docker_running "${OPENCLAW_DOCKER_NAME}"; then
        echo "  ·  Refusing to auto-stop a Docker agent; run make agent-stop for the active mode."
      fi
      ;;
  esac

  if [[ "${TELEGRAM_SWITCH_GRACE_SECONDS}" != "0" ]]; then
    echo "  ·  Waiting ${TELEGRAM_SWITCH_GRACE_SECONDS}s for Telegram polling handoff..."
    sleep "${TELEGRAM_SWITCH_GRACE_SECONDS}"
  fi
}

start_hermes() {
  if [[ -n "${TELEGRAM_BOT_TOKEN}" ]]; then
    switch_to_target_gateway_slot
    "${SCRIPT_DIR}/telegram-control.sh" doctor
  fi
  "${SCRIPT_DIR}/model-start-omlx-bg.sh"
  case "${target}" in
    docker)
      sync_shared_mounts
      OBSIDIAN_SHARED_PATH="${OBSIDIAN_SHARED_PATH}" "${SCRIPT_DIR}/docker-create.sh"
      if [[ -n "${TELEGRAM_BOT_TOKEN}" ]]; then
        TELEGRAM_TARGET=docker "${SCRIPT_DIR}/telegram-control.sh" start
      else
        "${SCRIPT_DIR}/docker-control.sh" start
      fi
      ;;
    vm)
      ensure_vm "${REQUESTED_VM_NAME}"
      sync_shared_mounts
      VM_NAME="${REQUESTED_VM_NAME}" "${SCRIPT_DIR}/agents-install.sh"
      VM_NAME="${REQUESTED_VM_NAME}" "${SCRIPT_DIR}/hermes-sync-models.sh"
      VM_NAME="${REQUESTED_VM_NAME}" DASHBOARD_TARGET=vm "${SCRIPT_DIR}/dashboard-control.sh" start
      if [[ -n "${TELEGRAM_BOT_TOKEN}" ]]; then
        VM_NAME="${REQUESTED_VM_NAME}" TELEGRAM_TARGET=vm "${SCRIPT_DIR}/telegram-control.sh" start
      else
        echo "Telegram not configured; skipping VM gateway."
      fi
      ;;
  esac
}

start_openclaw() {
  if [[ -n "${TELEGRAM_BOT_TOKEN}" ]]; then
    switch_to_target_gateway_slot
  fi
  "${SCRIPT_DIR}/model-start-omlx-bg.sh"
  case "${target}" in
    docker)
      sync_shared_mounts
      OBSIDIAN_SHARED_PATH="${OBSIDIAN_SHARED_PATH}" "${SCRIPT_DIR}/openclaw-control.sh" start docker
      ;;
    vm)
      ensure_vm "${REQUESTED_VM_NAME}"
      sync_shared_mounts
      OBSIDIAN_SHARED_PATH="${OBSIDIAN_SHARED_PATH}" VM_NAME="${REQUESTED_VM_NAME}" "${SCRIPT_DIR}/openclaw-control.sh" start multipass
      ;;
  esac
}

start_agent() {
  guard_single_active_agent
  case "${AGENT_RUNTIME}" in
    hermes) start_hermes ;;
    openclaw) start_openclaw ;;
  esac
  if [[ "${AGENT_PERSIST_SELECTION}" == "1" || "${AGENT_PERSIST_SELECTION}" == "true" ]]; then
    "${SCRIPT_DIR}/env-set.sh" "${ENV_FILE}" AGENT_RUNTIME "${AGENT_RUNTIME}"
    "${SCRIPT_DIR}/env-set.sh" "${ENV_FILE}" SANDBOX_BACKEND "${SANDBOX_BACKEND}"
  fi
}

stop_agent() {
  case "${AGENT_RUNTIME}:${target}" in
    hermes:docker)
      "${SCRIPT_DIR}/docker-control.sh" stop
      ;;
    hermes:vm)
      VM_NAME="${REQUESTED_VM_NAME}" TELEGRAM_TARGET=vm "${SCRIPT_DIR}/telegram-control.sh" stop || true
      VM_NAME="${REQUESTED_VM_NAME}" DASHBOARD_TARGET=vm "${SCRIPT_DIR}/dashboard-control.sh" stop || true
      ;;
    openclaw:docker)
      "${SCRIPT_DIR}/openclaw-control.sh" stop docker
      ;;
    openclaw:vm)
      VM_NAME="${REQUESTED_VM_NAME}" "${SCRIPT_DIR}/openclaw-control.sh" stop multipass
      ;;
  esac
}

pause_agent() {
  stop_agent
  if [[ "${target}" == "vm" ]]; then
    VM_NAME="${REQUESTED_VM_NAME}" "${SCRIPT_DIR}/vm-control.sh" stop || true
  fi
}

status_agent() {
  echo "selected_runtime=${AGENT_RUNTIME}"
  echo "selected_backend=${SANDBOX_BACKEND}"
  echo "selected_mode=${requested_mode}"
  echo
  echo "detected_agents:"
  local modes
  modes="$(active_modes | sort -u)"
  if [[ -n "${modes}" ]]; then
    printf '%s\n' "${modes}" | sed 's/^/  - /'
  else
    echo "  - none"
  fi
  echo
  "${SCRIPT_DIR}/docker-control.sh" status || true
  OPENCLAW_DOCKER_NAME="${OPENCLAW_DOCKER_NAME}" "${SCRIPT_DIR}/openclaw-control.sh" status docker || true
  if vm_exists "${HERMES_VM_NAME}"; then
    VM_NAME="${HERMES_VM_NAME}" AGENT_RUNTIME=hermes "${SCRIPT_DIR}/vm-control.sh" status || true
  else
    echo "hermes_vm=missing name=${HERMES_VM_NAME}"
  fi
  if vm_exists "${OPENCLAW_VM_NAME}"; then
    VM_NAME="${OPENCLAW_VM_NAME}" AGENT_RUNTIME=openclaw "${SCRIPT_DIR}/vm-control.sh" status || true
  else
    echo "openclaw_vm=missing name=${OPENCLAW_VM_NAME}"
  fi
  VM_NAME="${OPENCLAW_VM_NAME}" AGENT_RUNTIME=openclaw "${SCRIPT_DIR}/openclaw-control.sh" status multipass || true
}

active_agent() {
  active_records
}

pause_mode_action() {
  local mode="${2:-}"
  [[ -n "${mode}" ]] || die "pause-mode requires an agent mode such as hermes/vm"
  pause_mode "${mode}"
}

logs_agent() {
  case "${AGENT_RUNTIME}:${target}" in
    hermes:docker) docker logs --tail 200 "${DOCKER_NAME}" 2>&1 || true ;;
    hermes:vm)
      VM_NAME="${REQUESTED_VM_NAME}" DASHBOARD_TARGET=vm "${SCRIPT_DIR}/dashboard-control.sh" logs || true
      if [[ -n "${TELEGRAM_BOT_TOKEN}" ]]; then
        VM_NAME="${REQUESTED_VM_NAME}" TELEGRAM_TARGET=vm "${SCRIPT_DIR}/telegram-control.sh" logs || true
      fi
      ;;
    openclaw:docker) "${SCRIPT_DIR}/openclaw-control.sh" logs docker ;;
    openclaw:vm) VM_NAME="${REQUESTED_VM_NAME}" "${SCRIPT_DIR}/openclaw-control.sh" logs multipass ;;
  esac
}

shell_agent() {
  case "${AGENT_RUNTIME}:${target}" in
    hermes:docker) "${SCRIPT_DIR}/docker-control.sh" shell ;;
    hermes:vm) VM_NAME="${REQUESTED_VM_NAME}" "${SCRIPT_DIR}/vm-control.sh" ssh ;;
    openclaw:docker) "${SCRIPT_DIR}/openclaw-control.sh" shell docker ;;
    openclaw:vm) VM_NAME="${REQUESTED_VM_NAME}" "${SCRIPT_DIR}/openclaw-control.sh" shell multipass ;;
  esac
}

open_dashboard() {
  case "${AGENT_RUNTIME}:${target}" in
    hermes:docker) DASHBOARD_TARGET=docker "${SCRIPT_DIR}/dashboard-control.sh" open ;;
    hermes:vm) VM_NAME="${REQUESTED_VM_NAME}" DASHBOARD_TARGET=vm "${SCRIPT_DIR}/dashboard-control.sh" open ;;
    openclaw:docker) "${SCRIPT_DIR}/openclaw-control.sh" open-dashboard docker ;;
    openclaw:vm) VM_NAME="${REQUESTED_VM_NAME}" "${SCRIPT_DIR}/openclaw-control.sh" open-dashboard multipass ;;
  esac
}

case "${ACTION}" in
  start) start_agent ;;
  stop) stop_agent ;;
  restart) stop_agent; start_agent ;;
  pause) pause_agent ;;
  status) status_agent ;;
  active) active_agent ;;
  pause-mode) pause_mode_action "$@" ;;
  logs) logs_agent ;;
  shell) shell_agent ;;
  open-dashboard) open_dashboard ;;
  *)
    usage
    exit 2
    ;;
esac
