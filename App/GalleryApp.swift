import SwiftUI
import GalleryUI

@main
struct GalleryApp: App {
    @State private var container = AppContainer()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // One window, not a `WindowGroup`: a second scene would run a second `model.start()` over the same
        // coordinator and catalog — two progress feeds, two scans per folder — and opening a folder from
        // Finder is an everyday event, not a request for a second library.
        Window("Gallery", id: "library") {
            content
                .frame(minWidth: 860, minHeight: 520)
        }
        .defaultSize(width: 1240, height: 800)
        .commands {
            if let model = container.model {
                GalleryCommands(model: model)
            }
        }

        // A second surface for the same viewer. A `Window`, not a `WindowGroup`: one photo is open, so a
        // second viewer window would be a second view of the same state, and ⌘⏎ brings it forward.
        Window("Viewer", id: "viewer") {
            if let model = container.model {
                ViewerWindow(model: model)
            } else {
                Text("Gallery could not open.")
            }
        }
        .defaultSize(width: 1100, height: 760)
    }

    /// A library that will not open is a message, not an empty grid: the difference between "you have no
    /// photos" and "the catalog is unreadable" is the whole point of telling the user.
    @ViewBuilder private var content: some View {
        if let model = container.model {
            RootView(model: model, addFolders: {
                await FolderPicker.present(into: model)
            }, exportEditor: { session in
                await ExportPicker.presentEditorExport(for: session, into: model)
            }, exportCollage: { session in
                await ExportPicker.presentCollageExport(for: session, into: model)
            })
            // The other half of the `public.folder` document type in Info.plist: a folder opened in
            // Finder's Open With, or dropped on the dock icon, arrives here already granted to the sandbox.
            .onOpenURL { url in
                Task { await model.add(url) }
            }
            // The Finder service needs the model; the window owns it, so hand it over once it exists.
            .onAppear { appDelegate.model = model }
        } else {
            VStack(spacing: 10) {
                Image(systemName: "externaldrive.badge.xmark")
                    .font(.system(size: 38, weight: .thin))
                    .foregroundStyle(.secondary)
                Text("Gallery Could Not Open").font(.title2)
                Text(container.startupFailure ?? "The library database could not be created.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: 460)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
