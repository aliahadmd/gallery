import Foundation
import Vision
import GalleryDomain
import GalleryImaging

/// Runs Vision over one file. Synchronous on purpose: it is called inside a `BlockingLane`, and an async
/// wrapper around a synchronous framework call buys a hop and nothing else.
///
/// Every request is performed separately. One that throws — an unsupported image, a disabled model — costs
/// its own result and not the rest: a photo with no text is a fact, not a failure.
public struct VisionAnalyzer: Sendable {
    public struct Configuration: Sendable {
        /// The frame the cheap requests see. 1024 px is enough for classification, faces and a readable
        /// screenshot; dense documents escalate.
        public var maxPixel: Int32
        public var accuratePixel: Int32
        public var classificationLimit: Int
        public var ocrCharacterLimit: Int
        public var tagConfidence: Double
        public var maximumTags: Int
        /// How long one file may take before the remaining steps are skipped and what is done is kept.
        public var itemBudget: Duration

        public init(maxPixel: Int32 = 1024, accuratePixel: Int32 = 2048, classificationLimit: Int = 8,
                    ocrCharacterLimit: Int = 4096, tagConfidence: Double = 0.35, maximumTags: Int = 4,
                    itemBudget: Duration = .seconds(4)) {
            self.maxPixel = maxPixel
            self.accuratePixel = accuratePixel
            self.classificationLimit = max(1, classificationLimit)
            self.ocrCharacterLimit = max(0, ocrCharacterLimit)
            self.tagConfidence = tagConfidence
            self.maximumTags = max(0, maximumTags)
            self.itemBudget = itemBudget
        }
    }

    public struct Still: Sendable {
        public var labels: [SceneLabel]
        public var ocrText: String?
        public var ocrBlocks: Int
        public var ocrAccurate: Bool
        public var aesthetic: Double
        public var isUtility: Bool
        public var dhash: UInt64
    }

    private let configuration: Configuration

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    /// Nil when the file cannot be decoded at all; partial results when a request throws.
    public func analyzeImage(at url: URL, subtype: MediaSubtype) -> Still? {
        let clock = ContinuousClock()
        let start = clock.now
        func expired() -> Bool { clock.now - start > configuration.itemBudget }

        guard let frame = AnalysisImage.downsample(url: url, maxPixel: configuration.maxPixel) else {
            return nil
        }

        var labels: [SceneLabel] = []
        var aesthetic: Double = 0
        var modelSaysUtility = false
        var lines: [String] = []
        var blocks = 0
        var accurate = false

        let classify = VNClassifyImageRequest()
        if (try? VNImageRequestHandler(cgImage: frame).perform([classify])) != nil {
            labels = (classify.results ?? []).prefix(configuration.classificationLimit).map {
                SceneLabel(identifier: $0.identifier, confidence: Double($0.confidence))
            }
        }
        if !expired() {
            let aesthetics = VNCalculateImageAestheticsScoresRequest()
            if (try? VNImageRequestHandler(cgImage: frame).perform([aesthetics])) != nil,
               let observation = aesthetics.results?.first {
                aesthetic = Double(observation.overallScore)
                modelSaysUtility = observation.isUtility
            }
        }
        if !expired() {
            let fast = textRequest(level: .fast)
            if (try? VNImageRequestHandler(cgImage: frame).perform([fast])) != nil {
                lines = Self.lines(from: fast)
                blocks = fast.results?.count ?? 0
            }
        }

        // Dense text is unreadable at 1024 px, so the accurate tier re-decodes at 2048 — and only when the
        // picture is plausibly a document rather than every photograph paying 200 ms for nothing.
        if !expired(), shouldEscalate(lines: lines, labels: labels, subtype: subtype) {
            if let large = AnalysisImage.downsample(url: url, maxPixel: configuration.accuratePixel) {
                let accurateRequest = textRequest(level: .accurate)
                if (try? VNImageRequestHandler(cgImage: large).perform([accurateRequest])) != nil {
                    let accurateLines = Self.lines(from: accurateRequest)
                    if accurateLines.joined(separator: " ").count >= lines.joined(separator: " ").count {
                        lines = accurateLines
                        blocks = accurateRequest.results?.count ?? blocks
                        accurate = true
                    }
                }
            }
        }

        return Still(
            labels: labels,
            ocrText: AnalysisRules.normalizedOCR(lines, limit: configuration.ocrCharacterLimit),
            ocrBlocks: blocks,
            ocrAccurate: accurate,
            aesthetic: aesthetic,
            isUtility: modelSaysUtility,
            dhash: DHash.hash(frame)
        )
    }

    private func textRequest(level: VNRequestTextRecognitionLevel) -> VNRecognizeTextRequest {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = level
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        request.minimumTextHeight = level == .fast ? 0.01 : 0.005
        return request
    }

    private func shouldEscalate(lines: [String], labels: [SceneLabel], subtype: MediaSubtype) -> Bool {
        if subtype.contains(.screenshot) { return true }
        if lines.joined(separator: " ").count >= 40 { return true }
        return labels.contains { label in
            label.confidence >= 0.5
                && ["document", "receipt", "whiteboard", "paper", "invoice"]
                    .contains { label.identifier.lowercased().contains($0) }
        }
    }

    private static func lines(from request: VNRecognizeTextRequest) -> [String] {
        (request.results ?? []).compactMap { observation in
            guard let candidate = observation.topCandidates(1).first, candidate.confidence >= 0.3 else {
                return nil
            }
            return candidate.string
        }
    }
}
