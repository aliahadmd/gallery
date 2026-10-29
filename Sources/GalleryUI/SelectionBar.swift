import SwiftUI
import GalleryDomain

/// The strip above the grid while something is selected. It says how many rows the *album* has selected —
/// including the ones the grid has not loaded — and puts the batch actions one click away.
struct SelectionBar: View {
    let model: MediaLibraryModel

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.tint)
            Text(countLabel)
                .font(.callout.weight(.medium))
                .monospacedDigit()
            if model.isWholeAlbumSelection {
                Text("in " + model.selectionTitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if !model.isWholeAlbumSelection && model.selectedCount < model.rowCount {
                Button("Select All \(model.rowCount.formatted())") { model.selectAll() }
                    .controlSize(.small)
            }
            Button("Deselect") { model.deselectAll() }
                .controlSize(.small)
            Button("Invert") { model.invertSelection() }
                .controlSize(.small)
            Menu {
                selectionMenu
            } label: {
                Label("Actions", systemImage: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }

    private var countLabel: String {
        model.isWholeAlbumSelection
            ? "All \(model.selectedCount.formatted()) selected"
            : "\(model.selectedCount.formatted()) selected"
    }

    @ViewBuilder private var selectionMenu: some View {
        Button("Move to Trash", role: .destructive) { model.requestTrash() }
        Button("Add to Favorites / Remove") {
            Task { await model.toggleFavoriteSelection() }
        }
        Button("Export a Copy…") {
            Task { await model.actions?.exportSelection() }
        }
        Divider()
        Button("Edit Metadata…") { Task { await model.beginBatchMetadata() } }
        Button("Rename…") { Task { await model.beginRename() } }
            .disabled(!model.canRename)
        Button("Move to Folder…") { Task { await model.actions?.moveSelection() } }
            .disabled(model.actions == nil)
        Divider()
        Button("Copy Names") { Task { await model.copySelectedNames() } }
        Button("Copy Paths") { Task { await model.copySelectedPaths() } }
        Button("Reveal in Finder") { Task { await model.revealSelection() } }
    }
}
