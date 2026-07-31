#!/usr/bin/env bash
# Install Rise as a real macOS app (Applications + login item).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LABEL="app.rise.menubar"
PLIST_DST="${HOME}/Library/LaunchAgents/${LABEL}.plist"
UID_NUM="$(id -u)"
DOMAIN="gui/${UID_NUM}"

# Prefer Applications; fall back to repo bin for dev
APPS_DIR="/Applications"
APP_INSTALL="${APPS_DIR}/Rise.app"
DEV_APP="$ROOT/bin/Rise.app"

echo "==> Rise install"
echo "    root: $ROOT"

bash "$ROOT/scripts/package-app.sh"

# Copy polished app into Applications for organic Finder experience
echo "    installing to $APP_INSTALL"
rm -rf "$APP_INSTALL"
cp -R "$ROOT/dist/Rise.app" "$APP_INSTALL"
xattr -cr "$APP_INSTALL" 2>/dev/null || true
codesign --force --deep --sign - "$APP_INSTALL" 2>/dev/null || true

BINARY="$APP_INSTALL/Contents/MacOS/Rise"
SUPPORT="${HOME}/Library/Application Support/Rise"
mkdir -p "$SUPPORT/data"
mkdir -p "${HOME}/Library/LaunchAgents"

if [[ ! -f "$SUPPORT/data/config.json" ]]; then
  if [[ -f "$ROOT/data/config.default.json" ]]; then
    cp "$ROOT/data/config.default.json" "$SUPPORT/data/config.json"
    echo "    seeded Application Support config"
  fi
fi

# CLI convenience wrapper in repo
cat > "$ROOT/bin/rise" << WRAP
#!/bin/bash
exec "$BINARY" "\$@"
WRAP
chmod +x "$ROOT/bin/rise"

# LaunchAgent → Applications Rise.app
cat > "$PLIST_DST" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>${LABEL}</string>
	<key>ProgramArguments</key>
	<array>
		<string>${BINARY}</string>
		<string>--menubar</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
	<key>KeepAlive</key>
	<true/>
	<key>ProcessType</key>
	<string>Interactive</string>
	<key>LimitLoadToSessionType</key>
	<string>Aqua</string>
	<key>WorkingDirectory</key>
	<string>${SUPPORT}</string>
	<key>StandardOutPath</key>
	<string>${SUPPORT}/data/rise-menubar.out.log</string>
	<key>StandardErrorPath</key>
	<string>${SUPPORT}/data/rise-menubar.err.log</string>
</dict>
</plist>
PLIST
echo "    installed $PLIST_DST"

if launchctl print "${DOMAIN}/${LABEL}" &>/dev/null; then
  echo "    unloading existing agent..."
  launchctl bootout "${DOMAIN}/${LABEL}" 2>/dev/null || true
  sleep 0.3
fi

echo "    clearing old menu bar processes..."
# shellcheck disable=SC2009
ps -axo pid=,args= | grep -E '[D]eskHealthOverlay --menubar|[/]Rise --menubar|[R]ise.app/Contents/MacOS/Rise' | awk '{print $1}' | while read -r pid; do
  kill "$pid" 2>/dev/null || true
done
sleep 0.4
rm -f "$ROOT/data/rise-menubar.lock" "$SUPPORT/data/rise-menubar.lock" 2>/dev/null || true

echo "    loading agent..."
launchctl bootout "${DOMAIN}/${LABEL}" 2>/dev/null || true
sleep 0.2
launchctl bootstrap "${DOMAIN}" "$PLIST_DST" 2>/dev/null \
  || launchctl load -w "$PLIST_DST" 2>/dev/null \
  || true
launchctl enable "${DOMAIN}/${LABEL}" 2>/dev/null || true
launchctl kickstart -k "${DOMAIN}/${LABEL}" 2>/dev/null || true
sleep 0.5

if pgrep -f 'Rise.app/Contents/MacOS/Rise' >/dev/null 2>&1; then
  echo "    Rise is running"
else
  echo "    starting Rise.app…"
  open -a "$APP_INSTALL" --args --menubar 2>/dev/null || true
fi

echo ""
echo "Rise is installed."
echo ""
echo "  App:     $APP_INSTALL"
echo "  Data:    $SUPPORT"
echo "  Zip:     $ROOT/dist/Rise-${VERSION:-1.1.0}.zip  (see dist/)"
echo ""
echo "Finder: Applications → Rise (sunrise icon). Menu bar starts at login."
echo "Location: Set Home / Set Office from the menu bar icon."
echo ""
echo "Uninstall: bash $ROOT/scripts/uninstall.sh"
