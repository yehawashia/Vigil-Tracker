import Foundation

/// A timetable entry. `kind == .block` turns blocking on for its duration (time blocking).
public struct TimetableItem: Codable, Hashable, Identifiable {
    public enum Kind: String, Codable, CaseIterable { case task, block }

    public var id: String
    public var title: String
    public var notes: String?
    public var start: Date
    public var end: Date
    public var kind: Kind
    public var done: Bool

    public init(id: String = UUID().uuidString, title: String, notes: String? = nil, start: Date, end: Date,
                kind: Kind = .task, done: Bool = false) {
        self.id = id; self.title = title; self.notes = notes; self.start = start; self.end = end
        self.kind = kind; self.done = done
    }

    public func isActive(at date: Date = Date()) -> Bool { start <= date && date < end }
    public var duration: TimeInterval { end.timeIntervalSince(start) }

    /// Rejects anything malformed, whoever sent it (app, agent or paired device).
    public func validated() throws -> TimetableItem {
        var item = self
        item.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        item.notes = notes?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        guard !item.title.isEmpty else { throw TimetableError.invalid("A title is required.") }
        guard item.title.count <= 200, (item.notes?.count ?? 0) <= 4000 else { throw TimetableError.invalid("Title or notes too long.") }
        guard end > start else { throw TimetableError.invalid("End must be after start.") }
        guard duration <= 24 * 3600 else { throw TimetableError.invalid("Items can be at most 24 hours long.") }
        let year: TimeInterval = 366 * 86400
        guard abs(start.timeIntervalSinceNow) < year else { throw TimetableError.invalid("Start must be within a year of today.") }
        guard UUID(uuidString: id) != nil else { throw TimetableError.invalid("Bad item id.") }
        return item
    }
}

public enum TimetableError: Error, CustomStringConvertible {
    case invalid(String)
    case notFound
    case conflict(String)

    public var description: String {
        switch self {
        case .invalid(let m): return m
        case .notFound: return "No such item or revision."
        case .conflict(let m): return m
        }
    }
}

/// One change in the append-only history.
public struct TimetableRevision: Codable, Hashable, Identifiable {
    public enum Op: String, Codable { case create, update, delete, revert }
    public enum Status: String, Codable { case applied, proposed, rejected }

    public var id: Int64
    public var itemID: String
    public var op: Op
    public var before: TimetableItem?
    public var after: TimetableItem?
    /// "mac", "agent" or "device:<id>".
    public var author: String
    public var status: Status
    public var note: String?
    public var time: Date

    public var title: String { after?.title ?? before?.title ?? "Untitled" }

    public var authorLabel: String {
        if author == "mac" { return "You (Mac)" }
        if author == "agent" { return "Agent" }
        if author.hasPrefix("device:") { return "Paired device" }
        return author
    }

    /// Short description, e.g. "Moved to Thu 10:00–12:00".
    public var summary: String {
        let f = DateFormatter(); f.dateFormat = "EEE d MMM HH:mm"
        let t = DateFormatter(); t.dateFormat = "HH:mm"
        func when(_ i: TimetableItem) -> String { "\(f.string(from: i.start))–\(t.string(from: i.end))" }
        switch op {
        case .create: return after.map { "Add \"\($0.title)\" · \(when($0))" } ?? "Add"
        case .delete: return before.map { "Remove \"\($0.title)\"" } ?? "Remove"
        case .revert: return "Revert \"\(title)\""
        case .update:
            guard let b = before, let a = after else { return "Change" }
            var parts: [String] = []
            if a.title != b.title { parts.append("rename to \"\(a.title)\"") }
            if a.start != b.start || a.end != b.end { parts.append("move to \(when(a))") }
            if a.kind != b.kind { parts.append(a.kind == .block ? "turn blocking on" : "turn blocking off") }
            if a.done != b.done { parts.append(a.done ? "mark done" : "mark not done") }
            if a.notes != b.notes { parts.append("edit notes") }
            return "\"\(b.title)\": " + (parts.isEmpty ? "no change" : parts.joined(separator: ", "))
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

extension VigilStore {
    static let timetableSchema = """
    CREATE TABLE IF NOT EXISTS timetable_items (
        id TEXT PRIMARY KEY,
        title TEXT NOT NULL,
        notes TEXT,
        start REAL NOT NULL,
        end REAL NOT NULL,
        kind TEXT NOT NULL,
        done INTEGER NOT NULL DEFAULT 0,
        deleted INTEGER NOT NULL DEFAULT 0,
        revision INTEGER NOT NULL DEFAULT 0
    );
    CREATE INDEX IF NOT EXISTS idx_timetable_start ON timetable_items(start);
    CREATE TABLE IF NOT EXISTS timetable_revisions (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        item_id TEXT NOT NULL,
        op TEXT NOT NULL,
        before TEXT,
        after TEXT,
        author TEXT NOT NULL,
        status TEXT NOT NULL,
        note TEXT,
        time REAL NOT NULL
    );
    CREATE INDEX IF NOT EXISTS idx_revisions_item ON timetable_revisions(item_id);
    CREATE INDEX IF NOT EXISTS idx_revisions_status ON timetable_revisions(status);
    """

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder(); e.dateEncodingStrategy = .secondsSince1970; e.outputFormatting = .sortedKeys; return e
    }()
    private static let decoder: JSONDecoder = {
        let d = JSONDecoder(); d.dateDecodingStrategy = .secondsSince1970; return d
    }()

    private func encode(_ item: TimetableItem?) -> String? {
        item.flatMap { try? VigilStore.encoder.encode($0) }.flatMap { String(data: $0, encoding: .utf8) }
    }

    private func decode(_ text: String?) -> TimetableItem? {
        text.flatMap { $0.data(using: .utf8) }.flatMap { try? VigilStore.decoder.decode(TimetableItem.self, from: $0) }
    }

    private func itemFromRow(_ row: Row) -> TimetableItem? {
        guard let id = row.string("id"), let title = row.string("title"), let s = row.double("start"), let e = row.double("end") else { return nil }
        return TimetableItem(id: id, title: title, notes: row.string("notes"),
                             start: Date(timeIntervalSince1970: s), end: Date(timeIntervalSince1970: e),
                             kind: TimetableItem.Kind(rawValue: row.string("kind") ?? "") ?? .task, done: row.bool("done"))
    }

    private func revisionFromRow(_ row: Row) -> TimetableRevision? {
        guard let id = row.int("id"), let item = row.string("item_id"),
              let op = TimetableRevision.Op(rawValue: row.string("op") ?? ""),
              let status = TimetableRevision.Status(rawValue: row.string("status") ?? "") else { return nil }
        return TimetableRevision(id: Int64(id), itemID: item, op: op, before: decode(row.string("before")),
                                 after: decode(row.string("after")), author: row.string("author") ?? "?",
                                 status: status, note: row.string("note"),
                                 time: Date(timeIntervalSince1970: row.double("time") ?? 0))
    }

    // MARK: Reading

    /// Items overlapping [from, to), earliest first. Deleted items are excluded.
    public func timetable(from: Date, to: Date) -> [TimetableItem] {
        let rows = (try? db.query("""
            SELECT * FROM timetable_items WHERE deleted = 0 AND start < ? AND end > ? ORDER BY start
            """, [to, from])) ?? []
        return rows.compactMap(itemFromRow)
    }

    public func timetableItem(id: String) -> TimetableItem? {
        (try? db.query("SELECT * FROM timetable_items WHERE id = ? AND deleted = 0", [id]))?.first.flatMap(itemFromRow)
    }

    /// Time blocks that haven't ended yet. Cached by the app so the tick never queries.
    public func upcomingTimeBlocks(now: Date = Date()) -> [TimetableItem] {
        let rows = (try? db.query("""
            SELECT * FROM timetable_items WHERE deleted = 0 AND kind = 'block' AND end > ? ORDER BY start LIMIT 200
            """, [now])) ?? []
        return rows.compactMap(itemFromRow)
    }

    public func timetableHistory(itemID: String? = nil, limit: Int = 100) -> [TimetableRevision] {
        let rows: [Row]
        if let itemID {
            rows = (try? db.query("SELECT * FROM timetable_revisions WHERE item_id = ? ORDER BY id DESC LIMIT ?", [itemID, limit])) ?? []
        } else {
            rows = (try? db.query("SELECT * FROM timetable_revisions ORDER BY id DESC LIMIT ?", [limit])) ?? []
        }
        return rows.compactMap(revisionFromRow)
    }

    public func timetableRevision(id: Int64) -> TimetableRevision? {
        (try? db.query("SELECT * FROM timetable_revisions WHERE id = ?", [id]))?.first.flatMap(revisionFromRow)
    }

    public func pendingProposals() -> [TimetableRevision] {
        let rows = (try? db.query("SELECT * FROM timetable_revisions WHERE status = 'proposed' ORDER BY id")) ?? []
        return rows.compactMap(revisionFromRow)
    }

    // MARK: Writing

    /// Applies a change right away (you, on the Mac or a paired device). Returns the new revision id.
    @discardableResult
    public func applyTimetableChange(_ op: TimetableRevision.Op, item: TimetableItem, author: String) throws -> Int64 {
        var id: Int64 = 0
        try db.transaction {
            let current = timetableItem(id: item.id)
            let after: TimetableItem? = op == .delete ? nil : try item.validated()
            if op == .create, current != nil { throw TimetableError.conflict("An item with that id already exists.") }
            if op != .create, current == nil { throw TimetableError.notFound }
            id = try db.run("""
                INSERT INTO timetable_revisions(item_id, op, before, after, author, status, time)
                VALUES (?, ?, ?, ?, ?, 'applied', ?)
                """, [item.id, op.rawValue, encode(current), encode(after), author, Date()])
            try write(after, id: item.id, revision: id)
        }
        return id
    }

    /// Records a change for approval (agents). Nothing in the timetable changes yet.
    @discardableResult
    public func proposeTimetableChange(_ op: TimetableRevision.Op, item: TimetableItem, author: String = "agent",
                                       note: String?) throws -> Int64 {
        let current = timetableItem(id: item.id)
        let after: TimetableItem? = op == .delete ? nil : try item.validated()
        if op == .create, current != nil { throw TimetableError.conflict("An item with that id already exists.") }
        if op != .create, current == nil { throw TimetableError.notFound }
        let trimmedNote = note.map { String($0.prefix(500)) }
        return try db.run("""
            INSERT INTO timetable_revisions(item_id, op, before, after, author, status, note, time)
            VALUES (?, ?, ?, ?, ?, 'proposed', ?, ?)
            """, [item.id, op.rawValue, encode(current), encode(after), author, trimmedNote, Date()])
    }

    /// Approves a proposal. Refused (and the proposal rejected) if the item changed since it was proposed.
    public func approveProposal(id: Int64) throws {
        guard let rev = timetableRevision(id: id), rev.status == .proposed else {
            throw TimetableError.notFound
        }
        let current = timetableItem(id: rev.itemID)
        guard current == rev.before else {
            try? db.run("UPDATE timetable_revisions SET status = 'rejected', note = COALESCE(note, '') || ' [item changed since proposed]' WHERE id = ?", [id])
            throw TimetableError.conflict("That item changed after the agent proposed this, so the proposal was set aside.")
        }
        try db.transaction {
            try db.run("UPDATE timetable_revisions SET status = 'applied', time = ? WHERE id = ?", [Date(), id])
            try write(rev.after, id: rev.itemID, revision: id)
        }
    }

    public func rejectProposal(id: Int64) {
        _ = try? db.run("UPDATE timetable_revisions SET status = 'rejected' WHERE id = ? AND status = 'proposed'", [id])
    }

    /// Undoes an applied revision by applying its `before` state as a new 'revert' revision. History is kept.
    public func revert(revisionID: Int64, author: String) throws {
        guard let rev = timetableRevision(id: revisionID), rev.status == .applied else {
            throw TimetableError.notFound
        }
        let current = timetableItem(id: rev.itemID)
        try db.transaction {
            let id = try db.run("""
                INSERT INTO timetable_revisions(item_id, op, before, after, author, status, note, time)
                VALUES (?, 'revert', ?, ?, ?, 'applied', ?, ?)
                """, [rev.itemID, encode(current), encode(rev.before), author, "Reverts change #\(revisionID)", Date()])
            try write(rev.before, id: rev.itemID, revision: id)
        }
    }

    private func write(_ item: TimetableItem?, id: String, revision: Int64) throws {
        if let item {
            try db.run("""
                INSERT INTO timetable_items(id, title, notes, start, end, kind, done, deleted, revision)
                VALUES (?, ?, ?, ?, ?, ?, ?, 0, ?)
                ON CONFLICT(id) DO UPDATE SET title = excluded.title, notes = excluded.notes, start = excluded.start,
                  end = excluded.end, kind = excluded.kind, done = excluded.done, deleted = 0, revision = excluded.revision
                """, [item.id, item.title, item.notes, item.start, item.end, item.kind.rawValue, item.done ? 1 : 0, revision])
        } else {
            try db.run("UPDATE timetable_items SET deleted = 1, revision = ? WHERE id = ?", [revision, id])
        }
    }
}
