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
# Explicit targets. Without them swiftc builds for the Mac it runs on — a binary built on
# macOS 27 refused to open on macOS 26 Tahoe, whatever Info.plist claimed — and for its CPU
# only. One universal binary, Intel + Apple silicon, for macOS 13 and later.
MIN_MACOS="13.0"
BUILD_TMP="$(mktemp -d)"
for ARCH in arm64 x86_64; do
    swiftc -O -target "$ARCH-apple-macos$MIN_MACOS" -framework AppKit \
        src/Core.swift src/App.swift -o "$BUILD_TMP/CookieMonster-$ARCH"
done
lipo -create "$BUILD_TMP/CookieMonster-arm64" "$BUILD_TMP/CookieMonster-x86_64" -output "$MACOS/CookieMonster"
rm -rf "$BUILD_TMP"

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
    <key>CFBundleVersion</key>          <string>0.8.1</string>
    <key>CFBundleShortVersionString</key><string>0.8.1</string>
    <key>CFBundlePackageType</key>      <string>APPL</string>
    <key>CFBundleIconFile</key>         <string>AppIcon</string>
    <key>LSMinimumSystemVersion</key>   <string>13.0</string>
    <key>LSUIElement</key>              <true/>
    <key>NSHumanReadableCopyright</key> <string>Cookie Monster — local Claude usage menu bar.</string>
</dict>
</plist>
PLIST

# Ad-hoc by default. Signing with a Developer ID uses a private key from the login keychain,
# which can itself raise a keychain dialog — so a plain build (by you, CI, or an agent) never
# touches it. Opt in with SIGN_IDENTITY="Developer ID Application: …" (release.sh does).
if [ -n "${SIGN_IDENTITY:-}" ]; then
    codesign --force --deep --options runtime --timestamp=none --sign "$SIGN_IDENTITY" "$APP" 2>/dev/null \
        && echo "  signed: $SIGN_IDENTITY" || echo "  (signing with $SIGN_IDENTITY failed)"
else
    codesign --force --deep --sign - "$APP" 2>/dev/null || echo "  (codesign skipped)"
fi

echo "✓ Built ./$APP"
