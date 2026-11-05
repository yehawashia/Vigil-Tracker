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

struct TodoTests {
    private func store(at url: URL? = nil) throws -> VigilStore {
        try VigilStore(path: (url ?? FileManager.default.temporaryDirectory.appendingPathComponent("vigil-todo-\(UUID().uuidString).sqlite")).path)
    }

    @Test func todoLivesInPanelUntilScheduled() throws {
        let st = try store()
        let todo = TimetableItem(title: "Revise stats", start: Date(), end: Date(), kind: .todo, estimate: 90, wantsFocus: true)
        try st.applyTimetableChange(.create, item: todo, author: "mac")
        let window = (Date().addingTimeInterval(-86400), Date().addingTimeInterval(86400 * 2))
        #expect(st.todos().map(\.title) == ["Revise stats"])
        #expect(st.timetable(from: window.0, to: window.1).isEmpty)

        let start = Date().addingTimeInterval(3600)
        try st.applyTimetableChange(.update, item: try #require(st.todos().first).scheduled(at: start), author: "mac")
        #expect(st.todos().isEmpty)
        let placed = st.timetable(from: window.0, to: window.1)
        #expect(placed.first?.kind == .block)
        #expect(placed.first.map { Int($0.duration / 60) } == 90)
        #expect(st.upcomingTimeBlocks().count == 1)
        #expect(st.timetableHistory().first?.summary.hasPrefix("Schedule \"Revise stats\"") == true)
        #expect(st.timetableHistory().first?.summary.hasSuffix("blocking on") == true)
    }

    @Test func upgradesVersion3Database() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("vigil-v3-\(UUID().uuidString).sqlite")
        let db = try Database(path: url.path)
        try db.exec("""
            CREATE TABLE timetable_items (id TEXT PRIMARY KEY, title TEXT NOT NULL, notes TEXT, start REAL NOT NULL, end REAL NOT NULL,
              kind TEXT NOT NULL, done INTEGER NOT NULL DEFAULT 0, deleted INTEGER NOT NULL DEFAULT 0, revision INTEGER NOT NULL DEFAULT 0);
            INSERT INTO timetable_items(id, title, start, end, kind) VALUES ('6F1D2C3B-0000-4000-8000-000000000001', 'Old', 1800000000, 1800003600, 'task');
            PRAGMA user_version = 3;
            """)
        let st = try store(at: url)
        let item = try #require(st.timetableItem(id: "6F1D2C3B-0000-4000-8000-000000000001"))
        #expect(item.title == "Old")
        #expect(item.estimate == nil)
        var todo = TimetableItem(title: "New", start: Date(), end: Date(), kind: .todo, estimate: 30)
        todo.wantsFocus = false
        try st.applyTimetableChange(.create, item: todo, author: "mac")
        #expect(st.todos().first?.estimate == 30)
    }
}
