import Foundation
import Testing
@testable import VigilCore

struct EngineTests {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    /// Builds back-to-back segments from (app, domain, category, minutes).
    func day(_ steps: [(String, String?, ActivityCategory, Double)], gap: Double = 5) -> [EngineSegment] {
        var t = t0, out: [EngineSegment] = []
        for (app, domain, cat, minutes) in steps {
            out.append(EngineSegment(start: t, end: t.addingTimeInterval(minutes * 60), app: app, domain: domain, category: cat))
            t = t.addingTimeInterval(minutes * 60 + gap)
        }
        return out
    }

    @Test func mergesRunsAndCountsSwitches() {
        let segs = day([("Xcode", nil, .productive, 20), ("Xcode", nil, .productive, 10),
                        ("Safari", "reddit.com", .distracting, 5), ("Xcode", nil, .productive, 15)])
        let e = Engine.build(segments: segs, windows: [], fromDay: "2027-01-15", toDay: "2027-01-15", days: 1)
        #expect(e.object("Xcode")?.visits == 2)
        #expect(e.object("Xcode")?.seconds == Double(45 * 60))
        #expect(e.object("reddit.com")?.kind == .site)
        #expect(e.transitions.map(\.id).sorted() == ["Xcode→reddit.com", "reddit.com→Xcode"])
    }

    @Test func findsGatewayToDistraction() {
        var steps: [(String, String?, ActivityCategory, Double)] = []
        for _ in 0..<5 {
            steps += [("Xcode", nil, .productive, 25), ("Safari", "reddit.com", .distracting, 4), ("Safari", "youtube.com", .distracting, 10)]
        }
        let e = Engine.build(segments: day(steps), windows: [], fromDay: "a", toDay: "b", days: 1)
        let g = e.gateways.first { $0.key == "Xcode" }
        #expect(g != nil)
        #expect(g?.toDistractingShare == 1)
        #expect(g?.topDestination == "reddit.com")
        #expect(e.conclusions.contains { $0.kind == .gateway && $0.subject == "Xcode" })
        #expect(e.conclusions.contains { $0.kind == .cost && $0.subject == "youtube.com" })
        // Conclusions are ranked by impact.
        #expect(e.conclusions.map(\.impactSeconds) == e.conclusions.map(\.impactSeconds).sorted(by: >))
    }

    @Test func measuresInterruptionsInsideTasks() {
        let segs = day([("Pages", nil, .productive, 30), ("Safari", "instagram.com", .distracting, 10), ("Pages", nil, .productive, 20)])
        let window = EngineWindow(title: "Essay", kind: "task", start: t0, end: t0.addingTimeInterval(3600))
        let e = Engine.build(segments: segs, windows: [window], fromDay: "a", toDay: "b", days: 1)
        let i = e.interruptions.first
        #expect(i?.title == "Essay")
        #expect(abs((i?.distractingSeconds ?? 0) - 600) < 1)
        #expect(i?.topInterrupter == "instagram.com")
    }

    @Test func breaksAreNotSwitches() {
        let segs = day([("Xcode", nil, .productive, 20), ("Safari", "youtube.com", .distracting, 5)], gap: 600)
        let e = Engine.build(segments: segs, windows: [], fromDay: "a", toDay: "b", days: 1)
        #expect(e.transitions.isEmpty)
    }

    @Test func flowsSumByCategoryAppSite() {
        let segs = day([("Safari", "docs.python.org", .productive, 10), ("Safari", "docs.python.org", .productive, 5), ("Notes", nil, .neutral, 3)], gap: 400)
        let e = Engine.build(segments: segs, windows: [], fromDay: "a", toDay: "b", days: 1)
        #expect(e.flows.first?.site == "docs.python.org")
        #expect(e.flows.first?.seconds == Double(15 * 60))
        #expect(e.flows.contains { $0.app == "Notes" && $0.site == nil && $0.category == .neutral })
    }

    @Test func perDayUsesTrackedDaysNotRange() {
        // 2 hours of YouTube on one tracked day, inside a 14-day window: 2h a day, not ~9m.
        let segs = day([("Safari", "youtube.com", .distracting, 120)])
        let e = Engine.build(segments: segs, windows: [], fromDay: "a", toDay: "b", days: 14)
        #expect(e.trackedDays == 1)
        #expect(e.conclusions.first { $0.kind == .cost }?.text.contains("2h 00m a day") == true)
    }
}
