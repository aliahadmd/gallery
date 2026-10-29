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
        public var maximumFaces: Int
        public var minimumFaceConfidence: Double
        public var minimumFaceQuality: Double
        public var minimumFaceArea: Double
        /// How long one file may take before the remaining steps are skipped and what is done is kept.
        public var itemBudget: Duration

        public init(maxPixel: Int32 = 1024, accuratePixel: Int32 = 2048, classificationLimit: Int = 8,
                    ocrCharacterLimit: Int = 4096, tagConfidence: Double = 0.35, maximumTags: Int = 4,
                    maximumFaces: Int = 8, minimumFaceConfidence: Double = 0.4,
                    minimumFaceQuality: Double = 0.2, minimumFaceArea: Double = 0.004,
                    itemBudget: Duration = .seconds(4)) {
            self.maxPixel = maxPixel
            self.accuratePixel = accuratePixel
            self.classificationLimit = max(1, classificationLimit)
            self.ocrCharacterLimit = max(0, ocrCharacterLimit)
            self.tagConfidence = tagConfidence
            self.maximumTags = max(0, maximumTags)
            self.maximumFaces = max(0, maximumFaces)
            self.minimumFaceConfidence = minimumFaceConfidence
            self.minimumFaceQuality = minimumFaceQuality
            self.minimumFaceArea = minimumFaceArea
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
        /// Boxes and embeddings; the cluster id is filled in by the face index, which is not Vision's job.
        public var faces: [DetectedFace]
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

        var faces: [DetectedFace] = []
        if !expired() {
            faces = detectFaces(in: frame)
        }

        return Still(
            labels: labels,
            ocrText: AnalysisRules.normalizedOCR(lines, limit: configuration.ocrCharacterLimit),
            ocrBlocks: blocks,
            ocrAccurate: accurate,
            aesthetic: aesthetic,
            isUtility: modelSaysUtility,
            dhash: DHash.hash(frame),
            faces: faces
        )
    }

    /// Faces, with the quality Vision reports and a feature print per face.
    ///
    /// This SDK has no face-identity request, so the print is a general image descriptor taken over the face's
    /// region with a little padding. That is enough to cluster one person's photos together; it is not a
    /// recognition model, and the People shelf is built to be corrected by the user because of it.
    private func detectFaces(in frame: CGImage) -> [DetectedFace] {
        let request = VNDetectFaceCaptureQualityRequest()
        guard (try? VNImageRequestHandler(cgImage: frame).perform([request])) != nil,
              let observations = request.results else { return [] }

        let eligible = observations
            .filter { observation in
                let box = observation.boundingBox
                let area = Double(box.width * box.height)
                let quality = Double(observation.faceCaptureQuality ?? 1)
                return Double(observation.confidence) >= configuration.minimumFaceConfidence
                    && area >= configuration.minimumFaceArea
                    && quality >= configuration.minimumFaceQuality
            }
            .sorted { lhs, rhs in
                Self.weight(of: lhs) > Self.weight(of: rhs)
            }
            .prefix(configuration.maximumFaces)

        var faces: [DetectedFace] = []
        for observation in eligible {
            let print = VNGenerateImageFeaturePrintRequest()
            print.regionOfInterest = Self.padded(observation.boundingBox)
            guard (try? VNImageRequestHandler(cgImage: frame).perform([print])) != nil,
                  let result = print.results?.first as? VNFeaturePrintObservation,
                  let vector = Self.floats(from: result) else { continue }
            let box = observation.boundingBox
            let x = Double(box.origin.x)
            let y = Double(box.origin.y)
            let width = Double(box.width)
            let height = Double(box.height)
            let confidence = Double(observation.confidence)
            let quality = Double(observation.faceCaptureQuality ?? 0.5)
            faces.append(DetectedFace(
                x: x, y: y, width: width, height: height,
                confidence: confidence, quality: quality, embedding: vector
            ))
        }
        return faces
    }

    private static func weight(of observation: VNFaceObservation) -> Double {
        let box = observation.boundingBox
        return Double(box.width * box.height) * Double(observation.confidence)
    }

    /// A face print from exactly the box is tight; a little background around it is what a person-recognition
    /// model would see, and it makes two shots of one face more alike.
    private static func padded(_ box: CGRect, by fraction: CGFloat = 0.2) -> CGRect {
        let expanded = box.insetBy(dx: -box.width * fraction, dy: -box.height * fraction)
        return expanded.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    private static func floats(from observation: VNFeaturePrintObservation) -> [Float]? {
        guard observation.elementType == .float,
              observation.elementCount > 0,
              observation.data.count >= observation.elementCount * 4 else { return nil }
        var values = [Float](repeating: 0, count: observation.elementCount)
        _ = values.withUnsafeMutableBytes { observation.data.copyBytes(to: $0) }
        return values
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
