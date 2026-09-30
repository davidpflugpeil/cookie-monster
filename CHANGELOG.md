# Changelog

All notable changes to Cookie Monster are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/), and the project adheres to
[Semantic Versioning](https://semver.org/).

## [0.5.2] — 2026-09-30

### Fixed
- **Signing in could silently overwrite the wrong profile.** Without the shell
  functions installed, `CLAUDE_CONFIG_DIR` is never set, so `claude /login` always
  writes to the **default** profile — no matter which one you picked in the menu.
  Selecting a profile and signing in therefore replaced your default account's
  credentials while leaving the selected profile still signed out, which is how
  accounts ended up swapped between labels.
  - **Copy Sign-in Command…** now gives the exact command for a specific profile
    (`CLAUDE_CONFIG_DIR="…" claude /login`, or `env -u CLAUDE_CONFIG_DIR …` for the
    default), so a login cannot land anywhere else.
  - The missing-shell-setup warning moved out of the submenu onto the menu itself,
    and says what actually goes wrong.
- **A profile keeps the account you assigned it.** The keychain entry was pinned
  permanently, but signing in again makes Claude Code write a *new* entry — so the
  pinned one went stale and returned `401` forever. A profile is now bound to an
  account identity (written once, never silently rewritten) while the keychain
  entry is treated as a refreshable cache: a 401 drops it and searches again,
  matching on the bound account. A profile signed in as someone else is labelled
  as such rather than quietly relabelled.

## [0.5.1] — 2026-09-30

### Fixed
- **The app was burning your account's rate-limit quota and taking your own CLI
  sessions down with it.** A `401` set no backoff, so a profile whose token had
  expired was re-polled every interval forever — about 720 pointless requests a
  day against an endpoint whose hourly quota is shared with Claude Code itself.
  A 401 can only be resolved by a human signing in, so it now backs off 30
  minutes, doubling to a 4-hour cap, and the affected profile is parked for an
  hour.
- **Inactive profiles are polled at most every 15 minutes.** They only feed the
  account switcher, so they never needed the active profile's freshness — but
  polling them on the same schedule doubled the request rate the moment you added
  a second subscription.

## [0.5.0] — 2026-09-29

### Added
- **Codex gets the same treatment.** `CODEX_HOME` is Codex's equivalent of
  `CLAUDE_CONFIG_DIR`, so a Codex profile works identically — and more simply:
  Codex keeps credentials in a plain `auth.json` inside its config dir, so every
  profile's usage is readable with no keychain lookup at all. Seeding copies
  `config.toml` (where Codex's MCP servers live), `hooks.json`, `AGENTS.md`,
  `prompts` and `skills`; `sessions` (1.4 GB here), `archived_sessions` and the
  sqlite stores are never copied.
- The shell setup now installs a function for **both** `claude` and `codex`, each
  reading its own active-profile file, so the two switch independently.
- **An account switcher at the top of each provider's card.** Every subscription is
  listed with the value of your pinned metric for *that* account, the active one
  marked; click a row to switch. Switching does not dismiss the menu, so you can
  compare accounts in place. All profiles are polled, not just the active one, so the
  numbers are live for each. Each account has its own rate-limit budget, and a 429
  backs off per profile rather than for Claude as a whole.
- **Switch between two Claude subscriptions without logging out.** Keep both signed
  in and pick the active one from **Active Subscription** in the menu.
  - A profile is a config directory under `~/.cookie-monster/profiles/` holding
    **copies** of your settings and MCP servers. Claude Code keys its keychain entry
    to the directory path, which is what lets both accounts stay signed in.
  - **Copy Shell Setup** gives you a shell function for your rc file. It re-reads the
    active subscription on every `claude` invocation, so switching applies to
    terminals that are already open.
  - Switching re-syncs settings and MCP servers from your default config into the
    profile — one direction only, default → profile. Your own config is never
    written to; every write is gated to `~/.cookie-monster/profiles`.
  - `projects` (session history) is **not** copied: it is gigabytes, and each profile
    keeps its own.

### Known limitations
- **Editor integrations that exec `claude` directly** don't read the shell function
  and keep using your default subscription. The menu warns when the function isn't
  installed at all.
- Editor integrations aside, **usage now works for both subscriptions.** Claude Code
  derives a profile's keychain entry name by an undocumented scheme we can't
  reproduce — but we can *find* it: enumerating generic-password **attributes** is
  silent (no `kSecReturnData`, nothing decrypted, no prompt), and the entry for a
  profile is the one created when that profile was signed in. The candidate is then
  **verified against `/oauth/account`** before use, so the app can never show one
  subscription's usage under another's name, and the service name is recorded in the
  profile so the search happens once. Costs a single keychain prompt per profile
  ("Always Allow"); until it succeeds the card shows the profile's identity rather
  than another account's numbers.

### Note on the reverted v0.5.0
An earlier attempt built profiles as **symlinks** to the real config. A profile that
wasn't signed in yet caused Claude Code to initialise a fresh config, and that write
replaced the symlink rather than following it — landing on the shared original and
truncating `~/.claude.json` and `~/.claude/settings.json`. That version was reverted
(`b41491f`); this one never symlinks anything, and `./run-tests.sh` asserts the
originals are byte-identical against a throwaway home.

### Hardened after a third review round
- Copies now **dereference symlinks** (`cp -RL`). `FileManager.copyItem` preserves
  them, so a `~/.claude/commands` symlinked into a dotfiles repo — or
  `~/.claude/skills`, symlinked on the author's machine — put a link *inside* the
  profile pointing out of the sandbox, which Claude Code then wrote through. A
  post-seed sweep removes any symlink that slips in.
- A profile's own `.claude.json` is **left untouched when it can't be parsed**,
  instead of being replaced by an `mcpServers`-only file. Claude Code writes JSON
  via Node, which emits unpaired surrogate escapes that `JSONSerialization`
  rejects — so one emoji in that profile's history would otherwise have wiped it.
- Switching no longer re-copies `settings.json`, `CLAUDE.md`, `commands`, `agents`
  or `hooks`, which silently destroyed per-profile edits. Those are seeded once;
  only `mcpServers` is pushed on switch.
- The profile config is written `0600` (the source is `0600` and may carry MCP
  credentials); profile directories are `0700`.
- v0.5.0 symlink farms left on disk are neutralised at launch — they would still
  write through into the real `~/.claude`.

## [0.4.6] — 2026-09-21

### Fixed
- **The Claude card could show one account's usage under another account's email.**
  0.4.5 read the email from `oauthAccount` in `~/.claude.json` while reading the
  numbers from the keychain token — two independent sources. Claude Code keeps a
  credential store per config/session (this Mac had ~100), so they can disagree;
  here the token belonged to one address while the config file named another, and
  the menu paired them. The email is now resolved from the same token that
  produces the numbers, via `/oauth/account`, once per token — a sign-in or token
  refresh triggers one lookup, ordinary polls trigger none, so this doesn't bring
  back the 429s. If the lookup fails the email is retried next poll rather than
  falling back to the config file.

## [0.4.5] — 2026-09-18

### Fixed
- **The account email didn't update when you switched Claude accounts.** 0.4.4
  stopped re-fetching it on every poll (to cut the request rate that was causing
  429s) but had no way to notice a switch, so the old address stuck until you
  quit the app. The email is now read from `oauthAccount` in `~/.claude.json`,
  which Claude Code rewrites on sign-in — so a switch shows up on the next poll,
  and the `/oauth/account` request is gone entirely, taking more pressure off the
  rate-limited endpoint. (The network call remains as a one-time fallback for
  older Claude Code versions that don't write that key.)
- Switching accounts now clears the previous account's cached reading and any
  rate-limit backoff, since the new account has its own numbers and its own quota
  — you no longer sit out the old account's lockout.
- Signing out clears the remembered account, so signing back in re-detects it.

## [0.4.4] — 2026-09-16

### Fixed
- **Constant `429 Rate limited` from the Claude endpoint.** The usage API answers a
  429 with `Retry-After` — typically ~1 hour — and Cookie Monster ignored it,
  re-polling on its normal interval and burning the next quota window the moment it
  reset. Lowering the poll interval made this *worse*, not better. On two days in a
  row the app got 1,440 rejections and zero successful reads.
  - `Retry-After` is now honoured (seconds or HTTP-date), plus 5–60s of jitter so
    installs don't stampede the same reset.
  - Transient errors back off geometrically, capped at 30 minutes.
  - The account email is fetched **once** instead of on every poll — that alone
    halved the request rate against the rate-limited endpoint.
  - Default poll interval is now 5 minutes, and the 30-second option is gone.
- **A rate limit no longer blanks the dropdown.** The last good reading stays on
  screen (the numbers can't have moved while we're locked out) with an orange
  `rate limited · 50m` note counting down to the retry, and the menu-bar item keeps
  showing the pinned window instead of jumping to the other subscription.
- Non-2xx responses now log their rate-limit headers and body, so this is
  diagnosable from `~/.cookie-monster/cookie-monster.log` instead of being an
  opaque status code.

## [0.4.3] — 2026-09-07

### Changed
- **Codex shows only your plan's own rate-limit windows.** Codex's UI also lists
  the per-model caps in `additional_rate_limits`, but those meter one specific
  model: on Pro the 5h clock there belongs to `GPT-5.3-Codex-Spark` and reads 0%
  whether or not you're near your real limit, so it's noise in a menu-bar summary.
  Only the plan bucket (`rate_limit`) is shown — a single `Weekly` bar on Pro,
  `5h` + `Weekly` on Plus.

### Fixed
- A pinned window whose id no longer exists is rewritten once its provider reports
  successfully, instead of silently riding the fallback with a dead id stored.

## [0.4.2] — 2026-09-07

### Fixed
- **The Codex 5h row is back.** 0.4.1 removed it on the reasoning that a per-model
  cap isn't the plan's budget. Verified against the Codex client's own
  `account/rateLimits/read` RPC, that was wrong: Codex surfaces every bucket it
  meters, and on Pro the plan bucket (`limitId: "codex"`) has only a 7-day window,
  so the sole 5h clock legitimately belongs to a model bucket. Cookie Monster now
  shows one row per window length again, tagging any row that isn't the plan's own
  with the bucket it came from — matching what Codex itself displays.

## [0.4.1] — 2026-09-07

### Fixed
- **Codex now shows only your plan's own rate-limit windows.** 0.4.0 also surfaced
  entries from `additional_rate_limits`, which are caps on *individual models*
  (and on code review) rather than your subscription's budget. On Pro that
  produced a headline `5h` row taken from the `GPT-5.3-Codex-Spark` bucket — a
  model you may never invoke, so it sits at 0% and reads as "session budget
  untouched" when your plan has no 5-hour window at all. Only
  `rate_limit.primary_window` / `secondary_window` are read now, so a Pro account
  correctly shows a single `Weekly` bar and a Plus account shows `5h` + `Weekly`.
- Pinned-row spacing. The highlight block had a hard-coded height that was 6pt
  shorter than the row it wrapped, leaving 7pt of padding above the label and 1pt
  below the reset line. Its geometry is now derived from the row's own metrics, so
  the padding is symmetric, and the band sits evenly between the two hairlines.

## [0.4.0] — 2026-09-07

### Added
- **Codex subscription support.** Cookie Monster now reads the ChatGPT OAuth
  token the Codex CLI stores in `~/.codex/auth.json` (read-only, never rewritten)
  and polls `https://chatgpt.com/backend-api/codex/usage` for your Codex
  rate-limit windows. The dropdown gains a **Codex** section with your plan,
  account email, and a **5h** and **Weekly** bar. Codex reports the same two
  clocks in several places — the account-wide block, one entry per metered model
  (`additional_rate_limits`), and code review — so Cookie Monster reads all of
  them and shows one row per window length. Only the plan's own window gets an
  unqualified label — a per-model cap is tagged with the model it meters, so
  `5h — 0%` can't be misread as an untouched session budget when it only means
  that one model went unused. This matters on Pro, where `rate_limit.secondary_window`
  is null, the account-wide window is the *weekly* one, and the only 5-hour window
  in the response belongs to a per-model bucket.

### Fixed
- The open dropdown refreshes when a fetch lands. `NSMenu.update()` does nothing
  unless `autoenablesItems` is true, and `menuNeedsUpdate` only fires when a
  tracking session starts, so the menu used to freeze on the snapshot it opened
  with — including an "Updated …" counter ticking off a stale timestamp.
- The menu-bar item no longer sticks on "…" forever when neither Claude Code nor
  the Codex CLI is installed (that state transition skipped the render).
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
