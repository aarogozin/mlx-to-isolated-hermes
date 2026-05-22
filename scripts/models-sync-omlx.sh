#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENV_FILE="${PROJECT_ROOT}/.env"
ENV_SET="${SCRIPT_DIR}/env-set.sh"

RUNTIME_CATALOG="${PROJECT_ROOT}/.runtime/lmstudio-models.json"
LMS_BIN="${HOME}/.lmstudio/bin/lms"
# MODEL_DEFAULT_STRATEGY controls which model is auto-selected when MODEL/MODEL_NAME
# is not explicitly set. Options:
#   largest-tool  — largest model with tool-use support (default; best quality)
#   smallest-tool — smallest model with tool-use support (original behaviour)
#   largest       — largest model regardless of tool-use support
#   first         — first model in the LM Studio catalog
MODEL_DEFAULT_STRATEGY="${MODEL_DEFAULT_STRATEGY:-largest-tool}"

if [[ -f "${ENV_FILE}" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "${ENV_FILE}"
  set +a
fi

if [[ ! -x "${LMS_BIN}" ]]; then
  LMS_BIN="$(command -v lms)"
fi

# Detect LM Studio models directory
if [[ -d "${HOME}/.lmstudio/models" ]]; then
  LMSTUDIO_MODEL_DIR="${HOME}/.lmstudio/models"
elif [[ -d "${HOME}/Library/Application Support/LM Studio/models" ]]; then
  LMSTUDIO_MODEL_DIR="${HOME}/Library/Application Support/LM Studio/models"
else
  LMSTUDIO_MODEL_DIR="${HOME}/.lmstudio/models"
fi

mkdir -p "${PROJECT_ROOT}/.runtime"

json="$("${LMS_BIN}" ls --json 2>/dev/null || printf '[]')"

printf '%s\n' "${json}" | jq --arg home "${HOME}" '
  [
    .[]
    | select(.type == "llm" and .format == "safetensors")
    | {
        id: (.path | split("/") | last),
        modelKey: .modelKey,
        displayName: .displayName,
        publisher: .publisher,
        path: ($home + "/.lmstudio/models/" + .path),
        lmstudioPath: .path,
        sizeBytes: .sizeBytes,
        paramsString: .paramsString,
        architecture: .architecture,
        quantization: .quantization,
        vision: (.vision // false),
        trainedForToolUse: (.trainedForToolUse // false),
        maxContextLength: (.maxContextLength // null)
      }
  ]
' > "${RUNTIME_CATALOG}"



requested="${MODEL:-${MODEL_NAME:-}}"
if [[ -n "${requested}" ]]; then
  selected="$(
    jq -r --arg requested "${requested}" '
      map(select(.id == $requested or (.displayName | ascii_downcase) == ($requested | ascii_downcase)))
      | .[0].id // empty
    ' "${RUNTIME_CATALOG}"
  )"
else
  selected=""
fi

if [[ -z "${selected}" ]]; then
  # Pick a model automatically according to MODEL_DEFAULT_STRATEGY.
  case "${MODEL_DEFAULT_STRATEGY:-largest-tool}" in
    largest-tool)
      selected="$(
        jq -r '
          (map(select(.trainedForToolUse == true)) | sort_by(-.sizeBytes) | .[0].id // empty)
          // (sort_by(-.sizeBytes) | .[0].id // empty)
        ' "${RUNTIME_CATALOG}"
      )"
      ;;
    smallest-tool)
      selected="$(
        jq -r '
          (map(select(.trainedForToolUse == true)) | sort_by(.sizeBytes) | .[0].id // empty)
          // (sort_by(.sizeBytes) | .[0].id // empty)
        ' "${RUNTIME_CATALOG}"
      )"
      ;;
    largest)
      selected="$(
        jq -r 'sort_by(-.sizeBytes) | .[0].id // empty' "${RUNTIME_CATALOG}"
      )"
      ;;
    first|*)
      selected="$(
        jq -r '.[0].id // empty' "${RUNTIME_CATALOG}"
      )"
      ;;
  esac
fi

if [[ -z "${selected}" ]]; then
  printf 'ERROR: no MLX safetensors LLM models found in LM Studio.\n' >&2
  exit 1
fi

"${ENV_SET}" "${ENV_FILE}" MODEL_DIR "${LMSTUDIO_MODEL_DIR}"
"${ENV_SET}" "${ENV_FILE}" MODEL_NAME "${selected}"
"${ENV_SET}" "${ENV_FILE}" OPENAI_BASE_URL "http://localhost:8000/v1"
"${ENV_SET}" "${ENV_FILE}" ANTHROPIC_BASE_URL "http://localhost:8000"
"${ENV_SET}" "${ENV_FILE}" OPENAI_BASE_URL_GUEST "http://model-host.internal:8000/v1"
"${ENV_SET}" "${ENV_FILE}" ANTHROPIC_BASE_URL_GUEST "http://model-host.internal:8000"

echo "Using LM Studio models dir: ${LMSTUDIO_MODEL_DIR}"
echo "Catalog: ${RUNTIME_CATALOG}"
echo "Selected model: ${selected}"
echo
"${SCRIPT_DIR}/models-list-human.sh"
