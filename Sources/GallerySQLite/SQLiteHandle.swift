import Foundation
import SQLite3

/// Owns one `sqlite3*` connection. Not `Sendable` by design: a handle must be confined to a single
/// actor (the catalog opens two — one read-write, one read-only) so that the actor, not SQLite's
/// internal mutex, is the serialisation boundary.
public final class SQLiteHandle {
    public enum Kind: Sendable {
        case readWrite
        case readOnly
    }

    public static let defaultReadWritePragmas = [
        "PRAGMA journal_mode=WAL",
        "PRAGMA synchronous=NORMAL",
        "PRAGMA busy_timeout=4000",
        "PRAGMA foreign_keys=ON",
        "PRAGMA temp_store=MEMORY",
        "PRAGMA cache_size=-32768",
        "PRAGMA mmap_size=134217728",
        "PRAGMA journal_size_limit=33554432",
        "PRAGMA wal_autocheckpoint=1000",
    ]

    public static let defaultReadOnlyPragmas = [
        "PRAGMA busy_timeout=4000",
        "PRAGMA query_only=ON",
    ]

    let pointer: OpaquePointer
    public let kind: Kind
    public let path: String

    /// Guard against nested `write(...)` calls, which would emit a stray `BEGIN` inside a transaction.
    private var isInTransaction = false

    public static func open(
        path: String,
        kind: Kind,
        pragmas: [String]? = nil
    ) throws -> SQLiteHandle {
        let flags: Int32
        switch kind {
        case .readWrite:
            flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX
        case .readOnly:
            flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        }

        var database: OpaquePointer?
        let code = path.withCString { sqlite3_open_v2($0, &database, flags, nil) }
        guard code == SQLITE_OK, let database else {
            let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            if let database { sqlite3_close_v2(database) }
            throw SQLiteError.openFailed(code: code, message: message)
        }

        let handle = SQLiteHandle(pointer: database, kind: kind, path: path)
        // Extended codes are what let a writer tell a UNIQUE collision from a foreign-key failure; without
        // them both arrive as the primary SQLITE_CONSTRAINT and the recovery path would be guesswork.
        sqlite3_extended_result_codes(database, 1)
        for pragma in pragmas ?? (kind == .readWrite ? defaultReadWritePragmas : defaultReadOnlyPragmas) {
            try handle.exec(pragma)
        }
        return handle
    }

    private init(pointer: OpaquePointer, kind: Kind, path: String) {
        self.pointer = pointer
        self.kind = kind
        self.path = path
    }

    deinit {
        sqlite3_close_v2(pointer)
    }

    public var lastMessage: String { String(cString: sqlite3_errmsg(pointer)) }

    public func prepare(_ sql: String) throws -> Statement {
        var statement: OpaquePointer?
        let code = sql.withCString {
            sqlite3_prepare_v2(pointer, $0, -1, &statement, nil)
        }
        guard code == SQLITE_OK, let statement else {
            if let statement { sqlite3_finalize(statement) }
            throw SQLiteError.prepareFailed(sql: sql, code: code, message: lastMessage)
        }
        return Statement(handle: self, sql: sql, pointer: statement)
    }

    /// Runs one or more statements with no result rows — pragmas, DDL, `INSERT` with no bindings.
    /// Bindings apply to every statement in the script, so a multi-statement script and a value to bind
    /// are two different jobs; `Statement.bind` throws on a parameter-count mismatch rather than guessing.
    public func exec(_ sql: String, _ values: [Value] = []) throws {
        try sql.withCString { start in
            var cursor = start
            while true {
                var compiled: OpaquePointer?
                var tail: UnsafePointer<CChar>? = cursor
                let code = sqlite3_prepare_v2(pointer, cursor, -1, &compiled, &tail)
                guard code == SQLITE_OK else {
                    if let compiled { sqlite3_finalize(compiled) }
                    throw SQLiteError.prepareFailed(
                        sql: String(cString: cursor), code: code, message: lastMessage
                    )
                }
                // SQLITE_OK with no statement means only whitespace and comments are left.
                guard let compiled else { return }
                let statement = Statement(
                    handle: self,
                    sql: Self.statementText(from: cursor, to: tail),
                    pointer: compiled
                )
                if !values.isEmpty { try statement.bind(values) }
                _ = try statement.step()
                guard let tail else { return }
                cursor = tail
            }
        }
    }

    /// The text SQLite consumed for the statement it just compiled. The tail pointer is the only reliable
    /// boundary: `sqlite3_sql` returns the entire remainder of the script, which would re-prepare the same
    /// first statement forever.
    private static func statementText(
        from cursor: UnsafePointer<CChar>,
        to tail: UnsafePointer<CChar>?
    ) -> String {
        guard let tail else { return String(cString: cursor) }
        let bytes = UnsafeRawPointer(cursor).distance(to: UnsafeRawPointer(tail))
        guard bytes > 0 else { return "" }
        return String(decoding: UnsafeRawBufferPointer(start: cursor, count: bytes), as: UTF8.self)
    }

    public func query(_ sql: String, _ values: [Value] = []) throws -> [Row] {
        let statement = try prepare(sql)
        if !values.isEmpty { try statement.bind(values) }
        return try statement.all()
    }

    public func firstValue(_ sql: String, _ values: [Value] = []) throws -> Value? {
        let statement = try prepare(sql)
        if !values.isEmpty { try statement.bind(values) }
        return try statement.step()?.first
    }

    /// One row, by name — the primitive behind `INSERT … RETURNING`, where the statement either produces
    /// exactly one row or the write failed.
    public func firstRow(_ sql: String, _ values: [Value] = []) throws -> Row? {
        let statement = try prepare(sql)
        if !values.isEmpty { try statement.bind(values) }
        return try statement.step()
    }

    public func firstValueOrThrow(_ sql: String, _ values: [Value] = []) throws -> Value {
        guard let value = try firstValue(sql, values) else {
            throw SQLiteError.noRows(sql: sql)
        }
        return value
    }

    public var changes: Int32 { sqlite3_changes(pointer) }
    public var totalChanges: Int64 { sqlite3_total_changes64(pointer) }
    public var lastInsertRowID: Int64 { sqlite3_last_insert_rowid(pointer) }

    // MARK: - Transactions

    /// Runs `body` inside one `BEGIN IMMEDIATE` … `COMMIT`, rolling back on any throw.
    ///
    /// Synchronous on purpose. An `await` anywhere in this path would let the owning actor run another
    /// method between the `BEGIN` and the `COMMIT`, and that second write would meet a transaction that is
    /// already open. Concurrency at the connection level is the actor's job, not the transaction's;
    /// contention from *outside* the process is handled by `busy_timeout`, which applies to `BEGIN` too.
    public func write<T>(_ body: () throws -> T) throws -> T {
        guard kind == .readWrite else { throw SQLiteError.wrongConnectionKind("write on read-only connection") }
        guard !isInTransaction else { throw SQLiteError.wrongConnectionKind("nested write") }

        isInTransaction = true
        do {
            try exec("BEGIN IMMEDIATE")
            let result = try body()
            try exec("COMMIT")
            isInTransaction = false
            return result
        } catch {
            isInTransaction = false
            try? exec("ROLLBACK")
            throw error
        }
    }

    // MARK: - Schema versioning

    public func userVersion() throws -> Int32 {
        Int32(truncatingIfNeeded: try firstValueOrThrow("PRAGMA user_version").int64OrZero)
    }

    public func setUserVersion(_ version: Int32) throws {
        // PRAGMAs cannot be parameter-bound, and this value never comes from outside the process.
        try exec("PRAGMA user_version = \(version)")
    }

    public func checkpoint() throws { try exec("PRAGMA wal_checkpoint(TRUNCATE)") }
    public func optimize() throws { try exec("PRAGMA optimize") }

    public func integrityCheck() throws -> [String] {
        try query("PRAGMA integrity_check").map { try $0.string(at: 0) }
    }
}

extension Row {
    public func string(at index: Int) throws -> String {
        guard let value = try self[index].stringValue else {
            throw SQLiteError.typeMismatch(column: "#\(index)", expected: "text", got: try self[index])
        }
        return value
    }

    public var first: Value {
        get throws { try self[0] }
    }
}
