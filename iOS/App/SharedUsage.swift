import Foundation
import VigilCore

/// Usage written by the Safari extension and the Screen Time monitor into the shared App Group,
/// and collected by the app on its next sync. Totals are per day, so re-sending is harmless (upsert).
enum SharedUsage {
    static let group = "group.dev.vigil.mobile"
    static var defaults: UserDefaults? { UserDefaults(suiteName: group) }

    /// domain → seconds, per day (from the Safari extension).
    static func addDomain(_ domain: String, seconds: Double, day: String) {
        guard let d = defaults else { return }
        var all = d.dictionary(forKey: "domains.\(day)") as? [String: Double] ?? [:]
        all[domain, default: 0] += seconds
        d.set(all, forKey: "domains.\(day)")
    }

    /// group name → highest 15-minute threshold reached today (from the monitor extension).
    static func setGroup(_ name: String, minutes: Int, day: String) {
        guard let d = defaults else { return }
        var all = d.dictionary(forKey: "groups.\(day)") as? [String: Int] ?? [:]
        all[name] = max(all[name] ?? 0, minutes)
        d.set(all, forKey: "groups.\(day)")
    }

    /// Everything from the last 3 days, as DeviceUsage rows for the Mac.
    static func collect() -> [DeviceUsage] {
        guard let d = defaults else { return [] }
        var out: [DeviceUsage] = []
        for i in 0..<3 {
            let day = DayKey.offset(DayKey.today, days: -i)
            for (domain, secs) in d.dictionary(forKey: "domains.\(day)") as? [String: Double] ?? [:] {
                out.append(DeviceUsage(day: day, kind: .domain, key: domain, seconds: secs, precision: 1, category: nil))
            }
            for (group, mins) in d.dictionary(forKey: "groups.\(day)") as? [String: Int] ?? [:] {
                out.append(DeviceUsage(day: day, kind: .appGroup, key: group, seconds: Double(mins * 60), precision: 900, category: nil))
            }
        }
        // Forget anything older than a week.
        for key in d.dictionaryRepresentation().keys where key.hasPrefix("domains.") || key.hasPrefix("groups.") {
            let day = String(key.split(separator: ".", maxSplits: 1).last ?? "")
            if day < DayKey.offset(DayKey.today, days: -7) { d.removeObject(forKey: key) }
        }
        return out
    }
}
