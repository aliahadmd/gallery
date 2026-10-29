import SwiftUI
import GalleryDomain

/// How a view asks for the folder panel. The panel itself is AppKit and lives in the executable target, so
/// the library only ever needs to know that something happened.
public typealias AddFoldersAction = @MainActor () async -> Void

public struct RootView: View {
    private let model: MediaLibraryModel
    private let addFolders: AddFoldersAction

    public init(model: MediaLibraryModel, addFolders: @escaping AddFoldersAction) {
        self.model = model
        self.addFolders = addFolders
    }

    public var body: some View {
        ZStack {
            content
            // Over the whole window, sidebar included: a photo shown next to the thing it came from is not
            // full screen, and a viewer that stops at the detail column is a thumbnail with extra steps.
            if model.viewerItem != nil {
                ViewerView(model: model)
                    .zIndex(1)
            }
        }
        .animation(.easeOut(duration: 0.12), value: model.viewerID)
        .task { await model.start() }
        .onDisappear { model.stop() }
        .alert("Gallery", isPresented: hasNotice) {
            Button("OK") { model.dismissNotice() }
        } message: {
            if let notice = model.notices.first {
                Text(notice.text)
                if let detail = notice.detail { Text(detail) }
            }
        }
    }

    /// The split view owns the window's chrome, so the welcome screen cannot be one of its columns — and an
    /// empty sidebar is a worse first impression than a page that says what to do.
    @ViewBuilder private var content: some View {
        if model.sources.isEmpty {
            WelcomeView(addFolders: addFolders)
        } else {
            NavigationSplitView {
                SidebarView(model: model)
                    .navigationSplitViewColumnWidth(min: 208, ideal: 248, max: 330)
            } detail: {
                LibraryGridView(model: model, addFolders: addFolders)
            }
        }
    }

    private var hasNotice: Binding<Bool> {
        Binding(get: { !model.notices.isEmpty }, set: { if !$0 { model.dismissNotice() } })
    }
}

public struct WelcomeView: View {
    private let addFolders: AddFoldersAction

    public init(addFolders: @escaping AddFoldersAction) {
        self.addFolders = addFolders
    }

    public var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 46, weight: .thin))
                .foregroundStyle(.secondary)
            Text("No Folders Yet")
                .font(.title2)
            Text("Add a folder and Gallery will list every photo and video inside it, in place.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Add Folder…") {
                Task { await addFolders() }
            }
            .buttonStyle(.borderedProminent)
            Text("Nothing is uploaded. Access is limited to the folders you choose.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: 420)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
