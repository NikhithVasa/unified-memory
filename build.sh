#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release
APP="$PWD/dist/Unified Memory.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$(swift build -c release --show-bin-path)/UnifiedMemory" "$APP/Contents/MacOS/UnifiedMemory"
cp Info.plist "$APP/Contents/Info.plist"
xcrun swift tools/CreateIcon.swift "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP"
echo "Built: $APP"
