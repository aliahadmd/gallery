import Foundation
import GalleryDomain

/// Where a baked thumbnail lives on disk.
///
/// The filename carries the source file's modification stamp, so invalidation needs no bookkeeping: a new
/// mtime is a different name, and the old image simply stops being looked up and is evicted as cold.
public struct ThumbnailLayout: Sendable, Hashable {
    public let root: URL

    public init(root: URL) { self.root = root.standardizedFileURL }

    /// `thumbs/<bucket>/<hex2>` — the shard keeps a 600k-file cache out of one directory, where `readdir`
    /// and every eviction sweep would pay for it.
    public func directory(bucket: ThumbnailBucket, mediaID: MediaID) -> URL {
        root
            .appendingPathComponent("thumbs", isDirectory: true)
            .appendingPathComponent(String(bucket.longSide), isDirectory: true)
            .appendingPathComponent(Self.shard(mediaID))
    }

    public func url(mediaID: MediaID, bucket: ThumbnailBucket, mtime: Date?) -> URL {
        directory(bucket: bucket, mediaID: mediaID)
            .appendingPathComponent("\(mediaID.rawValue)-\(mtime?.nanoseconds ?? 0).jpg")
    }

    static func shard(_ mediaID: MediaID) -> String {
        String(format: "%02x", Int(truncatingIfNeeded: mediaID.rawValue & 0xFF))
    }
}
