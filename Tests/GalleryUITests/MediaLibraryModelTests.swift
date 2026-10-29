import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import GalleryUI
import GalleryCatalog
import GalleryDomain
import GalleryImaging
import GalleryIndexing
import GallerySupport

/// A model wired the way the app wires it — real catalog, real coordinator, real bookmark store — over a
/// small tree of stub files. Everything the grid draws is a function of this type, so paging, album
/// switching and the relaunch path can be proven without a window.
@MainActor
final class Fixture {
    /// A second coordinator and model over the same database and preferences — what a relaunch is. The
    /// coordinator travels with the model because waiting for its scan means asking that one.
    struct Relaunch {
        let model: MediaLibraryModel
        let coordinator: IndexCoordinator
    }

    let directory: URL
    let media: URL
    let catalog: Catalog
    let reader: CatalogReader
    let coordinator: IndexCoordinator
    let model: MediaLibraryModel
    let suiteName: String
    let defaults: UserDefaults
    /// Every drain this fixture started, so teardown can stop all of them before the tree goes away: two
    /// workers over one queue would each claim half a hop, and a hop that outlives its database is a write
    /// against a closed connection.
    private var drains: [MetadataWorker] = []

    init(files: Int = 3) async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("gallery-ui-\(UUID().uuidString)")
        directory = home
        media = home.appendingPathComponent("Library", isDirectory: true)
        let nested = media.appendingPathComponent("IMG", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        for index in 0..<files {
            // Every fifth file is a clip, and in a subdirectory, so both the type albums and the recursive
            // folder predicate have something real to answer with.
            let url = index % 5 == 0
                ? nested.appendingPathComponent("clip_\(index).mov")
                : media.appendingPathComponent("photo_\(index).jpg")
            try Data([0xFF, 0xD8]).write(to: url)
        }

        let database = home.appendingPathComponent("catalog.db")
        catalog = try Catalog.open(at: database)
        reader = try CatalogReader.open(at: database)
        suiteName = "gallery-ui-tests.\(UUID().uuidString)"
        defaults = try #require(UserDefaults(suiteName: suiteName))
        let bookmarks = BookmarkStore(defaults: defaults)
        let walk = IndexCoordinator(catalog: catalog, reader: reader, bookmarks: bookmarks)
        let pipeline = Self.pipeline(under: home, catalog: catalog, reader: reader, bookmarks: bookmarks)
        coordinator = walk
        model = MediaLibraryModel(reader: reader, coordinator: walk, passB: pipeline.worker,
                                  thumbnails: pipeline.thumbnails, catalog: catalog)
        drains.append(pipeline.worker)
    }

    /// Pass B and the cache it writes through, built the way the app builds them: the walk's bookmarks, a
    /// thumbnail cache inside the fixture's own directory, and the same reader the grid pages through.
    private static func pipeline(under home: URL, catalog: Catalog, reader: CatalogReader,
                                 bookmarks: BookmarkStore) -> (worker: MetadataWorker,
                                                               thumbnails: ThumbnailService) {
        let cache = home.appendingPathComponent("thumbs", isDirectory: true)
        let store = ThumbnailStore(layout: ThumbnailLayout(root: cache),
                                   byteLimit: ThumbnailStore.byteLimit(for: cache))
        let resolver = CatalogMediaResolver(reader: reader, bookmarks: bookmarks)
        let thumbnails = ThumbnailService(catalog: catalog, store: store, resolver: resolver)
        return (MetadataWorker(catalog: catalog, reader: reader, resolver: resolver,
                               thumbnails: thumbnails), thumbnails)
    }

    func relaunched() async throws -> Relaunch {
        let database = directory.appendingPathComponent("catalog.db")
        let bookmarks = BookmarkStore(defaults: defaults)
        let secondCatalog = try Catalog.open(at: database)
        let secondReader = try CatalogReader.open(at: database)
        let second = IndexCoordinator(catalog: secondCatalog, reader: secondReader, bookmarks: bookmarks)
        let pipeline = Self.pipeline(under: directory, catalog: secondCatalog, reader: secondReader,
                                     bookmarks: bookmarks)
        drains.append(pipeline.worker)
        return Relaunch(model: MediaLibraryModel(reader: secondReader, coordinator: second,
                                                 passB: pipeline.worker, thumbnails: pipeline.thumbnails,
                                                 catalog: secondCatalog),
                        coordinator: second)
    }

    /// A decodable picture inside the folder the test is about to add. The stub files prove paging and
    /// counting; only a real JPEG can prove that a drain left the grid something to draw.
    func writeJPEG(named name: String, width: Int = 640, height: Int = 480) throws {
        let url = media.appendingPathComponent(name)
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                             bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.4, green: 0.5, blue: 0.6, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let picture = try #require(context.makeImage())
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL,
                                                                       UTType.jpeg.identifier as CFString,
                                                                       1, nil))
        CGImageDestinationAddImage(destination, picture, nil)
        try #require(CGImageDestinationFinalize(destination), "the test could not write a JPEG")
    }

    func tearDown() async {
        model.stop()
        for worker in drains { await worker.cancel() }
        try? FileManager.default.removeItem(at: directory)
        defaults.removePersistentDomain(forName: suiteName)
    }

    /// Waits for the signal the HUD waits for: the coordinator has released the job, which is the only
    /// public proof a fire-and-forget scan is over.
    func waitUntilIdle(_ coordinator: IndexCoordinator, timeout: Duration = .seconds(30)) async throws {
        let clock = SuspendingClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if await coordinator.scanningSources().isEmpty { return }
            try await clock.sleep(for: .milliseconds(5))
        }
        Issue.record("the scan never finished")
    }

    /// Poll for state the progress feed writes on its own task. The finished frame reaches the model through
    /// a 100 ms coalescer, so the rows the grid shows land a beat after the walk ends — which is exactly the
    /// ordering a test must not assume away.
    func waitUntil(_ condition: @MainActor () -> Bool, timeout: Duration = .seconds(30)) async throws {
        let clock = SuspendingClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if condition() { return }
            try await clock.sleep(for: .milliseconds(5))
        }
        Issue.record("the model never reached the state the test asked for")
    }

    /// The refresh a running feed would have done by itself. Tests that never call `start()` have no
    /// subscriber, so they ask for the same two hops the finished frame triggers.
    func settle() async throws {
        try await waitUntilIdle(coordinator)
        await model.refreshSources()
        await model.reload()
    }

    /// Poll the queue's own claim order until that row is what comes out first. `claimWork` is the only
    /// public answer to "what would pass B read next", and asking it is a real hop rather than a guess about
    /// how long the model's window debounce takes.
    func waitUntilFirstToClaim(_ mediaID: MediaID, timeout: Duration = .seconds(10)) async throws {
        let clock = SuspendingClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if try await catalog.claimWork(limit: 1).first?.mediaID == mediaID { return }
            try await clock.sleep(for: .milliseconds(20))
        }
        Issue.record("the cell that came into view never reached the front of the queue")
    }
}

@Suite("Library view model")
@MainActor struct MediaLibraryModelTests {
    @Test("Adding a folder selects it and fills the grid")
    func addFillsTheGrid() async throws {
        let fixture = try await Fixture(files: 12)
        defer { await fixture.tearDown() }
        await fixture.model.add([fixture.media])
        try await fixture.settle()

        let source = try #require(fixture.model.sources.first)
        #expect(fixture.model.sources.count == 1)
        #expect(fixture.model.selection == .folder(source.id))
        #expect(fixture.model.rowCount == 12)
        #expect(fixture.model.items.count == 12)
        #expect(fixture.model.hasMorePages == false)
        #expect(fixture.model.notices.isEmpty)
    }

    @Test("A page is 200 rows and loadMore appends until the album runs out")
    func paging() async throws {
        let fixture = try await Fixture(files: 450)
        defer { await fixture.tearDown() }
        await fixture.model.add([fixture.media])
        try await fixture.settle()

        #expect(fixture.model.items.count == 200)
        #expect(fixture.model.hasMorePages)

        await fixture.model.loadMore()
        #expect(fixture.model.items.count == 400)

        await fixture.model.loadMore()
        #expect(fixture.model.items.count == 450)
        #expect(fixture.model.hasMorePages == false)

        // Past the end, another request is a no-op rather than a repeat of the last page.
        let ids = fixture.model.items.map(\.id)
        await fixture.model.loadMore()
        #expect(fixture.model.items.map(\.id) == ids)
    }

    @Test("A sort change restarts the cursor instead of seeking into a dead ordering")
    func sortingRepages() async throws {
        let fixture = try await Fixture(files: 260)
        defer { await fixture.tearDown() }
        await fixture.model.add([fixture.media])
        try await fixture.settle()
        #expect(fixture.model.items.count == 200)

        fixture.model.sort = MediaSort(field: .fileName, order: .ascending)
        await fixture.model.reload()
        let names = fixture.model.items.map(\.name)
        #expect(names == names.sorted())
        #expect(fixture.model.items.count == 200)

        await fixture.model.loadMore()
        #expect(fixture.model.items.count == 260)
        #expect(Set(fixture.model.items.map(\.id)).count == 260)
    }

    @Test("Switching albums replaces the page rather than appending to it")
    func switchingAlbums() async throws {
        let fixture = try await Fixture(files: 30)
        defer { await fixture.tearDown() }
        await fixture.model.add([fixture.media])
        try await fixture.settle()
        #expect(fixture.model.items.count == 30)

        await fixture.model.select(.allVideos)
        #expect(fixture.model.items.count == 6)
        #expect(fixture.model.items.allSatisfy { $0.kind == .video })
        #expect(fixture.model.rowCount == 6)
    }

    @Test("The last progress frame reaches the model, and a finished scan needs no HUD")
    func progressSettlesWhenDone() async throws {
        let fixture = try await Fixture(files: 4)
        defer { await fixture.tearDown() }
        #expect(fixture.model.activeProgress == nil)

        // The feed only exists once the window's task has started the model, which is what this test is about.
        await fixture.model.start()
        await fixture.model.add([fixture.media])
        try await fixture.waitUntilIdle(fixture.coordinator)
        try await fixture.waitUntil { fixture.model.activeProgress?.phase == .finished }
        try await fixture.waitUntil { fixture.model.rowCount == 4 }

        let progress = try #require(fixture.model.activeProgress)
        #expect(progress.phase.isCounting == false)
        fixture.model.stop()
    }

    @Test("A half-listed scan is reported as counting, which is what keeps the HUD up")
    func progressCountsWhileListing() async throws {
        let fixture = try await Fixture(files: 400)
        defer { await fixture.tearDown() }
        await fixture.model.start()
        await fixture.model.add([fixture.media])
        try await fixture.waitUntil { fixture.model.activeProgress?.phase.isCounting == true }
        #expect(fixture.model.activeProgress?.phase.isCounting == true)

        try await fixture.waitUntilIdle(fixture.coordinator)
        try await fixture.waitUntil { fixture.model.activeProgress?.phase == .finished }
        fixture.model.stop()
    }

    @Test("Removing a folder drops its rows and leaves the library browsable")
    func removeSource() async throws {
        let fixture = try await Fixture(files: 6)
        defer { await fixture.tearDown() }
        await fixture.model.add([fixture.media])
        try await fixture.settle()
        let source = try #require(fixture.model.sources.first)

        await fixture.model.remove(source)
        #expect(fixture.model.sources.isEmpty)
        #expect(fixture.model.selection == .all)
        #expect(fixture.model.items.isEmpty)
        #expect(fixture.model.notices.isEmpty)
    }

    @Test("A refused folder is a notice, not a source")
    func trashIsRefused() async throws {
        let fixture = try await Fixture(files: 2)
        defer { await fixture.tearDown() }
        let trash = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".Trash", isDirectory: true)

        await fixture.model.add([trash])

        #expect(fixture.model.sources.isEmpty)
        let notice = try #require(fixture.model.notices.first)
        #expect(notice.text.contains("Could not add"))
        fixture.model.dismissNotice()
        #expect(fixture.model.notices.isEmpty)
    }

    @Test("Relaunching resolves the stored folder and its rows, with no picker")
    func relaunchResumesWithoutPicking() async throws {
        let fixture = try await Fixture(files: 5)
        defer { await fixture.tearDown() }
        await fixture.model.add([fixture.media])
        try await fixture.settle()
        fixture.model.stop()

        let second = try await fixture.relaunched()
        await second.model.start()
        try await fixture.waitUntilIdle(second.coordinator)
        try await fixture.waitUntil {
            second.model.rowCount == 5 && second.model.items.count == 5
                && second.model.sources.first?.bookmarkState == .ok
        }

        #expect(second.model.sources.count == 1)
        #expect(second.model.sources[0].bookmarkState == .ok)
        #expect(second.model.rowCount == 5)
        #expect(second.model.items.count == 5)
        second.model.stop()
    }

    @Test("A folder that is gone asks the user to pick it again and keeps its rows")
    func deletedFolderStillBrowses() async throws {
        let fixture = try await Fixture(files: 7)
        defer { await fixture.tearDown() }
        await fixture.model.add([fixture.media])
        try await fixture.settle()
        fixture.model.stop()
        try FileManager.default.removeItem(at: fixture.media)

        let second = try await fixture.relaunched()
        await second.model.start()
        try await fixture.waitUntilIdle(second.coordinator)

        let source = try #require(second.model.sources.first)
        #expect(source.bookmarkState == .needsUserPick)
        #expect(second.model.rowCount == 7)
        second.model.stop()
    }

    @Test("The model runs the drain itself, and what it learned reaches the page the grid is showing")
    func previewsLandThroughTheModel() async throws {
        let fixture = try await Fixture(files: 0)
        defer { await fixture.tearDown() }
        try fixture.writeJPEG(named: "IMG_1.jpg")

        // Started first, because this is the wiring under test: nothing but the model can wake the drain here.
        await fixture.model.start()
        await fixture.model.add([fixture.media])
        let sourceID = try #require(fixture.model.sources.first).id
        try await fixture.waitUntilIdle(fixture.coordinator)
        // Poll for what the drain changes in the page rather than for the frame that triggers the re-read:
        // the reload is one hop behind the snapshot, and a grid inspected before it lands is a flake.
        try await fixture.waitUntil { fixture.model.items.first?.pixelSize != nil }
        try await fixture.waitUntil { fixture.model.previews[sourceID]?.phase == .finished }

        let preview = try #require(fixture.model.previews[sourceID])
        #expect(preview.thumbnailed == 1 && preview.queued == 0)
        #expect(preview.discovered == 1)
        #expect(fixture.model.activeProgress?.phase.isCounting == false,
                "with both passes done there is nothing left for a HUD to claim")
        // Pass A only ever statued this file, so a page that carries its dimensions is a page the model
        // re-read after the drain said it was done.
        let row = try #require(fixture.model.items.first)
        #expect(row.stage == .thumbnailed)
        #expect(row.pixelSize == PixelSize(width: 640, height: 480))
        // The cell's own question, answered from the cache the drain filled — which is what a tile on screen
        // ten minutes later costs nothing to draw.
        #expect(await fixture.model.preview(for: row) != nil)
        fixture.model.stop()
    }

    @Test("A cell that scrolls into view is the next row the drain reads")
    func viewportJumpsTheQueueThroughTheModel() async throws {
        let fixture = try await Fixture(files: 6)
        defer { await fixture.tearDown() }
        await fixture.model.add([fixture.media])
        try await fixture.settle()
        #expect(fixture.model.items.count == 6)

        // The last tile, so the queue's own order (newest day first) is guaranteed to disagree with it.
        let shown = try #require(fixture.model.items.last)
        fixture.model.cellAppeared(shown)
        try await fixture.waitUntilFirstToClaim(shown.id)

        fixture.model.cellDisappeared(shown)
        #expect(fixture.model.items.count == 6, "leaving a tile does not take the row out of the album")
    }

    @Test("Opening a photo shows it, and the arrows walk the page without wrapping")
    func viewerStepsThroughThePage() async throws {
        let fixture = try await Fixture(files: 5)
        defer { await fixture.tearDown() }
        await fixture.model.add([fixture.media])
        try await fixture.settle()

        let items = fixture.model.items
        #expect(items.count == 5)
        fixture.model.openViewer(items[0].id)

        #expect(fixture.model.viewerItem?.id == items[0].id)
        #expect(fixture.model.selectedID == items[0].id, "the inspector follows the viewer")

        await fixture.model.stepViewer(by: 1)
        #expect(fixture.model.viewerItem?.id == items[1].id)

        await fixture.model.stepViewer(by: -1)
        #expect(fixture.model.viewerItem?.id == items[0].id)

        // The first photo is the first photo: stepping back again is a no-op, not a jump to the end.
        await fixture.model.stepViewer(by: -1)
        #expect(fixture.model.viewerItem?.id == items[0].id)

        fixture.model.closeViewer()
        #expect(fixture.model.viewerItem == nil)
        #expect(fixture.model.selectedItem?.id == items[0].id, "closing leaves the inspector where it was")
    }

    @Test("Stepping past the last loaded photo pulls the next page")
    func viewerCrossesThePageBoundary() async throws {
        let fixture = try await Fixture(files: 260)
        defer { await fixture.tearDown() }
        await fixture.model.add([fixture.media])
        try await fixture.settle()
        #expect(fixture.model.items.count == 200)
        #expect(fixture.model.hasMorePages)

        fixture.model.openViewer(fixture.model.items[199].id)
        await fixture.model.stepViewer(by: 1)

        #expect(fixture.model.items.count == 260, "the page behind the edge was fetched")
        #expect(fixture.model.viewerItem?.id == fixture.model.items[200].id)
    }

    @Test("The viewer decodes the photo, not the grid tile")
    func viewerDrawsTheFullPhoto() async throws {
        let fixture = try await Fixture(files: 0)
        defer { await fixture.tearDown() }
        try fixture.writeJPEG(named: "IMG_big.jpg", width: 1280, height: 960)
        await fixture.model.add([fixture.media])
        try await fixture.settle()

        let item = try #require(fixture.model.items.first)
        fixture.model.openViewer(item.id)
        let image = try #require(await fixture.model.viewerImage(for: item))

        #expect(image.width > 320, "a cell's 320 px tile is not what fills the window")
        #expect(abs(Double(image.width) / Double(image.height) - 4.0 / 3.0) < 0.02)
    }

    @Test("Favoriting is a catalog fact, not a star drawn on one cell")
    func favoriteIsPersisted() async throws {
        let fixture = try await Fixture(files: 3)
        defer { await fixture.tearDown() }
        await fixture.model.add([fixture.media])
        try await fixture.settle()
        let item = try #require(fixture.model.items.first)
        #expect(item.isFavorite == false)

        await fixture.model.toggleFavorite(item.id)
        #expect(fixture.model.items.first(where: { $0.id == item.id })?.isFavorite == true)
        #expect(try await fixture.reader.item(id: item.id)?.isFavorite == true, "the next launch has to know")
        #expect(try await fixture.reader.count(album: .favorites) == 1)

        await fixture.model.toggleFavorite(item.id)
        #expect(try await fixture.reader.item(id: item.id)?.isFavorite == false)
        #expect(try await fixture.reader.count(album: .favorites) == 0)
    }
}
