#!/usr/bin/env bash
set -euo pipefail

LMS_BIN="${HOME}/.lmstudio/bin/lms"
if [[ ! -x "${LMS_BIN}" ]]; then
  LMS_BIN="$(command -v lms)"
fi

"${LMS_BIN}" ls --json | jq -r '
  ["MODEL KEY", "TYPE", "FORMAT", "SIZE", "TOOL", "PATH"],
  (
    .[]
    | select(.type == "llm")
    | [
        .modelKey,
        .type,
        .format,
        ((.sizeBytes / 1000000000) | tostring | .[0:5] + "GB"),
        ((.trainedForToolUse // false) | tostring),
        .path
      ]
  )
  | @tsv
' | column -t -s $'\t'

