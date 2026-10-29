import AppKit
import GalleryUI

/// The only way a folder enters the library. In a sandbox the panel *is* the permission — the URL it hands
/// back is what `BookmarkStore` turns into a grant that outlives this launch, so nothing here ever asks for
/// broader access than the one folder the user named.
@MainActor
enum FolderPicker {
    static func present(into model: MediaLibraryModel) async {
        let panel = NSOpenPanel()
        panel.message = "Choose folders to scan. Gallery reads them in place and uploads nothing."
        panel.prompt = "Add to Library"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.canCreateDirectories = false
        panel.resolvesAliases = true
        // Re-opening where the library already points beats dropping the user into their home folder.
        panel.directoryURL = model.sources.first?.rootURL

        // Modal rather than a sheet: the welcome screen can ask for a folder before any window is key, and
        // a sheet needs a window to hang from.
        guard panel.runModal() == .OK else { return }
        await model.add(panel.urls)
    }
}
