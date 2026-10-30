import Foundation
import GalleryDomain
import GallerySQLite

/// The SQL and the value encoders for the two write passes, kept side by side so a column list can never
/// drift from the array that binds it. Pass A (enumeration) and pass B (metadata) deliberately have
/// separate statements: one upsert that writes "everything the item knows" would let a stat-only rescan
/// null out a fully decoded 48 MP HEIC's pixel size, capture date and GPS.
enum MediaStatements {
    // MARK: - Pass A

    /// Identity + stat columns only. `RETURNING id` hands the enumerator the rowid for a row it may have
    /// just created, which is what lets thumbnails and queue entries reference media in the same batch.
    private static let enumerationInsertHead = """
    INSERT INTO media (src_id, rel_path, parent_rel, name, ext, volume_id, doc_id, res_id,
                        stat_hash, size_bytes, mtime_ns, ctime_ns, added_ns, uttype, kind, subtype,
                        stage, err_code, is_offline)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    """

    /// On conflict the path is what moved, so the identity columns stay and only the observations refresh.
    /// `added_ns` is deliberately absent: "date added" is a promise to the user, not a re-derivable fact.
    /// `trash` is absent because the ledger owns it, and a rescan must never resurrect an item.
    private static let enumerationUpdate = """
    DO UPDATE SET
      rel_path = excluded.rel_path,
      parent_rel = excluded.parent_rel,
      name = excluded.name,
      ext = excluded.ext,
      res_id = excluded.res_id,
      stat_hash = excluded.stat_hash,
      size_bytes = excluded.size_bytes,
      mtime_ns = excluded.mtime_ns,
      ctime_ns = excluded.ctime_ns,
      uttype = excluded.uttype,
      kind = excluded.kind,
      subtype = excluded.subtype,
      -- The same rule as `err_code` below, and for the same reason: a file whose bytes changed is a file
      -- pass B has not seen yet, so its stage goes back to what pass A actually observed. `MAX` alone would
      -- leave an edited 48 MP HEIC claiming `thumbnailed` — and therefore off the queue — forever.
      stage = CASE WHEN media.stat_hash <> excluded.stat_hash
                   THEN excluded.stage ELSE MAX(media.stage, excluded.stage) END,
      is_offline = excluded.is_offline,
      -- A file whose bytes changed is a file neither pass has looked at: the analysis row is stale too.
      analysis_stage = CASE WHEN media.stat_hash <> excluded.stat_hash
                            THEN 0 ELSE media.analysis_stage END,
      analysis_attempts = CASE WHEN media.stat_hash <> excluded.stat_hash
                               THEN 0 ELSE media.analysis_attempts END,
      -- The category is a verdict about bytes that no longer exist. It goes back to unclassified rather
      -- than waiting for the analysis pass to notice: a rescan alone must be able to drop a stale verdict.
      category = CASE WHEN media.stat_hash <> excluded.stat_hash
                      THEN 0 ELSE media.category END,
      category_confidence = CASE WHEN media.stat_hash <> excluded.stat_hash
                                 THEN 0 ELSE media.category_confidence END,
      category_stage = CASE WHEN media.stat_hash <> excluded.stat_hash
                            THEN 0 ELSE media.category_stage END,
      category_attempts = CASE WHEN media.stat_hash <> excluded.stat_hash
                               THEN 0 ELSE media.category_attempts END,
      -- Every SET expression sees the pre-update row, so this compares against the *old* hash: a file
      -- that really changed clears the error the previous attempt recorded, one that merely got
      -- re-walked keeps the error pass B gave it.
      err_code = CASE WHEN media.stat_hash <> excluded.stat_hash
                      THEN excluded.err_code ELSE media.err_code END
    RETURNING id
    """

    /// The three identity conflict targets, each naming one of the unique indexes on `media`. Joined with
    /// newlines rather than by string continuation, because `enumerationUpdate` carries `--` comments and a
    /// space join would comment out half the statement.
    private static func enumeration(conflictTarget: String) -> String {
        enumerationInsertHead + "\n" + conflictTarget + "\n" + enumerationUpdate
    }

    static let byDocument = enumeration(conflictTarget: "ON CONFLICT(volume_id, doc_id) WHERE doc_id IS NOT NULL")

    static let byResource = enumeration(
        conflictTarget: "ON CONFLICT(volume_id, res_id) WHERE doc_id IS NULL AND res_id IS NOT NULL"
    )

    static let byPath = enumeration(conflictTarget: "ON CONFLICT(src_id, rel_path)")

    // MARK: - Pass B

    /// Metadata is written by rowid: pass B always works on a row pass A already committed, so there is no
    /// identity question left to answer and no reason to pay for an upsert.
    static let metadataUpdate = """
    UPDATE media SET
      px_w = ?, px_h = ?, orientation = ?, color_space = ?,
      duration_us = ?, codec = ?,
      cap_utc = ?, cap_wall = ?, cap_day = ?, cap_month = ?, cap_tz = ?, cap_src = ?,
      lat = ?, lon = ?, has_gps = ?, place_key = ?, cluster_id = ?,
      device = ?, lens = ?, meta_json = COALESCE(?, meta_json), search_text = ?,
      subtype = ?, kind = ?, stage = ?, err_code = ?,
      -- The title is written without a COALESCE: it is authored by the user, and a title cleared in the
      -- editor must be able to stay cleared. The CAS makes a stale hop harmless — a hop that decoded the
      -- bytes before an edit lands on zero rows and is re-queued instead of overwriting the edit.
      title = ?
    WHERE id = ? AND stat_hash = ?
    """

    /// A rename lands as an update of `rel_path` on the doc-matched row. If another row already claims the
    /// destination path, that row is a stale path entry — the file it described is the one being renamed —
    /// and it retires before the rename is retried.
    ///
    /// The row being renamed is excluded by `doc_id`, not by `id`: at this point the caller does not know
    /// its own rowid, and `id <> -1` would match it and delete the very row the upsert was about to update.
    static let deleteStalePathOwner = """
    DELETE FROM media
    WHERE src_id = ? AND rel_path = ? AND COALESCE(doc_id, -1) <> ?
    """

    /// The same recovery for a file replaced outside the app — an editor that saves by writing a new file and
    /// renaming it over the old one leaves a new inode at an old path. The row that still claims the path
    /// describes the file that was replaced, so it retires and the new identity takes the path over. Without
    /// it, one replaced file would fail its whole batch on the unique path index, on every rescan, forever.
    static let deleteStalePathOwnerByResource = """
    DELETE FROM media
    WHERE src_id = ? AND rel_path = ? AND COALESCE(res_id, -1) <> ?
    """

    static func enumerationValues(_ item: MediaItem, addedNS: Int64) -> [Value] {
        [
            .integer(item.sourceID.rawValue),
            .text(item.relativePath),
            .text(item.parentDirectory),
            .text(item.name),
            item.fileExtension.isEmpty ? .null : .text(item.fileExtension),
            .text(item.identity.volumeID),
            item.identity.documentID.map(Value.integer) ?? .null,
            item.identity.resourceID.map(Value.integer) ?? .null,
            .integer(Int64(truncatingIfNeeded: item.identity.statHash)),
            .integer(item.byteSize),
            item.modificationDate.map { .integer($0.nanoseconds) } ?? .null,
            item.creationDate.map { .integer($0.nanoseconds) } ?? .null,
            .integer(addedNS),
            .text(item.uniformTypeIdentifier),
            .integer(Int64(item.kind.rawValue)),
            .integer(Int64(item.subtype.rawValue)),
            .integer(Int64(item.stage.rawValue)),
            .integer(Int64(item.error.rawValue)),
            .integer(item.isOffline ? 1 : 0),
        ]
    }

    static func metadataValues(_ item: MediaItem) -> [Value] {
        [
            item.pixelSize.map { .integer(Int64($0.width)) } ?? .null,
            item.pixelSize.map { .integer(Int64($0.height)) } ?? .null,
            item.orientation.map { .integer(Int64($0)) } ?? .null,
            item.colorSpace.map(Value.text) ?? .null,
            item.durationMicroseconds.map(Value.integer) ?? .null,
            item.codec.map(Value.text) ?? .null,
            .real(item.captureTimestamp),
            .real(item.capture?.wallClock.timeIntervalSince1970 ?? 0),
            .integer(Int64(item.dayBucket)),
            .integer(Int64(item.monthBucket)),
            item.capture.flatMap { $0.timeZone.map { .text($0.identifier) } } ?? .null,
            .integer(Int64(item.capture?.source.rawValue ?? CaptureSource.unknown.rawValue)),
            item.gps.map { .real($0.latitude) } ?? .null,
            item.gps.map { .real($0.longitude) } ?? .null,
            .integer(item.hasGPS ? 1 : 0),
            item.placeKey.map(Value.text) ?? .null,
            item.clusterID.map { .integer($0.rawValue) } ?? .null,
            item.device.map(Value.text) ?? .null,
            item.lens.map(Value.text) ?? .null,
            .null,  // meta_json: the unmodeled-EXIF blob, filled in by the metadata reader
            item.searchText.map(Value.text) ?? .null,
            .integer(Int64(item.subtype.rawValue)),
            .integer(Int64(item.kind.rawValue)),
            .integer(Int64(item.stage.rawValue)),
            .integer(Int64(item.error.rawValue)),
            item.title.map(Value.text) ?? .null,
            .integer(item.id.rawValue),
            .integer(Int64(bitPattern: item.identity.statHash)),
        ]
    }
}

extension Int64 {
    var statHashValue: UInt64 { UInt64(bitPattern: self) }
}
