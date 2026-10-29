import SwiftUI
import GalleryUI

@main
struct GalleryApp: App {
    @State private var container = AppContainer()

    var body: some Scene {
        WindowGroup {
            content
                .frame(minWidth: 860, minHeight: 520)
        }
        .defaultSize(width: 1240, height: 800)
        .commands {
            if let model = container.model {
                GalleryCommands(model: model)
            }
        }
    }

    /// A library that will not open is a message, not an empty grid: the difference between "you have no
    /// photos" and "the catalog is unreadable" is the whole point of telling the user.
    @ViewBuilder private var content: some View {
        if let model = container.model {
            RootView(model: model) {
                await FolderPicker.present(into: model)
            }
            // The other half of the `public.folder` document type in Info.plist: a folder opened in
            // Finder's Open With, or dropped on the dock icon, arrives here already granted to the sandbox.
            .onOpenURL { url in
                Task { await model.add(url) }
            }
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
