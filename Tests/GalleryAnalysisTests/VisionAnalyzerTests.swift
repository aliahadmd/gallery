import AVFoundation
import CoreGraphics
import CoreMedia
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

/// A two-second H.264 clip with one line of text burned into every frame, or a blank one when `text` is empty.
private func titleClip(_ text: String, seconds: Int = 2) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("analysis-\(UUID().uuidString).mov")
    let width = 640
    let height = 360
    let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264,
        AVVideoWidthKey: width,
        AVVideoHeightKey: height,
    ])
    input.expectsMediaDataInRealTime = false
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
        kCVPixelBufferWidthKey as String: width,
        kCVPixelBufferHeightKey as String: height,
    ])
    writer.add(input)
    #expect(writer.startWriting())
    writer.startSession(atSourceTime: .zero)
    let font = CTFontCreateWithName("Helvetica-Bold" as CFString, 92, nil)
    for frame in 0..<(10 * seconds) {
        while !input.isReadyForMoreMediaData { usleep(2_000) }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
        let pixelBuffer = try #require(buffer)
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        if let context = CGContext(
            data: CVPixelBufferGetBaseAddress(pixelBuffer), width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
        ) {
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            if !text.isEmpty {
                let attributed = NSAttributedString(string: text, attributes: [
                    kCTFontAttributeName as NSAttributedString.Key: font,
                    kCTForegroundColorAttributeName as NSAttributedString.Key: CGColor(gray: 0, alpha: 1),
                ])
                context.textPosition = CGPoint(x: 40, y: 130)
                CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
            }
        }
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
        adaptor.append(pixelBuffer, withPresentationTime: CMTime(value: Int64(frame), timescale: 10))
    }
    input.markAsFinished()
    let done = DispatchSemaphore(value: 0)
    writer.finishWriting { done.signal() }
    done.wait()
    #expect(writer.status == .completed)
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

    @Test("A clip with a title card is read at a sampled cadence, and a blank one invents nothing")
    func videoAnalysis() async throws {
        let titled = try titleClip("ZEBRA CROSSING")
        let blank = try titleClip("")
        defer {
            try? FileManager.default.removeItem(at: titled)
            try? FileManager.default.removeItem(at: blank)
        }
        let analyzer = VisionAnalyzer()

        let read = try #require(analyzer.analyzeVideo(
            at: titled, duration: try await AVURLAsset(url: titled).load(.duration)
        ))
        #expect(read.ocrText?.contains("ZEBRA") == true)
        #expect(read.frames >= 2, "a two-second clip is sampled, not watched")
        #expect(read.dhash == nil, "a clip has no single picture to hash")

        let silent = try #require(analyzer.analyzeVideo(
            at: blank, duration: try await AVURLAsset(url: blank).load(.duration)
        ))
        #expect(silent.ocrText == nil)
    }
}
