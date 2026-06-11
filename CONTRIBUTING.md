# Contributing to Cookie Monster 🍪

Thanks for your interest! This is a small, single-purpose macOS app with no external
dependencies (AppKit + Foundation only), so it's easy to get into.

## Prerequisites
- macOS 13 or later
- Xcode Command Line Tools: `xcode-select --install` (provides `swiftc`)

## Build & run
```bash
./build.sh        # compile "Cookie Monster.app" (+ generate the icon)
./install.sh      # build, install to ~/Applications, and launch
./uninstall.sh    # remove the app, login item, and logs
./package.sh      # build a .dmg + .zip into dist/
```

## Project layout
| Path | What |
|------|------|
| `src/Core.swift`  | keychain read, usage fetch, formatting (Foundation only) |
| `src/App.swift`   | menu-bar UI (AppKit `NSStatusItem`) |
| `build.sh`        | compile the `.app` and generate `AppIcon.icns` |
| `package.sh`      | build the distributable `.dmg` / `.zip` |
| `assets/icon.png` | app-icon source |

## Making a release
1. Bump the version in `build.sh` (Info.plist), `package.sh`, and `src/Core.swift` (`kVersion`).
2. Update `CHANGELOG.md`.
3. `git tag vX.Y.Z && git push origin vX.Y.Z` — the **Release** workflow builds,
   signs, notarizes, and publishes the `.dmg`/`.zip`. See
   [NOTARIZATION.md](NOTARIZATION.md) for the required secrets (without them it
   builds unsigned). For a local notarized build, run `./release.sh`.

## Style
Match the surrounding code: small functions, no third-party dependencies, and keep
the keychain access **read-only** (see [SECURITY.md](SECURITY.md)).
