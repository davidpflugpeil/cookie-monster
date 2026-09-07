# Changelog

All notable changes to Cookie Monster are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/), and the project adheres to
[Semantic Versioning](https://semver.org/).

## [0.4.0] — 2026-09-07

### Added
- **Codex subscription support.** Cookie Monster now reads the ChatGPT OAuth
  token the Codex CLI stores in `~/.codex/auth.json` (read-only, never rewritten)
  and polls `https://chatgpt.com/backend-api/codex/usage` for your Codex
  rate-limit windows. The dropdown gains a **Codex** section with your plan,
  account email, and one bar per window (`5h`, `Weekly`, …).
- **Pin to Menu Bar** now lists every window from *both* providers, grouped by
  subscription and annotated with its current percentage.
- **Click a usage row in the dropdown** to pin it to the menu bar. The pinned row
  is highlighted and tagged `PINNED`.
- Separate **Open Claude Usage…** / **Open Codex Usage…** items when both
  subscriptions are present.

### Changed
- Sections are shown only for tools actually installed on the Mac, so a
  Claude-only or Codex-only setup looks unchanged.
- Usage percentages in the dropdown are drawn in the label color (bold) instead
  of the severity color — the green was hard to read on the light menu material.
  The bars keep the green/orange/red coding.

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
