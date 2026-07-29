# Changelog

All notable changes to Cookie Monster are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/), and the project adheres to
[Semantic Versioning](https://semver.org/).

## [0.3.0] — 2026-07-29

### Added
- Redesigned dropdown: custom-drawn rounded progress bars with bold, color-coded
  percentages and cleaner spacing.
- Your signed-in **Claude account email** shown under the plan header.

### Changed
- New app bundle identifier (`com.pflugpeil.cookiemonster`).

### Fixed
- Menu-bar icon reliably reappears after relaunch/login — clears macOS's stale
  "removed" state on launch and forces the item visible.
- The account email now updates on refresh (was fetched only once).

## [0.2.1] — 2026-06-11

Maintenance release — **no app changes from 0.2.0.** Releases are now built
end-to-end through the automated Developer ID **sign + notarize** pipeline
(`release.sh` / the Release workflow), so downloads open with a normal
double-click. Also fixes a `release.sh` packaging bug that could pick up a stale
build artifact.

## [0.2.0] — 2026-06-11

### Added
- **Menu Bar Style** setting — **Default** (a monochrome gauge whose needle tracks
  your usage, in the native text color) or **Vibrant** (the 🍪 emoji with a
  green/orange/red percentage).
- **Pin to Menu Bar** setting — show **Session**, **Week**, or **Week (model)** in the bar.
- **Update Every** setting — configurable poll interval (30s / 1 / 2 / 5 / 15 min).
- App icon for Finder, the DMG, and the About box.

### Fixed
- The "Updated …" counter and the reset countdowns now refresh when the menu opens
  and **tick live every second** while the menu stays open (previously frozen at "0s ago").

## [0.1.0] — 2026-06-11

### Added
- Initial release: a native macOS menu-bar app showing your Claude 5-hour session
  and weekly usage with reset countdowns, read from the Claude Code OAuth token in
  the login keychain.
