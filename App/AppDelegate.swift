import AppKit
import GalleryUI

/// Finder integration for folders.
///
/// The document type in Info.plist is what puts Gallery under Finder's **Open With** menu; this service adds
/// **Services ▸ Open Folder in Gallery**, the native way to offer a right-click action without shipping a
/// Finder Sync extension. A true top-level context item needs that extension, which costs a separate signed
/// plug-in target and a trip through System Settings — not worth it for a local app (the README/INSTALL
/// notes show the one-minute Shortcuts Quick Action for people who want a top-level item).
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Set by the app once the model exists. Weak: the window owns the model, not the delegate.
    weak var model: MediaLibraryModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.servicesProvider = self
        NSUpdateDynamicServices()
    }

    @objc func openFolder(
        _ pasteboard: NSPasteboard,
        userData: String,
        error: AutoreleasingUnsafeMutablePointer<NSString?>
    ) {
        let urls = (pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL]) ?? []
        let folders = urls.filter { $0.hasDirectoryPath }
        guard !folders.isEmpty else {
            error.pointee = "Select a folder to open in Gallery." as NSString
            return
        }
        guard let model else {
            error.pointee = "Gallery is still starting. Try again in a moment." as NSString
            return
        }
        Task { @MainActor in
            await model.add(folders)
        }
    }
}
