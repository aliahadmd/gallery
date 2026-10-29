import Foundation

/// A single SQLite column value. Deliberately has no knowledge of gallery semantics.
public enum Value: Sendable, Hashable {
    case null
    case integer(Int64)
    case real(Double)
    case text(String)
    case blob([UInt8])

    public var isNull: Bool { if case .null = self { true } else { false } }

    public var int64Value: Int64? {
        switch self {
        case .integer(let v): v
        case .real(let v): v.isNaN ? nil : Int64(v)
        case .text(let v): Int64(v)
        default: nil
        }
    }

    public var doubleValue: Double? {
        switch self {
        case .real(let v): v
        case .integer(let v): Double(v)
        case .text(let v): Double(v)
        default: nil
        }
    }

    public var stringValue: String? {
        switch self {
        case .text(let v): v
        case .integer(let v): String(v)
        case .real(let v): String(v)
        case .blob: nil
        case .null: nil
        }
    }

    public var dataValue: Data? {
        switch self {
        case .blob(let v): Data(v)
        case .text(let v): Data(v.utf8)
        default: nil
        }
    }

    public var int64OrZero: Int64 { int64Value ?? 0 }
    public var doubleOrZero: Double { doubleValue ?? 0 }
}

extension Value: CustomStringConvertible {
    public var description: String {
        switch self {
        case .null: "NULL"
        case .integer(let v): "\(v)"
        case .real(let v): "\(v)"
        case .text(let v): "\"\(v)\""
        case .blob(let v): "blob(\(v.count))"
        }
    }
}

extension Value: ExpressibleByNilLiteral {
    public init(nilLiteral: ()) { self = .null }
}

extension Value: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int64) { self = .integer(value) }
}

extension Value: ExpressibleByFloatLiteral {
    public init(floatLiteral value: Double) { self = .real(value) }
}

extension Value: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) { self = .text(value) }
}

/// A row addressed by column index. Column names are resolved once per statement, not per row.
public struct Row: Sendable {
    fileprivate let values: [Value]
    fileprivate let columns: [String]

    init(values: [Value], columns: [String]) {
        self.values = values
        self.columns = columns
    }

    public var columnNames: [String] { columns }
    public var count: Int { values.count }

    public subscript(index: Int) -> Value {
        get throws {
            guard values.indices.contains(index) else {
                throw SQLiteError.columnOutOfRange(index: index, columnCount: values.count)
            }
            return values[index]
        }
    }

    /// Linear scan over column names; call sites cache the index for hot paths.
    public func index(of column: String) -> Int? {
        columns.firstIndex { $0.caseInsensitiveCompare(column) == .orderedSame }
    }

    public func value(named column: String) throws -> Value {
        guard let i = index(of: column) else {
            throw SQLiteError.noSuchColumn(column)
        }
        return values[i]
    }

    public func int64(named column: String) throws -> Int64 {
        guard let v = try value(named: column).int64Value else {
            throw SQLiteError.typeMismatch(column: column, expected: "integer", got: try value(named: column))
        }
        return v
    }

    public func optionalInt64(named column: String) throws -> Int64? {
        try value(named: column).int64Value
    }

    public func double(named column: String) throws -> Double {
        guard let v = try value(named: column).doubleValue else {
            throw SQLiteError.typeMismatch(column: column, expected: "real", got: try value(named: column))
        }
        return v
    }

    public func optionalDouble(named column: String) throws -> Double? {
        try value(named: column).doubleValue
    }

    public func string(named column: String) throws -> String {
        guard let v = try value(named: column).stringValue else {
            throw SQLiteError.typeMismatch(column: column, expected: "text", got: try value(named: column))
        }
        return v
    }

    public func optionalString(named column: String) throws -> String? {
        guard case .text = try value(named: column) else { return nil }
        return try value(named: column).stringValue
    }

    public func data(named column: String) throws -> Data? {
        try value(named: column).dataValue
    }

    public func blob(named column: String) throws -> [UInt8]? {
        if case .blob(let bytes) = try value(named: column) { return bytes }
        return nil
    }

    public func optionalBool(named column: String) throws -> Bool? {
        guard case .null = try value(named: column) else {
            return (try value(named: column).int64OrZero) != 0
        }
        return nil
    }

    public func bool(named column: String, default fallback: Bool = false) throws -> Bool {
        try optionalBool(named: column) ?? fallback
    }
}
