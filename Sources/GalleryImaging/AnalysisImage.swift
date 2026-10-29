import CoreGraphics
import Foundation
import ImageIO

/// The pixels the analyser looks at.
///
/// Not the poster: the grid's 320 px tile is a thumbnail of a thumbnail as far as OCR and faces are
/// concerned. This decodes the *original* file once, downsampled during the decode (never decode-then-scale,
/// which is the difference between a 4 MB working set and a 150 MB one on a 48 MP frame), with orientation
/// already applied so Vision and the hash agree about which way up the picture is.
public enum AnalysisImage {
    public static func downsample(url: URL, maxPixel: Int32) -> CGImage? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options) else { return nil }
        return downsample(source, maxPixel: maxPixel)
    }

    public static func downsample(_ source: CGImageSource, maxPixel: Int32) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// A normalized, bottom-left-origin box (Vision's convention) cut out of a frame, for the per-face
    /// feature print. Clamped to the image so a box that touches an edge cannot produce a zero-sized crop.
    public static func crop(_ image: CGImage, x: Double, y: Double, width: Double, height: Double) -> CGImage? {
        let imageWidth = Double(image.width)
        let imageHeight = Double(image.height)
        let rect = CGRect(
            x: (x * imageWidth).rounded(),
            y: (y * imageHeight).rounded(),
            width: (width * imageWidth).rounded(),
            height: (height * imageHeight).rounded()
        ).intersection(CGRect(x: 0, y: 0, width: imageWidth, height: imageHeight))
        guard rect.width >= 8, rect.height >= 8 else { return nil }
        return image.cropping(to: rect)
    }
}

/// A 64-bit perceptual hash for near-duplicate detection.
///
/// Difference hash: shrink to 9×8 grayscale and record, for every adjacent pair, whether the left pixel is
/// brighter than the right. It survives re-encoding and resize (which is exactly what a "duplicate" is), it
/// costs a millisecond, and at eight bytes a row a 100k library pays 800 kB rather than the 800 MB that
/// persisted Vision feature prints would.
public enum DHash {
    public static let width = 9
    public static let height = 8

    public static func hash(_ image: CGImage) -> UInt64 {
        var pixels = [UInt8](repeating: 0, count: width * height)
        var hash: UInt64 = 0
        pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return }
            context.interpolationQuality = .low
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        for row in 0..<height {
            for column in 0..<(width - 1) {
                let left = pixels[row * width + column]
                let right = pixels[row * width + column + 1]
                hash <<= 1
                if left > right { hash |= 1 }
            }
        }
        return hash
    }

    public static func distance(_ lhs: UInt64, _ rhs: UInt64) -> Int {
        (lhs ^ rhs).nonzeroBitCount
    }
}
