#!/usr/bin/env bash
# Build Rise.app (icon + Info.plist + binary) for local use and distribution.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/bin/Rise.app"
DIST="$ROOT/dist"
DIST_APP="$DIST/Rise.app"
MACOS="$APP/Contents/MacOS"
RES="$APP/Contents/Resources"
PLIST_SRC="$ROOT/native/Info.plist"
ICNS="$ROOT/assets/AppIcon/AppIcon.icns"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST_SRC" 2>/dev/null || echo "1.1.0")"

echo "==> Packaging Rise.app v${VERSION}"
(cd "$ROOT/native" && bash build.sh)

if [[ ! -f "$ICNS" ]]; then
  echo "error: missing icon $ICNS" >&2
  exit 1
fi

rm -rf "$APP"
mkdir -p "$MACOS" "$RES"
cp -f "$ROOT/bin/DeskHealthOverlay" "$MACOS/Rise"
chmod +x "$MACOS/Rise"

cp -f "$PLIST_SRC" "$APP/Contents/Info.plist"
cp -f "$ICNS" "$RES/AppIcon.icns"
# Optional default config for Application Support seed
if [[ -f "$ROOT/data/config.default.json" ]]; then
  cp -f "$ROOT/data/config.default.json" "$RES/config.default.json"
fi

/usr/libexec/PlistBuddy -c "Set :CFBundleExecutable Rise" "$APP/Contents/Info.plist" 2>/dev/null \
  || /usr/libexec/PlistBuddy -c "Add :CFBundleExecutable string Rise" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIconFile AppIcon" "$APP/Contents/Info.plist" 2>/dev/null \
  || /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$APP/Contents/Info.plist"

# Ad-hoc sign so TCC associates location + icon with this bundle
codesign --force --deep --sign - "$APP" 2>/dev/null || true

# Distribution copy + zip (drag into Applications)
mkdir -p "$DIST"
rm -rf "$DIST_APP"
cp -R "$APP" "$DIST_APP"
ZIP="$DIST/Rise-${VERSION}.zip"
rm -f "$ZIP"
(
  cd "$DIST"
  ditto -c -k --sequesterRsrc --keepParent "Rise.app" "Rise-${VERSION}.zip"
)

# Touch so Finder refreshes icon
touch "$APP" "$DIST_APP"

echo "    app:  $APP"
echo "    dist: $DIST_APP"
echo "    zip:  $ZIP"
echo "    install: bash scripts/install.sh"
echo "    or:      open $DIST && drag Rise.app to Applications"
