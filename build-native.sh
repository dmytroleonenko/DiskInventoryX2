#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$ROOT/build/Disk Inventory X2.app"
VERSION="${APP_VERSION:-$(plutil -extract CFBundleShortVersionString raw "$ROOT/Native/Info.plist")}"
BUILD="${APP_BUILD:-$(plutil -extract CFBundleVersion raw "$ROOT/Native/Info.plist")}"
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || [[ ! "$BUILD" =~ ^[1-9][0-9]*$ ]]; then
    printf 'Invalid APP_VERSION or APP_BUILD: expected X.Y.Z and a positive integer.\n' >&2
    exit 2
fi
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
SDK="$(xcrun --show-sdk-path)"
# Keep obsolete headers in /usr/local/include from shadowing the selected SDK.
printf '{"version":0,"roots":[{"type":"directory-remap","name":"/usr/local/include","external-contents":"%s/usr/include"}]}\n' "$SDK" > "$ROOT/build/sdk-overlay.json"
xcrun swiftc -swift-version 6 -O -target arm64-apple-macosx14.0 \
    -sdk "$SDK" -vfsoverlay "$ROOT/build/sdk-overlay.json" \
    -framework AppKit "$ROOT"/Native/*.swift \
    -o "$APP/Contents/MacOS/DiskInventoryX2"
cp "$ROOT/Native/Info.plist" "$APP/Contents/Info.plist"
plutil -replace CFBundleShortVersionString -string "$VERSION" "$APP/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$BUILD" "$APP/Contents/Info.plist"
cp "$ROOT/COPYING" "$APP/Contents/Resources/COPYING"
cp -R "$ROOT/Native/Resources/." "$APP/Contents/Resources/"
iconutil -c icns "$ROOT/Packaging/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP"
printf '\nBuilt: %s\n' "$APP"
file "$APP/Contents/MacOS/DiskInventoryX2"
"$ROOT/package-dmg.sh"
