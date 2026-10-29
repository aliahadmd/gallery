import CoreGraphics
import Foundation
import GalleryDomain
import GallerySupport
import os

/// Renders the editor's canvas preview.
///
/// Same plan, smaller raster: the recipe is resolved against the decoded size and then capped to the
/// canvas's long side, so the composition — crop, rotation, overlays — is identical to the export. The
/// decode never applies orientation; the plan does.
public actor EditPreviewer {
    private let lane: BlockingLane

    public init(lane: BlockingLane = BlockingLane(
        label: "app.gallery.editpreview", qos: .userInitiated, semaphore: .imageDecode()
    )) {
        self.lane = lane
    }

    public func preview(
        for source: EditSource, recipe: EditRecipe, maxLongSide: Int = 1600
    ) async -> CGImage? {
        let scope = source.scopedRoot ?? source.url.deletingLastPathComponent()
        let limit = Int32(min(max(maxLongSide, 512), 2048))
        let outcome = await lane.run { () -> CGImage? in
            SecurityScope.begin(scope)
            defer { SecurityScope.end(scope) }
            guard let header = EditRenderer.readHeader(source.url) else {
                Log.editing.error("preview: no readable header at \(source.url.path, privacy: .public)")
                return nil
            }
            guard let image = EditRenderer.decode(source.url, maxPixel: limit) else {
                Log.editing.error("preview: decode failed at \(source.url.path, privacy: .public)")
                return nil
            }
            let stored = PixelSize(width: Int32(image.width), height: Int32(image.height))
            guard let plan = EditPlanBuilder.plan(
                recipe, stored: stored, orientation: header.orientation
            ) else {
                Log.editing.error("preview: no plan for \(stored.width)x\(stored.height)")
                return nil
            }
            let rendered = EditRenderer.render(plan.scaled(toLongSide: maxLongSide), from: image)
            if rendered == nil {
                Log.editing.error("preview: render failed at \(stored.width)x\(stored.height)")
            }
            return rendered
        }
        guard case .completed(let image) = outcome else { return nil }
        return image
    }
}
