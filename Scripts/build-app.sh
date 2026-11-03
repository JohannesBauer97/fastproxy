#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app/Contents/Developer ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

swift build -c release --product FastProxy
swift build -c release --product fastproxy-cli
BIN_DIR="$(swift build -c release --show-bin-path)"

APP="$ROOT/dist/FastProxy.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN_DIR/FastProxy" "$APP/Contents/MacOS/FastProxy"
cp "$BIN_DIR/fastproxy-cli" "$APP/Contents/MacOS/fastproxy-cli"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"

if [[ -f "$ROOT/Resources/AppIcon.icns" ]]; then
  cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
  /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$APP/Contents/Info.plist" 2>/dev/null || true
fi

codesign --force --deep --sign - --timestamp=none "$APP" >/dev/null
touch "$APP"

echo "Built $APP"
echo "Install with: ./Scripts/install.sh"
