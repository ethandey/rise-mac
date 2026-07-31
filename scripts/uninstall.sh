#!/usr/bin/env bash
# Uninstall Rise LaunchAgent (optional: remove /Applications/Rise.app).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LABEL="app.rise.menubar"
PLIST_DST="${HOME}/Library/LaunchAgents/${LABEL}.plist"
UID_NUM="$(id -u)"
DOMAIN="gui/${UID_NUM}"
APP_INSTALL="/Applications/Rise.app"
SUPPORT="${HOME}/Library/Application Support/Rise"

echo "==> Rise uninstall"

if launchctl print "${DOMAIN}/${LABEL}" &>/dev/null; then
  echo "    stopping agent..."
  launchctl bootout "${DOMAIN}/${LABEL}" 2>/dev/null || true
else
  echo "    agent not loaded"
fi

# shellcheck disable=SC2009
ps -axo pid=,args= | grep -E '[R]ise.app/Contents/MacOS/Rise|[D]eskHealthOverlay --menubar' | awk '{print $1}' | while read -r pid; do
  kill "$pid" 2>/dev/null || true
done

if [[ -f "$PLIST_DST" ]]; then
  rm -f "$PLIST_DST"
  echo "    removed $PLIST_DST"
else
  echo "    no plist at $PLIST_DST"
fi

if [[ -d "$APP_INSTALL" ]]; then
  rm -rf "$APP_INSTALL"
  echo "    removed $APP_INSTALL"
fi

echo ""
echo "✓ Rise login item and Applications app removed"
echo "  Preferences left at: $SUPPORT"
echo "  Repo data (if any):  $ROOT/data"
echo ""
echo "  reinstall with: bash $ROOT/scripts/install.sh"
echo "  or drag dist/Rise.app into Applications"
