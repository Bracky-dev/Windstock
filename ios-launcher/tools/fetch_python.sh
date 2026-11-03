#!/bin/bash
# Download the CPython build the launcher embeds.
#
# Pinned on purpose: the server is a pile of 2016-era protocol code that has
# been made to work against one interpreter, and "whatever is newest" is not a
# thing you want to discover on a phone in a field.
set -euo pipefail

VERSION="3.13"
BUILD="b15"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
URL="https://github.com/beeware/Python-Apple-support/releases/download/${VERSION}-${BUILD}/Python-${VERSION}-iOS-support.${BUILD}.tar.gz"

if [ -d "$HERE/Vendor/Python.xcframework" ]; then
    echo "Vendor/Python.xcframework already there; delete it to re-download."
    exit 0
fi

mkdir -p "$HERE/Vendor"
echo "==> $URL"
curl -fL --progress-bar -o /tmp/python-ios-support.tar.gz "$URL"
tar xzf /tmp/python-ios-support.tar.gz -C "$HERE/Vendor"
rm -f /tmp/python-ios-support.tar.gz
echo "done: $HERE/Vendor/Python.xcframework"
