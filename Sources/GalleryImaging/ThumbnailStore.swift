import Foundation
import GalleryDomain
import GallerySupport

/// The thumbnail cache on disk, and the budget it has to live inside.
///
/// Two things make this more than a directory of JPEGs. The first is the filename: it carries the source
/// file's modification stamp, so a photo edited outside the app is a cache miss without a single query
/// asking whether it changed. The second is the budget — a 100k library at 20 KB a thumbnail is 2 GB, and
/// a cache that grows until the disk complains is not a cache, it is a leak with a good excuse.
public struct ThumbnailStore: Sendable {
    public let layout: ThumbnailLayout
    /// The ceiling this cache is allowed to occupy, which `ThumbnailService` compares against the manifest so
    /// an eviction pass can decide *before* walking the tree.
    public let byteLimit: Int64
    private let budget: DiskBudget

    public init(layout: ThumbnailLayout, byteLimit: Int64) {
        self.layout = layout
        self.byteLimit = byteLimit
        self.budget = DiskBudget(directory: layout.root.appendingPathComponent("thumbs", isDirectory: true),
                                 byteLimit: byteLimit)
    }

    /// 4 GB, or 15% of what the volume has free, whichever is smaller — so a 256 GB Mac that is nearly full
    /// does not get a gallery that fills the last of it in the background.
    public static func byteLimit(for root: URL, cap: Int64 = 4 * 1024 * 1024 * 1024,
                                 freeFraction: Double = 0.15) -> Int64 {
        let free = (try? root.resourceValues(forKeys: [.volumeAvailableCapacityKey]))?
            .volumeAvailableCapacity.map(Int64.init)
        guard let free, free > 0 else { return cap }
        return min(cap, Int64(Double(free) * freeFraction))
    }

    public func load(mediaID: MediaID, bucket: ThumbnailBucket, mtime: Date?) -> Data? {
        try? Data(contentsOf: layout.url(mediaID: mediaID, bucket: bucket, mtime: mtime))
    }

    /// Written atomically because a cache torn by a crash at 3 a.m. is a photo that looks half-drawn for
    /// the rest of its life, and nothing ever re-checks it.
    @discardableResult
    public func save(_ data: Data, mediaID: MediaID, bucket: ThumbnailBucket, mtime: Date?) throws -> URL {
        let url = layout.url(mediaID: mediaID, bucket: bucket, mtime: mtime)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try data.write(to: url, options: [.atomic])
        return url
    }

    /// Every bucket and every stale stamp for one picture. Called when a media row is deleted; the shard it
    /// lists holds about 1/256th of the library, so this is a directory read and not a sweep.
    public func removeAll(mediaID: MediaID) {
        let prefix = "\(mediaID.rawValue)-"
        for bucket in ThumbnailBucket.allCases {
            let directory = layout.directory(bucket: bucket, mediaID: mediaID)
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else {
                continue
            }
            for name in names where name.hasPrefix(prefix) {
                try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
            }
        }
    }

    public func usedBytes() -> Int64 { budget.usedBytes() }

    /// LRU bookkeeping lives in the catalog's `thumbnail_cache` manifest, which is the only place that knows
    /// when a thumbnail was *displayed*; a file's own dates say when it was baked, which is not the same
    /// thing and would evict the picture the user keeps looking at.
    public func evict(untilUnderBudget: Bool = true,
                      lastUsed: @Sendable (URL) -> Date?) -> DiskBudget.EvictionReport {
        budget.evict(untilUnderBudget: untilUnderBudget, lastUsed: lastUsed)
    }
}
