#!/usr/bin/env bash
# Uninstall desk-health LaunchAgent (leaves data/ and config intact).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LABEL="com.ethan.desk-health"
PLIST_DST="${HOME}/Library/LaunchAgents/${LABEL}.plist"
UID_NUM="$(id -u)"
DOMAIN="gui/${UID_NUM}"

echo "==> desk-health uninstall"

if launchctl print "${DOMAIN}/${LABEL}" &>/dev/null; then
  echo "    stopping agent..."
  launchctl bootout "${DOMAIN}/${LABEL}" 2>/dev/null || true
else
  echo "    agent not loaded"
fi

if [[ -f "$PLIST_DST" ]]; then
  rm -f "$PLIST_DST"
  echo "    removed $PLIST_DST"
else
  echo "    no plist at $PLIST_DST"
fi

echo ""
echo "✓ desk-health LaunchAgent removed"
echo "  data/ and config left intact at: $ROOT/data"
echo "  reinstall with: bash $ROOT/bin/install.sh"
