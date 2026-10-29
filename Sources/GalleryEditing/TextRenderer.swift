import CoreGraphics
import CoreText
import Foundation
import GalleryDomain

/// Draws captions and watermarks into the output bitmap with Core Text.
///
/// Everything is measured and drawn at output resolution — a preview re-rasterises the glyphs at the
/// preview's size instead of scaling a bitmap, which is what makes the canvas honest about how large the
/// text will be. The context is Core Graphics' bottom-left space; the plan's anchors are top-left, and the
/// conversion happens here and nowhere else.
public enum TextRenderer {
    public static func draw(_ overlays: [ResolvedOverlay], in context: CGContext, output: PixelSize) {
        guard !overlays.isEmpty, output.width > 0, output.height > 0 else { return }
        let canvas = CGSize(width: Int(output.width), height: Int(output.height))
        for overlay in overlays {
            switch overlay.placement {
            case .anchored(let anchor, let margin):
                drawAnchored(overlay, anchor: anchor, margin: margin, in: context, canvas: canvas)
            case .tiled(let angle, let centres):
                drawTiled(overlay, angleDegrees: angle, centres: centres, in: context)
            }
        }
    }

    // MARK: - Anchored

    private static func drawAnchored(
        _ overlay: ResolvedOverlay, anchor: OverlayAnchor, margin: Double,
        in context: CGContext, canvas: CGSize
    ) {
        let attributed = attributedString(overlay, alignment: overlay.alignment)
        let box = measure(attributed, maxWidth: overlay.maxWidthPixels)
        guard box.width > 0, box.height > 0 else { return }

        let topLeftX: Double = switch anchor {
        case .topLeading, .leading, .bottomLeading: margin
        case .top, .center, .bottom: (canvas.width - box.width) / 2
        case .topTrailing, .trailing, .bottomTrailing: canvas.width - margin - box.width
        }
        let topLeftY: Double = switch anchor {
        case .topLeading, .top, .topTrailing: margin
        case .leading, .center, .trailing: (canvas.height - box.height) / 2
        case .bottomLeading, .bottom, .bottomTrailing: canvas.height - margin - box.height
        }
        let frameRect = CGRect(
            x: topLeftX,
            y: canvas.height - topLeftY - box.height,
            width: box.width,
            height: box.height
        )

        context.saveGState()
        applyShadow(overlay, in: context)
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let path = CGPath(rect: frameRect, transform: nil)
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), path, nil)
        CTFrameDraw(frame, context)
        context.restoreGState()
    }

    /// Draws a single block centred inside a Core Graphics rect (bottom-left space). Used by the collage for
    /// its title band and by the placeholder for a missing member — both places where the caller already
    /// knows the frame and does not want anchor arithmetic.
    public static func drawCentered(
        _ text: String, in rect: CGRect, sizePixels: Double, color: RGBAColor, in context: CGContext
    ) {
        let trimmed = text
        if trimmed.isEmpty || rect.width < 2 || rect.height < 2 { return }
        let overlay = ResolvedOverlay(
            text: trimmed,
            font: .system,
            sizePixels: max(1, sizePixels),
            maxWidthPixels: rect.width,
            color: color,
            opacity: 1,
            shadow: false,
            alignment: .center,
            placement: .anchored(anchor: .center, marginPixels: 0)
        )
        let attributed = attributedString(overlay, alignment: .center)
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let fit = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter, CFRange(location: 0, length: 0), nil,
            CGSize(width: rect.width, height: rect.height), nil
        )
        let width = min(ceil(fit.width), rect.width)
        let height = min(ceil(fit.height), rect.height)
        let box = CGRect(
            x: rect.midX - width / 2,
            y: rect.midY - height / 2,
            width: width,
            height: height
        )
        let path = CGPath(rect: box, transform: nil)
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), path, nil)
        CTFrameDraw(frame, context)
    }

    // MARK: - Tiled

    private static func drawTiled(
        _ overlay: ResolvedOverlay, angleDegrees: Double, centres: [CGPoint], in context: CGContext
    ) {
        // A tiled watermark is a stamp, not a paragraph: one line, however long, so every tile is identical
        // and the spacing in the plan is exactly what the user sees.
        let single = overlay.text.replacingOccurrences(of: "\n", with: " ")
        let attributed = attributedString(overlay, alignment: .center, singleLine: single)
        let line = CTLineCreateWithAttributedString(attributed)
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var leading: CGFloat = 0
        let width = CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
        guard width > 0 else { return }
        let height = Double(ascent + descent)
        let angle = -angleDegrees * .pi / 180

        for centre in centres {
            context.saveGState()
            context.translateBy(x: centre.x, y: centre.y)
            context.rotate(by: angle)
            applyShadow(overlay, in: context)
            context.textPosition = CGPoint(x: -width / 2, y: -height / 2 + Double(descent))
            CTLineDraw(line, context)
            context.restoreGState()
        }
    }

    // MARK: - Text

    private static func attributedString(
        _ overlay: ResolvedOverlay, alignment: OverlayAlignment, singleLine: String? = nil
    ) -> CFAttributedString {
        let font = font(for: overlay.font, size: overlay.sizePixels)
        var color = overlay.color
        color.alpha *= overlay.opacity
        var textAlignment = switch alignment {
        case .leading: CTTextAlignment.left
        case .center: CTTextAlignment.center
        case .trailing: CTTextAlignment.right
        }
        var lineBreak = CTLineBreakMode.byWordWrapping
        let paragraph: CTParagraphStyle = withUnsafePointer(to: &textAlignment) { alignmentPointer in
            withUnsafePointer(to: &lineBreak) { breakPointer in
                let settings = [
                    CTParagraphStyleSetting(
                        spec: .alignment,
                        valueSize: MemoryLayout<CTTextAlignment>.size,
                        value: UnsafeRawPointer(alignmentPointer)
                    ),
                    CTParagraphStyleSetting(
                        spec: .lineBreakMode,
                        valueSize: MemoryLayout<CTLineBreakMode>.size,
                        value: UnsafeRawPointer(breakPointer)
                    ),
                ]
                return CTParagraphStyleCreate(settings, settings.count)
            }
        }
        let attributes: [CFString: Any] = [
            kCTFontAttributeName: font,
            kCTForegroundColorAttributeName: cgColor(color),
            kCTParagraphStyleAttributeName: paragraph,
        ]
        guard let attributed = CFAttributedStringCreate(
            nil, (singleLine ?? overlay.text) as CFString, attributes as CFDictionary
        ) else {
            return CFAttributedStringCreate(nil, "" as CFString, nil)!
        }
        return attributed
    }

    private static func measure(_ attributed: CFAttributedString, maxWidth: Double) -> CGSize {
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let constraint = CGSize(width: max(1, maxWidth), height: .greatestFiniteMagnitude)
        let size = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter, CFRange(location: 0, length: 0), nil, constraint, nil
        )
        return CGSize(width: min(ceil(size.width), max(1, maxWidth)), height: ceil(size.height))
    }

    private static func font(for choice: FontChoice, size: Double) -> CTFont {
        if let name = choice.postScriptName, !name.isEmpty {
            let font = CTFontCreateWithName(name as CFString, size, nil)
            if CTFontGetGlyphCount(font) > 0 { return font }
        }
        let base: CTFont
        switch choice.design {
        case .serif: base = CTFontCreateWithName("Times New Roman" as CFString, size, nil)
        case .rounded: base = CTFontCreateWithName("Arial Rounded MT Bold" as CFString, size, nil)
        case .monospaced: base = CTFontCreateWithName("Menlo-Regular" as CFString, size, nil)
        case .standard: base = CTFontCreateUIFontForLanguage(.system, size, nil)
            ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
        }
        let weight = min(max(choice.weight, 0), 1)
        guard choice.postScriptName == nil, weight != 0.5 else { return base }
        let traits: [CFString: Any] = [
            kCTFontWeightTrait: -0.4 + 1.2 * weight,
        ]
        let descriptor = CTFontDescriptorCreateWithAttributes(
            [kCTFontTraitsAttribute: traits] as CFDictionary
        )
        return CTFontCreateCopyWithAttributes(base, size, nil, descriptor)
    }

    private static func cgColor(_ color: RGBAColor) -> CGColor {
        CGColor(srgbRed: color.red, green: color.green, blue: color.blue, alpha: color.alpha)
    }

    private static func applyShadow(_ overlay: ResolvedOverlay, in context: CGContext) {
        guard overlay.shadow else { return }
        let size = overlay.sizePixels
        context.setShadow(
            offset: CGSize(width: 0, height: -max(1, size * 0.04)),
            blur: max(1, size * 0.08),
            color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.45 * overlay.opacity)
        )
    }
}
