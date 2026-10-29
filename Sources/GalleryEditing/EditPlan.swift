import CoreGraphics
import Foundation
import GalleryDomain

public enum ResolvedPlacement: Sendable, Hashable {
    case anchored(anchor: OverlayAnchor, marginPixels: Double)
    /// One centre per tile. The renderer measures the text once and draws it at each centre, rotated.
    case tiled(angleDegrees: Double, centres: [CGPoint])
}

/// An overlay resolved into output pixels. Everything a renderer needs and nothing it has to recompute:
/// the same numbers drive the preview and the export, at different rasters.
public struct ResolvedOverlay: Sendable, Hashable {
    public var text: String
    public var font: FontChoice
    public var sizePixels: Double
    public var maxWidthPixels: Double
    public var color: RGBAColor
    public var opacity: Double
    public var shadow: Bool
    public var alignment: OverlayAlignment
    public var placement: ResolvedPlacement
}

/// Everything needed to render one image, in integer output pixels plus one affine transform.
public struct EditPlan: Sendable {
    public struct Geometry: Sendable {
        /// The decoded bitmap's size, orientation not applied.
        public var stored: PixelSize
        public var orientation: Int16
        /// The canvas the crop rect refers to: stored pixels after EXIF orientation, flips and turns.
        public var display: PixelSize
        /// The visible region of `display`, in pixels. For `.fill` this is narrower than `recipe.crop`.
        public var crop: CGRect
        public var output: PixelSize
        /// Output pixels per display pixel.
        public var scale: Double
        /// Stored top-left pixels to output top-left pixels. This is what the renderer consumes.
        public var sourceToOutput: CGAffineTransform
        /// Display top-left pixels — the space `crop` lives in — to output top-left pixels. This is what
        /// the canvas uses to draw the crop frame over the preview.
        public var displayToOutput: CGAffineTransform
    }

    public var geometry: Geometry
    public var format: OutputFormat
    public var colorSpace: OutputColorSpace
    public var background: RGBAColor?
    public var overlays: [ResolvedOverlay]
    /// The recipe asked for more resolution than the source has; the output is the native size.
    public var wasClamped: Bool

    public var output: PixelSize { geometry.output }
    public var outputLongSide: Int32 { max(geometry.output.width, geometry.output.height) }
    public var outputPixelCount: Int { Int(geometry.output.width) * Int(geometry.output.height) }

    public var coreGraphicsTransform: CGAffineTransform {
        FrameTransform.coreGraphics(
            sourceToOutput: geometry.sourceToOutput,
            storedHeight: Double(geometry.stored.height),
            outputHeight: Double(geometry.output.height)
        )
    }

    /// The same composition at a smaller raster — the preview path. Text is re-resolved at the smaller
    /// size rather than scaled as a bitmap, which is what makes the preview agree with the export.
    public func scaled(toLongSide target: Int) -> EditPlan {
        let current = Int(outputLongSide)
        guard target > 0, current > target else { return self }
        let factor = Double(target) / Double(current)
        var copy = self
        copy.geometry.output = PixelSize(
            width: max(1, Int32((Double(geometry.output.width) * factor).rounded())),
            height: max(1, Int32((Double(geometry.output.height) * factor).rounded()))
        )
        copy.geometry.scale = geometry.scale * factor
        copy.geometry.sourceToOutput = FrameTransform.composed(
            geometry.sourceToOutput, FrameTransform.scale(factor)
        )
        copy.geometry.displayToOutput = FrameTransform.composed(
            geometry.displayToOutput, FrameTransform.scale(factor)
        )
        copy.overlays = overlays.map { overlay in
            var scaled = overlay
            scaled.sizePixels *= factor
            scaled.maxWidthPixels *= factor
            switch scaled.placement {
            case .anchored(let anchor, let margin):
                scaled.placement = .anchored(anchor: anchor, marginPixels: margin * factor)
            case .tiled(let angle, let centres):
                scaled.placement = .tiled(
                    angleDegrees: angle,
                    centres: centres.map { CGPoint(x: $0.x * factor, y: $0.y * factor) }
                )
            }
            return scaled
        }
        return copy
    }
}

public enum EditPlanBuilder {
    /// Pure: no ImageIO, no Core Graphics, no disk. Integer geometry is computed once, here, so the
    /// renderer, the preview and the tests all read the same numbers.
    ///
    /// Order is fixed: stored pixels → EXIF orientation → flips → quarter turns → crop → resize → overlays.
    public static func plan(
        _ recipe: EditRecipe,
        stored: PixelSize,
        orientation: Int16?,
        maxOutputPixels: Int = 50_000_000
    ) -> EditPlan? {
        guard stored.width > 0, stored.height > 0 else { return nil }
        let exif: Int16 = (1...8).contains(orientation ?? 1) ? (orientation ?? 1) : 1
        let displaySize = FrameTransform.displaySize(stored: stored, orientation: exif)
        var width = Double(displaySize.width)
        var height = Double(displaySize.height)

        var transform = FrameTransform.orientation(
            exif, width: Double(stored.width), height: Double(stored.height)
        )
        if recipe.flipHorizontal {
            transform = FrameTransform.composed(transform, FrameTransform.flipX(width))
        }
        if recipe.flipVertical {
            transform = FrameTransform.composed(transform, FrameTransform.flipY(height))
        }
        for _ in 0..<recipe.normalizedQuarterTurns {
            transform = FrameTransform.composed(
                transform, FrameTransform.rotation90(width: width, height: height)
            )
            (width, height) = (height, width)
        }
        let storedToDisplay = transform

        let recipeCrop = recipe.crop.clamped()
        var cropX = (recipeCrop.x * width).rounded()
        var cropY = (recipeCrop.y * height).rounded()
        var cropW = max(1, (recipeCrop.width * width).rounded())
        var cropH = max(1, (recipeCrop.height * height).rounded())
        cropX = min(max(0, cropX), max(0, width - 1))
        cropY = min(max(0, cropY), max(0, height - 1))
        cropW = min(cropW, width - cropX)
        cropH = min(cropH, height - cropY)
        guard cropW >= 1, cropH >= 1 else { return nil }

        var visibleX = cropX
        var visibleY = cropY
        var visibleW = cropW
        var visibleH = cropH
        var scale = 1.0
        var outputW = cropW
        var outputH = cropH
        var offsetX = 0.0
        var offsetY = 0.0
        var wasClamped = false

        switch recipe.resize {
        case .original:
            break

        case .longSide(let requested):
            guard requested > 0 else { return nil }
            let native = max(cropW, cropH)
            let target = Double(requested)
            scale = min(1, target / native)
            wasClamped = target > native
            outputW = max(1, (cropW * scale).rounded())
            outputH = max(1, (cropH * scale).rounded())

        case .exact(let exactW, let exactH, let fit, let allowUpscale):
            guard exactW > 0, exactH > 0 else { return nil }
            outputW = Double(exactW)
            outputH = Double(exactH)
            let raw = fit == .fit
                ? min(Double(exactW) / cropW, Double(exactH) / cropH)
                : max(Double(exactW) / cropW, Double(exactH) / cropH)
            if !allowUpscale && raw > 1 {
                scale = 1
                wasClamped = true
            } else {
                scale = raw
            }
            if fit == .fit {
                offsetX = (Double(exactW) - cropW * scale) / 2
                offsetY = (Double(exactH) - cropH * scale) / 2
            } else {
                // `.fill` legitimately narrows the crop: what the canvas cannot show is not part of the
                // exported image, so `geometry.crop` — not `recipe.crop` — is the authority.
                visibleW = min(cropW, Double(exactW) / scale)
                visibleH = min(cropH, Double(exactH) / scale)
                visibleX = cropX + (cropW - visibleW) / 2
                visibleY = cropY + (cropH - visibleH) / 2
                offsetX = (Double(exactW) - visibleW * scale) / 2
                offsetY = (Double(exactH) - visibleH * scale) / 2
            }
        }

        guard outputW >= 1, outputH >= 1, outputW * outputH <= Double(maxOutputPixels) else {
            return nil
        }

        transform = FrameTransform.composed(transform, FrameTransform.translation(x: -cropX, y: -cropY))
        if visibleX != cropX || visibleY != cropY {
            transform = FrameTransform.composed(
                transform, FrameTransform.translation(x: cropX - visibleX, y: cropY - visibleY)
            )
        }
        if scale != 1 {
            transform = FrameTransform.composed(transform, FrameTransform.scale(scale))
        }
        // The centring offset is in output pixels, so it must not be scaled by the step above.
        if offsetX != 0 || offsetY != 0 {
            transform = FrameTransform.composed(
                transform, FrameTransform.translation(x: offsetX, y: offsetY)
            )
        }

        let output = PixelSize(width: Int32(outputW), height: Int32(outputH))
        let geometry = EditPlan.Geometry(
            stored: stored,
            orientation: exif,
            display: PixelSize(width: Int32(width), height: Int32(height)),
            crop: CGRect(x: visibleX, y: visibleY, width: visibleW, height: visibleH),
            output: output,
            scale: scale,
            sourceToOutput: transform,
            displayToOutput: FrameTransform.composed(storedToDisplay.inverted(), transform)
        )
        return EditPlan(
            geometry: geometry,
            format: recipe.format,
            colorSpace: recipe.colorSpace,
            background: recipe.background,
            overlays: resolve(recipe.overlays, output: output),
            wasClamped: wasClamped
        )
    }

    static func resolve(_ overlays: [TextOverlay], output: PixelSize) -> [ResolvedOverlay] {
        let longSide = Double(max(output.width, output.height))
        let width = Double(output.width)
        let height = Double(output.height)
        return overlays.compactMap { overlay in
            let text = overlay.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, longSide > 0 else { return nil }

            let sizePixels = min(max(overlay.sizeFraction, 0.005), 0.25) * longSide
            let maxWidthPixels = min(max(overlay.maxWidthFraction, 0.05), 1) * width
            let placement: ResolvedPlacement = switch overlay.placement {
            case .anchored(let anchor, let margin):
                .anchored(
                    anchor: anchor,
                    marginPixels: min(max(margin, 0), 0.25) * longSide
                )
            case .tiled(let angle, let columnSpacing, let rowSpacing):
                .tiled(
                    angleDegrees: angle,
                    centres: tileCentres(
                        width: width,
                        height: height,
                        stepX: min(max(columnSpacing, 0.02), 1) * longSide,
                        stepY: min(max(rowSpacing, 0.02), 1) * longSide
                    )
                )
            }
            return ResolvedOverlay(
                text: text,
                font: overlay.font,
                sizePixels: sizePixels,
                maxWidthPixels: maxWidthPixels,
                color: overlay.color,
                opacity: min(max(overlay.opacity, 0), 1),
                shadow: overlay.shadow,
                alignment: overlay.alignment,
                placement: placement
            )
        }
    }

    private static func tileCentres(
        width: Double, height: Double, stepX: Double, stepY: Double
    ) -> [CGPoint] {
        guard width > 0, height > 0, stepX > 0, stepY > 0 else { return [] }
        var centres: [CGPoint] = []
        let limit = 4096
        var y = stepY / 2
        while y < height, centres.count < limit {
            var x = stepX / 2
            while x < width, centres.count < limit {
                centres.append(CGPoint(x: x, y: y))
                x += stepX
            }
            y += stepY
        }
        return centres
    }
}
