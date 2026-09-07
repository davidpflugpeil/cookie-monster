#!/bin/bash
# Build a distributable .dmg (and .zip) of Cookie Monster 🍪 into ./dist.
# Uses only built-in tools (hdiutil, ditto) — no extra dependencies.
set -euo pipefail
cd "$(dirname "$0")"

VERSION="0.4.0"
APP="Cookie Monster.app"
DMG="dist/Cookie-Monster-${VERSION}.dmg"
ZIP="dist/Cookie-Monster-${VERSION}.zip"

# release.sh sets SKIP_BUILD=1 so it can package an already-signed/stapled app.
if [ "${SKIP_BUILD:-0}" != "1" ]; then ./build.sh; fi

echo "› Packaging…"
mkdir -p dist
rm -f "$DMG" "$ZIP"

# Zip (for folks who prefer a plain download).
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

# DMG with an Applications symlink for drag-to-install.
STAGING="$(mktemp -d)"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
hdiutil create -volname "Cookie Monster" -srcfolder "$STAGING" \
    -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGING"

echo "✓ Wrote:"
echo "    $DMG"
echo "    $ZIP"
shasum -a 256 "$DMG" "$ZIP"
