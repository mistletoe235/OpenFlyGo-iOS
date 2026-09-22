#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
DEVICE_ID="${1:-F79457A2-9EAF-4585-850A-8B30BAFC8013}"
cd "$ROOT"
xcodegen generate
pod install --no-repo-update
xcodebuild -workspace DJIVLNiOS.xcworkspace -scheme DJIVLNiOS \
  -destination "platform=iOS Simulator,id=$DEVICE_ID" \
  -derivedDataPath build test
APP="build/Build/Products/Debug-iphonesimulator/DJIVLNiOS.app"
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Info.plist")"
xcrun simctl install "$DEVICE_ID" "$APP"
xcrun simctl launch --terminate-running-process "$DEVICE_ID" "$BUNDLE_ID"
