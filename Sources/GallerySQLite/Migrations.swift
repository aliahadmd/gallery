import Foundation

/// One step up the schema ladder. Migrations are append-only and monotonic: a released version of the
/// app never edits an old step, because a library on disk may be several versions behind and has to be
/// walkable forward from wherever it actually is.
public struct Migration: Sendable {
    public let version: Int32
    public let name: String
    public let up: @Sendable (SQLiteHandle) throws -> Void

    public init(version: Int32, name: String, up: @escaping @Sendable (SQLiteHandle) throws -> Void) {
        precondition(version > 0, "schema versions start at 1")
        self.version = version
        self.name = name
        self.up = up
    }
}

public enum Migrator {
    /// Bring `handle` up to `migrations.last.version`.
    ///
    /// A database *newer* than the binary is the case that decides the shape of this API: the only safe
    /// response is to refuse to write. Opening it read-only keeps the user's library browsable after an
    /// App Store downgrade instead of tempting anyone to "fix" it by wiping the catalog.
    public static func migrate(
        _ handle: SQLiteHandle,
        migrations: [Migration],
        fresh: @Sendable (SQLiteHandle) throws -> Void
    ) throws -> MigrationOutcome {
        precondition(
            zip(migrations, migrations.dropFirst()).allSatisfy { $0.version < $1.version },
            "migrations must be listed in ascending version order"
        )
        guard let newest = migrations.last?.version else {
            preconditionFailure("a schema with no versions cannot be opened")
        }

        let found = try handle.userVersion()
        guard found <= newest else {
            throw SQLiteError.downgradeDetected(found: found, supported: newest)
        }

        if found == 0 {
            try handle.write {
                try fresh(handle)
                try handle.setUserVersion(newest)
            }
            return .created
        }
        guard found < newest else { return .unchanged }

        let pending = migrations.filter { $0.version > found }
        try handle.write {
            for step in pending {
                try step.up(handle)
                try handle.setUserVersion(step.version)
            }
        }
        return .migrated(from: found, to: newest, steps: pending.map(\.name))
    }
}

public enum MigrationOutcome: Sendable, Hashable {
    case created
    case unchanged
    case migrated(from: Int32, to: Int32, steps: [String])

    public var description: String {
        switch self {
        case .created: "schema created"
        case .unchanged: "schema already current"
        case .migrated(let from, let to, let steps): "schema \(from) → \(to): \(steps.joined(separator: ", "))"
        }
    }
}
