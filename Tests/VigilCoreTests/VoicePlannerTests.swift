import Foundation
import Testing
@testable import VigilCore

struct VoicePlannerTests {
    // Thursday 5 Nov 2026, 10:00 local.
    let now = Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 5, hour: 10))!
    func hm(_ d: Date?) -> String {
        guard let d else { return "nil" }
        let c = Calendar.current.dateComponents([.day, .hour, .minute], from: d)
        return "\(c.day!) \(c.hour!):\(String(format: "%02d", c.minute!))"
    }

    @Test func rangeTomorrowWithFocus() {
        let p = VoicePlanner.parse("Essay draft tomorrow from 2 to 4pm, block distractions", now: now)
        #expect(p?.title == "Essay draft")
        #expect(hm(p?.start) == "6 14:00")
        #expect(hm(p?.end) == "6 16:00")
        #expect(p?.focus == true)
        #expect(p?.item().kind == .block)
    }

    @Test func timeWithDuration() {
        let p = VoicePlanner.parse("Call mum at 6pm for 20 minutes", now: now)
        #expect(p?.title == "Call mum")
        #expect(hm(p?.start) == "5 18:00")
        #expect(hm(p?.end) == "5 18:20")
        #expect(p?.item().kind == .task)
    }

    @Test func noTimeGoesToTaskPanel() {
        let p = VoicePlanner.parse("Revise statistics for an hour", now: now)
        #expect(p?.title == "Revise statistics")
        #expect(p?.start == nil)
        #expect(p?.minutes == 60)
        #expect(p?.item().kind == .todo)
    }

    @Test func fillerAndHours() {
        let p = VoicePlanner.parse("Please schedule gym tomorrow at 7am for 1.5 hours", now: now)
        #expect(p?.title == "Gym")
        #expect(hm(p?.start) == "6 7:00")
        #expect(hm(p?.end) == "6 8:30")
    }

    @Test func pastTimeMeansNextDay() {
        let p = VoicePlanner.parse("Read chapter 4 at 9am", now: now)
        #expect(hm(p?.start) == "6 9:00")
    }

    @Test func emptyIsNil() {
        #expect(VoicePlanner.parse("   ", now: now) == nil)
    }
}

struct SchedulerTests {
    let cal = Calendar.current
    func at(_ h: Int, _ m: Int = 0, day: Int = 5) -> Date { cal.date(from: DateComponents(year: 2026, month: 11, day: day, hour: h, minute: m))! }

    @Test func skipsBusyAndRoundsUp() {
        let busy = [TimetableItem(title: "A", start: at(10), end: at(11, 30))]
        #expect(Scheduler.nextFreeSlot(minutes: 60, after: at(9, 40), busy: busy) == at(11, 30))
        #expect(Scheduler.nextFreeSlot(minutes: 15, after: at(9, 40), busy: busy) == at(9, 45))
    }

    @Test func rollsToNextMorning() {
        #expect(Scheduler.nextFreeSlot(minutes: 90, after: at(21, 10), busy: []) == at(8, day: 6))
    }
}
