import AppKit
import VigilCore

/// Reads and redirects browser tabs through AppleScript (Apple Events).
/// The first call to each browser triggers macOS's "Vigil wants to control …" prompt.
final class BrowserBridge {
    enum Flavor { case safari, chromium }

    static let supported: [String: (name: String, flavor: Flavor)] = [
        "com.apple.Safari": ("Safari", .safari),
        "com.apple.SafariTechnologyPreview": ("Safari Technology Preview", .safari),
        "com.google.Chrome": ("Google Chrome", .chromium),
        "com.google.Chrome.beta": ("Chrome Beta", .chromium),
        "com.google.Chrome.dev": ("Chrome Dev", .chromium),
        "com.google.Chrome.canary": ("Chrome Canary", .chromium),
        "org.chromium.Chromium": ("Chromium", .chromium),
        "com.brave.Browser": ("Brave", .chromium),
        "com.microsoft.edgemac": ("Microsoft Edge", .chromium),
        "company.thebrowser.Browser": ("Arc", .chromium),
        "com.vivaldi.Vivaldi": ("Vivaldi", .chromium),
        "com.operasoftware.Opera": ("Opera", .chromium),
    ]

    /// Browsers we can see but not read URLs from (no AppleScript tab support).
    static let titleOnly: Set<String> = ["org.mozilla.firefox", "org.mozilla.firefoxdeveloperedition", "app.zen-browser.zen"]

    struct Tab: Equatable {
        var window: Int
        var index: Int
        var url: String
        var title: String = ""
        /// The tab showing in its window (other tabs in that window are in the background).
        var isActive: Bool = false
    }

    private var cache: [String: NSAppleScript] = [:]
    /// Last Apple Event error per bundle ID, e.g. -1743 (not authorised).
    private(set) var lastError: [String: Int] = [:]

    func isSupported(_ bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return BrowserBridge.supported[bundleID] != nil
    }

    // MARK: - Reading

    func activeTab(bundleID: String) -> (url: String, title: String)? {
        guard let flavor = BrowserBridge.supported[bundleID]?.flavor else { return nil }
        let tabRef = flavor == .safari ? "current tab" : "active tab"
        let titleProp = flavor == .safari ? "name" : "title"
        let source = """
        tell application id "\(bundleID)"
            try
                if (count of windows) is 0 then return ""
                set u to URL of \(tabRef) of front window
                set t to \(titleProp) of \(tabRef) of front window
                if u is missing value then set u to ""
                if t is missing value then set t to ""
                return u & (character id 10) & t
            on error
                return ""
            end try
        end tell
        """
        guard let output = run(source, bundleID: bundleID, cacheable: true), !output.isEmpty else { return nil }
        let parts = output.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        let url = parts.first ?? ""
        let title = parts.count > 1 ? parts[1] : ""
        if url.isEmpty && title.isEmpty { return nil }
        return (url, title)
    }

    /// Every tab in every window. Fetches URLs and titles one window at a time (two Apple Events per
    /// window, not two per tab), so even a few hundred tabs read in tens of milliseconds.
    func allTabs(bundleID: String) -> [Tab] {
        guard let flavor = BrowserBridge.supported[bundleID]?.flavor else { return [] }
        let titleProp = flavor == .safari ? "name" : "title"
        let activeIndex = flavor == .safari ? "index of current tab of w" : "active tab index of w"
        let source = """
        set out to {}
        tell application id "\(bundleID)"
            repeat with wi from 1 to (count of windows)
                set w to window wi
                try
                    set us to URL of every tab of w
                    set ns to {}
                    try
                        set ns to \(titleProp) of every tab of w
                    end try
                    set ai to 0
                    try
                        set ai to \(activeIndex)
                    end try
                    repeat with i from 1 to count of us
                        set u to item i of us
                        if u is not missing value then
                            set n to ""
                            if i is less than or equal to (count of ns) then
                                set n to item i of ns
                                if n is missing value then set n to ""
                            end if
                            set a to "0"
                            if i = ai then set a to "1"
                            set end of out to (wi as text) & (character id 9) & (i as text) & (character id 9) & a & (character id 9) & u & (character id 9) & n
                        end if
                    end repeat
                end try
            end repeat
        end tell
        set AppleScript's text item delimiters to (character id 10)
        set joined to out as text
        set AppleScript's text item delimiters to ""
        return joined
        """
        guard let output = run(source, bundleID: bundleID, cacheable: true) else { return [] }
        return output.split(separator: "\n").compactMap { line in
            let cols = line.split(separator: "\t", maxSplits: 4, omittingEmptySubsequences: false).map(String.init)
            guard cols.count >= 4, let w = Int(cols[0]), let t = Int(cols[1]) else { return nil }
            return Tab(window: w, index: t, url: cols[3], title: cols.count > 4 ? cols[4] : "", isActive: cols[2] == "1")
        }
    }

    // MARK: - Writing

    func redirectActiveTab(bundleID: String, to url: String) {
        guard let flavor = BrowserBridge.supported[bundleID]?.flavor else { return }
        let tabRef = flavor == .safari ? "current tab" : "active tab"
        let source = """
        tell application id "\(bundleID)"
            try
                set URL of \(tabRef) of front window to "\(escape(url))"
            end try
        end tell
        """
        _ = run(source, bundleID: bundleID, cacheable: false)
    }

    func redirect(bundleID: String, tab: Tab, to url: String) {
        let source = """
        tell application id "\(bundleID)"
            try
                set URL of tab \(tab.index) of window \(tab.window) to "\(escape(url))"
            end try
        end tell
        """
        _ = run(source, bundleID: bundleID, cacheable: false)
    }

    func close(bundleID: String, tab: Tab) {
        let source = """
        tell application id "\(bundleID)"
            try
                close tab \(tab.index) of window \(tab.window)
            end try
        end tell
        """
        _ = run(source, bundleID: bundleID, cacheable: false)
    }

    // MARK: - Plumbing

    private func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    private func run(_ source: String, bundleID: String, cacheable: Bool) -> String? {
        let script: NSAppleScript
        if cacheable, let cached = cache[source] {
            script = cached
        } else {
            guard let s = NSAppleScript(source: source) else { return nil }
            var compileError: NSDictionary?
            s.compileAndReturnError(&compileError)
            if compileError != nil { return nil }
            if cacheable { cache[source] = s }
            script = s
        }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if let error {
            lastError[bundleID] = (error[NSAppleScript.errorNumber] as? Int) ?? -1
            return nil
        }
        lastError[bundleID] = nil
        return result.stringValue
    }

    /// Human-readable permission state for the Settings screen.
    func permissionDescription(bundleID: String) -> String {
        switch lastError[bundleID] {
        case nil: return "OK"
        case -1743: return "Not allowed. Enable Vigil in Privacy & Security → Automation"
        case -600: return "Not running"
        case let code?: return "Error \(code)"
        }
    }
}
