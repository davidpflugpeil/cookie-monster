#!/bin/bash
# Build, install to ~/Applications, and launch Cookie Monster 🍪.
set -euo pipefail
cd "$(dirname "$0")"

./build.sh

DEST="$HOME/Applications"
mkdir -p "$DEST"
echo "› Installing to $DEST…"
rm -rf "$DEST/Cookie Monster.app"
cp -R "Cookie Monster.app" "$DEST/"

# Quit any running copy, then launch the installed one.
pkill -x CookieMonster 2>/dev/null || true
sleep 0.3
open "$DEST/Cookie Monster.app"

echo "✓ Cookie Monster is running — look for 🍪 in your menu bar."
echo "  First launch: macOS will ask to allow keychain access — click \"Always Allow\"."
echo "  Enable auto-start from the 🍪 menu → \"Start at Login\"."
