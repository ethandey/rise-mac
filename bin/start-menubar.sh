#!/usr/bin/env bash
# Start Desk Health menu bar app (safe to re-run).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/bin/DeskHealthOverlay"

if [[ ! -x "$BIN" ]]; then
  echo "Building native app…"
  bash "$ROOT/native/build.sh"
fi

# If already running menubar instance, leave it
if pgrep -x DeskHealthOverlay >/dev/null 2>&1; then
  # Could be a one-shot test; only skip if menubar arg present is hard to detect.
  # Prefer single instance: kill one-shots is OK; for simplicity start another
  # only if none exist with --menubar in args.
  if ps -axo args= | grep -F 'DeskHealthOverlay --menubar' | grep -v grep >/dev/null 2>&1; then
    echo "Desk Health menu bar already running."
    exit 0
  fi
fi

nohup "$BIN" --menubar >/tmp/desk-health-menubar.log 2>&1 &
echo "Desk Health menu bar started (pid $!)."
echo "Look for the figure icon in the menu bar."
