import CoreGraphics
import Foundation
import ImageIO
import GalleryDomain
import GalleryImaging
import GallerySupport

/// Renders a collage from library photos: one small decode per slot, then a single canvas.
///
/// Members are decoded through `AnalysisImage.downsample` — orientation applied, never a full decode — so a
/// twelve-up collage of 48 MP photos costs twelve thumbnails plus the canvas rather than twelve originals.
public actor CollageComposer {
    private let lane: BlockingLane

    public init(lane: BlockingLane = BlockingLane(
        label: "app.gallery.collage", qos: .userInitiated, semaphore: .imageDecode()
    )) {
        self.lane = lane
    }

    public func render(
        _ document: CollageDocument,
        members: [MediaID: EditSource],
        sourceLongSides: [MediaID: Int],
        previewLongSide: Int? = nil
    ) async -> CGImage? {
        var adjusted = document
        if let previewLongSide {
            adjusted.longSide = min(document.longSide, max(800, previewLongSide))
        }
        let scaled = adjusted
        let layout = CollageLayoutEngine.layout(scaled, sourceLongSides: sourceLongSides)
        let outcome = await lane.run { () -> CGImage? in
            Self.draw(scaled, layout: layout, members: members)
        }
        guard case .completed(let image) = outcome else { return nil }
        return image
    }

    /// Renders at the document's full size and writes it to `url` through a dot-named temp beside it, so a
    /// half-written collage can never be picked up by a scan of the same folder.
    public func write(
        _ document: CollageDocument,
        members: [MediaID: EditSource],
        sourceLongSides: [MediaID: Int],
        to url: URL
    ) async -> Bool {
        let layout = CollageLayoutEngine.layout(document, sourceLongSides: sourceLongSides)
        let temp = url.deletingLastPathComponent()
            .appendingPathComponent(".gallery-tmp-\(UUID().uuidString)")
        let outcome = await lane.run { () -> Bool in
            SecurityScope.begin(url.deletingLastPathComponent())
            defer { SecurityScope.end(url.deletingLastPathComponent()) }
            guard let image = Self.draw(document, layout: layout, members: members) else { return false }
            guard Self.encode(image, document: document, to: temp) else {
                try? FileManager.default.removeItem(at: temp)
                return false
            }
            do {
                if FileManager.default.fileExists(atPath: url.path) {
                    try FileManager.default.removeItem(at: url)
                }
                try FileManager.default.moveItem(at: temp, to: url)
                return true
            } catch {
                try? FileManager.default.removeItem(at: temp)
                return false
            }
        }
        guard case .completed(let written) = outcome else { return false }
        return written
    }

    // MARK: - Drawing

    private static func draw(
        _ document: CollageDocument, layout: CollageLayout, members: [MediaID: EditSource]
    ) -> CGImage? {
        let width = Int(layout.canvas.width)
        let height = Int(layout.canvas.height)
        guard width > 0, height > 0,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            return nil
        }
        context.interpolationQuality = .high
        ImageDraw.fill(
            CGRect(x: 0, y: 0, width: width, height: height), with: document.background, in: context
        )

        for slot in layout.slots {
            guard let member = slot.member, member < document.memberIDs.count else { continue }
            let id = document.memberIDs[member]
            let frame = coreGraphicsRect(slot.frame, canvasHeight: Double(height))
            if let source = members[id], let image = decode(source, maxPixel: slot.requiredPixels) {
                ImageDraw.aspectFill(image, in: frame, context: context)
            } else {
                drawPlaceholder(
                    name: members[id]?.name ?? "Missing photo",
                    in: frame, context: context
                )
            }
        }

        if let title = document.title?.trimmingCharacters(in: .whitespacesAndNewlines),
           !title.isEmpty, let titleFrame = layout.titleFrame {
            var color = RGBAColor.white
            let background = document.background
            let luminance = 0.299 * background.red + 0.587 * background.green
                + 0.114 * background.blue
            if luminance > 0.55 { color = .black }
            TextRenderer.drawCentered(
                title,
                in: coreGraphicsRect(titleFrame, canvasHeight: Double(height)),
                sizePixels: 0.05 * Double(max(width, height)),
                color: color,
                in: context
            )
        }
        return context.makeImage()
    }

    private static func decode(_ source: EditSource, maxPixel: Int32) -> CGImage? {
        let scope = source.scopedRoot ?? source.url.deletingLastPathComponent()
        SecurityScope.begin(scope)
        defer { SecurityScope.end(scope) }
        return AnalysisImage.downsample(url: source.url, maxPixel: max(2, maxPixel))
    }

    private static func drawPlaceholder(name: String, in frame: CGRect, context: CGContext) {
        ImageDraw.fill(frame, with: RGBAColor(white: 0.88), in: context)
        let inset = frame.insetBy(dx: frame.width * 0.06, dy: frame.height * 0.06)
        TextRenderer.drawCentered(
            name,
            in: inset,
            sizePixels: max(8, min(inset.height * 0.2, inset.width * 0.08)),
            color: RGBAColor(white: 0.35),
            in: context
        )
    }

    private static func coreGraphicsRect(_ rect: CGRect, canvasHeight: Double) -> CGRect {
        CGRect(
            x: rect.minX,
            y: canvasHeight - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }

    private static func encode(_ image: CGImage, document: CollageDocument, to url: URL) -> Bool {
        let type = OutputFormats.utType(document.format.kind).identifier as CFString
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, type, 1, nil) else {
            return false
        }
        var properties: [CFString: Any] = [kCGImageDestinationEmbedThumbnail: true]
        if document.format.isLossy {
            properties[kCGImageDestinationLossyCompressionQuality] = document.format.quality
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        return CGImageDestinationFinalize(destination)
    }
}
