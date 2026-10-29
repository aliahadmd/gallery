import CoreGraphics
import Foundation
import Testing
@testable import GalleryEditing
import GalleryDomain

@Test func captionDrawsInsideItsAnchoredBand() {
    var caption = TextOverlay(kind: .caption, text: "SAMPLE CAPTION")
    caption.sizeFraction = 0.08
    caption.shadow = false
    caption.placement = .anchored(.bottom, marginFraction: 0.05)

    let plan = EditPlanBuilder.plan(
        EditRecipe(overlays: [caption]),
        stored: PixelSize(width: 800, height: 600), orientation: 1
    )!
    let rendered = try! #require(EditRenderer.render(plan, from: solidImage(width: 800, height: 600)))

    #expect(inkCount(rendered, in: CGRect(x: 0, y: 470, width: 800, height: 130)) > 100)
    #expect(inkCount(rendered, in: CGRect(x: 0, y: 0, width: 800, height: 120)) == 0)
    #expect(inkCount(rendered, in: CGRect(x: 0, y: 0, width: 100, height: 600)) == 0)
}

@Test func overlayStaysInOutputSpaceWhenThePhotoIsRotated() {
    var caption = TextOverlay(kind: .caption, text: "BOTTOM")
    caption.sizeFraction = 0.1
    caption.shadow = false
    caption.placement = .anchored(.bottom, marginFraction: 0.04)

    let plan = EditPlanBuilder.plan(
        EditRecipe(quarterTurns: 1, overlays: [caption]),
        stored: PixelSize(width: 800, height: 600), orientation: 1
    )!
    #expect(plan.output == PixelSize(width: 600, height: 800))
    let rendered = try! #require(EditRenderer.render(plan, from: solidImage(width: 800, height: 600)))

    #expect(inkCount(rendered, in: CGRect(x: 0, y: 640, width: 600, height: 160)) > 50)
    #expect(inkCount(rendered, in: CGRect(x: 0, y: 0, width: 600, height: 160)) == 0)
}

@Test func tiledWatermarkCoversTheCanvas() {
    var watermark = TextOverlay(kind: .watermark, text: "SAMPLE")
    watermark.sizeFraction = 0.04
    watermark.opacity = 0.6
    watermark.shadow = false
    watermark.placement = .tiled(
        angleDegrees: 0, columnSpacingFraction: 0.25, rowSpacingFraction: 0.25
    )
    let plan = EditPlanBuilder.plan(
        EditRecipe(overlays: [watermark]),
        stored: PixelSize(width: 800, height: 600), orientation: 1
    )!
    guard case .tiled(_, let centres) = plan.overlays[0].placement else {
        Issue.record("expected a tiled overlay")
        return
    }
    #expect(centres.count == 12)
    let rendered = try! #require(EditRenderer.render(plan, from: solidImage(width: 800, height: 600)))

    var inked = 0
    for centre in centres {
        let box = CGRect(x: centre.x - 60, y: centre.y - 20, width: 120, height: 40)
        if inkCount(rendered, in: box, threshold: 0.6) > 10 { inked += 1 }
    }
    #expect(inked >= 10, "\(inked) of \(centres.count) tiles drew ink")
}

@Test func anEmptyOverlayListChangesNothing() {
    let base = solidImage(width: 400, height: 300)
    let plain = EditPlanBuilder.plan(
        EditRecipe(), stored: PixelSize(width: 400, height: 300), orientation: 1
    )!
    let blank = EditPlanBuilder.plan(
        EditRecipe(overlays: [TextOverlay(kind: .caption, text: "   ")]),
        stored: PixelSize(width: 400, height: 300), orientation: 1
    )!
    let first = EditRenderer.render(plain, from: base)!
    let second = EditRenderer.render(blank, from: base)!
    #expect(pixels(first) == pixels(second))
}

@Test func opacityAndShadowDoNotCrashTheRenderer() {
    var caption = TextOverlay(kind: .caption, text: "SHADOWED")
    caption.sizeFraction = 0.06
    caption.opacity = 0.4
    caption.shadow = true
    let plan = EditPlanBuilder.plan(
        EditRecipe(overlays: [caption]),
        stored: PixelSize(width: 500, height: 400), orientation: 1
    )!
    #expect(EditRenderer.render(plan, from: solidImage(width: 500, height: 400)) != nil)
}

// MARK: - Helpers

/// A mid-grey picture: white text at any opacity is distinguishable from it at a threshold of 0.6.
func solidImage(width: Int, height: Int, grey: Double = 0.45) -> CGImage {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.setFillColor(CGColor(srgbRed: grey, green: grey, blue: grey, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return context.makeImage()!
}

/// Rendered as premultiplied RGBA8. The buffer's first row is the top of the image, which is the same
/// top-left convention the assertions use.
func inkCount(_ image: CGImage, in rect: CGRect, threshold: Double = 0.7) -> Int {
    let bytes = pixels(image)
    let width = image.width
    let height = image.height
    var count = 0
    let x0 = max(0, Int(rect.minX)), x1 = min(width, Int(rect.maxX))
    let top = max(0, Int(rect.minY)), bottom = min(height, Int(rect.maxY))
    for row in top..<bottom {
        for x in x0..<x1 {
            let offset = (row * width + x) * 4
            let luminance = (Double(bytes[offset]) + Double(bytes[offset + 1])
                + Double(bytes[offset + 2])) / (3 * 255)
            if luminance >= threshold { count += 1 }
        }
    }
    return count
}

func pixels(_ image: CGImage) -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let context = CGContext(
        data: &bytes, width: image.width, height: image.height, bitsPerComponent: 8,
        bytesPerRow: image.width * 4, space: space,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    return bytes
}
