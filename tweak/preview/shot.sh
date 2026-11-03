#!/bin/bash
# Rebuild FriendsPreview for one page and relaunch it on the iPhone 17e simulator. The app must
# have been installed once (simctl install); after that the binary is swapped in place, which
# is seconds instead of minutes.  Usage: ./shot.sh [page]  (-1 switcher, 0 list, 1 add, 2 requests, 3 friend)
set -e
cd "$(dirname "$0")"
P=${1:-0}; DEV=15CC72D9-8618-4926-A020-C53B19F15A93; ID=com.windstock.friendspreview
SDK=$(xcrun -sdk iphonesimulator --show-sdk-path)
xcrun -sdk iphonesimulator clang++ -fobjc-arc -x objective-c++ -std=c++17 -target arm64-apple-ios17.0-simulator \
  -isysroot "$SDK" -DFR_PREVIEW_PAGE=$P FriendsPreview.mm -o build/FriendsPreview.app/FriendsPreview \
  -framework UIKit -framework Foundation -framework AVFoundation -framework QuartzCore -framework CoreText \
  -framework CoreGraphics -framework WebKit -framework CoreImage
APP=$(xcrun simctl get_app_container $DEV $ID)
cp build/FriendsPreview.app/FriendsPreview "$APP/FriendsPreview"
codesign -f -s - "$APP" >/dev/null 2>&1
xcrun simctl terminate $DEV $ID 2>/dev/null || true
xcrun simctl launch $DEV $ID >/dev/null
sleep 4
