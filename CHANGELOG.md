# Changelog

All notable changes to Cookie Monster are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/), and the project adheres to
[Semantic Versioning](https://semver.org/).

## [0.7.9] — 2026-10-15

### Fixed
- **A second subscription went dark after every `claude` run** and the menu sat at
  "reading this profile's usage…" forever. Each time Claude Code refreshes its token it
  rewrites the keychain item, and a rewrite resets the item's partition list to the
  writer's (`apple-tool:`), which silently drops any grant given to Cookie Monster —
  confirmed on a live item: `["apple-tool:"]` right after a `claude` run.
  - Cookie Monster now also reads through `/usr/bin/security`, the tool Claude Code
    itself uses. Claude Code's own writes keep that tool allowed, so this survives every
    refresh with no grant to lose.
  - It is only started after the item's access list — read without decrypting anything,
    the same view Keychain Access gives without a password — shows the tool is allowed
    in both the decrypt entry and the partition list. Anything unclear means "don't".
    A run still going after 3 s is killed and never repeated for that item.
  - A refused item is retried only when it changes, and the card now says it can't be
    read instead of "reading…".
- **The app no longer runs `claude auth status` on every poll.** Claude Code answers it by
  reading the keychain through `/usr/bin/security` with dialogs allowed, so a damaged item
  or a locked keychain turned each poll into a dialog per profile — part of the earlier
  storms (the log shows `timed out running claude` during them). Profile identity now
  comes from the profile's own `.claude.json`; the interactive-shell PATH lookup that ran
  your rc files is gone too.
- Hardening from two rounds of adversarial review:
  - The access-list check follows securityd's order (the first decrypt entry decides) and
    fails closed; a locked keychain is "try later", never a refusal.
  - A `security` run that hangs, fails, or overlaps a keychain dialog on screen blocks
    that item for good, in a file shared by every copy of the app. Slowness alone (e.g.
    right after wake) doesn't.
  - One copy of the app at a time (enabling Start at Login used to start a second one).
  - Reads are one at a time and never park a thread behind the explicit grant, whose
    result is now kept even for a one-time "Allow".
  - Switching subscriptions with the menu open updates the bars too, not just the list; an
    unreadable or signed-out profile no longer leaves its last % in the menu bar.
  - `build.sh` signs ad-hoc unless `SIGN_IDENTITY` is set, so a build never asks for a key.
  - HTTP uses an ephemeral session (no on-disk cache of authorised requests); the log
    file is written under a lock; `.claude.json` with a stray surrogate escape is read.

## [0.7.8] — 2026-10-15

### Fixed
- **Keychain prompt storms — for Cookie Monster and for Claude Code itself.**
  0.7.0–0.7.7 refreshed expired Claude tokens and wrote them back to Claude Code's
  keychain item. On macOS, modifying an item replaces its access partition with
  the writer's, so each write removed `apple-tool:` — the partition of
  `/usr/bin/security`, which Claude Code uses to read its own sign-in. From then on
  every Claude Code session prompted on every read (the system log shows
  `ACL partition mismatch: client apple-tool:`).
  - The app **never writes to the keychain**. The refresh/write-back code is gone,
    not switched off; the binary contains no `SecItemUpdate`/`SecItemAdd`/`SecItemDelete`.
  - Reads run with keychain UI disabled (`SecKeychainSetUserInteractionAllowed(false)`,
    `kSecUseAuthenticationUIFail`). A refused read is remembered and not retried;
    the menu offers **Allow Keychain Access…**, the only path that can show a dialog.
  - **Repairing an item damaged by an earlier version** (run once per item; it asks
    for your login password in the terminal, not in a dialog):
    `security set-generic-password-partition-list -S "apple-tool:,apple:,teamid:29T68WB833" -s "Claude Code-credentials"`

## [0.7.7] — 2026-10-14

### Fixed
- **Constant keychain password prompts.** The app read your Claude credentials by
  spawning `/usr/bin/security` on every poll, so each read was attributed to that
  Apple tool rather than to Cookie Monster — an "Always Allow" granted `security`,
  and since 0.7.0's token write-back the grant kept getting knocked out, which
  meant a prompt every few minutes.
  - Credentials are now read **in-process** via the Security framework, so a grant
    binds to Cookie Monster's own signature.
  - The secret is read **only when the keychain item actually changed**. Each poll
    does a silent attributes-only check of the item's modification date; the
    decrypting read — the only thing that can prompt — happens when Claude Code
    refreshes or you sign in again, a few times a day. A re-login still changes the
    item, so a switched account is picked up on the next poll.
  - Local builds are signed with your Developer ID when one is installed. Ad-hoc
    signatures change on every build, and macOS ties "Always Allow" to the
    signature, so every rebuild used to void the grant.

## [0.7.6] — 2026-10-14

### Fixed
- **Two subscriptions could show the same number and look broken.** The switcher
  showed only the pinned metric, and two accounts often sit at a similar value on
  one window — e.g. both at 9% session while their weekly usage was 35% and 17%.
  Each row now shows the pinned metric plus the next window, so distinct accounts
  are visibly distinct.

## [0.7.5] — 2026-10-13

### Fixed
- **Selecting a subscription no longer flips back.** Every `render()` rebuilt the
  open menu — including the one fired when a usage fetch returned — and rebuilding
  a menu that is being tracked replaces the card under the pointer, so AppKit
  delivered the pending click to the replacement. The card now takes new switcher
  data in place; the full rebuild waits for the next open.
- **Two profiles holding the same account say so.** They previously looked like two
  separate subscriptions showing near-identical numbers. The row now reads
  `<name> — same account as <other>`.
- **A profile is bound once it reports successfully**, using the account its own
  token resolves to. Profiles matched by the sign-in-time correlation recorded a
  keychain entry but were never bound, so they stayed unlabelled indefinitely.

## [0.7.3] — 2026-10-13

### Fixed
- **Selecting a subscription appeared not to switch.** It did switch, then flipped
  straight back about a second later. Rebuilding the menu from inside the click
  handler re-creates the card while the event is still being dispatched, so the
  replacement view received the same click and switched again. The rebuild is now
  deferred to the next run-loop pass, and a second switch arriving within 600 ms —
  faster than a person can click twice — is ignored.

## [0.7.2] — 2026-10-12

### Fixed
- **Token refresh now actually works — wrong endpoint.** 0.7.0 posted the refresh
  grant to `platform.claude.com/v1/oauth/token`, which appears in the Claude Code
  binary but answers `429` to every POST regardless of input (confirmed with a
  deliberately invalid token). The endpoint that validates the grant is
  `api.anthropic.com/v1/oauth/token` — it answers `400 invalid_grant` to a bad
  token and refreshes correctly with a real one.

## [0.7.1] — 2026-10-12

### Fixed
- **A failed refresh no longer makes the subscription disappear.** When the refresh
  couldn't run (rate limited, offline, token revoked) the credentials were treated
  as absent, so the card fell back to "couldn't identify this profile" and stopped
  reporting entirely. The stale credentials are handed back instead — the usage
  call still short-circuits locally on expiry, so no request is made, and the card
  says `token expired` as it did in 0.6.2.

## [0.7.0] — 2026-10-12

### Added
- **Tokens are refreshed automatically — no more re-running the CLI.** Claude Code
  refreshes its access token only when you actually run it, so a subscription you
  aren't actively using goes stale within hours. Cookie Monster now performs the
  same OAuth refresh grant itself (`platform.claude.com/v1/oauth/token`, using
  Claude Code's own client id read from the installed binary) and writes the
  result back to the same keychain entry, so the CLI sees the fresh token too.

  **This is the first time the app writes to your keychain**, and it only does so
  on a successful `200` carrying a new access token. The previous blob is copied
  to `~/.cookie-monster/keychain-backups/` before every write, because OAuth
  servers commonly rotate refresh tokens and losing the rotated one would sign
  that profile out. Writes go through `SecItemUpdate`, never the `security` CLI,
  so no secret ever appears in a process argument list.

  Refreshes are throttled to one attempt per profile per 5 minutes, and a `429`
  parks that profile's refresh for an hour — a refresh storm is precisely how this
  app has burned quota before.

## [0.6.2] — 2026-10-10

### Fixed
- **The real cause of the rate limiting.** Claude Code refreshes its access token
  *lazily* — only when you actually run it. Leave the CLI unused for a few days
  and the token in the keychain sits expired, and Cookie Monster kept sending it:
  a `401` every poll, against an hourly quota shared with your own Claude Code
  sessions. The expiry is in the keychain blob all along, so it is now checked
  locally and **no request is made at all** when the token is stale. The card says
  `token expired — run \`claude\` once to refresh it`, which is exactly what fixes
  it. Costs nothing, so it recovers on the very next poll.
- **A profile no longer gets stranded.** The keychain search ran once per launch;
  one failure left that subscription dark until the app was restarted. It now
  retries every 10 minutes.
- **A cached reading is never replaced by a placeholder.** The card could sit on
  "reading this profile's usage…" while the switcher directly above it showed that
  same profile's percentage.
- **Profiles are bound from the token, not `claude auth status`.** That field
  mirrors `~/.claude.json` and was observed naming the wrong account — it had two
  different subscriptions reporting the same address. Binding now comes from the
  account a verified token resolves to, and two profiles can never claim the same
  keychain entry.
- **An expired token can still be matched to its profile.** It can't be verified
  against the API, so the search falls back to correlating the entry's write time
  with the profile's last sign-in — they are written in the same moment.

## [0.6.1] — 2026-09-30

### Added
- **The default subscription can be renamed too.** Its config directory is your own
  `~/.claude` / `~/.codex`, which this app never writes to, so its label is stored
  in `~/.cookie-monster/` instead. Renaming still touches nothing of yours.

## [0.6.0] — 2026-09-30

### Added
- **Rename a subscription.** Each provider's submenu gains **Rename “…”** for the
  active profile. The label is stored inside the profile rather than by renaming
  the directory — the active-profile file holds an absolute path and a `claude`
  session may already be running against it, so moving directories would break
  both. Only the label changes: the account, credentials and settings stay put.
- Switcher rows now read **`Label — account`**, leading with the name you chose,
  and the label is truncated so a long name can never overlap the percentage.

## [0.5.4] — 2026-09-30

### Fixed
- **Switching no longer flashes "usage unavailable for a switched profile".** Two
  causes: the card showed a placeholder while the profile's credentials were being
  located, and it dropped the account switcher entirely while doing so — stranding
  you on a profile with no way back except the submenu.
  - The switcher now survives every state, including "not signed in" and errors.
  - A switch reuses the reading already taken for the switcher, so the numbers are
    there immediately.
  - The transient wording reads as progress ("reading this profile's usage…"),
    because it is — not as a permanent failure.

## [0.5.3] — 2026-09-30

### Added
- **Install Shell Setup** writes the `claude` and `codex` functions into your rc
  file directly — idempotent, and it backs the file up first. Previously the app
  only copied the text to the clipboard, and the obvious way to apply it
  (`pbpaste >> ~/.zshrc`) appends *whatever happens to be on the clipboard*. In
  testing that appended an image URL and broke the shell on next start.

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
