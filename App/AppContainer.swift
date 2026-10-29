import Foundation
import GalleryCatalog
import GalleryImaging
import GalleryIndexing
import GallerySupport
import GalleryUI

/// Composition root: one catalog, one read-only connection, one bookmark store, one of each indexing pass.
///
/// The database lives in the sandbox's own Application Support, so a second Gallery process shares it
/// through WAL instead of forking a divergent copy of the library.
@MainActor
final class AppContainer {
    let model: MediaLibraryModel?
    let startupFailure: String?

    init() {
        do {
            let url = try Self.databaseURL()
            let catalog = try Catalog.open(at: url)
            let reader = try CatalogReader.open(at: url)

            // One bookmark store for both passes: pass A rebinds folder roots and pass B rebinds file paths,
            // and a grant that resolves for one of them resolves for the other.
            let bookmarks = BookmarkStore()
            let coordinator = IndexCoordinator(catalog: catalog, reader: reader, bookmarks: bookmarks)

            let cache = try Self.cacheRoot()
            let store = ThumbnailStore(layout: ThumbnailLayout(root: cache),
                                       byteLimit: ThumbnailStore.byteLimit(for: cache))
            let resolver = CatalogMediaResolver(reader: reader, bookmarks: bookmarks)
            let thumbnails = ThumbnailService(catalog: catalog, store: store, resolver: resolver)
            let worker = MetadataWorker(catalog: catalog, reader: reader,
                                        resolver: resolver, thumbnails: thumbnails)

            model = MediaLibraryModel(reader: reader, coordinator: coordinator, passB: worker,
                                      thumbnails: thumbnails, catalog: catalog, resolver: resolver)
            startupFailure = nil
        } catch {
            model = nil
            startupFailure = error.localizedDescription
        }
    }

    /// Opened writer-first on purpose: `Catalog.open` is what creates the file and runs the migration
    /// ladder, and a read-only connection against a database that does not exist yet is not a library,
    /// it is an empty window.
    private static func databaseURL() throws -> URL {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                                    in: .userDomainMask).first else {
            throw StartupError.noApplicationSupport
        }
        return support
            .appendingPathComponent("Gallery", isDirectory: true)
            .appendingPathComponent("catalog.db")
    }

    /// The thumbnails go in Caches, not beside the catalog, because the distinction is recoverability: the
    /// database is the library's only copy of its own knowledge, and every byte of the cache can be re-decoded
    /// from the photos. Creating it here is what lets the budget read the volume's real free space.
    private static func cacheRoot() throws -> URL {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            throw StartupError.noCaches
        }
        let url = caches.appendingPathComponent("Gallery", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    enum StartupError: LocalizedError {
        case noApplicationSupport
        case noCaches

        var errorDescription: String? {
            switch self {
            case .noApplicationSupport:
                "Gallery has nowhere to keep its library. Check this Mac's home folder permissions."
            case .noCaches:
                "Gallery has nowhere to keep its previews. Check this Mac's home folder permissions."
            }
        }
    }
}
