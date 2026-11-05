import Foundation

// MARK: - Vigil's data engine
//
// An object model over the raw activity log: apps and sites are objects; switches, flows and
// interruptions are links between them. From those links it draws ranked, plain-English conclusions.
// Pure computation over one ordered query; run it off the main thread.

public enum ObjectKind: String, Codable { case app, site }

/// An app or a website, with what Vigil knows about it over the analysed range.
public struct EngineObject: Codable, Hashable, Identifiable {
    public var key: String              // domain for sites, app name for apps
    public var kind: ObjectKind
    public var app: String              // app it ran in (the browser, for sites)
    public var category: ActivityCategory
    public var seconds: Double
    public var visits: Int              // separate runs (consecutive segments merged)
    public var id: String { key }
    public var averageVisit: Double { visits > 0 ? seconds / Double(visits) : 0 }
}

/// Time flowing category → app → site (site is nil for non-browser time).
public struct FlowLink: Codable, Hashable, Identifiable {
    public var category: ActivityCategory
    public var app: String
    public var site: String?
    public var seconds: Double
    public var id: String { "\(category.rawValue)|\(app)|\(site ?? "")" }
}

/// Switching from one object to another within 2 minutes.
public struct Transition: Codable, Hashable, Identifiable {
    public var from: String
    public var to: String
    public var count: Int
    /// Time spent in `to` right after these switches.
    public var secondsAfter: Double
    public var toCategory: ActivityCategory
    public var id: String { "\(from)→\(to)" }
}

/// An object that often leads somewhere distracting.
public struct Gateway: Codable, Hashable, Identifiable {
    public var key: String
    public var switches: Int
    public var toDistractingShare: Double      // 0…1
    public var distractingSecondsAfter: Double
    public var topDestination: String?
    public var id: String { key }
}

/// A task, time block or focus session, and how much distraction got into it.
public struct Interruption: Codable, Hashable, Identifiable {
    public var title: String
    public var kind: String                     // "task" | "block" | "focus"
    public var start: Date
    public var end: Date
    public var trackedSeconds: Double
    public var distractingSeconds: Double
    public var topInterrupter: String?
    public var id: String { "\(kind)|\(title)|\(start.timeIntervalSince1970)" }
}

/// A finding, ranked by how much time it's about.
public struct Conclusion: Codable, Hashable, Identifiable {
    public enum Kind: String, Codable { case cost, gateway, interruption, rhythm, win }
    public var kind: Kind
    public var text: String
    public var subject: String?                 // object key to open in the explorer
    public var impactSeconds: Double
    public var id: String { kind.rawValue + text }
}

public struct EngineData: Codable, Hashable {
    public var fromDay: String
    public var toDay: String
    public var days: Int
    public var objects: [EngineObject]          // by time, descending
    public var flows: [FlowLink]
    public var transitions: [Transition]        // by count, descending
    public var gateways: [Gateway]
    public var interruptions: [Interruption]    // most recent first
    public var conclusions: [Conclusion]        // by impact, descending
    public var computedAt: Date

    public func object(_ key: String) -> EngineObject? { objects.first { $0.key == key } }
    public func incoming(_ key: String) -> [Transition] { transitions.filter { $0.to == key } }
    public func outgoing(_ key: String) -> [Transition] { transitions.filter { $0.from == key } }
}

/// One activity segment, as the engine sees it.
public struct EngineSegment: Hashable {
    public var start: Date, end: Date, app: String, domain: String?, category: ActivityCategory
    public init(start: Date, end: Date, app: String, domain: String?, category: ActivityCategory) {
        self.start = start; self.end = end; self.app = app; self.domain = domain; self.category = category
    }
    public var key: String { domain ?? app }
    public var duration: Double { max(0, end.timeIntervalSince(start)) }
}

/// A window to check for interruptions.
public struct EngineWindow: Hashable {
    public var title: String, kind: String, start: Date, end: Date
    public init(title: String, kind: String, start: Date, end: Date) { self.title = title; self.kind = kind; self.start = start; self.end = end }
}

extension VigilStore {
    /// Builds the engine for the last `days` days (today included).
    public func engine(days: Int = 14, now: Date = Date()) -> EngineData {
        let today = DayKey.string(for: now)
        let from = DayKey.offset(today, days: -(days - 1))
        let rows = (try? db.query("""
            SELECT start, end, app_name, domain, category FROM activity WHERE day BETWEEN ? AND ? ORDER BY start
            """, [from, today])) ?? []
        let segments = rows.compactMap { r -> EngineSegment? in
            guard let s = r.double("start"), let e = r.double("end"), let app = r.string("app_name") else { return nil }
            return EngineSegment(start: Date(timeIntervalSince1970: s), end: Date(timeIntervalSince1970: e), app: app,
                                 domain: r.string("domain"), category: ActivityCategory(rawValue: r.string("category") ?? "") ?? .neutral)
        }
        var windows: [EngineWindow] = []
        if let start = DayKey.date(from: from) {
            for item in timetable(from: start, to: now) where item.start < now {
                windows.append(EngineWindow(title: item.title, kind: item.kind.rawValue, start: item.start, end: min(item.end, now)))
            }
        }
        for f in focusSessions(sinceDay: from) where f.start < now {
            windows.append(EngineWindow(title: f.label ?? "Focus session", kind: "focus", start: f.start, end: min(f.effectiveEnd, now)))
        }
        return Engine.build(segments: segments, windows: windows, fromDay: from, toDay: today, days: days, now: now)
    }
}

public enum Engine {
    /// Two segments closer than this are one continuous stretch of work (a switch, not a break).
    static let switchGap: TimeInterval = 120

    public static func build(segments: [EngineSegment], windows: [EngineWindow], fromDay: String, toDay: String,
                             days: Int, now: Date = Date()) -> EngineData {
        // 1. Merge consecutive segments of the same object into runs (title changes split segments).
        struct Run { var key: String; var app: String; var site: String?; var category: ActivityCategory; var start: Date; var end: Date; var seconds: Double }
        var runs: [Run] = []
        for s in segments.sorted(by: { $0.start < $1.start }) where s.duration > 0 {
            if var last = runs.last, last.key == s.key, s.start.timeIntervalSince(last.end) <= switchGap {
                last.end = max(last.end, s.end); last.seconds += s.duration
                runs[runs.count - 1] = last
            } else {
                runs.append(Run(key: s.key, app: s.app, site: s.domain, category: s.category, start: s.start, end: s.end, seconds: s.duration))
            }
        }

        // 2. Objects and flows.
        var objects: [String: EngineObject] = [:]
        var flows: [String: FlowLink] = [:]
        for r in runs {
            var o = objects[r.key] ?? EngineObject(key: r.key, kind: r.site == nil ? .app : .site, app: r.app, category: r.category, seconds: 0, visits: 0)
            o.seconds += r.seconds; o.visits += 1
            objects[r.key] = o
            let f = FlowLink(category: r.category, app: r.app, site: r.site, seconds: 0)
            flows[f.id, default: f].seconds += r.seconds
        }

        // 3. Transitions between consecutive runs.
        var trans: [String: Transition] = [:]
        for (a, b) in zip(runs, runs.dropFirst()) where a.key != b.key && b.start.timeIntervalSince(a.end) <= switchGap {
            let t = Transition(from: a.key, to: b.key, count: 0, secondsAfter: 0, toCategory: b.category)
            trans[t.id, default: t].count += 1
            trans[t.id]!.secondsAfter += b.seconds
        }
        let transitions = trans.values.sorted { $0.count != $1.count ? $0.count > $1.count : $0.id < $1.id }

        // 4. Gateways: objects whose switches usually land on something distracting.
        var gateways: [Gateway] = []
        for (key, outs) in Dictionary(grouping: transitions, by: \.from) {
            guard objects[key]?.category != .distracting else { continue }
            let total = outs.reduce(0) { $0 + $1.count }
            let bad = outs.filter { $0.toCategory == .distracting }
            let badCount = bad.reduce(0) { $0 + $1.count }
            guard total >= 4, badCount >= 2 else { continue }
            gateways.append(Gateway(key: key, switches: total, toDistractingShare: Double(badCount) / Double(total),
                                    distractingSecondsAfter: bad.reduce(0) { $0 + $1.secondsAfter },
                                    topDestination: bad.max { $0.count < $1.count }?.to))
        }
        gateways.sort { $0.distractingSecondsAfter > $1.distractingSecondsAfter }

        // 5. Interruptions inside tasks, time blocks and focus sessions.
        var interruptions: [Interruption] = []
        for w in windows where w.end > w.start {
            var tracked = 0.0, bad = 0.0
            var byKey: [String: Double] = [:]
            for r in runs where r.end > w.start && r.start < w.end {
                let overlap = min(r.end, w.end).timeIntervalSince(max(r.start, w.start))
                guard overlap > 0 else { continue }
                // Runs can include short gaps; scale their seconds to the overlapping share.
                let share = overlap / max(1, r.end.timeIntervalSince(r.start))
                let secs = r.seconds * min(1, share)
                tracked += secs
                if r.category == .distracting { bad += secs; byKey[r.key, default: 0] += secs }
            }
            guard tracked > 60 else { continue }
            interruptions.append(Interruption(title: w.title, kind: w.kind, start: w.start, end: w.end, trackedSeconds: tracked,
                                              distractingSeconds: bad, topInterrupter: byKey.max { $0.value < $1.value }?.key))
        }
        interruptions.sort { $0.start > $1.start }

        var data = EngineData(fromDay: fromDay, toDay: toDay, days: days,
                              objects: objects.values.sorted { $0.seconds > $1.seconds },
                              flows: flows.values.sorted { $0.seconds > $1.seconds },
                              transitions: transitions, gateways: gateways, interruptions: interruptions,
                              conclusions: [], computedAt: now)
        data.conclusions = conclusions(for: data, runs: runs.map { ($0.start, $0.seconds, $0.category) })
        return data
    }

    // MARK: Conclusions

    static func conclusions(for d: EngineData, runs: [(Date, Double, ActivityCategory)]) -> [Conclusion] {
        var out: [Conclusion] = []
        let perDay = Double(max(1, d.days))
        func t(_ s: Double) -> String { DurationText.short(s) }

        // Costs: the biggest distracting objects, per day.
        for o in d.objects.filter({ $0.category == .distracting }).prefix(3) where o.seconds >= 600 {
            out.append(Conclusion(kind: .cost, text: "\(o.key) costs you about \(t(o.seconds / perDay)) a day, in \(o.visits) visits averaging \(t(o.averageVisit)).",
                                  subject: o.key, impactSeconds: o.seconds))
        }
        // Gateways: what leads you there.
        for g in d.gateways.prefix(3) where g.toDistractingShare >= 0.25 {
            let dest = g.topDestination.map { ", most often \($0)" } ?? ""
            out.append(Conclusion(kind: .gateway,
                                  text: "Leaving \(g.key) leads somewhere distracting \(Int((g.toDistractingShare * 100).rounded()))% of the time\(dest). That's \(t(g.distractingSecondsAfter)) over \(d.days) days.",
                                  subject: g.key, impactSeconds: g.distractingSecondsAfter))
        }
        // Interruptions: which plans leak, and to what.
        let leaky = d.interruptions.filter { $0.distractingSeconds >= 180 }
        if !leaky.isEmpty {
            let total = leaky.reduce(0) { $0 + $1.distractingSeconds }
            let culprits = Dictionary(grouping: leaky.compactMap(\.topInterrupter), by: { $0 }).max { $0.value.count < $1.value.count }?.key
            out.append(Conclusion(kind: .interruption,
                                  text: "\(leaky.count) of your tasks and focus blocks were interrupted for \(t(total)) in total\(culprits.map { ", mostly by \($0)" } ?? "").",
                                  subject: culprits, impactSeconds: total))
        }
        let clean = d.interruptions.filter { $0.distractingSeconds < 60 && $0.trackedSeconds >= 1200 }
        if !clean.isEmpty {
            out.append(Conclusion(kind: .win, text: "\(clean.count) planned blocks ran with no distraction at all. Keep those.",
                                  subject: nil, impactSeconds: clean.reduce(0) { $0 + $1.trackedSeconds } * 0.1))
        }
        // Rhythm: when distraction happens.
        var byHour = [Double](repeating: 0, count: 24)
        for (start, secs, cat) in runs where cat == .distracting { byHour[Calendar.current.component(.hour, from: start)] += secs }
        if let peak = byHour.indices.max(by: { byHour[$0] < byHour[$1] }), byHour[peak] >= 900 {
            out.append(Conclusion(kind: .rhythm, text: String(format: "Distraction peaks between %02d:00 and %02d:00. A focus block there would protect the most time.", peak, (peak + 1) % 24),
                                  subject: nil, impactSeconds: byHour[peak]))
        }
        return out.sorted { $0.impactSeconds > $1.impactSeconds }
    }
}
