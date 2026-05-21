#!/usr/bin/env bash
set -euo pipefail

ENV_FILE="${1:?env file required}"
KEY="${2:?key required}"
VALUE="${3:-}"

shell_quote() {
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

[[ -f "${ENV_FILE}" ]] || touch "${ENV_FILE}"

escaped_value="$(shell_quote "${VALUE}")"
tmp="$(mktemp)"

if grep -q "^${KEY}=" "${ENV_FILE}"; then
  awk -v key="${KEY}" -v value="${escaped_value}" '
    $0 ~ "^" key "=" {
      print key "=" value
      replaced = 1
      next
    }
    { print }
    END {
      if (replaced != 1) {
        print key "=" value
      }
    }
  ' "${ENV_FILE}" > "${tmp}"
else
  cp "${ENV_FILE}" "${tmp}"
  printf '%s=%s\n' "${KEY}" "${escaped_value}" >> "${tmp}"
fi

mv "${tmp}" "${ENV_FILE}"

