import Foundation
import GalleryDomain
import GallerySQLite

/// The values a metadata edit knows, written as a whole. Nil means "the file carries none", which is a
/// statement this schema can represent (and a `COALESCE` cannot).
public struct EditProjection: Sendable {
    public var title: String?
    public var capture: CaptureMoment?
    public var gps: GPSPoint?

    public init(title: String?, capture: CaptureMoment?, gps: GPSPoint?) {
        self.title = title
        self.capture = capture
        self.gps = gps
    }
}

public struct MediaEditCommit: Sendable {
    public var mediaID: MediaID
    /// The hash the caller saw. A mismatch means the file changed under the edit.
    public var expectedStatHash: UInt64
    public var stat: FileStat
    /// True after a replace or a pixel edit: the poster and the analysis describe bytes that are gone.
    public var pixelsChanged: Bool
    /// Nil leaves title/date/GPS alone and lets pass B read the new bytes.
    public var projection: EditProjection?

    public init(
        mediaID: MediaID, expectedStatHash: UInt64, stat: FileStat, pixelsChanged: Bool,
        projection: EditProjection? = nil
    ) {
        self.mediaID = mediaID
        self.expectedStatHash = expectedStatHash
        self.stat = stat
        self.pixelsChanged = pixelsChanged
        self.projection = projection
    }
}

extension Catalog {
    /// One transaction: new stat, the projected fields, and — for a pixel edit — everything derived from the
    /// old pixels. A 0-row result is the CAS refusing because the file changed under the caller.
    @discardableResult
    public func commitEdit(_ commit: MediaEditCommit) throws -> Bool {
        try handle.write {
            var values: [Value] = [
                .integer(Int64(bitPattern: commit.stat.statHash)),
                .integer(commit.stat.size),
                .integer(commit.stat.modificationDate.nanoseconds),
                commit.stat.creationDate.map { .integer($0.nanoseconds) } ?? .null,
            ]
            let sql: String
            if let projection = commit.projection {
                sql = commit.pixelsChanged ? Self.pixelEditSQL : Self.metadataEditSQL
                values += [
                    projection.title.map(Value.text) ?? .null,
                    projection.capture.map { .real($0.instant.timeIntervalSince1970) } ?? .real(0),
                    projection.capture.map { .real($0.wallClock.timeIntervalSince1970) } ?? .real(0),
                    .integer(Int64(projection.capture?.dayBucket ?? 0)),
                    .integer(Int64(projection.capture?.monthBucket ?? 0)),
                    projection.capture?.timeZone.map { .text($0.identifier) } ?? .null,
                    .integer(Int64(projection.capture?.source.rawValue ?? CaptureSource.unknown.rawValue)),
                    projection.gps.map { .real($0.latitude) } ?? .null,
                    projection.gps.map { .real($0.longitude) } ?? .null,
                    .integer(projection.gps?.isValid == true ? 1 : 0),
                ]
            } else {
                sql = commit.pixelsChanged ? Self.pixelEditNoProjectionSQL : Self.metadataEditNoProjectionSQL
            }
            values += [.integer(commit.mediaID.rawValue), .integer(Int64(bitPattern: commit.expectedStatHash))]

            try handle.exec(sql, values)
            let changed = handle.changes > 0
            guard changed, commit.pixelsChanged else { return changed }

            for table in ["media_tag", "face", "media_analysis", "thumbnail_cache"] {
                try handle.exec("DELETE FROM \(table) WHERE media_id = ?", [.integer(commit.mediaID.rawValue)])
            }
            try handle.exec("""
            UPDATE media SET analysis_stage = 0, analysis_attempts = 0, aesthetic = 0, is_utility = 0,
                             search_tags = NULL, search_ocr = NULL
            WHERE id = ?
            """, [.integer(commit.mediaID.rawValue)])
            try handle.exec(
                Self.queueInsert(matching: "id = ?"),
                [.integer(1), .integer(Date().nanoseconds), .integer(commit.mediaID.rawValue)]
            )
            return true
        }
    }

    /// A category is a verdict about the file as it was. Every edit — pixels or metadata — invalidates it,
    /// because capture date, GPS and device are classifier inputs; the pixels case additionally has to drop
    /// the derived rows entirely.
    private static let pixelEditNoProjectionSQL = """
    UPDATE media SET stat_hash = ?, size_bytes = ?, mtime_ns = ?, ctime_ns = ?,
                     stage = 1, err_code = 0,
                     category = 0, category_confidence = 0, category_stage = 0, category_attempts = 0
    WHERE id = ? AND stat_hash = ?
    """

    private static let metadataEditNoProjectionSQL = """
    UPDATE media SET stat_hash = ?, size_bytes = ?, mtime_ns = ?, ctime_ns = ?,
                     stage = MAX(stage, 3), err_code = 0,
                     category = 0, category_confidence = 0, category_stage = 0, category_attempts = 0
    WHERE id = ? AND stat_hash = ?
    """

    private static let pixelEditSQL = """
    UPDATE media SET stat_hash = ?, size_bytes = ?, mtime_ns = ?, ctime_ns = ?,
                     stage = 1, err_code = 0,
                     category = 0, category_confidence = 0, category_stage = 0, category_attempts = 0,
                     title = ?, cap_utc = ?, cap_wall = ?, cap_day = ?, cap_month = ?, cap_tz = ?,
                     cap_src = ?, lat = ?, lon = ?, has_gps = ?, place_key = NULL, cluster_id = NULL
    WHERE id = ? AND stat_hash = ?
    """

    private static let metadataEditSQL = """
    UPDATE media SET stat_hash = ?, size_bytes = ?, mtime_ns = ?, ctime_ns = ?,
                     stage = MAX(stage, 3), err_code = 0,
                     category = 0, category_confidence = 0, category_stage = 0, category_attempts = 0,
                     title = ?, cap_utc = ?, cap_wall = ?, cap_day = ?, cap_month = ?, cap_tz = ?,
                     cap_src = ?, lat = ?, lon = ?, has_gps = ?, place_key = NULL, cluster_id = NULL
    WHERE id = ? AND stat_hash = ?
    """
}
