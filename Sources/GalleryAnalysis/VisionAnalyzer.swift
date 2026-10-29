import Foundation
import CoreMedia
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
        /// Nil for video: a clip has no single picture to compare for duplicates.
        public var dhash: UInt64?
        /// Boxes and embeddings; the cluster id is filled in by the face index, which is not Vision's job.
        public var faces: [DetectedFace]
        /// Frames sampled, 0 for a still.
        public var frames: Int
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
            faces: faces,
            frames: 0
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

    /// A clip, sampled rather than watched.
    ///
    /// `VNVideoProcessor` decodes once and hands frames to the requests on a cadence, which is the only way to
    /// look at a video without reading it frame by frame into memory. Classification runs at 1 fps, text every
    /// six seconds, faces every three; a talking head produces one face row, not ninety.
    public func analyzeVideo(at url: URL, duration: CMTime) -> Still? {
        let seconds = duration.seconds
        guard seconds.isFinite, seconds > 0 else { return nil }
        let collector = VideoCollector()
        let processor = VNVideoProcessor(url: url)

        let classify = VNClassifyImageRequest { request, error in
            guard error == nil else { return }
            collector.addFrame((request.results ?? []).compactMap { $0 as? VNClassificationObservation })
        }
        let text: VNRecognizeTextRequest = VNRecognizeTextRequest { request, error in
            guard error == nil else { return }
            collector.addText((request.results ?? []).compactMap { $0 as? VNRecognizedTextObservation })
        }
        text.recognitionLevel = .fast
        text.usesLanguageCorrection = true
        let faces = VNDetectFaceCaptureQualityRequest { request, error in
            guard error == nil else { return }
            collector.addFaces((request.results ?? []).compactMap { $0 as? VNFaceObservation })
        }

        let classifyOptions = VNVideoProcessor.RequestProcessingOptions()
        classifyOptions.cadence = VNVideoProcessor.FrameRateCadence(1)
        let textOptions = VNVideoProcessor.RequestProcessingOptions()
        textOptions.cadence = VNVideoProcessor.TimeIntervalCadence(6)
        let faceOptions = VNVideoProcessor.RequestProcessingOptions()
        faceOptions.cadence = VNVideoProcessor.TimeIntervalCadence(3)

        do {
            try processor.addRequest(classify, processingOptions: classifyOptions)
            try processor.addRequest(text, processingOptions: textOptions)
            try processor.addRequest(faces, processingOptions: faceOptions)
            try processor.analyze(CMTimeRange(start: .zero, duration: duration))
        } catch {
            return nil
        }
        return collector.still()
    }

    private func textRequest(level: VNRequestTextRecognitionLevel) -> VNRecognizeTextRequest {        let request = VNRecognizeTextRequest()
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

/// Frames from a video arrive on Vision's own queues; this is the one place a clip's evidence accumulates.
///
/// Classification is counted rather than averaged: a label that only one frame saw is a flicker, not a scene.
/// Faces are deduplicated by box overlap, so a person standing in shot for thirty frames is one row.
private final class VideoCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var frameCount = 0
    private var labelTotals: [String: (sum: Double, count: Int)] = [:]
    private var lines: [String] = []
    private var faces: [DetectedFace] = []

    func addFrame(_ observations: [VNClassificationObservation]) {
        lock.withLock {
            frameCount += 1
            for observation in observations.prefix(5) where observation.confidence >= 0.3 {
                var entry = labelTotals[observation.identifier] ?? (0, 0)
                entry.sum += Double(observation.confidence)
                entry.count += 1
                labelTotals[observation.identifier] = entry
            }
        }
    }

    func addText(_ observations: [VNRecognizedTextObservation]) {
        let strings = observations
            .compactMap { $0.topCandidates(1).first }
            .filter { $0.confidence >= 0.3 }
            .map(\.string)
        guard !strings.isEmpty else { return }
        lock.withLock { lines.append(contentsOf: strings) }
    }

    func addFaces(_ observations: [VNFaceObservation]) {
        guard !observations.isEmpty else { return }
        lock.withLock {
            for observation in observations {
                let box = observation.boundingBox
                let quality = Double(observation.faceCaptureQuality ?? 0)
                if let index = faces.firstIndex(where: { Self.overlap($0, box) > 0.5 }) {
                    if quality > faces[index].quality {
                        faces[index] = Self.face(observation, quality: quality)
                    }
                } else {
                    faces.append(Self.face(observation, quality: quality))
                }
            }
        }
    }

    func still() -> VisionAnalyzer.Still {
        lock.withLock {
            let threshold = max(1, Int(Double(frameCount) * 0.2))
            let labels = labelTotals
                .filter { $0.value.count >= threshold || $0.value.sum / Double($0.value.count) >= 0.3 }
                .sorted { lhs, rhs in
                    lhs.value.count == rhs.value.count
                        ? lhs.value.sum > rhs.value.sum
                        : lhs.value.count > rhs.value.count
                }
                .prefix(8)
                .map { SceneLabel(identifier: $0.key, confidence: $0.value.sum / Double($0.value.count)) }
            var seen = Set<String>()
            let unique = lines.filter { seen.insert($0).inserted }
            return VisionAnalyzer.Still(
                labels: Array(labels),
                ocrText: AnalysisRules.normalizedOCR(unique, limit: 4096),
                ocrBlocks: unique.count,
                ocrAccurate: false,
                aesthetic: 0,
                isUtility: false,
                dhash: nil,
                faces: faces,
                frames: frameCount
            )
        }
    }

    private static func face(_ observation: VNFaceObservation, quality: Double) -> DetectedFace {
        let box = observation.boundingBox
        // No embedding: the processor does not hand out per-frame pixels, and a face without a descriptor is
        // a box and a count — it must not become a person on the People shelf.
        return DetectedFace(x: Double(box.origin.x), y: Double(box.origin.y),
                            width: Double(box.width), height: Double(box.height),
                            confidence: Double(observation.confidence), quality: quality, embedding: [])
    }

    private static func overlap(_ face: DetectedFace, _ box: CGRect) -> Double {
        let a = CGRect(x: face.x, y: face.y, width: face.width, height: face.height)
        let intersection = a.intersection(box)
        guard !intersection.isNull else { return 0 }
        let area = intersection.width * intersection.height
        let union = a.width * a.height + box.width * box.height - area
        return union > 0 ? Double(area / union) : 0
    }
}
