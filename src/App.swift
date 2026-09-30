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
    var claudeGeneration = 0                 // discards fetches issued for a previous profile
    var discoveryAttempted: Set<String> = [] // one keychain search per profile per launch
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

    /// `claude auth status` per profile — the only way to identify one whose keychain entry
    /// we can't name. Subprocess work, so never on the main thread.
    private func refreshProfileIdentities() {
        let profiles = listProfiles(.claude)   // Codex reports identity in its usage payload
        DispatchQueue.global(qos: .utility).async {
            var found: [String: AuthStatus] = [:]
            for p in profiles {
                if let a = claudeAuthStatus(configDir: p.envConfigDir) { found[p.configDir] = a }
            }
            for (dir, auth) in found {
                // The label the user assigned must keep meaning the same subscription, so
                // bind once and never rewrite. A later mismatch is surfaced, not absorbed.
                if let email = auth.email, auth.loggedIn, dir != Provider.claude.defaultConfigDir {
                    bindAccount(dir, email: email)
                }
            }
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
        if active.dir != (lastActiveProfile[.claude] ?? active.dir) {
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
        guard claudeInstalled() || readCredentials() != nil else {
            set(.claude, .notConfigured); return
        }
        if states[.claude] == nil { states[.claude] = .loading }
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
            guard let service = service, let creds = readCredentials(service: service) else {
                DispatchQueue.main.async {
                    if isActive { self.set(.claude, .otherProfile, generation: generation) }
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
                let email = prof.isDefault ? self.claudeEmail : self.profileAuth[dir]?.email
                fetchClaudeUsage(creds: creds, email: email) { result in
                    DispatchQueue.main.async {
                        switch result {
                        case .ok(let u):
                            self.profileUsage[dir] = u
                        case .rateLimited(let until):
                            self.profileBlocked[dir] = until
                        case .needsAuth:
                            // Signing in again makes Claude Code write a brand-new keychain
                            // entry, so a 401 usually means our cached one is stale rather
                            // than that the user is signed out. Drop it and search once more;
                            // only park the profile if that search also fails.
                            if !prof.isDefault, recordedKeychainService(dir) != nil {
                                clearKeychainRecord(dir)
                                self.discoveryAttempted.remove(dir)
                                self.profileBlocked[dir] = Date().addingTimeInterval(30)
                            } else {
                                self.profileBlocked[dir] = Date().addingTimeInterval(kSignedOutBackoff)
                                log("profile \(prof.name) signed out → not retrying for 1h")
                            }
                        default: break
                        }
                        if isActive { self.set(.claude, result, generation: generation) }
                        self.render()
                    }
                }
            }
        }
    }

    /// One silent keychain search per profile per launch; see discoverKeychainService.
    private func attemptDiscovery(_ prof: Profile) {
        let dir = prof.configDir
        guard !prof.isDefault, recordedKeychainService(dir) == nil,
              !discoveryAttempted.contains(dir),
              let expected = boundAccount(dir) ?? profileAuth[dir]?.email else { return }
        discoveryAttempted.insert(dir)
        DispatchQueue.global(qos: .utility).async {
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
        if active.dir != (lastActiveProfile[.codex] ?? active.dir) {
            log("active codex profile → \(active.dir)")
            lastGood[.codex] = nil
            nextAllowed[.codex] = nil
        }
        lastActiveProfile[.codex] = active.dir
        guard !active.missing else {
            set(.codex, .error("profile folder missing — pick another subscription"))
            return
        }
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
            case .notConfigured, .loading, .otherProfile:
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
        let cached = Provider.allCases.compactMap { lastGood[$0] }.flatMap { $0.metrics }
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
        menu.removeAllItems()
        populate(menu)
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
        case .otherProfile:
            // Looked up here, not captured in the state: the probe answers asynchronously.
            let dir = activeProfileDir(p)
            let auth = profileAuth[dir]
            let name = listProfiles(p).first { $0.configDir == dir }?.name ?? "profile"
            disabled(menu, "Claude — \(auth?.email ?? name)", bold: true)
            let detail: String
            if let auth = auth {
                detail = auth.loggedIn ? "usage unavailable for a switched profile"
                                       : "not signed in — run `claude` and /login"
            } else {
                detail = "couldn't identify this profile (is `claude` on your PATH?)"
            }
            disabled(menu, detail, bold: false)
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
        return profiles.map { prof in
            let usage = profileUsage[prof.configDir]
            let pct = usage?.metrics.first { $0.id == pinned }?.pct ?? usage?.metrics.first?.pct
            let bound = prof.isDefault ? nil : boundAccount(prof.configDir)
            let signedInAs = profileAuth[prof.configDir]?.email
            var label = bound
                ?? signedInAs
                ?? usage?.email
                ?? (prof.isDefault && provider == .claude ? (claudeEmail ?? prof.name) : prof.name)
            if let bound = bound, let now = signedInAs,
               bound.caseInsensitiveCompare(now) != .orderedSame {
                label = "\(prof.name): signed in as \(now)"   // never silently relabel
            }
            return InfoCardView.Account(dir: prof.configDir, label: label, pct: pct,
                                        active: prof.configDir == active)
        }
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
        if dir != provider.defaultConfigDir { syncProfile(provider, dir) }
        guard setActiveProfile(provider, dir) else { return }
        log("active \(provider.rawValue) profile set → \(dir)")
        refresh()
        render()
    }

    @objc func setProfile(_ sender: NSMenuItem) {
        guard let pair = sender.representedObject as? [String], pair.count == 2,
              let provider = Provider(rawValue: pair[0]) else { return }
        switchProfile(provider, to: pair[1])
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
    struct Account { let dir: String; let label: String; let pct: Double?; let active: Bool }

    private let title: String
    private let email: String?
    private let accounts: [Account]
    private let onSwitch: (String) -> Void
    private let note: () -> String?
    private let rows: [Row]
    private let fetchedAt: Date
    private let pinnedID: String?
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
    func refresh() { needsDisplay = true }        // recompute countdowns / "Updated …" on redraw

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
                    left(t(a.label, .systemFont(ofSize: 12, weight: a.active ? .semibold : .regular),
                           a.active ? .labelColor : .secondaryLabelColor), x + 14, y)
                    if let pct = a.pct {
                        right(t(String(format: "%.0f%%", pct),
                                .monospacedDigitSystemFont(ofSize: 12, weight: a.active ? .bold : .regular),
                                a.active ? .labelColor : .secondaryLabelColor), w - x, y)
                    } else {
                        right(t("—", .systemFont(ofSize: 12, weight: .regular), .tertiaryLabelColor), w - x, y)
                    }
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
        y += pad + 7
        if paint { NSColor.quaternaryLabelColor.setFill(); NSRect(x: x, y: y, width: cw, height: 1).fill() }
        y += 13
        if paint {
            left(t("Updated \(ago(fetchedAt))", .systemFont(ofSize: 12, weight: .regular), .secondaryLabelColor), x, y)
            if let note = note() {
                right(t(note, .systemFont(ofSize: 12, weight: .medium), .systemOrange), w - x, y)
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
        logHandler = fileLog
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)   // no Dock icon
        app.run()
    }
}
