#!/usr/bin/env bash
# scripts/agent-control.sh — Manage Hermes and OpenClaw Docker sandboxes.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENV_FILE="${PROJECT_ROOT}/.env"

OVERRIDE_AGENT_RUNTIME="${AGENT_RUNTIME:-}"
OVERRIDE_SANDBOX_BACKEND="${SANDBOX_BACKEND:-}"
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
SANDBOX_BACKEND="${OVERRIDE_SANDBOX_BACKEND:-${SANDBOX_BACKEND:-docker}}"

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
DOCKER_NAME="${DOCKER_NAME:-omlx-agent-docker}"
OPENCLAW_DOCKER_NAME="${OPENCLAW_DOCKER_NAME:-omlx-agent-openclaw-docker}"

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
    *) die "unsupported SANDBOX_BACKEND=${SANDBOX_BACKEND}. Only docker is supported." ;;
  esac
}

[[ "${AGENT_RUNTIME}" == "hermes" || "${AGENT_RUNTIME}" == "openclaw" ]] \
  || die "unsupported AGENT_RUNTIME=${AGENT_RUNTIME}. Use hermes or openclaw."

target="$(runtime_target)"
requested_mode="${AGENT_RUNTIME}/${target}"

docker_running() {
  local name="$1"
  command -v docker >/dev/null 2>&1 \
    && docker container inspect "${name}" >/dev/null 2>&1 \
    && [[ "$(docker inspect -f '{{.State.Running}}' "${name}" 2>/dev/null || true)" == "true" ]]
}

active_records() {
  if docker_running "${DOCKER_NAME}"; then
    echo "hermes/docker|hermes|docker|${DOCKER_NAME}"
  fi
  if docker_running "${OPENCLAW_DOCKER_NAME}"; then
    echo "openclaw/docker|openclaw|docker|${OPENCLAW_DOCKER_NAME}"
  fi
}

active_modes() {
  active_records | cut -d'|' -f1
}

pause_mode() {
  local mode="$1"
  local runtime="${mode%%/*}"
  local backend="${mode#*/}"

  echo "Pausing active agent: ${mode}"
  case "${runtime}:${backend}" in
    hermes:docker)
      AGENT_RUNTIME=hermes SANDBOX_BACKEND=docker "${SCRIPT_DIR}/docker-control.sh" stop || true
      ;;
    openclaw:docker)
      AGENT_RUNTIME=openclaw SANDBOX_BACKEND=docker "${SCRIPT_DIR}/openclaw-control.sh" stop docker || true
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
  - ${requested_mode} (sandbox)

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
  AGENT_RUNTIME=<active-runtime> SANDBOX_BACKEND=docker make agent-stop

Or switch by pausing the active stack:
  AGENT_RUNTIME=${AGENT_RUNTIME} SANDBOX_BACKEND=docker make agent-switch

For a full sandbox reset:
  FORCE=1 make clean-all
EOF
    exit 1
  }
}

sync_shared_mounts() {
  if ! AGENT_RUNTIME="${AGENT_RUNTIME}" OBSIDIAN_SHARED_PATH="${OBSIDIAN_SHARED_PATH}" "${SCRIPT_DIR}/shared-mounts.sh" sync "${target}"; then
    if [[ "${SHARED_MOUNTS_REQUIRED}" == "1" ]]; then
      die "shared mount sync failed"
    fi
    echo "WARNING: shared mount sync failed; continuing because SHARED_MOUNTS_REQUIRED=0."
  fi
}

start_hermes() {
  if [[ -n "${TELEGRAM_BOT_TOKEN}" ]]; then
    "${SCRIPT_DIR}/telegram-control.sh" stop-host 2>/dev/null || true
    "${SCRIPT_DIR}/telegram-control.sh" doctor
  fi
  "${SCRIPT_DIR}/model-start-omlx-bg.sh"
  sync_shared_mounts
  OBSIDIAN_SHARED_PATH="${OBSIDIAN_SHARED_PATH}" "${SCRIPT_DIR}/docker-create.sh"
  if [[ -n "${TELEGRAM_BOT_TOKEN}" ]]; then
    TELEGRAM_TARGET=docker "${SCRIPT_DIR}/telegram-control.sh" start
  else
    "${SCRIPT_DIR}/docker-control.sh" start
  fi
}

start_openclaw() {
  if [[ -n "${TELEGRAM_BOT_TOKEN}" ]]; then
    "${SCRIPT_DIR}/telegram-control.sh" stop-host 2>/dev/null || true
  fi
  "${SCRIPT_DIR}/model-start-omlx-bg.sh"
  sync_shared_mounts
  OBSIDIAN_SHARED_PATH="${OBSIDIAN_SHARED_PATH}" "${SCRIPT_DIR}/openclaw-control.sh" start docker
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
  case "${AGENT_RUNTIME}" in
    hermes)
      "${SCRIPT_DIR}/docker-control.sh" stop
      ;;
    openclaw)
      "${SCRIPT_DIR}/openclaw-control.sh" stop docker
      ;;
  esac
}

pause_agent() {
  stop_agent
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
}

active_agent() {
  active_records
}

pause_mode_action() {
  local mode="${2:-}"
  [[ -n "${mode}" ]] || die "pause-mode requires an agent mode such as hermes/docker"
  pause_mode "${mode}"
}

logs_agent() {
  case "${AGENT_RUNTIME}" in
    hermes) docker logs --tail 200 "${DOCKER_NAME}" 2>&1 || true ;;
    openclaw) "${SCRIPT_DIR}/openclaw-control.sh" logs docker ;;
  esac
}

shell_agent() {
  case "${AGENT_RUNTIME}" in
    hermes) "${SCRIPT_DIR}/docker-control.sh" shell ;;
    openclaw) "${SCRIPT_DIR}/openclaw-control.sh" shell docker ;;
  esac
}

open_dashboard() {
  case "${AGENT_RUNTIME}" in
    hermes) DASHBOARD_TARGET=docker "${SCRIPT_DIR}/dashboard-control.sh" open ;;
    openclaw) "${SCRIPT_DIR}/openclaw-control.sh" open-dashboard docker ;;
  esac
}

update_agent() {
  case "${AGENT_RUNTIME}" in
    hermes)
      "${SCRIPT_DIR}/docker-control.sh" update
      ;;
    openclaw)
      local oc_name
      oc_name="${OPENCLAW_DOCKER_NAME:-omlx-agent-openclaw-docker}"
      local oc_image
      oc_image="$(docker inspect -f '{{.Config.Image}}' "${oc_name}" 2>/dev/null || true)"
      if [[ -n "${oc_image}" ]]; then
        echo "Pulling latest image: ${oc_image}..."
        docker pull "${oc_image}" || true
      fi
      "${SCRIPT_DIR}/openclaw-control.sh" stop docker || true
      OPENCLAW_PULL_POLICY=always "${SCRIPT_DIR}/openclaw-control.sh" start docker
      echo "OpenClaw updated and restarted"
      ;;
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
  update) update_agent ;;
  *)
    usage
    exit 2
    ;;
esac
