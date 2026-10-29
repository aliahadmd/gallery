import AppKit
import GalleryUI

/// A folder panel constrained to the source the selection lives in: a move across sources would change which
/// library the row belongs to, which is a different feature.
@MainActor
enum MovePicker {
    static func present(into model: MediaLibraryModel) async {
        guard let root = await model.moveRoot() else {
            model.note("Move to Folder works inside one folder's library.",
                       detail: "Select photos from one folder first.")
            return
        }
        let panel = NSOpenPanel()
        panel.title = "Move to Folder"
        panel.message = "Choose a folder inside “\(root.lastPathComponent)”. The files stay in place in the library."
        panel.prompt = "Move Here"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.directoryURL = root
        guard panel.runModal() == .OK, let chosen = panel.url else { return }

        let rootPath = root.standardizedFileURL.path
        let chosenPath = chosen.standardizedFileURL.path
        guard chosenPath == rootPath || chosenPath.hasPrefix(rootPath + "/") else {
            model.note("That folder is outside the library.", detail: "Choose a folder inside “\(root.lastPathComponent)”.")
            return
        }
        var relative = String(chosenPath.dropFirst(rootPath.count))
        relative = relative.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        await model.beginMove(toRelativeFolder: relative)
    }
}
