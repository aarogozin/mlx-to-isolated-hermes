#!/usr/bin/env bash
set -euo pipefail

if ! command -v launchctl >/dev/null 2>&1; then
  echo "launchctl is required on macOS." >&2
  exit 1
fi

LAUNCHD_LABEL="${OMLX_LAUNCHD_LABEL:-com.omlx-to-client.omlx}"
LAUNCHD_PLIST="${HOME}/Library/LaunchAgents/${LAUNCHD_LABEL}.plist"
UID_VALUE="$(id -u)"

if launchctl print "gui/${UID_VALUE}/${LAUNCHD_LABEL}" >/dev/null 2>&1; then
  if [[ -f "${LAUNCHD_PLIST}" ]]; then
    launchctl bootout "gui/${UID_VALUE}" "${LAUNCHD_PLIST}"
  else
    launchctl bootout "gui/${UID_VALUE}/${LAUNCHD_LABEL}"
  fi
  echo "Stopped oMLX launchd service: ${LAUNCHD_LABEL}"
else
  echo "oMLX launchd service is not running: ${LAUNCHD_LABEL}"
fi
