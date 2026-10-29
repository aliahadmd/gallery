import Foundation
import AVFoundation
import CoreMedia
import GalleryDomain

/// Reads a moving image's properties with AVFoundation.
///
/// The keypath `load(_:)` calls are the only sanctioned way to ask an `AVAsset` anything: every
/// synchronous property on it blocks a thread on disk, and pass B runs on the cooperative pool, where one
/// blocked thread is a stalled thumbnail lane for the whole app.
public enum VideoMetadataReader {
    public static func read(at url: URL) async -> ReadOutcome {
        guard FileManager.default.fileExists(atPath: url.path) else { return .failed(.vanished) }
        guard FileManager.default.isReadableFile(atPath: url.path) else { return .failed(.noAccess) }

        let asset = AVURLAsset(url: url)
        do {
            async let loadingTracks = asset.loadTracks(withMediaType: .video)
            async let loadingDuration = asset.load(.duration)
            async let loadingItems = asset.load(.commonMetadata)
            let (tracks, duration, items) = try await (loadingTracks, loadingDuration, loadingItems)
            guard let video = tracks.first else { return .failed(.unreadableVideo) }
            let naturalSize = try await video.load(.naturalSize)
            let transform = try await video.load(.preferredTransform)
            let descriptions = try await video.load(.formatDescriptions)

            var file = FileMetadata()
            file.pixelSize = displaySize(naturalSize: naturalSize, transform: transform)
            file.durationMicroseconds = microseconds(of: duration)
            file.codec = codec(descriptions)
            file.dates = ExifDates(assetCreationDate: await creationDate(items))
            return .decoded(file)
        } catch {
            // A container AVFoundation will not open is the same problem whatever the reason turned out to
            // be: the row stays, the badge says the clip could not be read, and the rest of the scan goes
            // on without it.
            return .failed(.unreadableVideo)
        }
    }

    /// `naturalSize` is the encoded raster and `preferredTransform` is what turns it upright; a phone video
    /// is stored landscape and displayed portrait, and reporting the stored size would lay the cell out
    /// sideways. The transform is folded into the size and no EXIF orientation number is written: mapping a
    /// Core Graphics transform onto those eight values is a sign-convention trap, and the grid only needs
    /// the ratio, which the displayed size already gives it correctly.
    static func displaySize(naturalSize: CGSize, transform: CGAffineTransform) -> PixelSize? {
        guard naturalSize.width > 0, naturalSize.height > 0 else { return nil }
        let transformed = CGRect(origin: .zero, size: naturalSize).applying(transform)
        let width = abs(transformed.width).rounded()
        let height = abs(transformed.height).rounded()
        guard width > 0, height > 0 else {
            return PixelSize(width: Int32(naturalSize.width), height: Int32(naturalSize.height))
        }
        return PixelSize(width: Int32(width), height: Int32(height))
    }

    /// The movie header's duration is the honest one; a track can run longer than the container says.
    static func microseconds(of duration: CMTime) -> Int64? {
        let seconds = CMTimeGetSeconds(duration)
        guard seconds.isFinite, seconds > 0 else { return nil }
        return Int64((seconds * 1_000_000).rounded())
    }

    static func codec(_ descriptions: [CMFormatDescription]) -> String? {
        descriptions.first.map { fourCC(CMFormatDescriptionGetMediaSubType($0)) }
    }

    static func fourCC(_ code: FourCharCode) -> String {
        String(format: "%c%c%c%c",
               (Int(code) >> 24) & 0xFF, (Int(code) >> 16) & 0xFF,
               (Int(code) >> 8) & 0xFF, Int(code) & 0xFF)
    }

    /// The movie's own creation date. Matched on `key` as well as `identifier`, because AVFoundation spells
    /// the same QuickTime key two ways depending on who wrote it: a phone's file reads back as
    /// `com.apple.quicktime.creationdate`, one written by `AVAssetWriter` on this machine reads back as
    /// `mdta/com.apple.quicktime.creationdate`, and matching only the identifier dropped the date from every
    /// clip the second group contains.
    static func creationDate(_ items: [AVMetadataItem]) async -> Date? {
        let keys: Set<String> = [
            "creationDate",
            "com.apple.quicktime.creationdate",
            "mdta/com.apple.quicktime.creationdate",
        ]
        func carries(_ item: AVMetadataItem) -> Bool {
            if let identifier = item.identifier?.rawValue, keys.contains(identifier) { return true }
            return (item.key as? String).map { keys.contains($0) } ?? false
        }
        guard let item = items.first(where: carries) else { return nil }
        // The value is an ISO-8601 string in a `mdta` container and a real date in a common one; `dateValue`
        // converts either.
        return try? await item.load(.dateValue)
    }
}
