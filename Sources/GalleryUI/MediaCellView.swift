import SwiftUI
import GalleryDomain

/// One tile: the picture if the cache has one, and always the shape, the name and the badges — which is the
/// point of pass A. A photo that has not been decoded yet still holds its place in the timeline, and a file
/// that never will be says so instead of showing a grey rectangle.
public struct MediaCellView: View {
    public let item: MediaItem
    private let model: MediaLibraryModel
    private let isSelected: Bool

    public init(item: MediaItem, model: MediaLibraryModel, isSelected: Bool = false) {
        self.item = item
        self.model = model
        self.isSelected = isSelected
    }

    public var body: some View {
        ZStack(alignment: .bottomLeading) {
            Rectangle().fill(Color.primary.opacity(0.05))

            Image(systemName: item.kind == .video ? "video" : "photo")
                .font(.system(size: 22, weight: .thin))
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            if item.error == .none {
                ThumbnailView(item: item, model: model)
            }

            // A poster is a still frame; without this a clip and a photo are the same picture in the grid.
            // The layer stays out of cells on purpose — sixty live players die on the first scroll.
            if item.kind == .video {
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 24))
                    .foregroundStyle(.white.opacity(0.92))
                    .shadow(color: .black.opacity(0.45), radius: 3)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .allowsHitTesting(false)
            }

            caption
        }
        .aspectRatio(cellRatio, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay {
            RoundedRectangle(cornerRadius: 4).strokeBorder(.separator)
        }
        .overlay {
            if isSelected {
                RoundedRectangle(cornerRadius: 4).strokeBorder(Color.accentColor, lineWidth: 3)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 4))
        .onTapGesture(count: 2) { model.openViewer(item.id) }
        .onTapGesture { model.select(item.id) }
        .contextMenu {
            Button("Open") { model.openViewer(item.id) }
            Button(item.isFavorite ? "Remove from Favorites" : "Add to Favorites") {
                Task { await model.toggleFavorite(item.id) }
            }
            Button("Show Info") {
                model.select(item.id)
                model.isInspectorPresented = true
            }
        }
        .help(item.relativePath)
        .onAppear { model.cellAppeared(item) }
        .onDisappear { model.cellDisappeared(item) }
    }

    /// Tiles stay inside a 6:1 band in both directions: an ultra-wide panorama would otherwise collapse the
    /// adaptive grid to a single column.
    private var cellRatio: Double {
        min(6, max(1.0 / 6.0, item.displayAspectRatio))
    }

    @ViewBuilder private var caption: some View {
        HStack(spacing: 4) {
            if item.error != .none {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                    .help(item.error.userReason)
            }
            if item.isOffline {
                Image(systemName: "icloud.slash").help(IndexError.offline.userReason)
            }
            if item.isFavorite {
                Image(systemName: "star.fill").foregroundStyle(.yellow)
            }
            Text(item.name)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            if let duration = item.durationDisplay {
                Text(duration).monospacedDigit()
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 4)
        .padding(.vertical, 3)
    }
}
