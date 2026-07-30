#!/usr/bin/env bash
# Install Rise menu bar app as a macOS LaunchAgent (login item).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LABEL="app.rise.menubar"
PLIST_SRC="$ROOT/launchd/${LABEL}.plist"
PLIST_DST="${HOME}/Library/LaunchAgents/${LABEL}.plist"
BINARY="$ROOT/bin/DeskHealthOverlay"
UID_NUM="$(id -u)"
DOMAIN="gui/${UID_NUM}"

echo "==> Rise install"
echo "    root: $ROOT"

# Build native binary if missing
if [[ ! -x "$BINARY" ]]; then
  echo "    building native DeskHealthOverlay..."
  if [[ ! -d "$ROOT/native" ]]; then
    echo "error: native/ not found at $ROOT/native" >&2
    exit 1
  fi
  (cd "$ROOT/native" && bash build.sh)
fi
chmod +x "$BINARY"

# Convenience wrapper
if [[ ! -x "$ROOT/bin/rise" ]]; then
  cat > "$ROOT/bin/rise" << 'WRAP'
#!/bin/bash
exec "$(dirname "$0")/DeskHealthOverlay" "$@"
WRAP
  chmod +x "$ROOT/bin/rise"
fi

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

if [[ ! -f "$PLIST_SRC" ]]; then
  echo "error: missing plist template at $PLIST_SRC" >&2
  exit 1
fi

# Generate LaunchAgent plist with absolute ROOT paths
# Template uses /Users/ethan/desk-health as placeholder; replace with actual ROOT
sed \
  -e "s|/Users/ethan/desk-health|${ROOT}|g" \
  "$PLIST_SRC" > "$PLIST_DST"
echo "    installed $PLIST_DST"

# Unload if already loaded
if launchctl print "${DOMAIN}/${LABEL}" &>/dev/null; then
  echo "    unloading existing agent..."
  launchctl bootout "${DOMAIN}/${LABEL}" 2>/dev/null || true
  sleep 0.3
fi

# Kill any stray menu bar copies (manual starts, old installs).
# Only match the real binary name — never a shell that merely mentions it.
echo "    clearing duplicate menu bar processes..."
# shellcheck disable=SC2009
ps -axo pid=,args= | grep '[D]eskHealthOverlay --menubar' | awk '{print $1}' | while read -r pid; do
  kill "$pid" 2>/dev/null || true
done
sleep 0.4
rm -f "$ROOT/data/rise-menubar.lock"

echo "    loading agent..."
launchctl bootstrap "${DOMAIN}" "$PLIST_DST" 2>/dev/null || launchctl load "$PLIST_DST" 2>/dev/null || true
launchctl enable "${DOMAIN}/${LABEL}" 2>/dev/null || true
launchctl kickstart -k "${DOMAIN}/${LABEL}" 2>/dev/null || true

echo ""
echo "Rise is installed and will open at login."
echo ""
echo "Look for the figure / break icon in the menu bar."
echo "  Binary:  $BINARY --menubar"
echo "  Config:  $ROOT/data/config.json"
echo "  Logs:    $ROOT/data/rise-menubar.out.log"
echo "           $ROOT/data/rise-menubar.err.log"
echo ""
echo "Uninstall: bash $ROOT/scripts/uninstall.sh"
