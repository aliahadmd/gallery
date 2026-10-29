import SwiftUI
import CoreGraphics
import GalleryDomain
import GalleryIndexing

/// One tile's picture.
///
/// `.task(id:)` is the whole mechanism: the request starts when the tile appears and is cancelled when it
/// leaves or when the row's own facts change, which is what makes a flicked scroll stop paying for bitmaps it
/// never drew. The id carries `stage` for a reason — pass B landing a poster does not make SwiftUI rebuild
/// the cell, and a task that never restarts is a tile that stays a placeholder over a picture that exists.
///
/// The bucket is the drain's own poster size rather than whatever the cell measures on this display: asking a
/// 260 pt tile for its 520 px twin would bake a second size of every photo in the library to save a few
/// pixels of sharpness.
struct ThumbnailView: View {
    let item: MediaItem
    let model: MediaLibraryModel

    @State private var image: CGImage?

    private var key: LoadKey { LoadKey(item: item) }

    var body: some View {
        Color.clear
            .overlay {
                if let image {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                }
            }
            .task(id: key) {
                let loaded = await model.preview(for: item)
                // Leaving a tile, or the row changing under it, cancels this task — and a picture that arrives
                // for a cell which has moved on must not be written into whatever the grid put there next.
                guard !Task.isCancelled else { return }
                image = loaded
            }
    }

    private struct LoadKey: Equatable {
        let id: MediaID
        let mtime: Date?
        let stage: IndexStage

        init(item: MediaItem) {
            id = item.id
            mtime = item.modificationDate
            stage = item.stage
        }
    }
}
