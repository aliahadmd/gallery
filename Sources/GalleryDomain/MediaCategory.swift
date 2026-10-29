import Foundation

public struct SampledFeatures: Sendable, Hashable, Codable {
    public var side: Int
    public var hasAlpha: Bool
    public var transparentRatio: Double
    public var colorCount: Int
    public var flatRatio: Double
    public var edgeRatio: Double

    public init(
        side: Int, hasAlpha: Bool, transparentRatio: Double, colorCount: Int,
        flatRatio: Double, edgeRatio: Double
    ) {
        self.side = side
        self.hasAlpha = hasAlpha
        self.transparentRatio = transparentRatio
        self.colorCount = colorCount
        self.flatRatio = flatRatio
        self.edgeRatio = edgeRatio
    }
}

/// What the cleanup classifier thinks a still is. `photo` is a verdict ("we looked and it is an ordinary
/// photograph"), distinct from `none` ("not classified yet").
public enum MediaCategory: Int16, Sendable, Hashable, Codable, CaseIterable {
    case none = 0
    case screenshot = 1
    case document = 2
    case graphic = 3
    case meme = 4
    case wallpaper = 5
    case photo = 6

    public var title: String {
        switch self {
        case .none: "Unclassified"
        case .screenshot: "Screenshots"
        case .document: "Documents & Receipts"
        case .graphic: "Icons & Graphics"
        case .meme: "Memes"
        case .wallpaper: "Wallpapers"
        case .photo: "Photos"
        }
    }

    public var symbol: String {
        switch self {
        case .none: "questionmark"
        case .screenshot: "camera.viewfinder"
        case .document: "doc.text"
        case .graphic: "square.grid.2x2"
        case .meme: "face.smiling"
        case .wallpaper: "rectangle.inset.filled"
        case .photo: "photo"
        }
    }

    /// The categories offered as cleanup shelves, in display order.
    public static let cleanupShelf: [MediaCategory] = [.screenshot, .document, .graphic, .meme, .wallpaper]
}

public enum CategoryReasonCode: String, Sendable, Hashable, Codable, CaseIterable {
    case appleScreenshotName
    case screenshotSubtype
    case screenshotName
    case deviceDimensions
    case deviceAspect
    case noCameraMetadata
    case cameraMetadata
    case uiLabels
    case ocrText
    case documentLabel
    case denseText
    case textLayout
    case accurateOCR
    case lowAesthetic
    case pageAspect
    case graphicLabel
    case photographicLabels
    case alphaChannel
    case flatColors
    case smallPalette
    case smallImage
    case square
    case imageExtension
    case faces
    case panorama
    case utilityFlag

    public var text: String {
        switch self {
        case .appleScreenshotName: "Named like a screenshot"
        case .screenshotSubtype: "Recognised as a screenshot"
        case .screenshotName: "“screenshot” in the name"
        case .deviceDimensions: "Exact screen dimensions"
        case .deviceAspect: "Screen-shaped aspect ratio"
        case .noCameraMetadata: "No camera metadata"
        case .cameraMetadata: "Has camera metadata"
        case .uiLabels: "Contains interface elements"
        case .ocrText: "Contains text"
        case .documentLabel: "Looks like a document"
        case .denseText: "Dense text"
        case .textLayout: "Text laid out in many blocks"
        case .accurateOCR: "Text needed the accurate pass"
        case .lowAesthetic: "Low photographic quality"
        case .pageAspect: "Page-shaped aspect ratio"
        case .graphicLabel: "Looks like a graphic or logo"
        case .photographicLabels: "Looks like a photograph"
        case .alphaChannel: "Has transparency"
        case .flatColors: "Flat colours"
        case .smallPalette: "Small colour palette"
        case .smallImage: "Small image"
        case .square: "Square"
        case .imageExtension: "Image-editing file type"
        case .faces: "Contains faces"
        case .panorama: "Panorama"
        case .utilityFlag: "Flagged as utility"
        }
    }
}

public struct CategoryReason: Sendable, Hashable, Codable {
    public var code: CategoryReasonCode
    public var weight: Double
    public var detail: String?

    public init(code: CategoryReasonCode, weight: Double, detail: String? = nil) {
        self.code = code
        self.weight = weight
        self.detail = detail
    }
}

/// What the classifier concluded, with the evidence that got it there. The evidence is what the inspector
/// shows and what makes a bulk "select all" reviewable.
public struct CategoryEvidence: Sendable, Hashable, Codable {
    public var category: MediaCategory
    public var confidence: Double
    public var score: Double
    public var runnerUp: MediaCategory
    public var runnerUpScore: Double
    public var reasons: [CategoryReason]
    public var version: Int
    public var revision: String

    public init(
        category: MediaCategory, confidence: Double, score: Double,
        runnerUp: MediaCategory = .none, runnerUpScore: Double = 0,
        reasons: [CategoryReason], version: Int, revision: String
    ) {
        self.category = category
        self.confidence = confidence
        self.score = score
        self.runnerUp = runnerUp
        self.runnerUpScore = runnerUpScore
        self.reasons = reasons
        self.version = version
        self.revision = revision
    }
}

/// A count for the Cleanup shelf.
public struct CategoryCount: Sendable, Hashable, Identifiable {
    public var category: MediaCategory
    public var count: Int
    public var id: MediaCategory { category }

    public init(category: MediaCategory, count: Int) {
        self.category = category
        self.count = count
    }
}
