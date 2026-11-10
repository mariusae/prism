#!/bin/sh
# Builds Weft.app into build/. `scripts/build-app.sh run` also launches it;
# anything after `run` is passed to the app, e.g. `-GraphPath ~/notes`.
# The engine must be built first: ../../apple/build.sh.
set -e
cd "$(dirname "$0")/.."

swift build -c release --product WeftMac
app="build/Weft.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$(swift build -c release --show-bin-path)/WeftMac" "$app/Contents/MacOS/WeftMac"
cp Resources/Info.plist "$app/Contents/Info.plist"

# The GitHub App weft signs in through: its details from a file kept
# beside the iOS xcconfig and never committed. Read here, never printed.
# Weft's own file wins; else the GitHub App is Prism's, from reflect-mac.
# The relay is never taken from reflect-mac, whose relay is the old apps':
# it is the one named in iOS/GitHub.xcconfig, unless Weft's own file says.
own=iOS/GitHub.local.xcconfig
shared=../../../reflect-mac/iOS/GitHub.local.xcconfig
value_in() {
  [ -f "$1" ] || return 0
  sed -n "s/^[[:space:]]*$2[[:space:]]*=[[:space:]]*//p" "$1" | tail -1 | sed 's/[[:space:]]*$//'
}
for pair in GitHubClientID:GITHUB_CLIENT_ID GitHubClientSecret:GITHUB_CLIENT_SECRET \
            GitHubAppSlug:GITHUB_APP_SLUG SyncRelayHost:SYNC_RELAY_HOST; do
  name=${pair#*:}
  value=$(value_in "$own" "$name")
  if [ -z "$value" ]; then
    if [ "$name" = SYNC_RELAY_HOST ]; then value=$(value_in iOS/GitHub.xcconfig "$name"); else value=$(value_in "$shared" "$name"); fi
  fi
  /usr/libexec/PlistBuddy -c "Add :${pair%%:*} string $value" "$app/Contents/Info.plist" >/dev/null
done

# The icon is Icon Composer's (Resources/Icons/Weft.icon), compiled by
# Xcode's actool into Assets.car, which the bundle names.
if xcrun actool "$PWD/Resources/Icons/Weft.icon" --compile "$(cd "$app/Contents/Resources" && pwd)" --app-icon Weft \
     --platform macosx --minimum-deployment-target 26.0 --output-partial-info-plist "$PWD/build/icon-partial.plist" >/dev/null 2>&1 \
   && [ -f "$app/Contents/Resources/Assets.car" ]; then
  /usr/libexec/PlistBuddy -c "Add :CFBundleIconName string Weft" "$app/Contents/Info.plist"
fi
touch "$app"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$app" >/dev/null 2>&1 || true

# Signed with an Apple Development identity when there is one, so the
# keychain knows each build for the same app; else ad hoc.
identity=$(security find-identity -v -p codesigning 2>/dev/null | awk '/Apple Development/ { print $2; exit }')
if [ -z "$identity" ] || ! perl -e 'alarm 60; exec @ARGV' codesign --force --sign "$identity" "$app" >/dev/null 2>&1; then
  codesign --force --sign - "$app" >/dev/null 2>&1
fi
echo "built $app"

if [ "$1" = run ]; then
  shift
  pkill -x WeftMac 2>/dev/null || true
  open "$app" --args "$@"
fi
