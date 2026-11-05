import Foundation
import Testing
@testable import VigilCore

struct TimetableTests {
    private func makeStore() throws -> VigilStore {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("vigil-test-\(UUID().uuidString).sqlite")
        return try VigilStore(path: url.path)
    }

    private func item(_ title: String = "Essay", hours: Double = 2) -> TimetableItem {
        let start = Date().addingTimeInterval(3600).rounded()
        return TimetableItem(title: title, start: start, end: start.addingTimeInterval(hours * 3600), kind: .block)
    }

    @Test func testAgentProposalChangesNothingUntilApproved() throws {
        let st = try makeStore()
        let i = item()
        let rev = try st.proposeTimetableChange(.create, item: i, note: "test")
        #expect(st.timetableItem(id: i.id) == nil)
        #expect(st.pendingProposals().count == 1)
        try st.approveProposal(id: rev)
        #expect(st.timetableItem(id: i.id)?.title == "Essay")
        #expect(st.pendingProposals().isEmpty)
    }

    @Test func testRejectLeavesTimetableAndKeepsHistory() throws {
        let st = try makeStore()
        let i = item()
        let rev = try st.proposeTimetableChange(.create, item: i, note: nil)
        st.rejectProposal(id: rev)
        #expect(st.timetableItem(id: i.id) == nil)
        #expect(st.timetableHistory().first?.status == .rejected)
        #expect(throws: (any Error).self) { try st.approveProposal(id: rev) }
    }

    @Test func testStaleProposalIsRefused() throws {
        let st = try makeStore()
        var i = item()
        try st.applyTimetableChange(.create, item: i, author: "mac")
        var moved = i; moved.title = "Agent rename"
        let rev = try st.proposeTimetableChange(.update, item: moved, note: nil)
        i.title = "My rename"
        try st.applyTimetableChange(.update, item: i, author: "mac")
        #expect(throws: (any Error).self) { try st.approveProposal(id: rev) }
        #expect(st.timetableItem(id: i.id)?.title == "My rename")
    }

    @Test func testRevertRestoresAndAppendsHistory() throws {
        let st = try makeStore()
        var i = item()
        try st.applyTimetableChange(.create, item: i, author: "mac")
        i.title = "Changed"
        let change = try st.applyTimetableChange(.update, item: i, author: "device:abc")
        try st.revert(revisionID: change, author: "mac")
        #expect(st.timetableItem(id: i.id)?.title == "Essay")
        #expect(st.timetableHistory().count == 3)
        // Reverting a create deletes the item; reverting that brings it back.
        let del = st.timetableHistory().last!.id
        try st.revert(revisionID: del, author: "mac")
        #expect(st.timetableItem(id: i.id) == nil)
    }

    @Test func testValidationRejectsBadInput() throws {
        let st = try makeStore()
        var i = item(); i.end = i.start
        #expect(throws: (any Error).self) { try st.applyTimetableChange(.create, item: i, author: "mac") }
        var j = item(); j.title = "   "
        #expect(throws: (any Error).self) { try st.proposeTimetableChange(.create, item: j, note: nil) }
        let k = item(hours: 30)
        #expect(throws: (any Error).self) { try st.applyTimetableChange(.create, item: k, author: "mac") }
    }

    @Test func testTimeBlocksCache() throws {
        let st = try makeStore()
        try st.applyTimetableChange(.create, item: item(), author: "mac")
        #expect(st.upcomingTimeBlocks().count == 1)
    }
}

private extension Date {
    func rounded() -> Date { Date(timeIntervalSince1970: (timeIntervalSince1970 / 60).rounded() * 60) }
}
