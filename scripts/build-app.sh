#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release --disable-sandbox --build-system native
APP="$PWD/dist/Stick.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
BIN_DIR="$(swift build -c release --show-bin-path --disable-sandbox --build-system native)"
cp "$BIN_DIR/Stick" "$APP/Contents/MacOS/Stick"
cp Resources/Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - --identifier dev.elijasms.stick "$APP"
printf 'Built %s\n' "$APP"
