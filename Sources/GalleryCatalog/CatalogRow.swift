import Foundation
import GalleryDomain
import GallerySQLite

/// Row → value-type decoding, in one file, because these are the only places a column name appears as a
/// string. A rename in `Schema.create` should break here and nowhere else.
///
/// Every read throws on purpose: a column that is missing from a hand-written SELECT list, or an INTEGER
/// where a timestamp belongs, is a bug in this app, and silently decoding it to zero would hide it as a
/// photo filed on 1 January 1970.
enum CatalogRow {
    static func source(_ row: Row) throws -> FolderSource {
        FolderSource(
            id: SourceID(rawValue: try row.int64(named: "id")),
            displayName: try row.string(named: "display_name"),
            rootPath: try row.string(named: "root_rel"),
            volumeID: try row.string(named: "volume_id"),
            bookmarkState: try BookmarkState(rawValue: Int16(truncatingIfNeeded: row.int64(named: "state"))) ?? .ok,
            watcherState: WatcherState(code: Int16(truncatingIfNeeded: try row.int64(named: "watcher"))),
            lastEventID: try row.optionalInt64(named: "last_event_id").map { UInt64(truncatingIfNeeded: $0) },
            lastSweep: try row.optionalInt64(named: "last_sweep_ns").map(Date.init(nanoseconds:)),
            lastScan: try row.optionalInt64(named: "last_scan_ns").map(Date.init(nanoseconds:)),
            isIncluded: try row.bool(named: "is_included", default: true)
        )
    }

    static func item(_ row: Row) throws -> MediaItem {
        let pixelWidth = try row.optionalInt64(named: "px_w")
        let pixelHeight = try row.optionalInt64(named: "px_h")

        return MediaItem(
            id: MediaID(rawValue: try row.int64(named: "id")),
            identity: FileIdentity(
                volumeID: try row.string(named: "volume_id"),
                documentID: try row.optionalInt64(named: "doc_id"),
                resourceID: try row.optionalInt64(named: "res_id"),
                statHash: try row.int64(named: "stat_hash").statHashValue
            ),
            sourceID: SourceID(rawValue: try row.int64(named: "src_id")),
            relativePath: try row.string(named: "rel_path"),
            parentDirectory: try row.string(named: "parent_rel"),
            name: try row.string(named: "name"),
            fileExtension: try row.optionalString(named: "ext") ?? "",
            kind: MediaKind(rawValue: Int16(truncatingIfNeeded: try row.int64(named: "kind"))) ?? .unknown,
            subtype: MediaSubtype(rawValue: Int32(truncatingIfNeeded: try row.int64(named: "subtype"))),
            uniformTypeIdentifier: try row.string(named: "uttype"),
            byteSize: try row.int64(named: "size_bytes"),
            stage: IndexStage(rawValue: Int16(truncatingIfNeeded: try row.int64(named: "stage"))) ?? .enumerated,
            error: IndexError(rawValue: Int16(truncatingIfNeeded: try row.int64(named: "err_code"))) ?? .none,
            pixelSize: pixelWidth != nil || pixelHeight != nil
                ? PixelSize(width: Int32(truncatingIfNeeded: pixelWidth ?? 0),
                            height: Int32(truncatingIfNeeded: pixelHeight ?? 0))
                : nil,
            orientation: try row.optionalInt64(named: "orientation").map { Int16(truncatingIfNeeded: $0) },
            colorSpace: try row.optionalString(named: "color_space"),
            durationMicroseconds: try row.optionalInt64(named: "duration_us"),
            codec: try row.optionalString(named: "codec"),
            capture: try capture(of: row),
            gps: try gps(of: row),
            clusterID: try row.optionalInt64(named: "cluster_id").map(ClusterID.init(rawValue:)),
            placeKey: try row.optionalString(named: "place_key"),
            device: try row.optionalString(named: "device"),
            lens: try row.optionalString(named: "lens"),
            searchText: try row.optionalString(named: "search_text"),
            isFavorite: try row.bool(named: "is_favorite"),
            trash: TrashState(rawValue: Int16(truncatingIfNeeded: try row.int64(named: "trash"))) ?? .live,
            isOffline: try row.bool(named: "is_offline"),
            modificationDate: try row.optionalInt64(named: "mtime_ns").map(Date.init(nanoseconds:)),
            creationDate: try row.optionalInt64(named: "ctime_ns").map(Date.init(nanoseconds:)),
            addedAt: Date(nanoseconds: try row.int64(named: "added_ns")),
            indexedAt: nil
        )
    }

    /// `cap_utc = 0` is the "we don't know" sentinel the schema and the sort order both rely on, so a zero
    /// here means no capture date at all rather than January 1970.
    private static func capture(of row: Row) throws -> CaptureMoment? {
        let seconds = try row.double(named: "cap_utc")
        guard seconds != 0 else { return nil }
        return CaptureMoment(
            instant: Date(timeIntervalSince1970: seconds),
            wallClock: Date(timeIntervalSince1970: try row.double(named: "cap_wall")),
            timeZone: try row.optionalString(named: "cap_tz").flatMap(TimeZone.init(identifier:)),
            source: CaptureSource(rawValue: Int16(truncatingIfNeeded: try row.int64(named: "cap_src"))) ?? .unknown
        )
    }

    private static func gps(of row: Row) throws -> GPSPoint? {
        guard try row.bool(named: "has_gps"),
              let latitude = try row.optionalDouble(named: "lat"),
              let longitude = try row.optionalDouble(named: "lon"),
              GPSPoint(latitude: latitude, longitude: longitude).isValid
        else { return nil }
        return GPSPoint(latitude: latitude, longitude: longitude)
    }

    static func trashEntry(_ row: Row) throws -> TrashLedgerEntry {
        TrashLedgerEntry(
            id: try row.int64(named: "id"),
            mediaID: MediaID(rawValue: try row.int64(named: "media_id")),
            sourceID: SourceID(rawValue: try row.int64(named: "src_id")),
            fromRelativePath: try row.string(named: "from_rel"),
            fromVolumeID: try row.string(named: "from_volume"),
            toRelativePath: try row.optionalString(named: "to_rel"),
            mode: TrashMode(rawValue: Int16(truncatingIfNeeded: try row.int64(named: "mode"))) ?? .systemTrash,
            state: TrashState(rawValue: Int16(truncatingIfNeeded: try row.int64(named: "state"))) ?? .trashed,
            byteSize: try row.int64(named: "byte_size"),
            trashedAt: Date(nanoseconds: try row.int64(named: "trashed_ns")),
            restoredAt: try row.optionalInt64(named: "restored_ns").map(Date.init(nanoseconds:)),
            restoreError: try row.optionalString(named: "restore_err")
        )
    }

    static func thumbnail(_ row: Row) throws -> ThumbnailRecord {
        let rawBucket = try row.int64(named: "bucket")
        guard let bucket = ThumbnailBucket(rawValue: Int32(truncatingIfNeeded: rawBucket)) else {
            throw SQLiteError.typeMismatch(column: "bucket", expected: "a known thumbnail bucket",
                                           got: .integer(rawBucket))
        }
        let mtimeNS = try row.int64(named: "mtime_ns")
        return ThumbnailRecord(
            mediaID: MediaID(rawValue: try row.int64(named: "media_id")),
            bucket: bucket,
            mtime: mtimeNS == 0 ? nil : Date(nanoseconds: mtimeNS),
            path: try row.string(named: "path"),
            byteSize: try row.int64(named: "byte_size"),
            lastUsed: Date(nanoseconds: try row.int64(named: "last_used_ns"))
        )
    }

    static func workItem(_ row: Row) throws -> WorkItem {
        WorkItem(
            queueID: try row.int64(named: "id"),
            sourceID: SourceID(rawValue: try row.int64(named: "src_id")),
            mediaID: try row.optionalInt64(named: "media_id").map(MediaID.init(rawValue:)),
            kind: Int16(truncatingIfNeeded: try row.int64(named: "kind")),
            priority: Int(try row.int64(named: "priority")),
            attempts: Int(try row.int64(named: "attempts"))
        )
    }

    static func workOrder(_ row: Row) throws -> WorkOrder {
        let priority = try row.int64(named: "priority")
        let rank = try row.int64(named: "rank")
        return WorkOrder(tier: -priority,
                         day: -rank,
                         enqueued: try row.int64(named: "enqueued_ns"),
                         queueID: try row.int64(named: "id"))
    }

    /// Every column a media query must select. Keeping it in one constant is what makes the decode above
    /// total: a new column is added once, and every reader picks it up.
    static let itemSelectList = """
    media.*, CASE WHEN favorite.media_id IS NULL THEN 0 ELSE 1 END AS is_favorite
    """

    static let itemFrom = "FROM media LEFT JOIN favorite ON favorite.media_id = media.id"
}
