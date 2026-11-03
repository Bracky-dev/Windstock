#!/bin/bash
# The launcher's signing key. Made once and kept: Android only installs a new
# build over an old one when both carry the same certificate.
set -euo pipefail
cd "$(dirname "$0")"
[ -f windstock-launcher.jks ] && { echo "tools/windstock-launcher.jks already exists"; exit 0; }
keytool -genkeypair -keystore windstock-launcher.jks -storepass windstock -keypass windstock \
    -alias windstock -keyalg RSA -keysize 2048 -validity 36500 \
    -dname "CN=Windstock Launcher, O=Windstock"
