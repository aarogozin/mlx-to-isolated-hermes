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

MODEL_DIR="${MODEL_DIR:-${PROJECT_ROOT}/.runtime/omlx-models}"
OMLX_PORT="${OMLX_PORT:-8000}"
MODEL_BIND_HOST="${MODEL_BIND_HOST:-0.0.0.0}"
OPENAI_API_KEY="${OPENAI_API_KEY:-}"
LOG_DIR="${PROJECT_ROOT}/.runtime/logs"
PID_FILE="${PROJECT_ROOT}/.runtime/omlx.pid"
LAUNCHD_LABEL="${OMLX_LAUNCHD_LABEL:-com.omlx-to-client.omlx}"
LAUNCHD_PLIST="${HOME}/Library/LaunchAgents/${LAUNCHD_LABEL}.plist"
BREW_PREFIX="$(brew --prefix 2>/dev/null || printf '/opt/homebrew')"
OMLX_BIN="$(command -v omlx || printf '%s/bin/omlx' "${BREW_PREFIX}")"
JQ_BIN="$(command -v jq || printf '%s/bin/jq' "${BREW_PREFIX}")"
UID_VALUE="$(id -u)"

mkdir -p "${LOG_DIR}"

if [[ -z "${OPENAI_API_KEY}" ]]; then
  echo "ERROR: OPENAI_API_KEY is required for host oMLX auth. Run make bootstrap or set it in .env." >&2
  exit 1
fi

if [[ ! -d "${MODEL_DIR}" || -z "$(find "${MODEL_DIR}" -maxdepth 1 -type l -o -type d | tail -n +2 | head -1)" ]]; then
  "${SCRIPT_DIR}/models-sync-omlx.sh"
  set -a
  # shellcheck disable=SC1090
  source "${ENV_FILE}"
  set +a
  MODEL_DIR="${MODEL_DIR:-${PROJECT_ROOT}/.runtime/omlx-models}"
fi

if lsof -nP -iTCP:"${OMLX_PORT}" -sTCP:LISTEN >/dev/null 2>&1; then
  if brew services info jundot/omlx/omlx 2>/dev/null | grep -q 'Running: true'; then
    echo "Stopping Homebrew oMLX service so project runtime can bind ${MODEL_BIND_HOST}:${OMLX_PORT}"
    brew services stop jundot/omlx/omlx >/dev/null || true
    sleep 2
  fi
fi

models_url="http://localhost:${OMLX_PORT}/v1/models"

if lsof -nP -iTCP:"${OMLX_PORT}" -sTCP:LISTEN >/dev/null 2>&1; then
  if curl -fsS --max-time 2 -H "Authorization: Bearer ${OPENAI_API_KEY}" "${models_url}" >/dev/null 2>&1; then
    existing_pid="$(lsof -nP -iTCP:"${OMLX_PORT}" -sTCP:LISTEN -t | head -1)"
    echo "Port ${OMLX_PORT} is already served by PID ${existing_pid}; using existing model API."
  else
    existing_pid="$(lsof -nP -iTCP:"${OMLX_PORT}" -sTCP:LISTEN -t | head -1)"
    echo "ERROR: port ${OMLX_PORT} is in use by PID ${existing_pid}, but the authenticated model API is not reachable." >&2
    echo "Stop that process or set OMLX_PORT in .env, then rerun this command." >&2
    exit 1
  fi
else
  mkdir -p "${HOME}/Library/LaunchAgents"
  echo "Installing launchd oMLX service ${LAUNCHD_LABEL}"
  "${JQ_BIN}" -n \
    --arg label "${LAUNCHD_LABEL}" \
    --arg omlx "${OMLX_BIN}" \
    --arg model_dir "${MODEL_DIR}" \
    --arg host "${MODEL_BIND_HOST}" \
    --arg port "${OMLX_PORT}" \
    --arg api_key "${OPENAI_API_KEY}" \
    --arg stdout "${LOG_DIR}/omlx.log" \
    --arg stderr "${LOG_DIR}/omlx.err.log" \
    --arg path "${BREW_PREFIX}/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
    --arg working_directory "${PROJECT_ROOT}" \
    '{
      Label: $label,
      ProgramArguments: [
        $omlx,
        "serve",
        "--model-dir", $model_dir,
        "--host", $host,
        "--port", $port,
        "--api-key", $api_key
      ],
      EnvironmentVariables: {
        PATH: $path
      },
      RunAtLoad: true,
      KeepAlive: true,
      StandardOutPath: $stdout,
      StandardErrorPath: $stderr,
      WorkingDirectory: $working_directory
    }' | plutil -convert xml1 -o "${LAUNCHD_PLIST}" -

  launchctl bootout "gui/${UID_VALUE}" "${LAUNCHD_PLIST}" >/dev/null 2>&1 || true
  launchctl bootstrap "gui/${UID_VALUE}" "${LAUNCHD_PLIST}"
  launchctl kickstart -k "gui/${UID_VALUE}/${LAUNCHD_LABEL}" >/dev/null 2>&1 || true
fi

for _ in {1..120}; do
  if curl -fsS --max-time 2 -H "Authorization: Bearer ${OPENAI_API_KEY}" "${models_url}" >/dev/null 2>&1; then
    echo "oMLX ready: ${models_url}"
    if lsof -nP -iTCP:"${OMLX_PORT}" -sTCP:LISTEN -t >/dev/null 2>&1; then
      lsof -nP -iTCP:"${OMLX_PORT}" -sTCP:LISTEN -t | head -1 > "${PID_FILE}"
    fi
    curl -fsS -H "Authorization: Bearer ${OPENAI_API_KEY}" "${models_url}" | jq .
    exit 0
  fi
  sleep 1
done

echo "ERROR: oMLX did not become ready. Tail log:" >&2
tail -80 "${LOG_DIR}/omlx.log" >&2 || true
exit 1
