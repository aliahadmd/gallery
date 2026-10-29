import SwiftUI
import GalleryDomain

/// The middle column: paged rows of the selected album, plus the scan's own progress over it.
public struct LibraryGridView: View {
    private let model: MediaLibraryModel
    private let addFolders: AddFoldersAction

    public init(model: MediaLibraryModel, addFolders: @escaping AddFoldersAction) {
        self.model = model
        self.addFolders = addFolders
    }

    private static let columns = [GridItem(.adaptive(minimum: 160, maximum: 260), spacing: 3)]

    public var body: some View {
        ScrollView {
            if model.items.isEmpty {
                emptyState
            } else if model.sort.field == .captureDate {
                // Day headers under the date sort only: under "Name" a date header would describe an order
                // the page is not in. The header pins, so a long day still says which day it is.
                LazyVStack(alignment: .leading, spacing: 10, pinnedViews: [.sectionHeaders]) {
                    ForEach(model.daySections) { section in
                        Section {
                            LazyVGrid(columns: Self.columns, spacing: 3) {
                                ForEach(section.items) { item in cell(item) }
                            }
                        } header: {
                            DayHeader(title: section.title, count: section.items.count)
                        }
                    }
                    loadMoreTrigger
                }
                .padding(3)
            } else {
                LazyVGrid(columns: Self.columns, spacing: 3) {
                    ForEach(model.items) { item in cell(item) }
                    loadMoreTrigger
                }
                .padding(3)
            }
        }
        .navigationTitle(title)
        .navigationSubtitle(subtitle)
        .searchable(text: searchBinding, placement: .toolbar,
                    prompt: Text("Search \(model.selection.uiTitle(sources: model.sources))"))
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if !model.selectedIDs.isEmpty, let selected = model.selectedItem {
                    let count = model.selectedIDs.count
                    if model.isRecentlyDeleted {
                        Button {
                            Task { await model.restore(model.selectedMediaIDs) }
                        } label: {
                            Label("Restore", systemImage: "arrow.uturn.backward")
                        }
                        .help(count > 1 ? "Put \(count) items back (⌘⌫)" : "Put the photo back where it was (⌘⌫)")

                        Button {
                            Task { await model.deleteForever(model.selectedMediaIDs) }
                        } label: {
                            Label("Delete Forever", systemImage: "trash.slash")
                        }
                        .help("Remove the file for good")
                    } else {
                        Button {
                            Task { await model.moveToTrash(model.selectedMediaIDs) }
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                        .help(count > 1 ? "Move \(count) items to Gallery's trash (⌘⌫)"
                                        : "Move to Gallery's trash (⌘⌫)")

                        Button {
                            Task { await model.toggleFavoriteSelection() }
                        } label: {
                            let allFavorite = model.selectedItems.allSatisfy(\.isFavorite)
                            Label(allFavorite ? "Unfavorite" : "Favorite",
                                  systemImage: allFavorite ? "star.fill" : "star")
                        }
                        .help("Favorite (⌘⇧F)")

                        if count == 1 {
                            Button {
                                model.openViewer(selected.id)
                            } label: {
                                Label("Open", systemImage: "arrow.up.left.and.arrow.down.right")
                            }
                            .help("Open the selected photo (Return)")

                            if model.selection == .duplicates {
                                Button {
                                    Task { await model.keepBestAndTrashRest(around: selected) }
                                } label: {
                                    Label("Keep Best", systemImage: "crown")
                                }
                                .help("Keep the best shot of this set and move the rest to Trash")
                            }
                        }
                    }
                }

                Button {
                    model.isInspectorPresented.toggle()
                } label: {
                    Label("Info", systemImage: "sidebar.trailing")
                }
                .help("Show Info (⌘⌥I)")

                Menu {
                    sortMenu
                } label: {
                    Label("Sort", systemImage: "arrow.up.arrow.down")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()

                Button {
                    Task { await model.rescanAll() }
                } label: {
                    Label("Rescan", systemImage: "arrow.triangle.2.circlepath")
                }
                .help("Re-scan every folder (⌘R)")

                Button {
                    Task { await addFolders() }
                } label: {
                    Label("Add Folder", systemImage: "plus.rectangle.on.folder")
                }
                .help("Add a folder to the library (⌘O)")
            }
        }
        .inspector(isPresented: inspectorBinding) {
            InspectorView(model: model)
                .inspectorColumnWidth(min: 240, ideal: 280, max: 400)
        }
        .overlay(alignment: .bottomTrailing) {
            if let progress = model.activeProgress, progress.phase.isCounting {
                IndexProgressHUD(
                    progress: progress,
                    onPause: model.canPauseScan(progress)
                        ? { Task { await model.pauseScan(progress) } } : nil,
                    onCancel: model.canControlScan(progress)
                        ? { Task { await model.cancelScan(progress.sourceID) } } : nil
                )
                .padding(12)
            }
        }
    }

    @ViewBuilder private func cell(_ item: MediaItem) -> some View {
        MediaCellView(item: item, model: model, isSelected: model.selectedIDs.contains(item.id))
    }

    /// One clear pixel at the end of the grid is what turns "the user reached the bottom" into a page
    /// request; a scroll-offset observer would fight the lazy stack.
    @ViewBuilder private var loadMoreTrigger: some View {
        if model.hasMorePages {
            Color.clear
                .frame(height: 1)
                .onAppear { Task { await model.loadMore() } }
        }
    }

    private var title: String { model.selectionTitle }

    private var searchBinding: Binding<String> {
        Binding(get: { model.searchFieldText }, set: { model.updateSearch($0) })
    }

    private var inspectorBinding: Binding<Bool> {
        Binding(get: { model.isInspectorPresented }, set: { model.isInspectorPresented = $0 })
    }

    private var subtitle: String {
        if model.isLoadingPage { return "Loading…" }
        return model.rowCount.formatted() + (model.rowCount == 1 ? " item" : " items")
    }

    @ViewBuilder private var sortMenu: some View {
        Picker("Sort by", selection: fieldBinding) {
            ForEach(SortField.allCases, id: \.self) { field in
                Text(field.uiTitle).tag(field)
            }
        }
        Picker("Order", selection: orderBinding) {
            Text("Descending").tag(SortDirection.descending)
            Text("Ascending").tag(SortDirection.ascending)
        }
    }

    /// A sort change re-reads from the first page: the keyset cursor points into an ordering that no
    /// longer exists, so continuing from it would silently drop or repeat rows.
    private var fieldBinding: Binding<SortField> {
        Binding(get: { model.sort.field }, set: { apply(sort: MediaSort(field: $0, order: model.sort.order)) })
    }

    private var orderBinding: Binding<SortDirection> {
        Binding(get: { model.sort.order }, set: { apply(sort: MediaSort(field: model.sort.field, order: $0)) })
    }

    private func apply(sort: MediaSort) {
        model.sort = sort
        Task { await model.reload() }
    }

    @ViewBuilder private var emptyState: some View {
        VStack(spacing: 10) {
            if model.isLoadingPage {
                ProgressView().controlSize(.small)
            } else if let progress = model.activeProgress, progress.phase.isCounting {
                Image(systemName: "rays")
                    .font(.system(size: 30, weight: .thin))
                    .foregroundStyle(.secondary)
                Text("Listing files…").font(.title3)
                Text("Photos appear as they are found.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else if model.isSearching {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 30, weight: .thin))
                    .foregroundStyle(.secondary)
                Text("Nothing matches “\(model.appliedSearch)”.").font(.title3)
                Text("Search looks at names, folders and the metadata already read.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Image(systemName: "photo.on.rectangle")
                    .font(.system(size: 30, weight: .thin))
                    .foregroundStyle(.secondary)
                Text("Nothing here yet.").font(.title3)
                Text("This album has no items. Add a folder or rescan it.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 120)
    }
}

extension SortField {
    var uiTitle: String {
        switch self {
        case .captureDate: "Date Captured"
        case .dateAdded: "Date Added"
        case .fileName: "Name"
        case .byteSize: "File Size"
        case .pixelCount: "Resolution"
        case .duration: "Duration"
        case .aesthetic: "Aesthetic"
        }
    }
}

/// A pinned day header. Opaque on purpose: a material would let the previous day's tiles show through the
/// one line that is supposed to separate them.
private struct DayHeader: View {
    let title: String
    let count: Int

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .font(.headline)
            Text(count.formatted())
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 6)
        .background(.bar)
    }
}
