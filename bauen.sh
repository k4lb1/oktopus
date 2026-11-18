#!/bin/bash
# Baut Oktopus.app nach ~/Applications. Der Build-Ordner liegt außerhalb von iCloud, sonst hängt der Build.
set -euo pipefail
cd "$(dirname "$0")"
BUILD="$HOME/Library/Caches/oktopus-build"
APP="$HOME/Applications/Oktopus.app"

swift build -c release --scratch-path "$BUILD"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BUILD/release/Oktopus" "$APP/Contents/MacOS/Oktopus"
cp Info.plist "$APP/Contents/Info.plist"
mkdir -p "$APP/Contents/Resources"
cp Oktopus.icns "$APP/Contents/Resources/Oktopus.icns"
codesign --force --sign - "$APP"
echo "$APP"
