#!/usr/bin/env bash
set -euo pipefail

RAG_BASE_URL="${RAG_BASE_URL:-http://rag-host.internal:8765}"
TOP_K="${RAG_TOP_K:-8}"
JSON_OUTPUT=0

usage() {
  cat >&2 <<EOF
Usage: rag-search [--json] [--top-k N] QUERY...
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --json)
      JSON_OUTPUT=1
      shift
      ;;
    --top-k)
      [[ $# -ge 2 ]] || {
        usage
        exit 2
      }
      TOP_K="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      break
      ;;
  esac
done

QUERY="$*"
[[ -n "${QUERY}" ]] || {
  usage
  exit 2
}

command -v curl >/dev/null 2>&1 || {
  echo "ERROR: curl is required" >&2
  exit 1
}

payload="$(jq -cn --arg query "${QUERY}" --argjson top_k "${TOP_K}" '{query:$query, top_k:$top_k}' 2>/dev/null || true)"
if [[ -z "${payload}" ]]; then
  escaped_query="$(printf '%s' "${QUERY}" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')"
  payload="{\"query\":${escaped_query},\"top_k\":${TOP_K}}"
fi

tmp_response="$(mktemp)"
http_status="$(curl -sS --max-time "${RAG_TIMEOUT_SECONDS:-15}" \
  -o "${tmp_response}" \
  -w '%{http_code}' \
  -H 'Content-Type: application/json' \
  -d "${payload}" \
  "${RAG_BASE_URL%/}/search" || true)"

response="$(cat "${tmp_response}")"
rm -f "${tmp_response}"

if [[ ! "${http_status}" =~ ^2 ]]; then
  echo "ERROR: RAG search failed: HTTP ${http_status}" >&2
  if [[ -n "${response}" ]]; then
    printf '%s\n' "${response}" >&2
  fi
  exit 1
fi

if [[ "${JSON_OUTPUT}" == "1" ]]; then
  printf '%s\n' "${response}"
  exit 0
fi

if command -v jq >/dev/null 2>&1; then
  printf '%s\n' "${response}" | jq -r '
    if (.results | length) == 0 then
      "No RAG results for: " + .query
    else
      "RAG results for: " + .query + "\n" +
      (.results | to_entries | map(
        "\n" + ((.key + 1) | tostring) + ". " + (.value.path // "") + " - " + (.value.heading // .value.title // "") +
        "\n   score: " + ((.value.score // 0) | tostring) +
        "\n   " + (.value.excerpt // "")
      ) | join("\n"))
    end'
else
  printf '%s\n' "${response}"
fi
