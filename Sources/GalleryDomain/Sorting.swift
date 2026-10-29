import Foundation

public enum SortField: String, Sendable, Hashable, Codable, CaseIterable {
    case captureDate
    case dateAdded
    case fileName
    case byteSize
    case pixelCount
    case duration

    /// A closed set of expressions: the sort API never accepts a column name from a caller, which is what
    /// lets `AlbumQuery` place this into SQL as text rather than as a (impossible) parameter binding.
    public var columnSQL: String {
        switch self {
        case .captureDate: "cap_utc"
        case .dateAdded: "added_ns"
        case .fileName: "name COLLATE NOCASE"
        case .byteSize: "size_bytes"
        case .pixelCount: "COALESCE(px_w, 0) * COALESCE(px_h, 0)"
        case .duration: "COALESCE(duration_us, 0)"
        }
    }
}

/// `Direction` rather than `Order`: Foundation ships a `SortOrder` of its own, and every file that imports
/// both would otherwise have to qualify the name.
public enum SortDirection: String, Sendable, Hashable, Codable, CaseIterable {
    case ascending
    case descending

    public var sql: String { self == .ascending ? "ASC" : "DESC" }
    public var keysetOperator: String { self == .ascending ? ">" : "<" }
    public var toggled: SortDirection { self == .ascending ? .descending : .ascending }
}

public struct MediaSort: Sendable, Hashable, Codable {
    public var field: SortField
    public var order: SortDirection

    public init(field: SortField, order: SortDirection) {
        self.field = field
        self.order = order
    }

    /// The canonical grid order. `id` is the deterministic tiebreak, so paging never skips or repeats rows
    /// when a burst puts 4,000 photos on one timestamp. Undated media carries the 0 sentinel in `cap_utc`,
    /// which lands it at the end of a newest-first sort by arithmetic instead of a `NULLS LAST` clause the
    /// index cannot serve.
    public static let `default` = MediaSort(field: .captureDate, order: .descending)

    public var orderBySQL: String { "\(field.columnSQL) \(order.sql), id \(order.sql)" }

    /// Keyset ("seek") pagination: one row-value comparison against the last row of the previous page.
    /// `OFFSET` degrades past ~10k rows because it still walks and discards them; this is an index seek.
    public var keysetPredicateSQL: String {
        "(\(field.columnSQL), id) \(order.keysetOperator) (?, ?)"
    }
}

/// The value a page ended on. Kept as its own enum rather than a `Double` because a nanosecond epoch needs
/// full Int64 precision and a filename sort seeks on text.
public enum CursorValue: Sendable, Hashable, Codable {
    case integer(Int64)
    case real(Double)
    case text(String)
}

public struct SortCursor: Sendable, Hashable, Codable {
    public var primary: CursorValue
    public var id: Int64

    public init(primary: CursorValue, id: Int64) {
        self.primary = primary
        self.id = id
    }
}

/// What the middle column is showing. One comparable value rather than a navigation stack, so deep links,
/// back gestures and restored window state all reduce to the same thing.
public enum LibrarySelection: Sendable, Hashable, Codable {
    case welcome
    case album(AlbumKind)
}
