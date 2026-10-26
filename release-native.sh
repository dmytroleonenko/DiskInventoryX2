#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
if [[ $# -ne 2 ]] || [[ ! "$1" =~ ^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] || [[ ! "$2" =~ ^[1-9][0-9]*$ ]]; then
    printf 'Usage: %s vX.Y.Z BUILD_NUMBER\n' "$0" >&2
    exit 2
fi
VERSION="${1#v}"
BUILD="$2"
APP_VERSION="$VERSION" APP_BUILD="$BUILD" "$ROOT/build-native.sh"
APP="$ROOT/build/Disk Inventory X2.app"
OUTPUT="$ROOT/build/release"
NAME="DiskInventoryX2-$VERSION-arm64"
mkdir -p "$OUTPUT"
codesign --verify --deep --strict "$APP"
test "$(plutil -extract CFBundleShortVersionString raw "$APP/Contents/Info.plist")" = "$VERSION"
test "$(plutil -extract CFBundleVersion raw "$APP/Contents/Info.plist")" = "$BUILD"
test "$(lipo -archs "$APP/Contents/MacOS/DiskInventoryX2")" = arm64
cp "$ROOT/build/Disk Inventory X2.dmg" "$OUTPUT/$NAME.dmg"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$OUTPUT/$NAME.app.zip"
(
    cd "$OUTPUT"
    shasum -a 256 "$NAME.dmg" "$NAME.app.zip" > SHA256SUMS.txt
    shasum -a 256 -c SHA256SUMS.txt
)
printf '\nRelease assets: %s\n' "$OUTPUT"
