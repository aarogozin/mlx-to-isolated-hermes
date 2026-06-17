#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
OMLX_HOME="${OMLX_HOME:-${PROJECT_ROOT}}"
ENV_FILE="${OMLX_HOME}/.env"
MODEL_REQUIRED=0

if [[ "${1:-}" == "--model-required" ]]; then
  MODEL_REQUIRED=1
fi

failures=0
warnings=0

pass() {
  printf 'ok   %s\n' "$*"
}

warn() {
  warnings=$((warnings + 1))
  printf 'warn %s\n' "$*"
}

fail() {
  failures=$((failures + 1))
  printf 'fail %s\n' "$*"
}

check_command() {
  local name="$1"
  local cmd="$2"

  if command -v "$cmd" >/dev/null 2>&1; then
    pass "${name}: $(command -v "$cmd")"
  else
    fail "${name}: missing ${cmd}"
  fi
}

load_env() {
  if [[ -f "${ENV_FILE}" ]]; then
    set -a
    # shellcheck disable=SC1090
    source "${ENV_FILE}"
    set +a
    pass ".env loaded"
  else
    warn ".env missing; run make bootstrap"
  fi
}

check_platform() {
  if [[ "$(uname -s)" == "Darwin" ]]; then
    pass "macOS host"
  else
    fail "not running on macOS"
  fi

  if [[ "$(uname -m)" == "arm64" ]]; then
    pass "Apple Silicon arm64"
  else
    fail "not running on arm64"
  fi
}

check_lms() {
  if [[ -x "${HOME}/.lmstudio/bin/lms" ]]; then
    pass "lms: ${HOME}/.lmstudio/bin/lms"
  elif command -v lms >/dev/null 2>&1; then
    pass "lms: $(command -v lms)"
  else
    fail "lms missing; launch LM Studio once after install"
  fi
}

check_docker() {
  if [[ -d "/Applications/Docker.app" ]]; then
    pass "Docker.app"
  else
    fail "Docker.app missing"
  fi

  if command -v docker >/dev/null 2>&1; then
    pass "docker CLI: $(command -v docker)"
    if docker version >/dev/null 2>&1; then
      pass "Docker daemon reachable"
    else
      warn "Docker CLI exists, but daemon is not reachable; launch Docker Desktop"
    fi
  else
    fail "docker CLI missing"
  fi
}

check_model_api() {
  local base_url="${OPENAI_BASE_URL:-http://localhost:8000/v1}"
  local api_key="${OPENAI_API_KEY:-}"
  local models_url="${base_url%/}/models"
  local curl_args=(-fsS --max-time 3)

  if [[ -n "${api_key}" ]]; then
    curl_args+=(-H "Authorization: Bearer ${api_key}")
  fi

  if curl "${curl_args[@]}" "${models_url}" >/dev/null 2>&1; then
    pass "model API reachable: ${models_url}"
  elif [[ "${MODEL_REQUIRED}" == "1" ]]; then
    fail "model API not reachable: ${models_url}"
  else
    warn "model API not reachable yet: ${models_url}"
  fi
}

check_model_dir() {
  local model_dir="${MODEL_DIR:-${HOME}/.lmstudio/models}"

  if [[ -d "${model_dir}" ]]; then
    pass "model dir: ${model_dir}"
  else
    warn "model dir missing: ${model_dir}"
  fi
}

check_model_artifacts() {
  local output
  output="$("${SCRIPT_DIR}/models-doctor.py" 2>/dev/null | tail -n 1 || true)"
  if [[ "${output}" =~ issues=([0-9]+) ]]; then
    if [[ "${BASH_REMATCH[1]}" == "0" ]]; then
      pass "model artifact scan: no incomplete artifacts"
    else
      warn "model artifact scan: ${BASH_REMATCH[1]} issue(s); run make models-doctor"
    fi
  else
    warn "model artifact scan unavailable"
  fi
}

check_rag() {
  local enabled="${RAG_ENABLED:-1}"

  if [[ "${enabled}" != "1" && "${enabled}" != "true" && "${enabled}" != "yes" ]]; then
    pass "RAG: disabled"
    return
  fi

  if [[ ! -x "${SCRIPT_DIR}/rag-control.sh" ]]; then
    fail "RAG control script missing or not executable"
    return
  fi

  if output="$("${SCRIPT_DIR}/rag-control.sh" doctor 2>&1)"; then
    pass "RAG doctor"
  else
    warn "RAG doctor needs attention; run make rag-install and set OBSIDIAN_SHARED_PATH"
    printf '%s\n' "${output}" | sed 's/^/     /'
  fi
}

main() {
  load_env
  check_platform
  check_command "brew" brew
  check_command "git" git
  check_command "jq" jq
  check_command "yq" yq
  check_command "uv" uv
  check_command "pipx" pipx
  check_command "node" node
  check_command "pnpm" pnpm
  check_command "omlx" omlx
  check_lms
  check_model_dir
  check_model_artifacts

  check_docker
  check_model_api
  check_rag
  if [[ -x "${SCRIPT_DIR}/mcp-doctor.sh" ]]; then
    if "${SCRIPT_DIR}/mcp-doctor.sh" --quiet; then
      pass "MCP doctor"
    else
      warn "MCP doctor needs attention; run make mcp-doctor"
    fi
  fi

  printf '\nDoctor finished: %s failure(s), %s warning(s)\n' "${failures}" "${warnings}"

  if [[ "${failures}" -gt 0 ]]; then
    exit 1
  fi
}

main "$@"
