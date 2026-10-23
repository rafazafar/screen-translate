#!/bin/zsh
# Builds build/ScreenTranslate.app. Signs with $SIGN_ID, else the first "Apple Development" identity in
# the keychain, else ad-hoc. A stable identity keeps the Screen Recording permission across rebuilds;
# ad-hoc signatures change on every build so macOS asks again each time.
set -euo pipefail
cd "$(dirname "$0")"

APP=build/ScreenTranslate.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp Info.plist "$APP/Contents/Info.plist"

swiftc -O -swift-version 5 -target "$(uname -m)-apple-macos26.0" Sources/*.swift -o "$APP/Contents/MacOS/ScreenTranslate"

SIGN_ID="${SIGN_ID:-$(security find-identity -v -p codesigning | sed -n 's/.*"\(Apple Development:[^"]*\)".*/\1/p' | head -1)}"
codesign --force --sign "${SIGN_ID:--}" "$APP"
echo "Signed with: ${SIGN_ID:-ad-hoc}"
echo "Built $APP"
