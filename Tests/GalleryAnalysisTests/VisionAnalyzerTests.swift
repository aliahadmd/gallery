import CoreGraphics
import CoreText
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import GalleryAnalysis
import GalleryDomain
import GalleryImaging

/// Real Vision, real files. Gated because it costs seconds and because a result can move when the OS ships a
/// new revision — the unit tests above are the ones that decide whether the code is right.
private let enabled = ProcessInfo.processInfo.environment["GALLERY_ANALYSIS_TESTS"] != nil

/// Renders text with CoreText and encodes a real JPEG. The words are ours, so the OCR assertion can be exact.
private func textImage(_ lines: [String], width: Int = 900, height: Int = 400) throws -> URL {
    let context = try #require(CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let font = CTFontCreateWithName("Helvetica-Bold" as CFString, 56, nil)
    for (index, line) in lines.enumerated() {
        let attributed = NSAttributedString(string: line, attributes: [
            kCTFontAttributeName as NSAttributedString.Key: font,
            kCTForegroundColorAttributeName as NSAttributedString.Key: CGColor(gray: 0, alpha: 1),
        ])
        let ctLine = CTLineCreateWithAttributedString(attributed)
        context.textPosition = CGPoint(x: 40, y: height - 110 - index * 110)
        CTLineDraw(ctLine, context)
    }
    let image = try #require(context.makeImage())
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("analysis-\(UUID().uuidString).jpg")
    let destination = try #require(CGImageDestinationCreateWithURL(
        url as CFURL, UTType.jpeg.identifier as CFString, 1, nil
    ))
    CGImageDestinationAddImage(destination, image, nil)
    #expect(CGImageDestinationFinalize(destination))
    return url
}

@Suite("Vision analysis", .enabled(if: enabled))
struct VisionAnalyzerTests {
    @Test("A rendered invoice is read exactly")
    func readsRenderedText() throws {
        let url = try textImage(["INVOICE", "Total 42.00", "Thank you"])
        defer { try? FileManager.default.removeItem(at: url) }

        let still = try #require(VisionAnalyzer().analyzeImage(at: url, subtype: []))

        #expect(still.ocrText?.contains("INVOICE") == true)
        #expect(still.ocrText?.contains("42.00") == true)
        #expect(still.ocrBlocks > 0)
        #expect(still.dhash != 0)
    }

    @Test("Classification, aesthetics and the hash all answer with sane values")
    func classificationAndScore() throws {
        let url = try textImage(["GALLERY"])
        defer { try? FileManager.default.removeItem(at: url) }

        let still = try #require(VisionAnalyzer().analyzeImage(at: url, subtype: []))

        #expect(!still.labels.isEmpty, "the classifier always has an opinion")
        #expect(still.labels.allSatisfy { (0...1).contains($0.confidence) })
        #expect((-1...1).contains(still.aesthetic))
        // Whatever it calls this, the mapping produces only slugs from the shelf's vocabulary.
        let slugs = Set(still.labels.flatMap { AnalysisRules.tags(from: [$0], ocrCharacters: 0) })
        #expect(slugs.isSubset(of: TagVocabulary.slugs))
    }

    @Test("An image with no text is not invented text")
    func silentImageHasNoText() throws {
        let context = try #require(CGContext(
            data: nil, width: 400, height: 300, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(gray: 0.4, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 400, height: 300))
        let image = try #require(context.makeImage())
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("analysis-\(UUID().uuidString).jpg")
        defer { try? FileManager.default.removeItem(at: url) }
        let destination = try #require(CGImageDestinationCreateWithURL(
            url as CFURL, UTType.jpeg.identifier as CFString, 1, nil
        ))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))

        let still = try #require(VisionAnalyzer().analyzeImage(at: url, subtype: []))
        #expect(still.ocrText == nil)
    }
}
