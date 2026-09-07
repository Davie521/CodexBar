#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
swift build -c release --product CodexBarLite
BIN_DIR="$(swift build -c release --show-bin-path)"
APP_PATH="$ROOT_DIR/CodexBar Lite.app"
mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources"
install -m 755 "$BIN_DIR/CodexBarLite" "$APP_PATH/Contents/MacOS/CodexBarLite"
cp Resources/Lite-Info.plist "$APP_PATH/Contents/Info.plist"
cp Sources/CodexBar/Resources/Icon-classic.icns "$APP_PATH/Contents/Resources/Icon.icns"
cp LICENSE "$APP_PATH/Contents/Resources/LICENSE"
codesign --force --sign - "$APP_PATH"
codesign --verify --deep --strict "$APP_PATH"
du -sh "$APP_PATH"
printf 'Built: %s\n' "$APP_PATH"
