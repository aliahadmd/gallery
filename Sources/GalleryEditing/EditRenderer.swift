import CoreGraphics
import Foundation
import ImageIO
import GalleryDomain

/// The file header, before any pixels are touched. `properties` is the dictionary a re-encode merges into,
/// so the source is opened once and both jobs read the same answer.
public struct SourceHeader {
    public var size: PixelSize
    public var orientation: Int16
    public var properties: [CFString: Any]
    public var type: CFString
}

public enum EditRenderer {
    public static func readHeader(_ url: URL) -> SourceHeader? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let type = CGImageSourceGetType(source) else {
            return nil
        }
        guard let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.int32Value,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.int32Value,
              width > 0, height > 0 else {
            return nil
        }
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.int16Value ?? 1
        return SourceHeader(
            size: PixelSize(width: width, height: height),
            orientation: orientation,
            properties: properties,
            type: type
        )
    }

    /// Decodes without applying EXIF orientation — deliberately the opposite of `ThumbnailBaker` and
    /// `AnalysisImage.downsample`. The editor folds the orientation into its own affine transform, and a
    /// decoder that has already transposed the pixels would leave the plan describing the wrong image.
    public static func decode(_ url: URL, maxPixel: Int32? = nil) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        if let maxPixel, maxPixel > 0 {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: false,
                kCGImageSourceThumbnailMaxPixelSize: Int(maxPixel),
                kCGImageSourceShouldCacheImmediately: true,
            ]
            return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        }
        let options = [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
        return CGImageSourceCreateImageAtIndex(source, 0, options)
    }

    /// One context, one resampling draw, then overlays at output resolution.
    public static func render(_ plan: EditPlan, from source: CGImage) -> CGImage? {
        let width = Int(plan.output.width)
        let height = Int(plan.output.height)
        guard width > 0, height > 0 else { return nil }
        let space = colorSpace(for: plan.colorSpace, source: source)
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }
        context.interpolationQuality = .high

        // A lossy container cannot store alpha; leaving the padding transparent would encode it as black.
        let background = plan.background ?? (plan.format.isLossy ? .white : nil)
        if let background {
            ImageDraw.fill(CGRect(x: 0, y: 0, width: width, height: height),
                           with: background, in: context)
        }

        context.saveGState()
        context.concatenate(plan.coreGraphicsTransform)
        context.draw(source, in: CGRect(x: 0, y: 0, width: source.width, height: source.height))
        context.restoreGState()

        TextRenderer.draw(plan.overlays, in: context, output: plan.output)
        return context.makeImage()
    }

    public static func encode(
        _ image: CGImage, plan: EditPlan, properties: [CFString: Any], to url: URL
    ) -> Bool {
        let type = OutputFormats.utType(plan.format.kind).identifier as CFString
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, type, 1, nil) else {
            return false
        }
        var merged = properties
        if plan.format.isLossy {
            merged[kCGImageDestinationLossyCompressionQuality] = plan.format.quality
        }
        if plan.format.embedThumbnail {
            merged[kCGImageDestinationEmbedThumbnail] = true
        }
        CGImageDestinationAddImage(destination, image, merged as CFDictionary)
        return CGImageDestinationFinalize(destination)
    }

    /// Header size and a full decode. A truncated file can still carry a valid header, which is why the
    /// decode is part of the check rather than a dimension comparison alone.
    public static func verify(_ url: URL, matching plan: EditPlan) -> Bool {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.int32Value,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.int32Value,
              width == plan.output.width, height == plan.output.height else {
            return false
        }
        return CGImageSourceCreateImageAtIndex(source, 0, nil) != nil
    }

    private static func colorSpace(for choice: OutputColorSpace, source: CGImage) -> CGColorSpace {
        switch choice {
        case .matchSource:
            if let space = source.colorSpace, space.model == .rgb { return space }
            return CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        case .sRGB:
            return CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        case .displayP3:
            return CGColorSpace(name: CGColorSpace.displayP3) ?? CGColorSpaceCreateDeviceRGB()
        }
    }
}
