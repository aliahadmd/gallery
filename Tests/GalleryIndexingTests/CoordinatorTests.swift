import Testing
import Foundation
import GalleryDomain
import GalleryCatalog
import GallerySupport
@testable import GalleryIndexing

/// One coordinator over one catalog over one fixture tree, with its own bookmark suite so a test cannot
/// read a source registered by the last one.
struct CoordinatorFixture {
    let directory: URL
    let catalog: Catalog
    let reader: CatalogReader
    let bookmarks: BookmarkStore
    let coordinator: IndexCoordinator
    private let suite: String

    init(configuration: IndexCoordinator.Configuration = Configuration()) async throws {
        suite = "gallery.indexing.tests.\(UUID().uuidString)"
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("gallery-coordinator-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let database = directory.appendingPathComponent("catalog.db")
        catalog = try Catalog.open(at: database)
        reader = try CatalogReader.open(at: database)
        bookmarks = BookmarkStore(defaults: try #require(UserDefaults(suiteName: suite)))
        coordinator = IndexCoordinator(catalog: catalog, reader: reader, bookmarks: bookmarks,
                                      configuration: configuration)
    }

    /// The catalog keeps `-wal` and `-shm` beside the database, and a UserDefaults suite keeps a plist, so
    /// cleanup is two things rather than one.
    func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        UserDefaults.standard.removePersistentDomain(forName: suite)
    }

    func rows(_ sourceID: SourceID) async throws -> [MediaItem] {
        try await reader.page(album: .folder(sourceID), limit: 500).items
    }

    func paths(_ sourceID: SourceID) async throws -> Set<String> {
        Set(try await rows(sourceID).map(\.relativePath))
    }
}

private typealias Configuration = IndexCoordinator.Configuration

/// Pass A end to end: a picked folder becomes rows the grid can page through, and a rescan of the same
/// folder keeps the rows it still has evidence for.
@Suite("From a picked folder to a browsable grid")
struct CoordinatorTests {
    @Test("A scan writes every media file as a readable stub row")
    func firstScanPaints() async throws {
        let library = try await CoordinatorFixture()
        defer { library.tearDown() }
        let tree = try FixtureTree()
        defer { tree.cleanup() }
        try tree.file("IMG_1.jpg")
        try tree.file("holiday/IMG_2.heic")
        try tree.file("holiday/IMG_2.MOV")
        try tree.file("notes.txt")

        let source = try await library.coordinator.addFolder(tree.root, scanning: false)
        let outcome = await library.coordinator.scan(source.id)

        #expect(outcome.failure == nil, "\(outcome.failure ?? "")")
        #expect(outcome.discovered == 3)
        #expect(outcome.written == 3, "the grid can only show what the catalog accepted")
        let listed = try await library.paths(source.id)
        #expect(listed == ["IMG_1.jpg", "holiday/IMG_2.heic", "holiday/IMG_2.MOV"])

        let items = try await library.rows(source.id)
        #expect(items.allSatisfy { $0.stage == .classified }, "pass A stops at the stub row")
        #expect(items.allSatisfy { $0.error == .none })
        #expect(items.allSatisfy { $0.capture == nil }, "no capture date exists until pass B reads one")
        #expect(items.contains { $0.subtype.contains(.livePhotoCompanion) })
    }

    @Test("The queue for pass B is filled by the same scan that painted the grid")
    func queuesDeferredWork() async throws {
        let library = try await CoordinatorFixture()
        defer { library.tearDown() }
        let tree = try FixtureTree()
        defer { tree.cleanup() }
        try tree.file("IMG_1.jpg")
        try tree.file("IMG_2.jpg")

        let source = try await library.coordinator.addFolder(tree.root, scanning: false)
        _ = await library.coordinator.scan(source.id)

        let queued = try await library.catalog.queuedWorkCount(sourceID: source.id)
        #expect(queued == 2, "every stub row is pass B work")
        let refreshed = try #require(await library.reader.source(id: source.id))
        #expect(refreshed.lastScan != nil)
        #expect(refreshed.bookmarkState == .ok)
    }

    @Test("A file deleted between scans retires exactly its own row")
    func rescanRetires() async throws {
        let library = try await CoordinatorFixture()
        defer { library.tearDown() }
        let tree = try FixtureTree()
        defer { tree.cleanup() }
        try tree.file("keep.jpg")
        try tree.file("gone.jpg")

        let source = try await library.coordinator.addFolder(tree.root, scanning: false)
        _ = await library.coordinator.scan(source.id)
        try tree.remove("gone.jpg")

        let outcome = await library.coordinator.scan(source.id)
        #expect(outcome.retired == 1)
        let listed = try await library.paths(source.id)
        #expect(listed == ["keep.jpg"])
    }

    @Test("A renamed file keeps its row, its id and its favorite")
    func renameKeepsTheRow() async throws {
        let library = try await CoordinatorFixture()
        defer { library.tearDown() }
        let tree = try FixtureTree()
        defer { tree.cleanup() }
        let original = try tree.file("IMG_1.jpg")

        let source = try await library.coordinator.addFolder(tree.root, scanning: false)
        _ = await library.coordinator.scan(source.id)
        let before = try #require(await library.rows(source.id).first)
        try await library.catalog.setFavorite(before.id, true)

        try FileManager.default.moveItem(at: original, to: tree.url("IMG_100.jpg"))
        let outcome = await library.coordinator.scan(source.id)
        let after = try #require(await library.rows(source.id).first)

        #expect(outcome.retired == 0, "a rename is not a deletion")
        #expect(after.id == before.id, "favorites, thumbnails and cluster membership ride on the row")
        #expect(after.relativePath == "IMG_100.jpg")
        #expect(after.isFavorite, "the rename path has to preserve what the user marked")
    }

    @Test("A folder the walk could not read protects its rows",
          .enabled(if: FixtureTree.canDenyAccess))
    func refusedFolderProtectsRows() async throws {
        let library = try await CoordinatorFixture()
        defer { library.tearDown() }
        let tree = try FixtureTree()
        defer { tree.cleanup() }
        try tree.file("open/IMG_1.jpg")
        try tree.file("locked/IMG_2.jpg")

        let source = try await library.coordinator.addFolder(tree.root, scanning: false)
        _ = await library.coordinator.scan(source.id)
        try tree.makeUnreadable("locked")

        let outcome = await library.coordinator.scan(source.id)
        #expect(outcome.directoriesRefused == 1)
        #expect(outcome.retired == 0, "a permissions error must never look like a hundred deleted photos")
        let listed = try await library.paths(source.id)
        #expect(listed == ["open/IMG_1.jpg", "locked/IMG_2.jpg"])

        try tree.makeReadable("locked")
        try tree.remove("locked/IMG_2.jpg")
        let third = await library.coordinator.scan(source.id)
        #expect(third.retired == 1, "once it is readable again, the file really is gone")
    }

    @Test("A folder the system will not list is a failure, not an empty folder",
          .enabled(if: FixtureTree.canDenyAccess))
    func deniedRootIsNotAnEmptyFolder() async throws {
        let library = try await CoordinatorFixture()
        defer { library.tearDown() }
        let tree = try FixtureTree()
        defer { tree.cleanup() }
        try tree.file("IMG_1.jpg")
        let source = try await library.coordinator.addFolder(tree.root, scanning: false)
        _ = await library.coordinator.scan(source.id)
        try tree.makeUnreadable("")

        let outcome = await library.coordinator.scan(source.id)

        #expect(outcome.failure != nil, "an unlistable root is not a successful scan of zero files")
        #expect(outcome.written == 0)
        #expect(outcome.retired == 0, "rows behind a folder nobody could read are not deletions")
        #expect(try await library.paths(source.id) == ["IMG_1.jpg"], "nothing was touched")
        let state = try await library.reader.source(id: source.id)?.bookmarkState
        #expect(state == .needsUserPick, "the sidebar has to say why the folder went quiet")
    }

    @Test("Re-picking the same folder is a re-grant, not a second library")
    func repickIsIdempotent() async throws {
        let library = try await CoordinatorFixture()
        defer { library.tearDown() }
        let tree = try FixtureTree()
        defer { tree.cleanup() }
        try tree.file("IMG_1.jpg")

        let first = try await library.coordinator.addFolder(tree.root, scanning: false)
        _ = await library.coordinator.scan(first.id)
        let second = try await library.coordinator.addFolder(tree.root, scanning: false)

        #expect(second.id == first.id)
        let sources = try await library.catalog.sources()
        #expect(sources.count == 1)
        let listed = try await library.paths(second.id)
        #expect(listed == ["IMG_1.jpg"], "the rows stay exactly where they are")
    }

    @Test("The Trash is not a folder the user can add")
    func refusesTrash() async throws {
        let library = try await CoordinatorFixture()
        defer { library.tearDown() }
        let trash = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent(".Trash", isDirectory: true)

        await #expect(throws: IndexingError.self) {
            _ = try await library.coordinator.addFolder(trash, scanning: false)
        }
        let sources = try await library.catalog.sources()
        #expect(sources.isEmpty, "refusing the pick must also not leave a source behind")
    }

    @Test("A folder that no longer exists comes back needing a pick, not missing")
    func resolveAfterFolderDeleted() async throws {
        let library = try await CoordinatorFixture()
        defer { library.tearDown() }
        let tree = try FixtureTree()
        try tree.file("IMG_1.jpg")

        let source = try await library.coordinator.addFolder(tree.root, scanning: false)
        _ = await library.coordinator.scan(source.id)
        tree.cleanup()

        let resolved = try await library.coordinator.resolveSources()
        let refreshed = try #require(resolved.first)
        #expect(refreshed.bookmarkState == .needsUserPick,
                "the drive is connected; it is the folder that is gone")
        #expect(refreshed.bookmarkState.blocksScanning)
        let listed = try await library.paths(source.id)
        #expect(listed == ["IMG_1.jpg"], "a catalog the user can still browse beats an empty window")
    }

    @Test("Removing a source takes its rows and its bookmark with it")
    func removeSource() async throws {
        let library = try await CoordinatorFixture()
        defer { library.tearDown() }
        let tree = try FixtureTree()
        defer { tree.cleanup() }
        try tree.file("IMG_1.jpg")

        let source = try await library.coordinator.addFolder(tree.root, scanning: false)
        _ = await library.coordinator.scan(source.id)
        try await library.coordinator.removeSource(source.id)

        let sources = try await library.catalog.sources()
        #expect(sources.isEmpty)
        let rows = try await library.rows(source.id)
        #expect(rows.isEmpty)
        #expect(library.bookmarks.storedKeys.isEmpty)
    }

    @Test("Progress reports a growing count and a terminal phase")
    func progressReachesAListener() async throws {
        // Small batches so the walk of twelve files produces several publishes rather than one.
        let library = try await CoordinatorFixture(configuration: Configuration(batchRows: 2,
                                                                        batchInterval: .milliseconds(20)))
        defer { library.tearDown() }
        let tree = try FixtureTree()
        defer { tree.cleanup() }
        for index in 0..<12 { try tree.file("sub/IMG_\(index).jpg") }

        let source = try await library.coordinator.addFolder(tree.root, scanning: false)
        let feed = await library.coordinator.progressFeed()
        let collector = Task {
            var phases: [IndexPhase] = []
            var counts: [Int] = []
            for await progress in feed where progress.sourceID == source.id {
                phases.append(progress.phase)
                counts.append(progress.discovered)
                if progress.phase == .finished || progress.phase == .failed { break }
            }
            return (phases, counts)
        }
        let outcome = await library.coordinator.scan(source.id)
        let (phases, counts) = await collector.value

        #expect(outcome.failure == nil)
        #expect(phases.last == .finished)
        #expect(!phases.isEmpty, "a subscriber that joined before the scan finished must see it end")
        #expect(counts.isNonDecreasing, "a HUD that goes backwards reads as a bug even when it is a race")
        #expect(counts.last == outcome.written, "the coalescer must not drop the final update")
    }

    @Test("A scan of a folder nobody picked reports why instead of hanging")
    func unknownSource() async throws {
        let library = try await CoordinatorFixture()
        defer { library.tearDown() }
        let outcome = await library.coordinator.scan(SourceID(rawValue: 9_999))
        #expect(outcome.failure != nil)
        #expect(outcome.written == 0)
    }

    @Test("Two scans of one folder do not both write")
    func oneJobPerSource() async throws {
        let library = try await CoordinatorFixture()
        defer { library.tearDown() }
        let tree = try FixtureTree()
        defer { tree.cleanup() }
        for index in 0..<300 { try tree.file("IMG_\(index).jpg") }

        let source = try await library.coordinator.addFolder(tree.root, scanning: false)
        await library.coordinator.startScan(source.id)
        let second = await library.coordinator.scan(source.id)
        await library.coordinator.cancelScan(source.id)

        #expect(second.failure != nil, "a second scan of the same folder is refused, not queued")
        #expect(second.written == 0, "the refused scan must not have touched the catalog")
    }

    @Test("A file dropped into a watched folder reaches the catalog without a manual rescan")
    func watcherRescansOnChange() async throws {
        let library = try await CoordinatorFixture(
            configuration: Configuration(watchLatency: 0.1, watchDebounce: .milliseconds(200))
        )
        defer { library.tearDown() }
        let tree = try FixtureTree()
        defer { tree.cleanup() }
        try tree.file("first.jpg")

        let source = try await library.coordinator.addFolder(tree.root, scanning: false)
        _ = await library.coordinator.scan(source.id)
        #expect(try await library.reader.count(album: .folder(source.id)) == 1)
        await library.coordinator.startWatching(source.id)

        try tree.file("dropped.jpg")

        let clock = SuspendingClock()
        let deadline = clock.now.advanced(by: .seconds(15))
        var count = 0
        while clock.now < deadline {
            count = (try? await library.reader.count(album: .folder(source.id))) ?? 0
            if count == 2 { break }
            try await clock.sleep(for: .milliseconds(100))
        }
        await library.coordinator.stopAllWatching()

        #expect(count == 2, "the watcher's rescan has to find the new file")
    }
}

private extension Sequence where Element == Int {
    var isNonDecreasing: Bool {
        var previous: Int?
        for value in self {
            if let previous, value < previous { return false }
            previous = value
        }
        return true
    }
}
