#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENV_FILE="${PROJECT_ROOT}/.env"

OVERRIDE_AGENT_RUNTIME="${AGENT_RUNTIME:-}"
OVERRIDE_SANDBOX_BACKEND="${SANDBOX_BACKEND:-}"
OVERRIDE_OPENCLAW_IMAGE="${OPENCLAW_IMAGE:-}"
OVERRIDE_OPENCLAW_CONTROL_PORT="${OPENCLAW_CONTROL_PORT:-}"

if [[ -f "${ENV_FILE}" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "${ENV_FILE}"
  set +a
fi

ACTION="${1:-status}"
AGENT_RUNTIME="${OVERRIDE_AGENT_RUNTIME:-${AGENT_RUNTIME:-hermes}}"
SANDBOX_BACKEND="${OVERRIDE_SANDBOX_BACKEND:-${SANDBOX_BACKEND:-multipass}}"
TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
TELEGRAM_SWITCH_GRACE_SECONDS="${TELEGRAM_SWITCH_GRACE_SECONDS:-3}"
SHARED_MOUNTS_REQUIRED="${SHARED_MOUNTS_REQUIRED:-0}"
OPENCLAW_IMAGE="${OVERRIDE_OPENCLAW_IMAGE:-${OPENCLAW_IMAGE:-ghcr.io/openclaw/openclaw:latest}}"
OPENCLAW_CONTROL_PORT="${OVERRIDE_OPENCLAW_CONTROL_PORT:-${OPENCLAW_CONTROL_PORT:-18789}}"

usage() {
  cat <<EOF
Usage: $0 <start|stop|restart|status|logs|shell|open-dashboard>
EOF
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

backend_target() {
  case "${SANDBOX_BACKEND}" in
    docker) echo "docker" ;;
    multipass|vm) echo "vm" ;;
    *) die "unsupported SANDBOX_BACKEND=${SANDBOX_BACKEND}. Use docker or multipass." ;;
  esac
}

openclaw_stub() {
  cat <<EOF
OpenClaw adapter is planned but not implemented end-to-end yet.

Checked upstream:
  OpenClaw release: v2026.5.19
  Docker docs:      https://docs.openclaw.ai/install/docker
  Telegram docs:    https://docs.openclaw.ai/channels/telegram

Planned integration:
  - container image: ${OPENCLAW_IMAGE}
  - Control UI:      http://127.0.0.1:${OPENCLAW_CONTROL_PORT}
  - local models:    host oMLX as an OpenAI-compatible provider
  - Telegram:        TELEGRAM_BOT_TOKEN / TELEGRAM_USER_ID from .env

Use AGENT_RUNTIME=hermes for the supported runtime today.
EOF
}

if [[ "${AGENT_RUNTIME}" == "openclaw" ]]; then
  openclaw_stub
  exit 0
fi

[[ "${AGENT_RUNTIME}" == "hermes" ]] || die "unsupported AGENT_RUNTIME=${AGENT_RUNTIME}. Use hermes or openclaw."

target="$(backend_target)"

sync_shared_mounts() {
  case "${target}" in
    docker|vm)
      if ! "${SCRIPT_DIR}/shared-mounts.sh" sync "${target}"; then
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

  local status_output
  "${SCRIPT_DIR}/telegram-control.sh" stop-host 2>/dev/null || true

  case "${target}" in
    docker)
      status_output="$(TELEGRAM_TARGET=vm "${SCRIPT_DIR}/telegram-control.sh" status 2>/dev/null || true)"
      if grep -q '^gateway=running' <<<"${status_output}"; then
        echo "  ·  Stopping VM Telegram gateway before starting Docker..."
        TELEGRAM_TARGET=vm "${SCRIPT_DIR}/telegram-control.sh" stop 2>/dev/null || true
      fi
      ;;
    vm)
      status_output="$(TELEGRAM_TARGET=docker "${SCRIPT_DIR}/telegram-control.sh" status 2>/dev/null || true)"
      if grep -q '^gateway=running' <<<"${status_output}"; then
        echo "  ·  Stopping Docker Telegram gateway before starting VM..."
        TELEGRAM_TARGET=docker "${SCRIPT_DIR}/telegram-control.sh" stop 2>/dev/null || true
      fi
      ;;
  esac

  if [[ "${TELEGRAM_SWITCH_GRACE_SECONDS}" != "0" ]]; then
    echo "  ·  Waiting ${TELEGRAM_SWITCH_GRACE_SECONDS}s for Telegram polling handoff..."
    sleep "${TELEGRAM_SWITCH_GRACE_SECONDS}"
  fi
}

start_agent() {
  if [[ -n "${TELEGRAM_BOT_TOKEN}" ]]; then
    switch_to_target_gateway_slot
    "${SCRIPT_DIR}/telegram-control.sh" doctor
  fi
  "${SCRIPT_DIR}/model-start-omlx-bg.sh"
  case "${target}" in
    docker)
      sync_shared_mounts
      "${SCRIPT_DIR}/docker-create.sh"
      if [[ -n "${TELEGRAM_BOT_TOKEN}" ]]; then
        TELEGRAM_TARGET=docker "${SCRIPT_DIR}/telegram-control.sh" start
      else
        "${SCRIPT_DIR}/docker-control.sh" start
      fi
      ;;
    vm)
      "${SCRIPT_DIR}/vm-control.sh" start
      sync_shared_mounts
      "${SCRIPT_DIR}/agents-install.sh"
      "${SCRIPT_DIR}/hermes-sync-models.sh"
      DASHBOARD_TARGET=vm "${SCRIPT_DIR}/dashboard-control.sh" start
      if [[ -n "${TELEGRAM_BOT_TOKEN}" ]]; then
        TELEGRAM_TARGET=vm "${SCRIPT_DIR}/telegram-control.sh" start
      else
        echo "Telegram not configured; skipping VM gateway."
      fi
      ;;
  esac
}

stop_agent() {
  case "${target}" in
    docker)
      "${SCRIPT_DIR}/docker-control.sh" stop
      ;;
    vm)
      if [[ -n "${TELEGRAM_BOT_TOKEN}" ]]; then
        TELEGRAM_TARGET=vm "${SCRIPT_DIR}/telegram-control.sh" stop || true
      fi
      DASHBOARD_TARGET=vm "${SCRIPT_DIR}/dashboard-control.sh" stop || true
      ;;
  esac
}

status_agent() {
  echo "runtime=${AGENT_RUNTIME}"
  echo "backend=${SANDBOX_BACKEND}"
  case "${target}" in
    docker)
      "${SCRIPT_DIR}/docker-control.sh" status
      DASHBOARD_TARGET=docker "${SCRIPT_DIR}/dashboard-control.sh" status
      TELEGRAM_TARGET=docker "${SCRIPT_DIR}/telegram-control.sh" status
      ;;
    vm)
      "${SCRIPT_DIR}/vm-control.sh" status
      DASHBOARD_TARGET=vm "${SCRIPT_DIR}/dashboard-control.sh" status || true
      TELEGRAM_TARGET=vm "${SCRIPT_DIR}/telegram-control.sh" status || true
      ;;
  esac
}

logs_agent() {
  case "${target}" in
    docker)
      "${SCRIPT_DIR}/docker-control.sh" status >/dev/null 2>&1 || true
      docker logs --tail 200 "${DOCKER_NAME:-omlx-agent-docker}" 2>&1 || true
      ;;
    vm)
      DASHBOARD_TARGET=vm "${SCRIPT_DIR}/dashboard-control.sh" logs || true
      if [[ -n "${TELEGRAM_BOT_TOKEN}" ]]; then
        TELEGRAM_TARGET=vm "${SCRIPT_DIR}/telegram-control.sh" logs || true
      fi
      ;;
  esac
}

shell_agent() {
  case "${target}" in
    docker) "${SCRIPT_DIR}/docker-control.sh" shell ;;
    vm) "${SCRIPT_DIR}/vm-control.sh" ssh ;;
  esac
}

open_dashboard() {
  case "${target}" in
    docker) DASHBOARD_TARGET=docker "${SCRIPT_DIR}/dashboard-control.sh" open ;;
    vm) DASHBOARD_TARGET=vm "${SCRIPT_DIR}/dashboard-control.sh" open ;;
  esac
}

case "${ACTION}" in
  start) start_agent ;;
  stop) stop_agent ;;
  restart) stop_agent; start_agent ;;
  status) status_agent ;;
  logs) logs_agent ;;
  shell) shell_agent ;;
  open-dashboard) open_dashboard ;;
  *)
    usage
    exit 2
    ;;
esac
