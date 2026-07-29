#!/usr/bin/env bash
# Uninstall Rise LaunchAgent (leaves data/ and config intact).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LABEL="app.rise.menubar"
PLIST_DST="${HOME}/Library/LaunchAgents/${LABEL}.plist"
UID_NUM="$(id -u)"
DOMAIN="gui/${UID_NUM}"

echo "==> Rise uninstall"

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
echo "✓ Rise login item removed"
echo "  data/ and config left intact at: $ROOT/data"
echo ""
echo "To remove the login item fully:"
echo "  • This script already unloaded app.rise.menubar from launchd."
echo "  • If it still appears under System Settings → General → Login Items,"
echo "    remove “Rise” / DeskHealthOverlay there as well."
echo ""
echo "  reinstall with: bash $ROOT/scripts/install.sh"
