#!/bin/zsh
# Build, install and launch MOMENT on the booted simulator. Usage: Tools/run_sim.sh [-demo] [-reset] [-uitest]
set -e
cd "$(dirname "$0")/.."
xcodebuild -project Moment.xcodeproj -scheme Moment -destination 'platform=iOS Simulator,name=iPhone 16 Pro' -configuration Debug build CODE_SIGNING_ALLOWED=NO -derivedDataPath build 2>&1 | grep -E "error:|BUILD" 
xcrun simctl boot "iPhone 16 Pro" 2>/dev/null || true
xcrun simctl install booted build/Build/Products/Debug-iphonesimulator/MOMENT.app
xcrun simctl launch --terminate-running-process booted com.rakshitbargotra.moment "$@"
