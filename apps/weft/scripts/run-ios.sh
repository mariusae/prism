#!/bin/sh
# Builds Weft for the iOS Simulator and runs it in the booted one.
#   scripts/run-ios.sh                 # the app as it is: the welcome, or the graph brought down before
#   scripts/run-ios.sh /path/to/graph  # on a folder of notes, to try it out (no sign-in, no sync)
# The engine must be built first: ../../apple/build.sh.
set -e
cd "$(dirname "$0")/.."
DERIVED="${WEFT_DERIVED:-build/ios}"
xcodebuild -project iOS/Weft.xcodeproj -scheme Weft -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath "$DERIVED" -skipPackagePluginValidation CODE_SIGNING_ALLOWED=NO ARCHS=arm64 build 2>&1 | grep -E "error:|warning: unre|BUILD" | sort -u
app="$DERIVED/Build/Products/Debug-iphonesimulator/Weft.app"
xcrun simctl install booted "$app"
xcrun simctl terminate booted org.mutable.weft 2>/dev/null || true
if [ -n "$1" ]; then
  xcrun simctl launch booted org.mutable.weft -GraphPath "$1"
else
  xcrun simctl launch booted org.mutable.weft
fi
