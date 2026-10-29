import SwiftUI
import GalleryDomain

/// How a view asks for the folder panel. The panel itself is AppKit and lives in the executable target, so
/// the library only ever needs to know that something happened.
public typealias AddFoldersAction = @MainActor () async -> Void

public struct RootView: View {
    private let model: MediaLibraryModel
    private let addFolders: AddFoldersAction
    private let exportEditor: EditorExportAction?
    private let exportCollage: CollageExportAction?

    public init(
        model: MediaLibraryModel,
        addFolders: @escaping AddFoldersAction,
        exportEditor: EditorExportAction? = nil,
        exportCollage: CollageExportAction? = nil
    ) {
        self.model = model
        self.addFolders = addFolders
        self.exportEditor = exportEditor
        self.exportCollage = exportCollage
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
            // The editor sits above the viewer: opening it from the viewer keeps the photo behind it, so
            // closing the editor returns to the same picture rather than to the grid.
            if let session = model.editingSession {
                EditorView(model: model, session: session, exportCopy: exportEditor)
                    .zIndex(2)
            }
            // A collage is its own surface: several photos, one document, and a template rather than a
            // recipe. It sits above the editor so opening one from the grid never hides behind the other.
            if let session = model.collageSession {
                CollageView(model: model, session: session, exportCopy: exportCollage)
                    .zIndex(3)
            }
        }
        // The viewer is a full-window surface; the grid's search field and sort menu should not float above
        // a photo that is filling the screen.
        .toolbarVisibility(model.viewerItem == nil ? .visible : .hidden, for: .windowToolbar)
        .animation(.easeOut(duration: 0.12), value: model.viewerID)
        .animation(.easeOut(duration: 0.12), value: model.editorID)
        .animation(.easeOut(duration: 0.12), value: model.isCollageOpen)
        .task { await model.start() }
        .onDisappear { model.stop() }
        .alert("Gallery", isPresented: hasNotice) {
            if let notice = model.notices.first {
                ForEach(notice.commands, id: \.self) { command in
                    Button(command.title) { model.perform(command) }
                }
            }
            Button("OK") { model.dismissNotice() }
        } message: {
            if let notice = model.notices.first {
                Text(notice.text)
                if let detail = notice.detail { Text(detail) }
            }
        }
        .confirmationDialog(
            model.pendingDestructive?.title ?? "Confirm",
            isPresented: Binding(
                get: { model.pendingDestructive != nil },
                set: { if !$0 { model.cancelDestructive() } }
            ),
            presenting: model.pendingDestructive
        ) { action in
            Button(action.confirmTitle, role: .destructive) { model.confirmDestructive() }
            Button("Cancel", role: .cancel) { model.cancelDestructive() }
        } message: { action in
            Text(action.message)
        }
        .sheet(isPresented: Binding(
            get: { model.isShowingBatchFailures },
            set: { if !$0 { model.dismissBatchFailures() } }
        )) {
            BatchFailureSheet(failures: model.lastBatchFailures) { model.dismissBatchFailures() }
        }
        .sheet(isPresented: Binding(
            get: { model.renameSession != nil },
            set: { if !$0 { model.closeRename() } }
        )) {
            if let session = model.renameSession {
                RenameSheet(model: model, session: session)
            }
        }
        .sheet(isPresented: Binding(
            get: { model.batchMetadataSession != nil },
            set: { if !$0 { model.closeBatchMetadata() } }
        )) {
            if let session = model.batchMetadataSession {
                BatchMetadataSheet(model: model, session: session)
            }
        }
    }

    /// The split view owns the window's chrome, so the welcome screen cannot be one of its columns — and an
    /// empty sidebar is a worse first impression than a page that says what to do.
    @ViewBuilder private var content: some View {
        if model.sources.isEmpty {
            WelcomeView(addFolders: addFolders)
        } else {
            // Driven by the model so ⌘1/⌘2 and the system's own sidebar toggle agree about the column.
            NavigationSplitView(columnVisibility: columnVisibility) {
                SidebarView(model: model)
                    .navigationSplitViewColumnWidth(min: 208, ideal: 248, max: 330)
            } detail: {
                LibraryGridView(model: model, addFolders: addFolders)
            }
        }
    }

    private var columnVisibility: Binding<NavigationSplitViewVisibility> {
        Binding(
            get: { model.panels == .all ? .all : .detailOnly },
            set: { model.panels = $0 == .detailOnly ? .detailOnly : .all }
        )
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
