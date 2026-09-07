# Cookie Monster 🍪

<img src="assets/icon.png" width="104" align="right" alt="Cookie Monster app icon"/>

[![Build](https://img.shields.io/github/actions/workflow/status/davidpflugpeil/cookie-monster/ci.yml?branch=main&label=build)](https://github.com/davidpflugpeil/cookie-monster/actions/workflows/ci.yml)
[![Latest release](https://img.shields.io/github/v/release/davidpflugpeil/cookie-monster?sort=semver&cacheSeconds=3600)](https://github.com/davidpflugpeil/cookie-monster/releases/latest)
[![Downloads](https://img.shields.io/github/downloads/davidpflugpeil/cookie-monster/total?cacheSeconds=3600)](https://github.com/davidpflugpeil/cookie-monster/releases)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue)](LICENSE)
![Platform](https://img.shields.io/badge/platform-macOS%2013%2B-blue)
![Swift](https://img.shields.io/badge/Swift-6-orange?logo=swift&logoColor=white)
[![PRs welcome](https://img.shields.io/badge/PRs-welcome-brightgreen)](CONTRIBUTING.md)

A tiny native macOS menu-bar app that shows your **Claude and Codex subscription
usage** — the same numbers as Claude Code's "Plan usage limits" panel and Codex's
`/status` — right in your menu bar.

> **Why "Cookie Monster"?** It started life as *Token Monster* — it watches Claude
> gobble through your tokens. "Cookie Monster" just has the better appetite. 🍪

```
🍪 27%      ← whichever usage window you pinned, color-coded
```

Click it for the full breakdown — one section per subscription you're signed
into. **Click any row to pin it to the menu bar:**

```
Claude Max
you@example.com
────────────────────────────────────────────
Session  PINNED  ███░░░░░░░  27%  resets in 3h 24m
Week             ███░░░░░░░  29%  resets in 5d 4h
Week Sonnet      ░░░░░░░░░░   0%  resets in 5d 4h
────────────────────────────────────────────
Updated 12s ago

Codex Pro
you@example.com
────────────────────────────────────────────
5h  GPT-5.3-Codex-Spark  ░░░░░░░░░░   0%  resets in 4h 59m
Weekly                   █░░░░░░░░░   2%  resets in 6d 20h
────────────────────────────────────────────
Updated 12s ago

Refresh Now              ⌘R
Open Claude Usage…
Open Codex Usage…
Pin to Menu Bar          ▸
Update Every             ▸
Menu Bar Style           ▸
Start at Login            ✓
Quit Cookie Monster      ⌘Q
```

Sections only appear for the tools you actually have installed — Claude-only and
Codex-only setups both show a single section.

## Install

### Download (recommended)

1. Grab the latest **`Cookie-Monster-x.y.z.dmg`** from the
   [Releases page](https://github.com/davidpflugpeil/cookie-monster/releases).
2. Open the `.dmg` and drag **Cookie Monster** into **Applications**.
3. **Double-click to open** — release builds are **signed & notarized by Apple**,
   so there's no Gatekeeper warning.
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

**Claude** — reads your existing **Claude Code OAuth token** from the login
keychain (`Claude Code-credentials`) and polls the (undocumented)
`https://api.anthropic.com/api/oauth/usage` endpoint, the same one that powers
`/usage` inside Claude Code, with a `claude-code/<ver>` User-Agent and the
`anthropic-beta: oauth-2025-04-20` header.

**Codex** — reads the ChatGPT OAuth token the Codex CLI stores in
`~/.codex/auth.json` and polls `https://chatgpt.com/backend-api/codex/usage`
with a `codex_cli_rs/<ver>` User-Agent, the `originator: codex_cli_rs` header and
your `chatgpt-account-id`. That's the same data behind Codex's own rate-limit
display.

Both are polled every 60 seconds (configurable). The pinned window's percentage
goes in the bar, color-coded green < 50%, orange < 80%, red ≥ 80%.

It is **read-only on your credentials**: it never writes to the keychain or to
`~/.codex/auth.json`, never refreshes or modifies your tokens, and never logs a
token or a raw API response. A small diagnostic log (status codes + percentages
only) is kept at `~/.cookie-monster/cookie-monster.log`.

## Settings

All three are in the 🍪 menu and persist across restarts:

- **Pin to Menu Bar** — choose which window's percentage shows in the bar. Every
  window from every signed-in subscription is listed, grouped by provider
  (Claude **Session** / **Week** / **Week (model)**, Codex **5h** / **Weekly**).
  You can also just **click a row in the dropdown** to pin it.
- **Update Every** — how often it polls: 30 seconds, 1 / 2 / 5 / 15 minutes
  (default 1 minute).
- **Menu Bar Style** — **Default** (a monochrome gauge whose needle tracks your
  usage, in the native menu-bar text color) or **Vibrant** (the 🍪 emoji with a
  green/orange/red percentage).

## Uninstall

```bash
./uninstall.sh
```

Removes the app, the login item, and the log directory. Your Claude and Codex
credentials are left untouched.

## Limitations

- **macOS 13+ only.** Needs a Claude subscription signed into Claude Code
  (Pro / Max / Team) and/or a ChatGPT subscription signed into the Codex CLI
  (Plus / Pro / Business). It reports whatever accounts those CLIs are
  authenticated as.
- **Token refresh:** if a section shows *not signed in*, that provider's OAuth
  token expired — run `claude` or `codex` once to refresh it, then click
  **Refresh Now**. Cookie Monster intentionally does not refresh tokens itself,
  to avoid ever touching your stored credentials.
- Both usage endpoints are **undocumented** and may change without notice. If the
  numbers stop appearing, check the field names in [`src/Core.swift`](src/Core.swift)
  (`five_hour` / `seven_day` / `seven_day_opus` / `seven_day_sonnet` for Claude,
  `rate_limit`, `additional_rate_limits` and `code_review_rate_limit` for Codex).
- **Codex windows vary by plan.** On Pro, `rate_limit.secondary_window` is null
  and the plan's own window is the *weekly* one — the only 5h clock belongs to a
  per-model bucket and is tagged as such. Cookie Monster reads every block and
  shows one row per window length, tagging any row that isn't your plan's own with
  the bucket it came from. This mirrors Codex itself, which surfaces every bucket
  it meters — the plan window, one per metered model, and code review.

## Repo layout

| Path | What |
|------|------|
| [`src/Core.swift`](src/Core.swift) | Shared logic — credential reads, Claude + Codex usage fetch, formatting |
| [`src/App.swift`](src/App.swift)   | The menu-bar UI (AppKit `NSStatusItem`) |
| [`build.sh`](build.sh)             | Compile the `.app` bundle |
| [`install.sh`](install.sh) / [`uninstall.sh`](uninstall.sh) | Install/remove to `~/Applications` |
| [`package.sh`](package.sh)         | Build a `.dmg` + `.zip` into `dist/` for releases |

## Contributing

Issues and PRs are welcome — see [CONTRIBUTING.md](CONTRIBUTING.md). Security reports:
[SECURITY.md](SECURITY.md). Release history: [CHANGELOG.md](CHANGELOG.md).

## Disclaimer

This is an unofficial, community project. It is **not affiliated with, endorsed
by, or supported by Anthropic.** It relies on an undocumented endpoint that could
change or break at any time. Provided as-is under the [MIT License](LICENSE).
