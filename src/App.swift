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

final class AppDelegate: NSObject, NSApplicationDelegate {
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    var timer: Timer?
    var state: FetchState = .loading

    func applicationDidFinishLaunching(_ note: Notification) {
        log("launch (CC version \(claudeCodeVersion()))")
        statusItem.button?.title = "🍪 …"
        render()
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: kPollInterval, repeats: true) { [weak self] _ in
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
        statusItem.menu = buildMenu()
    }

    func renderButton() {
        guard let button = statusItem.button else { return }
        switch state {
        case .loading:
            button.title = "🍪 …"
        case .needsAuth:
            button.attributedTitle = attributed("🍪 ⚠", color: .systemRed)
        case .error:
            button.attributedTitle = attributed("🍪 ⚠", color: .systemOrange)
        case .ok(let u):
            if let s = u.session {
                button.attributedTitle = attributed(String(format: "🍪 %.0f%%", s.utilization),
                                                    color: severityColor(s.utilization))
            } else {
                button.title = "🍪 —"
            }
        }
    }

    func attributed(_ s: String, color: NSColor) -> NSAttributedString {
        NSAttributedString(string: s, attributes: [
            .foregroundColor: color,
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
        ])
    }

    func buildMenu() -> NSMenu {
        let menu = NSMenu()
        let mono = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

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
            let line = String(format: "%@ %@ %3.0f%%   resets in %@",
                              label, bar(win.utilization), win.utilization, countdown(to: win.resetsAt))
            let attr = NSMutableAttributedString(string: line, attributes: [
                .font: mono, .foregroundColor: NSColor.labelColor,
            ])
            if let r = line.range(of: bar(win.utilization)) {
                attr.addAttribute(.foregroundColor, value: severityColor(win.utilization),
                                  range: NSRange(r, in: line))
            }
            it.attributedTitle = attr
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
            let updated = NSMenuItem(title: "Updated \(ago(u.fetchedAt))", action: nil, keyEquivalent: "")
            updated.isEnabled = false; menu.addItem(updated)
        }

        menu.addItem(.separator())
        menu.addItem(item("Refresh Now", #selector(refreshClicked), "r"))
        menu.addItem(item("Open Usage in Browser…", #selector(openUsage), ""))
        let login = item("Start at Login", #selector(toggleLogin), "")
        login.state = LoginItem.isEnabled ? .on : .off
        menu.addItem(login)
        menu.addItem(.separator())
        menu.addItem(item("Quit Cookie Monster", #selector(quit), "q"))
        return menu
    }

    func item(_ title: String, _ sel: Selector, _ key: String) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: sel, keyEquivalent: key)
        it.target = self
        return it
    }

    @objc func refreshClicked() { state = .loading; render(); refresh() }
    @objc func openUsage() { NSWorkspace.shared.open(URL(string: "https://claude.ai/settings/usage")!) }
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
