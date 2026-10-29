import Foundation
import GalleryDomain
import GallerySQLite

/// The version ladder. v1 is created from `Schema.create`; everything after it is an appended step that
/// must be able to run against a database produced by any earlier release.
public enum CatalogMigrations {
    /// v1 is the floor rather than a step: it is `Schema.create` as of that version, so a fresh install and
    /// a version-0 database walked forward cannot end up with different tables. Later releases append a
    /// step here; they never edit this one.
    public static let all: [Migration] = [
        Migration(version: 1, name: "v1 baseline", up: { try $0.exec(Schema.create) }),
        // A library on disk from the first build gets the same table the installer creates: `ALTER TABLE`
        // appends, which is why `rank` sits at the end of the v1 script too. The claim index is rebuilt
        // because the old one cannot answer an ordering that includes it.
        Migration(version: 2, name: "v2 recency rank in the work queue", up: { try $0.exec(Self.v2) }),
    ]

    private static let v2 = """
    ALTER TABLE scan_queue ADD COLUMN rank INTEGER NOT NULL DEFAULT 0;
    DROP INDEX queue_claim;
    CREATE INDEX queue_claim ON scan_queue(priority DESC, rank DESC, enqueued_ns ASC, id);
    """
}

/// Owns the read-write connection. One writer, one transaction at a time, batched — which is also why the
/// read side is a second connection rather than a queue in front of this one.
public actor Catalog {
    /// Not `private`: the thumbnail manifest lives in its own file and writes through this same connection.
    let handle: SQLiteHandle

    /// Prepared once and cycled per row. Re-preparing inside the enumeration loop is a 5–10× penalty at
    /// 100k files, so the statements live for the life of the catalog.
    private let insertByDocument: Statement
    private let insertByResource: Statement
    private let insertByPath: Statement
    private let updateMetadata: Statement
    private let retireStalePathOwner: Statement
    private let retireReplacedPathOwner: Statement

    public init(handle: SQLiteHandle) throws {
        self.handle = handle
        self.insertByDocument = try handle.prepare(MediaStatements.byDocument)
        self.insertByResource = try handle.prepare(MediaStatements.byResource)
        self.insertByPath = try handle.prepare(MediaStatements.byPath)
        self.updateMetadata = try handle.prepare(MediaStatements.metadataUpdate)
        self.retireStalePathOwner = try handle.prepare(MediaStatements.deleteStalePathOwner)
        self.retireReplacedPathOwner = try handle.prepare(MediaStatements.deleteStalePathOwnerByResource)
    }

    /// Open (creating if necessary) and migrate. A database from a newer build is opened read-only by
    /// `CatalogReader`, never written by us, so `open` refuses it loudly instead of half-working.
    public static func open(at url: URL) throws -> Catalog {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let handle = try SQLiteHandle.open(path: url.path, kind: .readWrite)
        precondition(Schema.version == CatalogMigrations.all.last?.version,
                     "Schema.create describes v\(Schema.version) but the ladder ends at v\(CatalogMigrations.all.last?.version ?? 0)")
        let outcome = try Migrator.migrate(handle, migrations: CatalogMigrations.all) { try $0.exec(Schema.create) }
        if case .migrated = outcome {
            // Column additions invalidate an external-content FTS index that was built against the old list.
            try handle.exec(Schema.rebuildFTS)
        }
        return try Catalog(handle: handle)
    }

    public var databasePath: String { handle.path }

    // MARK: - Sources

    @discardableResult
    public func addSource(
        displayName: String,
        rootPath: String,
        volumeID: String,
        bookmark: [UInt8]? = nil,
        state: BookmarkState = .ok
    ) throws -> FolderSource {
        if let row = try handle.firstRow(
            "SELECT * FROM folder_source WHERE volume_id = ? AND root_rel = ?",
            [.text(volumeID), .text(rootPath)]
        ) {
            let source = try CatalogRow.source(row)
            // Re-picking the same folder is a re-grant, not a new library: refresh the bookmark and clear
            // whatever blocked it last time, and keep the media rows exactly where they are.
            try handle.write {
                try handle.exec(
                    "UPDATE folder_source SET bookmark = COALESCE(?, bookmark), state = ?, display_name = ? WHERE id = ?",
                    [.blob(bookmark ?? []), .integer(Int64(state.rawValue)), .text(displayName), .integer(source.id.rawValue)]
                )
            }
            return FolderSource(
                id: source.id, displayName: displayName, rootPath: rootPath, volumeID: volumeID,
                bookmarkState: state, watcherState: source.watcherState,
                lastEventID: source.lastEventID, lastSweep: source.lastSweep, lastScan: source.lastScan,
                isIncluded: source.isIncluded
            )
        }

        var inserted: Int64 = 0
        try handle.write {
            inserted = try handle.firstValueOrThrow(
                """
                INSERT INTO folder_source (root_rel, volume_id, display_name, bookmark, state)
                VALUES (?, ?, ?, ?, ?) RETURNING id
                """,
                [.text(rootPath), .text(volumeID), .text(displayName),
                 bookmark.map(Value.blob) ?? .null, .integer(Int64(state.rawValue))]
            ).int64OrZero
        }
        return FolderSource(id: SourceID(rawValue: inserted), displayName: displayName,
                            rootPath: rootPath, volumeID: volumeID, bookmarkState: state)
    }

    public func sources() throws -> [FolderSource] {
        try handle.query("SELECT * FROM folder_source ORDER BY display_name COLLATE NOCASE").map { try CatalogRow.source($0) }
    }

    public func updateSource(_ source: FolderSource) throws {
        let arguments: [Value] = [
            .text(source.displayName), .text(source.rootPath), .text(source.volumeID),
            .integer(Int64(source.bookmarkState.rawValue)), .integer(Int64(source.watcherState.code)),
            source.lastEventID.map { .integer(Int64(truncatingIfNeeded: $0)) } ?? .null,
            source.lastSweep.map { .integer($0.nanoseconds) } ?? .null,
            source.lastScan.map { .integer($0.nanoseconds) } ?? .null,
            .integer(source.isIncluded ? 1 : 0), .integer(source.id.rawValue),
        ]
        try handle.write {
            try handle.exec(
                """
                UPDATE folder_source SET display_name = ?, root_rel = ?, volume_id = ?, state = ?, watcher = ?,
                       last_event_id = ?, last_sweep_ns = ?, last_scan_ns = ?, is_included = ?
                WHERE id = ?
                """,
                arguments
            )
        }
    }

    /// Dropping a source takes its media, favorites, queue entries and ledger rows with it — every one of
    /// those is `ON DELETE CASCADE` from `folder_source`, which is the only reason this stays one statement.
    public func removeSource(id: SourceID) throws {
        try handle.write {
            try handle.exec("DELETE FROM folder_source WHERE id = ?", [.integer(id.rawValue)])
        }
    }

    // MARK: - Enumeration (pass A)

    /// Ids in input order, so the caller can zip them with the URLs it just walked without a second query.
    ///
    /// The batch is one transaction: a crash mid-batch loses the batch, not the library, and WAL means the
    /// reader never sees a torn write.
    public func recordEnumeration(_ items: [MediaItem]) throws -> [MediaID] {
        guard !items.isEmpty else { return [] }
        let addedNS = Date().nanoseconds
        return try handle.write {
            try items.map { item in
                MediaID(rawValue: try upsertEnumeration(item, addedNS: addedNS))
            }
        }
    }

    private func upsertEnumeration(_ item: MediaItem, addedNS: Int64) throws -> Int64 {
        let values = MediaStatements.enumerationValues(item, addedNS: addedNS)
        let statement: Statement
        switch item.identity.documentID {
        case .some: statement = insertByDocument
        case nil where item.identity.resourceID != nil: statement = insertByResource
        case nil: statement = insertByPath
        }

        do {
            guard let row = try statement.firstRow(values), case .integer(let id) = try row[0] else {
                throw SQLiteError.noRows(sql: statement.sql)
            }
            return id
        } catch let error as SQLiteError {
            // Two rows claiming one path: the identity that just walked in retires the stale path owner and
            // the write is retried. Anything else is a real failure and must not be swallowed here.
            guard error.isUniqueConstraintViolation else { throw error }
            switch (item.identity.documentID, item.identity.resourceID) {
            case let (documentID?, _):
                try retireStalePathOwner.run([
                    .integer(item.sourceID.rawValue),
                    .text(item.relativePath),
                    .integer(documentID),
                ])
            case let (nil, resourceID?):
                try retireReplacedPathOwner.run([
                    .integer(item.sourceID.rawValue),
                    .text(item.relativePath),
                    .integer(resourceID),
                ])
            case (nil, nil):
                throw error
            }
            guard let row = try statement.firstRow(values), case .integer(let id) = try row[0] else {
                throw error
            }
            return id
        }
    }

    // MARK: - Metadata (pass B)

    public func recordMetadata(_ items: [MediaItem]) throws {
        guard !items.isEmpty else { return }
        try handle.write {
            for item in items {
                try updateMetadata.run(MediaStatements.metadataValues(item))
            }
        }
    }

    public func recordMetadata(_ item: MediaItem) throws {
        try recordMetadata([item])
    }

    // MARK: - Sweep

    /// The sweep is the only place rows are deleted, and it deletes by explicit id list rather than by
    /// "everything not in this set": a 100k-element `NOT IN` would be a full scan of a table the enumerator
    /// is still walking.
    public func deleteMedia(ids: [MediaID]) throws {
        guard !ids.isEmpty else { return }
        try handle.write {
            let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ", ")
            try handle.exec(
                "DELETE FROM media WHERE id IN (\(placeholders))",
                ids.map { .integer($0.rawValue) }
            )
        }
    }

    /// The columns a sweep needs to identify a row by path — nothing else, because a 100k-row library read
    /// as full `MediaItem`s costs more memory than the whole diff it is feeding.
    public func pathRows(sourceID: SourceID) throws -> [CatalogPathRow] {
        try handle.query(
            "SELECT id, rel_path, parent_rel, trash FROM media WHERE src_id = ?",
            [.integer(sourceID.rawValue)]
        ).map { row in
            CatalogPathRow(
                id: MediaID(rawValue: try row.int64(named: "id")),
                relativePath: try row.string(named: "rel_path"),
                parentDirectory: try row.string(named: "parent_rel"),
                trash: TrashState(rawValue: Int16(truncatingIfNeeded: try row.int64(named: "trash"))) ?? .live
            )
        }
    }

    // MARK: - Favorites

    public func setFavorite(_ id: MediaID, _ flag: Bool) throws {
        try handle.write {
            if flag {
                try handle.exec(
                    "INSERT OR IGNORE INTO favorite (media_id, added_ns) VALUES (?, ?)",
                    [.integer(id.rawValue), .integer(Date().nanoseconds)]
                )
            } else {
                try handle.exec("DELETE FROM favorite WHERE media_id = ?", [.integer(id.rawValue)])
            }
        }
    }

    public func setFavorites(_ ids: [MediaID], _ flag: Bool) throws {
        for id in ids { try setFavorite(id, flag) }
    }

    // MARK: - Trash ledger

    /// Written *before* the filesystem operation, so a crash between the two leaves a ledger row pointing
    /// at a file that is still in place — recoverable — rather than a trashed file nobody can find.
    public func beginTrash(_ entry: TrashLedgerEntry) throws -> Int64 {
        try handle.write {
            try handle.exec(
                """
                INSERT INTO trash_ledger (media_id, src_id, from_rel, from_volume, to_rel, mode, state,
                                          byte_size, trashed_ns)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?) RETURNING id
                """,
                [.integer(entry.mediaID.rawValue), .integer(entry.sourceID.rawValue), .text(entry.fromRelativePath),
                 .text(entry.fromVolumeID), entry.toRelativePath.map(Value.text) ?? .null,
                 .integer(Int64(entry.mode.rawValue)), .integer(Int64(TrashState.trashed.rawValue)),
                 .integer(entry.byteSize), .integer(entry.trashedAt.nanoseconds)]
            )
            try handle.exec("UPDATE media SET trash = ? WHERE id = ?",
                            [.integer(Int64(TrashState.trashed.rawValue)), .integer(entry.mediaID.rawValue)])
            return handle.lastInsertRowID
        }
    }

    /// Records what the filesystem actually did. `media.trash` is only ever a visibility flag — the ledger
    /// holds the narrative — so a *failed* system-trash returns the row to the albums instead of leaving it
    /// flagged as deleted while the file is still sitting in the folder.
    public func finishTrash(ledgerID: Int64, mediaID: MediaID, succeeded: Bool, error: String?) throws {
        let ledgerState: TrashState = succeeded ? .trashed : .lost
        let mediaState: TrashState = succeeded ? .trashed : .live
        try handle.write {
            try handle.exec(
                "UPDATE trash_ledger SET state = ?, restore_err = ? WHERE id = ?",
                [.integer(Int64(ledgerState.rawValue)), error.map(Value.text) ?? .null, .integer(ledgerID)]
            )
            try handle.exec("UPDATE media SET trash = ? WHERE id = ?",
                            [.integer(Int64(mediaState.rawValue)), .integer(mediaID.rawValue)])
        }
    }

    /// A failed restore leaves the item trashed, which is the truth the UI can act on: it is still in
    /// Recently Deleted, and the next attempt can offer "Show in Trash" instead of promising a move.
    /// `restored_ns` is written only when the move happened, so a failed attempt cannot render as a
    /// restore date.
    public func restoreFromLedger(ledgerID: Int64, mediaID: MediaID, succeeded: Bool, error: String?) throws {
        let ledgerState: TrashState = succeeded ? .restored : .lost
        let mediaState: TrashState = succeeded ? .live : .trashed
        let ledgerSQL = succeeded
            ? "UPDATE trash_ledger SET state = ?, restored_ns = ?, restore_err = ? WHERE id = ?"
            : "UPDATE trash_ledger SET state = ?, restore_err = ? WHERE id = ?"
        let ledgerArguments: [Value] = succeeded
            ? [.integer(Int64(ledgerState.rawValue)), .integer(Date().nanoseconds),
               error.map(Value.text) ?? .null, .integer(ledgerID)]
            : [.integer(Int64(ledgerState.rawValue)), error.map(Value.text) ?? .null, .integer(ledgerID)]
        try handle.write {
            try handle.exec(ledgerSQL, ledgerArguments)
            try handle.exec("UPDATE media SET trash = ? WHERE id = ?",
                            [.integer(Int64(mediaState.rawValue)), .integer(mediaID.rawValue)])
        }
    }

    public func purgeOlderThan(_ date: Date) throws -> [TrashLedgerEntry] {
        try handle.query(
            "SELECT * FROM trash_ledger WHERE state = ? AND trashed_ns < ?",
            [.integer(Int64(TrashState.trashed.rawValue)), .integer(date.nanoseconds)]
        ).map { try CatalogRow.trashEntry($0) }
    }

    public func recordPurge(ledgerID: Int64, mediaID: MediaID) throws {
        try handle.write {
            try handle.exec("UPDATE trash_ledger SET state = ? WHERE id = ?",
                            [.integer(Int64(TrashState.purged.rawValue)), .integer(ledgerID)])
            try handle.exec("UPDATE media SET trash = ? WHERE id = ?",
                            [.integer(Int64(TrashState.purged.rawValue)), .integer(mediaID.rawValue)])
        }
    }

    // MARK: - Scan queue

    /// One statement, two entry points: which media rows to pick is the only difference between "everything
    /// this source still owes" and "the dozen rows the user is looking at". Reading them out of `media` is
    /// what keeps the queue honest — a row that already finished pass B, or sits in the Trash, cannot be
    /// queued again — and a row re-enqueued after a rescan keeps the *higher* priority rather than being
    /// duplicated, which is what lets a scroll-driven "decode the viewport now" call be cheap and repeatable.
    ///
    /// `rank` is the file's own modification date in whole days, computed in the `SELECT` because the queue
    /// is filled from the table: it is what makes pass B's order "viewport first, then newest, then the tail"
    /// cost nothing at claim time. A day is the grain because a day is what the user can see in the timeline.
    private static func queueInsert(matching filter: String) -> String {
        """
        INSERT INTO scan_queue (src_id, media_id, kind, priority, rank, enqueued_ns)
        SELECT src_id, id, 1, ?, COALESCE(mtime_ns, 0) / 86_400_000_000_000, ? FROM media
        WHERE \(filter) AND stage < \(IndexStage.thumbnailed.rawValue) AND trash = 0
        ON CONFLICT(src_id, kind, media_id) WHERE media_id IS NOT NULL
        DO UPDATE SET priority = MAX(scan_queue.priority, excluded.priority),
                      rank = MAX(scan_queue.rank, excluded.rank)
        """
    }

    /// Fills the queue from the table instead of from the enumerator's own list: which rows still need work
    /// is a question the `stage < 3` partial index already answers.
    public func enqueuePendingWork(sourceID: SourceID, priority: Int = 0) throws {
        try handle.write {
            try handle.exec(
                Self.queueInsert(matching: "src_id = ?"),
                [.integer(Int64(priority)), .integer(Date().nanoseconds), .integer(sourceID.rawValue)]
            )
        }
    }

    /// The rows the grid is drawing, jumped to the front of the queue. `attempts` is deliberately not
    /// reset: a file that has already failed three times is not made interesting by being on screen.
    public func raiseWorkPriority(mediaIDs: [MediaID], priority: Int) throws {
        guard !mediaIDs.isEmpty else { return }
        let placeholders = Array(repeating: "?", count: mediaIDs.count).joined(separator: ", ")
        try handle.write {
            try handle.exec(
                Self.queueInsert(matching: "id IN (\(placeholders))"),
                [.integer(Int64(priority)), .integer(Date().nanoseconds)]
                    + mediaIDs.map { .integer($0.rawValue) }
            )
        }
    }

    /// The claim hop: one transaction, `attempts` bumped, the claimed rows handed back by `RETURNING`.
    ///
    /// *Which* rows are claimed is the index's job — `queue_claim` is exactly `(priority, rank, enqueued_ns,
    /// id)`, so a 100k-row queue costs one walk and no sort. *What order they come back in* cannot be: an
    /// `UPDATE … WHERE id IN (SELECT … ORDER BY … LIMIT ?) RETURNING` hands rows back in the order it visits
    /// the table, not the subquery's, so the batch is re-sorted here on the same keys the index uses. The
    /// worker reads this array as its schedule, and "the viewport first, then the newest" is a promise about
    /// processing order, not merely about which 64 rows left the queue.
    public func claimWork(limit: Int) throws -> [WorkItem] {
        try handle.write {
            let rows = try handle.query(
                """
                UPDATE scan_queue SET attempts = attempts + 1
                WHERE id IN (
                  SELECT id FROM scan_queue
                  ORDER BY priority DESC, rank DESC, enqueued_ns ASC, id LIMIT ?
                )
                RETURNING id, src_id, media_id, kind, priority, attempts, rank, enqueued_ns
                """,
                [.integer(Int64(limit))]
            )
            return try rows
                .map { (item: try CatalogRow.workItem($0), order: try CatalogRow.workOrder($0)) }
                .sorted { $0.order < $1.order }
                .map(\.item)
        }
    }

    public func completeWork(ids: [Int64]) throws {
        guard !ids.isEmpty else { return }
        let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ", ")
        try handle.write {
            try handle.exec("DELETE FROM scan_queue WHERE id IN (\(placeholders))", ids.map(Value.integer))
        }
    }

    public func failWork(id: Int64, error: String) throws {
        try handle.write {
            try handle.exec("UPDATE scan_queue SET last_error = ? WHERE id = ?", [.text(error), .integer(id)])
        }
    }

    /// The sources with work waiting, so a HUD can ask for pass B's progress across the library without
    /// being told which folders are indexed.
    public func pendingSourceIDs() throws -> [SourceID] {
        let rows = try handle.query("SELECT DISTINCT src_id FROM scan_queue ORDER BY src_id")
        return try rows.map { SourceID(rawValue: try $0.int64(named: "src_id")) }
    }

    public func queuedWorkCount(sourceID: SourceID? = nil) throws -> Int {
        let sql = sourceID == nil
            ? "SELECT COUNT(*) AS count FROM scan_queue"
            : "SELECT COUNT(*) AS count FROM scan_queue WHERE src_id = ?"
        let arguments: [Value] = sourceID.map { [.integer($0.rawValue)] } ?? []
        return Int(try handle.firstValueOrThrow(sql, arguments).int64OrZero)
    }

    // MARK: - Settings

    public func setSetting(_ key: String, _ value: String) throws {
        try handle.write {
            try handle.exec(
                "INSERT INTO setting (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                [.text(key), .text(value)]
            )
        }
    }

    public func setting(_ key: String) throws -> String? {
        try handle.firstValue("SELECT value FROM setting WHERE key = ?", [.text(key)])?.stringValue
    }

    // MARK: - Maintenance

    public func stageCounts(sourceID: SourceID? = nil) throws -> [IndexStage: Int] {
        let selecting = "SELECT stage AS stage, COUNT(*) AS count FROM media"
        let sql = sourceID == nil ? "\(selecting) GROUP BY stage" : "\(selecting) WHERE src_id = ? GROUP BY stage"
        let rows = try handle.query(sql, sourceID.map { [.integer($0.rawValue)] } ?? [])
        var counts: [IndexStage: Int] = [:]
        for row in rows {
            guard let stage = IndexStage(rawValue: Int16(truncatingIfNeeded: try row.int64(named: "stage"))) else { continue }
            counts[stage] = Int(try row.int64(named: "count"))
        }
        return counts
    }

    /// Rows carrying a badge — what the Problems view lists, and what a scan HUD has to report. Counted from
    /// the catalog rather than remembered by the worker, so the number a user sees after a relaunch is the
    /// number for the whole library, not for the part this process happens to have read.
    public func problemCount(sourceID: SourceID? = nil) throws -> Int {
        let selecting = "SELECT COUNT(*) FROM media WHERE err_code <> 0 AND trash = 0"
        let sql = sourceID == nil ? selecting : "\(selecting) AND src_id = ?"
        let arguments: [Value] = sourceID.map { [.integer($0.rawValue)] } ?? []
        return Int(try handle.firstValueOrThrow(sql, arguments).int64OrZero)
    }

    public func rebuildFTS() throws { try handle.exec(Schema.rebuildFTS) }
    public func checkpoint() throws { try handle.checkpoint() }
    public func optimize() throws { try handle.optimize() }
    public func integrityCheck() throws -> [String] { try handle.integrityCheck() }
}

/// The queue's ordering policy as a value, so a claimed batch can be handed to the worker in the order the
/// index would have read it. The two `DESC` keys arrive negated: ascending on these four fields is the same
/// order as `priority DESC, rank DESC, enqueued_ns ASC, id ASC`.
struct WorkOrder: Comparable {
    var tier: Int64
    var day: Int64
    var enqueued: Int64
    var queueID: Int64

    static func < (lhs: WorkOrder, rhs: WorkOrder) -> Bool {
        if lhs.tier != rhs.tier { return lhs.tier < rhs.tier }
        if lhs.day != rhs.day { return lhs.day < rhs.day }
        if lhs.enqueued != rhs.enqueued { return lhs.enqueued < rhs.enqueued }
        return lhs.queueID < rhs.queueID
    }
}

/// One unit of pass-B work as the queue hands it out.
public struct WorkItem: Sendable, Hashable {
    public var queueID: Int64
    public var sourceID: SourceID
    public var mediaID: MediaID?
    public var kind: Int16
    public var priority: Int
    public var attempts: Int

    public init(queueID: Int64, sourceID: SourceID, mediaID: MediaID?, kind: Int16, priority: Int, attempts: Int) {
        self.queueID = queueID
        self.sourceID = sourceID
        self.mediaID = mediaID
        self.kind = kind
        self.priority = priority
        self.attempts = attempts
    }
}

public enum TrashMode: Int16, Sendable, Hashable, Codable {
    case systemTrash = 0
    case appTrash = 1
}

/// The undo record for one trashed item. `toRelativePath` is only meaningful for `.appTrash`; the system
/// Trash gives back a URL we cannot re-resolve later, so the "from" columns are what restore depends on.
public struct TrashLedgerEntry: Identifiable, Sendable, Hashable {
    public var id: Int64
    public var mediaID: MediaID
    public var sourceID: SourceID
    public var fromRelativePath: String
    public var fromVolumeID: String
    public var toRelativePath: String?
    public var mode: TrashMode
    public var state: TrashState
    public var byteSize: Int64
    public var trashedAt: Date
    public var restoredAt: Date?
    public var restoreError: String?

    public init(
        id: Int64 = 0,
        mediaID: MediaID,
        sourceID: SourceID,
        fromRelativePath: String,
        fromVolumeID: String,
        toRelativePath: String? = nil,
        mode: TrashMode,
        state: TrashState = .trashed,
        byteSize: Int64 = 0,
        trashedAt: Date = Date(),
        restoredAt: Date? = nil,
        restoreError: String? = nil
    ) {
        self.id = id
        self.mediaID = mediaID
        self.sourceID = sourceID
        self.fromRelativePath = fromRelativePath
        self.fromVolumeID = fromVolumeID
        self.toRelativePath = toRelativePath
        self.mode = mode
        self.state = state
        self.byteSize = byteSize
        self.trashedAt = trashedAt
        self.restoredAt = restoredAt
        self.restoreError = restoreError
    }
}
