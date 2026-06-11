// Core.swift — shared logic for the Cookie Monster 🍪 menu-bar app and CLI.
// Foundation-only (no AppKit) so it compiles into both frontends.

import Foundation

// MARK: - Constants

let kUsageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
let kKeychainService = "Claude Code-credentials"
let kLoginPlistLabel = "com.cookiemonster.usage"
let kPollInterval: TimeInterval = 60
let kLogDir = (NSHomeDirectory() as NSString).appendingPathComponent(".cookie-monster")
let kLogFile = (kLogDir as NSString).appendingPathComponent("cookie-monster.log")
let kVersion = "0.2.0"

// MARK: - Logging (no secrets ever pass through here)

/// Frontends install their own sink. Default is a no-op (used by the CLI).
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

// MARK: - Models

struct UsageWindow {
    var utilization: Double   // 0...100, percent used
    var resetsAt: Date?
}

struct Usage {
    var session: UsageWindow?    // five_hour
    var weekAll: UsageWindow?    // seven_day
    var weekModel: UsageWindow?  // seven_day_opus / seven_day_sonnet
    var weekModelLabel: String?  // "Opus" / "Sonnet"
    var plan: String?
    var fetchedAt: Date
}

enum FetchState {
    case loading
    case ok(Usage)
    case needsAuth          // no token, or 401/403
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

// MARK: - Keychain → access token

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

// MARK: - Usage fetch

func parseDate(_ s: String?) -> Date? {
    guard let s = s else { return nil }
    let f1 = ISO8601DateFormatter()
    f1.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let d = f1.date(from: s) { return d }
    let f2 = ISO8601DateFormatter()
    f2.formatOptions = [.withInternetDateTime]
    return f2.date(from: s)
}

func parseWindow(_ obj: Any?) -> UsageWindow? {
    guard let d = obj as? [String: Any],
          let util = (d["utilization"] as? NSNumber)?.doubleValue else { return nil }
    return UsageWindow(utilization: util, resetsAt: parseDate(d["resets_at"] as? String))
}

func fetchUsage(creds: Credentials, completion: @escaping (FetchState) -> Void) {
    var req = URLRequest(url: kUsageURL)
    req.httpMethod = "GET"
    req.setValue("Bearer \(creds.accessToken)", forHTTPHeaderField: "Authorization")
    req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
    req.setValue("claude-code/\(claudeCodeVersion())", forHTTPHeaderField: "User-Agent")
    req.setValue("application/json", forHTTPHeaderField: "Accept")
    req.timeoutInterval = 20

    URLSession.shared.dataTask(with: req) { data, resp, err in
        if let err = err {
            log("fetch error: \(err.localizedDescription)")
            completion(.error(err.localizedDescription)); return
        }
        guard let http = resp as? HTTPURLResponse else {
            completion(.error("no response")); return
        }
        if http.statusCode == 401 || http.statusCode == 403 {
            log("fetch http \(http.statusCode) → needs auth")
            completion(.needsAuth); return
        }
        guard http.statusCode == 200, let data = data,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            log("fetch http \((resp as? HTTPURLResponse)?.statusCode ?? -1)")
            completion(.error("HTTP \((resp as? HTTPURLResponse)?.statusCode ?? -1)")); return
        }

        var u = Usage(session: nil, weekAll: nil, weekModel: nil,
                      weekModelLabel: nil, plan: creds.plan, fetchedAt: Date())
        u.session = parseWindow(root["five_hour"])
        u.weekAll = parseWindow(root["seven_day"])
        if let m = parseWindow(root["seven_day_opus"]) {
            u.weekModel = m; u.weekModelLabel = "Opus"
        } else if let m = parseWindow(root["seven_day_sonnet"]) {
            u.weekModel = m; u.weekModelLabel = "Sonnet"
        }
        let s = u.session.map { String(format: "%.0f%%", $0.utilization) } ?? "—"
        let w = u.weekAll.map { String(format: "%.0f%%", $0.utilization) } ?? "—"
        log("ok session=\(s) week=\(w)")
        completion(.ok(u))
    }.resume()
}

/// Blocking fetch for the CLI.
func fetchUsageSync(creds: Credentials, timeout: TimeInterval = 25) -> FetchState {
    let sem = DispatchSemaphore(value: 0)
    var result: FetchState = .error("timed out")
    fetchUsage(creds: creds) { result = $0; sem.signal() }
    _ = sem.wait(timeout: .now() + timeout)
    return result
}

// MARK: - Pure formatting helpers (no AppKit)

func bar(_ pct: Double, width: Int = 10) -> String {
    let filled = max(0, min(width, Int((pct / 100.0 * Double(width)).rounded())))
    return String(repeating: "█", count: filled) + String(repeating: "░", count: width - filled)
}

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
    if s == "team" { return "Team" }
    if s.isEmpty { return "subscription" }
    return (raw ?? "").capitalized
}
