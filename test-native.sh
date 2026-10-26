#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/dix-tree-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
SDK="$(xcrun --show-sdk-path)"
printf '{"version":0,"roots":[{"type":"directory-remap","name":"/usr/local/include","external-contents":"%s/usr/include"}]}\n' "$SDK" > "$WORK/sdk-overlay.json"
SOURCES=()
for source in "$ROOT"/Native/*.swift; do
    case "$source" in */InventoryApplication.swift) continue ;; esac
    SOURCES+=("$source")
done
xcrun swiftc -swift-version 6 -O -parse-as-library -target arm64-apple-macosx14.0 \
    -sdk "$SDK" -vfsoverlay "$WORK/sdk-overlay.json" -framework AppKit \
    "${SOURCES[@]}" "$ROOT"/Tests/*.swift -o "$WORK/deletion-tree-state"
"$WORK/deletion-tree-state" "$@"
