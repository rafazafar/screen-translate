#!/bin/zsh
# Builds build/ScreenTranslate.app. Set SIGN_ID to a codesigning identity name to keep the
# Screen Recording permission across rebuilds; otherwise it falls back to ad-hoc signing.
set -euo pipefail
cd "$(dirname "$0")"

APP=build/ScreenTranslate.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp Info.plist "$APP/Contents/Info.plist"

swiftc -O -swift-version 5 -target "$(uname -m)-apple-macos26.0" Sources/*.swift -o "$APP/Contents/MacOS/ScreenTranslate"

codesign --force --sign "${SIGN_ID:--}" "$APP"
echo "Built $APP"
