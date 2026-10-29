import CoreGraphics
import Foundation

/// A colour in sRGB components, kept as plain numbers so a recipe is `Codable` and the editing model
/// never imports AppKit.
public struct RGBAColor: Sendable, Hashable, Codable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    public init(white: Double, alpha: Double = 1) {
        self.init(red: white, green: white, blue: white, alpha: alpha)
    }

    public static let white = RGBAColor(white: 1)
    public static let black = RGBAColor(white: 0)
    public static let clear = RGBAColor(white: 0, alpha: 0)
}

/// A crop in normalized display coordinates — after EXIF orientation, flips and quarter turns, which is
/// the space the user is looking at. Top-left origin, 0…1 on both axes.
public struct CropRect: Sendable, Hashable, Codable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public static let full = CropRect(x: 0, y: 0, width: 1, height: 1)

    public var isFull: Bool {
        abs(x) < 1e-9 && abs(y) < 1e-9 && abs(width - 1) < 1e-9 && abs(height - 1) < 1e-9
    }

    /// Clamps into the canvas without ever producing a zero-area rect, so a degenerate drag cannot make
    /// the plan builder divide by zero.
    public func clamped() -> CropRect {
        let w = min(max(width, 1e-4), 1)
        let h = min(max(height, 1e-4), 1)
        return CropRect(x: min(max(x, 0), 1 - w), y: min(max(y, 0), 1 - h), width: w, height: h)
    }

    /// The rect containing the images of this rect's corners under a clockwise quarter turn. This is what
    /// keeps the selected pixels selected when the user rotates the photo under an existing crop.
    public func rotated(quarterTurns: Int) -> CropRect {
        var rect = self
        for _ in 0..<(((quarterTurns % 4) + 4) % 4) {
            // Clockwise: (x, y) ↦ (1 − y, x), so the rect's x range becomes 1 − (y + height) … 1 − y.
            rect = CropRect(x: 1 - rect.y - rect.height, y: rect.x,
                            width: rect.height, height: rect.width)
        }
        return rect
    }

    public func flipped(horizontal: Bool, vertical: Bool) -> CropRect {
        var rect = self
        if horizontal { rect.x = 1 - rect.x - rect.width }
        if vertical { rect.y = 1 - rect.y - rect.height }
        return rect
    }
}

public enum ResizeRule: Sendable, Hashable, Codable {
    case original
    /// The long side, never enlarging beyond the crop's native size.
    case longSide(Int)
    case exact(width: Int, height: Int, fit: FitMode, allowUpscale: Bool)

    public enum FitMode: String, Sendable, Hashable, Codable {
        case fit
        case fill
    }
}

public enum OutputColorSpace: String, Sendable, Hashable, Codable {
    case matchSource
    case sRGB
    case displayP3
}

public struct OutputFormat: Sendable, Hashable, Codable {
    public enum Kind: String, CaseIterable, Sendable, Hashable, Codable {
        case jpeg
        case png
        case tiff
        case heic
        case avif
    }

    public var kind: Kind
    /// Ignored by `png` and `tiff`.
    public var quality: Double
    public var embedThumbnail: Bool

    public init(kind: Kind = .jpeg, quality: Double = 0.9, embedThumbnail: Bool = true) {
        self.kind = kind
        self.quality = quality
        self.embedThumbnail = embedThumbnail
    }

    public var fileExtension: String {
        switch kind {
        case .jpeg: "jpg"
        case .png: "png"
        case .tiff: "tiff"
        case .heic: "heic"
        case .avif: "avif"
        }
    }

    public var isLossy: Bool {
        kind == .jpeg || kind == .heic || kind == .avif
    }

    public static let qualityPresets: [Double] = [0.95, 0.9, 0.8]
}

public struct FontChoice: Sendable, Hashable, Codable {
    public enum Design: String, Sendable, Hashable, Codable {
        case standard
        case serif
        case rounded
        case monospaced
    }

    /// Nil means the system font; a PostScript name pins a face the machine may or may not have.
    public var postScriptName: String?
    /// 0…1, only meaningful for the system font.
    public var weight: Double
    public var design: Design

    public init(postScriptName: String? = nil, weight: Double = 0.5, design: Design = .standard) {
        self.postScriptName = postScriptName
        self.weight = weight
        self.design = design
    }

    public static let system = FontChoice()
}

public enum OverlayAlignment: String, Sendable, Hashable, Codable {
    case leading
    case center
    case trailing
}

public enum OverlayAnchor: String, Sendable, Hashable, Codable, CaseIterable {
    case topLeading
    case top
    case topTrailing
    case leading
    case center
    case trailing
    case bottomLeading
    case bottom
    case bottomTrailing
}

public enum OverlayPlacement: Sendable, Hashable, Codable {
    case anchored(OverlayAnchor, marginFraction: Double)
    case tiled(angleDegrees: Double, columnSpacingFraction: Double, rowSpacingFraction: Double)
}

/// A caption and a watermark are the same thing — text at a placement — with different defaults. Splitting
/// them into two types would duplicate the resolver, the editor panel and the renderer.
public struct TextOverlay: Sendable, Hashable, Codable, Identifiable {
    public enum Kind: String, Sendable, Hashable, Codable {
        case caption
        case watermark
    }

    public var id: UUID
    public var kind: Kind
    public var text: String
    public var font: FontChoice
    /// Of the output's long side, not of points or pixels — this is what makes a preview honest.
    public var sizeFraction: Double
    public var color: RGBAColor
    public var opacity: Double
    public var shadow: Bool
    public var alignment: OverlayAlignment
    /// Of the output width.
    public var maxWidthFraction: Double
    public var placement: OverlayPlacement

    public init(kind: Kind = .caption, text: String) {
        self.init(
            kind: kind,
            text: text,
            font: .system,
            sizeFraction: kind == .caption ? 0.045 : 0.028,
            color: .white,
            opacity: kind == .caption ? 1 : 0.35,
            shadow: kind == .caption,
            alignment: .center,
            maxWidthFraction: kind == .caption ? 0.9 : 0.5,
            placement: kind == .caption
                ? .anchored(.bottom, marginFraction: 0.04)
                : .anchored(.bottomTrailing, marginFraction: 0.03)
        )
    }

    public init(
        kind: Kind,
        text: String,
        font: FontChoice,
        sizeFraction: Double,
        color: RGBAColor,
        opacity: Double,
        shadow: Bool,
        alignment: OverlayAlignment,
        maxWidthFraction: Double,
        placement: OverlayPlacement
    ) {
        self.id = UUID()
        self.kind = kind
        self.text = text
        self.font = font
        self.sizeFraction = sizeFraction
        self.color = color
        self.opacity = opacity
        self.shadow = shadow
        self.alignment = alignment
        self.maxWidthFraction = maxWidthFraction
        self.placement = placement
    }
}

public struct EditRecipe: Sendable, Hashable, Codable {
    public var crop: CropRect
    /// Clockwise, 0…3 after normalization. Applied before the crop is read.
    public var quarterTurns: Int
    public var flipHorizontal: Bool
    public var flipVertical: Bool
    public var resize: ResizeRule
    public var format: OutputFormat
    public var overlays: [TextOverlay]
    /// Nil means no padding is drawn; `.fit` on a non-matching aspect then shows transparent (or black)
    /// bars, which is why the editor offers a colour.
    public var background: RGBAColor?
    public var colorSpace: OutputColorSpace

    public init(
        crop: CropRect = .full,
        quarterTurns: Int = 0,
        flipHorizontal: Bool = false,
        flipVertical: Bool = false,
        resize: ResizeRule = .original,
        format: OutputFormat = OutputFormat(),
        overlays: [TextOverlay] = [],
        background: RGBAColor? = nil,
        colorSpace: OutputColorSpace = .matchSource
    ) {
        self.crop = crop
        self.quarterTurns = quarterTurns
        self.flipHorizontal = flipHorizontal
        self.flipVertical = flipVertical
        self.resize = resize
        self.format = format
        self.overlays = overlays
        self.background = background
        self.colorSpace = colorSpace
    }

    public var normalizedQuarterTurns: Int {
        ((quarterTurns % 4) + 4) % 4
    }

    /// True when the output can be produced by copying the source bytes: same container, no geometry,
    /// no overlays, no colour conversion. Quality is deliberately not consulted — a byte copy is exact.
    public func isIdentity(for sourceKind: OutputFormat.Kind) -> Bool {
        crop.isFull
            && normalizedQuarterTurns == 0
            && !flipHorizontal
            && !flipVertical
            && resize == .original
            && overlays.isEmpty
            && background == nil
            && colorSpace == .matchSource
            && format.kind == sourceKind
    }
}
