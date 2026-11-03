import Foundation
import SQLite3

/// A deliberately small SQLite wrapper. Both the app and the MCP server open the same
/// file; WAL mode + a busy timeout lets them read and write concurrently.
public final class Database {
    public enum DBError: Error, CustomStringConvertible {
        case open(String)
        case prepare(String, String)
        case step(String, String)

        public var description: String {
            switch self {
            case .open(let m): return "SQLite open failed: \(m)"
            case .prepare(let m, let sql): return "SQLite prepare failed: \(m) — \(sql)"
            case .step(let m, let sql): return "SQLite step failed: \(m) — \(sql)"
            }
        }
    }

    private var handle: OpaquePointer?
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    public init(path: String) throws {
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        if sqlite3_open_v2(path, &handle, flags, nil) != SQLITE_OK {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            sqlite3_close(handle)
            throw DBError.open(message)
        }
        sqlite3_busy_timeout(handle, 5000)
        // WAL lets the app and the MCP server read/write concurrently; NORMAL sync is crash-safe in WAL mode
        // and much cheaper than FULL. secure_delete overwrites deleted rows instead of leaving them on disk.
        try exec("""
            PRAGMA journal_mode=WAL;
            PRAGMA synchronous=NORMAL;
            PRAGMA foreign_keys=ON;
            PRAGMA secure_delete=ON;
            PRAGMA trusted_schema=OFF;
            PRAGMA temp_store=MEMORY;
            """)
        VigilPaths.restrictFile(path)
    }

    deinit {
        sqlite3_close(handle)
    }

    private var errorMessage: String {
        String(cString: sqlite3_errmsg(handle))
    }

    public func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(handle, sql, nil, nil, &err) != SQLITE_OK {
            let message = err.map { String(cString: $0) } ?? errorMessage
            sqlite3_free(err)
            throw DBError.step(message, sql)
        }
    }

    private func prepare(_ sql: String, _ params: [Any?]) throws -> OpaquePointer? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DBError.prepare(errorMessage, sql)
        }
        for (offset, param) in params.enumerated() {
            let index = Int32(offset + 1)
            guard let value = param else {
                sqlite3_bind_null(stmt, index)
                continue
            }
            switch value {
            case let v as Int:
                sqlite3_bind_int64(stmt, index, Int64(v))
            case let v as Int64:
                sqlite3_bind_int64(stmt, index, v)
            case let v as Int32:
                sqlite3_bind_int64(stmt, index, Int64(v))
            case let v as Bool:
                sqlite3_bind_int64(stmt, index, v ? 1 : 0)
            case let v as Double:
                sqlite3_bind_double(stmt, index, v)
            case let v as Date:
                sqlite3_bind_double(stmt, index, v.timeIntervalSince1970)
            case let v as String:
                sqlite3_bind_text(stmt, index, v, -1, Database.transient)
            default:
                sqlite3_bind_text(stmt, index, String(describing: value), -1, Database.transient)
            }
        }
        return stmt
    }

    /// Runs a statement that returns no rows.
    @discardableResult
    public func run(_ sql: String, _ params: [Any?] = []) throws -> Int64 {
        let stmt = try prepare(sql, params)
        defer { sqlite3_finalize(stmt) }
        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else {
            throw DBError.step(errorMessage, sql)
        }
        return sqlite3_last_insert_rowid(handle)
    }

    /// Runs a query and returns every row as a dictionary of column name → value.
    public func query(_ sql: String, _ params: [Any?] = []) throws -> [Row] {
        let stmt = try prepare(sql, params)
        defer { sqlite3_finalize(stmt) }
        var rows: [Row] = []
        let columnCount = sqlite3_column_count(stmt)
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else { throw DBError.step(errorMessage, sql) }
            var values: [String: Any] = [:]
            for i in 0..<columnCount {
                let name = String(cString: sqlite3_column_name(stmt, i))
                switch sqlite3_column_type(stmt, i) {
                case SQLITE_INTEGER:
                    values[name] = sqlite3_column_int64(stmt, i)
                case SQLITE_FLOAT:
                    values[name] = sqlite3_column_double(stmt, i)
                case SQLITE_TEXT:
                    if let text = sqlite3_column_text(stmt, i) {
                        values[name] = String(cString: text)
                    }
                default:
                    break
                }
            }
            rows.append(Row(values: values))
        }
        return rows
    }

    public func transaction(_ body: () throws -> Void) throws {
        try exec("BEGIN IMMEDIATE;")
        do {
            try body()
            try exec("COMMIT;")
        } catch {
            try? exec("ROLLBACK;")
            throw error
        }
    }
}

public struct Row {
    public let values: [String: Any]

    public func string(_ key: String) -> String? {
        switch values[key] {
        case let s as String: return s
        case let i as Int64: return String(i)
        case let d as Double: return String(d)
        default: return nil
        }
    }

    public func double(_ key: String) -> Double? {
        switch values[key] {
        case let d as Double: return d
        case let i as Int64: return Double(i)
        case let s as String: return Double(s)
        default: return nil
        }
    }

    public func int(_ key: String) -> Int? {
        switch values[key] {
        case let i as Int64: return Int(i)
        case let d as Double: return Int(d)
        case let s as String: return Int(s)
        default: return nil
        }
    }

    public func bool(_ key: String) -> Bool {
        (int(key) ?? 0) != 0
    }
}
