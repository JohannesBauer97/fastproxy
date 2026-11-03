#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE="$ROOT/dist/FastProxy.app"
DESTINATION="$HOME/Applications/FastProxy.app"

if [[ ! -d "$SOURCE" ]]; then
  echo "Build the app first: ./Scripts/build-app.sh" >&2
  exit 1
fi

mkdir -p "$HOME/Applications"
pkill -f "$DESTINATION/Contents/MacOS/FastProxy" 2>/dev/null || true
sleep 0.5
rm -rf "$DESTINATION"
cp -R "$SOURCE" "$DESTINATION"
xattr -dr com.apple.quarantine "$DESTINATION" 2>/dev/null || true

# Enable the per-user LaunchAgent so the menu bar app comes back after the
# next login.
"$DESTINATION/Contents/MacOS/fastproxy-cli" --install-login-item "$DESTINATION" >/dev/null
open "$DESTINATION"

echo "Installed $DESTINATION"
echo "Launch at login: enabled"
echo "Configuration and logs: ~/Library/Application Support/FastProxy"
