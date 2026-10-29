import Foundation
import Testing
@testable import GalleryIndexing
import GalleryCatalog
import GalleryDomain

/// The ledger's filesystem half: a file moves into the app's trash, and the same grant that moved it in is
/// what moves it back.
@Suite("Trash")
struct TrashServiceTests {
    private func service(_ library: ServiceFixture) -> TrashService {
        TrashService(catalog: library.catalog,
                     resolver: CatalogMediaResolver(reader: library.reader, bookmarks: library.bookmarks),
                     root: library.directory.appendingPathComponent("trash", isDirectory: true))
    }

    @Test("Trashing moves the file, restoring brings it back")
    func roundTrip() async throws {
        let library = try await ServiceFixture()
        defer { library.tearDown() }
        let item = try await library.photo("IMG_1.jpg")
        let trash = service(library)
        let original = library.tree.url("IMG_1.jpg")

        let trashed = await trash.trash([item])
        #expect(trashed.trashed == [item.id])
        #expect(!FileManager.default.fileExists(atPath: original.path), "the file really left the folder")
        #expect(try await library.reader.count(album: .recentlyDeleted) == 1)
        #expect(try await library.reader.count(album: .all) == 0)

        let restored = await trash.restore([item])
        #expect(restored.restored == [item.id])
        #expect(FileManager.default.fileExists(atPath: original.path))
        #expect(try await library.reader.count(album: .all) == 1)
    }

    @Test("A restore refuses to overwrite a file that came back")
    func restoreRefusesToOverwrite() async throws {
        let library = try await ServiceFixture()
        defer { library.tearDown() }
        let item = try await library.photo("IMG_1.jpg")
        let trash = service(library)
        _ = await trash.trash([item])
        // Someone puts a new photo with the same name back into the folder.
        try Data([0xFF, 0xD8]).write(to: library.tree.url("IMG_1.jpg"))

        let restored = await trash.restore([item])
        #expect(restored.restored.isEmpty)
        #expect(restored.failed[item.id] != nil)
        #expect(try await library.reader.count(album: .recentlyDeleted) == 1, "still deleted, still recoverable")
    }

    @Test("Trash older than the cutoff is emptied and recorded as purged")
    func purgeExpired() async throws {
        let library = try await ServiceFixture()
        defer { library.tearDown() }
        let item = try await library.photo("IMG_1.jpg")
        let trash = service(library)
        _ = await trash.trash([item])
        #expect(try await library.reader.count(album: .recentlyDeleted) == 1)

        // A cutoff in the future stands in for "a month has passed" without moving the clock.
        let outcome = await trash.purgeExpired(olderThan: Date().addingTimeInterval(60))

        #expect(outcome.purged == [item.id])
        #expect(try await library.reader.count(album: .recentlyDeleted) == 0)
        let trashed = library.directory.appendingPathComponent("trash")
            .appendingPathComponent("\(item.sourceID.rawValue)/\(item.relativePath)")
        #expect(!FileManager.default.fileExists(atPath: trashed.path))
    }
}
