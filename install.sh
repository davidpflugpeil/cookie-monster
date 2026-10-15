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
echo "  It never shows keychain prompts by itself; if it can't read your sign-in, use the menu's \"Allow Keychain Access…\"."
echo "  Enable auto-start from the 🍪 menu → \"Start at Login\"."
