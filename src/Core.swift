// Core.swift — shared logic for the Cookie Monster 🍪 menu-bar app.
// Foundation-only (no AppKit) so it stays easy to test and reuse.

import Foundation

// MARK: - Constants

let kUsageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
let kAccountURL = URL(string: "https://api.anthropic.com/api/oauth/account")!
let kKeychainService = "Claude Code-credentials"
let kClaudeConfigPath = (NSHomeDirectory() as NSString).appendingPathComponent(".claude.json")
let kCodexUsageURL = URL(string: "https://chatgpt.com/backend-api/codex/usage")!
let kCodexDir = (NSHomeDirectory() as NSString).appendingPathComponent(".codex")
let kCodexAuthPath = (kCodexDir as NSString).appendingPathComponent("auth.json")
let kLoginPlistLabel = "com.pflugpeil.cookiemonster"
let kPollInterval: TimeInterval = 300
let kLogDir = (cmHome() as NSString).appendingPathComponent(".cookie-monster")
let kLogFile = (kLogDir as NSString).appendingPathComponent("cookie-monster.log")
let kVersion = "0.4.6"

// MARK: - Logging (no secrets ever pass through here)

/// Frontends install their own sink. Default is a no-op.
var logHandler: (String) -> Void = { _ in }
func log(_ msg: String) { logHandler(msg) }

/// A file logger the menu-bar app installs into `logHandler`.
func fileLog(_ msg: String) {
    let fm = FileManager.default
    if !fm.fileExists(atPath: kLogDir) {
        try? fm.createDirectory(atPath: kLogDir, withIntermediateDirectories: true)
    }
    let ts = ISO8601DateFormatter().string(from: Date())
    guard let data = "[\(ts)] \(msg)\n".data(using: .utf8) else { return }
    if let fh = FileHandle(forWritingAtPath: kLogFile) {
        fh.seekToEndOfFile(); fh.write(data); try? fh.close()
    } else {
        try? data.write(to: URL(fileURLWithPath: kLogFile))
    }
}

// MARK: - Providers

enum Provider: String, CaseIterable {
    case claude, codex
    var label: String { self == .claude ? "Claude" : "Codex" }
    /// Where "Open … Usage" sends you.
    var usageURL: URL {
        self == .claude ? URL(string: "https://claude.ai/settings/usage")!
                        : URL(string: "https://chatgpt.com/codex/settings/usage")!
    }
    /// Shown when the provider is installed but not signed in.
    var signInHint: String {
        self == .claude ? "Open Claude Code and sign in, then Refresh"
                        : "Run `codex` and sign in with ChatGPT, then Refresh"
    }
}

// MARK: - Models

/// One usage window, identified by a stable `id` so it can be pinned to the menu bar.
struct Metric {
    let id: String          // e.g. "claude.session", "codex.primary"
    let provider: Provider
    let name: String        // "Session", "Week", "5h", "Weekly"
    let pct: Double         // 0…100
    let resets: Date?
}

struct ProviderUsage {
    let provider: Provider
    let plan: String        // display name: "Max", "Pro", …
    let email: String?
    let metrics: [Metric]
    let fetchedAt: Date
}

enum FetchState {
    case notConfigured      // provider isn't installed at all — hide it entirely
    case loading
    case ok(ProviderUsage)
    case needsAuth          // installed but no token, or 401/403
    case rateLimited(Date)  // 429 — do not call again before this date
    case otherProfile      // a non-default profile is active; its token isn't readable
    case error(String)
}

enum Severity { case low, medium, high }
func severity(_ pct: Double) -> Severity {
    pct < 50 ? .low : (pct < 80 ? .medium : .high)
}

struct Credentials {
    var accessToken: String
    var plan: String?
    var expiresAt: Date?
}

struct CodexCredentials {
    var accessToken: String
    var accountId: String
}

// MARK: - Claude Code version (for the User-Agent header)

func claudeCodeVersion() -> String {
    let base = (NSHomeDirectory() as NSString)
        .appendingPathComponent(".local/share/claude/versions")
    if let entries = try? FileManager.default.contentsOfDirectory(atPath: base) {
        let versions = entries.filter {
            $0.range(of: #"^\d+\.\d+\.\d+"#, options: .regularExpression) != nil
        }
        if let newest = versions.sorted(by: versionLess).last { return newest }
    }
    return "2.1.172"
}

/// Codex writes the version it last checked for into ~/.codex/version.json.
func codexVersion() -> String {
    let path = (kCodexDir as NSString).appendingPathComponent("version.json")
    if let data = FileManager.default.contents(atPath: path),
       let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
       let v = root["latest_version"] as? String, !v.isEmpty { return v }
    return "0.50.0"
}

func versionLess(_ a: String, _ b: String) -> Bool {
    let pa = a.split(separator: ".").compactMap { Int($0) }
    let pb = b.split(separator: ".").compactMap { Int($0) }
    for i in 0..<max(pa.count, pb.count) {
        let x = i < pa.count ? pa[i] : 0
        let y = i < pb.count ? pb[i] : 0
        if x != y { return x < y }
    }
    return false
}

// MARK: - Claude credentials (login keychain)

/// Reads the raw credential blob from the login keychain via `/usr/bin/security`.
/// May trigger a one-time macOS "allow access" prompt on first use.
func keychainBlob() -> String? {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
    p.arguments = ["find-generic-password", "-s", kKeychainService, "-w"]
    let out = Pipe()
    p.standardOutput = out
    p.standardError = Pipe()
    do { try p.run() } catch { return nil }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    guard p.terminationStatus == 0 else { return nil }
    return String(data: data, encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

func readCredentials() -> Credentials? {
    guard let blob = keychainBlob(), !blob.isEmpty else { return nil }

    if let data = blob.data(using: .utf8),
       let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
        let oauth = (root["claudeAiOauth"] as? [String: Any]) ?? root
        if let token = oauth["accessToken"] as? String, !token.isEmpty {
            var expires: Date? = nil
            if let ms = (oauth["expiresAt"] as? NSNumber)?.doubleValue {
                expires = Date(timeIntervalSince1970: ms / 1000.0)
            }
            return Credentials(accessToken: token,
                               plan: oauth["subscriptionType"] as? String,
                               expiresAt: expires)
        }
    }
    if let r = blob.range(of: #"sk-ant-oat[A-Za-z0-9_-]+"#, options: .regularExpression) {
        return Credentials(accessToken: String(blob[r]), plan: nil, expiresAt: nil)
    }
    return nil
}

/// The account Claude Code's *config* file names — used only as a diagnostic, never as
/// the displayed email. Claude Code keeps a credential store per config/session, so this
/// can name a different account than the keychain token we actually poll with (seen in
/// practice: the token belonged to one address while this said another). The email shown
/// is always resolved from the token itself; see AppDelegate.resolveClaudeEmail.
/// The `path` parameter exists so tests can point at a fixture.
func readClaudeAccount(path: String = kClaudeConfigPath) -> (email: String, uuid: String?)? {
    guard let data = FileManager.default.contents(atPath: path),
          let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let acct = root["oauthAccount"] as? [String: Any],
          let email = acct["emailAddress"] as? String, !email.isEmpty else { return nil }
    return (email, acct["accountUuid"] as? String)
}

/// True when Claude Code is present on this Mac (so we know whether to show the section).
func claudeInstalled() -> Bool {
    let fm = FileManager.default
    for p in [".claude", ".claude.json", ".local/share/claude"] {
        if fm.fileExists(atPath: (NSHomeDirectory() as NSString).appendingPathComponent(p)) { return true }
    }
    return false
}

// MARK: - Codex credentials (~/.codex/auth.json)

/// True when the Codex CLI has been set up on this Mac.
func codexInstalled() -> Bool { FileManager.default.fileExists(atPath: kCodexDir) }

/// Reads the ChatGPT OAuth token Codex stores on disk. Read-only: we never
/// refresh or rewrite `auth.json`, so we can't disturb a running Codex session.
func readCodexCredentials() -> CodexCredentials? {
    guard let data = FileManager.default.contents(atPath: kCodexAuthPath),
          let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let tokens = root["tokens"] as? [String: Any],
          let token = tokens["access_token"] as? String, !token.isEmpty else { return nil }
    return CodexCredentials(accessToken: token,
                            accountId: (tokens["account_id"] as? String) ?? "")
}

// MARK: - Claude profiles (copy-based; never writes outside ~/.cookie-monster)

/// NSHomeDirectory() reads getpwuid and ignores $HOME, so tests cannot sandbox it.
/// COOKIE_MONSTER_HOME exists purely so the profile system can be exercised against a
/// throwaway home; unset in normal use.
func cmHome() -> String {
    ProcessInfo.processInfo.environment["COOKIE_MONSTER_HOME"] ?? NSHomeDirectory()
}

let kClaudeDefaultDir = (cmHome() as NSString).appendingPathComponent(".claude")
let kClaudeHomeConfig = (cmHome() as NSString).appendingPathComponent(".claude.json")
let kProfilesDir = (kLogDir as NSString).appendingPathComponent("profiles")
let kActiveProfileFile = (kLogDir as NSString).appendingPathComponent("active-profile")

/// v1 of this feature symlinked a profile's files to the real ones. That destroyed the
/// user's config: a profile that isn't signed in yet makes Claude Code initialise a fresh
/// config, and that write does NOT always go through the symlink — it replaces it, landing
/// on the shared original. So nothing is ever symlinked now. A profile holds COPIES, and
/// the app only ever writes inside kProfilesDir.
let kProfileSeed = [
    "settings.json", "settings.local.json", "CLAUDE.md",
    "commands", "agents", "hooks", "skills", "plugins",
]

/// Seeded ONCE, at creation. Deliberately not re-copied on switch: a profile may have its
/// own settings.json, CLAUDE.md or commands, and overwriting them on every switch silently
/// destroyed the user's per-profile work. Only mcpServers is pushed on switch.

struct ClaudeProfile {
    let name: String
    let configDir: String
    var isDefault: Bool { configDir == kClaudeDefaultDir }
    /// nil means CLAUDE_CONFIG_DIR is unset — the only way to reach the default profile's
    /// credentials. Setting it to ~/.claude keys a different keychain entry entirely.
    var envConfigDir: String? { isDefault ? nil : configDir }
}

struct AuthStatus {
    var loggedIn: Bool
    var email: String?
    var plan: String?
    var orgName: String?
}

/// A profile name becomes a directory under kProfilesDir. "." and ".." survive
/// appendingPathComponent unnormalised and would escape it.
func isValidProfileName(_ raw: String) -> Bool {
    let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty, name.count <= 40, !name.hasPrefix("."),
          name.lowercased() != "default" else { return false }
    let allowed = CharacterSet(charactersIn:
        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_ ")
    return name.unicodeScalars.allSatisfy { allowed.contains($0) }
}

/// Guarantees every write stays inside kProfilesDir, whatever the caller passes.
private func assertInsideProfiles(_ path: String) -> Bool {
    // Raw comparison on purpose: standardizingPath resolves /private/tmp -> /tmp only for
    // paths that already exist, so standardizing an as-yet-uncreated destination against an
    // existing root silently rejects every legitimate copy.
    guard !path.contains("/../"), !path.hasSuffix("/.."), !path.contains("//") else { return false }
    return (path + "/").hasPrefix(kProfilesDir + "/")
}

/// Copies with symlinks RESOLVED. FileManager.copyItem preserves them, which would put a
/// link inside the profile pointing at a shared file (dotfiles repos commonly symlink
/// ~/.claude/commands, and ~/.claude/skills is symlinked here) — Claude Code would then
/// write through it, defeating the entire sandbox. `cp -RL` dereferences at every level.
private func replaceCopy(from src: String, to dst: String) {
    let fm = FileManager.default
    guard fm.fileExists(atPath: src), assertInsideProfiles(dst) else { return }
    try? fm.removeItem(atPath: dst)
    guard runBounded("/bin/cp", ["-RL", src, dst], env: nil, timeout: 120) != nil else {
        log("profile copy failed for \((dst as NSString).lastPathComponent)")
        return
    }
}

/// Defence in depth: after seeding, nothing in a profile may be a symlink. Anything that is
/// gets removed rather than left pointing outside the sandbox.
private func stripSymlinks(under dir: String) {
    let fm = FileManager.default
    guard assertInsideProfiles(dir) || dir == kProfilesDir,
          let e = fm.enumerator(atPath: dir) else { return }
    for case let rel as String in e {
        let full = (dir as NSString).appendingPathComponent(rel)
        if (try? fm.destinationOfSymbolicLink(atPath: full)) != nil, assertInsideProfiles(full) {
            log("removed symlink inside profile: \(rel)")
            try? fm.removeItem(atPath: full)
        }
    }
}

func listProfiles() -> [ClaudeProfile] {
    var out = [ClaudeProfile(name: "Default", configDir: kClaudeDefaultDir)]
    for name in ((try? FileManager.default.contentsOfDirectory(atPath: kProfilesDir)) ?? []).sorted()
    where !name.hasPrefix(".") {
        let dir = (kProfilesDir as NSString).appendingPathComponent(name)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir, isDirectory: &isDir), isDir.boolValue else { continue }
        out.append(ClaudeProfile(name: name, configDir: dir))
    }
    return out
}

/// The configured profile and whether its directory still exists. Callers must not quietly
/// fall back to the default: the shell function doesn't, so the app would report one account
/// while every terminal keeps using another.
func activeProfile() -> (dir: String, missing: Bool) {
    guard let raw = try? String(contentsOfFile: kActiveProfileFile, encoding: .utf8) else {
        return (kClaudeDefaultDir, false)
    }
    let dir = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if dir.isEmpty || dir == kClaudeDefaultDir { return (kClaudeDefaultDir, false) }
    return (dir, !FileManager.default.fileExists(atPath: dir))
}

func activeProfileDir() -> String { activeProfile().dir }

@discardableResult
func setActiveProfile(_ configDir: String) -> Bool {
    try? FileManager.default.createDirectory(atPath: kLogDir, withIntermediateDirectories: true)
    do { try (configDir + "\n").write(toFile: kActiveProfileFile, atomically: true, encoding: .utf8); return true }
    catch { log("could not write active-profile"); return false }
}

/// Copies the default profile's config into `dir`, and merges the current `mcpServers` into
/// the profile's own .claude.json — never the other way round. `projects` (gigabytes of
/// history) is deliberately not copied.
func syncProfile(_ dir: String, seeding: Bool = false) {
    let fm = FileManager.default
    guard assertInsideProfiles(dir) else { return }
    try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
    try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir)

    if seeding {
        for entry in kProfileSeed {
            let dst = (dir as NSString).appendingPathComponent(entry)
            if fm.fileExists(atPath: dst) { continue }   // never clobber what the profile owns
            replaceCopy(from: (kClaudeDefaultDir as NSString).appendingPathComponent(entry), to: dst)
        }
        stripSymlinks(under: dir)
    }

    // The profile owns its .claude.json outright — we only push MCP servers into it, so a
    // fresh-init write by a signed-out Claude Code can never reach the real file.
    let target = (dir as NSString).appendingPathComponent(".claude.json")
    var profileCfg: [String: Any] = [:]
    if fm.fileExists(atPath: target) {
        // Present but unreadable means DO NOT TOUCH. Writing a config derived from a failed
        // read is exactly how v1 destroyed 104 KB of config. Note Claude Code writes JSON via
        // Node, which emits unpaired surrogate escapes that JSONSerialization rejects — so a
        // single emoji in that profile's history would otherwise wipe it.
        guard let d = fm.contents(atPath: target),
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else {
            log("profile config unreadable; leaving it alone")
            return
        }
        profileCfg = j
    }
    guard let hd = fm.contents(atPath: kClaudeHomeConfig),
          let home = try? JSONSerialization.jsonObject(with: hd) as? [String: Any],
          let mcp = home["mcpServers"] else { return }
    profileCfg["mcpServers"] = mcp
    guard assertInsideProfiles(target),
          let out = try? JSONSerialization.data(withJSONObject: profileCfg, options: [.prettyPrinted])
    else { return }
    try? out.write(to: URL(fileURLWithPath: target), options: .atomic)
    // #9: the source is 0600 and may carry MCP credentials; .atomic writes 0644 by default.
    try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target)
}

/// v0.5.0 built profiles as symlink farms. Those still on disk write straight through into
/// the real ~/.claude, so they must be neutralised before a profile is ever used.
func migrateLegacyProfiles() {
    let fm = FileManager.default
    for name in (try? fm.contentsOfDirectory(atPath: kProfilesDir)) ?? [] {
        let dir = (kProfilesDir as NSString).appendingPathComponent(name)
        stripSymlinks(under: dir)
    }
}

func createProfile(name rawName: String) throws -> ClaudeProfile {
    let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard isValidProfileName(name) else {
        throw NSError(domain: "CookieMonster", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "Use letters, numbers, spaces, - or _ (not \"Default\")."])
    }
    let dir = (kProfilesDir as NSString).appendingPathComponent(name)
    syncProfile(dir, seeding: true)
    log("created profile \(name)")
    return ClaudeProfile(name: name, configDir: dir)
}

let kShellSnippet = """
claude() {
  local p; p="$(cat ~/.cookie-monster/active-profile 2>/dev/null)"
  if [ -n "$p" ] && [ "$p" != "$HOME/.claude" ]; then
    CLAUDE_CONFIG_DIR="$p" command claude "$@"
  else
    command claude "$@"
  fi
}
"""

/// Runs a command with a hard deadline. stdout is drained on another queue so the deadline
/// can actually fire, and the process is never waited on inline: an rc file that spawns a
/// background process inheriting stdout keeps the pipe open long after the shell exits.
func runBounded(_ executable: String, _ args: [String], env: [String: String]?,
                timeout: TimeInterval) -> Data? {
    final class Box { var data = Data() }
    let box = Box()
    let p = Process()
    p.executableURL = URL(fileURLWithPath: executable)
    p.arguments = args
    if let env = env { p.environment = env }
    let out = Pipe()
    p.standardOutput = out
    p.standardError = FileHandle.nullDevice
    p.standardInput = FileHandle.nullDevice
    do { try p.run() } catch { return nil }
    let done = DispatchSemaphore(value: 0)
    DispatchQueue.global(qos: .utility).async {
        box.data = out.fileHandleForReading.readDataToEndOfFile()
        done.signal()
    }
    if done.wait(timeout: .now() + timeout) == .timedOut {
        p.terminate()
        _ = done.wait(timeout: .now() + 2)
        DispatchQueue.global(qos: .utility).async { p.waitUntilExit() }
        log("timed out running \((executable as NSString).lastPathComponent)")
        return nil
    }
    DispatchQueue.global(qos: .utility).async { p.waitUntilExit() }
    return box.data
}

private let cliPathLock = NSLock()
private var cachedCLIPath: String?
private var cliPathCheckedAt: Date?

func claudeCLIPath() -> String? {
    cliPathLock.lock(); defer { cliPathLock.unlock() }
    if let hit = cachedCLIPath {
        if FileManager.default.isExecutableFile(atPath: hit) { return hit }
        cachedCLIPath = nil; cliPathCheckedAt = nil     // e.g. the nvm version it lived in went away
    }
    // Never cache a miss for the process lifetime: the user may install the CLI, or fix
    // their PATH, while the app is running.
    if let checked = cliPathCheckedAt, Date().timeIntervalSince(checked) < 300 { return nil }
    let home = cmHome() as NSString
    let candidates = [
        home.appendingPathComponent(".local/bin/claude"), "/opt/homebrew/bin/claude",
        "/usr/local/bin/claude", home.appendingPathComponent(".bun/bin/claude"),
        home.appendingPathComponent(".npm-global/bin/claude"),
    ]
    var found = candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    if found == nil { found = whichClaudeViaLoginShell() }
    cliPathCheckedAt = Date()
    cachedCLIPath = found
    return found
}

private func whichClaudeViaLoginShell() -> String? {
    let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
    // -i matters: zsh/bash source ~/.zshrc / ~/.bashrc only for *interactive* shells, which
    // is exactly where nvm and npm-prefix installs put their PATH. `unset -f claude` matters
    // too: once our own shell function is installed, `command -v claude` answers with the
    // function name rather than a path.
    guard let data = runBounded(shell, ["-ilc", "unset -f claude 2>/dev/null; command -v claude"],
                                env: nil, timeout: 10),
          let text = String(data: data, encoding: .utf8) else { return nil }
    let path = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        .last { !$0.isEmpty } ?? ""
    guard path.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: path) else { return nil }
    return path
}

/// `claude auth status` answers differently under CLAUDE_CODE_USE_BEDROCK or an ANTHROPIC_*
/// override — loggedIn with no email — so strip anything that redirects auth before asking.
func claudeProbeEnv(configDir: String?) -> [String: String] {
    var env = ProcessInfo.processInfo.environment
    for key in env.keys where key.hasPrefix("ANTHROPIC_") || key.hasPrefix("CLAUDE_CODE_")
        || key == "CLAUDE_CONFIG_DIR" { env.removeValue(forKey: key) }
    // Setting CLAUDE_CONFIG_DIR at all keys a different keychain entry — even when set to
    // ~/.claude itself, which then reads as signed out. The default profile means *unset*.
    if let dir = configDir { env["CLAUDE_CONFIG_DIR"] = dir }
    return env
}

/// Pass nil for the default profile. `email` is often null — Claude Code mirrors
/// ~/.claude.json's oauthAccount there — so callers must not treat that as signed out.
func claudeAuthStatus(configDir: String?, timeout: TimeInterval = 15) -> AuthStatus? {
    guard let cli = claudeCLIPath() else { return nil }
    guard let data = runBounded(cli, ["auth", "status"],
                                env: claudeProbeEnv(configDir: configDir), timeout: timeout),
          let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
    return AuthStatus(loggedIn: (root["loggedIn"] as? Bool) ?? false,
                      email: root["email"] as? String,
                      plan: root["subscriptionType"] as? String,
                      orgName: root["orgName"] as? String)
}

/// Without the shell function installed, switching changes nothing `claude` will ever see.
func shellSnippetInstalled() -> Bool {
    for rc in ["/.zshrc", "/.zprofile", "/.bashrc", "/.bash_profile", "/.profile"] {
        if let text = try? String(contentsOfFile: cmHome() + rc, encoding: .utf8),
           text.contains("cookie-monster/active-profile") { return true }
    }
    return false
}

// MARK: - Parsing helpers

func parseDate(_ s: String?) -> Date? {
    guard let s = s else { return nil }
    let f1 = ISO8601DateFormatter()
    f1.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let d = f1.date(from: s) { return d }
    let f2 = ISO8601DateFormatter()
    f2.formatOptions = [.withInternetDateTime]
    return f2.date(from: s)
}

func parseWindow(_ obj: Any?) -> (pct: Double, resets: Date?)? {
    guard let d = obj as? [String: Any],
          let util = (d["utilization"] as? NSNumber)?.doubleValue else { return nil }
    return (util, parseDate(d["resets_at"] as? String))
}

/// Codex reports windows as `{used_percent, limit_window_seconds, reset_at, reset_after_seconds}`.
func parseCodexWindow(_ obj: Any?) -> (pct: Double, span: Double, resets: Date?)? {
    guard let d = obj as? [String: Any],
          let pct = (d["used_percent"] as? NSNumber)?.doubleValue else { return nil }
    let span = (d["limit_window_seconds"] as? NSNumber)?.doubleValue ?? 0
    var resets: Date? = nil
    if let at = (d["reset_at"] as? NSNumber)?.doubleValue, at > 0 {
        resets = Date(timeIntervalSince1970: at)
    } else if let after = (d["reset_after_seconds"] as? NSNumber)?.doubleValue {
        resets = Date().addingTimeInterval(after)
    }
    return (pct, span, resets)
}

/// Lowercases and dash-escapes a display name so it can be part of a stable metric id.
func slug(_ s: String) -> String {
    let mapped = s.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : "-" }
    return String(mapped).lowercased()
}

/// Names a rate-limit window by its length: 18000s → "5h", 604800s → "Weekly".
func windowLabel(_ seconds: Double) -> String {
    let hours = Int((seconds / 3600).rounded())
    switch hours {
    case ..<1:      return "Hourly"
    case 24:        return "Daily"
    case 168:       return "Weekly"
    case 672...744: return "Monthly"
    default:        return hours % 24 == 0 ? "\(hours / 24)d" : "\(hours)h"
    }
}

/// How long the server asked us to wait. `Retry-After` is seconds or an HTTP date.
func retryAfter(_ http: HTTPURLResponse) -> TimeInterval? {
    guard let raw = (http.value(forHTTPHeaderField: "Retry-After") ??
                     http.value(forHTTPHeaderField: "retry-after"))?
        .trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
    if let secs = TimeInterval(raw) { return max(0, secs) }
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = TimeZone(identifier: "GMT")
    f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
    if let d = f.date(from: raw) { return max(0, d.timeIntervalSinceNow) }
    return nil
}

/// Surfaces whatever the server says about *why* it refused, so a 429 is debuggable
/// from the log instead of being an opaque status code.
func rateLimitDiagnostics(_ http: HTTPURLResponse, _ data: Data?) -> String {
    var bits: [String] = []
    for (k, v) in http.allHeaderFields {
        let key = "\(k)".lowercased()
        guard key.contains("ratelimit") || key == "retry-after" || key == "x-should-retry"
                || key.contains("request-id") else { continue }
        bits.append("\(key)=\(v)")
    }
    if let data = data, !data.isEmpty,
       let body = String(data: data.prefix(200), encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines), !body.isEmpty {
        bits.append("body=\(body.replacingOccurrences(of: "\n", with: " "))")
    }
    return bits.isEmpty ? "" : " [" + bits.sorted().joined(separator: " ") + "]"
}

/// A 429 answer both providers share: honour Retry-After, and fall back to an hour —
/// these endpoints hand out windows on that scale, and retrying sooner just keeps the
/// rolling window pinned open.
func rateLimitedState(_ http: HTTPURLResponse, _ data: Data?, _ who: String) -> FetchState {
    let wait = retryAfter(http) ?? 3600
    log("\(who) fetch http 429 → backing off \(Int(wait))s\(rateLimitDiagnostics(http, data))")
    return .rateLimited(Date().addingTimeInterval(wait))
}

// MARK: - Claude fetch

func fetchClaudeUsage(creds: Credentials, email: String?, completion: @escaping (FetchState) -> Void) {
    var req = URLRequest(url: kUsageURL)
    req.httpMethod = "GET"
    req.setValue("Bearer \(creds.accessToken)", forHTTPHeaderField: "Authorization")
    req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
    req.setValue("claude-code/\(claudeCodeVersion())", forHTTPHeaderField: "User-Agent")
    req.setValue("application/json", forHTTPHeaderField: "Accept")
    req.timeoutInterval = 20

    URLSession.shared.dataTask(with: req) { data, resp, err in
        if let err = err {
            log("claude fetch error: \(err.localizedDescription)")
            completion(.error(err.localizedDescription)); return
        }
        guard let http = resp as? HTTPURLResponse else { completion(.error("no response")); return }
        if http.statusCode == 401 || http.statusCode == 403 {
            log("claude fetch http \(http.statusCode) → needs auth")
            completion(.needsAuth); return
        }
        if http.statusCode == 429 { completion(rateLimitedState(http, data, "claude")); return }
        guard http.statusCode == 200, let data = data,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            log("claude fetch http \(http.statusCode)\(rateLimitDiagnostics(http, data))")
            completion(.error("HTTP \(http.statusCode)")); return
        }

        var metrics: [Metric] = []
        func add(_ id: String, _ name: String, _ w: (pct: Double, resets: Date?)?) {
            guard let w = w else { return }
            metrics.append(Metric(id: id, provider: .claude, name: name,
                                  pct: w.pct, resets: w.resets))
        }
        add("claude.session", "Session", parseWindow(root["five_hour"]))
        add("claude.week", "Week", parseWindow(root["seven_day"]))
        if let m = parseWindow(root["seven_day_opus"]) {
            add("claude.weekModel", "Week Opus", m)
        } else if let m = parseWindow(root["seven_day_sonnet"]) {
            add("claude.weekModel", "Week Sonnet", m)
        }

        log("claude ok " + metrics.map { "\($0.name)=\(Int($0.pct))%" }.joined(separator: " "))
        completion(.ok(ProviderUsage(provider: .claude,
                                     plan: planDisplayName(creds.plan),
                                     email: email,
                                     metrics: metrics,
                                     fetchedAt: Date())))
    }.resume()
}

/// Fetches the signed-in Claude account's email.
func fetchAccountEmail(creds: Credentials, completion: @escaping (String?) -> Void) {
    var req = URLRequest(url: kAccountURL)
    req.setValue("Bearer \(creds.accessToken)", forHTTPHeaderField: "Authorization")
    req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
    req.setValue("claude-code/\(claudeCodeVersion())", forHTTPHeaderField: "User-Agent")
    req.setValue("application/json", forHTTPHeaderField: "Accept")
    req.timeoutInterval = 20
    URLSession.shared.dataTask(with: req) { data, resp, _ in
        guard (resp as? HTTPURLResponse)?.statusCode == 200, let data = data,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let email = root["email_address"] as? String, !email.isEmpty else {
            completion(nil); return
        }
        completion(email)
    }.resume()
}

// MARK: - Codex fetch

func fetchCodexUsage(creds: CodexCredentials, completion: @escaping (FetchState) -> Void) {
    var req = URLRequest(url: kCodexUsageURL)
    req.httpMethod = "GET"
    req.setValue("Bearer \(creds.accessToken)", forHTTPHeaderField: "Authorization")
    if !creds.accountId.isEmpty {
        req.setValue(creds.accountId, forHTTPHeaderField: "chatgpt-account-id")
    }
    req.setValue("codex_cli_rs", forHTTPHeaderField: "originator")
    req.setValue("codex_cli_rs/\(codexVersion())", forHTTPHeaderField: "User-Agent")
    req.setValue("application/json", forHTTPHeaderField: "Accept")
    req.timeoutInterval = 20

    URLSession.shared.dataTask(with: req) { data, resp, err in
        if let err = err {
            log("codex fetch error: \(err.localizedDescription)")
            completion(.error(err.localizedDescription)); return
        }
        guard let http = resp as? HTTPURLResponse else { completion(.error("no response")); return }
        if http.statusCode == 401 || http.statusCode == 403 {
            log("codex fetch http \(http.statusCode) → needs auth")
            completion(.needsAuth); return
        }
        if http.statusCode == 429 { completion(rateLimitedState(http, data, "codex")); return }
        guard http.statusCode == 200, let data = data,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            log("codex fetch http \(http.statusCode)\(rateLimitDiagnostics(http, data))")
            completion(.error("HTTP \(http.statusCode)")); return
        }

        // Only the plan's own window (Codex's `limitId: "codex"` bucket) is shown.
        // `additional_rate_limits` holds caps on individual models and on code review;
        // Codex's own UI lists those too, but they meter one model rather than your
        // subscription — on Pro the 5h clock there belongs to GPT-5.3-Codex-Spark and
        // sits at 0% whether or not you're close to your actual limit, which is noise.
        let limits = (root["rate_limit"] as? [String: Any]) ?? [:]
        var metrics: [Metric] = []
        for key in ["primary_window", "secondary_window"] {
            guard let w = parseCodexWindow(limits[key]), w.span > 0 else { continue }
            let name = windowLabel(w.span)
            metrics.append(Metric(id: "codex.\(slug(name))", provider: .codex, name: name,
                                  pct: w.pct, resets: w.resets))
        }
        metrics.sort { ($0.resets ?? .distantFuture) < ($1.resets ?? .distantFuture) }

        log("codex ok " + metrics.map { "\($0.name)=\(Int($0.pct))%" }.joined(separator: " "))
        completion(.ok(ProviderUsage(provider: .codex,
                                     plan: planDisplayName(root["plan_type"] as? String),
                                     email: root["email"] as? String,
                                     metrics: metrics,
                                     fetchedAt: Date())))
    }.resume()
}

// MARK: - Pure formatting helpers (no AppKit)

func countdown(to date: Date?) -> String {
    guard let date = date else { return "—" }
    let secs = Int(date.timeIntervalSinceNow)
    if secs <= 0 { return "now" }
    let d = secs / 86400, h = (secs % 86400) / 3600, m = (secs % 3600) / 60
    if d > 0 { return "\(d)d \(h)h" }
    if h > 0 { return "\(h)h \(m)m" }
    return "\(m)m"
}

func ago(_ date: Date) -> String {
    let s = Int(-date.timeIntervalSinceNow)
    if s < 60 { return "\(max(0, s))s ago" }
    if s < 3600 { return "\(s / 60)m ago" }
    return "\(s / 3600)h ago"
}

func planDisplayName(_ raw: String?) -> String {
    let s = (raw ?? "").lowercased()
    if s.contains("max") { return "Max" }
    if s == "pro" { return "Pro" }
    if s == "plus" { return "Plus" }
    if s == "team" { return "Team" }
    if s == "business" || s == "enterprise" { return raw!.capitalized }
    if s.isEmpty { return "subscription" }
    return (raw ?? "").capitalized
}
