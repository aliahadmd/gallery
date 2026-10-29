import Foundation
import Testing
@testable import GalleryCatalog
import GalleryDomain
import GallerySQLite

/// One catalog per test, in its own directory. WAL leaves `-wal` and `-shm` beside the database, so the
/// unit of cleanup is the directory rather than the file.
struct CatalogFixture {
    let directory: URL
    let databaseURL: URL
    let catalog: Catalog
    let reader: CatalogReader

    init() async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("gallery-catalog-\(UUID().uuidString)")
        databaseURL = directory.appendingPathComponent("catalog.db")
        catalog = try Catalog.open(at: databaseURL)
        reader = try CatalogReader.open(at: databaseURL)
    }

    func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    /// A second writer on the same file — what a relaunch, not a rescan, does.
    func reopened() async throws -> Catalog {
        try Catalog.open(at: databaseURL)
    }

    @discardableResult
    func addSource(
        _ name: String = "Library",
        volume: String = "vol-1",
        state: BookmarkState = .ok
    ) async throws -> FolderSource {
        try await catalog.addSource(
            displayName: name,
            rootPath: "/Volumes/\(name)",
            volumeID: volume,
            state: state
        )
    }

    @discardableResult
    func record(_ items: [MediaItem]) async throws -> [MediaID] {
        try await catalog.recordEnumeration(items)
    }

    func metadata(_ items: [MediaItem]) async throws {
        try await catalog.recordMetadata(items)
    }
}

func makeItem(
    _ name: String,
    at path: String? = nil,
    documentID: Int64? = nil,
    resourceID: Int64? = nil,
    sourceID: SourceID,
    volumeID: String = "vol-1",
    kind: MediaKind = .image,
    subtype: MediaSubtype = [],
    stage: IndexStage = .enumerated,
    error: IndexError = .none,
    size: Int64 = 1024,
    isOffline: Bool = false,
    mediaID: MediaID = MediaID(rawValue: 0)
) -> MediaItem {
    let relativePath = path ?? name
    let parent = (relativePath as NSString).deletingLastPathComponent
    return MediaItem(
        id: mediaID,
        identity: FileIdentity(
            volumeID: volumeID,
            documentID: documentID,
            resourceID: resourceID,
            statHash: statHash(size: size, modificationDate: nil, creationDate: nil)
        ),
        sourceID: sourceID,
        relativePath: relativePath,
        parentDirectory: parent == "." ? "" : parent,
        name: name,
        fileExtension: (name as NSString).pathExtension,
        kind: kind,
        subtype: subtype,
        uniformTypeIdentifier: kind == .image ? "public.jpeg" : "public.mpeg-4",
        byteSize: size,
        stage: stage,
        error: error,
        isOffline: isOffline
    )
}

/// A capture moment in UTC from `yyyy-mm-dd`, so a day-bucket expectation in a test reads the way the album
/// title will.
func captured(_ day: String, hour: Int = 12) throws -> CaptureMoment {
    let parts = day.split(separator: "-").compactMap { Int($0) }
    try #require(parts.count == 3)
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = CaptureMoment.utc
    let instant = try #require(calendar.date(from: DateComponents(
        year: parts[0], month: parts[1], day: parts[2], hour: hour
    )))
    return CaptureMoment(instant: instant, wallClock: instant, timeZone: CaptureMoment.utc,
                         source: .exifDateTimeOriginal)
}

extension MediaItem {
    /// The item as pass B would hand it back: same row, decoded.
    func decoded(
        capture: CaptureMoment? = nil,
        gps: GPSPoint? = nil,
        pixels: PixelSize? = nil,
        device: String? = nil,
        search: String? = nil,
        stage: IndexStage = .thumbnailed,
        error: IndexError = .none
    ) -> MediaItem {
        var copy = self
        copy.capture = capture
        copy.gps = gps
        copy.pixelSize = pixels
        copy.device = device
        copy.searchText = search
        copy.stage = stage
        copy.error = error
        return copy
    }
}
