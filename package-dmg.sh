#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$ROOT/build/Disk Inventory X2.app"
OUTPUT="$ROOT/build/Disk Inventory X2.dmg"
VOLUME="Disk Inventory X2"

# Write Finder metadata directly: no Automation permission or timing-dependent UI work.
codesign --verify --strict "$APP"
TOOLS="$ROOT/build/.dmg-tools"
REQUIREMENTS="$ROOT/Packaging/requirements.txt"
if [[ ! -x "$TOOLS/bin/python3" ]]; then
    python3 -m venv "$TOOLS"
fi
if ! cmp -s "$REQUIREMENTS" "$TOOLS/requirements.installed"; then
    "$TOOLS/bin/python3" -m pip install --disable-pip-version-check -r "$REQUIREMENTS"
    cp "$REQUIREMENTS" "$TOOLS/requirements.installed"
fi

# Publish only a complete, checksum-verified image; keep the previous DMG on failure.
WORK="$(mktemp -d "$ROOT/build/.dmg.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
"$TOOLS/bin/dmgbuild" -s "$ROOT/Packaging/dmg-settings.py" \
    -D "app=$APP" -D "background=$ROOT/Packaging/background.png" \
    "$VOLUME" "$WORK/Distribution.dmg"
hdiutil verify "$WORK/Distribution.dmg"
mv -f "$WORK/Distribution.dmg" "$OUTPUT"
printf '\nDMG: %s\n' "$OUTPUT"
