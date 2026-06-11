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

enum PinnedMetric: String, CaseIterable {
    case session, week, weekModel
}

enum DisplayMode: String, CaseIterable {
    case mono       // black & white template cookie icon + default text color
    case vibrant    // colorful 🍪 emoji + severity-colored percentage
    var label: String { self == .vibrant ? "Vibrant" : "Default" }
}

enum Prefs {
    static let d = UserDefaults.standard

    static var pinned: PinnedMetric {
        get { PinnedMetric(rawValue: d.string(forKey: "pinnedMetric") ?? "") ?? .session }
        set { d.set(newValue.rawValue, forKey: "pinnedMetric") }
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
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let menu = NSMenu()
    var timer: Timer?
    var menuTimer: Timer?                    // ticks while the menu is open
    var liveRefreshers: [() -> Void] = []    // updates time-sensitive rows in place
    var state: FetchState = .loading
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

    let intervalChoices: [(label: String, secs: TimeInterval)] = [
        ("30 seconds", 30), ("1 minute", 60), ("2 minutes", 120),
        ("5 minutes", 300), ("15 minutes", 900),
    ]

    func applicationDidFinishLaunching(_ note: Notification) {
        log("launch (CC version \(claudeCodeVersion()), pin=\(Prefs.pinned.rawValue), every=\(Int(Prefs.interval))s, style=\(Prefs.displayMode.rawValue))")
        statusItem.button?.title = "🍪 …"
        menu.delegate = self          // repopulate on open → fresh "ago"/countdowns
        statusItem.menu = menu
        renderButton()
        refresh()
        startTimer()
    }

    func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: Prefs.interval, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    func refresh() {
        guard let creds = readCredentials() else {
            log("no credentials in keychain")
            state = .needsAuth
            DispatchQueue.main.async { self.render() }
            return
        }
        fetchUsage(creds: creds) { [weak self] result in
            DispatchQueue.main.async { self?.state = result; self?.render() }
        }
    }

    // MARK: UI

    func render() {
        renderButton()
        // The menu rebuilds itself each time it opens (menuNeedsUpdate);
        // update() also refreshes it in place if it happens to be showing.
        menu.update()
    }

    /// The window currently chosen for the menu bar, with a sensible fallback.
    func pinnedWindow(_ u: Usage) -> (win: UsageWindow, name: String)? {
        switch Prefs.pinned {
        case .session:   if let w = u.session  { return (w, "Session") }
        case .week:      if let w = u.weekAll  { return (w, "Week") }
        case .weekModel: if let w = u.weekModel { return (w, "Week \(u.weekModelLabel ?? "")") }
        }
        if let w = u.session { return (w, "Session") }
        if let w = u.weekAll { return (w, "Week") }
        return nil
    }

    func renderButton() {
        switch state {
        case .loading:
            applyButton(text: "…", color: nil, percent: nil)
        case .needsAuth:
            applyButton(text: "⚠", color: .systemRed, percent: nil)
        case .error:
            applyButton(text: "⚠", color: .systemOrange, percent: nil)
        case .ok(let u):
            if let pinned = pinnedWindow(u) {
                applyButton(text: String(format: "%.0f%%", pinned.win.utilization),
                            color: severityColor(pinned.win.utilization),
                            percent: pinned.win.utilization)
            } else {
                applyButton(text: "—", color: nil, percent: nil)
            }
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

    func metricLabel(_ m: PinnedMetric, _ u: Usage?) -> String {
        switch m {
        case .session: return "Session"
        case .week:    return "Week"
        case .weekModel:
            if let lbl = u?.weekModelLabel, !lbl.isEmpty { return "Week \(lbl)" }
            return "Week (model)"
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        populate(menu)
    }

    // While the menu is open, tick the "Updated …" counter (and countdowns) every
    // second. The timer must run in .common mode to fire during menu tracking.
    func menuWillOpen(_ menu: NSMenu) {
        menuTimer?.invalidate()
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.liveRefreshers.forEach { $0() }
        }
        RunLoop.main.add(t, forMode: .common)
        menuTimer = t
    }

    func menuDidClose(_ menu: NSMenu) {
        menuTimer?.invalidate()
        menuTimer = nil
    }

    func populate(_ menu: NSMenu) {
        liveRefreshers.removeAll()
        let mono = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let usage: Usage? = { if case .ok(let u) = state { return u } else { return nil } }()

        func header(_ s: String) {
            let it = NSMenuItem(title: s, action: nil, keyEquivalent: "")
            it.isEnabled = false
            it.attributedTitle = NSAttributedString(string: s, attributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: .bold),
                .foregroundColor: NSColor.secondaryLabelColor,
            ])
            menu.addItem(it)
        }

        func windowRow(_ name: String, _ win: UsageWindow?) {
            let it = NSMenuItem(title: name, action: nil, keyEquivalent: "")
            it.isEnabled = false
            guard let win = win else {
                it.attributedTitle = NSAttributedString(string: "\(name)  —", attributes: [.font: mono])
                menu.addItem(it); return
            }
            let label = name.padding(toLength: 11, withPad: " ", startingAt: 0)
            let make: () -> NSAttributedString = {
                let line = String(format: "%@ %@ %3.0f%%   resets in %@",
                                  label, bar(win.utilization), win.utilization, countdown(to: win.resetsAt))
                let attr = NSMutableAttributedString(string: line, attributes: [
                    .font: mono, .foregroundColor: NSColor.labelColor,
                ])
                if let r = line.range(of: bar(win.utilization)) {
                    attr.addAttribute(.foregroundColor, value: severityColor(win.utilization),
                                      range: NSRange(r, in: line))
                }
                return attr
            }
            it.attributedTitle = make()
            liveRefreshers.append { it.attributedTitle = make() }
            menu.addItem(it)
        }

        switch state {
        case .loading:
            header("Loading…")
        case .needsAuth:
            header("Not signed in")
            let it = NSMenuItem(title: "Open Claude Code and sign in, then Refresh", action: nil, keyEquivalent: "")
            it.isEnabled = false; menu.addItem(it)
        case .error(let msg):
            header("Couldn't reach Claude")
            let it = NSMenuItem(title: msg, action: nil, keyEquivalent: "")
            it.isEnabled = false; menu.addItem(it)
        case .ok(let u):
            header("Claude \(planDisplayName(u.plan))")
            menu.addItem(.separator())
            windowRow("Session", u.session)
            windowRow("Week", u.weekAll)
            if let m = u.weekModel {
                windowRow("Week \(u.weekModelLabel ?? "")".trimmingCharacters(in: .whitespaces), m)
            }
            menu.addItem(.separator())
            let updated = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            updated.isEnabled = false
            let renderUpdated = { updated.title = "Updated \(ago(u.fetchedAt))" }
            renderUpdated()
            liveRefreshers.append(renderUpdated)
            menu.addItem(updated)
        }

        menu.addItem(.separator())
        menu.addItem(item("Refresh Now", #selector(refreshClicked), "r"))
        menu.addItem(item("Open Usage in Browser…", #selector(openUsage), ""))
        menu.addItem(pinSubmenuItem(usage))
        menu.addItem(intervalSubmenuItem())
        menu.addItem(displaySubmenuItem())
        let login = item("Start at Login", #selector(toggleLogin), "")
        login.state = LoginItem.isEnabled ? .on : .off
        menu.addItem(login)
        menu.addItem(.separator())
        menu.addItem(item("Quit Cookie Monster", #selector(quit), "q"))
    }

    func pinSubmenuItem(_ usage: Usage?) -> NSMenuItem {
        let sub = NSMenu()
        for metric in PinnedMetric.allCases {
            let it = NSMenuItem(title: metricLabel(metric, usage), action: #selector(setPinned(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = metric.rawValue
            it.state = (Prefs.pinned == metric) ? .on : .off
            sub.addItem(it)
        }
        let parent = NSMenuItem(title: "Pin to Menu Bar", action: nil, keyEquivalent: "")
        parent.submenu = sub
        return parent
    }

    func intervalSubmenuItem() -> NSMenuItem {
        let sub = NSMenu()
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

    @objc func refreshClicked() { state = .loading; render(); refresh() }
    @objc func openUsage() { NSWorkspace.shared.open(URL(string: "https://claude.ai/settings/usage")!) }

    @objc func setPinned(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let m = PinnedMetric(rawValue: raw) else { return }
        Prefs.pinned = m
        log("pin → \(m.rawValue)")
        render()
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
