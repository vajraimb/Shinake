#!/bin/bash
# Build and test Shinake for the iOS Simulator.
# Usage: ios/build-simulator.sh
#        ios/build-simulator.sh 'platform=iOS Simulator,name=iPhone 17 Pro'
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DESTINATION="${1:-platform=iOS Simulator,name=iPhone 17 Pro}"
cd "$ROOT"

xcodebuild \
  -project ios/Shinake.xcodeproj \
  -scheme Shinake \
  -destination "$DESTINATION" \
  -configuration Debug \
  build

xcodebuild \
  -project ios/Shinake.xcodeproj \
  -scheme Shinake \
  -destination "$DESTINATION" \
  -configuration Debug \
  test
