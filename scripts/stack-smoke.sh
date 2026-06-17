#!/usr/bin/env bash
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

DOCKER_NAME="${DOCKER_NAME:-omlx-agent-docker}"
RAG_DOCKER_NAME="${RAG_DOCKER_NAME:-mlx-isolated-rag}"
failures=0
warnings=0

ok() { printf 'ok   %s\n' "$*"; }
warn() { warnings=$((warnings + 1)); printf 'warn %s\n' "$*"; }
fail() { failures=$((failures + 1)); printf 'fail %s\n' "$*"; }

container_running() {
  local name="$1"
  command -v docker >/dev/null 2>&1 \
    && docker container inspect "${name}" >/dev/null 2>&1 \
    && [[ "$(docker inspect -f '{{.State.Running}}' "${name}" 2>/dev/null || true)" == "true" ]]
}

if ! command -v docker >/dev/null 2>&1; then
  fail "docker CLI missing"
  exit 1
fi

if container_running "${DOCKER_NAME}"; then
  ok "agent container running: ${DOCKER_NAME}"
else
  fail "agent container not running: ${DOCKER_NAME}"
fi

if container_running "${DOCKER_NAME}"; then
  if docker exec "${DOCKER_NAME}" sh -lc 'key="$(grep -E "^OPENAI_API_KEY=" /opt/data/.env 2>/dev/null | cut -d= -f2-)"; curl -fsS --max-time 5 http://model-host.internal:8000/v1/models -H "Authorization: Bearer ${key}" >/dev/null'; then
    ok "model API reachable from agent sandbox"
  else
    fail "model API not reachable from agent sandbox"
  fi

  if docker exec "${DOCKER_NAME}" sh -lc 'command -v rag-search >/dev/null 2>&1'; then
    ok "rag-search bridge installed in agent sandbox"
  else
    fail "rag-search bridge missing in agent sandbox"
  fi
fi

if [[ "${RAG_ENABLED:-1}" == "1" || "${RAG_ENABLED:-1}" == "true" ]]; then
  if container_running "${RAG_DOCKER_NAME}"; then
    ok "RAG container running: ${RAG_DOCKER_NAME}"
    if curl -fsS --max-time 5 "http://${RAG_HOST:-127.0.0.1}:${RAG_PORT:-8765}/health" >/dev/null; then
      ok "RAG API reachable on host"
    else
      fail "RAG API not reachable on host"
    fi
    if container_running "${DOCKER_NAME}" \
      && docker exec "${DOCKER_NAME}" sh -lc 'curl -fsS --max-time 5 http://rag-host.internal:8765/health >/dev/null'; then
      ok "RAG API reachable from agent sandbox"
    elif container_running "${DOCKER_NAME}"; then
      fail "RAG API not reachable from agent sandbox"
    fi
  else
    warn "RAG enabled but container is not running: ${RAG_DOCKER_NAME}"
  fi
fi

if curl -fsS --max-time 5 "http://127.0.0.1:${DOCKER_DASHBOARD_PORT:-9120}" >/dev/null 2>&1; then
  ok "agent dashboard reachable on host"
else
  warn "agent dashboard not reachable on host"
fi

if [[ "${N8N_ENABLED:-0}" == "1" || "${N8N_ENABLED:-0}" == "true" ]]; then
  if curl -fsS --max-time 5 "http://127.0.0.1:${N8N_PORT:-5678}/healthz" >/dev/null; then
    ok "n8n health endpoint reachable"
  else
    fail "n8n enabled but health endpoint is not reachable"
  fi
fi

if "${SCRIPT_DIR}/mcp-doctor.sh" --quiet; then
  ok "MCP doctor"
else
  warn "MCP doctor needs attention; run make mcp-doctor"
fi

printf 'stack_smoke=done failures=%d warnings=%d\n' "${failures}" "${warnings}"
[[ "${failures}" -eq 0 ]]
