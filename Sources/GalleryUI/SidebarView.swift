import SwiftUI
import AppKit
import GalleryDomain

/// The two things the sidebar can select in M2: a folder the user picked, and a type album over everything.
/// Date and location albums need pass B's decoded metadata, so listing them now would be an empty promise.
public struct SidebarView: View {
    private let model: MediaLibraryModel

    public init(model: MediaLibraryModel) {
        self.model = model
    }

    private static let typeAlbums: [(kind: AlbumKind, title: String, symbol: String)] = [
        (.allPhotos, "All Photos", "photo"),
        (.allVideos, "Videos", "video"),
        (.favorites, "Favorites", "star"),
        (.screenshots, "Screenshots", "camera.viewfinder"),
        (.raw, "RAW", "doc"),
        (.livePhotos, "Live Photos", "livephoto"),
        (.animated, "Animated", "film"),
        (.offline, "Not Downloaded", "icloud.slash"),
        (.problems, "Problems", "exclamationmark.triangle"),
    ]

    public var body: some View {
        List(selection: albumSelection) {
            Section("Folders") {
                if model.sources.isEmpty {
                    Text("No folders yet.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                ForEach(model.sources) { source in
                    SourceRow(source: source, model: model)
                        .tag(AlbumKind.folder(source.id))
                }
            }
            Section("Library") {
                ForEach(Self.typeAlbums, id: \.kind) { album in
                    Label(album.title, systemImage: album.symbol)
                        .tag(album.kind)
                }
            }
        }
        .listStyle(.sidebar)
    }

    /// Setting the selection starts the page load instead of performing it, because `select` is an actor hop
    /// and a `Binding` setter has nowhere to await.
    private var albumSelection: Binding<AlbumKind?> {
        Binding(
            get: { model.selection },
            set: { guard let album = $0 else { return }
                Task { await model.select(album) }
            }
        )
    }
}

private struct SourceRow: View {
    let source: FolderSource
    let model: MediaLibraryModel

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 1) {
                Text(source.displayName).lineLimit(1)
                if source.bookmarkState.blocksScanning {
                    Text(source.bookmarkState.userReason)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        } icon: {
            Image(systemName: symbol)
                .foregroundStyle(source.bookmarkState.blocksScanning ? .orange : .secondary)
        }
        .contextMenu {
            Button("Rescan") { Task { await model.rescan(source.id) } }
            if let progress = model.progress[source.id], progress.phase.isCounting {
                Button(progress.isPaused ? "Resume" : "Pause") {
                    Task { await model.setPaused(source.id, !progress.isPaused) }
                }
            }
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([source.rootURL])
            }
            Divider()
            Button("Remove Folder", role: .destructive) { Task { await model.remove(source) } }
        }
    }

    private var symbol: String {
        if source.bookmarkState.blocksScanning { return "folder.badge.questionmark" }
        if model.progress[source.id]?.phase.isCounting == true { return "folder.badge.gearshape" }
        return "folder"
    }
}

extension AlbumKind {
    /// Header text for the detail column. Folder names come from the catalog because that is what the rows
    /// were written under — a renamed volume mount point should not retitle an album mid-scroll.
    func uiTitle(sources: [FolderSource]) -> String {
        switch self {
        case .folder(let id), .subfolder(let id, _):
            sources.first { $0.id == id }?.displayName ?? "Missing Folder"
        case .all: "All Media"
        case .allPhotos: "All Photos"
        case .allVideos: "Videos"
        case .favorites: "Favorites"
        case .screenshots: "Screenshots"
        case .raw: "RAW"
        case .livePhotos: "Live Photos"
        case .animated: "Animated"
        case .offline: "Not Downloaded"
        case .recentlyDeleted: "Recently Deleted"
        case .uncategorized: "Uncategorized"
        case .problems: "Problems"
        case .day, .month, .event, .location, .place, .smart: "Album"
        }
    }
}

extension IndexPhase {
    /// Whether a scan of this phase is still producing numbers, which is what makes a HUD worth drawing.
    var isCounting: Bool {
        switch self {
        case .finished, .failed: false
        default: true
        }
    }
}
