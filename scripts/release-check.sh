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

SANDBOX_BACKEND="${SANDBOX_BACKEND:-docker}"

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

log "Checking release metadata"
version_str="$(cat VERSION)"
[[ "${version_str}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
  || fail "VERSION does not contain a valid semver string (got: '${version_str}')"
[[ -f LICENSE ]] || fail "LICENSE missing"
[[ -f CHANGELOG.md ]] || fail "CHANGELOG.md missing"
if ! grep -q "^## ${version_str}" CHANGELOG.md; then
  fail "Version '${version_str}' from VERSION file is not documented in CHANGELOG.md (expected '## ${version_str}')"
fi

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

for secret_name in TELEGRAM_BOT_TOKEN CLOUDFLARE_TUNNEL_TOKEN OPENCLAW_GATEWAY_TOKEN; do
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
  else
    log "Running RAG smoke (using mock source folder)"
    make rag-install
    
    # Create a temporary directory in .runtime to avoid Docker Desktop mount permission issues on macOS
    MOCK_DIR="${PROJECT_ROOT}/.runtime/omlx-rag-smoke"
    mkdir -p "${MOCK_DIR}"
    echo "This is a test document containing the secret keyword antigravities for RAG validation." > "${MOCK_DIR}/smoke-test-doc.txt"
    
    # Run index and search using the mock directory
    RAG_SOURCE_PATH="${MOCK_DIR}" make rag-index
    RAG_SOURCE_PATH="${MOCK_DIR}" QUERY="antigravities" make rag-search
    
    rm -rf "${MOCK_DIR}"
  fi
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

if [[ "${AGENT_RUNTIME}" == "openclaw" ]]; then
  "${SCRIPT_DIR}/openclaw-control.sh" status docker
elif command -v docker >/dev/null 2>&1 && docker container inspect "${DOCKER_NAME:-omlx-agent-docker}" >/dev/null 2>&1; then
  DASHBOARD_TARGET=docker "${SCRIPT_DIR}/dashboard-control.sh" status
else
  echo "Skipping Docker dashboard status because container is missing"
fi

log "Release check complete"
