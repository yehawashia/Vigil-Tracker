import Foundation

/// An iPhone or iPad paired with this Mac. Its secret key lives in the Keychain, never in SQLite.
public struct PairedDevice: Codable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var model: String?
    public var platform: String?      // "iOS" | "iPadOS"
    public var pairedAt: Date
    public var lastSeen: Date?
    public var revoked: Bool

    public init(id: String, name: String, model: String?, platform: String?, pairedAt: Date, lastSeen: Date?, revoked: Bool) {
        self.id = id; self.name = name; self.model = model; self.platform = platform
        self.pairedAt = pairedAt; self.lastSeen = lastSeen; self.revoked = revoked
    }

    /// Seen in the last 2 minutes.
    public func isOnline(now: Date = Date()) -> Bool { lastSeen.map { now.timeIntervalSince($0) < 120 } ?? false }
}

/// Time a paired device measured. `precision` is in seconds: 1 = exact, 900 = 15-minute steps (app groups).
public struct DeviceUsage: Codable, Hashable, Identifiable {
    public enum Kind: String, Codable { case domain, appGroup = "app_group", focus }

    public var day: String
    public var kind: Kind
    public var key: String
    public var seconds: Double
    public var precision: Int
    public var category: ActivityCategory?

    public init(day: String, kind: Kind, key: String, seconds: Double, precision: Int, category: ActivityCategory?) {
        self.day = day; self.kind = kind; self.key = key; self.seconds = seconds; self.precision = precision; self.category = category
    }

    public var id: String { "\(day)|\(kind.rawValue)|\(key)" }

    /// Validates input from another device before it touches the database.
    public func validated() -> DeviceUsage? {
        guard DayKey.date(from: day) != nil, seconds.isFinite, seconds >= 0, seconds <= 86400,
              (1...3600).contains(precision) else { return nil }
        var k = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if kind == .domain { k = Categorizer.domain(from: "https://\(k)/") ?? "" }
        guard !k.isEmpty, k.count <= 120 else { return nil }
        var copy = self
        copy.key = k
        return copy
    }
}

extension VigilStore {
    static let devicesSchema = """
    CREATE TABLE IF NOT EXISTS devices (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        model TEXT,
        platform TEXT,
        paired_at REAL NOT NULL,
        last_seen REAL,
        revoked INTEGER NOT NULL DEFAULT 0
    );
    CREATE TABLE IF NOT EXISTS device_usage (
        device_id TEXT NOT NULL,
        day TEXT NOT NULL,
        kind TEXT NOT NULL,
        key TEXT NOT NULL,
        seconds REAL NOT NULL,
        precision_seconds INTEGER NOT NULL,
        category TEXT,
        updated REAL NOT NULL,
        PRIMARY KEY (device_id, day, kind, key)
    );
    CREATE INDEX IF NOT EXISTS idx_device_usage_day ON device_usage(day);
    """

    public func devices(includeRevoked: Bool = false) -> [PairedDevice] {
        let rows = (try? db.query("SELECT * FROM devices \(includeRevoked ? "" : "WHERE revoked = 0") ORDER BY paired_at")) ?? []
        return rows.compactMap { r in
            guard let id = r.string("id"), let name = r.string("name") else { return nil }
            return PairedDevice(id: id, name: name, model: r.string("model"), platform: r.string("platform"),
                                pairedAt: Date(timeIntervalSince1970: r.double("paired_at") ?? 0),
                                lastSeen: r.double("last_seen").map { Date(timeIntervalSince1970: $0) },
                                revoked: r.bool("revoked"))
        }
    }

    public func addDevice(_ d: PairedDevice) throws {
        try db.run("""
            INSERT INTO devices(id, name, model, platform, paired_at, last_seen, revoked) VALUES (?, ?, ?, ?, ?, ?, 0)
            """, [d.id, String(d.name.prefix(80)), d.model.map { String($0.prefix(80)) }, d.platform, d.pairedAt, d.lastSeen])
    }

    public func touchDevice(id: String, name: String? = nil, at date: Date = Date()) {
        if let name {
            _ = try? db.run("UPDATE devices SET last_seen = ?, name = ? WHERE id = ? AND revoked = 0", [date, String(name.prefix(80)), id])
        } else {
            _ = try? db.run("UPDATE devices SET last_seen = ? WHERE id = ? AND revoked = 0", [date, id])
        }
    }

    /// Revokes a device and deletes what it sent. The caller also deletes its Keychain key.
    public func revokeDevice(id: String) {
        _ = try? db.run("UPDATE devices SET revoked = 1 WHERE id = ?", [id])
        _ = try? db.run("DELETE FROM device_usage WHERE device_id = ?", [id])
    }

    /// Upserts usage a device reported. Invalid rows are dropped. Returns how many were stored.
    @discardableResult
    public func recordDeviceUsage(deviceID: String, _ items: [DeviceUsage]) -> Int {
        let valid = items.prefix(5000).compactMap { $0.validated() }
        let now = Date()
        try? db.transaction {
            for u in valid {
                try db.run("""
                    INSERT INTO device_usage(device_id, day, kind, key, seconds, precision_seconds, category, updated)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(device_id, day, kind, key) DO UPDATE SET seconds = excluded.seconds,
                      precision_seconds = excluded.precision_seconds, category = excluded.category, updated = excluded.updated
                    """, [deviceID, u.day, u.kind.rawValue, u.key, u.seconds, u.precision, u.category?.rawValue, now])
            }
        }
        return valid.count
    }

    public func deviceUsage(deviceID: String, sinceDay: String) -> [DeviceUsage] {
        let rows = (try? db.query("""
            SELECT * FROM device_usage WHERE device_id = ? AND day >= ? ORDER BY day DESC, seconds DESC
            """, [deviceID, sinceDay])) ?? []
        return rows.compactMap { r in
            guard let day = r.string("day"), let kind = DeviceUsage.Kind(rawValue: r.string("kind") ?? ""),
                  let key = r.string("key") else { return nil }
            return DeviceUsage(day: day, kind: kind, key: key, seconds: r.double("seconds") ?? 0,
                               precision: r.int("precision_seconds") ?? 1,
                               category: r.string("category").flatMap(ActivityCategory.init(rawValue:)))
        }
    }
}
