import SwiftUI
import GalleryUI

/// ⌘O and ⌘R live in the menu bar rather than on the buttons, because a toolbar only exists once there is a
/// library to show — and the first thing a user with an empty window wants to do is add a folder.
struct GalleryCommands: Commands {
    let model: MediaLibraryModel

    var body: some Commands {
        // Replacing `.newItem` instead of appending to it: a second window would start a second `.task`
        // against the same coordinator, so two feeds, two scans per folder and two cursors over one grid.
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

        CommandMenu("Photo") {
            Button("Open") {
                if let id = model.selectedID { model.openViewer(id) }
            }
            .keyboardShortcut(.return, modifiers: [])
            .disabled(model.selectedID == nil || model.viewerItem != nil)

            Button("Toggle Favorite") {
                if let id = model.selectedID {
                    Task { await model.toggleFavorite(id) }
                }
            }
            .keyboardShortcut("f", modifiers: [.command, .shift])
            .disabled(model.selectedID == nil)

            // ⌘⌫, not ⌘⇧⌫: the shifted form is macOS's own "empty trash" gesture on other apps and is
            // reserved. In Recently Deleted the same key is the undo, because that is where the user is.
            Button(model.isRecentlyDeleted ? "Restore" : "Move to Trash") {
                if let id = model.selectedID {
                    Task {
                        if model.isRecentlyDeleted {
                            await model.restore([id])
                        } else {
                            await model.moveToTrash([id])
                        }
                    }
                }
            }
            .keyboardShortcut(.delete, modifiers: .command)
            .disabled(model.selectedID == nil)

            Divider()

            Button("Show Info") {
                model.isInspectorPresented.toggle()
            }
            .keyboardShortcut("i", modifiers: [.command, .option])
        }
    }
}
