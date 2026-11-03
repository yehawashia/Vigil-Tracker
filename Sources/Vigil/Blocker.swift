import AppKit
import VigilCore

/// Enforces the blocklist during focus sessions / schedules, and daily limits at all times.
/// Websites are redirected to a block page; apps are quit.
final class Blocker {
    private let store: VigilStore
    private let browser: BrowserBridge

    private(set) var blocklist: [BlockItem] = []
    private(set) var limits: [DailyLimit] = []
    private(set) var exceededLimits: [DailyLimit] = []
    private(set) var sessionActive = false
    private(set) var reason = ""
    private(set) var until: Date?
    private(set) var locked = false

    var closeTabsInstead = false
    /// Called with (target, reason) whenever something gets blocked.
    var onBlocked: ((String, String) -> Void)?

    private var lastSweep = Date.distantPast
    private var lastLimitCheck = Date.distantPast
    private var lastNotified: [String: Date] = [:]
    private var pendingForceQuit: [pid_t: Date] = [:]

    /// Never block these, so you can't lock yourself out of the system.
    private let protectedBundles: Set<String> = [
        "com.apple.finder", "com.apple.dock", "com.apple.loginwindow", "com.apple.systempreferences",
        "com.apple.SystemSettings", "com.apple.ActivityMonitor", "com.apple.controlcenter",
    ]

    init(store: VigilStore, browser: BrowserBridge) {
        self.store = store
        self.browser = browser
        reload()
    }

    func reload() {
        blocklist = store.blocklist()
        limits = store.limits()
        lastLimitCheck = .distantPast
    }

    var isBlockingActive: Bool { sessionActive || !exceededLimits.isEmpty }

    func update(focus: FocusSession?, schedule: BlockSchedule?, now: Date) {
        if let focus {
            sessionActive = true
            reason = focus.label.map { "Focus session: \($0)" } ?? "Focus session"
            until = focus.end
            locked = focus.locked
        } else if let schedule {
            sessionActive = true
            reason = schedule.label.map { "Scheduled block: \($0)" } ?? "Scheduled block"
            let startOfDay = Calendar.current.startOfDay(for: now)
            var end = startOfDay.addingTimeInterval(Double(schedule.endMinute) * 60)
            if end <= now { end = end.addingTimeInterval(86400) }
            until = end
            locked = false
        } else {
            sessionActive = false
            reason = ""
            until = nil
            locked = false
        }

        if now.timeIntervalSince(lastLimitCheck) > 15 {
            lastLimitCheck = now
            let day = DayKey.string(for: now)
            exceededLimits = limits.filter { limit in
                store.secondsToday(kind: limit.kind, pattern: limit.pattern, day: day) >= Double(limit.minutes) * 60
            }
        }
    }

    // MARK: - Decisions

    func blockReason(domain: String) -> String? {
        if sessionActive, blocklist.contains(where: { $0.kind == .domain && Categorizer.domain(domain, matches: $0.pattern) }) {
            return reason
        }
        if let limit = exceededLimits.first(where: { $0.kind == .domain && Categorizer.domain(domain, matches: $0.pattern) }) {
            return "Daily limit of \(limit.minutes) min reached"
        }
        return nil
    }

    func blockReason(app: NSRunningApplication) -> String? {
        guard app.activationPolicy == .regular else { return nil }
        let bundleID = app.bundleIdentifier
        if let bundleID, bundleID == Bundle.main.bundleIdentifier || protectedBundles.contains(bundleID) { return nil }
        let name = app.localizedName ?? ""
        if sessionActive, blocklist.contains(where: { $0.kind == .app && Categorizer.app(name: name, bundleID: bundleID, matches: $0.pattern) }) {
            return reason
        }
        if let limit = exceededLimits.first(where: { $0.kind == .app && Categorizer.app(name: name, bundleID: bundleID, matches: $0.pattern) }) {
            return "Daily limit of \(limit.minutes) min reached"
        }
        return nil
    }

    // MARK: - Enforcement

    func enforce(snapshot: TrackerSnapshot?, now: Date) {
        guard isBlockingActive else {
            pendingForceQuit.removeAll()
            return
        }

        // 1. Frontmost browser tab (fast path, every tick).
        if let s = snapshot, let bundleID = s.bundleID, let domain = s.domain, let why = blockReason(domain: domain) {
            if closeTabsInstead {
                if let tab = browser.allTabs(bundleID: bundleID).first(where: { Categorizer.domain(from: $0.url) == domain }) {
                    browser.close(bundleID: bundleID, tab: tab)
                }
            } else {
                browser.redirectActiveTab(bundleID: bundleID, to: blockPage(domain: domain, reason: why))
            }
            didBlock(kind: .domain, target: domain, reason: why)
        }

        // 2. Every few seconds: every tab in every running browser, and every running app.
        guard now.timeIntervalSince(lastSweep) >= 3 else { return }
        lastSweep = now

        for app in NSWorkspace.shared.runningApplications {
            if let why = blockReason(app: app) {
                quit(app, now: now)
                didBlock(kind: .app, target: app.localizedName ?? app.bundleIdentifier ?? "app", reason: why)
                continue
            }
            guard let bundleID = app.bundleIdentifier, browser.isSupported(bundleID) else { continue }
            let tabs = browser.allTabs(bundleID: bundleID)
            // Iterate backwards so closing tabs doesn't shift the indexes we still need.
            for tab in tabs.reversed() {
                guard let domain = Categorizer.domain(from: tab.url), let why = blockReason(domain: domain) else { continue }
                if closeTabsInstead {
                    browser.close(bundleID: bundleID, tab: tab)
                } else {
                    browser.redirect(bundleID: bundleID, tab: tab, to: blockPage(domain: domain, reason: why))
                }
                didBlock(kind: .domain, target: domain, reason: why)
            }
        }
    }

    /// Called from NSWorkspace.didLaunchApplicationNotification and on activation.
    func check(app: NSRunningApplication) {
        guard isBlockingActive, let why = blockReason(app: app) else { return }
        quit(app, now: Date())
        didBlock(kind: .app, target: app.localizedName ?? app.bundleIdentifier ?? "app", reason: why)
    }

    private func quit(_ app: NSRunningApplication, now: Date) {
        let pid = app.processIdentifier
        if let firstAttempt = pendingForceQuit[pid], now.timeIntervalSince(firstAttempt) > 5 {
            app.forceTerminate()
            pendingForceQuit[pid] = nil
        } else {
            app.hide()
            app.terminate()
            if pendingForceQuit[pid] == nil { pendingForceQuit[pid] = now }
        }
    }

    private func didBlock(kind: TargetKind, target: String, reason: String) {
        let now = Date()
        // Log and notify at most once a minute per target so the stats mean "attempts", not ticks.
        if let last = lastNotified[target], now.timeIntervalSince(last) < 60 { return }
        lastNotified[target] = now
        store.logBlock(kind: kind, target: target)
        onBlocked?(target, reason)
    }

    // MARK: - Block page

    func blockPage(domain: String, reason: String) -> String {
        let untilText: String
        if let until {
            let f = DateFormatter()
            f.timeStyle = .short
            untilText = "until \(f.string(from: until))"
        } else {
            untilText = "for the rest of today"
        }
        let quotes = [
            "We are what we repeatedly do. Excellence, then, is not an act, but a habit.",
            "Deep work is the superpower of the 21st century.",
            "The successful warrior is the average man, with laser-like focus.",
            "You will never reach your destination if you stop and throw stones at every dog that barks.",
            "Discipline is choosing between what you want now and what you want most.",
        ]
        let quote = quotes[domain.unicodeScalars.reduce(0) { $0 + Int($1.value) } % quotes.count]
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
        }
        let html = """
        <!doctype html><html><head><meta charset="utf-8"><title>Blocked by Vigil</title>
        <style>
        html,body{height:100%;margin:0}
        body{display:flex;align-items:center;justify-content:center;background:#0f1416;color:#e9efe9;
        font:16px/1.5 -apple-system,BlinkMacSystemFont,"SF Pro Text",sans-serif}
        .card{max-width:520px;padding:48px;text-align:center}
        .eye{width:56px;height:56px;border-radius:50%;margin:0 auto 28px;border:3px solid #3fb68b;
        display:flex;align-items:center;justify-content:center}
        .eye i{width:18px;height:18px;border-radius:50%;background:#3fb68b;display:block}
        h1{font-size:30px;font-weight:650;letter-spacing:-.02em;margin:0 0 8px}
        .site{color:#3fb68b}
        p{color:#9fb0aa;margin:6px 0}
        blockquote{margin:36px 0 0;color:#c9d6d1;font-style:italic;border-top:1px solid #23302c;padding-top:24px}
        </style></head><body><div class="card">
        <div class="eye"><i></i></div>
        <h1><span class="site">\(esc(domain))</span> is blocked</h1>
        <p>\(esc(reason)) · \(untilText)</p>
        <blockquote>\(quote)</blockquote>
        </div></body></html>
        """
        return "data:text/html;base64," + Data(html.utf8).base64EncodedString()
    }
}
