import Foundation
import GalleryDomain
import GallerySQLite

/// The `thumbnail_cache` manifest: which baked file belongs to which picture at which size, and when it was
/// last looked at.
///
/// The JPEG on disk is self-describing enough to *find* (`<mediaID>-<mtimeNs>.jpg`), but nothing about a
/// directory tree says which thumbnail the user scrolled past five minutes ago and which one was baked once
/// and never drawn. That difference is the whole of a least-recently-used policy, and it can only be kept
/// in a row.
public struct ThumbnailRecord: Sendable, Hashable {
    public var mediaID: MediaID
    public var bucket: ThumbnailBucket
    /// The source file's stamp at bake time, or nil when the file had none. Together with `mediaID` and
    /// `bucket` this is the primary key, which is why a re-stamped photo is a new row rather than an update.
    public var mtime: Date?
    public var path: String
    public var byteSize: Int64
    public var lastUsed: Date

    public init(
        mediaID: MediaID,
        bucket: ThumbnailBucket,
        mtime: Date?,
        path: String,
        byteSize: Int64,
        lastUsed: Date
    ) {
        self.mediaID = mediaID
        self.bucket = bucket
        self.mtime = mtime
        self.path = path
        self.byteSize = byteSize
        self.lastUsed = lastUsed
    }
}

enum ThumbnailStatements {
    /// One statement for both "just baked" and "just displayed": the bake records the bytes and the touch
    /// moves only the clock, and the conflict target is the triple the filename already encodes.
    static let note = """
    INSERT INTO thumbnail_cache (media_id, bucket, mtime_ns, path, byte_size, last_used_ns)
    VALUES (?, ?, ?, ?, ?, ?)
    ON CONFLICT(media_id, bucket, mtime_ns)
    DO UPDATE SET path = excluded.path, byte_size = excluded.byte_size, last_used_ns = excluded.last_used_ns
    """

    static let touch = """
    INSERT INTO thumbnail_cache (media_id, bucket, mtime_ns, path, byte_size, last_used_ns)
    VALUES (?, ?, ?, ?, 0, ?)
    ON CONFLICT(media_id, bucket, mtime_ns) DO UPDATE SET last_used_ns = excluded.last_used_ns
    """

    static let coldest = """
    SELECT media_id, bucket, mtime_ns, path, byte_size, last_used_ns FROM thumbnail_cache
    ORDER BY last_used_ns ASC, media_id ASC, bucket ASC LIMIT ?
    """

    static func values(_ record: ThumbnailRecord) -> [Value] {
        [
            .integer(record.mediaID.rawValue),
            .integer(Int64(record.bucket.longSide)),
            .integer(record.mtime?.nanoseconds ?? 0),
            .text(record.path),
            .integer(record.byteSize),
            .integer(record.lastUsed.nanoseconds),
        ]
    }

    static func touchValues(mediaID: MediaID, bucket: ThumbnailBucket, mtime: Date?,
                            path: String, usedAt: Date) -> [Value] {
        [.integer(mediaID.rawValue), .integer(Int64(bucket.longSide)),
         .integer(mtime?.nanoseconds ?? 0), .text(path), .integer(usedAt.nanoseconds)]
    }
}

extension Catalog {
    // MARK: - Thumbnail manifest

    /// Called after the bytes are on disk. A note that fails is not worth losing a thumbnail over, so the
    /// caller may ignore the error — the file still loads, and the tree sweep will date it from its own
    /// attributes if the manifest never got the row.
    public func noteThumbnail(_ record: ThumbnailRecord) throws {
        try handle.write {
            try handle.exec(ThumbnailStatements.note, ThumbnailStatements.values(record))
        }
    }

    /// The LRU tick on a display. Recorded with the path it is ticking, so a touch for a bucket that was
    /// never noted — a row lost to a crash between the write and the note — still leaves a pointer to the
    /// file rather than a row that describes nothing.
    public func touchThumbnail(mediaID: MediaID, bucket: ThumbnailBucket, mtime: Date?,
                               path: String, usedAt: Date) throws {
        try handle.write {
            try handle.exec(ThumbnailStatements.touch,
                            ThumbnailStatements.touchValues(mediaID: mediaID, bucket: bucket,
                                                            mtime: mtime, path: path, usedAt: usedAt))
        }
    }

    /// The eviction candidates, coldest first. Bounded by `limit` because the sweep is a background job, not
    /// a memory exercise: 600k rows read to decide which 200 files to delete is a bug, not a plan.
    public func coldestThumbnails(limit: Int) throws -> [ThumbnailRecord] {
        try handle.query(ThumbnailStatements.coldest, [.integer(Int64(limit))])
            .map(CatalogRow.thumbnail)
    }

    /// Deleted by path rather than by key because the caller is holding the files it just removed.
    public func deleteThumbnailRows(paths: [String]) throws {
        guard !paths.isEmpty else { return }
        let placeholders = Array(repeating: "?", count: paths.count).joined(separator: ", ")
        try handle.write {
            try handle.exec("DELETE FROM thumbnail_cache WHERE path IN (\(placeholders))",
                            paths.map(Value.text))
        }
    }

    public func deleteThumbnailRows(mediaID: MediaID) throws {
        try handle.write {
            try handle.exec("DELETE FROM thumbnail_cache WHERE media_id = ?", [.integer(mediaID.rawValue)])
        }
    }

    /// The budget's own number, straight out of the manifest instead of a directory walk: the sweep this
    /// answers for is already the expensive one.
    public func thumbnailManifestBytes() throws -> Int64 {
        try handle.firstValueOrThrow("SELECT COALESCE(SUM(byte_size), 0) AS bytes FROM thumbnail_cache")
            .int64OrZero
    }

    public func thumbnailRecordCount() throws -> Int {
        Int(try handle.firstValueOrThrow("SELECT COUNT(*) AS count FROM thumbnail_cache").int64OrZero)
    }
}
