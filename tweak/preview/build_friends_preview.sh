#!/bin/bash
# Build FriendsPreview.app for the simulator, install it on the booted one and launch it.
# Usage: ./build_friends_preview.sh [page]   (page: -1 switcher only, 0 list, 1 add, 2 requests, 3 friend)
set -e
cd "$(dirname "$0")"
PAGE=${1:-0}
OUT=build/FriendsPreview.app
mkdir -p "$OUT"
SDK=$(xcrun -sdk iphonesimulator --show-sdk-path)
xcrun -sdk iphonesimulator clang++ -fobjc-arc -x objective-c++ -std=c++17 -target arm64-apple-ios17.0-simulator \
  -isysroot "$SDK" -DFR_PREVIEW_PAGE=$PAGE FriendsPreview.mm -o "$OUT/FriendsPreview" \
  -framework UIKit -framework Foundation -framework AVFoundation -framework QuartzCore -framework CoreText \
  -framework CoreGraphics -framework WebKit -framework CoreImage
cat > "$OUT/Info.plist" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.windstock.friendspreview</string>
<key>CFBundleExecutable</key><string>FriendsPreview</string>
<key>CFBundleName</key><string>FriendsPreview</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>UILaunchScreen</key><dict/>
<key>NSAppTransportSecurity</key><dict><key>NSAllowsArbitraryLoads</key><true/></dict>
<key>UIApplicationSceneManifest</key><dict><key>UIApplicationSupportsMultipleScenes</key><false/></dict>
</dict></plist>
PL
codesign -f -s - "$OUT" >/dev/null 2>&1
xcrun simctl install booted "$OUT"
xcrun simctl terminate booted com.windstock.friendspreview 2>/dev/null || true
xcrun simctl launch booted com.windstock.friendspreview
