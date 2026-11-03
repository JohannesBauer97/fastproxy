#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app/Contents/Developer ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

# "-" keeps the local ad-hoc signing behavior. Release builds set this to a
# "Developer ID Application: ... (TEAMID)" identity imported into a keychain.
SIGNING_IDENTITY="${FASTPROXY_SIGNING_IDENTITY:--}"
if [[ "$SIGNING_IDENTITY" != "-" ]] && ! security find-identity -v -p codesigning | grep -Fq "\"$SIGNING_IDENTITY\""; then
  echo "error: code signing identity not found: $SIGNING_IDENTITY" >&2
  exit 1
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

# Allow release builds to stamp the version from the Git tag. The bundle is
# signed below, so the plist must be final before codesign runs.
if [[ -n "${FASTPROXY_VERSION:-}" ]]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $FASTPROXY_VERSION" "$APP/Contents/Info.plist"
fi
if [[ -n "${FASTPROXY_BUILD:-}" ]]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $FASTPROXY_BUILD" "$APP/Contents/Info.plist"
fi

if [[ -f "$ROOT/Resources/AppIcon.icns" ]]; then
  cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
  /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$APP/Contents/Info.plist" 2>/dev/null || true
fi

if [[ "$SIGNING_IDENTITY" == "-" ]]; then
  codesign --force --deep --sign - --timestamp=none "$APP" >/dev/null
else
  # Sign nested executables first, then the bundle. Hardened runtime and a
  # secure timestamp are required for notarization.
  codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" "$APP/Contents/MacOS/fastproxy-cli"
  codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" "$APP"
fi
touch "$APP"

echo "Built $APP"
echo "Install with: ./Scripts/install.sh"
