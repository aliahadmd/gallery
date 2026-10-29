import CoreGraphics
import Foundation
import GalleryDomain

/// A handful of cheap pixel facts for the classifier: transparency, palette size, flatness and edge
/// density. Sampled at 96 px, so an icon candidate costs one small decode rather than a full one.
public enum PixelProfile {
    /// The sampled facts, or nil when the file cannot be decoded. A failure is not fatal to classification:
    /// the metadata signals still apply.
    public static func sample(url: URL, side: Int = 96) -> SampledFeatures? {
        guard let image = AnalysisImage.downsample(url: url, maxPixel: Int32(side)) else { return nil }
        let width = side
        let height = side
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let hasAlphaChannel = switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: false
        default: true
        }
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: &pixels, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            return nil
        }
        context.interpolationQuality = .low
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        var counts: [UInt32: Int] = [:]
        var transparent = 0
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let alpha = pixels[index + 3]
            if alpha < 250 { transparent += 1 }
            let key = UInt32(pixels[index] >> 3) << 10
                | UInt32(pixels[index + 1] >> 3) << 5
                | UInt32(pixels[index + 2] >> 3)
            counts[key, default: 0] += 1
        }
        let total = width * height
        let top = counts.values.sorted(by: >).prefix(16).reduce(0, +)

        var edges = 0
        var pairs = 0
        func luma(_ index: Int) -> Int {
            (Int(pixels[index]) * 299 + Int(pixels[index + 1]) * 587 + Int(pixels[index + 2]) * 114) / 1000
        }
        for y in 0..<height {
            for x in 0..<width {
                let index = (y * width + x) * 4
                if x + 1 < width, abs(luma(index) - luma(index + 4)) > 24 { edges += 1 }
                if y + 1 < height, abs(luma(index) - luma(index + width * 4)) > 24 { edges += 1 }
                pairs += (x + 1 < width ? 1 : 0) + (y + 1 < height ? 1 : 0)
            }
        }

        let transparentRatio = total == 0 ? 0 : Double(transparent) / Double(total)
        return SampledFeatures(
            side: side,
            // A channel alone is not transparency: an opaque PNG still arrives premultiplied. The classifier
            // wants to know whether the image actually shows through.
            hasAlpha: hasAlphaChannel && transparentRatio > 0,
            transparentRatio: transparentRatio,
            colorCount: counts.count,
            flatRatio: total == 0 ? 0 : Double(top) / Double(total),
            edgeRatio: pairs == 0 ? 0 : Double(edges) / Double(pairs)
        )
    }
}
