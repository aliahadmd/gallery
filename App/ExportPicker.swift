import AppKit
import GalleryDomain
import GalleryEditing
import GalleryUI

/// The save panel for "Export a Copy…".
///
/// Modal rather than a sheet for the same reason as `FolderPicker`: the editor exists before the window is
/// key, and a sheet needs a window to hang from. The URL the panel returns carries its own sandbox grant for
/// the session, which is what lets the exporter write outside the library.
@MainActor
enum ExportPicker {
    static func presentEditorExport(for session: EditingSession, into model: MediaLibraryModel) async {
        let panel = NSSavePanel()
        panel.title = "Export a Copy"
        panel.message = "The original stays where it is. This writes a new file."
        panel.prompt = "Export"
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [OutputFormats.utType(session.recipe.format.kind)]
        panel.nameFieldStringValue = suggestedName(for: session)
        panel.directoryURL = lastFolder

        guard panel.runModal() == .OK, let url = panel.url else { return }
        lastFolder = url.deletingLastPathComponent()
        await model.exportEditorCopy(to: url)
    }

    private static var lastFolder: URL? {
        get { UserDefaults.standard.url(forKey: "exportFolder") }
        set { UserDefaults.standard.set(newValue, forKey: "exportFolder") }
    }

    private static func suggestedName(for session: EditingSession) -> String {
        ExportNaming.fileName(
            for: session.source,
            format: session.recipe.format,
            policy: .init(stem: .editedSuffix),
            taken: { _ in false }
        ) ?? "Export.\(session.recipe.format.fileExtension)"
    }
}

/// A folder panel with the naming policy under it: "Keep both" is the default because it is the only
/// collision behaviour that cannot lose a file.
@MainActor
private final class ExportOptionsView: NSView {
    private let stemPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let collisionPopup = NSPopUpButton(frame: .zero, pullsDown: false)

    var policy: ExportNaming.Policy {
        let stems: [ExportNaming.Policy.Stem] = [.same, .editedSuffix, .captureDate]
        let collisions: [ExportNaming.Policy.Collision] = [.number, .skip, .overwrite]
        return ExportNaming.Policy(
            stem: stems[max(0, min(stemPopup.indexOfSelectedItem, stems.count - 1))],
            collision: collisions[max(0, min(collisionPopup.indexOfSelectedItem, collisions.count - 1))]
        )
    }

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 360, height: 70))
        stemPopup.addItems(withTitles: ["Same name", "Add “-edited”", "Prefix with the capture date"])
        collisionPopup.addItems(withTitles: ["Keep both (number the copy)",
                                             "Skip the file",
                                             "Replace the existing file"])
        let nameLabel = NSTextField(labelWithString: "Name")
        let existsLabel = NSTextField(labelWithString: "If it exists")
        nameLabel.frame = NSRect(x: 12, y: 42, width: 90, height: 18)
        existsLabel.frame = NSRect(x: 12, y: 10, width: 90, height: 18)
        stemPopup.frame = NSRect(x: 108, y: 38, width: 232, height: 25)
        collisionPopup.frame = NSRect(x: 108, y: 6, width: 232, height: 25)
        for view in [nameLabel, existsLabel, stemPopup, collisionPopup] {
            addSubview(view)
        }
    }

    required init?(coder: NSCoder) { nil }
}

extension ExportPicker {
    static func presentBatchExport(_ ids: [MediaID], into model: MediaLibraryModel) async {
        let panel = NSOpenPanel()
        panel.title = "Export Copies"
        panel.message = "Choose where the copies go. The originals stay where they are."
        panel.prompt = "Export"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.directoryURL = lastFolder
        let options = ExportOptionsView()
        panel.accessoryView = options

        guard panel.runModal() == .OK, let folder = panel.url else { return }
        lastFolder = folder
        await model.exportCopies(ids, to: folder, policy: options.policy)
    }

    static func presentCollageExport(for session: CollageSession, into model: MediaLibraryModel) async {
        let panel = NSSavePanel()
        panel.title = "Export the Collage"
        panel.message = "The collage is written as a new file. Nothing in the library changes."
        panel.prompt = "Export"
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [OutputFormats.utType(session.document.format.kind)]
        panel.nameFieldStringValue = "Collage.\(session.document.format.fileExtension)"
        panel.directoryURL = lastFolder

        guard panel.runModal() == .OK, let url = panel.url else { return }
        lastFolder = url.deletingLastPathComponent()
        await model.exportCollage(to: url)
    }
}
