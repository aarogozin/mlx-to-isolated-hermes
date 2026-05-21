#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENV_FILE="${PROJECT_ROOT}/.env"
ENV_SET="${SCRIPT_DIR}/env-set.sh"
RUNTIME_MODEL_DIR="${PROJECT_ROOT}/.runtime/omlx-models"
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

mkdir -p "${RUNTIME_MODEL_DIR}"

json="$("${LMS_BIN}" ls --json)"

printf '%s\n' "${json}" | jq --arg home "${HOME}" '
  [
    .[]
    | select(.type == "llm" and .format == "safetensors")
    | {
        id: .modelKey,
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

printf '%s\n' "${json}" | jq -r --arg home "${HOME}" --arg out "${RUNTIME_MODEL_DIR}" '
  .[]
  | select(.type == "llm" and .format == "safetensors")
  | [.modelKey, .path, (.sizeBytes | tostring), ((.trainedForToolUse // false) | tostring)]
  | @tsv
' | while IFS=$'\t' read -r model_key rel_path _size _tool; do
  src="${HOME}/.lmstudio/models/${rel_path}"
  if [[ -f "${src}/config.json" ]]; then
    ln -sfn "${src}" "${RUNTIME_MODEL_DIR}/${model_key}"
  fi
done

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
        printf '%s\n' "${json}" | jq -r '
          [
            .[]
            | select(.type == "llm" and .format == "safetensors")
          ]
          | sort_by((.trainedForToolUse // false | not), -.sizeBytes)
          | .[0].modelKey // empty
        '
      )"
      ;;
    smallest-tool)
      selected="$(
        printf '%s\n' "${json}" | jq -r '
          [
            .[]
            | select(.type == "llm" and .format == "safetensors")
          ]
          | sort_by((.trainedForToolUse // false | not), .sizeBytes)
          | .[0].modelKey // empty
        '
      )"
      ;;
    largest)
      selected="$(
        printf '%s\n' "${json}" | jq -r '
          [
            .[]
            | select(.type == "llm" and .format == "safetensors")
          ]
          | sort_by(-.sizeBytes)
          | .[0].modelKey // empty
        '
      )"
      ;;
    first|*)
      selected="$(
        printf '%s\n' "${json}" | jq -r '
          [
            .[]
            | select(.type == "llm" and .format == "safetensors")
          ]
          | .[0].modelKey // empty
        '
      )"
      ;;
  esac
fi

if [[ -z "${selected}" ]]; then
  printf 'ERROR: no MLX safetensors LLM models found in LM Studio.\n' >&2
  exit 1
fi

"${ENV_SET}" "${ENV_FILE}" MODEL_DIR "${RUNTIME_MODEL_DIR}"
"${ENV_SET}" "${ENV_FILE}" MODEL_NAME "${selected}"
"${ENV_SET}" "${ENV_FILE}" OPENAI_BASE_URL "http://localhost:8000/v1"
"${ENV_SET}" "${ENV_FILE}" ANTHROPIC_BASE_URL "http://localhost:8000"
"${ENV_SET}" "${ENV_FILE}" OPENAI_BASE_URL_GUEST "http://model-host.internal:8000/v1"
"${ENV_SET}" "${ENV_FILE}" ANTHROPIC_BASE_URL_GUEST "http://model-host.internal:8000"

echo "Synced oMLX model dir: ${RUNTIME_MODEL_DIR}"
echo "Catalog: ${RUNTIME_CATALOG}"
echo "Selected model: ${selected}"
echo
"${SCRIPT_DIR}/models-list-human.sh"
