import Foundation
import GalleryDomain
import GallerySQLite

/// One row's rename, after the bytes have already moved. `stat` is read back from the destination, because a
/// volume may bump the mtime on a move.
public struct MediaRename: Sendable {
    public var mediaID: MediaID
    public var expectedStatHash: UInt64
    public var fromRelativePath: String
    public var toRelativePath: String
    public var parentRelativePath: String
    public var name: String
    public var fileExtension: String
    public var subtype: MediaSubtype
    public var searchText: String?
    public var stat: FileStat

    public init(
        mediaID: MediaID, expectedStatHash: UInt64, fromRelativePath: String, toRelativePath: String,
        parentRelativePath: String, name: String, fileExtension: String,
        subtype: MediaSubtype, searchText: String?, stat: FileStat
    ) {
        self.mediaID = mediaID
        self.expectedStatHash = expectedStatHash
        self.fromRelativePath = fromRelativePath
        self.toRelativePath = toRelativePath
        self.parentRelativePath = parentRelativePath
        self.name = name
        self.fileExtension = fileExtension
        self.subtype = subtype
        self.searchText = searchText
        self.stat = stat
    }
}

public struct RenameWriteOutcome: Sendable {
    public var applied: [MediaID] = []
    /// Renamed on disk but not in the catalog: the next scan reconciles by identity, but the user should
    /// know the page is stale until then.
    public var refused: [MediaID: String] = [:]
}

/// A staged move's journal row: written before the temporary name is used, deleted when the move lands.
public struct StagedMove: Sendable, Hashable {
    public var id: Int64
    public var mediaID: MediaID?
    public var sourceID: SourceID
    public var parentRelativePath: String
    public var fromName: String
    public var tempName: String
    public var toName: String
    public var createdAt: Date

    public init(
        id: Int64 = 0, mediaID: MediaID?, sourceID: SourceID, parentRelativePath: String,
        fromName: String, tempName: String, toName: String, createdAt: Date = Date()
    ) {
        self.id = id
        self.mediaID = mediaID
        self.sourceID = sourceID
        self.parentRelativePath = parentRelativePath
        self.fromName = fromName
        self.tempName = tempName
        self.toName = toName
        self.createdAt = createdAt
    }
}

extension Catalog {
    /// Filesystem first, catalog second. Each row is its own transaction so one contested path cannot roll
    /// back the other 199 renames; the CAS proves the bytes are still the ones the plan saw.
    @discardableResult
    public func applyRenames(_ renames: [MediaRename]) throws -> RenameWriteOutcome {
        var outcome = RenameWriteOutcome()
        for rename in renames {
            do {
                let result = try handle.write { () -> RenameWriteOutcome in
                    var local = RenameWriteOutcome()
                    let occupant = try handle.firstRow(
                        "SELECT id FROM media WHERE src_id = (SELECT src_id FROM media WHERE id = ?) AND rel_path = ? AND id <> ?",
                        [.integer(rename.mediaID.rawValue), .text(rename.toRelativePath),
                         .integer(rename.mediaID.rawValue)]
                    )
                    if occupant != nil {
                        local.refused[rename.mediaID] = "Another catalog entry claims that name."
                        return local
                    }
                    try handle.exec(
                        """
                        UPDATE media SET rel_path = ?, parent_rel = ?, name = ?, ext = ?, subtype = ?,
                                         search_text = ?, stat_hash = ?, size_bytes = ?, mtime_ns = ?,
                                         ctime_ns = ?,
                                         category = 0, category_confidence = 0, category_stage = 0,
                                         category_attempts = 0
                        WHERE id = ? AND stat_hash = ?
                        """,
                        [.text(rename.toRelativePath), .text(rename.parentRelativePath), .text(rename.name),
                         .text(rename.fileExtension), .integer(Int64(rename.subtype.rawValue)),
                         rename.searchText.map(Value.text) ?? .null,
                         .integer(Int64(bitPattern: rename.stat.statHash)),
                         .integer(rename.stat.size),
                         .integer(rename.stat.modificationDate.nanoseconds),
                         rename.stat.creationDate.map { .integer($0.nanoseconds) } ?? .null,
                         .integer(rename.mediaID.rawValue),
                         .integer(Int64(bitPattern: rename.expectedStatHash))]
                    )
                    if handle.changes == 0 {
                        // A concurrent scan may have already applied the same rename; that is success, not a
                        // conflict. Anything else means the bytes changed under the plan.
                        let current = try handle.firstRow(
                            "SELECT rel_path FROM media WHERE id = ?", [.integer(rename.mediaID.rawValue)]
                        )
                        let path = current.flatMap { try? $0.string(named: "rel_path") }
                        if path == rename.toRelativePath {
                            local.applied.append(rename.mediaID)
                        } else {
                            local.refused[rename.mediaID] = "The file changed while it was being renamed."
                        }
                    } else {
                        local.applied.append(rename.mediaID)
                    }
                    return local
                }
                outcome.applied += result.applied
                outcome.refused.merge(result.refused) { first, _ in first }
            } catch let error as SQLiteError where error.isUniqueConstraintViolation {
                outcome.refused[rename.mediaID] = "Another catalog entry claims that name."
            }
        }
        return outcome
    }

    @discardableResult
    public func beginStagedMove(_ move: StagedMove) throws -> Int64 {
        try handle.write {
            let row = try handle.firstRow(
                """
                INSERT INTO rename_journal (media_id, src_id, parent_rel, from_name, temp_name, to_name,
                                            created_ns)
                VALUES (?, ?, ?, ?, ?, ?, ?) RETURNING id
                """,
                [move.mediaID.map { .integer($0.rawValue) } ?? .null,
                 .integer(move.sourceID.rawValue), .text(move.parentRelativePath),
                 .text(move.fromName), .text(move.tempName), .text(move.toName),
                 .integer(move.createdAt.nanoseconds)]
            )
            guard let row, case .integer(let id) = try row[0] else {
                throw SQLiteError.noRows(sql: "INSERT INTO rename_journal")
            }
            return id
        }
    }

    public func finishStagedMoves(ids: [Int64]) throws {
        guard !ids.isEmpty else { return }
        let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ", ")
        try handle.write {
            try handle.exec(
                "DELETE FROM rename_journal WHERE id IN (\(placeholders))",
                ids.map { .integer($0) }
            )
        }
    }

    public func pendingStagedMoves() throws -> [StagedMove] {
        try handle.query("SELECT * FROM rename_journal ORDER BY id").map { row in
            StagedMove(
                id: try row.int64(named: "id"),
                mediaID: try row.optionalInt64(named: "media_id").map(MediaID.init(rawValue:)),
                sourceID: SourceID(rawValue: try row.int64(named: "src_id")),
                parentRelativePath: try row.string(named: "parent_rel"),
                fromName: try row.string(named: "from_name"),
                tempName: try row.string(named: "temp_name"),
                toName: try row.string(named: "to_name"),
                createdAt: Date(nanoseconds: try row.int64(named: "created_ns"))
            )
        }
    }
}
