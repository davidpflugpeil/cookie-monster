#!/bin/bash
# Remove Cookie Monster 🍪 completely.
set -euo pipefail

echo "› Stopping…"
launchctl bootout "gui/$(id -u)/com.cookiemonster.usage" 2>/dev/null || true
pkill -x CookieMonster 2>/dev/null || true

echo "› Removing files…"
rm -f "$HOME/Library/LaunchAgents/com.cookiemonster.usage.plist"
rm -rf "$HOME/Applications/Cookie Monster.app"
rm -rf "$HOME/.cookie-monster"

echo "✓ Uninstalled. (Your Claude keychain credentials were not touched.)"
