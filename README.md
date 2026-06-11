# Cookie Monster 🍪

A tiny native macOS menu-bar app that shows your **Claude subscription usage** —
the same numbers as Claude Code's "Plan usage limits" panel — right in your menu bar.

```
🍪 27%      ← your current 5-hour session usage, color-coded
```

Click it for the full breakdown:

```
Claude Max
────────────────────────────────────────────
Session     ███░░░░░░░  27%   resets in 3h 24m
Week        ███░░░░░░░  29%   resets in 5d 4h
Week Sonnet ░░░░░░░░░░   0%   resets in 5d 4h
────────────────────────────────────────────
Updated 12s ago
Refresh Now              ⌘R
Open Usage in Browser…
Start at Login            ✓
Quit Cookie Monster      ⌘Q
```

## Install

### Download (recommended)

1. Grab the latest **`Cookie-Monster-x.y.z.dmg`** from the
   [Releases page](https://github.com/davidpflugpeil/cookie-monster/releases).
2. Open the `.dmg` and drag **Cookie Monster** into **Applications**.
3. The app is **not notarized** (no paid Apple Developer account), so the first
   time you launch it, **right-click it → Open → Open** to get past Gatekeeper.
   After that it launches normally.
4. macOS will ask to allow keychain access — click **Always Allow**.
5. Enable auto-start from the 🍪 menu → **Start at Login**.

### Build from source

If you have the Xcode Command Line Tools (`xcode-select --install`), building
locally avoids Gatekeeper entirely:

```bash
git clone https://github.com/davidpflugpeil/cookie-monster
cd cookie-monster
./install.sh      # builds, installs to ~/Applications, and launches it
```

## How it works

- Reads your existing **Claude Code OAuth token** from the login keychain
  (`Claude Code-credentials`) at runtime.
- Polls the (undocumented) `https://api.anthropic.com/api/oauth/usage` endpoint
  every 60 seconds — the same endpoint that powers `/usage` inside Claude Code —
  with a `claude-code/<ver>` User-Agent and the `anthropic-beta: oauth-2025-04-20`
  header.
- Shows the 5-hour **session** window in the bar (green < 50%, orange < 80%,
  red ≥ 80%), with weekly windows in the dropdown.

It is **read-only on your credentials**: it never writes to the keychain, never
refreshes or modifies your token, and never logs the token or the raw API
response. A small diagnostic log (status codes + percentages only) is kept at
`~/.cookie-monster/cookie-monster.log`.

## Uninstall

```bash
./uninstall.sh
```

Removes the app, the login item, and the log directory. Your Claude credentials
are left untouched.

## Limitations

- **macOS 13+ only**, and requires a Claude subscription signed into Claude Code
  (Pro / Max / Team). It reports whatever account Claude Code is authenticated as.
- **Token refresh:** if the menu bar shows `🍪 ⚠` (red), your OAuth token
  expired — run `claude` once to refresh it, then click **Refresh Now**. Cookie
  Monster intentionally does not refresh tokens itself, to avoid ever touching
  your stored credentials.
- The usage endpoint is **undocumented** and may change without notice. If the
  numbers stop appearing, check the field names in [`src/Core.swift`](src/Core.swift)
  (`five_hour`, `seven_day`, `seven_day_opus`/`seven_day_sonnet`).

## Repo layout

| Path | What |
|------|------|
| [`src/Core.swift`](src/Core.swift) | Shared logic — keychain read, usage fetch, formatting |
| [`src/App.swift`](src/App.swift)   | The menu-bar UI (AppKit `NSStatusItem`) |
| [`build.sh`](build.sh)             | Compile the `.app` bundle |
| [`install.sh`](install.sh) / [`uninstall.sh`](uninstall.sh) | Install/remove to `~/Applications` |
| [`package.sh`](package.sh)         | Build a `.dmg` + `.zip` into `dist/` for releases |

## Disclaimer

This is an unofficial, community project. It is **not affiliated with, endorsed
by, or supported by Anthropic.** It relies on an undocumented endpoint that could
change or break at any time. Provided as-is under the [MIT License](LICENSE).
