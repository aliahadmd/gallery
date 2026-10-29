import Foundation
import SQLite3

/// A prepared statement. Reused across batched writes: re-preparing per row costs 5–10× at 100k items,
/// so callers keep one `Statement` and cycle it with `reset()` + `clearBindings()`.
/// Confined to the isolation domain of whoever prepared it (same rule as `SQLiteHandle`).
public final class Statement {
    private let handle: SQLiteHandle
    private let pointer: OpaquePointer
    public let sql: String
    public let columnNames: [String]
    public let parameterCount: Int

    /// - Parameter transient: `SQLITE_TRANSIENT` makes SQLite copy the bound bytes immediately, so the
    ///   Swift-side buffers (`String.UTF8`, `[UInt8]`) never need to outlive the call.
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(handle: SQLiteHandle, sql: String, pointer: OpaquePointer) {
        self.handle = handle
        self.sql = sql
        self.pointer = pointer
        self.parameterCount = Int(sqlite3_bind_parameter_count(pointer))
        let count = Int(sqlite3_column_count(pointer))
        self.columnNames = (0..<count).map { index in
            guard let name = sqlite3_column_name(pointer, Int32(index)) else { return "#\(index)" }
            return String(cString: name)
        }
    }

    deinit {
        sqlite3_finalize(pointer)
    }

    public func bind(_ values: [Value]) throws {
        guard values.count == parameterCount else {
            throw SQLiteError.bindFailed(index: values.count, value: .integer(Int64(parameterCount)))
        }
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let code: Int32
            switch value {
            case .null:
                code = sqlite3_bind_null(pointer, index)
            case .integer(let v):
                code = sqlite3_bind_int64(pointer, index, v)
            case .real(let v):
                code = sqlite3_bind_double(pointer, index, v)
            case .text(let v):
                code = v.withCString { sqlite3_bind_text(pointer, index, $0, -1, Self.transient) }
            case .blob(let bytes):
                code = bytes.withUnsafeBytes { buffer in
                    sqlite3_bind_blob(
                        pointer,
                        index,
                        buffer.baseAddress,
                        Int32(buffer.count),
                        Self.transient
                    )
                }
            }
            guard code == SQLITE_OK else { throw SQLiteError.bindFailed(index: offset, value: value) }
        }
    }

    /// Advances once. Returns a row for `SQLITE_ROW`, `nil` for `SQLITE_DONE`.
    public func step() throws -> Row? {
        let code = sqlite3_step(pointer)
        switch code {
        case SQLITE_ROW:
            return try readRow()
        case SQLITE_DONE:
            return nil
        default:
            throw SQLiteError.stepFailed(sql: sql, code: code, message: handle.lastMessage)
        }
    }

    public func run() throws {
        while try step() != nil {}
    }

    public func all() throws -> [Row] {
        var rows: [Row] = []
        while let row = try step() { rows.append(row) }
        return rows
    }

    public func firstRow() throws -> Row? {
        defer { reset() }
        return try step()
    }

    /// Bind, take one row, reset. This is the primitive behind `INSERT … RETURNING`: a batched upsert has
    /// to hand the caller the rowid it just assigned without stepping a second time.
    public func firstRow(_ values: [Value]) throws -> Row? {
        defer { reset() }
        try bind(values)
        return try step()
    }

    private func readRow() throws -> Row {
        let count = Int32(columnNames.count)
        var values: [Value] = []
        values.reserveCapacity(Int(count))
        for index in 0..<count {
            switch sqlite3_column_type(pointer, index) {
            case SQLITE_INTEGER: values.append(.integer(sqlite3_column_int64(pointer, index)))
            case SQLITE_FLOAT: values.append(.real(sqlite3_column_double(pointer, index)))
            case SQLITE_TEXT:
                guard let text = sqlite3_column_text(pointer, index) else { values.append(.null); continue }
                let length = Int(sqlite3_column_bytes(pointer, index))
                values.append(.text(String(decoding: UnsafeRawBufferPointer(start: text, count: length), as: UTF8.self)))
            case SQLITE_BLOB:
                let length = Int32(sqlite3_column_bytes(pointer, index))
                guard length > 0, let base = sqlite3_column_blob(pointer, index) else { values.append(.blob([])); continue }
                values.append(.blob(UnsafeRawBufferPointer(start: base, count: Int(length)).map { $0 }))
            case SQLITE_NULL: values.append(.null)
            default: values.append(.null)
            }
        }
        return Row(values: values, columns: columnNames)
    }

    public func reset() {
        sqlite3_reset(pointer)
    }

    public func clearBindings() {
        sqlite3_clear_bindings(pointer)
    }

    /// Resets before leaving scope so a partially-stepped statement never carries a stale read lock
    /// into the next `step()` — SQLite returns `SQLITE_BUSY` on an unfinalized open cursor.
    public func run(_ values: [Value]) throws {
        defer { reset() }
        try bind(values)
        try run()
    }

    public func query(_ values: [Value]) throws -> [Row] {
        defer { reset() }
        try bind(values)
        return try all()
    }
}
