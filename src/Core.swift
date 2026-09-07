// Core.swift — shared logic for the Cookie Monster 🍪 menu-bar app.
// Foundation-only (no AppKit) so it stays easy to test and reuse.

import Foundation

// MARK: - Constants

let kUsageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
let kAccountURL = URL(string: "https://api.anthropic.com/api/oauth/account")!
let kKeychainService = "Claude Code-credentials"
let kCodexUsageURL = URL(string: "https://chatgpt.com/backend-api/codex/usage")!
let kCodexDir = (NSHomeDirectory() as NSString).appendingPathComponent(".codex")
let kCodexAuthPath = (kCodexDir as NSString).appendingPathComponent("auth.json")
let kLoginPlistLabel = "com.pflugpeil.cookiemonster"
let kPollInterval: TimeInterval = 60
let kLogDir = (NSHomeDirectory() as NSString).appendingPathComponent(".cookie-monster")
let kLogFile = (kLogDir as NSString).appendingPathComponent("cookie-monster.log")
let kVersion = "0.4.0"

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
        guard http.statusCode == 200, let data = data,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            log("claude fetch http \(http.statusCode)")
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
        guard http.statusCode == 200, let data = data,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            log("codex fetch http \(http.statusCode)")
            completion(.error("HTTP \(http.statusCode)")); return
        }

        // Codex reports the same 5h / weekly clocks in several places — the
        // account-wide block, one entry per metered model, and code review. Keep the
        // most-consumed window of each *length*, so the card stays two rows (5h and
        // Weekly) instead of four near-identical bars.
        var worst: [Double: (pct: Double, resets: Date?)] = [:]
        func add(_ w: (pct: Double, span: Double, resets: Date?)?) {
            guard let w = w, w.span > 0 else { return }
            if let cur = worst[w.span], cur.pct >= w.pct { return }
            worst[w.span] = (w.pct, w.resets)
        }

        // The account-wide windows. On some plans (Pro) only `primary_window` is
        // populated and it's the weekly one — the 5h cap lives in the per-model
        // limits below, so parsing just this block would hide it entirely.
        let limits = (root["rate_limit"] as? [String: Any]) ?? [:]
        add(parseCodexWindow(limits["primary_window"]))
        add(parseCodexWindow(limits["secondary_window"]))

        // Per-model caps, e.g. a 5h window on a specific Codex model.
        for entry in (root["additional_rate_limits"] as? [[String: Any]]) ?? [] {
            let rl = (entry["rate_limit"] as? [String: Any]) ?? [:]
            add(parseCodexWindow(rl["primary_window"]))
            add(parseCodexWindow(rl["secondary_window"]))
        }

        // Codex cloud code review has its own budget on some plans.
        if let cr = root["code_review_rate_limit"] as? [String: Any] {
            let rl = (cr["rate_limit"] as? [String: Any]) ?? cr
            add(parseCodexWindow(rl["primary_window"]))
            add(parseCodexWindow(rl["secondary_window"]))
        }

        // Shortest window first — a 5h cap is the one you can actually act on today.
        // The id is derived from the window name, so it stays stable no matter which
        // underlying meter happened to be the most-consumed one.
        let metrics = worst.keys.sorted().map { span -> Metric in
            let name = windowLabel(span)
            return Metric(id: "codex.\(slug(name))", provider: .codex, name: name,
                          pct: worst[span]!.pct, resets: worst[span]!.resets)
        }

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
