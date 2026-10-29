import Foundation
import Testing
@testable import GalleryAnalysis
@testable import GalleryCatalog
import GalleryDomain
import GalleryIndexing
import GallerySupport

@Test func theWorkerClassifiesStoredSignalsWithoutVision() async throws {
    let fixture = try await CategoryFixture()
    defer { fixture.tearDown() }
    let count = await fixture.worker.runOnce()
    #expect(count == 3)

    let screenshot = try #require(await fixture.reader.item(id: fixture.screenshotID))
    #expect(screenshot.category == .screenshot)
    let document = try #require(await fixture.reader.item(id: fixture.documentID))
    #expect(document.category == .document)
    let photo = try #require(await fixture.reader.item(id: fixture.photoID))
    #expect(photo.category == .photo)

    #expect(try await fixture.reader.count(album: .category(.screenshot)) == 1)
    #expect(try await fixture.reader.count(album: .category(.document)) == 1)
    let counts = try await fixture.reader.categoryCounts()
    #expect(counts.first { $0.category == .screenshot }?.count == 1)
    #expect(counts.first { $0.category == .document }?.count == 1)

    let evidence = try await fixture.reader.categoryEvidence(ids: [fixture.screenshotID])
    #expect(evidence[fixture.screenshotID]?.reasons.isEmpty == false)
}

@Test func feedbackMovesRowsBetweenCategories() async throws {
    let fixture = try await CategoryFixture()
    defer { fixture.tearDown() }
    _ = await fixture.worker.runOnce()

    try await fixture.catalog.setCategoryFeedback(
        mediaID: fixture.screenshotID, category: .screenshot, verdict: -1
    )
    #expect(try await fixture.reader.count(album: .category(.screenshot)) == 0)
    #expect(try await fixture.reader.item(id: fixture.screenshotID)?.category == MediaCategory.none,
            "an excluded row leaves every shelf")

    try await fixture.catalog.setCategoryFeedback(
        mediaID: fixture.photoID, category: .document, verdict: 1
    )
    #expect(try await fixture.reader.count(album: .category(.document)) == 2)
    #expect(try await fixture.reader.item(id: fixture.photoID)?.category == .document,
            "the page projection and the album predicate agree")

    try await fixture.catalog.clearCategoryFeedback(mediaID: fixture.photoID)
    #expect(try await fixture.reader.item(id: fixture.photoID)?.category == .photo)
}

@Test func aRecategorizeRunKeepsTheFeedback() async throws {
    let fixture = try await CategoryFixture()
    defer { fixture.tearDown() }
    _ = await fixture.worker.runOnce()
    try await fixture.catalog.setCategoryFeedback(
        mediaID: fixture.screenshotID, category: .screenshot, verdict: -1
    )
    let again = await fixture.worker.resetAndRun()
    #expect(again == 3)
    #expect(try await fixture.reader.count(album: .category(.screenshot)) == 0,
            "a recategorize does not undo the user's verdict")
}

private struct CategoryFixture {
    let root: URL
    let catalog: Catalog
    let reader: CatalogReader
    let worker: CategoryWorker
    let screenshotID: MediaID
    let photoID: MediaID
    let documentID: MediaID

    init() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("category-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let database = root.appendingPathComponent("catalog.db")
        catalog = try Catalog.open(at: database)
        reader = try CatalogReader.open(at: database)
        let source = try await catalog.addSource(
            displayName: "Library", rootPath: root.path, volumeID: "vol-cat"
        )

        func row(_ name: String, subtype: MediaSubtype, size: (Int32, Int32),
                 device: String?, resourceID: Int64) -> MediaItem {
            MediaItem(
                id: MediaID(rawValue: 0),
                identity: FileIdentity(volumeID: "vol-cat", documentID: nil,
                                       resourceID: resourceID, statHash: 1),
                sourceID: source.id, relativePath: name, parentDirectory: "",
                name: name, fileExtension: (name as NSString).pathExtension,
                kind: .image, subtype: subtype, uniformTypeIdentifier: "public.jpeg",
                byteSize: 100, stage: .thumbnailed,
                pixelSize: PixelSize(width: size.0, height: size.1), device: device
            )
        }

        let rows = [
            row("Screenshot 2026-10-29.png", subtype: .screenshot, size: (1170, 2532),
                device: nil, resourceID: 1),
            row("IMG_0001.jpg", subtype: [], size: (4032, 3024),
                device: "iPhone 15 Pro", resourceID: 2),
            row("scan.jpg", subtype: [], size: (3024, 4032), device: nil, resourceID: 3),
        ]
        let ids = try await catalog.recordEnumeration(rows)
        screenshotID = ids[0]
        photoID = ids[1]
        documentID = ids[2]

        let longText = String(repeating: "invoice total amount due ", count: 20)
        try await catalog.recordAnalysis([
            MediaAnalysisResult(
                mediaID: ids[0], statHash: 1, version: 1, revision: "test",
                labels: [SceneLabel(identifier: "user interface", confidence: 0.8)],
                ocrText: "Screen", ocrBlockCount: 5, isUtility: true
            ),
            MediaAnalysisResult(
                mediaID: ids[1], statHash: 1, version: 1, revision: "test",
                labels: [SceneLabel(identifier: "mountain", confidence: 0.9)], aesthetic: 0.7
            ),
            MediaAnalysisResult(
                mediaID: ids[2], statHash: 1, version: 1, revision: "test",
                labels: [SceneLabel(identifier: "document", confidence: 0.8)],
                ocrText: longText, ocrBlockCount: 12, aesthetic: 0.02
            ),
        ])

        worker = CategoryWorker(
            catalog: catalog,
            resolver: CatalogMediaResolver(reader: reader, bookmarks: BookmarkStore()),
            configuration: .init(gate: nil, isLowPower: { false })
        )
    }

    func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }
}
