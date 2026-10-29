import Foundation
import Testing
@testable import GalleryIndexing
import GalleryCatalog
import GalleryDomain
import GalleryImaging
import GallerySupport

/// Pass B against a real catalog, real JPEGs, and the queue as its only source of work.
///
/// Every assertion here is about state the *next* process has to trust: what stage a row reached, what the
/// cache holds, what is still queued when a run stops. So the checks read the catalog back rather than
/// watching the worker's own counters, and the files are files — ImageIO either produces a poster or it does
/// not, and a mock would let a test pass that ships a grid of placeholders.
private struct WorkerFixture {
    let library: ServiceFixture

    init() async throws { library = try await ServiceFixture() }

    var catalog: Catalog { library.catalog }
    var reader: CatalogReader { library.reader }
    var sourceID: SourceID { library.sourceID }
    var tree: FixtureTree { library.tree }

    func tearDown() { library.tearDown() }

    /// A picture on disk with the row pass A left behind. `modified` is what the queue's `rank` is made of,
    /// which is why a test about ordering gets to choose it.
    func photo(_ name: String, modified: Date = Date(timeIntervalSince1970: 1_700_000_000)) async throws -> MediaItem {
        try await library.photo(name, modified: modified)
    }

    /// A row whose bytes are not a picture. `stage` is pass A's answer for a file it only statued.
    func undecidable(_ name: String, content: Data,
                     modified: Date = Date(timeIntervalSince1970: 1_700_000_000)) async throws -> MediaItem {
        let url = tree.url(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try content.write(to: url)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        let parent = (name as NSString).deletingLastPathComponent
        let item = MediaItem(
            id: MediaID(rawValue: 0),
            identity: FileIdentity(volumeID: "vol-1", documentID: nil, resourceID: nil,
                                   statHash: statHash(size: Int64(content.count),
                                                      modificationDate: modified, creationDate: nil)),
            sourceID: sourceID,
            relativePath: name,
            parentDirectory: parent == "." ? "" : parent,
            name: (name as NSString).lastPathComponent,
            fileExtension: (name as NSString).pathExtension,
            kind: .image,
            uniformTypeIdentifier: "public.jpeg",
            byteSize: Int64(content.count),
            stage: .classified,
            modificationDate: modified
        )
        let ids = try await catalog.recordEnumeration([item])
        let id = try #require(ids.first)
        return try #require(await reader.item(id: id))
    }

    /// A real JPEG that the catalog believes is still an iCloud stub — the only way to prove the worker read
    /// the row rather than the file.
    func offline(_ name: String) async throws -> MediaItem {
        var row = try await photo(name)
        row.isOffline = true
        _ = try await catalog.recordEnumeration([row])
        return try #require(await reader.item(id: row.id))
    }

    func target(_ item: MediaItem) -> MediaTarget { MediaTarget(url: tree.url(item.relativePath)) }

    func targets(of items: [MediaItem]) -> [MediaID: MediaTarget] {
        items.reduce(into: [MediaID: MediaTarget]()) { $0[$1.id] = target($1) }
    }

    func worker(_ resolver: any MediaResolving, batchRows: Int = 64, maximumAttempts: Int = 3,
                posterBucket: ThumbnailBucket = .gridLarge) -> MetadataWorker {
        MetadataWorker(catalog: catalog, reader: reader, resolver: resolver,
                       thumbnails: library.service(configuration: .init(prefetchWorkers: 0)),
                       configuration: .init(batchRows: batchRows, posterBucket: posterBucket,
                                            maximumAttempts: maximumAttempts))
    }

    /// A grid service that cannot reach the source files: anything it draws came out of the cache.
    func grid() -> ThumbnailService {
        ThumbnailService(catalog: catalog, store: library.store(), resolver: RecordingResolver([:]),
                         configuration: .init(prefetchWorkers: 0))
    }
}

@Suite("Draining the queue")
struct MetadataWorkerDrainTests {
    @Test("A drain leaves the grid something to draw without asking it to decode")
    func drainToThumbnailed() async throws {
        let fix = try await WorkerFixture()
        defer { fix.tearDown() }
        var items: [MediaItem] = []
        for index in 0..<3 {
            items.append(try await fix.photo("holiday/IMG_\(index).jpg"))
        }
        try await fix.catalog.enqueuePendingWork(sourceID: fix.sourceID)

        let asked = AskLog()
        let worker = fix.worker(RecordingResolver(fix.targets(of: items), asked: asked))
        let outcome = await worker.drain()

        #expect(outcome.hops == 1, "one claim takes a 64-row batch")
        #expect(outcome.claimed == 3)
        #expect(outcome.metadataRead == 3 && outcome.postersRecorded == 3)
        #expect(outcome.failures == 0 && outcome.parked == 0 && outcome.stale == 0)
        #expect(outcome.droppedBatches == 0)
        #expect(asked.unique == Set(items.map(\.id)), "each file resolved once")

        #expect(try await fix.catalog.queuedWorkCount(sourceID: fix.sourceID) == 0)
        #expect(try await fix.catalog.stageCounts(sourceID: fix.sourceID)[.thumbnailed] == 3)

        let stored = try #require(await fix.reader.item(id: items[0].id))
        #expect(stored.stage == .thumbnailed && stored.error == .none)
        #expect(stored.pixelSize == PixelSize(width: 1280, height: 960))
        #expect(stored.capture != nil, "a JPEG with no EXIF still gets a day from the file system")
        #expect(stored.searchText?.contains("photo") == true)

        // The milestone's whole point, checked from the consumer's side: the cell asks, the cache answers.
        let grid = fix.grid()
        let image = try #require(await grid.image(ThumbnailService.Request(item: stored), bucket: .gridLarge))
        #expect(image.width == 320)
        let stats = await grid.stats
        #expect(stats.bakes == 0 && stats.diskHits == 1,
                "the preview pass B wrote is the preview the grid draws")
    }

    @Test("The viewport is read before the backlog, and the backlog newest-first")
    func viewportJumpsTheQueue() async throws {
        let fix = try await WorkerFixture()
        defer { fix.tearDown() }
        let day: TimeInterval = 86_400
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let oldest = try await fix.photo("oldest.jpg", modified: base.addingTimeInterval(-100 * day))
        let middle = try await fix.photo("middle.jpg", modified: base.addingTimeInterval(-50 * day))
        let newest = try await fix.photo("newest.jpg", modified: base)
        try await fix.catalog.enqueuePendingWork(sourceID: fix.sourceID)
        // The user scrolled to the oldest picture, so it is the one row pass B must read next.
        try await fix.catalog.raiseWorkPriority(mediaIDs: [oldest.id], priority: 1)

        let asked = AskLog()
        // One row per hop: `rank` decides which file is next only if the worker takes them one at a time.
        let worker = fix.worker(RecordingResolver(fix.targets(of: [oldest, middle, newest]), asked: asked),
                               batchRows: 1)
        _ = await worker.drain()

        #expect(asked.all == [oldest.id, newest.id, middle.id],
                "priority first, then the newest file — the promise `queue_claim` is built for")
    }

    @Test("Two drains on one queue still read each file once")
    func oneConsumerPerQueue() async throws {
        let fix = try await WorkerFixture()
        defer { fix.tearDown() }
        var items: [MediaItem] = []
        for index in 0..<3 {
            items.append(try await fix.photo("IMG_\(index).jpg"))
        }
        try await fix.catalog.enqueuePendingWork(sourceID: fix.sourceID)

        let asked = AskLog()
        let worker = fix.worker(RecordingResolver(fix.targets(of: items), asked: asked))
        async let first = worker.drain()
        async let second = worker.drain()
        var total = await first
        total += await second

        #expect(total.metadataRead == 3, "the second caller was refused, not given half the queue")
        #expect(total.postersRecorded == 3)
        #expect(asked.count == 3, "no file was resolved twice")
        #expect(try await fix.catalog.stageCounts(sourceID: fix.sourceID)[.thumbnailed] == 3)
    }

    @Test("Cancelling costs the batch in flight, not the library behind it")
    func cancelKeepsTheQueue() async throws {
        let fix = try await WorkerFixture()
        defer { fix.tearDown() }
        let first = try await fix.photo("IMG_a.jpg")
        let second = try await fix.photo("IMG_b.jpg")
        try await fix.catalog.enqueuePendingWork(sourceID: fix.sourceID)

        let door = BakeDoor()
        let asked = AskLog()
        let worker = fix.worker(RecordingResolver(fix.targets(of: [first, second]), asked: asked, door: door),
                               batchRows: 2)
        let running = Task { await worker.drain() }
        await door.wait(forAtLeast: 1)
        running.cancel()
        // The hop is provably inside the resolver; opening the door lets it unwind onto the cancelled task.
        await door.open()

        let outcome = await running.value
        #expect(outcome.claimed == 2, "the batch was taken from the queue")
        #expect(outcome.metadataRead == 0 && outcome.postersRecorded == 0, "and nothing was settled")
        #expect(try await fix.catalog.queuedWorkCount(sourceID: fix.sourceID) == 2,
                "a cancelled batch is claimed again, not lost")
        #expect(try await fix.catalog.stageCounts(sourceID: fix.sourceID)[.thumbnailed] == nil)
    }

    @Test("A pause stops the next claim and lets the current batch land")
    func pauseStopsTheNextClaim() async throws {
        let fix = try await WorkerFixture()
        defer { fix.tearDown() }
        var items: [MediaItem] = []
        for index in 0..<3 {
            items.append(try await fix.photo("IMG_\(index).jpg"))
        }
        try await fix.catalog.enqueuePendingWork(sourceID: fix.sourceID)

        let door = BakeDoor()
        let asked = AskLog()
        // Two rows a hop, so the third is provably the next claim rather than part of this one.
        let worker = fix.worker(RecordingResolver(fix.targets(of: items), asked: asked, door: door),
                               batchRows: 2)
        let running = Task { await worker.drain() }
        await door.wait(forAtLeast: 1)
        // Pausing while the hop is provably inside the resolver: the loop is past its pause check and cannot
        // see the flag until this batch is done.
        await worker.setPaused(true)
        await door.open()

        try await waitForSettled(fix.catalog, sourceID: fix.sourceID, rows: 2)
        #expect(try await fix.catalog.queuedWorkCount(sourceID: fix.sourceID) == 1)
        let paused = try #require(await worker.latestProgress(sourceID: fix.sourceID).first)
        #expect(paused.isPaused && paused.queued == 1, "the HUD's number during a pause is the backlog")

        await worker.setPaused(false)
        let outcome = await running.value
        #expect(outcome.hops == 2 && outcome.claimed == 3)
        #expect(outcome.metadataRead == 3 && outcome.postersRecorded == 3)
        #expect(try await fix.catalog.queuedWorkCount(sourceID: fix.sourceID) == 0)
        #expect(asked.unique == Set(items.map(\.id)))
    }
}

/// Wait for a number the drain writes itself. Polling the catalog rather than sleeping for a guess is the
/// difference between a test that proves a pause landed and one that proves the machine was fast.
private func waitForSettled(_ catalog: Catalog, sourceID: SourceID, rows: Int,
                            timeout: Duration = .seconds(10)) async throws {
    let clock = SuspendingClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if (try? await catalog.stageCounts(sourceID: sourceID)[.thumbnailed]) ?? 0 == rows { return }
        try await clock.sleep(for: .milliseconds(5))
    }
    Issue.record("pass B never settled \(rows) rows")
}

@Suite("Files pass B cannot read")
struct MetadataWorkerFailureTests {
    @Test("A damaged file is retried a bounded number of times, then parked")
    func parksAfterMaximumAttempts() async throws {
        let fix = try await WorkerFixture()
        defer { fix.tearDown() }
        let broken = try await fix.undecidable("broken.jpg", content: Data(repeating: 0x2A, count: 512))
        try await fix.catalog.enqueuePendingWork(sourceID: fix.sourceID)

        let worker = fix.worker(RecordingResolver([broken.id: fix.target(broken)]),
                                batchRows: 1, maximumAttempts: 2)
        let outcome = await worker.drain()

        #expect(outcome.failures == 2 && outcome.parked == 1)
        #expect(outcome.metadataRead == 0 && outcome.postersRecorded == 0)
        #expect(try await fix.catalog.queuedWorkCount(sourceID: fix.sourceID) == 0,
                "parked so the rest of the library can drain")
        let stored = try #require(await fix.reader.item(id: broken.id))
        #expect(stored.error != .none)
        #expect(stored.stage == .classified, "a failed read never advances the row")
        #expect(try await fix.catalog.thumbnailRecordCount() == 0)
    }

    @Test("A file that left between the walk and the read is badged as vanished")
    func vanishedIsRecorded() async throws {
        let fix = try await WorkerFixture()
        defer { fix.tearDown() }
        let photo = try await fix.photo("IMG_gone.jpg")
        try await fix.catalog.enqueuePendingWork(sourceID: fix.sourceID)
        try fix.tree.remove("IMG_gone.jpg")

        let worker = fix.worker(RecordingResolver([photo.id: MediaTarget(url: fix.tree.url("IMG_gone.jpg"))]),
                                batchRows: 1)
        let outcome = await worker.drain()

        #expect(outcome.failures == 3 && outcome.parked == 1, "the default allowance is three attempts")
        let stored = try #require(await fix.reader.item(id: photo.id))
        #expect(stored.error == .vanished)
    }

    @Test("A row the resolver cannot place is badged with the reason the user will see")
    func unresolvedTarget() async throws {
        let fix = try await WorkerFixture()
        defer { fix.tearDown() }
        let photo = try await fix.photo("IMG_orphan.jpg")
        try await fix.catalog.enqueuePendingWork(sourceID: fix.sourceID)

        let worker = fix.worker(RecordingResolver([:]), batchRows: 1, maximumAttempts: 1)
        _ = await worker.drain()

        let stored = try #require(await fix.reader.item(id: photo.id))
        #expect(stored.error == .noAccess)
        #expect(stored.error.userReason == "No read permission")
        #expect(try await fix.catalog.queuedWorkCount(sourceID: fix.sourceID) == 0)
    }

    @Test("An iCloud stub is badged, not quietly downloaded")
    func offlineIsBadgedNotRead() async throws {
        let fix = try await WorkerFixture()
        defer { fix.tearDown() }
        let stub = try await fix.offline("IMG_stub.jpg")
        #expect(stub.isOffline)
        try await fix.catalog.enqueuePendingWork(sourceID: fix.sourceID)

        let asked = AskLog()
        let worker = fix.worker(RecordingResolver([stub.id: fix.target(stub)], asked: asked))
        let outcome = await worker.drain()

        // The file is a real JPEG on this disk; a worker that read it would have filled these in.
        #expect(outcome.metadataRead == 0 && outcome.postersRecorded == 0)
        #expect(outcome.failures == 1, "a stub is a problem the user should be told about")
        let stored = try #require(await fix.reader.item(id: stub.id))
        #expect(stored.error == .offline)
        #expect(stored.pixelSize == nil)
        #expect(stored.stage == .enumerated)
        #expect(try await fix.catalog.thumbnailRecordCount() == 0)
        #expect(try await fix.catalog.queuedWorkCount(sourceID: fix.sourceID) == 0)
    }

    @Test("A poster the cache refuses leaves the row at metadata, not at thumbnailed",
          .enabled(if: FixtureTree.canDenyAccess))
    func posterFailureIsABadge() async throws {
        let fix = try await WorkerFixture()
        // Restored before the fixture's directory is deleted, so the order of these two matters.
        defer { fix.tearDown() }
        let cache = fix.library.cacheRoot
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        defer { chmod(cache.path, 0o755) }
        chmod(cache.path, 0o000)

        let photo = try await fix.photo("IMG_cache.jpg")
        try await fix.catalog.enqueuePendingWork(sourceID: fix.sourceID)

        let worker = fix.worker(RecordingResolver([photo.id: fix.target(photo)]))
        let outcome = await worker.drain()

        #expect(outcome.metadataRead == 1, "the properties were read and are worth keeping")
        #expect(outcome.postersRecorded == 0)
        let stored = try #require(await fix.reader.item(id: photo.id))
        #expect(stored.stage == .metadata, "a row may not claim a preview the cache does not have")
        #expect(stored.error == .noThumbnail)
        #expect(stored.pixelSize?.width == 1280)
        #expect(try await fix.catalog.queuedWorkCount(sourceID: fix.sourceID) == 0)
    }

    @Test("A row that left the catalog while its work was queued is dropped quietly")
    func staleWork() async throws {
        let fix = try await WorkerFixture()
        defer { fix.tearDown() }
        let photo = try await fix.photo("IMG_deleted.jpg")
        try await fix.catalog.enqueuePendingWork(sourceID: fix.sourceID)
        try await fix.catalog.deleteMedia(ids: [photo.id])

        let worker = fix.worker(RecordingResolver([:]))
        let outcome = await worker.drain()

        #expect(outcome.stale == 1)
        #expect(outcome.metadataRead == 0 && outcome.failures == 0)
        #expect(try await fix.catalog.queuedWorkCount(sourceID: fix.sourceID) == 0)
    }
}

@Suite("What pass B reports")
struct MetadataWorkerProgressTests {
    @Test("Progress is the catalog's own count, not this worker's memory")
    func progressTracksTheCatalog() async throws {
        let fix = try await WorkerFixture()
        defer { fix.tearDown() }
        var items: [MediaItem] = []
        for index in 0..<2 {
            items.append(try await fix.photo("IMG_\(index).jpg"))
        }
        try await fix.catalog.enqueuePendingWork(sourceID: fix.sourceID)

        let worker = fix.worker(RecordingResolver(fix.targets(of: items)))
        let feed = await worker.progressFeed()
        let sourceID = fix.sourceID
        // The coalescer always delivers the newest value, so the last event is the one the run ended on.
        let collector = Task { () -> IndexProgress in
            var last = IndexProgress(sourceID: sourceID, phase: .resolving)
            for await entry in feed {
                last = entry
                if entry.phase == .finished { break }
            }
            return last
        }
        let outcome = await worker.drain()
        #expect(outcome.hops == 1)

        let reported = await collector.value
        #expect(reported.sourceID == fix.sourceID)
        #expect(reported.discovered == 2)
        #expect(reported.thumbnailed == 2)
        #expect(reported.metadataDone == 2)
        #expect(reported.queued == 0)
        #expect(reported.phase == .finished)
        #expect(reported.passBFraction == 1)

        // A HUD that asks after the fact gets the same numbers out of the database.
        let remembered = await worker.latestProgress(sourceID: fix.sourceID)
        #expect(remembered.first?.thumbnailed == 2)
        #expect(remembered.first?.phase == .finished)
    }

    @Test("A run that ends on a badged file reports it as a problem",
          .enabled(if: FixtureTree.canDenyAccess))
    func progressCountsProblems() async throws {
        let fix = try await WorkerFixture()
        defer { fix.tearDown() }
        let cache = fix.library.cacheRoot
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        defer { chmod(cache.path, 0o755) }
        chmod(cache.path, 0o000)

        let photo = try await fix.photo("IMG_bad.jpg")
        try await fix.catalog.enqueuePendingWork(sourceID: fix.sourceID)
        let worker = fix.worker(RecordingResolver([photo.id: fix.target(photo)]))
        _ = await worker.drain()

        let reported = await worker.latestProgress(sourceID: fix.sourceID)
        #expect(reported.first?.failed == 1)
        #expect(reported.first?.thumbnailed == 0)
        #expect(reported.first?.phase == .finished)
    }
}
