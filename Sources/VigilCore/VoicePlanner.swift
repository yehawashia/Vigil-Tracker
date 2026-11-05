import Foundation

/// Turns a spoken sentence into a timetable item, entirely on device.
///
///   "Essay draft tomorrow from 2 to 4pm, block distractions"  → block, tomorrow 14:00–16:00
///   "Call mum at 6 for 20 minutes"                            → task, today 18:00–18:20
///   "Revise statistics for an hour"                           → to-do in the task panel, 60 min estimate
///
/// Dates and times come from Apple's NSDataDetector (locale-aware); durations and the
/// "focus" intent from small keyword rules. Anything without a time goes to the task panel.
public struct VoicePlan: Equatable {
    public var title: String
    public var start: Date?
    public var end: Date?
    public var minutes: Int?
    public var focus: Bool

    /// The item to add: scheduled (task/block) when a time was heard, otherwise an unscheduled to-do.
    public func item() -> TimetableItem {
        if let start {
            let end = self.end ?? start.addingTimeInterval(Double(minutes ?? 60) * 60)
            return TimetableItem(title: title, start: start, end: end, kind: focus ? .block : .task)
        }
        return TimetableItem(title: title, start: Date(), end: Date(), kind: .todo, estimate: minutes, wantsFocus: focus)
    }
}

public enum VoicePlanner {
    static let focusPhrases = ["block distractions", "block distraction", "no distractions", "without distractions",
                               "focus block", "deep work", "focus mode", "lock in", "in focus", "with focus", "focus"]
    static let fillerPrefixes = ["please ", "can you ", "could you ", "schedule ", "add ", "put ", "plan ", "remind me to ",
                                 "i need to ", "i have to ", "i want to ", "block time for ", "block out time for ", "time block "]

    public static func parse(_ raw: String, now: Date = Date(), calendar: Calendar = .current) -> VoicePlan? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        var lower = text.lowercased()

        // 1. Focus intent.
        var focus = false
        for p in focusPhrases where lower.contains(p) {
            focus = true
            text = text.replacingOccurrences(of: p, with: " ", options: .caseInsensitive)
            lower = text.lowercased()
            if p != "focus" { break }
        }

        // 2. Duration: "for 90 minutes", "for 2 hours", "for an hour", "for half an hour", "for 1.5 hours".
        var minutes: Int?
        let durationPatterns: [(String, (String) -> Int?)] = [
            (#"for (\d+(?:\.\d+)?) ?(?:hours?|hrs?|h)\b"#, { Double($0).map { Int(($0 * 60).rounded()) } }),
            (#"for (\d+) ?(?:minutes?|mins?|m)\b"#, { Int($0) }),
            (#"for (?:an|one) hour and a half\b"#, { _ in 90 }),
            (#"for half an hour\b"#, { _ in 30 }),
            (#"for (?:an|one) hour\b"#, { _ in 60 }),
            (#"for (?:a|one) quarter of an hour\b"#, { _ in 15 }),
        ]
        for (pattern, value) in durationPatterns {
            guard let re = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
                  let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let r = Range(m.range, in: text) else { continue }
            let captured = m.numberOfRanges > 1 ? Range(m.range(at: 1), in: text).map { String(text[$0]) } ?? "" : ""
            minutes = value(captured)
            text.removeSubrange(r)
            break
        }

        // 3. Date / time / range via NSDataDetector.
        var start: Date?, end: Date?
        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue),
           let match = detector.matches(in: text, range: NSRange(text.startIndex..., in: text)).first,
           let date = match.date, let r = Range(match.range, in: text) {
            start = date
            if match.duration > 0 { end = date.addingTimeInterval(match.duration) }
            text.removeSubrange(r)
            // A time with no day that's already passed today means the next occurrence.
            if let s = start, s < now.addingTimeInterval(-60), calendar.isDate(s, inSameDayAs: now),
               !raw.lowercased().contains("today") {
                start = calendar.date(byAdding: .day, value: 1, to: s)
                end = end.flatMap { calendar.date(byAdding: .day, value: 1, to: $0) }
            }
            // "tomorrow" alone (midnight, no time spoken) means a day, not a time: keep it unscheduled.
            if let s = start, calendar.component(.hour, from: s) == 0, calendar.component(.minute, from: s) == 0,
               !lower.contains("midnight"), match.duration == 0 {
                start = nil
            }
        }
        if let s = start, end == nil, let m = minutes { end = s.addingTimeInterval(Double(m) * 60) }
        if let s = start, let e = end, e <= s { end = s.addingTimeInterval(3600) }

        // 4. Title: what's left, minus filler words and dangling joiners.
        var title = text.replacingOccurrences(of: #"[,.;:!?]+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        var changed = true
        while changed {
            changed = false
            for f in fillerPrefixes where title.lowercased().hasPrefix(f) {
                title = String(title.dropFirst(f.count)); changed = true
            }
            for suffix in [" from", " at", " on", " for", " and", " with", " to", " by", " during", " a"]
                where title.lowercased().hasSuffix(suffix) {
                title = String(title.dropLast(suffix.count)); changed = true
            }
            for prefix in ["a ", "an ", "the "] where title.lowercased().hasPrefix(prefix) && title.split(separator: " ").count > 2 {
                title = String(title.dropFirst(prefix.count)); changed = true
            }
            title = title.trimmingCharacters(in: .whitespaces)
        }
        guard !title.isEmpty else { return nil }
        title = title.prefix(1).uppercased() + title.dropFirst()
        return VoicePlan(title: String(title.prefix(200)), start: start, end: end, minutes: minutes, focus: focus)
    }
}

public enum Scheduler {
    /// First free quarter-hour slot (08:00–22:00, within one day) after `after` that fits `minutes`
    /// without overlapping `busy`. Looks up to 3 days ahead; falls back to `after`.
    public static func nextFreeSlot(minutes: Int, after: Date, busy: [TimetableItem], calendar cal: Calendar = .current) -> Date {
        var t = cal.date(bySetting: .second, value: 0, of: after) ?? after
        let q = cal.component(.minute, from: t) % 15
        t = t.addingTimeInterval(Double(q == 0 ? 0 : 15 - q) * 60)
        let scheduled = busy.filter { $0.kind != .todo }
        for _ in 0..<(4 * 24 * 3) {
            let end = t.addingTimeInterval(Double(minutes) * 60)
            let h = cal.component(.hour, from: t), he = cal.component(.hour, from: end), me = cal.component(.minute, from: end)
            let fitsDay = h >= 8 && (he < 22 || (he == 22 && me == 0)) && cal.isDate(t, inSameDayAs: end)
            if fitsDay, !scheduled.contains(where: { $0.start < end && $0.end > t }) { return t }
            t = t.addingTimeInterval(15 * 60)
        }
        return after
    }
}
