import Foundation
import Testing
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import GalleryIndexing
import GalleryCatalog
import GalleryDomain
import GalleryImaging
import GallerySupport

/// A catalog with real JPEGs in it and a cache directory beside them.
///
/// Baking is the part of this pipeline that lies to a mock: the tiers are only worth testing against pixels
/// that ImageIO will actually produce, so the fixtures write files, read them back as bitmaps, and let the
/// service find them through the same resolver the app uses.
struct ServiceFixture {
    let directory: URL
    let cacheRoot: URL
    let tree: FixtureTree
    let catalog: Catalog
    let reader: CatalogReader
    let bookmarks: BookmarkStore
    let sourceID: SourceID
    private let suite: String

    init() async throws {
        suite = "gallery.thumbnail.tests.\(UUID().uuidString)"
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("gallery-thumbs-\(UUID().uuidString)")
        cacheRoot = directory.appendingPathComponent("cache")
        tree = try FixtureTree()
        let database = directory.appendingPathComponent("catalog.db")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        catalog = try Catalog.open(at: database)
        reader = try CatalogReader.open(at: database)
        bookmarks = BookmarkStore(defaults: try #require(UserDefaults(suiteName: suite)))
        sourceID = try await catalog.addSource(displayName: "Library", rootPath: tree.root.path,
                                               volumeID: "vol-1").id
    }

    func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.removeItem(at: tree.root)
        UserDefaults.standard.removePersistentDomain(forName: suite)
    }

    /// A real JPEG, with the modification stamp the cache key is built from, and the row that points at it.
    func photo(_ name: String, width: Int = 1280, height: Int = 960,
               modified: Date = Date(timeIntervalSince1970: 1_700_000_000)) async throws -> MediaItem {
        let url = tree.url(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try #require(writeJPEG(to: url, width: width, height: height))
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)

        let item = MediaItem(
            id: MediaID(rawValue: 0),
            identity: FileIdentity(volumeID: "vol-1", documentID: nil, resourceID: nil,
                                   statHash: statHash(size: 1024, modificationDate: modified,
                                                      creationDate: nil)),
            sourceID: sourceID,
            relativePath: name,
            parentDirectory: (name as NSString).deletingLastPathComponent == "."
                ? "" : (name as NSString).deletingLastPathComponent,
            name: (name as NSString).lastPathComponent,
            fileExtension: (name as NSString).pathExtension,
            kind: .image,
            uniformTypeIdentifier: "public.jpeg",
            byteSize: 1024,
            modificationDate: modified
        )
        let ids = try await catalog.recordEnumeration([item])
        let id = try #require(ids.first)
        return try #require(await reader.item(id: id))
    }

    func store(byteLimit: Int64 = 16 * 1024 * 1024) -> ThumbnailStore {
        ThumbnailStore(layout: ThumbnailLayout(root: cacheRoot), byteLimit: byteLimit)
    }

    /// The service against the catalog's own path resolution — the wiring the app runs, not a stand-in.
    func service(byteLimit: Int64 = 16 * 1024 * 1024,
                 configuration: ThumbnailService.Configuration = .init()) -> ThumbnailService {
        ThumbnailService(catalog: catalog, store: store(byteLimit: byteLimit),
                         resolver: CatalogMediaResolver(reader: reader, bookmarks: bookmarks),
                         configuration: configuration)
    }

    func manifest() async throws -> [ThumbnailRecord] {
        try await catalog.coldestThumbnails(limit: 50)
    }
}

// MARK: - Stubs

/// A door the test opens, so "the bake is in flight" is a fact rather than a sleep.
actor BakeDoor {
    private var arrivals = 0
    private var isHeld = true
    private var blocked: [CheckedContinuation<Void, Never>] = []
    private var counts: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func arrive() async {
        arrivals += 1
        flush()
        guard isHeld else { return }
        await withCheckedContinuation { blocked.append($0) }
    }

    func wait(forAtLeast count: Int) async {
        if arrivals >= count { return }
        await withCheckedContinuation { counts.append((count, $0)) }
    }

    func open() {
        isHeld = false
        let parked = blocked
        blocked = []
        parked.forEach { $0.resume() }
        flush()
    }

    private func flush() {
        let ready = counts.filter { arrivals >= $0.count }
        counts = counts.filter { arrivals < $0.count }
        ready.forEach { $0.continuation.resume() }
    }
}

/// Which ids a resolver was asked for, and when it was held.
///
/// A class because `Mutex` is not copyable and the resolver is copied into the service — the test needs to
/// read the same log the copy appends to, which is the whole point of asserting "the catalog was never asked".
final class AskLog: @unchecked Sendable {
    private let lock = NSLock()
    private var ids: [MediaID] = []

    func record(_ batch: [MediaID]) {
        lock.withLock { ids.append(contentsOf: batch) }
    }

    /// In ask order, so a test can say the queue was thrown away rather than finished.
    var all: [MediaID] {
        lock.withLock { ids }
    }

    var unique: Set<MediaID> { Set(all) }
    var count: Int { all.count }
}

/// A resolver that says which ids it was asked for, and can be held mid-bake.
struct RecordingResolver: MediaResolving {
    let targets: [MediaID: MediaTarget]
    let asked: AskLog
    let door: BakeDoor?

    init(_ targets: [MediaID: MediaTarget], asked: AskLog = AskLog(), door: BakeDoor? = nil) {
        self.targets = targets
        self.asked = asked
        self.door = door
    }

    func targets(for ids: [MediaID]) async -> [MediaID: MediaTarget] {
        asked.record(ids)
        await door?.arrive()
        return targets.filter { ids.contains($0.key) }
    }
}

// MARK: - Fixtures for the pixels themselves

private func raster(width: Int, height: Int) -> CGImage? {
    let context = CGContext(data: nil, width: max(1, width), height: max(1, height), bitsPerComponent: 8,
                             bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    context?.setFillColor(CGColor(red: 0.4, green: 0.5, blue: 0.6, alpha: 1))
    context?.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return context?.makeImage()
}

private func writeJPEG(to url: URL, width: Int, height: Int) -> Bool {
    guard let image = raster(width: width, height: height),
          let destination = CGImageDestinationCreateWithURL(
              url as CFURL, UTType.jpeg.identifier as CFString, 1, nil
          ) else { return false }
    CGImageDestinationAddImage(destination, image, nil)
    return CGImageDestinationFinalize(destination)
}

@Suite("The three tiers")
struct ThumbnailTierTests {
    @Test("A cold cell bakes once, and every later ask is answered by a cheaper tier")
    func tiers() async throws {
        let library = try await ServiceFixture()
        defer { library.tearDown() }
        let item = try await library.photo("IMG_1.jpg")
        let request = ThumbnailService.Request(item: item)
        let asked = AskLog()
        let service = ThumbnailService(catalog: library.catalog, store: library.store(),
                                       resolver: RecordingResolver([item.id: MediaTarget(
                                           url: library.tree.url("IMG_1.jpg")
                                       )], asked: asked))

        let image = try #require(await service.image(request, bucket: .gridLarge))
        // The bucket is a ceiling, and the row's stamp is what the file is named for.
        #expect(image.width == 320 && image.height == 240)
        var stats = await service.stats
        #expect(stats.bakes == 1 && stats.diskHits == 0 && stats.memoryHits == 0)
        #expect(asked.count == 1, "only a bake asks where the file is")

        let cachedURL = library.store().layout.url(mediaID: item.id, bucket: .gridLarge,
                                                   mtime: item.modificationDate)
        #expect(FileManager.default.fileExists(atPath: cachedURL.path), "the JPEG is the cache")
        let rows = try await library.manifest()
        #expect(rows.count == 1)
        #expect(rows.first?.path == cachedURL.path)
        #expect((rows.first?.byteSize ?? 0) > 0)

        _ = try #require(await service.image(request, bucket: .gridLarge))
        stats = await service.stats
        #expect(stats.memoryHits == 1 && stats.bakes == 1)
        #expect(asked.count == 1, "a memory hit touches neither the disk nor the catalog")

        await service.purgeMemory()
        _ = try #require(await service.image(request, bucket: .gridLarge))
        stats = await service.stats
        #expect(stats.diskHits == 1 && stats.bakes == 1)
        #expect(asked.count == 1, "a disk hit is answered by the filename alone")
    }

    @Test("The cache answers with the source file gone")
    func diskOutlivesTheSource() async throws {
        let library = try await ServiceFixture()
        defer { library.tearDown() }
        let item = try await library.photo("IMG_2.jpg")
        let request = ThumbnailService.Request(item: item)
        let asked = AskLog()
        let service = ThumbnailService(catalog: library.catalog, store: library.store(),
                                       resolver: RecordingResolver([item.id: MediaTarget(
                                           url: library.tree.url("IMG_2.jpg")
                                       )], asked: asked))
        _ = try #require(await service.image(request, bucket: .gridSmall))
        try library.tree.remove("IMG_2.jpg")

        await service.purgeMemory()
        let image = try #require(await service.image(request, bucket: .gridSmall))
        #expect(image.width == 160)
        #expect((await service.stats).bakes == 1, "the second answer came from the cache, not a re-decode")
        #expect(asked.count == 1)
    }

    @Test("A cache file that cannot be decoded is replaced by a fresh bake")
    func corruptCacheHeals() async throws {
        let library = try await ServiceFixture()
        defer { library.tearDown() }
        let item = try await library.photo("IMG_3.jpg")
        let request = ThumbnailService.Request(item: item)
        let store = library.store()
        let service = ThumbnailService(catalog: library.catalog, store: store,
                                       resolver: CatalogMediaResolver(reader: library.reader,
                                                                          bookmarks: library.bookmarks))
        _ = try #require(await service.image(request, bucket: .gridLarge))
        let cachedURL = store.layout.url(mediaID: item.id, bucket: .gridLarge,
                                         mtime: item.modificationDate)
        try Data([0xDE, 0xAD, 0xBE, 0xEF]).write(to: cachedURL)

        await service.purgeMemory()
        let image = try #require(await service.image(request, bucket: .gridLarge))
        #expect(image.width == 320)
        #expect((await service.stats).bakes == 2)
        // Reading the file back proves the re-bake wrote it, rather than the nil answer coming from somewhere
        // else on the second pass.
        let decoded = ThumbnailBaker.image(from: try Data(contentsOf: cachedURL))
        #expect(decoded?.height == 240)
    }

    @Test("A re-stamped photo is a new key, a new file, and a new row")
    func restampIsAMiss() async throws {
        let library = try await ServiceFixture()
        defer { library.tearDown() }
        let item = try await library.photo("IMG_4.jpg")
        let store = library.store()
        let service = ThumbnailService(catalog: library.catalog, store: store,
                                       resolver: CatalogMediaResolver(reader: library.reader,
                                                                          bookmarks: library.bookmarks))
        _ = try #require(await service.image(ThumbnailService.Request(item: item), bucket: .gridLarge))

        let stamp = try #require(item.modificationDate)
        let later = stamp.addingTimeInterval(60)
        try FileManager.default.setAttributes([.modificationDate: later],
                                              ofItemAtPath: library.tree.url("IMG_4.jpg").path)
        _ = try #require(await service.image(
            ThumbnailService.Request(mediaID: item.id, mtime: later), bucket: .gridLarge
        ))

        let stats = await service.stats
        #expect(stats.bakes == 2 && stats.diskHits == 0)
        let rows = try await library.manifest()
        #expect(Set(rows.map(\.mtime)) == [stamp, later])
        #expect(Set(rows.map(\.path)).count == 2)
    }

    @Test("A file that is not there and a row that is not there both answer honestly")
    func failures() async throws {
        let library = try await ServiceFixture()
        defer { library.tearDown() }
        let item = try await library.photo("IMG_5.jpg")
        let store = library.store()
        let missingFile = ThumbnailService(catalog: library.catalog, store: store,
                                          resolver: RecordingResolver([
                                              item.id: MediaTarget(url: library.tree.url("gone.jpg"))
                                          ]))
        #expect(await missingFile.image(ThumbnailService.Request(item: item), bucket: .list) == nil)
        #expect((await missingFile.stats).failures == 1)
        #expect(try await library.catalog.thumbnailRecordCount() == 0, "nothing to record")

        let missingRow = ThumbnailService(catalog: library.catalog, store: store,
                                          resolver: RecordingResolver([:]))
        #expect(await missingRow.image(
            ThumbnailService.Request(mediaID: MediaID(rawValue: 9_999), mtime: nil), bucket: .list
        ) == nil)
        #expect((await missingRow.stats).failures == 1)
    }

    @Test("Pass B's bytes arrive at the same name the grid will look for")
    func recordBakedIsAFileTheGridFinds() async throws {
        let library = try await ServiceFixture()
        defer { library.tearDown() }
        let item = try await library.photo("IMG_6.jpg")
        let request = ThumbnailService.Request(item: item)
        let store = library.store()
        // What a background lane would hand over: it decoded the file for its own reasons.
        let jpeg = try #require(ThumbnailBaker.bake(url: library.tree.url("IMG_6.jpg"), bucket: .viewerHalf))
        let service = ThumbnailService(catalog: library.catalog, store: store,
                                       resolver: RecordingResolver([:]))
        await service.recordBaked(jpeg, request, bucket: .viewerHalf)

        let image = try #require(await service.image(request, bucket: .viewerHalf))
        #expect(image.width == 1024)
        let stats = await service.stats
        #expect(stats.diskHits == 1 && stats.bakes == 0)
        let rows = try await library.manifest()
        #expect(rows.first?.byteSize == Int64(jpeg.count))
    }
}

@Suite("One bake per picture")
struct ThumbnailCoalescingTests {
    @Test("Fifty cells asking for the same picture cause one decode")
    func concurrentRequests() async throws {
        let library = try await ServiceFixture()
        defer { library.tearDown() }
        let item = try await library.photo("IMG_7.jpg", width: 2000, height: 1500)
        let request = ThumbnailService.Request(item: item)
        let service = ThumbnailService(catalog: library.catalog, store: library.store(),
                                       resolver: RecordingResolver([item.id: MediaTarget(
                                           url: library.tree.url("IMG_7.jpg")
                                       )]))

        let images = await withTaskGroup(of: CGImage?.self) { group in
            for _ in 0..<50 {
                group.addTask { await service.image(request, bucket: .gridLarge) }
            }
            var collected: [CGImage?] = []
            for await image in group { collected.append(image) }
            return collected
        }

        #expect(images.compactMap { $0 }.count == 50)
        let stats = await service.stats
        #expect(stats.bakes == 1, "the bake is shared, not repeated")
        #expect(try await library.catalog.thumbnailRecordCount() == 1)
    }

    @Test("A cell that scrolled away stops waiting without stopping the bake")
    func cancellingAWaiter() async throws {
        let library = try await ServiceFixture()
        defer { library.tearDown() }
        let item = try await library.photo("IMG_8.jpg")
        let request = ThumbnailService.Request(item: item)
        let door = BakeDoor()
        let asked = AskLog()
        let resolver = RecordingResolver([item.id: MediaTarget(url: library.tree.url("IMG_8.jpg"))],
                                         asked: asked, door: door)
        let service = ThumbnailService(catalog: library.catalog, store: library.store(),
                                       resolver: resolver, configuration: .init(prefetchWorkers: 0))

        // Two cells, one picture: the viewer's thumbnail and a grid cell for the same photo.
        let staying = Task { await service.image(request, bucket: .gridLarge) }
        let scrolling = Task { await service.image(request, bucket: .gridLarge) }
        await door.wait(forAtLeast: 1)
        // The door is shut, so the bake is provably in flight; the short wait is only for the second cell to
        // be parked on it, which is in-memory work and cannot take milliseconds.
        try await Task.sleep(for: .milliseconds(20))
        scrolling.cancel()
        await door.open()

        let image = try #require(await staying.value)
        #expect(image.width == 320, "the cell that stayed got its picture")
        #expect(await scrolling.value == nil, "the cell that left stopped waiting")
        let stats = await service.stats
        #expect(stats.bakes == 1 && stats.failures == 0)
        #expect(asked.unique == [item.id])
    }

    @Test("Scrolling away and back does not start the same decode twice")
    func rejoinAfterCancel() async throws {
        let library = try await ServiceFixture()
        defer { library.tearDown() }
        let item = try await library.photo("IMG_9.jpg")
        let request = ThumbnailService.Request(item: item)
        let door = BakeDoor()
        let asked = AskLog()
        let service = ThumbnailService(catalog: library.catalog, store: library.store(),
                                       resolver: RecordingResolver(
                                           [item.id: MediaTarget(url: library.tree.url("IMG_9.jpg"))],
                                           asked: asked, door: door),
                                       configuration: .init(prefetchWorkers: 0))

        let flicked = Task { await service.image(request, bucket: .gridLarge) }
        await door.wait(forAtLeast: 1)
        flicked.cancel()
        // The cell that scrolled off is gone, but its decode is not: coming back has to join it.
        let back = Task { await service.image(request, bucket: .gridLarge) }
        try await Task.sleep(for: .milliseconds(20))
        #expect(asked.count == 1, "the second ask found the first bake still running and waited for it")

        await door.open()
        let image = try #require(await back.value)
        #expect(image.width == 320)
        #expect((await service.stats).bakes == 1)
    }

    @Test("The window is prefetched, and what scrolls out of it never costs a decode")
    func windowDropsWhatLeavesIt() async throws {
        let library = try await ServiceFixture()
        defer { library.tearDown() }
        var items: [MediaItem] = []
        for index in 0..<4 {
            items.append(try await library.photo("IMG_\(index).jpg"))
        }
        let requests = items.map(ThumbnailService.Request.init(item:))
        let door = BakeDoor()
        let asked = AskLog()
        var targets: [MediaID: MediaTarget] = [:]
        for (index, item) in items.enumerated() {
            targets[item.id] = MediaTarget(url: library.tree.url("IMG_\(index).jpg"))
        }
        let service = ThumbnailService(catalog: library.catalog, store: library.store(),
                                       resolver: RecordingResolver(targets, asked: asked, door: door),
                                       configuration: .init(prefetchWorkers: 1))

        await service.setWindow([requests[0], requests[1], requests[2]], bucket: .gridLarge)
        await door.wait(forAtLeast: 1)
        // The single worker is inside the first bake; the other two are still queued.
        await service.setWindow([requests[3]], bucket: .gridLarge)
        await door.wait(forAtLeast: 2)
        await door.open()
        // Two prefetches were parked inside the door when the window moved. Joining them is how the test
        // learns they finished — sleeping for a counter is how a suite learns to flake.
        _ = await service.image(requests[0], bucket: .gridLarge)
        _ = await service.image(requests[3], bucket: .gridLarge)

        // Nothing asked for directly, so every arrival is a prefetch.
        #expect(asked.unique == [items[0].id, items[3].id],
                "the two pictures that left the window were never decoded")
        let stats = await service.stats
        #expect(stats.prefetchDropped == 2)
        #expect(stats.bakes == 2)
    }

    @Test("Clearing the window stops the queue")
    func clearWindow() async throws {
        let library = try await ServiceFixture()
        defer { library.tearDown() }
        var items: [MediaItem] = []
        for index in 0..<3 {
            items.append(try await library.photo("IMG_\(index).jpg"))
        }
        let door = BakeDoor()
        let asked = AskLog()
        var targets: [MediaID: MediaTarget] = [:]
        for (index, item) in items.enumerated() {
            targets[item.id] = MediaTarget(url: library.tree.url("IMG_\(index).jpg"))
        }
        let service = ThumbnailService(catalog: library.catalog, store: library.store(),
                                       resolver: RecordingResolver(targets, asked: asked, door: door),
                                       configuration: .init(prefetchWorkers: 1))

        await service.setWindow(items.map(ThumbnailService.Request.init(item:)), bucket: .list)
        await door.wait(forAtLeast: 1)
        await service.clearWindow()
        await door.open()
        try await Task.sleep(for: .milliseconds(50))

        #expect(asked.all == [items[0].id], "the queue was thrown away, not finished")
        #expect((await service.stats).prefetchDropped == 2)
    }
}

@Suite("Cache bookkeeping")
struct ThumbnailCacheTests {
    @Test("Displaying a cached thumbnail moves its place in the eviction order")
    func displayTicksTheLRU() async throws {
        let library = try await ServiceFixture()
        defer { library.tearDown() }
        let item = try await library.photo("IMG_9.jpg")
        let request = ThumbnailService.Request(item: item)
        let store = library.store()
        let jpeg = try #require(ThumbnailBaker.bake(url: library.tree.url("IMG_9.jpg"), bucket: .gridSmall))
        let path = try store.save(jpeg, mediaID: item.id, bucket: .gridSmall, mtime: item.modificationDate)
        // A row written by an earlier session, dated long ago.
        try await library.catalog.noteThumbnail(ThumbnailRecord(
            mediaID: item.id, bucket: .gridSmall, mtime: item.modificationDate, path: path.path,
            byteSize: Int64(jpeg.count), lastUsed: .distantPast
        ))

        let service = ThumbnailService(catalog: library.catalog, store: store,
                                       resolver: RecordingResolver([:]))
        _ = try #require(await service.image(request, bucket: .gridSmall))
        let before = try #require((try await library.manifest()).first)
        await service.flushTouches()

        let after = try #require((try await library.manifest()).first)
        #expect(after.lastUsed > before.lastUsed, "the clock moved because the user looked at it")
        #expect(after.byteSize == before.byteSize, "a display tick must not forget the file's size")
    }

    @Test("The budget prunes the coldest picture, file and row together")
    func enforceBudget() async throws {
        let library = try await ServiceFixture()
        defer { library.tearDown() }
        var requests: [ThumbnailService.Request] = []
        for index in 0..<3 {
            let item = try await library.photo("IMG_\(10 + index).jpg")
            requests.append(ThumbnailService.Request(item: item))
        }
        let baker = library.service(configuration: .init(prefetchWorkers: 0))
        for request in requests {
            _ = try #require(await baker.image(request, bucket: .gridLarge))
        }

        let total = try await library.catalog.thumbnailManifestBytes()
        let store = library.store(byteLimit: max(1, total - 1))
        let service = ThumbnailService(catalog: library.catalog, store: store,
                                       resolver: RecordingResolver([:]),
                                       configuration: .init(evictionChunkRows: 1))
        // The one the user has not looked at since the Pleistocene goes first.
        let coldest = requests[2]
        try await library.catalog.touchThumbnail(mediaID: coldest.mediaID, bucket: .gridLarge,
                                                 mtime: coldest.mtime,
                                                 path: store.layout.url(mediaID: coldest.mediaID,
                                                                        bucket: .gridLarge,
                                                                        mtime: coldest.mtime).path,
                                                 usedAt: .distantPast)

        let freed = await service.enforceBudget()
        #expect(freed > 0)
        let rows = try await library.manifest()
        #expect(rows.count == 2, "one byte over a 3-thumbnail budget costs exactly one thumbnail")
        #expect(Set(rows.map(\.mediaID)) == Set([requests[0].mediaID, requests[1].mediaID]))
        #expect(!FileManager.default.fileExists(atPath: store.layout.url(
            mediaID: coldest.mediaID, bucket: .gridLarge, mtime: coldest.mtime
        ).path), "pruning deletes the file, not just the row that pointed at it")
        #expect(FileManager.default.fileExists(atPath: store.layout.url(
            mediaID: requests[0].mediaID, bucket: .gridLarge, mtime: requests[0].mtime
        ).path))
    }

    @Test("A budget already met costs no filesystem work")
    func underBudget() async throws {
        let library = try await ServiceFixture()
        defer { library.tearDown() }
        let item = try await library.photo("IMG_13.jpg")
        let service = library.service(byteLimit: 16 * 1024 * 1024,
                                      configuration: .init(prefetchWorkers: 0))
        _ = try #require(await service.image(ThumbnailService.Request(item: item), bucket: .gridLarge))
        #expect(await service.enforceBudget() == 0)
        #expect(try await library.catalog.thumbnailRecordCount() == 1)
    }

    @Test("The service finds its pictures through the catalog, not through a hand-built map")
    func catalogResolution() async throws {
        let library = try await ServiceFixture()
        defer { library.tearDown() }
        let item = try await library.photo("holiday/IMG_14.jpg")
        let service = library.service(configuration: .init(prefetchWorkers: 0))

        let image = try #require(await service.image(ThumbnailService.Request(item: item),
                                                     bucket: .gridSmall))
        #expect(image.width == 160)
        let rows = try await library.manifest()
        #expect(rows.first?.path.hasPrefix(library.cacheRoot.path) == true)
        #expect(rows.first?.path.contains("/160/") == true, "the bucket is in the path the grid will rebuild")
    }
}
