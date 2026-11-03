#!/bin/bash
# Lay out the embedded Python runtime under Staging/.
#
# Two things have to happen that a plain copy does not do:
#
#  1. The pure-Python stdlib is trimmed. Shipping all 50 MB means a slower
#     install for test suites, tkinter stubs and IDLE that can never run on a
#     phone.
#  2. Every C extension module is repackaged as a framework. iOS only
#     code-signs Mach-O files that live in Frameworks/ as a framework bundle,
#     and an unsigned .so is killed the moment dlopen touches it. ws_boot's
#     _FrameworkFinder is the other half of this trick.
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
XC="$HERE/Vendor/Python.xcframework"
STAGING="$HERE/Staging"
PYVER="3.13"

[ -d "$XC" ] || { echo "No $XC -- run tools/fetch_python.sh first." >&2; exit 1; }

echo "==> stdlib"
rm -rf "$STAGING/python-stdlib"
mkdir -p "$STAGING/python-stdlib"
cp -R "$XC/lib/python$PYVER/." "$STAGING/python-stdlib/"

# Nothing here can run on a phone, and together they are most of the size.
for junk in test tests idlelib tkinter turtledemo lib2to3 pydoc_data \
            ensurepip distutils config-* __pycache__; do
    rm -rf "$STAGING/python-stdlib/$junk"
done
find "$STAGING/python-stdlib" -name "__pycache__" -type d -exec rm -rf {} + 2>/dev/null || true
find "$STAGING/python-stdlib" -name "*.pyc" -delete 2>/dev/null || true
echo "    $(du -sh "$STAGING/python-stdlib" | cut -f1)"

stage_slice() {                    # stage_slice <xcframework-slice> <platform-name>
    local slice="$1" platform="$2"
    local dynload
    dynload="$(find "$XC/$slice" -type d -name lib-dynload | head -1)"
    if [ -z "$dynload" ]; then
        echo "    no lib-dynload in $slice, skipping"
        return
    fi

    local out="$STAGING/extensions/$platform"
    rm -rf "$out"
    mkdir -p "$out"

    local n=0
    for so in "$dynload"/*.so; do
        [ -e "$so" ] || continue
        # _ssl.cpython-313-iphoneos.so -> _ssl
        local module
        module="$(basename "$so")"
        module="${module%%.*}"

        # CPython's own test/demo modules. They cannot do anything useful on a
        # phone and each one is another framework to sign.
        case "$module" in
            xxlimited|xxlimited_35|xxsubtype|_test*|_xxtest*|_xxinterp*|_ctypes_test) continue ;;
        esac

        local fw="$out/$module.framework"
        mkdir -p "$fw"
        cp "$so" "$fw/$module"
        # A framework's own id should point at itself; the copied .so still
        # claims to be "Modules/<name>.so", which upsets some signers.
        install_name_tool -id "@rpath/$module.framework/$module" "$fw/$module" 2>/dev/null || true

        # A bundle identifier may only hold letters, digits and hyphens, so
        # "_codecs_kr" becomes "codecs-kr". The binary name has to stay exactly
        # the module name -- that is what the import looks for.
        local ident
        ident="$(printf '%s' "${module#_}" | tr '_' '-')"
        cat > "$fw/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key><string>$module</string>
	<key>CFBundleIdentifier</key><string>com.windstock.python.$ident</string>
	<key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
	<key>CFBundleName</key><string>$module</string>
	<key>CFBundlePackageType</key><string>FMWK</string>
	<key>CFBundleShortVersionString</key><string>$PYVER</string>
	<key>CFBundleVersion</key><string>1</string>
	<key>MinimumOSVersion</key><string>13.0</string>
</dict>
</plist>
PLIST
        n=$((n + 1))
    done
    echo "    $platform: $n extension frameworks"
}

echo "==> extension modules"
stage_slice "ios-arm64" "iphoneos"
stage_slice "ios-arm64_x86_64-simulator" "iphonesimulator"

echo "done. Staging/ is now $(du -sh "$STAGING" | cut -f1)"
