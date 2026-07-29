#!/usr/bin/env bash
# Build + install DeskHealthOverlay into ../bin
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"
swift build -c release
cp -f "$ROOT/.build/release/DeskHealthOverlay" "$ROOT/../bin/DeskHealthOverlay"
chmod +x "$ROOT/../bin/DeskHealthOverlay"
echo "installed: $ROOT/../bin/DeskHealthOverlay"
echo "menu bar:  $ROOT/../bin/start-menubar.sh"
echo "test all:  $ROOT/../bin/DeskHealthOverlay --test"
echo "install:   $ROOT/../scripts/install.sh  (login item: Rise)"

