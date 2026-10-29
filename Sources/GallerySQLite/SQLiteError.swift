import Foundation
import SQLite3

public enum SQLiteError: Error, Sendable, CustomStringConvertible {
    case openFailed(code: Int32, message: String)
    case prepareFailed(sql: String, code: Int32, message: String)
    case stepFailed(sql: String, code: Int32, message: String)
    case bindFailed(index: Int, value: Value)
    case busy(retries: Int)
    case columnOutOfRange(index: Int, columnCount: Int)
    case noSuchColumn(String)
    case noRows(sql: String)
    case typeMismatch(column: String, expected: String, got: Value)
    case wrongConnectionKind(String)
    case downgradeDetected(found: Int32, supported: Int32)

    /// The extended result code of the failed statement, when there is one. Callers test this instead of
    /// matching on cases, so `SQLITE_*` constants stay vocabulary that only this module has to import.
    public var resultCode: Int32? {
        switch self {
        case .prepareFailed(_, let code, _), .stepFailed(_, let code, _): code
        case .openFailed(let code, _): code
        default: nil
        }
    }

    /// True for a UNIQUE/PK collision. This is the one error a writer is expected to recover from by
    /// retrying a different statement, so it has to be distinguishable from a foreign-key or CHECK failure —
    /// which is why the handle enables extended result codes.
    public var isUniqueConstraintViolation: Bool {
        guard let code = resultCode else { return false }
        return code == Constraint.unique || code == Constraint.primaryKey || code == Constraint.rowID
    }

    /// True when the write lock was somebody else's. The *primary* code is what matters: `SQLITE_BUSY_SNAPSHOT`
    /// and friends share it, and the only legal response to any of them is to wait and try again — which is
    /// why this is a property rather than a case the caller has to match.
    public var isLockContention: Bool {
        guard let code = resultCode else { return false }
        return code & 0xFF == SQLITE_BUSY || code & 0xFF == SQLITE_LOCKED
    }

    /// The constraint subcodes are `#define`s built from an expression, which Swift's macro importer
    /// skips, so they are spelled here from the primary code and its index. Verified against the header
    /// this SDK ships — the upstream SQLite numbering differs, which is exactly why they are not literals.
    enum Constraint {
        static let primaryKey: Int32 = SQLITE_CONSTRAINT | (6 << 8)
        static let unique: Int32 = SQLITE_CONSTRAINT | (8 << 8)
        static let rowID: Int32 = SQLITE_CONSTRAINT | (10 << 8)
    }

    public var description: String {
        switch self {
        case .openFailed(let code, let message): "sqlite open failed (\(code)): \(message)"
        case .prepareFailed(let sql, let code, let message): "sqlite prepare failed (\(code)): \(message) in [\(sql)]"
        case .stepFailed(let sql, let code, let message): "sqlite step failed (\(code)): \(message) in [\(sql)]"
        case .bindFailed(let index, let value): "sqlite bind failed at index \(index) for \(value)"
        case .busy(let retries): "sqlite still busy after \(retries) retries"
        case .columnOutOfRange(let index, let count): "column index \(index) out of range (\(count) columns)"
        case .noSuchColumn(let name): "no such column in result: \(name)"
        case .noRows(let sql): "query returned no rows: [\(sql)]"
        case .typeMismatch(let column, let expected, let got):
            "column \"\(column)\" expected \(expected), got \(got)"
        case .wrongConnectionKind(let detail): "wrong connection kind: \(detail)"
        case .downgradeDetected(let found, let supported):
            "database is at version \(found), this build supports \(supported); opened read-only"
        }
    }
}
