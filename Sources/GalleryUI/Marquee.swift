import SwiftUI
import GalleryDomain

/// The rubber band's only decision: which cell frames intersect it. Pure, so the geometry is testable.
enum Marquee {
    static func ids(intersecting rect: CGRect, frames: [MediaID: CGRect]) -> [MediaID] {
        guard rect.width > 1 || rect.height > 1 else { return [] }
        return frames.filter { $0.value.intersects(rect) }.map(\.key)
    }

    static func rect(from start: CGPoint, to current: CGPoint) -> CGRect {
        CGRect(
            x: min(start.x, current.x),
            y: min(start.y, current.y),
            width: abs(current.x - start.x),
            height: abs(current.y - start.y)
        )
    }
}

/// Cell frames are a reference store, not `@State`: a lazy grid republishes them several times per layout
/// pass, and assigning an observed value from a preference callback makes SwiftUI complain (and re-layout)
/// on every one of those.
final class MarqueeFrames: @unchecked Sendable {
    var frames: [MediaID: CGRect] = [:]
}

/// Visible cells publish their frames; a lazy grid only materializes what the band can reach anyway.
struct CellFramePreferenceKey: PreferenceKey {
    static let defaultValue: [MediaID: CGRect] = [:]

    static func reduce(value: inout [MediaID: CGRect], nextValue: () -> [MediaID: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}
