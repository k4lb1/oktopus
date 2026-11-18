#!/bin/bash
# Builds Oktopus.app, signs it with a Developer ID, notarizes it and packs dist/Oktopus.zip.
# Requires NOTARY_KEY (path to an App Store Connect .p8 key), NOTARY_KEY_ID and NOTARY_ISSUER.
set -euo pipefail
cd "$(dirname "$0")"
BUILD="$HOME/Library/Caches/oktopus-build"
APP="dist/Oktopus.app"
IDENTITY="${SIGN_IDENTITY:-Developer ID Application}"

swift build -c release --arch arm64 --arch x86_64 --scratch-path "$BUILD"
rm -rf dist
mkdir -p "$APP/Contents/MacOS"
cp "$BUILD/out/Products/Release/Oktopus" "$APP/Contents/MacOS/Oktopus"
cp Info.plist "$APP/Contents/Info.plist"
mkdir -p "$APP/Contents/Resources"
cp Oktopus.icns "$APP/Contents/Resources/Oktopus.icns"
xattr -cr "$APP"
codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"

ditto -c -k --keepParent "$APP" dist/notarize.zip
xcrun notarytool submit dist/notarize.zip --key "$NOTARY_KEY" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER" --wait
xcrun stapler staple "$APP"
rm dist/notarize.zip
ditto -c -k --norsrc --keepParent "$APP" dist/Oktopus.zip
echo dist/Oktopus.zip
