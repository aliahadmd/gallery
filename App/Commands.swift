import SwiftUI
import GalleryUI

/// ⌘O and ⌘R live in the menu bar rather than on the buttons, because a toolbar only exists once there is a
/// library to show — and the first thing a user with an empty window wants to do is add a folder.
struct GalleryCommands: Commands {
    let model: MediaLibraryModel
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        // Replacing `.newItem` instead of appending to it: a second library window would start a second
        // `.task` against the same coordinator, so two feeds, two scans per folder and two cursors.
        CommandGroup(replacing: .newItem) {
            Button("Add Folder…") {
                Task { await FolderPicker.present(into: model) }
            }
            .keyboardShortcut("o", modifiers: .command)

            Button("Rescan Library") {
                Task { await model.rescanAll() }
            }
            .keyboardShortcut("r", modifiers: .command)
        }

        // The three panels, in the order they appear on screen.
        CommandGroup(after: .sidebar) {
            Button("Show All Panels") { model.panels = .all }
                .keyboardShortcut("1", modifiers: .command)
            Button("Hide Sidebar") { model.panels = .detailOnly }
                .keyboardShortcut("2", modifiers: .command)
            Button(model.isInspectorPresented ? "Hide Info" : "Show Info") {
                model.isInspectorPresented.toggle()
            }
            .keyboardShortcut("3", modifiers: .command)
        }

        CommandMenu("Analysis") {
            Button(model.analysisPaused ? "Resume Analysis" : "Pause Analysis") {
                Task { await model.setAnalysisPaused(!model.analysisPaused) }
            }
            .disabled(!model.hasAnalysis)

            Button("Analyze Library Again") {
                Task { await model.reanalyzeLibrary() }
            }
            .disabled(!model.hasAnalysis)

            Divider()

            Button("Rebuild Search Index") {
                Task { await model.rebuildSearchIndex() }
            }
        }

        CommandMenu("Photo") {            Button("Open") {
                if let id = model.selectedID { model.openViewer(id) }
            }
            .keyboardShortcut(.return, modifiers: [])
            .disabled(model.selectedID == nil || model.viewerItem != nil)

            Button("Open in New Window") {
                guard let id = model.selectedID else { return }
                model.openViewer(id)
                openWindow(id: "viewer")
            }
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(model.selectedID == nil)

            Button("Edit…") {
                guard let id = model.selectedID else { return }
                Task { await model.openEditor(id) }
            }
            .keyboardShortcut("e", modifiers: .command)
            .disabled(!canEditSelection)

            Button("Edit Metadata…") {
                guard let id = model.selectedID else { return }
                Task { await model.openEditor(id, tool: .metadata) }
            }
            .disabled(!canEditSelection)

            Button("Export a Copy…") {
                let ids = model.selectedMediaIDs
                Task { await ExportPicker.presentBatchExport(ids, into: model) }
            }
            .keyboardShortcut("e", modifiers: [.command, .shift])
            .disabled(model.selectedItems.allSatisfy { $0.kind != .image })

            Button("Create Collage…") {
                let ids = model.selectedMediaIDs
                Task { await model.createCollage(ids) }
            }
            .disabled(model.selectedItems.filter { $0.kind == .image }.count < 2)

            Button("Revert to Previous Version") {
                guard let item = model.selectedItem else { return }
                Task { await model.revertToPreviousVersion(item) }
            }
            .disabled(model.selectedItem?.kind != .image)

            Divider()

            Button(favoriteTitle) {
                Task { await model.toggleFavoriteSelection() }
            }
            .keyboardShortcut("f", modifiers: [.command, .shift])
            .disabled(model.selectedIDs.isEmpty)

            // ⌘⌫, not ⌘⇧⌫: the shifted form is macOS's own "empty trash" gesture elsewhere and is reserved.
            // In Recently Deleted the same key is the undo, because that is where the user is.
            Button(model.isRecentlyDeleted ? "Restore" : "Move to Trash") {
                let ids = model.selectedMediaIDs
                Task {
                    if model.isRecentlyDeleted {
                        await model.restore(ids)
                    } else {
                        await model.moveToTrash(ids)
                    }
                }
            }
            .keyboardShortcut(.delete, modifiers: .command)
            .disabled(model.selectedIDs.isEmpty)

            Button("Select All") { model.selectAll() }
                .keyboardShortcut("a", modifiers: .command)
        }
    }

    private var canEditSelection: Bool {
        guard let item = model.selectedItem else { return false }
        return model.canEdit(item)
    }

    /// The star's menu title follows what the selection would do, which is the difference between undoing a
    /// favourite and adding a hundred.
    private var favoriteTitle: String {
        let chosen = model.selectedItems
        let allFavorite = !chosen.isEmpty && chosen.allSatisfy(\.isFavorite)
        return allFavorite ? "Remove from Favorites" : "Add to Favorites"
    }
}
