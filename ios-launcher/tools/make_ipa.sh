#!/bin/bash
# Build an unsigned .ipa for Sideloadly / AltStore to sign and install.
#
#   tools/make_ipa.sh [output.ipa]
#
# Unsigned on purpose: Sideloadly re-signs the whole bundle with your Apple ID
# anyway, and a signature from here would only be thrown away. What matters is
# that every Mach-O is somewhere the signer looks -- Frameworks/ -- which is
# what embed_guest.sh and stage_python.sh arrange.
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-$HERE/build/WindstockLauncher.ipa}"
DD="$HERE/build/DerivedData"

mkdir -p "$(dirname "$OUT")"

# A build number testers can quote back to you ("20260921.1830").
BUILD="${BUILD:-$(date +%Y%m%d.%H%M)}"
# A separate app (tools/make_raids_ipa.sh): its own bundle id and home-screen name,
# so it installs next to the normal launcher instead of replacing it.
BUNDLE_ID="${BUNDLE_ID:-com.windstock.launcher}"
DISPLAY_NAME="${DISPLAY_NAME:-}"
echo "==> build $BUILD"

echo "==> building for device"
xcodebuild \
    -project "$HERE/WindstockLauncher.xcodeproj" \
    -scheme WindstockLauncher \
    -configuration Release \
    -sdk iphoneos \
    -derivedDataPath "$DD" \
    -destination 'generic/platform=iOS' \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGN_IDENTITY="" \
    CURRENT_PROJECT_VERSION="$BUILD" \
    PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID" \
    DEVELOPMENT_TEAM= \
    build
# The IPA is for OTHER people's Apple IDs, so it must not carry yours: the
# bundle id and team in signing.local are for Xcode builds to your own phone,
# and a free account cannot register an App ID another team already owns.

APP="$DD/Build/Products/Release-iphoneos/WindstockLauncher.app"
[ -d "$APP" ] || { echo "no app at $APP" >&2; exit 1; }

echo "==> packaging"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/Payload"
cp -R "$APP" "$WORK/Payload/"
# Signatures from this build would be replaced by the sideload signer; leaving
# them in only confuses it.
find "$WORK/Payload" -name "_CodeSignature" -type d -exec rm -rf {} + 2>/dev/null || true
# iPhone Duo gives full-screen layout only to apps linked against SDK 27.1+.
# The launcher hosts the game in-process, so this one binary covers both.
python3 "$HERE/tools/patch_sdk.py" "$WORK/Payload/WindstockLauncher.app/WindstockLauncher" --sdk "${DUO_SDK:-27.1}"
if [ -n "$DISPLAY_NAME" ]; then
    PL="$WORK/Payload/WindstockLauncher.app/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName $DISPLAY_NAME" "$PL" 2>/dev/null ||
        /usr/libexec/PlistBuddy -c "Add :CFBundleDisplayName string $DISPLAY_NAME" "$PL"
fi

rm -f "$OUT"
(cd "$WORK" && zip -qry "$OUT" Payload)

echo
echo "$OUT"
echo "$(du -h "$OUT" | cut -f1)"
echo
echo "Sideload it with Sideloadly or AltStore. Two things the app cannot do for"
echo "itself afterwards:"
echo "  1. Install the server's CA (Settings > Server > share ca.crt), then turn"
echo "     it on in Settings > General > About > Certificate Trust Settings."
echo "  2. Allow notifications when the launcher asks."
