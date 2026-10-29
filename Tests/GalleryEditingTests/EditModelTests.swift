import CoreGraphics
import Foundation
import Testing
@testable import GalleryEditing
import GalleryDomain

/// The orientation table is a convenience; these tests are the authority. Each case asks where a stored
/// quadrant *should* land, from EXIF's definition of the eight orientations, and compares with where the
/// plan's transform actually puts it.
@Test func orientationQuadrantMatrix() {
    let storedSizes = [PixelSize(width: 200, height: 120), PixelSize(width: 120, height: 200)]
    for stored in storedSizes {
        for orientation in Int16(1)...8 {
            for flipH in [false, true] {
                for flipV in [false, true] {
                    for turns in 0...4 {
                        let recipe = EditRecipe(
                            quarterTurns: turns, flipHorizontal: flipH, flipVertical: flipV
                        )
                        guard let plan = EditPlanBuilder.plan(
                            recipe, stored: stored, orientation: orientation
                        ) else {
                            Issue.record("no plan for \(orientation)/\(flipH)/\(flipV)/\(turns)")
                            continue
                        }
                        let output = plan.geometry.output
                        for qx in 0...1 {
                            for qy in 0...1 {
                                let point = CGPoint(
                                    x: (Double(qx) * 2 + 1) * Double(stored.width) / 4,
                                    y: (Double(qy) * 2 + 1) * Double(stored.height) / 4
                                )
                                let mapped = FrameTransform.apply(
                                    plan.geometry.sourceToOutput, point
                                )
                                let actual = (
                                    mapped.x < Double(output.width) / 2 ? 0 : 1,
                                    mapped.y < Double(output.height) / 2 ? 0 : 1
                                )
                                let expected = expectedQuadrant(
                                    (qx, qy), orientation: Int(orientation),
                                    flipH: flipH, flipV: flipV, turns: turns
                                )
                                #expect(
                                    actual == expected,
                                    "o\(orientation) f\(flipH ? 1 : 0)\(flipV ? 1 : 0) t\(turns) stored(\(qx),\(qy)) → \(actual), expected \(expected)"
                                )
                            }
                        }
                    }
                }
            }
        }
    }
}

/// Where a stored quadrant appears once an EXIF orientation, the user's flips and quarter turns are applied.
private func expectedQuadrant(
    _ q: (Int, Int), orientation: Int, flipH: Bool, flipV: Bool, turns: Int
) -> (Int, Int) {
    var expected: (Int, Int) = switch orientation {
    case 2: (1 - q.0, q.1)              // mirror horizontal
    case 3: (1 - q.0, 1 - q.1)          // rotate 180
    case 4: (q.0, 1 - q.1)              // mirror vertical
    case 5: (q.1, q.0)                  // transpose
    case 6: (1 - q.1, q.0)              // rotate 90 clockwise
    case 7: (1 - q.1, 1 - q.0)          // transverse
    case 8: (q.1, 1 - q.0)              // rotate 270 clockwise
    default: q
    }
    if flipH { expected.0 = 1 - expected.0 }
    if flipV { expected.1 = 1 - expected.1 }
    for _ in 0..<(((turns % 4) + 4) % 4) {
        expected = (1 - expected.1, expected.0)
    }
    return expected
}

@Test func orientationSwapsDisplaySize() {
    for orientation in Int16(5)...8 {
        let plan = EditPlanBuilder.plan(
            EditRecipe(), stored: PixelSize(width: 400, height: 300), orientation: orientation
        )
        #expect(plan?.geometry.display == PixelSize(width: 300, height: 400))
        #expect(plan?.geometry.output == PixelSize(width: 300, height: 400))
    }
    let normal = EditPlanBuilder.plan(
        EditRecipe(), stored: PixelSize(width: 400, height: 300), orientation: 1
    )
    #expect(normal?.geometry.display == PixelSize(width: 400, height: 300))
}

@Test func cropCornersMapToTheOutputRect() {
    let stored = PixelSize(width: 200, height: 120)
    let crops = [
        CropRect.full,
        CropRect(x: 0.1, y: 0.2, width: 0.5, height: 0.4),
        CropRect(x: 0.3, y: 0.05, width: 0.6, height: 0.9),
    ]
    let rules: [ResizeRule] = [
        .original, .longSide(90), .exact(width: 300, height: 200, fit: .fill, allowUpscale: false),
        .exact(width: 300, height: 200, fit: .fit, allowUpscale: true),
    ]
    for orientation in Int16(1)...8 {
        for crop in crops {
            for rule in rules {
                for turns in 0...1 {
                    for flipH in [false, true] {
                        let recipe = EditRecipe(
                            crop: crop, quarterTurns: turns, flipHorizontal: flipH, resize: rule
                        )
                        guard let plan = EditPlanBuilder.plan(
                            recipe, stored: stored, orientation: orientation
                        ) else {
                            Issue.record("no plan \(orientation) \(crop) \(rule)")
                            continue
                        }
                        let geometry = plan.geometry
                        let output = geometry.output
                        // Whatever the rule, the visible crop must land as a centred rect of its scaled
                        // size: equal to the canvas for original/longSide/fill, inset for fit and for a
                        // fill that refused to enlarge.
                        let w = geometry.crop.width * geometry.scale
                        let h = geometry.crop.height * geometry.scale
                        let expected = CGRect(
                            x: (Double(output.width) - w) / 2,
                            y: (Double(output.height) - h) / 2,
                            width: w, height: h
                        )
                        let corners = [
                            CGPoint(x: geometry.crop.minX, y: geometry.crop.minY),
                            CGPoint(x: geometry.crop.maxX, y: geometry.crop.minY),
                            CGPoint(x: geometry.crop.minX, y: geometry.crop.maxY),
                            CGPoint(x: geometry.crop.maxX, y: geometry.crop.maxY),
                        ].map { FrameTransform.apply(geometry.displayToOutput, $0) }
                        let actual = CGRect(
                            x: corners.map(\.x).min() ?? 0,
                            y: corners.map(\.y).min() ?? 0,
                            width: (corners.map(\.x).max() ?? 0) - (corners.map(\.x).min() ?? 0),
                            height: (corners.map(\.y).max() ?? 0) - (corners.map(\.y).min() ?? 0)
                        )
                        #expect(
                            abs(actual.minX - expected.minX) <= 0.6
                                && abs(actual.minY - expected.minY) <= 0.6
                                && abs(actual.width - expected.width) <= 0.6
                                && abs(actual.height - expected.height) <= 0.6,
                            "\(orientation) \(crop) \(rule): \(actual) vs \(expected)"
                        )
                        #expect(geometry.crop.minX >= 0 && geometry.crop.minY >= 0)
                        #expect(geometry.crop.maxX <= Double(geometry.display.width) + 0.001)
                        #expect(geometry.crop.maxY <= Double(geometry.display.height) + 0.001)
                    }
                }
            }
        }
    }
}

@Test func cropRectRotationKeepsTheSelectedPixels() {
    let crop = CropRect(x: 0.1, y: 0.2, width: 0.5, height: 0.3)
    #expect(crop.rotated(quarterTurns: 0) == crop)
    #expect(approximatelyEqual(crop.rotated(quarterTurns: 4), crop))
    #expect(approximatelyEqual(crop.rotated(quarterTurns: -4), crop))

    let turned = crop.rotated(quarterTurns: 1)
    // The image of the rect's corners under a clockwise turn (x, y) ↦ (1 − y, x).
    let corners = [
        CGPoint(x: crop.x, y: crop.y),
        CGPoint(x: crop.x + crop.width, y: crop.y),
        CGPoint(x: crop.x, y: crop.y + crop.height),
        CGPoint(x: crop.x + crop.width, y: crop.y + crop.height),
    ].map { CGPoint(x: 1 - $0.y, y: $0.x) }
    let minX = corners.map(\.x).min()!, maxX = corners.map(\.x).max()!
    let minY = corners.map(\.y).min()!, maxY = corners.map(\.y).max()!
    #expect(abs(turned.x - minX) < 1e-9)
    #expect(abs(turned.y - minY) < 1e-9)
    #expect(abs(turned.width - (maxX - minX)) < 1e-9)
    #expect(abs(turned.height - (maxY - minY)) < 1e-9)

    #expect(approximatelyEqual(crop.rotated(quarterTurns: 1).rotated(quarterTurns: 3), crop))
    #expect(approximatelyEqual(turned.rotated(quarterTurns: 3), crop))
}

@Test func cropRectFlipsAreInvolutions() {
    let crop = CropRect(x: 0.1, y: 0.2, width: 0.5, height: 0.3)
    let flipped = crop.flipped(horizontal: true, vertical: true)
    #expect(approximatelyEqual(flipped.flipped(horizontal: true, vertical: true), crop))
    #expect(abs(flipped.x - 0.4) < 1e-9)
    #expect(abs(flipped.y - 0.5) < 1e-9)
}

@Test func cropRectClampsIntoTheCanvas() {
    let clamped = CropRect(x: 0.8, y: -0.2, width: 0.5, height: 2).clamped()
    #expect(abs(clamped.x - 0.5) < 1e-9)
    #expect(abs(clamped.y) < 1e-9)
    #expect(abs(clamped.width - 0.5) < 1e-9)
    #expect(abs(clamped.height - 1) < 1e-9)
    let zero = CropRect(x: 0, y: 0, width: 0, height: 0).clamped()
    #expect(zero.width > 0 && zero.height > 0)
}

@Test func longSideNeverEnlarges() {
    let stored = PixelSize(width: 4000, height: 3000)
    let smaller = EditPlanBuilder.plan(
        EditRecipe(resize: .longSide(2000)), stored: stored, orientation: 1
    )
    #expect(smaller?.geometry.output == PixelSize(width: 2000, height: 1500))
    #expect(smaller?.wasClamped == false)

    let larger = EditPlanBuilder.plan(
        EditRecipe(resize: .longSide(6000)), stored: stored, orientation: 1
    )
    #expect(larger?.geometry.output == stored)
    #expect(larger?.wasClamped == true)
}

@Test func fitCentresAndFillNarrowsTheCrop() {
    let stored = PixelSize(width: 4000, height: 3000)

    let fit = EditPlanBuilder.plan(
        EditRecipe(resize: .exact(width: 1000, height: 1000, fit: .fit, allowUpscale: false)),
        stored: stored, orientation: 1
    )
    #expect(fit?.geometry.output == PixelSize(width: 1000, height: 1000))
    #expect(fit?.geometry.scale == 0.25)
    #expect(fit?.geometry.crop == CGRect(x: 0, y: 0, width: 4000, height: 3000))
    let fitCorner = FrameTransform.apply(
        fit!.geometry.sourceToOutput, CGPoint(x: 0, y: 0)
    )
    #expect(abs(fitCorner.x) < 0.01)
    #expect(abs(fitCorner.y - 125) < 0.01)

    let fill = EditPlanBuilder.plan(
        EditRecipe(resize: .exact(width: 1000, height: 1000, fit: .fill, allowUpscale: false)),
        stored: stored, orientation: 1
    )
    #expect(fill?.geometry.output == PixelSize(width: 1000, height: 1000))
    #expect(abs((fill?.geometry.scale ?? 0) - 1.0 / 3.0) < 1e-9)
    #expect(fill?.geometry.crop == CGRect(x: 500, y: 0, width: 3000, height: 3000))
}

@Test func upscaleIsRefusedUnlessAllowed() {
    let stored = PixelSize(width: 400, height: 300)
    let refused = EditPlanBuilder.plan(
        EditRecipe(resize: .exact(width: 800, height: 600, fit: .fill, allowUpscale: false)),
        stored: stored, orientation: 1
    )
    #expect(refused?.geometry.scale == 1)
    #expect(refused?.wasClamped == true)

    let allowed = EditPlanBuilder.plan(
        EditRecipe(resize: .exact(width: 800, height: 600, fit: .fill, allowUpscale: true)),
        stored: stored, orientation: 1
    )
    #expect(allowed?.geometry.scale == 2)
    #expect(allowed?.wasClamped == false)
}

@Test func invalidPlansAreRefused() {
    #expect(EditPlanBuilder.plan(
        EditRecipe(), stored: PixelSize(width: 0, height: 300), orientation: 1
    ) == nil)
    #expect(EditPlanBuilder.plan(
        EditRecipe(resize: .longSide(0)), stored: PixelSize(width: 400, height: 300), orientation: 1
    ) == nil)
    #expect(EditPlanBuilder.plan(
        EditRecipe(resize: .exact(width: 10000, height: 10000, fit: .fit, allowUpscale: true)),
        stored: PixelSize(width: 400, height: 300), orientation: 1
    ) == nil)
}

@Test func previewScalingKeepsTheComposition() {
    let stored = PixelSize(width: 4000, height: 3000)
    let recipe = EditRecipe(
        crop: CropRect(x: 0.1, y: 0.2, width: 0.5, height: 0.4),
        quarterTurns: 1,
        resize: .longSide(3000),
        overlays: [TextOverlay(kind: .caption, text: "Hello")]
    )
    guard let plan = EditPlanBuilder.plan(recipe, stored: stored, orientation: 6) else {
        Issue.record("no plan")
        return
    }
    let preview = plan.scaled(toLongSide: 1000)
    #expect(preview.outputLongSide == 1000)
    let factor = Double(preview.output.width) / Double(plan.output.width)
    #expect(abs(factor - 0.5) < 1e-9)
    #expect(abs(preview.geometry.scale - plan.geometry.scale * factor) < 1e-9)
    #expect(preview.overlays.count == 1)
    #expect(abs(preview.overlays[0].sizePixels - plan.overlays[0].sizePixels * factor) < 1e-6)

    let probe = CGPoint(
        x: plan.geometry.crop.minX + plan.geometry.crop.width * 0.37,
        y: plan.geometry.crop.minY + plan.geometry.crop.height * 0.61
    )
    let mapped = FrameTransform.apply(plan.geometry.displayToOutput, probe)
    let previewMapped = FrameTransform.apply(preview.geometry.displayToOutput, probe)
    #expect(abs(previewMapped.x - mapped.x * factor) < 0.01)
    #expect(abs(previewMapped.y - mapped.y * factor) < 0.01)

    #expect(plan.scaled(toLongSide: 99_999).output == plan.output)
}

@Test func coreGraphicsTransformCompensatesTheFlip() {
    let stored = PixelSize(width: 400, height: 300)
    let plan = EditPlanBuilder.plan(
        EditRecipe(crop: CropRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)),
        stored: stored, orientation: 1
    )!
    // A source pixel at the top-left of the crop: top-left output (0, 0), bottom-left CG (0, outH).
    let topLeftCrop = CGPoint(x: 100, y: 75)
    let outputPoint = FrameTransform.apply(plan.geometry.sourceToOutput, topLeftCrop)
    #expect(abs(outputPoint.x) < 0.01 && abs(outputPoint.y) < 0.01)

    // The same point in the source's CG space is (100, 300 − 75); mapping it through the CG transform
    // must land at (0, outH).
    let cgPoint = CGPoint(x: 100, y: 300 - 75)
    let mapped = FrameTransform.apply(plan.coreGraphicsTransform, cgPoint)
    #expect(abs(mapped.x) < 0.01)
    #expect(abs(mapped.y - Double(plan.output.height)) < 0.01)
}

@Test func overlaySizesAreFractionsOfTheLongSide() {
    let caption = TextOverlay(kind: .caption, text: "Hello")
    let plan = EditPlanBuilder.plan(
        EditRecipe(overlays: [caption]), stored: PixelSize(width: 1000, height: 800), orientation: 1
    )!
    #expect(plan.overlays.count == 1)
    #expect(abs(plan.overlays[0].sizePixels - 45) < 1e-9)
    #expect(abs(plan.overlays[0].maxWidthPixels - 900) < 1e-9)
    guard case .anchored(let anchor, let margin) = plan.overlays[0].placement else {
        Issue.record("expected an anchored placement")
        return
    }
    #expect(anchor == .bottom)
    #expect(abs(margin - 40) < 1e-9)

    let dropped = EditPlanBuilder.plan(
        EditRecipe(overlays: [TextOverlay(kind: .caption, text: "   ")]),
        stored: PixelSize(width: 1000, height: 800), orientation: 1
    )
    #expect(dropped?.overlays.isEmpty == true)
}

@Test func tiledOverlaysCoverTheCanvas() {
    var watermark = TextOverlay(kind: .watermark, text: "© A")
    watermark.placement = .tiled(
        angleDegrees: -30, columnSpacingFraction: 0.25, rowSpacingFraction: 0.25
    )
    let plan = EditPlanBuilder.plan(
        EditRecipe(overlays: [watermark]),
        stored: PixelSize(width: 2000, height: 1000), orientation: 1
    )!
    guard case .tiled(_, let centres) = plan.overlays[0].placement else {
        Issue.record("expected a tiled placement")
        return
    }
    #expect(centres.count == 8)
    #expect(centres.allSatisfy { $0.x > 0 && $0.x < 2000 && $0.y > 0 && $0.y < 1000 })

    let preview = plan.scaled(toLongSide: 1000)
    guard case .tiled(_, let previewCentres) = preview.overlays[0].placement else {
        Issue.record("expected a tiled placement")
        return
    }
    #expect(previewCentres.count == 8)
    #expect(abs(previewCentres[0].x - centres[0].x / 2) < 1e-6)
}

@Test func identityRecipeIsRecognised() {
    #expect(EditRecipe().isIdentity(for: .jpeg))
    #expect(!EditRecipe().isIdentity(for: .png))
    #expect(!EditRecipe(crop: CropRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5))
        .isIdentity(for: .jpeg))
    #expect(!EditRecipe(quarterTurns: 1).isIdentity(for: .jpeg))
    #expect(!EditRecipe(resize: .longSide(1000)).isIdentity(for: .jpeg))
    #expect(!EditRecipe(overlays: [TextOverlay(text: "x")]).isIdentity(for: .jpeg))
    #expect(!EditRecipe(flipHorizontal: true).isIdentity(for: .jpeg))
    var png = EditRecipe()
    png.format.kind = .png
    #expect(png.isIdentity(for: .png))
}

@Test func outputFormatExtensions() {
    #expect(OutputFormat(kind: .jpeg).fileExtension == "jpg")
    #expect(OutputFormat(kind: .png).fileExtension == "png")
    #expect(OutputFormat(kind: .tiff).fileExtension == "tiff")
    #expect(OutputFormat(kind: .heic).fileExtension == "heic")
    #expect(OutputFormat(kind: .avif).fileExtension == "avif")
    #expect(OutputFormat(kind: .png).isLossy == false)
    #expect(OutputFormat(kind: .jpeg).isLossy)
}

@Test func exportNamingHonoursCollisionPolicies() {
    let source = EditSource(
        mediaID: MediaID(rawValue: 1),
        url: URL(fileURLWithPath: "/tmp/IMG_0001.JPG"),
        name: "IMG_0001.JPG"
    )
    let free: (String) -> Bool = { _ in false }
    #expect(ExportNaming.fileName(for: source, format: OutputFormat(), policy: .init(), taken: free)
        == "IMG_0001.jpg")

    let firstTaken: (String) -> Bool = { $0 == "IMG_0001.jpg" }
    #expect(ExportNaming.fileName(for: source, format: OutputFormat(), policy: .init(),
                                  taken: firstTaken) == "IMG_0001-2.jpg")
    let twoTaken: (String) -> Bool = { $0 == "IMG_0001.jpg" || $0 == "IMG_0001-2.jpg" }
    #expect(ExportNaming.fileName(for: source, format: OutputFormat(), policy: .init(),
                                  taken: twoTaken) == "IMG_0001-3.jpg")

    #expect(ExportNaming.fileName(
        for: source, format: OutputFormat(),
        policy: .init(collision: .skip), taken: firstTaken
    ) == nil)
    #expect(ExportNaming.fileName(
        for: source, format: OutputFormat(),
        policy: .init(collision: .overwrite), taken: firstTaken
    ) == "IMG_0001.jpg")
    #expect(ExportNaming.fileName(
        for: source, format: OutputFormat(),
        policy: .init(stem: .editedSuffix), taken: free
    ) == "IMG_0001-edited.jpg")
    #expect(ExportNaming.fileName(
        for: source, format: OutputFormat(), policy: .init(customPrefix: "trip/"), taken: free
    ) == "trip-IMG_0001.jpg")
    #expect(ExportNaming.fileName(
        for: source, format: OutputFormat(kind: .heic), policy: .init(),
        taken: { $0 == "IMG_0001.heic" }
    ) == "IMG_0001-2.heic")
}

@Test func exportNamingUsesTheCaptureDay() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .current
    let date = calendar.date(from: DateComponents(year: 2024, month: 3, day: 5, hour: 12))!
    let source = EditSource(
        mediaID: MediaID(rawValue: 1),
        url: URL(fileURLWithPath: "/tmp/IMG_0001.JPG"),
        name: "IMG_0001.JPG",
        captureDate: date
    )
    let name = ExportNaming.fileName(
        for: source, format: OutputFormat(), policy: .init(stem: .captureDate), taken: { _ in false }
    )
    #expect(name == "2024-03-05 IMG_0001.jpg")
}

private func approximatelyEqual(_ lhs: CropRect, _ rhs: CropRect) -> Bool {
    abs(lhs.x - rhs.x) < 1e-9 && abs(lhs.y - rhs.y) < 1e-9
        && abs(lhs.width - rhs.width) < 1e-9 && abs(lhs.height - rhs.height) < 1e-9
}
