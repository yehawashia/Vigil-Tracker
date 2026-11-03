import Foundation

public enum VigilPaths {
    /// ~/Library/Application Support/Vigil, readable only by you (0700).
    public static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return privateDirectory(base.appendingPathComponent("Vigil", isDirectory: true))
    }

    public static var databaseURL: URL {
        supportDirectory.appendingPathComponent("vigil.sqlite")
    }

    public static var reportsDirectory: URL {
        privateDirectory(supportDirectory.appendingPathComponent("Reports", isDirectory: true))
    }

    @discardableResult
    static func privateDirectory(_ url: URL) -> URL {
        let fm = FileManager.default
        try? fm.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }

    /// Restricts a data file (and its SQLite WAL/SHM companions) to owner read/write (0600).
    public static func restrictFile(_ path: String) {
        for suffix in ["", "-wal", "-shm"] {
            let p = path + suffix
            if FileManager.default.fileExists(atPath: p) {
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: p)
            }
        }
    }
}

public enum ActivityCategory: String, Codable, CaseIterable, Identifiable {
    case productive
    case neutral
    case distracting

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .productive: return "Productive"
        case .neutral: return "Neutral"
        case .distracting: return "Distracting"
        }
    }

    /// Weight used for the 0–100 productivity score.
    public var weight: Double {
        switch self {
        case .productive: return 1.0
        case .neutral: return 0.5
        case .distracting: return 0.0
        }
    }
}

public enum TargetKind: String, Codable, CaseIterable, Identifiable {
    case domain
    case app

    public var id: String { rawValue }
    public var label: String { self == .domain ? "Website" : "App" }
}

public struct ActivityRecord: Codable, Identifiable, Hashable {
    public var id: Int64
    public var start: Date
    public var end: Date
    public var appName: String
    public var bundleID: String?
    public var windowTitle: String?
    public var url: String?
    public var domain: String?
    public var category: ActivityCategory

    public var duration: TimeInterval { max(0, end.timeIntervalSince(start)) }
}

public struct CategoryRule: Codable, Identifiable, Hashable {
    public var id: Int64
    public var kind: TargetKind
    public var pattern: String
    public var category: ActivityCategory
}

public struct BlockItem: Codable, Identifiable, Hashable {
    public var id: Int64
    public var kind: TargetKind
    public var pattern: String
}

public struct DailyLimit: Codable, Identifiable, Hashable {
    public var id: Int64
    public var kind: TargetKind
    public var pattern: String
    public var minutes: Int
}

public struct FocusSession: Codable, Identifiable, Hashable {
    public var id: Int64
    public var start: Date
    public var end: Date
    public var locked: Bool
    public var label: String?
    public var endedEarly: Date?
    public var createdBy: String?

    public var effectiveEnd: Date { endedEarly ?? end }
    public var plannedMinutes: Int { Int(end.timeIntervalSince(start) / 60) }

    public func isActive(at now: Date = Date()) -> Bool {
        endedEarly == nil && start <= now && now < end
    }

    public func remaining(at now: Date = Date()) -> TimeInterval {
        max(0, end.timeIntervalSince(now))
    }
}

/// A recurring block window, e.g. weekdays 09:00–12:00.
public struct BlockSchedule: Codable, Identifiable, Hashable {
    public var id: Int64
    /// Calendar weekday numbers, 1 = Sunday … 7 = Saturday.
    public var weekdays: [Int]
    public var startMinute: Int
    public var endMinute: Int
    public var enabled: Bool
    public var label: String?

    public func isActive(at date: Date = Date(), calendar: Calendar = .current) -> Bool {
        guard enabled else { return false }
        let weekday = calendar.component(.weekday, from: date)
        let minute = calendar.component(.hour, from: date) * 60 + calendar.component(.minute, from: date)
        if startMinute <= endMinute {
            return weekdays.contains(weekday) && minute >= startMinute && minute < endMinute
        }
        // Overnight window (e.g. 22:00–02:00): the part after midnight belongs to the previous day.
        if minute >= startMinute { return weekdays.contains(weekday) }
        let previous = weekday == 1 ? 7 : weekday - 1
        return minute < endMinute && weekdays.contains(previous)
    }

    public var timeRangeText: String {
        func fmt(_ m: Int) -> String { String(format: "%02d:%02d", m / 60, m % 60) }
        return "\(fmt(startMinute))–\(fmt(endMinute))"
    }

    public var weekdaysText: String {
        let names = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
        let set = Set(weekdays)
        if set == [2, 3, 4, 5, 6] { return "Weekdays" }
        if set == [1, 7] { return "Weekends" }
        if set.count == 7 { return "Every day" }
        return weekdays.sorted().compactMap { (1...7).contains($0) ? names[$0 - 1] : nil }.joined(separator: " ")
    }
}

public struct UsageItem: Codable, Identifiable, Hashable {
    public var name: String
    public var detail: String?
    public var seconds: Double
    public var category: ActivityCategory
    public var id: String { name }
}

public struct DaySummary: Codable, Hashable {
    public var day: String
    public var activeSeconds: Double
    public var productiveSeconds: Double
    public var neutralSeconds: Double
    public var distractingSeconds: Double
    public var score: Int
    public var topApps: [UsageItem]
    public var topDomains: [UsageItem]
    /// 24 buckets, seconds per category per hour.
    public var hourly: [HourBucket]
    public var focusSessionsCompleted: Int
    public var focusMinutes: Int
    public var blockedAttempts: Int
    public var firstActivity: Date?
    public var lastActivity: Date?
    public var contextSwitches: Int

    public static func empty(day: String) -> DaySummary {
        DaySummary(day: day, activeSeconds: 0, productiveSeconds: 0, neutralSeconds: 0, distractingSeconds: 0,
                   score: 0, topApps: [], topDomains: [],
                   hourly: (0..<24).map { HourBucket(hour: $0, productive: 0, neutral: 0, distracting: 0) },
                   focusSessionsCompleted: 0, focusMinutes: 0, blockedAttempts: 0,
                   firstActivity: nil, lastActivity: nil, contextSwitches: 0)
    }

    public func seconds(for category: ActivityCategory) -> Double {
        switch category {
        case .productive: return productiveSeconds
        case .neutral: return neutralSeconds
        case .distracting: return distractingSeconds
        }
    }
}

public struct HourBucket: Codable, Hashable, Identifiable {
    public var hour: Int
    public var productive: Double
    public var neutral: Double
    public var distracting: Double
    public var id: Int { hour }
}

public enum DayKey {
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    public static func string(for date: Date) -> String {
        formatter.string(from: date)
    }

    public static func date(from key: String) -> Date? {
        formatter.date(from: key)
    }

    public static var today: String { string(for: Date()) }

    public static func offset(_ key: String, days: Int) -> String {
        guard let d = date(from: key),
              let shifted = Calendar.current.date(byAdding: .day, value: days, to: d) else { return key }
        return string(for: shifted)
    }

    /// Accepts "today", "yesterday", "YYYY-MM-DD", or "-N" (N days ago).
    public static func resolve(_ input: String?) -> String {
        guard let raw = input?.trimmingCharacters(in: .whitespaces).lowercased(), !raw.isEmpty else { return today }
        if raw == "today" { return today }
        if raw == "yesterday" { return offset(today, days: -1) }
        if raw.hasPrefix("-"), let n = Int(raw.dropFirst()) { return offset(today, days: -n) }
        if date(from: raw) != nil { return raw }
        return today
    }
}

public enum DurationText {
    /// "2h 05m", "14m", "45s"
    public static func short(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        if s < 60 { return "\(s)s" }
        let h = s / 3600
        let m = (s % 3600) / 60
        if h == 0 { return "\(m)m" }
        return String(format: "%dh %02dm", h, m)
    }

    /// "24:10" countdown style
    public static func clock(_ seconds: Double) -> String {
        let s = max(0, Int(seconds.rounded()))
        let h = s / 3600
        let m = (s % 3600) / 60
        let sec = s % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, sec) }
        return String(format: "%02d:%02d", m, sec)
    }
}
