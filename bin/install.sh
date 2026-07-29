#!/usr/bin/env bash
# Install desk-health as a macOS LaunchAgent.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LABEL="com.ethan.desk-health"
PLIST_SRC="$ROOT/launchd/${LABEL}.plist"
PLIST_DST="${HOME}/Library/LaunchAgents/${LABEL}.plist"
UID_NUM="$(id -u)"
DOMAIN="gui/${UID_NUM}"

echo "==> desk-health install"
echo "    root: $ROOT"

# Data directory + default config
mkdir -p "$ROOT/data"
mkdir -p "${HOME}/Library/LaunchAgents"

if [[ ! -f "$ROOT/data/config.json" ]]; then
  if [[ -f "$ROOT/data/config.default.json" ]]; then
    cp "$ROOT/data/config.default.json" "$ROOT/data/config.json"
    echo "    created data/config.json from config.default.json"
  elif [[ -f "$ROOT/config.default.json" ]]; then
    cp "$ROOT/config.default.json" "$ROOT/data/config.json"
    echo "    created data/config.json from config.default.json"
  else
    echo "    note: no config.default.json found; create data/config.json when ready"
  fi
else
  echo "    data/config.json already present (left unchanged)"
fi

# Ensure scripts and daemon are executable
chmod +x "$ROOT/bin/install.sh" "$ROOT/bin/uninstall.sh" "$ROOT/bin/desk-health-ctl" 2>/dev/null || true
if [[ -f "$ROOT/bin/desk_health.py" ]]; then
  chmod +x "$ROOT/bin/desk_health.py"
fi

if [[ ! -f "$PLIST_SRC" ]]; then
  echo "error: missing plist at $PLIST_SRC" >&2
  exit 1
fi

# Install LaunchAgent plist
cp "$PLIST_SRC" "$PLIST_DST"
echo "    installed $PLIST_DST"

# Unload if already loaded, then bootstrap (modern launchctl)
if launchctl print "${DOMAIN}/${LABEL}" &>/dev/null; then
  echo "    unloading existing agent..."
  launchctl bootout "${DOMAIN}/${LABEL}" 2>/dev/null || true
fi

echo "    loading agent..."
launchctl bootstrap "${DOMAIN}" "$PLIST_DST"
# Ensure it is kicked if RunAtLoad did not already start it
launchctl enable "${DOMAIN}/${LABEL}" 2>/dev/null || true
launchctl kickstart -k "${DOMAIN}/${LABEL}" 2>/dev/null || true

echo ""
echo "✓ desk-health installed and started"
echo ""
echo "Usage:"
echo "  $ROOT/bin/desk-health-ctl status"
echo "  $ROOT/bin/desk-health-ctl stop|start|restart"
echo "  $ROOT/bin/desk-health-ctl pause|resume|snooze [mins]|once [A|B|C]|test"
echo ""
echo "Config:  $ROOT/data/config.json"
echo "Logs:    $ROOT/data/launchd.out.log"
echo "         $ROOT/data/launchd.err.log"
echo ""
echo "Uninstall: bash $ROOT/bin/uninstall.sh"
echo ""
echo "Note: first run may prompt for notification permissions"
echo "(Script Editor / osascript / Terminal). Allow them so alerts appear."
