import SwiftUI
import AppKit
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
        .background {
            GeometryReader { proxy in
                Color.clear.preference(
                    key: CellFramePreferenceKey.self,
                    value: [item.id: proxy.frame(in: .named("libraryGrid"))]
                )
            }
        }
        .onTapGesture(count: 2) { model.openViewer(item.id) }
        .onTapGesture {
            // SwiftUI's tap gesture does not carry the modifiers, and the click that extends a selection is
            // exactly the one with ⌘ or ⇧ held; read them at the moment the gesture fires.
            let modifiers = NSEvent.modifierFlags
            model.select(item.id, extending: modifiers.contains(.command),
                         range: modifiers.contains(.shift))
        }
        // Dragging a tile into Finder (or another app) hands over the file itself. The URL is the one the
        // model already resolved for the cells on screen; a tile that has never reported offers nothing.
        .onDrag {
            if let url = model.fileURL(for: item) {
                return NSItemProvider(contentsOf: url) ?? NSItemProvider()
            }
            return NSItemProvider()
        }
        .contextMenu {
            contextMenu
        }
        .help(item.relativePath)
        .onAppear { model.cellAppeared(item) }
        .onDisappear { model.cellDisappeared(item) }
    }

    /// A right-click on a row that is part of the selection acts on the whole selection; on any other row
    /// it acts on that row and selects it first. The menu titles say which one it is.
    @ViewBuilder private var contextMenu: some View {
        let multi = model.isInSelection(item)
        Button("Open") { model.openViewer(item.id) }
        if model.canEdit(item) {
            Button("Edit…") { Task { await model.openEditor(item.id) } }
        }
        if let actions = model.actions {
            Button(multi ? "Export \(model.selectedCount) Copies…" : "Export a Copy…") {
                Task {
                    if multi { await actions.exportSelection() } else { await actions.exportCopies([item.id]) }
                }
            }
        }
        if model.selectedMediaIDs.count >= 2 {
            Button("Create Collage…") {
                Task { await model.createCollage(model.selectedMediaIDs) }
            }
        }
        if item.kind == .image {
            Button("Revert to Previous Version") {
                Task { await model.revertToPreviousVersion(item) }
            }
        }
        Button(item.isFavorite ? "Remove from Favorites" : "Add to Favorites") {
            Task {
                if multi { await model.toggleFavoriteSelection() } else { await model.toggleFavorite(item.id) }
            }
        }
        Button("Show Info") {
            model.select(item.id)
            model.isInspectorPresented = true
        }
        Divider()
        Button("Edit Metadata…") {
            if !multi { model.select(item.id) }
            Task { await model.beginBatchMetadata() }
        }
        if item.kind == .image {
            Button("Select Similar") { Task { await model.selectSimilar(to: item) } }
        }
        Button(multi ? "Rename \(model.selectedCount) Items…" : "Rename…") {
            if !multi { model.select(item.id) }
            Task { await model.beginRename() }
        }
        .disabled(!model.canRename)
        Button("Move to Folder…") {
            if !multi { model.select(item.id) }
            Task { await model.actions?.moveSelection() }
        }
        .disabled(model.actions == nil)
        Divider()
        Button("Copy Name") {
            if !multi { model.select(item.id) }
            Task { await model.copySelectedNames() }
        }
        Button("Copy Path") {
            if !multi { model.select(item.id) }
            Task { await model.copySelectedPaths() }
        }
        Button("Reveal in Finder") {
            if !multi { model.select(item.id) }
            Task { await model.revealSelection() }
        }
        Divider()
        if model.isRecentlyDeleted {
            Button("Restore") {
                Task {
                    if multi { await model.restoreSelection() } else { await model.restore([item.id]) }
                }
            }
            Button("Delete Forever", role: .destructive) {
                if multi { model.requestDeleteForever() } else { Task { await model.deleteForever([item.id]) } }
            }
        } else {
            Button(multi ? "Move \(model.selectedCount) Items to Trash" : "Move to Trash", role: .destructive) {
                if multi { model.requestTrash() } else { Task { await model.moveToTrash([item.id]) } }
            }
        }
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
            if model.isDuplicateBest(item) {
                Image(systemName: "crown.fill")
                    .foregroundStyle(.yellow)
                    .help("The best shot in this duplicate set")
            }
            if item.subtype.contains(.raw) {
                Text("RAW")
                    .font(.system(size: 8, weight: .bold))
                    .padding(.horizontal, 3)
                    .padding(.vertical, 1)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 2))
            }
            // While a search is on, the cell says why it matched — the bracketed snippet the catalog
            // computed — instead of the name every other cell shares a prefix of.
            Text(captionText)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(item.name)
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

    private var captionText: String {
        guard let snippet = model.searchSnippets[item.id], !snippet.isEmpty else {
            return item.title ?? item.name
        }
        return snippet
            .replacingOccurrences(of: "[", with: "")
            .replacingOccurrences(of: "]", with: "")
    }
}
