#!/usr/bin/env bash
# Build Rise.app so macOS Location Services can prompt (TCC needs a real .app).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/bin/Rise.app"
MACOS="$APP/Contents/MacOS"
RES="$APP/Contents/Resources"
PLIST_SRC="$ROOT/native/Info.plist"

echo "==> Packaging Rise.app"
(cd "$ROOT/native" && bash build.sh)

rm -rf "$APP"
mkdir -p "$MACOS" "$RES"
cp -f "$ROOT/bin/DeskHealthOverlay" "$MACOS/Rise"
chmod +x "$MACOS/Rise"

# Info.plist for the app bundle (location usage + LSUIElement)
cp -f "$PLIST_SRC" "$APP/Contents/Info.plist"
# Executable name must match
/usr/libexec/PlistBuddy -c "Set :CFBundleExecutable Rise" "$APP/Contents/Info.plist" 2>/dev/null \
  || /usr/libexec/PlistBuddy -c "Add :CFBundleExecutable string Rise" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier app.rise.menubar" "$APP/Contents/Info.plist" 2>/dev/null || true

# Ad-hoc sign so TCC associates location with this bundle
codesign --force --deep --sign - "$APP" 2>/dev/null || true

echo "    created $APP"
echo "    run: open -a $APP --args --menubar"
echo "         or: $MACOS/Rise --menubar"
