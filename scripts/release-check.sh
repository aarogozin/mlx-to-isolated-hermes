#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENV_FILE="${PROJECT_ROOT}/.env"

cd "${PROJECT_ROOT}"

if [[ -f "${ENV_FILE}" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "${ENV_FILE}"
  set +a
fi

AGENT_RUNTIME="${AGENT_RUNTIME:-hermes}"
SANDBOX_BACKEND="${SANDBOX_BACKEND:-multipass}"
HERMES_VM_NAME="${HERMES_VM_NAME:-${VM_NAME:-omlx-agent-ubuntu}}"
OPENCLAW_VM_NAME="${OPENCLAW_VM_NAME:-omlx-openclaw-ubuntu}"
case "${AGENT_RUNTIME}" in
  hermes) SELECTED_VM_NAME="${HERMES_VM_NAME}" ;;
  openclaw) SELECTED_VM_NAME="${OPENCLAW_VM_NAME}" ;;
  *) SELECTED_VM_NAME="${VM_NAME:-omlx-agent-ubuntu}" ;;
esac

log() {
  printf '\n==> %s\n' "$*"
}

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

log "Checking shell syntax"
while IFS= read -r -d '' script; do
  bash -n "${script}"
done < <(find scripts -type f -name '*.sh' -print0)

log "Checking Python syntax and RAG unit tests"
python3 -m py_compile scripts/models-doctor.py scripts/rag.py
"${SCRIPT_DIR}/test-rag-unit.sh"

log "Running shared-folder mock tests"
"${SCRIPT_DIR}/test-shared-mounts-mock.sh"

log "Checking release metadata"
version_str="$(cat VERSION)"
[[ "${version_str}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
  || fail "VERSION does not contain a valid semver string (got: '${version_str}')"
[[ -f LICENSE ]] || fail "LICENSE missing"
[[ -f CHANGELOG.md ]] || fail "CHANGELOG.md missing"

log "Checking tracked text for non-English Cyrillic content"
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  "${SCRIPT_DIR}/check-english-text.py"
else
  echo "warn no git metadata in this workspace; skipping Cyrillic scan"
fi

log "Scanning publishable files for local secrets/runtime state"
legacy_default="$(printf 'b%s' 'ig7')"
if grep -RFIn --exclude-dir=.runtime --exclude-dir=.vm --exclude-dir=.cache --exclude=.env --exclude='*.log' -- "${legacy_default}" .; then
  fail "found old hardcoded local API key string in publishable files"
fi

if [[ -n "${OPENAI_API_KEY:-}" && "${#OPENAI_API_KEY}" -ge 16 ]]; then
  if grep -RFIn --exclude-dir=.runtime --exclude-dir=.vm --exclude-dir=.cache --exclude=.env --exclude='*.log' -- "${OPENAI_API_KEY}" .; then
    fail "found current OPENAI_API_KEY in publishable files"
  fi
fi

for secret_name in TELEGRAM_BOT_TOKEN TAILSCALE_AUTH_KEY CLOUDFLARE_TUNNEL_TOKEN OPENCLAW_GATEWAY_TOKEN; do
  secret_value="${!secret_name:-}"
  if [[ -n "${secret_value}" && "${#secret_value}" -ge 16 ]]; then
    if grep -RFIn --exclude-dir=.runtime --exclude-dir=.vm --exclude-dir=.cache --exclude=.env --exclude='*.log' -- "${secret_value}" .; then
      fail "found current ${secret_name} in publishable files"
    fi
  fi
done

if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  forbidden_tracked="$(git ls-files .env .runtime .vm .cache 2>/dev/null || true)"
  [[ -z "${forbidden_tracked}" ]] || fail "runtime/local files are tracked: ${forbidden_tracked}"
else
  echo "warn no git metadata in this workspace; skipping tracked-file check"
fi

log "Running host doctor and model API check"
if [[ "${SKIP_HOST_DOCTOR:-0}" == "1" ]]; then
  echo "Skipping host doctor/model API check because SKIP_HOST_DOCTOR=1"
  make models-doctor
else
  make doctor
  make model-check
  make models-doctor
fi

if [[ "${RAG_ENABLED:-1}" == "1" || "${RAG_ENABLED:-1}" == "true" ]]; then
  if [[ "${SKIP_RAG_E2E:-0}" == "1" ]]; then
    echo "Skipping RAG smoke because SKIP_RAG_E2E=1"
  elif [[ -n "${OBSIDIAN_SHARED_PATH:-}" || ( -n "${RAG_SOURCE_PATH:-}" && "${RAG_SOURCE_PATH:-}" != '${OBSIDIAN_SHARED_PATH}' && "${RAG_SOURCE_PATH:-}" != '${OBSIDIAN_SHARED_PATH:-}' ) ]]; then
    log "Running RAG smoke"
    make rag-install
    make rag-index
    QUERY="${RAG_SMOKE_QUERY:-test}" make rag-search
  else
    echo "Skipping RAG smoke because OBSIDIAN_SHARED_PATH/RAG_SOURCE_PATH is not set"
  fi
fi

if [[ "${SKIP_VM_E2E:-0}" != "1" ]]; then
  log "Running VM e2e smoke"
  multipass info "${SELECTED_VM_NAME}" >/dev/null 2>&1 || fail "Multipass VM missing: ${SELECTED_VM_NAME}. Run make vm-create before release-check."
  case "${AGENT_RUNTIME}" in
    hermes)
      VM_NAME="${SELECTED_VM_NAME}" "${SCRIPT_DIR}/e2e-ready.sh"
      ;;
    openclaw)
      VM_NAME="${SELECTED_VM_NAME}" "${SCRIPT_DIR}/openclaw-control.sh" status multipass
      ;;
  esac
  log "Checking Multipass shared folder"
  AGENT_RUNTIME="${AGENT_RUNTIME}" VM_NAME="${SELECTED_VM_NAME}" "${SCRIPT_DIR}/shared-mounts-check.sh" multipass
else
  echo "Skipping VM e2e because SKIP_VM_E2E=1"
fi

if [[ "${SKIP_DOCKER_E2E:-0}" != "1" ]]; then
  log "Running Docker preview e2e smoke"
  "${SCRIPT_DIR}/docker-e2e.sh"
else
  echo "Skipping Docker e2e because SKIP_DOCKER_E2E=1"
fi

log "Checking daemon control surfaces"
if [[ -n "${TELEGRAM_BOT_TOKEN:-}" ]]; then
  "${SCRIPT_DIR}/telegram-control.sh" doctor
else
  echo "Skipping telegram-doctor because TELEGRAM_BOT_TOKEN is not set"
fi

dashboard_target="${DASHBOARD_TARGET:-${SANDBOX_BACKEND:-vm}}"
case "${dashboard_target}" in
  docker)
    if [[ "${AGENT_RUNTIME}" == "openclaw" ]]; then
      "${SCRIPT_DIR}/openclaw-control.sh" status docker
    elif command -v docker >/dev/null 2>&1 && docker container inspect "${DOCKER_NAME:-omlx-agent-docker}" >/dev/null 2>&1; then
      DASHBOARD_TARGET=docker "${SCRIPT_DIR}/dashboard-control.sh" status
    else
      echo "Skipping Docker dashboard status because container is missing"
    fi
    ;;
  vm|multipass)
    if multipass info "${SELECTED_VM_NAME}" >/dev/null 2>&1; then
      if [[ "${AGENT_RUNTIME}" == "openclaw" ]]; then
        VM_NAME="${SELECTED_VM_NAME}" "${SCRIPT_DIR}/openclaw-control.sh" status multipass
      else
        VM_NAME="${SELECTED_VM_NAME}" DASHBOARD_TARGET=vm "${SCRIPT_DIR}/dashboard-control.sh" status
      fi
    else
      echo "Skipping VM dashboard status because VM is missing"
    fi
    ;;
  *)
    echo "Skipping dashboard status for unsupported target: ${dashboard_target}"
    ;;
esac

log "Release check complete"
