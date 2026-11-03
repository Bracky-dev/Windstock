#!/bin/sh
# Copy everything that is not compiled into the app bundle.
#
# Run from Xcode's "Stage bundle payload" phase. Deliberately tolerant: a
# missing piece prints a line and carries on, so you can build and run the
# launcher UI in the simulator long before the 170 MB guest is staged.
set -u

SRCROOT="${SRCROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
STAGING="$SRCROOT/Staging"
APP="${BUILT_PRODUCTS_DIR:-}/${CONTENTS_FOLDER_PATH:-}"
PLATFORM="${PLATFORM_NAME:-iphoneos}"

if [ -z "${BUILT_PRODUCTS_DIR:-}" ]; then
    echo "stage_payload: not running inside Xcode; nothing to do"
    exit 0
fi

echo "stage_payload: platform=$PLATFORM app=$APP"
mkdir -p "$APP/Frameworks"

copy_tree() {   # copy_tree <source> <dest-name>
    if [ ! -e "$1" ]; then
        echo "stage_payload: skipping $2 (no $1)"
        return
    fi
    rm -rf "$APP/$2"
    cp -R "$1" "$APP/$2"
    echo "stage_payload: staged $2"
}

# --- Python runtime ---------------------------------------------------------
copy_tree "$STAGING/python-stdlib" "python-stdlib"
copy_tree "$STAGING/PythonServer" "PythonServer"

# The C extension modules are per-platform: the simulator slice cannot load the
# device ones and vice versa.
EXT_DIR="$STAGING/extensions/$PLATFORM"
if [ -d "$EXT_DIR" ]; then
    count=0
    for fw in "$EXT_DIR"/*.framework; do
        [ -e "$fw" ] || continue
        rm -rf "$APP/Frameworks/$(basename "$fw")"
        cp -R "$fw" "$APP/Frameworks/"
        count=$((count + 1))
    done
    echo "stage_payload: staged $count Python extension frameworks"
else
    echo "stage_payload: skipping Python extensions (no $EXT_DIR)"
fi

# --- the game itself (device only; it is an arm64 iOS binary) ---------------
if [ "$PLATFORM" = "iphoneos" ]; then
    copy_tree "$STAGING/Guest" "Guest"
    if [ -d "$STAGING/Frameworks" ]; then
        for fw in "$STAGING/Frameworks"/*; do
            [ -e "$fw" ] || continue
            rm -rf "$APP/Frameworks/$(basename "$fw")"
            cp -R "$fw" "$APP/Frameworks/"
            echo "stage_payload: staged Frameworks/$(basename "$fw")"
        done
    else
        echo "stage_payload: skipping the guest app (no $STAGING/Frameworks)"
    fi
else
    echo "stage_payload: simulator build -- the guest game is device-only, skipped"
fi

# --- sign what we copied ----------------------------------------------------
# Xcode only signs what its own Embed phase copied. On a device build the
# sideload signer re-signs the whole bundle anyway, but an ad-hoc signature
# here keeps a local Xcode device run working.
if [ "${CODE_SIGNING_REQUIRED:-NO}" = "YES" ]; then
    IDENTITY="${EXPANDED_CODE_SIGN_IDENTITY:--}"
    find "$APP/Frameworks" -maxdepth 1 -name "*.framework" -print | while read -r fw; do
        codesign --force --sign "$IDENTITY" --timestamp=none "$fw" >/dev/null 2>&1 \
            || echo "stage_payload: could not sign $(basename "$fw")"
    done
    echo "stage_payload: signed staged frameworks with ${IDENTITY}"
fi

exit 0
