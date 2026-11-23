#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release
product="$(swift build -c release --show-bin-path)/DeskCalendar"
bundle="$PWD/dist/桌面待办日历.app"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
install -m 755 "$product" "$bundle/Contents/MacOS/DeskCalendar"
cp Info.plist "$bundle/Contents/Info.plist"
cp Resources/AppIcon.icns "$bundle/Contents/Resources/AppIcon.icns"
codesign --force --sign - --identifier local.deskcalendar.app "$bundle"
codesign --verify --strict "$bundle"
printf '%s\n' "$bundle"
