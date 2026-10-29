import Foundation
import GalleryDomain
import GalleryCatalog
import GallerySupport

/// Where one media file lives: the picture itself, and the folder the sandbox grant covers.
///
/// Named for the file rather than for a thumbnail because both halves of the pipeline need it — the pixel
/// service to bake a preview, pass B to read metadata and poster out of the same URL — and a resolver per
/// consumer would mean two places that know how a stored relative path becomes a readable one.
public struct MediaTarget: Sendable, Hashable {
    public var url: URL
    /// Beginning security-scoped access is a per-*folder* operation — a token belongs to the directory the
    /// user picked, not to the JPEG inside it — so a decoder that wants to read the file needs the root too.
    /// Nil means "no grant to begin", which is the unsandboxed case and the one every unit test runs in.
    public var scopedRoot: URL?

    public init(url: URL, scopedRoot: URL? = nil) {
        self.url = url
        self.scopedRoot = scopedRoot
    }
}

/// The catalog's answer to "where is this file".
///
/// Batch-shaped on purpose: a window of two hundred cells is one query, not two hundred, and the pixel
/// service only asks when a thumbnail actually has to be baked — a memory or disk hit never comes here.
public protocol MediaResolving: Sendable {
    func targets(for ids: [MediaID]) async -> [MediaID: MediaTarget]
}

/// Paths out of the catalog, rebound through the bookmarks the app holds.
///
/// The root comes from the bookmark when there is one, because that is the spelling the sandbox granted; the
/// stored `root_path` is the fallback, which is right for an unsandboxed build and for a source whose bookmark
/// has not been resolved yet. Joining happens here and nowhere else, so a volume remounted at a different
/// mount point still finds its pictures.
public struct CatalogMediaResolver: MediaResolving {
    private let reader: CatalogReader
    private let bookmarks: BookmarkStore

    public init(reader: CatalogReader, bookmarks: BookmarkStore = BookmarkStore()) {
        self.reader = reader
        self.bookmarks = bookmarks
    }

    private struct Root {
        var url: URL
        var scoped: URL?
    }

    public func targets(for ids: [MediaID]) async -> [MediaID: MediaTarget] {
        guard !ids.isEmpty else { return [:] }
        let items = (try? await reader.items(ids: ids)) ?? []
        guard !items.isEmpty else { return [:] }

        var roots: [SourceID: Root] = [:]
        for source in ((try? await reader.sources()) ?? []) {
            let key = IndexCoordinator.bookmarkKey(volumeID: source.volumeID, path: source.rootPath)
            switch bookmarks.resolve(key) {
            case .valid(let url), .stale(let url):
                roots[source.id] = Root(url: url, scoped: url)
            case .missing, .failed:
                roots[source.id] = Root(url: source.rootURL, scoped: nil)
            }
        }

        var targets: [MediaID: MediaTarget] = [:]
        targets.reserveCapacity(items.count)
        for item in items {
            guard let root = roots[item.sourceID] else { continue }
            targets[item.id] = MediaTarget(url: item.url(resolvedAgainst: root.url),
                                           scopedRoot: root.scoped)
        }
        return targets
    }
}
