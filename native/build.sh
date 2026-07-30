#!/usr/bin/env bash
# Build + install DeskHealthOverlay into ../bin (with location Info.plist)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"
PLIST="$ROOT/Info.plist"

# Embed Info.plist so Core Location usage strings are available
swift build -c release \
  -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker "$PLIST"

cp -f "$ROOT/.build/release/DeskHealthOverlay" "$ROOT/../bin/DeskHealthOverlay"
xattr -cr "$ROOT/../bin/DeskHealthOverlay" 2>/dev/null || true
chmod +x "$ROOT/../bin/DeskHealthOverlay"
echo "installed: $ROOT/../bin/DeskHealthOverlay"
echo "install:   $ROOT/../scripts/install.sh  (login item: Rise)"
