#!/bin/bash
set -euo pipefail

APP="$HOME/Applications/FastProxy.app"
PLIST="$HOME/Library/LaunchAgents/com.johannesbauer.fastproxy.plist"

launchctl bootout "gui/$(id -u)/com.johannesbauer.fastproxy" 2>/dev/null || true
rm -f "$PLIST"
pkill -f "$APP/Contents/MacOS/FastProxy" 2>/dev/null || true
sleep 0.5
rm -rf "$APP"

if [[ "${1:-}" == "--purge" ]]; then
  rm -rf "$HOME/Library/Application Support/FastProxy"
fi

echo "FastProxy uninstalled."
