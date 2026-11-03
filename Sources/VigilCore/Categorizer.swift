import Foundation

/// Decides whether a moment of activity is productive, neutral or distracting.
/// Website rules win over app rules; anything unmatched is neutral.
public struct Categorizer {
    private var domainRules: [String: ActivityCategory] = [:]
    private var appRules: [String: ActivityCategory] = [:]

    public init(rules: [CategoryRule]) {
        for rule in rules {
            switch rule.kind {
            case .domain:
                domainRules[Categorizer.normalizeDomainPattern(rule.pattern)] = rule.category
            case .app:
                appRules[rule.pattern.lowercased()] = rule.category
            }
        }
    }

    public func category(appName: String, bundleID: String?, domain: String?) -> ActivityCategory {
        if let domain, let c = category(forDomain: domain) { return c }
        if domain != nil { return .neutral }
        return category(forApp: appName, bundleID: bundleID) ?? .neutral
    }

    public func category(forDomain domain: String) -> ActivityCategory? {
        for candidate in Categorizer.suffixes(of: domain) {
            if let c = domainRules[candidate] { return c }
        }
        return nil
    }

    public func category(forApp name: String, bundleID: String?) -> ActivityCategory? {
        if let bundleID, let c = appRules[bundleID.lowercased()] { return c }
        return appRules[name.lowercased()]
    }

    // MARK: - Helpers shared with the blocker

    /// "https://www.youtube.com/watch?v=1" → "youtube.com". Non-web schemes return nil.
    public static func domain(from urlString: String?) -> String? {
        guard let urlString, let url = URL(string: urlString),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              var host = url.host?.lowercased(), !host.isEmpty else { return nil }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        return host
    }

    /// Strips credentials, and by default the query string and fragment, which often hold
    /// search terms, emails or session tokens. "https://site.com/a?q=secret#x" → "https://site.com/a"
    public static func sanitize(url: String?, keepQuery: Bool) -> String? {
        guard let url, var comps = URLComponents(string: url) else { return url }
        guard let scheme = comps.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return url.hasPrefix("data:") ? nil : url
        }
        comps.user = nil
        comps.password = nil
        if !keepQuery {
            comps.query = nil
            comps.fragment = nil
        }
        return comps.string ?? url
    }

    /// "a.b.example.com" → ["a.b.example.com", "b.example.com", "example.com", "com"]
    public static func suffixes(of domain: String) -> [String] {
        let parts = domain.lowercased().split(separator: ".")
        guard !parts.isEmpty else { return [] }
        return (0..<parts.count).map { parts[$0...].joined(separator: ".") }
    }

    public static func normalizeDomainPattern(_ raw: String) -> String {
        var p = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let range = p.range(of: "://") { p = String(p[range.upperBound...]) }
        if let slash = p.firstIndex(of: "/") { p = String(p[..<slash]) }
        if p.hasPrefix("*.") { p.removeFirst(2) }
        if p.hasPrefix("www.") { p.removeFirst(4) }
        return p
    }

    public static func domain(_ domain: String, matches pattern: String) -> Bool {
        let p = normalizeDomainPattern(pattern)
        guard !p.isEmpty else { return false }
        let d = domain.lowercased()
        return d == p || d.hasSuffix("." + p)
    }

    public static func app(name: String, bundleID: String?, matches pattern: String) -> Bool {
        let p = pattern.trimmingCharacters(in: .whitespaces).lowercased()
        guard !p.isEmpty else { return false }
        if let bundleID, bundleID.lowercased() == p { return true }
        return name.lowercased() == p
    }

    // MARK: - Defaults (editable in the app)

    public static let defaultRules: [(TargetKind, String, ActivityCategory)] = [
        // Productive apps
        (.app, "com.apple.dt.Xcode", .productive),
        (.app, "com.microsoft.VSCode", .productive),
        (.app, "com.todesktop.230313mzl4w4u92", .productive), // Cursor
        (.app, "dev.zed.Zed", .productive),
        (.app, "com.apple.Terminal", .productive),
        (.app, "com.googlecode.iterm2", .productive),
        (.app, "dev.warp.Warp-Stable", .productive),
        (.app, "com.mitchellh.ghostty", .productive),
        (.app, "com.jetbrains.pycharm", .productive),
        (.app, "com.jetbrains.intellij", .productive),
        (.app, "com.sublimetext.4", .productive),
        (.app, "com.anthropic.claudefordesktop", .productive),
        (.app, "md.obsidian", .productive),
        (.app, "notion.id", .productive),
        (.app, "com.apple.iWork.Pages", .productive),
        (.app, "com.apple.iWork.Numbers", .productive),
        (.app, "com.apple.iWork.Keynote", .productive),
        (.app, "com.microsoft.Word", .productive),
        (.app, "com.microsoft.Excel", .productive),
        (.app, "com.microsoft.Powerpoint", .productive),
        (.app, "com.apple.Preview", .productive),
        (.app, "com.apple.Notes", .productive),
        (.app, "com.mathworks.matlab", .productive),
        (.app, "org.R-project.R", .productive),
        (.app, "com.postmanlabs.mac", .productive),
        (.app, "com.docker.docker", .productive),
        (.app, "com.figma.Desktop", .productive),
        // Distracting apps
        (.app, "com.hnc.Discord", .distracting),
        (.app, "com.valvesoftware.steam", .distracting),
        (.app, "com.apple.TV", .distracting),
        (.app, "com.netflix.Netflix", .distracting),
        (.app, "com.apple.Arcade", .distracting),
        (.app, "com.facebook.archon", .distracting),
        // Productive sites
        (.domain, "github.com", .productive),
        (.domain, "gitlab.com", .productive),
        (.domain, "stackoverflow.com", .productive),
        (.domain, "stackexchange.com", .productive),
        (.domain, "developer.apple.com", .productive),
        (.domain, "developer.mozilla.org", .productive),
        (.domain, "docs.python.org", .productive),
        (.domain, "docs.swift.org", .productive),
        (.domain, "swift.org", .productive),
        (.domain, "rust-lang.org", .productive),
        (.domain, "go.dev", .productive),
        (.domain, "w3schools.com", .productive),
        (.domain, "leetcode.com", .productive),
        (.domain, "hackerrank.com", .productive),
        (.domain, "codeforces.com", .productive),
        (.domain, "atcoder.jp", .productive),
        (.domain, "projecteuler.net", .productive),
        (.domain, "kaggle.com", .productive),
        (.domain, "claude.ai", .productive),
        (.domain, "anthropic.com", .productive),
        (.domain, "coursera.org", .productive),
        (.domain, "edx.org", .productive),
        (.domain, "khanacademy.org", .productive),
        (.domain, "brilliant.org", .productive),
        (.domain, "mit.edu", .productive),
        (.domain, "arxiv.org", .productive),
        (.domain, "overleaf.com", .productive),
        (.domain, "docs.google.com", .productive),
        (.domain, "notion.so", .productive),
        (.domain, "investopedia.com", .productive),
        (.domain, "quantstart.com", .productive),
        (.domain, "wolframalpha.com", .productive),
        (.domain, "desmos.com", .productive),
        (.domain, "aws.amazon.com", .productive),
        (.domain, "vercel.com", .productive),
        // Distracting sites
        (.domain, "youtube.com", .distracting),
        (.domain, "tiktok.com", .distracting),
        (.domain, "instagram.com", .distracting),
        (.domain, "facebook.com", .distracting),
        (.domain, "x.com", .distracting),
        (.domain, "twitter.com", .distracting),
        (.domain, "reddit.com", .distracting),
        (.domain, "netflix.com", .distracting),
        (.domain, "twitch.tv", .distracting),
        (.domain, "primevideo.com", .distracting),
        (.domain, "disneyplus.com", .distracting),
        (.domain, "snapchat.com", .distracting),
        (.domain, "pinterest.com", .distracting),
        (.domain, "9gag.com", .distracting),
        (.domain, "espn.com", .distracting),
    ]

    public static let defaultBlocklist: [(TargetKind, String)] = [
        (.domain, "youtube.com"),
        (.domain, "tiktok.com"),
        (.domain, "instagram.com"),
        (.domain, "facebook.com"),
        (.domain, "x.com"),
        (.domain, "twitter.com"),
        (.domain, "reddit.com"),
        (.domain, "netflix.com"),
        (.domain, "twitch.tv"),
    ]
}
