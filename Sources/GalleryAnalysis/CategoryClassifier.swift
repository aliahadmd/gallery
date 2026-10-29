import Foundation
import GalleryDomain
import GalleryImaging

/// Everything the classifier is allowed to know, all of it already on disk. No Vision call, no network.
public struct CategoryInput: Sendable {
    public var name: String
    public var fileExtension: String
    public var typeIdentifier: String
    public var subtype: MediaSubtype
    public var pixelSize: PixelSize?
    public var device: String?
    public var hasGPS: Bool
    public var hasCaptureDate: Bool
    public var labels: [SceneLabel]
    public var ocrChars: Int
    public var ocrBlocks: Int
    public var ocrAccurate: Bool
    public var aesthetic: Double
    public var isUtility: Bool
    public var faceCount: Int
    public var sampled: SampledFeatures?

    public init(
        name: String, fileExtension: String = "", typeIdentifier: String = "",
        subtype: MediaSubtype = [], pixelSize: PixelSize? = nil, device: String? = nil,
        hasGPS: Bool = false, hasCaptureDate: Bool = false, labels: [SceneLabel] = [],
        ocrChars: Int = 0, ocrBlocks: Int = 0, ocrAccurate: Bool = false,
        aesthetic: Double = 0, isUtility: Bool = false, faceCount: Int = 0,
        sampled: SampledFeatures? = nil
    ) {
        self.name = name
        self.fileExtension = fileExtension
        self.typeIdentifier = typeIdentifier
        self.subtype = subtype
        self.pixelSize = pixelSize
        self.device = device
        self.hasGPS = hasGPS
        self.hasCaptureDate = hasCaptureDate
        self.labels = labels
        self.ocrChars = ocrChars
        self.ocrBlocks = ocrBlocks
        self.ocrAccurate = ocrAccurate
        self.aesthetic = aesthetic
        self.isUtility = isUtility
        self.faceCount = faceCount
        self.sampled = sampled
    }
}

/// Deterministic, weighted, explainable type recognition. The Vision pipeline supplies labels, OCR stats and
/// aesthetics; this table turns them plus metadata and a few pixel facts into a category and the reasons for
/// it. Precision-first: a special category needs 60 points (65 for wallpapers) *and* a 20-point lead, or the
/// verdict is `photo`. No generative AI, no trained model, no network.
public enum CategoryClassifier {
    public static let version = 1
    public static let revision = "signals-v1"

    private static let documentWords = [
        "document", "receipt", "invoice", "whiteboard", "paper", "menu", "business card", "book",
    ]
    private static let graphicWords = [
        "logo", "graphic", "illustration", "diagram", "chart", "icon", "symbol", "clip art", "font",
        "cartoon",
    ]
    private static let photographicWords = [
        "sky", "plant", "flower", "food", "animal", "person", "building", "beach", "landscape",
        "mountain", "ocean", "tree", "portrait",
    ]
    private static let imageExtensions: Set<String> = ["png", "ico", "cur", "tif", "tiff", "psd", "gif"]

    /// Common screenshot/display pixel sizes. Normalised to short×long at startup, so the literals may be
    /// written in either orientation and a portrait screenshot still matches.
    private static let rawDeviceSizes = [
        "1170x2532", "1179x2556", "1284x2778", "1290x2796", "1320x2868",
        "1536x2048", "1640x2360", "1668x2388", "2048x2732", "2064x2752",
        "1280x800", "1440x900", "1512x982", "1680x1050", "1728x1117",
        "1920x1080", "2560x1600", "2560x1440", "2880x1800",
        "3024x1964", "3456x2234", "3840x2160", "5120x2880", "6016x3384",
    ]
    private static let deviceSizes: Set<String> = Set(rawDeviceSizes.compactMap { key in
        let parts = key.split(separator: "x").compactMap { Int($0) }
        guard parts.count == 2 else { return nil }
        return "\(min(parts[0], parts[1]))x\(max(parts[0], parts[1]))"
    })
    private static let deviceRatios: [Double] = rawDeviceSizes.compactMap { key in
        let parts = key.split(separator: "x").compactMap { Double($0) }
        guard parts.count == 2, parts[1] > 0 else { return nil }
        return min(parts[0], parts[1]) / max(parts[0], parts[1])
    }

    public static func classify(_ input: CategoryInput) -> CategoryEvidence {
        var scores: [MediaCategory: Double] = [
            .screenshot: 0, .document: 0, .graphic: 0, .meme: 0, .wallpaper: 0,
        ]
        var reasons: [MediaCategory: [CategoryReason]] = [:]

        func add(_ category: MediaCategory, _ code: CategoryReasonCode, _ weight: Double,
                 _ detail: String? = nil) {
            scores[category, default: 0] += weight
            reasons[category, default: []].append(
                CategoryReason(code: code, weight: weight, detail: detail)
            )
        }

        let name = input.name.lowercased()
        let noCamera = input.device == nil && !input.hasGPS && !input.hasCaptureDate
        let strongDocument = bestLabel(input.labels, matching: documentWords, atLeast: 0.6)
        let weakDocument = strongDocument == nil
            ? bestLabel(input.labels, matching: documentWords, atLeast: 0.4) : nil
        let graphicLabel = bestLabel(input.labels, matching: graphicWords, atLeast: 0.5)
        let photoLabel = bestLabel(input.labels, matching: photographicWords, atLeast: 0.4)
        let uiLabel = bestLabel(
            input.labels, matching: ["user interface", "web site", "menu", "screenshot", "text"],
            atLeast: 0.5
        )
        let captureName = ["screenshot", "screen-capture", "screen capture", "capture-", "cleanshot",
                           "snagit", "simulator-screenshot"].contains { name.hasPrefix($0) }
        let screenshotWord = name.contains("screenshot") || name.contains("screen shot")
        let longSide = input.pixelSize.map { Int($0.longSide) } ?? 0
        let aspect = input.pixelSize.map { Double($0.width) / Double(max(1, $0.height)) } ?? 1
        let normalizedAspect = aspect >= 1 ? aspect : 1 / aspect
        let deviceSize = input.pixelSize.map {
            "\(min($0.width, $0.height))x\(max($0.width, $0.height))"
        }.map(deviceSizes.contains) ?? false
        let deviceAspect = longSide >= 1000
            && deviceRatios.contains { abs($0 - normalizedAspect) / $0 <= 0.01 }
        let texty = input.ocrChars >= 20 && input.ocrBlocks >= 3
        let dense = input.ocrChars >= 300
        let text = input.ocrChars >= 80
        let small = longSide > 0 && longSide <= 512
        let tiny = longSide > 0 && longSide <= 256
        let medium = longSide > 0 && longSide <= 2048
        let square = normalizedAspect <= 1.1
        let pageAspect = normalizedAspect >= 1.2 && normalizedAspect <= 1.5
        let imageExtension = imageExtensions.contains(input.fileExtension.lowercased())
        let sampled = input.sampled
        let flat = sampled?.flatRatio ?? 0
        let palette = sampled?.colorCount ?? .max
        let alpha = sampled?.hasAlpha ?? false
        let transparent = (sampled?.transparentRatio ?? 0) > 0.02

        // Screenshot.
        if input.subtype.contains(.screenshot) {
            add(.screenshot, .screenshotSubtype, 60)
        } else if captureName {
            add(.screenshot, .appleScreenshotName, 45, input.name)
        } else if screenshotWord {
            add(.screenshot, .screenshotName, 15)
        }
        if deviceSize { add(.screenshot, .deviceDimensions, 30) }
        if deviceAspect { add(.screenshot, .deviceAspect, 10) }
        if noCamera { add(.screenshot, .noCameraMetadata, 10) }
        if uiLabel != nil { add(.screenshot, .uiLabels, 12, uiLabel) }
        if texty { add(.screenshot, .ocrText, 8) }
        if input.isUtility { add(.screenshot, .utilityFlag, 8) }
        if input.subtype.contains(.panorama) { add(.screenshot, .panorama, -15) }
        if input.faceCount > 0 { add(.screenshot, .faces, -25) }
        if input.device != nil { add(.screenshot, .cameraMetadata, -20) }
        if strongDocument != nil { add(.screenshot, .documentLabel, -15) }

        // Document.
        if strongDocument != nil {
            add(.document, .documentLabel, 40, strongDocument)
        } else if weakDocument != nil {
            add(.document, .documentLabel, 20, weakDocument)
        }
        if dense { add(.document, .denseText, 30) } else if text { add(.document, .denseText, 15) }
        if input.ocrBlocks >= 8 { add(.document, .textLayout, 10) }
        if input.ocrAccurate { add(.document, .accurateOCR, 5) }
        if input.aesthetic <= 0.1 { add(.document, .lowAesthetic, 10) }
        if pageAspect { add(.document, .pageAspect, 8) }
        if noCamera { add(.document, .noCameraMetadata, 5) }
        if input.faceCount > 0 { add(.document, .faces, -25) }
        if input.subtype.contains(.screenshot) { add(.document, .screenshotSubtype, -40) }
        if alpha { add(.document, .alphaChannel, -15) }
        if flat >= 0.85 && palette <= 32 { add(.document, .flatColors, -25) }

        // Icon / graphic.
        if alpha {
            add(.graphic, .alphaChannel, 40)
            if transparent { add(.graphic, .alphaChannel, 10) }
        }
        if flat >= 0.85 {
            add(.graphic, .flatColors, 25)
        } else if flat >= 0.70 {
            add(.graphic, .flatColors, 15)
        }
        if palette <= 32 { add(.graphic, .smallPalette, 12) }
        if small { add(.graphic, .smallImage, 15) } else if tiny { add(.graphic, .smallImage, 8) }
        if square { add(.graphic, .square, 8) }
        if imageExtension { add(.graphic, .imageExtension, 12) }
        if noCamera { add(.graphic, .noCameraMetadata, 10) }
        if graphicLabel != nil { add(.graphic, .graphicLabel, 15, graphicLabel) }
        if input.faceCount > 0 { add(.graphic, .faces, -30) }
        if photoLabel != nil { add(.graphic, .photographicLabels, -20) }
        if input.device != nil { add(.graphic, .cameraMetadata, -25) }
        if input.ocrChars >= 200 { add(.graphic, .denseText, -10) }
        if deviceSize { add(.graphic, .deviceDimensions, -25) }

        // Meme.
        if medium { add(.meme, .smallImage, 10) }
        if input.ocrChars >= 20 && input.ocrChars <= 300 { add(.meme, .ocrText, 15) }
        if input.ocrBlocks >= 2 { add(.meme, .textLayout, 8) }
        if noCamera { add(.meme, .noCameraMetadata, 10) }
        if square || normalizedAspect >= 1.2 { add(.meme, .square, 6) }
        if graphicLabel != nil { add(.meme, .graphicLabel, 12, graphicLabel) }
        if strongDocument != nil { add(.meme, .documentLabel, -20) }
        if input.ocrChars > 300 { add(.meme, .denseText, -15) }
        if deviceSize { add(.meme, .deviceDimensions, -20) }
        if captureName { add(.meme, .appleScreenshotName, -30) }

        // Wallpaper.
        if deviceSize { add(.wallpaper, .deviceDimensions, 30) }
        if noCamera { add(.wallpaper, .noCameraMetadata, 10) }
        if input.ocrChars < 10 { add(.wallpaper, .ocrText, 15) }
        if uiLabel == nil { add(.wallpaper, .uiLabels, 10) }
        if photoLabel != nil { add(.wallpaper, .photographicLabels, 10) }
        if input.subtype.contains(.screenshot) || captureName {
            add(.wallpaper, .screenshotSubtype, -40)
        }
        if strongDocument != nil { add(.wallpaper, .documentLabel, -20) }

        let clamped = scores.mapValues { min(120, max(0, $0)) }
        let ranked: [(category: MediaCategory, score: Double)] = clamped
            .map { (category: $0.key, score: $0.value) }
            .sorted { lhs, rhs in
                if lhs.score == rhs.score {
                    return precedence(lhs.category) < precedence(rhs.category)
                }
                return lhs.score > rhs.score
            }
        let winner = ranked[0]
        let runnerUp = ranked.count > 1 ? ranked[1] : (category: MediaCategory.none, score: 0.0)
        let threshold: Double = winner.category == .wallpaper ? 65 : 60
        let accepted = winner.score >= threshold && winner.score - runnerUp.score >= 20

        if accepted {
            let top = (reasons[winner.category] ?? [])
                .sorted { abs($0.weight) > abs($1.weight) }
                .prefix(8)
            return CategoryEvidence(
                category: winner.category,
                confidence: min(1, winner.score / 100),
                score: winner.score,
                runnerUp: runnerUp.category,
                runnerUpScore: runnerUp.score,
                reasons: Array(top),
                version: version,
                revision: revision
            )
        }
        let top = reasons.values.flatMap { $0 }
            .sorted { abs($0.weight) > abs($1.weight) }
            .prefix(4)
        return CategoryEvidence(
            category: .photo,
            confidence: min(1, 1 - winner.score / 60),
            score: winner.score,
            runnerUp: winner.category,
            runnerUpScore: winner.score,
            reasons: Array(top),
            version: version,
            revision: revision
        )
    }

    private static func precedence(_ category: MediaCategory) -> Int {
        switch category {
        case .screenshot: 0
        case .document: 1
        case .graphic: 2
        case .meme: 3
        case .wallpaper: 4
        default: 5
        }
    }

    private static func bestLabel(
        _ labels: [SceneLabel], matching words: [String], atLeast confidence: Double
    ) -> String? {
        labels
            .filter { $0.confidence >= confidence }
            .filter { label in
                let identifier = label.identifier.lowercased()
                return words.contains { identifier.contains($0) }
            }
            .max { $0.confidence < $1.confidence }?
            .identifier
    }
}
