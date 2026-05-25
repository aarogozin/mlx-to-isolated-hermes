#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENV_FILE="${PROJECT_ROOT}/.env"

OVERRIDE_MATRIX_RAG_QUERY_SET="${MATRIX_RAG_QUERY+x}"
OVERRIDE_MATRIX_RAG_QUERY="${MATRIX_RAG_QUERY:-}"
OVERRIDE_MATRIX_RAG_SENTINEL_SET="${MATRIX_RAG_SENTINEL+x}"
OVERRIDE_MATRIX_RAG_SENTINEL="${MATRIX_RAG_SENTINEL:-}"

if [[ -f "${ENV_FILE}" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "${ENV_FILE}"
  set +a
fi

MATRIX_MODES="${MATRIX_MODES:-hermes/docker hermes/multipass openclaw/docker openclaw/multipass}"
MATRIX_CLEAN_MODE="${MATRIX_CLEAN_MODE:-once}"
MATRIX_TELEGRAM="${MATRIX_TELEGRAM:-disabled}"
MATRIX_FINAL_ACTION="${MATRIX_FINAL_ACTION:-pause}"
MATRIX_RAG_SOURCE_MODE="${MATRIX_RAG_SOURCE_MODE:-synthetic}"
MATRIX_RAG_SENTINEL="${OVERRIDE_MATRIX_RAG_SENTINEL:-${MATRIX_RAG_SENTINEL:-matrix-rag-sentinel-${MATRIX_RUN_ID:-manual}}}"
MATRIX_RAG_QUERY="${OVERRIDE_MATRIX_RAG_QUERY:-${MATRIX_RAG_QUERY:-${RAG_SMOKE_QUERY:-OpenClaw}}}"
MATRIX_CHAT_TIMEOUT_SECONDS="${MATRIX_CHAT_TIMEOUT_SECONDS:-180}"
MATRIX_REPORT_ROOT="${MATRIX_REPORT_ROOT:-${PROJECT_ROOT}/.runtime/matrix-e2e}"
MATRIX_RUN_ID="${MATRIX_RUN_ID:-$(date +%Y%m%d-%H%M%S)}"
MATRIX_REPORT_DIR="${MATRIX_REPORT_DIR:-${MATRIX_REPORT_ROOT}/${MATRIX_RUN_ID}}"
if [[ -z "${OVERRIDE_MATRIX_RAG_SENTINEL_SET}" && "${MATRIX_RAG_SENTINEL}" == "matrix-rag-sentinel-manual" ]]; then
  MATRIX_RAG_SENTINEL="matrix-rag-sentinel-${MATRIX_RUN_ID}"
fi
if [[ "${MATRIX_RAG_SOURCE_MODE}" == "synthetic" && -z "${OVERRIDE_MATRIX_RAG_QUERY_SET}" ]]; then
  MATRIX_RAG_QUERY="${MATRIX_RAG_SENTINEL}"
fi

HERMES_VM_NAME="${HERMES_VM_NAME:-${VM_NAME:-omlx-agent-ubuntu}}"
OPENCLAW_VM_NAME="${OPENCLAW_VM_NAME:-omlx-openclaw-ubuntu}"
VM_SSH_USER="${VM_SSH_USER:-agent}"
DOCKER_NAME="${DOCKER_NAME:-omlx-agent-docker}"
OPENCLAW_DOCKER_NAME="${OPENCLAW_DOCKER_NAME:-omlx-agent-openclaw-docker}"
RAG_PORT="${RAG_PORT:-8765}"

failures=0
current_mode=""
declare -a matrix_results=()

mkdir -p "${MATRIX_REPORT_DIR}"
SUMMARY_FILE="${MATRIX_REPORT_DIR}/summary.txt"
MODEL_SMOKE="${MATRIX_REPORT_DIR}/model-smoke.sh"
RAG_SMOKE="${MATRIX_REPORT_DIR}/rag-smoke.sh"
MATRIX_SYNTHETIC_RAG_VAULT="${MATRIX_REPORT_DIR}/rag-vault"
MATRIX_SYNTHETIC_RAG_INDEX="${MATRIX_REPORT_DIR}/rag-index"
MATRIX_RAG_EXPECTED_TEXT="${MATRIX_RAG_EXPECTED_TEXT:-}"
MATRIX_RAG_EXPECTED_PATH="${MATRIX_RAG_EXPECTED_PATH:-}"
: > "${SUMMARY_FILE}"

log() {
  printf '\n==> %s\n' "$*" | tee -a "${SUMMARY_FILE}"
}

note() {
  printf '%s\n' "$*" | tee -a "${SUMMARY_FILE}"
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

normalize_path() {
  local path="$1"
  [[ -n "${path}" ]] || return 0
  if [[ "${path}" == "~/"* ]]; then
    path="${HOME}/${path#~/}"
  fi
  printf '%s\n' "${path%/}"
}

rag_source_path() {
  local path="${RAG_SOURCE_PATH:-}"
  if [[ -z "${path}" || "${path}" == '${OBSIDIAN_SHARED_PATH}' || "${path}" == '${OBSIDIAN_SHARED_PATH:-}' ]]; then
    path="${OBSIDIAN_SHARED_PATH:-}"
  fi
  normalize_path "${path}"
}

create_synthetic_rag_vault() {
  local vault="${MATRIX_SYNTHETIC_RAG_VAULT}"
  rm -rf "${vault}"
  mkdir -p "${vault}/notes" "${vault}/data" "${vault}/.obsidian" "${vault}/.trash"

  cat > "${vault}/notes/agents.md" <<EOF
---
title: Matrix Agent Fixtures
tags: [matrix-e2e, local-rag]
---

# Matrix Agent Fixtures

${MATRIX_RAG_SENTINEL} is the canonical synthetic proof that Hermes and OpenClaw can reach the shared local RAG service.

The sandbox agents should use rag-search before answering questions about local Obsidian notes, project knowledge, or private documents.
EOF

  cat > "${vault}/notes/model-hosting.md" <<EOF
# Model Hosting

oMLX serves MLX models on the Apple Silicon host through an OpenAI-compatible API.
LM Studio is used as the local catalog and download manager for model artifacts.
The matrix smoke test expects Docker and Multipass sandboxes to reach model-host.internal and rag-host.internal.
EOF

  cat > "${vault}/data/config.json" <<EOF
{
  "fixture": "matrix-e2e",
  "runtime": ["hermes", "openclaw"],
  "backend": ["docker", "multipass"],
  "sentinel": "${MATRIX_RAG_SENTINEL}"
}
EOF

  cat > "${vault}/data/table.csv" <<EOF
name,value
rag_source,synthetic
sentinel,${MATRIX_RAG_SENTINEL}
EOF

  cat > "${vault}/.obsidian/ignored.md" <<EOF
${MATRIX_RAG_SENTINEL}-ignored-obsidian
EOF
  cat > "${vault}/.trash/ignored.md" <<EOF
${MATRIX_RAG_SENTINEL}-ignored-trash
EOF
  cat > "${vault}/secret.env" <<EOF
MATRIX_RAG_SECRET=${MATRIX_RAG_SENTINEL}-ignored-env
EOF
  cat > "${vault}/private.key" <<EOF
${MATRIX_RAG_SENTINEL}-ignored-key
EOF
}

configure_matrix_rag_source() {
  case "${MATRIX_RAG_SOURCE_MODE}" in
    synthetic)
      create_synthetic_rag_vault
      OBSIDIAN_SHARED_PATH="${MATRIX_SYNTHETIC_RAG_VAULT}"
      RAG_SOURCE_PATH="${MATRIX_SYNTHETIC_RAG_VAULT}"
      RAG_INDEX_PATH="${MATRIX_SYNTHETIC_RAG_INDEX}"
      MATRIX_RAG_EXPECTED_TEXT="${MATRIX_RAG_EXPECTED_TEXT:-${MATRIX_RAG_SENTINEL}}"
      MATRIX_RAG_EXPECTED_PATH="${MATRIX_RAG_EXPECTED_PATH:-notes/agents.md}"
      ;;
    env)
      MATRIX_RAG_EXPECTED_TEXT="${MATRIX_RAG_EXPECTED_TEXT:-}"
      MATRIX_RAG_EXPECTED_PATH="${MATRIX_RAG_EXPECTED_PATH:-}"
      ;;
    *)
      die "unsupported MATRIX_RAG_SOURCE_MODE=${MATRIX_RAG_SOURCE_MODE}. Use synthetic or env."
      ;;
  esac

  export OBSIDIAN_SHARED_PATH RAG_SOURCE_PATH RAG_INDEX_PATH MATRIX_RAG_QUERY MATRIX_RAG_SENTINEL MATRIX_RAG_EXPECTED_TEXT MATRIX_RAG_EXPECTED_PATH
}

telegram_env_args() {
  if [[ "${MATRIX_TELEGRAM}" == "disabled" ]]; then
    printf '%s\0' \
      TELEGRAM_BOT_TOKEN= \
      TELEGRAM_USER_ID= \
      TELEGRAM_ALLOWED_USERS= \
      TELEGRAM_GROUP_ALLOWED_USERS= \
      TELEGRAM_GROUP_ALLOWED_CHATS= \
      GATEWAY_ALLOWED_USERS=
  fi
}

run_logged() {
  local logfile="$1"
  local label="$2"
  shift 2

  {
    printf '\n---- %s ----\n' "${label}"
    printf '+'
    printf ' %q' "$@"
    printf '\n'
  } | tee -a "${logfile}"

  set +e
  "$@" > >(tee -a "${logfile}") 2>&1
  local status=$?
  set -e
  return "${status}"
}

strip_ansi() {
  perl -pe 's/\e\[[0-9;?]*[ -\/]*[@-~]//g' 2>/dev/null || cat
}

summarize_failure() {
  local logfile="$1"
  local step="$2"
  local output_file="$3"

  {
    printf 'failed_step=%s\n' "${step}"
    printf 'log=%s\n\n' "${logfile}"
    printf '%s\n' 'last_log_lines:'
    tail -n 80 "${logfile}" 2>/dev/null | strip_ansi
  } > "${output_file}"
}

run_step() {
  local steps_file="$1"
  local logfile="$2"
  local label="$3"
  shift 3

  set +e
  run_logged "${logfile}" "${label}" "$@"
  local status=$?
  set -e

  if [[ "${status}" -eq 0 ]]; then
    printf 'PASS\t%s\n' "${label}" >> "${steps_file}"
    return 0
  fi

  printf 'FAIL\t%s\t%s\n' "${label}" "${status}" >> "${steps_file}"
  LAST_FAILED_STEP="${label}"
  return "${status}"
}

write_smoke_scripts() {
  cat > "${MODEL_SMOKE}" <<'EOF'
#!/usr/bin/env sh
set -eu

if [ -n "${MATRIX_ENV_FILE:-}" ] && [ -f "${MATRIX_ENV_FILE}" ]; then
  set -a
  . "${MATRIX_ENV_FILE}"
  set +a
fi

export PATH="/opt/data/.local/bin:$HOME/.local/bin:$HOME/.npm-global/bin:$PATH"
: "${OPENAI_BASE_URL:?OPENAI_BASE_URL missing}"
: "${OPENAI_API_KEY:?OPENAI_API_KEY missing}"

command -v node >/dev/null 2>&1 || {
  echo "node missing; cannot run model smoke"
  exit 1
}

node <<'NODE'
const base = (process.env.OPENAI_BASE_URL || '').replace(/\/$/, '');
const key = process.env.OPENAI_API_KEY || '';
const requestedModel = process.env.MODEL_NAME || '';
const timeoutSeconds = Number(process.env.MATRIX_CHAT_TIMEOUT_SECONDS || '180');

async function request(path, body) {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), timeoutSeconds * 1000);
  try {
    const response = await fetch(`${base}${path}`, {
      method: body ? 'POST' : 'GET',
      headers: {
        'Authorization': `Bearer ${key}`,
        'Content-Type': 'application/json'
      },
      body: body ? JSON.stringify(body) : undefined,
      signal: controller.signal
    });
    const text = await response.text();
    if (!response.ok) {
      throw new Error(`${path} -> HTTP ${response.status}: ${text.slice(0, 500)}`);
    }
    return text ? JSON.parse(text) : {};
  } finally {
    clearTimeout(timeout);
  }
}

(async () => {
  const models = await request('/models');
  const list = Array.isArray(models.data) ? models.data : [];
  if (list.length === 0) {
    throw new Error('/models returned no models');
  }
  const model = list.some((item) => item.id === requestedModel) ? requestedModel : list[0].id;
  console.log(`models_ok count=${list.length} model=${model}`);
  const chat = await request('/chat/completions', {
    model,
    messages: [{role: 'user', content: 'Reply with exactly: ok'}],
    max_tokens: 8
  });
  const content = chat.choices?.[0]?.message?.content ?? '';
  console.log(`chat_ok content=${JSON.stringify(content).slice(0, 160)}`);
})().catch((error) => {
  console.error(`model_smoke_failed: ${error.message}`);
  process.exit(1);
});
NODE
EOF

  cat > "${RAG_SMOKE}" <<'EOF'
#!/usr/bin/env sh
set -eu

if [ -n "${MATRIX_ENV_FILE:-}" ] && [ -f "${MATRIX_ENV_FILE}" ]; then
  set -a
  . "${MATRIX_ENV_FILE}"
  set +a
fi

export PATH="/opt/data/.local/bin:$HOME/.local/bin:$HOME/.npm-global/bin:/usr/local/bin:$PATH"
export RAG_BASE_URL="${RAG_BASE_URL:-http://rag-host.internal:8765}"
: "${RAG_QUERY:?RAG_QUERY missing}"
RAG_EXPECTED="${RAG_EXPECTED:-}"
RAG_EXPECTED_PATH="${RAG_EXPECTED_PATH:-}"

command -v rag-search >/dev/null 2>&1 || {
  echo "rag-search missing from sandbox PATH"
  exit 1
}

result="$(rag-search --json --top-k 5 "${RAG_QUERY}")"
printf '%s\n' "${result}"

if command -v jq >/dev/null 2>&1; then
  count="$(printf '%s\n' "${result}" | jq '.results | length')"
  [ "${count}" -gt 0 ] || {
    echo "RAG smoke failed: no results for ${RAG_QUERY}" >&2
    exit 1
  }
  if [ -n "${RAG_EXPECTED}" ]; then
    printf '%s\n' "${result}" | jq -e --arg expected "${RAG_EXPECTED}" '
      any(.results[]; ((.text // "") + " " + (.excerpt // "") + " " + (.path // "")) | contains($expected))
    ' >/dev/null || {
      echo "RAG smoke failed: expected sentinel not found: ${RAG_EXPECTED}" >&2
      exit 1
    }
  fi
  if [ -n "${RAG_EXPECTED_PATH}" ]; then
    printf '%s\n' "${result}" | jq -e --arg expected_path "${RAG_EXPECTED_PATH}" '
      any(.results[]; (.path // "") == $expected_path)
    ' >/dev/null || {
      echo "RAG smoke failed: expected path not found: ${RAG_EXPECTED_PATH}" >&2
      exit 1
    }
  fi
else
  printf '%s\n' "${result}" | grep -Eq '"results"[[:space:]]*:[[:space:]]*\[\]' && {
    echo "RAG smoke failed: no results for ${RAG_QUERY}" >&2
    exit 1
  }
  if [ -n "${RAG_EXPECTED}" ]; then
    printf '%s\n' "${result}" | grep -Fq "${RAG_EXPECTED}" || {
      echo "RAG smoke failed: expected sentinel not found: ${RAG_EXPECTED}" >&2
      exit 1
    }
  fi
fi
EOF

  chmod +x "${MODEL_SMOKE}" "${RAG_SMOKE}"
}

mode_runtime() {
  printf '%s\n' "${1%%/*}"
}

mode_backend() {
  local backend="${1#*/}"
  case "${backend}" in
    vm) printf 'multipass\n' ;;
    *) printf '%s\n' "${backend}" ;;
  esac
}

runtime_vm_name() {
  case "$1" in
    hermes) printf '%s\n' "${HERMES_VM_NAME}" ;;
    openclaw) printf '%s\n' "${OPENCLAW_VM_NAME}" ;;
    *) die "unsupported runtime: $1" ;;
  esac
}

runtime_docker_name() {
  case "$1" in
    hermes) printf '%s\n' "${DOCKER_NAME}" ;;
    openclaw) printf '%s\n' "${OPENCLAW_DOCKER_NAME}" ;;
    *) die "unsupported runtime: $1" ;;
  esac
}

sandbox_env_file() {
  local runtime="$1"
  local backend="$2"
  case "${runtime}/${backend}" in
    hermes/docker) printf '/opt/data/.env\n' ;;
    openclaw/docker) printf '\n' ;;
    hermes/multipass) printf '/home/%s/.hermes/.env\n' "${VM_SSH_USER}" ;;
    openclaw/multipass) printf '/home/%s/.openclaw/.env\n' "${VM_SSH_USER}" ;;
  esac
}

clean_all() {
  log "Cleaning sandbox runtime"
  FORCE=1 "${SCRIPT_DIR}/clean-all.sh"
}

rag_control() {
  RAG_ENABLED=1 \
  OBSIDIAN_SHARED_PATH="${OBSIDIAN_SHARED_PATH:-}" \
  RAG_SOURCE_PATH="${RAG_SOURCE_PATH:-}" \
  RAG_INDEX_PATH="${RAG_INDEX_PATH:-.runtime/rag}" \
  RAG_HOST="${RAG_HOST:-127.0.0.1}" \
  RAG_BIND_HOST="${RAG_BIND_HOST:-0.0.0.0}" \
  RAG_PORT="${RAG_PORT}" \
    "${SCRIPT_DIR}/rag-control.sh" "$@"
}

validate_synthetic_rag_manifest() {
  [[ "${MATRIX_RAG_SOURCE_MODE}" == "synthetic" ]] || return 0

  local manifest="${RAG_INDEX_PATH}/manifest.json"
  [[ -f "${manifest}" ]] || die "synthetic RAG manifest missing: ${manifest}"
  python3 - "${manifest}" <<'PY'
import json
import sys
from pathlib import Path

manifest = json.loads(Path(sys.argv[1]).read_text())
paths = set(manifest.get("documents", {}).keys())
required = {"notes/agents.md", "notes/model-hosting.md", "data/config.json", "data/table.csv"}
for path in sorted(required - paths):
    print(f"missing indexed fixture: {path}", file=sys.stderr)
    sys.exit(1)
for path in sorted(paths):
    if path.startswith(".obsidian/") or path.startswith(".trash/") or path.endswith(".env") or path.endswith(".key"):
        print(f"excluded fixture was indexed: {path}", file=sys.stderr)
        sys.exit(1)
print("synthetic_manifest=ok")
PY
}

prepare_rag() {
  local source
  source="$(rag_source_path)"
  [[ -n "${source}" ]] || die "RAG is mandatory for matrix-e2e; set OBSIDIAN_SHARED_PATH or RAG_SOURCE_PATH."
  [[ -d "${source}" ]] || die "RAG source path does not exist: ${source}"

  log "Preparing shared host RAG"
  "${SCRIPT_DIR}/rag-control.sh" stop >/dev/null 2>&1 || true
  rag_control stop >/dev/null 2>&1 || true
  rag_control install
  rag_control index
  validate_synthetic_rag_manifest
  rag_control start
  rag_control doctor
}

start_mode() {
  local runtime="$1"
  local backend="$2"
  shift 2
  local -a env_args=("$@")

  env -u VM_NAME \
    "${env_args[@]}" \
    AGENT_RUNTIME="${runtime}" \
    SANDBOX_BACKEND="${backend}" \
    AGENT_CONFLICT_POLICY=pause \
    SHARED_MOUNTS_REQUIRED="${SHARED_MOUNTS_REQUIRED:-0}" \
    make -C "${PROJECT_ROOT}" agent-start
}

agent_status() {
  local runtime="$1"
  local backend="$2"
  shift 2
  local -a env_args=("$@")

  env -u VM_NAME \
    "${env_args[@]}" \
    AGENT_RUNTIME="${runtime}" \
    SANDBOX_BACKEND="${backend}" \
    make -C "${PROJECT_ROOT}" agent-status
}

pause_mode() {
  local runtime="$1"
  local backend="$2"
  shift 2
  local -a env_args=("$@")

  env -u VM_NAME \
    "${env_args[@]}" \
    AGENT_RUNTIME="${runtime}" \
    SANDBOX_BACKEND="${backend}" \
    make -C "${PROJECT_ROOT}" agent-pause
}

run_in_sandbox() {
  local runtime="$1"
  local backend="$2"
  local script_path="$3"
  local env_file
  env_file="$(sandbox_env_file "${runtime}" "${backend}")"

  if [[ "${backend}" == "docker" ]]; then
    local container
    container="$(runtime_docker_name "${runtime}")"
    docker exec -i \
      -e "MATRIX_ENV_FILE=${env_file}" \
      -e "RAG_QUERY=${MATRIX_RAG_QUERY}" \
      -e "RAG_EXPECTED=${MATRIX_RAG_EXPECTED_TEXT}" \
      -e "RAG_EXPECTED_PATH=${MATRIX_RAG_EXPECTED_PATH}" \
      -e "RAG_BASE_URL=http://rag-host.internal:${RAG_PORT}" \
      -e "MATRIX_CHAT_TIMEOUT_SECONDS=${MATRIX_CHAT_TIMEOUT_SECONDS}" \
      "${container}" sh -s < "${script_path}"
  else
    local vm
    local remote_script
    vm="$(runtime_vm_name "${runtime}")"
    remote_script="/tmp/$(basename "${script_path}")"
    multipass transfer "${script_path}" "${vm}:${remote_script}" >/dev/null
    multipass exec "${vm}" -- sudo -Hu "${VM_SSH_USER}" env \
      "MATRIX_ENV_FILE=${env_file}" \
      "RAG_QUERY=${MATRIX_RAG_QUERY}" \
      "RAG_EXPECTED=${MATRIX_RAG_EXPECTED_TEXT}" \
      "RAG_EXPECTED_PATH=${MATRIX_RAG_EXPECTED_PATH}" \
      "RAG_BASE_URL=http://rag-host.internal:${RAG_PORT}" \
      "MATRIX_CHAT_TIMEOUT_SECONDS=${MATRIX_CHAT_TIMEOUT_SECONDS}" \
      sh "${remote_script}"
  fi
}

target_ready_check() {
  local runtime="$1"
  local backend="$2"

  if [[ "${backend}" == "docker" ]]; then
    local container
    container="$(runtime_docker_name "${runtime}")"
    docker container inspect "${container}" >/dev/null 2>&1 || {
      echo "target-ready=missing container=${container}"
      return 1
    }
    [[ "$(docker inspect -f '{{.State.Running}}' "${container}")" == "true" ]] || {
      echo "target-ready=stopped container=${container}"
      return 1
    }
    echo "target-ready=ok container=${container}"
    return 0
  fi

  local vm
  vm="$(runtime_vm_name "${runtime}")"
  multipass info "${vm}" >/dev/null 2>&1 || {
    echo "target-ready=missing vm=${vm}"
    return 1
  }
  [[ "$(multipass info "${vm}" | awk '/State/ { print $2; exit }')" == "Running" ]] || {
    echo "target-ready=stopped vm=${vm}"
    return 1
  }
  echo "target-ready=ok vm=${vm}"
}

shared_folder_check() {
  local runtime="$1"
  local backend="$2"

  if [[ -z "${OBSIDIAN_SHARED_PATH:-}" ]]; then
    echo "shared-check=skipped reason=OBSIDIAN_SHARED_PATH unset"
    return 0
  fi

  if [[ "${backend}" == "docker" ]]; then
    AGENT_RUNTIME="${runtime}" \
    SANDBOX_BACKEND="${backend}" \
    DOCKER_NAME="$(runtime_docker_name "${runtime}")" \
    "${SCRIPT_DIR}/shared-mounts-check.sh" "${backend}"
    return $?
  fi

  AGENT_RUNTIME="${runtime}" \
  SANDBOX_BACKEND="${backend}" \
  VM_NAME="$(runtime_vm_name "${runtime}")" \
  "${SCRIPT_DIR}/shared-mounts-check.sh" "${backend}"
}

dashboard_check() {
  local runtime="$1"
  local backend="$2"

  case "${runtime}/${backend}" in
    hermes/docker)
      DASHBOARD_TARGET=docker "${SCRIPT_DIR}/dashboard-control.sh" status
      ;;
    hermes/multipass)
      VM_NAME="${HERMES_VM_NAME}" DASHBOARD_TARGET=vm "${SCRIPT_DIR}/dashboard-control.sh" status
      ;;
    openclaw/docker)
      "${SCRIPT_DIR}/openclaw-control.sh" status docker
      ;;
    openclaw/multipass)
      VM_NAME="${OPENCLAW_VM_NAME}" "${SCRIPT_DIR}/openclaw-control.sh" status multipass
      ;;
  esac
}

cleanup_after_mode() {
  local runtime="$1"
  local backend="$2"
  shift 2
  local -a env_args=("$@")

  case "${MATRIX_FINAL_ACTION}" in
    keep)
      echo "final-action=keep mode=${runtime}/${backend}"
      ;;
    pause)
      pause_mode "${runtime}" "${backend}" "${env_args[@]}"
      ;;
    destroy)
      clean_all
      if [[ "${MATRIX_CLEAN_MODE}" != "each" ]]; then
        prepare_rag
      fi
      ;;
    *)
      die "unsupported MATRIX_FINAL_ACTION=${MATRIX_FINAL_ACTION}. Use pause, keep, or destroy."
      ;;
  esac
}

print_matrix_summary() {
  log "Matrix summary"

  if [[ "${#matrix_results[@]}" -eq 0 ]]; then
    note "No matrix modes were run."
    return 0
  fi

  local entry
  for entry in "${matrix_results[@]}"; do
    IFS='|' read -r status mode logfile steps_file failure_file <<<"${entry}"
    note "${status} ${mode}"
    if [[ -f "${steps_file}" ]]; then
      while IFS=$'\t' read -r step_status step_label step_code; do
        [[ -n "${step_status}" ]] || continue
        if [[ "${step_status}" == "PASS" ]]; then
          note "  ok   ${step_label}"
        else
          note "  fail ${step_label} exit=${step_code:-unknown}"
        fi
      done < "${steps_file}"
    fi

    if [[ "${status}" == "FAIL" ]]; then
      note "  log  ${logfile}"
      if [[ -f "${failure_file}" ]]; then
        note "  failure_excerpt:"
        sed -n '1,45p' "${failure_file}" | sed 's/^/    /' | tee -a "${SUMMARY_FILE}"
      fi
    fi
  done
}

run_mode() {
  local mode="$1"
  local runtime
  local backend
  runtime="$(mode_runtime "${mode}")"
  backend="$(mode_backend "${mode}")"
  [[ "${runtime}" == "hermes" || "${runtime}" == "openclaw" ]] || die "unsupported runtime in MATRIX_MODES: ${mode}"
  [[ "${backend}" == "docker" || "${backend}" == "multipass" ]] || die "unsupported backend in MATRIX_MODES: ${mode}"

  current_mode="${runtime}/${backend}"
  local mode_id="${runtime}-${backend}"
  local logfile="${MATRIX_REPORT_DIR}/${mode_id}.log"
  local steps_file="${MATRIX_REPORT_DIR}/${mode_id}.steps"
  local failure_file="${MATRIX_REPORT_DIR}/${mode_id}.failure.txt"
  : > "${logfile}"
  : > "${steps_file}"
  rm -f "${failure_file}"
  LAST_FAILED_STEP=""

  log "Running matrix mode: ${current_mode}"

  local -a env_args=()
  while IFS= read -r -d '' item; do
    env_args+=("${item}")
  done < <(telegram_env_args)

  if [[ "${MATRIX_CLEAN_MODE}" == "each" ]]; then
    run_step "${steps_file}" "${logfile}" "clean-all before ${current_mode}" clean_all || {
      summarize_failure "${logfile}" "${LAST_FAILED_STEP}" "${failure_file}"
      return 1
    }
    run_step "${steps_file}" "${logfile}" "prepare RAG before ${current_mode}" prepare_rag || {
      summarize_failure "${logfile}" "${LAST_FAILED_STEP}" "${failure_file}"
      return 1
    }
  fi

  run_step "${steps_file}" "${logfile}" "start ${current_mode}" start_mode "${runtime}" "${backend}" "${env_args[@]}" || {
    summarize_failure "${logfile}" "${LAST_FAILED_STEP}" "${failure_file}"
    return 1
  }
  run_step "${steps_file}" "${logfile}" "target ready ${current_mode}" target_ready_check "${runtime}" "${backend}" || {
    summarize_failure "${logfile}" "${LAST_FAILED_STEP}" "${failure_file}"
    return 1
  }
  run_step "${steps_file}" "${logfile}" "agent status ${current_mode}" agent_status "${runtime}" "${backend}" "${env_args[@]}" || {
    summarize_failure "${logfile}" "${LAST_FAILED_STEP}" "${failure_file}"
    return 1
  }
  run_step "${steps_file}" "${logfile}" "model API smoke ${current_mode}" run_in_sandbox "${runtime}" "${backend}" "${MODEL_SMOKE}" || {
    summarize_failure "${logfile}" "${LAST_FAILED_STEP}" "${failure_file}"
    return 1
  }
  run_step "${steps_file}" "${logfile}" "RAG smoke ${current_mode}" run_in_sandbox "${runtime}" "${backend}" "${RAG_SMOKE}" || {
    summarize_failure "${logfile}" "${LAST_FAILED_STEP}" "${failure_file}"
    return 1
  }
  run_step "${steps_file}" "${logfile}" "shared folder smoke ${current_mode}" shared_folder_check "${runtime}" "${backend}" || {
    summarize_failure "${logfile}" "${LAST_FAILED_STEP}" "${failure_file}"
    return 1
  }
  run_step "${steps_file}" "${logfile}" "dashboard/control status ${current_mode}" dashboard_check "${runtime}" "${backend}" || {
    summarize_failure "${logfile}" "${LAST_FAILED_STEP}" "${failure_file}"
    return 1
  }
  run_step "${steps_file}" "${logfile}" "final action ${current_mode}" cleanup_after_mode "${runtime}" "${backend}" "${env_args[@]}" || {
    summarize_failure "${logfile}" "${LAST_FAILED_STEP}" "${failure_file}"
    return 1
  }

  return 0
}

main() {
  cd "${PROJECT_ROOT}"
  configure_matrix_rag_source
  write_smoke_scripts

  note "matrix_report_dir=${MATRIX_REPORT_DIR}"
  note "matrix_modes=${MATRIX_MODES}"
  note "matrix_clean_mode=${MATRIX_CLEAN_MODE}"
  note "matrix_telegram=${MATRIX_TELEGRAM}"
  note "matrix_final_action=${MATRIX_FINAL_ACTION}"
  note "matrix_rag_source_mode=${MATRIX_RAG_SOURCE_MODE}"
  note "matrix_rag_source=${RAG_SOURCE_PATH:-}"
  note "matrix_rag_index=${RAG_INDEX_PATH:-}"
  note "matrix_rag_sentinel=${MATRIX_RAG_SENTINEL}"
  note "matrix_rag_query=${MATRIX_RAG_QUERY}"

  case "${MATRIX_CLEAN_MODE}" in
    once)
      clean_all
      prepare_rag
      ;;
    each)
      ;;
    none)
      prepare_rag
      ;;
    *)
      die "unsupported MATRIX_CLEAN_MODE=${MATRIX_CLEAN_MODE}. Use once, each, or none."
      ;;
  esac

  local mode
  for mode in ${MATRIX_MODES}; do
    local mode_id
    mode_id="$(tr / - <<<"${mode}")"
    if run_mode "${mode}"; then
      note "PASS ${mode}"
      matrix_results+=("PASS|${mode}|${MATRIX_REPORT_DIR}/${mode_id}.log|${MATRIX_REPORT_DIR}/${mode_id}.steps|")
    else
      note "FAIL ${mode} log=${MATRIX_REPORT_DIR}/${mode_id}.log"
      matrix_results+=("FAIL|${mode}|${MATRIX_REPORT_DIR}/${mode_id}.log|${MATRIX_REPORT_DIR}/${mode_id}.steps|${MATRIX_REPORT_DIR}/${mode_id}.failure.txt")
      failures=$((failures + 1))
      if [[ "${MATRIX_STOP_ON_FAIL:-0}" == "1" ]]; then
        break
      fi
    fi
  done

  log "Matrix complete"
  note "failures=${failures}"
  note "report=${MATRIX_REPORT_DIR}"
  print_matrix_summary

  if [[ "${failures}" -gt 0 ]]; then
    exit 1
  fi
}

main "$@"
