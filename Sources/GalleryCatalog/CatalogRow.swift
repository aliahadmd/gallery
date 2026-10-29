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
            indexedAt: nil,
            aesthetic: try row.double(named: "aesthetic"),
            isUtility: try row.bool(named: "is_utility")
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

    static func locationCluster(_ row: Row) throws -> LocationCluster {
        let level = ClusterLevel(code: Int(try row.int64(named: "level")))
        let name = try row.optionalString(named: "name")
        let placemark = (name != nil || level.isNamed) ? PlaceSummary(
            name: name,
            locality: try row.optionalString(named: "locality"),
            subLocality: try row.optionalString(named: "sublocality"),
            adminArea: try row.optionalString(named: "admin_area"),
            country: try row.optionalString(named: "country"),
            isoCountryCode: try row.optionalString(named: "iso_country")
        ) : nil
        return LocationCluster(
            id: ClusterID(rawValue: try row.int64(named: "id")),
            center: GPSPoint(latitude: try row.double(named: "center_lat"),
                             longitude: try row.double(named: "center_lon")),
            radiusMeters: try row.double(named: "radius_m"),
            count: Int(try row.int64(named: "item_count")),
            placemark: placemark,
            level: level
        )
    }

    static func trashEntry(_ row: Row) throws -> TrashLedgerEntry {        TrashLedgerEntry(
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

    static func analysisJob(_ row: Row) throws -> AnalysisJob {
        AnalysisJob(
            mediaID: MediaID(rawValue: try row.int64(named: "id")),
            sourceID: SourceID(rawValue: try row.int64(named: "src_id")),
            kind: MediaKind(rawValue: Int16(truncatingIfNeeded: try row.int64(named: "kind"))) ?? .unknown,
            subtype: MediaSubtype(rawValue: Int32(truncatingIfNeeded: try row.int64(named: "subtype"))),
            relativePath: try row.string(named: "rel_path"),
            modificationDate: try row.optionalInt64(named: "mtime_ns").map(Date.init(nanoseconds:)),
            dayBucket: Int32(truncatingIfNeeded: try row.int64(named: "cap_day")),
            statHash: try row.int64(named: "stat_hash").statHashValue,
            attempts: Int(try row.int64(named: "analysis_attempts"))
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

    /// Every column a media query must select. Explicit rather than `media.*` since v3: `search_ocr` can be
    /// four kilobytes a row, and a 200-row page that drags it through `Row` for a `MediaItem` that cannot use
    /// it is half a megabyte of copying per scroll. A column missing here is a decode error, not a silent
    /// zero, so the list cannot rot without a test failing.
    static let itemSelectList = """
    media.id, media.src_id, media.rel_path, media.parent_rel, media.name, media.ext, media.volume_id,
    media.doc_id, media.res_id, media.stat_hash, media.size_bytes, media.mtime_ns, media.ctime_ns,
    media.added_ns, media.uttype, media.kind, media.subtype, media.stage, media.err_code,
    media.px_w, media.px_h, media.orientation, media.color_space, media.duration_us, media.codec,
    media.cap_utc, media.cap_wall, media.cap_tz, media.cap_src,
    media.lat, media.lon, media.has_gps, media.place_key, media.cluster_id, media.device, media.lens,
    media.search_text, media.is_offline, media.trash, media.aesthetic, media.is_utility,
    CASE WHEN favorite.media_id IS NULL THEN 0 ELSE 1 END AS is_favorite
    """

    static let itemFrom = "FROM media LEFT JOIN favorite ON favorite.media_id = media.id"
}
