import Foundation

/// The only sizes a thumbnail is ever baked at.
///
/// A closed set rather than "whatever the cell measured": one file re-sized for every window width would
/// turn a 100k library into an unbounded cache. The grid asks for the longest side it needs in *pixels*
/// (points × backing scale) and gets the smallest bucket that covers it. In the domain rather than in the
/// imaging code because the catalog records it, the view asks for it, and the baker fills it — the bucket is
/// the agreement between them, not a detail of either.
public enum ThumbnailBucket: Int32, Sendable, Hashable, Comparable, CaseIterable {
    case list = 96
    case gridSmall = 160
    case gridLarge = 320
    case viewerHalf = 1024
    case viewerFull = 2048
    /// The ceiling on purpose: a 108 MP panorama decoded whole is ~430 MB, and the deep zoom that would
    /// need more than this is a `CATiledLayer` feature this build does not ship.
    case viewerMax = 4096

    /// The decoded image's longest side, in pixels. Also what the manifest's `bucket` column stores, so a
    /// bucket added later reads as a number rather than as an enum index that shifted.
    public var longSide: Int32 { rawValue }

    public static func < (lhs: ThumbnailBucket, rhs: ThumbnailBucket) -> Bool { lhs.rawValue < rhs.rawValue }

    /// The smallest bucket at or above `longSide`, or the biggest one when nothing reaches. Asking for 0 is
    /// a real case — a placeholder still has to land in a bucket rather than fail.
    public static func best(longSide: Int) -> ThumbnailBucket {
        allCases.first { $0.longSide >= max(1, longSide) } ?? .viewerMax
    }

    /// The bucket for a cell of `cellPoints` points on a display with `scale` pixels per point, rounded up
    /// so a Retina cell is never drawn from an image the size of its non-Retina twin.
    public static func best(cellPoints: Double, scale: CGFloat) -> ThumbnailBucket {
        best(longSide: Int((cellPoints * Double(scale)).rounded(.up)))
    }
}
