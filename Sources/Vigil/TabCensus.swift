import AppKit
import VigilCore

/// One open browser tab. Kept in memory only: open tabs are never written to disk.
struct OpenTab: Identifiable, Equatable {
    var browserID: String
    var browserName: String
    var window: Int
    var index: Int
    var domain: String?
    var title: String
    var category: ActivityCategory
    /// Showing in its window. Every other tab is in the background.
    var isActive: Bool
    /// The tab you're looking at right now (active tab of the frontmost browser's front window).
    var isFront: Bool

    var id: String { "\(browserID)#\(window)#\(index)" }
    var isBackground: Bool { !isActive }
}

/// Knows every tab open in every running supported browser, including background tabs and
/// background windows. Cheap: one bulk Apple Event pair per window, and only when a browser is running.
final class TabCensus {
    private let browser: BrowserBridge
    private(set) var tabs: [OpenTab] = []
    private(set) var lastRefresh = Date.distantPast

    /// How often to re-read tabs when nothing prompted it.
    let interval: TimeInterval = 10

    init(browser: BrowserBridge) {
        self.browser = browser
    }

    /// Re-reads tabs if `interval` has passed (or `force`). Returns true if the list changed.
    @discardableResult
    func refresh(categorizer: Categorizer, includeTitles: Bool, now: Date = Date(), force: Bool = false) -> Bool {
        guard force || now.timeIntervalSince(lastRefresh) >= interval else { return false }
        lastRefresh = now
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        var result: [OpenTab] = []
        for app in NSWorkspace.shared.runningApplications {
            guard let id = app.bundleIdentifier, let info = BrowserBridge.supported[id],
                  browser.lastError[id] != -1743 else { continue }  // -1743: user said no to Automation; don't nag
            for tab in browser.allTabs(bundleID: id) {
                let domain = Categorizer.domain(from: tab.url)
                result.append(OpenTab(
                    browserID: id, browserName: info.name, window: tab.window, index: tab.index,
                    domain: domain,
                    title: includeTitles ? tab.title : "",
                    category: domain.map { categorizer.category(appName: info.name, bundleID: id, domain: $0) } ?? .neutral,
                    isActive: tab.isActive,
                    isFront: id == front && tab.window == 1 && tab.isActive))
            }
        }
        guard result != tabs else { return false }
        tabs = result
        return true
    }

    /// Closes every distracting tab except the one you're looking at. Re-reads indexes first and
    /// closes from the highest index down so earlier closes don't shift later ones.
    func closeDistracting(categorizer: Categorizer) -> Int {
        var closed = 0
        for app in NSWorkspace.shared.runningApplications {
            guard let id = app.bundleIdentifier, BrowserBridge.supported[id] != nil else { continue }
            let isFrontApp = id == NSWorkspace.shared.frontmostApplication?.bundleIdentifier
            let targets = browser.allTabs(bundleID: id).filter { tab in
                guard let d = Categorizer.domain(from: tab.url) else { return false }
                if isFrontApp && tab.window == 1 && tab.isActive { return false }
                return categorizer.category(appName: "", bundleID: id, domain: d) == .distracting
            }
            for tab in targets.sorted(by: { ($0.window, $0.index) > ($1.window, $1.index) }) {
                browser.close(bundleID: id, tab: tab)
                closed += 1
            }
        }
        lastRefresh = .distantPast
        return closed
    }

    func close(_ tab: OpenTab) {
        // Confirm the tab at that position is still the same site before closing it.
        let fresh = browser.allTabs(bundleID: tab.browserID)
        if let match = fresh.first(where: { $0.window == tab.window && $0.index == tab.index }),
           Categorizer.domain(from: match.url) == tab.domain {
            browser.close(bundleID: tab.browserID, tab: match)
        }
        lastRefresh = .distantPast
    }
}

extension OpenTab {
    /// Made-up tabs for demo screenshots.
    static let samples: [OpenTab] = {
        let rows: [(String, String, ActivityCategory, Bool, Bool)] = [
            ("developer.apple.com", "SwiftUI | Apple Developer Documentation", .productive, true, true),
            ("github.com", "Pull requests", .productive, false, false),
            ("docs.python.org", "3.13 Documentation", .productive, false, false),
            ("youtube.com", "YouTube", .distracting, false, false),
            ("reddit.com", "r/programming", .distracting, false, false),
            ("calendar.google.com", "Calendar", .neutral, true, false),
            ("x.com", "Home / X", .distracting, false, false),
            ("stackoverflow.com", "How to draw tick marks with Canvas", .productive, false, false),
        ]
        return rows.enumerated().map { i, r in
            OpenTab(browserID: "com.apple.Safari", browserName: "Safari", window: r.3 && !r.4 ? 2 : 1, index: i + 1,
                    domain: r.0, title: r.1, category: r.2, isActive: r.3, isFront: r.4)
        }
    }()
}

extension Array where Element == OpenTab {
    var backgroundCount: Int { filter(\.isBackground).count }
    var distractingCount: Int { filter { $0.category == .distracting }.count }
    var browserCount: Int { Set(map(\.browserID)).count }

    /// One-line summary, e.g. "23 tabs in 2 browsers · 4 distracting".
    var summaryText: String {
        guard !isEmpty else { return "No browser tabs open" }
        var s = "\(count) tab\(count == 1 ? "" : "s")"
        if browserCount > 1 { s += " in \(browserCount) browsers" }
        s += " · \(backgroundCount) in background"
        if distractingCount > 0 { s += " · \(distractingCount) distracting" }
        return s
    }
}
