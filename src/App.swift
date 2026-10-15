// App.swift — the menu-bar frontend for Cookie Monster 🍪.

import AppKit
import Foundation

func severityColor(_ pct: Double) -> NSColor {
    switch severity(pct) {
    case .low:    return .systemGreen
    case .medium: return .systemOrange
    case .high:   return .systemRed
    }
}

// MARK: - Preferences (persisted in UserDefaults)

enum DisplayMode: String, CaseIterable {
    case mono       // black & white template gauge + default text color
    case vibrant    // colorful 🍪 emoji + severity-colored percentage
    var label: String { self == .vibrant ? "Vibrant" : "Default" }
}

enum Prefs {
    static let d = UserDefaults.standard

    /// The `Metric.id` shown in the menu bar, e.g. "claude.session" or "codex.primary".
    static var pinnedID: String {
        get {
            if let id = d.string(forKey: "pinnedMetricID"), !id.isEmpty { return id }
            // Migrate 0.3.x, which stored a bare Claude metric name.
            if let old = d.string(forKey: "pinnedMetric"), !old.isEmpty { return "claude.\(old)" }
            return "claude.session"
        }
        set { d.set(newValue, forKey: "pinnedMetricID") }
    }

    static var interval: TimeInterval {
        get { let v = d.double(forKey: "pollInterval"); return v > 0 ? v : kPollInterval }
        set { d.set(newValue, forKey: "pollInterval") }
    }

    static var displayMode: DisplayMode {
        get { DisplayMode(rawValue: d.string(forKey: "displayMode") ?? "") ?? .mono }
        set { d.set(newValue.rawValue, forKey: "displayMode") }
    }
}

// MARK: - Login item (LaunchAgent)

enum LoginItem {
    static var plistPath: String {
        (NSHomeDirectory() as NSString)
            .appendingPathComponent("Library/LaunchAgents/\(kLoginPlistLabel).plist")
    }
    static var isEnabled: Bool { FileManager.default.fileExists(atPath: plistPath) }

    static func enable() {
        guard let exe = Bundle.main.executablePath else { return }
        let plist: [String: Any] = [
            "Label": kLoginPlistLabel,
            "ProgramArguments": [exe],
            "RunAtLoad": true,
            "KeepAlive": false,
            "ProcessType": "Interactive",
        ]
        let dir = (plistPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        if let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0) {
            try? data.write(to: URL(fileURLWithPath: plistPath))
            launchctl(["bootstrap", "gui/\(getuid())", plistPath])
        }
    }

    static func disable() {
        launchctl(["bootout", "gui/\(getuid())/\(kLoginPlistLabel)"])
        try? FileManager.default.removeItem(atPath: plistPath)
    }

    @discardableResult
    static func launchctl(_ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = args
        p.standardOutput = Pipe(); p.standardError = Pipe()
        try? p.run(); p.waitUntilExit()
        return p.terminationStatus
    }
}

// MARK: - App delegate

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var statusItem: NSStatusItem!   // created in applicationDidFinishLaunching (not earlier)
    let menu = NSMenu()
    var timer: Timer?
    var menuTimer: Timer?                    // ticks while the menu is open
    var liveRefreshers: [() -> Void] = []    // updates time-sensitive rows in place
    var grantInFlight = false                  // one "Allow Keychain Access…" at a time
    /// Serial: two discoveries at once could both claim the same keychain entry.
    let discoveryQueue = DispatchQueue(label: "cookie-monster.discovery", qos: .utility)
    var states: [Provider: FetchState] = [:]
    var claudeEmail: String?                 // email of the account behind claudeEmailToken
    var claudeEmailToken: String?            // the access token claudeEmail was resolved from (memory only)
    var claudeEmailInFlight = false          // one /oauth/account lookup at a time
    var lastGood: [Provider: ProviderUsage] = [:]   // survives a 429 so the card stays useful
    var nextAllowed: [Provider: Date] = [:]         // earliest next call, per provider
    var failures: [Provider: Int] = [:]             // consecutive failures → backoff
    var menuIsOpen = false                   // drives the in-place rebuild in render()
    var profileAuth: [String: AuthStatus] = [:]     // keyed by config dir
    var lastActiveProfile: [Provider: String] = [:]
    var lastSwitchAt: [Provider: Date] = [:]        // debounces the switch click
    var openCards: [Provider: InfoCardView] = [:]   // live cards, updated in place
    var claudeGeneration = 0                 // discards fetches issued for a previous profile
    var discoveryAttemptedAt: [String: Date] = [:]  // throttles the keychain search
    var profileUsage: [String: ProviderUsage] = [:]   // usage per profile, for the switcher
    var profileBlocked: [String: Date] = [:]          // per-profile 429 backoff
    var profileFetchedAt: [String: Date] = [:]        // throttles inactive profiles

    /// A monochrome gauge drawn as a template image (so macOS tints it to the menu
    /// bar). The needle reflects `percent`, so it agrees with the number beside it.
    static func makeGaugeIcon(percent: Double) -> NSImage {
        let p = max(0, min(100, percent))
        let img = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { _ in
            NSColor.black.setStroke(); NSColor.black.setFill()
            let c = NSPoint(x: 8, y: 6.6); let r: CGFloat = 6
            let dial = NSBezierPath(); dial.lineWidth = 1.5; dial.lineCapStyle = .round
            dial.appendArc(withCenter: c, radius: r, startAngle: 215, endAngle: -35, clockwise: true)
            dial.stroke()
            let ang = (215 - (p / 100.0) * 250) * Double.pi / 180   // 0% = left, 100% = right
            let needle = NSBezierPath(); needle.lineWidth = 1.3; needle.lineCapStyle = .round
            needle.move(to: c)
            needle.line(to: NSPoint(x: c.x + 4.2 * CGFloat(cos(ang)), y: c.y + 4.2 * CGFloat(sin(ang))))
            needle.stroke()
            NSBezierPath(ovalIn: NSRect(x: c.x - 1.0, y: c.y - 1.0, width: 2.0, height: 2.0)).fill()
            return true
        }
        img.isTemplate = true
        return img
    }

    // No sub-minute option: these endpoints hand out hour-long rate-limit windows, and
    // a 60s poll is what got this app blocked for days.
    let intervalChoices: [(label: String, secs: TimeInterval)] = [
        ("1 minute", 60), ("2 minutes", 120), ("5 minutes", 300),
        ("15 minutes", 900), ("30 minutes", 1800),
    ]

    func applicationDidFinishLaunching(_ note: Notification) {
        clearPersistedStatusItemState()   // always reappear, even if dragged off before
        migrateProfileLayout()            // 0.5.0 kept Claude profiles at profiles/<name>
        migrateLegacyProfiles()           // and as symlink farms, which write into the real config
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.isVisible = true
        log("launch v\(kVersion) (pin=\(Prefs.pinnedID), every=\(Int(Prefs.interval))s, style=\(Prefs.displayMode.rawValue), claude=\(claudeInstalled()), codex=\(codexInstalled()))")
        statusItem.button?.title = "🍪 …"
        menu.delegate = self          // repopulate on open → fresh "ago"/countdowns
        menu.autoenablesItems = false // the usage cards handle their own clicks
        statusItem.menu = menu
        renderButton()
        refresh()
        startTimer()
    }

    /// When you drag the item off the menu bar, macOS persists a per-item
    /// "removed"/hidden/position state under keys prefixed "NSStatusItem …" in the app's
    /// own preferences — which then hides it on every relaunch. Clearing that on launch
    /// guarantees the icon always comes back.
    func clearPersistedStatusItemState() {
        let d = UserDefaults.standard
        for key in d.dictionaryRepresentation().keys where key.hasPrefix("NSStatusItem") {
            d.removeObject(forKey: key)
        }
    }

    func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: Prefs.interval, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    // MARK: Fetching

    func refresh() {
        refreshClaude()
        refreshCodex()
        refreshProfileIdentities()
    }

    /// Who each profile is signed in as, from its files — see claudeProfileIdentity for why
    /// this no longer runs `claude auth status`.
    private func refreshProfileIdentities() {
        let profiles = listProfiles(.claude)   // Codex reports identity in its usage payload
        DispatchQueue.global(qos: .utility).async {
            var found: [String: AuthStatus] = [:]
            for p in profiles { found[p.configDir] = claudeProfileIdentity(p) }
            DispatchQueue.main.async { self.profileAuth = found; self.render() }
        }
    }

    /// True while a provider is inside a Retry-After / backoff window. Calling anyway is
    /// what keeps a rolling rate-limit window pinned open, so every path respects it.
    func isBlocked(_ p: Provider) -> Bool {
        guard let until = nextAllowed[p] else { return false }
        if Date() >= until { nextAllowed[p] = nil; return false }
        return true
    }

    private func refreshClaude() {
        let active = activeProfile(.claude)
        let switched = active.dir != (lastActiveProfile[.claude] ?? active.dir)
        if switched {
            log("active claude profile → \(active.dir)")
            claudeGeneration += 1            // anything in flight belongs to the old profile
            lastGood[.claude] = nil
            nextAllowed[.claude] = nil
            claudeEmail = nil; claudeEmailToken = nil
        }
        lastActiveProfile[.claude] = active.dir
        let generation = claudeGeneration
        guard !active.missing else {
            // The folder is gone, but the shell function does NOT fall back — terminals keep
            // using it. Say so instead of showing the Default account's numbers.
            set(.claude, .error("profile folder missing — pick another subscription"))
            return
        }
        // Attributes only: this runs on the main thread, so it must never wait on a read.
        guard claudeInstalled() || keychainModDate(service: kKeychainService) != nil else {
            set(.claude, .notConfigured); return
        }
        if states[.claude] == nil { states[.claude] = .loading }
        // The switcher already polls every profile, so a switch usually has a recent reading
        // in hand: show it at once. Only on a switch — re-seeding every poll would paper over
        // a rate limit, sign-out or error and reset the backoff. With nothing in hand, don't
        // leave the previous profile's numbers standing as the active state.
        if switched {
            if let cached = profileUsage[active.dir] {
                set(.claude, .ok(cached), generation: generation)
            } else if let until = profileBlocked[active.dir], Date() < until {
                set(.claude, .rateLimited(until), generation: generation)
            } else {
                set(.claude, .loading, generation: generation)
            }
        }
        // Every profile, not just the active one — the switcher shows each subscription's
        // pinned metric, so each needs its own reading.
        for prof in listProfiles(.claude) {
            fetchProfileUsage(prof, isActive: prof.configDir == active.dir, generation: generation)
        }
    }

    /// Reads one profile's usage. The default profile uses the plain keychain service; a
    /// switched profile uses the entry discovered and verified for it.
    private func fetchProfileUsage(_ prof: Profile, isActive: Bool, generation: Int) {
        if let until = profileBlocked[prof.configDir], Date() < until { return }
        if isActive, isBlocked(.claude) { return }
        // An inactive profile only feeds the switcher, so it does not need the active
        // profile's freshness — and these endpoints rate-limit on roughly an hourly quota
        // that is shared with the user's own CLI sessions.
        if !isActive, let last = profileFetchedAt[prof.configDir],
           Date().timeIntervalSince(last) < kInactiveProfileInterval { return }
        let dir = prof.configDir
        profileFetchedAt[dir] = Date()
        DispatchQueue.global(qos: .utility).async {
            let service = prof.isDefault ? kKeychainService : recordedKeychainService(dir)
            guard let service = service, let creds = usableCredentials(service: service) else {
                DispatchQueue.main.async {
                    // Only fall back to the placeholder when there is genuinely nothing to
                    // show. Overwriting a cached reading left the card blank while the
                    // switcher right above it displayed that same profile's percentage.
                    // An unreadable sign-in is the exception: its cached numbers would sit
                    // there looking current, so say what's wrong (the switcher keeps them).
                    let refused = service.map { keychainDeniedServices().contains($0) } ?? false
                    if isActive, self.profileUsage[dir] == nil || refused {
                        self.set(.claude, .otherProfile, generation: generation)
                    }
                    self.attemptDiscovery(prof)
                }
                return
            }
            DispatchQueue.main.async {
                // The default profile's email must come from the token that produced the
                // numbers; a switched profile's comes from `claude auth status`.
                if prof.isDefault, creds.accessToken != self.claudeEmailToken,
                   !self.claudeEmailInFlight {
                    self.claudeEmail = nil
                    self.resolveClaudeEmail(creds)
                }
                // For a non-default profile prefer what the TOKEN says over `claude auth
                // status`, which mirrors ~/.claude.json and has named the wrong account here.
                let email = prof.isDefault ? self.claudeEmail
                                           : (boundAccount(dir) ?? self.profileAuth[dir]?.email)
                fetchClaudeUsage(creds: creds, email: email) { result in
                    DispatchQueue.main.async {
                        var shown = result
                        switch result {
                        case .ok(let u):
                            self.profileUsage[dir] = u
                            if !prof.isDefault, boundAccount(dir) == nil, let e = u.email {
                                bindAccount(dir, email: e)   // token-derived, so authoritative
                            }
                        case .rateLimited(let until):
                            self.profileBlocked[dir] = until
                        case .tokenExpired:
                            break   // free to re-check; no request was made
                        case .needsAuth:
                            // Signing in again makes Claude Code write a brand-new keychain
                            // entry, so a 401 usually means our cached one is stale rather
                            // than that the user is signed out. Drop it and search once more;
                            // only park the profile if that search also fails.
                            if !prof.isDefault, recordedKeychainService(dir) != nil {
                                clearKeychainRecord(dir)
                                self.discoveryAttemptedAt[dir] = nil
                                self.profileBlocked[dir] = Date().addingTimeInterval(30)
                                shown = .otherProfile        // "reading…", not a sign-out
                                self.attemptDiscovery(prof)
                            } else {
                                self.profileBlocked[dir] = Date().addingTimeInterval(kSignedOutBackoff)
                                log("profile \(prof.name) signed out → not retrying for 1h")
                            }
                        default: break
                        }
                        if isActive { self.set(.claude, shown, generation: generation) }
                        self.render()
                    }
                }
            }
        }
    }

    /// The keychain entries the app genuinely needs and has been refused.
    func neededDeniedServices() -> [String] {
        let denied = keychainDeniedServices()
        guard !denied.isEmpty else { return [] }
        var needed = [kKeychainService]
        for prof in listProfiles(.claude) where !prof.isDefault {
            if let s = recordedKeychainService(prof.configDir) { needed.append(s) }
        }
        return needed.filter { denied.contains($0) }
    }

    /// The only place a keychain dialog can come from, and only on an explicit click.
    @objc func allowKeychainAccess() {
        let services = neededDeniedServices()
        guard !services.isEmpty, !grantInFlight else { return }
        let alert = NSAlert()
        alert.messageText = "Allow Cookie Monster to read your Claude sign-in?"
        alert.informativeText = "macOS will ask \(services.count == 1 ? "once" : "\(services.count) times — once per subscription"). "
            + "Choose \u{201C}Always Allow\u{201D} each time.\n\n"
            + "Cookie Monster never asks on its own — this only happens because you clicked."
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        grantInFlight = true
        DispatchQueue.global(qos: .userInitiated).async {
            _ = requestKeychainAccess(services: services)
            DispatchQueue.main.async {
                self.grantInFlight = false
                self.profileFetchedAt.removeAll()    // granted profiles shouldn't wait 15 min
                self.refresh(); self.render()
            }
        }
    }

    /// One silent keychain search per profile per launch; see discoverKeychainService.
    private func attemptDiscovery(_ prof: Profile) {
        let dir = prof.configDir
        guard !prof.isDefault, recordedKeychainService(dir) == nil else { return }
        // Retry on an interval rather than once per launch: a single failed search used to
        // leave the profile dark until the app was restarted.
        if let last = discoveryAttemptedAt[dir], Date().timeIntervalSince(last) < kDiscoveryRetryInterval {
            return
        }
        discoveryAttemptedAt[dir] = Date()
        // No bound account yet means this is the first sighting; discovery binds to whatever
        // the token resolves to.
        let expected = boundAccount(dir)
        discoveryQueue.async {
            let found = discoverKeychainService(profileDir: dir, expectedEmail: expected) { creds, done in
                fetchAccountEmail(creds: creds, completion: done)
            }
            if found != nil { DispatchQueue.main.async { self.refresh() } }
        }
    }


    private func resolveClaudeEmail(_ creds: Credentials) {
        claudeEmailInFlight = true
        let token = creds.accessToken
        fetchAccountEmail(creds: creds) { [weak self] email in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.claudeEmailInFlight = false
                guard let email = email else {
                    // Leave claudeEmailToken unset so the next poll retries. Don't fall back
                    // to ~/.claude.json: it's the source that was showing the wrong account.
                    log("claude: couldn't resolve account for current token; will retry")
                    return
                }
                let onDisk = readClaudeAccount()?.email
                log("claude token → \(email)" + (onDisk != nil && onDisk != email
                    ? " (~/.claude.json says \(onDisk!) — ignoring)" : ""))
                if let previous = self.claudeEmail, previous != email {
                    self.accountSwitched(to: email)
                }
                self.claudeEmail = email
                self.claudeEmailToken = token
                self.render()
            }
        }
    }

    /// A different account means different numbers and a fresh rate-limit budget, so drop
    /// the previous account's cached reading and any backoff we were sitting out.
    private func accountSwitched(to email: String) {
        log("claude account switched → \(email); clearing cache + backoff")
        lastGood[.claude] = nil
        failures[.claude] = 0
        nextAllowed[.claude] = nil
        states[.claude] = .loading
    }

    private func refreshCodex() {
        guard codexInstalled() else { states[.codex] = .notConfigured; return }
        if states[.codex] == nil { states[.codex] = .loading }
        let active = activeProfile(.codex)
        let switched = active.dir != (lastActiveProfile[.codex] ?? active.dir)
        if switched {
            log("active codex profile → \(active.dir)")
            lastGood[.codex] = nil
            nextAllowed[.codex] = nil
        }
        lastActiveProfile[.codex] = active.dir
        guard !active.missing else {
            set(.codex, .error("profile folder missing — pick another subscription"))
            return
        }
        if switched { set(.codex, profileUsage[active.dir].map { .ok($0) } ?? .loading) }
        for prof in listProfiles(.codex) {
            let isActive = prof.configDir == active.dir
            if let until = profileBlocked[prof.configDir], Date() < until { continue }
            if isActive, isBlocked(.codex) { continue }
            if !isActive, let last = profileFetchedAt[prof.configDir],
               Date().timeIntervalSince(last) < kInactiveProfileInterval { continue }
            profileFetchedAt[prof.configDir] = Date()
            // Codex stores credentials in auth.json inside its config dir, so every profile's
            // token is directly readable — no keychain discovery needed.
            guard let creds = readCodexCredentials(dir: prof.isDefault ? nil : prof.configDir) else {
                if isActive {
                    log("codex: no token in \(prof.name)/auth.json")
                    set(.codex, .needsAuth)
                }
                continue
            }
            let dir = prof.configDir
            fetchCodexUsage(creds: creds) { [weak self] result in
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    switch result {
                    case .ok(let u): self.profileUsage[dir] = u
                    case .rateLimited(let until): self.profileBlocked[dir] = until
                    case .needsAuth:
                        self.profileBlocked[dir] = Date().addingTimeInterval(kSignedOutBackoff)
                    default: break
                    }
                    if isActive { self.set(.codex, result) }
                    self.render()
                }
            }
        }
    }

    private func set(_ p: Provider, _ s: FetchState, generation: Int? = nil) {
        DispatchQueue.main.async {
            if let g = generation, g != self.claudeGeneration { return }
            switch s {
            case .ok(let u):
                self.lastGood[p] = u
                self.failures[p] = 0
                self.nextAllowed[p] = nil
            case .rateLimited(let until):
                // Spread the retry so every install doesn't stampede the same second.
                self.nextAllowed[p] = until.addingTimeInterval(Double.random(in: 5...60))
                self.failures[p] = 0
            case .error:
                // Back off geometrically on transient failures, capped at 30 minutes.
                let n = (self.failures[p] ?? 0) + 1
                self.failures[p] = n
                let wait = min(Prefs.interval * pow(2, Double(min(n, 5))), 1800)
                self.nextAllowed[p] = Date().addingTimeInterval(wait)
                log("\(p.rawValue) error #\(n) → retry in \(Int(wait))s")
            case .needsAuth:
                // Re-sending a dead token achieves nothing and spends the account's quota,
                // which is shared with the user's actual CLI sessions. Only a human signing
                // in fixes this, so back off hard and escalate.
                let n = (self.failures[p] ?? 0) + 1
                self.failures[p] = n
                let wait = min(1800 * pow(2, Double(min(n - 1, 3))), 14400)   // 30m → 4h
                self.nextAllowed[p] = Date().addingTimeInterval(wait)
                log("\(p.rawValue) needs sign-in → not retrying for \(Int(wait / 60))m")
            case .tokenExpired, .notConfigured, .loading, .otherProfile:
                self.nextAllowed[p] = nil
            }
            self.states[p] = s
            self.reconcilePin(p)
            self.render()
        }
    }

    /// Metric ids have changed between versions. Once a provider reports successfully we
    /// know its real ids, so rewrite a pin of *that* provider's that no longer resolves —
    /// otherwise it rides `pinnedMetric`'s fallback forever and the stored preference
    /// keeps naming a window that doesn't exist.
    private func reconcilePin(_ p: Provider) {
        guard case .ok(let u)? = states[p], let first = u.metrics.first else { return }
        let id = Prefs.pinnedID
        guard id.hasPrefix("\(p.rawValue)."), !u.metrics.contains(where: { $0.id == id }) else { return }
        Prefs.pinnedID = first.id
        log("pin \(id) no longer exists → \(first.id)")
    }

    // MARK: Derived state

    /// Providers that exist on this Mac, in display order.
    var activeProviders: [Provider] {
        Provider.allCases.filter {
            if case .notConfigured? = states[$0] { return false }
            return states[$0] != nil
        }
    }

    /// Every window we could pin, across all signed-in providers.
    var allMetrics: [Metric] {
        Provider.allCases.flatMap { p -> [Metric] in
            if case .ok(let u)? = states[p] { return u.metrics }
            return []
        }
    }

    private func isNotConfigured(_ s: FetchState) -> Bool {
        if case .notConfigured = s { return true }
        return false
    }

    /// The window shown in the menu bar. Resolution order matters: a provider that is
    /// rate limited has no live metrics, and jumping to the *other* subscription's number
    /// would be worse than showing the pinned one's last known value.
    var pinnedMetric: Metric? {
        let live = allMetrics
        // A rate limit, a network error or a fetch in flight leaves the last reading valid.
        // An unreadable, expired or signed-out sign-in doesn't: showing its old % as current
        // is exactly the "frozen" look.
        let cached = Provider.allCases.filter { p in
            switch states[p] {
            case .rateLimited?, .error?, .loading?: return true
            default: return false
            }
        }.compactMap { lastGood[$0] }.flatMap { $0.metrics }
        let id = Prefs.pinnedID
        if let m = live.first(where: { $0.id == id }) { return m }
        if let m = cached.first(where: { $0.id == id }) { return m }
        // Ids can change between versions — stay on the pinned provider before falling
        // back across subscriptions.
        if let p = Provider(rawValue: id.split(separator: ".").first.map(String.init) ?? "") {
            if let m = live.first(where: { $0.provider == p }) { return m }
            if let m = cached.first(where: { $0.provider == p }) { return m }
            // Present but unreadable (switched profile, signed out, errored). The menu bar
            // carries no label, so another provider's percentage would read as this one's.
            if let st = states[p], !isNotConfigured(st) { return nil }
        }
        return live.first ?? cached.first
    }

    // MARK: UI

    /// `rebuildOpenMenu` is false on the click-to-pin path, where the menu is already
    /// being dismissed and rebuilding it would just churn items on the way out.
    func render(rebuildOpenMenu: Bool = true) {
        renderButton()
        // NSMenu.update() is documented to do nothing unless autoenablesItems is true,
        // and menuNeedsUpdate only fires when a tracking session starts — so a fetch
        // landing while the dropdown is open would otherwise leave it frozen on the
        // old snapshot (including a stale "Updated 3m ago" ticking off a stale date).
        guard rebuildOpenMenu, menuIsOpen else { return }
        // Rebuilding a menu that is being tracked replaces the card views under the pointer,
        // and AppKit then delivers the pending click to the replacement. Update what the
        // cards show instead; the full rebuild happens on the next open.
        for p in Provider.allCases {
            openCards[p]?.update(cardContent(p), accounts: switcherAccounts(p))
        }
        liveRefreshers.forEach { $0() }
    }

    func renderButton() {
        if let m = pinnedMetric {
            applyButton(text: String(format: "%.0f%%", m.pct),
                        color: severityColor(m.pct), percent: m.pct)
            return
        }
        let all = states.values
        if all.contains(where: { if case .loading = $0 { return true }; return false }) || all.isEmpty {
            applyButton(text: "…", color: nil, percent: nil)
        } else if all.contains(where: { if case .tokenExpired = $0 { return true }; return false }) {
            applyButton(text: "↻", color: .systemOrange, percent: nil)
        } else if all.contains(where: { if case .needsAuth = $0 { return true }; return false }) {
            applyButton(text: "⚠", color: .systemRed, percent: nil)
        } else if all.contains(where: { if case .error = $0 { return true }; return false }) {
            applyButton(text: "⚠", color: .systemOrange, percent: nil)
        } else {
            applyButton(text: "—", color: nil, percent: nil)
        }
    }

    /// Draws the menu-bar button for the active display mode.
    /// `color` is the severity tint (Vibrant only); `percent` aims the gauge needle (Default only).
    func applyButton(text: String, color: NSColor?, percent: Double?) {
        guard let button = statusItem.button else { return }
        switch Prefs.displayMode {
        case .vibrant:
            button.image = nil
            button.imagePosition = .noImage
            let s = "🍪 \(text)"
            button.attributedTitle = color.map { attributed(s, color: $0) }
                ?? NSAttributedString(string: s)
        case .mono:
            button.image = AppDelegate.makeGaugeIcon(percent: percent ?? 0)
            button.imagePosition = .imageLeading
            button.imageScaling = .scaleProportionallyUpOrDown
            button.attributedTitle = NSAttributedString(string: " \(text)")  // default text color
        }
    }

    func attributed(_ s: String, color: NSColor) -> NSAttributedString {
        NSAttributedString(string: s, attributes: [
            .foregroundColor: color,
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
        ])
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        populate(menu)
    }

    // While the menu is open, tick the "Updated …" counter (and countdowns) every
    // second. The timer must run in .common mode to fire during menu tracking.
    func menuWillOpen(_ menu: NSMenu) {
        menuIsOpen = true
        menuTimer?.invalidate()
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.liveRefreshers.forEach { $0() }
        }
        RunLoop.main.add(t, forMode: .common)
        menuTimer = t
    }

    func menuDidClose(_ menu: NSMenu) {
        menuIsOpen = false
        menuTimer?.invalidate()
        menuTimer = nil
    }

    // MARK: Menu construction

    func populate(_ menu: NSMenu) {
        liveRefreshers.removeAll()
        openCards.removeAll()

        let providers = activeProviders
        if providers.isEmpty {
            disabled(menu, "Claude Code / Codex not found on this Mac", bold: true)
        }
        for (i, p) in providers.enumerated() {
            if i > 0 { menu.addItem(.separator()) }
            addSection(menu, for: p)
        }

        if Provider.allCases.contains(where: { listProfiles($0).count > 1 }), !shellSnippetInstalled() {
            menu.addItem(.separator())
            disabled(menu, "⚠︎ Shell setup not installed", bold: true)
            disabled(menu, "Switching won't affect `claude`, and signing in will overwrite", bold: false)
            disabled(menu, "your default profile. Use Install Shell Setup.", bold: false)
        }
        if !neededDeniedServices().isEmpty {
            menu.addItem(.separator())
            disabled(menu, "⚠︎ Claude sign-in not readable", bold: true)
            disabled(menu, "Cookie Monster won't ask on its own.", bold: false)
            menu.addItem(item("Allow Keychain Access…", #selector(allowKeychainAccess), ""))
        }
        menu.addItem(.separator())
        menu.addItem(item("Refresh Now", #selector(refreshClicked), "r"))
        for p in providers {
            let title = providers.count > 1 ? "Open \(p.label) Usage…" : "Open Usage in Browser…"
            let it = item(title, #selector(openUsage(_:)), "")
            it.representedObject = p.rawValue
            menu.addItem(it)
        }
        for p in providers { menu.addItem(profileSubmenuItem(p)) }
        menu.addItem(pinSubmenuItem())
        menu.addItem(intervalSubmenuItem())
        menu.addItem(displaySubmenuItem())
        let login = item("Start at Login", #selector(toggleLogin), "")
        login.state = LoginItem.isEnabled ? .on : .off
        menu.addItem(login)
        menu.addItem(.separator())
        menu.addItem(item("Quit Cookie Monster", #selector(quit), "q"))
    }

    private func addSection(_ menu: NSMenu, for p: Provider) {
        switch states[p] ?? .loading {
        case .notConfigured:
            break
        case .loading:
            disabled(menu, "\(p.label) — loading…", bold: true)
        case .needsAuth:
            disabled(menu, "\(p.label) — not signed in", bold: true)
            disabled(menu, p.signInHint, bold: false)
        case .rateLimited(let until):
            // The numbers can't have moved while we're locked out, so the last good card
            // is still the best answer — just say when we'll try again.
            if let u = lastGood[p] {
                addCard(menu, p, u) { [weak self] in
                    guard let t = self?.nextAllowed[p] ?? until as Date? else { return nil }
                    return "rate limited · \(countdown(to: t))"
                }
            } else {
                disabled(menu, "\(p.label) — rate limited", bold: true)
                disabled(menu, "retrying in \(countdown(to: until))", bold: false)
            }
        case .otherProfile where listProfiles(p).count > 1:
            addSwitcherCard(menu, p, note: otherProfileNote(p))
        case .otherProfile:
            // Looked up here, not captured in the state: the probe answers asynchronously.
            let dir = activeProfileDir(p)
            let auth = profileAuth[dir]
            let name = listProfiles(p).first { $0.configDir == dir }?.name ?? "profile"
            disabled(menu, "Claude — \(auth?.email ?? name)", bold: true)
            disabled(menu, otherProfileNote(p), bold: false)
        case .tokenExpired where listProfiles(p).count > 1:
            addSwitcherCard(menu, p, note: "token expired — run `\(p.cliName)` once to refresh it")
        case .tokenExpired:
            disabled(menu, "\(p.label) — token expired", bold: true)
            disabled(menu, "Run `\(p.cliName)` once; it refreshes the token automatically.", bold: false)
        case .needsAuth where listProfiles(p).count > 1:
            addSwitcherCard(menu, p, note: "not signed in — use Copy Sign-in Command")
        case .error(let msg) where listProfiles(p).count > 1 && lastGood[p] == nil:
            addSwitcherCard(menu, p, note: msg)
        case .error(let msg):
            if let u = lastGood[p] {
                addCard(menu, p, u) { "couldn't refresh" }
            } else {
                disabled(menu, "\(p.label) — couldn't reach usage API", bold: true)
                disabled(menu, msg, bold: false)
            }
        case .ok(let u):
            addCard(menu, p, u)
        }
    }

    /// The subscriptions the switcher offers, each showing the pinned metric for that account.
    private func switcherAccounts(_ provider: Provider) -> [InfoCardView.Account] {
        let profiles = listProfiles(provider)
        guard profiles.count > 1 else { return [] }
        let active = activeProfileDir(provider)
        let pinned = Prefs.pinnedID
        var seen: [String: String] = [:]      // account -> first profile holding it
        return profiles.map { prof in
            let usage = profileUsage[prof.configDir]
            let metrics = usage?.metrics ?? []
            let pinnedMetric = metrics.first { $0.id == pinned } ?? metrics.first
            let pct = pinnedMetric?.pct
            // The longest window that isn't the pinned one — the two rarely coincide.
            let secondary = metrics.last { $0.id != pinnedMetric?.id }?.pct
            let bound = prof.isDefault ? nil : boundAccount(prof.configDir)
            // The default profile's address from the token beats ~/.claude.json's.
            let tokenEmail = prof.isDefault
                ? ((provider == .claude ? claudeEmail : nil) ?? usage?.email) : nil
            let signedInAs = tokenEmail ?? profileAuth[prof.configDir]?.email
            let account = bound ?? signedInAs ?? usage?.email
                ?? (prof.isDefault && provider == .claude ? claudeEmail : nil)
            // Lead with the label the user assigned; the account follows it.
            var label = account.map { "\(prof.name) — \($0)" } ?? prof.name
            if let bound = bound, let now = signedInAs,
               bound.caseInsensitiveCompare(now) != .orderedSame {
                label = "\(prof.name) — signed in as \(now)"   // never silently relabel
            }
            let identity = prof.isDefault ? tokenEmail : (bound ?? usage?.email)
            if let account = identity, !prof.isDefault,
               let dup = seen[account.lowercased()] {
                // Two profiles on one account look like two subscriptions but aren't — say so
                // rather than letting the user believe they are switching between plans.
                label = "\(prof.name) — same account as \(dup)"
            }
            if let account = identity { seen[account.lowercased()] = prof.name }
            return InfoCardView.Account(dir: prof.configDir, label: label, pct: pct,
                                        secondary: secondary,
                                        active: prof.configDir == active)
        }
    }

    /// A card with the switcher but no usage rows, so a profile that can't be read yet still
    /// lets you pick a different one without hunting through the submenu.
    private func addSwitcherCard(_ menu: NSMenu, _ p: Provider, note: String) {
        let card = InfoCardView(title: p.label, email: nil, rows: [], fetchedAt: Date(),
                                note: { note },
                                accounts: switcherAccounts(p),
                                onSwitch: { [weak self] dir in self?.switchProfile(p, to: dir) },
                                pinnedID: nil, onPick: { _ in })
        let entry = NSMenuItem()
        entry.isEnabled = true
        entry.view = card
        liveRefreshers.append { [weak card] in card?.refresh() }
        openCards[p] = card
        menu.addItem(entry)
    }

    /// What an open card should show right now, mirroring addSection's card cases, so a
    /// switch or a fetch landing while the menu is open updates the card in place.
    private func cardContent(_ p: Provider) -> InfoCardView.Content {
        func usage(_ u: ProviderUsage, _ note: @escaping () -> String?) -> InfoCardView.Content {
            InfoCardView.Content(
                title: "\(u.provider.label) \(u.plan)",
                email: (p == .claude ? claudeEmail : nil) ?? u.email,
                rows: u.metrics.map { .init(id: $0.id, name: $0.name, pct: $0.pct, resets: $0.resets) },
                fetchedAt: u.fetchedAt, note: note, pinnedID: pinnedMetric?.id)
        }
        func bare(_ note: String) -> InfoCardView.Content {
            InfoCardView.Content(title: p.label, email: nil, rows: [], fetchedAt: Date(),
                                 note: { note }, pinnedID: nil)
        }
        switch states[p] ?? .loading {
        case .ok(let u):
            return usage(u) { nil }
        case .rateLimited(let until):
            if let u = lastGood[p] {
                return usage(u) { [weak self] in
                    "rate limited · \(countdown(to: self?.nextAllowed[p] ?? until))"
                }
            }
            return bare("rate limited · retrying in \(countdown(to: until))")
        case .error(let msg):
            if let u = lastGood[p] { return usage(u) { "couldn't refresh" } }
            return bare(msg)
        case .otherProfile:
            return bare(otherProfileNote(p))
        case .tokenExpired:
            return bare("token expired — run `\(p.cliName)` once to refresh it")
        case .needsAuth:
            return bare("not signed in — use Copy Sign-in Command")
        case .loading:
            return bare("loading…")
        case .notConfigured:
            return bare("")
        }
    }

    /// Reads as progress, not failure: locating a switched profile's credentials takes a
    /// couple of seconds, and "usage unavailable" looked like a permanent error.
    private func otherProfileNote(_ p: Provider) -> String {
        let dir = activeProfileDir(p)
        // A sign-in we may not read without asking would otherwise sit at "reading…" forever.
        if p == .claude, let prof = listProfiles(p).first(where: { $0.configDir == dir }),
           let service = prof.isDefault ? kKeychainService : recordedKeychainService(dir),
           keychainDeniedServices().contains(service) {
            return "can't read this sign-in without asking — see below"
        }
        guard let auth = profileAuth[dir] else { return "identifying this profile…" }
        return auth.loggedIn ? "reading this profile's usage…"
                             : "not signed in — use Copy Sign-in Command"
    }

    private func addCard(_ menu: NSMenu, _ p: Provider, _ u: ProviderUsage,
                         note: @escaping () -> String? = { nil }) {
        let rows = u.metrics.map {
            InfoCardView.Row(id: $0.id, name: $0.name, pct: $0.pct, resets: $0.resets)
        }
        // claudeEmail arrives on its own request, so prefer the freshest value.
        let email = (p == .claude ? claudeEmail : nil) ?? u.email
        let card = InfoCardView(title: "\(u.provider.label) \(u.plan)",
                                email: email,
                                rows: rows,
                                fetchedAt: u.fetchedAt,
                                note: note,
                                accounts: switcherAccounts(p),
                                onSwitch: { [weak self] dir in self?.switchProfile(p, to: dir) },
                                pinnedID: pinnedMetric?.id) { [weak self] id in
            self?.pick(id)
        }
        let cardItem = NSMenuItem()
        cardItem.isEnabled = true
        cardItem.view = card
        liveRefreshers.append { [weak card] in card?.refresh() }
        openCards[p] = card
        menu.addItem(cardItem)
    }

    private func disabled(_ menu: NSMenu, _ s: String, bold: Bool) {
        let it = NSMenuItem(title: s, action: nil, keyEquivalent: "")
        it.isEnabled = false
        it.attributedTitle = NSAttributedString(string: s, attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: bold ? .bold : .regular),
            .foregroundColor: bold ? NSColor.secondaryLabelColor : NSColor.tertiaryLabelColor,
        ])
        menu.addItem(it)
    }

    /// Lists every pinnable window, grouped by provider.
    /// Switch which subscription `claude` uses. Each profile is a config dir holding COPIES
    /// of your config — never symlinks — and Claude Code keys its keychain entry to the
    /// directory path, which is what keeps both accounts signed in at once.
    func profileSubmenuItem(_ provider: Provider) -> NSMenuItem {
        let sub = NSMenu()
        sub.autoenablesItems = false
        let active = activeProfileDir(provider)
        for prof in listProfiles(provider) {
            let auth = profileAuth[prof.configDir]
            var title = prof.name
            if let email = auth?.email, !email.isEmpty {
                title += " — \(email)"
            } else if let auth = auth {
                // `claude auth status` reports email only when ~/.claude.json still carries
                // oauthAccount; it is frequently null. Say what we do know.
                title += auth.loggedIn ? " — signed in\(auth.plan.map { " (\($0.capitalized))" } ?? "")"
                                       : " — not signed in"
            }
            let it = NSMenuItem(title: title, action: #selector(setProfile(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = [provider.rawValue, prof.configDir]
            it.state = (prof.configDir == active) ? .on : .off
            sub.addItem(it)
        }
        sub.addItem(.separator())
        if listProfiles(provider).count > 1 && !shellSnippetInstalled() {
            disabled(sub, "⚠︎ Shell setup not installed — switching won't affect `claude`", bold: false)
        }
        if let activeProfile = listProfiles(provider).first(where: { $0.configDir == active }) {
            let ren = item("Rename “\(activeProfile.name)”…", #selector(renameProfile(_:)), "")
            ren.representedObject = [provider.rawValue, activeProfile.configDir]
            sub.addItem(ren)
        }
        let signIn = item("Copy Sign-in Command…", #selector(copySignIn(_:)), "")
        signIn.representedObject = [provider.rawValue, activeProfileDir(provider)]
        sub.addItem(signIn)
        let add = item("Add Subscription…", #selector(addProfile(_:)), "")
        add.representedObject = provider.rawValue
        sub.addItem(add)
        sub.addItem(item(shellSnippetInstalled() ? "Shell Setup (installed)" : "Install Shell Setup…",
                         #selector(installShellSetup), ""))
        let parent = NSMenuItem(title: "\(provider.label) Subscription", action: nil, keyEquivalent: "")
        parent.submenu = sub
        return parent
    }

    func pinSubmenuItem() -> NSMenuItem {
        let sub = NSMenu()
        sub.autoenablesItems = false
        let current = pinnedMetric?.id
        var shown = 0
        for p in Provider.allCases {
            guard case .ok(let u)? = states[p], !u.metrics.isEmpty else { continue }
            if shown > 0 { sub.addItem(.separator()) }
            disabled(sub, "\(u.provider.label) \(u.plan)", bold: true)
            for m in u.metrics {
                let it = NSMenuItem(title: "\(m.name) — \(String(format: "%.0f%%", m.pct))",
                                    action: #selector(setPinned(_:)), keyEquivalent: "")
                it.target = self
                it.representedObject = m.id
                it.state = (current == m.id) ? .on : .off
                sub.addItem(it)
            }
            shown += 1
        }
        if shown == 0 { disabled(sub, "Nothing to pin yet", bold: false) }
        let parent = NSMenuItem(title: "Pin to Menu Bar", action: nil, keyEquivalent: "")
        parent.submenu = sub
        return parent
    }

    func intervalSubmenuItem() -> NSMenuItem {
        let sub = NSMenu()
        sub.autoenablesItems = false
        for choice in intervalChoices {
            let it = NSMenuItem(title: choice.label, action: #selector(setInterval(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = choice.secs
            it.state = (abs(Prefs.interval - choice.secs) < 0.5) ? .on : .off
            sub.addItem(it)
        }
        let parent = NSMenuItem(title: "Update Every", action: nil, keyEquivalent: "")
        parent.submenu = sub
        return parent
    }

    func displaySubmenuItem() -> NSMenuItem {
        let sub = NSMenu()
        sub.autoenablesItems = false
        for mode in DisplayMode.allCases {
            let it = NSMenuItem(title: mode.label, action: #selector(setDisplayMode(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = mode.rawValue
            it.state = (Prefs.displayMode == mode) ? .on : .off
            sub.addItem(it)
        }
        let parent = NSMenuItem(title: "Menu Bar Style", action: nil, keyEquivalent: "")
        parent.submenu = sub
        return parent
    }

    func item(_ title: String, _ sel: Selector, _ key: String) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: sel, keyEquivalent: key)
        it.target = self
        return it
    }

    // MARK: Actions

    func pick(_ id: String) {
        Prefs.pinnedID = id
        log("pin → \(id)")
        render(rebuildOpenMenu: false)
    }

    @objc func refreshClicked() {
        // Only providers we will actually call: one inside its Retry-After window returns at
        // the isBlocked guard, so marking it .loading would strand the card there.
        for p in activeProviders where !isBlocked(p) { states[p] = .loading }
        render(); refresh()
    }

    @objc func openUsage(_ sender: NSMenuItem) {
        let p = (sender.representedObject as? String).flatMap(Provider.init(rawValue:)) ?? .claude
        NSWorkspace.shared.open(p.usageURL)
    }

    @objc func setPinned(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        pick(id)
    }

    func switchProfile(_ provider: Provider, to dir: String) {
        // Rebuilding the menu from inside the click handler re-creates the card while the
        // event is still being dispatched, and the replacement view receives the same click —
        // which looked like the selection flipping back a second later. Ignore a second
        // switch that arrives faster than a person can click twice.
        if let last = lastSwitchAt[provider], Date().timeIntervalSince(last) < 0.6 { return }
        lastSwitchAt[provider] = Date()

        if dir != provider.defaultConfigDir { syncProfile(provider, dir) }
        guard setActiveProfile(provider, dir) else { return }
        log("active \(provider.rawValue) profile set → \(dir)")
        refresh()
        renderButton()
        // In place, never a rebuild: the menu stays exactly as it is, so no view is replaced
        // under the cursor and no click can be re-delivered.
        for p in Provider.allCases {
            openCards[p]?.update(cardContent(p), accounts: switcherAccounts(p))
        }
    }

    @objc func setProfile(_ sender: NSMenuItem) {
        guard let pair = sender.representedObject as? [String], pair.count == 2,
              let provider = Provider(rawValue: pair[0]) else { return }
        switchProfile(provider, to: pair[1])
    }

    @objc func renameProfile(_ sender: NSMenuItem) {
        guard let pair = sender.representedObject as? [String], pair.count == 2,
              let provider = Provider(rawValue: pair[0]) else { return }
        let dir = pair[1]
        let current = listProfiles(provider).first { $0.configDir == dir }?.name ?? ""
        let alert = NSAlert()
        alert.messageText = "Rename subscription"
        alert.informativeText = "Only the label changes. The account signed into this profile, "
            + "its settings and its credentials all stay exactly where they are."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = current
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        guard setProfileDisplayName(dir, field.stringValue) else {
            let fail = NSAlert()
            fail.messageText = "Couldn't rename"
            fail.informativeText = "Use up to 40 characters on a single line."
            fail.alertStyle = .warning
            NSApp.activate(ignoringOtherApps: true)
            fail.runModal()
            return
        }
        render()
    }

    @objc func copySignIn(_ sender: NSMenuItem) {
        guard let pair = sender.representedObject as? [String], pair.count == 2,
              let provider = Provider(rawValue: pair[0]) else { return }
        let dir = pair[1]
        let cmd = signInCommand(provider, profileDir: dir)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(cmd, forType: .string)
        let name = listProfiles(provider).first { $0.configDir == dir }?.name ?? "this profile"
        let alert = NSAlert()
        alert.messageText = "Sign-in command copied"
        alert.informativeText = "Paste it in a terminal to sign \(name) in:\n\n\(cmd)\n\n"
            + "It names the profile explicitly, so the login can't land on a different one. "
            + "Plain `\(provider.cliName) \(provider == .claude ? "/login" : "login")` always "
            + "writes to your default profile and would overwrite whatever account is there."
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    @objc func addProfile(_ sender: NSMenuItem) {
        let provider = (sender.representedObject as? String).flatMap(Provider.init(rawValue:)) ?? .claude
        let alert = NSAlert()
        alert.messageText = "Add a \(provider.label) subscription"
        alert.informativeText = "Creates a profile holding a copy of your settings and MCP servers — only the "
            + "Claude account differs. Your own config is never modified.\n\n"
            + "After switching to it, run `claude` once and sign in with the other "
            + "subscription. Both stay signed in from then on."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.placeholderString = "work"
        alert.accessoryView = field
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            _ = try createProfile(provider, name: field.stringValue)   // validates; "." / ".." escape
            refresh(); render()
        } catch {
            log("createProfile failed: \(error.localizedDescription)")
            let fail = NSAlert()
            fail.messageText = "Couldn't create that profile"
            fail.informativeText = error.localizedDescription
            fail.alertStyle = .warning
            NSApp.activate(ignoringOtherApps: true)
            fail.runModal()
        }
    }

    @objc func installShellSetup() {
        if shellSnippetInstalled() {
            copyShellSetup(); return          // already in place — just hand over the text
        }
        let confirm = NSAlert()
        confirm.messageText = "Add the shell functions to your shell config?"
        confirm.informativeText = "This appends two functions (`claude` and `codex`) to your "
            + "rc file so switching subscriptions affects the command line. Your current file "
            + "is backed up first.\n\nWithout them, switching only changes this menu — and "
            + "signing in writes to your default profile whichever one you selected."
        confirm.addButton(withTitle: "Install")
        confirm.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard confirm.runModal() == .alertFirstButtonReturn else { return }

        let result = installShellSnippet()
        log("shell setup install: \(result.ok ? "ok" : "failed")")
        let done = NSAlert()
        done.messageText = result.ok ? "Shell setup installed" : "Couldn't install shell setup"
        done.informativeText = result.message
        done.alertStyle = result.ok ? .informational : .warning
        NSApp.activate(ignoringOtherApps: true)
        done.runModal()
        render()
    }

    @objc func copyShellSetup() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(kShellSnippet, forType: .string)
        log("copied shell setup snippet")
        let alert = NSAlert()
        alert.messageText = "Shell setup copied"
        alert.informativeText = "Paste it into ~/.zshrc (or ~/.bashrc), then open a new terminal.\n\n"
            + "It re-reads the active subscription every time you run `claude`, so switching "
            + "applies to terminals that are already open.\n\n"
            + "It only covers `claude` run from a shell. Editor integrations that launch the "
            + "binary directly keep using your default subscription."
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    @objc func setInterval(_ sender: NSMenuItem) {
        guard let secs = sender.representedObject as? TimeInterval else { return }
        Prefs.interval = secs
        log("interval → \(Int(secs))s")
        startTimer()
        render()
    }

    @objc func setDisplayMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let m = DisplayMode(rawValue: raw) else { return }
        Prefs.displayMode = m
        log("display → \(m.rawValue)")
        render()
    }

    @objc func toggleLogin() {
        if LoginItem.isEnabled { LoginItem.disable() } else { LoginItem.enable() }
        render()
    }
    @objc func quit() { NSApp.terminate(nil) }
}

// MARK: - Info card (custom-drawn dropdown section: plan, email, usage bars, updated)

final class InfoCardView: NSView {
    struct Row { let id: String; let name: String; let pct: Double; let resets: Date? }
    /// One switchable subscription, with the pinned metric's value for that account.
    struct Account {
        let dir: String; let label: String
        let pct: Double?        // the pinned metric
        let secondary: Double?  // the next window, so two accounts can't look identical
        let active: Bool
    }

    /// Everything the card shows apart from the switcher; swapped in place on a switch.
    struct Content {
        var title: String
        var email: String?
        var rows: [Row]
        var fetchedAt: Date
        var note: () -> String?
        var pinnedID: String?
    }

    private var title: String
    private var email: String?
    private var accounts: [Account]
    private let onSwitch: (String) -> Void
    private var note: () -> String?
    private var rows: [Row]
    private var fetchedAt: Date
    private var pinnedID: String?
    private let onPick: (String) -> Void
    /// Filled during layout so a click can find the row underneath it.
    private var hitRects: [(rect: NSRect, id: String)] = []
    private var accountRects: [(rect: NSRect, dir: String)] = []

    init(title: String, email: String?, rows: [Row], fetchedAt: Date, note: @escaping () -> String? = { nil },
         accounts: [Account] = [], onSwitch: @escaping (String) -> Void = { _ in },
         pinnedID: String?, onPick: @escaping (String) -> Void) {
        self.title = title; self.email = email; self.rows = rows; self.note = note
        self.accounts = accounts; self.onSwitch = onSwitch
        self.fetchedAt = fetchedAt; self.pinnedID = pinnedID; self.onPick = onPick
        super.init(frame: NSRect(x: 0, y: 0, width: 300, height: 10))
        setFrameSize(NSSize(width: 300, height: layout(false)))   // exact fit to content
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }        // lay out top→down
    func refresh() { needsDisplay = true }

    /// Swap in new switcher data without rebuilding the menu. Rebuilding replaces this view
    /// while the menu is tracking, and the replacement receives the in-flight click — which
    /// is what made a selection flip back a second or two later.
    func updateAccounts(_ next: [Account]) {
        accounts = next
        needsDisplay = true
    }

    /// Swap in another profile's bars, title and note — same reason as updateAccounts. The
    /// height follows the content so a profile with more (or no) rows isn't clipped.
    func update(_ c: Content, accounts next: [Account]) {
        title = c.title; email = c.email; rows = c.rows; fetchedAt = c.fetchedAt
        note = c.note; pinnedID = c.pinnedID; accounts = next
        let h = layout(false)
        if abs(h - frame.height) > 0.5 {
            setFrameSize(NSSize(width: frame.width, height: h))
            if let item = enclosingMenuItem { item.menu?.itemChanged(item) }
        }
        needsDisplay = true
    }        // recompute countdowns / "Updated …" on redraw

    // Clicking a usage row pins it to the menu bar, then closes the menu.
    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let acct = accountRects.first(where: { $0.rect.contains(p) }) {
            // Deliberately does NOT dismiss: switching is something you may do twice in a
            // row, and the card re-renders in place so the new account's numbers appear
            // under the cursor.
            onSwitch(acct.dir)
            return
        }
        guard let hit = hitRects.first(where: { $0.rect.contains(p) }) else { return }
        enclosingMenuItem?.menu?.cancelTracking()
        onPick(hit.id)
    }

    private func t(_ s: String, _ f: NSFont, _ c: NSColor) -> NSAttributedString {
        NSAttributedString(string: s, attributes: [.font: f, .foregroundColor: c])
    }
    private func left(_ s: NSAttributedString, _ x: CGFloat, _ y: CGFloat) { s.draw(at: NSPoint(x: x, y: y)) }
    private func right(_ s: NSAttributedString, _ rx: CGFloat, _ y: CGFloat) { s.draw(at: NSPoint(x: rx - s.size().width, y: y)) }

    /// A small "PINNED" pill marking the row that's showing in the menu bar.
    private let resetHeight: CGFloat = 15
    private func pill(_ x: CGFloat, _ y: CGFloat) {
        let s = t("PINNED", .systemFont(ofSize: 9, weight: .bold), .controlAccentColor)
        let r = NSRect(x: x, y: y, width: s.size().width + 12, height: resetHeight)
        NSColor.controlAccentColor.withAlphaComponent(0.15).setFill()
        NSBezierPath(roundedRect: r, xRadius: 7.5, yRadius: 7.5).fill()
        s.draw(at: NSPoint(x: x + 6, y: y + 3))
    }

    /// Single source of truth for layout: with `paint` false it only advances `y`
    /// (so the frame fits exactly); with `paint` true it draws.
    @discardableResult
    private func layout(_ paint: Bool) -> CGFloat {
        hitRects.removeAll()
        let x: CGFloat = 16, w = bounds.width, cw = w - x * 2
        var y: CGFloat = 13
        accountRects.removeAll()
        if paint { left(t(title, .systemFont(ofSize: 13, weight: .bold), .secondaryLabelColor), x, y) }
        y += accounts.count > 1 ? 23 : 18   // the switcher's tint needs air under the title
        if accounts.count > 1 {
            // A switcher, not a label: each row is the account plus its pinned metric, and
            // clicking one makes it the subscription `claude` uses.
            for a in accounts {
                let block = NSRect(x: x - 8, y: y - 4, width: cw + 16, height: 22)
                accountRects.append((block, a.dir))
                if paint {
                    if a.active {
                        NSColor.controlAccentColor.withAlphaComponent(0.12).setFill()
                        NSBezierPath(roundedRect: block, xRadius: 6, yRadius: 6).fill()
                    }
                    let dot = NSRect(x: x, y: y + 4, width: 6, height: 6)
                    (a.active ? NSColor.controlAccentColor : NSColor.quaternaryLabelColor).setFill()
                    NSBezierPath(ovalIn: dot).fill()
                    // Two subscriptions often sit at a similar value on one window, so show
                    // the next one too — otherwise identical numbers read as a bug.
                    var valueWidth: CGFloat = 0
                    if let second = a.secondary {
                        let secondText = t(String(format: "%.0f%%", second),
                                           .monospacedDigitSystemFont(ofSize: 11, weight: .regular),
                                           .tertiaryLabelColor)
                        right(secondText, w - x, y + 1)
                        valueWidth = secondText.size().width + 7
                    }
                    let value = a.pct.map { String(format: "%.0f%%", $0) } ?? "—"
                    let valueText = t(value,
                                      .monospacedDigitSystemFont(ofSize: 12, weight: a.active ? .bold : .regular),
                                      a.pct == nil ? .tertiaryLabelColor
                                                   : (a.active ? .labelColor : .secondaryLabelColor))
                    right(valueText, w - x - valueWidth, y)
                    valueWidth += valueText.size().width
                    // Clip the label to the space left over, so renaming to something long
                    // can never overlap the number.
                    let labelX = x + 14
                    let avail = (w - x) - valueWidth - 10 - labelX
                    let para = NSMutableParagraphStyle()
                    para.lineBreakMode = .byTruncatingTail
                    NSAttributedString(string: a.label, attributes: [
                        .font: NSFont.systemFont(ofSize: 12, weight: a.active ? .semibold : .regular),
                        .foregroundColor: a.active ? NSColor.labelColor : NSColor.secondaryLabelColor,
                        .paragraphStyle: para,
                    ]).draw(in: NSRect(x: labelX, y: y, width: max(40, avail), height: 16))
                }
                y += 24
            }
        } else if let email = email {
            if paint { left(t(email, .systemFont(ofSize: 12, weight: .regular), .tertiaryLabelColor), x, y) }
            y += 18
        }
        y += 10
        if paint { NSColor.quaternaryLabelColor.setFill(); NSRect(x: x, y: y, width: cw, height: 1).fill() }
        y += 15
        // Row geometry. The pinned row's tint wraps the whole row, so the block has to
        // be derived from the same numbers the content uses — hard-coding its height is
        // how it ended up with 7pt above the label and 1pt below the reset line.
        let nameH: CGFloat = 16, barH: CGFloat = 8, resetH = resetHeight
        let gap: CGFloat = 9, pad: CGFloat = 7
        let rowH = nameH + gap + barH + gap + resetH

        for (i, r) in rows.enumerated() {
            let isPinned = (r.id == pinnedID)
            let block = NSRect(x: x - 8, y: y - pad, width: cw + 16, height: rowH + pad * 2)
            hitRects.append((block, r.id))
            if paint {
                if isPinned {
                    NSColor.controlAccentColor.withAlphaComponent(0.10).setFill()
                    NSBezierPath(roundedRect: block, xRadius: 8, yRadius: 8).fill()
                }
                let name = t(r.name, .systemFont(ofSize: 13, weight: isPinned ? .semibold : .medium), .labelColor)
                left(name, x, y)
                right(t(String(format: "%.0f%%", r.pct), .monospacedDigitSystemFont(ofSize: 13, weight: .bold), .labelColor), w - x, y)
            }
            y += nameH + gap
            if paint {
                let bh = barH
                NSColor.quaternaryLabelColor.setFill()
                NSBezierPath(roundedRect: NSRect(x: x, y: y, width: cw, height: bh), xRadius: bh/2, yRadius: bh/2).fill()
                let fw = max(bh, cw * CGFloat(min(100, max(0, r.pct)) / 100))
                severityColor(r.pct).setFill()
                NSBezierPath(roundedRect: NSRect(x: x, y: y, width: fw, height: bh), xRadius: bh/2, yRadius: bh/2).fill()
            }
            y += barH + gap
            if paint {
                if isPinned { pill(x, y) }
                right(t("resets in \(countdown(to: r.resets))", .systemFont(ofSize: 12, weight: .medium), .secondaryLabelColor), w - x, y)
            }
            y += resetH
            if i < rows.count - 1 { y += 16 }
        }
        if !rows.isEmpty {
            y += pad + 7
            if paint { NSColor.quaternaryLabelColor.setFill(); NSRect(x: x, y: y, width: cw, height: 1).fill() }
        }
        y += 13
        if paint {
            if !rows.isEmpty {
                left(t("Updated \(ago(fetchedAt))", .systemFont(ofSize: 12, weight: .regular), .secondaryLabelColor), x, y)
            }
            if let note = note() {
                let style = t(note, .systemFont(ofSize: 12, weight: .medium),
                              rows.isEmpty ? .secondaryLabelColor : .systemOrange)
                if rows.isEmpty { left(style, x, y) } else { right(style, w - x, y) }
            }
        }
        y += 16 + 13
        return y
    }
    override func draw(_ dirtyRect: NSRect) { layout(true) }
}

// MARK: - Entry

@main
struct CookieMonsterApp {
    static func main() {
        // Before anything can touch the keychain: this app never shows a keychain dialog on
        // its own. See disableKeychainPrompts().
        disableKeychainPrompts()
        // One copy only. Enabling Start at Login bootstraps a second one immediately, and two
        // copies would each poll — and each be able to start a keychain read.
        let me = ProcessInfo.processInfo.processIdentifier
        if let id = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: id)
               .contains(where: { $0.processIdentifier != me }) {
            exit(0)
        }
        logHandler = fileLog
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)   // no Dock icon
        app.run()
    }
}
