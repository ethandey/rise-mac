#!/usr/bin/env bash
# Install Rise menu bar as LaunchAgent (login item) using Rise.app for Location TCC.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LABEL="app.rise.menubar"
PLIST_DST="${HOME}/Library/LaunchAgents/${LABEL}.plist"
APP="$ROOT/bin/Rise.app"
BINARY="$APP/Contents/MacOS/Rise"
UID_NUM="$(id -u)"
DOMAIN="gui/${UID_NUM}"

echo "==> Rise install"
echo "    root: $ROOT"

# Package .app (builds binary + embeds Info.plist for Location)
bash "$ROOT/scripts/package-app.sh"

mkdir -p "$ROOT/data"
mkdir -p "${HOME}/Library/LaunchAgents"

if [[ ! -f "$ROOT/data/config.json" ]]; then
  if [[ -f "$ROOT/data/config.default.json" ]]; then
    cp "$ROOT/data/config.default.json" "$ROOT/data/config.json"
    echo "    created data/config.json from config.default.json"
  fi
else
  echo "    data/config.json already present (left unchanged)"
fi

# Wrapper for CLI convenience
cat > "$ROOT/bin/rise" << WRAP
#!/bin/bash
exec "$BINARY" "\$@"
WRAP
chmod +x "$ROOT/bin/rise"

# LaunchAgent → Rise.app binary (needed for location permission dialog)
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
	<string>${ROOT}</string>
	<key>StandardOutPath</key>
	<string>${ROOT}/data/rise-menubar.out.log</string>
	<key>StandardErrorPath</key>
	<string>${ROOT}/data/rise-menubar.err.log</string>
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
rm -f "$ROOT/data/rise-menubar.lock"

echo "    loading agent..."
launchctl bootstrap "${DOMAIN}" "$PLIST_DST" 2>/dev/null || true
launchctl enable "${DOMAIN}/${LABEL}" 2>/dev/null || true
launchctl kickstart -k "${DOMAIN}/${LABEL}" 2>/dev/null || true

echo ""
echo "Rise is installed and will open at login."
echo ""
echo "  App:     $APP"
echo "  Binary:  $BINARY --menubar"
echo "  Logs:    $ROOT/data/rise-menubar.out.log"
echo ""
echo "Location: first “Set Home Here…” should show a permission dialog."
echo "If not: System Settings → Privacy & Security → Location Services → Rise"
echo ""
echo "Uninstall: bash $ROOT/scripts/uninstall.sh"
