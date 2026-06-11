#!/bin/bash
# Build Cookie Monster 🍪 into a self-contained macOS .app bundle.
set -euo pipefail
cd "$(dirname "$0")"

APP="Cookie Monster.app"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"

echo "› Compiling…"
rm -rf "$APP"
mkdir -p "$MACOS"
swiftc -O -framework AppKit src/Core.swift src/App.swift -o "$MACOS/CookieMonster"

cat > "$CONTENTS/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>             <string>Cookie Monster</string>
    <key>CFBundleDisplayName</key>      <string>Cookie Monster</string>
    <key>CFBundleIdentifier</key>       <string>com.cookiemonster.usage</string>
    <key>CFBundleExecutable</key>       <string>CookieMonster</string>
    <key>CFBundleVersion</key>          <string>0.1.0</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundlePackageType</key>      <string>APPL</string>
    <key>LSMinimumSystemVersion</key>   <string>13.0</string>
    <key>LSUIElement</key>              <true/>
    <key>NSHumanReadableCopyright</key> <string>Cookie Monster — local Claude usage menu bar.</string>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$APP" 2>/dev/null || echo "  (codesign skipped)"

echo "✓ Built ./$APP"
