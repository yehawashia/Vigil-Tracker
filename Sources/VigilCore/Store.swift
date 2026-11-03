import Foundation

/// All persistence for Vigil. One SQLite file shared by the app and the MCP server.
public final class VigilStore {
    public let db: Database

    public init(path: String = VigilPaths.databaseURL.path) throws {
        db = try Database(path: path)
        try migrate()
        try upgradeSchema()
        try seedIfNeeded()
    }

    // MARK: - Schema

    private func migrate() throws {
        try db.exec("""
        CREATE TABLE IF NOT EXISTS activity (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            start REAL NOT NULL,
            end REAL NOT NULL,
            day TEXT NOT NULL,
            app_name TEXT NOT NULL,
            bundle_id TEXT,
            window_title TEXT,
            url TEXT,
            domain TEXT,
            category TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_activity_day ON activity(day);
        CREATE INDEX IF NOT EXISTS idx_activity_end ON activity(end);
        CREATE INDEX IF NOT EXISTS idx_activity_domain ON activity(domain);
        CREATE INDEX IF NOT EXISTS idx_activity_day_start ON activity(day, start);

        CREATE TABLE IF NOT EXISTS rules (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            kind TEXT NOT NULL,
            pattern TEXT NOT NULL,
            category TEXT NOT NULL,
            UNIQUE(kind, pattern)
        );

        CREATE TABLE IF NOT EXISTS blocklist (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            kind TEXT NOT NULL,
            pattern TEXT NOT NULL,
            UNIQUE(kind, pattern)
        );

        CREATE TABLE IF NOT EXISTS limits (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            kind TEXT NOT NULL,
            pattern TEXT NOT NULL,
            minutes INTEGER NOT NULL,
            UNIQUE(kind, pattern)
        );

        CREATE TABLE IF NOT EXISTS focus_sessions (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            start REAL NOT NULL,
            end REAL NOT NULL,
            locked INTEGER NOT NULL DEFAULT 0,
            label TEXT,
            ended_early REAL,
            created_by TEXT
        );
        CREATE INDEX IF NOT EXISTS idx_focus_end ON focus_sessions(end);

        CREATE TABLE IF NOT EXISTS schedules (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            weekdays TEXT NOT NULL,
            start_minute INTEGER NOT NULL,
            end_minute INTEGER NOT NULL,
            enabled INTEGER NOT NULL DEFAULT 1,
            label TEXT
        );

        CREATE TABLE IF NOT EXISTS block_events (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            time REAL NOT NULL,
            day TEXT NOT NULL,
            kind TEXT NOT NULL,
            target TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_block_events_day ON block_events(day);

        CREATE TABLE IF NOT EXISTS settings (
            key TEXT PRIMARY KEY,
            value TEXT
        );
        """)
    }

    /// Bump when the schema changes; add a step to `upgradeSchema` for each version.
    static let schemaVersion = 2

    private func upgradeSchema() throws {
        let current = (try? db.query("PRAGMA user_version"))?.first?.int("user_version") ?? 0
        guard current < VigilStore.schemaVersion else { return }
        if current < 2 {
            // v2: stop keeping query strings / fragments (search terms, tokens) in stored URLs.
            let rows = try db.query("SELECT id, url FROM activity WHERE url LIKE '%?%' OR url LIKE '%#%'")
            try db.transaction {
                for row in rows {
                    guard let id = row.int("id") else { continue }
                    try db.run("UPDATE activity SET url = ? WHERE id = ?",
                               [Categorizer.sanitize(url: row.string("url"), keepQuery: false), id])
                }
            }
        }
        try db.exec("PRAGMA user_version = \(VigilStore.schemaVersion);")
    }

    private func seedIfNeeded() throws {
        guard setting("seeded") == nil else { return }
        try db.transaction {
            for (kind, pattern, category) in Categorizer.defaultRules {
                try db.run("INSERT OR IGNORE INTO rules(kind, pattern, category) VALUES (?, ?, ?)",
                           [kind.rawValue, pattern, category.rawValue])
            }
            for (kind, pattern) in Categorizer.defaultBlocklist {
                try db.run("INSERT OR IGNORE INTO blocklist(kind, pattern) VALUES (?, ?)", [kind.rawValue, pattern])
            }
            try db.run("INSERT OR REPLACE INTO settings(key, value) VALUES ('seeded', '1')")
        }
    }

    // MARK: - Change detection

    /// Changes whenever *another* connection (e.g. the MCP server) commits a write.
    /// Cheap enough to poll every tick, so the app only reloads config when something changed.
    public func dataVersion() -> Int {
        (try? db.query("PRAGMA data_version"))?.first?.int("data_version") ?? 0
    }

    // MARK: - Settings

    public func setting(_ key: String) -> String? {
        (try? db.query("SELECT value FROM settings WHERE key = ?", [key]))?.first?.string("value")
    }

    public func setting(_ key: String, default value: Int) -> Int {
        setting(key).flatMap(Int.init) ?? value
    }

    public func setSetting(_ key: String, _ value: String?) {
        if let value {
            _ = try? db.run("INSERT OR REPLACE INTO settings(key, value) VALUES (?, ?)", [key, value])
        } else {
            _ = try? db.run("DELETE FROM settings WHERE key = ?", [key])
        }
    }

    // MARK: - Activity

    @discardableResult
    public func insertActivity(start: Date, end: Date, appName: String, bundleID: String?,
                               windowTitle: String?, url: String?, domain: String?,
                               category: ActivityCategory) throws -> Int64 {
        try db.run("""
            INSERT INTO activity(start, end, day, app_name, bundle_id, window_title, url, domain, category)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            [start, end, DayKey.string(for: start), appName, bundleID, windowTitle, url, domain, category.rawValue])
    }

    public func extendActivity(id: Int64, to end: Date) throws {
        try db.run("UPDATE activity SET end = ? WHERE id = ?", [end, id])
    }

    private func record(from row: Row) -> ActivityRecord {
        ActivityRecord(
            id: Int64(row.int("id") ?? 0),
            start: Date(timeIntervalSince1970: row.double("start") ?? 0),
            end: Date(timeIntervalSince1970: row.double("end") ?? 0),
            appName: row.string("app_name") ?? "Unknown",
            bundleID: row.string("bundle_id"),
            windowTitle: row.string("window_title"),
            url: row.string("url"),
            domain: row.string("domain"),
            category: ActivityCategory(rawValue: row.string("category") ?? "") ?? .neutral)
    }

    public func activities(day: String) -> [ActivityRecord] {
        let rows = (try? db.query("SELECT * FROM activity WHERE day = ? ORDER BY start", [day])) ?? []
        return rows.map(record(from:))
    }

    /// The segment currently being written by the tracker, if it is fresh.
    public func currentActivity(now: Date = Date(), freshness: TimeInterval = 15) -> ActivityRecord? {
        let rows = (try? db.query("SELECT * FROM activity WHERE end > ? ORDER BY end DESC LIMIT 1",
                                  [now.addingTimeInterval(-freshness)])) ?? []
        return rows.first.map(record(from:))
    }

    public func recentActivities(limit: Int = 50) -> [ActivityRecord] {
        let rows = (try? db.query("SELECT * FROM activity ORDER BY end DESC LIMIT ?", [limit])) ?? []
        return rows.map(record(from:))
    }

    public func searchActivities(query: String, sinceDay: String, limit: Int = 100) -> [ActivityRecord] {
        let like = "%\(query)%"
        let rows = (try? db.query("""
            SELECT * FROM activity
            WHERE day >= ? AND (app_name LIKE ? OR window_title LIKE ? OR url LIKE ? OR domain LIKE ?)
            ORDER BY start DESC LIMIT ?
            """, [sinceDay, like, like, like, like, limit])) ?? []
        return rows.map(record(from:))
    }

    /// Re-applies the current rules to stored activity (used after the user re-categorises something).
    public func recategorize(sinceDay: String) {
        let categorizer = Categorizer(rules: rules())
        guard let rows = try? db.query(
            "SELECT DISTINCT app_name, bundle_id, domain FROM activity WHERE day >= ?", [sinceDay]) else { return }
        try? db.transaction {
            for row in rows {
                let app = row.string("app_name") ?? ""
                let bundle = row.string("bundle_id")
                let domain = row.string("domain")
                let category = categorizer.category(appName: app, bundleID: bundle, domain: domain)
                try db.run("""
                    UPDATE activity SET category = ?
                    WHERE day >= ? AND app_name = ? AND IFNULL(bundle_id, '') = ? AND IFNULL(domain, '') = ?
                    """, [category.rawValue, sinceDay, app, bundle ?? "", domain ?? ""])
            }
        }
    }

    public func deleteAllActivity() {
        try? db.exec("DELETE FROM activity; DELETE FROM block_events;")
        compact()
    }

    // MARK: - Retention & maintenance

    /// Deletes activity and block events older than `days` (0 = keep forever). Returns rows removed.
    @discardableResult
    public func prune(olderThanDays days: Int) -> Int {
        guard days > 0 else { return 0 }
        let cutoff = DayKey.offset(DayKey.today, days: -days)
        let before = (try? db.query("SELECT COUNT(*) AS n FROM activity WHERE day < ?", [cutoff]))?.first?.int("n") ?? 0
        guard before > 0 else { return 0 }
        _ = try? db.run("DELETE FROM activity WHERE day < ?", [cutoff])
        _ = try? db.run("DELETE FROM block_events WHERE day < ?", [cutoff])
        _ = try? db.run("DELETE FROM focus_sessions WHERE end < ?", [DayKey.date(from: cutoff) ?? Date.distantPast])
        return before
    }

    /// Light daily upkeep: refresh query planner stats and fold the WAL back into the main file.
    public func maintenance() {
        try? db.exec("PRAGMA optimize; PRAGMA wal_checkpoint(TRUNCATE);")
        VigilPaths.restrictFile(VigilPaths.databaseURL.path)
    }

    /// Reclaims space after large deletes (and, with secure_delete, leaves no old rows in free pages).
    public func compact() {
        try? db.exec("PRAGMA wal_checkpoint(TRUNCATE); VACUUM;")
        VigilPaths.restrictFile(VigilPaths.databaseURL.path)
    }

    // MARK: - Aggregates

    public enum GroupBy: String { case app, domain, category, day }

    public func usage(fromDay: String, toDay: String, groupBy: GroupBy, limit: Int = 25) -> [UsageItem] {
        let categorizer = Categorizer(rules: rules())
        switch groupBy {
        case .app:
            let rows = (try? db.query("""
                SELECT app_name, MAX(bundle_id) AS bundle_id, SUM(end - start) AS seconds
                FROM activity WHERE day BETWEEN ? AND ?
                GROUP BY app_name ORDER BY seconds DESC LIMIT ?
                """, [fromDay, toDay, limit])) ?? []
            return rows.map { row in
                let name = row.string("app_name") ?? "Unknown"
                let bundle = row.string("bundle_id")
                return UsageItem(name: name, detail: bundle, seconds: row.double("seconds") ?? 0,
                                 category: categorizer.category(forApp: name, bundleID: bundle) ?? .neutral)
            }
        case .domain:
            let rows = (try? db.query("""
                SELECT domain, SUM(end - start) AS seconds, COUNT(*) AS visits
                FROM activity WHERE day BETWEEN ? AND ? AND domain IS NOT NULL AND domain != ''
                GROUP BY domain ORDER BY seconds DESC LIMIT ?
                """, [fromDay, toDay, limit])) ?? []
            return rows.map { row in
                let domain = row.string("domain") ?? ""
                return UsageItem(name: domain, detail: "\(row.int("visits") ?? 0) segments",
                                 seconds: row.double("seconds") ?? 0,
                                 category: categorizer.category(forDomain: domain) ?? .neutral)
            }
        case .category:
            let rows = (try? db.query("""
                SELECT category, SUM(end - start) AS seconds FROM activity
                WHERE day BETWEEN ? AND ? GROUP BY category ORDER BY seconds DESC
                """, [fromDay, toDay])) ?? []
            return rows.map { row in
                let c = ActivityCategory(rawValue: row.string("category") ?? "") ?? .neutral
                return UsageItem(name: c.label, detail: nil, seconds: row.double("seconds") ?? 0, category: c)
            }
        case .day:
            let rows = (try? db.query("""
                SELECT day, SUM(end - start) AS seconds FROM activity
                WHERE day BETWEEN ? AND ? GROUP BY day ORDER BY day
                """, [fromDay, toDay])) ?? []
            return rows.map { row in
                UsageItem(name: row.string("day") ?? "", detail: nil, seconds: row.double("seconds") ?? 0, category: .neutral)
            }
        }
    }

    /// Seconds spent today on something matching a block/limit pattern.
    public func secondsToday(kind: TargetKind, pattern: String, day: String = DayKey.today) -> Double {
        switch kind {
        case .domain:
            let p = Categorizer.normalizeDomainPattern(pattern)
            let rows = try? db.query("""
                SELECT SUM(end - start) AS s FROM activity WHERE day = ? AND (domain = ? OR domain LIKE ?)
                """, [day, p, "%." + p])
            return rows?.first?.double("s") ?? 0
        case .app:
            let rows = try? db.query("""
                SELECT SUM(end - start) AS s FROM activity
                WHERE day = ? AND (bundle_id = ? COLLATE NOCASE OR app_name = ? COLLATE NOCASE)
                """, [day, pattern, pattern])
            return rows?.first?.double("s") ?? 0
        }
    }

    // MARK: - Category rules

    public func rules() -> [CategoryRule] {
        let rows = (try? db.query("SELECT * FROM rules ORDER BY kind, pattern")) ?? []
        return rows.compactMap { row in
            guard let kind = TargetKind(rawValue: row.string("kind") ?? ""),
                  let category = ActivityCategory(rawValue: row.string("category") ?? "") else { return nil }
            return CategoryRule(id: Int64(row.int("id") ?? 0), kind: kind, pattern: row.string("pattern") ?? "",
                                category: category)
        }
    }

    public func setRule(kind: TargetKind, pattern: String, category: ActivityCategory) throws {
        let p = kind == .domain ? Categorizer.normalizeDomainPattern(pattern) : pattern.trimmingCharacters(in: .whitespaces)
        guard !p.isEmpty else { return }
        try db.run("""
            INSERT INTO rules(kind, pattern, category) VALUES (?, ?, ?)
            ON CONFLICT(kind, pattern) DO UPDATE SET category = excluded.category
            """, [kind.rawValue, p, category.rawValue])
        recategorize(sinceDay: DayKey.offset(DayKey.today, days: -30))
    }

    public func deleteRule(id: Int64) {
        _ = try? db.run("DELETE FROM rules WHERE id = ?", [id])
        recategorize(sinceDay: DayKey.offset(DayKey.today, days: -30))
    }

    // MARK: - Blocklist

    public func blocklist() -> [BlockItem] {
        let rows = (try? db.query("SELECT * FROM blocklist ORDER BY kind DESC, pattern")) ?? []
        return rows.compactMap { row in
            guard let kind = TargetKind(rawValue: row.string("kind") ?? "") else { return nil }
            return BlockItem(id: Int64(row.int("id") ?? 0), kind: kind, pattern: row.string("pattern") ?? "")
        }
    }

    public func addBlock(kind: TargetKind, pattern: String) throws {
        let p = kind == .domain ? Categorizer.normalizeDomainPattern(pattern) : pattern.trimmingCharacters(in: .whitespaces)
        guard !p.isEmpty else { return }
        try db.run("INSERT OR IGNORE INTO blocklist(kind, pattern) VALUES (?, ?)", [kind.rawValue, p])
    }

    public func removeBlock(kind: TargetKind, pattern: String) throws {
        let p = kind == .domain ? Categorizer.normalizeDomainPattern(pattern) : pattern
        try db.run("DELETE FROM blocklist WHERE kind = ? AND pattern = ? COLLATE NOCASE", [kind.rawValue, p])
    }

    // MARK: - Daily limits

    public func limits() -> [DailyLimit] {
        let rows = (try? db.query("SELECT * FROM limits ORDER BY pattern")) ?? []
        return rows.compactMap { row in
            guard let kind = TargetKind(rawValue: row.string("kind") ?? "") else { return nil }
            return DailyLimit(id: Int64(row.int("id") ?? 0), kind: kind, pattern: row.string("pattern") ?? "",
                              minutes: row.int("minutes") ?? 0)
        }
    }

    public func setLimit(kind: TargetKind, pattern: String, minutes: Int) throws {
        let p = kind == .domain ? Categorizer.normalizeDomainPattern(pattern) : pattern.trimmingCharacters(in: .whitespaces)
        guard !p.isEmpty else { return }
        if minutes <= 0 {
            try db.run("DELETE FROM limits WHERE kind = ? AND pattern = ?", [kind.rawValue, p])
            return
        }
        try db.run("""
            INSERT INTO limits(kind, pattern, minutes) VALUES (?, ?, ?)
            ON CONFLICT(kind, pattern) DO UPDATE SET minutes = excluded.minutes
            """, [kind.rawValue, p, minutes])
    }

    public func deleteLimit(id: Int64) {
        _ = try? db.run("DELETE FROM limits WHERE id = ?", [id])
    }

    // MARK: - Focus sessions

    private func session(from row: Row) -> FocusSession {
        FocusSession(
            id: Int64(row.int("id") ?? 0),
            start: Date(timeIntervalSince1970: row.double("start") ?? 0),
            end: Date(timeIntervalSince1970: row.double("end") ?? 0),
            locked: row.bool("locked"),
            label: row.string("label"),
            endedEarly: row.double("ended_early").map { Date(timeIntervalSince1970: $0) },
            createdBy: row.string("created_by"))
    }

    public func activeFocusSession(now: Date = Date()) -> FocusSession? {
        let rows = (try? db.query("""
            SELECT * FROM focus_sessions
            WHERE start <= ? AND end > ? AND ended_early IS NULL
            ORDER BY locked DESC, end DESC LIMIT 1
            """, [now, now])) ?? []
        return rows.first.map(session(from:))
    }

    /// Sessions that haven't finished yet (running or scheduled to start), soonest first.
    public func pendingFocusSessions(now: Date = Date()) -> [FocusSession] {
        let rows = (try? db.query("""
            SELECT * FROM focus_sessions WHERE end > ? AND ended_early IS NULL ORDER BY start
            """, [now])) ?? []
        return rows.map(session(from:))
    }

    @discardableResult
    public func startFocusSession(minutes: Int, locked: Bool, label: String?, createdBy: String) throws -> FocusSession {
        let now = Date()
        if let existing = activeFocusSession(now: now) {
            // Extending: never shorten a running session, and never unlock a locked one.
            let newEnd = max(existing.end, now.addingTimeInterval(Double(minutes) * 60))
            try db.run("UPDATE focus_sessions SET end = ?, locked = ? WHERE id = ?",
                       [newEnd, existing.locked || locked, existing.id])
            return activeFocusSession(now: now) ?? existing
        }
        let end = now.addingTimeInterval(Double(max(1, minutes)) * 60)
        let id = try db.run("""
            INSERT INTO focus_sessions(start, end, locked, label, created_by) VALUES (?, ?, ?, ?, ?)
            """, [now, end, locked, label, createdBy])
        return FocusSession(id: id, start: now, end: end, locked: locked, label: label, endedEarly: nil, createdBy: createdBy)
    }

    public enum StopResult { case stopped, locked, noSession }

    @discardableResult
    public func stopFocusSession(force: Bool = false) -> StopResult {
        guard let session = activeFocusSession() else { return .noSession }
        if session.locked && !force { return .locked }
        _ = try? db.run("UPDATE focus_sessions SET ended_early = ? WHERE id = ?", [Date(), session.id])
        return .stopped
    }

    public func focusSessions(sinceDay: String) -> [FocusSession] {
        let since = DayKey.date(from: sinceDay) ?? Date().addingTimeInterval(-7 * 86400)
        let rows = (try? db.query("SELECT * FROM focus_sessions WHERE start >= ? ORDER BY start DESC", [since])) ?? []
        return rows.map(session(from:))
    }

    // MARK: - Schedules

    public func schedules() -> [BlockSchedule] {
        let rows = (try? db.query("SELECT * FROM schedules ORDER BY start_minute")) ?? []
        return rows.map { row in
            BlockSchedule(
                id: Int64(row.int("id") ?? 0),
                weekdays: (row.string("weekdays") ?? "").split(separator: ",").compactMap { Int($0) },
                startMinute: row.int("start_minute") ?? 0,
                endMinute: row.int("end_minute") ?? 0,
                enabled: row.bool("enabled"),
                label: row.string("label"))
        }
    }

    public func addSchedule(weekdays: [Int], startMinute: Int, endMinute: Int, label: String?) throws {
        try db.run("""
            INSERT INTO schedules(weekdays, start_minute, end_minute, enabled, label) VALUES (?, ?, ?, 1, ?)
            """, [weekdays.sorted().map(String.init).joined(separator: ","), startMinute, endMinute, label])
    }

    public func setScheduleEnabled(id: Int64, enabled: Bool) {
        _ = try? db.run("UPDATE schedules SET enabled = ? WHERE id = ?", [enabled, id])
    }

    public func deleteSchedule(id: Int64) {
        _ = try? db.run("DELETE FROM schedules WHERE id = ?", [id])
    }

    public func activeSchedule(now: Date = Date()) -> BlockSchedule? {
        schedules().first { $0.isActive(at: now) }
    }

    // MARK: - Block events

    public func logBlock(kind: TargetKind, target: String) {
        let now = Date()
        _ = try? db.run("INSERT INTO block_events(time, day, kind, target) VALUES (?, ?, ?, ?)",
                    [now, DayKey.string(for: now), kind.rawValue, target])
    }

    public func blockCount(day: String) -> Int {
        (try? db.query("SELECT COUNT(*) AS n FROM block_events WHERE day = ?", [day]))?.first?.int("n") ?? 0
    }

    public func blockEvents(day: String) -> [(Date, String)] {
        let rows = (try? db.query("SELECT time, target FROM block_events WHERE day = ? ORDER BY time DESC", [day])) ?? []
        return rows.map { (Date(timeIntervalSince1970: $0.double("time") ?? 0), $0.string("target") ?? "") }
    }
}
