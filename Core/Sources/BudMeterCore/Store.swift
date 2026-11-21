import Foundation
import SQLite3

public enum StoreError: Error {
    case sqlite(String)
}

/// Small SQLite wrapper holding devices and battery samples. Not thread safe: use from one actor.
public final class Store {
    private var db: OpaquePointer?

    public init(path: String) throws {
        if sqlite3_open(path, &db) != SQLITE_OK {
            throw StoreError.sqlite("Cannot open \(path)")
        }
        try exec("""
            PRAGMA journal_mode = WAL;
            CREATE TABLE IF NOT EXISTS devices (
                address TEXT PRIMARY KEY,
                name TEXT NOT NULL,
                product_id INTEGER,
                first_seen REAL NOT NULL,
                last_seen REAL NOT NULL,
                rated_hours REAL
            );
            CREATE TABLE IF NOT EXISTS samples (
                address TEXT NOT NULL,
                time REAL NOT NULL,
                main INTEGER,
                left_level INTEGER,
                right_level INTEGER,
                case_level INTEGER,
                state TEXT NOT NULL
            );
            CREATE INDEX IF NOT EXISTS samples_by_device ON samples(address, time);
            """)
        // Added after the first version; fails harmlessly when the column exists.
        try? exec("ALTER TABLE samples ADD COLUMN wearing INTEGER")
        try? exec("ALTER TABLE samples ADD COLUMN in_case INTEGER")
        try? exec("ALTER TABLE samples ADD COLUMN session_start INTEGER")
        try? exec("ALTER TABLE samples ADD COLUMN left_place INTEGER")
        try? exec("ALTER TABLE samples ADD COLUMN right_place INTEGER")
    }

    deinit { sqlite3_close(db) }

    /// ~/Library/Application Support/BudMeter/budmeter.sqlite, or $BUDMETER_DB if set (for demo data).
    public static func defaultPath() throws -> String {
        if let path = ProcessInfo.processInfo.environment["BUDMETER_DB"] { return path }
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BudMeter", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("budmeter.sqlite").path
    }

    // MARK: Devices

    /// Insert a new device or refresh name / product ID / last seen of an existing one.
    public func upsertDevice(address: String, name: String, productID: Int?, seen: Date) throws {
        try run("""
            INSERT INTO devices (address, name, product_id, first_seen, last_seen) VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(address) DO UPDATE SET name = excluded.name,
                product_id = COALESCE(excluded.product_id, devices.product_id),
                last_seen = excluded.last_seen
            """, [address, name, productID, seen.timeIntervalSince1970, seen.timeIntervalSince1970])
    }

    public func setRatedHours(address: String, hours: Double?) throws {
        try run("UPDATE devices SET rated_hours = ? WHERE address = ?", [hours, address])
    }

    public func devices() throws -> [Device] {
        try query("SELECT address, name, product_id, first_seen, last_seen, rated_hours FROM devices ORDER BY last_seen DESC") { s in
            Device(address: text(s, 0), name: text(s, 1), productID: int(s, 2),
                   firstSeen: Date(timeIntervalSince1970: sqlite3_column_double(s, 3)),
                   lastSeen: Date(timeIntervalSince1970: sqlite3_column_double(s, 4)),
                   ratedHoursOverride: double(s, 5))
        }
    }

    // MARK: Samples

    public func insert(_ sample: Sample) throws {
        try run("INSERT INTO samples (address, time, main, left_level, right_level, case_level, state, wearing, in_case, session_start, left_place, right_place) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                [sample.address, sample.time.timeIntervalSince1970, sample.main, sample.left, sample.right,
                 sample.caseLevel, sample.state.rawValue, sample.wearing.map { $0 ? 1 : 0 },
                 sample.inCase.map { $0 ? 1 : 0 }, sample.sessionStart ? 1 : nil,
                 sample.placementLeft, sample.placementRight])
    }

    /// Saves a reading and refreshes the device's name and last-seen time in one transaction.
    public func record(_ sample: Sample, name: String, productID: Int?) throws {
        try exec("BEGIN")
        do {
            try insert(sample)
            try upsertDevice(address: sample.address, name: name, productID: productID, seen: sample.time)
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    public func samples(address: String, since: Date = .distantPast) throws -> [Sample] {
        try query("SELECT time, main, left_level, right_level, case_level, state, wearing, in_case, session_start, left_place, right_place FROM samples WHERE address = ? AND time >= ? ORDER BY time",
                  [address, since.timeIntervalSince1970]) { s in
            Sample(time: Date(timeIntervalSince1970: sqlite3_column_double(s, 0)), address: address,
                   main: int(s, 1), left: int(s, 2), right: int(s, 3), caseLevel: int(s, 4),
                   state: UsageState(rawValue: text(s, 5)) ?? .idle, wearing: int(s, 6).map { $0 != 0 },
                   inCase: int(s, 7).map { $0 != 0 }, sessionStart: int(s, 8) == 1,
                   placementLeft: int(s, 9), placementRight: int(s, 10))
        }
    }

    // MARK: SQLite plumbing

    private func exec(_ sql: String) throws {
        if sqlite3_exec(db, sql, nil, nil, nil) != SQLITE_OK { throw error() }
    }

    private func prepare(_ sql: String, _ params: [Any?]) throws -> OpaquePointer? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { throw error() }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (i, param) in params.enumerated() {
            let idx = Int32(i + 1)
            switch param {
            case let v as String: sqlite3_bind_text(stmt, idx, v, -1, transient)
            case let v as Int: sqlite3_bind_int64(stmt, idx, Int64(v))
            case let v as Double: sqlite3_bind_double(stmt, idx, v)
            default: sqlite3_bind_null(stmt, idx)
            }
        }
        return stmt
    }

    private func run(_ sql: String, _ params: [Any?] = []) throws {
        let stmt = try prepare(sql, params)
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw error() }
    }

    private func query<T>(_ sql: String, _ params: [Any?] = [], _ row: (OpaquePointer?) -> T) throws -> [T] {
        let stmt = try prepare(sql, params)
        defer { sqlite3_finalize(stmt) }
        var out: [T] = []
        var result = sqlite3_step(stmt)
        while result == SQLITE_ROW {
            out.append(row(stmt))
            result = sqlite3_step(stmt)
        }
        guard result == SQLITE_DONE else { throw error() }  // never return part of a result as if complete
        return out
    }

    private func error() -> StoreError {
        StoreError.sqlite(String(cString: sqlite3_errmsg(db)))
    }
}

private func text(_ s: OpaquePointer?, _ i: Int32) -> String {
    sqlite3_column_text(s, i).map { String(cString: $0) } ?? ""
}

private func int(_ s: OpaquePointer?, _ i: Int32) -> Int? {
    sqlite3_column_type(s, i) == SQLITE_NULL ? nil : Int(sqlite3_column_int64(s, i))
}

private func double(_ s: OpaquePointer?, _ i: Int32) -> Double? {
    sqlite3_column_type(s, i) == SQLITE_NULL ? nil : sqlite3_column_double(s, i)
}
