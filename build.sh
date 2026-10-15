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

echo "› Building app icon…"
mkdir -p "$CONTENTS/Resources"
if [ -f assets/icon.png ]; then
    ICONSET="$(mktemp -d)/AppIcon.iconset"; mkdir -p "$ICONSET"
    for s in 16 32 128 256 512; do
        sips -z "$s" "$s"             assets/icon.png --out "$ICONSET/icon_${s}x${s}.png"    >/dev/null
        sips -z "$((s*2))" "$((s*2))" assets/icon.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
    done
    iconutil -c icns "$ICONSET" -o "$CONTENTS/Resources/AppIcon.icns"
    rm -rf "$(dirname "$ICONSET")"
fi

cat > "$CONTENTS/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>             <string>Cookie Monster</string>
    <key>CFBundleDisplayName</key>      <string>Cookie Monster</string>
    <key>CFBundleIdentifier</key>       <string>com.pflugpeil.cookiemonster</string>
    <key>CFBundleExecutable</key>       <string>CookieMonster</string>
    <key>CFBundleVersion</key>          <string>0.7.8</string>
    <key>CFBundleShortVersionString</key><string>0.7.8</string>
    <key>CFBundlePackageType</key>      <string>APPL</string>
    <key>CFBundleIconFile</key>         <string>AppIcon</string>
    <key>LSMinimumSystemVersion</key>   <string>13.0</string>
    <key>LSUIElement</key>              <true/>
    <key>NSHumanReadableCopyright</key> <string>Cookie Monster — local Claude usage menu bar.</string>
</dict>
</plist>
PLIST

# Sign with a Developer ID when one is available. An ad-hoc signature changes on every
# build, and macOS ties a keychain "Always Allow" to the signature — so ad-hoc builds would
# re-prompt for the Claude credentials after every rebuild. A Developer ID signature is
# anchored to the team, so the grant sticks. Falls back to ad-hoc for contributors.
DEV_ID="$(security find-identity -v -p codesigning 2>/dev/null \
          | sed -n 's/.*"\(Developer ID Application:[^"]*\)".*/\1/p' | head -1)"
if [ -n "$DEV_ID" ]; then
    codesign --force --deep --options runtime --timestamp=none --sign "$DEV_ID" "$APP" 2>/dev/null \
        && echo "  signed: $DEV_ID" || echo "  (Developer ID signing failed)"
else
    codesign --force --deep --sign - "$APP" 2>/dev/null || echo "  (codesign skipped)"
fi

echo "✓ Built ./$APP"
