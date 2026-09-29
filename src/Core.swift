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
let kLogDir = (NSHomeDirectory() as NSString).appendingPathComponent(".cookie-monster")
let kLogFile = (kLogDir as NSString).appendingPathComponent("cookie-monster.log")
let kVersion = "0.5.0"

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
    case otherProfile(AuthStatus?)  // a non-default profile is active; its token isn't readable
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

// MARK: - Claude profiles (keep two subscriptions signed in, switch between them)

let kClaudeDefaultDir = (NSHomeDirectory() as NSString).appendingPathComponent(".claude")
let kProfilesDir = (kLogDir as NSString).appendingPathComponent("profiles")
let kActiveProfileFile = (kLogDir as NSString).appendingPathComponent("active-profile")

/// Entries that must stay private to a profile: credentials, and anything a running
/// instance locks or owns. Everything else in ~/.claude is symlinked, so MCP servers,
/// settings, skills, plugins, history and preferences are literally the same files.
let kProfilePrivateEntries: Set<String> = [
    ".credentials.json", "daemon", "daemon.status.json", "ipc", "backups",
]

/// Suffixes that must never be symlinked. Claude Code takes its config lock with mkdir(),
/// which on a symlink-to-directory fails EEXIST forever and cannot be broken by rmdir
/// (ENOTDIR) — the CLI then falls through to an *unlocked* rewrite of the shared
/// ~/.claude.json. Matched by pattern because the set keeps growing (.claude.json.lock,
/// .oauth_refresh.lock, .oauth_refresh.lock.owner, .design_oauth_refresh.lock, daemon.lock).
let kProfilePrivateSuffixes = [".lock", ".pid", ".sock", ".lock.owner"]

func isProfilePrivate(_ entry: String) -> Bool {
    if kProfilePrivateEntries.contains(entry) { return true }
    return kProfilePrivateSuffixes.contains { entry.hasSuffix($0) }
}

/// A profile name becomes a directory under kProfilesDir. "." and ".." both survive
/// appendingPathComponent unnormalised, which would build the symlink farm *outside* the
/// profiles directory — into ~/.cookie-monster itself, beside the app's own data.
func isValidProfileName(_ raw: String) -> Bool {
    let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty, name.count <= 40, !name.hasPrefix("."),
          name.lowercased() != "default" else { return false }
    let allowed = CharacterSet(charactersIn:
        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_ ")
    return name.unicodeScalars.allSatisfy { allowed.contains($0) }
}

struct ClaudeProfile {
    let name: String
    let configDir: String
    var isDefault: Bool { configDir == kClaudeDefaultDir }
    /// What CLAUDE_CONFIG_DIR must be for this profile — nil means the variable is unset,
    /// which is the only way to reach the credentials the default profile already has.
    var envConfigDir: String? { isDefault ? nil : configDir }
}

/// What `claude auth status` reports for one config dir. This is Claude Code's own answer,
/// so it stays correct for profiles whose keychain entry we cannot name.
struct AuthStatus {
    var loggedIn: Bool
    var email: String?
    var plan: String?
    var orgName: String?
}

private var cachedCLIPath: String??
func claudeCLIPath() -> String? {
    if let cached = cachedCLIPath { return cached }
    let home = NSHomeDirectory() as NSString
    let candidates = [
        home.appendingPathComponent(".local/bin/claude"),
        "/opt/homebrew/bin/claude",
        "/usr/local/bin/claude",
        home.appendingPathComponent(".bun/bin/claude"),
        home.appendingPathComponent(".npm-global/bin/claude"),
    ]
    var found = candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    // npm/nvm installs land somewhere only the user's PATH knows about.
    if found == nil { found = whichClaudeViaLoginShell() }
    cachedCLIPath = .some(found)
    return found
}

private func whichClaudeViaLoginShell() -> String? {
    let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
    let p = Process()
    p.executableURL = URL(fileURLWithPath: shell)
    p.arguments = ["-lc", "command -v claude"]
    let out = Pipe(); p.standardOutput = out; p.standardError = FileHandle.nullDevice
    p.standardInput = FileHandle.nullDevice
    do { try p.run() } catch { return nil }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    let path = String(data: data, encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return FileManager.default.isExecutableFile(atPath: path) ? path : nil
}

/// `claude auth status` answers differently under CLAUDE_CODE_USE_BEDROCK or an ANTHROPIC_*
/// override — loggedIn with no email — so strip anything that redirects auth before asking.
private func claudeProbeEnv(configDir: String?) -> [String: String] {
    var env = ProcessInfo.processInfo.environment
    for key in env.keys where key.hasPrefix("ANTHROPIC_") || key.hasPrefix("CLAUDE_CODE_")
        || key == "CLAUDE_CONFIG_DIR" {
        env.removeValue(forKey: key)
    }
    // Setting CLAUDE_CONFIG_DIR at all keys a different keychain entry — even when set to
    // ~/.claude itself, which then reads as signed out. The default profile means *unset*.
    if let dir = configDir { env["CLAUDE_CONFIG_DIR"] = dir }
    return env
}

/// True when the user has actually installed the shell function. Without it, switching in
/// the menu changes nothing that `claude` will ever see.
func shellSnippetInstalled() -> Bool {
    for rc in ["~/.zshrc", "~/.zprofile", "~/.bashrc", "~/.bash_profile", "~/.profile"] {
        let path = (rc as NSString).expandingTildeInPath
        if let text = try? String(contentsOfFile: path, encoding: .utf8),
           text.contains("cookie-monster/active-profile") { return true }
    }
    return false
}

/// Runs `claude auth status` for a config dir — pass nil for the default profile.
/// Read-only, and it's how we identify
/// a profile without needing to locate its keychain entry (whose name Claude Code derives
/// from the directory by an undocumented scheme we can't reproduce).
func claudeAuthStatus(configDir: String?, timeout: TimeInterval = 15) -> AuthStatus? {
    guard let cli = claudeCLIPath() else { return nil }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: cli)
    p.arguments = ["auth", "status"]
    p.environment = claudeProbeEnv(configDir: configDir)
    let out = Pipe()
    p.standardOutput = out
    p.standardError = FileHandle.nullDevice
    p.standardInput = FileHandle.nullDevice
    do { try p.run() } catch { return nil }

    // Drain the pipe on another queue: reading inline blocks until EOF, which made the
    // deadline below unreachable and left one hung probe stalling every profile.
    var data = Data()
    let done = DispatchSemaphore(value: 0)
    DispatchQueue.global(qos: .utility).async {
        data = out.fileHandleForReading.readDataToEndOfFile()
        done.signal()
    }
    if done.wait(timeout: .now() + timeout) == .timedOut {
        p.terminate()
        _ = done.wait(timeout: .now() + 2)   // let the reader finish so we never leak it
        p.waitUntilExit()
        log("claude auth status timed out for \(configDir ?? "default")")
        return nil
    }
    p.waitUntilExit()   // `auth status` exits non-zero when signed out, but still prints JSON

    guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
    return AuthStatus(loggedIn: (root["loggedIn"] as? Bool) ?? false,
                      email: root["email"] as? String,
                      plan: root["subscriptionType"] as? String,
                      orgName: root["orgName"] as? String)
}

/// The profiles available to switch between: the real ~/.claude plus any we created.
func listProfiles() -> [ClaudeProfile] {
    var out = [ClaudeProfile(name: "Default", configDir: kClaudeDefaultDir)]
    let entries = (try? FileManager.default.contentsOfDirectory(atPath: kProfilesDir)) ?? []
    for name in entries.sorted() where !name.hasPrefix(".") {
        let dir = (kProfilesDir as NSString).appendingPathComponent(name)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir, isDirectory: &isDir), isDir.boolValue else { continue }
        out.append(ClaudeProfile(name: name, configDir: dir))
    }
    return out
}

/// The configured profile and whether its directory still exists. Callers must NOT quietly
/// fall back to the default when it is missing: the shell function does not fall back, so
/// the app would show the Default account's numbers while every terminal keeps using the
/// other subscription.
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
    do {
        try (configDir + "\n").write(toFile: kActiveProfileFile, atomically: true, encoding: .utf8)
        return true
    } catch { log("could not write active-profile: \(error.localizedDescription)"); return false }
}

/// Builds a profile directory as a symlink farm over ~/.claude, so the new profile shares
/// every setting, MCP server, plugin and session with the default one. Only the
/// credentials differ, because Claude Code keys its keychain entry to the directory path.
/// Existing symlinks are refreshed; real files already in the profile are left alone.
func createProfile(name rawName: String) throws -> ClaudeProfile {
    let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard isValidProfileName(name) else {
        throw NSError(domain: "CookieMonster", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "Use letters, numbers, spaces, - or _ (not \"Default\")."])
    }
    let fm = FileManager.default
    let dir = (kProfilesDir as NSString).appendingPathComponent(name)
    try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)

    func link(_ target: String, _ linkName: String) {
        let dest = (dir as NSString).appendingPathComponent(linkName)
        guard fm.fileExists(atPath: target) else { return }
        if let existing = try? fm.destinationOfSymbolicLink(atPath: dest) {
            if existing == target { return }
            try? fm.removeItem(atPath: dest)
        } else if fm.fileExists(atPath: dest) {
            // A real file Claude Code wrote here — e.g. after the profile dir was deleted and
            // recreated from scratch. Keep it, but move it aside so the profile can be
            // repaired: leaving it in place silently costs the user every MCP server.
            let aside = dest + ".replaced-" + String(Int(Date().timeIntervalSince1970))
            guard (try? fm.moveItem(atPath: dest, toPath: aside)) != nil else { return }
            log("profile \(name): kept \(linkName) as \((aside as NSString).lastPathComponent)")
        }
        try? fm.createSymbolicLink(atPath: dest, withDestinationPath: target)
    }

    // The per-directory equivalent of ~/.claude.json — this is where MCP servers live
    // (4 global plus per-project on this Mac). Note ~/.claude/.claude.json also exists and
    // is NOT the same file: linking that one instead silently loses every MCP server.
    link((NSHomeDirectory() as NSString).appendingPathComponent(".claude.json"), ".claude.json")
    for entry in (try? fm.contentsOfDirectory(atPath: kClaudeDefaultDir)) ?? [] {
        guard !isProfilePrivate(entry), entry != ".claude.json" else { continue }
        link((kClaudeDefaultDir as NSString).appendingPathComponent(entry), entry)
    }
    log("created profile \(name) at \(dir)")
    return ClaudeProfile(name: name, configDir: dir)
}

/// The line a user adds to their shell rc. A function, not an `export`, so it re-reads the
/// active profile on every invocation — switching then applies to terminals already open.
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
