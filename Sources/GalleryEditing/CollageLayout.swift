import CoreGraphics
import Foundation
import GalleryDomain

public struct CollageDocument: Sendable, Hashable, Codable, Identifiable {
    public var id: UUID
    public var memberIDs: [MediaID]
    public var template: CollageTemplate
    public var aspect: CollageAspect
    /// Output long side in pixels, clamped to 800…8192 by the layout engine.
    public var longSide: Int
    /// Of the long side.
    public var gutterFraction: Double
    public var marginFraction: Double
    public var background: RGBAColor
    /// A caption band under the grid.
    public var title: String?
    public var format: OutputFormat

    public init(
        id: UUID = UUID(),
        memberIDs: [MediaID],
        template: CollageTemplate = .grid(columns: 2),
        aspect: CollageAspect = .landscape3x2,
        longSide: Int = 3000,
        gutterFraction: Double = 0.008,
        marginFraction: Double = 0.02,
        background: RGBAColor = .white,
        title: String? = nil,
        format: OutputFormat = OutputFormat()
    ) {
        self.id = id
        self.memberIDs = memberIDs
        self.template = template
        self.aspect = aspect
        self.longSide = longSide
        self.gutterFraction = gutterFraction
        self.marginFraction = marginFraction
        self.background = background
        self.title = title
        self.format = format
    }
}

/// Templates only: freeform needs drag handles, snapping and a persisted layout vocabulary, and buys
/// nothing the four arrangements do not.
public enum CollageTemplate: Sendable, Hashable, Codable {
    case grid(columns: Int)
    case heroTop
    case heroLeft
    case strip

    public static let presets: [CollageTemplate] = [
        .grid(columns: 2), .grid(columns: 3), .heroTop, .heroLeft, .strip,
    ]
}

public enum CollageAspect: Sendable, Hashable, Codable {
    case square
    case portrait4x5
    case landscape3x2
    case wide16x9
    case custom(width: Int, height: Int)

    public var ratio: Double {
        switch self {
        case .square: 1
        case .portrait4x5: 4.0 / 5.0
        case .landscape3x2: 3.0 / 2.0
        case .wide16x9: 16.0 / 9.0
        case .custom(let width, let height):
            height > 0 ? Double(max(1, width)) / Double(height) : 1
        }
    }

    /// The canvas with the requested long side; the other side is derived from the ratio.
    public func canvas(longSide: Int) -> PixelSize {
        let side = max(1, longSide)
        let r = ratio
        if abs(r - 1) < 0.0001 {
            return PixelSize(width: Int32(side), height: Int32(side))
        }
        if r > 1 {
            return PixelSize(
                width: Int32(side),
                height: Int32(max(1, Int((Double(side) / r).rounded())))
            )
        }
        return PixelSize(
            width: Int32(max(1, Int((Double(side) * r).rounded()))),
            height: Int32(side)
        )
    }
}

public struct CollageLayout: Sendable, Hashable {
    public struct Slot: Sendable, Hashable {
        public var frame: CGRect
        /// Index into `CollageDocument.memberIDs`; nil would be an intentionally empty cell.
        public var member: Int?
        /// What the decoder should be asked for — the slot's longest dimension.
        public var requiredPixels: Int32
    }

    public var canvas: PixelSize
    public var slots: [Slot]
    public var titleFrame: CGRect?
    /// > 1 means at least one member is being enlarged; the UI warns above 1.05.
    public var upscaleFactor: Double
}

public enum CollageLayoutEngine {
    /// Pure geometry. Every edge is an integer, cells in a row share the gutter exactly, and the last cell
    /// absorbs the rounding remainder — so frames tile with no gaps and no overlaps.
    public static func layout(
        _ document: CollageDocument,
        sourceLongSides: [MediaID: Int] = [:]
    ) -> CollageLayout {
        let longSide = min(max(document.longSide, 800), 8192)
        let canvas = document.aspect.canvas(longSide: longSide)
        let margin = (min(max(document.marginFraction, 0), 0.2) * Double(longSide)).rounded()
        let gutter = (min(max(document.gutterFraction, 0), 0.1) * Double(longSide)).rounded()

        let hasTitle = !(document.title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        let titleHeight = hasTitle ? max(1, (0.07 * Double(longSide)).rounded()) : 0
        let content = CGRect(
            x: margin,
            y: margin,
            width: max(0, Double(canvas.width) - 2 * margin),
            height: max(0, Double(canvas.height) - 2 * margin - (titleHeight > 0 ? titleHeight + gutter : 0))
        )
        let titleFrame = titleHeight > 0 && content.width > 0
            ? CGRect(x: content.minX, y: content.maxY + gutter,
                     width: content.width, height: titleHeight)
            : nil

        let count = document.memberIDs.count
        guard count > 0, content.width >= 1, content.height >= 1 else {
            return CollageLayout(canvas: canvas, slots: [], titleFrame: titleFrame, upscaleFactor: 1)
        }

        // A gap large enough to leave no room for the cells is a document bug, not an instruction: clamp
        // it so every slot still gets at least one pixel.
        let safeGutter = min(
            gutter,
            max(0, (min(content.width, content.height) - Double(count) - 2) / Double(max(1, count - 1)))
        )
        let boxes = templateBoxes(
            document.template, count: count, in: content, gutter: safeGutter
        )
        var slots: [CollageLayout.Slot] = []
        var upscale = 0.0
        for (index, frame) in boxes.enumerated() {
            let required = Int32(max(1, Int(max(frame.width, frame.height).rounded())))
            slots.append(.init(frame: frame, member: index, requiredPixels: required))
            if index < count,
               let longSide = sourceLongSides[document.memberIDs[index]], longSide > 0 {
                upscale = max(upscale, Double(required) / Double(longSide))
            }
        }
        return CollageLayout(
            canvas: canvas, slots: slots, titleFrame: titleFrame,
            upscaleFactor: upscale > 0 ? upscale : 1
        )
    }

    static func templateBoxes(
        _ template: CollageTemplate, count: Int, in content: CGRect, gutter: Double
    ) -> [CGRect] {
        switch template {
        case .grid(let columns):
            return boxes(count: count, in: content, gutter: gutter,
                         columns: max(1, min(columns, 6)))
        case .strip:
            return boxes(count: count, in: content, gutter: gutter, columns: count)
        case .heroTop:
            guard count > 1 else { return [content] }
            let heroHeight = max(1, ((content.height - gutter) * 0.62).rounded())
            let hero = CGRect(x: content.minX, y: content.minY,
                              width: content.width, height: min(heroHeight, content.height))
            let rest = CGRect(x: content.minX, y: hero.maxY + gutter, width: content.width,
                              height: max(1, content.maxY - hero.maxY - gutter))
            return [hero] + boxes(count: count - 1, in: rest, gutter: gutter,
                                  columns: min(4, count - 1))
        case .heroLeft:
            guard count > 1 else { return [content] }
            let heroWidth = max(1, ((content.width - gutter) * 0.58).rounded())
            let hero = CGRect(x: content.minX, y: content.minY,
                              width: min(heroWidth, content.width), height: content.height)
            let rest = CGRect(x: hero.maxX + gutter, y: content.minY,
                              width: max(1, content.maxX - hero.maxX - gutter),
                              height: content.height)
            return [hero] + boxes(count: count - 1, in: rest, gutter: gutter, columns: 1)
        }
    }

    /// `count` cells in rows of `columns`, the ragged last row spread across the full width.
    static func boxes(count: Int, in rect: CGRect, gutter: Double, columns: Int) -> [CGRect] {
        guard count > 0, rect.width >= 1, rect.height >= 1 else { return [] }
        let cols = max(1, min(columns, count))
        let rows = (count + cols - 1) / cols
        let heights = parts(span: rect.height, count: rows, gap: gutter)
        var result: [CGRect] = []
        var y = rect.minY
        for row in 0..<rows {
            let first = row * cols
            let inRow = min(cols, count - first)
            let widths = parts(span: rect.width, count: inRow, gap: gutter)
            var x = rect.minX
            for width in widths where result.count < count {
                result.append(CGRect(x: x, y: y, width: width, height: heights[row]))
                x += width + gutter
            }
            y += heights[row] + gutter
        }
        return result
    }

    /// Sizes that sum to `span` with exactly `gap` between them; the last absorbs the remainder.
    static func parts(span: Double, count: Int, gap: Double) -> [Double] {
        guard count > 0 else { return [] }
        guard count > 1 else { return [max(1, span)] }
        let usable = span - gap * Double(count - 1)
        guard usable >= Double(count) else {
            return Array(repeating: max(1, span / Double(count)), count: count)
        }
        let cell = max(1, (usable / Double(count)).rounded(.down))
        var result = Array(repeating: cell, count: count - 1)
        result.append(max(1, usable - cell * Double(count - 1)))
        return result
    }
}
