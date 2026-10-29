import SwiftUI
import CoreGraphics
import GalleryDomain

/// The photo, over the grid, at the size the display can give it.
///
/// One decode per photo at `.viewerFull` and a transform on top of it: zoom and pan move a bitmap that is
/// already in memory, so neither costs a second read of the file. The viewer owns no state that survives it
/// — which photo is showing lives in the model, so closing it and reopening lands on the same row the grid
/// is highlighting.
public struct ViewerView: View {
    private let model: MediaLibraryModel

    @State private var image: CGImage?
    @State private var isLoading = true
    @State private var zoom: CGFloat = 1
    @State private var baseZoom: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var baseOffset: CGSize = .zero
    @FocusState private var isFocused: Bool

    public init(model: MediaLibraryModel) {
        self.model = model
    }

    public var body: some View {
        if let item = model.viewerItem {
            ZStack {
                Color.black.opacity(0.94).ignoresSafeArea()
                canvas
                chrome(item)
            }
            .focusable()
            .focused($isFocused)
            .focusEffectDisabled()
            .onAppear { isFocused = true }
            .onChange(of: model.viewerID) { _, _ in resetTransform() }
            .onKeyPress(.leftArrow) {
                Task { await model.stepViewer(by: -1) }
                return .handled
            }
            .onKeyPress(.rightArrow) {
                Task { await model.stepViewer(by: 1) }
                return .handled
            }
            .onKeyPress(.escape) {
                model.closeViewer()
                return .handled
            }
            .onKeyPress(.upArrow) { setZoom(zoom * 1.25); return .handled }
            .onKeyPress(.downArrow) { setZoom(zoom / 1.25); return .handled }
            .task(id: LoadKey(item)) {
                await load(item)
            }
            .transition(.opacity)
        }
    }

    @ViewBuilder private var canvas: some View {
        if let image {
            Image(decorative: image, scale: 1)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .scaleEffect(zoom)
                .offset(offset)
                .gesture(pan)
                .simultaneousGesture(magnify)
                .onTapGesture(count: 2) { setZoom(zoom > 1.01 ? 1 : 2.5) }
                .padding(56)
        } else if isLoading {
            ProgressView().controlSize(.large).tint(.white)
        } else {
            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 30, weight: .thin))
                Text("This photo could not be drawn.").font(.callout)
            }
            .foregroundStyle(.white.opacity(0.8))
        }
    }

    @ViewBuilder private func chrome(_ item: MediaItem) -> some View {
        VStack {
            HStack(spacing: 10) {
                Button { model.closeViewer() } label: {
                    Image(systemName: "xmark.circle.fill").font(.title3)
                }
                .buttonStyle(.plain)
                .help("Close (Esc)")

                Text(item.name)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer()

                Button { Task { await model.toggleFavorite(item.id) } } label: {
                    Image(systemName: item.isFavorite ? "star.fill" : "star")
                        .foregroundStyle(item.isFavorite ? .yellow : .white)
                }
                .buttonStyle(.plain)
                .help("Favorite (⌘⇧F)")

                if let index = model.items.firstIndex(where: { $0.id == item.id }) {
                    Text("\(index + 1) of \(model.items.count)")
                        .font(.callout)
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(0.7))
                }

                Button { model.isInspectorPresented.toggle() } label: {
                    Image(systemName: "sidebar.trailing")
                }
                .buttonStyle(.plain)
                .help("Show Info (⌘⌥I)")
            }
            .padding(.horizontal, 18)
            .padding(.top, 14)
            .foregroundStyle(.white)

            Spacer()

            HStack(spacing: 10) {
                Text(item.capture?.instant.formatted(date: .abbreviated, time: .shortened) ?? item.name)
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.7))
                Spacer()
                zoomControls
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 14)
        }
    }

    private var zoomControls: some View {
        HStack(spacing: 8) {
            Button { setZoom(zoom / 1.25) } label: { Image(systemName: "minus.magnifyingglass") }
            Button { setZoom(1) } label: { Text("\(Int(zoom * 100))%").monospacedDigit() }
                .frame(minWidth: 52)
            Button { setZoom(zoom * 1.25) } label: { Image(systemName: "plus.magnifyingglass") }
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .help("Zoom (±, or pinch)")
    }

    // MARK: - Gestures

    private var pan: some Gesture {
        DragGesture()
            .onChanged { value in
                guard zoom > 1.01 else { return }
                offset = CGSize(width: baseOffset.width + value.translation.width,
                                height: baseOffset.height + value.translation.height)
            }
            .onEnded { _ in baseOffset = offset }
    }

    private var magnify: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                zoom = clampZoom(baseZoom * value.magnification)
            }
            .onEnded { _ in
                baseZoom = zoom
                if zoom <= 1.01 { withAnimation(.snappy) { offset = .zero; baseOffset = .zero } }
            }
    }

    private func setZoom(_ value: CGFloat) {
        withAnimation(.snappy(duration: 0.18)) {
            zoom = clampZoom(value)
            baseZoom = zoom
            if zoom <= 1.01 { offset = .zero; baseOffset = .zero }
        }
    }

    private func clampZoom(_ value: CGFloat) -> CGFloat {
        min(8, max(0.5, value))
    }

    private func resetTransform() {
        zoom = 1
        baseZoom = 1
        offset = .zero
        baseOffset = .zero
        image = nil
        isLoading = true
    }

    /// The decode is a full read of the original, so it follows the photo the viewer is actually on rather
    /// than racing the arrow key the user pressed twice.
    private func load(_ item: MediaItem) async {
        let loaded = await model.viewerImage(for: item)
        guard !Task.isCancelled, model.viewerID == item.id else { return }
        image = loaded
        isLoading = false
    }

    /// A new photo is a new decode, and a favorite toggle is not. The id is the whole key: the transform is
    /// reset by `onChange` of the same value.
    private struct LoadKey: Equatable {
        let id: MediaID
        let mtime: Date?
        let stage: IndexStage

        init(_ item: MediaItem) {
            id = item.id
            mtime = item.modificationDate
            stage = item.stage
        }
    }
}
