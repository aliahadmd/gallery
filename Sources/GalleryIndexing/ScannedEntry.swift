import Foundation
import GalleryDomain

/// One file exactly as `stat` describes it — everything pass A knows, and nothing pass B has to re-read.
///
/// Paths are root-relative by construction: the walker builds them as it descends instead of stripping a
/// prefix off an absolute path afterwards, so a volume that remounts at `/Volumes/SD 1` cannot invalidate
/// a single row.
public struct ScannedEntry: Sendable, Hashable {
    public var relativePath: String
    public var parentDirectory: String
    public var name: String
    public var fileExtension: String

    public var documentID: Int64?
    public var resourceID: Int64?
    public var byteSize: Int64
    public var modificationDate: Date?
    public var creationDate: Date?

    public var kind: MediaKind
    public var subtype: MediaSubtype
    public var uniformTypeIdentifier: String
    public var stage: IndexStage
    public var error: IndexError
    /// An iCloud placeholder. Flagged, never downloaded here: silently pulling a whole Drive folder
    /// through the network during a scan is the sort of thing users notice immediately.
    public var isOffline: Bool

    public var statHash: UInt64

    public init(
        relativePath: String,
        parentDirectory: String,
        name: String,
        fileExtension: String,
        documentID: Int64?,
        resourceID: Int64?,
        byteSize: Int64,
        modificationDate: Date?,
        creationDate: Date?,
        kind: MediaKind,
        subtype: MediaSubtype = [],
        uniformTypeIdentifier: String,
        stage: IndexStage = .classified,
        error: IndexError = .none,
        isOffline: Bool = false
    ) {
        self.relativePath = relativePath
        self.parentDirectory = parentDirectory
        self.name = name
        self.fileExtension = fileExtension
        self.documentID = documentID
        self.resourceID = resourceID
        self.byteSize = byteSize
        self.modificationDate = modificationDate
        self.creationDate = creationDate
        self.kind = kind
        self.subtype = subtype
        self.uniformTypeIdentifier = uniformTypeIdentifier
        self.stage = stage
        self.error = error
        self.isOffline = isOffline
        self.statHash = GalleryDomain.statHash(size: byteSize, modificationDate: modificationDate,
                                               creationDate: creationDate)
    }

    /// The row pass A writes. `id` is zero on purpose: the catalog's upsert returns the real row id, and a
    /// caller that invents one here would have it silently overwritten.
    public func mediaItem(sourceID: SourceID, volumeID: String, seenAt: Date = Date()) -> MediaItem {
        MediaItem(
            id: MediaID(rawValue: 0),
            identity: FileIdentity(volumeID: volumeID, documentID: documentID, resourceID: resourceID,
                                   statHash: statHash),
            sourceID: sourceID,
            relativePath: relativePath,
            parentDirectory: parentDirectory,
            name: name,
            fileExtension: fileExtension,
            kind: kind,
            subtype: subtype,
            uniformTypeIdentifier: uniformTypeIdentifier,
            byteSize: byteSize,
            stage: stage,
            error: error,
            isOffline: isOffline,
            modificationDate: modificationDate,
            creationDate: creationDate,
            addedAt: seenAt
        )
    }

    /// `0` is what a volume that does not implement document identifiers reports, and binding it would
    /// collapse every file on that share onto one row.
    static func identifier(_ value: Int?) -> Int64? {
        guard let value, value > 0 else { return nil }
        return Int64(value)
    }
}
