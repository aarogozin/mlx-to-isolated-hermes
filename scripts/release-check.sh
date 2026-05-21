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

log "Checking release metadata"
version_str="$(cat VERSION)"
[[ "${version_str}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
  || fail "VERSION does not contain a valid semver string (got: '${version_str}')"
[[ -f LICENSE ]] || fail "LICENSE missing"
[[ -f CHANGELOG.md ]] || fail "CHANGELOG.md missing"

log "Scanning publishable files for local secrets/runtime state"
legacy_default="$(printf 'b%s' 'ig7')"
if grep -RIn --exclude-dir=.runtime --exclude-dir=.vm --exclude-dir=.cache --exclude=.env --exclude='*.log' -- "${legacy_default}" .; then
  fail "found old hardcoded local API key string in publishable files"
fi

if [[ -n "${OPENAI_API_KEY:-}" && "${#OPENAI_API_KEY}" -ge 16 ]]; then
  if grep -RIn --exclude-dir=.runtime --exclude-dir=.vm --exclude-dir=.cache --exclude=.env --exclude='*.log' -- "${OPENAI_API_KEY}" .; then
    fail "found current OPENAI_API_KEY in publishable files"
  fi
fi

if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  forbidden_tracked="$(git ls-files .env .runtime .vm .cache 2>/dev/null || true)"
  [[ -z "${forbidden_tracked}" ]] || fail "runtime/local files are tracked: ${forbidden_tracked}"
else
  echo "warn no git metadata in this workspace; skipping tracked-file check"
fi

log "Running host doctor and model API check"
make doctor
make model-check

if [[ "${SKIP_VM_E2E:-0}" != "1" ]]; then
  log "Running VM e2e smoke"
  multipass info "${VM_NAME:-omlx-agent-ubuntu}" >/dev/null 2>&1 || fail "Multipass VM missing. Run make vm-create before release-check."
  make e2e-ready
else
  echo "Skipping VM e2e because SKIP_VM_E2E=1"
fi

if [[ "${SKIP_DOCKER_E2E:-0}" != "1" ]]; then
  log "Running Docker preview e2e smoke"
  make docker-e2e
else
  echo "Skipping Docker e2e because SKIP_DOCKER_E2E=1"
fi

log "Release check complete"
