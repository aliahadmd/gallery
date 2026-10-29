import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import GalleryAnalysis
import GalleryDomain
import GalleryImaging

/// A horizontal gradient, dark to light or the other way. Every adjacent pair differs in the same direction,
/// so the hash is all ones or all zeros — a pattern a hash test can reason about.
private func gradient(width: Int, height: Int, ascending: Bool) -> CGImage {
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    for column in 0..<9 {
        let position = Double(column) / 8
        let value = ascending ? position : 1 - position
        context.setFillColor(CGColor(gray: value, alpha: 1))
        let x = Double(column * width / 9)
        context.fill(CGRect(x: x, y: 0, width: Double(width / 9 + 1), height: Double(height)))
    }
    return context.makeImage()!
}

private func roundTrip(_ image: CGImage) throws -> CGImage {
    let data = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(
        data, "public.jpeg" as CFString, 1, nil
    ))
    CGImageDestinationAddImage(destination, image, nil)
    #expect(CGImageDestinationFinalize(destination))
    let source = try #require(CGImageSourceCreateWithData(data, nil))
    return try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
}

@Suite("Perceptual hashing")
struct DHashTests {
    @Test("A gradient and its inverse are opposite, and a resized copy is the same picture")
    func gradientPolarity() throws {
        let original = gradient(width: 200, height: 120, ascending: true)
        let resized = gradient(width: 45, height: 27, ascending: true)
        let reversed = gradient(width: 200, height: 120, ascending: false)

        #expect(DHash.hash(original) == DHash.hash(resized), "resize is not a different photograph")
        #expect(DHash.distance(DHash.hash(original), DHash.hash(reversed)) == 64)
    }

    @Test("Re-encoding through JPEG does not move the hash")
    func survivesReencoding() throws {
        let original = gradient(width: 200, height: 120, ascending: true)
        let decoded = try roundTrip(original)
        #expect(DHash.distance(DHash.hash(original), DHash.hash(decoded)) <= 2)
    }
}

@Suite("Analysis rules")
struct AnalysisRulesTests {
    @Test("Labels map onto the curated vocabulary, best first and without duplicates")
    func tagMapping() {
        let labels = [
            SceneLabel(identifier: "food.pizza", confidence: 0.8),
            SceneLabel(identifier: "food", confidence: 0.7),
            SceneLabel(identifier: "beverage.coffee", confidence: 0.5),
            SceneLabel(identifier: "outdoor", confidence: 0.9),
        ]
        #expect(AnalysisRules.tags(from: labels, ocrCharacters: 0) == ["food", "drinks"])
    }

    @Test("A weak label does not tag, and enough text adds the text tag")
    func tagThresholds() {
        #expect(AnalysisRules.tags(from: [SceneLabel(identifier: "food", confidence: 0.2)],
                                   ocrCharacters: 0).isEmpty)
        #expect(AnalysisRules.tags(from: [], ocrCharacters: 60) == ["text"])
        #expect(AnalysisRules.tags(from: [], ocrCharacters: 10).isEmpty)
    }

    @Test("Utility is a screenshot, the model's verdict, or text with no aesthetic merit")
    func utility() {
        #expect(AnalysisRules.isUtility(aesthetic: 0.5, ocrCharacters: 0, labels: [],
                                        subtype: .screenshot, modelSaidSo: false))
        #expect(AnalysisRules.isUtility(aesthetic: 0.8, ocrCharacters: 0, labels: [],
                                        subtype: [], modelSaidSo: true))
        #expect(AnalysisRules.isUtility(aesthetic: 0.01, ocrCharacters: 80, labels: [],
                                        subtype: [], modelSaidSo: false))
        #expect(!AnalysisRules.isUtility(aesthetic: 0.6, ocrCharacters: 80, labels: [],
                                         subtype: [], modelSaidSo: false))
    }

    @Test("Recognised text is one line, whitespace collapsed, cut on a word")
    func ocrNormalization() throws {
        #expect(AnalysisRules.normalizedOCR(["  Total 42.00 ", "", "Thank\nyou"])
                == "Total 42.00 Thank you")
        let long = String(repeating: "word ", count: 2_000)
        let text = try #require(AnalysisRules.normalizedOCR([long], limit: 100))
        #expect(text.count <= 100)
        #expect(!text.hasSuffix(" "))
        #expect(AnalysisRules.normalizedOCR(["   "]) == nil)
    }
}
