#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

LAUNCHD_LABEL="${OMLX_LAUNCHD_LABEL:-com.omlx-to-client.omlx}"
UID_VALUE="$(id -u)"
was_running=0

if command -v launchctl >/dev/null 2>&1 && launchctl print "gui/${UID_VALUE}/${LAUNCHD_LABEL}" >/dev/null 2>&1; then
  echo "oMLX background service is running. Stopping it for upgrade..."
  "${SCRIPT_DIR}/model-stop-omlx-bg.sh"
  was_running=1
fi

echo "Updating oMLX via Homebrew..."
brew update

# Upgrade formula
if brew list --formula --versions jundot/omlx/omlx >/dev/null 2>&1; then
  if brew info jundot/omlx/omlx 2>/dev/null | grep -q 'with-grammar'; then
    echo "Upgrading oMLX with grammar support..."
    brew reinstall jundot/omlx/omlx --with-grammar
  else
    echo "Upgrading oMLX..."
    brew upgrade jundot/omlx/omlx
  fi
else
  echo "oMLX is not installed via brew. Installing it..."
  brew install jundot/omlx/omlx
fi

if [[ "${was_running}" -eq 1 ]]; then
  echo "Restarting oMLX background service..."
  "${SCRIPT_DIR}/model-start-omlx-bg.sh"
fi

echo "oMLX update complete!"
