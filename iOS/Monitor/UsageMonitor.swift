import DeviceActivity
import Foundation
import ManagedSettings

/// Runs in its own tiny process when Screen Time thresholds are reached.
/// It only ever learns "group X reached N minutes today"; Apple never reveals which apps.
final class UsageMonitor: DeviceActivityMonitor {
    override func eventDidReachThreshold(_ event: DeviceActivityEvent.Name, activity: DeviceActivityName) {
        super.eventDidReachThreshold(event, activity: activity)
        let parts = event.rawValue.split(separator: "|")
        guard parts.count == 3, parts[0] == "g", let minutes = Int(parts[2]) else { return }
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.locale = Locale(identifier: "en_US_POSIX")
        let day = f.string(from: Date())
        let d = UserDefaults(suiteName: "group.dev.vigil.mobile")
        var all = d?.dictionary(forKey: "groups.\(day)") as? [String: Int] ?? [:]
        all[String(parts[1])] = max(all[String(parts[1])] ?? 0, minutes)
        d?.set(all, forKey: "groups.\(day)")
    }

    /// A focus window ended: lift every shield, even if the app isn't running.
    override func intervalDidEnd(for activity: DeviceActivityName) {
        super.intervalDidEnd(for: activity)
        if activity.rawValue == "vigil.focus" { ManagedSettingsStore().clearAllSettings() }
    }
}
