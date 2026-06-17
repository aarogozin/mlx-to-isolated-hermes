#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
QUERY="$*"
TOP_K="${RAG_WHY_TOP_K:-${RAG_TOP_K:-8}}"

if [[ -z "${QUERY}" ]]; then
  echo 'Usage: rag-why "your query"' >&2
  exit 2
fi

command -v jq >/dev/null 2>&1 || {
  echo "ERROR: jq is required for rag-why" >&2
  exit 1
}

json="$("${SCRIPT_DIR}/rag-control.sh" search --json "${QUERY}")"

printf '%s\n' "${json}" | jq -r --arg query "${QUERY}" --argjson top_k "${TOP_K}" '
  def short_text:
    (.excerpt // .text // "")
    | gsub("[[:space:]]+"; " ")
    | if length > 420 then .[0:420] + "..." else . end;

  "RAG explanation for: " + $query,
  ("results=" + ((.results | length) | tostring)),
  "",
  (
    .results[0:$top_k]
    | to_entries[]
    | .value as $r
    | [
        ((.key + 1) | tostring) + ". " + ($r.path // "(unknown path)"),
        "   score=" + (($r.score // 0) | tostring) +
          " source_type=" + ($r.source_type // "unknown") +
          " extractor=" + ($r.extractor // "unknown") +
          " ocr_used=" + (($r.ocr_used // false) | tostring) +
          " chunk=" + (($r.chunk_index // 0) | tostring),
        (
          if ($r.mtime // 0) > 0
          then "   source_mtime_epoch=" + (($r.mtime // 0) | tostring)
          else empty
          end
        ),
        "   excerpt: " + ($r | short_text),
        ""
      ]
      | .[]
  )
'
