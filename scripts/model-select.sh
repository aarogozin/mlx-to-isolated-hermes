#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENV_FILE="${PROJECT_ROOT}/.env"
CATALOG="${PROJECT_ROOT}/.runtime/lmstudio-models.json"

if [[ -f "${ENV_FILE}" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "${ENV_FILE}"
  set +a
fi

MODEL="${MODEL:-${1:-}}"

"${SCRIPT_DIR}/models-sync-omlx.sh" >/dev/null

if [[ ! -s "${CATALOG}" ]]; then
  echo "ERROR: model catalog is empty. Download an MLX safetensors model in LM Studio first." >&2
  exit 1
fi

if [[ -z "${MODEL}" ]]; then
  echo "Downloaded MLX models:"
  jq -r '
    to_entries[]
    | "\(.key + 1). \(.value.id)  \(.value.displayName)  \(((.value.sizeBytes / 1000000000) | tostring)[0:5])GB  tool=\(.value.trainedForToolUse)"
  ' "${CATALOG}"
  echo

  if [[ ! -t 0 ]]; then
    echo "ERROR: non-interactive mode requires MODEL=<model-key>." >&2
    exit 1
  fi

  read -r -p "Select model number or model key: " MODEL
fi

selected="$(
  jq -r --arg model "${MODEL}" '
    if ($model | test("^[0-9]+$")) then
      .[(($model | tonumber) - 1)].id // empty
    else
      [
        .[]
        | select(
            .id == $model
            or (.displayName | ascii_downcase) == ($model | ascii_downcase)
            or (.id | ascii_downcase | contains($model | ascii_downcase))
            or (.displayName | ascii_downcase | contains($model | ascii_downcase))
          )
      ]
      | if length == 1 then .[0].id else empty end
    end
  ' "${CATALOG}"
)"

if [[ -z "${selected}" ]]; then
  echo "ERROR: model selection is empty or ambiguous: ${MODEL}" >&2
  echo "Use one of:" >&2
  jq -r '.[].id' "${CATALOG}" >&2
  exit 1
fi

MODEL="${selected}" "${SCRIPT_DIR}/models-sync-omlx.sh"

echo
echo "==> Syncing Hermes model catalog"
if ! "${SCRIPT_DIR}/hermes-sync-models.sh"; then
  echo "warn Hermes sync failed. Run make e2e-ready after VM/Docker are ready." >&2
fi

echo
echo "Selected local model: ${selected}"
echo "Hermes can also inspect all served models through /v1/models."
