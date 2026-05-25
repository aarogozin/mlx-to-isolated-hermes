#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENV_FILE="${PROJECT_ROOT}/.env"

OVERRIDE_OBSIDIAN_SHARED_PATH_SET="${OBSIDIAN_SHARED_PATH+x}"
OVERRIDE_OBSIDIAN_SHARED_PATH="${OBSIDIAN_SHARED_PATH:-}"
OVERRIDE_RAG_SOURCE_PATH_SET="${RAG_SOURCE_PATH+x}"
OVERRIDE_RAG_SOURCE_PATH="${RAG_SOURCE_PATH:-}"
OVERRIDE_RAG_INDEX_PATH_SET="${RAG_INDEX_PATH+x}"
OVERRIDE_RAG_INDEX_PATH="${RAG_INDEX_PATH:-}"
OVERRIDE_RAG_HOST_SET="${RAG_HOST+x}"
OVERRIDE_RAG_HOST="${RAG_HOST:-}"
OVERRIDE_RAG_BIND_HOST_SET="${RAG_BIND_HOST+x}"
OVERRIDE_RAG_BIND_HOST="${RAG_BIND_HOST:-}"
OVERRIDE_RAG_PORT_SET="${RAG_PORT+x}"
OVERRIDE_RAG_PORT="${RAG_PORT:-}"
OVERRIDE_RAG_ENABLED_SET="${RAG_ENABLED+x}"
OVERRIDE_RAG_ENABLED="${RAG_ENABLED:-}"

if [[ -f "${ENV_FILE}" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "${ENV_FILE}"
  set +a
fi

if [[ -n "${OVERRIDE_OBSIDIAN_SHARED_PATH_SET}" ]]; then
  OBSIDIAN_SHARED_PATH="${OVERRIDE_OBSIDIAN_SHARED_PATH}"
fi
if [[ -n "${OVERRIDE_RAG_SOURCE_PATH_SET}" ]]; then
  RAG_SOURCE_PATH="${OVERRIDE_RAG_SOURCE_PATH}"
fi
if [[ -n "${OVERRIDE_RAG_INDEX_PATH_SET}" ]]; then
  RAG_INDEX_PATH="${OVERRIDE_RAG_INDEX_PATH}"
fi

RAG_ENABLED="${OVERRIDE_RAG_ENABLED:-${RAG_ENABLED:-1}}"
RAG_INDEX_PATH="${RAG_INDEX_PATH:-.runtime/rag}"
RAG_HOST="${OVERRIDE_RAG_HOST:-${RAG_HOST:-127.0.0.1}}"
RAG_BIND_HOST="${OVERRIDE_RAG_BIND_HOST:-${RAG_BIND_HOST:-0.0.0.0}}"
RAG_PORT="${OVERRIDE_RAG_PORT:-${RAG_PORT:-8765}}"
RAG_VENV_PATH="${RAG_VENV_PATH:-.runtime/rag-venv}"
RAG_EMBEDDING_BACKEND="${RAG_EMBEDDING_BACKEND:-sentence-transformers}"

case "${RAG_INDEX_PATH}" in
  /*) RAG_INDEX_ABS="${RAG_INDEX_PATH}" ;;
  *) RAG_INDEX_ABS="${PROJECT_ROOT}/${RAG_INDEX_PATH}" ;;
esac

case "${RAG_VENV_PATH}" in
  /*) RAG_VENV_ABS="${RAG_VENV_PATH}" ;;
  *) RAG_VENV_ABS="${PROJECT_ROOT}/${RAG_VENV_PATH}" ;;
esac

PID_FILE="${RAG_INDEX_ABS}/rag-service.pid"
LOG_FILE="${RAG_INDEX_ABS}/rag-service.log"
PYTHON_BIN="${RAG_VENV_ABS}/bin/python"

die() {
  echo "ERROR: $*" >&2
  exit 1
}

ensure_enabled() {
  case "${RAG_ENABLED}" in
    1|true|yes|on) ;;
    *) die "RAG is disabled. Set RAG_ENABLED=1 in .env." ;;
  esac
}

install_deps() {
  mkdir -p "${RAG_INDEX_ABS}"
  if [[ ! -x "${PYTHON_BIN}" ]]; then
    python3 -m venv "${RAG_VENV_ABS}"
  fi
  "${PYTHON_BIN}" -m pip install --upgrade pip wheel
  "${PYTHON_BIN}" -m pip install --upgrade lancedb fastapi uvicorn pydantic
  if [[ "${RAG_EMBEDDING_BACKEND}" != "hash" ]]; then
    "${PYTHON_BIN}" -m pip install --upgrade sentence-transformers
  fi
}

ensure_installed() {
  if [[ ! -x "${PYTHON_BIN}" ]]; then
    install_deps
  fi
}

service_pid() {
  if [[ -f "${PID_FILE}" ]]; then
    cat "${PID_FILE}"
  fi
}

service_running() {
  local pid
  pid="$(service_pid || true)"
  [[ -n "${pid}" ]] && kill -0 "${pid}" >/dev/null 2>&1
}

port_service_pids() {
  command -v lsof >/dev/null 2>&1 || return 0
  local pid
  while IFS= read -r pid; do
    [[ -n "${pid}" ]] || continue
    if ps -p "${pid}" -o command= 2>/dev/null | grep -F "${SCRIPT_DIR}/rag.py serve" >/dev/null; then
      printf '%s\n' "${pid}"
    fi
  done < <(lsof -tiTCP:"${RAG_PORT}" -sTCP:LISTEN 2>/dev/null || true)
}

start_service() {
  ensure_enabled
  ensure_installed
  mkdir -p "${RAG_INDEX_ABS}"
  if service_running; then
    echo "RAG service already running: pid=$(service_pid), url=http://${RAG_HOST}:${RAG_PORT}"
    return 0
  fi
  RAG_BIND_HOST="${RAG_BIND_HOST}" RAG_HOST="${RAG_HOST}" RAG_PORT="${RAG_PORT}" \
    nohup "${PYTHON_BIN}" "${SCRIPT_DIR}/rag.py" serve >"${LOG_FILE}" 2>&1 &
  echo "$!" > "${PID_FILE}"
  sleep 1
  if ! service_running; then
    tail -n 80 "${LOG_FILE}" >&2 || true
    die "RAG service failed to start"
  fi
  echo "RAG service running: http://${RAG_HOST}:${RAG_PORT}"
}

stop_service() {
  local stopped=0
  if service_running; then
    kill "$(service_pid)" >/dev/null 2>&1 || true
    rm -f "${PID_FILE}"
    stopped=1
  else
    rm -f "${PID_FILE}"
  fi

  local pid
  while IFS= read -r pid; do
    [[ -n "${pid}" ]] || continue
    kill "${pid}" >/dev/null 2>&1 || true
    stopped=1
  done < <(port_service_pids)

  if [[ "${stopped}" == "1" ]]; then
    echo "RAG service stopped"
  else
    echo "RAG service not running"
  fi
}

status_service() {
  if service_running; then
    echo "rag=running pid=$(service_pid) url=http://${RAG_HOST}:${RAG_PORT}"
    curl -fsS --max-time 2 "http://${RAG_HOST}:${RAG_PORT}/health" || true
    echo
  else
    echo "rag=stopped url=http://${RAG_HOST}:${RAG_PORT}"
  fi
}

ACTION="${1:-}"
shift || true

case "${ACTION}" in
  install)
    install_deps
    "${PYTHON_BIN}" "${SCRIPT_DIR}/rag.py" doctor || true
    ;;
  index)
    ensure_enabled
    ensure_installed
    "${PYTHON_BIN}" "${SCRIPT_DIR}/rag.py" index "$@"
    ;;
  search)
    ensure_enabled
    ensure_installed
    "${PYTHON_BIN}" "${SCRIPT_DIR}/rag.py" search "$@"
    ;;
  start)
    start_service
    ;;
  stop)
    stop_service
    ;;
  restart)
    stop_service
    start_service
    ;;
  status)
    status_service
    ;;
  doctor)
    if [[ "${RAG_ENABLED}" != "1" && "${RAG_ENABLED}" != "true" ]]; then
      echo "rag=disabled"
      exit 0
    fi
    if [[ ! -x "${PYTHON_BIN}" ]]; then
      echo "rag_venv=missing path=${RAG_VENV_ABS}"
      echo "next=make rag-install"
      exit 2
    fi
    "${PYTHON_BIN}" "${SCRIPT_DIR}/rag.py" doctor
    ;;
  health)
    ensure_installed
    "${PYTHON_BIN}" "${SCRIPT_DIR}/rag.py" health
    ;;
  logs)
    tail -n "${RAG_LOG_LINES:-120}" "${LOG_FILE}" 2>/dev/null || true
    ;;
  *)
    cat >&2 <<EOF
Usage: $0 <install|index|search|start|stop|restart|status|doctor|health|logs>
EOF
    exit 2
    ;;
esac
