import Foundation
import AVFoundation
import CoreMedia
import ImageIO
import UniformTypeIdentifiers
import GalleryDomain

/// Bakes a thumbnail out of a still image without ever holding the full decode.
///
/// `CGImageSourceCreateThumbnailAtIndex` downsamples *during* the decode, which is the difference between
/// a 2 MB working set and a 150 MB one on a 48 MP HEIC; scaling a full `CGImage` afterwards is the single
/// easiest way to make this app jetsam. The blocking ImageIO call belongs on a dedicated queue, not the
/// cooperative pool — see `ThumbnailService`.
public enum ThumbnailBaker {
    /// JPEG bytes at `bucket` size, or nil when ImageIO cannot produce a picture from this file.
    ///
    /// Orientation is applied by ImageIO rather than by the caller (`WithTransform`), and the built-in
    /// Exif thumbnail is deliberately ignored (`FromImageAlways`): a camera's embedded preview is usually
    /// smaller than the grid cell it would fill, and whether it was written pre-rotated varies by vendor.
    /// One honest decode costs a few hundred microseconds and cannot be wrong.
    public static func bake(url: URL, bucket: ThumbnailBucket) -> Data? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options) else { return nil }
        guard let image = thumbnail(source, bucket) else { return nil }
        return jpeg(image)
    }

    /// The longest decoded side, in pixels — which is what makes a RAW file with no readable header come
    /// back as nil instead of a silently oversized bitmap.
    static func thumbnail(_ source: CGImageSource, _ bucket: ThumbnailBucket) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceThumbnailMaxPixelSize: bucket.longSide,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// A 320 px JPEG at this quality is 15–25 KB. Going lower trades banding in the grid — the one place
    /// every photo of the user's life is visible at once — for bytes that the 4 GB budget already allows.
    static func jpeg(_ image: CGImage, quality: Double = 0.82) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, UTType.jpeg.identifier as CFString, 1, nil
        ) else { return nil }
        CGImageDestinationAddImage(destination, image,
                                   [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    /// Reads baked bytes back as a bitmap. `ShouldCache` is on here because the caller draws the result
    /// immediately and ImageIO would otherwise re-decode the same small JPEG on every grid re-entry.
    public static func image(from data: Data) -> CGImage? {
        let options = [kCGImageSourceShouldCache: true] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, options) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// One frame of a clip, at `bucket` size — the grid poster for a video.
    ///
    /// `AVAssetImageGenerator` is the only API that downsamples while decoding; grabbing a full-frame
    /// `CGImage` and scaling it would put a 4K bitmap in the app's working set for the sake of a 320 px tile.
    /// The frame is a tenth of the way in rather than the first one because a clip that fades up from black
    /// otherwise gets a black cell, and a screenshot-quality poster is not what a grid asks for.
    public static func videoPoster(url: URL, bucket: ThumbnailBucket) async -> Data? {
        let asset = AVURLAsset(url: url)
        let duration = (try? await asset.load(.duration)) ?? .zero
        let seconds = CMTimeGetSeconds(duration)
        let mark = seconds.isFinite && seconds > 0.3 ? seconds * 0.1 : 0
        guard let generator = await imageGenerator(for: asset, bucket: bucket) else { return nil }
        guard let image = try? await generator.image(at: CMTime(seconds: mark, preferredTimescale: 600)).image
        else { return nil }
        return jpeg(image)
    }

    private static func imageGenerator(for asset: AVAsset, bucket: ThumbnailBucket) async -> AVAssetImageGenerator? {
        let tracks = (try? await asset.loadTracks(withMediaType: .video)) ?? []
        guard !tracks.isEmpty else { return nil }
        let generator = AVAssetImageGenerator(asset: asset)
        // The display transform, not the encoded raster: a phone clip is stored landscape and shown
        // portrait, and a sideways poster in the grid is the bug a user notices first.
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: Double(bucket.longSide), height: Double(bucket.longSide))
        // Frames are dropped rather than waited for when the container is missing its timing; a rough cut
        // still gives the grid something to draw.
        generator.requestedTimeToleranceBefore = .positiveInfinity
        generator.requestedTimeToleranceAfter = .positiveInfinity
        return generator
    }
}
