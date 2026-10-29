import Foundation
import Testing
@testable import GalleryAnalysis
import GalleryDomain
import GalleryImaging

private func input(
    _ name: String, ext: String = "jpg", subtype: MediaSubtype = [],
    size: (Int32, Int32)? = nil, device: String? = nil, gps: Bool = false, captured: Bool = false,
    labels: [(String, Double)] = [], ocrChars: Int = 0, blocks: Int = 0, accurate: Bool = false,
    aesthetic: Double = 0.5, utility: Bool = false, faces: Int = 0, sampled: SampledFeatures? = nil
) -> CategoryInput {
    CategoryInput(
        name: name, fileExtension: ext, subtype: subtype,
        pixelSize: size.map { PixelSize(width: $0.0, height: $0.1) },
        device: device, hasGPS: gps, hasCaptureDate: captured,
        labels: labels.map { SceneLabel(identifier: $0.0, confidence: $0.1) },
        ocrChars: ocrChars, ocrBlocks: blocks, ocrAccurate: accurate,
        aesthetic: aesthetic, isUtility: utility, faceCount: faces, sampled: sampled
    )
}

@Test func anAppleScreenshotAtDeviceSizeIsAScreenshot() {
    let evidence = CategoryClassifier.classify(input(
        "Screenshot 2026-10-29 at 09.12.png", ext: "png", subtype: .screenshot,
        size: (1170, 2532), labels: [("user interface", 0.8)],
        ocrChars: 40, blocks: 5, utility: true
    ))
    #expect(evidence.category == .screenshot)
    #expect(evidence.confidence >= 0.9)
    #expect(evidence.reasons.contains { $0.code == .screenshotSubtype })
    #expect(evidence.reasons.contains { $0.code == .deviceDimensions })
}

@Test func aCameraPhotoNamedScreenshotStaysAPhoto() {
    let evidence = CategoryClassifier.classify(input(
        "my screenshot from the trip.jpg", size: (4032, 3024),
        device: "iPhone 15 Pro", gps: true, captured: true,
        labels: [("mountain", 0.9)], aesthetic: 0.7
    ))
    #expect(evidence.category == .photo)
}

@Test func aDenseDocumentIsADocument() {
    let evidence = CategoryClassifier.classify(input(
        "scan.jpg", size: (3024, 4032), labels: [("document", 0.8)],
        ocrChars: 400, blocks: 12, aesthetic: 0.02
    ))
    #expect(evidence.category == .document)
    #expect(evidence.reasons.contains { $0.code == .documentLabel })
    #expect(evidence.reasons.count <= 8)
}

@Test func aFlatTransparentSquareIsAGraphic() {
    let evidence = CategoryClassifier.classify(input(
        "logo.png", ext: "png", size: (256, 256), labels: [("logo", 0.8)],
        sampled: SampledFeatures(
            side: 96, hasAlpha: true, transparentRatio: 0.12, colorCount: 20,
            flatRatio: 0.9, edgeRatio: 0.08
        )
    ))
    #expect(evidence.category == .graphic)
    #expect(evidence.reasons.contains { $0.code == .alphaChannel })
    #expect(evidence.reasons.contains { $0.code == .flatColors })
}

@Test func aSmallImageWithOverlaidTextIsAMeme() {
    let evidence = CategoryClassifier.classify(input(
        "funny.jpg", size: (1080, 1350), labels: [("cartoon", 0.7)],
        ocrChars: 60, blocks: 3, aesthetic: 0.3
    ))
    #expect(evidence.category == .meme)
}

@Test func aScreenSizedImageWithNoTextIsAWallpaper() {
    let evidence = CategoryClassifier.classify(input(
        "IMG_4021.jpg", size: (3024, 1964), labels: [("landscape", 0.8)], aesthetic: 0.7
    ))
    #expect(evidence.category == .wallpaper)
}

@Test func anOrdinaryCameraPhotoStaysAPhoto() {
    let evidence = CategoryClassifier.classify(input(
        "IMG_0001.jpg", size: (6000, 4000), device: "iPhone 15", gps: true, captured: true,
        labels: [("person", 0.9)], aesthetic: 0.7, faces: 2
    ))
    #expect(evidence.category == .photo)
    #expect(evidence.confidence >= 0.4)
}

@Test func weakEvidenceIsNotEnough() {
    let evidence = CategoryClassifier.classify(input(
        "scan.jpg", size: (800, 600), labels: [("document", 0.45)],
        ocrChars: 80, blocks: 2
    ))
    #expect(evidence.category == .photo)
    #expect(evidence.score < 60)
}

@Test func anUnclassifiableBlankHasNoCategory() {
    let evidence = CategoryClassifier.classify(input("blob.jpg", size: (300, 300)))
    #expect(evidence.category == .photo)
    #expect(evidence.reasons.count <= 4)
}
