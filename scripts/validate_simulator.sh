#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
DEVICE_ID="${1:-F79457A2-9EAF-4585-850A-8B30BAFC8013}"
cd "$ROOT"
xcodegen generate
xcodebuild -project DJIVLNiOS.xcodeproj -scheme DJIVLNiOS \
  -destination "platform=iOS Simulator,id=$DEVICE_ID" \
  -derivedDataPath build test
xcrun simctl install "$DEVICE_ID" build/Build/Products/Debug-iphonesimulator/DJIVLNiOS.app
xcrun simctl launch --terminate-running-process "$DEVICE_ID" com.openfly.go
