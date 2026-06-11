#!/bin/bash
# Build, sign (Developer ID), notarize, staple, and package Cookie Monster 🍪
# into a distributable .dmg + .zip that pass Gatekeeper with no warning.
#
# Requires (see NOTARIZATION.md):
#   SIGN_IDENTITY   e.g. "Developer ID Application: David Pflugpeil (Q737S2247S)"
#   NOTARY_PROFILE  a notarytool keychain profile (xcrun notarytool store-credentials …)
set -euo pipefail
cd "$(dirname "$0")"

: "${SIGN_IDENTITY:?Set SIGN_IDENTITY — see NOTARIZATION.md}"
: "${NOTARY_PROFILE:?Set NOTARY_PROFILE — see NOTARIZATION.md}"

APP="Cookie Monster.app"

echo "› Building…"
./build.sh

echo "› Signing app (Developer ID + hardened runtime)…"
codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP"
codesign --verify --strict --verbose=2 "$APP"

echo "› Notarizing app…"
mkdir -p dist
ditto -c -k --keepParent "$APP" dist/_notarize.zip
xcrun notarytool submit dist/_notarize.zip --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$APP"
rm -f dist/_notarize.zip

echo "› Packaging signed .dmg + .zip…"
rm -f dist/Cookie-Monster-*.dmg dist/Cookie-Monster-*.zip   # don't notarize stale builds
SKIP_BUILD=1 ./package.sh

echo "› Signing + notarizing + stapling the .dmg…"
DMG="$(ls dist/Cookie-Monster-*.dmg | head -1)"
codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG"

echo "› Gatekeeper assessment:"
spctl -a -vvv -t install "$DMG" 2>&1 || true

echo "✓ Signed, notarized, stapled → $DMG"
