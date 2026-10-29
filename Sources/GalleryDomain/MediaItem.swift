import Foundation

public enum MediaKind: Int16, Sendable, Hashable, Codable, CaseIterable {
    case image = 0
    case video = 1
    case unknown = 2

    /// Only images and videos are worth rendering; `unknown` rows exist so a file the classifier could
    /// not place still shows up in the Problems album instead of vanishing.
    public var isRenderable: Bool { self != .unknown }
}

public struct MediaSubtype: OptionSet, Sendable, Hashable, Codable {
    public let rawValue: Int32
    public init(rawValue: Int32) { self.rawValue = rawValue }

    public static let screenshot = MediaSubtype(rawValue: 1 << 0)
    public static let raw = MediaSubtype(rawValue: 1 << 1)
    public static let heic = MediaSubtype(rawValue: 1 << 2)
    public static let livePhoto = MediaSubtype(rawValue: 1 << 3)
    /// The `.MOV` half of a Live Photo pair: kept in the catalog so the file is accounted for, excluded
    /// from "Videos".
    public static let livePhotoCompanion = MediaSubtype(rawValue: 1 << 4)
    public static let animated = MediaSubtype(rawValue: 1 << 5)
    public static let panorama = MediaSubtype(rawValue: 1 << 6)
    public static let hdr = MediaSubtype(rawValue: 1 << 7)
    public static let gif = MediaSubtype(rawValue: 1 << 8)
    public static let tiff = MediaSubtype(rawValue: 1 << 9)
}

/// How far the indexer has gotten with a file. Ordered, and `stage < thumbnailed` is exactly the
/// pass-B work queue, so the raw values must stay ascending.
public enum IndexStage: Int16, Sendable, Hashable, Codable, Comparable {
    case enumerated = 0
    case classified = 1
    case metadata = 2
    case thumbnailed = 3

    public static func < (lhs: IndexStage, rhs: IndexStage) -> Bool { lhs.rawValue < rhs.rawValue }

    public var needsFurtherWork: Bool { self < .thumbnailed }
}

/// Per-file failure codes. Stored on the row rather than thrown away, so a 100k scan reports what it
/// could not read instead of silently coming up short.
public enum IndexError: Int16, Sendable, Hashable, Codable, CaseIterable {
    case none = 0
    case noAccess = 1
    case undecodable = 2
    case corrupt = 3
    case unreadableVideo = 4
    case noThumbnail = 5
    case vanished = 6
    case tooLarge = 7
    case offline = 8

    public var userReason: String {
        switch self {
        case .none: "no problem"
        case .noAccess: "No read permission"
        case .undecodable: "Image format not supported"
        case .corrupt: "File appears damaged"
        case .unreadableVideo: "Video could not be read"
        case .noThumbnail: "No preview available"
        case .vanished: "File disappeared during scanning"
        case .tooLarge: "File exceeds the size limit"
        case .offline: "Not downloaded from iCloud"
        }
    }
}

public enum TrashState: Int16, Sendable, Hashable, Codable {
    case live = 0
    case trashed = 1
    case restored = 2
    case lost = 3
    case purged = 4

    /// Trashed rows must leave every album; `lost` means the user emptied Trash behind our back.
    public var hidesFromAlbums: Bool { self == .trashed || self == .purged }
}

/// File identity that survives a rename or a same-volume move, which is what keeps favorites,
/// thumbnails and cluster membership attached to the picture rather than to its path.
public struct FileIdentity: Sendable, Hashable, Codable {
    public var volumeID: String
    public var documentID: Int64?
    public var resourceID: Int64?
    public var statHash: UInt64

    public init(volumeID: String, documentID: Int64?, resourceID: Int64?, statHash: UInt64) {
        self.volumeID = volumeID
        self.documentID = documentID
        self.resourceID = resourceID
        self.statHash = statHash
    }

    /// Network and non-iCloud volumes often hand back no document identifier, so the catalog falls
    /// back to the inode, and only then to the path. The path key needs the row's own coordinates, which
    /// an identity does not have — hence the parameters rather than a stored property.
    public enum MatchKey: Sendable, Hashable {
        case document(volumeID: String, documentID: Int64)
        case resource(volumeID: String, resourceID: Int64)
        case path(sourceID: SourceID, relativePath: String)
    }

    public func matchKey(sourceID: SourceID, relativePath: String) -> MatchKey {
        if let documentID { .document(volumeID: volumeID, documentID: documentID) }
        else if let resourceID { .resource(volumeID: volumeID, resourceID: resourceID) }
        else { .path(sourceID: sourceID, relativePath: relativePath) }
    }
}

/// FNV-1a over the cheap stat fields: enough to decide "this file changed" without reading it.
public func statHash(size: Int64, modificationDate: Date?, creationDate: Date?) -> UInt64 {
    func nanoseconds(_ date: Date?) -> UInt64 {
        guard let date else { return 0 }
        return UInt64(max(0, (date.timeIntervalSince1970 * 1_000_000_000).rounded()))
    }

    var bytes: [UInt8] = []
    bytes.reserveCapacity(24)
    for value in [UInt64(bitPattern: size), nanoseconds(modificationDate), nanoseconds(creationDate)] {
        for shift in stride(from: 56, through: 0, by: -8) {
            bytes.append(UInt8(truncatingIfNeeded: value >> shift))
        }
    }
    return fnv1a(bytes)
}

public struct PixelSize: Sendable, Hashable, Codable {
    public var width: Int32
    public var height: Int32

    public init(width: Int32, height: Int32) {
        self.width = width
        self.height = height
    }

    /// Pre-orientation pixels, so the grid can lay out an aspect ratio without decoding anything.
    public var aspectRatio: Double { height == 0 ? 1 : Double(width) / Double(height) }
    public var longSide: Int32 { max(width, height) }
}

public struct MediaItem: Identifiable, Sendable, Hashable, Codable {
    public var id: MediaID
    public var identity: FileIdentity
    public var sourceID: SourceID
    /// Root-relative, so a volume remounting at a different path does not invalidate the row.
    public var relativePath: String
    public var parentDirectory: String
    public var name: String
    public var fileExtension: String

    public var kind: MediaKind
    public var subtype: MediaSubtype
    public var uniformTypeIdentifier: String

    public var byteSize: Int64
    public var stage: IndexStage
    public var error: IndexError

    public var pixelSize: PixelSize?
    public var orientation: Int16?
    public var colorSpace: String?
    public var durationMicroseconds: Int64?
    public var codec: String?

    public var capture: CaptureMoment?
    public var gps: GPSPoint?
    public var clusterID: ClusterID?
    public var placeKey: String?

    public var device: String?
    public var lens: String?
    public var searchText: String?

    public var isFavorite: Bool
    public var trash: TrashState
    public var isOffline: Bool
    public var modificationDate: Date?
    public var creationDate: Date?
    /// When the catalog first saw this file. Separated from `modificationDate` because pass A can only
    /// stat, and "date added" is the one sort a user expects to survive an EXIF re-read.
    public var addedAt: Date
    public var indexedAt: Date?

    public init(
        id: MediaID,
        identity: FileIdentity,
        sourceID: SourceID,
        relativePath: String,
        parentDirectory: String,
        name: String,
        fileExtension: String,
        kind: MediaKind,
        subtype: MediaSubtype = [],
        uniformTypeIdentifier: String,
        byteSize: Int64 = 0,
        stage: IndexStage = .enumerated,
        error: IndexError = .none,
        pixelSize: PixelSize? = nil,
        orientation: Int16? = nil,
        colorSpace: String? = nil,
        durationMicroseconds: Int64? = nil,
        codec: String? = nil,
        capture: CaptureMoment? = nil,
        gps: GPSPoint? = nil,
        clusterID: ClusterID? = nil,
        placeKey: String? = nil,
        device: String? = nil,
        lens: String? = nil,
        searchText: String? = nil,
        isFavorite: Bool = false,
        trash: TrashState = .live,
        isOffline: Bool = false,
        modificationDate: Date? = nil,
        creationDate: Date? = nil,
        addedAt: Date = Date(),
        indexedAt: Date? = nil
    ) {
        self.id = id
        self.identity = identity
        self.sourceID = sourceID
        self.relativePath = relativePath
        self.parentDirectory = parentDirectory
        self.name = name
        self.fileExtension = fileExtension
        self.kind = kind
        self.subtype = subtype
        self.uniformTypeIdentifier = uniformTypeIdentifier
        self.byteSize = byteSize
        self.stage = stage
        self.error = error
        self.pixelSize = pixelSize
        self.orientation = orientation
        self.colorSpace = colorSpace
        self.durationMicroseconds = durationMicroseconds
        self.codec = codec
        self.capture = capture
        self.gps = gps
        self.clusterID = clusterID
        self.placeKey = placeKey
        self.device = device
        self.lens = lens
        self.searchText = searchText
        self.isFavorite = isFavorite
        self.trash = trash
        self.isOffline = isOffline
        self.modificationDate = modificationDate
        self.creationDate = creationDate
        self.addedAt = addedAt
        self.indexedAt = indexedAt
    }

    /// Cell aspect ratio, corrected for EXIF orientation so a portrait JPEG does not lay out landscape.
    public var displayAspectRatio: Double {
        guard let pixelSize else { return 1 }
        return switch orientation ?? 1 {
        case 5, 6, 7, 8: pixelSize.width == 0 ? 1 : Double(pixelSize.height) / Double(pixelSize.width)
        default: pixelSize.aspectRatio
        }
    }

    public var durationDisplay: String? {
        guard let microseconds = durationMicroseconds, microseconds > 0 else { return nil }
        let seconds = Int(microseconds / 1_000_000)
        return seconds >= 3600
            ? String(format: "%d:%02d:%02d", seconds / 3600, (seconds % 3600) / 60, seconds % 60)
            : String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    public var isLivePhotoCompanion: Bool { subtype.contains(.livePhotoCompanion) }
    public var appearsInAllVideos: Bool { kind == .video && !isLivePhotoCompanion }

    // The values the catalog writes as denormalised columns. They live here so the write path and the
    // query path agree on the encoding by construction — a day album and a date-header must never be able
    // to disagree about which day a photo belongs to.

    /// 0 means "no capture date known", which sorts to the end of a newest-first grid and is the sentinel
    /// the schema's `cap_utc NOT NULL DEFAULT 0` expects.
    public var captureTimestamp: Double { capture?.instant.timeIntervalSince1970 ?? 0 }
    public var dayBucket: Int32 { capture?.dayBucket ?? 0 }
    public var monthBucket: Int32 { capture?.monthBucket ?? 0 }
    public var hasGPS: Bool { gps?.isValid ?? false }

    public func url(resolvedAgainst root: URL) -> URL {
        root.appendingPathComponent(relativePath)
    }
}
