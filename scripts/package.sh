#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
umask 077
swift build -c release
payday_bin_dir="$(swift build -c release --show-bin-path)"
payday_bundle="dist/Payday.app"
mkdir -p "$payday_bundle/Contents/MacOS" "$payday_bundle/Contents/Resources" dist/Payday.iconset
cp "$payday_bin_dir/Payday" "$payday_bundle/Contents/MacOS/Payday"
cp packaging/Info.plist "$payday_bundle/Contents/Info.plist"
swift scripts/create-icon.swift dist/Payday.iconset
iconutil -c icns dist/Payday.iconset -o "$payday_bundle/Contents/Resources/AppIcon.icns"
codesign --force --sign "${PAYDAY_SIGN_IDENTITY:--}" --options runtime "$payday_bundle"
codesign --verify --deep --strict "$payday_bundle"
printf 'Built %s\n' "$payday_bundle"
printf 'Open normally, or practice with: open dist/Payday.app --args --demo\n'
