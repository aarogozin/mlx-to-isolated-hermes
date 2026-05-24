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

VM_NAME="${VM_NAME:-omlx-agent-ubuntu}"
HERMES_VM_NAME="${HERMES_VM_NAME:-${VM_NAME}}"
OPENCLAW_VM_NAME="${OPENCLAW_VM_NAME:-omlx-openclaw-ubuntu}"
DOCKER_NAME="${DOCKER_NAME:-omlx-agent-docker}"
DOCKER_DATA_VOLUME="${DOCKER_DATA_VOLUME:-${DOCKER_NAME}-data}"
DOCKER_WORKSPACE_VOLUME="${DOCKER_WORKSPACE_VOLUME:-${DOCKER_NAME}-workspace}"
OPENCLAW_DOCKER_NAME="${OPENCLAW_DOCKER_NAME:-omlx-agent-openclaw-docker}"
OPENCLAW_DOCKER_CONFIG_VOLUME="${OPENCLAW_DOCKER_CONFIG_VOLUME:-${OPENCLAW_DOCKER_NAME}-config}"
OPENCLAW_DOCKER_WORKSPACE_VOLUME="${OPENCLAW_DOCKER_WORKSPACE_VOLUME:-${OPENCLAW_DOCKER_NAME}-workspace}"
OPENCLAW_DOCKER_AUTH_VOLUME="${OPENCLAW_DOCKER_AUTH_VOLUME:-${OPENCLAW_DOCKER_NAME}-auth}"
FORCE="${FORCE:-0}"
CLEAN_STEP_TIMEOUT_SECONDS="${CLEAN_STEP_TIMEOUT_SECONDS:-30}"

log() {
  printf '\n==> %s\n' "$*"
}

confirm_destroy() {
  if [[ "${FORCE}" == "1" || "${FORCE}" == "true" ]]; then
    return 0
  fi

  if [[ ! -t 0 ]]; then
    cat >&2 <<EOF
ERROR: clean-all is destructive and needs confirmation.
Run FORCE=1 make clean-all for non-interactive cleanup.
EOF
    exit 1
  fi

  cat <<EOF
This will delete the local sandbox runtime:
  - Hermes Multipass VM: ${HERMES_VM_NAME}
  - OpenClaw Multipass VM: ${OPENCLAW_VM_NAME}
  - Docker container: ${DOCKER_NAME}
  - Docker volumes: ${DOCKER_DATA_VOLUME}, ${DOCKER_WORKSPACE_VOLUME}
  - OpenClaw Docker container: ${OPENCLAW_DOCKER_NAME}
  - OpenClaw Docker volumes: ${OPENCLAW_DOCKER_CONFIG_VOLUME}, ${OPENCLAW_DOCKER_WORKSPACE_VOLUME}, ${OPENCLAW_DOCKER_AUTH_VOLUME}

It will keep:
  - .env and secrets
  - LM Studio downloaded models
  - Homebrew, Docker Desktop, Multipass

Type clean-all to continue:
EOF
  read -r answer
  if [[ "${answer}" != "clean-all" ]]; then
    echo "Aborted."
    exit 1
  fi
}

run_with_timeout() {
  local seconds="$1"
  shift
  local pid
  local elapsed=0

  "$@" &
  pid="$!"

  while kill -0 "${pid}" >/dev/null 2>&1; do
    if [[ "${elapsed}" -ge "${seconds}" ]]; then
      kill_descendants "${pid}" TERM
      kill "${pid}" >/dev/null 2>&1 || true
      sleep 1
      kill_descendants "${pid}" KILL
      kill -9 "${pid}" >/dev/null 2>&1 || true
      wait "${pid}" >/dev/null 2>&1 || true
      return 124
    fi
    sleep 1
    elapsed=$((elapsed + 1))
  done

  wait "${pid}"
}

kill_descendants() {
  local parent="$1"
  local signal="$2"
  local child

  while read -r child; do
    [[ -n "${child}" ]] || continue
    kill_descendants "${child}" "${signal}"
    kill "-${signal}" "${child}" >/dev/null 2>&1 || true
  done < <(pgrep -P "${parent}" 2>/dev/null || true)
}

stop_omlx() {
  "${SCRIPT_DIR}/model-stop-omlx-bg.sh" >/dev/null 2>&1 || true
  pids="$(pgrep -f '[o]mlx.*serve' 2>/dev/null || true)"
  if [[ -n "${pids}" ]]; then
    printf '%s\n' ${pids} | xargs kill >/dev/null 2>&1 || true
    sleep 1
  fi
  pids="$(pgrep -f '[o]mlx.*serve' 2>/dev/null || true)"
  if [[ -n "${pids}" ]]; then
    printf '%s\n' ${pids} | xargs kill -9 >/dev/null 2>&1 || true
  fi
}

stop_telegram() {
  run_with_timeout "${CLEAN_STEP_TIMEOUT_SECONDS}" "${SCRIPT_DIR}/telegram-control.sh" stop-host >/dev/null 2>&1 || true
  run_with_timeout "${CLEAN_STEP_TIMEOUT_SECONDS}" env VM_NAME="${HERMES_VM_NAME}" TELEGRAM_TARGET=vm "${SCRIPT_DIR}/telegram-control.sh" stop >/dev/null 2>&1 || true
  run_with_timeout "${CLEAN_STEP_TIMEOUT_SECONDS}" env TELEGRAM_TARGET=docker "${SCRIPT_DIR}/telegram-control.sh" stop >/dev/null 2>&1 || true
  run_with_timeout "${CLEAN_STEP_TIMEOUT_SECONDS}" env VM_NAME="${OPENCLAW_VM_NAME}" "${SCRIPT_DIR}/openclaw-control.sh" stop multipass >/dev/null 2>&1 || true
  run_with_timeout "${CLEAN_STEP_TIMEOUT_SECONDS}" "${SCRIPT_DIR}/openclaw-control.sh" stop docker >/dev/null 2>&1 || true
}

stop_dashboards() {
  run_with_timeout "${CLEAN_STEP_TIMEOUT_SECONDS}" env VM_NAME="${HERMES_VM_NAME}" DASHBOARD_TARGET=vm "${SCRIPT_DIR}/dashboard-control.sh" stop >/dev/null 2>&1 || true
  run_with_timeout "${CLEAN_STEP_TIMEOUT_SECONDS}" env DASHBOARD_TARGET=docker "${SCRIPT_DIR}/dashboard-control.sh" stop >/dev/null 2>&1 || true
}

destroy_docker() {
  "${SCRIPT_DIR}/docker-control.sh" destroy || true
  "${SCRIPT_DIR}/openclaw-control.sh" destroy docker || true
}

destroy_vm() {
  VM_NAME="${HERMES_VM_NAME}" "${SCRIPT_DIR}/vm-control.sh" destroy || true
  VM_NAME="${OPENCLAW_VM_NAME}" "${SCRIPT_DIR}/vm-control.sh" destroy || true
}

print_final_status() {
  log "Final status"

  if pgrep -af '[o]mlx.*serve' >/dev/null 2>&1; then
    echo "omlx=running"
  else
    echo "omlx=stopped"
  fi

  if command -v multipass >/dev/null 2>&1 && multipass info "${HERMES_VM_NAME}" >/dev/null 2>&1; then
    echo "hermes_vm=present name=${HERMES_VM_NAME}"
  else
    echo "hermes_vm=missing name=${HERMES_VM_NAME}"
  fi
  if command -v multipass >/dev/null 2>&1 && multipass info "${OPENCLAW_VM_NAME}" >/dev/null 2>&1; then
    echo "openclaw_vm=present name=${OPENCLAW_VM_NAME}"
  else
    echo "openclaw_vm=missing name=${OPENCLAW_VM_NAME}"
  fi

  if command -v docker >/dev/null 2>&1 && docker container inspect "${DOCKER_NAME}" >/dev/null 2>&1; then
    echo "docker=present container=${DOCKER_NAME}"
  else
    echo "docker=missing container=${DOCKER_NAME}"
  fi

  if command -v docker >/dev/null 2>&1 && docker container inspect "${OPENCLAW_DOCKER_NAME}" >/dev/null 2>&1; then
    echo "openclaw_docker=present container=${OPENCLAW_DOCKER_NAME}"
  else
    echo "openclaw_docker=missing container=${OPENCLAW_DOCKER_NAME}"
  fi

  if command -v docker >/dev/null 2>&1; then
    if docker volume inspect "${DOCKER_DATA_VOLUME}" >/dev/null 2>&1; then
      echo "docker_data_volume=present name=${DOCKER_DATA_VOLUME}"
    else
      echo "docker_data_volume=missing name=${DOCKER_DATA_VOLUME}"
    fi
    if docker volume inspect "${DOCKER_WORKSPACE_VOLUME}" >/dev/null 2>&1; then
      echo "docker_workspace_volume=present name=${DOCKER_WORKSPACE_VOLUME}"
    else
      echo "docker_workspace_volume=missing name=${DOCKER_WORKSPACE_VOLUME}"
    fi
    if docker volume inspect "${OPENCLAW_DOCKER_CONFIG_VOLUME}" >/dev/null 2>&1; then
      echo "openclaw_config_volume=present name=${OPENCLAW_DOCKER_CONFIG_VOLUME}"
    else
      echo "openclaw_config_volume=missing name=${OPENCLAW_DOCKER_CONFIG_VOLUME}"
    fi
    if docker volume inspect "${OPENCLAW_DOCKER_WORKSPACE_VOLUME}" >/dev/null 2>&1; then
      echo "openclaw_workspace_volume=present name=${OPENCLAW_DOCKER_WORKSPACE_VOLUME}"
    else
      echo "openclaw_workspace_volume=missing name=${OPENCLAW_DOCKER_WORKSPACE_VOLUME}"
    fi
    if docker volume inspect "${OPENCLAW_DOCKER_AUTH_VOLUME}" >/dev/null 2>&1; then
      echo "openclaw_auth_volume=present name=${OPENCLAW_DOCKER_AUTH_VOLUME}"
    else
      echo "openclaw_auth_volume=missing name=${OPENCLAW_DOCKER_AUTH_VOLUME}"
    fi
  fi

  VM_NAME="${HERMES_VM_NAME}" "${SCRIPT_DIR}/telegram-control.sh" doctor || true
}

main() {
  confirm_destroy

  log "Stopping host model server"
  stop_omlx

  log "Stopping Telegram gateways"
  stop_telegram

  log "Stopping dashboards"
  stop_dashboards

  log "Destroying Docker sandbox"
  destroy_docker

  log "Destroying Multipass VM"
  destroy_vm

  print_final_status

  cat <<EOF

Clean sandbox reset complete.
Preserved .env, host dependencies, and LM Studio model files.
EOF
}

main "$@"
